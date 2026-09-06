namespace BITWebManager.Services;

public sealed class UpdateException : Exception
{
    public UpdateException(string userMessage, string technicalDetails, string errorCode, Exception? innerException = null)
        : base(userMessage, innerException)
    {
        TechnicalDetails = technicalDetails;
        ErrorCode = errorCode;
    }

    public string TechnicalDetails { get; }
    public string ErrorCode { get; }
}
