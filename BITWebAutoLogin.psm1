Set-StrictMode -Version 2.0

function Get-HtmlAttribute {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Tag,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $escapedName = [regex]::Escape($Name)
    $pattern = '(?is)\b' + $escapedName + '\s*=\s*(?:"(?<value>[^"]*)"|''(?<value>[^'']*)''|(?<value>[^\s>]+))'
    $match = [regex]::Match($Tag, $pattern)
    if (-not $match.Success) {
        return $null
    }

    return [System.Net.WebUtility]::HtmlDecode($match.Groups['value'].Value)
}

function Find-PortalLoginForm {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Html,
        [Parameter(Mandatory = $true)][uri]$BaseUri,
        [string]$UsernameField,
        [string]$PasswordField
    )

    $formMatches = [regex]::Matches(
        $Html,
        '<form\b(?<attributes>[^>]*)>(?<body>.*?)</form\s*>',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )

    foreach ($formMatch in $formMatches) {
        $formBody = $formMatch.Groups['body'].Value
        $inputMatches = [regex]::Matches(
            $formBody,
            '<input\b[^>]*>',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
            [System.Text.RegularExpressions.RegexOptions]::Singleline
        )

        $inputs = @()
        foreach ($inputMatch in $inputMatches) {
            $tag = $inputMatch.Value
            $name = Get-HtmlAttribute -Tag $tag -Name 'name'
            if ([string]::IsNullOrWhiteSpace($name)) {
                continue
            }

            $type = Get-HtmlAttribute -Tag $tag -Name 'type'
            if ([string]::IsNullOrWhiteSpace($type)) {
                $type = 'text'
            }

            $value = Get-HtmlAttribute -Tag $tag -Name 'value'
            if ($null -eq $value) {
                $value = ''
            }

            $inputs += [pscustomobject]@{
                Name  = $name
                Type  = $type.ToLowerInvariant()
                Value = $value
                Tag   = $tag
            }
        }

        $passwordInput = $null
        if (-not [string]::IsNullOrWhiteSpace($PasswordField)) {
            $passwordInput = $inputs | Where-Object { $_.Name -eq $PasswordField } | Select-Object -First 1
        }
        else {
            $passwordInput = $inputs | Where-Object { $_.Type -eq 'password' } | Select-Object -First 1
        }

        if ($null -eq $passwordInput) {
            continue
        }

        $usernameInput = $null
        if (-not [string]::IsNullOrWhiteSpace($UsernameField)) {
            $usernameInput = $inputs | Where-Object { $_.Name -eq $UsernameField } | Select-Object -First 1
        }
        else {
            $usernameInput = $inputs |
                Where-Object {
                    $_.Type -in @('text', 'email', 'tel') -and
                    $_.Name -match '(?i)(user|account|login|name)'
                } |
                Select-Object -First 1

            if ($null -eq $usernameInput) {
                $usernameInput = $inputs |
                    Where-Object { $_.Type -in @('text', 'email', 'tel') } |
                    Select-Object -First 1
            }
        }

        if ($null -eq $usernameInput) {
            continue
        }

        $formAttributes = $formMatch.Groups['attributes'].Value
        $action = Get-HtmlAttribute -Tag $formAttributes -Name 'action'
        if ([string]::IsNullOrWhiteSpace($action)) {
            $actionUri = $BaseUri
        }
        else {
            $actionUri = [uri]::new($BaseUri, $action)
        }

        $method = Get-HtmlAttribute -Tag $formAttributes -Name 'method'
        if ([string]::IsNullOrWhiteSpace($method)) {
            $method = 'GET'
        }
        else {
            $method = $method.ToUpperInvariant()
        }

        if ($method -notin @('GET', 'POST')) {
            throw "Unsupported login form HTTP method: $method"
        }

        $defaults = @{}
        foreach ($input in $inputs) {
            if ($input.Type -in @('hidden', 'submit')) {
                $defaults[$input.Name] = $input.Value
            }
        }

        return [pscustomobject]@{
            ActionUri      = $actionUri
            Method         = $method
            UsernameField  = $usernameInput.Name
            PasswordField  = $passwordInput.Name
            DefaultFields  = $defaults
        }
    }

    throw 'No HTML form containing both username and password fields was found. The page may use JavaScript; configure the endpoint fields in settings.json.'
}

