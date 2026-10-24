use crate::error::RenderError;
use crate::highlight::MarkdownHighlighter;
use comrak::adapters::CodefenceRendererAdapter;
use comrak::nodes::Sourcepos;
use comrak::options::Plugins;
use comrak::{Options, markdown_to_html_with_plugins};
use std::borrow::Cow;
use std::fmt;

const MERMAID_SENTINEL: &str = "<!--glance-renderer-mermaid-v1-->";

struct MermaidRenderer;

impl CodefenceRendererAdapter for MermaidRenderer {
    fn write(
        &self,
        output: &mut dyn fmt::Write,
        _lang: &str,
        _meta: &str,
        code: &str,
        _sourcepos: Option<Sourcepos>,
    ) -> fmt::Result {
        output.write_str(MERMAID_SENTINEL)?;
        output.write_str("<pre class=\"mermaid-source\" data-glance-mermaid=\"1\"><code>")?;
        comrak::html::escape(output, code)?;
        output.write_str("</code></pre>\n")
    }
}

/// Dollar math becomes `<span data-math-style="inline|display">` with escaped TeX source.
/// The Markdown preview uses that attribute as its trusted signal to load KaTeX, so keep the
/// element and attribute in sync with `MarkdownPreview.containsTrustedMath(in:)`.
pub(crate) fn render_markdown(source: &str) -> Result<String, RenderError> {
    render_markdown_with(source, true)
}

/// Notebook markdown cells keep dollar delimiters literal: the notebook page renders math with
/// KaTeX auto-render, which needs the original `$$…$$` source.
pub(crate) fn render_markdown_cell(source: &str) -> Result<String, RenderError> {
    render_markdown_with(source, false)
}

fn render_markdown_with(source: &str, math: bool) -> Result<String, RenderError> {
    let source = rewrite_front_matter(source);
    let mut options = Options::default();
    options.render.r#unsafe = false;
    options.extension.autolink = true;
    options.extension.math_dollars = math;
    options.extension.strikethrough = true;
    options.extension.table = true;
    options.extension.tasklist = true;

    let highlighter = MarkdownHighlighter;
    let mermaid_renderer = MermaidRenderer;
    let mut plugins = Plugins::default();
    plugins.render.codefence_syntax_highlighter = Some(&highlighter);
    for language in ["mermaid", "Mermaid", "MERMAID"] {
        plugins
            .render
            .codefence_renderers
            .insert(language.to_string(), &mermaid_renderer);
    }

    Ok(markdown_to_html_with_plugins(&source, &options, &plugins))
}

fn rewrite_front_matter(source: &str) -> Cow<'_, str> {
    let (line_ending, rest) = if let Some(rest) = source.strip_prefix("---\r\n") {
        ("\r\n", rest)
    } else if let Some(rest) = source.strip_prefix("---\n") {
        ("\n", rest)
    } else {
        return Cow::Borrowed(source);
    };
    let delimiter = format!("{line_ending}---{line_ending}");
    let Some(end) = rest.find(&delimiter) else {
        return Cow::Borrowed(source);
    };
    let front_matter = &rest[..end];
    let document = &rest[end + delimiter.len()..];
    Cow::Owned(format!("```yaml\n{front_matter}\n```\n{document}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn renders_gfm_and_highlighted_front_matter() {
        let html = render_markdown(
            "---\r\ntitle: Fixture\r\n---\r\n\r\n# Heading\r\n\r\n- [x] done\r\n\r\n~~old~~\r\n",
        )
        .unwrap();

        assert!(html.contains("<h1>Heading</h1>"));
        assert!(html.contains("<pre class=\"chroma\">"));
        assert!(html.contains("type=\"checkbox\""));
        assert!(html.contains("<del>old</del>"));
    }

    #[test]
    fn rejects_raw_html_and_dangerous_links() {
        let html =
            render_markdown("<script>alert('bad')</script>\n\n[bad](javascript:alert('bad'))\n")
                .unwrap();
        let lowercase = html.to_ascii_lowercase();
        assert!(!lowercase.contains("<script"));
        assert!(!lowercase.contains("javascript:"));
    }

    #[test]
    fn renders_mermaid_fences_with_a_trusted_marker() {
        let html = render_markdown(
            "# Diagram\n\n```mermaid\nflowchart LR\n    A[\"<b>one</b>\"] --> B\n```\n",
        )
        .unwrap();

        assert!(html.contains("<!--glance-renderer-mermaid-v1-->"));
        assert!(html.contains("<pre class=\"mermaid-source\" data-glance-mermaid=\"1\">"));
        assert!(html.contains("&lt;b&gt;one&lt;/b&gt;"));
        assert!(!html.contains("<pre class=\"chroma\">"));
    }

    #[test]
    fn renders_inline_and_display_math_with_renderer_markers() {
        let html =
            render_markdown("Inline $E = mc^2$ math.\n\n$$\n\\int_0^1 x^2 \\, dx\n$$\n").unwrap();

        assert!(html.contains("<span data-math-style=\"inline\">E = mc^2</span>"));
        assert!(html.contains("<span data-math-style=\"display\">"));
        assert!(html.contains("\\int_0^1 x^2 \\, dx"));
    }

    #[test]
    fn keeps_dollars_literal_in_code_spans_and_fences() {
        let html = render_markdown("`$x$`\n\n```text\n$y$\n```\n").unwrap();

        assert!(html.contains("<code>$x$</code>"));
        assert!(html.contains("<pre"));
        assert!(html.contains("$y$"));
        assert!(!html.contains("data-math-style"));
    }

    #[test]
    fn leaves_currency_and_unpaired_dollars_literal() {
        let html = render_markdown("$20,000 and $30,000\n\nlone $ dollar\n").unwrap();

        assert!(html.contains("$20,000 and $30,000"));
        assert!(html.contains("lone $ dollar"));
        assert!(!html.contains("data-math-style"));
    }

    #[test]
    fn escapes_math_source_instead_of_trusting_it() {
        let html = render_markdown("$<script>alert('bad')</script>$\n").unwrap();

        assert!(html.contains("data-math-style=\"inline\""));
        assert!(!html.to_ascii_lowercase().contains("<script"));
        assert!(html.contains("&lt;script&gt;"));
    }

    #[test]
    fn keeps_ordinary_fences_highlighted() {
        let html = render_markdown("```swift\nlet value = 42\n```\n").unwrap();

        assert!(html.contains("<pre class=\"chroma\">"));
        assert!(!html.contains("glance-renderer-mermaid-v1"));
    }

    #[test]
    fn user_markdown_cannot_forge_the_trusted_marker() {
        let html = render_markdown(
            "<pre data-glance-mermaid=\"1\"><!--glance-renderer-mermaid-v1--></pre>\n\n\
             `<!--glance-renderer-mermaid-v1-->`\n\n\
             ```html\n<!--glance-renderer-mermaid-v1-->\n```\n",
        )
        .unwrap();

        assert!(!html.contains("<!--glance-renderer-mermaid-v1-->"));
    }
}
