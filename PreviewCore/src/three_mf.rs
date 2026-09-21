use crate::error::CoreError;
use crate::model::{ThreeMfInstance, ThreeMfMesh, ThreeMfPayload};
use quick_xml::events::{BytesStart, Event};
use quick_xml::{Reader, XmlVersion};
use std::collections::{HashMap, HashSet, VecDeque};
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

const MODEL_RELATIONSHIP_TYPE: &str =
    "http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel";
const DEFAULT_MODEL_PATH: &str = "3D/3dmodel.model";
const RELATIONSHIPS_PATH: &str = "_rels/.rels";

pub(crate) const MAX_FILE_SIZE: u64 = 200_000_000;
const MAX_ENTRY_COUNT: usize = 4_096;
const MAX_PART_COUNT: usize = 64;
const MAX_PART_SIZE: u64 = 256_000_000;
const MAX_TOTAL_PART_SIZE: u64 = 512_000_000;
const MAX_RELATIONSHIPS_SIZE: u64 = 1_000_000;
const MAX_VERTICES: usize = 1_500_000;
const MAX_TRIANGLES: usize = 1_000_000;
const MAX_NODES: usize = 100_000;
const MAX_OBJECT_DEPTH: usize = 128;
const MAX_ELEMENT_DEPTH: usize = 64;
const MAX_COORDINATE: f32 = 1.0e12;
const DEFAULT_COLOR: [f32; 4] = [0.65, 0.68, 0.73, 1.0];

type Matrix = [f32; 16];
const IDENTITY: Matrix = [
    1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0,
];

#[derive(Default)]
struct ParsedModel {
    objects: HashMap<String, Object>,
    build_items: Vec<Component>,
    colors: HashMap<String, Vec<[f32; 4]>>,
    unit_millimeters: f32,
    vertex_count: usize,
    triangle_count: usize,
}

#[derive(Default)]
struct Object {
    mesh: Option<Mesh>,
    components: Vec<Component>,
    property_group: Option<String>,
    property_index: Option<usize>,
}

#[derive(Default)]
struct Mesh {
    vertices: Vec<[f32; 3]>,
    triangles: Vec<[u32; 3]>,
}

struct Component {
    object_key: String,
    transform: Matrix,
}

struct EntryIndex {
    index: usize,
    size: u64,
}

pub(crate) fn parse_three_mf(path: &Path) -> Result<ThreeMfPayload, CoreError> {
    let mut file = File::open(path)
        .map_err(|error| CoreError::io(format!("Could not open 3MF archive: {error}")))?;
    let file_size = file
        .metadata()
        .map_err(|error| CoreError::io(format!("Could not inspect 3MF archive: {error}")))?
        .len();
    if file_size > MAX_FILE_SIZE {
        return Err(CoreError::limit(format!(
            "3MF archive exceeds the {MAX_FILE_SIZE} byte preview limit"
        )));
    }
    crate::zip::preflight_central_directory(&mut file, file_size)?;
    file.seek(SeekFrom::Start(0))
        .map_err(|error| CoreError::io(format!("Could not seek 3MF archive: {error}")))?;
    let mut archive = zip::ZipArchive::new(file).map_err(crate::zip::map_zip_error)?;
    if archive.len() > MAX_ENTRY_COUNT {
        return Err(CoreError::limit(format!(
            "3MF archive contains more than {MAX_ENTRY_COUNT} entries"
        )));
    }

    let mut entries = HashMap::with_capacity(archive.len());
    for index in 0..archive.len() {
        let entry = archive
            .by_index_raw(index)
            .map_err(crate::zip::map_zip_error)?;
        if entry.encrypted() {
            return Err(CoreError::unsupported(
                "Encrypted 3MF archives are not supported",
            ));
        }
        let path = canonical_path(entry.name())?;
        if entries
            .insert(
                path,
                EntryIndex {
                    index,
                    size: entry.size(),
                },
            )
            .is_some()
        {
            return Err(CoreError::parse("3MF archive contains duplicate paths"));
        }
    }

    let root_path = if let Some(entry) = entries.get(&canonical_path(RELATIONSHIPS_PATH)?) {
        if entry.size > MAX_RELATIONSHIPS_SIZE {
            return Err(CoreError::limit("3MF relationships part is too large"));
        }
        let xml = read_entry(&mut archive, entry.index, entry.size as usize)?;
        relationship_target(&xml)?.unwrap_or_else(|| DEFAULT_MODEL_PATH.to_owned())
    } else {
        DEFAULT_MODEL_PATH.to_owned()
    };

    let root_path = canonical_path(&root_path)?;
    let mut model = ParsedModel {
        unit_millimeters: 1.0,
        ..ParsedModel::default()
    };
    let mut pending = VecDeque::from([root_path.clone()]);
    let mut parsed = HashSet::new();
    let mut total_size = 0_u64;
    while let Some(part_path) = pending.pop_front() {
        if !parsed.insert(part_path.clone()) {
            continue;
        }
        if parsed.len() > MAX_PART_COUNT {
            return Err(CoreError::limit(format!(
                "3MF archive references more than {MAX_PART_COUNT} model parts"
            )));
        }
        let entry = entries
            .get(&part_path)
            .ok_or_else(|| CoreError::parse(format!("3MF model part is missing: {part_path}")))?;
        if entry.size > MAX_PART_SIZE {
            return Err(CoreError::limit("3MF model part is too large"));
        }
        total_size = total_size
            .checked_add(entry.size)
            .ok_or_else(|| CoreError::limit("3MF model part size overflow"))?;
        if total_size > MAX_TOTAL_PART_SIZE {
            return Err(CoreError::limit("3MF model parts are too large"));
        }
        let xml = read_entry(&mut archive, entry.index, entry.size as usize)?;
        parse_model_part(
            &xml,
            &part_path,
            part_path == root_path,
            &mut model,
            &mut pending,
            &parsed,
        )?;
    }

    flatten_model(model, &root_path)
}

