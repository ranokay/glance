//! Property checks for preview parsing and escaping.
//!
//! Example tests pin known shapes. These cover arbitrary input: values survive
//! the TSV escape/parse cycle, markup is always escaped, and budgets hold for
//! whatever shape a document takes.

use crate::markdown::render_markdown;
use crate::structured::{MAX_OUTPUT_BYTES, StructuredFormat, render_structured};
use crate::tsv::parse_tsv;
use proptest::prelude::*;
use serde_json::Value as JsonValue;
use std::collections::BTreeSet;

fn text(max_chars: usize) -> impl Strategy<Value = String> {
    proptest::collection::vec(any::<char>(), 0..max_chars)
        .prop_map(|chars| chars.into_iter().collect())
}

/// Cell text. A leading U+FEFF is a byte-order mark rather than data, so cells
/// deliberately exclude it; `tsv` pins that normalization with an example test.
fn cell_text(max_chars: usize) -> impl Strategy<Value = String> {
    proptest::collection::vec(
        any::<char>().prop_filter("U+FEFF marks the encoding", |character| {
            *character != '\u{feff}'
        }),
        0..max_chars,
    )
    .prop_map(|chars| chars.into_iter().collect())
}

/// Bounded recursive JSON, including strings and keys that look like markup.
fn json_value() -> impl Strategy<Value = JsonValue> {
    let leaf = prop_oneof![
        Just(JsonValue::Null),
        any::<bool>().prop_map(JsonValue::Bool),
        any::<i64>().prop_map(|value| JsonValue::Number(value.into())),
        text(12).prop_map(JsonValue::String),
    ];
    leaf.prop_recursive(4, 64, 8, |inner| {
        prop_oneof![
            proptest::collection::vec(inner.clone(), 0..6).prop_map(JsonValue::Array),
            proptest::collection::vec((text(8), inner), 0..6)
                .prop_map(|entries| JsonValue::Object(entries.into_iter().collect())),
        ]
    })
}

/// Encode a table with the same CSV quoting rules production reads back.
fn encode_tsv(headers: &[String], rows: &[Vec<String>]) -> Vec<u8> {
    let mut writer = csv::WriterBuilder::new()
        .delimiter(b'\t')
        .from_writer(Vec::new());
    writer.write_record(headers).expect("write header");
    for row in rows {
        writer.write_record(row).expect("write row");
    }
    writer.into_inner().expect("finish table")
}

/// A uniform-width table, the only shape a non-flexible TSV reader accepts.
fn table() -> impl Strategy<Value = (Vec<String>, Vec<Vec<String>>)> {
    (1usize..6).prop_flat_map(|width| {
        (
            proptest::collection::vec(cell_text(12), width),
            proptest::collection::vec(proptest::collection::vec(cell_text(12), width), 0..6),
        )
    })
}

/// Arbitrary prose wrapped around the payloads a hostile document would use.
fn markdown_source() -> impl Strategy<Value = String> {
    let hostile = prop_oneof![
        Just(""),
        Just("<script>alert(1)</script>"),
        Just("<img src=x onerror=alert(1)>"),
        Just("[link](javascript:alert(1))"),
        Just("![image](javascript:alert(1))"),
    ];
    (text(40), hostile, text(40))
        .prop_map(|(before, payload, after)| format!("{before}{payload}{after}"))
}

proptest! {
    #[test]
    fn tsv_round_trips_every_cell((headers, rows) in table()) {
        let encoded = encode_tsv(&headers, &rows);

        let payload = parse_tsv(&encoded).expect("generated TSV parses");
        prop_assert_eq!(payload.headers.len(), headers.len());
        prop_assert_eq!(payload.rows.len(), rows.len());
        let unique = payload.headers.iter().collect::<BTreeSet<_>>();
        prop_assert_eq!(unique.len(), payload.headers.len(), "headers must stay addressable");

        for (row, values) in payload.rows.iter().zip(&rows) {
            for (header, value) in payload.headers.iter().zip(values) {
                prop_assert_eq!(row.get(header).map(String::as_str), Some(value.as_str()));
            }
        }
    }

    #[test]
    fn tsv_parses_arbitrary_text_without_panicking(source in text(200)) {
        let _ = parse_tsv(source.as_bytes());
    }

    #[test]
    fn structured_json_escapes_markup(value in json_value()) {
        let source = serde_json::to_vec(&value).expect("serialize generated JSON");
        let html = render_structured(&source, StructuredFormat::Json).expect("valid JSON renders");

        prop_assert!(!html.to_ascii_lowercase().contains("<script"));
        // Scalar escaping can overshoot the cap by a few times the value limit.
        prop_assert!(html.len() <= MAX_OUTPUT_BYTES + 64 * 1_024);
    }

    #[test]
    fn structured_arbitrary_bytes_do_not_panic(data in proptest::collection::vec(any::<u8>(), 0..4_096)) {
        for format in [StructuredFormat::Json, StructuredFormat::Plist, StructuredFormat::Xml] {
            let _ = render_structured(&data, format);
        }
    }

    #[test]
    fn markdown_never_emits_active_content(source in markdown_source()) {
        let html = render_markdown(&source).expect("markdown rendering cannot fail");
        let lower = html.to_ascii_lowercase();

        prop_assert!(!lower.contains("<script"));
        prop_assert!(!lower.contains("href=\"javascript:"));
        prop_assert!(!lower.contains("src=\"javascript:"));
    }
}
