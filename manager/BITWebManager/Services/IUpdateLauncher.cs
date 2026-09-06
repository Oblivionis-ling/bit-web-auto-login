using BITWebManager.Models;

namespace BITWebManager.Services;

public interface IUpdateLauncher
{
    void Launch(PreparedUpdate update, string targetDirectory, int managerProcessId);
}
