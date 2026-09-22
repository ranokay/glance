use crate::error::CoreError;
use crate::model::{ArchiveEntry, ArchiveEntryType, ArchivePayload};
use rars::{Archive, ArchiveReader, Error as RarError};
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

const RAR4_SIGNATURE: &[u8; 7] = b"Rar!\x1a\x07\x00";
const RAR5_SIGNATURE: &[u8; 8] = b"Rar!\x1a\x07\x01\x00";
const MAX_ARCHIVE_SIZE: u64 = 200 * 1_024 * 1_024;
const MAX_HEADER_SIZE: u64 = 1_024 * 1_024;
const MAX_TOTAL_HEADER_SIZE: u64 = 8 * 1_024 * 1_024;
const MAX_ENTRY_COUNT: usize = 50_000;
const MAX_PATH_COMPONENTS: usize = 128;
const MAX_TOTAL_PATH_BYTES: usize = 32 * 1_024 * 1_024;

pub(crate) fn scan_rar(path: &Path) -> Result<ArchivePayload, CoreError> {
    let mut file = File::open(path)
        .map_err(|error| CoreError::io(format!("Could not open RAR archive: {error}")))?;
    let file_size = file
        .metadata()
        .map_err(|error| CoreError::io(format!("Could not inspect RAR archive: {error}")))?
        .len();
    if file_size > MAX_ARCHIVE_SIZE {
        return Err(CoreError::limit(format!(
            "RAR archive exceeds the {MAX_ARCHIVE_SIZE} byte preview limit"
        )));
    }

    let format = preflight_archive(&mut file, file_size)?;
    let archive = ArchiveReader::read_path(path).map_err(map_rar_error)?;
    match (&format, &archive) {
        (RarFormat::Rar4, Archive::Rar15To40(_)) | (RarFormat::Rar5, Archive::Rar50Plus(_)) => {}
        _ => {
            return Err(CoreError::parse(
                "RAR archive version changed while being read",
            ));
        }
    }

    let mut scanner = ArchiveScanner::default();
    match archive {
        Archive::Rar15To40(archive) => {
            if archive.main.is_volume() {
                return Err(CoreError::unsupported(
                    "Multipart RAR archives are not supported",
                ));
            }
            if archive.main.has_encrypted_headers() {
                return Err(CoreError::unsupported(
                    "Encrypted RAR archives are not supported",
                ));
            }
            for block in archive.blocks {
                let rars::rar15_40::Block::File(entry) = block else {
                    continue;
                };
                scanner.push(
                    entry.name_lossy(),
                    entry.is_directory(),
                    false,
                    entry.is_encrypted(),
                    entry.is_split_before() || entry.is_split_after(),
                    entry.pack_size,
                    entry.unp_size,
                    dos_datetime_to_unix(entry.file_time),
                )?;
            }
        }
        Archive::Rar50Plus(archive) => {
            if archive.main.is_volume() {
                return Err(CoreError::unsupported(
                    "Multipart RAR archives are not supported",
                ));
            }
            for block in archive.blocks {
                let rars::rar50::Block::File(entry) = block else {
                    continue;
                };
                scanner.push(
                    entry.name_lossy(),
                    entry.is_directory(),
                    entry.is_redirection(),
                    entry.encrypted,
                    entry.is_split_before() || entry.is_split_after(),
                    entry.packed_size(),
                    entry.unpacked_size,
                    entry.htime_mtime.or(entry.mtime).map(f64::from),
                )?;
            }
        }
        Archive::Rar13(_) => {
            return Err(CoreError::unsupported(
                "RAR 1.3 and 1.4 archives are not supported",
            ));
        }
        _ => {
            return Err(CoreError::unsupported(
                "RAR archive version is not supported",
            ));
        }
    }

    Ok(ArchivePayload {
        entries: scanner.entries,
        compressed_size: scanner.compressed_size,
        uncompressed_size: scanner.uncompressed_size,
        scanned_uncompressed_size: None,
        truncated: false,
    })
}

#[derive(Default)]
struct ArchiveScanner {
    entries: Vec<ArchiveEntry>,
    compressed_size: u64,
    uncompressed_size: u64,
    path_bytes: usize,
}

