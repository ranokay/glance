use crate::error::CoreError;
use serde::Serialize;
use std::cell::Cell;
use std::ffi::{CStr, CString, c_char, c_int, c_uchar, c_void};
use std::fmt::Write as _;
use std::fs;
use std::io::{Read, Write};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::ptr;
use std::slice;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const SQLITE_OK: c_int = 0;
const SQLITE_ROW: c_int = 100;
const SQLITE_DONE: c_int = 101;
const SQLITE_OPEN_READONLY: c_int = 0x0000_0001;
const SQLITE_OPEN_READWRITE: c_int = 0x0000_0002;
const SQLITE_OPEN_URI: c_int = 0x0000_0040;
const SQLITE_LIMIT_LENGTH: c_int = 0;
const SQLITE_DBCONFIG_TRUSTED_SCHEMA: c_int = 1017;
const PROGRESS_INSTRUCTIONS: c_int = 10_000;
const QUERY_DEADLINE: Duration = Duration::from_secs(5);

const SQLITE_HEADER: &[u8; 16] = b"SQLite format 3\0";

const TABLES_PER_PREVIEW: usize = 200;
const COLUMNS_PER_PAGE: usize = 64;
const ROWS_PER_PAGE: usize = 50;
const CELL_BYTES: usize = 256;
const PAGE_BYTES: usize = 1_000_000;
const TABLE_NAME_BYTES: usize = 64 * 1_024;
const LABEL_BYTES: usize = 256;
const COPY_BYTES: u64 = 512 * 1_024 * 1_024;
const COPY_ATTEMPTS: usize = 3;

/// Per-value memory bound for SQLite itself. `substr()` still materializes the
/// whole value before slicing it, so this stops a single crafted cell or
/// generated-column expression from allocating unbounded memory.
const SQL_LENGTH_LIMIT: c_int = 4 * 1_024 * 1_024;

#[derive(Debug, PartialEq, Serialize)]
pub(crate) struct SqlitePayload {
    pub tables: Vec<String>,
    pub tables_truncated: bool,
    pub table: Option<SqliteTable>,
}

#[derive(Debug, PartialEq, Serialize)]
pub(crate) struct SqliteTable {
    pub name: String,
    pub columns: Vec<SqliteColumn>,
    pub columns_truncated: bool,
    pub virtual_columns_omitted: bool,
    pub rows: Vec<Vec<SqliteCell>>,
    pub offset: u64,
    pub has_more: bool,
    pub page_truncated: bool,
    pub values_truncated: bool,
}

#[derive(Debug, PartialEq, Serialize)]
pub(crate) struct SqliteColumn {
    pub name: String,
    pub declared_type: Option<String>,
}

#[derive(Debug, PartialEq, Serialize)]
pub(crate) struct SqliteCell {
    pub kind: SqliteCellKind,
    pub text: String,
    pub truncated: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub byte_count: Option<u64>,
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum SqliteCellKind {
    Null,
    Integer,
    Real,
    Text,
    Blob,
}

impl SqliteCell {
    fn empty(kind: SqliteCellKind) -> Self {
        Self {
            kind,
            text: String::new(),
            truncated: false,
            byte_count: None,
        }
    }

    fn blob(byte_count: u64) -> Self {
        Self {
            byte_count: Some(byte_count),
            ..Self::empty(SqliteCellKind::Blob)
        }
    }

    fn text(kind: SqliteCellKind, text: String, truncated: bool) -> Self {
        Self {
            kind,
            text,
            truncated,
            byte_count: None,
        }
    }

