#Requires -Version 7.2
# Offline self-check of the installer resolver: no network, no Pester (plain throws).
# Run: pwsh -NoProfile -File tests/Resolve.Tests.ps1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..' 'setup-qgis.ps1')

$script:failures = 0
function Test-Case([string] $Name, [scriptblock] $Body) {
    try { & $Body; Write-Host "ok   $Name" }
    catch { $script:failures++; Write-Host "FAIL $Name`n     $($_.Exception.Message)" }
}
function Assert-Equal($Expected, $Actual) {
    if ($Expected -cne $Actual) { throw "expected '$Expected', got '$Actual'" }
}
function Assert-Throw([scriptblock] $Body, [string] $Like) {
    try { & $Body } catch {
        if ($_.Exception.Message -notlike "*$Like*") { throw "threw '$($_.Exception.Message)', wanted '*$Like*'" }
        return
    }
    throw "did not throw (wanted '*$Like*')"
}

$files = Get-ListingFile (Get-Content -Raw (Join-Path $PSScriptRoot 'fixtures' 'listing.html'))

# Resolves a request against the real listing fixture and returns the chosen file name.
function Select-From([string] $Version, [string] $Flavor = '') {
    $req = Resolve-Request -Version $Version -Flavor $Flavor
    if ($req.Installer) { return $req.Installer }
    (Select-Installer -File $files -Family $req.Family -Prefix $req.Prefix)
}

