use crate::error::RenderError;
use crate::highlight::render_code;
use crate::markdown::render_markdown;
use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;
use serde::Deserialize;
use std::fmt::Write;

#[derive(Debug, Default, Deserialize)]
struct Notebook {
    #[serde(default)]
    cells: Vec<Cell>,
    #[serde(default)]
    metadata: Metadata,
    #[serde(default)]
    nbformat: i64,
}

#[derive(Debug, Default, Deserialize)]
struct Metadata {
    #[serde(default)]
    language_info: LanguageInfo,
    #[serde(default)]
    kernelspec: KernelSpec,
}

#[derive(Debug, Default, Deserialize)]
struct LanguageInfo {
    file_extension: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
struct KernelSpec {
    language: Option<String>,
    name: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
struct Cell {
    #[serde(default)]
    cell_type: String,
    execution_count: Option<i64>,
    #[serde(default)]
    source: NotebookText,
    #[serde(default)]
    outputs: Vec<Output>,
}

#[derive(Debug, Default, Deserialize)]
struct Output {
    #[serde(default)]
    output_type: String,
    execution_count: Option<i64>,
    #[serde(default)]
    text: NotebookText,
    #[serde(default)]
    traceback: Vec<String>,
    #[serde(default)]
    data: OutputData,
}

#[derive(Debug, Default, Deserialize)]
struct OutputData {
    #[serde(rename = "text/html")]
    text_html: Option<NotebookText>,
    #[serde(rename = "application/pdf")]
    application_pdf: Option<NotebookText>,
    #[serde(rename = "text/latex")]
    text_latex: Option<NotebookText>,
    #[serde(rename = "image/svg+xml")]
    image_svg: Option<NotebookText>,
    #[serde(rename = "image/png")]
    image_png: Option<NotebookText>,
    #[serde(rename = "image/jpeg")]
    image_jpeg: Option<NotebookText>,
    #[serde(rename = "text/markdown")]
    text_markdown: Option<NotebookText>,
    #[serde(rename = "text/plain")]
    text_plain: Option<NotebookText>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(untagged)]
enum NotebookText {
    One(String),
    Many(Vec<String>),
    #[default]
    Missing,
}

impl NotebookText {
    fn joined(&self) -> String {
        match self {
            Self::One(value) => value.clone(),
            Self::Many(values) => values.concat(),
            Self::Missing => String::new(),
        }
    }
}

pub(crate) fn render_notebook(source: &str) -> Result<String, RenderError> {
    let notebook: Notebook = serde_json::from_str(source)
        .map_err(|error| RenderError::new(format!("Could not parse notebook JSON: {error}")))?;
    if notebook.nbformat < 4 {
        return Err(RenderError::new(
            "The provided Jupyter Notebook uses an old format; version 4 or newer is required",
        ));
    }

    let language = notebook_language(&notebook);
    let mut html = String::from("<div class=\"notebook\">");
    for cell in notebook.cells {
        let input = render_cell_input(&cell, &language)?;
        let cell_class = class_token(&cell.cell_type);
        write!(
            html,
            "<div class=\"cell cell-{cell_class}\"><div class=\"input-wrapper\"><div class=\"input-prompt\">{}</div><div class=\"input\">{input}</div></div>",
            render_prompt(cell.execution_count)
        )
        .expect("writing to a string cannot fail");

        for output in cell.outputs {
            let class_name = class_token(&output.output_type.replace('_', "-"));
            let rendered = render_output(&output)?;
            write!(
                html,
                "<div class=\"output-wrapper\"><div class=\"output-prompt\">{}</div><div class=\"output output-{class_name}\">{rendered}</div></div>",
                render_prompt(output.execution_count)
            )
            .expect("writing to a string cannot fail");
        }
        html.push_str("</div>");
    }
    html.push_str("</div>");
    Ok(html)
}

fn notebook_language(notebook: &Notebook) -> String {
    notebook
        .metadata
        .language_info
        .file_extension
        .as_deref()
        .map(|extension| extension.trim_start_matches('.').to_owned())
        .filter(|language| !language.is_empty())
        .or_else(|| notebook.metadata.kernelspec.language.clone())
        .or_else(|| notebook.metadata.kernelspec.name.clone())
        .unwrap_or_else(|| "autodetect".to_owned())
}

fn render_cell_input(cell: &Cell, language: &str) -> Result<String, RenderError> {
    let source = cell.source.joined();
    match cell.cell_type.as_str() {
        "markdown" => render_markdown(&source),
        "code" => render_code(&source, language),
        "raw" => Ok(format!("<pre>{}</pre>", escape_html(&source))),
        _ => Ok(String::new()),
    }
}

fn render_output(output: &Output) -> Result<String, RenderError> {
    Ok(match output.output_type.as_str() {
        "display_data" => render_data_output(&output.data)?,
        "execute_result" => render_data_output(&output.data)?,
        "error" => render_error_output(output),
        "stream" => format!("<pre>{}</pre>", escape_html(&output.text.joined())),
        _ => String::new(),
    })
}

fn class_token(value: &str) -> String {
    value
        .chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() || character == '-' {
                character
            } else {
                '-'
            }
        })
        .collect()
}

