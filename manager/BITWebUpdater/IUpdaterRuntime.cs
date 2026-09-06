using BITWebVersioning;

namespace BITWebUpdater;

public interface IUpdaterRuntime
{
    void RunInstaller(string targetDirectory);
    bool RunHealthCheck(string managerPath, ReleaseVersion expectedVersion, string healthResultPath);
    void LaunchManager(string managerPath);
}