Test-Case 'listing parses msi and sha256sum names only' {
    Assert-Equal $true ($files -contains 'QGIS-OSGeo4W-4.4.0-1.msi')
    Assert-Equal $true ($files -contains 'QGIS-OSGeo4W-4.4.0-1.sha256sum')
    Assert-Equal $false ($files -contains '../')
    Assert-Equal 0 @($files | Where-Object { $_ -like '`?*' }).Count
}
Test-Case 'empty version = latest standard' { Assert-Equal 'QGIS-OSGeo4W-4.4.0-1.msi' (Select-From '') }
Test-Case 'latest keyword' { Assert-Equal 'QGIS-OSGeo4W-4.4.0-1.msi' (Select-From 'latest') }
Test-Case 'major prefix 4' { Assert-Equal 'QGIS-OSGeo4W-4.4.0-1.msi' (Select-From '4') }
Test-Case 'major prefix 3 picks 3.44.16-1' { Assert-Equal 'QGIS-OSGeo4W-3.44.16-1.msi' (Select-From '3') }
Test-Case 'minor prefix picks highest revision' { Assert-Equal 'QGIS-OSGeo4W-4.2.3-2.msi' (Select-From '4.2') }
Test-Case 'patch prefix picks highest revision' { Assert-Equal 'QGIS-OSGeo4W-4.2.3-2.msi' (Select-From '4.2.3') }
Test-Case 'numeric not lexical: 3.44.9 < 3.44.16' { Assert-Equal 'QGIS-OSGeo4W-3.44.16-1.msi' (Select-From '3.44') }
Test-Case 'dot boundary: 3.4 never matches 3.40/3.44' { Assert-Throw { Select-From '3.4' } 'No QGIS-OSGeo4W installer matches' }
Test-Case 'exact version needs no listing' {
    $req = Resolve-Request -Version '4.2.3-1'
    Assert-Equal 'QGIS-OSGeo4W-4.2.3-1.msi' $req.Installer
}
Test-Case 'grids latest' { Assert-Equal 'QGIS-Grids-OSGeo4W-4.4.0-1.msi' (Select-From '' 'grids') }
Test-Case 'grids prefix with no match fails' { Assert-Throw { Select-From '3.40' 'grids' } 'No QGIS-Grids-OSGeo4W installer matches' }
Test-Case 'grids exact' { Assert-Equal 'QGIS-Grids-OSGeo4W-4.2.3-2.msi' (Select-From '4.2.3-2' 'grids') }
Test-Case 'standard flavor spelled out' { Assert-Equal 'QGIS-OSGeo4W-4.4.0-1.msi' (Select-From '' 'standard') }
Test-Case 'msi without .sha256sum is skipped; .msi.off ignored' {
    $f = 'QGIS-OSGeo4W-9.0.0-1.msi', 'QGIS-OSGeo4W-9.0.1-1.msi', 'QGIS-OSGeo4W-9.0.0-1.sha256sum',
    'QGIS-OSGeo4W-9.0.2-1.msi.off', 'QGIS-OSGeo4W-9.0.2-1.sha256sum'
    Assert-Equal 'QGIS-OSGeo4W-9.0.0-1.msi' (Select-Installer -File $f -Family 'QGIS-OSGeo4W' -Prefix @())
}
Test-Case 'revision compares numerically (-10 > -9)' {
    $f = 'QGIS-OSGeo4W-9.0.0-9.msi', 'QGIS-OSGeo4W-9.0.0-9.sha256sum', 'QGIS-OSGeo4W-9.0.0-10.msi', 'QGIS-OSGeo4W-9.0.0-10.sha256sum'
    Assert-Equal 'QGIS-OSGeo4W-9.0.0-10.msi' (Select-Installer -File $f -Family 'QGIS-OSGeo4W' -Prefix @())
}
Test-Case 'family match is exact (QGISQT6 / Grids not mixed in)' {
    $f = 'QGISQT6-OSGeo4W-9.9.9-1.msi', 'QGISQT6-OSGeo4W-9.9.9-1.sha256sum', 'QGIS-OSGeo4W-1.0.0-1.msi', 'QGIS-OSGeo4W-1.0.0-1.sha256sum'
    Assert-Equal 'QGIS-OSGeo4W-1.0.0-1.msi' (Select-Installer -File $f -Family 'QGIS-OSGeo4W' -Prefix @())
}
foreach ($bad in '4.', 'v4', '4.2-1', '4.2.3.1', '4.2.3-', ' 4', 'latest-1') {
    Test-Case "invalid version '$bad'" { Assert-Throw { Resolve-Request -Version $bad } 'Invalid version' }
}
Test-Case 'invalid flavor' { Assert-Throw { Resolve-Request -Flavor 'qt6' } 'Invalid flavor' }
Test-Case 'installer with and without .msi' {
    Assert-Equal 'QGISQT6-OSGeo4W-3.44.6-1.msi' (Resolve-Request -Installer 'QGISQT6-OSGeo4W-3.44.6-1').Installer
    Assert-Equal 'QGIS-Grids-OSGeo4W-4.2.3-2.msi' (Resolve-Request -Installer 'QGIS-Grids-OSGeo4W-4.2.3-2.msi').Installer
}
foreach ($bad in 'weekly/QGIS-OSGeo4W-4.3.0-1.msi', 'QGIS-OSGeo4W-4.3.0-1254-b7db8233afb-1.msi', '..\QGIS-OSGeo4W-4.2.3-1.msi', 'QGIS-OSGeo4W-4.2.3-1.exe', 'https://x/QGIS-OSGeo4W-4.2.3-1.msi') {
    Test-Case "invalid installer '$bad'" { Assert-Throw { Resolve-Request -Installer $bad } 'Invalid installer' }
}
Test-Case 'installer + version is rejected' { Assert-Throw { Resolve-Request -Installer 'QGIS-OSGeo4W-4.2.3-1' -Version '4.2' } 'mutually exclusive' }
Test-Case 'installer + flavor is rejected' { Assert-Throw { Resolve-Request -Installer 'QGIS-OSGeo4W-4.2.3-1' -Flavor 'grids' } 'mutually exclusive' }
$sha = 'A' * 64
Test-Case 'sha256 with exact version is accepted and lowercased' { Assert-Equal ('a' * 64) (Resolve-Request -Version '4.2.3-1' -Sha256 $sha).Sha256 }
Test-Case 'sha256 with installer is accepted' { Assert-Equal ('a' * 64) (Resolve-Request -Installer 'QGIS-OSGeo4W-4.2.3-1' -Sha256 $sha).Sha256 }
Test-Case 'sha256 with prefix is rejected' { Assert-Throw { Resolve-Request -Version '4.2' -Sha256 $sha } 'exact' }
Test-Case 'sha256 with latest is rejected' { Assert-Throw { Resolve-Request -Sha256 $sha } 'exact' }
Test-Case 'bad sha256 format' { Assert-Throw { Resolve-Request -Version '4.2.3-1' -Sha256 'abc' } 'Invalid sha256' }
Test-Case 'version parts of an installer name' {
    $v = Get-InstallerVersion 'QGIS-Grids-OSGeo4W-4.2.3-2.msi'
    Assert-Equal '4.2.3-2' $v.Full
    Assert-Equal '4.2.3' $v.Release
}
Test-Case '.sha256sum parsing' {
    Assert-Equal ('9b' + 'c' * 62) (Read-Sha256Sum "9B$('C' * 62) *QGIS-OSGeo4W-4.4.0-1.msi`n" 'QGIS-OSGeo4W-4.4.0-1.msi')
    Assert-Throw { Read-Sha256Sum "$('c' * 64) *QGIS-OSGeo4W-4.4.0-2.msi" 'QGIS-OSGeo4W-4.4.0-1.msi' } 'does not list'
    Assert-Throw { Read-Sha256Sum '<html>404</html>' 'QGIS-OSGeo4W-4.4.0-1.msi' } 'does not list'
}
Test-Case 'cache key changes with path, sha and image' {
    $a = Get-CacheKey -Installer 'QGIS-OSGeo4W-4.4.0-1.msi' -Sha256 ('a' * 64) -InstallDir 'C:\Program Files\QGIS 4.4.0' -ImageOS 'win25'
    Assert-Equal $a (Get-CacheKey -Installer 'QGIS-OSGeo4W-4.4.0-1.msi' -Sha256 ('a' * 64) -InstallDir 'c:\program files\qgis 4.4.0' -ImageOS 'win25')
    Assert-Equal $true ($a -ne (Get-CacheKey -Installer 'QGIS-OSGeo4W-4.4.0-1.msi' -Sha256 ('a' * 64) -InstallDir 'D:\QGIS' -ImageOS 'win25'))
    Assert-Equal $true ($a -ne (Get-CacheKey -Installer 'QGIS-OSGeo4W-4.4.0-1.msi' -Sha256 ('b' * 64) -InstallDir 'C:\Program Files\QGIS 4.4.0' -ImageOS 'win25'))
    Assert-Equal $true ($a -ne (Get-CacheKey -Installer 'QGIS-OSGeo4W-4.4.0-1.msi' -Sha256 ('a' * 64) -InstallDir 'C:\Program Files\QGIS 4.4.0' -ImageOS 'win22'))
}
Test-Case 'signer check accepts both certificate subject styles' {
    Assert-Equal $true (Test-OsgeoSigner 'CN=THE OPEN SOURCE GEOSPATIAL FOUNDATION, O=THE OPEN SOURCE GEOSPATIAL FOUNDATION, L=Beaverton, S=Oregon, C=US')
    Assert-Equal $true (Test-OsgeoSigner 'CN=The Open Source Geospatial Foundation, OU=OSGeo Foundation, O=The Open Source Geospatial Foundation, L=Beaverton, S=Oregon, C=US')
    Assert-Equal $false (Test-OsgeoSigner 'CN=The Open Source Geospatial Foundation, O=Evil Corp, C=US')
    Assert-Equal $false (Test-OsgeoSigner 'CN=x, O=The Open Source Geospatial Foundation Fake, C=US')
}