function Assert-SafeLoginUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][uri]$PortalUri,
        [Parameter(Mandatory = $true)][uri]$LoginUri,
        [switch]$AllowCrossOrigin
    )

    if ($PortalUri.Scheme -notin @('http', 'https')) {
        throw "Unsupported portal URL scheme: $($PortalUri.Scheme)"
    }
    if ($LoginUri.Scheme -notin @('http', 'https')) {
        throw "Unsupported login URL scheme: $($LoginUri.Scheme)"
    }

    $sameOrigin =
        $PortalUri.Scheme -eq $LoginUri.Scheme -and
        $PortalUri.Host -eq $LoginUri.Host -and
        $PortalUri.Port -eq $LoginUri.Port

    if (-not $sameOrigin -and -not $AllowCrossOrigin) {
        throw "Cross-origin login URL rejected to protect credentials: $LoginUri"
    }
}

function ConvertTo-PlainText {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][securestring]$SecureString)

    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

function New-PortalLoginPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Form,
        [Parameter(Mandatory = $true)][pscredential]$Credential,
        $ExtraFields
    )

    $payload = @{}
    if ($null -ne $Form.DefaultFields) {
        foreach ($key in $Form.DefaultFields.Keys) {
            $payload[$key] = [string]$Form.DefaultFields[$key]
        }
    }

    $payload[$Form.UsernameField] = $Credential.UserName
    $plainPassword = ConvertTo-PlainText -SecureString $Credential.Password
    try {
        $payload[$Form.PasswordField] = $plainPassword
    }
    finally {
        $plainPassword = $null
    }

    if ($null -ne $ExtraFields) {
        if ($ExtraFields -is [System.Collections.IDictionary]) {
            foreach ($key in $ExtraFields.Keys) {
                $payload[[string]$key] = [string]$ExtraFields[$key]
            }
        }
        else {
            foreach ($property in $ExtraFields.PSObject.Properties) {
                $payload[$property.Name] = [string]$property.Value
            }
        }
    }

    return $payload
}

function Test-InternetAccess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][uri]$Uri,
        [string]$ExpectedText,
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 8
    )

    try {
        $response = Invoke-WebRequest -Uri $Uri -Method Get -UseBasicParsing -TimeoutSec $TimeoutSeconds -ErrorAction Stop
        if ([string]::IsNullOrEmpty($ExpectedText)) {
            return $response.StatusCode -ge 200 -and $response.StatusCode -lt 400
        }
        return ([string]$response.Content).Trim() -eq $ExpectedText.Trim()
    }
    catch {
        return $false
    }
}

