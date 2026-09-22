use crate::error::CoreError;
use base64::Engine;
use quick_xml::events::{BytesStart, Event};
use quick_xml::{Reader, XmlVersion};
use std::collections::{HashMap, HashSet};
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;
use std::sync::Arc;

pub(crate) const MAX_FILE_SIZE: u64 = 200_000_000;
const MAX_ENTRY_COUNT: usize = 10_000;
const MAX_TOTAL_UNCOMPRESSED_SIZE: u64 = 128 * 1_024 * 1_024;
const MAX_XML_SIZE: u64 = 4 * 1_024 * 1_024;
const MAX_CHAPTER_COUNT: usize = 500;
const MAX_CHAPTER_SIZE: u64 = 4 * 1_024 * 1_024;
const MAX_TOTAL_CHAPTER_SIZE: u64 = 32 * 1_024 * 1_024;
const MAX_IMAGE_SIZE: u64 = 16 * 1_024 * 1_024;
const MAX_TOTAL_IMAGE_SIZE: u64 = 48 * 1_024 * 1_024;
const MAX_OUTPUT_SIZE: usize = 96 * 1_024 * 1_024;
const MAX_PATH_LENGTH: usize = 4_096;
const MAX_ELEMENT_DEPTH: usize = 128;

#[derive(Clone)]
struct EntryIndex {
    index: usize,
    size: u64,
}

#[derive(Clone)]
struct ManifestItem {
    path: String,
    media_type: String,
}

struct Package {
    title: String,
    creator: Option<String>,
    language: Option<String>,
    manifest: HashMap<String, ManifestItem>,
    spine: Vec<String>,
}

/// Produces one self-contained, script-free HTML article from a DRM-free EPUB 2 or EPUB 3 book.
pub(crate) fn render_epub(path: &Path) -> Result<String, CoreError> {
    render_epub_with_output_limit(path, MAX_OUTPUT_SIZE)
}

