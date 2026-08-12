use crate::error::RenderError;
use crate::highlight::MarkdownHighlighter;
use comrak::options::Plugins;
use comrak::{Options, markdown_to_html_with_plugins};
use std::borrow::Cow;

pub(crate) fn render_markdown(source: &str) -> Result<String, RenderError> {
    let source = rewrite_front_matter(source);
    let mut options = Options::default();
    options.render.r#unsafe = false;
    options.extension.autolink = true;
    options.extension.strikethrough = true;
    options.extension.table = true;
    options.extension.tasklist = true;

    let highlighter = MarkdownHighlighter;
    let mut plugins = Plugins::default();
    plugins.render.codefence_syntax_highlighter = Some(&highlighter);

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
}
