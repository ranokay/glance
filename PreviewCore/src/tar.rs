use crate::error::CoreError;
use crate::model::{ArchiveEntry, ArchiveEntryType, ArchivePayload};
use flate2::read::MultiGzDecoder;
use std::collections::BTreeMap;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

const BLOCK_SIZE: usize = 512;
const MAX_ENTRY_COUNT: usize = 50_000;
const MAX_METADATA_ENTRY_SIZE: u64 = 1_048_576;
const MAX_GZIP_SCAN_SIZE: u64 = 200 * 1_024 * 1_024;

pub(crate) fn scan_tar(path: &Path, is_gzipped: bool) -> Result<ArchivePayload, CoreError> {
    let file = File::open(path)
        .map_err(|error| CoreError::io(format!("Could not open TAR archive: {error}")))?;
    let compressed_size = file
        .metadata()
        .map_err(|error| CoreError::io(format!("Could not inspect TAR archive: {error}")))?
        .len();
    let reader: Box<dyn TarReader> = if is_gzipped {
        Box::new(GzipTarReader {
            decoder: MultiGzDecoder::new(file),
        })
    } else {
        Box::new(FileTarReader {
            file,
            file_size: compressed_size,
        })
    };
    let mut scanner = TarScanner::new(reader, is_gzipped);
    let scan = scanner.scan()?;
    Ok(ArchivePayload {
        entries: scan.entries,
        compressed_size,
        uncompressed_size: scan.uncompressed_size,
        scanned_uncompressed_size: Some(scan.scanned_size),
        truncated: scan.truncated,
    })
}

trait TarReader {
    fn read(&mut self, buffer: &mut [u8]) -> Result<usize, CoreError>;
    fn skip(&mut self, count: u64) -> Result<(), CoreError>;
}

struct FileTarReader {
    file: File,
    file_size: u64,
}

impl TarReader for FileTarReader {
    fn read(&mut self, buffer: &mut [u8]) -> Result<usize, CoreError> {
        self.file
            .read(buffer)
            .map_err(|error| CoreError::io(format!("Could not read TAR archive: {error}")))
    }

    fn skip(&mut self, count: u64) -> Result<(), CoreError> {
        let current = self
            .file
            .stream_position()
            .map_err(|error| CoreError::io(format!("Could not inspect TAR offset: {error}")))?;
        let target = current
            .checked_add(count)
            .filter(|target| *target <= self.file_size)
            .ok_or_else(|| CoreError::parse("TAR archive is truncated"))?;
        self.file
            .seek(SeekFrom::Start(target))
            .map_err(|error| CoreError::io(format!("Could not seek TAR archive: {error}")))?;
        Ok(())
    }
}

struct GzipTarReader {
    decoder: MultiGzDecoder<File>,
}

impl TarReader for GzipTarReader {
    fn read(&mut self, buffer: &mut [u8]) -> Result<usize, CoreError> {
        self.decoder.read(buffer).map_err(|error| {
            CoreError::parse(format!("Could not read gzipped TAR archive: {error}"))
        })
    }

    fn skip(&mut self, mut count: u64) -> Result<(), CoreError> {
        let mut discard = [0_u8; 64 * 1_024];
        while count > 0 {
            let requested = usize::try_from(count.min(discard.len() as u64)).unwrap();
            let read = self.read(&mut discard[..requested])?;
            if read == 0 {
                return Err(CoreError::parse("TAR archive is truncated"));
            }
            count -= read as u64;
        }
        Ok(())
    }
}

struct TarScan {
    entries: Vec<ArchiveEntry>,
    uncompressed_size: u64,
    scanned_size: u64,
    truncated: bool,
}

struct TarScanner {
    reader: Box<dyn TarReader>,
    should_limit_payload_skips: bool,
    entries: Vec<ArchiveEntry>,
    uncompressed_size: u64,
    scanned_size: u64,
    entry_count: usize,
    truncated: bool,
    pending_long_name: Option<String>,
    pending_local_pax: PaxHeaders,
    global_pax: PaxHeaders,
}

