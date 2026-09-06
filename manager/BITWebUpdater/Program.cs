using BITWebUpdater;
using BITWebVersioning;
using System.Reflection;

try
{
    var options = UpdaterOptions.Parse(args);
    var updaterVersion = ReleaseVersion.FromAssembly(Assembly.GetExecutingAssembly());
    var failHealthCheck = RcQaFailureInjection.ShouldFailHealthCheck(
        updaterVersion,
        Environment.GetEnvironmentVariable(RcQaFailureInjection.EnvironmentVariable));
    new UpdateDeployment(new ProcessUpdaterRuntime(), failHealthCheck).Execute(options);
    return 0;
}
catch (Exception exception)
{
    Console.Error.WriteLine(exception);
    return 1;
}
