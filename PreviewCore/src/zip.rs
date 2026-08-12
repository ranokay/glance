use crate::error::CoreError;
use crate::model::{ArchiveEntry, ArchiveEntryType, ArchivePayload};
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;
use zip::result::ZipError;

const MAX_ENTRY_COUNT: usize = 50_000;
const MAX_CENTRAL_DIRECTORY_SIZE: u64 = 64 * 1_024 * 1_024;
const EOCD_MIN_SIZE: usize = 22;
const EOCD_SEARCH_SIZE: u64 = EOCD_MIN_SIZE as u64 + u16::MAX as u64;

pub(crate) fn scan_zip(path: &Path) -> Result<ArchivePayload, CoreError> {
    let mut file = File::open(path)
        .map_err(|error| CoreError::io(format!("Could not open ZIP archive: {error}")))?;
    let file_size = file
        .metadata()
        .map_err(|error| CoreError::io(format!("Could not inspect ZIP archive: {error}")))?
        .len();
    preflight_central_directory(&mut file, file_size)?;
    file.seek(SeekFrom::Start(0))
        .map_err(|error| CoreError::io(format!("Could not seek ZIP archive: {error}")))?;

    let mut archive = zip::ZipArchive::new(file).map_err(map_zip_error)?;
    if archive.len() > MAX_ENTRY_COUNT {
        return Err(CoreError::limit(format!(
            "ZIP archive metadata exceeds the {MAX_ENTRY_COUNT} entry preview limit"
        )));
    }

    let mut entries = Vec::with_capacity(archive.len());
    let mut compressed_size = 0_u64;
    let mut uncompressed_size = 0_u64;
    for index in 0..archive.len() {
        let entry = archive.by_index_raw(index).map_err(map_zip_error)?;
        if entry.encrypted() {
            return Err(CoreError::unsupported(
                "Encrypted ZIP archives are not supported",
            ));
        }
        let path = entry.name().to_owned();
        if path == "__MACOSX" || path.starts_with("__MACOSX/") {
            continue;
        }
        compressed_size = compressed_size
            .checked_add(entry.compressed_size())
            .ok_or_else(|| CoreError::limit("ZIP archive metadata size overflow"))?;
        uncompressed_size = uncompressed_size
            .checked_add(entry.size())
            .ok_or_else(|| CoreError::limit("ZIP archive metadata size overflow"))?;
        let entry_type = if entry.is_dir() {
            ArchiveEntryType::Directory
        } else if entry.is_file() {
            ArchiveEntryType::File
        } else {
            ArchiveEntryType::Other
        };
        entries.push(ArchiveEntry {
            path,
            entry_type,
            size: entry.size(),
            modified_unix_seconds: entry.last_modified().and_then(zip_datetime_to_unix),
        });
    }

    Ok(ArchivePayload {
        entries,
        compressed_size,
        uncompressed_size,
        scanned_uncompressed_size: None,
        truncated: false,
    })
}