function Test-InternetAccessSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object[]]$Checks,
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 8
    )

    if (@($Checks).Count -lt 1) {
        throw 'At least one connectivity check is required.'
    }

    foreach ($check in @($Checks)) {
        if ($null -eq $check.PSObject.Properties['Url'] -or
            [string]::IsNullOrWhiteSpace([string]$check.Url)) {
            throw 'Each connectivity check must provide Url.'
        }

        $expectedText = ''
        if ($null -ne $check.PSObject.Properties['ExpectedText']) {
            $expectedText = [string]$check.ExpectedText
        }

        if (Test-InternetAccess `
            -Uri ([uri]$check.Url) `
            -ExpectedText $expectedText `
            -TimeoutSeconds $TimeoutSeconds) {
            return $true
        }
    }

    return $false
}

function Get-ConnectivityDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][bool]$InternetHealthy,
        [Parameter(Mandatory = $true)][ValidateRange(0, 1000)][int]$ConsecutiveFailures,
        [Parameter(Mandatory = $true)][ValidateRange(1, 100)][int]$RequiredFailures,
        [Parameter(Mandatory = $true)][datetime]$Now,
        [Parameter(Mandatory = $true)][datetime]$CooldownUntil,
        [Parameter(Mandatory = $true)][datetime]$NextAttemptAt
    )

    if ($InternetHealthy) {
        return [pscustomobject]@{
            Action              = 'Online'
            ConsecutiveFailures = 0
        }
    }

    $nextFailureCount = [Math]::Min($RequiredFailures, $ConsecutiveFailures + 1)
    if ($Now -lt $CooldownUntil) {
        return [pscustomobject]@{
            Action              = 'Cooldown'
            ConsecutiveFailures = $nextFailureCount
        }
    }
    if ($nextFailureCount -lt $RequiredFailures) {
        return [pscustomobject]@{
            Action              = 'Confirm'
            ConsecutiveFailures = $nextFailureCount
        }
    }
    if ($Now -lt $NextAttemptAt) {
        return [pscustomobject]@{
            Action              = 'Backoff'
            ConsecutiveFailures = $nextFailureCount
        }
    }

    return [pscustomobject]@{
        Action              = 'Authenticate'
        ConsecutiveFailures = $nextFailureCount
    }
}

function Get-ConnectedWifiSsids {
    [CmdletBinding()]
    param()

    $output = & "$env:SystemRoot\System32\netsh.exe" wlan show interfaces 2>$null
    if ($LASTEXITCODE -ne 0) {
        return @()
    }

    $ssids = @()
    foreach ($line in $output) {
        if ($line -match '^\s*SSID\s*:\s*(.*?)\s*$') {
            $value = $Matches[1]
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                $ssids += $value
            }
        }
    }
    return @($ssids | Select-Object -Unique)
}

function Get-ActivePhysicalEthernetAdapters {
    [CmdletBinding()]
    param()

    if ($null -eq (Get-Command Get-NetAdapter -ErrorAction SilentlyContinue)) {
        return @()
    }

    $results = @()
    $adapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
        Where-Object { $_.Status -eq 'Up' })

    foreach ($adapter in $adapters) {
        $mediaType = [string]$adapter.MediaType
        $physicalMedium = [string]$adapter.NdisPhysicalMedium
        $identity = '{0} {1}' -f $adapter.Name, $adapter.InterfaceDescription
        $isWifi = $mediaType -match '(?i)802\.11' -or
            $physicalMedium -eq '9' -or
            $identity -match '(?i)(wi-?fi|wireless|wlan)'
        $isEthernet = $mediaType -match '(?i)802\.3' -or
            $physicalMedium -eq '14' -or
            $identity -match '(?i)(ethernet|gigabit)'

        if ($isWifi -or -not $isEthernet) {
            continue
        }

        $addresses = @()
        if ($null -ne (Get-Command Get-NetIPAddress -ErrorAction SilentlyContinue)) {
            $addresses = @(Get-NetIPAddress `
                -InterfaceIndex $adapter.InterfaceIndex `
                -AddressFamily IPv4 `
                -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.IPAddress -and
                    $_.IPAddress -notmatch '^169\.254\.'
                } |
                ForEach-Object { [string]$_.IPAddress })
        }

        $results += [pscustomobject]@{
            Name             = [string]$adapter.Name
            Description      = [string]$adapter.InterfaceDescription
            InterfaceIndex   = [int]$adapter.InterfaceIndex
            IPv4Addresses    = @($addresses)
        }
    }

    return @($results)
}

