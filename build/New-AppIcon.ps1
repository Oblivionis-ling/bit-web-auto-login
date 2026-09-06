[CmdletBinding()]
param(
    [string]$OutputPath,
    [string]$PreviewPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $projectRoot 'manager\BITWebManager\Resources\BITWebManager.ico'
}
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
$expectedRoot = ([IO.Path]::GetFullPath($projectRoot)).TrimEnd('\') + '\'
if (-not $OutputPath.StartsWith($expectedRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "OutputPath must stay under $expectedRoot"
}
if (-not [string]::IsNullOrWhiteSpace($PreviewPath)) {
    $PreviewPath = [IO.Path]::GetFullPath($PreviewPath)
    if (-not $PreviewPath.StartsWith($expectedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "PreviewPath must stay under $expectedRoot"
    }
}

Add-Type -AssemblyName System.Drawing

function New-RoundedRectanglePath {
    param([float]$X, [float]$Y, [float]$Width, [float]$Height, [float]$Radius)
    $path = New-Object Drawing.Drawing2D.GraphicsPath
    $diameter = $Radius * 2
    $path.AddArc($X, $Y, $diameter, $diameter, 180, 90)
    $path.AddArc($X + $Width - $diameter, $Y, $diameter, $diameter, 270, 90)
    $path.AddArc($X + $Width - $diameter, $Y + $Height - $diameter, $diameter, $diameter, 0, 90)
    $path.AddArc($X, $Y + $Height - $diameter, $diameter, $diameter, 90, 90)
    $path.CloseFigure()
    return $path
}

function New-IconFrame {
    param([int]$Size)
    $scale = $Size / 256.0
    $bitmap = New-Object Drawing.Bitmap($Size, $Size, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.Clear([Drawing.Color]::Transparent)
        $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality

        $background = New-RoundedRectanglePath (8 * $scale) (8 * $scale) (240 * $scale) (240 * $scale) (52 * $scale)
        $backgroundBrush = New-Object Drawing.SolidBrush([Drawing.ColorTranslator]::FromHtml('#16324A'))
        try { $graphics.FillPath($backgroundBrush, $background) } finally { $backgroundBrush.Dispose(); $background.Dispose() }

        $mark = New-Object Drawing.Drawing2D.GraphicsPath
        $mark.StartFigure()
        $mark.AddLine(76 * $scale, 52 * $scale, 76 * $scale, 204 * $scale)
        $mark.StartFigure()
        $mark.AddBezier(76 * $scale, 62 * $scale, 114 * $scale, 62 * $scale, 178 * $scale, 60 * $scale, 178 * $scale, 102 * $scale)
        $mark.AddBezier(178 * $scale, 102 * $scale, 178 * $scale, 142 * $scale, 116 * $scale, 142 * $scale, 76 * $scale, 142 * $scale)
        $mark.StartFigure()
        $mark.AddBezier(76 * $scale, 142 * $scale, 120 * $scale, 142 * $scale, 186 * $scale, 138 * $scale, 186 * $scale, 181 * $scale)
        $mark.AddBezier(186 * $scale, 181 * $scale, 186 * $scale, 224 * $scale, 119 * $scale, 220 * $scale, 76 * $scale, 220 * $scale)
        $pen = New-Object Drawing.Pen([Drawing.Color]::White, [Math]::Max(2.0, 20 * $scale))
        $pen.StartCap = $pen.EndCap = [Drawing.Drawing2D.LineCap]::Round
        $pen.LineJoin = [Drawing.Drawing2D.LineJoin]::Round
        try { $graphics.DrawPath($pen, $mark) } finally { $pen.Dispose(); $mark.Dispose() }

        $nodeBrush = New-Object Drawing.SolidBrush([Drawing.ColorTranslator]::FromHtml('#45C7D8'))
        $nodePen = New-Object Drawing.Pen([Drawing.ColorTranslator]::FromHtml('#16324A'), [Math]::Max(1.0, 7 * $scale))
        try {
            $graphics.FillEllipse($nodeBrush, 175 * $scale, 47 * $scale, 30 * $scale, 30 * $scale)
            $graphics.DrawEllipse($nodePen, 175 * $scale, 47 * $scale, 30 * $scale, 30 * $scale)
        }
        finally { $nodeBrush.Dispose(); $nodePen.Dispose() }

        $stream = New-Object IO.MemoryStream
        $bitmap.Save($stream, [Drawing.Imaging.ImageFormat]::Png)
        return ,$stream.ToArray()
    }
    finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

$sizes = @(16, 20, 24, 32, 48, 64, 128, 256)
$frames = @($sizes | ForEach-Object { New-IconFrame $_ })
$outputDirectory = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

$stream = [IO.File]::Open($OutputPath, [IO.FileMode]::Create, [IO.FileAccess]::Write)
$writer = New-Object IO.BinaryWriter($stream)
try {
    $writer.Write([uint16]0)
    $writer.Write([uint16]1)
    $writer.Write([uint16]$sizes.Count)
    $offset = 6 + (16 * $sizes.Count)
    for ($index = 0; $index -lt $sizes.Count; $index++) {
        $sizeByte = if ($sizes[$index] -eq 256) { 0 } else { $sizes[$index] }
        $writer.Write([byte]$sizeByte)
        $writer.Write([byte]$sizeByte)
        $writer.Write([byte]0)
        $writer.Write([byte]0)
        $writer.Write([uint16]1)
        $writer.Write([uint16]32)
        $writer.Write([uint32]$frames[$index].Length)
        $writer.Write([uint32]$offset)
        $offset += $frames[$index].Length
    }
    foreach ($frame in $frames) { $writer.Write([byte[]]$frame) }
}
finally {
    $writer.Dispose()
    $stream.Dispose()
}

if (-not [string]::IsNullOrWhiteSpace($PreviewPath)) {
    $previewDirectory = Split-Path -Parent $PreviewPath
    if (-not (Test-Path -LiteralPath $previewDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $previewDirectory -Force | Out-Null
    }
    [IO.File]::WriteAllBytes($PreviewPath, [byte[]]$frames[$frames.Count - 1])
}

Write-Host "Generated $OutputPath with $($sizes.Count) frames: $($sizes -join ', ') px"