    /// Approximate serialized size, including JSON punctuation and escaping headroom.
    fn estimated_bytes(&self) -> usize {
        self.text.len() * 2 + 64
    }
}

impl SqliteCellKind {
    fn from_typeof(value: &str) -> Self {
        match value {
            "null" => Self::Null,
            "integer" => Self::Integer,
            "real" => Self::Real,
            "blob" => Self::Blob,
            _ => Self::Text,
        }
    }
}

#[derive(Clone, Copy)]
struct Limits {
    max_tables: usize,
    max_columns: usize,
    rows_per_page: usize,
    max_cell_bytes: usize,
    max_page_bytes: usize,
    max_table_name_bytes: usize,
    max_copy_bytes: u64,
}

const DEFAULT_LIMITS: Limits = Limits {
    max_tables: TABLES_PER_PREVIEW,
    max_columns: COLUMNS_PER_PAGE,
    rows_per_page: ROWS_PER_PAGE,
    max_cell_bytes: CELL_BYTES,
    max_page_bytes: PAGE_BYTES,
    max_table_name_bytes: TABLE_NAME_BYTES,
    max_copy_bytes: COPY_BYTES,
};

/// Reads one page of a SQLite database. `table` selects a listed table; an
/// unknown or missing name falls back to the first table.
pub(crate) fn parse_sqlite(
    path: &Path,
    table: Option<&str>,
    offset: u64,
) -> Result<SqlitePayload, CoreError> {
    parse_sqlite_with_limits(path, table, offset, DEFAULT_LIMITS)
}

fn parse_sqlite_with_limits(
    path: &Path,
    requested_table: Option<&str>,
    offset: u64,
    limits: Limits,
) -> Result<SqlitePayload, CoreError> {
    validate_header(path)?;
    let database = Database::open(path, &limits)?;
    database.connection.start_deadline();
    let (tables, tables_truncated) = read_tables(&database.connection, &limits)?;
    let selected = requested_table
        .and_then(|requested| tables.iter().find(|name| *name == requested))
        .or_else(|| tables.first())
        .cloned();
    let table = match selected {
        Some(name) => Some(read_table(&database.connection, &name, offset, &limits)?),
        None => None,
    };
    Ok(SqlitePayload {
        tables,
        tables_truncated,
        table,
    })
}

fn validate_header(path: &Path) -> Result<(), CoreError> {
    let mut file = fs::File::open(path)
        .map_err(|error| CoreError::io(format!("Could not open SQLite database: {error}")))?;
    let mut header = [0_u8; 16];
    if file.read_exact(&mut header).is_err() || &header != SQLITE_HEADER {
        return Err(CoreError::parse(
            "The file is not a SQLite database: the header is missing or unrecognized",
        ));
    }
    Ok(())
}

/// A preview connection and the temporary copy it may read from. The
/// connection is dropped before the temporary directory.
struct Database {
    connection: Connection,
    _temporary: Option<TemporaryCopy>,
}

impl Database {
    fn open(path: &Path, limits: &Limits) -> Result<Self, CoreError> {
        // A WAL sidecar holds committed data, so an immutable read of the main
        // file alone would be stale. Copy the database and its WAL into the
        // temporary directory and let SQLite recover the copy there. A live
        // checkpoint can change both files between the copies, so retry the
        // whole decision instead of pairing mismatched versions.
        for _ in 0..COPY_ATTEMPTS {
            if !has_wal_sidecar(path) {
                return Ok(Self {
                    connection: open_connection(path, true)?,
                    _temporary: None,
                });
            }
            match copy_with_wal(path, limits.max_copy_bytes)? {
                Some(temporary) => {
                    let connection = open_connection(&temporary.database_path, false)?;
                    return Ok(Self {
                        connection,
                        _temporary: Some(temporary),
                    });
                }
                None => continue,
            }
        }
        Err(CoreError::parse(
            "SQLite database changed while preparing the preview; try again",
        ))
    }
}

fn has_wal_sidecar(path: &Path) -> bool {
    sidecar_path(path, "-wal").exists()
}

fn sidecar_path(path: &Path, suffix: &str) -> PathBuf {
    let mut name = path.as_os_str().to_os_string();
    name.push(suffix);
    PathBuf::from(name)
}

struct TemporaryCopy {
    directory: PathBuf,
    database_path: PathBuf,
}

impl Drop for TemporaryCopy {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.directory);
    }
}

fn copy_with_wal(path: &Path, max_copy_bytes: u64) -> Result<Option<TemporaryCopy>, CoreError> {
    let wal_path = sidecar_path(path, "-wal");
    let Some(before) = SnapshotSignature::read(path)? else {
        return Ok(None);
    };
    if before.total_bytes() > max_copy_bytes {
        return Err(copy_limit_error(max_copy_bytes));
    }

    let directory = create_temporary_directory()?;
    let database_path = match copy_snapshot(path, &wal_path, &directory, max_copy_bytes) {
        Ok(database_path) => database_path,
        Err(CopyFailure::Changed) => {
            let _ = fs::remove_dir_all(&directory);
            return Ok(None);
        }
        Err(CopyFailure::Budget) => {
            let _ = fs::remove_dir_all(&directory);
            return Err(copy_limit_error(max_copy_bytes));
        }
        Err(CopyFailure::Io(error)) => {
            let _ = fs::remove_dir_all(&directory);
            return Err(CoreError::io(format!(
                "Could not copy SQLite database for preview: {error}"
            )));
        }
    };

    // A checkpoint can rewrite the main file or reset the WAL while the copy
    // is in flight. Only keep the copy when both files are unchanged.
    if SnapshotSignature::read(path)?.as_ref() != Some(&before) {
        let _ = fs::remove_dir_all(&directory);
        return Ok(None);
    }
    Ok(Some(TemporaryCopy {
        directory,
        database_path,
    }))
}

