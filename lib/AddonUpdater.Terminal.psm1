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
    if([Console]::IsInputRedirected){throw 'An interactive console is required. Double-click UpdateAddons.cmd, or use -CheckOnly for noninteractive checks.'}
    return [Console]::ReadKey($true).Key.ToString()
}
function Show-TerminalHeading([string]$Subtitle,[switch]$NoClear){
    $separatorWidth=54
    try{$separatorWidth=[Math]::Max(1,[Math]::Min(54,$Host.UI.RawUI.WindowSize.Width-1))}catch{}
    if(-not $NoClear){Clear-Host};Write-Host 'Addon Updater' -ForegroundColor Yellow;Write-Host ('='*$separatorWidth) -ForegroundColor DarkYellow
    if($Subtitle){Write-Host $Subtitle -ForegroundColor Gray};Write-Host ''
}
function Select-TerminalOption([string]$Title,[string[]]$Options){
    $cursor=0
    while($true){Show-TerminalHeading $Title;for($i=0;$i -lt $Options.Count;$i++){$prefix=if($i -eq $cursor){'> '}else{'  '};Write-Host ($prefix+$Options[$i]) -ForegroundColor $(if($i -eq $cursor){'Yellow'}else{'Gray'})};Write-Host "`nUp/Down: move | Enter: choose | Q / Esc: exit" -ForegroundColor Cyan
        switch(Read-TerminalKey){'UpArrow'{$cursor=($cursor+$Options.Count-1)%$Options.Count};'DownArrow'{$cursor=($cursor+1)%$Options.Count};'Enter'{return $cursor};'Escape'{return -1};'Q'{return -1}}
    }
}
function Update-CheckboxState([string]$Key,[int]$Cursor,[bool[]]$Checked,[bool[]]$Enabled){
    $result=@{cursor=$Cursor;checked=@($Checked);action=''};$count=$Enabled.Count
    if(-not $count){switch($Key){'Escape'{$result.action='Exit'};'Q'{$result.action='Exit'};'C'{$result.action='Client'};'R'{$result.action='Recheck'}};return $result}
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
function Get-TerminalShortcutLayout([int]$Width){
    $groups=@(
        @(@{key='Enter';label='Update selected'},@{key='Space';label='Toggle'},@{key='A/N';label='All/none'}),
        @(@{key='Up/Down';label='Move'},@{key='Home/End';label='First/last'},@{key='S';label='Choose source'}),
        @(@{key='R';label='Check again'},@{key='C';label='Change game folder'},@{key='Q/Esc';label='Exit'})
    )
    $lines=New-Object 'System.Collections.Generic.List[object]'
    foreach($group in $groups){
        $line=@{segments=@();length=0}
        foreach($item in $group){
            $length=$item.key.Length+$item.label.Length+3
            if($line.segments.Count -and $line.length+3+$length -gt $Width){$lines.Add($line);$line=@{segments=@();length=0}}
            if($line.segments.Count){$line.length+=3};$line.segments+=@($item);$line.length+=$length
        }
        if($line.segments.Count){$lines.Add($line)}
    }
    return $lines.ToArray()
}
function Show-TerminalShortcuts([object[]]$Lines){
    foreach($line in $Lines){
        $first=$true
        foreach($item in $line.segments){
            if(-not $first){Write-Host '   ' -NoNewline};$first=$false
            Write-Host ('['+$item.key+']') -ForegroundColor Yellow -NoNewline
            Write-Host (' '+$item.label) -ForegroundColor White -NoNewline
        }
        Write-Host ''
    }
}
function Format-AddonProgress($Progress,[int]$Width){
    if($Progress.percent -lt 0 -or $Progress.activity -eq 'Installed'){
        return Format-TerminalCell $Progress.activity $Width
    }
    $percentage='{0,3}%' -f $Progress.percent
    $barWidth=[Math]::Min(12,$Width-$percentage.Length-3)
    $filled=[int][Math]::Floor($barWidth*$Progress.percent/100.0)
    $bar='['+('#'*$filled)+('-'*($barWidth-$filled))+'] '+$percentage
    if($Width-$bar.Length -gt 8){$bar+=' '+$Progress.activity}
    return Format-TerminalCell $bar $Width
}
function Show-AddonList([object[]]$Plans,[int]$Cursor,[bool[]]$Checked,[string]$Client,[switch]$NoClear,[hashtable]$ProgressRows,[switch]$InPlace){
    if($InPlace){
        try{
            $Host.UI.RawUI.CursorPosition=[Management.Automation.Host.Coordinates]::new(0,$Host.UI.RawUI.WindowPosition.Y)
            $NoClear=$true
        }catch{}
    }
    $height=30;$width=100;try{$height=$Host.UI.RawUI.WindowSize.Height;$width=$Host.UI.RawUI.WindowSize.Width-1}catch{}
    $width=[Math]::Max(39,$width)
    Show-TerminalHeading (Format-TerminalCell $Client $width) -NoClear:$NoClear
    $compact=$width -lt 70
    if($compact){
        $versionWidth=7
        $nameWidth=[Math]::Min(30,$width-30)
        $statusWidth=$width-$nameWidth-$versionWidth-8
    }else{
        $versionWidth=10
        $sizeWidth=9
        $nameWidth=[Math]::Min(36,$width-56)
        $statusWidth=$width-$nameWidth-2*$versionWidth-$sizeWidth-10
    }
    $header='      '+(Format-TerminalCell 'Addon' $nameWidth)+' '+(Format-TerminalCell 'Current' $versionWidth)
    if(-not $compact){$header+=' '+(Format-TerminalCell 'Available' $versionWidth)+' '+(Format-TerminalCell 'Download' $sizeWidth)}
    $header+=' '+(Format-TerminalCell 'Status' $statusWidth)
    Write-Host $header -ForegroundColor Cyan;Write-Host ('-'*[Math]::Min($width,$header.Length)) -ForegroundColor DarkGray
    $shortcuts=@(Get-TerminalShortcutLayout $width)
    $capacity=[Math]::Max(1,$height-12-$shortcuts.Count);$start=[Math]::Max(0,[Math]::Min($Cursor-[Math]::Floor($capacity/2),$Plans.Count-$capacity));$end=[Math]::Min($Plans.Count,$start+$capacity)
    for($i=$start;$i -lt $end;$i++){
        $p=$Plans[$i];$marker=if($i -eq $Cursor){'>'}else{' '};$box=if($Checked[$i]){'[x]'}elseif($p.update){'[ ]'}else{' - '}
        $row="$marker $box "+(Format-TerminalCell $p.name $nameWidth)+' '+(Format-TerminalCell $p.installed $versionWidth)
        if(-not $compact){
            $size=if($p.update -or $Checked[$i]){'{0:N1} MB' -f ($p.size/1MB)}else{'-'}
            $row+=' '+(Format-TerminalCell $p.latest $versionWidth)+' '+(Format-TerminalCell $size $sizeWidth)
        }
        $status=if($ProgressRows -and $ProgressRows.ContainsKey($p)){Format-AddonProgress $ProgressRows[$p] $statusWidth}else{Format-TerminalCell $p.status $statusWidth}
        $row+=' '+$status
        Write-Host $row -ForegroundColor $(if($i -eq $Cursor){'Yellow'}elseif($p.status -like 'CHECK FAILED*'){'Red'}else{'Gray'})
    }
    if(-not $Plans.Count){Write-Host 'No addons found in this client.'}
    Write-Host ''
    if($Plans.Count){
        $p=$Plans[$Cursor]
        $detail=$p.status
        if($ProgressRows -and $ProgressRows.ContainsKey($p)){$detail=$ProgressRows[$p].activity}
        Write-Host (Format-TerminalCell ("$($Cursor+1)/$($Plans.Count) | "+$p.name+' | '+$detail) $width) -ForegroundColor White
        Write-Host (Format-TerminalCell ('Source: '+$(if($p.source){$p.source}else{'Not selected'})+'  '+$p.origin) $width) -ForegroundColor Gray
    }
    $selected=@(for($i=0;$i -lt $Plans.Count;$i++){if($Checked[$i]){$Plans[$i]}});$bytes=0L;foreach($p in $selected){$bytes+=[long]$p.size}
    $summary="{0} selected -- {1:N1} MB" -f $selected.Count,($bytes/1MB)
    if($ProgressRows){
        $done=@($ProgressRows.Values | Where-Object {$_.activity -eq 'Installed'}).Count
        $summary="$done of $($selected.Count) updates installed"
    }
    Write-Host (Format-TerminalCell $summary $width) -ForegroundColor Cyan
    Write-Host ('-'*$width) -ForegroundColor Gray
    if($ProgressRows){
        $message='Installation in progress'
        if(@($ProgressRows.Values | Where-Object {$_.activity -eq 'Failed'}).Count){$message='Installation stopped'}
        elseif($done -eq $selected.Count){$message='Installation complete'}
        Write-Host (Format-TerminalCell $message $width) -ForegroundColor Cyan
        for($i=1;$i -lt $shortcuts.Count;$i++){Write-Host (' '*$width)}
    }else{Show-TerminalShortcuts $shortcuts}
}
function Select-AddonUpdates([object[]]$Plans,[string]$Client){
    $state=@{cursor=0;checked=@($Plans | ForEach-Object{[bool]$_.update});action=''};$enabled=@($Plans | ForEach-Object{[bool]$_.update})
    while($true){Show-AddonList $Plans $state.cursor $state.checked $Client;$state=Update-CheckboxState (Read-TerminalKey) $state.cursor $state.checked $enabled
        if($state.action){$indexes=@(for($i=0;$i -lt $Plans.Count;$i++){if($state.checked[$i]){$i}});return @{action=$state.action;indexes=$indexes;cursor=$state.cursor}}
    }
}
Export-ModuleMember -Function *
