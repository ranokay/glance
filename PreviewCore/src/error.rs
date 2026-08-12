use std::fmt;

#[derive(Debug)]
pub(crate) struct RenderError(String);

impl RenderError {
    pub(crate) fn new(message: impl Into<String>) -> Self {
        Self(message.into())
    }
}

impl fmt::Display for RenderError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl std::error::Error for RenderError {}

#[derive(Debug)]
pub(crate) enum CoreError {
    InvalidInput(String),
    Parse(String),
    Io(String),
    ResourceLimit(String),
    Unsupported(String),
}

impl CoreError {
    pub(crate) fn invalid(message: impl Into<String>) -> Self {
        Self::InvalidInput(message.into())
    }

    pub(crate) fn parse(message: impl Into<String>) -> Self {
        Self::Parse(message.into())
    }

    pub(crate) fn io(message: impl Into<String>) -> Self {
        Self::Io(message.into())
    }

    pub(crate) fn limit(message: impl Into<String>) -> Self {
        Self::ResourceLimit(message.into())
    }

    pub(crate) fn unsupported(message: impl Into<String>) -> Self {
        Self::Unsupported(message.into())
    }
}

impl fmt::Display for CoreError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidInput(message)
            | Self::Parse(message)
            | Self::Io(message)
            | Self::ResourceLimit(message)
            | Self::Unsupported(message) => formatter.write_str(message),
        }
    }
}

impl std::error::Error for CoreError {}
