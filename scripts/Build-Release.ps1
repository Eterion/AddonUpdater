#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'lib\AddonUpdater.Core.psm1') -Force -DisableNameChecking
$version=(Read-JsonFile (Join-Path $root 'version.json')).version
if($version -notmatch '^\d+\.\d+\.\d+$'){throw 'version.json must contain a three-part numeric version.'}
$boundary=Join-Path $root '.release-build';Assert-NoLinks $boundary -Recursive
$work=Join-Path $boundary ([Guid]::NewGuid().ToString('N'));$stage=Join-Path $work 'package';[IO.Directory]::CreateDirectory($stage) | Out-Null
try{
    foreach($name in @('UpdateAddons.cmd','AddonUpdater.ps1','config.json','version.json','README.md','THIRD_PARTY_NOTICES.md','lib')){
        $source=Join-Path $root $name;Assert-NoLinks $source -Recursive;Copy-Item -LiteralPath $source -Destination (Join-Path $stage $name) -Recurse
    }
    $files=@(Get-ChildItem -LiteralPath $stage -Recurse -File | Sort-Object FullName | ForEach-Object {@{path=$_.FullName.Substring($stage.Length+1).Replace('\','/');sha256=(Get-Hash $_.FullName)}})
    Save-JsonFile (Join-Path $stage 'release-files.json') @{version=$version;files=$files}
    Assert-UpdaterPackage $stage $version
    $dist=Join-Path $root 'dist';Assert-NoLinks $dist -Recursive;[IO.Directory]::CreateDirectory($dist) | Out-Null
    $zip=Join-Path $dist 'AddonUpdater.zip';if(Test-Path -LiteralPath $zip){Remove-Item -LiteralPath $zip -Force}
    [IO.Compression.ZipFile]::CreateFromDirectory($stage,$zip,[IO.Compression.CompressionLevel]::Optimal,$false)
    Write-Host "Release v$version ready: $zip" -ForegroundColor Green
    Write-Host ('SHA-256: '+(Get-Hash $zip))
}finally{Remove-WorkDirectory $work $boundary}
