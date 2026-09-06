using System.Globalization;
using System.Reflection;
using System.Text.RegularExpressions;

namespace BITWebVersioning;

public sealed partial class ReleaseVersion : IComparable<ReleaseVersion>, IEquatable<ReleaseVersion>
{
    private ReleaseVersion(int major, int minor, int patch, int? rcOrdinal)
    {
        Major = major;
        Minor = minor;
        Patch = patch;
        RcOrdinal = rcOrdinal;
    }

    public int Major { get; }
    public int Minor { get; }
    public int Patch { get; }
    public int? RcOrdinal { get; }
    public bool IsPrerelease => RcOrdinal.HasValue;
    public string BaseVersion => $"{Major}.{Minor}.{Patch}";

    public static ReleaseVersion Parse(string value)
    {
        if (!TryParse(value, out var version))
            throw new FormatException($"Invalid release version: '{value}'.");
        return version;
    }

    public static bool TryParse(string? value, out ReleaseVersion version)
    {
        version = null!;
        var match = VersionPattern().Match(value ?? string.Empty);
        if (!match.Success) return false;
        if (!int.TryParse(match.Groups[1].Value, NumberStyles.None, CultureInfo.InvariantCulture, out var major) ||
            !int.TryParse(match.Groups[2].Value, NumberStyles.None, CultureInfo.InvariantCulture, out var minor) ||
            !int.TryParse(match.Groups[3].Value, NumberStyles.None, CultureInfo.InvariantCulture, out var patch)) return false;
        int? rc = null;
        if (match.Groups[4].Success)
        {
            if (!int.TryParse(match.Groups[4].Value, NumberStyles.None, CultureInfo.InvariantCulture, out var ordinal)) return false;
            rc = ordinal;
        }
        version = new ReleaseVersion(major, minor, patch, rc);
        return true;
    }

    public static ReleaseVersion ParseTag(string tag)
    {
        if (string.IsNullOrEmpty(tag) || tag[0] != 'v' || !TryParse(tag[1..], out var version))
            throw new FormatException($"Invalid release tag: '{tag}'.");
        return version;
    }

    public static ReleaseVersion FromAssembly(Assembly assembly)
    {
        var value = assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion;
        if (!TryParse(value, out var version))
            throw new InvalidOperationException($"Assembly informational version '{value}' is not a supported release version.");
        return version;
    }

    public int CompareTo(ReleaseVersion? other)
    {
        if (other is null) return 1;
        var comparison = Major.CompareTo(other.Major);
        if (comparison == 0) comparison = Minor.CompareTo(other.Minor);
        if (comparison == 0) comparison = Patch.CompareTo(other.Patch);
        if (comparison != 0) return comparison;
        if (RcOrdinal is null) return other.RcOrdinal is null ? 0 : 1;
        if (other.RcOrdinal is null) return -1;
        return RcOrdinal.Value.CompareTo(other.RcOrdinal.Value);
    }

    public bool Equals(ReleaseVersion? other) => CompareTo(other) == 0;
    public override bool Equals(object? obj) => obj is ReleaseVersion other && Equals(other);
    public override int GetHashCode() => HashCode.Combine(Major, Minor, Patch, RcOrdinal);
    public override string ToString() => RcOrdinal is null ? BaseVersion : $"{BaseVersion}-rc.{RcOrdinal.Value}";

    public static implicit operator ReleaseVersion(Version version) =>
        new(version.Major, version.Minor, version.Build < 0 ? 0 : version.Build, null);

    public static bool operator <(ReleaseVersion left, ReleaseVersion right) => left.CompareTo(right) < 0;
    public static bool operator >(ReleaseVersion left, ReleaseVersion right) => left.CompareTo(right) > 0;
    public static bool operator <=(ReleaseVersion left, ReleaseVersion right) => left.CompareTo(right) <= 0;
    public static bool operator >=(ReleaseVersion left, ReleaseVersion right) => left.CompareTo(right) >= 0;
    public static bool operator ==(ReleaseVersion? left, ReleaseVersion? right) => Equals(left, right);
    public static bool operator !=(ReleaseVersion? left, ReleaseVersion? right) => !Equals(left, right);

    [GeneratedRegex(@"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-rc\.([1-9]\d*))?$", RegexOptions.CultureInvariant)]
    private static partial Regex VersionPattern();
}
