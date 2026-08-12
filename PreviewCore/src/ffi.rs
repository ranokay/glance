use crate::error::{CoreError, RenderError};
use std::ffi::OsStr;
use std::os::unix::ffi::OsStrExt;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::Path;
use std::ptr;
use std::slice;
use std::str;

const STATUS_OK: i32 = 0;
const STATUS_INVALID_INPUT: i32 = 1;
const STATUS_PARSE_ERROR: i32 = 2;
const STATUS_INTERNAL_ERROR: i32 = 3;
const STATUS_IO_ERROR: i32 = 4;
const STATUS_RESOURCE_LIMIT: i32 = 5;
const STATUS_UNSUPPORTED: i32 = 6;

#[repr(C)]
pub struct GlanceRenderResult {
    pub data: *mut u8,
    pub length: usize,
    pub status: i32,
}

/// Renders source code supplied as UTF-8 bytes.
///
/// # Safety
///
/// Each non-null pointer must be valid for reads of its paired length for the duration of this
/// call. A null pointer is accepted only when its paired length is zero.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn glance_render_code(
    source_data: *const u8,
    source_length: usize,
    lexer_data: *const u8,
    lexer_length: usize,
) -> GlanceRenderResult {
    ffi_call(|| unsafe {
        let source = utf8_input(source_data, source_length)?;
        let lexer = utf8_input(lexer_data, lexer_length)?;
        crate::highlight::render_code(source, lexer)
            .map_err(CoreError::from)
            .map(String::into_bytes)
    })
}

/// Renders Markdown supplied as UTF-8 bytes.
///
/// # Safety
///
/// The pointer must be valid for reads of `source_length` bytes for the duration of this call. A
/// null pointer is accepted only when `source_length` is zero.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn glance_render_markdown(
    source_data: *const u8,
    source_length: usize,
) -> GlanceRenderResult {
    ffi_call(|| unsafe {
        let source = utf8_input(source_data, source_length)?;
        crate::markdown::render_markdown(source)
            .map_err(CoreError::from)
            .map(String::into_bytes)
    })
}

/// Renders a Jupyter notebook supplied as UTF-8 JSON bytes.
///
/// # Safety
///
/// The pointer must be valid for reads of `source_length` bytes for the duration of this call. A
/// null pointer is accepted only when `source_length` is zero.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn glance_render_notebook(
    source_data: *const u8,
    source_length: usize,
) -> GlanceRenderResult {
    ffi_call(|| unsafe {
        let source = utf8_input(source_data, source_length)?;
        crate::notebook::render_notebook(source)
            .map_err(CoreError::from)
            .map(String::into_bytes)
    })
}

/// Parses TSV bytes into a typed JSON payload.
///
/// # Safety
///
/// The pointer must be valid for reads of `data_length` bytes for the duration of this call. A
/// null pointer is accepted only when `data_length` is zero.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn glance_parse_tsv(
    data: *const u8,
    data_length: usize,
) -> GlanceRenderResult {
    ffi_call(|| unsafe {
        let data = byte_input(data, data_length, "TSV")?;
        json_bytes(&crate::tsv::parse_tsv(data)?)
    })
}

/// Scans a ZIP/JAR/EAR/WAR archive at a raw filesystem path into a typed JSON payload.
///
/// # Safety
///
/// The pointer must be valid for reads of `path_length` bytes for the duration of this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn glance_scan_zip(
    path_data: *const u8,
    path_length: usize,
) -> GlanceRenderResult {
    ffi_call(|| unsafe { json_bytes(&crate::zip::scan_zip(path_input(path_data, path_length)?)?) })
}

/// Scans a TAR or gzip-compressed TAR archive at a raw filesystem path.
///
/// # Safety
///
/// The pointer must be valid for reads of `path_length` bytes for the duration of this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn glance_scan_tar(
    path_data: *const u8,
    path_length: usize,
    is_gzipped: bool,
) -> GlanceRenderResult {
    ffi_call(|| unsafe {
        json_bytes(&crate::tar::scan_tar(
            path_input(path_data, path_length)?,
            is_gzipped,
        )?)
    })
}

