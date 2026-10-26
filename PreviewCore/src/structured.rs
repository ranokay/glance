use crate::error::CoreError;
use quick_xml::Reader;
use quick_xml::events::{BytesStart, Event};
use serde_json::Value as JsonValue;
use std::fmt::Write;
use std::io::Cursor;

/// Files above this size are not parsed; the preview shows a truncation notice instead.
pub(crate) const MAX_INPUT_BYTES: usize = 4 * 1_024 * 1_024;
pub(crate) const MAX_NODES: usize = 20_000;
pub(crate) const MAX_DEPTH: usize = 64;
pub(crate) const MAX_OUTPUT_BYTES: usize = 1_000_000;

/// Containers shallower than this start expanded; deeper ones start collapsed.
const OPEN_DEPTH: usize = 3;
const MAX_VALUE_CHARS: usize = 4_000;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum StructuredFormat {
    Json,
    Plist,
    Xml,
}

impl StructuredFormat {
    pub(crate) fn from_ffi(value: u8) -> Result<Self, CoreError> {
        match value {
            0 => Ok(Self::Json),
            1 => Ok(Self::Plist),
            2 => Ok(Self::Xml),
            _ => Err(CoreError::invalid("Unknown structured preview format")),
        }
    }

    fn label(self) -> &'static str {
        match self {
            Self::Json => "JSON",
            Self::Plist => "property list",
            Self::Xml => "XML",
        }
    }
}

pub(crate) fn render_structured(
    data: &[u8],
    format: StructuredFormat,
) -> Result<String, CoreError> {
    if data.len() > MAX_INPUT_BYTES {
        return Ok(truncated_page(format!(
            "this {} file is larger than the {} MB preview limit",
            format.label(),
            MAX_INPUT_BYTES / (1_024 * 1_024),
        )));
    }

    let mut budget = Budget::default();
    let tree = match format {
        StructuredFormat::Json => json_tree(data, &mut budget)?,
        StructuredFormat::Plist => plist_tree(data, &mut budget)?,
        StructuredFormat::Xml => xml_tree(data, &mut budget)?,
    };

    let mut renderer = Renderer::default();
    renderer.render(&tree, 0);
    if budget.truncated {
        renderer.truncated = true;
    }
    Ok(renderer.finish())
}

fn json_tree(data: &[u8], budget: &mut Budget) -> Result<Node, CoreError> {
    // serde_json refuses to recurse past its own limit. Detect that case first so an
    // extremely deep document still gets a truncation notice instead of a text fallback.
    if json_exceeds_parser_depth(data) {
        budget.truncated = true;
        return Ok(Node::Ellipsis);
    }
    let value: JsonValue = serde_json::from_slice(data)
        .map_err(|error| CoreError::parse(format!("Could not parse JSON: {error}")))?;
    Ok(json_node(&value, 0, budget))
}

/// String-aware bracket depth scan, independent of serde_json's recursion limit.
fn json_exceeds_parser_depth(data: &[u8]) -> bool {
    const PARSER_DEPTH: usize = 120;
    let mut depth = 0usize;
    let mut in_string = false;
    let mut escaped = false;
    for byte in data {
        if in_string {
            if escaped {
                escaped = false;
            } else if *byte == b'\\' {
                escaped = true;
            } else if *byte == b'"' {
                in_string = false;
            }
            continue;
        }
        match byte {
            b'"' => in_string = true,
            b'{' | b'[' => {
                depth += 1;
                if depth > PARSER_DEPTH {
                    return true;
                }
            }
            b'}' | b']' => depth = depth.saturating_sub(1),
            _ => {}
        }
    }
    false
}

fn json_node(value: &JsonValue, depth: usize, budget: &mut Budget) -> Node {
    if !budget.take(depth) {
        return Node::Ellipsis;
    }
    match value {
        JsonValue::Object(object) => {
            let mut entries = Vec::new();
            for (key, value) in object {
                let label = Label::Key {
                    text: budget.text(key),
                    quoted: true,
                };
                let node = json_node(value, depth + 1, budget);
                entries.push(Entry { label, node });
                if budget.exhausted {
                    break;
                }
            }
            Node::Object(entries)
        }
        JsonValue::Array(array) => {
            let mut entries = Vec::new();
            for (index, value) in array.iter().enumerate() {
                let node = json_node(value, depth + 1, budget);
                entries.push(Entry {
                    label: Label::Index(index),
                    node,
                });
                if budget.exhausted {
                    break;
                }
            }
            Node::Array(entries)
        }
        JsonValue::String(value) => Node::String(budget.text(value)),
        JsonValue::Number(value) => Node::Number(value.to_string()),
        JsonValue::Bool(value) => Node::Boolean(*value),
        JsonValue::Null => Node::Null,
    }
}

