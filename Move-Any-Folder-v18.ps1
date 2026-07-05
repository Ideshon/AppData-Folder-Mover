# Move-Any-Folder-v18.ps1
# GUI-программа для переноса выбранной локальной папки на другой диск и создания NTFS junction-ссылки.
# Запуск: powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File ".\Move-Any-Folder.ps1"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

# Кэш последней проверки занятости.
# Нужен, чтобы кнопка "Проверить" не заставляла повторно сканировать тысячи файлов
# при последующем нажатии "Перенести" / "Переезд базы".
$script:LastLockCheck = $null
$script:LastLockCheckHadErrors = $false
$script:LastLockCheckErrorText = ""

function Normalize-Path([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }

    $full = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path.Trim()))
    $root = [System.IO.Path]::GetPathRoot($full)

    if (-not [string]::IsNullOrWhiteSpace($root)) {
        if ($full.TrimEnd('\').ToLowerInvariant() -eq $root.TrimEnd('\').ToLowerInvariant()) {
            return $root
        }
    }

    return $full.TrimEnd('\')
}

function Test-PathInside([string]$Child, [string]$Parent) {
    $c = (Normalize-Path $Child).ToLowerInvariant()
    $p = (Normalize-Path $Parent).ToLowerInvariant()
    if ($c -eq $p) { return $true }
    return $c.StartsWith($p.TrimEnd('\') + '\')
}

function Get-UserAppDataRoot {
    return Normalize-Path (Join-Path $env:USERPROFILE "AppData")
}

function Get-UserDocumentsRoot {
    try {
        $docs = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)
        if (-not [string]::IsNullOrWhiteSpace($docs)) {
            return Normalize-Path $docs
        }
    } catch {}
    return Normalize-Path (Join-Path $env:USERPROFILE "Documents")
}

function Get-KnownRelativeRoots {
    $roots = New-Object System.Collections.Generic.List[object]

    $appDataRoot = Get-UserAppDataRoot
    if (Test-Path -LiteralPath $appDataRoot -PathType Container) {
        $roots.Add([PSCustomObject]@{ Name = "AppData"; Path = $appDataRoot }) | Out-Null
    }
    $docs = Get-UserDocumentsRoot
    if (Test-Path -LiteralPath $docs -PathType Container) {
        $roots.Add([PSCustomObject]@{ Name = "Документы"; Path = $docs }) | Out-Null
    }

    return @($roots | Sort-Object @{ Expression = { $_.Path.Length }; Descending = $true } -Unique)
}

function Get-RelativePathAfterKnownRoot([string]$SourceRaw) {
    $source = Normalize-Path $SourceRaw

    foreach ($rootInfo in @(Get-KnownRelativeRoots)) {
        $root = Normalize-Path $rootInfo.Path
        if (Test-PathInside $source $root) {
            $relative = ""
            if ($source.ToLowerInvariant() -ne $root.ToLowerInvariant()) {
                $relative = $source.Substring($root.Length).TrimStart('\')
            }
            return [PSCustomObject]@{
                RootName = $rootInfo.Name
                RootPath = $root
                Relative = $relative
            }
        }
    }

    $leaf = Split-Path -Leaf $source
    return [PSCustomObject]@{
        RootName = "обычная папка"
        RootPath = ""
        Relative = $leaf
    }
}

function Get-DefaultTargetRelativePath([string]$SourceRaw) {
    $source = Normalize-Path $SourceRaw
    if ([string]::IsNullOrWhiteSpace($source)) { return "" }

    $info = Get-RelativePathAfterKnownRoot $source
    if ($info -and -not [string]::IsNullOrWhiteSpace($info.Relative)) {
        return $info.Relative
    }

    $leaf = Split-Path -Leaf $source
    if (-not [string]::IsNullOrWhiteSpace($leaf)) { return $leaf }
    return "MovedFolder"
}

function Get-ForbiddenSourceRoots {
    $roots = @()

    $roots += (Get-UserAppDataRoot)
    if ($env:LOCALAPPDATA) { $roots += (Normalize-Path $env:LOCALAPPDATA) }
    if ($env:APPDATA) { $roots += (Normalize-Path $env:APPDATA) }
    $roots += (Normalize-Path (Join-Path $env:USERPROFILE "AppData\LocalLow"))
    $roots += (Get-UserDocumentsRoot)
    if ($env:USERPROFILE) { $roots += (Normalize-Path $env:USERPROFILE) }
    if ($env:SystemRoot) { $roots += (Normalize-Path $env:SystemRoot) }

    return @($roots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
}

function Get-AppDataRoots {
    $roots = @()
    $appDataRoot = Get-UserAppDataRoot
    if (Test-Path -LiteralPath $appDataRoot -PathType Container) { $roots += $appDataRoot }
    if ($env:APPDATA) { $roots += (Normalize-Path $env:APPDATA) }          # Roaming
    if ($env:LOCALAPPDATA) { $roots += (Normalize-Path $env:LOCALAPPDATA) } # Local
    $localLow = Join-Path $env:USERPROFILE "AppData\LocalLow"
    if (Test-Path -LiteralPath $localLow) { $roots += (Normalize-Path $localLow) }
    return $roots | Select-Object -Unique
}

function Get-RelativePathAfterAppData([string]$SourceRaw) {
    $source = Normalize-Path $SourceRaw
    $appDataRoot = Get-UserAppDataRoot

    if (!(Test-PathInside $source $appDataRoot)) {
        return $null
    }

    if ($source.ToLowerInvariant() -eq $appDataRoot.ToLowerInvariant()) {
        return ""
    }

    return $source.Substring($appDataRoot.Length).TrimStart('\')
}

function Join-BaseAndRelative([string]$BaseRaw, [string]$RelativeRaw) {
    $base = Normalize-Path $BaseRaw

    # В v8 здесь мог падать режим "Слить базы", если список найденных ссылок
    # возвращался как пустая коллекция, а Relative приходил как $null.
    # Для корня базы пустой relative — нормальный случай.
    $relative = ""
    if ($null -ne $RelativeRaw) {
        $relative = ([string]$RelativeRaw).TrimStart('\').TrimEnd('\')
    }

    if ([string]::IsNullOrWhiteSpace($relative)) {
        return $base
    }

    $result = $base
    foreach ($part in ($relative -split '\\')) {
        if (-not [string]::IsNullOrWhiteSpace($part)) {
            $result = Join-Path $result $part
        }
    }
    return Normalize-Path $result
}

function Build-DefaultTargetPath([string]$BaseRaw, [string]$SourceRaw) {
    $relative = Get-DefaultTargetRelativePath $SourceRaw
    if ([string]::IsNullOrWhiteSpace($relative)) {
        return Normalize-Path $BaseRaw
    }
    return Join-BaseAndRelative $BaseRaw $relative
}

function Is-ReparsePoint([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    return (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Test-DirectoryIsEmpty([string]$PathRaw) {
    $path = Normalize-Path $PathRaw
    if (!(Test-Path -LiteralPath $path -PathType Container)) { return $false }

    try {
        $enumerator = [System.IO.Directory]::EnumerateFileSystemEntries($path).GetEnumerator()
        try {
            return (-not $enumerator.MoveNext())
        } finally {
            if ($enumerator -and ($enumerator -is [System.IDisposable])) {
                $enumerator.Dispose()
            }
        }
    } catch {
        return $false
    }
}


function Format-Bytes([Int64]$Bytes) {
    if ($Bytes -lt 1024) { return "$Bytes B" }
    $units = @("KB", "MB", "GB", "TB")
    $value = [double]$Bytes
    foreach ($unit in $units) {
        $value = $value / 1024
        if ($value -lt 1024) {
            return ("{0:N2} {1}" -f $value, $unit)
        }
    }
    return ("{0:N2} PB" -f ($value / 1024))
}

function Get-ReparsePointTarget([string]$PathRaw) {
    try {
        $item = Get-Item -LiteralPath $PathRaw -Force -ErrorAction Stop
        if ($item.PSObject.Properties.Name -contains "Target" -and $item.Target) {
            return ($item.Target -join "; ")
        }
        if ($item.PSObject.Properties.Name -contains "LinkTarget" -and $item.LinkTarget) {
            return $item.LinkTarget
        }
    } catch {}
    return ""
}

function Get-ReparsePointDisplayLine($Item) {
    $path = ""
    $target = ""
    try { $path = $Item.FullName } catch { $path = [string]$Item }
    try { $target = Get-ReparsePointTarget $path } catch {}

    if ([string]::IsNullOrWhiteSpace($target)) {
        return $path
    }
    return "$path -> $target"
}

function Get-NestedReparsePointDirectories([string]$RootRaw, [int]$MaxResults = 50) {
    $root = Normalize-Path $RootRaw
    $result = @()

    if ([string]::IsNullOrWhiteSpace($root) -or !(Test-Path -LiteralPath $root -PathType Container)) {
        return @()
    }

    try {
        $result = Get-ChildItem -LiteralPath $root -Force -Directory -Recurse -ErrorAction SilentlyContinue |
            Where-Object { ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 } |
            Select-Object -First $MaxResults
    } catch {
        return @()
    }

    return @($result)
}

function Get-DirectorySizeBytes([string]$PathRaw) {
    $path = Normalize-Path $PathRaw
    [Int64]$total = 0
    $files = 0
    $skippedLinks = 0
    $errors = 0

    if ([string]::IsNullOrWhiteSpace($path) -or !(Test-Path -LiteralPath $path -PathType Container)) {
        return [PSCustomObject]@{ Bytes = 0; Files = 0; SkippedLinks = 0; Errors = 1 }
    }

    try {
        $rootItem = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            return [PSCustomObject]@{ Bytes = 0; Files = 0; SkippedLinks = 1; Errors = 0 }
        }
    } catch {
        return [PSCustomObject]@{ Bytes = 0; Files = 0; SkippedLinks = 0; Errors = 1 }
    }

    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($path)

    while ($stack.Count -gt 0) {
        $current = $stack.Pop()

        try {
            Get-ChildItem -LiteralPath $current -Force -File -ErrorAction Stop | ForEach-Object {
                try {
                    $total += [Int64]$_.Length
                    $files += 1
                } catch {
                    $errors += 1
                }
            }
        } catch {
            $errors += 1
        }

        try {
            Get-ChildItem -LiteralPath $current -Force -Directory -ErrorAction Stop | ForEach-Object {
                try {
                    if (($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                        $skippedLinks += 1
                    } else {
                        $stack.Push($_.FullName)
                    }
                } catch {
                    $errors += 1
                }
            }
        } catch {
            $errors += 1
        }
    }

    return [PSCustomObject]@{ Bytes = $total; Files = $files; SkippedLinks = $skippedLinks; Errors = $errors }
}

function Get-SubfolderSizeRows([string]$RootRaw, [scriptblock]$GuiLog = $null) {
    $root = Normalize-Path $RootRaw

    if ([string]::IsNullOrWhiteSpace($root) -or !(Test-Path -LiteralPath $root -PathType Container)) {
        throw "Папка для сортировки не найдена: $root"
    }

    if ($GuiLog) { & $GuiLog "Считаю размеры подпапок: $root" }
    Write-DetailLog "Считаю размеры подпапок: $root"

    $rows = New-Object System.Collections.Generic.List[object]
    $dirs = @(Get-ChildItem -LiteralPath $root -Force -Directory -ErrorAction Stop)
    $index = 0
    $totalDirs = $dirs.Count

    foreach ($dir in $dirs) {
        $index += 1
        if ($GuiLog) { & $GuiLog "[$index/$totalDirs] $($dir.Name)" }
        Write-DetailLog "Размер [$index/$totalDirs]: $($dir.FullName)"

        $isLink = (($dir.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
        $target = ""
        if ($isLink) { $target = Get-ReparsePointTarget $dir.FullName }

        $sizeInfo = Get-DirectorySizeBytes $dir.FullName
        $typeText = "папка"
        if ($isLink) { $typeText = "ссылка/junction" }
        elseif ($sizeInfo.SkippedLinks -gt 0) { $typeText = "папка, внутри есть ссылки: $($sizeInfo.SkippedLinks)" }

        $rows.Add([PSCustomObject]@{
            Name         = $dir.Name
            Path         = $dir.FullName
            Bytes        = [Int64]$sizeInfo.Bytes
            SizeText     = Format-Bytes ([Int64]$sizeInfo.Bytes)
            Files        = [int]$sizeInfo.Files
            SkippedLinks = [int]$sizeInfo.SkippedLinks
            Errors       = [int]$sizeInfo.Errors
            IsLink       = [bool]$isLink
            Target       = $target
            TypeText     = $typeText
        }) | Out-Null
    }

    return @($rows | Sort-Object Bytes -Descending)
}

function New-DetailedLogFile {
    $root = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($root)) {
        $root = Join-Path $env:TEMP "AppData-Folder-Mover"
    }

    $logDir = Join-Path $root "detailed_logs"
    if (!(Test-Path -LiteralPath $logDir -PathType Container)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    return Join-Path $logDir "move_$timestamp.log"
}

function Write-DetailLog([string]$Message, [string]$LogFile = $script:CurrentDetailedLog) {
    $line = "[" + (Get-Date -Format "HH:mm:ss") + "] " + $Message
    Write-Host $line
    if ($LogFile) {
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    }
}

function Ensure-RestartManagerLoaded {
    if (([System.Management.Automation.PSTypeName]'RestartManagerUtil').Type) {
        return
    }

    $restartManagerCode = @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Linq;
using System.Runtime.InteropServices;

public static class RestartManagerUtil
{
    private const int RmRebootReasonNone = 0;
    private const int ERROR_MORE_DATA = 234;

    [StructLayout(LayoutKind.Sequential)]
    private struct RM_UNIQUE_PROCESS
    {
        public int dwProcessId;
        public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime;
    }

    private enum RM_APP_TYPE
    {
        RmUnknownApp = 0,
        RmMainWindow = 1,
        RmOtherWindow = 2,
        RmService = 3,
        RmExplorer = 4,
        RmConsole = 5,
        RmCritical = 1000
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct RM_PROCESS_INFO
    {
        public RM_UNIQUE_PROCESS Process;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string strAppName;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]
        public string strServiceShortName;

        public RM_APP_TYPE ApplicationType;
        public uint AppStatus;
        public uint TSSessionId;
        [MarshalAs(UnmanagedType.Bool)]
        public bool bRestartable;
    }

    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    private static extern int RmStartSession(out uint pSessionHandle, int dwSessionFlags, string strSessionKey);

    [DllImport("rstrtmgr.dll")]
    private static extern int RmEndSession(uint pSessionHandle);

    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    private static extern int RmRegisterResources(
        uint pSessionHandle,
        uint nFiles,
        string[] rgsFilenames,
        uint nApplications,
        [In] RM_UNIQUE_PROCESS[] rgApplications,
        uint nServices,
        string[] rgsServiceNames);

    [DllImport("rstrtmgr.dll")]
    private static extern int RmGetList(
        uint dwSessionHandle,
        out uint pnProcInfoNeeded,
        ref uint pnProcInfo,
        [In, Out] RM_PROCESS_INFO[] rgAffectedApps,
        ref uint lpdwRebootReasons);

    public static Process[] GetLockingProcesses(string[] paths)
    {
        string[] cleanPaths = paths
            .Where(p => !String.IsNullOrWhiteSpace(p))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();

        if (cleanPaths.Length == 0)
        {
            return new Process[0];
        }

        uint handle;
        string key = Guid.NewGuid().ToString();
        int result = RmStartSession(out handle, 0, key);

        if (result != 0)
        {
            throw new Win32Exception(result);
        }

        try
        {
            result = RmRegisterResources(handle, (uint)cleanPaths.Length, cleanPaths, 0, null, 0, null);

            if (result != 0)
            {
                throw new Win32Exception(result);
            }

            uint pnProcInfoNeeded = 0;
            uint pnProcInfo = 0;
            uint lpdwRebootReasons = RmRebootReasonNone;

            result = RmGetList(handle, out pnProcInfoNeeded, ref pnProcInfo, null, ref lpdwRebootReasons);

            if (result == ERROR_MORE_DATA)
            {
                RM_PROCESS_INFO[] processInfo = new RM_PROCESS_INFO[pnProcInfoNeeded];
                pnProcInfo = pnProcInfoNeeded;

                result = RmGetList(handle, out pnProcInfoNeeded, ref pnProcInfo, processInfo, ref lpdwRebootReasons);

                if (result != 0)
                {
                    throw new Win32Exception(result);
                }

                List<Process> processes = new List<Process>();

                for (int i = 0; i < pnProcInfo; i++)
                {
                    try
                    {
                        processes.Add(Process.GetProcessById(processInfo[i].Process.dwProcessId));
                    }
                    catch (ArgumentException)
                    {
                        // Process already exited.
                    }
                }

                return processes
                    .GroupBy(p => p.Id)
                    .Select(g => g.First())
                    .ToArray();
            }

            if (result == 0)
            {
                return new Process[0];
            }

            throw new Win32Exception(result);
        }
        finally
        {
            RmEndSession(handle);
        }
    }
}
'@

    Add-Type -Language CSharp -TypeDefinition $restartManagerCode -ErrorAction Stop
}

function Get-LockCheckPaths([string]$RootRaw, [int]$MaxFiles = 1500) {
    $root = Normalize-Path $RootRaw
    $items = New-Object System.Collections.Generic.List[string]

    if ([string]::IsNullOrWhiteSpace($root) -or !(Test-Path -LiteralPath $root -PathType Container)) {
        return @()
    }

    $items.Add($root) | Out-Null

    $queue = New-Object System.Collections.Generic.Queue[string]
    $queue.Enqueue($root)
    $visited = New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
    [void]$visited.Add($root)

    while ($queue.Count -gt 0 -and $items.Count -lt $MaxFiles) {
        $dir = $queue.Dequeue()

        try {
            foreach ($file in [System.IO.Directory]::EnumerateFiles($dir)) {
                $items.Add($file) | Out-Null
                if ($items.Count -ge $MaxFiles) { break }
            }
        } catch {}

        if ($items.Count -ge $MaxFiles) { break }

        try {
            foreach ($subdir in [System.IO.Directory]::EnumerateDirectories($dir)) {
                try {
                    if ($visited.Contains($subdir)) { continue }
                    [void]$visited.Add($subdir)

                    $attr = [System.IO.File]::GetAttributes($subdir)
                    if (($attr -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                        continue
                    }

                    $queue.Enqueue($subdir)
                } catch {}
            }
        } catch {}

        if (($items.Count % 250) -eq 0) {
            Pump-GuiIfPossible
        }
    }

    return $items.ToArray()
}

function Split-ArrayIntoChunks([object[]]$Items, [int]$ChunkSize) {
    $chunks = @()
    if ($null -eq $Items -or $Items.Count -eq 0) { return $chunks }

    for ($i = 0; $i -lt $Items.Count; $i += $ChunkSize) {
        $end = [Math]::Min($i + $ChunkSize - 1, $Items.Count - 1)
        $chunks += ,($Items[$i..$end])
    }

    return $chunks
}

function Get-LockingProcessesForFolder([string]$FolderRaw, [scriptblock]$GuiLog = $null) {
    $folder = Normalize-Path $FolderRaw

    $script:LastLockCheckHadErrors = $false
    $script:LastLockCheckErrorText = ""

    if ($GuiLog) { & $GuiLog "Проверяю, какие приложения держат файлы в папке..." }
    Write-DetailLog "Проверка блокирующих процессов: $folder"

    try {
        Ensure-RestartManagerLoaded
    } catch {
        $script:LastLockCheckHadErrors = $true
        $script:LastLockCheckErrorText = $_.Exception.Message
        if ($GuiLog) { & $GuiLog "ПРЕДУПРЕЖДЕНИЕ: Restart Manager недоступен: $($_.Exception.Message)" }
        Write-DetailLog "Restart Manager load error: $($_.Exception.GetType().FullName): $($_.Exception.Message)"
        return @()
    }

    # Слишком глубокое сканирование больших папок делает GUI похожим на зависший.
    # Для проверки берём корень, первые прямые файлы и ограниченное число вложенных файлов.
    $paths = @(Get-LockCheckPaths $folder 1500)
    if ($GuiLog) { & $GuiLog "Проверено путей для занятости: $($paths.Count)" }
    Write-DetailLog "Проверено путей для занятости: $($paths.Count)"

    if ($paths.Count -eq 0) {
        return @()
    }

    $processMap = @{}
    $chunks = Split-ArrayIntoChunks $paths 256
    $errorCount = 0

    foreach ($chunk in $chunks) {
        try {
            Pump-GuiIfPossible
            $found = [RestartManagerUtil]::GetLockingProcesses([string[]]$chunk)
            foreach ($p in $found) {
                if ($p -and -not $processMap.ContainsKey($p.Id)) {
                    $processMap[$p.Id] = $p
                }
            }
        } catch {
            $errorCount++
            $msg = $_.Exception.Message
            $script:LastLockCheckHadErrors = $true
            $script:LastLockCheckErrorText = $msg
            Write-DetailLog "Restart Manager error: $msg"

            if ($errorCount -eq 1 -and $GuiLog) {
                & $GuiLog "ПРЕДУПРЕЖДЕНИЕ: Restart Manager не смог проверить часть файлов: $msg"
            }

            # Access denied обычно повторяется на каждом куске. Нет смысла гонять все чанки и создавать ощущение зависания.
            if ($msg -match 'Access is denied|Отказано в доступе|доступ.*запрещ') {
                if ($GuiLog) { & $GuiLog "Проверка занятости остановлена после отказа в доступе. Это не ошибка переноса; просто Windows не дала проверить часть файлов." }
                break
            }
        }
    }

    if ($errorCount -gt 1 -and $GuiLog) {
        & $GuiLog "ПРЕДУПРЕЖДЕНИЕ: ошибок Restart Manager при проверке: $errorCount. Подробности в detailed_logs."
    }

    return @($processMap.Values | Sort-Object ProcessName, Id)
}

function Get-ProcessDisplayLine($Process) {
    $name = ""
    $id = ""
    $title = ""
    $path = ""

    try { $name = $Process.ProcessName } catch { $name = "unknown" }
    try { $id = $Process.Id } catch { $id = "?" }
    try { $title = $Process.MainWindowTitle } catch { $title = "" }
    try { $path = $Process.MainModule.FileName } catch { $path = "" }

    $line = "$name | PID $id"
    if (-not [string]::IsNullOrWhiteSpace($title)) {
        $line += " | $title"
    }
    if (-not [string]::IsNullOrWhiteSpace($path)) {
        $line += " | $path"
    }

    return $line
}

function Format-LockingProcessesText($Processes, [int]$MaxLines = 12) {
    $lines = @()
    foreach ($p in @($Processes | Select-Object -First $MaxLines)) {
        $lines += (Get-ProcessDisplayLine $p)
    }

    if (@($Processes).Count -gt $MaxLines) {
        $lines += "...ещё $(@($Processes).Count - $MaxLines)"
    }

    return ($lines -join "`r`n")
}

function Log-LockingProcesses($Processes, [scriptblock]$GuiLog) {
    if ($null -eq $Processes -or @($Processes).Count -eq 0) {
        & $GuiLog "Блокирующих приложений не найдено."
        Write-DetailLog "Блокирующих приложений не найдено."
        return
    }

    & $GuiLog "Найдены приложения, которые могут мешать переносу:"
    Write-DetailLog "Найдены приложения, которые могут мешать переносу:"

    foreach ($p in @($Processes)) {
        $line = Get-ProcessDisplayLine $p
        & $GuiLog "  $line"
        Write-DetailLog "  $line"
    }
}


function Save-LockCheckCache([string]$FolderRaw, $Processes) {
    try {
        $script:LastLockCheck = [PSCustomObject]@{
            Source = (Normalize-Path $FolderRaw)
            Time = (Get-Date)
            Processes = @($Processes)
            HadErrors = [bool]$script:LastLockCheckHadErrors
            ErrorText = [string]$script:LastLockCheckErrorText
        }
    } catch {
        $script:LastLockCheck = $null
    }
}

function Get-ValidLockCheckCache([string]$FolderRaw, [int]$MaxAgeMinutes = 5) {
    try {
        if ($null -eq $script:LastLockCheck) { return $null }
        $source = Normalize-Path $FolderRaw
        if ($script:LastLockCheck.Source.ToLowerInvariant() -ne $source.ToLowerInvariant()) { return $null }
        if (((Get-Date) - $script:LastLockCheck.Time).TotalMinutes -gt $MaxAgeMinutes) { return $null }
        return $script:LastLockCheck
    } catch {
        return $null
    }
}

function Close-LockingProcessesGracefully($Processes, [scriptblock]$GuiLog) {
    foreach ($p in @($Processes)) {
        try {
            if ($p.HasExited) { continue }

            $line = Get-ProcessDisplayLine $p

            if ($p.MainWindowHandle -ne [IntPtr]::Zero) {
                & $GuiLog "Отправляю команду закрытия: $line"
                Write-DetailLog "Отправляю команду закрытия: $line"
                [void]$p.CloseMainWindow()
            } else {
                & $GuiLog "У процесса нет главного окна для мягкого закрытия: $line"
                Write-DetailLog "У процесса нет главного окна для мягкого закрытия: $line"
            }
        } catch {
            & $GuiLog "Не удалось отправить закрытие: $($_.Exception.Message)"
            Write-DetailLog "Не удалось отправить закрытие: $($_.Exception.Message)"
        }
    }

    Start-Sleep -Seconds 3
}

function Kill-LockingProcesses($Processes, [scriptblock]$GuiLog) {
    foreach ($p in @($Processes)) {
        try {
            if ($p.HasExited) { continue }

            $line = Get-ProcessDisplayLine $p
            & $GuiLog "Принудительно закрываю: $line"
            Write-DetailLog "Принудительно закрываю: $line"
            Stop-Process -Id $p.Id -Force -ErrorAction Stop
        } catch {
            & $GuiLog "Не удалось принудительно закрыть процесс: $($_.Exception.Message)"
            Write-DetailLog "Не удалось принудительно закрыть процесс: $($_.Exception.Message)"
        }
    }

    Start-Sleep -Seconds 2
}

function Resolve-LockingProcessesBeforeMove([string]$FolderRaw, [scriptblock]$GuiLog, [System.Windows.Forms.Form]$OwnerForm) {
    $cached = Get-ValidLockCheckCache $FolderRaw 5
    if ($cached) {
        & $GuiLog "Использую результат последней проверки занятости. Повторное сканирование пропущено."
        Write-DetailLog "Использован кэш проверки занятости: $($cached.Source)"
        $lockers = @($cached.Processes)
        if ($cached.HadErrors) {
            & $GuiLog "ПРЕДУПРЕЖДЕНИЕ: последняя проверка занятости была неполной: $($cached.ErrorText)"
        }
    } else {
        $lockers = @(Get-LockingProcessesForFolder $FolderRaw $GuiLog)
        Save-LockCheckCache $FolderRaw $lockers
    }

    # Процессы из кэша могли уже закрыться.
    $alive = @()
    foreach ($p in @($lockers)) {
        try {
            if ($p -and -not $p.HasExited) { $alive += $p }
        } catch {}
    }
    $lockers = @($alive)

    Log-LockingProcesses $lockers $GuiLog

    if ($lockers.Count -eq 0) {
        return $true
    }

    $listText = Format-LockingProcessesText $lockers 14

    $answer = [System.Windows.Forms.MessageBox]::Show(
        "Эти приложения держат файлы в выбранной папке и могут помешать переносу:`r`n`r`n$listText`r`n`r`nПопробовать закрыть их автоматически?`r`n`r`nСначала будет отправлена обычная команда закрытия окна. Несохранённые данные в этих приложениях могут быть потеряны.",
        "Папка используется",
        [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )

    if ($answer -eq [System.Windows.Forms.DialogResult]::Cancel) {
        & $GuiLog "Перенос отменён пользователем."
        return $false
    }

    if ($answer -eq [System.Windows.Forms.DialogResult]::No) {
        & $GuiLog "Пользователь отказался от автозакрытия. Перенос отменён."
        return $false
    }

    Close-LockingProcessesGracefully $lockers $GuiLog

    $lockersAfterClose = @(Get-LockingProcessesForFolder $FolderRaw $GuiLog)
    Save-LockCheckCache $FolderRaw $lockersAfterClose
    Log-LockingProcesses $lockersAfterClose $GuiLog

    if ($lockersAfterClose.Count -eq 0) {
        & $GuiLog "После мягкого закрытия блокировок не найдено."
        return $true
    }

    $listText2 = Format-LockingProcessesText $lockersAfterClose 14

    $killAnswer = [System.Windows.Forms.MessageBox]::Show(
        "Некоторые процессы всё ещё держат файлы:`r`n`r`n$listText2`r`n`r`nЗакрыть их принудительно?`r`n`r`nЭто может привести к потере несохранённых данных.",
        "Процессы всё ещё мешают",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )

    if ($killAnswer -ne [System.Windows.Forms.DialogResult]::Yes) {
        & $GuiLog "Пользователь отказался от принудительного закрытия. Перенос отменён."
        return $false
    }

    Kill-LockingProcesses $lockersAfterClose $GuiLog

    $lockersAfterKill = @(Get-LockingProcessesForFolder $FolderRaw $GuiLog)
    Save-LockCheckCache $FolderRaw $lockersAfterKill
    Log-LockingProcesses $lockersAfterKill $GuiLog

    if ($lockersAfterKill.Count -eq 0) {
        & $GuiLog "После принудительного закрытия блокировок не найдено."
        return $true
    }

    [System.Windows.Forms.MessageBox]::Show(
        "Папка всё ещё используется. Перенос отменён.`r`n`r`nЗакройте приложения вручную или перезагрузите Windows.",
        "Папка всё ещё занята",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null

    return $false
}


function Resolve-RegularMoveTarget([string]$SourceRaw, [string]$TargetRaw) {
    $source = Normalize-Path $SourceRaw
    $target = Normalize-Path $TargetRaw

    if ([string]::IsNullOrWhiteSpace($source) -or [string]::IsNullOrWhiteSpace($target)) {
        return $target
    }

    $sourceName = Split-Path -Leaf $source
    $targetName = Split-Path -Leaf $target

    if ([string]::IsNullOrWhiteSpace($sourceName)) {
        return $target
    }

    # Обычный перенос работает как перенос папки В указанную папку назначения.
    # Если пользователь уже указал путь, который заканчивается именем исходной папки,
    # считаем это явным итоговым путём и не добавляем имя повторно.
    if ($targetName -ieq $sourceName) {
        return $target
    }

    return (Normalize-Path (Join-Path $target $sourceName))
}

function Test-DirectoryIsMissingOrEmpty([string]$Path) {
    if (!(Test-Path -LiteralPath $Path)) { return $true }
    if (!(Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    return (Test-DirectoryIsEmpty $Path)
}

function Remove-JunctionLinkOnly([string]$LinkPath) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "cmd.exe"
    $psi.Arguments = "/c rmdir `"$LinkPath`""
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()
    $p.WaitForExit()

    return [PSCustomObject]@{
        ExitCode = $p.ExitCode
        Output   = ($stdout + "`r`n" + $stderr).Trim()
    }
}

function Repair-MisnestedJunctionContent([object]$Plan, [scriptblock]$Log) {
    $sourceLink = $Plan.Source
    $currentTarget = $Plan.CurrentTarget
    $newTarget = $Plan.Target

    $script:CurrentDetailedLog = New-DetailedLogFile

    & $Log "Исправление структуры уже перенесённой папки."
    & $Log "Ссылка:          $sourceLink"
    & $Log "Текущая цель:    $currentTarget"
    & $Log "Новая цель:      $newTarget"
    & $Log "Подробный лог:   $script:CurrentDetailedLog"

    Write-DetailLog "=== Folder Mover: repair misnested junction content ==="
    Write-DetailLog "Ссылка:        $sourceLink"
    Write-DetailLog "Текущая цель:  $currentTarget"
    Write-DetailLog "Новая цель:    $newTarget"

    if (!(Test-Path -LiteralPath $sourceLink -PathType Container)) {
        throw "Ссылка больше не найдена: $sourceLink"
    }
    if (!(Is-ReparsePoint $sourceLink)) {
        throw "Исходная папка больше не является ссылкой: $sourceLink"
    }
    if (!(Test-Path -LiteralPath $currentTarget -PathType Container)) {
        throw "Текущая цель ссылки не найдена: $currentTarget"
    }
    if (!(Test-DirectoryIsMissingOrEmpty $newTarget)) {
        throw "Новая цель уже существует и не пустая: $newTarget"
    }

    if (!(Test-Path -LiteralPath $newTarget -PathType Container)) {
        & $Log "Создаю вложенную итоговую папку: $newTarget"
        Write-DetailLog "Создаю вложенную итоговую папку: $newTarget"
        New-Item -ItemType Directory -Path $newTarget -Force -ErrorAction Stop | Out-Null
    }

    $items = @(Get-ChildItem -LiteralPath $currentTarget -Force -ErrorAction Stop)
    $moved = 0
    foreach ($item in $items) {
        $itemPath = Normalize-Path $item.FullName
        if ($itemPath.ToLowerInvariant() -eq (Normalize-Path $newTarget).ToLowerInvariant()) {
            continue
        }

        & $Log "Перемещаю: $($item.Name)"
        Write-DetailLog ("Перемещаю: {0} -> {1}" -f $itemPath, $newTarget)
        Move-Item -LiteralPath $itemPath -Destination $newTarget -Force -ErrorAction Stop
        $moved++
        Pump-GuiIfPossible
    }

    & $Log "Перенесено элементов внутрь новой папки: $moved"
    Write-DetailLog "Перенесено элементов внутрь новой папки: $moved"

    & $Log "Пересоздаю junction-ссылку на новую цель..."
    Write-DetailLog "Удаляю старую junction-ссылку: $sourceLink"
    $rm = Remove-JunctionLinkOnly $sourceLink
    if ($rm.Output) { Write-DetailLog $rm.Output }
    if ($rm.ExitCode -ne 0 -or (Test-Path -LiteralPath $sourceLink)) {
        throw "Не удалось удалить старую junction-ссылку. rmdir вернул код $($rm.ExitCode)."
    }

    Write-DetailLog "Создаю junction-ссылку: $sourceLink -> $newTarget"
    $mk = New-Junction $sourceLink $newTarget
    if ($mk.Output) {
        & $Log $mk.Output
        Write-DetailLog $mk.Output
    }

    if ($mk.ExitCode -ne 0 -or !(Test-Path -LiteralPath $sourceLink)) {
        Write-DetailLog "Создание новой ссылки не удалось. Пробую вернуть ссылку на старую цель."
        $fallback = New-Junction $sourceLink $currentTarget
        if ($fallback.Output) { Write-DetailLog $fallback.Output }
        throw "Не удалось создать новую junction-ссылку. mklink вернул код $($mk.ExitCode). Данные уже лежат в: $newTarget"
    }

    & $Log "Готово. Содержимое вложено в отдельную папку, ссылка переназначена."
    & $Log "Проверка: $sourceLink -> $newTarget"
    Write-DetailLog "Готово. Содержимое вложено в отдельную папку, ссылка переназначена."
}

function Validate-MovePlan([string]$SourceRaw, [string]$TargetRaw) {
    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]

    $source = Normalize-Path $SourceRaw
    $targetInput = Normalize-Path $TargetRaw
    $target = Resolve-RegularMoveTarget $source $targetInput
    $repairMode = $false
    $currentTarget = ""

    if ([string]::IsNullOrWhiteSpace($source)) { $errors.Add("Не указана исходная папка.") }
    if ([string]::IsNullOrWhiteSpace($targetInput)) { $errors.Add("Не указана папка назначения.") }

    if ($errors.Count -eq 0) {
        if (!(Test-Path -LiteralPath $source -PathType Container)) {
            $errors.Add("Исходная папка не существует: $source")
        }

        $sourceRootPath = [System.IO.Path]::GetPathRoot($source)
        if (-not [string]::IsNullOrWhiteSpace($sourceRootPath)) {
            if ((Normalize-Path $source).ToLowerInvariant() -eq (Normalize-Path $sourceRootPath).ToLowerInvariant()) {
                $errors.Add("Нельзя переносить корень диска целиком: $source")
            }
        }

        $forbiddenRoots = Get-ForbiddenSourceRoots
        foreach ($root in $forbiddenRoots) {
            if ((Normalize-Path $source).ToLowerInvariant() -eq (Normalize-Path $root).ToLowerInvariant()) {
                $errors.Add("Нельзя переносить эту корневую системную/пользовательскую папку целиком. Выберите конкретную вложенную папку: $source")
            }
        }

        if ($target.ToLowerInvariant() -ne $targetInput.ToLowerInvariant()) {
            $warnings.Add("Итоговая папка переноса будет создана внутри указанной папки назначения: $target")
        }

        if (Test-Path -LiteralPath $targetInput) {
            if (!(Test-Path -LiteralPath $targetInput -PathType Container)) {
                $errors.Add("Папка назначения уже существует, но это не папка: $targetInput")
            }
        }

        if (Test-Path -LiteralPath $source -PathType Container) {
            try {
                if (Is-ReparsePoint $source) {
                    # Специальный режим восстановления после ошибочного выбора папки назначения:
                    # C:\Users\...\Documents\Electronic Arts -> G:\C-Link\Documents
                    # нужно превратить в:
                    # C:\Users\...\Documents\Electronic Arts -> G:\C-Link\Documents\Electronic Arts
                    $targetRaw = Get-ReparsePointTarget $source
                    $currentTarget = Normalize-ReparseTargetPath $targetRaw
                    $targetParentForRepair = Split-Path -Parent $target

                    if ([string]::IsNullOrWhiteSpace($currentTarget) -or !(Test-Path -LiteralPath $currentTarget -PathType Container)) {
                        $errors.Add("Исходная папка является ссылкой, но её текущая цель не найдена: $currentTarget")
                    } elseif ((Normalize-Path $targetParentForRepair).ToLowerInvariant() -eq (Normalize-Path $currentTarget).ToLowerInvariant()) {
                        $repairMode = $true
                        $warnings.Add("Исходная папка уже является junction-ссылкой. Будет выполнено исправление структуры: содержимое текущей цели будет вложено в отдельную папку, а ссылка будет переназначена.")
                        $warnings.Add("Текущая цель ссылки: $currentTarget")
                        $warnings.Add("Новая цель ссылки: $target")
                    } else {
                        $errors.Add("Исходная папка уже является ссылкой/reparse point. Обычный перенос такой папки запрещён. Для исправления укажите папку назначения так, чтобы итоговый путь был прямой подпапкой текущей цели ссылки: $currentTarget")
                    }
                }
            } catch {
                $errors.Add("Не удалось проверить исходную папку: $($_.Exception.Message)")
            }

            if (-not $repairMode -and $errors.Count -eq 0) {
                try {
                    $nestedLinks = @(Get-NestedReparsePointDirectories $source 25)
                    if ($nestedLinks.Count -gt 0) {
                        $errors.Add("Внутри выбранной папки уже есть перенесённые/ссылочные папки. Нельзя безопасно переносить родительскую папку, иначе вложенная ссылка может потеряться при копировании.")
                        foreach ($link in $nestedLinks) {
                            $errors.Add("  вложенная ссылка: $(Get-ReparsePointDisplayLine $link)")
                        }
                        if ($nestedLinks.Count -ge 25) {
                            $errors.Add("  показаны первые 25 ссылок; возможно, внутри есть ещё.")
                        }
                    }
                } catch {
                    $warnings.Add("Не удалось проверить вложенные ссылки/reparse point: $($_.Exception.Message)")
                }
            }
        }

        if (Test-Path -LiteralPath $target) {
            if (!(Test-Path -LiteralPath $target -PathType Container)) {
                $errors.Add("Итоговая папка уже существует, но это не папка: $target")
            } elseif (Test-DirectoryIsEmpty $target) {
                $warnings.Add("Итоговая папка уже существует, но она пустая. Она будет использована.")
            } else {
                $errors.Add("Итоговая папка уже существует и не пустая. Укажите другую папку или очистите её: $target")
            }
        }

        $targetParent = Split-Path -Parent $target
        if ([string]::IsNullOrWhiteSpace($targetParent)) {
            $errors.Add("У итоговой папки должен быть родительский каталог.")
        }

        if (-not $repairMode) {
            if (Test-PathInside $target $source) {
                $errors.Add("Итоговая папка не может находиться внутри исходной папки.")
            }

            if (Test-PathInside $source $target) {
                $errors.Add("Исходная папка не может находиться внутри итоговой папки.")
            }

            if ((Normalize-Path $source).ToLowerInvariant() -eq (Normalize-Path $target).ToLowerInvariant()) {
                $errors.Add("Исходный и итоговый путь совпадают.")
            }
        } else {
            if ((Normalize-Path $currentTarget).ToLowerInvariant() -eq (Normalize-Path $target).ToLowerInvariant()) {
                $errors.Add("Текущая цель ссылки и новая цель совпадают.")
            }
        }

        $sourceRoot = [System.IO.Path]::GetPathRoot($source)
        $targetRoot = [System.IO.Path]::GetPathRoot($target)
        if ($sourceRoot -and $targetRoot -and ($sourceRoot.ToLowerInvariant() -eq $targetRoot.ToLowerInvariant())) {
            $warnings.Add("Исходная и итоговая папки находятся на одном диске. Это допустимо, но перенос не освободит место на этом диске.")
        }

        if ($targetRoot -match '^[A-Za-z]:\\') {
            try {
                $driveLetter = $targetRoot.Substring(0,1)
                $vol = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='${driveLetter}:'" -ErrorAction Stop
                if ($vol.FileSystem -ne "NTFS") {
                    $warnings.Add("Целевой диск не NTFS ($($vol.FileSystem)). Junction-ссылки работают только на NTFS.")
                }
            } catch {
                $warnings.Add("Не удалось проверить файловую систему целевого диска. Для junction нужен NTFS.")
            }
        } else {
            $warnings.Add("Итоговый путь не похож на обычный локальный путь вида D:\Folder. Сетевые пути для junction не подходят.")
        }
    }

    return [PSCustomObject]@{
        Source        = $source
        TargetInput   = $targetInput
        Target        = $target
        RepairMode    = $repairMode
        CurrentTarget = $currentTarget
        Errors        = $errors
        Warnings      = $warnings
    }
}

function New-Junction([string]$LinkPath, [string]$TargetPath) {
    $cmd = "mklink /J `"$LinkPath`" `"$TargetPath`""
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "cmd.exe"
    $psi.Arguments = "/c $cmd"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()
    $p.WaitForExit()

    return [PSCustomObject]@{
        ExitCode = $p.ExitCode
        Output   = ($stdout + "`r`n" + $stderr).Trim()
    }
}

function Copy-FolderWithRobocopy([string]$From, [string]$To, [string]$DetailLogFile) {
    Write-DetailLog "Подробный вывод копирования ниже. Если папка большая, следите за этим окном консоли." $DetailLogFile
    Write-DetailLog "Robocopy: $From -> $To" $DetailLogFile

    $args = @(
        $From,
        $To,
        "/E",
        "/COPY:DAT",
        "/DCOPY:DAT",
        "/R:2",
        "/W:2",
        "/XJ",
        "/FFT",
        "/ETA",
        "/TEE",
        "/LOG+:$DetailLogFile"
    )

    & robocopy.exe @args
    $code = $LASTEXITCODE

    Write-DetailLog "Robocopy exit code: $code" $DetailLogFile

    if ($code -ge 8) {
        throw "Robocopy сообщил об ошибке. Код: $code. Подробности в файле: $DetailLogFile"
    }

    if (!(Test-Path -LiteralPath $To -PathType Container)) {
        throw "После копирования новая папка не найдена: $To"
    }
}

function Remove-FolderAfterSuccessfulMove([string]$Path, [scriptblock]$GuiLog) {
    if (!(Test-Path -LiteralPath $Path -PathType Container)) {
        return
    }

    & $GuiLog "Удаляю временную исходную копию. Для большой папки это может занять время..."
    Write-DetailLog "Удаляю временную исходную копию: $Path"

    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        Write-DetailLog "Временная копия удалена."
    } catch {
        & $GuiLog "ПРЕДУПРЕЖДЕНИЕ: ссылку создал, но временную копию удалить не удалось: $Path"
        & $GuiLog "Её можно удалить вручную после проверки."
        Write-DetailLog "Не удалось удалить временную копию: $($_.Exception.Message)"
    }
}

function Move-AppDataFolderAndLink([string]$SourceRaw, [string]$TargetRaw, [scriptblock]$Log) {
    $plan = Validate-MovePlan $SourceRaw $TargetRaw
    foreach ($e in $plan.Errors) { & $Log "ОШИБКА: $e" }
    foreach ($w in $plan.Warnings) { & $Log "ПРЕДУПРЕЖДЕНИЕ: $w" }
    if ($plan.Errors.Count -gt 0) { throw "План содержит ошибки. Перенос отменён." }

    if ($plan.RepairMode) {
        Repair-MisnestedJunctionContent $plan $Log
        return
    }

    $source = $plan.Source
    $target = $plan.Target
    $targetParent = Split-Path -Parent $target
    $sourceParent = Split-Path -Parent $source
    $sourceName = Split-Path -Leaf $source
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $tempPath = Join-Path $sourceParent ($sourceName + ".__moving_to_link_" + $timestamp)

    $script:CurrentDetailedLog = New-DetailedLogFile

    & $Log "Исходная папка: $source"
    & $Log "Новая папка:    $target"
    & $Log "Подробный лог:  $script:CurrentDetailedLog"
    & $Log "Во время большого переноса смотрите окно консоли."
    & $Log "Временное имя:  $tempPath"

    Write-DetailLog "=== Folder Mover ==="
    Write-DetailLog "Исходная папка: $source"
    Write-DetailLog "Новая папка:    $target"
    Write-DetailLog "Временное имя:  $tempPath"

    try {
        if (!(Test-Path -LiteralPath $targetParent -PathType Container)) {
            & $Log "Создаю родительскую папку: $targetParent"
            Write-DetailLog "Создаю родительскую папку: $targetParent"
            New-Item -ItemType Directory -Path $targetParent -Force -ErrorAction Stop | Out-Null
        }

        & $Log "Переименовываю исходную папку во временную..."
        Write-DetailLog "Переименовываю исходную папку во временную..."

        try {
            Rename-Item -LiteralPath $source -NewName (Split-Path -Leaf $tempPath) -ErrorAction Stop
        } catch {
            & $Log "Не удалось переименовать исходную папку. Вероятно, она занята приложением."
            Write-DetailLog "Rename failed: $($_.Exception.Message)"
            try {
                $lockers = @(Get-LockingProcessesForFolder $source $Log)
                Log-LockingProcesses $lockers $Log
            } catch {
                & $Log "Не удалось определить мешающее приложение: $($_.Exception.Message)"
            }
            throw "Исходная папка занята или нет прав на переименование: $($_.Exception.Message)"
        }

        try {
            & $Log "Копирую данные через robocopy. Подробности выводятся в консоль..."
            Copy-FolderWithRobocopy $tempPath $target $script:CurrentDetailedLog
        } catch {
            & $Log "Копирование не удалось. Возвращаю исходную папку на место..."
            Write-DetailLog "Копирование не удалось. Пытаюсь вернуть исходную папку на место."
            if (Test-Path -LiteralPath $target) {
                Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
            }
            if (Test-Path -LiteralPath $tempPath) {
                Rename-Item -LiteralPath $tempPath -NewName $sourceName -ErrorAction SilentlyContinue
            }
            throw
        }

        & $Log "Создаю junction-ссылку..."
        Write-DetailLog "Создаю junction-ссылку: $source -> $target"
        $mk = New-Junction $source $target
        if ($mk.Output) {
            & $Log $mk.Output
            Write-DetailLog $mk.Output
        }

        if ($mk.ExitCode -ne 0 -or !(Test-Path -LiteralPath $source)) {
            & $Log "Создание ссылки не удалось. Пробую откатить перенос..."
            Write-DetailLog "Создание ссылки не удалось. Пробую откатить перенос."
            if (Test-Path -LiteralPath $target -PathType Container) {
                Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
            }
            if (Test-Path -LiteralPath $tempPath -PathType Container) {
                Rename-Item -LiteralPath $tempPath -NewName $sourceName -ErrorAction SilentlyContinue
            }
            throw "mklink вернул код $($mk.ExitCode)."
        }

        Remove-FolderAfterSuccessfulMove $tempPath $Log

        & $Log "Готово. Старый путь теперь ведёт в новую папку."
        & $Log "Проверка: $source -> $target"
        Write-DetailLog "Готово. Старый путь теперь ведёт в новую папку."
    } catch {
        throw $_
    }
}


function Normalize-ReparseTargetPath([string]$TargetRaw) {
    if ([string]::IsNullOrWhiteSpace($TargetRaw)) { return "" }

    $target = ([string]$TargetRaw).Trim()
    if ($target.Contains(";")) {
        $target = ($target -split ';')[0].Trim()
    }
    if ($target.StartsWith("\??\")) {
        $target = $target.Substring(4)
    }
    if ($target.StartsWith("\\?\")) {
        $target = $target.Substring(4)
    }

    try {
        return Normalize-Path $target
    } catch {
        return $target.TrimEnd('\')
    }
}

function Get-LinkSearchRoots {
    $roots = New-Object System.Collections.Generic.List[string]

    foreach ($p in @((Get-UserAppDataRoot), (Get-UserDocumentsRoot))) {
        try {
            if (-not [string]::IsNullOrWhiteSpace($p) -and (Test-Path -LiteralPath $p -PathType Container)) {
                $roots.Add((Normalize-Path $p)) | Out-Null
            }
        } catch {}
    }

    return @($roots | Select-Object -Unique)
}


function Pump-GuiIfPossible {
    try {
        [System.Windows.Forms.Application]::DoEvents()
    } catch {}
}

function Get-JunctionsPointingIntoBase([string]$BaseRaw, [int]$MaxResults = 2000, [scriptblock]$GuiLog = $null) {
    $base = Normalize-Path $BaseRaw
    $baseLower = $base.ToLowerInvariant()
    $rows = New-Object System.Collections.Generic.List[object]

    if ([string]::IsNullOrWhiteSpace($base) -or !(Test-Path -LiteralPath $base -PathType Container)) {
        return @()
    }

    $scanned = 0
    $skipped = 0
    $errors = 0
    $lastUi = Get-Date

    foreach ($root in @(Get-LinkSearchRoots)) {
        if ($GuiLog) { & $GuiLog "Ищу ссылки внутри: $root"; Pump-GuiIfPossible }

        $stack = New-Object 'System.Collections.Generic.Stack[string]'
        $stack.Push((Normalize-Path $root))

        while ($stack.Count -gt 0) {
            $current = $stack.Pop()
            $scanned++

            if ($GuiLog -and (($scanned % 300) -eq 0)) {
                & $GuiLog "Поиск ссылок: просмотрено папок $scanned, найдено $($rows.Count), пропущено $skipped. Текущая: $current"
                Pump-GuiIfPossible
            } elseif ($GuiLog -and (((Get-Date) - $lastUi).TotalSeconds -ge 2)) {
                Pump-GuiIfPossible
                $lastUi = Get-Date
            }

            $children = $null
            try {
                $children = [System.IO.Directory]::GetDirectories($current)
            } catch {
                $errors++
                continue
            }

            foreach ($child in $children) {
                if ($rows.Count -ge $MaxResults) { break }

                try {
                    $attrs = [System.IO.File]::GetAttributes($child)
                    $isReparse = (($attrs -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)

                    if ($isReparse) {
                        $skipped++

                        $targetRaw = Get-ReparsePointTarget $child
                        $target = Normalize-ReparseTargetPath $targetRaw
                        if ([string]::IsNullOrWhiteSpace($target)) { continue }

                        if (Test-PathInside $target $base) {
                            $relative = ""
                            $targetNorm = Normalize-Path $target
                            if ($targetNorm.ToLowerInvariant() -ne $baseLower) {
                                $relative = $targetNorm.Substring($base.Length).TrimStart('\')
                            }

                            $rows.Add([PSCustomObject]@{
                                LinkPath  = Normalize-Path $child
                                OldTarget = $targetNorm
                                Relative  = $relative
                            }) | Out-Null

                            if ($GuiLog) {
                                & $GuiLog "Найдена ссылка: $(Normalize-Path $child) -> $targetNorm"
                                Pump-GuiIfPossible
                            }
                        }

                        # Внутрь junction/symlink не заходим: это защищает от циклов и сильного зависания.
                        continue
                    }

                    $stack.Push($child)
                } catch {
                    $errors++
                    continue
                }
            }
        }
    }

    if ($GuiLog) {
        & $GuiLog "Поиск ссылок завершён: просмотрено папок $scanned, найдено $($rows.Count), пропущено reparse point $skipped, ошибок доступа $errors."
        Pump-GuiIfPossible
    }

    return $rows.ToArray()
}

function Validate-BaseMigrationPlan([string]$SourceBaseRaw, [string]$TargetBaseRaw) {
    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]

    $source = Normalize-Path $SourceBaseRaw
    $target = Normalize-Path $TargetBaseRaw

    if ([string]::IsNullOrWhiteSpace($source)) { $errors.Add("Не указана старая база/исходная папка.") }
    if ([string]::IsNullOrWhiteSpace($target)) { $errors.Add("Не указана новая база/новая папка.") }

    if ($errors.Count -eq 0) {
        if (!(Test-Path -LiteralPath $source -PathType Container)) {
            $errors.Add("Старая база не существует: $source")
        }

        $sourceRootPath = [System.IO.Path]::GetPathRoot($source)
        if (-not [string]::IsNullOrWhiteSpace($sourceRootPath)) {
            if ((Normalize-Path $source).ToLowerInvariant() -eq (Normalize-Path $sourceRootPath).ToLowerInvariant()) {
                $errors.Add("Нельзя переносить корень диска целиком: $source")
            }
        }

        if (Test-Path -LiteralPath $source -PathType Container) {
            try {
                if (Is-ReparsePoint $source) {
                    $errors.Add("Старая база уже является ссылкой/reparse point. Выберите реальную папку с данными, а не ссылку.")
                }
            } catch {
                $errors.Add("Не удалось проверить старую базу: $($_.Exception.Message)")
            }

            try {
                $nestedLinks = @(Get-NestedReparsePointDirectories $source 25)
                if ($nestedLinks.Count -gt 0) {
                    $warnings.Add("Внутри старой базы есть вложенные ссылки/reparse point. Robocopy будет копировать с /XJ, то есть не будет раскрывать вложенные junction.")
                    foreach ($link in $nestedLinks) {
                        $warnings.Add("  вложенная ссылка: $(Get-ReparsePointDisplayLine $link)")
                    }
                    if ($nestedLinks.Count -ge 25) {
                        $warnings.Add("  показаны первые 25 ссылок; возможно, внутри есть ещё.")
                    }
                }
            } catch {
                $warnings.Add("Не удалось проверить вложенные ссылки/reparse point: $($_.Exception.Message)")
            }
        }

        if (Test-Path -LiteralPath $target) {
            if (!(Test-Path -LiteralPath $target -PathType Container)) {
                $errors.Add("Новая база уже существует, но это не папка: $target")
            } elseif (Test-DirectoryIsEmpty $target) {
                $warnings.Add("Новая база уже существует, но она пустая. Будет использована как итоговая база без автодобавления AppData или имени исходной папки.")
            } else {
                $errors.Add("Новая база уже существует и не пустая. Для переезда базы укажите пустую папку или путь, которого ещё нет: $target")
            }
        }

        $targetParent = Split-Path -Parent $target
        if ([string]::IsNullOrWhiteSpace($targetParent)) {
            $errors.Add("У новой базы должен быть родительский каталог.")
        }

        if (Test-PathInside $target $source) {
            $errors.Add("Новая база не может находиться внутри старой базы.")
        }

        if (Test-PathInside $source $target) {
            $errors.Add("Старая база не может находиться внутри новой базы.")
        }

        if ((Normalize-Path $source).ToLowerInvariant() -eq (Normalize-Path $target).ToLowerInvariant()) {
            $errors.Add("Старый и новый путь совпадают.")
        }

        $sourceRoot = [System.IO.Path]::GetPathRoot($source)
        $targetRoot = [System.IO.Path]::GetPathRoot($target)
        if ($sourceRoot -eq $targetRoot) {
            $warnings.Add("Старая и новая база находятся на одном диске. Для безопасного переноса потребуется временно занять место под копию.")
        }

        if ($target -match '^[A-Za-z]:\\') {
            $drive = $target.Substring(0,1)
            try {
                $vol = Get-Volume -DriveLetter $drive -ErrorAction Stop
                if ($vol.FileSystem -ne "NTFS") {
                    $warnings.Add("Целевой диск не NTFS ($($vol.FileSystem)). Junction-ссылки работают только на NTFS.")
                }
            } catch {
                $warnings.Add("Не удалось проверить файловую систему целевого диска. Для junction нужен NTFS.")
            }
        } else {
            $warnings.Add("Целевой путь не похож на обычный локальный путь вида E:\\Folder. Сетевые пути для junction не подходят.")
        }
    }

    return [PSCustomObject]@{
        Source   = $source
        Target   = $target
        Errors   = $errors
        Warnings = $warnings
    }
}

function Remove-ReparseDirectoryLink([string]$LinkPath) {
    $link = Normalize-Path $LinkPath
    if (!(Test-Path -LiteralPath $link)) {
        throw "Ссылка не найдена: $link"
    }
    if (-not (Is-ReparsePoint $link)) {
        throw "Путь уже не является ссылкой/reparse point: $link"
    }

    $cmd = "rmdir `"$link`""
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "cmd.exe"
    $psi.Arguments = "/c $cmd"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()
    $p.WaitForExit()

    $out = ($stdout + "`r`n" + $stderr).Trim()
    if ($p.ExitCode -ne 0) {
        throw "Не удалось удалить ссылку $link. Код: $($p.ExitCode). $out"
    }
}

function Retarget-ReparseDirectoryLink([string]$LinkPath, [string]$NewTarget, [string]$OldTarget, [scriptblock]$Log) {
    $link = Normalize-Path $LinkPath
    $newTargetNorm = Normalize-Path $NewTarget
    $oldTargetNorm = Normalize-Path $OldTarget

    & $Log "Переназначаю ссылку: $link"
    & $Log "  было: $oldTargetNorm"
    & $Log "  стало: $newTargetNorm"

    try {
        Remove-ReparseDirectoryLink $link
        $mk = New-Junction $link $newTargetNorm
        if ($mk.Output) { & $Log $mk.Output }
        if ($mk.ExitCode -ne 0 -or !(Test-Path -LiteralPath $link)) {
            throw "mklink вернул код $($mk.ExitCode)."
        }
    } catch {
        & $Log "ОШИБКА переназначения ссылки. Пробую восстановить старую ссылку: $link -> $oldTargetNorm"
        try {
            if (!(Test-Path -LiteralPath $link)) {
                $restore = New-Junction $link $oldTargetNorm
                if ($restore.Output) { & $Log $restore.Output }
            }
        } catch {
            & $Log "КРИТИЧЕСКИ: не удалось восстановить старую ссылку: $($_.Exception.Message)"
        }
        throw
    }
}

function Test-TargetIsDirectSubfolderOfSource([string]$SourceRaw, [string]$TargetRaw) {
    $source = Normalize-Path $SourceRaw
    $target = Normalize-Path $TargetRaw
    if ([string]::IsNullOrWhiteSpace($source) -or [string]::IsNullOrWhiteSpace($target)) { return $false }
    if (-not (Test-PathInside $target $source)) { return $false }
    $targetParent = Split-Path -Parent $target
    if ([string]::IsNullOrWhiteSpace($targetParent)) { return $false }
    return ((Normalize-Path $targetParent).ToLowerInvariant() -eq $source.ToLowerInvariant())
}

function Invoke-BaseMoveSmart([string]$SourceBaseRaw, [string]$TargetBaseRaw, [scriptblock]$Log) {
    if (Test-TargetIsDirectSubfolderOfSource $SourceBaseRaw $TargetBaseRaw) {
        & $Log "Обнаружен переезд базы в прямую подпапку. Выполняю вложение базы через тот же режим 'Переезд базы'."
        Wrap-BaseIntoSubfolderAndRetargetLinks $SourceBaseRaw $TargetBaseRaw $Log
        return "wrap"
    }

    Move-BaseFolderAndRetargetLinks $SourceBaseRaw $TargetBaseRaw $Log
    return "move"
}

function Move-BaseFolderAndRetargetLinks([string]$SourceBaseRaw, [string]$TargetBaseRaw, [scriptblock]$Log) {
    $plan = Validate-BaseMigrationPlan $SourceBaseRaw $TargetBaseRaw
    foreach ($e in $plan.Errors) { & $Log "ОШИБКА: $e" }
    foreach ($w in $plan.Warnings) { & $Log "ПРЕДУПРЕЖДЕНИЕ: $w" }
    if ($plan.Errors.Count -gt 0) { throw "План содержит ошибки. Переезд базы отменён." }

    $source = $plan.Source
    $target = $plan.Target
    $targetParent = Split-Path -Parent $target
    $sourceParent = Split-Path -Parent $source
    $sourceName = Split-Path -Leaf $source
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $tempPath = Join-Path $sourceParent ($sourceName + ".__base_moving_" + $timestamp)

    $script:CurrentDetailedLog = New-DetailedLogFile

    & $Log "Старая база:   $source"
    & $Log "Новая база:    $target"
    & $Log "Подробный лог: $script:CurrentDetailedLog"
    & $Log "Ищу старые AppData/Документы-ссылки, которые ведут внутрь старой базы..."

    Write-DetailLog "=== Folder Mover: base migration ==="
    Write-DetailLog "Старая база: $source"
    Write-DetailLog "Новая база:  $target"
    Write-DetailLog "Временное имя: $tempPath"

    $links = @(Get-JunctionsPointingIntoBase $source 2000 $Log)
    if ($links.Count -eq 0) {
        & $Log "ПРЕДУПРЕЖДЕНИЕ: не найдено AppData/Документы-ссылок, которые указывают внутрь старой базы. Будет создана только ссылка старой базы на новую."
    } else {
        & $Log "Найдено ссылок для переназначения: $($links.Count)"
        foreach ($row in $links | Select-Object -First 30) {
            $newTargetPreview = Join-BaseAndRelative $target $row.Relative
            & $Log "  $($row.LinkPath) -> $newTargetPreview"
        }
        if ($links.Count -gt 30) { & $Log "  показаны первые 30 ссылок." }
    }

    try {
        if (!(Test-Path -LiteralPath $targetParent -PathType Container)) {
            & $Log "Создаю родительскую папку: $targetParent"
            Write-DetailLog "Создаю родительскую папку: $targetParent"
            New-Item -ItemType Directory -Path $targetParent -Force -ErrorAction Stop | Out-Null
        }

        & $Log "Переименовываю старую базу во временную папку..."
        Write-DetailLog "Переименовываю старую базу во временную папку..."
        try {
            Rename-Item -LiteralPath $source -NewName (Split-Path -Leaf $tempPath) -ErrorAction Stop
        } catch {
            & $Log "Не удалось переименовать старую базу. Вероятно, она занята приложением."
            Write-DetailLog "Rename failed: $($_.Exception.Message)"
            throw "Старая база занята или нет прав на переименование: $($_.Exception.Message)"
        }

        try {
            & $Log "Копирую базу через robocopy. Подробности выводятся в консоль..."
            Copy-FolderWithRobocopy $tempPath $target $script:CurrentDetailedLog
        } catch {
            & $Log "Копирование не удалось. Возвращаю старую базу на место..."
            Write-DetailLog "Копирование не удалось. Пытаюсь вернуть старую базу на место."
            if (Test-Path -LiteralPath $target) {
                Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
            }
            if (Test-Path -LiteralPath $tempPath) {
                Rename-Item -LiteralPath $tempPath -NewName $sourceName -ErrorAction SilentlyContinue
            }
            throw
        }

        & $Log "Создаю страховочную ссылку старой базы на новую: $source -> $target"
        Write-DetailLog "Создаю страховочную ссылку старой базы: $source -> $target"
        $mkBase = New-Junction $source $target
        if ($mkBase.Output) {
            & $Log $mkBase.Output
            Write-DetailLog $mkBase.Output
        }
        if ($mkBase.ExitCode -ne 0 -or !(Test-Path -LiteralPath $source)) {
            & $Log "Создание ссылки старой базы не удалось. Пробую откатить перенос..."
            Write-DetailLog "Создание ссылки старой базы не удалось. Пробую откатить перенос."
            if (Test-Path -LiteralPath $target -PathType Container) {
                Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
            }
            if (Test-Path -LiteralPath $tempPath -PathType Container) {
                Rename-Item -LiteralPath $tempPath -NewName $sourceName -ErrorAction SilentlyContinue
            }
            throw "mklink для старой базы вернул код $($mkBase.ExitCode)."
        }

        foreach ($row in $links) {
            $newTarget = Join-BaseAndRelative $target $row.Relative
            if (!(Test-Path -LiteralPath $newTarget -PathType Container)) {
                throw "После копирования не найден новый путь для ссылки: $newTarget"
            }
            Retarget-ReparseDirectoryLink $row.LinkPath $newTarget $row.OldTarget $Log
        }

        Remove-FolderAfterSuccessfulMove $tempPath $Log

        & $Log "Готово. База перенесена, старая база оставлена как junction-страховка, найденные ссылки переназначены на новую базу."
        Write-DetailLog "Готово. База перенесена и ссылки переназначены."
    } catch {
        throw $_
    }
}



function Get-ParentLevelReparseLinksPointingIntoBase([string]$BaseRaw, [scriptblock]$GuiLog = $null) {
    $base = Normalize-Path $BaseRaw
    $items = @()

    if ([string]::IsNullOrWhiteSpace($base)) { return @() }
    $parent = Split-Path -Parent $base
    if ([string]::IsNullOrWhiteSpace($parent) -or !(Test-Path -LiteralPath $parent -PathType Container)) { return @() }

    if ($GuiLog) { & $GuiLog "Ищу внешние ссылки рядом с базой: $parent" }
    Write-DetailLog "Ищу внешние ссылки рядом с базой: $parent"

    $baseLower = $base.ToLowerInvariant()
    $seen = @{}

    try {
        $entries = @(Get-ChildItem -LiteralPath $parent -Force -Directory -ErrorAction SilentlyContinue)
        foreach ($entry in $entries) {
            $entryName = ""
            try { $entryName = [string]$entry.FullName } catch { $entryName = [string]$entry }

            try {
                if ([string]::IsNullOrWhiteSpace($entryName)) { continue }

                $linkPath = Normalize-Path $entryName
                if ($linkPath.ToLowerInvariant() -eq $baseLower) { continue }

                $attrs = [System.IO.File]::GetAttributes($linkPath)
                if (($attrs -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) { continue }

                $targetText = [string](Get-ReparsePointTarget $linkPath)
                if ([string]::IsNullOrWhiteSpace($targetText)) { continue }

                foreach ($targetPartRaw in @($targetText -split ';')) {
                    try {
                        $targetPart = [string]$targetPartRaw
                        if ([string]::IsNullOrWhiteSpace($targetPart)) { continue }

                        $oldTarget = Normalize-ReparseTargetPath $targetPart
                        if ([string]::IsNullOrWhiteSpace($oldTarget)) { continue }
                        if (-not (Test-PathInside $oldTarget $base)) { continue }

                        $oldTargetLower = $oldTarget.ToLowerInvariant()
                        $relative = ""
                        if ($oldTargetLower -ne $baseLower) {
                            $relative = $oldTarget.Substring($base.Length).TrimStart('\')
                        }

                        $key = $linkPath.ToLowerInvariant()
                        if (-not $seen.ContainsKey($key)) {
                            $seen[$key] = $true
                            $items += [PSCustomObject]@{
                                LinkPath  = $linkPath
                                OldTarget = $oldTarget
                                Relative  = $relative
                                Root      = $parent
                                Kind      = "Sibling"
                            }
                            if ($GuiLog) { & $GuiLog "Найдена внешняя ссылка: $linkPath -> $oldTarget" }
                            Write-DetailLog "Найдена внешняя ссылка: $linkPath -> $oldTarget"
                        }
                    } catch {
                        if ($GuiLog) { & $GuiLog ("ПРЕДУПРЕЖДЕНИЕ: не удалось разобрать цель внешней ссылки {0}: {1}" -f $linkPath, $_.Exception.Message) }
                        Write-DetailLog ("ПРЕДУПРЕЖДЕНИЕ цели внешней ссылки {0}: {1}: {2}" -f $linkPath, $_.Exception.GetType().FullName, $_.Exception.Message)
                        continue
                    }
                }
            } catch {
                if ($GuiLog) { & $GuiLog ("ПРЕДУПРЕЖДЕНИЕ: не удалось проверить внешнюю ссылку {0}: {1}" -f $entryName, $_.Exception.Message) }
                Write-DetailLog ("ПРЕДУПРЕЖДЕНИЕ внешней ссылки {0}: {1}: {2}" -f $entryName, $_.Exception.GetType().FullName, $_.Exception.Message)
                continue
            }
        }
    } catch {
        if ($GuiLog) { & $GuiLog "ПРЕДУПРЕЖДЕНИЕ: не удалось просканировать соседние ссылки: $($_.Exception.Message)" }
        Write-DetailLog "ПРЕДУПРЕЖДЕНИЕ сканирования соседних ссылок: $($_.Exception.GetType().FullName): $($_.Exception.Message)"
    }

    return @($items)
}

function Validate-BaseWrapPlan([string]$SourceBaseRaw, [string]$TargetSubfolderRaw) {
    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]

    $source = Normalize-Path $SourceBaseRaw
    $target = Normalize-Path $TargetSubfolderRaw

    if ([string]::IsNullOrWhiteSpace($source)) { $errors.Add("Не указана текущая база.") }
    if ([string]::IsNullOrWhiteSpace($target)) { $errors.Add("Не указана итоговая подпапка базы.") }

    if ($errors.Count -eq 0) {
        if (!(Test-Path -LiteralPath $source -PathType Container)) {
            $errors.Add("Текущая база не существует: $source")
        }

        if (Test-Path -LiteralPath $source -PathType Container) {
            try {
                if (Is-ReparsePoint $source) {
                    $errors.Add("Текущая база является ссылкой/reparse point. Выберите реальную папку с данными, а не ссылку.")
                }
            } catch {
                $errors.Add("Не удалось проверить текущую базу: $($_.Exception.Message)")
            }
        }

        $sourceRootPath = [System.IO.Path]::GetPathRoot($source)
        if (-not [string]::IsNullOrWhiteSpace($sourceRootPath)) {
            if ((Normalize-Path $source).ToLowerInvariant() -eq (Normalize-Path $sourceRootPath).ToLowerInvariant()) {
                $errors.Add("Нельзя вкладывать корень диска целиком: $source")
            }
        }

        if ((Normalize-Path $source).ToLowerInvariant() -eq (Normalize-Path $target).ToLowerInvariant()) {
            $errors.Add("Текущая база и итоговая подпапка совпадают.")
        }

        if (-not (Test-PathInside $target $source)) {
            $errors.Add("Итоговая подпапка должна находиться внутри текущей базы. Пример: G:\C-Link -> G:\C-Link\Appdata")
        }

        $targetParent = Split-Path -Parent $target
        if ((Normalize-Path $targetParent).ToLowerInvariant() -ne $source.ToLowerInvariant()) {
            $errors.Add("Итоговая папка должна быть прямой подпапкой текущей базы, а не глубже. Пример: G:\C-Link\Appdata")
        }

        if (Test-Path -LiteralPath $target) {
            if (!(Test-Path -LiteralPath $target -PathType Container)) {
                $errors.Add("Итоговая подпапка уже существует, но это не папка: $target")
            } elseif (Test-DirectoryIsEmpty $target) {
                $warnings.Add("Итоговая подпапка уже существует, но она пустая. Она будет использована.")
            } else {
                $errors.Add("Итоговая подпапка уже существует и не пустая: $target. Чтобы не смешать данные после частичного запуска, сначала проверьте её содержимое вручную.")
            }
        }

        if (Test-Path -LiteralPath $source -PathType Container) {
            $targetLeaf = Split-Path -Leaf $target
            $movableCount = 0
            try {
                foreach ($entry in @(Get-ChildItem -LiteralPath $source -Force -ErrorAction Stop)) {
                    if ($entry.Name.ToLowerInvariant() -eq $targetLeaf.ToLowerInvariant()) { continue }
                    $movableCount++
                }
            } catch {
                $errors.Add("Не удалось проверить содержимое текущей базы: $($_.Exception.Message)")
            }

            if ($movableCount -eq 0) {
                $warnings.Add("В корне текущей базы нет элементов для перемещения. Можно использовать режим для повторного переназначения ссылок после частичного выполнения.")
            }
        }

        if ($target -match '^[A-Za-z]:\\') {
            $drive = $target.Substring(0,1)
            try {
                $vol = Get-Volume -DriveLetter $drive -ErrorAction Stop
                if ($vol.FileSystem -ne "NTFS") {
                    $warnings.Add("Целевой диск не NTFS ($($vol.FileSystem)). Junction-ссылки работают только на NTFS.")
                }
            } catch {
                $warnings.Add("Не удалось проверить файловую систему целевого диска. Для junction нужен NTFS.")
            }
        } else {
            $warnings.Add("Целевой путь не похож на обычный локальный путь вида G:\\Folder. Сетевые пути для junction не подходят.")
        }
    }

    return [PSCustomObject]@{
        Source   = $source
        Target   = $target
        Errors   = $errors
        Warnings = $warnings
    }
}

function Wrap-BaseIntoSubfolderAndRetargetLinks([string]$SourceBaseRaw, [string]$TargetSubfolderRaw, [scriptblock]$Log) {
    $plan = Validate-BaseWrapPlan $SourceBaseRaw $TargetSubfolderRaw
    foreach ($e in $plan.Errors) { & $Log "ОШИБКА: $e" }
    foreach ($w in $plan.Warnings) { & $Log "ПРЕДУПРЕЖДЕНИЕ: $w" }
    if ($plan.Errors.Count -gt 0) { throw "План содержит ошибки. Вложение базы отменено." }

    $source = $plan.Source
    $target = $plan.Target
    $targetLeaf = Split-Path -Leaf $target
    $sourceParent = Split-Path -Parent $source
    $sourceLeaf = Split-Path -Leaf $source
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $staging = Join-Path $sourceParent ($sourceLeaf + ".__wrap_moving_" + $timestamp)

    $script:CurrentDetailedLog = New-DetailedLogFile

    & $Log "Текущая база:        $source"
    & $Log "Итоговая подпапка:   $target"
    & $Log "Временная папка:     $staging"
    & $Log "Подробный лог:       $script:CurrentDetailedLog"
    & $Log "Ищу ссылки, которые ведут внутрь текущей базы..."

    Write-DetailLog "=== Folder Mover: wrap base into subfolder ==="
    Write-DetailLog "Текущая база: $source"
    Write-DetailLog "Итоговая подпапка: $target"
    Write-DetailLog "Временная папка: $staging"

    $links = @()
    $seenLinks = @{}

    try {
        Write-DetailLog "Сканирую AppData/Документы-ссылки."
        foreach ($row in @(Get-JunctionsPointingIntoBase $source 2000 $Log)) {
            try {
                if ($null -eq $row -or [string]::IsNullOrWhiteSpace([string]$row.LinkPath)) { continue }
                $key = (Normalize-Path ([string]$row.LinkPath)).ToLowerInvariant()
                if (-not $seenLinks.ContainsKey($key)) {
                    $seenLinks[$key] = $true
                    $links += $row
                }
            } catch {
                Write-DetailLog "ПРЕДУПРЕЖДЕНИЕ: не удалось добавить найденную AppData/Документы-ссылку: $($_.Exception.GetType().FullName): $($_.Exception.Message)"
            }
        }
        Write-DetailLog "Сканирую соседние внешние ссылки."
        foreach ($row in @(Get-ParentLevelReparseLinksPointingIntoBase $source $Log)) {
            try {
                if ($null -eq $row -or [string]::IsNullOrWhiteSpace([string]$row.LinkPath)) { continue }
                $key = (Normalize-Path ([string]$row.LinkPath)).ToLowerInvariant()
                if (-not $seenLinks.ContainsKey($key)) {
                    $seenLinks[$key] = $true
                    $links += $row
                }
            } catch {
                Write-DetailLog "ПРЕДУПРЕЖДЕНИЕ: не удалось добавить найденную внешнюю ссылку: $($_.Exception.GetType().FullName): $($_.Exception.Message)"
            }
        }
    } catch {
        Write-DetailLog "ОШИБКА поиска ссылок: $($_.Exception.GetType().FullName): $($_.Exception.Message)"
        if ($_.InvocationInfo) {
            Write-DetailLog ("Строка поиска ссылок: " + $_.InvocationInfo.ScriptLineNumber)
            Write-DetailLog ("Команда поиска ссылок: " + $_.InvocationInfo.Line)
        }
        throw
    }

    if ($links.Count -eq 0) {
        & $Log "ПРЕДУПРЕЖДЕНИЕ: не найдено ссылок, которые указывают внутрь текущей базы. Будет выполнено только перемещение содержимого в подпапку."
        Write-DetailLog "Ссылок для переназначения не найдено."
    } else {
        & $Log "Найдено ссылок для переназначения: $($links.Count)"
        Write-DetailLog "Найдено ссылок для переназначения: $($links.Count)"
        foreach ($row in $links | Select-Object -First 40) {
            $newTargetPreview = Join-BaseAndRelative $target $row.Relative
            & $Log "  $($row.LinkPath) -> $newTargetPreview"
            Write-DetailLog "Link preview: $($row.LinkPath) -> $newTargetPreview"
        }
        if ($links.Count -gt 40) { & $Log "  показаны первые 40 ссылок." }
    }

    try {
        if (Test-Path -LiteralPath $staging) {
            throw "Временная папка уже существует: $staging"
        }

        $targetExistedEmpty = $false
        if (Test-Path -LiteralPath $target -PathType Container) {
            if (Test-DirectoryIsEmpty $target) {
                $targetExistedEmpty = $true
            } else {
                throw "Итоговая подпапка уже существует и не пустая: $target"
            }
        }

        & $Log "Переименовываю текущую базу во временную папку..."
        Write-DetailLog "Rename-Item: $source -> $staging"
        Rename-Item -LiteralPath $source -NewName (Split-Path -Leaf $staging) -ErrorAction Stop

        & $Log "Создаю новую оболочку базы и итоговую подпапку..."
        Write-DetailLog "New-Item: $source"
        New-Item -ItemType Directory -Path $source -Force -ErrorAction Stop | Out-Null
        Write-DetailLog "New-Item: $target"
        New-Item -ItemType Directory -Path $target -Force -ErrorAction Stop | Out-Null

        $entries = @(Get-ChildItem -LiteralPath $staging -Force -ErrorAction Stop | Where-Object { $_.Name.ToLowerInvariant() -ne $targetLeaf.ToLowerInvariant() })
        if ($entries.Count -eq 0) {
            & $Log "Во временной базе нет элементов для перемещения. Перехожу к переназначению ссылок."
            Write-DetailLog "Во временной базе нет элементов для перемещения."
        } else {
            & $Log "Перемещаю элементы базы в подпапку. Это обычно быстро, потому что путь на том же диске."
            Write-DetailLog "Перемещаю элементов: $($entries.Count)"

            foreach ($entry in $entries) {
                $dest = Join-Path $target $entry.Name
                if (Test-Path -LiteralPath $dest) {
                    throw "В итоговой подпапке уже есть элемент с таким именем: $dest"
                }

                & $Log "Перемещаю: $($entry.FullName) -> $target"
                Write-DetailLog "Move-Item: $($entry.FullName) -> $target"
                Move-Item -LiteralPath $entry.FullName -Destination $target -Force -ErrorAction Stop
            }
        }

        if ($targetExistedEmpty) {
            $oldEmptyTarget = Join-Path $staging $targetLeaf
            if (Test-Path -LiteralPath $oldEmptyTarget -PathType Container) {
                try {
                    Remove-Item -LiteralPath $oldEmptyTarget -Force -ErrorAction Stop
                    Write-DetailLog "Удалена старая пустая подпапка из временной базы: $oldEmptyTarget"
                } catch {
                    Write-DetailLog "ПРЕДУПРЕЖДЕНИЕ: не удалось удалить старую пустую подпапку: $($_.Exception.Message)"
                }
            }
        }

        foreach ($row in $links) {
            $newTarget = Join-BaseAndRelative $target $row.Relative
            if (!(Test-Path -LiteralPath $newTarget -PathType Container)) {
                throw "После перемещения не найден новый путь для ссылки: $newTarget"
            }
            Retarget-ReparseDirectoryLink $row.LinkPath $newTarget $row.OldTarget $Log
        }

        try {
            if (Test-DirectoryIsEmpty $staging) {
                Remove-Item -LiteralPath $staging -Force -ErrorAction Stop
                Write-DetailLog "Удалена пустая временная папка: $staging"
            } else {
                & $Log "ПРЕДУПРЕЖДЕНИЕ: временная папка не пуста и оставлена для проверки: $staging"
                Write-DetailLog "Временная папка не пуста и оставлена: $staging"
            }
        } catch {
            & $Log "ПРЕДУПРЕЖДЕНИЕ: не удалось удалить временную папку: $($_.Exception.Message)"
            Write-DetailLog "ПРЕДУПРЕЖДЕНИЕ удаления временной папки: $($_.Exception.Message)"
        }

        & $Log "Готово. Содержимое базы вложено в подпапку, найденные ссылки переназначены."
        Write-DetailLog "Готово. База вложена в подпапку и ссылки переназначены."
    } catch {
        $msg = $_.Exception.Message
        Write-DetailLog "ОШИБКА режима вложения базы: $msg"
        if ($_.InvocationInfo) {
            Write-DetailLog ("Строка: " + $_.InvocationInfo.ScriptLineNumber)
            Write-DetailLog ("Команда: " + $_.InvocationInfo.Line)
        }

        # Минимальный откат только для ситуации, когда данные ещё не переносились:
        # если новая оболочка базы пуста, а staging ещё содержит исходные данные, возвращаем старое имя.
        try {
            if ((Test-Path -LiteralPath $staging -PathType Container) -and (Test-Path -LiteralPath $source -PathType Container)) {
                if (Test-DirectoryIsEmpty $source) {
                    Remove-Item -LiteralPath $source -Force -ErrorAction Stop
                    Rename-Item -LiteralPath $staging -NewName $sourceLeaf -ErrorAction Stop
                    Write-DetailLog "Выполнен откат: временная папка возвращена на место исходной базы."
                }
            }
        } catch {
            Write-DetailLog "ПРЕДУПРЕЖДЕНИЕ: автоматический откат не удался: $($_.Exception.Message)"
        }
        throw
    }
}

function Test-FilesLookDifferent([string]$APath, [string]$BPath) {
    try {
        if (!(Test-Path -LiteralPath $APath -PathType Leaf) -or !(Test-Path -LiteralPath $BPath -PathType Leaf)) { return $true }
        $a = Get-Item -LiteralPath $APath -Force -ErrorAction Stop
        $b = Get-Item -LiteralPath $BPath -Force -ErrorAction Stop
        if ($a.Length -ne $b.Length) { return $true }
        $delta = [Math]::Abs(($a.LastWriteTimeUtc - $b.LastWriteTimeUtc).TotalSeconds)
        if ($delta -gt 2) { return $true }
        return $false
    } catch {
        return $true
    }
}

function Get-MergeBackupPaths([string]$SourceRaw, [string]$TargetRaw, [string]$Timestamp) {
    $source = Normalize-Path $SourceRaw
    $target = Normalize-Path $TargetRaw

    $targetParent = Split-Path -Parent $target
    $targetLeaf = Split-Path -Leaf $target
    if ([string]::IsNullOrWhiteSpace($targetParent)) { $targetParent = [System.IO.Path]::GetPathRoot($target) }

    if (Test-PathInside $source $target) {
        $sourceBackup = Join-Path $targetParent ($targetLeaf + ".__nested_source_backup_" + $Timestamp)
    } else {
        $sourceParent = Split-Path -Parent $source
        $sourceLeaf = Split-Path -Leaf $source
        $sourceBackup = Join-Path $sourceParent ($sourceLeaf + ".__merged_backup_" + $Timestamp)
    }

    $conflictBackup = Join-Path $targetParent ($targetLeaf + ".__merge_conflicts_" + $Timestamp)

    return [PSCustomObject]@{
        SourceBackup   = Normalize-Path $sourceBackup
        ConflictBackup = Normalize-Path $conflictBackup
    }
}

function Validate-BaseMergePlan([string]$SourceBaseRaw, [string]$TargetBaseRaw) {
    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]

    $source = Normalize-Path $SourceBaseRaw
    $target = Normalize-Path $TargetBaseRaw

    if ([string]::IsNullOrWhiteSpace($source)) { $errors.Add("Не указана вложенная/лишняя база-источник.") }
    if ([string]::IsNullOrWhiteSpace($target)) { $errors.Add("Не указана итоговая база-приёмник.") }

    if ($errors.Count -eq 0) {
        if (!(Test-Path -LiteralPath $source -PathType Container)) {
            $errors.Add("Источник слияния не существует: $source")
        }
        if (!(Test-Path -LiteralPath $target -PathType Container)) {
            $errors.Add("Итоговая база должна уже существовать: $target")
        }
        if ((Normalize-Path $source).ToLowerInvariant() -eq (Normalize-Path $target).ToLowerInvariant()) {
            $errors.Add("Источник и итоговая база совпадают.")
        }

        $sourceRootPath = [System.IO.Path]::GetPathRoot($source)
        if (-not [string]::IsNullOrWhiteSpace($sourceRootPath)) {
            if ((Normalize-Path $source).ToLowerInvariant() -eq (Normalize-Path $sourceRootPath).ToLowerInvariant()) {
                $errors.Add("Нельзя сливать корень диска целиком: $source")
            }
        }

        if (Test-PathInside $target $source) {
            $errors.Add("Итоговая база не может находиться внутри источника. Это создаст рекурсию.")
        }

        if (Test-Path -LiteralPath $source -PathType Container) {
            try {
                if (Is-ReparsePoint $source) {
                    $errors.Add("Источник слияния является ссылкой/reparse point. Выберите реальную папку с данными.")
                }
            } catch {
                $errors.Add("Не удалось проверить источник: $($_.Exception.Message)")
            }
        }
        if (Test-Path -LiteralPath $target -PathType Container) {
            try {
                if (Is-ReparsePoint $target) {
                    $errors.Add("Итоговая база является ссылкой/reparse point. Выберите реальную папку с данными.")
                }
            } catch {
                $errors.Add("Не удалось проверить итоговую базу: $($_.Exception.Message)")
            }
        }

        try {
            $nestedLinks = @(Get-NestedReparsePointDirectories $source 25)
            if ($nestedLinks.Count -gt 0) {
                $warnings.Add("Внутри источника есть вложенные ссылки/reparse point. Слияние не будет заходить внутрь таких папок.")
                foreach ($link in $nestedLinks) {
                    $warnings.Add("  вложенная ссылка: $(Get-ReparsePointDisplayLine $link)")
                }
            }
        } catch {
            $warnings.Add("Не удалось проверить вложенные ссылки/reparse point: $($_.Exception.Message)")
        }

        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $backupPaths = Get-MergeBackupPaths $source $target $timestamp
        if (Test-Path -LiteralPath $backupPaths.SourceBackup) {
            $errors.Add("Папка резервной копии источника уже существует: $($backupPaths.SourceBackup)")
        }
        if (Test-Path -LiteralPath $backupPaths.ConflictBackup) {
            $errors.Add("Папка резервной копии конфликтов уже существует: $($backupPaths.ConflictBackup)")
        }

        if (Test-PathInside $source $target) {
            $warnings.Add("Источник находится внутри итоговой базы. После слияния он будет вынесен в резервную копию рядом с итоговой базой, а не превращён в junction, чтобы не получить самоссылку.")
        }
    }

    return [PSCustomObject]@{
        Source   = $source
        Target   = $target
        Errors   = $errors
        Warnings = $warnings
    }
}


function Get-UniqueBackupPath([string]$BackupPathRaw) {
    $backupPath = Normalize-Path $BackupPathRaw
    if (!(Test-Path -LiteralPath $backupPath)) { return $backupPath }

    $i = 1
    while ($true) {
        $candidate = "$backupPath.__conflict_$i"
        if (!(Test-Path -LiteralPath $candidate)) { return $candidate }
        $i++
    }
}

function Backup-ExistingPathToConflict([string]$ExistingPathRaw, [string]$ConflictBackupRoot, [string]$RelativePath, [scriptblock]$Log) {
    $existing = Normalize-Path $ExistingPathRaw
    if (!(Test-Path -LiteralPath $existing)) { return $null }

    $backupPath = Join-BaseAndRelative $ConflictBackupRoot $RelativePath
    $backupPath = Get-UniqueBackupPath $backupPath
    $backupParent = Split-Path -Parent $backupPath
    if (!(Test-Path -LiteralPath $backupParent -PathType Container)) {
        New-Item -ItemType Directory -Path $backupParent -Force -ErrorAction Stop | Out-Null
    }

    if ($Log) { & $Log "Сохраняю конфликт в резерв: $existing -> $backupPath" }
    Move-Item -LiteralPath $existing -Destination $backupPath -Force -ErrorAction Stop
    return $backupPath
}

function Copy-FileSourceWinsWithBackup([string]$SourceFile, [string]$TargetFile, [string]$ConflictBackupRoot, [string]$RelativePath, [scriptblock]$Log) {
    $targetParent = Split-Path -Parent $TargetFile
    if (!(Test-Path -LiteralPath $targetParent -PathType Container)) {
        New-Item -ItemType Directory -Path $targetParent -Force -ErrorAction Stop | Out-Null
    }

    if (Test-Path -LiteralPath $TargetFile -PathType Leaf) {
        if (Test-FilesLookDifferent $SourceFile $TargetFile) {
            $backupFile = Join-BaseAndRelative $ConflictBackupRoot $RelativePath
            $backupFile = Get-UniqueBackupPath $backupFile
            $backupParent = Split-Path -Parent $backupFile
            if (!(Test-Path -LiteralPath $backupParent -PathType Container)) {
                New-Item -ItemType Directory -Path $backupParent -Force -ErrorAction Stop | Out-Null
            }
            Copy-Item -LiteralPath $TargetFile -Destination $backupFile -Force -ErrorAction Stop
        }
    } elseif (Test-Path -LiteralPath $TargetFile -PathType Container) {
        # В грязной AppData может быть конфликт типов: в одной базе файл,
        # в другой базе папка с тем же путём. Не останавливаем слияние:
        # старая папка итоговой базы уходит в резерв конфликтов, файл источника становится активным.
        Backup-ExistingPathToConflict $TargetFile $ConflictBackupRoot $RelativePath $Log | Out-Null
    }

    Copy-Item -LiteralPath $SourceFile -Destination $TargetFile -Force -ErrorAction Stop
}

function Merge-DirectorySourceWinsWithBackup([string]$SourceRaw, [string]$TargetRaw, [string]$ConflictBackupRoot, [scriptblock]$Log) {
    $source = Normalize-Path $SourceRaw
    $target = Normalize-Path $TargetRaw
    $sourceLen = $source.Length

    $copied = 0
    $dirs = 0
    $conflicts = 0
    $skippedReparse = 0
    $errors = 0
    $lastUi = Get-Date

    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($source)

    while ($stack.Count -gt 0) {
        $current = $stack.Pop()
        $dirs++

        $relativeDir = ""
        if ((Normalize-Path $current).ToLowerInvariant() -ne $source.ToLowerInvariant()) {
            $relativeDir = (Normalize-Path $current).Substring($sourceLen).TrimStart('\')
        }
        $destDir = Join-BaseAndRelative $target $relativeDir

        if ((Normalize-Path $destDir).ToLowerInvariant() -eq $source.ToLowerInvariant() -or (Test-PathInside $destDir $source)) {
            throw "Слияние остановлено: относительный путь '$relativeDir' ведёт обратно внутрь источника ($destDir). Вероятно, есть лишняя вложенная папка с тем же именем."
        }

        if (Test-Path -LiteralPath $destDir -PathType Leaf) {
            # Конфликт типов: в источнике это папка, а в итоговой базе файл.
            # Файл уходит в резерв конфликтов, после этого создаётся папка.
            Backup-ExistingPathToConflict $destDir $ConflictBackupRoot $relativeDir $Log | Out-Null
            $conflicts++
        }
        if (!(Test-Path -LiteralPath $destDir -PathType Container)) {
            New-Item -ItemType Directory -Path $destDir -Force -ErrorAction Stop | Out-Null
        }

        $files = @()
        try {
            $files = [System.IO.Directory]::GetFiles($current)
        } catch {
            $errors++
            & $Log "ОШИБКА чтения файлов: $current — $($_.Exception.Message)"
            continue
        }

        foreach ($file in $files) {
            try {
                $attrs = [System.IO.File]::GetAttributes($file)
                if (($attrs -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                    $skippedReparse++
                    continue
                }

                $relFile = (Normalize-Path $file).Substring($sourceLen).TrimStart('\')
                $destFile = Join-BaseAndRelative $target $relFile
                $hadDifferentTarget = $false
                if (Test-Path -LiteralPath $destFile -PathType Leaf) {
                    $hadDifferentTarget = Test-FilesLookDifferent $file $destFile
                }
                Copy-FileSourceWinsWithBackup $file $destFile $ConflictBackupRoot $relFile $Log
                $copied++
                if ($hadDifferentTarget) { $conflicts++ }

                if (($copied % 500) -eq 0) {
                    & $Log "Слияние: файлов скопировано $copied, конфликтов сохранено $conflicts, папок просмотрено $dirs, пропущено ссылок $skippedReparse."
                    Pump-GuiIfPossible
                } elseif (((Get-Date) - $lastUi).TotalSeconds -ge 2) {
                    Pump-GuiIfPossible
                    $lastUi = Get-Date
                }
            } catch {
                $errors++
                & $Log "ОШИБКА копирования файла: $file — $($_.Exception.Message)"
                throw
            }
        }

        $children = @()
        try {
            $children = [System.IO.Directory]::GetDirectories($current)
        } catch {
            $errors++
            & $Log "ОШИБКА чтения подпапок: $current — $($_.Exception.Message)"
            continue
        }

        foreach ($child in $children) {
            try {
                $attrs = [System.IO.File]::GetAttributes($child)
                if (($attrs -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                    $skippedReparse++
                    & $Log "Пропущена вложенная ссылка: $child"
                    continue
                }
                $stack.Push($child)
            } catch {
                $errors++
                & $Log "ОШИБКА проверки подпапки: $child — $($_.Exception.Message)"
            }
        }
    }

    return [PSCustomObject]@{
        CopiedFiles     = $copied
        Directories     = $dirs
        ConflictsBacked = $conflicts
        SkippedReparse  = $skippedReparse
        Errors          = $errors
    }
}

function Merge-BaseIntoExistingAndRetargetLinks([string]$SourceBaseRaw, [string]$TargetBaseRaw, [scriptblock]$Log) {
    $plan = Validate-BaseMergePlan $SourceBaseRaw $TargetBaseRaw
    foreach ($e in $plan.Errors) { & $Log "ОШИБКА: $e" }
    foreach ($w in $plan.Warnings) { & $Log "ПРЕДУПРЕЖДЕНИЕ: $w" }
    if ($plan.Errors.Count -gt 0) { throw "План содержит ошибки. Слияние баз отменено." }

    $source = $plan.Source
    $target = $plan.Target
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $backupPaths = Get-MergeBackupPaths $source $target $timestamp
    $sourceBackup = $backupPaths.SourceBackup
    $conflictBackup = $backupPaths.ConflictBackup

    $script:CurrentDetailedLog = New-DetailedLogFile

    & $Log "Источник слияния: $source"
    & $Log "Итоговая база:     $target"
    & $Log "Резерв источника:  $sourceBackup"
    & $Log "Конфликты старой итоговой базы будут сохранены в: $conflictBackup"
    & $Log "Подробный лог:     $script:CurrentDetailedLog"
    & $Log "Ищу AppData/Документы-ссылки, которые ведут внутрь источника слияния..."

    Write-DetailLog "=== Folder Mover: base merge ==="
    Write-DetailLog "Источник слияния: $source"
    Write-DetailLog "Итоговая база: $target"
    Write-DetailLog "Резерв источника: $sourceBackup"
    Write-DetailLog "Резерв конфликтов: $conflictBackup"

    $links = @(Get-JunctionsPointingIntoBase $source 3000 $Log)
    # В Windows PowerShell 5.1 Generic.List иногда возвращается как один объект.
    # Принудительно оставляем только строки с нужными свойствами.
    $links = @($links | Where-Object { $_ -and ($_.PSObject.Properties.Name -contains "LinkPath") -and ($_.PSObject.Properties.Name -contains "Relative") })
    if ($links.Count -eq 0) {
        & $Log "ПРЕДУПРЕЖДЕНИЕ: не найдено AppData/Документы-ссылок, которые указывают внутрь источника. Ссылки переназначены не будут."
    } else {
        & $Log "Найдено ссылок для переназначения: $($links.Count)"
        foreach ($row in $links | Select-Object -First 30) {
            $newTargetPreview = Join-BaseAndRelative $target $row.Relative
            & $Log "  $($row.LinkPath) -> $newTargetPreview"
        }
        if ($links.Count -gt 30) { & $Log "  показаны первые 30 ссылок." }
    }

    & $Log "Создаю/проверяю папку конфликтов: $conflictBackup"
    if (!(Test-Path -LiteralPath $conflictBackup -PathType Container)) {
        New-Item -ItemType Directory -Path $conflictBackup -Force -ErrorAction Stop | Out-Null
    }

    & $Log "Начинаю слияние. При совпадении путей выигрывает источник; старая версия из итоговой базы сохраняется в папку конфликтов."
    $summary = Merge-DirectorySourceWinsWithBackup $source $target $conflictBackup $Log
    & $Log "Слияние файлов завершено: скопировано $($summary.CopiedFiles), конфликтов сохранено $($summary.ConflictsBacked), папок просмотрено $($summary.Directories), пропущено ссылок $($summary.SkippedReparse)."
    Write-DetailLog "Слияние файлов завершено: скопировано $($summary.CopiedFiles), конфликтов сохранено $($summary.ConflictsBacked), папок просмотрено $($summary.Directories), пропущено ссылок $($summary.SkippedReparse)."

    foreach ($row in $links) {
        $newTarget = Join-BaseAndRelative $target $row.Relative
        if (!(Test-Path -LiteralPath $newTarget -PathType Container)) {
            throw "После слияния не найден новый путь для ссылки: $newTarget"
        }
        Retarget-ReparseDirectoryLink $row.LinkPath $newTarget $row.OldTarget $Log
    }

    & $Log "Выношу старый вложенный источник в резервную копию: $sourceBackup"
    if (Test-Path -LiteralPath $sourceBackup) {
        throw "Резервная папка уже существует: $sourceBackup"
    }
    Move-Item -LiteralPath $source -Destination $sourceBackup -ErrorAction Stop

    & $Log "Готово. Активные ссылки переназначены на итоговую базу. Старый источник не удалён, а вынесен в резерв."
    & $Log "После проверки работы программ можно удалить резерв источника и резерв конфликтов вручную."
    Write-DetailLog "Готово. Базы слиты, ссылки переназначены, источник вынесен в резерв."
}

# ---------- GUI ----------

$form = New-Object System.Windows.Forms.Form
$form.Text = "Folder Mover"
$form.Size = New-Object System.Drawing.Size(1030, 710)
$form.StartPosition = "CenterScreen"
$form.MinimumSize = New-Object System.Drawing.Size(980, 640)

$font = New-Object System.Drawing.Font("Segoe UI", 9)
$form.Font = $font

$lblInfo = New-Object System.Windows.Forms.Label
$lblInfo.Text = "Переносит выбранную локальную папку в новое место и создаёт NTFS junction-ссылку. Режим Переезд базы переносит уже вынесенную базу, например D:\Appdata -> E:\Appdata, и переназначает найденные ссылки. Слияние объединяет базы, например D:\Appdata\Appdata -> D:\Appdata."
$lblInfo.Location = New-Object System.Drawing.Point(12, 12)
$lblInfo.Size = New-Object System.Drawing.Size(980, 42)
$form.Controls.Add($lblInfo)

$lblSource = New-Object System.Windows.Forms.Label
$lblSource.Text = "Что переносим:"
$lblSource.Location = New-Object System.Drawing.Point(12, 64)
$lblSource.Size = New-Object System.Drawing.Size(820, 20)
$form.Controls.Add($lblSource)

$txtSource = New-Object System.Windows.Forms.TextBox
$txtSource.Location = New-Object System.Drawing.Point(12, 86)
$txtSource.Size = New-Object System.Drawing.Size(855, 24)
$txtSource.Anchor = "Top,Left,Right"
$form.Controls.Add($txtSource)

$btnSource = New-Object System.Windows.Forms.Button
$btnSource.Text = "Выбрать"
$btnSource.Location = New-Object System.Drawing.Point(875, 84)
$btnSource.Size = New-Object System.Drawing.Size(95, 28)
$btnSource.Anchor = "Top,Right"
$form.Controls.Add($btnSource)

$lblSourceHint = New-Object System.Windows.Forms.Label
$lblSourceHint.Text = "Обычная папка, база или источник слияния. Быстрые кнопки ниже только подставляют путь."
$lblSourceHint.Location = New-Object System.Drawing.Point(12, 114)
$lblSourceHint.Size = New-Object System.Drawing.Size(980, 18)
$form.Controls.Add($lblSourceHint)

$lblTarget = New-Object System.Windows.Forms.Label
$lblTarget.Text = "Куда переносим:"
$lblTarget.Location = New-Object System.Drawing.Point(12, 134)
$lblTarget.Size = New-Object System.Drawing.Size(820, 20)
$form.Controls.Add($lblTarget)

$txtTarget = New-Object System.Windows.Forms.TextBox
$txtTarget.Location = New-Object System.Drawing.Point(12, 156)
$txtTarget.Size = New-Object System.Drawing.Size(855, 24)
$txtTarget.Anchor = "Top,Left,Right"
$form.Controls.Add($txtTarget)

$btnTarget = New-Object System.Windows.Forms.Button
$btnTarget.Text = "База"
$btnTarget.Location = New-Object System.Drawing.Point(875, 154)
$btnTarget.Size = New-Object System.Drawing.Size(95, 28)
$btnTarget.Anchor = "Top,Right"
$form.Controls.Add($btnTarget)

$lblTargetHint = New-Object System.Windows.Forms.Label
$lblTargetHint.Text = "Папка назначения или итоговая база. Для обычного переноса имя исходной папки добавляется автоматически, если его нет в конце пути."
$lblTargetHint.Location = New-Object System.Drawing.Point(12, 184)
$lblTargetHint.Size = New-Object System.Drawing.Size(980, 18)
$form.Controls.Add($lblTargetHint)

$lblExample = New-Object System.Windows.Forms.Label
$lblExample.Text = "Пример: обычный перенос, переезд базы или слияние используют эти два пути как указано. Автодобавление подпапок отключено."
$lblExample.Location = New-Object System.Drawing.Point(12, 210)
$lblExample.Size = New-Object System.Drawing.Size(980, 20)
$form.Controls.Add($lblExample)

$chkClosed = New-Object System.Windows.Forms.CheckBox
$chkClosed.Text = "Я закрыл программу/игру, которая использует эту папку"
$chkClosed.Location = New-Object System.Drawing.Point(12, 234)
$chkClosed.Size = New-Object System.Drawing.Size(820, 24)
$form.Controls.Add($chkClosed)

$btnCheck = New-Object System.Windows.Forms.Button
$btnCheck.Text = "Проверить"
$btnCheck.Location = New-Object System.Drawing.Point(12, 266)
$btnCheck.Size = New-Object System.Drawing.Size(230, 32)
$form.Controls.Add($btnCheck)

$btnLocks = New-Object System.Windows.Forms.Button
$btnLocks.Text = "Занятость"
$btnLocks.Location = New-Object System.Drawing.Point(132, 266)
$btnLocks.Size = New-Object System.Drawing.Size(110, 32)
$form.Controls.Add($btnLocks)
$btnLocks.Visible = $false
# Проверка занятости объединена с кнопкой "Проверить".

$btnSizes = New-Object System.Windows.Forms.Button
$btnSizes.Text = "Размеры"
$btnSizes.Location = New-Object System.Drawing.Point(252, 266)
$btnSizes.Size = New-Object System.Drawing.Size(110, 32)
$form.Controls.Add($btnSizes)

$btnMove = New-Object System.Windows.Forms.Button
$btnMove.Text = "Перенести"
$btnMove.Location = New-Object System.Drawing.Point(372, 266)
$btnMove.Size = New-Object System.Drawing.Size(120, 32)
$form.Controls.Add($btnMove)

$btnMoveBase = New-Object System.Windows.Forms.Button
$btnMoveBase.Text = "Переезд базы"
$btnMoveBase.Location = New-Object System.Drawing.Point(502, 266)
$btnMoveBase.Size = New-Object System.Drawing.Size(130, 32)
$form.Controls.Add($btnMoveBase)

$btnMergeBase = New-Object System.Windows.Forms.Button
$btnMergeBase.Text = "Слить базы"
$btnMergeBase.Location = New-Object System.Drawing.Point(642, 266)
$btnMergeBase.Size = New-Object System.Drawing.Size(120, 32)
$form.Controls.Add($btnMergeBase)

$btnWrapBase = New-Object System.Windows.Forms.Button
$btnWrapBase.Text = "В подпапку"
$btnWrapBase.Location = New-Object System.Drawing.Point(772, 266)
$btnWrapBase.Size = New-Object System.Drawing.Size(120, 32)
$btnWrapBase.Visible = $false
# Отдельная кнопка скрыта: этот сценарий теперь автоматически обрабатывает кнопка "Переезд базы".
# $form.Controls.Add($btnWrapBase)

$btnQuickAppData = New-Object System.Windows.Forms.Button
$btnQuickAppData.Text = "AppData"
$btnQuickAppData.Location = New-Object System.Drawing.Point(12, 304)
$btnQuickAppData.Size = New-Object System.Drawing.Size(90, 32)
$form.Controls.Add($btnQuickAppData)

$btnQuickDocuments = New-Object System.Windows.Forms.Button
$btnQuickDocuments.Text = "Документы"
$btnQuickDocuments.Location = New-Object System.Drawing.Point(112, 304)
$btnQuickDocuments.Size = New-Object System.Drawing.Size(110, 32)
$form.Controls.Add($btnQuickDocuments)

$btnOpenLogs = New-Object System.Windows.Forms.Button
$btnOpenLogs.Text = "Логи"
$btnOpenLogs.Location = New-Object System.Drawing.Point(232, 304)
$btnOpenLogs.Size = New-Object System.Drawing.Size(75, 32)
$form.Controls.Add($btnOpenLogs)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(12, 346)
$txtLog.Size = New-Object System.Drawing.Size(988, 312)
$txtLog.Multiline = $true
$txtLog.ScrollBars = "Vertical"
$txtLog.ReadOnly = $true
$txtLog.Anchor = "Top,Bottom,Left,Right"
$form.Controls.Add($txtLog)

$log = {
    param([string]$msg)
    $txtLog.AppendText(("[" + (Get-Date -Format "HH:mm:ss") + "] " + $msg + "`r`n"))
    $txtLog.SelectionStart = $txtLog.TextLength
    $txtLog.ScrollToCaret()
    Pump-GuiIfPossible
}

$pickFolder = {
    param([string]$Description, [string]$InitialPath)
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = $Description
    $dlg.ShowNewFolderButton = $true
    if ($InitialPath -and (Test-Path -LiteralPath $InitialPath -PathType Container)) {
        $dlg.SelectedPath = $InitialPath
    }
    if ($dlg.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        return $dlg.SelectedPath
    }
    return $null
}

function Refresh-TargetFromBaseIfPossible {
    # v10: автодобавление относительного пути отключено.
    # Источник больше не меняет строку новой папки/базы.
    return
}

$btnSource.Add_Click({
    $selected = & $pickFolder "Выберите исходную папку" $env:USERPROFILE
    if ($selected) {
        $txtSource.Text = $selected
    }
})

$btnTarget.Add_Click({
    $initial = ""
    if ($txtTarget.Text) {
        try {
            $targetNorm = Normalize-Path $txtTarget.Text
            while ($targetNorm -and !(Test-Path -LiteralPath $targetNorm -PathType Container)) {
                $targetNorm = Split-Path -Parent $targetNorm
            }
            if ($targetNorm -and (Test-Path -LiteralPath $targetNorm -PathType Container)) {
                $initial = $targetNorm
            }
        } catch {}
    }

    $selected = & $pickFolder "Выберите новую папку / итоговую базу. Путь будет вставлен как есть, без добавления AppData или имени исходной папки." $initial
    if ($selected) {
        $txtTarget.Text = Normalize-Path $selected
    }
})

function Invoke-CheckAndLockReport {
    $txtLog.Clear()
    try {
        if ($txtSource.Text) {
            $info = Get-RelativePathAfterKnownRoot $txtSource.Text
            if ($info) {
                if (-not [string]::IsNullOrWhiteSpace($info.RootPath)) {
                    & $log "Быстрый корень: $($info.RootName) ($($info.RootPath))"
                    & $log "Относительный путь: $($info.Relative)"
                } else {
                    & $log "Обычная папка. Автодобавление в поле новой папки отключено."
                }
            }
        }

        if (Test-TargetIsDirectSubfolderOfSource $txtSource.Text $txtTarget.Text) {
            $plan = Validate-BaseWrapPlan $txtSource.Text $txtTarget.Text
            & $log "Проверка плана: Переезд базы в подпапку"
        } else {
            $plan = Validate-MovePlan $txtSource.Text $txtTarget.Text
            & $log "Проверка плана:"
        }
        & $log "Исходная папка: $($plan.Source)"
        & $log "Новая папка:    $($plan.Target)"
        foreach ($w in $plan.Warnings) { & $log "ПРЕДУПРЕЖДЕНИЕ: $w" }
        foreach ($e in $plan.Errors) { & $log "ОШИБКА: $e" }

        try {
            if (-not [string]::IsNullOrWhiteSpace($plan.Source) -and (Test-Path -LiteralPath $plan.Source -PathType Container) -and -not (Is-ReparsePoint $plan.Source)) {
                $baseLinks = @(Get-JunctionsPointingIntoBase $plan.Source 50 $null)
                if ($baseLinks.Count -gt 0) {
                    & $log "Найдено ссылок AppData/Документы, которые указывают внутрь исходной папки: $($baseLinks.Count). Для переноса такой базы используйте кнопку 'Переезд базы'."
                }
            }
        } catch {}

        if (-not [string]::IsNullOrWhiteSpace($plan.Source) -and (Test-Path -LiteralPath $plan.Source -PathType Container)) {
            & $log "Проверка занятости:"
            $lockers = @(Get-LockingProcessesForFolder $plan.Source $log)
            Save-LockCheckCache $plan.Source $lockers
            Log-LockingProcesses $lockers $log
            if ($script:LastLockCheckHadErrors) {
                & $log "Проверка занятости завершена с предупреждением. Если программу/игру закрыли вручную, можно продолжать."
            }
        } else {
            & $log "Проверка занятости пропущена: исходная папка не выбрана или не существует."
        }

        if ($plan.Errors.Count -eq 0) {
            & $log "Проверка завершена. Ошибок плана не найдено. Можно переносить."
        } else {
            & $log "Проверка завершена. Исправьте ошибки плана перед переносом."
        }
    } catch {
        & $log "ОШИБКА: $($_.Exception.Message)"
    }
}

$btnCheck.Add_Click({
    $btnCheck.Enabled = $false
    $btnLocks.Enabled = $false
    try {
        Invoke-CheckAndLockReport
    } finally {
        $btnCheck.Enabled = $true
        $btnLocks.Enabled = $true
    }
})

$btnLocks.Add_Click({
    if ([string]::IsNullOrWhiteSpace($txtSource.Text) -or !(Test-Path -LiteralPath (Normalize-Path $txtSource.Text) -PathType Container)) {
        [System.Windows.Forms.MessageBox]::Show(
            "Сначала выберите существующую исходную папку.",
            "Нет исходной папки",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return
    }

    $btnLocks.Enabled = $false
    try {
        $lockers = @(Get-LockingProcessesForFolder $txtSource.Text $log)
        Log-LockingProcesses $lockers $log

        if ($lockers.Count -gt 0) {
            $listText = Format-LockingProcessesText $lockers 16
            [System.Windows.Forms.MessageBox]::Show(
                "Найдены приложения, которые держат файлы:`r`n`r`n$listText",
                "Папка используется",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
        } else {
            [System.Windows.Forms.MessageBox]::Show(
                "Блокирующих приложений не найдено.",
                "Папка свободна",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
        }
    } catch {
        & $log "ОШИБКА проверки занятости: $($_.Exception.Message)"
    } finally {
        $btnLocks.Enabled = $true
    }
})


function Show-SizeSelectionWindow([object[]]$Rows, [string]$RootPath) {
    $sizeForm = New-Object System.Windows.Forms.Form
    $sizeForm.Text = "Размеры подпапок: $RootPath"
    $sizeForm.Size = New-Object System.Drawing.Size(980, 620)
    $sizeForm.StartPosition = "CenterParent"
    $sizeForm.MinimumSize = New-Object System.Drawing.Size(850, 480)
    $sizeForm.Font = $font

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "Сортировка по размеру по убыванию. Двойной щелчок или кнопка выбора подставит папку как исходную. Ссылки/junction не раскрываются и не считаются как реальный размер цели."
    $lbl.Location = New-Object System.Drawing.Point(12, 12)
    $lbl.Size = New-Object System.Drawing.Size(940, 36)
    $sizeForm.Controls.Add($lbl)

    $list = New-Object System.Windows.Forms.ListView
    $list.Location = New-Object System.Drawing.Point(12, 54)
    $list.Size = New-Object System.Drawing.Size(940, 455)
    $list.Anchor = "Top,Bottom,Left,Right"
    $list.View = [System.Windows.Forms.View]::Details
    $list.FullRowSelect = $true
    $list.GridLines = $true
    $list.HideSelection = $false
    [void]$list.Columns.Add("Размер", 100)
    [void]$list.Columns.Add("Имя", 190)
    [void]$list.Columns.Add("Тип", 210)
    [void]$list.Columns.Add("Файлы", 80)
    [void]$list.Columns.Add("Путь", 330)

    foreach ($row in $Rows) {
        $item = New-Object System.Windows.Forms.ListViewItem($row.SizeText)
        [void]$item.SubItems.Add($row.Name)
        [void]$item.SubItems.Add($row.TypeText)
        [void]$item.SubItems.Add([string]$row.Files)
        [void]$item.SubItems.Add($row.Path)
        $item.Tag = $row
        [void]$list.Items.Add($item)
    }
    $sizeForm.Controls.Add($list)

    $btnUse = New-Object System.Windows.Forms.Button
    $btnUse.Text = "Выбрать как исходную"
    $btnUse.Location = New-Object System.Drawing.Point(12, 522)
    $btnUse.Size = New-Object System.Drawing.Size(170, 32)
    $btnUse.Anchor = "Bottom,Left"
    $sizeForm.Controls.Add($btnUse)

    $btnOpen = New-Object System.Windows.Forms.Button
    $btnOpen.Text = "Открыть"
    $btnOpen.Location = New-Object System.Drawing.Point(194, 522)
    $btnOpen.Size = New-Object System.Drawing.Size(100, 32)
    $btnOpen.Anchor = "Bottom,Left"
    $sizeForm.Controls.Add($btnOpen)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Закрыть"
    $btnClose.Location = New-Object System.Drawing.Point(852, 522)
    $btnClose.Size = New-Object System.Drawing.Size(100, 32)
    $btnClose.Anchor = "Bottom,Right"
    $sizeForm.Controls.Add($btnClose)

    $useSelected = {
        if ($list.SelectedItems.Count -eq 0) { return }
        $row = $list.SelectedItems[0].Tag
        $txtSource.Text = $row.Path
        $sizeForm.Close()
    }

    $btnUse.Add_Click($useSelected)
    $list.Add_DoubleClick($useSelected)
    $btnOpen.Add_Click({
        if ($list.SelectedItems.Count -eq 0) { return }
        $row = $list.SelectedItems[0].Tag
        Start-Process explorer.exe $row.Path
    })
    $btnClose.Add_Click({ $sizeForm.Close() })

    [void]$sizeForm.ShowDialog($form)
}

$btnSizes.Add_Click({
    $root = ""
    try {
        if (-not [string]::IsNullOrWhiteSpace($txtSource.Text) -and (Test-Path -LiteralPath (Normalize-Path $txtSource.Text) -PathType Container)) {
            $root = Normalize-Path $txtSource.Text
        } else {
            $root = Normalize-Path $env:USERPROFILE
        }
    } catch {
        $root = Normalize-Path $env:USERPROFILE
    }

    $btnSizes.Enabled = $false
    try {
        $txtLog.Clear()
        & $log "Сортирую подпапки по размеру. Для больших папок это может занять время."
        $rows = @(Get-SubfolderSizeRows $root $log)

        if ($rows.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show(
                "В выбранной папке нет подпапок для сортировки.",
                "Нет подпапок",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
            return
        }

        & $log "Готово. Найдено подпапок: $($rows.Count). Открываю окно сортировки."
        Show-SizeSelectionWindow $rows $root
    } catch {
        & $log "ОШИБКА сортировки по размеру: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show(
            "Не удалось отсортировать папки по размеру:`r`n$($_.Exception.Message)",
            "Ошибка",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    } finally {
        $btnSizes.Enabled = $true
    }
})

$btnMove.Add_Click({
    if (-not $chkClosed.Checked) {
        [System.Windows.Forms.MessageBox]::Show(
            "Сначала закройте программу/игру, которая использует эту папку, и поставьте галочку.",
            "Папка может быть занята",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return
    }

    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "Будет выполнено:`r`n`r`n1. Поле 'Куда переносим' трактуется как папка назначения.`r`n2. Если путь не заканчивается именем исходной папки, программа сама создаст внутри него папку с исходным именем.`r`n3. Перед переносом программа проверит, какие приложения держат файлы.`r`n4. Исходная папка будет временно переименована.`r`n5. Данные будут скопированы через robocopy с подробным выводом в консоль.`r`n6. На старом пути будет создана junction-ссылка.`r`n7. Временная исходная копия будет удалена после успешного создания ссылки.`r`n`r`nПродолжить?",
        "Подтверждение переноса",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )

    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    $btnMove.Enabled = $false
    $btnMoveBase.Enabled = $false
    $btnMergeBase.Enabled = $false
    $btnWrapBase.Enabled = $false
    $btnCheck.Enabled = $false
    $btnLocks.Enabled = $false
    $btnSizes.Enabled = $false

    try {
        $plan = Validate-MovePlan $txtSource.Text $txtTarget.Text
        foreach ($e in $plan.Errors) { & $log "ОШИБКА: $e" }
        foreach ($w in $plan.Warnings) { & $log "ПРЕДУПРЕЖДЕНИЕ: $w" }
        if ($plan.Errors.Count -gt 0) { throw "План содержит ошибки. Перенос отменён." }

        $lockPath = $txtSource.Text
        if ($plan.RepairMode -and -not [string]::IsNullOrWhiteSpace($plan.CurrentTarget)) {
            $lockPath = $plan.CurrentTarget
        }

        $canContinue = Resolve-LockingProcessesBeforeMove $lockPath $log $form
        if (-not $canContinue) {
            return
        }

        Move-AppDataFolderAndLink $txtSource.Text $txtTarget.Text $log

        $doneMessage = "Перенос завершён. Старый путь теперь является ссылкой на новую папку."
        if ($plan.RepairMode) {
            $doneMessage = "Исправление завершено. Содержимое вложено в отдельную папку, ссылка переназначена."
        }

        [System.Windows.Forms.MessageBox]::Show(
            $doneMessage,
            "Готово",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    } catch {
        & $log "ОШИБКА: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show(
            "Перенос не завершён:`r`n$($_.Exception.Message)`r`n`r`nСмотрите лог в окне и подробный лог в папке detailed_logs.",
            "Ошибка",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    } finally {
        $btnMove.Enabled = $true
        $btnMoveBase.Enabled = $true
        $btnMergeBase.Enabled = $true
        $btnWrapBase.Enabled = $true
        $btnCheck.Enabled = $true
        $btnLocks.Enabled = $true
        $btnSizes.Enabled = $true
    }
})


$btnMoveBase.Add_Click({
    if (-not $chkClosed.Checked) {
        [System.Windows.Forms.MessageBox]::Show(
            "Сначала закройте программу/игру, которая использует старую базу, и поставьте галочку.",
            "Папка может быть занята",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return
    }

    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "Режим Переезд базы переносит уже вынесенную базу и переназначает найденные ссылки.`r`n`r`nЕсли новая база указана как прямая подпапка старой базы, например G:\C-Link -> G:\C-Link\Appdata, программа автоматически вложит содержимое базы в эту подпапку без отдельной кнопки.`r`n`r`nПродолжить?",
        "Подтверждение переезда базы",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )

    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    $btnMove.Enabled = $false
    $btnMoveBase.Enabled = $false
    $btnMergeBase.Enabled = $false
    $btnWrapBase.Enabled = $false
    $btnCheck.Enabled = $false
    $btnLocks.Enabled = $false
    $btnSizes.Enabled = $false

    try {
        $txtLog.Clear()
        $isWrapMove = Test-TargetIsDirectSubfolderOfSource $txtSource.Text $txtTarget.Text
        if ($isWrapMove) {
            $plan = Validate-BaseWrapPlan $txtSource.Text $txtTarget.Text
        } else {
            $plan = Validate-BaseMigrationPlan $txtSource.Text $txtTarget.Text
        }
        foreach ($e in $plan.Errors) { & $log "ОШИБКА: $e" }
        foreach ($w in $plan.Warnings) { & $log "ПРЕДУПРЕЖДЕНИЕ: $w" }
        if ($plan.Errors.Count -gt 0) { throw "План содержит ошибки. Переезд базы отменён." }

        $canContinue = Resolve-LockingProcessesBeforeMove $txtSource.Text $log $form
        if (-not $canContinue) {
            return
        }

        $modeDone = Invoke-BaseMoveSmart $txtSource.Text $txtTarget.Text $log

        if ($modeDone -eq "wrap") {
            $doneText = "Переезд базы завершён. Содержимое базы вложено в подпапку, найденные ссылки переназначены."
        } else {
            $doneText = "Переезд базы завершён. Найденные ссылки переназначены, а старая база оставлена как junction-страховка."
        }

        [System.Windows.Forms.MessageBox]::Show(
            $doneText,
            "Готово",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    } catch {
        & $log "ОШИБКА: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show(
            "Переезд базы не завершён:`r`n$($_.Exception.Message)`r`n`r`nСмотрите лог в окне и подробный лог в папке detailed_logs.",
            "Ошибка",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    } finally {
        $btnMove.Enabled = $true
        $btnMoveBase.Enabled = $true
        $btnMergeBase.Enabled = $true
        $btnWrapBase.Enabled = $true
        $btnCheck.Enabled = $true
        $btnLocks.Enabled = $true
        $btnSizes.Enabled = $true
    }
})


$btnMergeBase.Add_Click({
    if (-not $chkClosed.Checked) {
        [System.Windows.Forms.MessageBox]::Show(
            "Сначала закройте программы/игры/браузеры, которые используют обе базы, и поставьте галочку.",
            "Папки могут быть заняты",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return
    }

    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "Режим Слить базы нужен для случая вроде G:\Appdata\Appdata -> G:\Appdata, когда есть две похожие базы и нужно оставить одну.`r`n`r`nБудет выполнено:`r`n`r`n1. Программа найдёт AppData/Документы-ссылки, которые ведут внутрь источника слияния.`r`n2. Данные из источника будут скопированы в итоговую базу.`r`n3. Если в итоговой базе уже есть файл с таким же путём, старая версия итоговой базы будет сохранена в папку конфликтов.`r`n4. При совпадении путей активной станет версия из источника слияния.`r`n5. Найденные старые ссылки будут переназначены на итоговую базу.`r`n6. Источник слияния не удаляется, а выносится в резервную копию.`r`n`r`nДля твоего случая обычно: источник G:\Appdata\Appdata, итоговая база G:\Appdata.`r`n`r`nПродолжить?",
        "Подтверждение слияния баз",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )

    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    $btnMove.Enabled = $false
    $btnMoveBase.Enabled = $false
    $btnMergeBase.Enabled = $false
    $btnWrapBase.Enabled = $false
    $btnCheck.Enabled = $false
    $btnLocks.Enabled = $false
    $btnSizes.Enabled = $false

    try {
        $txtLog.Clear()
        $plan = Validate-BaseMergePlan $txtSource.Text $txtTarget.Text
        foreach ($e in $plan.Errors) { & $log "ОШИБКА: $e" }
        foreach ($w in $plan.Warnings) { & $log "ПРЕДУПРЕЖДЕНИЕ: $w" }
        if ($plan.Errors.Count -gt 0) { throw "План содержит ошибки. Слияние баз отменено." }

        $canContinue1 = Resolve-LockingProcessesBeforeMove $txtSource.Text $log $form
        if (-not $canContinue1) { return }
        $canContinue2 = Resolve-LockingProcessesBeforeMove $txtTarget.Text $log $form
        if (-not $canContinue2) { return }

        Merge-BaseIntoExistingAndRetargetLinks $txtSource.Text $txtTarget.Text $log

        [System.Windows.Forms.MessageBox]::Show(
            "Слияние баз завершено. Проверьте работу программ. Резервные папки пока не удаляйте.",
            "Готово",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    } catch {
        & $log "ОШИБКА: $($_.Exception.Message)"
        try { & $log "Тип ошибки: $($_.Exception.GetType().FullName)" } catch {}
        try { & $log "Строка скрипта: $($_.InvocationInfo.ScriptLineNumber)" } catch {}
        try { & $log "Команда: $($_.InvocationInfo.Line.Trim())" } catch {}
        [System.Windows.Forms.MessageBox]::Show(
            "Слияние баз не завершено:`r`n$($_.Exception.Message)`r`n`r`nСмотрите лог в окне и подробный лог в папке detailed_logs.",
            "Ошибка",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    } finally {
        $btnMove.Enabled = $true
        $btnMoveBase.Enabled = $true
        $btnMergeBase.Enabled = $true
        $btnWrapBase.Enabled = $true
        $btnCheck.Enabled = $true
        $btnLocks.Enabled = $true
        $btnSizes.Enabled = $true
    }
})


$btnWrapBase.Add_Click({
    if (-not $chkClosed.Checked) {
        [System.Windows.Forms.MessageBox]::Show(
            "Сначала закройте программы/игры/браузеры, которые используют эту базу, и поставьте галочку.",
            "Папка может быть занята",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return
    }

    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "Режим В подпапку нужен для случая вроде G:\C-Link -> G:\C-Link\Appdata, когда данные уже лежат прямо в корне базы, а их нужно вложить в подпапку.`r`n`r`nБудет выполнено:`r`n`r`n1. Программа найдёт AppData/Документы-ссылки и соседние ссылки, которые ведут внутрь текущей базы.`r`n2. Внутри текущей базы будет создана итоговая подпапка, если её ещё нет.`r`n3. Все элементы из корня текущей базы будут перемещены в эту подпапку.`r`n4. Найденные ссылки будут переназначены на новую вложенную базу.`r`n`r`nДля твоего случая: текущая база G:\C-Link, итоговая подпапка G:\C-Link\Appdata.`r`n`r`nПродолжить?",
        "Подтверждение вложения базы",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )

    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    $btnMove.Enabled = $false
    $btnMoveBase.Enabled = $false
    $btnMergeBase.Enabled = $false
    $btnWrapBase.Enabled = $false
    $btnCheck.Enabled = $false
    $btnLocks.Enabled = $false
    $btnSizes.Enabled = $false

    try {
        $txtLog.Clear()
        $plan = Validate-BaseWrapPlan $txtSource.Text $txtTarget.Text
        foreach ($e in $plan.Errors) { & $log "ОШИБКА: $e" }
        foreach ($w in $plan.Warnings) { & $log "ПРЕДУПРЕЖДЕНИЕ: $w" }
        if ($plan.Errors.Count -gt 0) { throw "План содержит ошибки. Вложение базы отменено." }

        $canContinue = Resolve-LockingProcessesBeforeMove $txtSource.Text $log $form
        if (-not $canContinue) { return }

        Wrap-BaseIntoSubfolderAndRetargetLinks $txtSource.Text $txtTarget.Text $log

        [System.Windows.Forms.MessageBox]::Show(
            "База вложена в подпапку. Найденные ссылки переназначены. Проверьте работу программ.",
            "Готово",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    } catch {
        & $log "ОШИБКА: $($_.Exception.Message)"
        try { & $log "Тип ошибки: $($_.Exception.GetType().FullName)" } catch {}
        try { & $log "Строка скрипта: $($_.InvocationInfo.ScriptLineNumber)" } catch {}
        try { & $log "Команда: $($_.InvocationInfo.Line.Trim())" } catch {}
        [System.Windows.Forms.MessageBox]::Show(
            "Вложение базы не завершено:`r`n$($_.Exception.Message)`r`n`r`nСмотрите лог в окне и подробный лог в папке detailed_logs.",
            "Ошибка",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    } finally {
        $btnMove.Enabled = $true
        $btnMoveBase.Enabled = $true
        $btnMergeBase.Enabled = $true
        $btnWrapBase.Enabled = $true
        $btnCheck.Enabled = $true
        $btnLocks.Enabled = $true
        $btnSizes.Enabled = $true
    }
})

$btnQuickAppData.Add_Click({
    $p = Get-UserAppDataRoot
    if (Test-Path -LiteralPath $p -PathType Container) {
        $txtSource.Text = $p
        & $log "Выбран быстрый корень AppData. Для переноса выберите вложенную папку или нажмите Размеры. Корень AppData целиком заблокирован проверкой."
    }
})
$btnQuickDocuments.Add_Click({
    $p = Get-UserDocumentsRoot
    if (Test-Path -LiteralPath $p -PathType Container) {
        $txtSource.Text = $p
        & $log "Выбран быстрый корень Документы. Для переноса выберите вложенную папку или нажмите Размеры. Корень Документы целиком заблокирован проверкой."
    }
})
$btnOpenLogs.Add_Click({
    $root = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($root)) {
        $root = Join-Path $env:TEMP "AppData-Folder-Mover"
    }
    $logDir = Join-Path $root "detailed_logs"
    if (!(Test-Path -LiteralPath $logDir -PathType Container)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    Start-Process explorer.exe $logDir
})

[void][System.Windows.Forms.Application]::Run($form)