/// Scans a 7z archive at a raw filesystem path into a typed JSON payload.
///
/// # Safety
///
/// The pointer must be valid for reads of `path_length` bytes for the duration of this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn glance_scan_seven_zip(
    path_data: *const u8,
    path_length: usize,
) -> GlanceRenderResult {
    ffi_call(|| unsafe {
        json_bytes(&crate::sevenzip::scan_seven_zip(path_input(
            path_data,
            path_length,
        )?)?)
    })
}

/// Releases a renderer result buffer.
///
/// # Safety
///
/// `data` and `length` must be the unchanged values returned together in one `GlanceRenderResult`.
/// Each non-null buffer may be released exactly once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn glance_render_buffer_free(data: *mut u8, length: usize) {
    if data.is_null() {
        return;
    }
    let slice = ptr::slice_from_raw_parts_mut(data, length);
    unsafe {
        drop(Box::from_raw(slice));
    }
}

fn ffi_call(operation: impl FnOnce() -> Result<Vec<u8>, CoreError>) -> GlanceRenderResult {
    match catch_unwind(AssertUnwindSafe(operation)) {
        Ok(Ok(output)) => result_from_bytes(output, STATUS_OK),
        Ok(Err(error)) => {
            let status = match error {
                CoreError::InvalidInput(_) => STATUS_INVALID_INPUT,
                CoreError::Parse(_) => STATUS_PARSE_ERROR,
                CoreError::Io(_) => STATUS_IO_ERROR,
                CoreError::ResourceLimit(_) => STATUS_RESOURCE_LIMIT,
                CoreError::Unsupported(_) => STATUS_UNSUPPORTED,
            };
            result_from_bytes(error.to_string().into_bytes(), status)
        }
        Err(_) => result_from_bytes(
            b"The Rust preview core stopped after an internal panic".to_vec(),
            STATUS_INTERNAL_ERROR,
        ),
    }
}

fn result_from_bytes(bytes: Vec<u8>, status: i32) -> GlanceRenderResult {
    if bytes.is_empty() {
        return GlanceRenderResult {
            data: ptr::null_mut(),
            length: 0,
            status,
        };
    }
    let mut bytes = bytes.into_boxed_slice();
    let result = GlanceRenderResult {
        data: bytes.as_mut_ptr(),
        length: bytes.len(),
        status,
    };
    std::mem::forget(bytes);
    result
}

unsafe fn utf8_input<'a>(data: *const u8, length: usize) -> Result<&'a str, CoreError> {
    let bytes = unsafe { byte_input(data, length, "Renderer")? };
    str::from_utf8(bytes)
        .map_err(|error| CoreError::invalid(format!("Renderer input is not valid UTF-8: {error}")))
}

unsafe fn byte_input<'a>(
    data: *const u8,
    length: usize,
    input_name: &str,
) -> Result<&'a [u8], CoreError> {
    if length == 0 {
        return Ok(&[]);
    }
    if data.is_null() {
        return Err(CoreError::invalid(format!(
            "{input_name} input pointer is null for a non-empty buffer"
        )));
    }
    Ok(unsafe { slice::from_raw_parts(data, length) })
}

unsafe fn path_input<'a>(data: *const u8, length: usize) -> Result<&'a Path, CoreError> {
    let bytes = unsafe { byte_input(data, length, "Archive path")? };
    if bytes.is_empty() {
        return Err(CoreError::invalid("Archive path must not be empty"));
    }
    if bytes.contains(&0) {
        return Err(CoreError::invalid("Archive path contains a null byte"));
    }
    Ok(Path::new(OsStr::from_bytes(bytes)))
}

fn json_bytes(value: &impl serde::Serialize) -> Result<Vec<u8>, CoreError> {
    serde_json::to_vec(value)
        .map_err(|error| CoreError::parse(format!("Could not encode preview payload: {error}")))
}