function Select-CampusConnectionContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Auto', 'Wifi', 'Ethernet')]
        [string]$Mode,
        [Parameter(Mandatory = $true)][string]$TargetSsid,
        [string[]]$ConnectedWifiSsids = @(),
        [object[]]$ActiveEthernetAdapters = @(),
        [string[]]$EthernetIpv4Prefixes = @()
    )

    $wifiMatch = @($ConnectedWifiSsids) -contains $TargetSsid
    if ($wifiMatch -and $Mode -in @('Auto', 'Wifi')) {
        return [pscustomobject]@{
            Eligible    = $true
            Kind        = 'Wifi'
            DisplayName = $TargetSsid
            IPv4Address = ''
            Reason      = 'Target Wi-Fi SSID is connected.'
        }
    }

    if ($Mode -in @('Auto', 'Ethernet')) {
        foreach ($adapter in @($ActiveEthernetAdapters)) {
            foreach ($address in @($adapter.IPv4Addresses)) {
                foreach ($prefix in @($EthernetIpv4Prefixes)) {
                    if (-not [string]::IsNullOrWhiteSpace($prefix) -and
                        ([string]$address).StartsWith([string]$prefix, [StringComparison]::OrdinalIgnoreCase)) {
                        return [pscustomobject]@{
                            Eligible    = $true
                            Kind        = 'Ethernet'
                            DisplayName = [string]$adapter.Name
                            IPv4Address = [string]$address
                            Reason      = "Active physical Ethernet matches IPv4 prefix '$prefix'."
                        }
                    }
                }
            }
        }
    }

    $reason = switch ($Mode) {
        'Wifi' { "Target Wi-Fi SSID '$TargetSsid' is not connected." }
        'Ethernet' { 'No active physical Ethernet adapter matched the allowed IPv4 prefixes.' }
        default { "Neither target Wi-Fi '$TargetSsid' nor an allowed physical Ethernet connection is active." }
    }
    return [pscustomobject]@{
        Eligible    = $false
        Kind        = 'None'
        DisplayName = ''
        IPv4Address = ''
        Reason      = $reason
    }
}