fn plist_tree(data: &[u8], budget: &mut Budget) -> Result<Node, CoreError> {
    // Consume the event stream directly so repeated binary-plist references cannot expand
    // into a full value tree before the node budget applies.
    let events = plist::stream::Reader::new(Cursor::new(data));
    let mut stack: Vec<PlistFrame> = Vec::new();
    let mut roots = Vec::new();

    for event in events {
        let event = event
            .map_err(|error| CoreError::parse(format!("Could not parse property list: {error}")))?;
        match event {
            plist::stream::Event::StartArray(_) => {
                if !budget.take(stack.len()) {
                    mark_plist_truncated(&mut stack, &mut roots);
                    break;
                }
                stack.push(PlistFrame::Array(Vec::new()));
            }
            plist::stream::Event::StartDictionary(_) => {
                if !budget.take(stack.len()) {
                    mark_plist_truncated(&mut stack, &mut roots);
                    break;
                }
                stack.push(PlistFrame::Dictionary {
                    entries: Vec::new(),
                    pending_key: None,
                });
            }
            plist::stream::Event::EndCollection => {
                let Some(frame) = stack.pop() else {
                    return Err(CoreError::parse(
                        "Property list closes a collection that was not opened",
                    ));
                };
                if !frame.is_complete() {
                    return Err(CoreError::parse(
                        "Property list dictionary is missing a value",
                    ));
                }
                append_plist_node(&mut stack, &mut roots, frame.into_node())?;
            }
            event => {
                if !budget.take(stack.len()) {
                    mark_plist_truncated(&mut stack, &mut roots);
                    break;
                }
                let node = plist_event_node(event, budget);
                append_plist_node(&mut stack, &mut roots, node)?;
            }
        }
    }

    if budget.exhausted {
        while let Some(frame) = stack.pop() {
            append_plist_node(&mut stack, &mut roots, frame.into_node())?;
        }
    } else if !stack.is_empty() {
        return Err(CoreError::parse(
            "Property list ended before every collection was closed",
        ));
    }

    if roots.len() != 1 {
        return Err(CoreError::parse(
            "Property list does not contain a single root value",
        ));
    }
    Ok(roots.pop().expect("length checked"))
}

enum PlistFrame {
    Array(Vec<Entry>),
    Dictionary {
        entries: Vec<Entry>,
        pending_key: Option<String>,
    },
}

impl PlistFrame {
    fn is_complete(&self) -> bool {
        match self {
            Self::Array(_) => true,
            Self::Dictionary { pending_key, .. } => pending_key.is_none(),
        }
    }

    fn into_node(self) -> Node {
        match self {
            Self::Array(entries) => Node::Array(entries),
            Self::Dictionary { entries, .. } => Node::Object(entries),
        }
    }
}

fn plist_event_node(event: plist::stream::Event<'static>, budget: &mut Budget) -> Node {
    match event {
        plist::stream::Event::Boolean(value) => Node::Boolean(value),
        plist::stream::Event::Data(bytes) => Node::Data(bytes.len()),
        plist::stream::Event::Date(date) => Node::Date(date.to_xml_format()),
        plist::stream::Event::Integer(value) => Node::Number(value.to_string()),
        plist::stream::Event::Real(value) => Node::Number(value.to_string()),
        plist::stream::Event::String(value) => Node::String(budget.text(&value)),
        plist::stream::Event::Uid(value) => Node::Uid(value.get()),
        _ => Node::String("Unsupported property list value".to_owned()),
    }
}

fn append_plist_node(
    stack: &mut [PlistFrame],
    roots: &mut Vec<Node>,
    node: Node,
) -> Result<(), CoreError> {
    match stack.last_mut() {
        None => roots.push(node),
        Some(PlistFrame::Array(entries)) => entries.push(Entry {
            label: Label::Index(entries.len()),
            node,
        }),
        Some(PlistFrame::Dictionary {
            entries,
            pending_key,
        }) => {
            if let Some(key) = pending_key.take() {
                entries.push(Entry {
                    label: Label::Key {
                        text: key,
                        quoted: false,
                    },
                    node,
                });
            } else {
                match node {
                    Node::String(key) => *pending_key = Some(key),
                    _ => {
                        return Err(CoreError::parse(
                            "Property list dictionary key is not a string",
                        ));
                    }
                }
            }
        }
    }
    Ok(())
}

