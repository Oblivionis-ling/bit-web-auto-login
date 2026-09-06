namespace BITWebManager.Services;

public sealed class StatusReadException : Exception
{
    public StatusReadException(string userMessage, string technicalDetails, Exception? innerException = null)
        : base(userMessage, innerException)
    {
        TechnicalDetails = technicalDetails;
    }

    public string TechnicalDetails { get; }
}
