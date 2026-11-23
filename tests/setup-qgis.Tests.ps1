#Requires -Version 7.4
# Offline self-check of setup-qgis.ps1's pure parts: no network, no Pester (plain throws).
# Run: pwsh -NoProfile -File tests/setup-qgis.Tests.ps1
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
Test-Case 'cache key separates signature-checked trees from unchecked ones' {
    $checked = Get-CacheKey -Installer 'QGIS-OSGeo4W-4.4.0-1.msi' -Sha256 ('a' * 64) -InstallDir 'C:\QGIS' -ImageOS 'win25' -SignatureChecked $true
    $unchecked = Get-CacheKey -Installer 'QGIS-OSGeo4W-4.4.0-1.msi' -Sha256 ('a' * 64) -InstallDir 'C:\QGIS' -ImageOS 'win25' -SignatureChecked $false
    Assert-Equal $true ($checked -ne $unchecked)
}

# Real certificates, so the check sees the subject exactly as Get-AuthenticodeSignature hands it over.
# $Subject is DN text, or an X500DistinguishedName for what the text parsers disagree on.
function Get-TestCertificate($Subject) {
    $rsa = [Security.Cryptography.RSA]::Create(2048)
    $req = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
        $Subject, $rsa, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $req.CreateSelfSigned([datetimeoffset]::UtcNow.AddMinutes(-1), [datetimeoffset]::UtcNow.AddDays(1))
}
# DER-encoded DN from RDNs given as arrays of (oid, value) pairs. Windows parses "CN=x + O=y" as a
# multi-valued RDN, .NET on Linux as one CN value, so multi-valued RDNs are built here instead.
function ConvertTo-DistinguishedName([object[][]] $Rdns) {
    $w = [Formats.Asn1.AsnWriter]::new([Formats.Asn1.AsnEncodingRules]::DER)
    $null = $w.PushSequence()
    foreach ($rdn in $Rdns) {
        $null = $w.PushSetOf()
        foreach ($atv in $rdn) {
            $null = $w.PushSequence()
            $w.WriteObjectIdentifier($atv[0])
            $w.WriteCharacterString([Formats.Asn1.UniversalTagNumber]::UTF8String, $atv[1])
            $w.PopSequence()
        }
        $w.PopSetOf()
    }
    $w.PopSequence()
    [Security.Cryptography.X509Certificates.X500DistinguishedName]::new($w.Encode())
}
Test-Case 'signer check accepts both OSGeo certificate subject styles' {
    Assert-Equal $true (Test-OsgeoSigner (Get-TestCertificate 'CN=THE OPEN SOURCE GEOSPATIAL FOUNDATION, O=THE OPEN SOURCE GEOSPATIAL FOUNDATION, L=Beaverton, S=Oregon, C=US'))
    Assert-Equal $true (Test-OsgeoSigner (Get-TestCertificate 'CN=The Open Source Geospatial Foundation, OU=OSGeo Foundation, O=The Open Source Geospatial Foundation, L=Beaverton, S=Oregon, C=US'))
}
Test-Case 'signer check rejects other organizations, including look-alikes inside quoted fields' {
    foreach ($subject in 'CN=The Open Source Geospatial Foundation, O=Evil Corp, C=US',
        'CN=x, O=The Open Source Geospatial Foundation Fake, C=US',
        'C=US, O=Evil Corp, CN="Evil, O=The Open Source Geospatial Foundation"',
        'L="Beaverton, O=The Open Source Geospatial Foundation, x", O=Evil Corp',
        'CN=The Open Source Geospatial Foundation, C=US') {
        if (Test-OsgeoSigner (Get-TestCertificate $subject)) { throw "accepted '$subject'" }
    }
}
Test-Case 'signer check rejects a second O hidden in a multi-valued RDN' {
    $osgeo = [object[]] @('2.5.4.10', 'The Open Source Geospatial Foundation')
    $cn = [object[]] @('2.5.4.3', 'x')
    $evil = [object[]] @('2.5.4.10', 'Evil Corp')
    $dn = ConvertTo-DistinguishedName ([object[][]] @([object[]] @(, $osgeo), [object[]] @($cn, $evil)))
    Assert-Equal $true ([bool]($dn.EnumerateRelativeDistinguishedNames() | Where-Object HasMultipleElements))
    Assert-Equal $false (Test-OsgeoSigner (Get-TestCertificate $dn))
}