fn mark_plist_truncated(stack: &mut [PlistFrame], roots: &mut Vec<Node>) {
    match stack.last_mut() {
        Some(PlistFrame::Array(entries)) => entries.push(Entry {
            label: Label::Index(entries.len()),
            node: Node::Ellipsis,
        }),
        Some(PlistFrame::Dictionary {
            entries,
            pending_key,
        }) => {
            let key = pending_key.take().unwrap_or_else(|| "…".to_owned());
            entries.push(Entry {
                label: Label::Key {
                    text: key,
                    quoted: false,
                },
                node: Node::Ellipsis,
            });
        }
        None => roots.push(Node::Ellipsis),
    }
}

fn xml_tree(data: &[u8], budget: &mut Budget) -> Result<Node, CoreError> {
    let mut reader = Reader::from_reader(Cursor::new(data));
    let mut buffer = Vec::new();
    let mut stack: Vec<XmlFrame> = Vec::new();
    let mut roots = Vec::new();
    let mut pending_text = String::new();

    loop {
        let event = reader
            .read_event_into(&mut buffer)
            .map_err(|error| CoreError::parse(format!("Could not parse XML: {error}")))?;
        match event {
            Event::Start(start) => {
                flush_xml_text(&mut pending_text, &mut stack, &mut roots, budget)?;
                if budget.exhausted || !budget.take(stack.len()) {
                    break;
                }
                stack.push(xml_frame(&start, budget)?);
            }
            Event::Empty(start) => {
                flush_xml_text(&mut pending_text, &mut stack, &mut roots, budget)?;
                if budget.exhausted || !budget.take(stack.len()) {
                    break;
                }
                let frame = xml_frame(&start, budget)?;
                push_xml_node(
                    &mut stack,
                    &mut roots,
                    Node::Element {
                        name: frame.name,
                        attributes: frame.attributes,
                        children: Vec::new(),
                        self_closing: true,
                    },
                );
            }
            Event::End(_) => {
                flush_xml_text(&mut pending_text, &mut stack, &mut roots, budget)?;
                if budget.exhausted {
                    break;
                }
                let Some(frame) = stack.pop() else {
                    return Err(CoreError::parse(
                        "XML closes an element that was not opened",
                    ));
                };
                push_xml_node(
                    &mut stack,
                    &mut roots,
                    Node::Element {
                        name: frame.name,
                        attributes: frame.attributes,
                        children: frame.children,
                        self_closing: false,
                    },
                );
            }
            Event::Text(text) => pending_text.push_str(&xml_text(&text)),
            Event::CData(text) => {
                pending_text.push_str(text.as_ref());
            }
            Event::Comment(comment) => {
                flush_xml_text(&mut pending_text, &mut stack, &mut roots, budget)?;
                if budget.exhausted || !budget.take(stack.len()) {
                    break;
                }
                let value = comment.as_ref().to_owned();
                push_xml_node(&mut stack, &mut roots, Node::Comment(budget.text(&value)));
            }
            Event::GeneralRef(reference) => {
                pending_text.push_str(&reference_text(reference.as_ref()));
            }
            Event::Eof => {
                flush_xml_text(&mut pending_text, &mut stack, &mut roots, budget)?;
                break;
            }
            Event::Decl(_) | Event::PI(_) | Event::DocType(_) => {
                flush_xml_text(&mut pending_text, &mut stack, &mut roots, budget)?;
                if budget.exhausted {
                    break;
                }
            }
        }
    }

    let unterminated = !stack.is_empty() && !budget.exhausted;
    while let Some(frame) = stack.pop() {
        push_xml_node(
            &mut stack,
            &mut roots,
            Node::Element {
                name: frame.name,
                attributes: frame.attributes,
                children: frame.children,
                self_closing: false,
            },
        );
    }
    if unterminated {
        return Err(CoreError::parse(
            "XML ended before every element was closed",
        ));
    }
    let element_count = roots
        .iter()
        .filter(|node| matches!(node, Node::Element { .. }))
        .count();
    if element_count != 1 {
        return Err(CoreError::parse(if element_count == 0 {
            "XML has no root element"
        } else {
            "XML has more than one root element"
        }));
    }

    Ok(Node::Fragment(roots))
}

fn flush_xml_text(
    pending: &mut String,
    stack: &mut [XmlFrame],
    roots: &mut Vec<Node>,
    budget: &mut Budget,
) -> Result<(), CoreError> {
    if pending.is_empty() {
        return Ok(());
    }
    let preserve_space = preserves_xml_space(stack);
    let value = if preserve_space {
        pending.as_str()
    } else {
        pending.trim_end()
    };
    if value.is_empty() || (!preserve_space && value.trim().is_empty()) {
        pending.clear();
        return Ok(());
    }
    if stack.is_empty() {
        return Err(CoreError::parse(
            "XML text appears outside the root element",
        ));
    }
    if budget.take(stack.len()) {
        let text = budget.text(value);
        push_xml_node(stack, roots, Node::Text(text));
    }
    pending.clear();
    Ok(())
}

