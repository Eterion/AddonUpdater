$script:Keys=New-Object 'System.Collections.Generic.Queue[string]'
function Initialize-TerminalAppearance {
    try{$Host.UI.RawUI.BackgroundColor='Black';$Host.UI.RawUI.ForegroundColor='Gray'}catch{}
    foreach($property in @('ProgressBackgroundColor','ErrorBackgroundColor','WarningBackgroundColor','VerboseBackgroundColor','DebugBackgroundColor')){try{$Host.PrivateData.$property='Black'}catch{}}
    try{$Host.PrivateData.ProgressForegroundColor='Cyan'}catch{}
}
function Format-TerminalCell([string]$Text,[int]$Width){
    $Text=$Text -replace '[\r\n\t]',' '
    if($Text.Length -gt $Width){return $Text.Substring(0,$Width-1)+'~'}
    return $Text.PadRight($Width)
}
function Set-TerminalKeySequence([string[]]$Keys){$script:Keys.Clear();foreach($key in $Keys){$script:Keys.Enqueue($key)}}
function Read-TerminalKey {
    if($script:Keys.Count){return $script:Keys.Dequeue()}
    if([Console]::IsInputRedirected){throw 'An interactive console is required. Double-click Addon Updater.cmd, or use -CheckOnly for noninteractive checks.'}
    return [Console]::ReadKey($true).Key.ToString()
}
function Show-TerminalHeading([string]$Subtitle,[switch]$NoClear){
    if(-not $NoClear){Clear-Host};Write-Host 'Addon Updater' -ForegroundColor Yellow;Write-Host ('='*54) -ForegroundColor DarkYellow
    if($Subtitle){Write-Host $Subtitle -ForegroundColor Gray};Write-Host ''
}
function Select-TerminalOption([string]$Title,[string[]]$Options){
    $cursor=0
    while($true){Show-TerminalHeading $Title;for($i=0;$i -lt $Options.Count;$i++){$prefix=if($i -eq $cursor){'> '}else{'  '};Write-Host ($prefix+$Options[$i]) -ForegroundColor $(if($i -eq $cursor){'Yellow'}else{'Gray'})};Write-Host "`nUp/Down: move | Enter: choose | Q / Esc: exit" -ForegroundColor Cyan
        switch(Read-TerminalKey){'UpArrow'{$cursor=($cursor+$Options.Count-1)%$Options.Count};'DownArrow'{$cursor=($cursor+1)%$Options.Count};'Enter'{return $cursor};'Escape'{return -1};'Q'{return -1}}
    }
}
function Update-CheckboxState([string]$Key,[int]$Cursor,[bool[]]$Checked,[bool[]]$Enabled){
    $result=@{cursor=$Cursor;checked=@($Checked);action=''};$count=$Enabled.Count;if(-not $count){if($Key -in @('Escape','Q')){$result.action='Exit'};return $result}
    switch($Key){
        'UpArrow'{$result.cursor=($Cursor+$count-1)%$count}
        'DownArrow'{$result.cursor=($Cursor+1)%$count}
        'Home'{$result.cursor=0}
        'End'{$result.cursor=$count-1}
        'Spacebar'{if($Enabled[$Cursor]){$result.checked[$Cursor]=-not $result.checked[$Cursor]}}
        'A'{for($i=0;$i -lt $count;$i++){$result.checked[$i]=$Enabled[$i]}}
        'N'{for($i=0;$i -lt $count;$i++){$result.checked[$i]=$false}}
        'Enter'{if(@($result.checked | Where-Object{$_}).Count){$result.action='Update'}}
        'S'{$result.action='Source'}
        'R'{$result.action='Recheck'}
        'C'{$result.action='Client'}
        'Escape'{$result.action='Exit'}
        'Q'{$result.action='Exit'}
    };return $result
}
function Show-AddonList([object[]]$Plans,[int]$Cursor,[bool[]]$Checked,[string]$Client,[switch]$NoClear){
    Show-TerminalHeading $Client -NoClear:$NoClear
    $height=30;$width=100;try{$height=$Host.UI.RawUI.WindowSize.Height;$width=$Host.UI.RawUI.WindowSize.Width-1}catch{}
    $width=[Math]::Max(40,$width);$versionWidth=12;$sizeWidth=9;$nameWidth=[Math]::Max(10,[Math]::Min(36,$width-55));$statusWidth=$width-$nameWidth-2*$versionWidth-$sizeWidth-10
    $showStatus=$statusWidth -ge 12
    if(-not $showStatus){$versionWidth=8;$sizeWidth=7;$nameWidth=[Math]::Max(6,$width-2*$versionWidth-$sizeWidth-9)}
    $header='      '+(Format-TerminalCell 'Addon' $nameWidth)+' '+(Format-TerminalCell 'Installed' $versionWidth)+' '+(Format-TerminalCell 'Available' $versionWidth)+' '+(Format-TerminalCell 'Download' $sizeWidth)
    if($showStatus){$header+=' '+(Format-TerminalCell 'Status' $statusWidth)}
    Write-Host $header -ForegroundColor Cyan;Write-Host ('-'*[Math]::Min($width,$header.Length)) -ForegroundColor DarkGray
    $capacity=[Math]::Max(1,$height-15);$start=[Math]::Max(0,[Math]::Min($Cursor-[Math]::Floor($capacity/2),$Plans.Count-$capacity));$end=[Math]::Min($Plans.Count,$start+$capacity)
    for($i=$start;$i -lt $end;$i++){
        $p=$Plans[$i];$marker=if($i -eq $Cursor){'>'}else{' '};$box=if($p.update){if($Checked[$i]){'[x]'}else{'[ ]'}}else{' - '};$size=if($p.update){'{0:N1} MB' -f ($p.size/1MB)}else{'-'}
        $row="$marker $box "+(Format-TerminalCell $p.name $nameWidth)+' '+(Format-TerminalCell $p.installed $versionWidth)+' '+(Format-TerminalCell $p.latest $versionWidth)+' '+(Format-TerminalCell $size $sizeWidth)
        if($showStatus){$row+=' '+(Format-TerminalCell $p.status $statusWidth)}
        Write-Host $row -ForegroundColor $(if($i -eq $Cursor){'Yellow'}elseif($p.status -like 'CHECK FAILED*'){'Red'}else{'Gray'})
    }
    if(-not $Plans.Count){Write-Host 'No addons found in this client.'}
    Write-Host ''
    if($Plans.Count){$p=$Plans[$Cursor];Write-Host (Format-TerminalCell ("$($Cursor+1)/$($Plans.Count) | "+$p.name+' | '+$p.status) $width) -ForegroundColor Gray;Write-Host (Format-TerminalCell ('Source: '+$(if($p.source){$p.source}else{'Not selected'})+'  '+$p.origin) $width) -ForegroundColor DarkCyan}
    $selected=@(for($i=0;$i -lt $Plans.Count;$i++){if($Checked[$i]){$Plans[$i]}});$bytes=0L;foreach($p in $selected){$bytes+=[long]$p.size}
    Write-Host ("`n{0} selected -- {1:N1} MB" -f $selected.Count,($bytes/1MB)) -ForegroundColor Cyan
    Write-Host 'Up/Down: move | Space: toggle | A: all | N: none' -ForegroundColor DarkGray
    Write-Host 'Enter: update | S: source | R: refresh | C: client' -ForegroundColor DarkGray
    Write-Host 'Q / Esc: exit | Home / End: first / last addon' -ForegroundColor Cyan
}
function Select-AddonUpdates([object[]]$Plans,[string]$Client){
    if(-not $Plans.Count){return @{action='Exit';indexes=@();cursor=0}}
    $state=@{cursor=0;checked=@($Plans | ForEach-Object{[bool]$_.update});action=''};$enabled=@($Plans | ForEach-Object{[bool]$_.update})
    while($true){Show-AddonList $Plans $state.cursor $state.checked $Client;$state=Update-CheckboxState (Read-TerminalKey) $state.cursor $state.checked $enabled
        if($state.action){$indexes=@(for($i=0;$i -lt $Plans.Count;$i++){if($state.checked[$i]){$i}});return @{action=$state.action;indexes=$indexes;cursor=$state.cursor}}
    }
}
Export-ModuleMember -Function *