fn render_data_output(data: &OutputData) -> Result<String, RenderError> {
    if let Some(value) = &data.text_html {
        let html = value.joined();
        let unwrapped = html
            .strip_prefix("<div>")
            .and_then(|html| html.strip_suffix("</div>"))
            .unwrap_or(&html);
        return Ok(ammonia::Builder::default().clean(unwrapped).to_string());
    }
    if data.application_pdf.is_some() {
        return Ok("<pre>PDF output</pre>".to_owned());
    }
    if data.text_latex.is_some() {
        return Ok("<pre>LaTeX output</pre>".to_owned());
    }
    if data.image_svg.is_some() {
        return Ok("<pre>SVG output</pre>".to_owned());
    }
    if let Some(value) = &data.image_png {
        return render_image("png", &value.joined());
    }
    if let Some(value) = &data.image_jpeg {
        return render_image("jpeg", &value.joined());
    }
    if let Some(value) = &data.text_markdown {
        return render_markdown(&value.joined());
    }
    if let Some(value) = &data.text_plain {
        return Ok(format!("<pre>{}</pre>", escape_html(&value.joined())));
    }
    Ok(String::new())
}

fn render_image(kind: &str, encoded: &str) -> Result<String, RenderError> {
    let encoded = encoded
        .chars()
        .filter(|character| !character.is_ascii_whitespace())
        .collect::<String>();
    BASE64
        .decode(encoded.as_bytes())
        .map_err(|_| RenderError::new(format!("Invalid base64 data for image/{kind} output")))?;
    Ok(format!(
        "<img src=\"data:image/{kind};base64,{encoded}\" alt=\"Notebook output\">"
    ))
}

fn render_error_output(output: &Output) -> String {
    if output.traceback.is_empty() {
        return "<pre>An unknown error occurred</pre>".to_owned();
    }

    let converted = output
        .traceback
        .iter()
        .map(|line| ansi_to_html::convert(line).unwrap_or_else(|_| escape_html(line)))
        .collect::<Vec<_>>()
        .join("\n");
    format!("<pre>{converted}</pre>")
}

fn render_prompt(execution_count: Option<i64>) -> String {
    execution_count
        .map(|count| format!("[{count}]:"))
        .unwrap_or_default()
}

fn escape_html(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOTEBOOK: &str = r##"{
        "cells": [
            {"cell_type":"markdown","source":["# Heading"]},
            {"cell_type":"code","execution_count":1,"source":["print('hi')"],"outputs":[
                {"output_type":"stream","text":["<unsafe>\\n"]},
                {"output_type":"error","traceback":["\\u001b[31mError\\u001b[0m"]},
                {"output_type":"display_data","data":{"image/png":"aGVsbG8="}},
                {"output_type":"execute_result","execution_count":1,"data":{"text/html":["<div><b>safe</b><script>bad()</script></div>"]}}
            ]},
            {"cell_type":"raw","source":"<raw>"}
        ],
        "metadata":{"kernelspec":{"language":"python","name":"python3"}},
        "nbformat":4,
        "nbformat_minor":4
    }"##;

    #[test]
    fn renders_supported_cells_and_outputs_safely() {
        let html = render_notebook(NOTEBOOK).unwrap();
        assert!(html.starts_with("<div class=\"notebook\">"));
        assert!(html.contains("<h1>Heading</h1>"));
        assert!(html.contains("cell-code"));
        assert!(html.contains("output-stream"));
        assert!(html.contains("data:image/png;base64,aGVsbG8="));
        assert!(html.contains("&lt;unsafe&gt;"));
        assert!(html.contains("&lt;raw&gt;"));
        assert!(!html.contains("<script>"));
    }

    #[test]
    fn renders_every_supported_notebook_output_and_preserves_unknown_wrappers() {
        let source = r##"{
            "cells":[
                {"cell_type":"unknown type","source":["ignored"],"outputs":[]},
                {"cell_type":"code","execution_count":7,"source":["let value = 42"],"outputs":[
                    {"output_type":"display_data","data":{"application/pdf":"data"}},
                    {"output_type":"display_data","data":{"text/latex":"x"}},
                    {"output_type":"display_data","data":{"image/svg+xml":"<svg/>"}},
                    {"output_type":"display_data","data":{"image/jpeg":"aGVsbG8="}},
                    {"output_type":"display_data","data":{"text/markdown":"**bold**"}},
                    {"output_type":"execute_result","execution_count":7,"data":{"text/plain":"<plain>"}},
                    {"output_type":"error","traceback":["\u001b[31mError\u001b[0m"]},
                    {"output_type":"future output","data":{}}
                ]}
            ],
            "metadata":{"language_info":{"file_extension":".swift"},"kernelspec":{"language":"python","name":"python3"}},
            "nbformat":4
        }"##;

        let html = render_notebook(source).unwrap();
        assert!(html.contains("cell-unknown-type"));
        assert!(html.contains("<pre>PDF output</pre>"));
        assert!(html.contains("<pre>LaTeX output</pre>"));
        assert!(html.contains("<pre>SVG output</pre>"));
        assert!(html.contains("data:image/jpeg;base64,aGVsbG8="));
        assert!(html.contains("<strong>bold</strong>"));
        assert!(html.contains("&lt;plain&gt;"));
        assert!(html.contains("color:"));
        assert!(html.contains("output-future-output"));
        assert!(html.contains("storage type swift"));
        assert!(!html.contains("source python"));
    }

    #[test]
    fn rejects_invalid_notebooks_and_images() {
        assert!(render_notebook("not json").is_err());
        assert!(render_notebook(r#"{"cells":[],"metadata":{},"nbformat":3}"#).is_err());
        assert!(
            render_notebook(
                r#"{"cells":[{"cell_type":"code","outputs":[{"output_type":"display_data","data":{"image/png":"not base64"}}]}],"metadata":{},"nbformat":4}"#
            )
            .is_err()
        );
    }

    #[test]
    fn renders_repository_notebook_fixture() {
        let fixture = include_str!("../../GlanceTests/TestFiles/jupyter-notebook/example.ipynb");
        render_notebook(fixture).unwrap();
    }
}
