use crate::error::CoreError;
use calamine::{Data, ExcelDateTime, Reader, open_workbook_auto};
use serde::Serialize;
use std::path::Path;

pub(crate) const MAX_FILE_SIZE: u64 = 25 * 1_024 * 1_024;
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
    pub truncated: bool,
}

pub(crate) fn parse_xlsx(path: &Path) -> Result<SpreadsheetPayload, CoreError> {
    parse_xlsx_with_limits(path, MAX_ROWS, MAX_COLUMNS, MAX_SHEETS)
}

fn parse_xlsx_with_limits(
    path: &Path,
    max_rows: usize,
    max_columns: usize,
    max_sheets: usize,
) -> Result<SpreadsheetPayload, CoreError> {
    let file_size = std::fs::metadata(path)
        .map_err(|error| CoreError::io(format!("Could not inspect XLSX workbook: {error}")))?
        .len();
    if file_size > MAX_FILE_SIZE {
        return Err(CoreError::limit(format!(
            "XLSX workbook exceeds the {MAX_FILE_SIZE} byte preview limit"
        )));
    }

    let mut workbook = open_workbook_auto(path).map_err(map_calamine_error)?;
    let sheet_names = workbook.sheet_names();
    if sheet_names.len() > max_sheets {
        return Err(CoreError::limit(format!(
            "XLSX workbook exceeds the {max_sheets} sheet preview limit"
        )));
    }

    let mut sheets = Vec::with_capacity(sheet_names.len());
    for name in sheet_names {
        let range = workbook
            .worksheet_range(&name)
            .map_err(map_calamine_error)?;
        let column_count = range.width().min(max_columns);
        let truncated = range.height() > max_rows || range.width() > max_columns;
        let mut rows = Vec::new();
        for row in range.rows().take(max_rows) {
            let mut values = row
                .iter()
                .take(column_count)
                .map(format_cell)
                .collect::<Vec<_>>();
            while values.last().is_some_and(String::is_empty) {
                values.pop();
            }
            if !values.is_empty() {
                rows.push(values);
            }
        }
        sheets.push(SpreadsheetSheet {
            name,
            rows,
            truncated,
        });
    }

    Ok(SpreadsheetPayload { sheets })
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

fn map_calamine_error(error: calamine::Error) -> CoreError {
    match error {
        calamine::Error::Io(error) => {
            CoreError::io(format!("Could not read XLSX workbook: {error}"))
        }
        error => CoreError::parse(format!("Could not parse XLSX workbook: {error}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

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
        assert!(!payload.sheets[0].truncated);
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
        let payload = parse_xlsx_with_limits(&fixture(), 1, 2, 2).unwrap();

        assert_eq!(payload.sheets.len(), 2);
        assert_eq!(payload.sheets[0].rows, vec![vec!["Name", "Value"]]);
        assert!(payload.sheets[0].truncated);
    }

    #[test]
    fn rejects_workbooks_over_the_sheet_limit() {
        assert!(parse_xlsx_with_limits(&fixture(), MAX_ROWS, MAX_COLUMNS, 1).is_err());
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