fn preserves_xml_space(stack: &[XmlFrame]) -> bool {
    for frame in stack.iter().rev() {
        if let Some((_, value)) = frame
            .attributes
            .iter()
            .find(|(name, _)| name == "xml:space")
        {
            return value == "preserve";
        }
    }
    false
}

struct XmlFrame {
    name: String,
    attributes: Vec<(String, String)>,
    children: Vec<Node>,
}

fn xml_frame(start: &BytesStart<'_>, budget: &mut Budget) -> Result<XmlFrame, CoreError> {
    let mut attributes = Vec::new();
    for attribute in start.attributes() {
        let attribute = attribute
            .map_err(|error| CoreError::parse(format!("Could not parse XML attribute: {error}")))?;
        let name = budget.text(attribute.key.as_ref());
        let value = attribute
            .normalized_value(quick_xml::XmlVersion::Implicit1_0)
            .map(|value| value.into_owned())
            .unwrap_or_else(|_| attribute.value.as_ref().to_owned());
        attributes.push((name, budget.text(&value)));
    }
    Ok(XmlFrame {
        name: budget.text(start.name().as_ref()),
        attributes,
        children: Vec::new(),
    })
}

fn xml_text(text: &quick_xml::events::BytesText<'_>) -> String {
    quick_xml::escape::unescape(text.as_ref())
        .map(|value| value.into_owned())
        .unwrap_or_else(|_| text.as_ref().to_owned())
}

fn push_xml_node(stack: &mut [XmlFrame], roots: &mut Vec<Node>, node: Node) {
    match stack.last_mut() {
        Some(frame) => frame.children.push(node),
        None => roots.push(node),
    }
}

/// Resolves only predefined and numeric character references. Named entities declared in a
/// document type definition are shown literally, so previews never resolve external entities.
fn reference_text(name: &str) -> String {
    match name {
        "lt" => "<".to_owned(),
        "gt" => ">".to_owned(),
        "amp" => "&".to_owned(),
        "quot" => "\"".to_owned(),
        "apos" => "'".to_owned(),
        _ => {
            let code_point = name
                .strip_prefix("#x")
                .or_else(|| name.strip_prefix("#X"))
                .and_then(|value| u32::from_str_radix(value, 16).ok())
                .or_else(|| name.strip_prefix('#').and_then(|value| value.parse().ok()));
            code_point
                .and_then(char::from_u32)
                .map(|character| character.to_string())
                .unwrap_or_else(|| format!("&{name};"))
        }
    }
}

#[derive(Default)]
struct Budget {
    nodes: usize,
    truncated: bool,
    exhausted: bool,
}

impl Budget {
    fn take(&mut self, depth: usize) -> bool {
        if self.exhausted {
            return false;
        }
        if depth > MAX_DEPTH {
            self.truncated = true;
            self.exhausted = true;
            return false;
        }
        self.nodes += 1;
        if self.nodes > MAX_NODES {
            self.truncated = true;
            self.exhausted = true;
            return false;
        }
        true
    }

    fn text(&mut self, value: &str) -> String {
        if value.chars().count() <= MAX_VALUE_CHARS {
            return value.to_owned();
        }
        self.truncated = true;
        let mut truncated = value.chars().take(MAX_VALUE_CHARS).collect::<String>();
        truncated.push('…');
        truncated
    }
}

enum Node {
    Object(Vec<Entry>),
    Array(Vec<Entry>),
    String(String),
    Number(String),
    Boolean(bool),
    Null,
    Date(String),
    Data(usize),
    Uid(u64),
    Element {
        name: String,
        attributes: Vec<(String, String)>,
        children: Vec<Node>,
        self_closing: bool,
    },
    Fragment(Vec<Node>),
    Text(String),
    Comment(String),
    Ellipsis,
}

struct Entry {
    label: Label,
    node: Node,
}

enum Label {
    Key { text: String, quoted: bool },
    Index(usize),
    None,
}

#[derive(Default)]
struct Renderer {
    html: String,
    truncated: bool,
}

impl Renderer {
    fn finish(mut self) -> String {
        if self.truncated {
            self.html.push_str(
                "<p class=\"structured-truncated\" role=\"note\">Preview truncated — the document exceeded the preview limits.</p>",
            );
        }
        format!("<div class=\"structured-preview\">{}</div>", self.html)
    }

    fn render(&mut self, node: &Node, depth: usize) {
        self.render_node(node, &Label::None, depth);
    }

    fn render_entry(&mut self, entry: &Entry, depth: usize) {
        self.render_node(&entry.node, &entry.label, depth);
    }