fn copy_limit_error(max_copy_bytes: u64) -> CoreError {
    CoreError::limit(format!(
        "SQLite database with a WAL sidecar exceeds the {} MB preview limit",
        max_copy_bytes / (1_024 * 1_024)
    ))
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct FileSignature {
    length: u64,
    modified: Option<SystemTime>,
    inode: u64,
}

impl FileSignature {
    fn read(path: &Path) -> std::io::Result<Self> {
        let metadata = fs::metadata(path)?;
        Ok(Self {
            length: metadata.len(),
            modified: metadata.modified().ok(),
            inode: metadata.ino(),
        })
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct SnapshotSignature {
    database: FileSignature,
    wal: FileSignature,
}

impl SnapshotSignature {
    fn read(path: &Path) -> Result<Option<Self>, CoreError> {
        let database = FileSignature::read(path).map_err(|error| {
            CoreError::io(format!("Could not inspect SQLite database: {error}"))
        })?;
        let wal = match FileSignature::read(&sidecar_path(path, "-wal")) {
            Ok(wal) => wal,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => {
                return Err(CoreError::io(format!(
                    "Could not inspect SQLite WAL: {error}"
                )));
            }
        };
        Ok(Some(Self { database, wal }))
    }

    fn total_bytes(&self) -> u64 {
        self.database.length.saturating_add(self.wal.length)
    }
}

enum CopyFailure {
    Changed,
    Budget,
    Io(std::io::Error),
}

fn copy_snapshot(
    path: &Path,
    wal_path: &Path,
    directory: &Path,
    max_bytes: u64,
) -> Result<PathBuf, CopyFailure> {
    let file_name = path.file_name().ok_or_else(|| {
        CopyFailure::Io(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "SQLite database path has no file name",
        ))
    })?;
    let database_path = directory.join(file_name);
    let mut remaining = max_bytes;
    copy_bounded(path, &database_path, &mut remaining)?;
    let wal_copy = sidecar_path(&database_path, "-wal");
    copy_bounded(wal_path, &wal_copy, &mut remaining)?;

    // A source may be read-only, but SQLite needs to recover the WAL in the
    // copy. Only the copies change permissions.
    for candidate in [&database_path, &wal_copy] {
        let mut permissions = fs::metadata(candidate)
            .map_err(CopyFailure::Io)?
            .permissions();
        permissions.set_mode(0o600);
        fs::set_permissions(candidate, permissions).map_err(CopyFailure::Io)?;
    }
    Ok(database_path)
}

/// Copies with a shared byte budget so a file that grows after the initial
/// size check cannot consume more temporary space than advertised.
fn copy_bounded(source: &Path, target: &Path, remaining: &mut u64) -> Result<(), CopyFailure> {
    let mut input = fs::File::open(source).map_err(|error| {
        if error.kind() == std::io::ErrorKind::NotFound {
            CopyFailure::Changed
        } else {
            CopyFailure::Io(error)
        }
    })?;
    let mut output = fs::File::create(target).map_err(CopyFailure::Io)?;
    let mut buffer = vec![0_u8; 64 * 1_024];
    loop {
        let read = input.read(&mut buffer).map_err(CopyFailure::Io)?;
        if read == 0 {
            return Ok(());
        }
        let read = read as u64;
        if read > *remaining {
            return Err(CopyFailure::Budget);
        }
        output
            .write_all(&buffer[..read as usize])
            .map_err(CopyFailure::Io)?;
        *remaining -= read;
    }
}

fn create_temporary_directory() -> Result<PathBuf, CoreError> {
    let base = std::env::temp_dir();
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or(0);
    for attempt in 0..100 {
        let name = format!("glance-sqlite-{}-{nanos}-{attempt}", std::process::id());
        let directory = base.join(name);
        match fs::create_dir(&directory) {
            Ok(()) => return Ok(directory),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => {
                return Err(CoreError::io(format!(
                    "Could not create a temporary SQLite preview directory: {error}"
                )));
            }
        }
    }
    Err(CoreError::io(
        "Could not create a unique temporary SQLite preview directory",
    ))
}

fn open_connection(path: &Path, immutable: bool) -> Result<Connection, CoreError> {
    let filename = if immutable {
        sqlite_uri(path)?
    } else {
        CString::new(path.as_os_str().as_bytes())
            .map_err(|_| CoreError::invalid("SQLite database path contains a null byte"))?
    };
    let flags = if immutable {
        SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
    } else {
        SQLITE_OPEN_READWRITE
    };
    let mut handle = ptr::null_mut();
    let status = unsafe { sqlite3_open_v2(filename.as_ptr(), &mut handle, flags, ptr::null()) };
    if status != SQLITE_OK {
        let message = if handle.is_null() {
            format!("SQLite error code {status}")
        } else {
            let message = error_message(handle);
            unsafe { sqlite3_close_v2(handle) };
            message
        };
        return Err(CoreError::parse(format!(
            "Could not open SQLite database: {message}"
        )));
    }
    let mut trusted_schema: c_int = 0;
    let deadline = Box::new(ProgressDeadline {
        expires: Cell::new(None),
    });
    unsafe {
        sqlite3_limit(handle, SQLITE_LIMIT_LENGTH, SQL_LENGTH_LIMIT);
        sqlite3_db_config(
            handle,
            SQLITE_DBCONFIG_TRUSTED_SCHEMA,
            0 as c_int,
            &mut trusted_schema as *mut c_int,
        );
        sqlite3_progress_handler(
            handle,
            PROGRESS_INSTRUCTIONS,
            Some(progress_callback),
            &*deadline as *const ProgressDeadline as *mut c_void,
        );
    }
    Ok(Connection(handle, deadline))
}

/// Builds a `file:` URI with the original path bytes percent-encoded. The
/// immutable flag keeps SQLite from creating `-wal`, `-shm`, or journal files
/// next to the user's database.
fn sqlite_uri(path: &Path) -> Result<CString, CoreError> {
    let mut uri = String::from("file:");
    for &byte in path.as_os_str().as_bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' | b'/' => {
                uri.push(byte as char);
            }
            _ => {
                let _ = write!(uri, "%{byte:02X}");
            }
        }
    }
    uri.push_str("?immutable=1");
    CString::new(uri).map_err(|_| CoreError::invalid("SQLite URI contains a null byte"))
}

fn read_tables(database: &Connection, limits: &Limits) -> Result<(Vec<String>, bool), CoreError> {
    // rootpage 0 marks virtual tables, which are out of scope.
    let statement = prepare(
        database,
        "SELECT name FROM sqlite_master \
         WHERE type = 'table' AND rootpage != 0 AND substr(name, 1, 7) != 'sqlite_' \
         ORDER BY name LIMIT ?1",
    )?;
    let limit = limits.max_tables.saturating_add(1);
    bind_int64(
        database,
        &statement,
        1,
        i64::try_from(limit).unwrap_or(i64::MAX),
    )?;

    let mut tables = Vec::new();
    let mut name_bytes = 0_usize;
    let mut truncated = false;
    while let SQLITE_ROW = step(database, &statement)? {
        if tables.len() >= limits.max_tables {
            truncated = true;
            break;
        }
        let name = column_text(&statement, 0);
        if name_bytes.saturating_add(name.len()) > limits.max_table_name_bytes {
            truncated = true;
            break;
        }
        name_bytes += name.len();
        tables.push(name);
    }
    Ok((tables, truncated))
}

