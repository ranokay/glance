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

#[derive(Debug, PartialEq, Serialize)]
pub(crate) struct ThreeMfPayload {
    pub meshes: Vec<ThreeMfMesh>,
    pub instances: Vec<ThreeMfInstance>,
    pub unit_millimeters: f32,
    pub bounds_min: [f32; 3],
    pub bounds_max: [f32; 3],
    pub triangle_count: usize,
}

#[derive(Debug, PartialEq, Serialize)]
pub(crate) struct ThreeMfMesh {
    pub vertices: Vec<[f32; 3]>,
    pub triangles: Vec<[u32; 3]>,
    pub color: [f32; 4],
}

#[derive(Debug, PartialEq, Serialize)]
pub(crate) struct ThreeMfInstance {
    pub mesh_index: usize,
    /// Row-major transform matching SceneKit's `SCNMatrix4` field order.
    pub transform: [f32; 16],
}