    fn render_node(&mut self, node: &Node, label: &Label, depth: usize) {
        if self.limit_reached() {
            return;
        }
        match node {
            Node::Object(entries) => {
                self.render_container(label, ContainerKind::Object, entries, depth);
            }
            Node::Array(entries) => {
                self.render_container(label, ContainerKind::Array, entries, depth);
            }
            Node::String(value) => {
                self.render_scalar(label, "string", &format!("\"{value}\""));
            }
            Node::Number(value) => self.render_scalar(label, "number", value),
            Node::Boolean(value) => {
                self.render_scalar(label, "boolean", if *value { "true" } else { "false" });
            }
            Node::Null => self.render_scalar(label, "null", "null"),
            Node::Date(value) => self.render_scalar(label, "date", value),
            Node::Data(bytes) => {
                self.render_scalar(label, "data", &format!("{bytes} bytes of data"));
            }
            Node::Uid(value) => self.render_scalar(label, "number", &format!("#{value}")),
            Node::Element {
                name,
                attributes,
                children,
                self_closing,
            } => self.render_element(name, attributes, children, *self_closing, depth),
            Node::Fragment(children) => {
                for child in children {
                    self.render(child, depth);
                    if self.limit_reached() {
                        break;
                    }
                }
            }
            Node::Text(value) => {
                self.html
                    .push_str("<div class=\"structured-node structured-text\">");
                push_escaped(&mut self.html, value);
                self.html.push_str("</div>");
            }
            Node::Comment(value) => {
                self.html
                    .push_str("<div class=\"structured-node structured-comment\">&lt;!--");
                push_escaped(&mut self.html, value);
                self.html.push_str("--&gt;</div>");
            }
            Node::Ellipsis => {
                self.truncated = true;
                self.html
                    .push_str("<div class=\"structured-node structured-ellipsis\">…</div>");
            }
        }
    }

    fn render_container(
        &mut self,
        label: &Label,
        kind: ContainerKind,
        entries: &[Entry],
        depth: usize,
    ) {
        let (open, close, unit) = kind.delimiters();
        if entries.is_empty() {
            self.html
                .push_str("<div class=\"structured-node structured-row\">");
            render_label(&mut self.html, label);
            write!(
                self.html,
                "<span class=\"structured-punct\">{open}{close}</span></div>"
            )
            .expect("writing to a string cannot fail");
            return;
        }

        self.html
            .push_str("<details class=\"structured-node structured-container\"");
        if depth < OPEN_DEPTH {
            self.html.push_str(" open");
        }
        self.html
            .push_str("><summary class=\"structured-summary\">");
        render_label(&mut self.html, label);
        let plural = if entries.len() == 1 {
            unit.to_owned()
        } else {
            format!("{unit}s")
        };
        write!(
            self.html,
            "<span class=\"structured-punct\">{open}</span><span class=\"structured-meta\">{} {plural}</span></summary><div class=\"structured-children\">",
            entries.len()
        )
        .expect("writing to a string cannot fail");
        for entry in entries {
            self.render_entry(entry, depth + 1);
            if self.limit_reached() {
                break;
            }
        }
        self.html.push_str("</div>");
        write!(
            self.html,
            "<div class=\"structured-closing\"><span class=\"structured-punct\">{close}</span></div></details>"
        )
        .expect("writing to a string cannot fail");
    }

    fn render_scalar(&mut self, label: &Label, class: &str, value: &str) {
        self.html
            .push_str("<div class=\"structured-node structured-row\">");
        render_label(&mut self.html, label);
        write!(
            self.html,
            "<span class=\"structured-value structured-{class}\">{}</span></div>",
            escape_html(value)
        )
        .expect("writing to a string cannot fail");
    }

    fn render_element(
        &mut self,
        name: &str,
        attributes: &[(String, String)],
        children: &[Node],
        self_closing: bool,
        depth: usize,
    ) {
        if self_closing || children.is_empty() {
            self.html
                .push_str("<div class=\"structured-node structured-row\">");
            self.write_open_tag(name, attributes);
            self.html
                .push_str("<span class=\"structured-punct\"> /&gt;</span></div>");
            return;
        }

        self.html
            .push_str("<details class=\"structured-node structured-container\"");
        if depth < OPEN_DEPTH {
            self.html.push_str(" open");
        }
        self.html
            .push_str("><summary class=\"structured-summary\">");
        let truncated = self.write_open_tag(name, attributes);
        self.html
            .push_str("<span class=\"structured-punct\">&gt;</span></summary><div class=\"structured-children\">");
        if !truncated {
            for child in children {
                self.render(child, depth + 1);
                if self.limit_reached() {
                    break;
                }
            }
        }
        self.html.push_str("</div><div class=\"structured-closing\"><span class=\"structured-punct\">&lt;/</span><span class=\"structured-tag\">");
        push_escaped(&mut self.html, name);
        self.html
            .push_str("</span><span class=\"structured-punct\">&gt;</span></div></details>");
    }

