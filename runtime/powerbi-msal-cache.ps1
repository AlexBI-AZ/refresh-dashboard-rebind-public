function Enable-PowerBiChainedRefreshTokenCache {
    param([Microsoft.Identity.Client.IPublicClientApplication]$PublicClientApplication)

    if (-not ("PowerBiChainedRefreshTokenCache" -as [type])) {
        Add-Type -AssemblyName System.Security -ErrorAction Stop
        $source = @'
using System;
using System.IO;
using System.Security.Cryptography;
using Microsoft.Identity.Client;

public static class PowerBiChainedRefreshTokenCache
{
    private static readonly object FileLock = new object();
    private static string cacheFilePath;

    public static void EnableSerialization(ITokenCache tokenCache, string path)
    {
        if (String.IsNullOrWhiteSpace(path)) throw new ArgumentException("A cache path is required.", "path");
        lock (FileLock) { cacheFilePath = path; }
        tokenCache.SetBeforeAccess(BeforeAccessNotification);
        tokenCache.SetAfterAccess(AfterAccessNotification);
    }

    private static string CacheFilePath
    {
        get { lock (FileLock) { return cacheFilePath; } }
    }

    private static void BeforeAccessNotification(TokenCacheNotificationArgs args)
    {
        lock (FileLock)
        {
            byte[] data = null;
            if (File.Exists(CacheFilePath))
            {
                try
                {
                    data = ProtectedData.Unprotect(File.ReadAllBytes(CacheFilePath), null, DataProtectionScope.CurrentUser);
                }
                catch (CryptographicException ex)
                {
                    throw new InvalidOperationException("The Power BI refresh token cache could not be decrypted.", ex);
                }
            }
            args.TokenCache.DeserializeMsalV3(data);
        }
    }

    private static void AfterAccessNotification(TokenCacheNotificationArgs args)
    {
        if (!args.HasStateChanged) return;
        lock (FileLock)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(CacheFilePath));
            File.WriteAllBytes(
                CacheFilePath,
                ProtectedData.Protect(args.TokenCache.SerializeMsalV3(), null, DataProtectionScope.CurrentUser));
        }
    }
}
'@
        Add-Type -TypeDefinition $source -ReferencedAssemblies @(
            [Microsoft.Identity.Client.ITokenCache].Assembly.Location,
            [System.Security.Cryptography.ProtectedData].Assembly.Location
        ) -ErrorAction Stop
    }

    $cachePath = Join-Path ([Environment]::GetFolderPath("LocalApplicationData")) "PowerBIChainedRefresh\msalcache.bin3"
    [PowerBiChainedRefreshTokenCache]::EnableSerialization($PublicClientApplication.UserTokenCache, $cachePath)
    return $cachePath
}
