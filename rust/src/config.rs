use anyhow::{Context, Result};

pub fn required(name: &str) -> Result<String> {
    std::env::var(name).with_context(|| format!("{name} is required"))
}

pub fn setting(name: &str, default: &str) -> String {
    std::env::var(name).unwrap_or_else(|_| default.to_owned())
}

pub fn parse<T>(name: &str) -> Result<T>
where
    T: std::str::FromStr,
    T::Err: std::error::Error + Send + Sync + 'static,
{
    required(name)?
        .parse()
        .with_context(|| format!("{name} is invalid"))
}
