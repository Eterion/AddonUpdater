# Dot-sourced by AddonUpdater.Core.psm1; providers share its one update context.
function Get-GithubRepo([string]$Value) {
    if($Value -match 'https://github\.com/([a-z\d_.-]+)/([a-z\d_.-]+)'){$owner=$Matches[1];$repo=($Matches[2] -replace '\.git$','').TrimEnd('.');if($repo -and @('orgs','users','topics','sponsors','settings') -notcontains $owner){return "$owner/$repo"}};return $null
}
function Get-SourceDiscovery([string]$Folder) {
    $dir=Join-Path $script:Root $Folder;$explicit=New-Object 'System.Collections.Generic.List[string]';$docs=New-Object 'System.Collections.Generic.List[string]';$providers=New-Object 'System.Collections.Generic.List[string]'
    $files=@(Get-ChildItem -LiteralPath $dir -File | Where-Object{-not($_.Attributes -band [IO.FileAttributes]::ReparsePoint)})
    foreach($toc in $files | Where-Object{$_.Extension -eq '.toc'}){
        $m=Get-TocMetadata ([IO.File]::ReadAllText($toc.FullName));if(-not(Test-Compatible $m)){continue}
        foreach($field in @('X-Website','Website','X-Source','Source','X-GitHub','X-GitHub-Repo')){
            foreach($url in [regex]::Matches([string]$m[$field],'https://github\.com/[a-z\d_.-]+/[a-z\d_.-]+','IgnoreCase')){$r=Get-GithubRepo $url.Value;if($r){$explicit.Add($r)}}
            if($field -like '*GitHub*' -and $m[$field] -match '^[a-z\d_.-]+/[a-z\d_.-]+$'){$explicit.Add($m[$field])}
        }
        if($m['X-Curse-Project-ID'] -match '^\d+$'){$providers.Add('CurseForge project '+$m['X-Curse-Project-ID'])}
        if($m['X-WoWI-ID'] -match '^\d+$'){$providers.Add('WoWInterface project '+$m['X-WoWI-ID'])}
        if($m['X-Wago-ID'] -match '^[a-z\d_-]+$'){$providers.Add('Wago project '+$m['X-Wago-ID'])}
    }
    foreach($file in $files | Where-Object{$_.Name -match '^readme(?:\.[a-z]+)?$' -and $_.Length -le 256KB}){foreach($url in [regex]::Matches([IO.File]::ReadAllText($file.FullName),'https://github\.com/[a-z\d_.-]+/[a-z\d_.-]+','IgnoreCase')){$r=Get-GithubRepo $url.Value;if($r){$docs.Add($r)}}}
    $repos=@($explicit | Select-Object -Unique);$origin='TOC metadata';if(-not $repos.Count){$repos=@($docs | Select-Object -Unique);$origin='README'}
    return @{repos=@($repos);automatic=(@($explicit | Select-Object -Unique).Count -eq 1);origin=$origin;providers=@($providers | Select-Object -Unique)}
}
function Set-SourceChoice([string]$Folder,[string]$Repo) {
    $d=Get-SourceDiscovery $Folder;if($d.repos -notcontains $Repo){throw 'Choose a repository found in the addon metadata or top-level README.'}
    $key=$script:Root.ToLowerInvariant();if(-not $script:Sources[$key]){$script:Sources[$key]=@{}};$script:Sources[$key][$Folder]=$Repo
    Save-JsonFile (Join-Path $script:HomeFolder 'sources.local.json') $script:Sources
}
function New-AddonPlan([string]$Name,[string[]]$Folders,[string]$Kind='unknown') {
    return @{name=$Name;folders=@($Folders);kind=$Kind;installed='';latest='';source='';origin='';choices=@();status='';update=$false;size=0L;url='';digest='';required='';manifest=$null;changed=@()}
}
function Get-VersionSortKey([string]$Version) {
    if($Version -notmatch '^v?(\d+(?:\.\d+){0,3})(?:[ -]?([a-z]))?$'){return ''};$parts=@($Matches[1].Split('.'));while($parts.Count -lt 4){$parts+='0'};$key=($parts | ForEach-Object{([long]$_).ToString('D12')}) -join '.';$rank=0;if($Matches[2]){$rank=[int][char]$Matches[2].ToLowerInvariant()-96};return $key+'.'+$rank.ToString('D2')
}
function Get-SpokenPlan {
    $folders=@($script:SpokenFolders | Where-Object{Get-LocalMetadata $_});if(-not $folders.Count){return $null}
    $releases=@();for($page=1;$page -le 5;$page++){$list=@(Get-RemoteJson "https://api.github.com/repos/rusty-key/spoken-wow/releases?per_page=100&page=$page");$releases+=$list;if($list.Count -lt 100){break}}
    $r=$releases | Where-Object{-not $_.draft -and -not $_.prerelease -and $_.tag_name -match '^spoken/v\d+\.\d+\.\d+$'} | Sort-Object @{Expression={Get-VersionSortKey ($_.tag_name -replace '^spoken/','')};Descending=$true} | Select-Object -First 1
    if(-not $r){throw 'No stable Spoken release found.'};$v=$r.tag_name -replace '^spoken/v','';$asset=$r.assets | Where-Object{$_.name -eq "Spoken-$v.zip"} | Select-Object -First 1
    if(-not $asset -or $asset.digest -notmatch '^sha256:[a-f0-9]{64}$'){throw 'Spoken release has no verified ZIP.'}
    $p=New-AddonPlan 'Spoken + bundled modules' $folders 'spoken';$p.latest=$v;$p.source='rusty-key/spoken-wow';$p.origin='Spoken package adapter';$p.url=$asset.browser_download_url;$p.digest=$asset.digest.Substring(7);$p.size=[long]$asset.size
    $versions=@($folders | ForEach-Object{(Get-LocalMetadata $_).Version});$p.installed=(@($versions | Select-Object -Unique) -join ', ');$newer=$false;$older=$false
    foreach($version in $versions){$cmp=Compare-AddonVersion $version $v;if($cmp -gt 0){$newer=$true};if($cmp -lt 0){$older=$true}}
    $p.update=$older -and -not $newer;$p.status=if($newer){'Installed version is newer; no downgrade'}elseif($p.update){'Update available'}else{'Up to date'};return $p
}
function Get-DialoguePlan {
    $local=Get-LocalMetadata 'DialogueUI';if(-not $local){return $null}
    $tags=@(Get-RemoteJson 'https://api.github.com/repos/Peterodox/YUI-Dialogue/tags?per_page=100') | Where-Object{$_.name -match '^v\d+\.\d+\.\d+(?:-[a-z])?$'} | Sort-Object @{Expression={Get-VersionSortKey $_.name};Descending=$true} | Select-Object -First 10
    foreach($tag in $tags){$encoded=[Uri]::EscapeDataString($tag.name);$m=Get-TocMetadata (Get-RemoteText "https://raw.githubusercontent.com/Peterodox/YUI-Dialogue/$encoded/DialogueUI.toc");if(-not(Test-Compatible $m)){continue}
        $p=New-AddonPlan 'Dialogue UI' @('DialogueUI') 'dialogue';$p.installed=$local.Version;$p.latest=$m.Version;$p.source='Peterodox/YUI-Dialogue';$p.origin='Versioned-tag adapter';$p.url=$tag.zipball_url;$cmp=Compare-AddonVersion $local.Version $p.latest;$p.update=$cmp -lt 0;$p.status=if($cmp -lt 0){'Update available'}elseif($cmp -gt 0){'Installed version is newer; no downgrade'}else{'Up to date'};return $p
    };throw 'No Forever-compatible Dialogue UI tag found.'
}
function Get-GithubPlan([string]$Folder,[string]$Repo,[string]$Origin) {
    $local=Get-LocalMetadata $Folder;$p=New-AddonPlan $Folder @($Folder) 'github';$p.installed=$local.Version;$p.source=$Repo;$p.origin=$Origin
    if(-not(Test-Compatible $local)){$p.status='Installed addon does not declare Forever compatibility';return $p}
    $releases=@(Get-RemoteJson "https://api.github.com/repos/$Repo/releases?per_page=30") | Where-Object{-not $_.draft -and -not $_.prerelease} | Select-Object -First 12
    foreach($r in $releases){$packages=@();$manifest=$r.assets | Where-Object{$_.name -match '^\.?release\.json$'} | Select-Object -First 1
        if($manifest){$index=Get-RemoteJson $manifest.browser_download_url;foreach($entry in $index.releases){if($entry.nolib -or -not @($entry.metadata | Where-Object{[int]$_.interface -eq $script:Interface}).Count){continue};$a=$r.assets | Where-Object{$_.name -eq $entry.filename -and $_.name -match '\.zip$' -and $_.name -notmatch 'nolib'} | Select-Object -First 1;if($a){$packages+=@{asset=$a;version=$entry.version}}}}
        else{$zips=@($r.assets | Where-Object{$_.name -match '\.zip$' -and $_.name -notmatch 'nolib'});if($zips.Count -ne 1){continue};$tag=[Uri]::EscapeDataString($r.tag_name)
            foreach($file in @("$Folder.toc","$Folder/$Folder.toc","${Folder}_Camelot.toc","$Folder/${Folder}_Camelot.toc")){
                try{$m=Get-TocMetadata (Get-RemoteText "https://raw.githubusercontent.com/$Repo/$tag/$file")}catch{if($_.Exception.Message -match 'HTTP 404\b'){continue};throw};if(-not(Test-Compatible $m)){continue}
                $v=$m.Version;if(-not $v -or $v.Contains('@')){if($r.tag_name -match '(?:^|[/_-])(v?\d+(?:\.\d+){1,3}(?:[ -]?[a-z])?)$'){$v=$Matches[1]}else{$v=$null}};if($v){$packages+=@{asset=$zips[0];version=$v}};break
            }
        }
        if($packages.Count -gt 1){$p.status='Multiple Forever packages; manual review required';return $p};if(-not $packages.Count){continue}
        $a=$packages[0].asset;$url=[Uri]$a.browser_download_url;if($url.Scheme -ne 'https' -or $url.Host -ne 'github.com' -or -not $url.AbsolutePath.StartsWith("/$Repo/releases/download/",[StringComparison]::OrdinalIgnoreCase)){throw 'Unexpected release download address.'}
        $p.latest=$packages[0].version;$p.url=$a.browser_download_url;$p.size=[long]$a.size;if($a.digest -match '^sha256:[a-f0-9]{64}$'){$p.digest=$a.digest.Substring(7)};$cmp=Compare-AddonVersion $p.installed $p.latest;$p.update=$cmp -lt 0;$p.status=if($cmp -lt 0){'Update available'}elseif($cmp -gt 0){'Installed version is newer; no downgrade'}else{'Up to date'};return $p
    };$p.status='No verifiable Forever-compatible packaged release';return $p
}
function Get-VerifiedAudioManifest([string]$Folder,$Entry){
    $cachePath=Join-Path $script:Data "manifests/$($Entry.manifestSha256).json"
    try{
        $cached=Read-JsonFile $cachePath
        if($cached.signed){
            return Test-AudioManifest (Open-SignedEnvelope $cached) $Folder $Entry
        }
    }catch{
        Write-Verbose "Cached manifest for $Folder could not be verified. Fetching it again."
    }
    $raw=Get-RemoteJson ($script:PacksBase+"packs/$Folder/$($Entry.rev).json")
    $manifest=Test-AudioManifest (Open-SignedEnvelope $raw) $Folder $Entry
    Save-JsonFile $cachePath $raw
    return $manifest
}
function Get-AudioPlans([string[]]$Installed) {
    if(-not @($Installed | Where-Object{$_ -match '^Spoken.*Audio'}).Count){return @()}
    $raw=Get-RemoteJson ($script:PacksBase+'index.json');$index=(Open-SignedEnvelope $raw).value
    if(-not $index.generatedAt -or -not $index.packs){throw 'Invalid audio catalog.'};$date=[DateTime]::Parse($index.generatedAt)
    $saved=Join-Path $script:Data 'index.json';if(Test-Path -LiteralPath $saved){$previous=(Open-SignedEnvelope (Read-JsonFile $saved)).value;if($date -lt [DateTime]::Parse($previous.generatedAt)){throw 'Audio catalog is older than the last verified catalog.'}};Save-JsonFile $saved $raw
    $plans=New-Object 'System.Collections.Generic.List[object]'
    foreach($folder in $Installed | Where-Object{$index.packs.ContainsKey($_)}){
        $p=New-AddonPlan $folder @($folder) 'audio';$p.source='packs.spoken.quest';$p.origin='Signed audio catalog'
        try{
            if($folder -notmatch '^Spoken[A-Za-z]+(?:_[a-z]{2}[A-Z]{2})?$'){throw 'Invalid audio pack name.'}
            $packPath=Join-Path $script:Root $folder
            $entry=$index.packs[$folder];if($entry.rev -notmatch '^\d{8}T\d{6}Z$' -or $entry.manifestSha256 -notmatch '^[a-f0-9]{64}$'){throw 'Invalid audio catalog revision.'}
            Write-Host "Checking $folder..." -ForegroundColor Gray
            $m=Get-VerifiedAudioManifest $folder $entry
            $toc=$m.files | Where-Object{$_.path -eq "$folder.toc"} | Select-Object -First 1;$remote=Get-TocMetadata ([IO.File]::ReadAllText((Get-AudioBlob $toc)))
            if(-not(Test-Compatible $remote)){throw 'Audio pack does not support this Forever interface.'};$p.installed=(Get-LocalMetadata $folder).Version;$p.latest=$remote.Version;$p.manifest=$m;$p.required=$m.requires.Spoken.Substring(2)
            $changed=New-Object 'System.Collections.Generic.List[object]';$newer=(Compare-AddonVersion $p.installed $p.latest) -gt 0
            if(-not $newer){
                $fileIndex=Get-SafeFileIndex $packPath
                $fileCount=$m.files.Count
                $i=0
                foreach($f in $m.files){
                    $path=[IO.Path]::Combine($packPath,$f.path)
                    if(-not(Test-FileMatch $path $f $fileIndex)){
                        $changed.Add($f)
                        $p.size+=[long]$f.size
                    }
                    $i++
                    if($i % 500 -eq 0){Show-ItemProgress "Checking $folder" $i $fileCount 'files'}
                }
            }
            $p.changed=$changed.ToArray();$p.update=$changed.Count -gt 0;$p.status=if($newer){'Installed version is newer; no downgrade'}elseif($p.update){"$($changed.Count) changed/missing files"}else{'Up to date'}
        }catch{$p.update=$false;$p.status='CHECK FAILED: '+$_.Exception.Message};$plans.Add($p)
    };Write-Progress -Id 2 -Completed -Activity 'Audio check';return $plans.ToArray()
}
function Get-AddonPlans {
    $script:ApiCache=@{};$plans=New-Object 'System.Collections.Generic.List[object]';$installed=@()
    if(Test-Path -LiteralPath $script:Root){$installed=@(Get-ChildItem -LiteralPath $script:Root -Directory | Where-Object{-not($_.Attributes -band [IO.FileAttributes]::ReparsePoint)} | Select-Object -ExpandProperty Name)}
    foreach($adapter in @('Spoken','Dialogue')){try{$p=if($adapter -eq 'Spoken'){Get-SpokenPlan}else{Get-DialoguePlan};if($p){$plans.Add($p)}}catch{$p=New-AddonPlan $adapter @() 'error';$p.status='CHECK FAILED: '+$_.Exception.Message;$plans.Add($p)}}
    try{foreach($p in @(Get-AudioPlans $installed)){$plans.Add($p)}}catch{$p=New-AddonPlan 'Spoken audio catalog' @() 'error';$p.status='CHECK FAILED: '+$_.Exception.Message;$plans.Add($p)}
    $known=@{};foreach($folder in $script:SpokenFolders){$known[$folder]=$true};foreach($p in $plans){foreach($f in $p.folders){$known[$f]=$true}}
    foreach($folder in $installed | Where-Object{-not $known.ContainsKey($_)}){
        $p=New-AddonPlan $folder @($folder)
        try{$d=Get-SourceDiscovery $folder;$p.installed=(Get-LocalMetadata $folder).Version;$p.choices=@($d.repos);$repo=$null;$origin=$d.origin;$remembered=$null;if($script:Sources[$script:Root.ToLowerInvariant()]){$remembered=$script:Sources[$script:Root.ToLowerInvariant()][$folder]}
            if($remembered -and (Get-GithubRepo ('https://github.com/'+$remembered)) -eq $remembered){$repo=$remembered;$origin='Your saved choice'}elseif($d.automatic){$repo=$d.repos[0]}
            if($repo){$p=Get-GithubPlan $folder $repo $origin;$p.choices=@(@($repo)+$d.repos | Select-Object -Unique)}else{$p.origin=$d.origin;$p.source=$d.providers -join ', ';$p.status=if($d.repos.Count){'Choose repository (S) to check updates'}elseif($d.providers.Count){'Project identified; GitHub source needed'}else{'No update source found'}}
        }catch{$p.update=$false;$p.status='CHECK FAILED: '+$_.Exception.Message};$plans.Add($p)
    }
    $result=New-Object 'System.Collections.Generic.List[object]';$grouped=@{}
    foreach($p in $plans){if($p.kind -eq 'github' -and $p.url){$key=$p.source+'|'+$p.url;if($grouped.ContainsKey($key)){$g=$grouped[$key];$g.folders+=@($p.folders);$g.name=$g.folders -join ' + ';$g.installed+=', '+$p.installed;$g.update=$g.update -or $p.update;$g.choices=@($g.choices | Where-Object{$p.choices -contains $_});continue};$grouped[$key]=$p};$result.Add($p)}
    foreach($p in $result | Where-Object{$_.kind -eq 'github' -and $_.folders.Count -gt 1}){foreach($folder in $p.folders){if((Compare-AddonVersion (Get-LocalMetadata $folder).Version $p.latest) -gt 0){$p.update=$false;$p.status='A bundled folder is newer; no downgrade';break}};if($p.update){$p.status='Update available; bundled folders update together'}}
    Save-HashState
    return $result.ToArray()
}
function Assert-GameClosed { if(Get-Process -Name Wow,WowClassic,WowT,WowB -ErrorAction SilentlyContinue){throw 'Close World of Warcraft before installing updates.'} }
function Install-AddonPlan($Plan) {
    if($script:CheckOnly){throw 'Installation is disabled in check-only mode.'};Assert-GameClosed
    [IO.Directory]::CreateDirectory($script:Root) | Out-Null
    $workRoot=Join-Path $script:Data 'staging';$job=[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfff')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8);$work=Join-Path $workRoot $job;$stage=Join-Path $work 'ready';[IO.Directory]::CreateDirectory($stage) | Out-Null;$success=$false
    try{
        if($Plan.kind -eq 'audio'){
            $local=Get-LocalMetadata 'Spoken';if(-not $local -or (Compare-AddonVersion $local.Version $Plan.required) -lt 0){throw "Spoken >=$($Plan.required) must be installed first."};$folder=$Plan.folders[0];$n=0
            $fileCount=$Plan.manifest.files.Count
            Show-ItemProgress 'Preparing audio pack' 0 $fileCount 'files'
            foreach($f in $Plan.manifest.files){$old=Join-Path (Join-Path $script:Root $folder) $f.path;$source=if(Test-FileMatch $old $f){$old}else{Get-AudioBlob $f};$dest=Join-Path (Join-Path $stage $folder) $f.path;[IO.Directory]::CreateDirectory((Split-Path $dest -Parent)) | Out-Null;[IO.File]::Copy($source,$dest,$false);$n++;Show-ItemProgress 'Preparing audio pack' $n $fileCount 'files'}
        }else{
            $zip=Join-Path $work 'release.zip';Save-RemoteFile $Plan.url $zip ([long]$Plan.size) $Plan.digest 'Downloading release';$unpacked=Join-Path $work 'unpacked';Expand-SafeArchive $zip $unpacked
            if($Plan.kind -eq 'dialogue'){$dirs=@(Get-ChildItem -LiteralPath $unpacked -Directory);if($dirs.Count -ne 1){throw 'Unexpected tagged archive layout.'};[IO.Directory]::Move($dirs[0].FullName,(Join-Path $stage 'DialogueUI'))}
            else{
                $top=@(Get-ChildItem -LiteralPath $unpacked -Directory | Select-Object -ExpandProperty Name)
                if($Plan.kind -eq 'spoken'){$unknown=@($top | Where-Object{$script:SpokenFolders -notcontains $_});if($unknown.Count){throw 'Spoken release has new module folders; update the updater first.'}}
                else{$extra=@($top | Where-Object{(Test-Path -LiteralPath (Join-Path $script:Root $_)) -and $Plan.folders -notcontains $_});if($extra.Count){throw "Package also updates $($extra -join ', '). Configure the same source and check again to update the bundle together."}}
                foreach($folder in $Plan.folders){if(-not(Test-Path -LiteralPath (Join-Path $unpacked $folder) -PathType Container)){throw "Release is missing $folder; source archives cannot be installed automatically."};[IO.Directory]::Move((Join-Path $unpacked $folder),(Join-Path $stage $folder))}
            }
        }
        Show-ItemProgress 'Verifying staged files';Assert-StagedAddons $stage $Plan.folders $Plan.latest;Assert-GameClosed
        $backup=Join-Path (Join-Path (Split-Path $script:Root -Parent) 'ForeverAddonUpdater-Backups') $job
        Show-ItemProgress 'Backing up and installing';Move-AddonFolders $script:Root $stage $Plan.folders $backup
        $success=$true
        if(-not $script:InstallProgress){Write-Host "  Installed. Backup: $backup" -ForegroundColor DarkGray}
    }finally{
        if($success){Remove-WorkDirectory $work $workRoot}
        if(-not $script:InstallProgress){Write-Progress -Id 2 -Completed -Activity 'Addon operation'}
    }
}
function Install-SelectedPlans([object[]]$Plans,[scriptblock]$Progress){
    Assert-GameClosed
    $ordered=@($Plans | Sort-Object @{Expression={if($_.kind -eq 'spoken'){0}else{1}}})
    $script:InstallProgress=$Progress
    try{
        foreach($plan in $ordered){
            $script:ActiveInstallPlan=$plan
            $script:InstallPhase=''
            try{
                Show-ItemProgress 'Starting update'
                Install-AddonPlan $plan
            }catch{
                if($Progress){$null=& $Progress $plan 'Failed' -1}
                throw
            }
            $plan.update=$false
            $plan.installed=$plan.latest
            $plan.status='Updated successfully'
            if($Progress){$null=& $Progress $plan 'Installed' 100}
        }
        Save-HashState
    }finally{
        $script:InstallProgress=$null
        $script:ActiveInstallPlan=$null
    }
}
