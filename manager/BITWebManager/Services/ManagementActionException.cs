namespace BITWebManager.Services;

public sealed class ManagementActionException : Exception
{
    public ManagementActionException(
        string userMessage,
        string technicalDetails,
        string? errorCode = null,
        Exception? innerException = null)
        : base(userMessage, innerException)
    {
        TechnicalDetails = technicalDetails;
        ErrorCode = errorCode;
    }

    public string TechnicalDetails { get; }
    public string? ErrorCode { get; }
}
