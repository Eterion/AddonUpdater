# Addon discovery, download verification and installation for Windows PowerShell 5.1.
$ErrorActionPreference = 'Stop'
$script:HomeFolder = Split-Path $PSScriptRoot -Parent
$script:Interface = 16001
$script:PacksBase = 'https://packs.spoken.quest/'
$script:PublicKey = 'MCowBQYDK2VwAyEAtiV14d1ANsreuZtPlaGdosc1ZUyk9QlC7I4KpXjNrA4='
$script:SpokenFolders = @('Spoken','Spoken_Quests','Spoken_Places','Spoken_Readables','Spoken_Bosses','SpokenContributions')
$script:ApiCache = @{}
$script:HashState = @{}
$script:Sources = @{}
$script:Lock = $null
$script:Root = $null
$script:CheckOnly = $false
$script:ItemNumber = 0
$script:ItemCount = 0
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.Web.Extensions
$script:JsonReader=New-Object System.Web.Script.Serialization.JavaScriptSerializer
$script:JsonReader.MaxJsonLength=64MB
$script:JsonReader.RecursionLimit=100
if (-not ('AddonUpdater.ArchiveTools' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'ArchiveTools.cs') }

function ConvertFrom-UpdaterJson([string]$Text){return ,$script:JsonReader.DeserializeObject($Text)}
function Read-JsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @{} }
    return ,(ConvertFrom-UpdaterJson ([IO.File]::ReadAllText($Path)))
}
function Save-JsonFile([string]$Path,$Value) {
    [IO.Directory]::CreateDirectory((Split-Path $Path -Parent)) | Out-Null
    [IO.File]::WriteAllText($Path+'.tmp',($Value | ConvertTo-Json -Depth 60),[Text.UTF8Encoding]::new($false))
    if([IO.File]::Exists($Path)){[IO.File]::Replace($Path+'.tmp',$Path,[NullString]::Value)}else{[IO.File]::Move($Path+'.tmp',$Path)}
}
function Test-SafeRelative([string]$Path) {
    if(-not $Path){return $false}
    foreach($s in $Path.Split('/')){if(-not $s -or $s -eq '.' -or $s -eq '..' -or $s -match '[\x00-\x1f<>:"|?*\\]' -or $s -match '[. ]$' -or $s -match '^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)'){return $false}}
    return $true
}
function Assert-NoLinks([string]$Path,[switch]$Recursive) {
    if(-not (Test-Path -LiteralPath $Path)){return}
    $item=Get-Item -LiteralPath $Path -Force
    if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw "Linked paths are not supported: $Path"}
    if($Recursive -and $item.PSIsContainer){$null=Get-SafeFileIndex $Path}
}
function Get-SafeFileIndex([string]$Path){
    $files=@{};$pending=New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]';$pending.Push([IO.DirectoryInfo]::new($Path))
    while($pending.Count){
        $directory=$pending.Pop()
        if($directory.Attributes -band [IO.FileAttributes]::ReparsePoint){throw "Linked paths are not supported: $($directory.FullName)"}
        foreach($entry in $directory.EnumerateFileSystemInfos()){
            if($entry.Attributes -band [IO.FileAttributes]::ReparsePoint){throw "Linked paths are not supported: $($entry.FullName)"}
            if($entry -is [IO.DirectoryInfo]){$pending.Push($entry)}else{$files[$entry.FullName.ToLowerInvariant()]=$entry}
        }
    }
    return $files
}
function Remove-WorkDirectory([string]$Path,[string]$Boundary) {
    $full=[IO.Path]::GetFullPath($Path);$base=[IO.Path]::GetFullPath($Boundary).TrimEnd('\')+'\'
    if(-not $full.StartsWith($base,[StringComparison]::OrdinalIgnoreCase)){throw 'Refusing to remove a path outside the work directory.'}
    Assert-NoLinks $full -Recursive
    if(Test-Path -LiteralPath $full){Remove-Item -LiteralPath $full -Recurse -Force}
}
function Compare-AddonVersion([string]$Left,[string]$Right) {
    $lists=@()
    foreach($v in @($Left,$Right)){
        if($v.Trim() -notmatch '^v?(\d+(?:\.\d+){0,3})(?:[ -]?([a-z]))?$'){throw "Version needs manual review: $v"}
        $numbers=@($Matches[1].Split('.') | ForEach-Object{[long]$_});while($numbers.Count -lt 4){$numbers+=0}
        $suffix=0;if($Matches[2]){$suffix=[int][char]$Matches[2].ToLowerInvariant()-96};$lists+=,@($numbers+$suffix)
    }
    for($i=0;$i -lt 5;$i++){if($lists[0][$i] -lt $lists[1][$i]){return -1};if($lists[0][$i] -gt $lists[1][$i]){return 1}};return 0
}
function Get-TocMetadata([string]$Text) {
    $m=@{};foreach($line in $Text -split '\r?\n'){if($line -match '^##\s*([^:]+):\s*(.*)$'){$m[$Matches[1].Trim()]=$Matches[2].Trim()}};return $m
}
function Test-Compatible($Meta){return @(([string]$Meta.Interface) -split '[,\s]+') -contains [string]$script:Interface}
function Get-LocalMetadata([string]$Folder) {
    $dir=Join-Path $script:Root $Folder;if(-not(Test-Path -LiteralPath $dir -PathType Container)){return $null}
    $all=@(Get-ChildItem -LiteralPath $dir -Filter '*.toc' -File | ForEach-Object{Get-TocMetadata ([IO.File]::ReadAllText($_.FullName))})
    foreach($m in $all){if(Test-Compatible $m){return $m}};if($all.Count){return $all[0]};return $null
}
function Resolve-WowInstallation([string]$Path) {
    if(-not $Path.Trim()){throw 'Choose a WoW Forever folder.'}
    $selected=[IO.Path]::GetFullPath($Path.Trim().Trim('"'))
    foreach($game in @($selected,(Join-Path $selected '_forever_'),(Split-Path $selected -Parent),(Split-Path (Split-Path $selected -Parent) -Parent))){
        if(-not $game -or (Split-Path $game -Leaf) -ne '_forever_' -or -not(Test-Path -LiteralPath (Join-Path $game 'Wow.exe') -PathType Leaf)){continue}
        $ancestor=$game;while($ancestor){Assert-NoLinks $ancestor;$next=Split-Path $ancestor -Parent;if($next -eq $ancestor){break};$ancestor=$next}
        $ui=Join-Path $game 'Interface';$addons=Join-Path $ui 'AddOns';Assert-NoLinks $ui;Assert-NoLinks $addons;return $addons
    };throw 'Select World of Warcraft, _forever_, or _forever_\Interface\AddOns. A Forever client containing Wow.exe is required.'
}
function Find-WowInstallations([string[]]$Extra=@()) {
    $bases=@($Extra)+@($env:ProgramFiles,${env:ProgramFiles(x86)})
    foreach($d in @('C','D','E','F')){$bases+=@("${d}:\Games","${d}:\Program Files","${d}:\Program Files (x86)","${d}:\")}
    $seen=@{};foreach($base in $bases){if(-not $base){continue};foreach($candidate in @($base,([IO.Path]::Combine($base,'World of Warcraft')))){try{$p=Resolve-WowInstallation $candidate;$seen[$p]=$p}catch{}}};return @($seen.Values | Sort-Object)
}
function Get-RememberedWowInstallation([string]$Path){
    if(-not $Path){return $null};try{return Resolve-WowInstallation $Path}catch{return $null}
}
function Initialize-UpdateContext([string]$AddonsPath,[switch]$CheckOnly,[string]$StateDirectory) {
    $script:Root=Resolve-WowInstallation $AddonsPath;$script:CheckOnly=[bool]$CheckOnly
    if($StateDirectory){$script:Data=[IO.Path]::GetFullPath($StateDirectory)}elseif($CheckOnly){$script:Data=Join-Path $script:HomeFolder '.check-data'}else{$script:Data=Join-Path (Split-Path $script:Root -Parent) 'ForeverAddonUpdater-Data'}
    [IO.Directory]::CreateDirectory($script:Data) | Out-Null
    $script:LockPath=Join-Path $script:Data 'running.lock'
    try{$script:Lock=[IO.File]::Open($script:LockPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)}catch{throw "Another updater may be running. If it crashed, remove $script:LockPath after closing all updater sessions."}
    $script:StatePath=Join-Path $script:Data 'state.ps51.json';$script:HashState=@{}
    try{$loaded=Read-JsonFile $script:StatePath;if($loaded.files){$script:HashState=$loaded.files}}catch{}
    try{$script:Sources=Read-JsonFile (Join-Path $script:HomeFolder 'sources.local.json')}catch{$script:Sources=@{}}
    $script:ApiCache=@{};[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
}
function Close-UpdateContext {
    if($script:Lock){$script:Lock.Dispose();$script:Lock=$null;if(Test-Path -LiteralPath $script:LockPath){Remove-Item -LiteralPath $script:LockPath -Force}}
}
function Get-Hash([string]$Path){
    $stream=[IO.File]::OpenRead($Path);$hash=[Security.Cryptography.SHA256]::Create()
    try{return ([BitConverter]::ToString($hash.ComputeHash($stream))).Replace('-','').ToLowerInvariant()}finally{$hash.Dispose();$stream.Dispose()}
}
function Get-TextHash([string]$Text){$hash=[Security.Cryptography.SHA256]::Create();try{return ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','').ToLowerInvariant()}finally{$hash.Dispose()}}
function Test-FileMatch([string]$Path,$File,[System.Collections.IDictionary]$FileIndex) {
    if($null -ne $FileIndex){$s=$FileIndex[[IO.Path]::GetFullPath($Path).ToLowerInvariant()];if(-not $s){return $false}}
    else{if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $false};Assert-NoLinks $Path;$s=Get-Item -LiteralPath $Path}
    $key=$s.FullName.ToLowerInvariant();$cached=$script:HashState[$key]
    if($s.Length -ne [long]$File.size){return $false}
    if($cached -and $cached.size -eq $s.Length -and $cached.modified -eq $s.LastWriteTimeUtc.Ticks.ToString() -and $cached.created -eq $s.CreationTimeUtc.Ticks.ToString() -and $cached.hash -eq $File.sha256){return $true}
    $digest=Get-Hash $Path;$script:HashState[$key]=@{size=$s.Length;modified=$s.LastWriteTimeUtc.Ticks.ToString();created=$s.CreationTimeUtc.Ticks.ToString();hash=$digest};return $digest -eq $File.sha256
}
function Show-ItemProgress([string]$Activity,[long]$Current=-1,[long]$Total=-1,[string]$Unit='bytes') {
    $status=$Activity;$percent=-1
    if($Total -gt 0 -and $Current -ge 0){$percent=[Math]::Min(100,[int](100.0*$Current/$Total));if($Unit -eq 'files'){$status="${Current}/${Total} files"}else{$status=('{0:N1} / {1:N1} MB' -f ($Current/1MB),($Total/1MB))}}
    $parent=0;if($script:ItemCount -gt 0){$parent=1};Write-Progress -Id 2 -ParentId $parent -Activity $Activity -Status $status -PercentComplete $percent
}
function Get-HttpBytes([string]$Url,[long]$Limit=20MB) {
    if($Url -notmatch '^https://'){throw 'Only HTTPS sources are supported.'}
    $req=[Net.HttpWebRequest]::Create($Url);$req.UserAgent='AddonUpdater/0.2';$req.Timeout=60000;$req.ReadWriteTimeout=60000
    try{$response=$req.GetResponse()}catch [Net.WebException]{$r=$_.Exception.Response;if($r){throw "HTTP $([int]$r.StatusCode): $Url"};throw}
    $memory=[IO.MemoryStream]::new();$input=$response.GetResponseStream()
    try{$buffer=New-Object byte[] 65536;while(($n=$input.Read($buffer,0,$buffer.Length)) -gt 0){if($memory.Length+$n -gt $Limit){throw 'Response exceeded the allowed size.'};$memory.Write($buffer,0,$n)};return ,$memory.ToArray()}finally{$input.Dispose();$response.Dispose();$memory.Dispose()}
}
function Get-RemoteText([string]$Url){return [Text.Encoding]::UTF8.GetString((Get-HttpBytes $Url))}
function Get-RemoteJson([string]$Url){if(-not $script:ApiCache.ContainsKey($Url)){$script:ApiCache[$Url]=ConvertFrom-UpdaterJson (Get-RemoteText $Url)};return $script:ApiCache[$Url]}
function Save-RemoteFile([string]$Url,[string]$Path,[long]$Size=0,[string]$Digest,[string]$Activity='Downloading') {
    if($Url -notmatch '^https://'){throw 'Only HTTPS downloads are supported.'}
    [IO.Directory]::CreateDirectory((Split-Path $Path -Parent)) | Out-Null
    $req=[Net.HttpWebRequest]::Create($Url);$req.UserAgent='AddonUpdater/0.2';$req.Timeout=120000;$req.ReadWriteTimeout=120000
    $response=$req.GetResponse();$input=$response.GetResponseStream();$output=[IO.File]::Create($Path+'.part')
    $received=0L;$last=[DateTime]::MinValue;$limit=512MB;if($Size -gt 0){$limit=$Size}
    try{$buffer=New-Object byte[] 131072;while(($n=$input.Read($buffer,0,$buffer.Length)) -gt 0){$received+=$n;if($received -gt $limit){throw 'Download exceeds expected size.'};$output.Write($buffer,0,$n);if(([DateTime]::UtcNow-$last).TotalMilliseconds -gt 150){Show-ItemProgress $Activity $received $(if($Size -gt 0){$Size}else{$response.ContentLength});$last=[DateTime]::UtcNow}}}
    finally{$output.Dispose();$input.Dispose();$response.Dispose()}
    if($Size -gt 0 -and $received -ne $Size){throw 'Download length does not match the release.'}
    if($Digest -and (Get-Hash ($Path+'.part')) -ne $Digest){throw 'Download SHA-256 verification failed.'}
    if(Test-Path -LiteralPath $Path){Remove-Item -LiteralPath $Path -Force};[IO.File]::Move($Path+'.part',$Path)
}
function Initialize-SignatureVerifier {
    if('Org.BouncyCastle.Crypto.Signers.Ed25519Signer' -as [type]){return}
    $dll=Join-Path $PSScriptRoot 'BouncyCastle.Cryptography.dll'
    if((Get-Hash $dll) -ne '4f96977e9c67334742c683410b3a361258219f0d3084a5e0bc10fba96cf23a0d'){throw 'Bundled signature verifier checksum does not match.'}
    # Load verified bytes so a downloaded ZIP's Zone.Identifier does not block .NET loading.
    [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($dll)) | Out-Null
}
function Open-SignedEnvelope($Envelope,[string]$PublicKey=$script:PublicKey) {
    Initialize-SignatureVerifier
    if($Envelope.signed -isnot [string] -or $Envelope.sig -isnot [string]){throw 'Invalid signed audio envelope.'}
    $key=[Org.BouncyCastle.Security.PublicKeyFactory]::CreateKey([Convert]::FromBase64String($PublicKey))
    $verifier=New-Object Org.BouncyCastle.Crypto.Signers.Ed25519Signer;$verifier.Init($false,$key)
    $data=[Text.Encoding]::UTF8.GetBytes($Envelope.signed);$verifier.BlockUpdate($data,0,$data.Length)
    if(-not $verifier.VerifySignature([Convert]::FromBase64String($Envelope.sig))){throw 'Audio signature verification failed.'}
    return @{text=$Envelope.signed;value=(ConvertFrom-UpdaterJson $Envelope.signed)}
}
function Get-AudioBlob($File) {
    $p=Join-Path (Join-Path $script:Data 'blobs') $File.sha256
    if((Test-Path -LiteralPath $p -PathType Leaf) -and (Get-Item -LiteralPath $p).Length -eq [long]$File.size -and (Get-Hash $p) -eq $File.sha256){return $p}
    Save-RemoteFile ($script:PacksBase+'blobs/'+$File.sha256) $p ([long]$File.size) $File.sha256 'Fetching audio changes';return $p
}
function Test-AudioManifest($Envelope,[string]$Folder,$IndexEntry) {
    $m=$Envelope.value
    if((Get-TextHash $Envelope.text) -ne $IndexEntry.manifestSha256 -or $m.packId -ne $Folder -or $m.rev -ne $IndexEntry.rev -or -not($m.files -is [array])){throw 'Audio manifest does not match the signed index.'}
    $seen=@{};$total=0L
    foreach($f in $m.files){if(-not(Test-SafeRelative $f.path) -or $f.sha256 -notmatch '^[a-f0-9]{64}$' -or $f.size -lt 0 -or $f.size -gt 512MB -or $seen.ContainsKey($f.path)){throw 'Invalid or duplicate audio file.'};$seen[$f.path]=$true;$total+=[long]$f.size}
    if(-not $seen.ContainsKey($Folder+'.toc') -or @($m.files).Count -ne $IndexEntry.fileCount -or $total -ne $IndexEntry.totalSize -or $total -gt 12GB -or $m.requires.Spoken -ne $IndexEntry.requires.Spoken -or $m.requires.Spoken -notmatch '^>=\d+\.\d+\.\d+$'){throw 'Incomplete audio manifest or invalid dependency.'};return $m
}
function Expand-SafeArchive([string]$Zip,[string]$Destination) {
    $crcs=[AddonUpdater.ArchiveTools]::Crcs($Zip);$archive=[IO.Compression.ZipFile]::OpenRead($Zip)
    try{
        $seen=@{};$total=0L
        foreach($entry in $archive.Entries){$name=$entry.FullName.Replace('\','/').TrimEnd('/');if(-not(Test-SafeRelative $name) -or $seen.ContainsKey($name) -or $entry.Length -gt 512MB){throw "Unsafe or duplicate ZIP path: $name"};$seen[$name]=$true;$total+=$entry.Length;if($total -gt 2GB){throw 'Uncompressed release exceeds size limit.'}}
        $n=0;foreach($entry in $archive.Entries){$n++;if($entry.FullName.EndsWith('/') -or $entry.FullName.EndsWith('\')){continue};$dest=Join-Path $Destination ($entry.FullName.Replace('/',[IO.Path]::DirectorySeparatorChar));[IO.Directory]::CreateDirectory((Split-Path $dest -Parent)) | Out-Null
            $input=$entry.Open();$output=[IO.File]::Create($dest);try{$crc=[AddonUpdater.ArchiveTools]::Copy($input,$output)}finally{$input.Dispose();$output.Dispose()}
            if(-not $crcs.ContainsKey($entry.FullName) -or $crc -ne $crcs[$entry.FullName] -or (Get-Item -LiteralPath $dest).Length -ne $entry.Length){throw 'ZIP entry checksum/length mismatch.'}
            if($n % 25 -eq 0){Show-ItemProgress 'Unpacking and checking files' $n $archive.Entries.Count 'files'}
        }
    }finally{$archive.Dispose()}
}
function Assert-StagedAddons([string]$Stage,[string[]]$Folders,[string]$Version) {
    foreach($folder in $Folders){$dir=Join-Path $Stage $folder;$valid=$false;if(-not(Test-Path -LiteralPath $dir -PathType Container)){throw "Release is missing $folder."}
        foreach($toc in Get-ChildItem -LiteralPath $dir -Filter '*.toc' -File){$m=Get-TocMetadata ([IO.File]::ReadAllText($toc.FullName));if(Test-Compatible $m){if((Compare-AddonVersion $m.Version $Version) -eq 0){$valid=$true};foreach($dep in @(([string]$m.Dependencies+' '+[string]$m.RequiredDeps) -split '[,\s]+' | Where-Object{$_})){if(-not(Test-SafeRelative $dep) -or $dep.Contains('/')){throw 'Invalid dependency name.'};if(-not $dep.StartsWith('Blizzard_') -and $Folders -notcontains $dep -and -not(Test-Path -LiteralPath (Join-Path $script:Root $dep))){throw "$folder requires $dep. Install the dependency first."}}}}
        if(-not $valid){throw "$folder has an incompatible interface or unexpected version."}
    }
}
function Move-AddonFolders([string]$Addons,[string]$Stage,[string[]]$Folders,[string]$Backup,[scriptblock]$BeforeInstall) {
    [IO.Directory]::CreateDirectory($Backup) | Out-Null;$moved=New-Object 'System.Collections.Generic.List[string]';$installed=New-Object 'System.Collections.Generic.List[string]'
    Save-JsonFile (Join-Path $Backup 'restore.json') @{addonsPath=$Addons;folders=@($Folders);status='installing';created=[DateTime]::UtcNow.ToString('o')}
    try{foreach($folder in $Folders){if(-not(Test-SafeRelative $folder) -or $folder.Contains('/')){throw 'Invalid addon folder.'};$target=Join-Path $Addons $folder;Assert-NoLinks $target -Recursive
            if(Test-Path -LiteralPath $target){[IO.Directory]::Move($target,(Join-Path $Backup $folder));$moved.Add($folder)}
            if($BeforeInstall){& $BeforeInstall $folder}
            [IO.Directory]::Move((Join-Path $Stage $folder),$target);$installed.Add($folder)
        };Save-JsonFile (Join-Path $Backup 'restore.json') @{addonsPath=$Addons;folders=@($Folders);status='complete';created=[DateTime]::UtcNow.ToString('o')}
    }catch{for($i=$installed.Count-1;$i -ge 0;$i--){[IO.Directory]::Move((Join-Path $Addons $installed[$i]),(Join-Path $Stage $installed[$i]))};for($i=$moved.Count-1;$i -ge 0;$i--){[IO.Directory]::Move((Join-Path $Backup $moved[$i]),(Join-Path $Addons $moved[$i]))};throw}
}
$configPath=Join-Path $script:HomeFolder 'config.json'
if(Test-Path -LiteralPath $configPath){$configuration=Read-JsonFile $configPath;if(-not $configuration.interface -or [int]$configuration.interface -lt 1){throw 'config.json must contain a positive interface version.'};$script:Interface=[int]$configuration.interface}
. (Join-Path $PSScriptRoot 'AddonUpdater.Sources.ps1')
. (Join-Path $PSScriptRoot 'AddonUpdater.SelfUpdate.ps1')
Export-ModuleMember -Function *