    /// Writes the opening tag and reports whether the output cap stopped its attributes early.
    fn write_open_tag(&mut self, name: &str, attributes: &[(String, String)]) -> bool {
        self.html.push_str(
            "<span class=\"structured-punct\">&lt;</span><span class=\"structured-tag\">",
        );
        push_escaped(&mut self.html, name);
        self.html.push_str("</span>");
        for (key, value) in attributes {
            if self.html.len() >= MAX_OUTPUT_BYTES {
                self.truncated = true;
                self.html.push('…');
                return true;
            }
            self.html.push_str(" <span class=\"structured-attribute\">");
            push_escaped(&mut self.html, key);
            self.html
                .push_str("</span><span class=\"structured-punct\">=</span><span class=\"structured-string\">\"");
            push_escaped(&mut self.html, value);
            self.html.push_str("\"</span>");
        }
        false
    }

    fn limit_reached(&mut self) -> bool {
        if self.html.len() < MAX_OUTPUT_BYTES {
            return false;
        }
        self.truncated = true;
        true
    }
}

#[derive(Clone, Copy)]
enum ContainerKind {
    Object,
    Array,
}

impl ContainerKind {
    fn delimiters(self) -> (&'static str, &'static str, &'static str) {
        match self {
            Self::Object => ("{", "}", "key"),
            Self::Array => ("[", "]", "item"),
        }
    }
}

fn render_label(html: &mut String, label: &Label) {
    match label {
        Label::Key { text, quoted } => {
            html.push_str("<span class=\"structured-key\">");
            if *quoted {
                html.push('"');
            }
            push_escaped(html, text);
            if *quoted {
                html.push('"');
            }
            html.push_str("</span><span class=\"structured-punct\">:</span> ");
        }
        Label::Index(index) => {
            write!(
                html,
                "<span class=\"structured-index\">{index}</span><span class=\"structured-punct\">:</span> "
            )
            .expect("writing to a string cannot fail");
        }
        Label::None => {}
    }
}

fn truncated_page(reason: String) -> String {
    format!(
        "<div class=\"structured-preview\"><p class=\"structured-truncated\" role=\"note\">Preview truncated — {reason}.</p></div>"
    )
}

fn escape_html(value: &str) -> String {
    let mut escaped = String::with_capacity(value.len());
    push_escaped(&mut escaped, value);
    escaped
}

