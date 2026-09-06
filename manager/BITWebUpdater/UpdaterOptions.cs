using BITWebVersioning;

namespace BITWebUpdater;

public sealed record UpdaterOptions(
    int ManagerProcessId,
    string PreparedDirectory,
    string TargetDirectory,
    ReleaseVersion ExpectedVersion,
    string ResultPath,
    bool TestMode)
{
    public static UpdaterOptions Parse(IReadOnlyList<string> arguments)
    {
        var values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var testMode = false;
        for (var index = 0; index < arguments.Count; index++)
        {
            if (arguments[index] == "--test-mode") { testMode = true; continue; }
            if (!arguments[index].StartsWith("--", StringComparison.Ordinal) || index + 1 >= arguments.Count)
            {
                throw new ArgumentException($"Invalid updater argument: {arguments[index]}");
            }
            values[arguments[index]] = arguments[++index];
        }

        if (!int.TryParse(Required("--manager-pid"), out var pid) || pid < 0) throw new ArgumentException("Invalid manager PID.");
        var expected = ReleaseVersion.Parse(Required("--expected-version"));
        return new UpdaterOptions(
            pid,
            Path.GetFullPath(Required("--prepared-directory")),
            Path.GetFullPath(Required("--target-directory")),
            expected,
            Path.GetFullPath(Required("--result-path")),
            testMode);

        string Required(string name) => values.TryGetValue(name, out var value) && !string.IsNullOrWhiteSpace(value)
            ? value
            : throw new ArgumentException($"Missing updater argument: {name}");
    }
}
