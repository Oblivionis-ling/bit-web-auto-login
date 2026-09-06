using BITWebUpdater;

try
{
    var options = UpdaterOptions.Parse(args);
    new UpdateDeployment(new ProcessUpdaterRuntime()).Execute(options);
    return 0;
}
catch (Exception exception)
{
    Console.Error.WriteLine(exception);
    return 1;
}
