use crate::error::CoreError;
use calamine::{Data, ExcelDateTime, Reader, Xlsx, open_workbook};
use serde::Serialize;
use std::collections::{BTreeMap, HashSet};
use std::fs::File;
use std::io::{Seek, SeekFrom};
use std::path::Path;
use zip::ZipArchive;

pub(crate) const MAX_FILE_SIZE: u64 = 25 * 1_024 * 1_024;
pub(crate) const MAX_UNCOMPRESSED_SIZE: u64 = 200 * 1_024 * 1_024;
pub(crate) const MAX_RENDERED_BYTES: usize = 64 * 1_024 * 1_024;
pub(crate) const MAX_CELLS: usize = 4_000_000;
pub(crate) const MAX_ROWS: usize = 5_000;
pub(crate) const MAX_COLUMNS: usize = 256;
pub(crate) const MAX_SHEETS: usize = 64;

#[derive(Debug, PartialEq, Serialize)]
pub(crate) struct SpreadsheetPayload {
    pub sheets: Vec<SpreadsheetSheet>,
}

#[derive(Debug, PartialEq, Serialize)]
pub(crate) struct SpreadsheetSheet {
    pub name: String,
    pub rows: Vec<Vec<String>>,
    pub rows_truncated: bool,
    pub columns_truncated: bool,
}

pub(crate) fn parse_xlsx(path: &Path) -> Result<SpreadsheetPayload, CoreError> {
    parse_xlsx_with_limits(
        path,
        MAX_ROWS,
        MAX_COLUMNS,
        MAX_SHEETS,
        MAX_RENDERED_BYTES,
        MAX_CELLS,
    )
}

fn parse_xlsx_with_limits(
    path: &Path,
    max_rows: usize,
    max_columns: usize,
    max_sheets: usize,
    max_rendered_bytes: usize,
    max_cells: usize,
) -> Result<SpreadsheetPayload, CoreError> {
    let file_size = std::fs::metadata(path)
        .map_err(|error| CoreError::io(format!("Could not inspect XLSX workbook: {error}")))?
        .len();
    if file_size > MAX_FILE_SIZE {
        return Err(CoreError::limit(format!(
            "XLSX workbook exceeds the {MAX_FILE_SIZE} byte preview limit"
        )));
    }

    preflight_uncompressed_sizes(path, MAX_UNCOMPRESSED_SIZE)?;

    let mut workbook: Xlsx<_> = open_workbook(path).map_err(map_xlsx_error)?;
    let sheet_names = workbook.sheet_names();
    if sheet_names.len() > max_sheets {
        return Err(CoreError::limit(format!(
            "XLSX workbook exceeds the {max_sheets} sheet preview limit"
        )));
    }
    if sheet_names.iter().collect::<HashSet<_>>().len() != sheet_names.len() {
        return Err(CoreError::invalid(
            "XLSX workbooks with duplicate sheet names are not supported",
        ));
    }

    let mut sheets = Vec::with_capacity(sheet_names.len());
    let mut rendered_bytes = 0_usize;
    let mut retained_cells = 0_usize;
    for name in sheet_names {
        let mut reader = workbook
            .worksheet_cells_reader(&name)
            .map_err(map_xlsx_error)?;
        let dimensions = reader.dimensions();
        let start_row = dimensions.start.0 as usize;
        let row_span = dimensions.end.0.saturating_sub(dimensions.start.0) as usize + 1;
        let rows_truncated = row_span > max_rows;
        let columns_truncated = dimensions.end.1 as usize + 1 > max_columns;
        let mut rows_by_offset = BTreeMap::new();

        while let Some(cell) = reader.next_cell().map_err(map_xlsx_error)? {
            let (row, column) = cell.get_position();
            let row_offset = (row as usize).saturating_sub(start_row);
            let column = column as usize;
            if row_offset >= max_rows || column >= max_columns {
                continue;
            }
            let value = format_cell(&Data::from(cell.get_value().clone()));
            rendered_bytes = rendered_bytes
                .checked_add(value.len())
                .ok_or_else(|| CoreError::limit("XLSX rendered cell text size overflow"))?;
            if rendered_bytes > max_rendered_bytes {
                return Err(CoreError::limit(format!(
                    "XLSX cell text exceeds the {max_rendered_bytes} byte preview limit"
                )));
            }
            let values = rows_by_offset.entry(row_offset).or_insert_with(Vec::new);
            if values.len() <= column {
                retained_cells = retained_cells
                    .checked_add(column + 1 - values.len())
                    .ok_or_else(|| CoreError::limit("XLSX cell slot count overflow"))?;
                if retained_cells > max_cells {
                    return Err(CoreError::limit(format!(
                        "XLSX workbook exceeds the {max_cells} cell preview limit"
                    )));
                }
                values.resize(column + 1, String::new());
            }
            values[column] = value;
        }

        let mut rows = Vec::new();
        if let Some(max_offset) = rows_by_offset.keys().next_back().copied() {
            for offset in 0..=max_offset {
                let mut values = rows_by_offset.remove(&offset).unwrap_or_default();
                while values.last().is_some_and(String::is_empty) {
                    values.pop();
                }
                rows.push(values);
            }
            while rows.last().is_some_and(Vec::is_empty) {
                rows.pop();
            }
        }
        sheets.push(SpreadsheetSheet {
            name,
            rows,
            rows_truncated,
            columns_truncated,
        });
    }

    Ok(SpreadsheetPayload { sheets })
}