fn read_columns(
    database: &Connection,
    table: &str,
    limits: &Limits,
) -> Result<(Vec<SqliteColumn>, Vec<String>, bool, bool), CoreError> {
    let statement = prepare(
        database,
        &format!("PRAGMA table_xinfo({})", quote_identifier(table)),
    )?;
    let mut columns = Vec::new();
    let mut column_names = Vec::new();
    let mut truncated = false;
    let mut virtual_columns_omitted = false;
    while let SQLITE_ROW = step(database, &statement)? {
        let position = unsafe { sqlite3_column_int64(statement.0, 0) };
        let raw_name = column_text(&statement, 1);
        let hidden = unsafe { sqlite3_column_int64(statement.0, 6) };
        // Virtual generated columns evaluate database-defined expressions on
        // every read, so they are omitted before they can run. Stored
        // generated columns are ordinary record values and remain available.
        if hidden == 1 || hidden == 2 {
            virtual_columns_omitted |= hidden == 2;
            continue;
        }
        if columns.len() >= limits.max_columns {
            truncated = true;
            continue;
        }
        let display_name = if raw_name.is_empty() {
            format!("unnamed column {}", position + 1)
        } else {
            raw_name.clone()
        };
        let declared_type = {
            let value = column_text(&statement, 2);
            if value.is_empty() {
                None
            } else {
                Some(clip_label(&value))
            }
        };
        columns.push(SqliteColumn {
            name: clip_label(&display_name),
            declared_type,
        });
        column_names.push(raw_name);
    }
    Ok((columns, column_names, truncated, virtual_columns_omitted))
}

fn read_table(
    database: &Connection,
    table: &str,
    offset: u64,
    limits: &Limits,
) -> Result<SqliteTable, CoreError> {
    let quoted_table = quote_identifier(table);
    let (columns, column_names, columns_truncated, virtual_columns_omitted) =
        read_columns(database, table, limits)?;
    let retained_columns = columns.len();

    let mut values_truncated = false;
    let mut rows = Vec::new();
    let mut has_more = false;
    let mut page_truncated = false;
    if retained_columns > 0 {
        // One extra character detects whether more text exists without
        // scanning a whole cell.
        let value_prefix_chars = limits.max_cell_bytes.saturating_add(1);
        let mut sql = String::from("SELECT ");
        for (index, name) in column_names.iter().enumerate() {
            if index > 0 {
                sql.push_str(", ");
            }
            let quoted = quote_identifier(name);
            // BLOBs only need their byte count; text is read as a bounded
            // prefix. SQLite materializes the source value before substr()
            // slices it, so SQLITE_LIMIT_LENGTH is the actual memory bound.
            let _ = write!(
                sql,
                "typeof({quoted}), \
                 CASE WHEN typeof({quoted}) = 'blob' THEN length({quoted}) ELSE 0 END, \
                 CASE WHEN typeof({quoted}) = 'blob' THEN NULL \
                 ELSE substr({quoted}, 1, {value_prefix_chars}) END"
            );
        }
        let order = row_order(database, table)?;
        let _ = write!(
            sql,
            " FROM {quoted_table} {order} LIMIT {} OFFSET ?1",
            limits.rows_per_page.saturating_add(1)
        );
        let statement = prepare(database, &sql)?;
        bind_int64(
            database,
            &statement,
            1,
            i64::try_from(offset).unwrap_or(i64::MAX),
        )?;

        let mut rendered_bytes = 0_usize;
        while let SQLITE_ROW = step(database, &statement)? {
            if rows.len() >= limits.rows_per_page {
                has_more = true;
                break;
            }
            let mut row = Vec::with_capacity(retained_columns);
            let mut row_bytes = 0_usize;
            for index in 0..retained_columns {
                let base = c_int::try_from(index * 3).unwrap_or(c_int::MAX);
                let kind = SqliteCellKind::from_typeof(&column_text(&statement, base));
                let blob_bytes = unsafe { sqlite3_column_int64(statement.0, base + 1) };
                let cell = match kind {
                    SqliteCellKind::Null => SqliteCell::empty(kind),
                    SqliteCellKind::Blob => {
                        SqliteCell::blob(u64::try_from(blob_bytes).unwrap_or(0))
                    }
                    SqliteCellKind::Integer | SqliteCellKind::Real | SqliteCellKind::Text => {
                        let value = column_text(&statement, base + 2);
                        let (text, clipped) = clip_bytes(&value, limits.max_cell_bytes);
                        let truncated = clipped || value.chars().count() >= value_prefix_chars;
                        SqliteCell::text(
                            kind,
                            if truncated {
                                format!("{text}…")
                            } else {
                                text
                            },
                            truncated,
                        )
                    }
                };
                values_truncated |= cell.truncated;
                row_bytes = row_bytes.saturating_add(cell.estimated_bytes());
                row.push(cell);
            }
            if !rows.is_empty() && rendered_bytes.saturating_add(row_bytes) > limits.max_page_bytes
            {
                has_more = true;
                page_truncated = true;
                break;
            }
            rendered_bytes = rendered_bytes.saturating_add(row_bytes);
            rows.push(row);
        }
    }

    Ok(SqliteTable {
        name: table.to_owned(),
        columns,
        columns_truncated,
        virtual_columns_omitted,
        rows,
        offset,
        has_more,
        page_truncated,
        values_truncated,
    })
}

/// Rowid tables have no inherent page order, so every page sorts by the
/// primary key, or by the implicit rowid when there is none. WITHOUT ROWID
/// tables always have a primary key, so they never reach the rowid fallback.
fn row_order(database: &Connection, table: &str) -> Result<String, CoreError> {
    let statement = prepare(
        database,
        &format!("PRAGMA table_info({})", quote_identifier(table)),
    )?;
    let mut keys = Vec::new();
    while let SQLITE_ROW = step(database, &statement)? {
        let position = unsafe { sqlite3_column_int64(statement.0, 5) };
        if position > 0 {
            keys.push((position, column_text(&statement, 1)));
        }
    }
    if keys.is_empty() {
        return Ok("ORDER BY _rowid_".to_owned());
    }
    keys.sort_by_key(|(position, _)| *position);
    let columns = keys
        .iter()
        .map(|(_, name)| quote_identifier(name))
        .collect::<Vec<_>>()
        .join(", ");
    Ok(format!("ORDER BY {columns}"))
}

