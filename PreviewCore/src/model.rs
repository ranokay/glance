use serde::Serialize;
use std::collections::BTreeMap;

#[derive(Debug, PartialEq, Serialize)]
pub(crate) struct TsvPayload {
    pub headers: Vec<String>,
    pub rows: Vec<BTreeMap<String, String>>,
}

#[derive(Debug, PartialEq, Serialize)]
pub(crate) struct ArchivePayload {
    pub entries: Vec<ArchiveEntry>,
    pub compressed_size: u64,
    pub uncompressed_size: u64,
    pub scanned_uncompressed_size: Option<u64>,
    pub truncated: bool,
}

#[derive(Debug, PartialEq, Serialize)]
pub(crate) struct ArchiveEntry {
    pub path: String,
    pub entry_type: ArchiveEntryType,
    pub size: u64,
    pub modified_unix_seconds: Option<f64>,
}

#[derive(Debug, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum ArchiveEntryType {
    File,
    Directory,
    Other,
}
