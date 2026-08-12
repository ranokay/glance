mod error;
mod ffi;
mod highlight;
mod markdown;
mod model;
mod notebook;
mod sevenzip;
mod tar;
mod tsv;
mod zip;

pub use ffi::{
    GlanceRenderResult, glance_parse_tsv, glance_render_buffer_free, glance_render_code,
    glance_render_markdown, glance_render_notebook, glance_scan_seven_zip, glance_scan_tar,
    glance_scan_zip,
};

#[cfg(test)]
mod performance {
    use crate::{highlight, markdown, notebook};
    use std::time::{Duration, Instant};

    #[test]
    #[ignore = "run explicitly for migration performance evidence"]
    fn renderer_performance() {
        let code = "func render(value string) string { return value + \"!\" }\n".repeat(5_000);
        let markdown_source =
            "## Heading\n\n- item one\n- item two\n\n```swift\nlet value = 42\n```\n\n"
                .repeat(1_000);
        let notebook_source = r#"{"cells":[{"cell_type":"code","execution_count":1,"metadata":{},"outputs":[{"name":"stdout","output_type":"stream","text":["Hello world\\n"]}],"source":["print(\\\"Hello world\\\")"]}],"metadata":{"kernelspec":{"display_name":"Python 3","language":"python","name":"python3"}},"nbformat":4,"nbformat_minor":4}"#;

        measure("code", || highlight::render_code(&code, "swift").unwrap());
        measure("markdown", || {
            markdown::render_markdown(&markdown_source).unwrap()
        });
        measure("notebook", || {
            notebook::render_notebook(notebook_source).unwrap()
        });
    }

    fn measure(name: &str, mut render: impl FnMut() -> String) {
        _ = render();
        let mut durations = (0..30)
            .map(|_| {
                let start = Instant::now();
                _ = render();
                start.elapsed()
            })
            .collect::<Vec<_>>();
        durations.sort_unstable();
        let median = durations[durations.len() / 2];
        let p95 = durations[(durations.len() * 95).div_ceil(100) - 1];
        println!(
            "RUST {name} median={} p95={}",
            display(median),
            display(p95)
        );
    }

    fn display(duration: Duration) -> String {
        if duration.as_millis() > 0 {
            format!("{:.3}ms", duration.as_secs_f64() * 1_000.0)
        } else {
            format!("{:.3}us", duration.as_secs_f64() * 1_000_000.0)
        }
    }
}
