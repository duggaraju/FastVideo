namespace Video.Contracts;

public static class BlobMountPaths
{
    public static string FromUri(Uri uri, string storageAccountName, string containerName, string mountRoot)
    {
        var expectedHostPrefix = $"{storageAccountName}.blob.";
        if (!uri.Host.StartsWith(expectedHostPrefix, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException($"Blob URI host '{uri.Host}' does not match storage account '{storageAccountName}'");

        var segments = uri.AbsolutePath.Trim('/').Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (segments.Length < 2)
            throw new InvalidOperationException($"Blob URI '{uri}' does not contain a container and blob path");
        if (!segments[0].Equals(containerName, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException($"Blob URI container '{segments[0]}' does not match configured container '{containerName}'");

        return FromBlobName(string.Join('/', segments.Skip(1).Select(Uri.UnescapeDataString)), mountRoot);
    }

    public static string FromBlobName(string blobName, string mountRoot)
    {
        var segments = blobName.Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (segments.Length == 0)
            throw new InvalidOperationException("Blob path is empty");

        var pathSegments = new List<string>(segments.Length + 1) { mountRoot };
        foreach (var segment in segments)
        {
            if (segment is "." or "..")
                throw new InvalidOperationException("Blob path contains invalid traversal segments");
            pathSegments.Add(segment);
        }

        return Path.Combine(pathSegments.ToArray());
    }
}