fn preflight_uncompressed_sizes(path: &Path, max_uncompressed: u64) -> Result<(), CoreError> {
    let mut file = File::open(path)
        .map_err(|error| CoreError::io(format!("Could not open XLSX workbook: {error}")))?;
    let file_size = file
        .metadata()
        .map_err(|error| CoreError::io(format!("Could not inspect XLSX workbook: {error}")))?
        .len();
    crate::zip::preflight_central_directory(&mut file, file_size)?;
    file.seek(SeekFrom::Start(0))
        .map_err(|error| CoreError::io(format!("Could not seek XLSX workbook: {error}")))?;
    let mut archive = ZipArchive::new(file)
        .map_err(|error| CoreError::parse(format!("Could not read XLSX archive: {error}")))?;
    let mut total = 0_u64;
    for index in 0..archive.len() {
        let entry = archive
            .by_index_raw(index)
            .map_err(|error| CoreError::parse(format!("Could not read XLSX entry: {error}")))?;
        // Calamine eagerly reads styles and relationships too, and package relationships can
        // relocate workbook parts, so every entry must share the expansion budget.
        total = total
            .checked_add(entry.size())
            .ok_or_else(|| CoreError::limit("XLSX uncompressed size overflow"))?;
        if total > max_uncompressed {
            return Err(CoreError::limit(format!(
                "XLSX workbook exceeds the {max_uncompressed} byte uncompressed preview limit"
            )));
        }
    }
    Ok(())
}

fn format_cell(cell: &Data) -> String {
    match cell {
        Data::Empty => String::new(),
        Data::String(value) => value.clone(),
        Data::Float(value) => format_float(*value),
        Data::Int(value) => value.to_string(),
        Data::Bool(value) => if *value { "TRUE" } else { "FALSE" }.to_string(),
        Data::DateTime(value) => format_datetime(value),
        Data::DateTimeIso(value) | Data::DurationIso(value) => value.clone(),
        Data::Error(value) => value.to_string(),
    }
}

fn format_float(value: f64) -> String {
    if value.is_finite() {
        value.to_string()
    } else {
        String::new()
    }
}

fn format_datetime(datetime: &ExcelDateTime) -> String {
    if datetime.is_duration() {
        let total_seconds = (datetime.as_f64() * 86_400.0).round().max(0.0) as u64;
        let hours = total_seconds / 3_600;
        let minutes = total_seconds % 3_600 / 60;
        let seconds = total_seconds % 60;
        return format!("{hours:02}:{minutes:02}:{seconds:02}");
    }

    let (year, month, day, hour, minute, second, millisecond) = datetime.to_ymd_hms_milli();
    let serial = datetime.as_f64();
    if (0.0..1.0).contains(&serial) {
        return format!("{hour:02}:{minute:02}:{second:02}");
    }
    if hour == 0 && minute == 0 && second == 0 && millisecond == 0 {
        return format!("{year:04}-{month:02}-{day:02}");
    }
    let mut formatted = format!("{year:04}-{month:02}-{day:02} {hour:02}:{minute:02}:{second:02}");
    if millisecond > 0 {
        formatted.push_str(&format!(".{millisecond:03}"));
    }
    formatted
}