Test-Case 'install-dir rejects control characters, wildcards and cmd metacharacters' {
    # OSGeo4W's own .bat files expand the root unquoted (pushd %~dp0, path %OSGEO4W_ROOT%\...).
    foreach ($bad in "C:\a`nb", "C:\a`tb", 'C:\QGIS [ci]', 'C:\QGIS*', 'C:\QGIS?',
        'C:\a&calc', 'C:\a%PATH%b', 'C:\a" /x evil.msi "b', 'C:\a^b', 'C:\a!b', 'C:\a|b', 'C:\a<b', 'C:\a>b') {
        Assert-Throw { Resolve-InstallDir -Value $bad -Release '4.4.0' } 'not allowed'
    }
}
if ($IsWindows) {
    Test-Case 'install-dir keeps ordinary punctuation' {
        Assert-Equal 'C:\R(x) - QGIS_1.2' (Resolve-InstallDir -Value 'C:\R(x) - QGIS_1.2' -Release '4.4.0')
    }
}
if ($IsWindows) {
    Test-Case 'install-dir defaults to the MSI default and is normalized' {
        Assert-Equal 'C:\Program Files\QGIS 4.4.0' (Resolve-InstallDir -Value '' -Release '4.4.0' -ProgramFiles 'C:\Program Files')
        Assert-Equal 'C:\QGIS' (Resolve-InstallDir -Value 'C:\QGIS\' -Release '4.4.0')
        Assert-Equal 'C:\b' (Resolve-InstallDir -Value 'C:\a\..\b' -Release '4.4.0')
    }
    Test-Case 'install-dir rejects relative paths and drive or share roots' {
        foreach ($bad in 'QGIS', 'D:', 'D:QGIS', '\QGIS') { Assert-Throw { Resolve-InstallDir -Value $bad -Release '4.4.0' } 'absolute' }
        foreach ($bad in 'C:\', 'C:\.', '\\server\share', '\\server\share\') { Assert-Throw { Resolve-InstallDir -Value $bad -Release '4.4.0' } 'root' }
    }
}

# The Marketplace rejects a top-level description of 125+ chars. Without a YAML parser, insist on one
# plain line, so what the regex measures is the whole value.
function Assert-MarketplaceDescription([string] $Yaml) {
    # Not a block scalar (>- |), not a comment (null), and the next line starts a new key.
    $m = [regex]::Match($Yaml, '(?m)^description: ([^>|#\s].*?)\r?\n(?=\S)')
    if (-not $m.Success) { throw 'top-level description must be a single plain line' }
    if ($m.Groups[1].Value.Length -ge 125) { throw "description is $($m.Groups[1].Value.Length) chars" }
}
Test-Case 'action.yml description fits the Marketplace limit (< 125 chars, one line)' {
    Assert-MarketplaceDescription (Get-Content -Raw (Join-Path $PSScriptRoot '..' 'action.yml'))
}
Test-Case 'description check rejects folded continuations and empty values' {
    Assert-Throw { Assert-MarketplaceDescription "name: n`ndescription: $('x' * 100)`n  continued past the limit`nauthor: a`n" } 'single plain line'
    Assert-Throw { Assert-MarketplaceDescription "name: n`ndescription: # todo`nauthor: a`n" } 'single plain line'
    Assert-Throw { Assert-MarketplaceDescription "name: n`ndescription: >-`n  short`nauthor: a`n" } 'single plain line'
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

# '[ci]' in the path: the lookups must be literal, not wildcard patterns.
$tree = Join-Path ([IO.Path]::GetTempPath()) "sqo [ci] $([guid]::NewGuid())"
try {
    foreach ($d in 'bin', 'apps/qgis-ltr', 'apps/Python312') { $null = [IO.Directory]::CreateDirectory((Join-Path $tree $d)) }
    foreach ($f in 'bin/qgis_process-qgis-ltr.bat', 'apps/Python312/python.exe') { [IO.File]::WriteAllText((Join-Path $tree $f), '') }
    Test-Case 'layout of an installed tree (LTR build)' {
        $l = Get-QgisLayout $tree
        Assert-Equal (Join-Path $tree 'apps' 'qgis-ltr') $l.Prefix
        Assert-Equal (Join-Path $tree 'bin' 'qgis_process-qgis-ltr.bat') $l.QgisProcess
        Assert-Equal (Join-Path $tree 'apps' 'Python312' 'python.exe') $l.Python
    }
    Test-Case 'layout rejects an ambiguous tree' {
        [IO.File]::WriteAllText((Join-Path $tree 'bin/qgis_process-qgis.bat'), '')
        Assert-Throw { Get-QgisLayout $tree } 'qgis_process'
    }
    Test-Case 'layout rejects an empty tree' { Assert-Throw { Get-QgisLayout (Join-Path $tree 'apps') } 'qgis_process' }
} finally { Remove-Item -LiteralPath $tree -Recurse -Force }

if ($script:failures) { Write-Host "`n$script:failures failure(s)"; exit 1 }
Write-Host "`nall passed"