impl TarScanner {
    fn new(reader: Box<dyn TarReader>, should_limit_payload_skips: bool) -> Self {
        Self {
            reader,
            should_limit_payload_skips,
            entries: Vec::new(),
            uncompressed_size: 0,
            scanned_size: 0,
            entry_count: 0,
            truncated: false,
            pending_long_name: None,
            pending_local_pax: PaxHeaders::default(),
            global_pax: PaxHeaders::default(),
        }
    }

    fn scan(&mut self) -> Result<TarScan, CoreError> {
        while let Some(block) = self.read_block(true)? {
            self.add_scanned_bytes(BLOCK_SIZE as u64)?;
            if block.iter().all(|byte| *byte == 0) {
                if self.read_block(true)?.is_some() {
                    self.add_scanned_bytes(BLOCK_SIZE as u64)?;
                }
                break;
            }

            let header = TarHeader::parse(&block)?;
            let payload_size = if header.entry_type.uses_pax_size_override() {
                self.pending_local_pax
                    .size
                    .or(self.global_pax.size)
                    .unwrap_or(header.size)
            } else {
                header.size
            };
            let padded_size = padded_tar_size(payload_size)?;

            match header.entry_type {
                TarEntryType::GlobalPax => {
                    if self.should_stop_before_skipping(padded_size) {
                        break;
                    }
                    if let Some(payload) = self.read_metadata(payload_size, padded_size)? {
                        self.global_pax = PaxHeaders::parse(&payload);
                    }
                }
                TarEntryType::LocalPax => {
                    if self.should_stop_before_skipping(padded_size) {
                        break;
                    }
                    if let Some(payload) = self.read_metadata(payload_size, padded_size)? {
                        self.pending_local_pax = PaxHeaders::parse(&payload);
                    }
                }
                TarEntryType::LongName => {
                    if self.should_stop_before_skipping(padded_size) {
                        break;
                    }
                    self.pending_long_name = self
                        .read_metadata(payload_size, padded_size)?
                        .map(|payload| metadata_string(&payload));
                }
                TarEntryType::LongLink => {
                    if self.should_stop_before_skipping(padded_size) {
                        break;
                    }
                    self.reader.skip(padded_size)?;
                    self.add_scanned_bytes(padded_size)?;
                }
                TarEntryType::File | TarEntryType::Directory | TarEntryType::Other => {
                    self.add_entry(&header, payload_size)?;
                    if self.truncated || self.should_stop_before_skipping(padded_size) {
                        break;
                    }
                    self.reader.skip(padded_size)?;
                    self.add_scanned_bytes(padded_size)?;
                    self.pending_long_name = None;
                    self.pending_local_pax = PaxHeaders::default();
                }
            }
        }

        Ok(TarScan {
            entries: std::mem::take(&mut self.entries),
            uncompressed_size: self.uncompressed_size,
            scanned_size: self.scanned_size,
            truncated: self.truncated,
        })
    }

    fn add_entry(&mut self, header: &TarHeader, payload_size: u64) -> Result<(), CoreError> {
        if self.entry_count >= MAX_ENTRY_COUNT {
            self.truncated = true;
            return Ok(());
        }
        self.entry_count += 1;
        let path = self
            .pending_local_pax
            .path
            .as_ref()
            .or(self.pending_long_name.as_ref())
            .or(self.global_pax.path.as_ref())
            .unwrap_or(&header.path)
            .clone();
        if path.is_empty() {
            return Ok(());
        }
        let is_directory = header.entry_type == TarEntryType::Directory || path.ends_with('/');
        let size = if is_directory { 0 } else { payload_size };
        self.uncompressed_size = self
            .uncompressed_size
            .checked_add(size)
            .ok_or_else(|| CoreError::limit("TAR archive metadata size overflow"))?;
        self.entries.push(ArchiveEntry {
            path,
            entry_type: if is_directory {
                ArchiveEntryType::Directory
            } else if header.entry_type == TarEntryType::File {
                ArchiveEntryType::File
            } else {
                ArchiveEntryType::Other
            },
            size,
            modified_unix_seconds: self
                .pending_local_pax
                .modification_time
                .or(self.global_pax.modification_time)
                .or(header.modification_time),
        });
        Ok(())
    }