impl ArchiveScanner {
    #[allow(clippy::too_many_arguments)]
    fn push(
        &mut self,
        raw_path: String,
        is_directory: bool,
        is_other: bool,
        is_encrypted: bool,
        is_split: bool,
        compressed_size: u64,
        uncompressed_size: u64,
        modified_unix_seconds: Option<f64>,
    ) -> Result<(), CoreError> {
        if self.entries.len() >= MAX_ENTRY_COUNT {
            return Err(CoreError::limit(format!(
                "RAR archive metadata exceeds the {MAX_ENTRY_COUNT} entry preview limit"
            )));
        }
        if is_encrypted {
            return Err(CoreError::unsupported(
                "Encrypted RAR archives are not supported",
            ));
        }
        if is_split {
            return Err(CoreError::unsupported(
                "Multipart RAR archives are not supported",
            ));
        }

        let path = normalize_path(&raw_path)?;
        let component_count = path.split('/').count();
        if component_count > MAX_PATH_COMPONENTS {
            return Err(CoreError::limit(format!(
                "RAR entry path exceeds the {MAX_PATH_COMPONENTS} component preview limit"
            )));
        }
        self.path_bytes = self
            .path_bytes
            .checked_add(path.len())
            .ok_or_else(|| CoreError::limit("RAR entry path metadata size overflow"))?;
        if self.path_bytes > MAX_TOTAL_PATH_BYTES {
            return Err(CoreError::limit(format!(
                "RAR entry paths exceed the {MAX_TOTAL_PATH_BYTES} byte preview limit"
            )));
        }
        self.compressed_size = self
            .compressed_size
            .checked_add(compressed_size)
            .ok_or_else(|| CoreError::limit("RAR compressed size metadata overflow"))?;
        self.uncompressed_size = self
            .uncompressed_size
            .checked_add(uncompressed_size)
            .ok_or_else(|| CoreError::limit("RAR uncompressed size metadata overflow"))?;

        self.entries.push(ArchiveEntry {
            path,
            entry_type: if is_directory {
                ArchiveEntryType::Directory
            } else if is_other {
                ArchiveEntryType::Other
            } else {
                ArchiveEntryType::File
            },
            size: uncompressed_size,
            modified_unix_seconds,
        });
        Ok(())
    }
}

fn normalize_path(path: &str) -> Result<String, CoreError> {
    let normalized = path.replace('\\', "/");
    let mut components = Vec::new();
    for component in normalized.split('/') {
        match component {
            "" | "." => {}
            ".." => {
                return Err(CoreError::parse(
                    "RAR archive contains a parent-directory path component",
                ));
            }
            component => components.push(component),
        }
    }
    if components.is_empty() {
        return Err(CoreError::parse("RAR archive contains an empty entry path"));
    }
    Ok(components.join("/"))
}

#[derive(Debug, PartialEq)]
enum RarFormat {
    Rar4,
    Rar5,
}

fn preflight_archive(file: &mut File, file_size: u64) -> Result<RarFormat, CoreError> {
    let mut signature = [0_u8; 8];
    let signature_length = usize::try_from(file_size.min(signature.len() as u64)).unwrap();
    file.read_exact(&mut signature[..signature_length])
        .map_err(|error| CoreError::io(format!("Could not read RAR signature: {error}")))?;
    file.seek(SeekFrom::Start(0))
        .map_err(|error| CoreError::io(format!("Could not seek RAR archive: {error}")))?;

    if signature.starts_with(RAR5_SIGNATURE) {
        preflight_rar5(file, file_size)?;
        Ok(RarFormat::Rar5)
    } else if signature.starts_with(RAR4_SIGNATURE) {
        preflight_rar4(file, file_size)?;
        Ok(RarFormat::Rar4)
    } else {
        Err(CoreError::parse("RAR archive has an invalid signature"))
    }
}