fn render_epub_with_output_limit(path: &Path, output_limit: usize) -> Result<String, CoreError> {
    let mut file =
        File::open(path).map_err(|error| CoreError::io(format!("Could not open EPUB: {error}")))?;
    let file_size = file
        .metadata()
        .map_err(|error| CoreError::io(format!("Could not inspect EPUB: {error}")))?
        .len();
    if file_size > MAX_FILE_SIZE {
        return Err(CoreError::limit(format!(
            "EPUB exceeds the {MAX_FILE_SIZE} byte preview limit"
        )));
    }
    crate::zip::preflight_central_directory(&mut file, file_size)?;
    file.seek(SeekFrom::Start(0))
        .map_err(|error| CoreError::io(format!("Could not seek EPUB: {error}")))?;
    let mut archive = zip::ZipArchive::new(file).map_err(crate::zip::map_zip_error)?;
    if archive.len() > MAX_ENTRY_COUNT {
        return Err(CoreError::limit(format!(
            "EPUB contains more than {MAX_ENTRY_COUNT} entries"
        )));
    }

    let mut entries = HashMap::with_capacity(archive.len());
    let mut total_size = 0_u64;
    for index in 0..archive.len() {
        let entry = archive
            .by_index_raw(index)
            .map_err(crate::zip::map_zip_error)?;
        if entry.encrypted() {
            return Err(CoreError::unsupported(
                "Encrypted or DRM-protected EPUB books are not supported",
            ));
        }
        if !entry.is_file() && !entry.is_dir() {
            return Err(CoreError::unsupported(
                "EPUB contains an unsupported non-file entry",
            ));
        }
        let name = canonical_path(entry.name())?;
        if name.is_empty() || entry.is_dir() {
            continue;
        }
        total_size = total_size
            .checked_add(entry.size())
            .ok_or_else(|| CoreError::limit("EPUB entry size overflow"))?;
        if total_size > MAX_TOTAL_UNCOMPRESSED_SIZE {
            return Err(CoreError::limit(format!(
                "EPUB expands beyond the {MAX_TOTAL_UNCOMPRESSED_SIZE} byte preview limit"
            )));
        }
        if entries
            .insert(
                name,
                EntryIndex {
                    index,
                    size: entry.size(),
                },
            )
            .is_some()
        {
            return Err(CoreError::parse("EPUB contains duplicate paths"));
        }
    }

    validate_mimetype(&mut archive, &entries)?;
    if entries.contains_key("META-INF/encryption.xml") {
        return Err(CoreError::unsupported(
            "Encrypted or DRM-protected EPUB books are not supported",
        ));
    }
    let container = read_named_entry(
        &mut archive,
        &entries,
        "META-INF/container.xml",
        MAX_XML_SIZE,
        "EPUB container",
    )?;
    let package_path = parse_container(&container)?;
    let package_xml = read_named_entry(
        &mut archive,
        &entries,
        &package_path,
        MAX_XML_SIZE,
        "EPUB package",
    )?;
    let package = parse_package(&package_xml, &package_path)?;
    if package.spine.len() > MAX_CHAPTER_COUNT {
        return Err(CoreError::limit(format!(
            "EPUB spine contains more than {MAX_CHAPTER_COUNT} chapters"
        )));
    }

    let chapter_items = package
        .spine
        .iter()
        .map(|id| {
            package.manifest.get(id).ok_or_else(|| {
                CoreError::parse(format!("EPUB spine references missing item: {id}"))
            })
        })
        .collect::<Result<Vec<_>, _>>()?;
    if chapter_items.is_empty() {
        return Err(CoreError::parse(
            "EPUB spine does not contain any readable chapters",
        ));
    }
    let chapter_paths = chapter_items
        .iter()
        .enumerate()
        .map(|(index, item)| (item.path.clone(), index))
        .collect::<HashMap<_, _>>();

    let mut html = String::new();
    html.push_str("<article class=\"epub-book\"><header class=\"epub-metadata\">");
    html.push_str("<h1>");
    escape_html_into(&package.title, &mut html);
    html.push_str("</h1>");
    if let Some(creator) = &package.creator {
        html.push_str("<p class=\"epub-creator\">");
        escape_html_into(creator, &mut html);
        html.push_str("</p>");
    }
    if let Some(language) = &package.language {
        html.push_str("<p class=\"epub-language\">");
        escape_html_into(language, &mut html);
        html.push_str("</p>");
    }
    html.push_str("</header><nav class=\"epub-contents\" aria-label=\"Contents\"><ol>");
    for (index, _) in chapter_items.iter().enumerate() {
        html.push_str("<li><a href=\"#glance-chapter-");
        html.push_str(&(index + 1).to_string());
        html.push_str("\">Chapter ");
        html.push_str(&(index + 1).to_string());
        html.push_str("</a></li>");
    }
    html.push_str("</ol></nav>");
    ensure_output_limit(html.len(), output_limit)?;

    let mut total_chapter_size = 0_u64;
    let mut total_image_size = 0_u64;
    let mut image_cache = HashMap::new();
    for (index, item) in chapter_items.iter().enumerate() {
        if !matches!(
            item.media_type.as_str(),
            "application/xhtml+xml" | "text/html"
        ) {
            return Err(CoreError::unsupported(format!(
                "EPUB spine item uses unsupported media type: {}",
                item.media_type
            )));
        }
        let entry = entries
            .get(&item.path)
            .ok_or_else(|| CoreError::parse(format!("EPUB chapter is missing: {}", item.path)))?;
        if entry.size > MAX_CHAPTER_SIZE {
            return Err(CoreError::limit(format!(
                "EPUB chapter exceeds the {MAX_CHAPTER_SIZE} byte preview limit"
            )));
        }
        total_chapter_size = total_chapter_size
            .checked_add(entry.size)
            .ok_or_else(|| CoreError::limit("EPUB chapter size overflow"))?;
        if total_chapter_size > MAX_TOTAL_CHAPTER_SIZE {
            return Err(CoreError::limit(format!(
                "EPUB chapters exceed the {MAX_TOTAL_CHAPTER_SIZE} byte preview limit"
            )));
        }
        let chapter = read_entry(&mut archive, entry, MAX_CHAPTER_SIZE, "EPUB chapter")?;
        let body = render_chapter(
            &chapter,
            &item.path,
            index,
            &chapter_paths,
            &package.manifest,
            &entries,
            &mut archive,
            &mut image_cache,
            &mut total_image_size,
            output_limit.saturating_sub(html.len()),
        )?;
        html.push_str("<section class=\"epub-chapter\" id=\"glance-chapter-");
        html.push_str(&(index + 1).to_string());
        html.push_str("\">");
        html.push_str(&body);
        html.push_str("<nav class=\"epub-chapter-navigation\" aria-label=\"Chapter navigation\">");
        if index > 0 {
            html.push_str("<a href=\"#glance-chapter-");
            html.push_str(&index.to_string());
            html.push_str("\">Previous</a>");
        }
        if index + 1 < chapter_items.len() {
            html.push_str("<a href=\"#glance-chapter-");
            html.push_str(&(index + 2).to_string());
            html.push_str("\">Next</a>");
        }
        html.push_str("</nav></section>");
        ensure_output_limit(html.len(), output_limit)?;
    }
    html.push_str("</article>");
    ensure_output_limit(html.len(), output_limit)?;
    Ok(html)
}

fn ensure_output_limit(size: usize, output_limit: usize) -> Result<(), CoreError> {
    if size > output_limit {
        return Err(CoreError::limit(format!(
            "EPUB preview exceeds the {output_limit} byte output limit"
        )));
    }
    Ok(())
}

fn validate_mimetype<R: Read + Seek>(
    archive: &mut zip::ZipArchive<R>,
    entries: &HashMap<String, EntryIndex>,
) -> Result<(), CoreError> {
    let bytes = read_named_entry(archive, entries, "mimetype", 128, "EPUB mimetype")?;
    if bytes != b"application/epub+zip" {
        return Err(CoreError::parse("EPUB has an invalid mimetype entry"));
    }
    Ok(())
}

fn parse_container(xml: &[u8]) -> Result<String, CoreError> {
    let mut reader = Reader::from_reader(xml);
    reader.config_mut().trim_text(false);
    let mut depth = 0_usize;
    loop {
        match reader.read_event() {
            Ok(Event::Start(element)) => {
                depth += 1;
                check_depth(depth)?;
                if local_name(element.name().as_ref()) == b"rootfile" {
                    let path = required_attribute(reader.decoder(), &element, b"full-path")?;
                    return canonical_path(&percent_decode(&path)?);
                }
            }
            Ok(Event::Empty(element)) if local_name(element.name().as_ref()) == b"rootfile" => {
                let path = required_attribute(reader.decoder(), &element, b"full-path")?;
                return canonical_path(&percent_decode(&path)?);
            }
            Ok(Event::End(_)) => depth = depth.saturating_sub(1),
            Ok(Event::DocType(_)) => {
                return Err(CoreError::unsupported(
                    "EPUB XML document types are not supported",
                ));
            }
            Ok(Event::Eof) => return Err(CoreError::parse("EPUB container has no rootfile")),
            Ok(_) => {}
            Err(error) => {
                return Err(CoreError::parse(format!(
                    "Could not parse EPUB container XML: {error}"
                )));
            }
        }
    }
}

