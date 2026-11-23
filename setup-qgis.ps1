#Requires -Version 7.4
<#
.SYNOPSIS
    Resolves, verifies, installs and checks an official QGIS OSGeo4W MSI (setup-qgis-osgeo4w).
.DESCRIPTION
    Called by action.yml with -Phase resolve|install. Dot-source without -Phase to load the functions
    only (tests/setup-qgis.Tests.ps1 does that). Inputs arrive as INPUT_* environment variables.
#>
param([ValidateSet('resolve', 'install')] [string] $Phase)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:BaseUrl = 'https://download.osgeo.org/qgis/windows'
$script:Families = @{ standard = 'QGIS-OSGeo4W'; grids = 'QGIS-Grids-OSGeo4W' }
# Bump when the cached tree's layout or contents change meaning, so old entries stop matching.
$script:CacheFormat = '1'

#region resolver (pure, offline-testable) ---------------------------------------------------------

# File names (.msi / .sha256sum) linked from the nginx autoindex page.
function Get-ListingFile([string] $Html) {
    [regex]::Matches($Html, 'href="([^"/?#]+\.(?:msi|sha256sum))"') | ForEach-Object { $_.Groups[1].Value }
}

# Validates the selector inputs. Returns Installer (exact file name, when known without a listing),
# Family + Prefix (int[] version prefix, for listing resolution) and Sha256 (pin, lowercase, or '').
function Resolve-Request([string] $Version = '', [string] $Flavor = '', [string] $Installer = '', [string] $Sha256 = '') {
    if ($Sha256 -and $Sha256 -notmatch '^[0-9A-Fa-f]{64}$') { throw "Invalid sha256 '$Sha256': expected 64 hex digits." }
    $pin = $Sha256.ToLowerInvariant()

    if ($Installer) {
        if ($Version -or $Flavor) { throw "'installer' is mutually exclusive with 'version' and 'flavor'." }
        if ($Installer -notmatch '^[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*-OSGeo4W-\d+\.\d+\.\d+-\d+(?:\.msi)?$') {
            throw "Invalid installer '$Installer': expected a bare file name like QGIS-OSGeo4W-4.2.3-2[.msi]."
        }
        if ($Installer -notlike '*.msi') { $Installer += '.msi' }
        return [pscustomobject]@{ Installer = $Installer; Family = $null; Prefix = @(); Sha256 = $pin }
    }

    $family = $script:Families[$(if ($Flavor) { $Flavor } else { 'standard' })]
    if (-not $family -or $Flavor -cnotmatch '^(?:|standard|grids)$') { throw "Invalid flavor '$Flavor': expected standard or grids." }

    if ($Version -match '^\d+\.\d+\.\d+-\d+$') {
        return [pscustomobject]@{ Installer = "$family-$Version.msi"; Family = $family; Prefix = @(); Sha256 = $pin }
    }
    if ($Version -and $Version -cne 'latest' -and $Version -notmatch '^\d+(?:\.\d+){0,2}$') {
        throw "Invalid version '$Version': expected latest, 4, 4.2, 4.2.3 or 4.2.3-2."
    }
    if ($pin) { throw "'sha256' needs an exact build: version x.y.z-r or an installer file name, not '$Version'." }
    [int[]] $prefix = @()
    if ($Version -and $Version -cne 'latest') { $prefix = $Version -split '\.' }
    [pscustomobject]@{ Installer = $null; Family = $family; Prefix = $prefix; Sha256 = '' }
}