fn preflight_rar4(file: &mut File, file_size: u64) -> Result<(), CoreError> {
    let mut offset = RAR4_SIGNATURE.len() as u64;
    let mut total_header_size = 0_u64;
    let mut block_count = 0_usize;
    let mut saw_end = false;

    while offset < file_size {
        let base = read_at::<7>(file, offset, "RAR4 base header")?;
        let header_type = base[2];
        let flags = u16::from_le_bytes([base[3], base[4]]);
        let header_size = u64::from(u16::from_le_bytes([base[5], base[6]]));
        if header_size < 7 {
            return Err(CoreError::parse(
                "RAR4 archive contains an invalid header size",
            ));
        }
        check_header_limits(header_size, &mut total_header_size, &mut block_count)?;
        let header_end = offset
            .checked_add(header_size)
            .ok_or_else(|| CoreError::limit("RAR4 header offset overflow"))?;
        if header_end > file_size {
            return Err(CoreError::parse("RAR4 header lies outside the archive"));
        }

        let body_length = usize::try_from((header_size - 7).min(33)).unwrap();
        let mut body = [0_u8; 33];
        read_exact_at(file, offset + 7, &mut body[..body_length], "RAR4 header")?;

        if header_type == 0x73 {
            if flags & 0x0001 != 0 {
                return Err(CoreError::unsupported(
                    "Multipart RAR archives are not supported",
                ));
            }
            if flags & 0x0080 != 0 {
                return Err(CoreError::unsupported(
                    "Encrypted RAR archives are not supported",
                ));
            }
        }

        let data_size = if matches!(header_type, 0x74 | 0x7a) {
            if body_length < 25 {
                return Err(CoreError::parse("RAR4 file header is truncated"));
            }
            let low = u64::from(read_u32(&body, 0).unwrap());
            let high = if flags & 0x0100 != 0 {
                if body_length < 33 {
                    return Err(CoreError::parse("RAR4 large-file header is truncated"));
                }
                u64::from(read_u32(&body, 25).unwrap())
            } else {
                0
            };
            low | (high << 32)
        } else if flags & 0x8000 != 0 {
            if body_length < 4 {
                return Err(CoreError::parse("RAR4 long-block header is truncated"));
            }
            u64::from(read_u32(&body, 0).unwrap())
        } else {
            0
        };
        let next = header_end
            .checked_add(data_size)
            .ok_or_else(|| CoreError::limit("RAR4 data offset overflow"))?;
        if next > file_size {
            return Err(CoreError::parse("RAR4 entry data lies outside the archive"));
        }
        offset = next;
        if header_type == 0x7b {
            saw_end = true;
            break;
        }
    }

    if !saw_end && offset != file_size {
        return Err(CoreError::parse("RAR4 end-of-archive header was not found"));
    }
    Ok(())
}

fn preflight_rar5(file: &mut File, file_size: u64) -> Result<(), CoreError> {
    let mut offset = RAR5_SIGNATURE.len() as u64;
    let mut total_header_size = 0_u64;
    let mut block_count = 0_usize;
    let mut saw_end = false;

    while offset < file_size {
        let available = usize::try_from((file_size - offset).min(64)).unwrap();
        let mut probe = [0_u8; 64];
        read_exact_at(file, offset, &mut probe[..available], "RAR5 header")?;
        if available < 6 {
            return Err(CoreError::parse("RAR5 header is truncated"));
        }

        let (header_size, size_end) = read_vint(&probe[..available], 4)?;
        let header_total = 4_u64
            .checked_add((size_end - 4) as u64)
            .and_then(|value| value.checked_add(header_size))
            .ok_or_else(|| CoreError::limit("RAR5 header size overflow"))?;
        check_header_limits(header_total, &mut total_header_size, &mut block_count)?;
        let header_end = offset
            .checked_add(header_total)
            .ok_or_else(|| CoreError::limit("RAR5 header offset overflow"))?;
        if header_end > file_size {
            return Err(CoreError::parse("RAR5 header lies outside the archive"));
        }

        let (header_type, mut cursor) = read_vint(&probe[..available], size_end)?;
        let (header_flags, next) = read_vint(&probe[..available], cursor)?;
        cursor = next;
        if header_flags & 0x0001 != 0 {
            (_, cursor) = read_vint(&probe[..available], cursor)?;
        }
        let data_size = if header_flags & 0x0002 != 0 {
            let (data_size, next) = read_vint(&probe[..available], cursor)?;
            cursor = next;
            data_size
        } else {
            0
        };

        if header_type == 1 {
            let (archive_flags, _) = read_vint(&probe[..available], cursor)?;
            if archive_flags & 0x0001 != 0 {
                return Err(CoreError::unsupported(
                    "Multipart RAR archives are not supported",
                ));
            }
        } else if header_type == 4 {
            return Err(CoreError::unsupported(
                "Encrypted RAR archives are not supported",
            ));
        }

        let next = header_end
            .checked_add(data_size)
            .ok_or_else(|| CoreError::limit("RAR5 data offset overflow"))?;
        if next > file_size {
            return Err(CoreError::parse("RAR5 entry data lies outside the archive"));
        }
        offset = next;
        if header_type == 5 {
            saw_end = true;
            break;
        }
    }

    if !saw_end && offset != file_size {
        return Err(CoreError::parse("RAR5 end-of-archive header was not found"));
    }
    Ok(())
}