fn parse_package(xml: &[u8], package_path: &str) -> Result<Package, CoreError> {
    let mut reader = Reader::from_reader(xml);
    reader.config_mut().trim_text(false);
    let mut stack = Vec::<Vec<u8>>::new();
    let mut version = None;
    let mut title = String::new();
    let mut creator = String::new();
    let mut language = String::new();
    let mut manifest = HashMap::new();
    let mut spine = Vec::new();

    loop {
        match reader.read_event() {
            Ok(Event::Start(element)) => {
                let name = local_name(element.name().as_ref()).to_vec();
                if stack.len() >= MAX_ELEMENT_DEPTH {
                    return Err(CoreError::limit("EPUB package XML is nested too deeply"));
                }
                if stack.is_empty() && name == b"package" {
                    version = Some(required_attribute(reader.decoder(), &element, b"version")?);
                } else if stack.last().is_some_and(|parent| parent == b"manifest")
                    && name == b"item"
                {
                    parse_manifest_item(reader.decoder(), &element, package_path, &mut manifest)?;
                } else if stack.last().is_some_and(|parent| parent == b"spine")
                    && name == b"itemref"
                {
                    parse_spine_item(reader.decoder(), &element, &mut spine)?;
                }
                stack.push(name);
            }
            Ok(Event::Empty(element)) => {
                let qualified_name = element.name();
                let name = local_name(qualified_name.as_ref());
                if stack.last().is_some_and(|parent| parent == b"manifest") && name == b"item" {
                    parse_manifest_item(reader.decoder(), &element, package_path, &mut manifest)?;
                } else if stack.last().is_some_and(|parent| parent == b"spine")
                    && name == b"itemref"
                {
                    parse_spine_item(reader.decoder(), &element, &mut spine)?;
                }
            }
            Ok(Event::Text(text)) => {
                let value = decoded_text(&text)?;
                if inside_metadata_field(&stack, b"title") {
                    title.push_str(&value);
                } else if inside_metadata_field(&stack, b"creator") {
                    creator.push_str(&value);
                } else if inside_metadata_field(&stack, b"language") {
                    language.push_str(&value);
                }
            }
            Ok(Event::GeneralRef(reference)) => {
                let value = predefined_entity(reference.as_ref())?;
                if inside_metadata_field(&stack, b"title") {
                    title.push_str(value);
                } else if inside_metadata_field(&stack, b"creator") {
                    creator.push_str(value);
                } else if inside_metadata_field(&stack, b"language") {
                    language.push_str(value);
                }
            }
            Ok(Event::End(_)) => {
                stack.pop();
            }
            Ok(Event::DocType(_)) => {
                return Err(CoreError::unsupported(
                    "EPUB XML document types are not supported",
                ));
            }
            Ok(Event::Eof) => break,
            Ok(_) => {}
            Err(error) => {
                return Err(CoreError::parse(format!(
                    "Could not parse EPUB package XML: {error}"
                )));
            }
        }
    }

    let version = version.ok_or_else(|| CoreError::parse("EPUB package element is missing"))?;
    if !version.starts_with("2.") && !version.starts_with("3.") {
        return Err(CoreError::unsupported(format!(
            "EPUB package version {version} is not supported"
        )));
    }
    let title = title.trim().to_owned();
    if title.is_empty() {
        return Err(CoreError::parse("EPUB package title is missing"));
    }
    if manifest.is_empty() {
        return Err(CoreError::parse("EPUB manifest is empty"));
    }
    if spine.is_empty() {
        return Err(CoreError::parse("EPUB spine is empty"));
    }
    Ok(Package {
        title,
        creator: nonempty(creator),
        language: nonempty(language),
        manifest,
        spine,
    })
}

fn parse_manifest_item(
    decoder: quick_xml::encoding::Decoder,
    element: &BytesStart<'_>,
    package_path: &str,
    manifest: &mut HashMap<String, ManifestItem>,
) -> Result<(), CoreError> {
    let id = required_attribute(decoder, element, b"id")?;
    let href = required_attribute(decoder, element, b"href")?;
    let media_type = required_attribute(decoder, element, b"media-type")?;
    let path = resolve_path(package_path, &href)?;
    if manifest
        .insert(id, ManifestItem { path, media_type })
        .is_some()
    {
        return Err(CoreError::parse("EPUB manifest contains duplicate IDs"));
    }
    Ok(())
}