fn clip_label(value: &str) -> String {
    let (text, truncated) = clip_bytes(value, LABEL_BYTES);
    if truncated {
        format!("{text}…")
    } else {
        text
    }
}

/// Clips at a UTF-8 boundary without splitting a character.
fn clip_bytes(value: &str, max_bytes: usize) -> (String, bool) {
    let mut text = String::new();
    for character in value.chars() {
        let character = if character.is_control() && character != '\n' && character != '\t' {
            ' '
        } else {
            character
        };
        if text.len() + character.len_utf8() > max_bytes {
            return (text, true);
        }
        text.push(character);
    }
    (text, false)
}

fn quote_identifier(name: &str) -> String {
    let mut quoted = String::with_capacity(name.len() + 2);
    quoted.push('"');
    for character in name.chars() {
        if character == '"' {
            quoted.push('"');
        }
        quoted.push(character);
    }
    quoted.push('"');
    quoted
}

fn prepare(database: &Connection, sql: &str) -> Result<Statement, CoreError> {
    let sql =
        CString::new(sql).map_err(|_| CoreError::invalid("SQLite query contains a null byte"))?;
    let mut statement = ptr::null_mut();
    let status = unsafe {
        sqlite3_prepare_v2(
            database.0,
            sql.as_ptr(),
            -1,
            &mut statement,
            ptr::null_mut(),
        )
    };
    if status != SQLITE_OK {
        return Err(database.read_error());
    }
    if statement.is_null() {
        return Err(CoreError::parse(
            "Could not read SQLite database: empty statement",
        ));
    }
    Ok(Statement(statement))
}

fn bind_int64(
    database: &Connection,
    statement: &Statement,
    index: c_int,
    value: i64,
) -> Result<(), CoreError> {
    let status = unsafe { sqlite3_bind_int64(statement.0, index, value) };
    if status != SQLITE_OK {
        return Err(database.read_error());
    }
    Ok(())
}

fn step(database: &Connection, statement: &Statement) -> Result<c_int, CoreError> {
    let status = unsafe { sqlite3_step(statement.0) };
    if status == SQLITE_ROW || status == SQLITE_DONE {
        return Ok(status);
    }
    Err(database.read_error())
}

fn column_text(statement: &Statement, index: c_int) -> String {
    let pointer = unsafe { sqlite3_column_text(statement.0, index) };
    if pointer.is_null() {
        return String::new();
    }
    let length = unsafe { sqlite3_column_bytes(statement.0, index) }.max(0) as usize;
    let bytes = unsafe { slice::from_raw_parts(pointer, length) };
    String::from_utf8_lossy(bytes).into_owned()
}

fn error_message(database: *mut Sqlite3) -> String {
    let pointer = unsafe { sqlite3_errmsg(database) };
    if pointer.is_null() {
        return "unknown SQLite error".to_owned();
    }
    unsafe { CStr::from_ptr(pointer) }
        .to_string_lossy()
        .into_owned()
}

struct Connection(*mut Sqlite3, Box<ProgressDeadline>);

impl Connection {
    fn start_deadline(&self) {
        self.1.set();
    }

    fn read_error(&self) -> CoreError {
        if self.1.expired() {
            return CoreError::limit("SQLite preview timed out while reading the database");
        }
        CoreError::parse(format!(
            "Could not read SQLite database: {}",
            error_message(self.0)
        ))
    }
}

impl Drop for Connection {
    fn drop(&mut self) {
        unsafe {
            sqlite3_progress_handler(self.0, 0, None, ptr::null_mut());
            sqlite3_close_v2(self.0);
        }
    }
}

struct ProgressDeadline {
    expires: Cell<Option<Instant>>,
}

impl ProgressDeadline {
    fn set(&self) {
        self.expires.set(Some(Instant::now() + QUERY_DEADLINE));
    }

    fn expired(&self) -> bool {
        self.expires
            .get()
            .is_some_and(|deadline| Instant::now() >= deadline)
    }
}

unsafe extern "C" fn progress_callback(argument: *mut c_void) -> c_int {
    let deadline = unsafe { &*(argument as *const ProgressDeadline) };
    if deadline.expired() { 1 } else { 0 }
}

struct Statement(*mut Sqlite3Stmt);

impl Drop for Statement {
    fn drop(&mut self) {
        unsafe {
            sqlite3_finalize(self.0);
        }
    }
}

#[repr(C)]
struct Sqlite3 {
    _private: [u8; 0],
}

#[repr(C)]
struct Sqlite3Stmt {
    _private: [u8; 0],
}

