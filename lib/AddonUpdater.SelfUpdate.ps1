# Self-update support. Dot-sourced into the core module; only official packaged releases are accepted.
$script:UpdaterRepository='Eterion/AddonUpdater'
$script:UpdaterFiles=@('Addon Updater.cmd','AddonUpdater.ps1','config.json','version.json','README.md','THIRD_PARTY_NOTICES.md','release-files.json','lib')
function Test-DevelopmentCheckout([string]$Root){
    $parent=[IO.Path]::GetFullPath($Root)
    while($parent){if(Test-Path -LiteralPath (Join-Path $parent '.git')){return $true};$next=Split-Path $parent -Parent;if($next -eq $parent){break};$parent=$next};return $false
}
function Get-SelfUpdatePlan($Release,[string]$CurrentVersion){
    if($Release.draft -or $Release.prerelease -or $Release.tag_name -notmatch '^v(\d+\.\d+\.\d+)$'){return $null}
    $version=$Matches[1];if((Compare-AddonVersion $version $CurrentVersion) -le 0){return $null}
    $assets=@($Release.assets | Where-Object {$_.name -ceq 'AddonUpdater.zip' -and $_.state -eq 'uploaded'})
    if($assets.Count -ne 1){throw 'The latest release has no unique AddonUpdater.zip package.'}
    $asset=$assets[0];$expected='https://github.com/'+$script:UpdaterRepository+'/releases/download/'+$Release.tag_name+'/AddonUpdater.zip'
    if($asset.browser_download_url -cne $expected -or $asset.digest -notmatch '^sha256:([a-f0-9]{64})$' -or $asset.size -le 0 -or $asset.size -gt 32MB){throw 'The updater release URL, size or GitHub SHA-256 digest is invalid.'}
    return @{version=$version;url=$expected;size=[long]$asset.size;digest=$Matches[1]}
}
function Assert-UpdaterPackage([string]$Stage,[string]$Version){
    Assert-NoLinks $Stage -Recursive
    $manifest=Read-JsonFile (Join-Path $Stage 'release-files.json')
    if($manifest.version -ne $Version -or $manifest.files -isnot [array] -or -not $manifest.files.Count){throw 'Updater package manifest has an unexpected version or file list.'}
    $seen=@{'release-files.json'=$true}
    foreach($file in $manifest.files){
        $path=[string]$file.path;$top=($path -split '/')[0]
        if(-not(Test-SafeRelative $path) -or $seen.ContainsKey($path) -or $script:UpdaterFiles -cnotcontains $top -or ($top -ne 'lib' -and $path.Contains('/')) -or $file.sha256 -notmatch '^[a-f0-9]{64}$'){throw 'Updater package contains an invalid or duplicate file.'}
        $seen[$path]=$true;$full=Join-Path $Stage $path
        if(-not(Test-Path -LiteralPath $full -PathType Leaf) -or (Get-Hash $full) -ne $file.sha256){throw "Updater package checksum failed: $path"}
    }
    foreach($item in Get-ChildItem -LiteralPath $Stage -Recurse -File){$relative=$item.FullName.Substring($Stage.TrimEnd('\').Length+1).Replace('\','/');if(-not $seen.ContainsKey($relative)){throw 'Updater package contains an unlisted file.'}}
    foreach($name in $script:UpdaterFiles){if(-not(Test-Path -LiteralPath (Join-Path $Stage $name))){throw "Updater package is missing $name"}}
    foreach($name in @('AddonUpdater.Core.psm1','AddonUpdater.Terminal.psm1','AddonUpdater.SelfUpdate.ps1','AddonUpdater.Sources.ps1','ArchiveTools.cs','BouncyCastle.Cryptography.dll','BouncyCastle.LICENSE.txt')){
        if(-not $seen.ContainsKey('lib/'+$name)){throw "Updater package is missing lib/$name"}
    }
    if((Read-JsonFile (Join-Path $Stage 'version.json')).version -ne $Version){throw 'Updater package version.json does not match the release.'}
    foreach($item in Get-ChildItem -LiteralPath $Stage -Recurse -File | Where-Object {$_.Extension -in @('.ps1','.psm1')}){
        $tokens=$null;$errors=$null;[void][Management.Automation.Language.Parser]::ParseFile($item.FullName,[ref]$tokens,[ref]$errors);if($errors.Count){throw "Updater package has invalid PowerShell: $($item.Name)"}
    }
}
function Install-UpdaterPackage([string]$Root,[string]$Stage,[string]$Version,[scriptblock]$BeforeInstall){
    if(Test-DevelopmentCheckout $Root){throw 'Self-updating a Git checkout is disabled.'}
    $ancestor=[IO.Path]::GetFullPath($Root);while($ancestor){Assert-NoLinks $ancestor;$next=Split-Path $ancestor -Parent;if($next -eq $ancestor){break};$ancestor=$next}
    Assert-UpdaterPackage $Stage $Version
    Assert-NoLinks (Join-Path $Root '.self-update') -Recursive
    foreach($name in $script:UpdaterFiles){Assert-NoLinks (Join-Path $Root $name) -Recursive}
    $backup=Join-Path $Root ('.self-update/backups/'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfff')+'-'+[Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($backup) | Out-Null
    $moved=New-Object 'System.Collections.Generic.List[string]';$installed=New-Object 'System.Collections.Generic.List[string]'
    Save-JsonFile (Join-Path $backup 'restore.json') @{status='installing';version=$Version;items=$script:UpdaterFiles}
    try{
        foreach($name in $script:UpdaterFiles){
            $target=Join-Path $Root $name
            if(Test-Path -LiteralPath $target){Move-Item -LiteralPath $target -Destination (Join-Path $backup $name);$moved.Add($name)}
            if($BeforeInstall){& $BeforeInstall $name}
            Move-Item -LiteralPath (Join-Path $Stage $name) -Destination $target;$installed.Add($name)
        }
        Save-JsonFile (Join-Path $backup 'restore.json') @{status='complete';version=$Version;items=$script:UpdaterFiles}
    }catch{
        $failure=$_
        try{
            for($i=$installed.Count-1;$i -ge 0;$i--){Move-Item -LiteralPath (Join-Path $Root $installed[$i]) -Destination (Join-Path $Stage $installed[$i])}
            for($i=$moved.Count-1;$i -ge 0;$i--){Move-Item -LiteralPath (Join-Path $backup $moved[$i]) -Destination (Join-Path $Root $moved[$i])}
            Save-JsonFile (Join-Path $backup 'restore.json') @{status='rolled-back';version=$Version;items=$script:UpdaterFiles}
        }catch{
            $fatal=[InvalidOperationException]::new("Self-update rollback was interrupted. Close the updater and restore the files from $backup. Staging: $Stage",$_.Exception)
            $fatal.Data['SelfUpdateFatal']=$true;throw $fatal
        }
        throw $failure
    }
    return $backup
}
function Invoke-UpdaterSelfUpdate([string]$Root){
    if(Test-DevelopmentCheckout $Root){Write-Host 'Updater self-check disabled in Git checkouts.' -ForegroundColor DarkGray;return 'Continue'}
    try{
        Write-Host 'Checking for an Addon Updater release...' -ForegroundColor DarkGray
        $current=(Read-JsonFile (Join-Path $Root 'version.json')).version
        if($current -notmatch '^\d+\.\d+\.\d+$'){throw 'Local updater version is invalid.'}
        [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
        try{$release=ConvertTo-Map (ConvertFrom-Json -InputObject (Get-RemoteText ('https://api.github.com/repos/'+$script:UpdaterRepository+'/releases/latest')))}catch{if($_.Exception.Message -like 'HTTP 404:*'){return 'Continue'};throw}
        $plan=Get-SelfUpdatePlan $release $current;if(-not $plan){return 'Continue'}
        # Terminal commands are resolved from the imported terminal module.
        $choice=Select-TerminalOption ("Addon Updater $current -> $($plan.version)") @('Update Addon Updater and restart','Skip for now')
        if($choice -lt 0){return 'Exit'};if($choice -eq 1){return 'Continue'}
        $boundary=Join-Path $Root '.self-update';Assert-NoLinks $boundary -Recursive
        $work=Join-Path $boundary ([Guid]::NewGuid().ToString('N'));$stage=Join-Path $work 'stage';[IO.Directory]::CreateDirectory($stage) | Out-Null
        $completed=$false
        try{
            $zip=Join-Path $work 'AddonUpdater.zip';Save-RemoteFile $plan.url $zip $plan.size $plan.digest 'Downloading Addon Updater'
            Expand-SafeArchive $zip $stage;$backup=Install-UpdaterPackage $Root $stage $plan.version
            $completed=$true
            Write-Host "Addon Updater updated. Backup: $backup" -ForegroundColor Green
        }finally{Write-Progress -Id 2 -Activity 'Updating Addon Updater' -Completed;if($completed -and (Test-Path -LiteralPath $work)){Remove-WorkDirectory $work $boundary}}
        return 'Restart'
    }catch{if($_.Exception.Data['SelfUpdateFatal']){throw};Write-Host ('Updater self-check/update failed: '+$_.Exception.Message) -ForegroundColor Yellow;Write-Host 'Continuing with the current updater.' -ForegroundColor DarkGray;return 'Continue'}
}