fn parse_spine_item(
    decoder: quick_xml::encoding::Decoder,
    element: &BytesStart<'_>,
    spine: &mut Vec<String>,
) -> Result<(), CoreError> {
    if attribute(decoder, element, b"linear")?.as_deref() == Some("no") {
        return Ok(());
    }
    spine.push(required_attribute(decoder, element, b"idref")?);
    if spine.len() > MAX_CHAPTER_COUNT {
        return Err(CoreError::limit(format!(
            "EPUB spine contains more than {MAX_CHAPTER_COUNT} chapters"
        )));
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn render_chapter<R: Read + Seek>(
    xml: &[u8],
    chapter_path: &str,
    chapter_index: usize,
    chapter_paths: &HashMap<String, usize>,
    manifest: &HashMap<String, ManifestItem>,
    entries: &HashMap<String, EntryIndex>,
    archive: &mut zip::ZipArchive<R>,
    image_cache: &mut HashMap<String, Arc<str>>,
    total_image_size: &mut u64,
    output_limit: usize,
) -> Result<String, CoreError> {
    let mut reader = Reader::from_reader(xml);
    reader.config_mut().trim_text(false);
    let mut output = String::new();
    let mut stack = Vec::<Vec<u8>>::new();
    let mut in_body = false;
    let mut body_seen = false;
    let mut suppressed_depth = 0_usize;

    loop {
        match reader.read_event() {
            Ok(Event::Start(element)) => {
                let name = local_name(element.name().as_ref()).to_ascii_lowercase();
                if stack.len() >= MAX_ELEMENT_DEPTH {
                    return Err(CoreError::limit("EPUB chapter XML is nested too deeply"));
                }
                stack.push(name.clone());
                if name == b"body" {
                    in_body = true;
                    body_seen = true;
                } else if in_body && (name == b"script" || name == b"style") {
                    suppressed_depth += 1;
                } else if in_body && suppressed_depth == 0 && allowed_tag(&name) {
                    write_start_tag(
                        reader.decoder(),
                        &element,
                        &name,
                        chapter_path,
                        chapter_index,
                        chapter_paths,
                        manifest,
                        entries,
                        archive,
                        image_cache,
                        total_image_size,
                        output_limit,
                        &mut output,
                    )?;
                }
            }
            Ok(Event::Empty(element)) => {
                let name = local_name(element.name().as_ref()).to_ascii_lowercase();
                if in_body && suppressed_depth == 0 && allowed_tag(&name) {
                    write_start_tag(
                        reader.decoder(),
                        &element,
                        &name,
                        chapter_path,
                        chapter_index,
                        chapter_paths,
                        manifest,
                        entries,
                        archive,
                        image_cache,
                        total_image_size,
                        output_limit,
                        &mut output,
                    )?;
                    if !void_tag(&name) {
                        output.push_str("</");
                        output.push_str(std::str::from_utf8(&name).unwrap_or("span"));
                        output.push('>');
                    }
                }
            }
            Ok(Event::End(element)) => {
                let name = local_name(element.name().as_ref()).to_ascii_lowercase();
                if name == b"body" {
                    in_body = false;
                } else if in_body && (name == b"script" || name == b"style") {
                    suppressed_depth = suppressed_depth.saturating_sub(1);
                } else if in_body && suppressed_depth == 0 && allowed_tag(&name) && !void_tag(&name)
                {
                    output.push_str("</");
                    output.push_str(std::str::from_utf8(&name).unwrap_or("span"));
                    output.push('>');
                }
                stack.pop();
            }
            Ok(Event::Text(text)) if in_body && suppressed_depth == 0 => {
                escape_html_into(&decoded_text(&text)?, &mut output);
            }
            Ok(Event::CData(text)) if in_body && suppressed_depth == 0 => {
                let decoded = text.decode().map_err(|error| {
                    CoreError::parse(format!("Could not decode EPUB chapter text: {error}"))
                })?;
                escape_html_into(&decoded, &mut output);
            }
            Ok(Event::GeneralRef(reference)) if in_body && suppressed_depth == 0 => {
                escape_html_into(predefined_entity(reference.as_ref())?, &mut output);
            }
            Ok(Event::DocType(_)) => {
                return Err(CoreError::unsupported(
                    "EPUB XML document types are not supported",
                ));
            }
            Ok(Event::Eof) => break,
            Ok(_) => {}
            Err(error) => {
                return Err(CoreError::parse(format!(
                    "Could not parse EPUB chapter XML: {error}"
                )));
            }
        }
        ensure_output_limit(output.len(), output_limit)?;
    }
    if !body_seen {
        return Err(CoreError::parse(
            "EPUB chapter does not contain a body element",
        ));
    }

    let mut sanitizer = ammonia::Builder::default();
    sanitizer
        .url_schemes(HashSet::from(["data"]))
        .add_generic_attributes(&["id", "class"]);
    Ok(sanitizer.clean(&output).to_string())
}

#[allow(clippy::too_many_arguments)]
fn write_start_tag<R: Read + Seek>(
    decoder: quick_xml::encoding::Decoder,
    element: &BytesStart<'_>,
    name: &[u8],
    chapter_path: &str,
    chapter_index: usize,
    chapter_paths: &HashMap<String, usize>,
    manifest: &HashMap<String, ManifestItem>,
    entries: &HashMap<String, EntryIndex>,
    archive: &mut zip::ZipArchive<R>,
    image_cache: &mut HashMap<String, Arc<str>>,
    total_image_size: &mut u64,
    output_limit: usize,
    output: &mut String,
) -> Result<(), CoreError> {
    output.push('<');
    output.push_str(std::str::from_utf8(name).unwrap_or("span"));
    if let Some(id) = attribute(decoder, element, b"id")? {
        output.push_str(" id=\"");
        escape_attribute_into(&format!("glance-c{}-{id}", chapter_index + 1), output);
        output.push('"');
    }
    if name == b"a" {
        if let Some(href) = attribute(decoder, element, b"href")?
            && let Some(rewritten) =
                rewrite_href(chapter_path, chapter_index, &href, chapter_paths)?
        {
            output.push_str(" href=\"");
            escape_attribute_into(&rewritten, output);
            output.push('"');
        }
    } else if name == b"img" {
        if let Some(alt) = attribute(decoder, element, b"alt")? {
            output.push_str(" alt=\"");
            escape_attribute_into(&alt, output);
            output.push('"');
        }
        if let Some(src) = attribute(decoder, element, b"src")?
            && let Some(data_url) = image_data_url(
                chapter_path,
                &src,
                manifest,
                entries,
                archive,
                image_cache,
                total_image_size,
            )?
        {
            let projected_size = output
                .len()
                .checked_add(" src=\"\"".len())
                .and_then(|size| size.checked_add(data_url.len()))
                .ok_or_else(|| CoreError::limit("EPUB output size overflow"))?;
            ensure_output_limit(projected_size, output_limit)?;
            output.push_str(" src=\"");
            output.push_str(data_url.as_ref());
            output.push('"');
        }
    } else if name == b"td" || name == b"th" {
        for key in [b"colspan".as_slice(), b"rowspan".as_slice()] {
            if let Some(value) = attribute(decoder, element, key)?
                && value.parse::<u8>().is_ok_and(|number| number > 0)
            {
                output.push(' ');
                output.push_str(std::str::from_utf8(key).unwrap());
                output.push_str("=\"");
                output.push_str(&value);
                output.push('"');
            }
        }
    }
    output.push('>');
    Ok(())
}

fn rewrite_href(
    chapter_path: &str,
    chapter_index: usize,
    href: &str,
    chapter_paths: &HashMap<String, usize>,
) -> Result<Option<String>, CoreError> {
    if href.trim().is_empty() || is_external_reference(href) {
        return Ok(None);
    }
    let (path, fragment) = href.split_once('#').unwrap_or((href, ""));
    let fragment = percent_decode(fragment)?;
    if path.is_empty() {
        return Ok(
            (!fragment.is_empty()).then(|| format!("#glance-c{}-{fragment}", chapter_index + 1))
        );
    }
    let target = resolve_path(chapter_path, path)?;
    let Some(target_index) = chapter_paths.get(&target) else {
        return Ok(None);
    };
    if fragment.is_empty() {
        Ok(Some(format!("#glance-chapter-{}", target_index + 1)))
    } else {
        Ok(Some(format!("#glance-c{}-{fragment}", target_index + 1)))
    }
}

#[allow(clippy::too_many_arguments)]
fn image_data_url<R: Read + Seek>(
    chapter_path: &str,
    src: &str,
    manifest: &HashMap<String, ManifestItem>,
    entries: &HashMap<String, EntryIndex>,
    archive: &mut zip::ZipArchive<R>,
    cache: &mut HashMap<String, Arc<str>>,
    total_image_size: &mut u64,
) -> Result<Option<Arc<str>>, CoreError> {
    if src.trim().is_empty() || is_external_reference(src) || src.contains('#') {
        return Ok(None);
    }
    let path = resolve_path(chapter_path, src)?;
    if let Some(cached) = cache.get(&path) {
        return Ok(Some(cached.clone()));
    }
    let Some(item) = manifest.values().find(|item| item.path == path) else {
        return Ok(None);
    };
    let media_type = match item.media_type.as_str() {
        "image/png" | "image/jpeg" | "image/gif" | "image/webp" => item.media_type.as_str(),
        _ => return Ok(None),
    };
    let entry = entries
        .get(&path)
        .ok_or_else(|| CoreError::parse(format!("EPUB image is missing: {path}")))?;
    if entry.size > MAX_IMAGE_SIZE {
        return Err(CoreError::limit(format!(
            "EPUB image exceeds the {MAX_IMAGE_SIZE} byte preview limit"
        )));
    }
    *total_image_size = total_image_size
        .checked_add(entry.size)
        .ok_or_else(|| CoreError::limit("EPUB image size overflow"))?;
    if *total_image_size > MAX_TOTAL_IMAGE_SIZE {
        return Err(CoreError::limit(format!(
            "EPUB images exceed the {MAX_TOTAL_IMAGE_SIZE} byte preview limit"
        )));
    }
    let bytes = read_entry(archive, entry, MAX_IMAGE_SIZE, "EPUB image")?;
    let value: Arc<str> = format!(
        "data:{media_type};base64,{}",
        base64::engine::general_purpose::STANDARD.encode(bytes)
    )
    .into();
    cache.insert(path, value.clone());
    Ok(Some(value))
}

fn read_named_entry<R: Read + Seek>(
    archive: &mut zip::ZipArchive<R>,
    entries: &HashMap<String, EntryIndex>,
    name: &str,
    limit: u64,
    description: &str,
) -> Result<Vec<u8>, CoreError> {
    let entry = entries
        .get(name)
        .ok_or_else(|| CoreError::parse(format!("{description} entry is missing")))?;
    read_entry(archive, entry, limit, description)
}

fn read_entry<R: Read + Seek>(
    archive: &mut zip::ZipArchive<R>,
    indexed: &EntryIndex,
    limit: u64,
    description: &str,
) -> Result<Vec<u8>, CoreError> {
    if indexed.size > limit {
        return Err(CoreError::limit(format!("{description} is too large")));
    }
    let entry = archive
        .by_index(indexed.index)
        .map_err(crate::zip::map_zip_error)?;
    let mut bytes = Vec::with_capacity(indexed.size.min(1_048_576) as usize);
    entry
        .take(limit + 1)
        .read_to_end(&mut bytes)
        .map_err(|error| CoreError::io(format!("Could not read {description}: {error}")))?;
    if bytes.len() as u64 != indexed.size {
        return Err(CoreError::parse(format!(
            "{description} has an invalid size"
        )));
    }
    Ok(bytes)
}

fn resolve_path(base_file: &str, reference: &str) -> Result<String, CoreError> {
    if is_external_reference(reference) {
        return Err(CoreError::unsupported(
            "EPUB contains an external resource path",
        ));
    }
    let reference = reference.split('#').next().unwrap_or(reference);
    if reference.contains('?') {
        return Err(CoreError::unsupported(
            "EPUB resource paths with queries are not supported",
        ));
    }
    let decoded = percent_decode(reference)?;
    let parent = base_file.rsplit_once('/').map_or("", |(parent, _)| parent);
    let joined = if parent.is_empty() {
        decoded
    } else {
        format!("{parent}/{decoded}")
    };
    canonical_path(&joined)
}

fn canonical_path(path: &str) -> Result<String, CoreError> {
    if path.len() > MAX_PATH_LENGTH || path.contains('\0') || path.contains('\\') {
        return Err(CoreError::limit(
            "EPUB contains an invalid or oversized path",
        ));
    }
    if path.starts_with('/') || is_external_reference(path) {
        return Err(CoreError::unsupported(
            "EPUB contains an absolute or external path",
        ));
    }
    let mut components = Vec::new();
    for component in path.split('/') {
        match component {
            "" | "." => {}
            ".." => {
                if components.pop().is_none() {
                    return Err(CoreError::unsupported("EPUB path escapes the archive root"));
                }
            }
            value => components.push(value),
        }
        if components.len() > 128 {
            return Err(CoreError::limit("EPUB path is nested too deeply"));
        }
    }
    Ok(components.join("/"))
}

fn percent_decode(value: &str) -> Result<String, CoreError> {
    let bytes = value.as_bytes();
    let mut output = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' {
            let pair = bytes
                .get(index + 1..index + 3)
                .ok_or_else(|| CoreError::parse("EPUB path has malformed percent encoding"))?;
            let text = std::str::from_utf8(pair)
                .map_err(|_| CoreError::parse("EPUB path has malformed percent encoding"))?;
            output.push(
                u8::from_str_radix(text, 16)
                    .map_err(|_| CoreError::parse("EPUB path has malformed percent encoding"))?,
            );
            index += 3;
        } else {
            output.push(bytes[index]);
            index += 1;
        }
    }
    String::from_utf8(output).map_err(|_| CoreError::parse("EPUB path is not valid UTF-8"))
}