fn map_xlsx_error(error: calamine::XlsxError) -> CoreError {
    match error {
        calamine::XlsxError::Io(error) => {
            CoreError::io(format!("Could not read XLSX workbook: {error}"))
        }
        error => CoreError::parse(format!("Could not parse XLSX workbook: {error}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use zip::write::SimpleFileOptions;

    struct TemporaryWorkbook(PathBuf);

    impl TemporaryWorkbook {
        fn new(entries: &[(&str, &[u8])]) -> Self {
            let file = Self::from_bytes(&[]);
            let mut writer = zip::ZipWriter::new(File::create(&file.0).unwrap());
            for (name, contents) in entries {
                writer
                    .start_file(*name, SimpleFileOptions::default())
                    .unwrap();
                writer.write_all(contents).unwrap();
            }
            writer.finish().unwrap();
            file
        }

        fn from_bytes(bytes: &[u8]) -> Self {
            static NEXT_FIXTURE: AtomicUsize = AtomicUsize::new(0);
            let path = std::env::temp_dir().join(format!(
                "glance-xlsx-{}-{}.xlsx",
                std::process::id(),
                NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed)
            ));
            std::fs::write(&path, bytes).unwrap();
            Self(path)
        }
    }

    impl Drop for TemporaryWorkbook {
        fn drop(&mut self) {
            let _ = std::fs::remove_file(&self.0);
        }
    }

    fn fixture() -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../GlanceTests/TestFiles/spreadsheet/example.xlsx")
    }

    #[test]
    fn parses_sheets_shared_strings_numbers_dates_and_cached_formulas() {
        let payload = parse_xlsx(&fixture()).unwrap();

        assert_eq!(payload.sheets.len(), 2);
        assert_eq!(payload.sheets[0].name, "Summary");
        assert_eq!(
            payload.sheets[0].rows,
            vec![
                vec!["Name", "Value", "Date"],
                vec!["Alpha", "1.5", "2026-10-23"],
                vec!["Beta", "3", "2026-10-24"],
                vec!["Flag", "TRUE"],
            ]
        );
        assert_eq!(payload.sheets[1].rows, vec![vec!["Only sheet"], vec!["42"]]);
        assert!(!payload.sheets[0].rows_truncated);
        assert!(!payload.sheets[0].columns_truncated);
    }

    #[test]
    fn preserves_leading_columns_for_offsets() {
        let payload = parse_xlsx(
            &Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../GlanceTests/TestFiles/spreadsheet/offset.xlsx"),
        )
        .unwrap();

        assert_eq!(payload.sheets[0].rows, vec![vec!["", "", "Hello"]]);
        assert!(!payload.sheets[0].columns_truncated);
    }

    #[test]
    fn preserves_interior_empty_rows() {
        let payload = parse_xlsx(
            &Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../GlanceTests/TestFiles/spreadsheet/gap-rows.xlsx"),
        )
        .unwrap();

        assert_eq!(
            payload.sheets[0].rows,
            vec![vec!["Top"], vec![], vec!["", "Bottom"]]
        );
    }

    #[test]
    fn row_limit_uses_the_sheet_span_not_the_absolute_end_row() {
        let payload = parse_xlsx_with_limits(
            &Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../GlanceTests/TestFiles/spreadsheet/late-start.xlsx"),
            2,
            MAX_COLUMNS,
            MAX_SHEETS,
            MAX_RENDERED_BYTES,
            MAX_CELLS,
        )
        .unwrap();

        assert_eq!(
            payload.sheets[0].rows,
            vec![vec!["Late"], vec!["Still late"]]
        );
        assert!(!payload.sheets[0].rows_truncated);
    }

    #[test]
    fn rejects_duplicate_sheet_names() {
        assert!(
            parse_xlsx(
                &Path::new(env!("CARGO_MANIFEST_DIR"))
                    .join("../GlanceTests/TestFiles/spreadsheet/duplicate-sheets.xlsx"),
            )
            .is_err()
        );
    }

    #[test]
    fn rejects_oversized_uncompressed_workbooks() {
        assert!(preflight_uncompressed_sizes(&fixture(), 1).is_err());
        assert!(preflight_uncompressed_sizes(&fixture(), 1_048_576).is_ok());
    }

    #[test]
    fn rejects_oversized_styles_relationships_and_relocated_workbook_parts() {
        for part in [
            "xl/styles.xml",
            "xl/workbook.xml",
            "xl/_rels/workbook.xml.rels",
            "_rels/.rels",
            "custom/sharedStrings.xml",
            "custom/worksheets/sheet1.xml",
        ] {
            let workbook = TemporaryWorkbook::new(&[(part, &[b'x'; 128])]);
            assert!(
                matches!(
                    preflight_uncompressed_sizes(&workbook.0, 64),
                    Err(CoreError::ResourceLimit(_))
                ),
                "part {part} bypassed the expanded-byte budget"
            );
        }
    }

    #[test]
    fn expanded_byte_budget_is_shared_by_all_workbook_parts() {
        let workbook = TemporaryWorkbook::new(&[
            ("xl/worksheets/sheet1.xml", &[b'x'; 40]),
            ("xl/styles.xml", &[b'x'; 40]),
        ]);
        assert!(matches!(
            preflight_uncompressed_sizes(&workbook.0, 64),
            Err(CoreError::ResourceLimit(_))
        ));
        assert!(preflight_uncompressed_sizes(&workbook.0, 80).is_ok());
    }

    #[test]
    fn rejects_oversized_zip_metadata_before_workbook_parsing() {
        let mut eocd = vec![0_u8; 22];
        eocd[0..4].copy_from_slice(b"PK\x05\x06");
        eocd[12..16].copy_from_slice(&(64_u32 * 1_024 * 1_024 + 1).to_le_bytes());
        let workbook = TemporaryWorkbook::from_bytes(&eocd);

        assert!(matches!(
            preflight_uncompressed_sizes(&workbook.0, MAX_UNCOMPRESSED_SIZE),
            Err(CoreError::ResourceLimit(_))
        ));
    }

    #[test]
    fn rejects_missing_and_malformed_files() {
        assert!(parse_xlsx(Path::new("/nonexistent/glance.xlsx")).is_err());

        let malformed = std::env::temp_dir().join("glance-malformed.xlsx");
        std::fs::write(&malformed, b"not a workbook").unwrap();
        let result = parse_xlsx(&malformed);
        let _ = std::fs::remove_file(&malformed);
        assert!(result.is_err());
    }

    #[test]
    fn truncates_rows_and_columns() {
        let payload =
            parse_xlsx_with_limits(&fixture(), 1, 2, 2, MAX_RENDERED_BYTES, MAX_CELLS).unwrap();

        assert_eq!(payload.sheets.len(), 2);
        assert_eq!(payload.sheets[0].rows, vec![vec!["Name", "Value"]]);
        assert!(payload.sheets[0].rows_truncated);
        assert!(payload.sheets[0].columns_truncated);
    }

    #[test]
    fn rejects_workbooks_over_the_sheet_limit() {
        assert!(
            parse_xlsx_with_limits(
                &fixture(),
                MAX_ROWS,
                MAX_COLUMNS,
                1,
                MAX_RENDERED_BYTES,
                MAX_CELLS,
            )
            .is_err()
        );
    }

    #[test]
    fn rejects_workbooks_over_the_rendered_text_budget() {
        assert!(
            parse_xlsx_with_limits(&fixture(), MAX_ROWS, MAX_COLUMNS, MAX_SHEETS, 1, MAX_CELLS,)
                .is_err()
        );
    }

    #[test]
    fn rejects_workbooks_over_the_cell_budget() {
        assert!(
            parse_xlsx_with_limits(
                &fixture(),
                MAX_ROWS,
                MAX_COLUMNS,
                MAX_SHEETS,
                MAX_RENDERED_BYTES,
                1,
            )
            .is_err()
        );
    }

    #[test]
    fn formats_date_time_and_duration_cells() {
        let date = ExcelDateTime::new(46_318.0, calamine::ExcelDateTimeType::DateTime, false);
        assert_eq!(format_datetime(&date), "2026-10-23");

        let time = ExcelDateTime::new(0.5, calamine::ExcelDateTimeType::DateTime, false);
        assert_eq!(format_datetime(&time), "12:00:00");

        let duration = ExcelDateTime::new(1.5, calamine::ExcelDateTimeType::TimeDelta, false);
        assert_eq!(format_datetime(&duration), "36:00:00");
    }
}