fn check_header_limits(
    header_size: u64,
    total_header_size: &mut u64,
    block_count: &mut usize,
) -> Result<(), CoreError> {
    if header_size > MAX_HEADER_SIZE {
        return Err(CoreError::limit(format!(
            "RAR header exceeds the {MAX_HEADER_SIZE} byte preview limit"
        )));
    }
    *total_header_size = total_header_size
        .checked_add(header_size)
        .ok_or_else(|| CoreError::limit("RAR header metadata size overflow"))?;
    if *total_header_size > MAX_TOTAL_HEADER_SIZE {
        return Err(CoreError::limit(format!(
            "RAR headers exceed the {MAX_TOTAL_HEADER_SIZE} byte preview limit"
        )));
    }
    *block_count = block_count
        .checked_add(1)
        .ok_or_else(|| CoreError::limit("RAR header count overflow"))?;
    if *block_count > MAX_ENTRY_COUNT {
        return Err(CoreError::limit(format!(
            "RAR metadata exceeds the {MAX_ENTRY_COUNT} header preview limit"
        )));
    }
    Ok(())
}

fn read_vint(bytes: &[u8], start: usize) -> Result<(u64, usize), CoreError> {
    let mut value = 0_u64;
    for index in 0..10 {
        let byte = *bytes
            .get(start + index)
            .ok_or_else(|| CoreError::parse("RAR5 variable integer is truncated"))?;
        if index == 9 && byte & 0xfe != 0 {
            return Err(CoreError::limit("RAR5 variable integer overflows 64 bits"));
        }
        value |= u64::from(byte & 0x7f) << (index * 7);
        if byte & 0x80 == 0 {
            return Ok((value, start + index + 1));
        }
    }
    Err(CoreError::parse("RAR5 variable integer is malformed"))
}

fn read_at<const N: usize>(
    file: &mut File,
    offset: u64,
    description: &str,
) -> Result<[u8; N], CoreError> {
    let mut bytes = [0_u8; N];
    read_exact_at(file, offset, &mut bytes, description)?;
    Ok(bytes)
}

fn read_exact_at(
    file: &mut File,
    offset: u64,
    bytes: &mut [u8],
    description: &str,
) -> Result<(), CoreError> {
    file.seek(SeekFrom::Start(offset))
        .map_err(|error| CoreError::io(format!("Could not seek {description}: {error}")))?;
    file.read_exact(bytes)
        .map_err(|error| CoreError::parse(format!("Could not read {description}: {error}")))
}

fn read_u32(bytes: &[u8], offset: usize) -> Option<u32> {
    bytes
        .get(offset..offset + 4)?
        .try_into()
        .ok()
        .map(u32::from_le_bytes)
}

fn dos_datetime_to_unix(value: u32) -> Option<f64> {
    if value == 0 {
        return None;
    }
    let mut local_time: libc::tm = unsafe { std::mem::zeroed() };
    local_time.tm_sec = i32::try_from((value & 0x1f) * 2).ok()?;
    local_time.tm_min = i32::try_from((value >> 5) & 0x3f).ok()?;
    local_time.tm_hour = i32::try_from((value >> 11) & 0x1f).ok()?;
    local_time.tm_mday = i32::try_from((value >> 16) & 0x1f).ok()?;
    local_time.tm_mon = i32::try_from((value >> 21) & 0x0f).ok()? - 1;
    local_time.tm_year = i32::try_from((value >> 25) & 0x7f).ok()? + 80;
    local_time.tm_isdst = -1;
    let timestamp = unsafe { libc::mktime(&mut local_time) };
    (timestamp != -1).then_some(timestamp as f64)
}

fn map_rar_error(error: RarError) -> CoreError {
    match root_rar_error(&error) {
        RarError::NeedPassword
        | RarError::WrongPasswordOrCorruptData
        | RarError::UnsupportedEncryption { .. } => {
            CoreError::unsupported("Encrypted RAR archives are not supported")
        }
        RarError::Rar50BufferedDecodeLimitExceeded { .. }
        | RarError::MemoryLimitExceeded { .. } => {
            CoreError::limit(format!("RAR archive exceeds a resource limit: {error}"))
        }
        RarError::UnsupportedVersion(_)
        | RarError::UnsupportedFeature { .. }
        | RarError::UnsupportedFamilyFeature { .. }
        | RarError::UnsupportedCompression { .. } => {
            CoreError::unsupported(format!("RAR archive is not supported: {error}"))
        }
        RarError::Io(_) => CoreError::io(format!("Could not read RAR archive: {error}")),
        _ => CoreError::parse(format!("Could not parse RAR archive: {error}")),
    }
}