fn is_external_reference(value: &str) -> bool {
    let value = value.trim();
    if value.starts_with("//") {
        return true;
    }
    value.find(':').is_some_and(|colon| {
        value[..colon]
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'+' | b'-' | b'.'))
    })
}

fn allowed_tag(name: &[u8]) -> bool {
    matches!(
        name,
        b"a" | b"abbr"
            | b"article"
            | b"aside"
            | b"b"
            | b"blockquote"
            | b"br"
            | b"caption"
            | b"cite"
            | b"code"
            | b"dd"
            | b"del"
            | b"div"
            | b"dl"
            | b"dt"
            | b"em"
            | b"figcaption"
            | b"figure"
            | b"footer"
            | b"h1"
            | b"h2"
            | b"h3"
            | b"h4"
            | b"h5"
            | b"h6"
            | b"header"
            | b"hr"
            | b"i"
            | b"img"
            | b"li"
            | b"main"
            | b"mark"
            | b"nav"
            | b"ol"
            | b"p"
            | b"pre"
            | b"q"
            | b"rp"
            | b"rt"
            | b"ruby"
            | b"s"
            | b"section"
            | b"small"
            | b"span"
            | b"strong"
            | b"sub"
            | b"sup"
            | b"table"
            | b"tbody"
            | b"td"
            | b"tfoot"
            | b"th"
            | b"thead"
            | b"tr"
            | b"u"
            | b"ul"
    )
}

