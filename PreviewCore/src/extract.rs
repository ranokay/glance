use crate::error::CoreError;
use std::path::Path;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ArchiveFormat {
    Zip,
    Tar,
    TarGz,
    SevenZip,
    Rar,
}

impl ArchiveFormat {
    pub(crate) fn from_ffi(value: u8) -> Result<Self, CoreError> {
        match value {
            0 => Ok(Self::Zip),
            1 => Ok(Self::Tar),
            2 => Ok(Self::TarGz),
            3 => Ok(Self::SevenZip),
            4 => Ok(Self::Rar),
            _ => Err(CoreError::invalid("Unknown archive entry format")),
        }
    }
}

pub(crate) fn extract_archive_entry(
    path: &Path,
    entry: &str,
    format: ArchiveFormat,
    max_bytes: usize,
) -> Result<Vec<u8>, CoreError> {
    match format {
        ArchiveFormat::Zip => crate::zip::extract_entry(path, entry, max_bytes),
        ArchiveFormat::Tar => crate::tar::extract_entry(path, entry, false, max_bytes),
        ArchiveFormat::TarGz => crate::tar::extract_entry(path, entry, true, max_bytes),
        ArchiveFormat::SevenZip => crate::sevenzip::extract_entry(path, entry, max_bytes),
        ArchiveFormat::Rar => crate::rar::extract_entry(path, entry, max_bytes),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn fixture(name: &str) -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../GlanceTests/TestFiles/archives")
            .join(name)
    }

    #[test]
    fn extracts_entries_from_every_supported_archive_format() {
        let cases = [
            (
                "example-root-directory.zip",
                ArchiveFormat::Zip,
                "example/hello-world.txt",
                "Hello world!\n",
            ),
            (
                "example-root-directory.tar",
                ArchiveFormat::Tar,
                "example/hello-world.txt",
                "Hello world!\n",
            ),
            (
                "example.tar.gz",
                ArchiveFormat::TarGz,
                "example/hello-world.txt",
                "Hello world!\n",
            ),
            (
                "example.7z",
                ArchiveFormat::SevenZip,
                "hello.txt",
                "Hello from Glance\n",
            ),
            (
                "example-rar5.rar",
                ArchiveFormat::Rar,
                "hello.txt",
                "Hello, RAR 5.0 fixture world.\n",
            ),
        ];

        for (name, format, entry, expected) in cases {
            let bytes = extract_archive_entry(&fixture(name), entry, format, 1_024).unwrap();
            assert_eq!(String::from_utf8(bytes).unwrap(), expected, "{name}");
        }
    }

    #[test]
    fn rejects_missing_directories_and_oversized_entries() {
        assert!(
            extract_archive_entry(
                &fixture("example-root-directory.zip"),
                "missing.txt",
                ArchiveFormat::Zip,
                1_024,
            )
            .is_err()
        );
        assert!(
            extract_archive_entry(
                &fixture("example-root-directory.zip"),
                "example/",
                ArchiveFormat::Zip,
                1_024,
            )
            .is_err()
        );
        assert!(
            extract_archive_entry(
                &fixture("example-root-directory.zip"),
                "example/hello-world.txt",
                ArchiveFormat::Zip,
                4,
            )
            .is_err()
        );
    }

    #[test]
    fn rejects_encrypted_archives() {
        assert!(
            extract_archive_entry(
                &fixture("encrypted.7z"),
                "hello.txt",
                ArchiveFormat::SevenZip,
                1_024,
            )
            .is_err()
        );
        assert!(
            extract_archive_entry(
                &fixture("encrypted-rar5.rar"),
                "hello.txt",
                ArchiveFormat::Rar,
                1_024,
            )
            .is_err()
        );
    }
}