function Get-CampusConnectionContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Auto', 'Wifi', 'Ethernet')]
        [string]$Mode,
        [Parameter(Mandatory = $true)][string]$TargetSsid,
        [string[]]$EthernetIpv4Prefixes = @()
    )

    $wifiSsids = @(Get-ConnectedWifiSsids)
    $ethernetAdapters = @(Get-ActivePhysicalEthernetAdapters)
    return Select-CampusConnectionContext `
        -Mode $Mode `
        -TargetSsid $TargetSsid `
        -ConnectedWifiSsids $wifiSsids `
        -ActiveEthernetAdapters $ethernetAdapters `
        -EthernetIpv4Prefixes $EthernetIpv4Prefixes
}

function Initialize-SrunCrypto {
    [CmdletBinding()]
    param()

    if ($null -ne ('BitWebSrunCryptoV1' -as [type])) {
        return
    }

    $source = @'
using System;
using System.Security.Cryptography;
using System.Text;

public static class BitWebSrunCryptoV1
{
    private const string StandardBase64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

    private static uint[] ToUInt32Array(byte[] data, bool includeLength)
    {
        int wordCount = (data.Length + 3) / 4;
        uint[] result = new uint[wordCount + (includeLength ? 1 : 0)];
        for (int i = 0; i < data.Length; i++)
        {
            result[i >> 2] |= (uint)data[i] << ((i & 3) << 3);
        }
        if (includeLength)
        {
            result[wordCount] = (uint)data.Length;
        }
        return result;
    }

    private static byte[] ToByteArray(uint[] data)
    {
        byte[] result = new byte[data.Length * 4];
        for (int i = 0; i < data.Length; i++)
        {
            result[(i << 2)] = (byte)(data[i] & 0xff);
            result[(i << 2) + 1] = (byte)((data[i] >> 8) & 0xff);
            result[(i << 2) + 2] = (byte)((data[i] >> 16) & 0xff);
            result[(i << 2) + 3] = (byte)((data[i] >> 24) & 0xff);
        }
        return result;
    }

    public static byte[] XEncode(string value, string key)
    {
        if (String.IsNullOrEmpty(value))
        {
            return new byte[0];
        }

        uint[] v = ToUInt32Array(Encoding.UTF8.GetBytes(value), true);
        uint[] k = ToUInt32Array(Encoding.UTF8.GetBytes(key), false);
        if (k.Length < 4)
        {
            Array.Resize(ref k, 4);
        }

        int n = v.Length - 1;
        uint z = v[n];
        uint y = v[0];
        const uint delta = 0x9E3779B9;
        uint sum = 0;
        int rounds = 6 + 52 / (n + 1);

        unchecked
        {
            while (rounds-- > 0)
            {
                sum += delta;
                uint e = (sum >> 2) & 3;
                int p;
                for (p = 0; p < n; p++)
                {
                    y = v[p + 1];
                    uint m = (z >> 5) ^ (y << 2);
                    m += ((y >> 3) ^ (z << 4)) ^ (sum ^ y);
                    m += k[(p & 3) ^ (int)e] ^ z;
                    z = v[p] += m;
                }
                y = v[0];
                uint last = (z >> 5) ^ (y << 2);
                last += ((y >> 3) ^ (z << 4)) ^ (sum ^ y);
                last += k[(p & 3) ^ (int)e] ^ z;
                z = v[n] += last;
            }
        }

        return ToByteArray(v);
    }

    public static string CustomBase64(byte[] value, string alphabet)
    {
        if (alphabet == null || alphabet.Length != 64)
        {
            throw new ArgumentException("Custom Base64 alphabet must contain 64 characters.");
        }
        string encoded = Convert.ToBase64String(value);
        StringBuilder result = new StringBuilder(encoded.Length);
        foreach (char current in encoded)
        {
            if (current == '=')
            {
                result.Append(current);
            }
            else
            {
                int index = StandardBase64.IndexOf(current);
                result.Append(alphabet[index]);
            }
        }
        return result.ToString();
    }

    private static string ToLowerHex(byte[] value)
    {
        StringBuilder result = new StringBuilder(value.Length * 2);
        foreach (byte current in value)
        {
            result.Append(current.ToString("x2"));
        }
        return result.ToString();
    }

    public static string HmacMd5Hex(string value, string key)
    {
        using (HMACMD5 hmac = new HMACMD5(Encoding.UTF8.GetBytes(key)))
        {
            return ToLowerHex(hmac.ComputeHash(Encoding.UTF8.GetBytes(value)));
        }
    }

    public static string Sha1Hex(string value)
    {
        using (SHA1 sha1 = SHA1.Create())
        {
            return ToLowerHex(sha1.ComputeHash(Encoding.UTF8.GetBytes(value)));
        }
    }
}
'@

    Add-Type -TypeDefinition $source -Language CSharp -ErrorAction Stop
}

function ConvertTo-SrunInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Username,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$IpAddress,
        [Parameter(Mandatory = $true)][string]$AcId,
        [Parameter(Mandatory = $true)][string]$Token
    )

    Initialize-SrunCrypto
    $infoObject = [ordered]@{
        username = $Username
        password = $Password
        ip       = $IpAddress
        acid     = $AcId
        enc_ver  = 'srun_bx1'
    }
    $json = $infoObject | ConvertTo-Json -Compress
    $encoded = [BitWebSrunCryptoV1]::XEncode($json, $Token)
    $alphabet = 'LVoJPiCN2R8G90yg+hmFHuacZ1OWMnrsSTXkYpUq/3dlbfKwv6xztjI7DeBE45QA'
    return '{SRBX1}' + [BitWebSrunCryptoV1]::CustomBase64($encoded, $alphabet)
}

function ConvertFrom-Jsonp {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Content)

    $trimmed = $Content.Trim()
    if ($trimmed.StartsWith('{')) {
        return $trimmed | ConvertFrom-Json
    }
    $match = [regex]::Match(
        $trimmed,
        '^[^(]*\((?<json>.*)\)\s*;?\s*$',
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )
    if (-not $match.Success) {
        throw 'Unexpected JSONP response from the Srun portal.'
    }
    return $match.Groups['json'].Value | ConvertFrom-Json
}

function Get-HtmlInputValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Html,
        [Parameter(Mandatory = $true)][string]$Id
    )

    $inputs = [regex]::Matches(
        $Html,
        '<input\b[^>]*>',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )
    foreach ($input in $inputs) {
        $inputId = Get-HtmlAttribute -Tag $input.Value -Name 'id'
        if ($inputId -eq $Id) {
            return Get-HtmlAttribute -Tag $input.Value -Name 'value'
        }
    }
    return $null
}

function Invoke-SrunPortalAuthentication {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][uri]$PortalUri,
        [Parameter(Mandatory = $true)][string]$PortalHtml,
        [Parameter(Mandatory = $true)]
        [Microsoft.PowerShell.Commands.WebRequestSession]$WebSession,
        [Parameter(Mandatory = $true)][pscredential]$Credential,
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 8
    )

    Initialize-SrunCrypto
    $acId = Get-HtmlInputValue -Html $PortalHtml -Id 'ac_id'
    $clientIp = Get-HtmlInputValue -Html $PortalHtml -Id 'user_ip'
    if ([string]::IsNullOrWhiteSpace($acId)) {
        throw 'Srun portal page did not provide ac_id.'
    }

    $callbackName = 'bitwebCallback'
    $timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $challengeUri = [uri]::new($PortalUri, '/cgi-bin/get_challenge')
    Assert-SafeLoginUri -PortalUri $PortalUri -LoginUri $challengeUri
    $challengeResponse = Invoke-WebRequest `
        -Uri $challengeUri `
        -Method Get `
        -Body @{
            callback = $callbackName
            username = $Credential.UserName
            ip       = $clientIp
            _        = $timestamp
        } `
        -UseBasicParsing `
        -WebSession $WebSession `
        -TimeoutSec $TimeoutSeconds `
        -ErrorAction Stop
    $challenge = ConvertFrom-Jsonp -Content ([string]$challengeResponse.Content)
    if ([string]$challenge.error -ne 'ok' -or
        [string]::IsNullOrWhiteSpace([string]$challenge.challenge)) {
        throw ("Srun challenge failed: {0}" -f [string]$challenge.error)
    }
    if ([string]::IsNullOrWhiteSpace($clientIp)) {
        $clientIp = [string]$challenge.client_ip
    }
    if ([string]::IsNullOrWhiteSpace($clientIp)) {
        throw 'Srun portal did not provide the client IPv4 address.'
    }

    $token = [string]$challenge.challenge
    $plainPassword = ConvertTo-PlainText -SecureString $Credential.Password
    try {
        $hmacMd5 = [BitWebSrunCryptoV1]::HmacMd5Hex($plainPassword, $token)
        $info = ConvertTo-SrunInfo `
            -Username $Credential.UserName `
            -Password $plainPassword `
            -IpAddress $clientIp `
            -AcId $acId `
            -Token $token
    }
    finally {
        $plainPassword = $null
    }

    $n = '200'
    $type = '1'
    $checksumSource =
        $token + $Credential.UserName +
        $token + $hmacMd5 +
        $token + $acId +
        $token + $clientIp +
        $token + $n +
        $token + $type +
        $token + $info
    $checksum = [BitWebSrunCryptoV1]::Sha1Hex($checksumSource)
    $loginUri = [uri]::new($PortalUri, '/cgi-bin/srun_portal')
    Assert-SafeLoginUri -PortalUri $PortalUri -LoginUri $loginUri
    $loginResponse = Invoke-WebRequest `
        -Uri $loginUri `
        -Method Get `
        -Body @{
            callback     = $callbackName
            action       = 'login'
            username     = $Credential.UserName
            password     = '{MD5}' + $hmacMd5
            ac_id        = $acId
            ip           = $clientIp
            chksum       = $checksum
            info         = $info
            n            = $n
            type         = $type
            os           = 'Windows 10'
            name         = 'Windows'
            double_stack = '0'
            ignore       = '2'
            _            = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        } `
        -UseBasicParsing `
        -WebSession $WebSession `
        -TimeoutSec $TimeoutSeconds `
        -ErrorAction Stop
    $login = ConvertFrom-Jsonp -Content ([string]$loginResponse.Content)
    if ([string]$login.error -ne 'ok') {
        $errorCode = [string]$login.ecode
        $errorName = [string]$login.error
        $errorMessage = [string]$login.error_msg
        throw ("Srun login failed: error={0}, ecode={1}, message={2}" -f $errorName, $errorCode, $errorMessage)
    }

    return [pscustomobject]@{
        StatusCode = $loginResponse.StatusCode
        Method     = 'GET'
        LoginUri   = $loginUri
        Protocol   = 'Srun'
    }
}

