use crate::error::CoreError;
use crate::model::{ArchiveEntry, ArchiveEntryType, ArchivePayload};
use sevenz_rust2::{
    Archive, ArchiveReader, BlockDecoder, EncoderMethod, Error as SevenZipError, Password,
};
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;
use std::sync::OnceLock;
use std::time::{SystemTime, UNIX_EPOCH};

const SIGNATURE: &[u8; 6] = b"7z\xBC\xAF\x27\x1C";
const SIGNATURE_HEADER_SIZE: u64 = 32;
const MAX_ARCHIVE_SIZE: u64 = 200 * 1_024 * 1_024;
const MAX_HEADER_SIZE: u64 = 8 * 1_024 * 1_024;
const MAX_ENTRY_COUNT: usize = 50_000;
const MAX_SOLID_SCAN_SIZE: u64 = 200 * 1_024 * 1_024;

pub(crate) fn scan_seven_zip(path: &Path) -> Result<ArchivePayload, CoreError> {
    let mut file = File::open(path)
        .map_err(|error| CoreError::io(format!("Could not open 7z archive: {error}")))?;
    let file_size = file
        .metadata()
        .map_err(|error| CoreError::io(format!("Could not inspect 7z archive: {error}")))?
        .len();
    if file_size > MAX_ARCHIVE_SIZE {
        return Err(CoreError::limit(format!(
            "7z archive exceeds the {MAX_ARCHIVE_SIZE} byte preview limit"
        )));
    }
    preflight_header(&mut file, file_size)?;
    file.seek(SeekFrom::Start(0))
        .map_err(|error| CoreError::io(format!("Could not seek 7z archive: {error}")))?;

    let reader = ArchiveReader::new(file, Password::empty()).map_err(map_seven_zip_error)?;
    let archive = reader.archive();
    if archive.files.len() > MAX_ENTRY_COUNT {
        return Err(CoreError::limit(format!(
            "7z archive metadata exceeds the {MAX_ENTRY_COUNT} entry preview limit"
        )));
    }
    if archive.blocks.iter().any(|block| {
        block
            .coders
            .iter()
            .any(|coder| coder.encoder_method_id() == EncoderMethod::ID_AES256_SHA256)
    }) {
        return Err(CoreError::unsupported(
            "Encrypted 7z archives are not supported",
        ));
    }

    let mut entries = Vec::with_capacity(archive.files.len());
    let mut uncompressed_size = 0_u64;
    for entry in &archive.files {
        uncompressed_size = uncompressed_size
            .checked_add(entry.size)
            .ok_or_else(|| CoreError::limit("7z archive metadata size overflow"))?;
        entries.push(ArchiveEntry {
            path: entry.name.clone(),
            entry_type: if entry.is_directory {
                ArchiveEntryType::Directory
            } else if is_seven_zip_symlink(entry) {
                ArchiveEntryType::Other
            } else {
                ArchiveEntryType::File
            },
            size: entry.size,
            modified_unix_seconds: entry
                .has_last_modified_date
                .then(|| system_time_to_unix(entry.last_modified_date.into())),
        });
    }

    Ok(ArchivePayload {
        entries,
        compressed_size: file_size,
        uncompressed_size,
        scanned_uncompressed_size: None,
        truncated: false,
    })
}