fn preflight_central_directory(file: &mut File, file_size: u64) -> Result<(), CoreError> {
    if file_size < EOCD_MIN_SIZE as u64 {
        return Err(CoreError::parse(
            "ZIP archive is too small to contain an end record",
        ));
    }
    let tail_size = file_size.min(EOCD_SEARCH_SIZE);
    file.seek(SeekFrom::Start(file_size - tail_size))
        .map_err(|error| CoreError::io(format!("Could not seek ZIP archive: {error}")))?;
    let mut tail = vec![0_u8; tail_size as usize];
    file.read_exact(&mut tail)
        .map_err(|error| CoreError::io(format!("Could not read ZIP archive: {error}")))?;
    let eocd_index = (0..=tail.len() - EOCD_MIN_SIZE)
        .rev()
        .find(|&index| {
            tail[index..].starts_with(b"PK\x05\x06")
                && read_u16(&tail, index + 20)
                    .is_some_and(|length| index + EOCD_MIN_SIZE + length as usize == tail.len())
        })
        .ok_or_else(|| CoreError::parse("ZIP end-of-central-directory record was not found"))?;
    let eocd_offset = file_size - tail_size + eocd_index as u64;

    let disk = read_u16(&tail, eocd_index + 4).unwrap();
    let central_disk = read_u16(&tail, eocd_index + 6).unwrap();
    let entries_on_disk = read_u16(&tail, eocd_index + 8).unwrap();
    let entry_count = read_u16(&tail, eocd_index + 10).unwrap();
    let central_size_32 = read_u32(&tail, eocd_index + 12).unwrap();
    let central_offset_32 = read_u32(&tail, eocd_index + 16).unwrap();
    if disk != 0 || central_disk != 0 || entries_on_disk != entry_count {
        return Err(CoreError::unsupported(
            "Multi-disk ZIP archives are not supported",
        ));
    }

    let uses_zip64 =
        entry_count == u16::MAX || central_size_32 == u32::MAX || central_offset_32 == u32::MAX;
    let (entry_count, central_size, central_offset) = if uses_zip64 {
        parse_zip64_directory(file, eocd_offset)?
    } else {
        (
            u64::from(entry_count),
            u64::from(central_size_32),
            u64::from(central_offset_32),
        )
    };
    if entry_count > MAX_ENTRY_COUNT as u64 {
        return Err(CoreError::limit(format!(
            "ZIP archive metadata exceeds the {MAX_ENTRY_COUNT} entry preview limit"
        )));
    }
    if central_size > MAX_CENTRAL_DIRECTORY_SIZE {
        return Err(CoreError::limit(format!(
            "ZIP central directory exceeds the {MAX_CENTRAL_DIRECTORY_SIZE} byte preview limit"
        )));
    }
    let central_end = central_offset
        .checked_add(central_size)
        .ok_or_else(|| CoreError::limit("ZIP central directory offset overflow"))?;
    if central_end > file_size {
        return Err(CoreError::parse(
            "ZIP central directory lies outside the archive",
        ));
    }
    Ok(())
}

fn parse_zip64_directory(file: &mut File, eocd_offset: u64) -> Result<(u64, u64, u64), CoreError> {
    if eocd_offset < 20 {
        return Err(CoreError::parse("ZIP64 locator is missing"));
    }
    file.seek(SeekFrom::Start(eocd_offset - 20))
        .map_err(|error| CoreError::io(format!("Could not seek ZIP64 locator: {error}")))?;
    let mut locator = [0_u8; 20];
    file.read_exact(&mut locator)
        .map_err(|error| CoreError::io(format!("Could not read ZIP64 locator: {error}")))?;
    if !locator.starts_with(b"PK\x06\x07") {
        return Err(CoreError::parse("ZIP64 locator is malformed"));
    }
    if read_u32(&locator, 4) != Some(0) || read_u32(&locator, 16) != Some(1) {
        return Err(CoreError::unsupported(
            "Multi-disk ZIP64 archives are not supported",
        ));
    }
    let record_offset = read_u64(&locator, 8).unwrap();
    file.seek(SeekFrom::Start(record_offset))
        .map_err(|error| CoreError::io(format!("Could not seek ZIP64 end record: {error}")))?;
    let mut record = [0_u8; 56];
    file.read_exact(&mut record)
        .map_err(|error| CoreError::io(format!("Could not read ZIP64 end record: {error}")))?;
    if !record.starts_with(b"PK\x06\x06") {
        return Err(CoreError::parse("ZIP64 end record is malformed"));
    }
    if read_u32(&record, 16) != Some(0) || read_u32(&record, 20) != Some(0) {
        return Err(CoreError::unsupported(
            "Multi-disk ZIP64 archives are not supported",
        ));
    }
    let entries_on_disk = read_u64(&record, 24).unwrap();
    let entry_count = read_u64(&record, 32).unwrap();
    if entries_on_disk != entry_count {
        return Err(CoreError::unsupported(
            "Multi-disk ZIP64 archives are not supported",
        ));
    }
    Ok((
        entry_count,
        read_u64(&record, 40).unwrap(),
        read_u64(&record, 48).unwrap(),
    ))
}

fn map_zip_error(error: ZipError) -> CoreError {
    match error {
        ZipError::Io(error) => CoreError::io(format!("Could not read ZIP archive: {error}")),
        ZipError::UnsupportedArchive(message) => CoreError::unsupported(message),
        ZipError::CompressionMethodNotSupported(method) => {
            CoreError::unsupported(format!("ZIP compression method {method} is not supported"))
        }
        ZipError::InvalidPassword => CoreError::unsupported("Encrypted ZIP archive is unsupported"),
        other => CoreError::parse(format!("Could not parse ZIP archive: {other}")),
    }
}

