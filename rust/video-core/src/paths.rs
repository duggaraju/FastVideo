use anyhow::{Result, bail};
use percent_encoding::percent_decode_str;
use std::path::{Component, Path, PathBuf};
use url::Url;

pub fn from_uri(uri: &Url, account: &str, container: &str, mount_root: &Path) -> Result<PathBuf> {
    let expected = format!("{account}.blob.");
    if !uri.host_str().is_some_and(|host| {
        host.to_ascii_lowercase()
            .starts_with(&expected.to_ascii_lowercase())
    }) {
        bail!("Blob URI host does not match storage account '{account}'");
    }
    let mut segments = uri.path().trim_matches('/').split('/');
    let actual_container = segments.next().unwrap_or_default();
    if !actual_container.eq_ignore_ascii_case(container) {
        bail!(
            "Blob URI container '{actual_container}' does not match configured container '{container}'"
        );
    }
    let decoded = segments
        .map(|segment| percent_decode_str(segment).decode_utf8())
        .collect::<Result<Vec<_>, _>>()?
        .join("/");
    from_blob_name(&decoded, mount_root)
}

pub fn from_blob_name(blob_name: &str, mount_root: &Path) -> Result<PathBuf> {
    if blob_name.is_empty() {
        bail!("Blob path is empty");
    }
    let relative = Path::new(blob_name);
    if relative.components().any(|part| {
        matches!(
            part,
            Component::ParentDir | Component::CurDir | Component::RootDir | Component::Prefix(_)
        )
    }) {
        bail!("Blob path contains invalid traversal segments");
    }
    Ok(mount_root.join(relative))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_https_blob_uri() {
        let uri = Url::parse("https://acct.blob.core.windows.net/videos/a%20b/file.mp4").unwrap();
        assert_eq!(
            from_uri(&uri, "acct", "videos", Path::new("/mnt/output")).unwrap(),
            Path::new("/mnt/output/a b/file.mp4")
        );
    }

    #[test]
    fn rejects_traversal() {
        assert!(from_blob_name("a/../secret", Path::new("/mnt")).is_err());
    }
}