    fn read_metadata(&mut self, size: u64, padded_size: u64) -> Result<Option<Vec<u8>>, CoreError> {
        if size > MAX_METADATA_ENTRY_SIZE {
            self.reader.skip(padded_size)?;
            self.add_scanned_bytes(padded_size)?;
            return Ok(None);
        }
        let size = usize::try_from(size)
            .map_err(|_| CoreError::limit("TAR metadata entry is too large"))?;
        let payload = self.read_exact(size, false)?.unwrap();
        self.reader.skip(padded_size - size as u64)?;
        self.add_scanned_bytes(padded_size)?;
        Ok(Some(payload))
    }

    fn read_block(
        &mut self,
        allow_empty_at_eof: bool,
    ) -> Result<Option<[u8; BLOCK_SIZE]>, CoreError> {
        let Some(bytes) = self.read_exact(BLOCK_SIZE, allow_empty_at_eof)? else {
            return Ok(None);
        };
        Ok(Some(bytes.try_into().unwrap()))
    }

    fn read_exact(
        &mut self,
        count: usize,
        allow_empty_at_eof: bool,
    ) -> Result<Option<Vec<u8>>, CoreError> {
        let mut result = vec![0_u8; count];
        let mut offset = 0;
        while offset < count {
            let read = self.reader.read(&mut result[offset..])?;
            if read == 0 {
                if allow_empty_at_eof && offset == 0 {
                    return Ok(None);
                }
                return Err(CoreError::parse("TAR archive is truncated"));
            }
            offset += read;
        }
        Ok(Some(result))
    }

    fn should_stop_before_skipping(&mut self, padded_size: u64) -> bool {
        if !self.should_limit_payload_skips {
            return false;
        }
        let fits = self
            .scanned_size
            .checked_add(padded_size)
            .is_some_and(|size| size <= MAX_GZIP_SCAN_SIZE);
        if !fits {
            self.truncated = true;
        }
        !fits
    }

    fn add_scanned_bytes(&mut self, count: u64) -> Result<(), CoreError> {
        self.scanned_size = self
            .scanned_size
            .checked_add(count)
            .ok_or_else(|| CoreError::limit("TAR scan size overflow"))?;
        Ok(())
    }
}

struct TarHeader {
    path: String,
    size: u64,
    modification_time: Option<f64>,
    entry_type: TarEntryType,
}

impl TarHeader {
    fn parse(block: &[u8; BLOCK_SIZE]) -> Result<Self, CoreError> {
        let stored_checksum = tar_integer(&block[148..156])?;
        let computed_checksum = block
            .iter()
            .enumerate()
            .fold(0_u64, |total, (index, byte)| {
                total
                    + u64::from(if (148..156).contains(&index) {
                        b' '
                    } else {
                        *byte
                    })
            });
        if stored_checksum != computed_checksum {
            return Err(CoreError::parse(
                "TAR archive has an invalid header checksum",
            ));
        }
        let name = tar_string(&block[0..100]);
        let prefix = tar_string(&block[345..500]);
        let path = if prefix.is_empty() {
            name
        } else {
            format!("{prefix}/{name}")
        };
        let size = tar_integer(&block[124..136])?;
        let modification_time = match tar_integer(&block[136..148])? {
            0 => None,
            value => Some(value as f64),
        };
        Ok(Self {
            path,
            size,
            modification_time,
            entry_type: TarEntryType::from(block[156]),
        })
    }
}

#[derive(Clone, Copy, PartialEq)]
enum TarEntryType {
    File,
    Directory,
    GlobalPax,
    LocalPax,
    LongName,
    LongLink,
    Other,
}