fn void_tag(name: &[u8]) -> bool {
    matches!(name, b"br" | b"hr" | b"img")
}

fn inside_metadata_field(stack: &[Vec<u8>], field: &[u8]) -> bool {
    stack.last().is_some_and(|name| name == field) && stack.iter().any(|name| name == b"metadata")
}

fn local_name(name: &[u8]) -> &[u8] {
    name.rsplit(|byte| *byte == b':').next().unwrap_or(name)
}

fn required_attribute(
    decoder: quick_xml::encoding::Decoder,
    element: &BytesStart<'_>,
    key: &[u8],
) -> Result<String, CoreError> {
    attribute(decoder, element, key)?.ok_or_else(|| {
        CoreError::parse(format!(
            "EPUB XML element is missing {}",
            String::from_utf8_lossy(key)
        ))
    })
}

fn attribute(
    decoder: quick_xml::encoding::Decoder,
    element: &BytesStart<'_>,
    key: &[u8],
) -> Result<Option<String>, CoreError> {
    for attribute in element.attributes().with_checks(true) {
        let attribute = attribute.map_err(|error| {
            CoreError::parse(format!("Could not parse EPUB XML attribute: {error}"))
        })?;
        if local_name(attribute.key.as_ref()) == key {
            return attribute
                .decoded_and_normalized_value(XmlVersion::Implicit1_0, decoder)
                .map(|value| Some(value.into_owned()))
                .map_err(|error| {
                    CoreError::parse(format!("Could not decode EPUB XML attribute: {error}"))
                });
        }
    }
    Ok(None)
}

