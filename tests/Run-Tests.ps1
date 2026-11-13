#Requires -Version 5.1
$ErrorActionPreference='Stop'
$app=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $app 'lib\AddonUpdater.Core.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $app 'lib\AddonUpdater.Terminal.psm1') -Force -DisableNameChecking
$core=Get-Module AddonUpdater.Core
$temp=Join-Path $app ('.test-tmp-'+[Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temp) | Out-Null
$script:Passed=0;$script:Failed=0
function Assert($Condition,[string]$Message='Assertion failed'){if(-not $Condition){throw $Message}}
function Equal($Actual,$Expected){if($Actual -ne $Expected){throw "Expected '$Expected', got '$Actual'."}}
function Throws([scriptblock]$Action){$failed=$false;try{& $Action | Out-Null}catch{$failed=$true};Assert $failed 'Expected an exception.'}
function Test([string]$Name,[scriptblock]$Action){try{& $Action;$script:Passed++;Write-Host "PASS $Name" -ForegroundColor Green}catch{$script:Failed++;Write-Host "FAIL $Name -- $($_.Exception.Message) at $($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor Red}}
function Write-File([string]$Path,[string]$Text){[IO.Directory]::CreateDirectory((Split-Path $Path -Parent)) | Out-Null;[IO.File]::WriteAllText($Path,$Text)}
try{
    Test 'terminal exit shortcuts and compact cells' {
        Equal (Update-CheckboxState 'Q' 0 @($true) @($true)).action 'Exit'
        Equal (Update-CheckboxState 'Q' 0 @() @()).action 'Exit'
        Equal (Update-CheckboxState 'End' 0 @($true,$false) @($true,$true)).cursor 1
        Equal (Update-CheckboxState 'Home' 1 @($true,$false) @($true,$true)).cursor 0
        Equal (Format-TerminalCell 'Long addon name' 8) 'Long ad~'
        Equal (Format-TerminalCell 'Addon' 8).Length 8
        Set-TerminalKeySequence @('Q');Equal (Select-TerminalOption 'Exit test' @('Example')) -1
    }
    Test 'shortcut rows fit narrow terminals and expose game folder selection' {
        foreach($width in @(40,60,80,120)){
            $lines=@(Get-TerminalShortcutLayout $width);foreach($line in $lines){Assert ($line.length -le $width)}
            $actions=@($lines | ForEach-Object {$_.segments});Equal @($actions | Where-Object {$_.key -eq 'C'}).Count 1
        }
        Equal (Update-CheckboxState 'C' 0 @($true) @($true)).action 'Client'
        Equal (Update-CheckboxState 'C' 0 @() @()).action 'Client'
        Equal (Update-CheckboxState 'R' 0 @() @()).action 'Recheck'
    }
    Test 'Windows PowerShell 5.1 runtime' {Equal $PSVersionTable.PSVersion.Major 5;Equal $PSVersionTable.PSVersion.Minor 1}
    Test 'path traversal, absolute paths and Windows device names are rejected' {
        foreach($bad in @('../evil','/absolute','C:/bad','foo\bar','foo/../bar','nul.txt','x:y','trailing.','a//b')){Assert (-not(Test-SafeRelative $bad)) $bad};Assert (Test-SafeRelative 'Data/Sounds.lua')
    }
    Test 'version ordering and unknown version rejection' {Equal (Compare-AddonVersion '1.2' 'v1.2.0') 0;Equal (Compare-AddonVersion '1.0.7 b' '1.0.7') 1;Equal (Compare-AddonVersion '3.8.2' '3.8.3') -1;Throws {Compare-AddonVersion '1.2.0-rc1' '1.1'}}
    $game=Join-Path $temp 'World of Warcraft';$forever=Join-Path $game '_forever_';$addons=Join-Path $forever 'Interface\AddOns';Write-File (Join-Path $forever 'Wow.exe') 'fixture only'
    Test 'client selection accepts main folder, Forever folder and AddOns path without creating it' {
        foreach($p in @($game,$forever,$addons)){Equal (Resolve-WowInstallation $p) $addons};Assert (-not(Test-Path -LiteralPath $addons));Equal @((Find-WowInstallations @($game,$forever)) | Where-Object{$_ -eq $addons}).Count 1
        Write-File (Join-Path $temp '_retail_\Wow.exe') 'fixture';Throws {Resolve-WowInstallation (Join-Path $temp '_retail_')}
    }
    Test 'remembered clients resolve directly and unavailable clients return to selection' {
        Equal (Get-RememberedWowInstallation $game) $addons
        Assert ($null -eq (Get-RememberedWowInstallation ''))
        Assert ($null -eq (Get-RememberedWowInstallation (Join-Path $temp 'missing')))
    }
    & $core {param($home)$script:HomeFolder=$home} (Join-Path $temp 'AppState')
    Initialize-UpdateContext $addons -CheckOnly -StateDirectory (Join-Path $temp 'State')
    Test 'check-only mode cannot install' {Throws {Install-AddonPlan @{}}}
    Test 'JSON settings preserve arrays and 64-bit timestamp strings' {$p=Join-Path $temp 'settings.json';Save-JsonFile $p @{list=@('one');modified='638981234567890123'};$m=Read-JsonFile $p;Equal $m.list.Count 1;Equal $m.modified '638981234567890123';Save-JsonFile $p @{changed=$true};Assert (Read-JsonFile $p).changed}
    Test 'JSON reader preserves nested arrays, empty lists and 64-bit values' {$list=ConvertFrom-UpdaterJson '[{"tag_name":"v1.2","assets":[{"name":"one.zip"}],"empty":[],"number":638981234567890123}]';Assert ($list -is [array]);Equal $list.Count 1;Equal $list[0].tag_name 'v1.2';Equal $list[0].assets[0].name 'one.zip';Equal $list[0].empty.Count 0;Equal $list[0].number 638981234567890123}
    Test 'indexed audio checks detect changed, missing and resized files' {
        $audio=Join-Path $temp 'Audio';$path=Join-Path $audio 'Data\voice.ogg';Write-File $path 'audio'
        $file=@{size=5;sha256=(Get-Hash $path)};$index=Get-SafeFileIndex $audio
        Assert (Test-FileMatch (Join-Path $audio 'Data/voice.ogg') $file $index)
        Assert (Test-FileMatch $path $file $index)
        Write-File $path 'other';[IO.File]::SetLastWriteTimeUtc($path,[DateTime]::UtcNow.AddSeconds(2))
        Assert (-not(Test-FileMatch $path $file (Get-SafeFileIndex $audio)))
        Write-File $path 'longer';Assert (-not(Test-FileMatch $path $file (Get-SafeFileIndex $audio)))
        Remove-Item -LiteralPath $path;Assert (-not(Test-FileMatch $path $file (Get-SafeFileIndex $audio)))
    }
    Test 'file hashing works when the Get-FileHash command is unavailable' {
        $path=Join-Path $temp 'hash-input';Write-File $path 'abc'
        & $core {
            param($fixture)
            function Get-FileHash {throw 'Hash cmdlet unavailable in this test'}
            if((Get-Hash $fixture) -ne 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'){throw 'Unexpected SHA-256 digest.'}
        } $path
    }
    Test 'directory indexing rejects junctions before following them' {
        $target=Join-Path $temp 'LinkTarget';$tree=Join-Path $temp 'LinkTree';[IO.Directory]::CreateDirectory($target) | Out-Null;[IO.Directory]::CreateDirectory($tree) | Out-Null
        $link=Join-Path $tree 'Linked';New-Item -ItemType Junction -Path $link -Target $target | Out-Null
        try{Throws {Get-SafeFileIndex $tree};Throws {Assert-NoLinks $tree -Recursive}}finally{[IO.Directory]::Delete($link)}
    }
    $example=Join-Path $addons 'Example';Write-File (Join-Path $example 'Example.toc') "## Interface: 16001`n## Version: 1.0`n## X-Website: https://github.com/author/example`n## X-Curse-Project-ID: 1234`n"
    Write-File (Join-Path $example 'README.md') 'Source https://github.com/author/example and https://github.com/other/docs'
    Write-File (Join-Path $example 'Libs\Other\README.md') 'https://github.com/library/ignored'
    Test 'explicit source metadata wins and nested library READMEs are ignored' {$d=Get-SourceDiscovery 'Example';Assert $d.automatic;Equal $d.repos.Count 1;Equal $d.repos[0] 'author/example';Equal $d.providers[0] 'CurseForge project 1234'}
    Test 'README sources need selection and choices are saved per installation' {
        Write-File (Join-Path $example 'Example.toc') "## Interface: 16001`n## Version: 1.0`n";$d=Get-SourceDiscovery 'Example';Assert (-not $d.automatic);Equal $d.repos.Count 2;Assert ($d.repos -notcontains 'library/ignored');Throws {Set-SourceChoice 'Example' 'attacker/not-discovered'};Set-SourceChoice 'Example' 'author/example'
        $saved=Read-JsonFile (Join-Path $temp 'AppState\sources.local.json');Equal $saved[$addons.ToLowerInvariant()].Example 'author/example'
    }
    Initialize-SignatureVerifier
    $private=[Org.BouncyCastle.Crypto.Parameters.Ed25519PrivateKeyParameters]::new((New-Object byte[] 32),0)
    $public=[Convert]::ToBase64String([Org.BouncyCastle.X509.SubjectPublicKeyInfoFactory]::CreateSubjectPublicKeyInfo($private.GeneratePublicKey()).GetEncoded())
    function Sign([string]$Text){$s=New-Object Org.BouncyCastle.Crypto.Signers.Ed25519Signer;$s.Init($true,$private);$bytes=[Text.Encoding]::UTF8.GetBytes($Text);$s.BlockUpdate($bytes,0,$bytes.Length);return @{signed=$Text;sig=[Convert]::ToBase64String($s.GenerateSignature())}}
    Test 'Ed25519 envelopes authenticate payloads and reject tampering' {$e=Sign '{"ok":true}';Assert (Open-SignedEnvelope $e $public).value.ok;$e.signed+=' ';Throws {Open-SignedEnvelope $e $public}}
    Test 'audio manifests verify digest, path, file count and total bytes' {
        $m=@{packId='SpokenPlacesAudio';rev='20261107T120000Z';requires=@{Spoken='>=3.0.0'};files=@(@{path='SpokenPlacesAudio.toc';sha256=('a'*64);size=12})};$text=$m | ConvertTo-Json -Depth 10 -Compress;$entry=@{rev=$m.rev;requires=$m.requires;fileCount=1;totalSize=12;manifestSha256=(Get-TextHash $text)};$env=@{text=$text;value=$m};Equal (Test-AudioManifest $env 'SpokenPlacesAudio' $entry).packId 'SpokenPlacesAudio';$entry.totalSize=0;Throws {Test-AudioManifest $env 'SpokenPlacesAudio' $entry}
    }
    $payload=Join-Path $temp 'Payload';Write-File (Join-Path $payload 'Example\Example.toc') "## Interface: 16001`n## Version: 1.2`n";Write-File (Join-Path $payload 'Example\new.lua') 'new'
    $zip=Join-Path $temp 'release.zip';[IO.Compression.ZipFile]::CreateFromDirectory($payload,$zip)
    Test 'ZIP extraction checks CRCs and staged TOC compatibility' {$out=Join-Path $temp 'Extracted';Expand-SafeArchive $zip $out;Assert-StagedAddons $out @('Example') '1.2';Throws {Assert-StagedAddons $out @('Example') '1.3'}}
    Test 'ZIP traversal is rejected before extraction' {
        $evil=Join-Path $temp 'evil.zip';$stream=[IO.File]::Create($evil);$archive=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create);$entry=$archive.CreateEntry('../escaped.lua');$writer=[IO.StreamWriter]::new($entry.Open());$writer.Write('evil');$writer.Dispose();$archive.Dispose();$stream.Dispose();Throws {Expand-SafeArchive $evil (Join-Path $temp 'Unsafe')};Assert (-not(Test-Path -LiteralPath (Join-Path $temp 'escaped.lua')))
    }
    Test 'ZIP central directory checksum tampering is detected' {
        $bytes=[IO.File]::ReadAllBytes($zip);for($i=0;$i -lt $bytes.Length-4;$i++){if($bytes[$i] -eq 0x50 -and $bytes[$i+1] -eq 0x4b -and $bytes[$i+2] -eq 1 -and $bytes[$i+3] -eq 2){$bytes[$i+16]=$bytes[$i+16] -bxor 1;break}};$bad=Join-Path $temp 'crc.zip';[IO.File]::WriteAllBytes($bad,$bytes);Throws {Expand-SafeArchive $bad (Join-Path $temp 'Corrupt')}
    }
    Test 'multi-folder installation rolls back every original on failure' {
        $target=Join-Path $temp 'Swap\AddOns';$stage=Join-Path $temp 'Swap\Stage';$backup=Join-Path $temp 'Swap\Backup'
        foreach($f in @('One','Two')){Write-File (Join-Path $target "$f\version") 'old';Write-File (Join-Path $stage "$f\version") 'new'}
        Throws {Move-AddonFolders $target $stage @('One','Two') $backup {param($folder)if($folder -eq 'Two'){throw 'simulated failure'}}};foreach($f in @('One','Two')){Equal ([IO.File]::ReadAllText((Join-Path $target "$f\version"))) 'old'}
        Move-AddonFolders $target $stage @('One','Two') (Join-Path $temp 'Swap\Success');Equal ([IO.File]::ReadAllText((Join-Path $target 'One\version'))) 'new';Assert (Test-Path -LiteralPath (Join-Path $temp 'Swap\Success\One\version'))
    }
    Test 'cleanup cannot remove its boundary or another directory' {Throws {Remove-WorkDirectory $temp $temp};Throws {Remove-WorkDirectory $app $temp}}
    Test 'keyboard checkboxes wrap, toggle enabled rows and preserve disabled rows' {
        $s=Update-CheckboxState 'UpArrow' 0 @($true,$false,$false) @($true,$true,$false);Equal $s.cursor 2;$s=Update-CheckboxState 'Spacebar' 2 $s.checked @($true,$true,$false);Assert (-not $s.checked[2]);$s=Update-CheckboxState 'A' 0 $s.checked @($true,$true,$false);Assert $s.checked[0];Assert $s.checked[1];Assert (-not $s.checked[2]);Equal (Update-CheckboxState 'Enter' 0 $s.checked @($true,$true,$false)).action 'Update';$s=Update-CheckboxState 'N' 0 $s.checked @($true,$true,$false);Equal (Update-CheckboxState 'Enter' 0 $s.checked @($true,$true,$false)).action '';Equal (Update-CheckboxState 'Escape' 0 $s.checked @($true,$true,$false)).action 'Exit'
    }
    # Provider fixtures replace networking inside this test-only module instance.
    & $core {
        $script:FixtureRelease=@{tag_name='v1.2';assets=@(@{name='Example-1.2.zip';size=123;digest=('sha256:'+('a'*64));browser_download_url='https://github.com/author/example/releases/download/v1.2/Example-1.2.zip'},@{name='release.json';browser_download_url='https://github.com/author/example/releases/download/v1.2/release.json'})}
        $script:FixtureIndex=@{releases=@(@{filename='Example-1.2.zip';version='1.2';metadata=@(@{interface=16001})})}
        function script:Get-RemoteJson([string]$Url){if($Url -like 'https://api.github.com/*'){return @($script:FixtureRelease)};return $script:FixtureIndex}
    }
    Test 'generic release checks select compatible packages and reject downgrades' {$p=Get-GithubPlan 'Example' 'author/example' 'TOC';Assert $p.update;Equal $p.latest '1.2';Equal $p.digest ('a'*64);Write-File (Join-Path $example 'Example.toc') "## Interface: 16001`n## Version: 2.0`n";Assert (-not(Get-GithubPlan 'Example' 'author/example' 'TOC').update);Write-File (Join-Path $example 'Example.toc') "## Interface: 16001`n## Version: 1.0`n"}
    Test 'retail-only and ambiguous packages do not produce update offers' {
        & $core {$script:FixtureIndex.releases[0].metadata[0].interface=120001};Assert (-not(Get-GithubPlan 'Example' 'author/example' 'TOC').update)
        & $core {$script:FixtureIndex.releases[0].metadata[0].interface=16001;$script:FixtureIndex.releases+=@($script:FixtureIndex.releases[0])};$p=Get-GithubPlan 'Example' 'author/example' 'TOC';Assert (-not $p.update);Assert ($p.status -match 'Multiple');& $core {$script:FixtureIndex.releases=@($script:FixtureIndex.releases[0])}
    }
    Test 'generic discovery produces an update plan using the saved source' {$plans=@(Get-AddonPlans);Equal $plans.Count 1;Equal $plans[0].source 'author/example';Assert $plans[0].update}
    Test 'full selected-update pipeline stages, installs and retains a recoverable backup' {
        & $core {param($onlyRoot,$fixtureZip)
            $script:AllowedTestRoot=$onlyRoot;$script:FixtureZip=$fixtureZip;$script:CheckOnly=$false
            function script:Assert-GameClosed {if($script:Root -ne $script:AllowedTestRoot){throw 'Test installation outside fixture refused.'}}
            function script:Save-RemoteFile([string]$Url,[string]$Path,[long]$Size,[string]$Digest,[string]$Activity){if($Url -ne 'https://fixture.invalid/release.zip'){throw 'Unexpected test download.'};Show-ItemProgress $Activity 1 2;[IO.File]::Copy($script:FixtureZip,$Path)}
        } $addons $zip
        $p=New-AddonPlan 'Example' @('Example') 'github';$p.latest='1.2';$p.installed='1.0';$p.url='https://fixture.invalid/release.zip';$p.update=$true
        $events=New-Object 'System.Collections.Generic.List[string]'
        $rendered=@{}
        $report={
            param($plan,$activity,$percent)
            if(-not [object]::ReferenceEquals($plan,$p)){throw 'Progress was reported for the wrong row.'}
            $events.Add("${activity}:${percent}")
            $rendered[$plan]=@{activity=$activity;percent=$percent}
            if($activity -eq 'Downloading release'){Show-AddonList @($p) 0 @($true) 'Fixture' -ProgressRows $rendered -NoClear}
        }.GetNewClosure()
        $hostOutput=@(Install-SelectedPlans @($p) $report 6>&1) -join "`n"
        Assert ($hostOutput -match '\[#+-+\]\s+50%')
        Assert ($events.Contains('Unpacking and checking files:0'))
        Equal $events[$events.Count-1] 'Installed:100'
        Equal (Get-LocalMetadata 'Example').Version '1.2';Assert (-not $p.update)
        $backup=@(Get-ChildItem -LiteralPath (Join-Path $forever 'Interface\ForeverAddonUpdater-Backups') -Directory);Equal $backup.Count 1;Equal (Read-JsonFile (Join-Path $backup[0].FullName 'restore.json')).status 'complete';Assert (Test-Path -LiteralPath (Join-Path $backup[0].FullName 'Example\README.md'))
    }
}finally{Close-UpdateContext;Remove-WorkDirectory $temp $app}
Write-Host "`n$script:Passed passed; $script:Failed failed."
if($script:Failed){exit 1}