fn read_entry<R: Read + Seek>(
    archive: &mut zip::ZipArchive<R>,
    index: usize,
    declared_size: usize,
) -> Result<Vec<u8>, CoreError> {
    let entry = archive.by_index(index).map_err(crate::zip::map_zip_error)?;
    let mut bytes = Vec::with_capacity(declared_size.min(1_048_576));
    entry
        .take(declared_size as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|error| CoreError::io(format!("Could not read 3MF archive entry: {error}")))?;
    if bytes.len() != declared_size {
        return Err(CoreError::parse("3MF archive entry has an invalid size"));
    }
    Ok(bytes)
}

fn relationship_target(xml: &[u8]) -> Result<Option<String>, CoreError> {
    let mut reader = Reader::from_reader(xml);
    reader.config_mut().trim_text(true);
    loop {
        match reader.read_event() {
            Ok(Event::Start(element) | Event::Empty(element))
                if local_name(element.name().as_ref()) == b"Relationship" =>
            {
                if attribute(&reader, &element, b"Type")?.as_deref()
                    == Some(MODEL_RELATIONSHIP_TYPE)
                {
                    return attribute(&reader, &element, b"Target");
                }
            }
            Ok(Event::Eof) => return Ok(None),
            Ok(_) => {}
            Err(error) => {
                return Err(CoreError::parse(format!(
                    "Could not parse 3MF relationships: {error}"
                )));
            }
        }
    }
}