Test-Case 'action.yml description fits the Marketplace limit (< 125 chars, one line)' {
    $m = [regex]::Match((Get-Content -Raw (Join-Path $PSScriptRoot '..' 'action.yml')), '(?m)^description: ([^>|\s].*)$')  # not a >- / | block scalar
    if (-not $m.Success) { throw 'top-level description must be a single plain line' }
    if ($m.Groups[1].Value.Length -ge 125) { throw "description is $($m.Groups[1].Value.Length) chars" }
}

$pwshExe = (Get-Process -Id $PID).Path
Test-Case 'deadline helper returns the exit code' {
    Assert-Equal 3 (Invoke-WithDeadline -FilePath $pwshExe -Arguments '-NoProfile -Command exit 3' -Deadline ([datetime]::MaxValue))
}
Test-Case 'deadline helper kills an overrunning process' {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Assert-Throw { Invoke-WithDeadline -FilePath $pwshExe -Arguments '-NoProfile -Command Start-Sleep 60' -Deadline ([datetime]::UtcNow.AddSeconds(2)) } 'timed out'
    if ($sw.Elapsed.TotalSeconds -gt 20) { throw "took $($sw.Elapsed.TotalSeconds) s" }
}
Test-Case 'deadline already passed fails before starting' {
    Assert-Throw { Invoke-WithDeadline -FilePath $pwshExe -Arguments '-NoProfile -Command exit 0' -Deadline ([datetime]::UtcNow.AddSeconds(-1)) } 'timed out'
}

$tree = Join-Path ([IO.Path]::GetTempPath()) "sqo-$([guid]::NewGuid())"
try {
    foreach ($d in 'bin', 'apps/qgis-ltr', 'apps/Python312') { New-Item -ItemType Directory -Force (Join-Path $tree $d) | Out-Null }
    foreach ($f in 'bin/qgis_process-qgis-ltr.bat', 'apps/Python312/python.exe') { New-Item -ItemType File (Join-Path $tree $f) | Out-Null }
    Test-Case 'layout of an installed tree (LTR build)' {
        $l = Get-QgisLayout $tree
        Assert-Equal (Join-Path $tree 'apps' 'qgis-ltr') $l.Prefix
        Assert-Equal (Join-Path $tree 'bin' 'qgis_process-qgis-ltr.bat') $l.QgisProcess
        Assert-Equal (Join-Path $tree 'apps' 'Python312' 'python.exe') $l.Python
    }
    Test-Case 'layout rejects an ambiguous tree' {
        New-Item -ItemType File (Join-Path $tree 'bin/qgis_process-qgis.bat') | Out-Null
        Assert-Throw { Get-QgisLayout $tree } 'qgis_process'
    }
    Test-Case 'layout rejects an empty tree' { Assert-Throw { Get-QgisLayout (Join-Path $tree 'apps') } 'qgis_process' }
} finally { Remove-Item -Recurse -Force $tree }

if ($script:failures) { Write-Host "`n$script:failures failure(s)"; exit 1 }
Write-Host "`nall passed"