fn preflight_header(file: &mut File, file_size: u64) -> Result<(), CoreError> {
    if file_size < SIGNATURE_HEADER_SIZE {
        return Err(CoreError::parse(
            "7z archive is too small to contain a signature header",
        ));
    }
    let mut signature_header = [0_u8; SIGNATURE_HEADER_SIZE as usize];
    file.read_exact(&mut signature_header)
        .map_err(|error| CoreError::io(format!("Could not read 7z signature header: {error}")))?;
    if &signature_header[..6] != SIGNATURE {
        return Err(CoreError::parse("7z archive has an invalid signature"));
    }
    let expected_start_crc = read_u32(&signature_header, 8).unwrap();
    if crc32(&signature_header[12..32]) != expected_start_crc {
        return Err(CoreError::parse(
            "7z signature header checksum does not match",
        ));
    }
    let next_header_offset = read_u64(&signature_header, 12).unwrap();
    let next_header_size = read_u64(&signature_header, 20).unwrap();
    let expected_next_crc = read_u32(&signature_header, 28).unwrap();
    if next_header_size > MAX_HEADER_SIZE {
        return Err(CoreError::limit(format!(
            "7z archive metadata exceeds the {MAX_HEADER_SIZE} byte preview limit"
        )));
    }
    let next_header_start = SIGNATURE_HEADER_SIZE
        .checked_add(next_header_offset)
        .ok_or_else(|| CoreError::limit("7z metadata offset overflow"))?;
    let next_header_end = next_header_start
        .checked_add(next_header_size)
        .ok_or_else(|| CoreError::limit("7z metadata size overflow"))?;
    if next_header_end > file_size {
        return Err(CoreError::parse(
            "7z metadata header lies outside the archive",
        ));
    }
    file.seek(SeekFrom::Start(next_header_start))
        .map_err(|error| CoreError::io(format!("Could not seek 7z metadata header: {error}")))?;
    let mut next_header = vec![0_u8; next_header_size as usize];
    file.read_exact(&mut next_header)
        .map_err(|error| CoreError::io(format!("Could not read 7z metadata header: {error}")))?;
    if crc32(&next_header) != expected_next_crc {
        return Err(CoreError::parse(
            "7z metadata header checksum does not match",
        ));
    }
    Ok(())
}

fn map_seven_zip_error(error: SevenZipError) -> CoreError {
    match error {
        SevenZipError::Io(error, context) => {
            CoreError::io(format!("Could not read 7z archive {context}: {error}"))
        }
        SevenZipError::FileOpen(error, path) => {
            CoreError::io(format!("Could not open 7z archive {path}: {error}"))
        }
        SevenZipError::PasswordRequired | SevenZipError::MaybeBadPassword(_) => {
            CoreError::unsupported("Encrypted 7z archives are not supported")
        }
        SevenZipError::UnsupportedCompressionMethod(method) => {
            CoreError::unsupported(format!("7z compression method {method} is not supported"))
        }
        SevenZipError::Unsupported(message) => CoreError::unsupported(message),
        SevenZipError::ExternalUnsupported => {
            CoreError::unsupported("External 7z compression methods are not supported")
        }
        SevenZipError::MaxMemLimited { max_kb, actaul_kb } => CoreError::limit(format!(
            "7z decoder requires {actaul_kb} KiB, above its {max_kb} KiB limit"
        )),
        other => CoreError::parse(format!("Could not parse 7z archive: {other}")),
    }
}

fn is_seven_zip_symlink(entry: &sevenz_rust2::ArchiveEntry) -> bool {
    const FILE_ATTRIBUTE_UNIX_EXTENSION: u32 = 0x8000;
    entry.has_windows_attributes
        && entry.windows_attributes & FILE_ATTRIBUTE_UNIX_EXTENSION != 0
        && crate::extract::is_unix_symlink(entry.windows_attributes >> 16)
}

fn system_time_to_unix(time: SystemTime) -> f64 {
    match time.duration_since(UNIX_EPOCH) {
        Ok(duration) => duration.as_secs_f64(),
        Err(error) => -error.duration().as_secs_f64(),
    }
}

