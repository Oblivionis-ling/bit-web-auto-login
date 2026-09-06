using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Text;
using BITWebManager.Models;

namespace BITWebManager.Services;

public sealed class PowerShellService
{
    private static readonly TimeSpan DefaultTimeout = TimeSpan.FromSeconds(15);

    public async Task<PowerShellResult> RunFileAsync(
        string scriptPath,
        IEnumerable<string>? arguments = null,
        TimeSpan? timeout = null,
        PowerShellInvocationOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        if (!File.Exists(scriptPath))
        {
            throw new FileNotFoundException("PowerShell bridge script was not found.", scriptPath);
        }

        options ??= new PowerShellInvocationOptions();
        var startInfo = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            UseShellExecute = false,
            CreateNoWindow = !options.Interactive,
            WindowStyle = options.Interactive ? ProcessWindowStyle.Normal : ProcessWindowStyle.Hidden,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = new UTF8Encoding(false),
            StandardErrorEncoding = new UTF8Encoding(false),
        };

        startInfo.ArgumentList.Add("-NoLogo");
        startInfo.ArgumentList.Add("-NoProfile");
        if (!options.Interactive)
        {
            startInfo.ArgumentList.Add("-NonInteractive");
        }
        startInfo.ArgumentList.Add("-ExecutionPolicy");
        startInfo.ArgumentList.Add("Bypass");
        startInfo.ArgumentList.Add("-File");
        startInfo.ArgumentList.Add(scriptPath);

        if (arguments is not null)
        {
            foreach (var argument in arguments)
            {
                startInfo.ArgumentList.Add(argument);
            }
        }

        using var process = new Process { StartInfo = startInfo };
        try
        {
            if (!process.Start())
            {
                throw new InvalidOperationException("PowerShell did not start.");
            }
        }
        catch (Win32Exception exception)
        {
            throw new InvalidOperationException("Windows PowerShell is unavailable or could not be started.", exception);
        }

        using var timeoutSource = new CancellationTokenSource(timeout ?? DefaultTimeout);
        using var linkedSource = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, timeoutSource.Token);

        var stdoutTask = process.StandardOutput.ReadToEndAsync(linkedSource.Token);
        var stderrTask = process.StandardError.ReadToEndAsync(linkedSource.Token);

        try
        {
            await process.WaitForExitAsync(linkedSource.Token).ConfigureAwait(false);
            var stdout = await stdoutTask.ConfigureAwait(false);
            var stderr = await stderrTask.ConfigureAwait(false);
            return new PowerShellResult(process.ExitCode, stdout.Trim(), stderr.Trim());
        }
        catch (OperationCanceledException) when (timeoutSource.IsCancellationRequested && !cancellationToken.IsCancellationRequested)
        {
            TryTerminate(process);
            throw new TimeoutException($"PowerShell request exceeded {(timeout ?? DefaultTimeout).TotalSeconds:0} seconds.");
        }
        catch
        {
            TryTerminate(process);
            throw;
        }
    }

    private static void TryTerminate(Process process)
    {
        try
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
            }
        }
        catch
        {
            // Best effort only. The original exception remains the useful failure.
        }
    }
}
