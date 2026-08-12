use crate::error::RenderError;
use std::fmt;
use std::sync::OnceLock;
use two_face::re_exports::syntect::html::{ClassStyle, ClassedHTMLGenerator};
use two_face::re_exports::syntect::parsing::{SyntaxReference, SyntaxSet};
use two_face::re_exports::syntect::util::LinesWithEndings;

static SYNTAX_SET: OnceLock<SyntaxSet> = OnceLock::new();

fn syntax_set() -> &'static SyntaxSet {
    SYNTAX_SET.get_or_init(two_face::syntax::extra_newlines)
}

pub(crate) fn render_code(source: &str, lexer: &str) -> Result<String, RenderError> {
    let highlighted = render_code_body(source, lexer)?;
    Ok(format!(
        "<pre class=\"chroma\"><code>{highlighted}</code></pre>"
    ))
}

pub(crate) fn render_code_body(source: &str, lexer: &str) -> Result<String, RenderError> {
    let syntax_set = syntax_set();
    let syntax = select_syntax(syntax_set, source, lexer);
    let mut generator =
        ClassedHTMLGenerator::new_with_class_style(syntax, syntax_set, ClassStyle::Spaced);

    for line in LinesWithEndings::from(source) {
        generator
            .parse_html_for_line_which_includes_newline(line)
            .map_err(|error| {
                RenderError::new(format!("Could not highlight source code: {error}"))
            })?;
    }

    Ok(generator.finalize())
}

fn select_syntax<'a>(syntax_set: &'a SyntaxSet, source: &str, lexer: &str) -> &'a SyntaxReference {
    if !lexer.is_empty() && lexer != "autodetect" {
        let extension = lexer.trim_start_matches('.');
        for candidate in lexer_candidates(lexer)
            .iter()
            .copied()
            .chain(std::iter::once(extension))
        {
            if let Some(syntax) = syntax_set.find_syntax_by_token(candidate) {
                return syntax;
            }
            if let Some(syntax) = syntax_set.find_syntax_by_extension(candidate) {
                return syntax;
            }
            if let Some(syntax) = syntax_set.find_syntax_by_name(candidate) {
                return syntax;
            }
        }
    }

    let first_line = source.lines().next().unwrap_or_default();
    if let Some(syntax) = syntax_set.find_syntax_by_first_line(first_line) {
        return syntax;
    }

    let trimmed = source.trim_start();
    if (trimmed.starts_with('{') || trimmed.starts_with('['))
        && serde_json::from_str::<serde_json::Value>(source).is_ok()
        && let Some(syntax) = syntax_set.find_syntax_by_token("json")
    {
        return syntax;
    }
    if trimmed.starts_with('<')
        && let Some(syntax) = syntax_set.find_syntax_by_token("xml")
    {
        return syntax;
    }

    syntax_set.find_syntax_plain_text()
}

fn lexer_candidates(lexer: &str) -> &'static [&'static str] {
    match lexer.trim_start_matches('.').to_ascii_lowercase().as_str() {
        "applescript" | "scpt" | "scptd" => &["AppleScript", "applescript"],
        "bash" | "bashrc" | "zsh" | "zshrc" => &["Bash", "Shell-Unix-Generic", "sh"],
        "c" => &["C", "c"],
        "dockerfile" => &["Dockerfile"],
        "elisp" => &["Lisp", "lisp"],
        "gemfile" | "rakefile" => &["Ruby", "rb"],
        "handlebars" => &["HTML (Handlebars)", "HTML", "html"],
        "hcl" => &["Terraform", "HCL", "tf"],
        "ini" => &["INI", "ini"],
        "js" => &["JavaScript", "js"],
        "json" => &["JSON", "json"],
        "makefile" => &["Makefile"],
        "pkgbuild" => &["Bash", "sh"],
        "swift" => &["Swift", "swift"],
        "tex" => &["LaTeX", "TeX", "tex"],
        "txt" => &["Plain Text", "txt"],
        "twig" => &["Jinja2", "HTML", "html"],
        "vimrc" => &["VimL", "vim"],
        "xml" => &["XML", "xml"],
        "yaml" | "yml" => &["YAML", "yaml"],
        _ => &[],
    }
}