#[link(name = "sqlite3")]
unsafe extern "C" {
    fn sqlite3_open_v2(
        filename: *const c_char,
        database: *mut *mut Sqlite3,
        flags: c_int,
        vfs: *const c_char,
    ) -> c_int;
    fn sqlite3_close_v2(database: *mut Sqlite3) -> c_int;
    fn sqlite3_errmsg(database: *mut Sqlite3) -> *const c_char;
    fn sqlite3_limit(database: *mut Sqlite3, id: c_int, new_value: c_int) -> c_int;
    fn sqlite3_db_config(database: *mut Sqlite3, op: c_int, ...) -> c_int;
    fn sqlite3_progress_handler(
        database: *mut Sqlite3,
        instructions: c_int,
        callback: Option<unsafe extern "C" fn(*mut c_void) -> c_int>,
        argument: *mut c_void,
    );
    fn sqlite3_prepare_v2(
        database: *mut Sqlite3,
        sql: *const c_char,
        length: c_int,
        statement: *mut *mut Sqlite3Stmt,
        tail: *mut *const c_char,
    ) -> c_int;
    fn sqlite3_step(statement: *mut Sqlite3Stmt) -> c_int;
    fn sqlite3_finalize(statement: *mut Sqlite3Stmt) -> c_int;
    fn sqlite3_bind_int64(statement: *mut Sqlite3Stmt, index: c_int, value: i64) -> c_int;
    fn sqlite3_column_text(statement: *mut Sqlite3Stmt, index: c_int) -> *const c_uchar;
    fn sqlite3_column_bytes(statement: *mut Sqlite3Stmt, index: c_int) -> c_int;
    fn sqlite3_column_int64(statement: *mut Sqlite3Stmt, index: c_int) -> i64;
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;
    use std::ffi::OsString;

    fn fixture() -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../GlanceTests/TestFiles/sqlite/example.sqlite")
    }

    fn temporary_directory(name: &str) -> PathBuf {
        let directory = std::env::temp_dir().join(format!(
            "glance-sqlite-test-{name}-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir(&directory).unwrap();
        directory
    }

    fn snapshot(directory: &Path) -> BTreeMap<OsString, Vec<u8>> {
        fs::read_dir(directory)
            .unwrap()
            .map(|entry| {
                let entry = entry.unwrap();
                (
                    entry.file_name(),
                    fs::read(entry.path()).unwrap_or_default(),
                )
            })
            .collect()
    }

    fn receiver() -> PathBuf {
        let directory = temporary_directory("read-only");
        let path = directory.join("example.sqlite");
        fs::copy(fixture(), &path).unwrap();
        path
    }

    #[test]
    fn lists_tables_and_excludes_views_and_internal_tables() {
        let payload = parse_sqlite(&fixture(), None, 0).unwrap();
        assert_eq!(
            payload.tables,
            [
                "big",
                "empty_names",
                "empty_table",
                "generated_columns",
                "long_values",
                "people",
                "quoted",
                "wide",
                "without_rowid"
            ]
        );
        assert!(!payload.tables_truncated);
        assert_eq!(payload.table.as_ref().unwrap().name, "big");
    }

    #[test]
    fn presents_typed_columns_nulls_empty_strings_and_blobs() {
        let payload = parse_sqlite(&fixture(), Some("people"), 0).unwrap();
        let table = payload.table.unwrap();
        assert_eq!(
            table
                .columns
                .iter()
                .map(|column| (column.name.as_str(), column.declared_type.as_deref()))
                .collect::<Vec<_>>(),
            [
                ("id", Some("INTEGER")),
                ("name", Some("TEXT")),
                ("score", Some("REAL")),
                ("note", Some("TEXT")),
                ("avatar", Some("BLOB")),
                ("active", Some("INTEGER")),
            ]
        );

        let ada = &table.rows[0];
        assert_eq!(ada[0].kind, SqliteCellKind::Integer);
        assert_eq!(ada[0].text, "1");
        assert_eq!(ada[1].text, "Ada");
        assert_eq!(ada[2].kind, SqliteCellKind::Real);
        assert_eq!(ada[2].text, "9.5");
        assert_eq!(ada[3].kind, SqliteCellKind::Null);
        assert_eq!(ada[3].text, "");
        assert_eq!(ada[4].kind, SqliteCellKind::Blob);
        assert_eq!(ada[4].byte_count, Some(4));
        assert_eq!(ada[4].text, "");

        let grace = &table.rows[1];
        assert_eq!(grace[3].kind, SqliteCellKind::Text);
        assert_eq!(grace[3].text, "");

        let lin = &table.rows[2];
        assert_eq!(lin[2].kind, SqliteCellKind::Null);
        assert_eq!(lin[3].text, "line one\nline two");
    }

    #[test]
    fn keeps_raw_names_for_empty_columns() {
        let table = parse_sqlite(&fixture(), Some("empty_names"), 0)
            .unwrap()
            .table
            .unwrap();
        assert_eq!(table.columns[0].name, "unnamed column 1");
        assert_eq!(table.columns[1].name, "column 1");
        assert_eq!(table.rows[0][0].text, "empty-name-value");
        assert_eq!(table.rows[0][1].text, "real-column-1");
    }

    #[test]
    fn omits_virtual_generated_columns_and_keeps_stored_ones() {
        let table = parse_sqlite(&fixture(), Some("generated_columns"), 0)
            .unwrap()
            .table
            .unwrap();
        assert_eq!(
            table
                .columns
                .iter()
                .map(|column| column.name.as_str())
                .collect::<Vec<_>>(),
            ["id", "base", "stored_text"]
        );
        assert!(table.virtual_columns_omitted);
        assert!(!table.columns_truncated);
        assert_eq!(table.rows[0][2].text, "ALPHA");
    }

    #[test]
    fn pages_rows_without_gaps_and_reports_more() {
        let first = parse_sqlite(&fixture(), Some("big"), 0)
            .unwrap()
            .table
            .unwrap();
        assert_eq!(first.rows.len(), ROWS_PER_PAGE);
        assert!(first.has_more);
        assert_eq!(first.offset, 0);
        assert_eq!(first.rows[0][0].text, "1");
        assert_eq!(first.rows[49][0].text, "50");

        let second = parse_sqlite(&fixture(), Some("big"), 50)
            .unwrap()
            .table
            .unwrap();
        assert_eq!(second.rows.len(), 25);
        assert!(!second.has_more);
        assert_eq!(second.offset, 50);
        assert_eq!(second.rows[0][0].text, "51");
        assert_eq!(second.rows.last().unwrap()[0].text, "75");

        let beyond = parse_sqlite(&fixture(), Some("big"), 500)
            .unwrap()
            .table
            .unwrap();
        assert!(beyond.rows.is_empty());
        assert!(!beyond.has_more);
    }

    #[test]
    fn pages_without_rowid_tables_in_primary_key_order() {
        let limits = Limits {
            rows_per_page: 2,
            ..DEFAULT_LIMITS
        };
        let first = parse_sqlite_with_limits(&fixture(), Some("without_rowid"), 0, limits)
            .unwrap()
            .table
            .unwrap();
        assert_eq!(first.rows.len(), 2);
        assert_eq!(first.rows[0][0].text, "a");
        assert_eq!(first.rows[1][0].text, "b");
        assert!(first.has_more);

        let second = parse_sqlite_with_limits(&fixture(), Some("without_rowid"), 2, limits)
            .unwrap()
            .table
            .unwrap();
        assert_eq!(second.rows.len(), 1);
        assert_eq!(second.rows[0][0].text, "c");
        assert!(!second.has_more);
    }

    #[test]
    fn clips_long_values_and_reports_the_cap() {
        let table = parse_sqlite(&fixture(), Some("long_values"), 0)
            .unwrap()
            .table
            .unwrap();
        let cell = &table.rows[0][0];
        assert!(cell.truncated);
        assert!(cell.text.ends_with('…'));
        assert!(cell.text.len() <= CELL_BYTES + '…'.len_utf8());
        assert_eq!(table.rows[0][1].kind, SqliteCellKind::Blob);
        assert_eq!(table.rows[0][1].byte_count, Some(4096));
        assert!(table.values_truncated);
    }

    #[test]
    fn truncates_table_column_row_and_output_caps() {
        let limited = Limits {
            max_tables: 2,
            ..DEFAULT_LIMITS
        };
        let payload = parse_sqlite_with_limits(&fixture(), None, 0, limited).unwrap();
        assert_eq!(payload.tables.len(), 2);
        assert!(payload.tables_truncated);

        let limited = Limits {
            max_columns: 3,
            ..DEFAULT_LIMITS
        };
        let table = parse_sqlite_with_limits(&fixture(), Some("wide"), 0, limited)
            .unwrap()
            .table
            .unwrap();
        assert_eq!(table.columns.len(), 3);
        assert!(table.columns_truncated);
        assert_eq!(table.rows[0].len(), 3);

        let limited = Limits {
            rows_per_page: 2,
            ..DEFAULT_LIMITS
        };
        let table = parse_sqlite_with_limits(&fixture(), Some("big"), 0, limited)
            .unwrap()
            .table
            .unwrap();
        assert_eq!(table.rows.len(), 2);
        assert!(table.has_more);

        let limited = Limits {
            max_page_bytes: 10,
            ..DEFAULT_LIMITS
        };
        let table = parse_sqlite_with_limits(&fixture(), Some("big"), 0, limited)
            .unwrap()
            .table
            .unwrap();
        assert_eq!(table.rows.len(), 1);
        assert!(table.has_more);
        assert!(table.page_truncated);
    }

    #[test]
    fn quotes_hostile_table_and_column_names() {
        let table = parse_sqlite(&fixture(), Some("quoted"), 0)
            .unwrap()
            .table
            .unwrap();
        assert_eq!(table.columns[0].name, "odd \"column\"");
        assert_eq!(table.columns[1].name, "spaced column");
        assert_eq!(table.rows[0][0].text, "ok");
        assert_eq!(table.rows[0][1].text, "typed");
    }

    #[test]
    fn preview_leaves_the_database_byte_identical_and_creates_no_sidecars() {
        let path = receiver();
        let directory = path.parent().unwrap();
        let before_bytes = fs::read(&path).unwrap();
        let before_entries = snapshot(directory);

        parse_sqlite(&path, Some("people"), 0).unwrap();

        // Byte-for-byte equality is stricter than the ticket's SHA-256
        // evidence: it catches every difference, not just hash collisions.
        assert_eq!(fs::read(&path).unwrap(), before_bytes);
        assert_eq!(snapshot(directory), before_entries);
        assert!(!sidecar_path(&path, "-wal").exists());
        assert!(!sidecar_path(&path, "-shm").exists());
        assert!(!sidecar_path(&path, "-journal").exists());
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn previews_committed_rows_from_a_wal_sidecar_without_touching_the_originals() {
        let directory = temporary_directory("wal");
        let path = directory.join("wal.sqlite");
        fs::copy(fixture(), &path).unwrap();
        let connection = open_write(&path);
        execute(&connection, "PRAGMA journal_mode=WAL");
        execute(&connection, "PRAGMA wal_autocheckpoint=0");
        execute(
            &connection,
            "INSERT INTO empty_table (id, label) VALUES (1, 'from-wal')",
        );
        assert!(sidecar_path(&path, "-wal").exists());

        let before_entries = snapshot(&directory);
        let table = parse_sqlite(&path, Some("empty_table"), 0)
            .unwrap()
            .table
            .unwrap();
        assert_eq!(table.rows[0][1].text, "from-wal");
        assert_eq!(snapshot(&directory), before_entries);

        drop(connection);
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn previews_read_only_wal_databases_from_a_writable_copy() {
        let directory = temporary_directory("wal-read-only");
        let path = directory.join("wal.sqlite");
        fs::copy(fixture(), &path).unwrap();
        let connection = open_write(&path);
        execute(&connection, "PRAGMA journal_mode=WAL");
        execute(&connection, "PRAGMA wal_autocheckpoint=0");
        execute(
            &connection,
            "INSERT INTO empty_table (id, label) VALUES (1, 'read-only')",
        );
        for candidate in [&path, &sidecar_path(&path, "-wal")] {
            let mut permissions = fs::metadata(candidate).unwrap().permissions();
            permissions.set_mode(0o444);
            fs::set_permissions(candidate, permissions).unwrap();
        }

        let table = parse_sqlite(&path, Some("empty_table"), 0)
            .unwrap()
            .table
            .unwrap();
        assert_eq!(table.rows[0][1].text, "read-only");

        drop(connection);
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn rejects_cells_over_the_sqlite_length_limit() {
        let directory = temporary_directory("length-limit");
        let path = directory.join("large.sqlite");
        let connection = open_write(&path);
        execute(&connection, "CREATE TABLE large (value TEXT)");
        execute(
            &connection,
            "INSERT INTO large VALUES (printf('%.*c', 5000000, 'x'))",
        );
        drop(connection);

        let error = parse_sqlite(&path, None, 0).unwrap_err();
        assert!(matches!(error, CoreError::Parse(_)));
        assert!(error.to_string().contains("too big"));

        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn progress_deadline_expires() {
        let deadline = ProgressDeadline {
            expires: Cell::new(None),
        };
        assert!(!deadline.expired());
        deadline
            .expires
            .set(Some(Instant::now() - Duration::from_secs(1)));
        assert!(deadline.expired());
    }

    #[test]
    fn bounded_copy_stops_at_the_shared_budget() {
        let directory = temporary_directory("copy-budget");
        let source = directory.join("source.bin");
        fs::write(&source, vec![0_u8; 128 * 1_024]).unwrap();
        let target = directory.join("target.bin");
        let mut budget = 100 * 1_024;

        assert!(matches!(
            copy_bounded(&source, &target, &mut budget),
            Err(CopyFailure::Budget)
        ));
        assert_eq!(budget, 36 * 1_024);
        assert_eq!(fs::metadata(&target).unwrap().len(), 64 * 1_024);

        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn snapshot_signatures_change_when_a_file_changes() {
        let directory = temporary_directory("signature");
        let path = directory.join("snapshot.sqlite");
        fs::write(&path, b"one").unwrap();
        let wal = sidecar_path(&path, "-wal");
        fs::write(&wal, b"wal-one").unwrap();
        let before = SnapshotSignature::read(&path).unwrap().unwrap();
        fs::write(&wal, b"wal-two-longer").unwrap();
        let after = SnapshotSignature::read(&path).unwrap().unwrap();

        assert_ne!(before, after);
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn rejects_missing_non_database_encrypted_and_truncated_files() {
        assert!(matches!(
            parse_sqlite(Path::new("/nonexistent/glance.sqlite"), None, 0),
            Err(CoreError::Io(_))
        ));

        let directory = temporary_directory("invalid");
        let garbage = directory.join("garbage.sqlite");
        fs::write(&garbage, b"not a database").unwrap();
        let error = parse_sqlite(&garbage, None, 0).unwrap_err();
        assert!(matches!(error, CoreError::Parse(_)));
        assert!(error.to_string().contains("not a SQLite database"));

        let encrypted = directory.join("encrypted.sqlite");
        let bytes = (0..4096)
            .map(|index| (index % 251) as u8)
            .collect::<Vec<_>>();
        fs::write(&encrypted, bytes).unwrap();
        assert!(matches!(
            parse_sqlite(&encrypted, None, 0),
            Err(CoreError::Parse(_))
        ));

        let truncated = directory.join("truncated.sqlite");
        let source = fs::read(fixture()).unwrap();
        fs::write(&truncated, &source[..100]).unwrap();
        assert!(matches!(
            parse_sqlite(&truncated, None, 0),
            Err(CoreError::Parse(_))
        ));

        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn rejects_wal_databases_over_the_copy_limit() {
        let directory = temporary_directory("wal-limit");
        let path = directory.join("wal.sqlite");
        fs::copy(fixture(), &path).unwrap();
        let connection = open_write(&path);
        execute(&connection, "PRAGMA journal_mode=WAL");
        execute(
            &connection,
            "INSERT INTO empty_table (id, label) VALUES (1, 'from-wal')",
        );

        let limits = Limits {
            max_copy_bytes: 1,
            ..DEFAULT_LIMITS
        };
        let result = parse_sqlite_with_limits(&path, None, 0, limits);
        assert!(matches!(result, Err(CoreError::ResourceLimit(_))));

        drop(connection);
        fs::remove_dir_all(directory).unwrap();
    }

    fn open_write(path: &Path) -> Connection {
        let filename = CString::new(path.as_os_str().as_bytes()).unwrap();
        let mut handle = ptr::null_mut();
        let flags = SQLITE_OPEN_READWRITE | 0x0000_0004; // SQLITE_OPEN_CREATE
        let status = unsafe { sqlite3_open_v2(filename.as_ptr(), &mut handle, flags, ptr::null()) };
        assert_eq!(status, SQLITE_OK);
        Connection(
            handle,
            Box::new(ProgressDeadline {
                expires: Cell::new(None),
            }),
        )
    }

    fn execute(connection: &Connection, sql: &str) {
        let sql = CString::new(sql).unwrap();
        let mut statement = ptr::null_mut();
        let status = unsafe {
            sqlite3_prepare_v2(
                connection.0,
                sql.as_ptr(),
                -1,
                &mut statement,
                ptr::null_mut(),
            )
        };
        assert_eq!(status, SQLITE_OK);
        let statement = Statement(statement);
        while unsafe { sqlite3_step(statement.0) } == SQLITE_ROW {}
    }
}
