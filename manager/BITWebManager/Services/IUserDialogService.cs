namespace BITWebManager.Services;

public interface IUserDialogService
{
    bool ConfirmUninstall();
    bool ConfirmClearCredential();
    bool ConfirmClearCredentialAgain();
    void ShowInformation(string title, string message);
}