pub(crate) struct MarkdownHighlighter;

impl comrak::adapters::SyntaxHighlighterAdapter for MarkdownHighlighter {
    fn write_highlighted(
        &self,
        output: &mut dyn fmt::Write,
        language: Option<&str>,
        code: &str,
    ) -> fmt::Result {
        let highlighted =
            render_code_body(code, language.unwrap_or("autodetect")).map_err(|_| fmt::Error)?;
        output.write_str(&highlighted)
    }

    fn write_pre_tag<'a>(
        &self,
        output: &mut dyn fmt::Write,
        _attributes: std::collections::HashMap<&'static str, std::borrow::Cow<'a, str>>,
    ) -> fmt::Result {
        output.write_str("<pre class=\"chroma\">")
    }

    fn write_code_tag<'a>(
        &self,
        output: &mut dyn fmt::Write,
        _attributes: std::collections::HashMap<&'static str, std::borrow::Cow<'a, str>>,
    ) -> fmt::Result {
        output.write_str("<code>")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn highlights_explicit_and_detected_source() {
        let empty = render_code("", "swift").unwrap();
        assert_eq!(empty, "<pre class=\"chroma\"><code></code></pre>");

        let swift = render_code("let value = 42\n", "swift").unwrap();
        assert!(swift.starts_with("<pre class=\"chroma\"><code>"));
        assert!(swift.contains("span"));

        let unicode = render_code("let cafe = \"\u{2615}\"\n", "swift").unwrap();
        assert!(unicode.contains('\u{2615}'));

        let shell = render_code("#!/bin/zsh\necho hello\n", "autodetect").unwrap();
        assert!(shell.contains("span"));

        let json = render_code("{\"value\": 42}", "unknown-extension").unwrap();
        assert!(json.contains("span"));

        let rust = select_syntax(syntax_set(), "fn main() {}\n", "rs");
        assert_ne!(rust.name, "Plain Text");

        let xml = select_syntax(syntax_set(), "<root />\n", "unknown-extension");
        assert_ne!(xml.name, "Plain Text");

        let plain = select_syntax(syntax_set(), "ordinary prose\n", "unknown-extension");
        assert_eq!(plain.name, "Plain Text");
    }

    #[test]
    fn escapes_source_html() {
        let html = render_code("<script>alert('bad')</script>\n", "js").unwrap();
        assert!(!html.contains("<script>"));
        assert!(html.contains("&lt;"));
    }

    #[test]
    fn supports_every_registry_lexer_alias() {
        let aliases = [
            ".bashrc",
            "bash",
            "ini",
            "elisp",
            ".vimrc",
            "zsh",
            "txt",
            ".zshrc",
            "Dockerfile",
            "Gemfile",
            "Makefile",
            "PKGBUILD",
            "Rakefile",
            "json",
            "js",
            "tex",
            "xml",
            "handlebars",
            "twig",
            "hcl",
            "applescript",
            "c",
            "swift",
            "yaml",
            "autodetect",
        ];

        for alias in aliases {
            let html = render_code("let value = \"test\"\n", alias).unwrap();
            assert!(html.starts_with("<pre class=\"chroma\">"), "{alias}");
        }
    }

    #[test]
    fn resolves_registered_non_plain_lexer_aliases() {
        let syntax_set = syntax_set();
        let aliases = [
            ".bashrc",
            "bash",
            "ini",
            "elisp",
            ".vimrc",
            "zsh",
            ".zshrc",
            "Dockerfile",
            "Gemfile",
            "Makefile",
            "PKGBUILD",
            "Rakefile",
            "json",
            "js",
            "tex",
            "xml",
            "handlebars",
            "twig",
            "hcl",
            "applescript",
            "c",
        ];

        for alias in aliases {
            let syntax = select_syntax(syntax_set, "let value = 42\n", alias);
            assert_ne!(syntax.name, "Plain Text", "{alias}");
        }
    }
}