function Invoke-PortalAuthentication {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Settings,
        [Parameter(Mandatory = $true)][pscredential]$Credential
    )

    $portalUri = [uri]$Settings.PortalUrl
    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $page = Invoke-WebRequest `
        -Uri $portalUri `
        -Method Get `
        -UseBasicParsing `
        -WebSession $session `
        -TimeoutSec ([int]$Settings.RequestTimeoutSeconds) `
        -ErrorAction Stop

    $pageContent = [string]$page.Content
    $isSrunPortal = $pageContent -match '(?i)jquery\.srun\.portal\.js|/cgi-bin/srun_portal'
    if ($isSrunPortal -and [string]::IsNullOrWhiteSpace([string]$Settings.LoginEndpoint)) {
        return Invoke-SrunPortalAuthentication `
            -PortalUri $portalUri `
            -PortalHtml $pageContent `
            -WebSession $session `
            -Credential $Credential `
            -TimeoutSeconds ([int]$Settings.RequestTimeoutSeconds)
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$Settings.LoginEndpoint)) {
        $loginUri = [uri]::new($portalUri, [string]$Settings.LoginEndpoint)
        $method = [string]$Settings.LoginMethod
        if ([string]::IsNullOrWhiteSpace($method)) {
            $method = 'POST'
        }
        $method = $method.ToUpperInvariant()
        if ($method -notin @('GET', 'POST')) {
            throw "LoginMethod must be GET or POST; current value: $method"
        }
        if ([string]::IsNullOrWhiteSpace([string]$Settings.UsernameField) -or
            [string]::IsNullOrWhiteSpace([string]$Settings.PasswordField)) {
            throw 'UsernameField and PasswordField are required when LoginEndpoint is set.'
        }

        $form = [pscustomobject]@{
            ActionUri     = $loginUri
            Method        = $method
            UsernameField = [string]$Settings.UsernameField
            PasswordField = [string]$Settings.PasswordField
            DefaultFields = @{}
        }
    }
    else {
        $form = Find-PortalLoginForm `
            -Html ([string]$page.Content) `
            -BaseUri $portalUri `
            -UsernameField ([string]$Settings.UsernameField) `
            -PasswordField ([string]$Settings.PasswordField)
    }

    Assert-SafeLoginUri `
        -PortalUri $portalUri `
        -LoginUri $form.ActionUri `
        -AllowCrossOrigin:([bool]$Settings.AllowCrossOriginLoginEndpoint)

    $payload = New-PortalLoginPayload -Form $form -Credential $Credential -ExtraFields $Settings.ExtraFields
    $request = @{
        Uri         = $form.ActionUri
        Method      = $form.Method
        Body        = $payload
        UseBasicParsing = $true
        WebSession  = $session
        TimeoutSec  = [int]$Settings.RequestTimeoutSeconds
        ErrorAction = 'Stop'
    }
    $response = Invoke-WebRequest @request

    return [pscustomobject]@{
        StatusCode = $response.StatusCode
        Method     = $form.Method
        LoginUri   = $form.ActionUri
    }
}

function Get-NextRetryDelay {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateRange(1, 86400)][int]$CurrentSeconds,
        [Parameter(Mandatory = $true)][ValidateRange(1, 86400)][int]$MaximumSeconds
    )

    return [Math]::Min($MaximumSeconds, $CurrentSeconds * 2)
}

Export-ModuleMember -Function @(
    'Assert-SafeLoginUri',
    'ConvertFrom-Jsonp',
    'ConvertTo-SrunInfo',
    'Find-PortalLoginForm',
    'Get-ActivePhysicalEthernetAdapters',
    'Get-CampusConnectionContext',
    'Get-ConnectedWifiSsids',
    'Get-ConnectivityDecision',
    'Get-NextRetryDelay',
    'Invoke-PortalAuthentication',
    'Invoke-SrunPortalAuthentication',
    'New-PortalLoginPayload',
    'Select-CampusConnectionContext',
    'Test-InternetAccess',
    'Test-InternetAccessSet'
)