fn crc32(bytes: &[u8]) -> u32 {
    static TABLE: OnceLock<[u32; 256]> = OnceLock::new();
    let table = TABLE.get_or_init(|| {
        let mut table = [0_u32; 256];
        for (index, value) in table.iter_mut().enumerate() {
            let mut crc = index as u32;
            for _ in 0..8 {
                crc = if crc & 1 == 1 {
                    0xedb8_8320 ^ (crc >> 1)
                } else {
                    crc >> 1
                };
            }
            *value = crc;
        }
        table
    });
    let mut crc = u32::MAX;
    for byte in bytes {
        crc = table[((crc ^ u32::from(*byte)) & 0xff) as usize] ^ (crc >> 8);
    }
    !crc
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

pub(crate) fn extract_entry(
    path: &Path,
    entry_name: &str,
    max_bytes: usize,
) -> Result<Vec<u8>, CoreError> {
    extract_entry_with_scan_limit(path, entry_name, max_bytes, MAX_SOLID_SCAN_SIZE)
}

fn extract_entry_with_scan_limit(
    path: &Path,
    entry_name: &str,
    max_bytes: usize,
    max_scan_bytes: u64,
) -> Result<Vec<u8>, CoreError> {
    let mut file = File::open(path)
        .map_err(|error| CoreError::io(format!("Could not open 7z archive: {error}")))?;
    let file_size = file
        .metadata()
        .map_err(|error| CoreError::io(format!("Could not inspect 7z archive: {error}")))?
        .len();
    if file_size > MAX_ARCHIVE_SIZE {
        return Err(CoreError::limit(format!(
            "7z archive exceeds the {MAX_ARCHIVE_SIZE} byte preview limit"
        )));
    }
    preflight_header(&mut file, file_size)?;
    file.seek(SeekFrom::Start(0))
        .map_err(|error| CoreError::io(format!("Could not seek 7z archive: {error}")))?;
    let password = Password::empty();
    let archive = Archive::read(&mut file, &password).map_err(map_seven_zip_error)?;
    let entry_index = archive
        .files
        .iter()
        .position(|entry| entry.name == entry_name)
        .ok_or_else(|| CoreError::invalid(format!("7z entry \"{entry_name}\" was not found")))?;
    let target_entry = &archive.files[entry_index];
    if target_entry.is_directory {
        return Err(CoreError::invalid(
            "7z directory entries cannot be previewed",
        ));
    }
    if is_seven_zip_symlink(target_entry) {
        return Err(CoreError::invalid("7z links cannot be previewed"));
    }
    if target_entry.size > max_bytes as u64 {
        return Err(CoreError::limit(
            "7z entry exceeds the extracted preview size limit",
        ));
    }
    if !target_entry.has_stream {
        return Ok(Vec::new());
    }
    let block_index = archive.stream_map.file_block_index[entry_index]
        .ok_or_else(|| CoreError::parse("7z file has no compression block"))?;
    let decoder = BlockDecoder::new(1, block_index, &archive, &password, &mut file);
    let mut scan_bytes = 0_u64;
    for entry in decoder
        .entries()
        .iter()
        .take_while(|entry| !std::ptr::eq(*entry, target_entry))
    {
        scan_bytes = scan_bytes
            .checked_add(entry.size)
            .ok_or_else(|| CoreError::limit("7z solid block scan size overflow"))?;
        if scan_bytes > max_scan_bytes {
            return Err(CoreError::limit(format!(
                "7z solid entry requires scanning more than {max_scan_bytes} bytes"
            )));
        }
    }
    let mut selected: Option<Result<Vec<u8>, CoreError>> = None;

    decoder
        .for_each_entries(&mut |entry, reader| {
            if !std::ptr::eq(entry, target_entry) {
                // Solid files share one decoder; discarding a reader without consuming it
                // leaves the next entry positioned at the previous file's bytes.
                std::io::copy(reader, &mut std::io::sink())?;
                return Ok(true);
            }
            let mut data = Vec::with_capacity(entry.size as usize);
            selected = Some(
                reader
                    .take(max_bytes as u64 + 1)
                    .read_to_end(&mut data)
                    .map_err(|error| CoreError::io(format!("Could not read 7z entry: {error}")))
                    .and_then(|_| {
                        if data.len() > max_bytes {
                            Err(CoreError::limit(
                                "7z entry exceeds the extracted preview size limit",
                            ))
                        } else {
                            Ok(data)
                        }
                    }),
            );
            Ok(false)
        })
        .map_err(map_seven_zip_error)?;

    selected.unwrap_or_else(|| {
        Err(CoreError::invalid(format!(
            "7z entry \"{entry_name}\" was not found"
        )))
    })
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
    fn scans_valid_encoded_header_fixture() {
        let path = fixture("example.7z");
        let bytes = fs::read(&path).unwrap();
        let next_header_offset = read_u64(&bytes, 12).unwrap() as usize + 32;
        assert_eq!(bytes[next_header_offset], 0x17);

        let payload = scan_seven_zip(&path).unwrap();
        assert_eq!(payload.entries.len(), 3);
        assert!(
            payload
                .entries
                .iter()
                .any(|entry| entry.path == "hello.txt")
        );
        assert!(
            payload
                .entries
                .iter()
                .any(|entry| entry.path.contains("unicode-ș.txt"))
        );
    }

    #[test]
    fn recognizes_unix_symlink_attributes() {
        let mut entry = sevenz_rust2::ArchiveEntry::new_file("link");
        entry.has_windows_attributes = true;
        entry.windows_attributes = 0x8000 | (0o120777 << 16);
        assert!(is_seven_zip_symlink(&entry));

        entry.windows_attributes = 0x8000 | (0o100644 << 16);
        assert!(!is_seven_zip_symlink(&entry));
    }

    #[test]
    fn extracts_later_file_from_solid_archive() {
        let path = temporary_path();
        fs::write(&path, solid_copy_archive()).unwrap();
        let reference = ArchiveReader::open(&path, Password::empty()).unwrap();
        assert!(reference.archive().is_solid);
        let result = extract_entry(&path, "second.txt", 1_024);
        fs::remove_file(path).unwrap();

        assert_eq!(result.unwrap(), b"second payload\n");
    }

    #[test]
    fn extracts_each_file_from_a_non_solid_archive() {
        let path = fixture("example.7z");
        let mut reference = ArchiveReader::open(&path, Password::empty()).unwrap();
        assert!(!reference.archive().is_solid);
        let names: Vec<String> = reference
            .archive()
            .files
            .iter()
            .filter(|entry| !entry.is_directory)
            .map(|entry| entry.name.clone())
            .collect();

        for name in names {
            assert_eq!(
                extract_entry(&path, &name, 1_024).unwrap(),
                reference.read_file(&name).unwrap(),
                "entry {name} was read from the wrong compression block"
            );
        }
    }

    #[test]
    fn limits_the_preceding_data_decoded_for_a_solid_entry() {
        let path = temporary_path();
        fs::write(&path, solid_copy_archive()).unwrap();
        let over_budget = extract_entry_with_scan_limit(&path, "second.txt", 1_024, 5);
        let within_budget = extract_entry_with_scan_limit(&path, "second.txt", 1_024, 6);
        fs::remove_file(path).unwrap();

        assert!(matches!(over_budget, Err(CoreError::ResourceLimit(_))));
        assert_eq!(within_budget.unwrap(), b"second payload\n");
    }

    fn solid_copy_archive() -> Vec<u8> {
        let first = b"first\n";
        let second = b"second payload\n";
        let content_size = (first.len() + second.len()) as u8;
        let mut header = vec![
            0x01, // Header
            0x04, // MainStreamsInfo
            0x06,
            0,
            1,
            0x09,
            content_size,
            0, // PackInfo: one stream at offset zero
            0x07,
            0x0b,
            1,
            0,
            1,
            1,
            0, // UnpackInfo: one block using the COPY coder
            0x0c,
            content_size,
            0, // CodersUnpackSize
            0x08,
            0x0d,
            2,
            0x09,
            first.len() as u8,
            0, // Two solid substreams
            0, // End MainStreamsInfo
            0x05,
            2, // FilesInfo
        ];
        let names: Vec<u8> = "first.txt\0second.txt\0"
            .encode_utf16()
            .flat_map(u16::to_le_bytes)
            .collect();
        header.extend([0x11, (names.len() + 1) as u8, 0]);
        header.extend(names);
        header.extend([0, 0]);

        let mut start_header = Vec::new();
        start_header.extend(u64::from(content_size).to_le_bytes());
        start_header.extend((header.len() as u64).to_le_bytes());
        start_header.extend(crc32(&header).to_le_bytes());
        let mut bytes = SIGNATURE.to_vec();
        bytes.extend([0, 4]);
        bytes.extend(crc32(&start_header).to_le_bytes());
        bytes.extend(start_header);
        bytes.extend(first);
        bytes.extend(second);
        bytes.extend(header);
        bytes
    }

    #[test]
    fn rejects_encrypted_archives() {
        assert!(matches!(
            scan_seven_zip(&fixture("encrypted.7z")),
            Err(CoreError::Unsupported(_))
        ));
    }

    #[test]
    fn rejects_malformed_and_oversized_archives() {
        let path = temporary_path();
        fs::write(&path, b"not a seven zip").unwrap();
        assert!(matches!(scan_seven_zip(&path), Err(CoreError::Parse(_))));

        let file = File::create(&path).unwrap();
        file.set_len(MAX_ARCHIVE_SIZE + 1).unwrap();
        assert!(matches!(
            scan_seven_zip(&path),
            Err(CoreError::ResourceLimit(_))
        ));
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn crc_matches_standard_vector() {
        assert_eq!(crc32(b"123456789"), 0xcbf4_3926);
    }

    fn temporary_path() -> std::path::PathBuf {
        std::env::temp_dir().join(format!(
            "glance-sevenzip-test-{}-{}.7z",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ))
    }
}
