using BITWebVersioning;

namespace BITWebUpdater;

public static class RcQaFailureInjection
{
    public const string EnvironmentVariable = "BITWEB_RC_QA_FAIL_HEALTH_CHECK";

    public static bool ShouldFailHealthCheck(ReleaseVersion updaterVersion, string? value)
    {
        if (!string.Equals(value, "1", StringComparison.Ordinal)) return false;
        if (!updaterVersion.IsPrerelease)
            throw new InvalidOperationException("RC QA failure injection is unavailable in a stable updater.");
        return true;
    }
}