impl From<RenderError> for CoreError {
    fn from(error: RenderError) -> Self {
        Self::parse(error.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn take(result: GlanceRenderResult) -> (i32, String) {
        let output = if result.length == 0 {
            String::new()
        } else {
            let bytes = unsafe { slice::from_raw_parts(result.data, result.length) };
            String::from_utf8(bytes.to_vec()).unwrap()
        };
        unsafe { glance_render_buffer_free(result.data, result.length) };
        (result.status, output)
    }

    #[test]
    fn returns_and_frees_successful_buffers() {
        let input = b"# Heading";
        let result = unsafe { glance_render_markdown(input.as_ptr(), input.len()) };
        let (status, html) = take(result);
        assert_eq!(status, STATUS_OK);
        assert!(html.contains("<h1>Heading</h1>"));
    }

    #[test]
    fn validates_pointers_and_utf8() {
        let result = unsafe { glance_render_markdown(ptr::null(), 1) };
        let (status, message) = take(result);
        assert_eq!(status, STATUS_INVALID_INPUT);
        assert!(message.contains("null"));

        let invalid = [0xff];
        let result = unsafe { glance_render_markdown(invalid.as_ptr(), invalid.len()) };
        let (status, message) = take(result);
        assert_eq!(status, STATUS_INVALID_INPUT);
        assert!(message.contains("UTF-8"));

        let malformed_notebook = b"not json";
        let result = unsafe {
            glance_render_notebook(malformed_notebook.as_ptr(), malformed_notebook.len())
        };
        let (status, message) = take(result);
        assert_eq!(status, STATUS_PARSE_ERROR);
        assert!(message.contains("notebook JSON"));
    }

    #[test]
    fn accepts_empty_buffers() {
        let result = unsafe { glance_render_markdown(ptr::null(), 0) };
        let (status, html) = take(result);
        assert_eq!(status, STATUS_OK);
        assert!(html.is_empty());

        unsafe { glance_render_buffer_free(ptr::null_mut(), 0) };
    }

    #[test]
    fn parses_tsv_and_validates_archive_paths() {
        let input = b"name\tvalue\nhello\tworld\n";
        let result = unsafe { glance_parse_tsv(input.as_ptr(), input.len()) };
        let (status, json) = take(result);
        assert_eq!(status, STATUS_OK);
        assert!(json.contains("\"headers\":[\"name\",\"value\"]"));

        let result = unsafe { glance_scan_zip(ptr::null(), 1) };
        let (status, message) = take(result);
        assert_eq!(status, STATUS_INVALID_INPUT);
        assert!(message.contains("null"));

        let result = unsafe { glance_scan_tar(ptr::null(), 0, false) };
        let (status, message) = take(result);
        assert_eq!(status, STATUS_INVALID_INPUT);
        assert!(message.contains("must not be empty"));
    }

    #[test]
    fn reports_every_error_status_without_unwinding() {
        let malformed = b"name\tvalue\nmissing\n";
        let result = unsafe { glance_parse_tsv(malformed.as_ptr(), malformed.len()) };
        assert_eq!(take(result).0, STATUS_PARSE_ERROR);

        let oversized = vec![b'a'; crate::tsv::MAX_FILE_SIZE + 1];
        let result = unsafe { glance_parse_tsv(oversized.as_ptr(), oversized.len()) };
        assert_eq!(take(result).0, STATUS_RESOURCE_LIMIT);

        let missing = Path::new("/definitely/missing/glance-preview.zip");
        let missing_bytes = missing.as_os_str().as_bytes();
        let result = unsafe { glance_scan_zip(missing_bytes.as_ptr(), missing_bytes.len()) };
        assert_eq!(take(result).0, STATUS_IO_ERROR);

        let encrypted = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../GlanceTests/TestFiles/archives/encrypted.7z");
        let encrypted_bytes = encrypted.as_os_str().as_bytes();
        let result =
            unsafe { glance_scan_seven_zip(encrypted_bytes.as_ptr(), encrypted_bytes.len()) };
        assert_eq!(take(result).0, STATUS_UNSUPPORTED);

        let result = ffi_call(|| panic!("FFI panic test"));
        let (status, message) = take(result);
        assert_eq!(status, STATUS_INTERNAL_ERROR);
        assert!(message.contains("internal panic"));
    }
}