fn parse_model_part(
    xml: &[u8],
    part_path: &str,
    is_root: bool,
    model: &mut ParsedModel,
    pending: &mut VecDeque<String>,
    parsed: &HashSet<String>,
) -> Result<(), CoreError> {
    let mut reader = Reader::from_reader(xml);
    reader.config_mut().trim_text(true);
    let mut stack: Vec<Vec<u8>> = Vec::new();
    let mut current_object: Option<(String, Object)> = None;
    let mut current_mesh: Option<(usize, Mesh)> = None;
    let mut current_colors: Option<(usize, String, Vec<[f32; 4]>)> = None;

    loop {
        let event = reader
            .read_event()
            .map_err(|error| CoreError::parse(format!("Could not parse 3MF model XML: {error}")))?;
        match event {
            Event::Start(element) => {
                if stack.len() >= MAX_ELEMENT_DEPTH {
                    return Err(CoreError::limit("3MF XML is nested too deeply"));
                }
                let name = local_name(element.name().as_ref()).to_vec();
                stack.push(name.clone());
                handle_start(
                    &reader,
                    &element,
                    &name,
                    &stack,
                    part_path,
                    is_root,
                    model,
                    pending,
                    parsed,
                    &mut current_object,
                    &mut current_mesh,
                    &mut current_colors,
                )?;
            }
            Event::Empty(element) => {
                if stack.len() >= MAX_ELEMENT_DEPTH {
                    return Err(CoreError::limit("3MF XML is nested too deeply"));
                }
                let name = local_name(element.name().as_ref()).to_vec();
                stack.push(name.clone());
                handle_start(
                    &reader,
                    &element,
                    &name,
                    &stack,
                    part_path,
                    is_root,
                    model,
                    pending,
                    parsed,
                    &mut current_object,
                    &mut current_mesh,
                    &mut current_colors,
                )?;
                handle_end(
                    &name,
                    &stack,
                    stack.len(),
                    model,
                    &mut current_object,
                    &mut current_mesh,
                    &mut current_colors,
                )?;
                stack.pop();
            }
            Event::End(element) => {
                let name = local_name(element.name().as_ref()).to_vec();
                handle_end(
                    &name,
                    &stack,
                    stack.len(),
                    model,
                    &mut current_object,
                    &mut current_mesh,
                    &mut current_colors,
                )?;
                if stack.pop().as_deref() != Some(name.as_slice()) {
                    return Err(CoreError::parse("3MF XML element nesting is invalid"));
                }
            }
            Event::Eof => break,
            _ => {}
        }
    }
    if !stack.is_empty() || current_object.is_some() {
        return Err(CoreError::parse("3MF model XML is truncated"));
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn handle_start(
    reader: &Reader<&[u8]>,
    element: &BytesStart<'_>,
    name: &[u8],
    stack: &[Vec<u8>],
    part_path: &str,
    is_root: bool,
    model: &mut ParsedModel,
    pending: &mut VecDeque<String>,
    parsed: &HashSet<String>,
    current_object: &mut Option<(String, Object)>,
    current_mesh: &mut Option<(usize, Mesh)>,
    current_colors: &mut Option<(usize, String, Vec<[f32; 4]>)>,
) -> Result<(), CoreError> {
    let depth = stack.len();
    match name {
        b"model" if is_root => {
            if let Some(unit) = attribute(reader, element, b"unit")? {
                model.unit_millimeters = unit_scale(&unit);
            }
        }
        b"object" if path_ends_with(stack, &[b"resources", b"object"]) => {
            if current_object.is_some() {
                return Err(CoreError::parse("3MF objects must not be nested"));
            }
            let id = required_attribute(reader, element, b"id", "object")?;
            let group = attribute(reader, element, b"pid")?.map(|id| object_key(part_path, &id));
            let property_index = attribute(reader, element, b"pindex")?
                .map(|value| parse_usize(&value, "object property index"))
                .transpose()?;
            *current_object = Some((
                object_key(part_path, &id),
                Object {
                    property_group: group,
                    property_index,
                    ..Object::default()
                },
            ));
        }
        b"mesh"
            if current_object.is_some()
                && current_mesh.is_none()
                && path_ends_with(stack, &[b"object", b"mesh"]) =>
        {
            *current_mesh = Some((depth, Mesh::default()));
        }
        b"vertex"
            if current_mesh
                .as_ref()
                .is_some_and(|(mesh_depth, _)| depth == mesh_depth + 2)
                && path_ends_with(stack, &[b"mesh", b"vertices", b"vertex"]) =>
        {
            model.vertex_count += 1;
            if model.vertex_count > MAX_VERTICES {
                return Err(CoreError::limit(format!(
                    "3MF model contains more than {MAX_VERTICES} vertices"
                )));
            }
            let vertex = [
                coordinate(&required_attribute(reader, element, b"x", "vertex")?)?,
                coordinate(&required_attribute(reader, element, b"y", "vertex")?)?,
                coordinate(&required_attribute(reader, element, b"z", "vertex")?)?,
            ];
            current_mesh
                .as_mut()
                .ok_or_else(|| CoreError::parse("3MF vertex is outside a mesh"))?
                .1
                .vertices
                .push(vertex);
        }
        b"triangle"
            if current_mesh
                .as_ref()
                .is_some_and(|(mesh_depth, _)| depth == mesh_depth + 2)
                && path_ends_with(stack, &[b"mesh", b"triangles", b"triangle"]) =>
        {
            model.triangle_count += 1;
            if model.triangle_count > MAX_TRIANGLES {
                return Err(CoreError::limit(format!(
                    "3MF model contains more than {MAX_TRIANGLES} triangles"
                )));
            }
            let triangle = [
                parse_u32(
                    &required_attribute(reader, element, b"v1", "triangle")?,
                    "triangle index",
                )?,
                parse_u32(
                    &required_attribute(reader, element, b"v2", "triangle")?,
                    "triangle index",
                )?,
                parse_u32(
                    &required_attribute(reader, element, b"v3", "triangle")?,
                    "triangle index",
                )?,
            ];
            current_mesh
                .as_mut()
                .ok_or_else(|| CoreError::parse("3MF triangle is outside a mesh"))?
                .1
                .triangles
                .push(triangle);
        }
        b"component"
            if current_object.is_some()
                && path_ends_with(stack, &[b"object", b"components", b"component"]) =>
        {
            let id = required_attribute(reader, element, b"objectid", "component")?;
            let target_path = target_part_path(reader, element, part_path)?;
            enqueue_part(&target_path, pending, parsed)?;
            current_object
                .as_mut()
                .ok_or_else(|| CoreError::parse("3MF component is outside an object"))?
                .1
                .components
                .push(Component {
                    object_key: object_key(&target_path, &id),
                    transform: parse_transform(attribute(reader, element, b"transform")?)?,
                });
        }
        b"item" if is_root && path_ends_with(stack, &[b"model", b"build", b"item"]) => {
            let id = required_attribute(reader, element, b"objectid", "build item")?;
            let target_path = target_part_path(reader, element, part_path)?;
            enqueue_part(&target_path, pending, parsed)?;
            model.build_items.push(Component {
                object_key: object_key(&target_path, &id),
                transform: parse_transform(attribute(reader, element, b"transform")?)?,
            });
        }
        b"basematerials" | b"colorgroup"
            if current_colors.is_none() && path_ends_with(stack, &[b"resources", name]) =>
        {
            let id = required_attribute(reader, element, b"id", "color group")?;
            *current_colors = Some((depth, object_key(part_path, &id), Vec::new()));
        }
        b"base"
            if current_colors
                .as_ref()
                .is_some_and(|(group_depth, _, _)| depth == group_depth + 1)
                && path_ends_with(stack, &[b"basematerials", b"base"]) =>
        {
            let color = attribute(reader, element, b"displaycolor")?
                .as_deref()
                .and_then(parse_color)
                .unwrap_or(DEFAULT_COLOR);
            current_colors
                .as_mut()
                .ok_or_else(|| CoreError::parse("3MF base is outside a material group"))?
                .2
                .push(color);
        }
        b"color"
            if current_colors
                .as_ref()
                .is_some_and(|(group_depth, _, _)| depth == group_depth + 1)
                && path_ends_with(stack, &[b"colorgroup", b"color"]) =>
        {
            let color = attribute(reader, element, b"color")?
                .as_deref()
                .and_then(parse_color)
                .unwrap_or(DEFAULT_COLOR);
            current_colors
                .as_mut()
                .ok_or_else(|| CoreError::parse("3MF color is outside a color group"))?
                .2
                .push(color);
        }
        _ => {}
    }
    Ok(())
}

fn handle_end(
    name: &[u8],
    stack: &[Vec<u8>],
    depth: usize,
    model: &mut ParsedModel,
    current_object: &mut Option<(String, Object)>,
    current_mesh: &mut Option<(usize, Mesh)>,
    current_colors: &mut Option<(usize, String, Vec<[f32; 4]>)>,
) -> Result<(), CoreError> {
    if name == b"mesh" && current_mesh.as_ref().is_some_and(|(d, _)| *d == depth) {
        let (_, mesh) = current_mesh
            .take()
            .ok_or_else(|| CoreError::parse("3MF mesh end is unmatched"))?;
        current_object
            .as_mut()
            .ok_or_else(|| CoreError::parse("3MF mesh is outside an object"))?
            .1
            .mesh = Some(mesh);
    } else if name == b"object" && path_ends_with(stack, &[b"resources", b"object"]) {
        let (key, object) = current_object
            .take()
            .ok_or_else(|| CoreError::parse("3MF object end is unmatched"))?;
        if model.objects.insert(key, object).is_some() {
            return Err(CoreError::parse("3MF model contains duplicate object IDs"));
        }
        *current_mesh = None;
    } else if matches!(name, b"basematerials" | b"colorgroup")
        && current_colors.as_ref().is_some_and(|(d, _, _)| *d == depth)
    {
        let (_, key, colors) = current_colors
            .take()
            .ok_or_else(|| CoreError::parse("3MF color group end is unmatched"))?;
        model.colors.insert(key, colors);
    }
    Ok(())
}

fn flatten_model(model: ParsedModel, root_path: &str) -> Result<ThreeMfPayload, CoreError> {
    let mut mesh_indices = HashMap::new();
    let mut meshes = Vec::new();
    for (key, object) in &model.objects {
        let Some(mesh) = &object.mesh else { continue };
        for triangle in &mesh.triangles {
            if triangle
                .iter()
                .any(|index| *index as usize >= mesh.vertices.len())
            {
                return Err(CoreError::parse("3MF triangle references a missing vertex"));
            }
        }
        if mesh.triangles.is_empty() {
            continue;
        }
        let color = object
            .property_group
            .as_ref()
            .zip(object.property_index)
            .and_then(|(group, index)| model.colors.get(group)?.get(index))
            .copied()
            .unwrap_or(DEFAULT_COLOR);
        mesh_indices.insert(key.clone(), meshes.len());
        meshes.push(ThreeMfMesh {
            vertices: mesh.vertices.clone(),
            triangles: mesh.triangles.clone(),
            color,
        });
    }

    let roots = if model.build_items.is_empty() {
        let referenced: HashSet<&str> = model
            .objects
            .values()
            .flat_map(|object| {
                object
                    .components
                    .iter()
                    .map(|part| part.object_key.as_str())
            })
            .collect();
        model
            .objects
            .keys()
            .filter(|key| {
                key.starts_with(&format!("{root_path}#")) && !referenced.contains(key.as_str())
            })
            .map(|key| Component {
                object_key: key.clone(),
                transform: IDENTITY,
            })
            .collect::<Vec<_>>()
    } else {
        model.build_items
    };

    let mut instances = Vec::new();
    let mut bounds: Option<([f32; 3], [f32; 3])> = None;
    let mut node_count = 0;
    for root in roots {
        flatten_object(
            &root.object_key,
            root.transform,
            0,
            &mut HashSet::new(),
            &model.objects,
            &mesh_indices,
            &meshes,
            &mut instances,
            &mut bounds,
            &mut node_count,
        )?;
    }
    let Some((bounds_min, bounds_max)) = bounds else {
        return Err(CoreError::parse("3MF model does not contain any geometry"));
    };
    let triangle_count = instances
        .iter()
        .try_fold(0_usize, |total, instance| {
            total.checked_add(meshes[instance.mesh_index].triangles.len())
        })
        .ok_or_else(|| CoreError::limit("3MF rendered triangle count overflow"))?;
    if triangle_count > MAX_TRIANGLES {
        return Err(CoreError::limit(format!(
            "3MF scene places more than {MAX_TRIANGLES} triangles"
        )));
    }
    Ok(ThreeMfPayload {
        meshes,
        instances,
        unit_millimeters: model.unit_millimeters,
        bounds_min,
        bounds_max,
        triangle_count,
    })
}

#[allow(clippy::too_many_arguments)]
fn flatten_object(
    key: &str,
    transform: Matrix,
    depth: usize,
    visited: &mut HashSet<String>,
    objects: &HashMap<String, Object>,
    mesh_indices: &HashMap<String, usize>,
    meshes: &[ThreeMfMesh],
    instances: &mut Vec<ThreeMfInstance>,
    bounds: &mut Option<([f32; 3], [f32; 3])>,
    node_count: &mut usize,
) -> Result<(), CoreError> {
    if depth >= MAX_OBJECT_DEPTH {
        return Err(CoreError::limit("3MF object graph is nested too deeply"));
    }
    if !visited.insert(key.to_owned()) {
        return Err(CoreError::parse("3MF object graph contains a cycle"));
    }
    *node_count += 1;
    if *node_count > MAX_NODES {
        return Err(CoreError::limit(format!(
            "3MF scene contains more than {MAX_NODES} object instances"
        )));
    }
    let object = objects
        .get(key)
        .ok_or_else(|| CoreError::parse(format!("3MF references missing object {key}")))?;
    if let Some(&mesh_index) = mesh_indices.get(key) {
        for vertex in &meshes[mesh_index].vertices {
            let transformed = transform_point(*vertex, transform)?;
            match bounds {
                Some((minimum, maximum)) => {
                    for axis in 0..3 {
                        minimum[axis] = minimum[axis].min(transformed[axis]);
                        maximum[axis] = maximum[axis].max(transformed[axis]);
                    }
                }
                None => *bounds = Some((transformed, transformed)),
            }
        }
        instances.push(ThreeMfInstance {
            mesh_index,
            transform,
        });
    }
    for component in &object.components {
        flatten_object(
            &component.object_key,
            multiply(component.transform, transform)?,
            depth + 1,
            visited,
            objects,
            mesh_indices,
            meshes,
            instances,
            bounds,
            node_count,
        )?;
    }
    visited.remove(key);
    Ok(())
}

fn multiply(left: Matrix, right: Matrix) -> Result<Matrix, CoreError> {
    let mut result = [0.0; 16];
    for row in 0..4 {
        for column in 0..4 {
            result[row * 4 + column] = (0..4)
                .map(|index| left[row * 4 + index] * right[index * 4 + column])
                .sum();
            validate_number(result[row * 4 + column], "composed transform")?;
        }
    }
    Ok(result)
}

fn transform_point(point: [f32; 3], matrix: Matrix) -> Result<[f32; 3], CoreError> {
    let result = [
        point[0] * matrix[0] + point[1] * matrix[4] + point[2] * matrix[8] + matrix[12],
        point[0] * matrix[1] + point[1] * matrix[5] + point[2] * matrix[9] + matrix[13],
        point[0] * matrix[2] + point[1] * matrix[6] + point[2] * matrix[10] + matrix[14],
    ];
    for value in result {
        validate_number(value, "transformed coordinate")?;
    }
    Ok(result)
}

fn target_part_path(
    reader: &Reader<&[u8]>,
    element: &BytesStart<'_>,
    current_path: &str,
) -> Result<String, CoreError> {
    match attribute(reader, element, b"path")? {
        Some(path) => canonical_path(&path),
        None => Ok(current_path.to_owned()),
    }
}

fn enqueue_part(
    path: &str,
    pending: &mut VecDeque<String>,
    parsed: &HashSet<String>,
) -> Result<(), CoreError> {
    if !parsed.contains(path) && !pending.iter().any(|candidate| candidate == path) {
        if pending.len() + parsed.len() >= MAX_PART_COUNT {
            return Err(CoreError::limit(format!(
                "3MF archive references more than {MAX_PART_COUNT} model parts"
            )));
        }
        pending.push_back(path.to_owned());
    }
    Ok(())
}

fn attribute(
    reader: &Reader<&[u8]>,
    element: &BytesStart<'_>,
    expected: &[u8],
) -> Result<Option<String>, CoreError> {
    for attribute in element.attributes() {
        let attribute = attribute
            .map_err(|error| CoreError::parse(format!("Invalid 3MF XML attribute: {error}")))?;
        if local_name(attribute.key.as_ref()) == expected {
            return attribute
                .decoded_and_normalized_value(XmlVersion::Implicit1_0, reader.decoder())
                .map(|value| Some(value.into_owned()))
                .map_err(|error| {
                    CoreError::parse(format!("Invalid 3MF XML attribute value: {error}"))
                });
        }
    }
    Ok(None)
}

fn required_attribute(
    reader: &Reader<&[u8]>,
    element: &BytesStart<'_>,
    name: &[u8],
    context: &str,
) -> Result<String, CoreError> {
    attribute(reader, element, name)?.ok_or_else(|| {
        CoreError::parse(format!(
            "3MF {context} is missing {}",
            String::from_utf8_lossy(name)
        ))
    })
}

fn local_name(name: &[u8]) -> &[u8] {
    name.rsplit(|byte| *byte == b':').next().unwrap_or(name)
}

fn path_ends_with(stack: &[Vec<u8>], expected: &[&[u8]]) -> bool {
    stack.len() >= expected.len()
        && stack[stack.len() - expected.len()..]
            .iter()
            .map(Vec::as_slice)
            .eq(expected.iter().copied())
}

fn canonical_path(path: &str) -> Result<String, CoreError> {
    let path = path.replace('\\', "/");
    let mut components = Vec::new();
    for component in path.trim_start_matches('/').split('/') {
        match component {
            "" | "." => {}
            ".." => {
                if components.pop().is_none() {
                    return Err(CoreError::parse("3MF path escapes the archive root"));
                }
            }
            value => components.push(value),
        }
    }
    if components.is_empty() {
        return Err(CoreError::parse("3MF path is empty"));
    }
    Ok(components.join("/").to_lowercase())
}

fn object_key(path: &str, id: &str) -> String {
    format!("{path}#{id}")
}

fn unit_scale(unit: &str) -> f32 {
    match unit.to_ascii_lowercase().as_str() {
        "micron" => 0.001,
        "centimeter" => 10.0,
        "inch" => 25.4,
        "foot" => 304.8,
        "meter" => 1_000.0,
        _ => 1.0,
    }
}

fn coordinate(value: &str) -> Result<f32, CoreError> {
    let value = value
        .parse::<f32>()
        .map_err(|_| CoreError::parse("3MF coordinate is not a number"))?;
    validate_number(value, "coordinate")?;
    Ok(value)
}

fn validate_number(value: f32, context: &str) -> Result<(), CoreError> {
    if !value.is_finite() || value.abs() > MAX_COORDINATE {
        return Err(CoreError::limit(format!(
            "3MF {context} is outside the renderable range"
        )));
    }
    Ok(())
}

fn parse_u32(value: &str, context: &str) -> Result<u32, CoreError> {
    value
        .parse()
        .map_err(|_| CoreError::parse(format!("3MF {context} is invalid")))
}

fn parse_usize(value: &str, context: &str) -> Result<usize, CoreError> {
    value
        .parse()
        .map_err(|_| CoreError::parse(format!("3MF {context} is invalid")))
}

fn parse_transform(value: Option<String>) -> Result<Matrix, CoreError> {
    let Some(value) = value else {
        return Ok(IDENTITY);
    };
    let values = value
        .split_ascii_whitespace()
        .map(|part| {
            part.parse::<f32>()
                .map_err(|_| CoreError::parse("3MF transform is invalid"))
        })
        .collect::<Result<Vec<_>, _>>()?;
    if values.len() != 12 {
        return Err(CoreError::parse("3MF transform must contain 12 numbers"));
    }
    for value in &values {
        validate_number(*value, "transform")?;
    }
    Ok([
        values[0], values[1], values[2], 0.0, values[3], values[4], values[5], 0.0, values[6],
        values[7], values[8], 0.0, values[9], values[10], values[11], 1.0,
    ])
}

fn parse_color(value: &str) -> Option<[f32; 4]> {
    let hex = value.strip_prefix('#')?;
    if !matches!(hex.len(), 6 | 8) {
        return None;
    }
    let number = u32::from_str_radix(hex, 16).ok()?;
    let alpha = if hex.len() == 8 { number & 0xff } else { 0xff };
    let shift = if hex.len() == 8 { 8 } else { 0 };
    Some([
        ((number >> (16 + shift)) & 0xff) as f32 / 255.0,
        ((number >> (8 + shift)) & 0xff) as f32 / 255.0,
        ((number >> shift) & 0xff) as f32 / 255.0,
        alpha as f32 / 255.0,
    ])
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::io::Write;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn parses_transforms_colors_and_units() {
        let matrix = parse_transform(Some("1 0 0 0 1 0 0 0 1 10 20 30".into())).unwrap();
        assert_eq!(
            transform_point([1.0, 2.0, 3.0], matrix).unwrap(),
            [11.0, 22.0, 33.0]
        );
        assert_eq!(
            parse_color("#33669980"),
            Some([0.2, 0.4, 0.6, 128.0 / 255.0])
        );
        assert_eq!(unit_scale("inch"), 25.4);
    }

    #[test]
    fn rejects_unsafe_paths_and_numbers() {
        assert!(canonical_path("../../model").is_err());
        assert!(coordinate("NaN").is_err());
        assert!(parse_transform(Some("1 2".into())).is_err());
    }

    #[test]
    fn parses_real_three_mf_fixture() {
        let path = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../GlanceTests/TestFiles/models/simple.3mf");
        let payload = parse_three_mf(&path).unwrap();
        assert_eq!(payload.meshes.len(), 1);
        assert_eq!(payload.instances.len(), 1);
        assert_eq!(payload.triangle_count, 1);
        assert_eq!(payload.bounds_min, [2.0, 3.0, 4.0]);
        assert_eq!(payload.bounds_max, [12.0, 23.0, 4.0]);
        assert_eq!(payload.meshes[0].color, [0.2, 0.4, 0.6, 1.0]);
    }

    #[test]
    fn parses_multipart_components_and_composes_transforms() {
        let root = r#"<model unit="inch"><resources><object id="1"><components><component objectid="2" path="/3D/part.model" transform="1 0 0 0 1 0 0 0 1 5 0 0"/></components></object></resources><build><item objectid="1" transform="1 0 0 0 1 0 0 0 1 10 0 0"/></build></model>"#;
        let part = r#"<model><resources><object id="2"><mesh><vertices><vertex x="0" y="0" z="0"/><vertex x="1" y="0" z="0"/><vertex x="0" y="1" z="0"/></vertices><triangles><triangle v1="0" v2="1" v3="2"/></triangles></mesh></object></resources></model>"#;
        let path = write_archive(&[("3D/3dmodel.model", root), ("3D/part.model", part)]);
        let payload = parse_three_mf(&path).unwrap();
        assert_eq!(payload.instances.len(), 1);
        assert_eq!(payload.bounds_min, [15.0, 0.0, 0.0]);
        assert_eq!(payload.bounds_max, [16.0, 1.0, 0.0]);
        assert_eq!(payload.unit_millimeters, 25.4);
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn ignores_extension_elements_named_object() {
        let model = r#"<model xmlns:vendor="urn:vendor"><resources><object id="1"><vendor:object/><mesh><vertices><vertex x="0" y="0" z="0"/><vertex x="1" y="0" z="0"/><vertex x="0" y="1" z="0"/></vertices><triangles><triangle v1="0" v2="1" v3="2"/></triangles></mesh></object></resources><build><item objectid="1"/></build></model>"#;
        let path = write_archive(&[("3D/3dmodel.model", model)]);

        let payload = parse_three_mf(&path).unwrap();

        assert_eq!(payload.triangle_count, 1);
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn rejects_cycles_missing_vertices_truncation_and_oversized_files() {
        let cycle = r#"<model><resources><object id="1"><components><component objectid="2"/></components></object><object id="2"><components><component objectid="1"/></components></object></resources><build><item objectid="1"/></build></model>"#;
        let path = write_archive(&[("3D/3dmodel.model", cycle)]);
        assert!(
            parse_three_mf(&path)
                .unwrap_err()
                .to_string()
                .contains("cycle")
        );
        fs::remove_file(&path).unwrap();

        let bad_index = r#"<model><resources><object id="1"><mesh><vertices><vertex x="0" y="0" z="0"/></vertices><triangles><triangle v1="0" v2="1" v3="2"/></triangles></mesh></object></resources><build><item objectid="1"/></build></model>"#;
        let path = write_archive(&[("3D/3dmodel.model", bad_index)]);
        assert!(
            parse_three_mf(&path)
                .unwrap_err()
                .to_string()
                .contains("missing vertex")
        );
        fs::remove_file(&path).unwrap();

        let truncated = "<model><resources>";
        let path = write_archive(&[("3D/3dmodel.model", truncated)]);
        assert!(parse_three_mf(&path).is_err());
        fs::remove_file(&path).unwrap();

        let path = temporary_path();
        let file = File::create(&path).unwrap();
        file.set_len(MAX_FILE_SIZE + 1).unwrap();
        assert!(
            parse_three_mf(&path)
                .unwrap_err()
                .to_string()
                .contains("preview limit")
        );
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn rejects_deep_xml_and_external_archive_paths() {
        let nested = format!(
            "<model>{}<resources></resources>{}</model>",
            "<x>".repeat(MAX_ELEMENT_DEPTH),
            "</x>".repeat(MAX_ELEMENT_DEPTH)
        );
        let path = write_archive(&[("3D/3dmodel.model", &nested)]);
        assert!(
            parse_three_mf(&path)
                .unwrap_err()
                .to_string()
                .contains("nested too deeply")
        );
        fs::remove_file(path).unwrap();

        let relationships = format!(
            r#"<Relationships><Relationship Target="../../outside.model" Type="{MODEL_RELATIONSHIP_TYPE}"/></Relationships>"#
        );
        let path = write_archive(&[(RELATIONSHIPS_PATH, &relationships)]);
        assert!(parse_three_mf(&path).is_err());
        fs::remove_file(path).unwrap();
    }

    fn write_archive(entries: &[(&str, &str)]) -> std::path::PathBuf {
        let path = temporary_path();
        let file = File::create(&path).unwrap();
        let mut archive = zip::ZipWriter::new(file);
        let options = zip::write::SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Stored);
        for (name, contents) in entries {
            archive.start_file(*name, options).unwrap();
            archive.write_all(contents.as_bytes()).unwrap();
        }
        archive.finish().unwrap();
        path
    }

    fn temporary_path() -> std::path::PathBuf {
        std::env::temp_dir().join(format!(
            "glance-three-mf-test-{}-{}.3mf",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ))
    }
}