fn decoded_text(text: &quick_xml::events::BytesText<'_>) -> Result<String, CoreError> {
    let decoded = text
        .decode()
        .map_err(|error| CoreError::parse(format!("Could not decode EPUB XML text: {error}")))?;
    quick_xml::escape::unescape(&decoded)
        .map(|value| value.into_owned())
        .map_err(|error| CoreError::parse(format!("Could not decode EPUB XML entity: {error}")))
}

fn predefined_entity(name: &[u8]) -> Result<&'static str, CoreError> {
    match name {
        b"amp" => Ok("&"),
        b"lt" => Ok("<"),
        b"gt" => Ok(">"),
        b"quot" => Ok("\""),
        b"apos" => Ok("'"),
        _ => Err(CoreError::unsupported(
            "EPUB contains an unsupported custom XML entity",
        )),
    }
}

fn check_depth(depth: usize) -> Result<(), CoreError> {
    if depth > MAX_ELEMENT_DEPTH {
        Err(CoreError::limit("EPUB XML is nested too deeply"))
    } else {
        Ok(())
    }
}

fn nonempty(value: String) -> Option<String> {
    let value = value.trim().to_owned();
    (!value.is_empty()).then_some(value)
}

fn escape_html_into(value: &str, output: &mut String) {
    for character in value.chars() {
        match character {
            '&' => output.push_str("&amp;"),
            '<' => output.push_str("&lt;"),
            '>' => output.push_str("&gt;"),
            _ => output.push(character),
        }
    }
}

