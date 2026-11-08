#Requires -Version 5.1
$ErrorActionPreference='Stop'
$app=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $app 'lib\AddonUpdater.Core.psm1') -Force -DisableNameChecking
$temp=Join-Path $app ('.test-tmp-startup-'+[Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temp) | Out-Null
$passed=0;$failed=0
function Assert($Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Run-StartupCase([string]$Mode,[string]$SavedPath){
    Save-JsonFile (Join-Path $temp 'settings.local.json') @{addonsPath=$SavedPath}
    [IO.File]::WriteAllText((Join-Path $temp 'scenario.txt'),$Mode)
    [IO.File]::WriteAllText((Join-Path $temp 'events.txt'),'')
    $output=& powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $temp 'AddonUpdater.ps1') -SkipSelfUpdate -NoPause 2>&1
    if($LASTEXITCODE -ne 0){throw ($output -join [Environment]::NewLine)}
    return @(Get-Content -LiteralPath (Join-Path $temp 'events.txt'))
}
try{
    Copy-Item -LiteralPath (Join-Path $app 'AddonUpdater.ps1') -Destination $temp
    Copy-Item -LiteralPath (Join-Path $app 'config.json') -Destination $temp
    Copy-Item -LiteralPath (Join-Path $app 'lib') -Destination $temp -Recurse
    $clients=@()
    foreach($name in @('First','Second')){$game=Join-Path $temp ($name+'\_forever_');[IO.Directory]::CreateDirectory($game) | Out-Null;[IO.File]::WriteAllText((Join-Path $game 'Wow.exe'),'fixture');$clients+=Join-Path $game 'Interface\AddOns'}
    Save-JsonFile (Join-Path $temp 'clients.json') @{paths=$clients}
    @'
function Find-WowInstallations {
    Add-Content -LiteralPath (Join-Path $script:HomeFolder 'events.txt') -Value 'detect'
    return (Read-JsonFile (Join-Path $script:HomeFolder 'clients.json')).paths
}
function Get-AddonPlans {
    Add-Content -LiteralPath (Join-Path $script:HomeFolder 'events.txt') -Value ('check:'+$script:Root)
    return New-AddonPlan 'Example' @('Example')
}
Export-ModuleMember -Function *
'@ | Add-Content -LiteralPath (Join-Path $temp 'lib\AddonUpdater.Core.psm1')
    @'
$script:StartupLists=0
function Select-TerminalOption {
    $fixture=Split-Path $PSScriptRoot -Parent
    Add-Content -LiteralPath (Join-Path $fixture 'events.txt') -Value 'picker'
    if([IO.File]::ReadAllText((Join-Path $fixture 'scenario.txt')) -eq 'change'){return 1};return 0
}
function Select-AddonUpdates {
    $fixture=Split-Path $PSScriptRoot -Parent;$script:StartupLists++
    if([IO.File]::ReadAllText((Join-Path $fixture 'scenario.txt')) -eq 'change' -and $script:StartupLists -eq 1){return @{action='Client'}}
    return @{action='Exit'}
}
Export-ModuleMember -Function *
'@ | Add-Content -LiteralPath (Join-Path $temp 'lib\AddonUpdater.Terminal.psm1')
    foreach($case in @('saved','change','missing','first')){
        try{
            $saved=$clients[0];if($case -eq 'missing'){$saved=Join-Path $temp 'unavailable'};if($case -eq 'first'){$saved=''}
            $events=@(Run-StartupCase $case $saved)
            if($case -eq 'saved'){
                Assert ($events -notcontains 'picker' -and $events -notcontains 'detect') 'Saved client should bypass detection and selection.'
                Assert ($events -contains ('check:'+$clients[0])) 'Saved client was not checked.'
            }elseif($case -eq 'change'){
                Assert (@($events | Where-Object {$_ -eq 'picker'}).Count -eq 1) 'Change client should open the picker once.'
                Assert ($events -contains ('check:'+$clients[0]) -and $events -contains ('check:'+$clients[1])) 'Both clients should be checked in order.'
                Assert ((Read-JsonFile (Join-Path $temp 'settings.local.json')).addonsPath -eq $clients[1]) 'New selection was not saved.'
            }else{
                Assert ($events -contains 'picker') 'Missing client should open the picker.'
                Assert ($events -contains ('check:'+$clients[0])) 'Selected client was not checked.'
            }
            $passed++;Write-Host "PASS startup $case" -ForegroundColor Green
        }catch{$failed++;Write-Host "FAIL startup $case -- $($_.Exception.Message)" -ForegroundColor Red}
    }
}finally{Remove-WorkDirectory $temp $app}
Write-Host "$passed passed; $failed failed."
if($failed){exit 1}
