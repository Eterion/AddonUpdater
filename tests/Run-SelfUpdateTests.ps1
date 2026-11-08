#Requires -Version 5.1
$ErrorActionPreference='Stop'
$app=Split-Path $PSScriptRoot -Parent
& (Join-Path $app 'scripts\Build-Release.ps1')
Import-Module (Join-Path $app 'lib\AddonUpdater.Core.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $app 'lib\AddonUpdater.Terminal.psm1') -Force -DisableNameChecking
$core=Get-Module AddonUpdater.Core
$packageVersion=(Read-JsonFile (Join-Path $app 'version.json')).version
$temp=Join-Path ([IO.Path]::GetTempPath()) ('AddonUpdater-tests-'+[Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temp) | Out-Null
$script:Passed=0;$script:Failed=0
function Assert($Condition,[string]$Message='Assertion failed'){if(-not $Condition){throw $Message}}
function Equal($Actual,$Expected){if($Actual -ne $Expected){throw "Expected '$Expected', got '$Actual'."}}
function Throws([scriptblock]$Action){$failed=$false;try{& $Action | Out-Null}catch{$failed=$true};Assert $failed 'Expected an exception.'}
function Test([string]$Name,[scriptblock]$Action){try{& $Action;$script:Passed++;Write-Host "PASS $Name" -ForegroundColor Green}catch{$script:Failed++;Write-Host "FAIL $Name -- $($_.Exception.Message) at $($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor Red}}
function Fixture([string]$Name){$stage=Join-Path $temp $Name;Expand-SafeArchive (Join-Path $app 'dist\AddonUpdater.zip') $stage;return $stage}
try{
    $zip=Join-Path $app 'dist\AddonUpdater.zip'
    $release=@{tag_name=('v'+$packageVersion);draft=$false;prerelease=$false;assets=@(@{name='AddonUpdater.zip';state='uploaded';browser_download_url=('https://github.com/Eterion/AddonUpdater/releases/download/v'+$packageVersion+'/AddonUpdater.zip');size=(Get-Item $zip).Length;digest=('sha256:'+(Get-Hash $zip))})}
    Test 'official stable release selects a verified package and never downgrades' {
        $plan=Get-SelfUpdatePlan $release '0.9.0';Equal $plan.version $packageVersion;Equal $plan.digest (Get-Hash $zip)
        Assert ($null -eq (Get-SelfUpdatePlan $release $packageVersion));Assert ($null -eq (Get-SelfUpdatePlan $release '2.0.0'))
        $release.prerelease=$true;Assert ($null -eq (Get-SelfUpdatePlan $release '0.9.0'));$release.prerelease=$false
        $release.draft=$true;Assert ($null -eq (Get-SelfUpdatePlan $release '0.9.0'));$release.draft=$false
    }
    Test 'missing digests, unexpected hosts and duplicate release assets are rejected' {
        $asset=$release.assets[0];$digest=$asset.digest;$asset.digest='';Throws {Get-SelfUpdatePlan $release '0.9.0'};$asset.digest=$digest
        $url=$asset.browser_download_url;$asset.browser_download_url='https://evil.invalid/AddonUpdater.zip';Throws {Get-SelfUpdatePlan $release '0.9.0'};$asset.browser_download_url=$url
        $release.assets=@($asset,$asset);Throws {Get-SelfUpdatePlan $release '0.9.0'};$release.assets=@($asset)
    }
    Test 'release ZIP validates and contains no personal settings or development files' {
        $stage=Fixture 'valid';Assert-UpdaterPackage $stage $packageVersion
        foreach($name in @('settings.local.json','sources.local.json','.git','.check-data','tests','scripts')){Assert (-not(Test-Path -LiteralPath (Join-Path $stage $name)))}
    }
    Test 'tampering, extra files and wrong versions are rejected before replacement' {
        $stage=Fixture 'tampered';[IO.File]::AppendAllText((Join-Path $stage 'README.md'),'tampered');Throws {Assert-UpdaterPackage $stage $packageVersion}
        $stage=Fixture 'extra';[IO.File]::WriteAllText((Join-Path $stage 'settings.local.json'),'{}');Throws {Assert-UpdaterPackage $stage $packageVersion}
        Throws {Assert-UpdaterPackage (Join-Path $temp 'valid') '2.0.0'}
    }
    Test 'Git checkouts and nested folders cannot self-update' {
        $gitRoot=Join-Path $temp 'checkout';[IO.Directory]::CreateDirectory((Join-Path $gitRoot 'nested')) | Out-Null;[IO.File]::WriteAllText((Join-Path $gitRoot '.git'),'gitdir: fixture')
        Assert (Test-DevelopmentCheckout (Join-Path $gitRoot 'nested'));Throws {Install-UpdaterPackage $gitRoot (Join-Path $temp 'valid') $packageVersion}
    }
    Test 'a failed file replacement rolls back the complete updater' {
        $root=Fixture 'rollback-root';$stage=Fixture 'rollback-stage'
        [IO.File]::WriteAllText((Join-Path $root 'README.md'),'original README')
        Save-JsonFile (Join-Path $root 'version.json') @{version='0.9.0'}
        Throws {Install-UpdaterPackage $root $stage $packageVersion {param($name) if($name -eq 'lib'){throw 'Injected swap failure'}}}
        Equal ([IO.File]::ReadAllText((Join-Path $root 'README.md'))) 'original README';Equal (Read-JsonFile (Join-Path $root 'version.json')).version '0.9.0'
        Assert (Test-Path -LiteralPath (Join-Path $root 'lib\AddonUpdater.Core.psm1'))
        $backup=@(Get-ChildItem -LiteralPath (Join-Path $root '.self-update\backups') -Directory);Equal (Read-JsonFile (Join-Path $backup[0].FullName 'restore.json')).status 'rolled-back'
    }
    Test 'successful self-update preserves settings and cache and retains old files' {
        $root=Fixture 'install-root';$stage=Fixture 'install-stage'
        [IO.File]::WriteAllText((Join-Path $root 'README.md'),'old README');Save-JsonFile (Join-Path $root 'version.json') @{version='0.9.0'}
        foreach($name in @('settings.local.json','sources.local.json')){[IO.File]::WriteAllText((Join-Path $root $name),'personal data')}
        [IO.Directory]::CreateDirectory((Join-Path $root '.check-data')) | Out-Null;[IO.File]::WriteAllText((Join-Path $root '.check-data\cached'),'cached data')
        $backup=Install-UpdaterPackage $root $stage $packageVersion
        Equal (Read-JsonFile (Join-Path $root 'version.json')).version $packageVersion;Equal ([IO.File]::ReadAllText((Join-Path $backup 'README.md'))) 'old README'
        foreach($name in @('settings.local.json','sources.local.json')){Equal ([IO.File]::ReadAllText((Join-Path $root $name))) 'personal data'}
        Equal ([IO.File]::ReadAllText((Join-Path $root '.check-data\cached'))) 'cached data'
    }
    # Mock only the network and menu at the module boundary; use the real ZIP/extraction/replacement.
    & $core {param($fakeRelease,$fixtureZip)
        $script:FixtureRelease=$fakeRelease;$script:FixtureZip=$fixtureZip;$script:FixtureChoice=1;$script:FixtureOffline=$false
        function script:Get-RemoteText([string]$Url){if($script:FixtureOffline){throw 'HTTP 404: no release'};if($Url -ne 'https://api.github.com/repos/Eterion/AddonUpdater/releases/latest'){throw 'Unexpected URL'};return ($script:FixtureRelease | ConvertTo-Json -Depth 10)}
        function script:Save-RemoteFile([string]$Url,[string]$Path,[long]$Size,[string]$Digest,[string]$Activity){if((Get-Hash $script:FixtureZip) -ne $Digest -or (Get-Item $script:FixtureZip).Length -ne $Size){throw 'Incorrect digest or size passed to downloader'};[IO.File]::Copy($script:FixtureZip,$Path)}
        function script:Select-TerminalOption {return $script:FixtureChoice}
    } $release $zip
    Test 'startup Skip, Exit and no-release choices leave existing files intact' {
        $root=Fixture 'prompt-root';Save-JsonFile (Join-Path $root 'version.json') @{version='0.9.0'}
        Equal (Invoke-UpdaterSelfUpdate $root) 'Continue';Equal (Read-JsonFile (Join-Path $root 'version.json')).version '0.9.0'
        & $core {$script:FixtureChoice=-1};Equal (Invoke-UpdaterSelfUpdate $root) 'Exit'
        & $core {$script:FixtureOffline=$true};Equal (Invoke-UpdaterSelfUpdate $root) 'Continue';& $core {$script:FixtureOffline=$false}
    }
    Test 'startup update flow verifies, downloads, installs and requests restart' {
        $root=Fixture 'flow-root';Save-JsonFile (Join-Path $root 'version.json') @{version='0.9.0'};& $core {$script:FixtureChoice=0}
        Equal (Invoke-UpdaterSelfUpdate $root) 'Restart';Equal (Read-JsonFile (Join-Path $root 'version.json')).version $packageVersion
    }
}finally{Remove-WorkDirectory $temp ([IO.Path]::GetTempPath())}
Write-Host "`n$script:Passed passed; $script:Failed failed."
if($script:Failed){exit 1}
