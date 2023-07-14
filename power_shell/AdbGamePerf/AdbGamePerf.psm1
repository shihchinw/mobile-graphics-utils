# Default config settings.
$Config = @{
    AGP_ANDROID_PROFILER = 'C:\Program Files\Android\Android Studio\bin\profiler.exe'
    AGP_MALI_MOBILE_STUDIO = 'C:\Program Files\Arm\Arm Mobile Studio 2023.0'
}

$ConfigFilepath = "$PSScriptRoot/config.json"

function Import-AGPConfig {
    if (-not (Test-Path $ConfigFilepath)) {
        # Export default settings to config file.
        $Config | ConvertTo-Json | Out-File $ConfigFilepath
    } else {
        $Config = Get-Content $ConfigFilepath -Raw | ConvertFrom-Json -AsHashtable
    }

    Write-Host $Config.Keys
    foreach ($k in $Config.Keys) {
        [Environment]::SetEnvironmentVariable($k, $Config[$k])
    }
}

function Export-AGPConfig {
    $Config | ConvertTo-Json | Out-File $ConfigFilepath
}

function Resolve-Filepath {
    param (
        [string]$Filepath,
        [string]$VarName
    )

    $IsValid = Test-Path $Filepath

    while (-not $IsValid) {
        Write-Host "Invalid filepath: $Filepath"
        $Filepath = Read-Host "Please specify a valid path for $VarName ('q' to escape)"

        $IsValidPath = (Test-Path $Filepath)
        if ($IsValidPath) {
            [Environment]::SetEnvironmentVariable($VarName, $Filepath)
            $Config[$VarName] = $Filepath
            Export-AGPConfig
        }

        $IsValid = $IsValidPath -or ($Filepath -eq 'q')
    }

    return $Filepath.Replace('\', '/')
}

function Get-MobileStudioVersion {
    param (
        [string]$Filepath
    )

    $Name = Split-Path -Path $Filepath -Leaf
    if ($Name -match 'Arm Mobile Studio (\d+\.\d)') {
        return $Matches[1]
    }

    throw "Failed to get version string from '$Filepath'"
}


# -----------------------------------------------------------------------------
# Basic Android helper commands
# -----------------------------------------------------------------------------
<#
.SYNOPSIS
Get name of active application in the foreground.
#>
function Get-FocusedPackageName {
    $Log = adb shell "dumpsys activity activities | grep mFocusedApp"
    if (-not ($Log -match "\w+([.]\w+)+")) {
        Write-Warning "Can't find focused package"
        return
    }

    return $Matches.0
}

<#
.SYNOPSIS
Get installed package names on Android device.
#>
function Get-PackageNameList {
    return (adb shell "pm list packages -3 | sort | sed 's/^package://'").split([System.Environment]::NewLine)
}

<#
.SYNOPSIS
Select entity from prompted package name list.
#>
function Select-Package {
    param (
        [switch]$ShowResult
    )
    $PackageNames = Get-PackageNameList
    $Index = 1
    foreach ($Name in $PackageNames) { Write-Host ("{0, 2:N0}) {1}" -f $Index, $Name); $Index++}
    Write-Host " 0) Exit"

    $SelectedIdx = Read-Host -Prompt "`nSelect entry"
    if ($SelectedIdx -eq 0) {
        return ''
    }

    $SelectedPackageName = $PackageNames[$SelectedIdx - 1]
    if ($ShowResult) { Write-Host "Selected app: $SelectedPackageName" }
    return $SelectedPackageName
}

<#
.DESCRIPTION
Resolve application by following alias:
 ~ Focused application (i.e. foregraound activity).
 ? Select application name from package list.
 ! Last selected application name.

.PARAMETER AppName
Input application name.

.PARAMETER AbortMessage
Print message when aborting application selection.
#>
function Resolve-AppName {
    param(
        [string] $AppName,
        [string] $AbortMessage
    )

    if ($AppName -eq '~') {
        return Get-FocusedPackageName
    }

    if ($AppName -eq '!') {
        $AppName = $env:AGP_LAST_APPNAME
        if (-not $AppName) {
            $AppName = '?'
        }
    }

    if ($AppName -eq '?') {
        $AppName = Select-Package
        if (-not $AppName) {
            Write-Host $AbortMessage
            return ''
        }
    }

    return $AppName
}

function Save-AppName {
    param(
        [string] $AppName
    )

    [Environment]::SetEnvironmentVariable('AGP_LAST_APPNAME', $AppName)
}

function Start-DeviceApp {
    param(
        [string] $AppName = '?',
        [switch] $WaitForLaunch
    )

    $AppName = Resolve-AppName $AppName "Abort starting application."
    if (-not $AppName) {
        return
    }

    adb shell "monkey -p $AppName -c android.intent.category.LAUNCHER 1" | Out-Null
    Save-AppName $AppName

    if ($WaitForLaunch) {
        # Pipe to Out-Null for waiting adb finishing its work.
        adb shell "while [ ! `"`$(pidof $AppName)`" ]; do (sleep 1); done" | Out-Null
    }
}

function Stop-DeviceApp {
    param(
        [string] $AppName = '~',
        [switch] $WaitForExit
    )

    $AppName = Resolve-AppName $AppName "Abort stopping application."
    if (-not $AppName) {
        return
    }

    adb shell am force-stop $AppName
    if ($WaitForExit) {
        # Pipe to Out-Null for waiting adb finishing its work.
        adb shell "while [ `"`$(pidof $AppName)`" ]; do (sleep 1); done" | Out-Null
    }
}

<#
.SYNOPSIS
Wait for application on device with time out.

.PARAMETER AppName
Application name.

.PARAMETER ForceStopApp
Force stop app after time out.

.PARAMETER TimeOut
Duration of waiting.

.EXAMPLE
Wait-DeviceApp -AppName com.foo.bar -TimeOut 30 -ForceStopApp

Wait for com.foo.bar for up to 30 secs.
#>
function Wait-DeviceApp {
    param(
        [string] $AppName = '~',
        [switch] $ForceStopApp,
        [UInt16] $TimeOut = 10
    )

    $AppName = Resolve-AppName $AppName "Abort stopping application."
    if (-not $AppName) {
        return
    }

    adb shell "t=$TimeOut; while [ `"`$(pidof $AppName)`" ] && [ `$t -gt 0 ]; do sleep 1; t=`$((`$t - 1)); echo Waiting for $AppName in `$t secs; done"

    if ($ForceStopApp) {
        adb shell am force-stop $AppName
    }
}

function Enter-AdbShell { adb shell "$Args" }
Set-Alias -Name as -Value Enter-AdbShell

<#
.SYNOPSIS
Watch logcat of specific application.

.EXAMPLE
Watch-Logcat -AppName ~

Watch logcat of currently focused application.

.EXAMPLE
Watch-Logcat -AppName ?

Select entity from installed packages first, then watch its logcat.

.EXAMPLE
Watch-Logcat -AppName com.foo.bar

Watch logcat of com.foo.bar

.EXAMPLE
Watch-Logcat -AppName com.foo.bar -tag UE

Watch logcat of com.foo.bar with specific tag 'UE'.
#>
function Watch-Logcat {
    param(
        [string]$AppName = '*',
        [switch]$Clear,
        [switch]$NoColor,
        [string]$Tag
    )

    $CmdArgs = New-Object System.Collections.ArrayList
    if ($Clear) {
        $CmdArgs.Add("logcat -c |") | Out-Null
    }
    $CmdArgs.Add("logcat") | Out-Null

    if ($AppName -eq '?') {
        $AppName = Select-Package
        if (-not $AppName) {
            Write-Host "Abort logcat watching..."
            return
        }
    } elseif ($AppName -eq '~') {
        $AppName = Get-FocusedPackageName
    }

    if ($AppName -ne '*') {
        if (-not ($AppName -match "\w+([.]\w+)+")) {
            throw "Invalid format of package name: $AppName"
        }

        # Watch specific pid of given application name.
        $AppPidStr = adb shell pidof $AppName
        if (-not $AppPidStr) { throw "Can't find any running process of $AppName" }
        $AppPid = ($AppPidStr).Split()[0]   # Get first returned pid
        $CmdArgs.Add("--pid=$AppPid") | Out-Null
    }

    if (-not $NoColor) { $CmdArgs.Add("-v color") | Out-Null }
    if ($Tag) { $CmdArgs.Add("$($Tag):D *:S") | Out-Null }

    adb shell $CmdArgs
}

Set-Alias -Name wl -Value Watch-Logcat

<#
.SYNOPSIS
Show memory info for focused package or whole system.

.PARAMETER Detailed
Show detailed memory report from whole system.
#>
function Show-MemoryInfo {
    param(
        [switch] $Detailed
    )

    if ($Detailed) {
        adb shell dumpsys meminfo
    } else {
        $AppName = Get-FocusedPackageName
        adb shell dumpsys meminfo $AppName
    }
}

<#
.SYNOPSIS
Watch memory info of focused package.

.PARAMETER Type
Monitor type of meminfo (Graphics|GL|Heap|mmap).

.PARAMETER Interval
Update interval (in seconds).

.EXAMPLE
Watch-MemoryInfo -Type GL -Interval 0.5

Watch EGL & GL memory for active package every 0.5 sec.
#>
function Watch-MemoryInfo {
    param(
        [ValidateSet('Graphics', 'GL', 'Heap', 'mmap')]
        [string] $Type = 'GL',
        [float] $Interval = 0.5
    )

    $AppName = Get-FocusedPackageName
    Write-Host "Watch memory of [$AppName]"
    Write-Host "                       Pss(KB)                        Rss(KB)"
    Write-Host "                        ------                         ------"

    while ($true) {
        adb shell "dumpsys meminfo $AppName | grep $Type"
        Start-Sleep $Interval
        if ($Type -ne 'Graphics') {
            Write-Host "                        ------                         ------"
        }
    }
}

function Get-EncodedFilename {
    param (
        [Parameter(Mandatory)]
        [string]$Filename,
        [string]$FileExt = ''
    )

    # $Filename = [io.path]::GetFileNameWithoutExtension($Filename)
    $Timestamp = $(Get-Date -f MMdd_hhmmss)
    $OutFileName = "{0}_{1}{2}" -f ($Filename, $Timestamp, $FileExt)
    return $OutFileName
}

<#
.SYNOPSIS
Save a screen capture on device to local machine.

.PARAMETER Filename
File name of output image.
#>
function Save-DeviceScreenCap {
    param (
        [ValidateNotNullOrEmpty()]
        [string]$Filename = "capture"
    )

    $OutFileName = Get-EncodedFilename $Filename '.png'
    $DeviceFilePath = '/sdcard/capture.png'
    adb shell screencap $DeviceFilePath
    adb pull $DeviceFilePath $OutFileName
    Write-Host "Saved screen cap to '$OutFilename'"
}

<#
.SYNOPSIS
Save a screen recording on device to local machine.

.PARAMETER Duration
Duration of recordin in secs.

.PARAMETER Filename
Filename of output mp4 file.
#>
function Save-DeviceScreenRecord {
    param (
        [byte]$Duration = 5,

        [ValidateNotNullOrEmpty()]
        [string]$Filename = "record"
    )

    $OutFileName = Get-EncodedFilename $Filename '.mp4'
    $DeviceFilePath = '/sdcard/record.mp4'
    adb shell "screenrecord --time-limit $Duration $DeviceFilePath"
    adb pull $DeviceFilePath $OutFileName
    Write-Host "Saved $Duration sec(s) screen recording to '$OutFilename'"
}

<#
.SYNOPSIS
Start recording a perfetto trace.

.PARAMETER Filename
Trace filename on local machine.

.PARAMETER Time
Trace duration TIME[s|m|h]. If time is not set explicitly, it will keep recording until user presses Ctrl+C to cancel.

.PARAMETER Buffer
Ring buffer size [mb|gb] during recording.

.PARAMETER ExtraAtraceCagetories
Extra ATRACE categories to trace.

.EXAMPLE
Start-Perfetto -o foo.perfetto-trace

.NOTES
Record traces on Android: https://perfetto.dev/docs/quickstart/android-tracing (require Python installation)

This function utilizes helper script from google.
curl -O https://raw.githubusercontent.com/google/perfetto/master/tools/record_android_trace
#>
function Start-Perfetto {
    param (
        [string]$Filename,
        [string]$Time,
        [string]$Buffer = '32mb',
        [string[]]$ExtraAtraceCagetories
    )

    $CmdArgs = New-Object System.Collections.ArrayList

    if ($Time) {
        $CmdArgs.Add("-t $Time") | Out-Null
    }

    if ($Filename) {
        $OutFileName = Get-EncodedFilename $Filename '.perfetto-trace'
        $CmdArgs.Add("-o $OutFileName") | Out-Null
    }

    $CmdArgs.Add("-b $Buffer") > $null

    # For more tracing categories, please refer to
    # https://android.googlesource.com/platform/frameworks/native/+/refs/tags/android-q-preview-5/cmds/atrace/atrace.cpp#100
    # $AtraceCategory =  @('gfx', 'sched', 'freq', 'idle', 'load', 'am', 'wm', 'view', 'sync', 'hal', 'input', 'res', 'memory')
    $AtraceCategory = 'gfx sched freq idle load am wm view sync hal input res memory'
    $CmdArgs.Add($AtraceCategory) | Out-Null
    $CmdArgs.Add($ExtraAtraceCagetories) | Out-Null

    python "$PSScriptRoot\record_android_trace" $CmdArgs
}

function Start-AndroidProfiler {
    $ProfilerPath = Resolve-Filepath $env:AGP_ANDROID_PROFILER 'AGP_ANDROID_PROFILER'
    Start-Process $ProfilerPath
}

Set-Alias -Name saap -Value Start-AndroidProfiler

# -----------------------------------------------------------------------------
# Mali Mobile Studio
# -----------------------------------------------------------------------------

<#
.SYNOPSIS
Install streamline gator for following TCP connection.

.DESCRIPTION
By using TCP connection, we can start capturing counters in the middle of execution instead of start from APP launch.

.LINK
https://developer.arm.com/documentation/102718/0102/Streamline-can-not-access-my-device
#>
function Start-StreamlineGator {
    $MobileStudioPath = Resolve-Filepath $env:AGP_MALI_MOBILE_STUDIO 'AGP_MALI_MOBILE_STUDIO'
    $Version = Get-MobileStudioVersion $MobileStudioPath
    if ($Version -ge '2023.2') {
        adb root
        adb push "$MobileStudioPath/streamline/bin/android/arm64/gatord" /data/local/tmp
        adb shell 'chmod 777 /data/local/tmp/gatord'
        adb shell '/data/local/tmp/gatord --system-wide=yes'
    } else {
        $ScriptPath = "$MobileStudioPath/streamline/gator/gator_me.py"
        python $ScriptPath --daemon "$MobileStudioPath/streamline/bin/android/arm64/gatord"
    }
}

<#
.SYNOPSIS
Enable Light Weight Interceptor library (LWI) to add streamline annotations.

.EXAMPLE
Enable-LightWeightInterceptor

Enable LWI for Vulkan and overwrite files to $env:TEMP/mali_lwi

.EXAMPLE
Enable-LightWeightInterceptor -h

Show detailed flags of lwi_me.py in $MobileStudioPath/{performance_advisor|streamline}/bin/android/lwi_me.py

.LINK
https://developer.arm.com/documentation/102009/0102/Before-you-begin/Integrate-Performance-Advisor-with-your-application
#>
function Enable-LightWeightInterceptor {
    param (
        [switch]$GLES
    )

    $MobileStudioPath = Resolve-Filepath $env:AGP_MALI_MOBILE_STUDIO 'AGP_MALI_MOBILE_STUDIO'
    $Version = Get-MobileStudioVersion $MobileStudioPath
    $SubFolderName = if ($Version -ge '2023.1') { 'streamline' } else { 'performance_advisor' }
    $ScriptName = if ($Version -ge '2023.2') { 'streamline_me.py' } else { 'lwi_me.py' }
    $ScriptPath = "$MobileStudioPath/$SubFolderName/bin/android/$ScriptName"

    if ($Args) {
        python $ScriptPath $Args
    } else {
        $API = if ($GLES) { 'gles' } else { 'vulkan' }

        if ($Version -ge '2023.2') {
            python $ScriptPath --lwi-mode counters --lwi-api $API --overwrite --lwi-out-dir "$env:TEMP/mali_lwi"
        } else {
            python $ScriptPath --lwi-api $API --overwrite --lwi-out-dir "$env:TEMP/mali_lwi"
        }
    }
}

<#
.SYNOPSIS
Invoke Mali Performance Advisor.

.EXAMPLE
Invoke-PerformanceAdvisor -h

Show help flags of Performance Advisor in Mali Mobile Studio.

.EXAMPLE
Invoke-PerformanceAdvisor foo.apc -t json

Import Streamline capture foo.apc and generate output report.

.LINK
https://developer.arm.com/Tools%20and%20Software/Performance%20Advisor
#>
function Invoke-PerformanceAdvisor {
    $MobileStudioPath = Resolve-Filepath $env:AGP_MALI_MOBILE_STUDIO 'AGP_MALI_MOBILE_STUDIO'
    $Version = Get-MobileStudioVersion $MobileStudioPath
    if ($Version -ge '2023.1') {
        & "$MobileStudioPath/streamline/Streamline-cli.exe" -pa $Args
    } else {
        & "$MobileStudioPath/performance_advisor/pa.exe" $Args
    }
}

<#
.SYNOPSIS
Invoke Mali offline compiler to compile a folder of shaders and collect results in one csv.

.PARAMETER ShaderFolder
The folder of source shaders.

.PARAMETER JobCount
Max number of parallel compiling processes. (Not support for compiling of Vulkan shaders).

.PARAMETER OutputFolderPath
Folder path of the output report.

.PARAMETER Vulkan
Target the Vulkan API.

.EXAMPLE
Invoke-MaliOfflineCompiler -JobCount 6 shader_folder

Compiling GLES shaders in shader_folder with 6 processes.

.EXAMPLE
Invoke-MaliOfflineCompiler -Target SPIRV -JobCount 6 shader_folder

Compile SPIR-V binary shaders in shader_folder with 6 processes. Each shader's file extension should be as
(.vert|.frag|.comp).spv
#>
function Invoke-MaliOfflineCompiler {
    param (
        [System.IO.FileInfo]$ShaderFolder,
        [byte]$JobCount = 4,
        [string]$OutputFolderPath = '.',
        [ValidateSet('SPIRV', 'VulkanGLSL', 'GLSL')]
        [string]$Target,
        [ValidatePattern('(Mali|Immortalis)-\w+')]
        [string]$Core = ''
    )

    if ($Target -eq 'SPIRV') {
        python "$PSScriptRoot/shader_profile.py" -c $Core --spirv -j $JobCount -o $OutputFolderPath $ShaderFolder
    } elseif ($Target -eq 'VulkanGLSL') {
        python "$PSScriptRoot/shader_profile.py" -c $Core --vulkan -o $OutputFolderPath $ShaderFolder
    } else {
        python "$PSScriptRoot/shader_profile.py" -c $Core -j $JobCount -o $OutputFolderPath $ShaderFolder
    }
}

<#
.SYNOPSIS
Save Streamline profile (*.apc.zip) via headless capturing and return output file path.

.PARAMETER AppName
Target application name. Support name alias ? (from selection), ! (last selected app), ~ (focused app).

.PARAMETER GLES
If using GLES API.

.PARAMETER Config
Counter configuration file.

.PARAMETER OutputName
Output capture name.

.PARAMETER OutputFolderPath
Output folder path.

.PARAMETER Duration
Duration of capturing in seconds.

.EXAMPLE
Save-StreamlineCapture -AppName ? -Config config.xml

Select an App entity and save its headless Sreamline capture with counters defined in config.xml.
#>
function Save-StreamlineCapture {
    param(
        [string] $AppName = '?',
        [switch] $GLES,
        [string] $Config,
        [string] $OutputName,
        [string] $OutputFolderPath = '.',
        [switch] $NoTimeStr,
        [UInt16] $Duration = 10
    )

    $MobileStudioPath = Resolve-Filepath $env:AGP_MALI_MOBILE_STUDIO 'AGP_MALI_MOBILE_STUDIO'
    $Version = Get-MobileStudioVersion $MobileStudioPath
    if ($Version -lt '2023.2') {
        throw "Not support for older version of Streamline: $Version. Please update to Mobile Studio 2023.2."
    }

    $ScriptPath = "$MobileStudioPath/streamline/bin/android/streamline_me.py"
    $API = if ($GLES) { 'gles' } else { 'vulkan' }
    $GatordPath = "$MobileStudioPath/streamline/bin/android/arm64/gatord"

    $AppName = Resolve-AppName $AppName 'Abort Streamline capturing...'
    if (-not $AppName) {
        return
    }

    Stop-DeviceApp $AppName -WaitForExit

    if (-not $OutputName) {
        $OutputName = $AppName
    }

    if (-not $Config) {
        $Config = "$PSScriptRoot/streamline_config.xml"
    }

    $OutputFileName = if ($NoTimeStr) { $OutputName } else { Get-EncodedFilename $OutputName }
    $OutputFilePath = "$OutputFolderPath/$OutputFileName.apc.zip"
    $LwiOutDir = "$OutputFolderPath/lwi-out-$OutputFileName"
    $ProcArgs = "`"$ScriptPath`" --lwi-mode counters --lwi-api $API --package $AppName --headless $OutputFilePath --daemon `"$GatordPath`" --config $Config --lwi-out-dir $LwiOutDir"
    $StreamlineProc = Start-Process -FilePath python -ArgumentList $ProcArgs -WorkingDirectory . -PassThru -RedirectStandardError StreamlineCaptureStdErr.log

    Start-Sleep 10  # Wait for launch of Streamline

    Write-Host "Start $AppName"
    Start-DeviceApp $AppName -WaitForLaunch
    Write-Host "$AppName has been launched"

    Wait-DeviceApp $AppName -TimeOut $Duration -ForceStopApp
    $StreamlineProc.Close()
    Write-Host "Close $AppName"
    return $OutputFilePath
}

Set-Alias -Name sasg -Value Start-StreamlineGator
Set-Alias -Name svsc -Value Save-StreamlineCapture
Set-Alias -Name lwi -Value Enable-LightWeightInterceptor
Set-Alias -Name ipa -Value Invoke-PerformanceAdvisor

# -----------------------------------------------------------------------------
# Unreal utilities
# -----------------------------------------------------------------------------
<#
.SYNOPSIS
Execute Unreal console command via adb shell am broadcast.

.EXAMPLE
Invoke-UnrealCommand t.MaxFPS=60
#>
function Invoke-UnrealCommand { adb shell "am broadcast -a android.intent.action.RUN -e cmd '$Args'" }
Set-Alias -Name uecmd -Value Invoke-UnrealCommand

<#
.SYNOPSIS
Start FPS chart data capture on device.

.NOTES
https://docs.unrealengine.com/4.27/en-US/TestingAndOptimization/PerformanceAndProfiling/Overview/#generateachartoveraperiodoftime
#>
function Start-UnrealFPSChart {
    param (
        [switch] $ClearLogcat
    )

    if ($ClearLogcat) { adb logcat -c }
    uecmd StartFPSChart
}

<#
.SYNOPSIS
Stop FPS chart data capture on device.
#>
function Stop-UnrealFPSChart {
    param (
        [string] $OutputFolderPath = '.'
    )
    uecmd StopFPSChart

    $Log = adb shell "logcat UE:D UE4:D *:S -d -e 'FPS Chart' | tail -1"
    if (-not ($Log -match 'saved to (.+)')) {
        Write-Warning "Can't find output FPS chart"
        return
    }

    $DeviceOutFolderPath = (Split-Path $Matches.1).Replace('\', '/')
    $FolderName = Split-Path -Leaf $DeviceOutFolderPath
    New-Item -ItemType Directory -Force -Path $OutputFolderPath | Out-Null
    Write-Host "Pulling trace '$DeviceOutFolderPath'"
    adb pull $DeviceOutFolderPath "$OutputFolderPath/$FolderName"
}

<#
.SYNOPSIS
Start a statistics capture.

.NOTES
https://docs.unrealengine.com/5.0/en-US/stat-commands-in-unreal-engine/
#>
function Start-UnrealStatFile {
    uecmd stat StartFile
}

<#
.SYNOPSIS
Stop current statistics capture. Output file could be located at
[Unreal Engine Project Directory][ProjectName]\Saved\Profiling\UnrealStats.
#>
function Stop-UnrealStatFile {
    param (
        [string] $OutputFolderPath = '.'
    )
    uecmd stat StopFile

    $PackageName = Get-FocusedPackageName
    $Log = adb shell "logcat UE:D UE4:D *:S -d -e 'Wrote stats file' | tail -1"

    if (-not ($Log -match '../../../((\w+)/(.+))$')) {
        Write-Warning "Can't find output stats file"
        return
    }

    $RelativePath = $Matches.1
    if ($RelativePath.EndsWith('uestats')) {
        $ParentFolderPath = "/sdcard/Android/data/$PackageName/files/UnrealGame"
    } else {
        $ParentFolderPath = "/sdcard/UE4Game"
    }

    $DeviceOutFolderPath = (Split-Path -Parent "$ParentFolderPath/$($Matches.2)/$RelativePath").Replace('\', '/')

    $FolderName = Split-Path -Leaf $DeviceOutFolderPath
    New-Item -ItemType Directory -Force -Path $OutputFolderPath | Out-Null
    Write-Host "Pulling trace '$DeviceOutFolderPath'"

    adb pull $DeviceOutFolderPath "$OutputFolderPath/$FolderName"
}

# https://docs.unrealengine.com/5.0/en-US/unreal-insights-reference-in-unreal-engine-5/
function Start-UnrealInsight {
    param (
        [switch] $ClearLogcat,
        [switch] $Memory
    )

    if ($ClearLogcat) { adb logcat -c }

    if ($Memory) {
        # It seems Memalloc, MemTag do not work on Android so far.
        uecmd "Trace.File Default,MemAlloc,MemTag"
    } else {
        uecmd "Trace.File CPU,Frame,GPU,Bookmark,Log,Stats,RHICommands"
    }
    adb shell "logcat UE:D UE4:D *:S -d | grep utrace | tail -1"
}

function Stop-UnrealInsight {
    param (
        [switch] $PullToDefaultStore,
        [string] $OutputFolderPath = '.'
    )
    uecmd Trace.stop
    $Log = adb shell "logcat UE:D UE4:D *:S -d | grep utrace | tail -1"
    if (-not ($Log -match '"(.+)"')) {
        Write-Warning "Can't find output trace"
        return
    }

    $DeviceOutFilePath = $Matches.1
    if ($PullToDefaultStore) {
        $OutputFolderPath = "$env:USERPROFILE/AppData/Local/UnrealEngine/Common/UnrealTrace/Store/001"
    } else {
        New-Item -ItemType Directory -Force -Path $OutputFolderPath | Out-Null
    }

    Write-Host "Pulling trace '$DeviceOutFilePath' to $OutputFolderPath"
    adb pull $DeviceOutFilePath $OutputFolderPath
}

# https://docs.unrealengine.com/5.0/en-US/gpudump-viewer-tool-in-unreal-engine/
function Save-UnrealGPUDump {
    param (
        [string] $OutputFolderPath = '.'
    )

    uecmd DumpGPU

    $Log = adb shell "logcat UE:D *:S -d | grep DumpGPU | tail -1"
    if (-not ($Log -match "../../../(.+)/Base/ConsoleVariables.csv")) {
        Write-Warning "Can't find dumped data"
        return
    }

    $PackageName = Get-FocusedPackageName
    $ParentFolderPath = "/sdcard/Android/data/$PackageName/files/UnrealGame/Mobile"

    $RelativePath = $Matches.1
    $DeviceOutFolderPath = ("$ParentFolderPath/$RelativePath").Replace('\', '/')

    $FolderName = Split-Path -Leaf $DeviceOutFolderPath
    New-Item -ItemType Directory -Force -Path $OutputFolderPath | Out-Null
    Write-Host "Pulling GPUDump '$DeviceOutFolderPath'"

    adb pull $DeviceOutFolderPath "$OutputFolderPath/$FolderName"
}

function Show-UnrealLogcat {
    param (
        [switch] $LogProfilingDebugging
    )

    if ($LogProfilingDebugging) {
        adb logcat UE:D UE4:D *:S -e LogProfilingDebugging -d $Args
    } else {
        adb logcat UE:D UE4:D *:S -d $Args
    }
}

function Show-UnrealSynthBenchmark {
    adb logcat -c
    uecmd SynthBenchmark
    adb logcat -v raw UE:D UE4:D *:S -e LogSynthBenchmark
}

function Export-UnrealCallStats {
    param (
        [single] $DurationInMs = 0.1,
        [string] $Filename
    )

    adb logcat -c
    # Dump call statistics to logcat.
    uecmd stat DumpFrame -ms=$DurationInMs
    if ($Filename) {
        # Exclusively redirect UE debug info to file.
        adb logcat -v raw UE:D UE4:D *:S -e LogStats -d > $Filename
    } else {
        adb logcat -v raw UE:D UE4:D *:S -e LogStats -d
    }
}

function Switch-UnrealStats {
    param (
        [switch] $FPSUnit,
        [switch] $SceneRendering,
        [switch] $Game,
        [switch] $InitViews,
        [switch] $Threading,
        [switch] $RHI,
        [switch] $TaskGraphTasks,
        [switch] $Memory,
        [switch] $LightRendering,
        [switch] $Anim,
        [switch] $Physics,
        [ValidateSet($null, $true, $false)]
        [object] $Serialization
    )

    if ($FPSUnit) {
        uecmd stat fps | Out-Null
        uecmd stat unit
    }

    if ($Memory) {
        uecmd stat Memory | Out-Null
        uecmd stat MemoryPlatform
    }

    if ($SceneRendering) { uecmd stat SceneRendering }
    if ($Game) { uecmd stat game }
    if ($InitViews) { uecmd stat InitViews }
    if ($Threading) { uecmd stat Threading }
    if ($RHI) { uecmd stat RHI }
    if ($TaskGraphTasks) { uecmd stat TaskGraphTasks }
    if ($LightRendering) { uecmd stat LightRendering }
    if ($Anim) { uecmd stat Anim }
    if ($Physics) { uecmd stat Physics }

    if ($null -ne $Serialization) {
        [int]$EnableSerialization = [int][bool]::Parse($Serialization)
        uecmd r.Vulkan.UploadCmdBufferSemaphore $EnableSerialization | Out-Null
        uecmd r.Vulkan.SubmitAfterEveryEndRenderPass $EnableSerialization | Out-Null
        uecmd r.Vulkan.SubmitOnDispatch $EnableSerialization | Out-Null
        uecmd r.Vulkan.WaitforIdleOnSubmit $EnableSerialization
    }
}

# https://docs.unrealengine.com/4.26/en-US/TestingAndOptimization/PerformanceAndProfiling/Overview/#showflags
function Show-UnrealRenderFeature {
    [CmdletBinding()]
    param (
        [Alias("SSR")]
        [switch] $ScreenSpaceReflections,
        [Alias("AO")]
        [switch] $AmbientOcclusion,
        [Alias("AA")]
        [switch] $AntiAliasing,
        [switch] $Bloom,
        [switch] $DeferredLighting,
        [switch] $DynamicShadows,
        [switch] $GlobalIllumination,
        [Alias("PP")]
        [switch] $PostProcessing,
        [switch] $ReflectionEnvironment,
        [switch] $Refraction,
        [switch] $Translucency
    )

    $ParameterNames = $MyInvocation.BoundParameters.Keys
    foreach ($Name in $ParameterNames) {
        Write-Host "Enable rendering feature: $Name"
        uecmd "showflag.$Name 1" | Out-Null
    }
}

function Hide-UnrealRenderFeature {
    [CmdletBinding()]
    param (
        [Alias("SSR")]
        [switch] $ScreenSpaceReflections,
        [Alias("AO")]
        [switch] $AmbientOcclusion,
        [Alias("AA")]
        [switch] $AntiAliasing,
        [switch] $Bloom,
        [switch] $DeferredLighting,
        [switch] $DynamicShadows,
        [switch] $GlobalIllumination,
        [Alias("PP")]
        [switch] $PostProcessing,
        [switch] $Translucency
    )

    $ParameterNames = $MyInvocation.BoundParameters.Keys
    foreach ($Name in $ParameterNames) {
        Write-Host "Disable rendering feature: $Name"
        uecmd "showflag.$Name 0" | Out-Null
    }
}

Set-Alias -Name uest -Value Switch-UnrealStats
Set-Alias -Name uelog -Value Show-UnrealLogcat
Set-Alias -Name ueshow -Value Show-UnrealRenderFeature
Set-Alias -Name uehide -Value Hide-UnrealRenderFeature