fn escape_attribute_into(value: &str, output: &mut String) {
    for character in value.chars() {
        match character {
            '&' => output.push_str("&amp;"),
            '<' => output.push_str("&lt;"),
            '>' => output.push_str("&gt;"),
            '"' => output.push_str("&quot;"),
            '\'' => output.push_str("&#39;"),
            _ => output.push(character),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::sync::atomic::{AtomicU64, Ordering};
    use zip::write::SimpleFileOptions;

    static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(0);

    struct Fixture(std::path::PathBuf);

    impl Fixture {
        fn new(entries: &[(&str, &[u8])]) -> Self {
            let path = std::env::temp_dir().join(format!(
                "glance-epub-{}-{}.epub",
                std::process::id(),
                NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed)
            ));
            let file = File::create(&path).unwrap();
            let mut writer = zip::ZipWriter::new(file);
            for (name, contents) in entries {
                let options = if *name == "mimetype" {
                    SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored)
                } else {
                    SimpleFileOptions::default()
                        .compression_method(zip::CompressionMethod::Deflated)
                };
                writer.start_file(*name, options).unwrap();
                writer.write_all(contents).unwrap();
            }
            writer.finish().unwrap();
            Self(path)
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_file(&self.0);
        }
    }

    const CONTAINER: &[u8] = br#"<?xml version="1.0"?>
<container><rootfiles><rootfile full-path="OPS/package.opf"/></rootfiles></container>"#;

    fn epub(package: &[u8], chapters: &[(&str, &[u8])]) -> Fixture {
        let mut entries = vec![
            ("mimetype", b"application/epub+zip".as_slice()),
            ("META-INF/container.xml", CONTAINER),
            ("OPS/package.opf", package),
        ];
        entries.extend_from_slice(chapters);
        Fixture::new(&entries)
    }

    #[test]
    fn renders_epub3_metadata_spine_images_and_safe_internal_links() {
        let package = br#"<package version="3.0"><metadata><dc:title>Safe &amp; Offline</dc:title><dc:creator>Alice</dc:creator><dc:language>en</dc:language></metadata><manifest><item id="one" href="one.xhtml" media-type="application/xhtml+xml"/><item id="two" href="two.xhtml" media-type="application/xhtml+xml"/><item id="cover" href="cover.png" media-type="image/png"/></manifest><spine><itemref idref="one"/><itemref idref="two"/></spine></package>"#;
        let first = br#"<html><body><h2 id="start">One</h2><script>alert(1)</script><a href="two.xhtml#end" onclick="bad()">Next chapter</a><a href="https://example.com">external</a><img src="cover.png" alt="Cover" onerror="bad()"/></body></html>"#;
        let second =
            br#"<html><body><h2 id="end">Two</h2><a href="one.xhtml#start">Back</a></body></html>"#;
        let fixture = epub(
            package,
            &[
                ("OPS/one.xhtml", first),
                ("OPS/two.xhtml", second),
                ("OPS/cover.png", b"png"),
            ],
        );
        let html = render_epub(&fixture.0).unwrap();
        assert!(html.contains("Safe &amp; Offline"), "{html}");
        assert!(html.contains("Alice"));
        assert!(html.contains("href=\"#glance-c2-end\""));
        assert!(html.contains("src=\"data:image/png;base64,cG5n\""));
        assert!(!html.contains("script"));
        assert!(!html.contains("onclick"));
        assert!(!html.contains("https://"));
    }

    #[test]
    fn supports_epub2_and_skips_non_linear_spine_items() {
        let package = br#"<package version="2.0"><metadata><dc:title>EPUB Two</dc:title></metadata><manifest><item id="main" href="main.xhtml" media-type="application/xhtml+xml"/><item id="notes" href="notes.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="main"/><itemref idref="notes" linear="no"/></spine></package>"#;
        let fixture = epub(
            package,
            &[
                ("OPS/main.xhtml", b"<html><body><p>Main</p></body></html>"),
                ("OPS/notes.xhtml", b"<html><body><p>Notes</p></body></html>"),
            ],
        );
        let html = render_epub(&fixture.0).unwrap();
        assert!(html.contains("Main"));
        assert!(!html.contains("Notes"));
    }

    #[test]
    fn decodes_container_rootfile_paths_before_validating_them() {
        let empty = br#"<container><rootfiles><rootfile full-path="OPS/package%20file.opf"/></rootfiles></container>"#;
        assert_eq!(parse_container(empty).unwrap(), "OPS/package file.opf");

        let paired = br#"<container><rootfiles><rootfile full-path="OPS/package%20file.opf"></rootfile></rootfiles></container>"#;
        assert_eq!(parse_container(paired).unwrap(), "OPS/package file.opf");

        let traversal = br#"<container><rootfiles><rootfile full-path="OPS/%2e%2e/%2e%2e/package.opf"/></rootfiles></container>"#;
        assert!(parse_container(traversal).is_err());
    }

    #[test]
    fn enforces_output_budget_while_rendering_cached_images() {
        let package = br#"<package version="3.0"><metadata><dc:title>Book</dc:title></metadata><manifest><item id="main" href="main.xhtml" media-type="application/xhtml+xml"/><item id="image" href="image.png" media-type="image/png"/></manifest><spine><itemref idref="main"/></spine></package>"#;
        let images = "<img src=\"image.png\"/>".repeat(100);
        let chapter = format!("<html><body>{images}</body></html>");
        let fixture = epub(
            package,
            &[
                ("OPS/main.xhtml", chapter.as_bytes()),
                ("OPS/image.png", b"png"),
            ],
        );

        assert!(matches!(
            render_epub_with_output_limit(&fixture.0, 512),
            Err(CoreError::ResourceLimit(_))
        ));
    }

    #[test]
    fn rejects_drm_traversal_corruption_and_unsupported_versions() {
        let package = br#"<package version="3.0"><metadata><dc:title>Book</dc:title></metadata><manifest><item id="main" href="main.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="main"/></spine></package>"#;
        let drm = Fixture::new(&[
            ("mimetype", b"application/epub+zip"),
            ("META-INF/container.xml", CONTAINER),
            ("META-INF/encryption.xml", b"<encryption/>"),
            ("OPS/package.opf", package),
            ("OPS/main.xhtml", b"<html><body>Book</body></html>"),
        ]);
        assert!(matches!(
            render_epub(&drm.0),
            Err(CoreError::Unsupported(_))
        ));

        let traversal = epub(
            br#"<package version="3.0"><metadata><dc:title>Book</dc:title></metadata><manifest><item id="main" href="../../outside.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="main"/></spine></package>"#,
            &[],
        );
        assert!(matches!(
            render_epub(&traversal.0),
            Err(CoreError::Unsupported(_))
        ));

        let corrupt = Fixture::new(&[("mimetype", b"not-an-epub")]);
        assert!(render_epub(&corrupt.0).is_err());

        let unsupported = epub(
            br#"<package version="4.0"><metadata><dc:title>Book</dc:title></metadata><manifest><item id="main" href="main.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="main"/></spine></package>"#,
            &[("OPS/main.xhtml", b"<html><body>Book</body></html>")],
        );
        assert!(matches!(
            render_epub(&unsupported.0),
            Err(CoreError::Unsupported(_))
        ));
    }

    #[test]
    fn enforces_spine_chapter_image_and_xml_safety_limits() {
        let mut spine = String::new();
        for _ in 0..=MAX_CHAPTER_COUNT {
            spine.push_str("<itemref idref=\"main\"/>");
        }
        let package = format!(
            "<package version=\"3.0\"><metadata><dc:title>Book</dc:title></metadata><manifest><item id=\"main\" href=\"main.xhtml\" media-type=\"application/xhtml+xml\"/></manifest><spine>{spine}</spine></package>"
        );
        let fixture = epub(
            package.as_bytes(),
            &[("OPS/main.xhtml", b"<html><body>Book</body></html>")],
        );
        assert!(matches!(
            render_epub(&fixture.0),
            Err(CoreError::ResourceLimit(_))
        ));

        let package = br#"<package version="3.0"><metadata><dc:title>Book</dc:title></metadata><manifest><item id="main" href="main.xhtml" media-type="application/xhtml+xml"/><item id="large" href="large.png" media-type="image/png"/></manifest><spine><itemref idref="main"/></spine></package>"#;
        let large_image = vec![0_u8; MAX_IMAGE_SIZE as usize + 1];
        let fixture = epub(
            package,
            &[
                (
                    "OPS/main.xhtml",
                    b"<html><body><img src=\"large.png\"/></body></html>",
                ),
                ("OPS/large.png", &large_image),
            ],
        );
        assert!(matches!(
            render_epub(&fixture.0),
            Err(CoreError::ResourceLimit(_))
        ));

        let custom_entity = epub(
            br#"<package version="3.0"><metadata><dc:title>Book</dc:title></metadata><manifest><item id="main" href="main.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="main"/></spine></package>"#,
            &[("OPS/main.xhtml", b"<html><body>&custom;</body></html>")],
        );
        assert!(matches!(
            render_epub(&custom_entity.0),
            Err(CoreError::Unsupported(_))
        ));
    }
}
