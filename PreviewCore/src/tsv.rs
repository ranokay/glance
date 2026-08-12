use crate::error::CoreError;
use crate::model::TsvPayload;
use csv::ReaderBuilder;
use std::collections::BTreeMap;

pub(crate) const MAX_FILE_SIZE: usize = 25 * 1_024 * 1_024;
pub(crate) const MAX_ROWS: usize = 5_000;
pub(crate) const MAX_COLUMNS: usize = 512;

pub(crate) fn parse_tsv(data: &[u8]) -> Result<TsvPayload, CoreError> {
    parse_tsv_with_limits(data, MAX_FILE_SIZE, MAX_ROWS, MAX_COLUMNS)
}

fn parse_tsv_with_limits(
    data: &[u8],
    max_file_size: usize,
    max_rows: usize,
    max_columns: usize,
) -> Result<TsvPayload, CoreError> {
    if data.len() > max_file_size {
        return Err(CoreError::limit(format!(
            "TSV file exceeds the {max_file_size} byte preview limit"
        )));
    }
    std::str::from_utf8(data)
        .map_err(|error| CoreError::invalid(format!("TSV input is not valid UTF-8: {error}")))?;
    if data.is_empty() {
        return Ok(TsvPayload {
            headers: Vec::new(),
            rows: Vec::new(),
        });
    }

    let mut reader = ReaderBuilder::new()
        .delimiter(b'\t')
        .has_headers(true)
        .flexible(false)
        .from_reader(data);
    let headers = reader
        .headers()
        .map_err(|error| CoreError::parse(format!("Could not parse TSV header: {error}")))?
        .iter()
        .map(str::to_owned)
        .collect::<Vec<_>>();
    if headers.len() > max_columns {
        return Err(CoreError::limit(format!(
            "TSV header exceeds the {max_columns} column preview limit"
        )));
    }

    let mut rows = Vec::with_capacity(max_rows.min(256));
    for record in reader.records().take(max_rows) {
        let record = record
            .map_err(|error| CoreError::parse(format!("Could not parse TSV row: {error}")))?;
        let row = headers
            .iter()
            .zip(record.iter())
            .map(|(header, value)| (header.clone(), value.to_owned()))
            .collect::<BTreeMap<_, _>>();
        rows.push(row);
    }

    Ok(TsvPayload { headers, rows })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_quotes_tabs_newlines_and_unicode() {
        let payload =
            parse_tsv("name\tdescription\nș\t\"one\tline\"\n二\t\"two\nlines\"\n".as_bytes())
                .unwrap();
        assert_eq!(payload.headers, ["name", "description"]);
        assert_eq!(payload.rows.len(), 2);
        assert_eq!(payload.rows[0]["description"], "one\tline");
        assert_eq!(payload.rows[1]["description"], "two\nlines");
    }

    #[test]
    fn handles_empty_input_and_row_limit() {
        assert_eq!(
            parse_tsv(b"").unwrap(),
            TsvPayload {
                headers: Vec::new(),
                rows: Vec::new()
            }
        );
        let payload = parse_tsv_with_limits(b"a\n1\n2\n", 32, 1, 1).unwrap();
        assert_eq!(payload.rows.len(), 1);
        assert_eq!(payload.rows[0]["a"], "1");
    }

    #[test]
    fn rejects_malformed_data_and_limits() {
        assert!(matches!(
            parse_tsv_with_limits(b"a\tb\n1\n", 32, 5, 2),
            Err(CoreError::Parse(_))
        ));
        assert!(matches!(
            parse_tsv_with_limits(b"abc", 2, 5, 2),
            Err(CoreError::ResourceLimit(_))
        ));
        assert!(matches!(
            parse_tsv_with_limits(b"a\tb\tc\n", 32, 5, 2),
            Err(CoreError::ResourceLimit(_))
        ));
        assert!(matches!(
            parse_tsv(&[0xff]),
            Err(CoreError::InvalidInput(_))
        ));
    }
}