fn push_escaped(html: &mut String, value: &str) {
    for character in value.chars() {
        match character {
            '&' => html.push_str("&amp;"),
            '<' => html.push_str("&lt;"),
            '>' => html.push_str("&gt;"),
            '"' => html.push_str("&quot;"),
            '\'' => html.push_str("&#39;"),
            _ => html.push(character),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(name: &str) -> Vec<u8> {
        std::fs::read(
            std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../GlanceTests/TestFiles/structured")
                .join(name),
        )
        .unwrap()
    }

    fn render_json(source: &str) -> String {
        render_structured(source.as_bytes(), StructuredFormat::Json).unwrap()
    }

    /// A valid binary property list whose single-element array chain is `depth` levels deep.
    fn deep_binary_plist(depth: usize) -> Vec<u8> {
        let mut objects = vec![vec![0x51, b'x']];
        for index in 1..=depth {
            let mut object = vec![0xA1];
            object.extend_from_slice(&binary_reference((index - 1) as u32));
            objects.push(object);
        }
        binary_plist(objects, depth)
    }

    /// A binary plist whose array chain references the previous level twice, so its expanded
    /// tree is exponential in the file size.
    fn amplified_binary_plist(depth: usize) -> Vec<u8> {
        let mut objects = vec![vec![0x51, b'x']];
        for index in 1..=depth {
            let mut object = vec![0xA2];
            for _ in 0..2 {
                object.extend_from_slice(&binary_reference((index - 1) as u32));
            }
            objects.push(object);
        }
        binary_plist(objects, depth)
    }

    fn binary_reference(value: u32) -> [u8; 3] {
        let bytes = value.to_be_bytes();
        [bytes[1], bytes[2], bytes[3]]
    }

    fn binary_plist(objects: Vec<Vec<u8>>, top_object: usize) -> Vec<u8> {
        const OBJECT_REFERENCE_BYTES: usize = 3;
        let mut bytes = b"bplist00".to_vec();
        let mut offsets = Vec::new();
        for object in &objects {
            offsets.push(bytes.len());
            bytes.extend_from_slice(object);
        }
        let offset_table_offset = bytes.len();
        for offset in offsets {
            bytes.extend_from_slice(&(offset as u32).to_be_bytes());
        }
        bytes.extend_from_slice(&[0; 6]);
        bytes.push(4);
        bytes.push(OBJECT_REFERENCE_BYTES as u8);
        bytes.extend_from_slice(&(objects.len() as u64).to_be_bytes());
        bytes.extend_from_slice(&(top_object as u64).to_be_bytes());
        bytes.extend_from_slice(&(offset_table_offset as u64).to_be_bytes());
        bytes
    }

    #[test]
    fn renders_nested_json_in_authored_order_and_escapes_scalars() {
        let html = render_json(
            r#"{"z":1,"a":{"b":[true,false,null,"<script>alert('x')</script>",1.5]},"empty":{},"list":[]}"#,
        );

        assert!(html.contains("structured-container"));
        assert!(html.contains("<summary"));
        assert!(html.contains("structured-key"));
        assert!(html.contains("structured-number"));
        assert!(html.contains("structured-boolean"));
        assert!(html.contains("structured-null"));
        assert!(html.contains("structured-string"));
        assert!(html.contains("structured-index"));
        assert!(!html.contains("<script>"));
        assert!(html.contains("&lt;script&gt;"));

        let z = html.find("\"z\"").unwrap();
        let a = html.find("\"a\"").unwrap();
        let empty = html.find("\"empty\"").unwrap();
        assert!(z < a && a < empty, "keys must stay in authored order");
        assert!(
            html.contains("<span class=\"structured-index\">0</span>"),
            "array items are labelled with their index"
        );
    }

    #[test]
    fn renders_every_plist_scalar_from_xml_and_binary_encodings() {
        for fixture_name in ["example-xml.plist", "example-binary.plist"] {
            let html = render_structured(&fixture(fixture_name), StructuredFormat::Plist).unwrap();
            assert!(html.contains("Glance &amp; fixture"), "{fixture_name}");
            assert!(html.contains("structured-number"), "{fixture_name}");
            assert!(html.contains("structured-boolean"), "{fixture_name}");
            assert!(html.contains("structured-date"), "{fixture_name}");
            assert!(html.contains("2024-05-06T07:08:09Z"), "{fixture_name}");
            assert!(html.contains("5 bytes of data"), "{fixture_name}");
            assert!(html.contains("structured-index"), "{fixture_name}");
            assert!(!html.contains("<script>"), "{fixture_name}");
        }
    }

    #[test]
    fn renders_xml_elements_attributes_and_text_without_resolving_entities() {
        let html = render_structured(&fixture("example.xml"), StructuredFormat::Xml).unwrap();

        assert!(html.contains("structured-tag"));
        assert!(html.contains("structured-attribute"));
        assert!(html.contains("priority"));
        assert!(html.contains("structured-text"));
        assert!(html.contains("&amp;xxe;"), "named entities stay literal");
        assert!(!html.contains("root:"));
        assert!(!html.contains("&amp;lt;"));
    }

    #[test]
    fn refuses_to_parse_oversized_input() {
        let html = render_structured(&fixture("oversized.json"), StructuredFormat::Json).unwrap();

        assert!(html.contains("Preview truncated"));
        assert!(html.contains("larger than the 4 MB preview limit"));
    }

    #[test]
    fn merges_text_around_entities_into_one_node() {
        let html = render_structured(
            b"<root>XML &amp; entity preview</root>",
            StructuredFormat::Xml,
        )
        .unwrap();

        assert_eq!(html.matches("structured-text").count(), 1);
        assert!(html.contains("XML &amp; entity preview"));
    }

    #[test]
    fn renders_top_level_comments_with_the_root_element() {
        let html = render_structured(
            b"<!-- generated by fixture --><root><child>ok</child></root>",
            StructuredFormat::Xml,
        )
        .unwrap();

        assert!(html.contains("generated by fixture"));
        assert!(html.contains("child"));
        assert!(html.contains("ok"));
    }

    #[test]
    fn truncates_json_beyond_the_parser_recursion_limit() {
        let deep = format!("{}0{}", "[".repeat(200), "]".repeat(200));
        assert!(render_json(&deep).contains("Preview truncated"));
    }

    #[test]
    fn truncates_deep_binary_plists() {
        let html = render_structured(&deep_binary_plist(50_000), StructuredFormat::Plist).unwrap();
        assert!(html.contains("Preview truncated"));
    }

    #[test]
    fn truncates_amplified_binary_plists() {
        let html = render_structured(&amplified_binary_plist(24), StructuredFormat::Plist).unwrap();
        assert!(html.contains("Preview truncated"));
    }

    #[test]
    fn preserves_xml_space_directives() {
        let html = render_structured(
            b"<root xml:space=\"preserve\"><value>   </value><trail>text   </trail></root>",
            StructuredFormat::Xml,
        )
        .unwrap();

        assert!(html.contains(">   </div>"));
        assert!(html.contains("text   </div>"));
    }

    #[test]
    fn rejects_malformed_xml_attributes() {
        assert!(render_structured(b"<root bad=oops/>", StructuredFormat::Xml).is_err());
        assert!(render_structured(b"<root a=\"1\" a=\"2\"/>", StructuredFormat::Xml).is_err());
    }

    #[test]
    fn truncates_deep_node_and_output_limits() {
        let deep = format!(
            "{}0{}",
            "[".repeat(MAX_DEPTH + 8),
            "]".repeat(MAX_DEPTH + 8)
        );
        let deep_html = render_json(&deep);
        assert!(deep_html.contains("Preview truncated"));
        assert!(deep_html.contains("structured-ellipsis"));

        let deep_plist = format!(
            "<?xml version=\"1.0\"?><plist version=\"1.0\">{}<string>x</string>{}</plist>",
            "<array>".repeat(MAX_DEPTH + 1),
            "</array>".repeat(MAX_DEPTH + 1)
        );
        let deep_plist_html =
            render_structured(deep_plist.as_bytes(), StructuredFormat::Plist).unwrap();
        assert!(deep_plist_html.contains("Preview truncated"));

        let wide = format!(
            "[{}]",
            std::iter::repeat_n("0", MAX_NODES + 10)
                .collect::<Vec<_>>()
                .join(",")
        );
        assert!(render_json(&wide).contains("Preview truncated"));

        let long = "x".repeat(MAX_VALUE_CHARS + 100);
        let output = format!(
            "{{{}}}",
            (0..400)
                .map(|index| format!("\"key{index}\":\"{long}\""))
                .collect::<Vec<_>>()
                .join(",")
        );
        let output_html = render_json(&output);
        assert!(output_html.contains("Preview truncated"));
        assert!(output_html.len() < MAX_OUTPUT_BYTES + MAX_VALUE_CHARS * 2);

        let attributes = (0..60_000)
            .map(|index| format!(" attribute{index}=\"value\""))
            .collect::<String>();
        let attribute_html = render_structured(
            format!("<root{attributes}/>").as_bytes(),
            StructuredFormat::Xml,
        )
        .unwrap();
        assert!(attribute_html.contains("Preview truncated"));
        assert!(attribute_html.len() < MAX_OUTPUT_BYTES + 64 * 1_024);
    }

    #[test]
    fn rejects_malformed_structured_input() {
        assert!(render_structured(b"{", StructuredFormat::Json).is_err());
        assert!(render_structured(b"not a plist", StructuredFormat::Plist).is_err());
        assert!(render_structured(b"<root>", StructuredFormat::Xml).is_err());
        assert!(render_structured(b"", StructuredFormat::Xml).is_err());
        assert!(render_structured(b"<?xml version=\"1.0\"?>", StructuredFormat::Xml).is_err());
        assert!(render_structured(b"<first/><second/>", StructuredFormat::Xml).is_err());
    }

    #[test]
    fn rejects_non_utf8_xml_with_a_contextual_error() {
        let error = render_structured(b"<root>\xff</root>", StructuredFormat::Xml).unwrap_err();

        assert!(matches!(error, CoreError::Parse(_)), "{error}");
        assert!(error.to_string().contains("Could not parse XML"), "{error}");
    }

    #[test]
    fn renders_repository_fixtures() {
        let html = render_structured(&fixture("nested.json"), StructuredFormat::Json).unwrap();
        assert!(html.contains("structured-preview"));
        assert!(html.contains("structured-container"));

        let scalars = render_structured(&fixture("scalars.json"), StructuredFormat::Json).unwrap();
        assert!(scalars.contains("structured-null"));
        assert!(scalars.contains("structured-boolean"));

        assert!(render_structured(&fixture("malformed.json"), StructuredFormat::Json).is_err());
    }

    #[test]
    fn renders_empty_containers_without_details() {
        let html = render_json(r#"{"object":{},"array":[]}"#);
        assert!(html.contains("{}"));
        assert!(html.contains("[]"));
        assert!(!html.contains("<details class=\"structured-node structured-container\"><summary"));
    }

    #[test]
    fn separates_labels_from_values_with_a_space() {
        let html = render_json(r#"{"key":"value","list":[0]}"#);

        assert!(
            html.contains(r#""key"</span><span class="structured-punct">:</span> "#),
            "object labels are followed by a space"
        );
        assert!(
            html.contains(
                r#"<span class="structured-index">0</span><span class="structured-punct">:</span> "#
            ),
            "array indices are followed by a space"
        );
    }
}