impl From<u8> for TarEntryType {
    fn from(value: u8) -> Self {
        match value {
            0 | b'0' => Self::File,
            b'5' => Self::Directory,
            b'g' => Self::GlobalPax,
            b'x' => Self::LocalPax,
            b'L' => Self::LongName,
            b'K' => Self::LongLink,
            _ => Self::Other,
        }
    }
}

impl TarEntryType {
    fn uses_pax_size_override(self) -> bool {
        matches!(self, Self::File | Self::Directory | Self::Other)
    }
}

#[derive(Default)]
struct PaxHeaders {
    path: Option<String>,
    size: Option<u64>,
    modification_time: Option<f64>,
}

impl PaxHeaders {
    fn parse(data: &[u8]) -> Self {
        let mut values = BTreeMap::new();
        let mut offset = 0;
        while offset < data.len() {
            let Some(relative_space) = data[offset..].iter().position(|byte| *byte == b' ') else {
                break;
            };
            let space = offset + relative_space;
            let Ok(length_text) = std::str::from_utf8(&data[offset..space]) else {
                break;
            };
            let Ok(length) = length_text.parse::<usize>() else {
                break;
            };
            let Some(end) = offset.checked_add(length) else {
                break;
            };
            if length == 0 || end > data.len() || space + 1 >= end {
                break;
            }
            let record = &data[space + 1..end - 1];
            if let Some(equals) = record.iter().position(|byte| *byte == b'=') {
                values.insert(
                    String::from_utf8_lossy(&record[..equals]).into_owned(),
                    String::from_utf8_lossy(&record[equals + 1..]).into_owned(),
                );
            }
            offset = end;
        }
        Self {
            path: values.remove("path"),
            size: values.remove("size").and_then(|value| value.parse().ok()),
            modification_time: values.remove("mtime").and_then(|value| value.parse().ok()),
        }
    }
}

fn tar_string(bytes: &[u8]) -> String {
    let end = bytes
        .iter()
        .position(|byte| *byte == 0)
        .unwrap_or(bytes.len());
    String::from_utf8_lossy(&bytes[..end]).into_owned()
}

fn metadata_string(bytes: &[u8]) -> String {
    let end = bytes
        .iter()
        .position(|byte| *byte == 0)
        .unwrap_or(bytes.len());
    String::from_utf8_lossy(&bytes[..end]).into_owned()
}

fn tar_integer(bytes: &[u8]) -> Result<u64, CoreError> {
    if bytes.first().is_some_and(|byte| byte & 0x80 != 0) {
        let mut value = 0_u64;
        for (index, byte) in bytes.iter().enumerate() {
            let byte = if index == 0 { byte & 0x7f } else { *byte };
            value = value
                .checked_mul(256)
                .and_then(|value| value.checked_add(u64::from(byte)))
                .ok_or_else(|| CoreError::limit("TAR numeric metadata overflow"))?;
        }
        return Ok(value);
    }
    let text = bytes
        .iter()
        .copied()
        .filter(|byte| *byte != 0 && *byte != b' ')
        .collect::<Vec<_>>();
    if text.is_empty() {
        return Ok(0);
    }
    let text = std::str::from_utf8(&text)
        .map_err(|_| CoreError::parse("TAR archive contains invalid numeric metadata"))?;
    u64::from_str_radix(text, 8)
        .map_err(|_| CoreError::parse("TAR archive contains invalid numeric metadata"))
}

