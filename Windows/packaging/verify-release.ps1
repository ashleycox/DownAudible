[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Directory,
    [Parameter(Mandatory)] [ValidatePattern('^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$')] [string] $Version,
    [Parameter(Mandatory)] [ValidateRange(1, 65535)] [int] $Build,
    [string] $Publisher,
    [switch] $AllowUnsigned
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($AllowUnsigned -and $Publisher) {
    throw 'Use either the expected publisher or -AllowUnsigned for an unsigned build.'
}
if (!$AllowUnsigned -and [string]::IsNullOrWhiteSpace($Publisher)) {
    throw 'Provide the exact Authenticode certificate subject with -Publisher.'
}
if ($Publisher -match '[\r\n]') {
    throw 'The publisher must be a single certificate subject.'
}

function Assert-Machine([string] $Artifact, [uint16] $Expected) {
    $stream = [System.IO.File]::OpenRead($Artifact)
    try {
        $reader = [System.IO.BinaryReader]::new($stream)
        try {
            if ($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5a4d) {
                throw "Missing DOS header in $Artifact."
            }
            $stream.Position = 60
            $offset = [long] $reader.ReadUInt32()
            if ($offset -lt 64 -or $offset + 6 -gt $stream.Length) {
                throw "Invalid PE header offset in $Artifact."
            }
            $stream.Position = $offset
            if ($reader.ReadUInt32() -ne 0x00004550) {
                throw "Missing PE header in $Artifact."
            }
            $machine = $reader.ReadUInt16()
            if ($machine -ne $Expected) {
                throw ('Wrong machine for {0}. Expected 0x{1:x4}, found 0x{2:x4}.' -f $Artifact, $Expected, $machine)
            }
        } finally {
            $reader.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
}

function Assert-Version([string] $Artifact) {
    $info = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($Artifact)
    $fileVersion = "$Version.$Build"
    $numeric = '{0}.{1}.{2}.{3}' -f $info.FileMajorPart, $info.FileMinorPart, $info.FileBuildPart, $info.FilePrivatePart
    if ($info.ProductVersion -cne $Version -or $info.FileVersion -cne $fileVersion -or $numeric -cne $fileVersion) {
        throw "Expected product version $Version and file version $fileVersion in $Artifact."
    }
}

function Get-SignatureStatus([string] $Artifact) {
    $signature = Microsoft.PowerShell.Security\Get-AuthenticodeSignature -LiteralPath $Artifact
    if ($AllowUnsigned -and $signature.Status -eq 'NotSigned') {
        return 'NotSigned'
    }
    if ($signature.Status -ne 'Valid' -or $signature.SignatureType -ne 'Authenticode' -or !$signature.SignerCertificate) {
        throw "Expected a trusted Authenticode signature on $Artifact. Actual status: $($signature.Status)."
    }
    if (!$signature.TimeStamperCertificate) {
        throw "Missing Authenticode timestamp on $Artifact."
    }
    if (!$AllowUnsigned -and $signature.SignerCertificate.Subject -cne $Publisher) {
        throw "Unexpected Authenticode publisher on $Artifact."
    }
    return 'Valid'
}

function Get-ReleaseAsset([string] $AssetName) {
    $files = @(Get-ChildItem -LiteralPath $release.FullName -File -Force |
        Where-Object { $_.Name -ceq $AssetName })
    if ($files.Count -ne 1) {
        throw "Expected the release file $AssetName."
    }
    return $files[0]
}

function Get-SHA256([string] $Artifact) {
    return (Get-FileHash -LiteralPath $Artifact -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-Installer([System.IO.FileInfo] $Asset, [string] $Architecture) {
    # The read-only handle keeps these exact bytes in place during all checks.
    $lock = [System.IO.File]::OpenRead($Asset.FullName)
    try {
        Assert-Machine $Asset.FullName 0x014c
        Assert-Version $Asset.FullName
        $description = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($Asset.FullName).FileDescription
        if ($description -cne "DownAudible installer ($Architecture)") {
            throw "The description of $($Asset.Name) must identify its $Architecture payload."
        }
        $signature = Get-SignatureStatus $Asset.FullName
        return [pscustomobject] @{
            name = $Asset.Name
            length = $lock.Length
            sha256 = Get-SHA256 $Asset.FullName
            signature = $signature
            architecture = $Architecture
        }
    } finally {
        $lock.Dispose()
    }
}

function Save-CheckedEntry($Archive, [string] $EntryName, [string] $Destination, [long] $Limit) {
    $entries = @($Archive.Entries | Where-Object { $_.FullName -ieq $EntryName })
    if ($entries.Count -ne 1 -or $entries[0].FullName -cne $EntryName) {
        throw "Expected one exact ZIP entry at $EntryName."
    }
    $entry = $entries[0]
    if ($entry.Length -le 0 -or $entry.Length -gt $Limit) {
        throw "Unexpected ZIP entry length for $EntryName."
    }
    # Destination paths come from the verifier, never from ZIP entry paths.
    $output = [System.IO.File]::Open($Destination, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
    try {
        $source = $entry.Open()
        try {
            $buffer = New-Object byte[] 65536
            $total = 0L
            while (($read = $source.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $total += $read
                if ($total -gt $entry.Length) {
                    throw "ZIP entry data exceeded its declared length for $EntryName."
                }
                $output.Write($buffer, 0, $read)
            }
            if ($total -ne $entry.Length) {
                throw "ZIP entry data was truncated for $EntryName."
            }
        } finally {
            $source.Dispose()
        }
    } finally {
        $output.Dispose()
    }
}

function Assert-Portability([System.IO.FileInfo] $Asset, [string] $Stem, [string] $Architecture, [uint16] $Machine, [string] $Work) {
    $archive = [System.IO.Compression.ZipFile]::OpenRead($Asset.FullName)
    try {
        $launcher = Join-Path $Work 'DownAudible.exe'
        Save-CheckedEntry $archive "$Stem/DownAudible.exe" $launcher 2MB
        Assert-Machine $launcher $Machine
        Assert-Version $launcher
        $signature = Get-SignatureStatus $launcher

        $executables = [ordered] @{
            'python/python.exe' = 'python.exe'
            'python/pythonw.exe' = 'pythonw.exe'
            'resources/Media/ffmpeg.exe' = 'ffmpeg.exe'
            'resources/Media/ffprobe.exe' = 'ffprobe.exe'
        }
        foreach ($entry in $executables.GetEnumerator()) {
            $destination = Join-Path $Work $entry.Value
            Save-CheckedEntry $archive "$Stem/$($entry.Key)" $destination 200MB
            Assert-Machine $destination $Machine
        }

        $metadata = Join-Path $Work 'release.json'
        Save-CheckedEntry $archive "$Stem/python/downaudible_windows/release.json" $metadata 4KB
        $runtime = Get-Content -LiteralPath $metadata -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($runtime.version -isnot [string] -or $runtime.version -cne $Version -or
            ($runtime.build -isnot [int] -and $runtime.build -isnot [long]) -or $runtime.build -ne $Build) {
            throw "The runtime release information in $($Asset.Name) did not match $Version build $Build."
        }

        $manual = Join-Path $Work 'README.html'
        Save-CheckedEntry $archive "$Stem/resources/Help/README.html" $manual 1MB
        $contents = Get-Content -LiteralPath $manual -Raw -Encoding UTF8
        if ($contents -notmatch 'href="help-01-getting-started\.html"') {
            throw "Missing the Getting Started link from the offline manual in $($Asset.Name)."
        }
        Save-CheckedEntry $archive "$Stem/resources/Help/help-01-getting-started.html" (Join-Path $Work 'help-01-getting-started.html') 1MB

        if (!$AllowUnsigned) {
            $publisherFile = Join-Path $Work 'UpdatePublisher.txt'
            Save-CheckedEntry $archive "$Stem/resources/UpdatePublisher.txt" $publisherFile 4KB
            $packagedPublisher = (Get-Content -LiteralPath $publisherFile -Raw -Encoding UTF8).TrimEnd("`r", "`n")
            if ($packagedPublisher -cne $Publisher) {
                throw "The updater publisher in $($Asset.Name) did not match the expected signer."
            }
        }
        return [pscustomobject] @{
            name = $Asset.Name
            length = $Asset.Length
            sha256 = Get-SHA256 $Asset.FullName
            launcher_signature = $signature
            launcher_sha256 = Get-SHA256 $launcher
            architecture = $Architecture
        }
    } finally {
        $archive.Dispose()
    }
}

$release = Get-Item -LiteralPath $Directory
if ($release -isnot [System.IO.DirectoryInfo]) {
    throw 'Choose the directory containing the four Windows release assets.'
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
$scratch = Join-Path ([System.IO.Path]::GetTempPath()) ('DownAudibleVerify-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $scratch
try {
    $machines = [ordered] @{ ARM64 = 0xaa64; x64 = 0x8664 }
    $verified = foreach ($platform in $machines.Keys) {
        $architecture = $platform.ToLowerInvariant()
        $stem = "DownAudible-$Version-windows-$architecture"
        $assetStem = "DownAudible-Windows-$platform"
        $installer = Get-ReleaseAsset "$assetStem-Installer.exe"
        Assert-Installer $installer $architecture

        $portable = Get-ReleaseAsset "$assetStem-Portable.zip"
        $work = Join-Path $scratch $architecture
        $null = New-Item -ItemType Directory -Path $work
        Assert-Portability $portable $stem $architecture $machines[$platform] $work
    }
    [pscustomobject] @{
        version = $Version
        build = $Build
        publisher = $Publisher
        unsigned_rehearsal = [bool] $AllowUnsigned
        assets = @($verified)
    } | ConvertTo-Json -Depth 4
} finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