fn root_rar_error(mut error: &RarError) -> &RarError {
    loop {
        error = match error {
            RarError::AtArchiveOffset { source, .. }
            | RarError::AtEntry { source, .. }
            | RarError::InVolume { source, .. } => source,
            _ => return error,
        };
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn fixture(name: &str) -> std::path::PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../GlanceTests/TestFiles/archives")
            .join(name)
    }

    #[test]
    fn scans_rar4_and_rar5_fixtures() {
        let rar4 = scan_rar(&fixture("example-rar4.rar")).unwrap();
        assert_eq!(rar4.entries[0].path, "payload.txt");
        assert_eq!(rar4.entries[0].entry_type, ArchiveEntryType::File);
        assert_eq!(rar4.entries[0].size, 21);

        let rar5 = scan_rar(&fixture("example-rar5.rar")).unwrap();
        assert_eq!(rar5.entries[0].path, "hello.txt");
        assert_eq!(rar5.entries[0].size, 30);
        assert!(rar5.entries[0].modified_unix_seconds.is_some());
    }

    #[test]
    fn converts_available_rar4_dos_timestamps() {
        let timestamp = (44 << 25) | (9 << 21) | (22 << 16) | (14 << 11) | (37 << 5) | 15;
        assert!(dos_datetime_to_unix(timestamp).is_some());
        assert_eq!(dos_datetime_to_unix(0), None);
    }

    #[test]
    fn emits_typed_entries_and_checked_totals() {
        let mut scanner = ArchiveScanner::default();
        scanner
            .push("folder".into(), true, false, false, false, 0, 0, None)
            .unwrap();
        scanner
            .push(
                "folder/file.txt".into(),
                false,
                false,
                false,
                false,
                7,
                11,
                Some(1_700_000_000.0),
            )
            .unwrap();

        assert_eq!(scanner.entries[0].entry_type, ArchiveEntryType::Directory);
        assert_eq!(scanner.entries[1].entry_type, ArchiveEntryType::File);
        assert_eq!(scanner.compressed_size, 7);
        assert_eq!(scanner.uncompressed_size, 11);
        assert_eq!(
            scanner.entries[1].modified_unix_seconds,
            Some(1_700_000_000.0)
        );
    }

    #[test]
    fn rejects_malformed_encrypted_multipart_and_oversized_archives() {
        let path = temporary_path();
        fs::write(&path, b"not a rar").unwrap();
        assert!(matches!(scan_rar(&path), Err(CoreError::Parse(_))));

        assert!(matches!(
            scan_rar(&fixture("encrypted-rar5.rar")),
            Err(CoreError::Unsupported(_))
        ));
        assert!(matches!(
            scan_rar(&fixture("multipart-rar5.rar")),
            Err(CoreError::Unsupported(_))
        ));

        let file = File::create(&path).unwrap();
        file.set_len(MAX_ARCHIVE_SIZE + 1).unwrap();
        assert!(matches!(scan_rar(&path), Err(CoreError::ResourceLimit(_))));
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn rejects_oversized_header_before_library_parsing() {
        let path = temporary_path();
        let mut bytes = RAR5_SIGNATURE.to_vec();
        bytes.extend_from_slice(&[0; 4]);
        bytes.extend_from_slice(&encode_vint(MAX_HEADER_SIZE + 1));
        fs::write(&path, bytes).unwrap();
        assert!(matches!(scan_rar(&path), Err(CoreError::ResourceLimit(_))));
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn rejects_deep_and_parent_paths() {
        let mut scanner = ArchiveScanner::default();
        let deep = std::iter::repeat_n("folder", MAX_PATH_COMPONENTS + 1)
            .collect::<Vec<_>>()
            .join("/");
        assert!(matches!(
            scanner.push(deep, false, false, false, false, 1, 1, None),
            Err(CoreError::ResourceLimit(_))
        ));
        assert!(matches!(
            normalize_path("safe/../escape.txt"),
            Err(CoreError::Parse(_))
        ));
    }

    fn encode_vint(mut value: u64) -> Vec<u8> {
        let mut bytes = Vec::new();
        loop {
            let mut byte = (value & 0x7f) as u8;
            value >>= 7;
            if value != 0 {
                byte |= 0x80;
            }
            bytes.push(byte);
            if value == 0 {
                return bytes;
            }
        }
    }

    fn temporary_path() -> std::path::PathBuf {
        std::env::temp_dir().join(format!(
            "glance-rar-test-{}-{}.rar",
            std::process::id(),
            std::thread::current().name().unwrap_or("thread")
        ))
    }
}