fn padded_tar_size(size: u64) -> Result<u64, CoreError> {
    size.checked_add(511)
        .map(|value| value / 512 * 512)
        .ok_or_else(|| CoreError::limit("TAR payload size overflow"))
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
    fn scans_real_tar_and_multi_gzip_stream() {
        let tar = scan_tar(&fixture("example-root-directory.tar"), false).unwrap();
        assert!(!tar.entries.is_empty());
        assert!(!tar.truncated);
        let tgz = scan_tar(&fixture("example.tar.gz"), true).unwrap();
        assert!(!tgz.entries.is_empty());
        assert!(!tgz.truncated);
        assert!(tgz.scanned_uncompressed_size.unwrap() > 0);
    }

    #[test]
    fn rejects_bad_checksum_and_truncated_gzip() {
        let path = temporary_path("tar");
        fs::write(&path, [1_u8; BLOCK_SIZE]).unwrap();
        assert!(matches!(scan_tar(&path, false), Err(CoreError::Parse(_))));

        let gzip = fs::read(fixture("example.tar.gz")).unwrap();
        fs::write(&path, &gzip[..gzip.len() / 2]).unwrap();
        assert!(matches!(scan_tar(&path, true), Err(CoreError::Parse(_))));
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn parses_base_256_numbers_and_rejects_overflow() {
        let mut bytes = [0_u8; 12];
        bytes[0] = 0x80;
        bytes[11] = 42;
        assert_eq!(tar_integer(&bytes).unwrap(), 42);
        assert!(padded_tar_size(u64::MAX).is_err());
    }

    #[test]
    fn applies_pax_and_gnu_long_names_and_skips_sparse_payloads() {
        let path = temporary_path("tar");
        let pax_path = "pax/路径/fixture.txt";
        let pax = pax_record("path", pax_path);
        let long_path = format!("gnu/{}/fixture.txt", "long-segment".repeat(10));
        let mut archive = Vec::new();
        append_entry(&mut archive, "pax-header", b'x', &pax);
        append_entry(&mut archive, "placeholder", b'0', b"");
        append_entry(&mut archive, "gnu-long-name", b'L', long_path.as_bytes());
        append_entry(&mut archive, "placeholder", b'0', b"");
        append_entry(&mut archive, "sparse.bin", b'S', &[7_u8; 1_024]);
        archive.extend_from_slice(&[0_u8; BLOCK_SIZE * 2]);
        fs::write(&path, archive).unwrap();

        let payload = scan_tar(&path, false).unwrap();
        assert!(payload.entries.iter().any(|entry| entry.path == pax_path));
        assert!(payload.entries.iter().any(|entry| entry.path == long_path));
        let sparse = payload
            .entries
            .iter()
            .find(|entry| entry.path == "sparse.bin")
            .unwrap();
        assert_eq!(sparse.entry_type, ArchiveEntryType::Other);
        assert_eq!(sparse.size, 1_024);
        fs::remove_file(path).unwrap();
    }

    fn append_entry(archive: &mut Vec<u8>, name: &str, entry_type: u8, payload: &[u8]) {
        archive.extend_from_slice(&tar_header(name, payload.len() as u64, entry_type));
        archive.extend_from_slice(payload);
        let padding = (BLOCK_SIZE - payload.len() % BLOCK_SIZE) % BLOCK_SIZE;
        archive.extend(std::iter::repeat_n(0, padding));
    }

    fn tar_header(name: &str, size: u64, entry_type: u8) -> [u8; BLOCK_SIZE] {
        let mut header = [0_u8; BLOCK_SIZE];
        let name_bytes = name.as_bytes();
        header[..name_bytes.len().min(100)]
            .copy_from_slice(&name_bytes[..name_bytes.len().min(100)]);
        let size = format!("{size:011o}\0");
        header[124..136].copy_from_slice(size.as_bytes());
        header[156] = entry_type;
        header[148..156].fill(b' ');
        let checksum = header.iter().map(|byte| u64::from(*byte)).sum::<u64>();
        let checksum = format!("{checksum:06o}\0 ");
        header[148..156].copy_from_slice(checksum.as_bytes());
        header
    }

    fn pax_record(key: &str, value: &str) -> Vec<u8> {
        let body = format!(" {key}={value}\n");
        let mut length = body.len() + 1;
        loop {
            let record = format!("{length}{body}");
            if record.len() == length {
                return record.into_bytes();
            }
            length = record.len();
        }
    }

    fn temporary_path(extension: &str) -> std::path::PathBuf {
        std::env::temp_dir().join(format!(
            "glance-tar-test-{}-{}.{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos(),
            extension
        ))
    }
}
