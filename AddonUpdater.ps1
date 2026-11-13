#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$AddonsPath,
    [switch]$CheckOnly,
    [switch]$Demo,
    [switch]$NoPause,
    [switch]$RenderOnly,
    [switch]$SkipSelfUpdate,
    [string[]]$DemoKeys,
    [string]$StateDirectory
)
$ErrorActionPreference='Stop'
try {
    if($env:OS -ne 'Windows_NT'){throw 'This updater targets Windows PowerShell 5.1 on Windows.'}
    Import-Module (Join-Path $PSScriptRoot 'lib\AddonUpdater.Core.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'lib\AddonUpdater.Terminal.psm1') -Force -DisableNameChecking
    Initialize-TerminalAppearance
    try{$Host.UI.RawUI.WindowTitle='Addon Updater'}catch{}
    if($DemoKeys -and -not $Demo){throw 'Scripted menu keys are only accepted in Demo mode.'}
    if($RenderOnly -and -not $Demo){throw 'RenderOnly is only available in Demo mode.'}
    if($Demo){
        $plans=@()
        $p=New-AddonPlan 'Spoken + bundled modules' @('Spoken') 'spoken';$p.installed='3.8.2';$p.latest='3.8.3';$p.status='Update available';$p.update=$true;$p.size=72242597;$p.source='rusty-key/spoken-wow';$plans+=$p
        $p=New-AddonPlan 'Spoken audio' @('SpokenQuestsAudioShared') 'audio';$p.installed='2.5.0';$p.latest='2.5.0';$p.status='34 changed/missing files';$p.update=$true;$p.size=5040000;$p.source='packs.spoken.quest';$plans+=$p
        $p=New-AddonPlan 'Dialogue UI' @('DialogueUI') 'dialogue';$p.installed='1.0.7 b';$p.latest='1.0.7 b';$p.status='Up to date';$p.source='Peterodox/YUI-Dialogue';$plans+=$p
        if($RenderOnly){Show-AddonList $plans 0 @($true,$true,$false) 'DEMO -- no game files or network access' -NoClear;return}
        if($DemoKeys){Set-TerminalKeySequence $DemoKeys}
        $selection=Select-AddonUpdates $plans 'DEMO -- no game files or network access'
        if($selection.action -eq 'Update'){Write-Host "`nDemo selection: $($selection.indexes -join ', '). No downloads or installations were performed." -ForegroundColor Green}
        return
    }
    # Keep this lock for the whole interactive session, including any addon installs.
    if(-not $CheckOnly){
        Assert-NoLinks (Join-Path $PSScriptRoot '.updater.lock')
        try{$updaterLock=[IO.File]::Open((Join-Path $PSScriptRoot '.updater.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch{throw 'Another Addon Updater session is already open in this folder.'}
        if(-not $SkipSelfUpdate){
            $selfUpdate=Invoke-UpdaterSelfUpdate $PSScriptRoot
            if($selfUpdate -eq 'Exit'){return}
            if($selfUpdate -eq 'Restart'){
                $updaterLock.Dispose();$updaterLock=$null
                $restartArgs=@('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'AddonUpdater.ps1'),'-SkipSelfUpdate')
                if($AddonsPath){$restartArgs+=@('-AddonsPath',$AddonsPath)};if($NoPause){$restartArgs+='-NoPause'};if($StateDirectory){$restartArgs+=@('-StateDirectory',$StateDirectory)}
                & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" @restartArgs
                return
            }
        }
    }
    $settingsFile=Join-Path $PSScriptRoot 'settings.local.json';$settings=@{};try{$settings=Read-JsonFile $settingsFile}catch{}
    $candidate=$AddonsPath;if(-not $candidate){$candidate=$settings.addonsPath}
    if($CheckOnly -and -not $candidate){throw 'No saved client. Run interactively to choose a client, or pass -AddonsPath <folder>.'}
    $chooseClient=$false
    if(-not $CheckOnly){$remembered=Get-RememberedWowInstallation $candidate;if($remembered){$candidate=$remembered}else{$chooseClient=$true}}
    :Clients while($true){
        if(-not $CheckOnly -and $chooseClient){
            $clients=@(Find-WowInstallations @($candidate));$options=@($clients)+@('Enter a custom path')
            $choice=Select-TerminalOption 'Choose your WoW Forever installation' $options;if($choice -lt 0){return}
            if($choice -eq $clients.Count){$candidate=Read-Host 'Paste the World of Warcraft, _forever_, or AddOns folder';if(-not $candidate){continue}}else{$candidate=$clients[$choice]}
        }
        try{
            $resolved=Resolve-WowInstallation $candidate
            $chooseClient=$false
            if(-not $CheckOnly){Save-JsonFile $settingsFile @{addonsPath=$resolved}}
            Initialize-UpdateContext $resolved -CheckOnly:$CheckOnly -StateDirectory $StateDirectory
            :Addons while($true){
                Show-TerminalHeading "Checking $resolved"
                $plans=@(Get-AddonPlans);Write-Progress -Id 2 -Activity 'Checking addons' -Completed
                if($CheckOnly){foreach($p in $plans){Write-Output ("{0}: {1} -> {2} -- {3} [source: {4}]" -f $p.name,$p.installed,$p.latest,$p.status,$p.source)};return}
                :Menu while($true){
                    $selection=Select-AddonUpdates $plans $resolved
                    switch($selection.action){
                        'Exit'{return}
                        'Client'{$chooseClient=$true;continue Clients}
                        'Recheck'{continue Addons}
                        'Source'{
                            $p=$plans[$selection.cursor]
                            if(-not $p.choices.Count){Write-Host "`nNo GitHub repository found in this addon's metadata or top-level README." -ForegroundColor Yellow;[void](Read-Host 'Press Enter to return');continue Menu}
                            $source=Select-TerminalOption "Choose the repository for $($p.name)" @($p.choices);if($source -lt 0){continue Menu}
                            try{foreach($folder in $p.folders){Set-SourceChoice $folder $p.choices[$source]}}catch{Write-Host $_.Exception.Message -ForegroundColor Red;[void](Read-Host 'Press Enter to return');continue Menu};continue Addons
                        }
                        'Update'{
                            $selected=@($selection.indexes | ForEach-Object{$plans[$_]})
                            $checked=@(for($i=0;$i -lt $plans.Count;$i++){$selection.indexes -contains $i})
                            $progressRows=@{}
                            foreach($plan in $selected){$progressRows[$plan]=@{activity='Queued';percent=-1}}
                            $reportProgress={
                                param($plan,$activity,$percent)
                                $progressRows[$plan]=@{activity=$activity;percent=$percent}
                                $activeRow=[Array]::IndexOf($plans,$plan)
                                Show-AddonList $plans $activeRow $checked $resolved -ProgressRows $progressRows -InPlace
                            }.GetNewClosure()
                            try{
                                Install-SelectedPlans $selected $reportProgress
                            }catch{
                                Write-Host "`nUpdate stopped: $($_.Exception.Message)" -ForegroundColor Red
                                Write-Host 'Previously completed updates remain installed. Backups and any failed staging are retained.' -ForegroundColor DarkGray
                                if(-not $NoPause){[void](Read-Host 'Press Enter to return to the addon list')}
                            }
                            continue Menu
                        }
                    }
                }
            }
        }catch{
            if($CheckOnly){throw};Write-Host "`n$($_.Exception.Message)" -ForegroundColor Red;if($NoPause){throw};[void](Read-Host 'Press Enter to choose another client');$candidate=$null;$chooseClient=$true
        }finally{Close-UpdateContext;Write-Progress -Id 1 -Activity 'Total progress' -Completed;Write-Progress -Id 2 -Activity 'Addon operation' -Completed}
    }
}catch{
    $message=$_.Exception.ToString();Write-Host "`nERROR: $message" -ForegroundColor Red
    try{[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'last-error.txt'),([DateTime]::UtcNow.ToString('o')+"`r`n"+$message))}catch{}
    if(-not $NoPause -and -not [Console]::IsInputRedirected){[void](Read-Host 'Press Enter to close')};exit 1
}finally{if($updaterLock){$updaterLock.Dispose()}}