# Greatest <Family>-x.y.z-r.msi whose leading version components equal Prefix and whose .sha256sum
# is also listed (the MSI shows up about a minute before its checksum while uploading).
function Select-Installer([string[]] $File, [string] $Family, [int[]] $Prefix = @()) {
    $Prefix = @($Prefix)  # an empty array arrives as $null through a pscustomobject property
    $pattern = '^' + [regex]::Escape($Family) + '-(\d+)\.(\d+)\.(\d+)-(\d+)\.msi$'
    $best = $File | ForEach-Object {
        if ($_ -match $pattern -and $File -contains ($_ -replace '\.msi$', '.sha256sum')) {
            $parts = [int[]] $Matches[1..4]
            $ok = $true
            for ($i = 0; $i -lt $Prefix.Count; $i++) { if ($parts[$i] -ne $Prefix[$i]) { $ok = $false } }
            if ($ok) { [pscustomobject]@{ Name = $_; P = $parts } }
        }
    } | Sort-Object { $_.P[0] }, { $_.P[1] }, { $_.P[2] }, { $_.P[3] } | Select-Object -Last 1
    if (-not $best) {
        $wanted = if ($Prefix.Count) { "version prefix '$($Prefix -join '.')'" } else { 'any version' }
        throw "No $Family installer matches $wanted (with a published .sha256sum) at $script:BaseUrl/."
    }
    $best.Name
}

function Get-InstallerVersion([string] $Installer) {
    if ($Installer -notmatch '-((\d+\.\d+\.\d+)-\d+)\.msi$') { throw "Cannot parse a version from '$Installer'." }
    [pscustomobject]@{ Full = $Matches[1]; Release = $Matches[2] }
}

# Hash from a sha256sum line ("<hex> *<file>"), insisting it is the line for this installer.
function Read-Sha256Sum([string] $Text, [string] $Installer) {
    $m = [regex]::Match($Text, '(?im)^([0-9a-f]{64}) [ *]' + [regex]::Escape($Installer) + '\s*$')
    if (-not $m.Success) { throw "The .sha256sum for $Installer does not list that file." }
    $m.Groups[1].Value.ToLowerInvariant()
}