fn zip_datetime_to_unix(date: zip::DateTime) -> Option<f64> {
    // ZIP DOS timestamps are local wall-clock values without a time-zone offset.
    // `mktime` applies the previewing Mac's current time zone and daylight-saving rules.
    let mut local_time: libc::tm = unsafe { std::mem::zeroed() };
    local_time.tm_sec = i32::from(date.second());
    local_time.tm_min = i32::from(date.minute());
    local_time.tm_hour = i32::from(date.hour());
    local_time.tm_mday = i32::from(date.day());
    local_time.tm_mon = i32::from(date.month()) - 1;
    local_time.tm_year = i32::from(date.year()) - 1900;
    local_time.tm_isdst = -1;
    let timestamp = unsafe { libc::mktime(&mut local_time) };
    (timestamp != -1).then_some(timestamp as f64)
}

fn read_u16(bytes: &[u8], offset: usize) -> Option<u16> {
    bytes
        .get(offset..offset + 2)?
        .try_into()
        .ok()
        .map(u16::from_le_bytes)
}

fn read_u32(bytes: &[u8], offset: usize) -> Option<u32> {
    bytes
        .get(offset..offset + 4)?
        .try_into()
        .ok()
        .map(u32::from_le_bytes)
}

fn read_u64(bytes: &[u8], offset: usize) -> Option<u64> {
    bytes
        .get(offset..offset + 8)?
        .try_into()
        .ok()
        .map(u64::from_le_bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn fixture(name: &str) -> std::path::PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../GlanceTests/TestFiles/archives")
            .join(name)
    }

    #[test]
    fn scans_real_zip_and_filters_macos_metadata() {
        let payload = scan_zip(&fixture("example-root-directory.zip")).unwrap();
        assert!(!payload.entries.is_empty());
        assert!(
            payload
                .entries
                .iter()
                .all(|entry| !entry.path.starts_with("__MACOSX"))
        );
        assert!(payload.uncompressed_size > 0);
    }

    #[test]
    fn filtered_macos_metadata_does_not_affect_totals() {
        let path = temporary_path();
        fs::write(&path, single_file_zip(b"__MACOSX/metadata", 0, false)).unwrap();

        let payload = scan_zip(&path).unwrap();
        assert!(payload.entries.is_empty());
        assert_eq!(payload.compressed_size, 0);
        assert_eq!(payload.uncompressed_size, 0);
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn rejects_corruption_and_central_directory_limit_before_parsing() {
        let malformed = std::env::temp_dir().join(format!(
            "glance-malformed-zip-{}-{}.zip",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::write(&malformed, b"not a zip").unwrap();
        assert!(matches!(scan_zip(&malformed), Err(CoreError::Parse(_))));

        let mut eocd = vec![0_u8; EOCD_MIN_SIZE];
        eocd[0..4].copy_from_slice(b"PK\x05\x06");
        eocd[12..16].copy_from_slice(&(MAX_CENTRAL_DIRECTORY_SIZE as u32 + 1).to_le_bytes());
        fs::write(&malformed, eocd).unwrap();
        assert!(matches!(
            scan_zip(&malformed),
            Err(CoreError::ResourceLimit(_))
        ));
        fs::remove_file(malformed).unwrap();
    }

    #[test]
    fn preserves_dos_timestamps_as_local_wall_time() {
        let date = zip::DateTime::from_date_and_time(2024, 2, 29, 12, 34, 56).unwrap();
        let timestamp = zip_datetime_to_unix(date).unwrap() as libc::time_t;
        let mut local_time: libc::tm = unsafe { std::mem::zeroed() };
        let converted = unsafe { libc::localtime_r(&timestamp, &mut local_time) };

        assert!(!converted.is_null());
        assert_eq!(local_time.tm_year + 1900, 2024);
        assert_eq!(local_time.tm_mon + 1, 2);
        assert_eq!(local_time.tm_mday, 29);
        assert_eq!(local_time.tm_hour, 12);
        assert_eq!(local_time.tm_min, 34);
        assert_eq!(local_time.tm_sec, 56);
    }

    #[test]
    fn decodes_cp437_and_utf8_names() {
        let path = temporary_path();
        fs::write(
            &path,
            single_file_zip(&[0x82, b'.', b't', b'x', b't'], 0, false),
        )
        .unwrap();
        let cp437 = scan_zip(&path).unwrap();
        assert_eq!(cp437.entries[0].path, "é.txt");

        fs::write(&path, single_file_zip("ș.txt".as_bytes(), 0x0800, false)).unwrap();
        let utf8 = scan_zip(&path).unwrap();
        assert_eq!(utf8.entries[0].path, "ș.txt");
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn scans_zip64_metadata() {
        let path = temporary_path();
        fs::write(&path, single_file_zip(b"zip64.txt", 0, true)).unwrap();
        let payload = scan_zip(&path).unwrap();
        assert_eq!(payload.entries[0].path, "zip64.txt");
        assert_eq!(payload.uncompressed_size, 7);
        fs::remove_file(path).unwrap();
    }

    fn single_file_zip(name: &[u8], flags: u16, zip64: bool) -> Vec<u8> {
        let contents = b"fixture";
        let checksum = crc32(contents);
        let mut bytes = Vec::new();
        push_u32(&mut bytes, 0x0403_4b50);
        push_u16(&mut bytes, 20);
        push_u16(&mut bytes, flags);
        push_u16(&mut bytes, 0);
        push_u16(&mut bytes, 0);
        push_u16(&mut bytes, 0);
        push_u32(&mut bytes, checksum);
        push_u32(&mut bytes, contents.len() as u32);
        push_u32(&mut bytes, contents.len() as u32);
        push_u16(&mut bytes, name.len() as u16);
        push_u16(&mut bytes, 0);
        bytes.extend_from_slice(name);
        bytes.extend_from_slice(contents);

        let central_offset = bytes.len() as u64;
        push_u32(&mut bytes, 0x0201_4b50);
        push_u16(&mut bytes, 20);
        push_u16(&mut bytes, 20);
        push_u16(&mut bytes, flags);
        push_u16(&mut bytes, 0);
        push_u16(&mut bytes, 0);
        push_u16(&mut bytes, 0);
        push_u32(&mut bytes, checksum);
        push_u32(&mut bytes, contents.len() as u32);
        push_u32(&mut bytes, contents.len() as u32);
        push_u16(&mut bytes, name.len() as u16);
        push_u16(&mut bytes, 0);
        push_u16(&mut bytes, 0);
        push_u16(&mut bytes, 0);
        push_u16(&mut bytes, 0);
        push_u32(&mut bytes, 0);
        push_u32(&mut bytes, 0);
        bytes.extend_from_slice(name);
        let central_size = bytes.len() as u64 - central_offset;

        if zip64 {
            let zip64_offset = bytes.len() as u64;
            push_u32(&mut bytes, 0x0606_4b50);
            push_u64(&mut bytes, 44);
            push_u16(&mut bytes, 45);
            push_u16(&mut bytes, 45);
            push_u32(&mut bytes, 0);
            push_u32(&mut bytes, 0);
            push_u64(&mut bytes, 1);
            push_u64(&mut bytes, 1);
            push_u64(&mut bytes, central_size);
            push_u64(&mut bytes, central_offset);
            push_u32(&mut bytes, 0x0706_4b50);
            push_u32(&mut bytes, 0);
            push_u64(&mut bytes, zip64_offset);
            push_u32(&mut bytes, 1);
        }

        push_u32(&mut bytes, 0x0605_4b50);
        push_u16(&mut bytes, 0);
        push_u16(&mut bytes, 0);
        push_u16(&mut bytes, if zip64 { u16::MAX } else { 1 });
        push_u16(&mut bytes, if zip64 { u16::MAX } else { 1 });
        push_u32(
            &mut bytes,
            if zip64 { u32::MAX } else { central_size as u32 },
        );
        push_u32(
            &mut bytes,
            if zip64 {
                u32::MAX
            } else {
                central_offset as u32
            },
        );
        push_u16(&mut bytes, 0);
        bytes
    }

    fn crc32(bytes: &[u8]) -> u32 {
        let mut crc = u32::MAX;
        for byte in bytes {
            crc ^= u32::from(*byte);
            for _ in 0..8 {
                crc = if crc & 1 == 1 {
                    0xedb8_8320 ^ (crc >> 1)
                } else {
                    crc >> 1
                };
            }
        }
        !crc
    }

    fn push_u16(bytes: &mut Vec<u8>, value: u16) {
        bytes.extend_from_slice(&value.to_le_bytes());
    }

    fn push_u32(bytes: &mut Vec<u8>, value: u32) {
        bytes.extend_from_slice(&value.to_le_bytes());
    }

    fn push_u64(bytes: &mut Vec<u8>, value: u64) {
        bytes.extend_from_slice(&value.to_le_bytes());
    }

    fn temporary_path() -> std::path::PathBuf {
        std::env::temp_dir().join(format!(
            "glance-zip-test-{}-{}.zip",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ))
    }
}