# SignatureChecked keeps trees installed with verify-signature: false apart from checked ones, so a
# job that skipped the check can't hand its tree to one that relies on it.
function Get-CacheKey([string] $Installer, [string] $Sha256, [string] $InstallDir, [string] $ImageOS, [bool] $SignatureChecked = $true) {
    $dirHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
            [Text.Encoding]::UTF8.GetBytes($InstallDir.TrimEnd('\').ToLowerInvariant()))).Substring(0, 8).ToLowerInvariant()
    $sig = if ($SignatureChecked) { 'sig' } else { 'nosig' }
    "setup-qgis-osgeo4w-$script:CacheFormat-$ImageOS-$($Installer -replace '\.msi$')-$Sha256-$dirHash-$sig"
}

# Exactly one O= (organizationName, 2.5.4.10) attribute equal to OSGeo's name, ignoring case (the
# subject's style changed over the years). Parsed, not matched as text: a quoted CN or L can contain
# ", O=The Open Source Geospatial Foundation".
function Test-OsgeoSigner([Security.Cryptography.X509Certificates.X509Certificate2] $Certificate) {
    if (-not $Certificate) { return $false }
    $rdns = @($Certificate.SubjectName.EnumerateRelativeDistinguishedNames())
    # .NET can't read inside a multi-valued RDN (where a second O= could hide); OSGeo's never has one.
    if ($rdns | Where-Object HasMultipleElements) { return $false }
    $orgs = @($rdns | Where-Object { $_.GetSingleElementType().Value -eq '2.5.4.10' } | ForEach-Object { $_.GetSingleElementValue() })
    $orgs.Count -eq 1 -and $orgs[0] -eq 'The Open Source Geospatial Foundation'
}

# Absolute, normalized, no trailing backslash. A drive or share root is refused: the bad-cache
# fallback deletes the install dir, and "C:\" trimmed to "C:" means the current directory.
# Control characters would forge step outputs; * ? [ ] are globs to actions/cache and Get-ChildItem;
# " breaks the msiexec command line, and % & ^ ! < > | are live in cmd, including in OSGeo4W's own
# .bat files, which expand the root unquoted (pushd %~dp0, path %OSGEO4W_ROOT%\...).
function Resolve-InstallDir([string] $Value, [string] $Release, [string] $ProgramFiles = $env:ProgramFiles) {
    if (-not $Value) { return Join-Path $ProgramFiles "QGIS $Release" }
    if ($Value -match '[\x00-\x1f*?\[\]"%&^!<>|]') { throw 'Invalid install-dir: control characters and * ? [ ] " % & ^ ! < > | are not allowed.' }
    if (-not [IO.Path]::IsPathFullyQualified($Value)) { throw "Invalid install-dir '$Value': expected an absolute path." }
    $full = [IO.Path]::GetFullPath($Value)
    if ([IO.Path]::GetPathRoot($full).TrimEnd('\') -eq $full.TrimEnd('\')) {
        throw "Invalid install-dir '$Value': a drive or share root can't be the install directory."
    }
    $full.TrimEnd('\')
}

#endregion

#region runtime helpers ------------------------------------------------------------------------------

# Runs a program with a raw command line (msiexec parses its own: PROP="value", never "PROP=value"),
# output going straight to the job log. Kills the process tree and throws once Deadline (UTC) passes.
function Invoke-WithDeadline([string] $FilePath, [string] $Arguments, [datetime] $Deadline) {
    $left = ($Deadline - [datetime]::UtcNow).TotalMilliseconds
    $name = [IO.Path]::GetFileName($FilePath)
    if ($left -le 0) { throw "$name timed out: its phase budget ran out before it could start." }
    $psi = [Diagnostics.ProcessStartInfo]::new($FilePath, $Arguments)
    $psi.UseShellExecute = $false
    $p = [Diagnostics.Process]::Start($psi)
    try {
        if (-not $p.WaitForExit([int][math]::Min($left, [int]::MaxValue))) {
            $p.Kill($true)
            $p.WaitForExit()
            throw "$name timed out: still running at the phase deadline ($($Deadline.ToString('u')))."
        }
        $p.WaitForExit()
        $p.ExitCode
    } finally { $p.Dispose() }
}

function Get-Deadline([int] $Minutes) {
    if ($Minutes -le 0) { [datetime]::MaxValue } else { [datetime]::UtcNow.AddMinutes($Minutes) }
}

# Where the parts consumers need live inside an installed tree. The package name (qgis, qgis-ltr, ...)
# varies per build, so it is read from the single bin\qgis_process-<package>.bat.
function Get-QgisLayout([string] $Root) {
    $bats = @(Get-ChildItem -LiteralPath (Join-Path $Root 'bin') -Filter 'qgis_process-*.bat' -File -ErrorAction SilentlyContinue)
    if ($bats.Count -ne 1) { throw "Expected exactly one bin\qgis_process-*.bat under $Root, found $($bats.Count)." }
    $python = Get-ChildItem -LiteralPath (Join-Path $Root 'apps') -Directory -Filter 'Python3*' -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName 'python.exe' } | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    [pscustomobject]@{
        Prefix      = Join-Path $Root 'apps' ($bats[0].BaseName -replace '^qgis_process-')
        QgisProcess = $bats[0].FullName
        Python      = if ($python) { $python } else { '' }
    }
}

function Invoke-Download([string] $Url, [string] $OutFile, [datetime] $Deadline, [switch] $Large) {
    # --retry covers timeouts/429/5xx. The big MSI also retries resets and resumes (--continue-at -);
    # small files don't use --retry-all-errors, so a 404 fails at once instead of after 5 retries.
    $extra = if ($Large) { '--retry-all-errors --continue-at - --speed-limit 102400 --speed-time 60' } else { '--max-time 120' }
    $curl = (Get-Command curl -CommandType Application | Select-Object -First 1).Source
    # HTTPS only, redirects included: with verify-signature off and no pin, http would let both
    # the .sha256sum and the MSI be swapped in transit.
    $code = Invoke-WithDeadline $curl "--fail --location --proto =https --proto-redir =https --silent --show-error --retry 5 --retry-delay 5 $extra --user-agent setup-qgis-osgeo4w --output `"$OutFile`" `"$Url`"" $Deadline
    if ($code -eq 22) { throw "Download failed (HTTP error, e.g. 404 not found): $Url" }
    if ($code -ne 0) { throw "curl exited with code $code downloading $Url" }
}

function Write-StepOutput([hashtable] $Values) {
    $Values.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" } | Add-Content -LiteralPath $env:GITHUB_OUTPUT
}

# Folds a phase's log. The block runs in a child scope: hand values back as its output, not by assignment.
function Invoke-Group([string] $Title, [scriptblock] $Body) {
    Write-Host "::group::$Title"
    try { & $Body } finally { Write-Host '::endgroup::' }
}

function Get-BoolInput([string] $Name) {
    $v = [Environment]::GetEnvironmentVariable("INPUT_$Name")
    if ($v -notin 'true', 'false') { throw "Invalid $($Name.ToLower() -replace '_', '-') '$v': expected true or false." }
    $v -eq 'true'
}

function Get-MinutesInput([string] $Name) {
    $v = [Environment]::GetEnvironmentVariable("INPUT_$Name")
    if ($v -notmatch '^\d{1,4}$') { throw "Invalid $($Name.ToLower() -replace '_', '-') '$v': expected whole minutes (0 = no limit)." }
    [int] $v
}

function Show-LogTail([string] $Path, [int] $Lines = 60) {
    if (Test-Path -LiteralPath $Path) {
        Write-Host "----- last $Lines lines of $Path -----"
        Get-Content -LiteralPath $Path -Tail $Lines | Write-Host
    }
}

# Runs qgis_process --version through its .bat (which needs the paths postinstall wrote).
function Test-QgisInstall([string] $Root, [datetime] $Deadline) {
    $layout = Get-QgisLayout $Root
    $code = Invoke-WithDeadline $env:ComSpec "/d /s /c `"`"$($layout.QgisProcess)`" --version`"" $Deadline
    if ($code -ne 0) { throw "qgis_process --version exited with code $code." }
    $layout
}

#endregion

#region phases ---------------------------------------------------------------------------------------

function Invoke-ResolvePhase {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    if (-not $IsWindows) { throw 'setup-qgis-osgeo4w runs on Windows runners only.' }
    $req = Resolve-Request -Version "$env:INPUT_VERSION".Trim() -Flavor "$env:INPUT_FLAVOR".Trim() `
        -Installer "$env:INPUT_INSTALLER".Trim() -Sha256 "$env:INPUT_SHA256".Trim()
    foreach ($b in 'CACHE', 'ADD_TO_PATH') { $null = Get-BoolInput $b }
    $verifySignature = Get-BoolInput 'VERIFY_SIGNATURE'
    $downloadMinutes = Get-MinutesInput 'DOWNLOAD_TIMEOUT_MINUTES'
    $null = Get-MinutesInput 'INSTALL_TIMEOUT_MINUTES'
    $dirInput = "$env:INPUT_INSTALL_DIR".Trim()
    $null = Resolve-InstallDir -Value $dirInput -Release '0'  # validate before any network access

    $deadline = Get-Deadline $downloadMinutes
    $work = New-Item -ItemType Directory -Force (Join-Path $env:RUNNER_TEMP 'setup-qgis-osgeo4w')
    $installer = $req.Installer
    if (-not $installer) {
        $installer = Invoke-Group 'Resolve installer from the download listing' {
            $listing = Join-Path $work 'listing.html'
            Invoke-Download "$script:BaseUrl/" $listing $deadline
            $name = Select-Installer -File (Get-ListingFile (Get-Content -Raw -LiteralPath $listing)) -Family $req.Family -Prefix $req.Prefix
            Write-Host "Selected $name"
            $name
        }
    }
    $sha256 = $req.Sha256
    if ($sha256) { Write-Host "Using the pinned sha256 $sha256" }
    else {
        $sumFile = Join-Path $work ($installer -replace '\.msi$', '.sha256sum')
        Invoke-Download "$script:BaseUrl/$(Split-Path -Leaf $sumFile)" $sumFile $deadline
        $sha256 = Read-Sha256Sum (Get-Content -Raw -LiteralPath $sumFile) $installer
        Write-Host "Published sha256 of ${installer}: $sha256"
    }

    $version = Get-InstallerVersion $installer
    $installDir = Resolve-InstallDir -Value $dirInput -Release $version.Release
    $imageOS = if ($env:ImageOS) { $env:ImageOS } else { 'unknown' }
    Write-StepOutput @{
        'installer'        = $installer
        'version'          = $version.Full
        'sha256'           = $sha256
        'install-dir'      = $installDir
        'cache-key'        = Get-CacheKey -Installer $installer -Sha256 $sha256 -InstallDir $installDir -ImageOS $imageOS -SignatureChecked $verifySignature
        'resolve-seconds'  = [int] $sw.Elapsed.TotalSeconds
        'resolved-at'      = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    }
}

function Invoke-InstallPhase {
    $timing = [ordered]@{ resolve = [int] $env:SQO_RESOLVE_SECONDS }
    $timing.restore = [int](([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - [long] $env:SQO_RESOLVED_AT) / 1000)
    $dir = $env:SQO_INSTALL_DIR
    $installer = $env:SQO_INSTALLER
    $key = $env:SQO_CACHE_KEY
    $cacheEnabled = Get-BoolInput 'CACHE'
    $installMinutes = Get-MinutesInput 'INSTALL_TIMEOUT_MINUTES'
    $downloadMinutes = Get-MinutesInput 'DOWNLOAD_TIMEOUT_MINUTES'
    $signer = 'not checked'
    $cacheState = if (-not $cacheEnabled) { 'disabled' } elseif ($env:SQO_RESTORE_HIT -eq 'true') { 'hit' } else { 'miss' }
    $layout = $null

    if ($cacheState -eq 'hit') {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try {
            $layout = Invoke-Group 'Check the cached QGIS tree' { Test-QgisInstall $dir (Get-Deadline $installMinutes) }
            # The key ties the tree to a verified MSI, but anything that can write this repo's
            # cache could have stored it; nothing here re-checks it (see README, Security).
            $signer = 'restored from cache, not re-verified'
        } catch {
            Write-Host "::warning title=setup-qgis-osgeo4w::The cached QGIS tree failed its check ($($_.Exception.Message)); reinstalling from the MSI. Delete the bad entry with: gh cache delete $key"
            $cacheState = 'hit, failed check, reinstalled'
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
        $timing.check = [int] $sw.Elapsed.TotalSeconds
    }

    if (-not $layout) {
        $work = Join-Path $env:RUNNER_TEMP 'setup-qgis-osgeo4w'
        $msi = Join-Path $work $installer
        $partial = "$msi.partial"
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Invoke-Group "Download $installer" {
            $left = $downloadMinutes * 60 - [int] $env:SQO_RESOLVE_SECONDS
            $deadline = if ($downloadMinutes -le 0) { [datetime]::MaxValue } else { [datetime]::UtcNow.AddSeconds([math]::Max($left, 0)) }
            Invoke-Download "$script:BaseUrl/$installer" $partial $deadline -Large
        }
        $timing.download = [int] $sw.Elapsed.TotalSeconds

        $sw.Restart()
        $signer = Invoke-Group "Verify $installer" {
            $actual = (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($actual -ne $env:SQO_SHA256) {
                Remove-Item -LiteralPath $partial -Force
                throw "SHA-256 mismatch for ${installer}: expected $env:SQO_SHA256, got $actual. The file on the server changed or the download is corrupt."
            }
            Write-Host "SHA-256 OK: $actual"
            Move-Item -LiteralPath $partial -Destination $msi -Force
            if (-not (Get-BoolInput 'VERIFY_SIGNATURE')) { return 'not checked (verify-signature: false)' }
            # Checked on the final .msi name: Windows picks the signature format from the file type.
            $sig = Get-AuthenticodeSignature -LiteralPath $msi
            $subject = if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { '' }
            if ($sig.Status -ne 'Valid' -or -not (Test-OsgeoSigner $sig.SignerCertificate)) {
                Remove-Item -LiteralPath $msi -Force
                throw "Authenticode check failed for ${installer}: status $($sig.Status), signer '$subject'. Set verify-signature: false only if you trust this file anyway."
            }
            Write-Host "Signature OK: $subject"
            $subject
        }
        $timing.verify = [int] $sw.Elapsed.TotalSeconds

        $sw.Restart()
        $deadline = Get-Deadline $installMinutes
        $log = Join-Path $work 'msiexec.log'
        Invoke-Group "Install into $dir" {
            # No trailing backslash before the closing quote: msiexec would read \" as an escaped quote.
            $code = Invoke-WithDeadline (Join-Path $env:SystemRoot 'System32' 'msiexec.exe') `
                "/i `"$msi`" /qn /norestart INSTALLDIR=`"$($dir.TrimEnd('\'))`" INSTALLDESKTOPSHORTCUTS=0 INSTALLMENUSHORTCUTS=0 /l* `"$log`"" $deadline
            if ($code -notin 0, 3010) {
                Show-LogTail $log
                throw "msiexec exited with code $code (see https://learn.microsoft.com/windows/win32/msi/error-codes)."
            }
            Remove-Item -LiteralPath $msi -Force
        }
        $timing.install = [int] $sw.Elapsed.TotalSeconds

        $sw.Restart()
        $layout = Invoke-Group 'Check the installed QGIS' {
            try { Test-QgisInstall $dir $deadline }
            catch {
                # postinstall.bat failures don't fail msiexec (its custom action ignores the exit code).
                Show-LogTail (Join-Path $dir 'var' 'log' 'postinstall.log')
                Show-LogTail $log
                throw
            }
        }
        $timing.check = [int] $sw.Elapsed.TotalSeconds
    }

    $fromCache = $cacheState -eq 'hit'
    Write-StepOutput @{
        'cache-hit'    = $fromCache.ToString().ToLower()
        'fresh'        = (-not $fromCache).ToString().ToLower()
        'root'         = $dir
        'prefix'       = $layout.Prefix
        'qgis-process' = $layout.QgisProcess
        'python'       = $layout.Python
    }
    if (Get-BoolInput 'ADD_TO_PATH') { Join-Path $dir 'bin' | Add-Content -LiteralPath $env:GITHUB_PATH }

    $times = ($timing.GetEnumerator() | ForEach-Object { "$($_.Key) $($_.Value)" }) -join ', '
    Write-Host "Timings (s): $times"
    @(
        '### setup-qgis-osgeo4w', '', '| | |', '|---|---|'
        "| Installer | ``$installer`` |", "| SHA-256 | ``$env:SQO_SHA256`` |", "| Signature | $signer |"
        "| Cache | $cacheState |", "| Root | ``$dir`` |", "| Prefix | ``$($layout.Prefix)`` |", "| Timings (s) | $times |", ''
    ) | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY
}

#endregion

if ($Phase) {
    try {
        if ($Phase -eq 'resolve') { Invoke-ResolvePhase } else { Invoke-InstallPhase }
    } catch {
        $msg = $_.Exception.Message -replace '%', '%25' -replace "`r", '%0D' -replace "`n", '%0A'
        Write-Host "::error title=setup-qgis-osgeo4w::$msg"
        exit 1
    }
}
