# Default config settings.
$Config = @{
    AGP_ANDROID_PROFILER = 'C:\Program Files\Android\Android Studio\bin\profiler.exe'
    AGP_MALI_MOBILE_STUDIO = 'C:\Program Files\Arm\Arm Performance Studio 2024.0'
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
    } elseif ($Name -match 'Arm Performance Studio (\d+\.\d)') {
        return $Matches[1]
    }

    throw "Failed to get version string from '$Filepath'"
}


# -----------------------------------------------------------------------------
# Basic Android helper commands
# -----------------------------------------------------------------------------
<#
.SYNOPSIS Confirm if connected device has root access permission.
#>
function Confirm-RootAccess {
    $Result = adb shell "su 0 echo true || exit 0"
    return $Result -eq 'true'
}

<#
.SYNOPSIS
Get name of active application in the foreground.
#>
function Get-FocusedPackageName {
    $Log = adb shell "dumpsys activity activities | grep mFocusedApp=ActivityRecord"
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
        # But, this approach does not block caller, thus we periodically check with adb command.
        # adb shell "while [ ! `"`$(pidof $AppName)`" ]; do (sleep 1); done" | Out-Null
        while (!(adb shell "pidof $AppName")) {
            Start-Sleep -Seconds 0.5
        }
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
        # But, this approach does not block caller, thus we periodically check with adb command.
        # adb shell "while [ `"`$(pidof $AppName)`" ]; do (sleep 1); done" | Out-Null
        while (adb shell "pidof $AppName") {
            Start-Sleep -Seconds 0.5
        }
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
        [string]$AppName = '~',
        [switch]$ForceStopApp,
        [Int32]$TimeOut = 10
    )

    $AppName = Resolve-AppName $AppName "Abort stopping application."
    if (-not $AppName) {
        return
    }

    if ($TimeOut -lt 0) {
        $TimeOut = [Int32]::MaxValue
    }

    try {
        # Following approach not works for all devices.
        # adb shell "t=$TimeOut; while [ `"`$(pidof $AppName)`" ] && [ `$t -gt 0 ]; do sleep 1; t=`$((`$t - 1)); echo Waiting for $AppName in `$t secs; done"

        # Therefore, we periodically check app with adb command.
        while ((adb shell "pidof $AppName") -and ($TimeOut -gt 0)) {
            Start-Sleep -Seconds 1
            $TimeOut -= 1
        }

    } catch {
        Write-Host "Abort wating $AppName..."
    } finally {
        if ($ForceStopApp) {
            adb shell am force-stop $AppName
        }
    }
}

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
        [byte]$Duration,
        [ValidateNotNullOrEmpty()]
        [string]$Filename = "record",
        [switch]$OpenFileAfterRecording
    )

    $OutFileName = Get-EncodedFilename $Filename '.mp4'
    $DeviceFilePath = '/sdcard/record.mp4'
    try {
        if (!$Duration) {
            adb shell "screenrecord $DeviceFilePath"
        } else {
            Write-Host "Start recording for $Duration secs"
            adb shell "screenrecord --time-limit $Duration $DeviceFilePath"
        }
    } catch {
        Write-Host "Stop screen recording"
    } finally {
        adb pull $DeviceFilePath $OutFileName
        Write-Host "Saved screen recording to '$OutFilename'"

        if ($OpenFileAfterRecording) {
            Invoke-Item $OutFileName
        }
    }
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

.EXAMPLE
Start-Perfetto foobar 5s
Record a trace named foobar for 5 seconds.

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

    $CmdArgs = [System.Collections.ArrayList]@("-b", $Buffer)

    if ($Time) {
        $CmdArgs.AddRange(@("-t", $Time)) | Out-Null
    }

    if ($Filename) {
        $OutFileName = Get-EncodedFilename $Filename '.perfetto-trace'
        $CmdArgs.AddRange(@("-o", $OutFileName)) | Out-Null
    }

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
    param (
        $AppName = '~'
    )

    $MobileStudioPath = Resolve-Filepath $env:AGP_MALI_MOBILE_STUDIO 'AGP_MALI_MOBILE_STUDIO'
    $Version = Get-MobileStudioVersion $MobileStudioPath

    if ($Version -ge '2023.2') {
        $HasRootAccess = Confirm-RootAccess
        if ($HasRootAccess) {
            adb root
            $CmdArg = '--system-wide=yes'
        } else {
            # We can't capture system wide counters on non-rooted devices.
            # We need to specify target application for capturing.
            $AppName = Resolve-AppName $AppName "Abort starting application."
            if (-not $AppName) {
                return
            }

            $CmdArg = "-l $AppName"
        }

        adb push "$MobileStudioPath/streamline/bin/android/arm64/gatord" /data/local/tmp
        adb shell 'chmod 777 /data/local/tmp/gatord'
        adb shell "/data/local/tmp/gatord $CmdArg"
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
Invoke-PerformanceAdvisor -help

Show help flags of Performance Advisor in Mali Mobile Studio.

.EXAMPLE
Invoke-PerformanceAdvisor foo.apc -CustomReportTemplate Valhall

Import Streamline capture foo.apc and generate output report with template mali_pa_template_valhall.json.

.EXAMPLE
Invoke-PerformanceAdvisor foo.apc -ClipStart 100f -ClipEnd 500f

Import Streamline capture foo.apc and generate output between 100 to 500 frames.

.EXAMPLE
Invoke-PerformanceAdvisor foo.apc -ClipStart 100 -ClipEnd 500

Import Streamline capture foo.apc and generate output for 100 to 500ms.

.EXAMPLE
Invoke-PerformanceAdvisor foo.apc -ClipStart 100f -ClipEnd 500f

Import Streamline capture foo.apc and generate output for frames 100 to 500.

.EXAMPLE
Invoke-PerformanceAdvisor foo.apc -ChartListOutput bar.json

Output charts from foo.apc and save as bar.json.

.EXAMPLE
Invoke-PerformanceAdvisor foo.apc -ExtraArgs --build-name=FOO

Generate report with extra arguments --build-name.

.LINK
https://developer.arm.com/Tools%20and%20Software/Performance%20Advisor
#>
function Invoke-PerformanceAdvisor {
    param(
        [Alias("apc")]
        [string]$StreamlineCapture,
        [string]$CustomReport,
        [ValidateSet($null, "Valhall")]
        [string]$CustomReportTemplate,
        [string]$ChartListOutput,
        [string]$ClipStart,
        [string]$ClipEnd,
        [Int16]$TargetFPS = 60,
        [Alias("mspf")]
        [switch]$UseFrameTime,
        [switch]$Help,
        [string[]]$ExtraArgs
    )

    $CmdArgs = New-Object System.Collections.ArrayList
    if ($Help) {
        $CmdArgs.Add("--help") | Out-Null
    } else {
        if ($ChartListOutput) {
            $CmdArgs.Add("--chart-list-output=$ChartListOutput") | Out-Null
        } elseif ($CustomReport) {
            $CmdArgs.Add("--custom-report=$CustomReport") | Out-Null
        } elseif ($CustomReportTemplate -eq "Valhall") {
            $CmdArgs.Add("--custom-report=$PSScriptRoot/mali_pa_template_valhall.json") | Out-Null
        }

        if ($ClipStart) {
            $CmdArgs.Add("--clip-start=$ClipStart") | Out-Null
        }
        if ($ClipEnd) {
            $CmdArgs.Add("--clip-end=$ClipEnd") | Out-Null
        }
        if ($TargetFPS) {
            $CmdArgs.Add("--target-fps=$TargetFPS") | Out-Null
        }
        if ($UseFrameTime) {
            $CmdArgs.Add("--mspf") | Out-Null
        }

        $CmdArgs.Add($StreamlineCapture) | Out-Null
        $CmdArgs += $ExtraArgs
    }

    $MobileStudioPath = Resolve-Filepath $env:AGP_MALI_MOBILE_STUDIO 'AGP_MALI_MOBILE_STUDIO'
    $Version = Get-MobileStudioVersion $MobileStudioPath

    if ($Version -ge '2023.1') {
        & "$MobileStudioPath/streamline/Streamline-cli.exe" -pa $CmdArgs
    } else {
        & "$MobileStudioPath/performance_advisor/pa.exe" $CmdArgs
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
        [string] $Config,
        [UInt16] $Duration = 10,
        [string] $OutputName,
        [string] $OutputFolderPath = '.',
        [switch] $NoTimeStr,
        [switch] $ClearLayers,
        [switch] $GLES
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

    $ActivatedLayerConfig = 'adb shell settings get global gpu_debug_layers' | Invoke-Expression
    Write-Host "Activated layers: $ActivatedLayerConfig"

    $OutputFileName = if ($NoTimeStr) { $OutputName } else { Get-EncodedFilename $OutputName }
    $OutputFilePath = "$OutputFolderPath/$OutputFileName.apc.zip"
    $LwiOutDir = "$OutputFolderPath/lwi-out-$OutputFileName"
    $ProcArgs = "`"$ScriptPath`" --lwi-mode counters --lwi-api $API --package $AppName --headless $OutputFilePath --daemon `"$GatordPath`" --config $Config --lwi-out-dir $LwiOutDir"
    $StreamlineProc = Start-Process -FilePath python -ArgumentList $ProcArgs -WorkingDirectory . -PassThru -RedirectStandardError StreamlineCaptureStdErr.log

    if (-not $ClearLayers -and $ActivatedLayerConfig -ne 'null') {
        # Prepend previous active layers.
        $StreamlineLayerConfig = 'adb shell settings get global gpu_debug_layers' | Invoke-Expression
        adb shell settings put global gpu_debug_layers "$ActivatedLayerConfig`:$StreamlineLayerConfig"
    }

    Start-Sleep 10  # Wait for launch of Streamline

    Write-Host "Start $AppName"
    Start-DeviceApp $AppName -WaitForLaunch
    Write-Host "$AppName has been launched"

    Wait-DeviceApp $AppName -TimeOut $Duration -ForceStopApp
    $StreamlineProc.Close()
    Write-Host "Close $AppName"

    if ($ActivatedLayerConfig -ne 'null') {
        # Recover activated layer configuration.
        adb shell settings put global gpu_debug_layers $ActivatedLayerConfig
        Write-Host "Recover activated layers: $ActivatedLayerConfig"
    }

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

function Show-UnrealCommandLine {
    $UECmdLine = adb shell getprop debug.ue.commandline
    Write-Host "UE commandline: $UECmdLine"
}

<#
.SYNOPSIS
Enable csvprofile from UE commandline.

.PARAMETER Frames
Specifies frame count for csv profiling.

.PARAMETER FPS
Specifies FPS for fixed timestep.

.PARAMETER BenchmarkMode
Enable benchmark mode with fixed timestep and fixed random seed.

.LINK
https://gpuopen.com/learn/unreal-engine-performance-guide/#reducing-noise-in-profiling-results

.EXAMPLE
Enable-UnrealCsvProfile -FPS 60 -Frames 3600

Enable csvprofile for 3600 frames with 60FPS as fixed time step.

.EXAMPLE
Enable-UnrealCsvProfile -FPS 60 -Frames 3600 -BenchmarkMode

Enable csvprofile for 3600 frames with 60FPS fixed time step in benchmark mode.
#>
function Enable-UnrealCsvProfile {
    param (
        [uint]$Frames = 3600,
        [byte]$FPS = 60,
        [switch]$BenchmarkMode
    )

    $LastCommandLine = adb shell getprop debug.ue.commandline
    adb shell setprop debug.ue.commandline.bak "'$LastCommandLine'"

    $CmdArgs = New-Object System.Collections.ArrayList
    $CmdArgs.Add("-ExecCmds=`"csvprofile frames=$Frames`"") | Out-Null
    $CmdArgs.Add("-fps=$FPS") | Out-Null

    if ($BenchmarkMode) {
        # Ideally, we need to set '-nosound -noailogging -noverifygc -novsync' as well.
        $CmdArgs.Add("-benchmark -deterministic") | Out-Null
        $BenchmarkSeconds = $Frames / $FPS
        $CmdArgs.Add("-benchmarkseconds=$BenchmarkSeconds") | Out-Null
    }

    # Set commandline arguments to system property.
    # Caution: this config would be overrided by UECommandLine.txt.
    $CmdArgStr = $CmdArgs -join ' '
    adb shell setprop debug.ue.commandline "'$CmdArgStr'"

    Show-UnrealCommandLine
}

function Disable-UnrealCsvProfile {
    $LastCommandLine = adb shell getprop debug.ue.commandline.bak
    adb shell setprop debug.ue.commandline "'$LastCommandLine'"
    adb shell setprop debug.ue.commandline.bak "''"

    Show-UnrealCommandLine
}

<#
.SYNOPSIS
Get .csv profile from Unreal app when CSV profiling is enabled.

.DESCRIPTION
CSV profiling should be enabled via Enable-UnrealCsvProfile or custom UECommandLine.txt.

.PARAMETER AppName
Specifies package name to fetch its csv profile. It supports following fast-access options:
    ~ Focused application (i.e. foregraound activity).
    ? Select application name from package list.
    ! Last selected application name.

.PARAMETER LaunchNewAppExec
Launch new APP process for csv profiling.

.PARAMETER WaitForExit
Get .csv profile until running APP exits.

.LINK
Specify a URI to a help page, this will show when Get-Help -Online is used.

.EXAMPLE
Get-UnrealCsvProfile ? -LaunchNewAppExec

Select app name from installed apks and launch new app process for csv profiling.

.EXAMPLE
Get-UnrealCsvProfile ~ -WaitForExit

Get .csv profile of foreground app until the app exits.
#>
function Get-UnrealCsvProfile {
    param(
        [string]$AppName = '?',
        [string]$CsvName = 'Profile',
        [string]$OutputFolderPath = '.',
        [switch]$LaunchNewAppExec,
        [switch]$WaitForExit
    )

    $AppName = Resolve-AppName $AppName "Abort getting csv profile."
    if (-not $AppName) {
        Write-Warning("Not found valid application name.")
        return
    }

    Save-AppName $AppName

    if ($LaunchNewAppExec) {
        Stop-DeviceApp $AppName -WaitForExit
        Start-DeviceApp $AppName -WaitForLaunch
    }

    # TODO: Check if csvprofiling is enabled.

    # Compose folder path to fetch latest .csv file.
    $ProjectName = adb shell "ls /sdcard/Android/data/$AppName/files/UnrealGame"
    $CsvFolderOnDevice = "/sdcard/Android/data/$AppName/files/UnrealGame/$ProjectName/$ProjectName/Saved/Profiling/CSV"
    $LatestFileName = adb shell "ls $CsvFolderOnDevice | tail -1"
    if (-not ($LatestFileName -match "Profile\((\d+_\d+)\).csv")) {
        Write-Warning "Can't find valid csv filename!"
        return
    }

    $DateTimeStr = $Matches.1

    $CsvFilePathOnDevice = "$CsvFolderOnDevice/$LatestFileName"
    Write-Host("Writing to $CsvFilePathOnDevice")

    try {
        if ($LaunchNewAppExec -or $WaitForExit) {
            Wait-DeviceApp $AppName -TimeOut -1
        }
    } finally {
        $PidOnDevice = adb shell "pidof $AppName"
        if ($PidOnDevice) {
            do {
                $Choice = Read-Host "Do you want to stop '$AppName'? (Y/[N])"
                if (!$Choice) {
                    break
                } elseif ($Choice -eq 'y') {
                    Stop-DeviceApp $AppName -WaitForExit
                }
            } until ($Choice -match "[yn]")
        }

        New-Item -ItemType Directory -Force -Path $OutputFolderPath | Out-Null
        $FileName = "$CsvName`_$DateTimeStr.csv"
        $OutputFilePath = Join-Path $OutputFolderPath $FileName
        adb pull $CsvFilePathOnDevice $OutputFilePath
    }
}

enum UECsvProfilePreset {
    CPUFreq
    SystemMemory
    ThreadTime
    RenderThread
    GameThread
    RHI
    RDG
    DrawCall
    Shaders
    PSO
    RayTracing
    PassTime
}

<#
.SYNOPSIS
Convert CSV profile into interactive SVG file.

.DESCRIPTION
Assume the location of CSVToSVG.exe is already added to $env:Path environment variable.
[UnrealEngineDirectory]/Engine/Binaries/DotNET/CSVTools/CSVToSVG.exe

It provides presets with corresponding stats:

* CPUFreq: AndroidCPU/CPUFreq*
* SystemMemory: AndroidMemory/*
* ThreadTime: (FrameTime, GameThreadTime, RenderThreadTime, RHIThreadTime)
* RenderThread: Exclusive/RenderThread/*
* GameThread: Exclusive/GameThread/*
* RHI: RHI/*
* DrawCall: DrawCall/*
* Shaders: Shaders/*
* PSO: PSO/*
* RayTracing: RayTracingGeometry/*
* PassTime: PassTime/*

.PARAMETER Filepath
Specifies a .csv profile.

.PARAMETER ShowEvents
Specifies event names to show in the graph. Default is '*' (all events).

.PARAMETER Title
Specifies title of output figure. Can use placeholder '{0}' for Preset name.

.LINK
https://dev.epicgames.com/documentation/en-us/unreal-engine/csvtosvg-tool?application_version=4.27

.EXAMPLE
Convert-UnrealCsvToSvg foo.csv -Preset ThreadTime

Generate svg for (FrameTime, GameThreadTime, RenderThreadTime, RHIThreadTime).

.EXAMPLE
Convert-UnrealCsvToSvg foo.csv -Preset ThreadTime -MaxAutoY 100

Generate ThreadTime svg and clamp auto max Y value to 100.

.EXAMPLE
Convert-UnrealCsvToSvg foo.csv -Preset RenderThread -IgnoreStats Exclusive/RenderThread/EventWait

Generate RenderThread stats graph without Exclusive/RenderThread/EventWait.

.EXAMPLE
Convert-UnrealCsvToSvg foo.csv -Preset ThreadTime -Title "FOO: {0}"

Generate ThreadTime svg with title "FOO: ThreadTime" ({0} would be replaced with preset name).
#>
function Convert-UnrealCsvToSvg {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [string]$StartEvent,
        [string]$EndEvent,
        [string]$Title,
        [string]$IgnoreStats,
        [string]$OutputFileName,
        [string]$OutputFolderPath = ".",
        [single]$MinX,
        [single]$MaxX,
        [single]$MinY,
        [single]$MaxY,
        [single]$MaxAutoY,
        [single]$AvgThreshold,
        [uint]$SkipRows,
        [UECsvProfilePreset]$Preset = [UECsvProfilePreset]::ThreadTime,
        [string []]$ShowEvents = '*'
    )

    $CmdArgs = [System.Collections.ArrayList]@("-csvs", $Path, "-interactive", "-showAverages", "-stats")
    $PresetName = "Unknown"
    $HideStatPrefix = ""
    $StackTotalStat = $null

    if ($Preset -eq [UECsvProfilePreset]::RenderThread) {
        $StackTotalStat = "RenderThreadTime"
        $HideStatPrefix = "Exclusive/RenderThread/"
        $CmdArgs.AddRange(@("$HideStatPrefix*", $StackTotalStat)) | Out-Null
        $IgnoreStats += ";Exclusive/RenderThread/FetchVisibilityForPrimitives;Exclusive/RenderThread/EventWait*"
        $PresetName ="RenderThread"
    } elseif ($preset -eq [UECsvProfilePreset]::GameThread) {
        $StackTotalStat = "GameThreadTime"
        $HideStatPrefix = "Exclusive/GameThread/"
        $CmdArgs.AddRange(@("$HideStatPrefix*", $StackTotalStat)) | Out-Null
        $IgnoreStats += ";Exclusive/GameThread/EventWait*"
        $PresetName ="GameThread"
    } elseif ($preset -eq [UECsvProfilePreset]::RHI) {
        $HideStatPrefix = "RHI/"
        $CmdArgs.Add("$HideStatPrefix*") | Out-Null
        $PresetName ="RHI"
    } elseif ($preset -eq [UECsvProfilePreset]::RDG) {
        $HideStatPrefix = "RDGCount/"
        $CmdArgs.Add("$HideStatPrefix*") | Out-Null
        $PresetName ="RDG"
    } elseif ($preset -eq [UECsvProfilePreset]::DrawCall) {
        $HideStatPrefix = "DrawCall/"
        $CmdArgs.Add("$HideStatPrefix*") | Out-Null
        $PresetName ="DrawCall"
    } elseif ($preset -eq [UECsvProfilePreset]::Shaders) {
        $HideStatPrefix = "Shaders/"
        $CmdArgs.Add("$HideStatPrefix*") | Out-Null
        $PresetName ="Shaders"
    } elseif ($preset -eq [UECsvProfilePreset]::PSO) {
        $HideStatPrefix = "PSO/"
        $CmdArgs.Add("$HideStatPrefix*") | Out-Null
        $PresetName ="PSO"
    } elseif ($preset -eq [UECsvProfilePreset]::RayTracing) {
        $HideStatPrefix = "RayTracingGeometry/"
        $CmdArgs.Add("$HideStatPrefix*") | Out-Null
        $PresetName ="RayTracing"
    } elseif ($preset -eq [UECsvProfilePreset]::PassTime) {
        $HideStatPrefix = "PassTime/"
        $CmdArgs.Add("$HideStatPrefix*") | Out-Null
        $PresetName ="PassTime"
    } elseif ($preset -eq [UECsvProfilePreset]::CPUFreq) {
        $HideStatPrefix = "AndroidCPU/"
        $CmdArgs.Add("AndroidCPU/CPUFreq*") | Out-Null
        $PresetName ="CPUFreq"
    } elseif ($preset -eq [UECsvProfilePreset]::SystemMemory) {
        $HideStatPrefix = "AndroidMemory/"
        $CmdArgs.Add("$HideStatPrefix*") | Out-Null
        $PresetName ="SysMemory"
    } else {
        $CmdArgs.AddRange(@("FrameTime", "*ThreadTime")) | Out-Null
        $PresetName ="ThreadTime"
    }

    # Set stacked for stats with wildcards.
    if ($Preset -gt [UECsvProfilePreset]::ThreadTime) {
        $CmdArgs.Add("-stacked") | Out-Null
    }

    if ($ShowEvents) {
        $CmdArgs.Add("-showEvents") | Out-Null
        $CmdArgs.AddRange($ShowEvents) | Out-Null
    }

    if (! $Title) {
        # Use stat prefix as default title of figure.
        $Title = $HideStatPrefix
    } else {
        # Resolve {0} in $Title with preset name.
        $Title = $Title -f $PresetName
    }

    $ArgsMap = @(($StartEvent, "-startEvent"), ($EndEvent, "-endEvent"), ($Title, "-title"), ($HideStatPrefix, "-hideStatPrefix"),
                 ($StackTotalStat, "-stackTotalStat"), ($IgnoreStats, "-ignoreStats"), ($AvgThreshold, "-averageThreshold"), ($SkipRows, "-skipRows"))

    foreach ($Entity in $ArgsMap) {
        $ArgValue, $ArgName = $Entity[0], $Entity[1]
        if ($ArgValue) {
            $CmdArgs.AddRange(@($ArgName, $ArgValue)) | Out-Null
        }
    }

    $Ranges = @(($MinX, "-minX"), ($MaxX, "-maxX"), ($MinY, "-minY"), ($MaxY, "-maxY"), ($MaxAutoY, "-maxAutoMaxY"))
    foreach ($Entity in $Ranges) {
        $ArgValue, $ArgName = $Entity[0], $Entity[1]
        if ($ArgValue) {
            $CmdArgs.AddRange(@($ArgName, $ArgValue)) | Out-Null
        }
    }

    # Create output folder if it does not exist.
    New-Item -ItemType Directory -Force -Path $OutputFolderPath | Out-Null
    if (!$OutputFileName) {
        $OutputFileName = Split-Path $Path -LeafBase
        $OutputFileName += "_$PresetName.svg"
    }

    $OutputFilePath = Join-Path $OutputFolderPath $OutputFileName
    $CmdArgs.AddRange(@("-o", $OutputFilePath)) | Out-Null

    CSVToSVG.exe $CmdArgs
    Write-Host "Convert $Path to $OutputFilePath"
}

<#
.SYNOPSIS
Convert CSV files in a folder to SVG.

.NOTES
It provides presets with corresponding stats:

* ThreadTime: FrameTime, GameThreadTime, RenderThreadTime, RHIThreadTime
* Workload: RHI/DrawCalls, RHI/PrimitivesDrawn, GPUSceneInstanceCount, LightCount/All

.EXAMPLE
Convert-UnrealCsvDirToSvg .\foo -Preset ThreadTime

Compare .csv files in .\foo folder with ThreadTime preset (FrameTime, *ThreadTime).

.EXAMPLE
Convert-UnrealCsvDirToSvg .\foo -Preset ThreadTime -StartEvent bar

Compare .csv files in .\foo folder and aligned with event bar.

.EXAMPLE
Convert-UnrealCsvDirToSvg .\foo -StatName foobar

Compare .csv files in .\foo folder in terms of the stat named "foobar".

.EXAMPLE
Convert-UnrealCsvDirToSvg .\foo -Preset ThreadTime -Title "FOOBAR: {0}"

Generate a ThreadTime svg with title "FOOBAR: ThreadTime" ({0} would be replaced with preset name).
#>
function Convert-UnrealCsvDirToSvg {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [ValidateSet("ThreadTime", "Workload", "CPU", "Memory")]
        [string]$Preset,
        [string]$StatName,
        [string]$StartEvent,
        [string]$EndEvent,
        [string]$Title,
        [string]$OutputNamePrefix,
        [string]$OutputFolderPath = ".",
        [single]$MinX,
        [single]$MaxX,
        [single]$MinY,
        [single]$MaxY,
        [single]$MaxAutoY,
        [uint]$SkipRows,
        [string []]$ShowEvents = "*"
    )

    $CmdArgs = [System.Collections.ArrayList]@("-csvDir", $Path, "-interactive", "-showAverages")

    if ($ShowEvents) {
        $CmdArgs.Add("-showEvents") | Out-Null
        $CmdArgs.AddRange($ShowEvents) | Out-Null
    }

    $ArgsMap = @(($StartEvent, "-startEvent"), ($EndEvent, "-endEvent"), ($SkipRows, "-skipRows"))

    foreach ($Entity in $ArgsMap) {
        $ArgValue, $ArgName = $Entity[0], $Entity[1]
        if ($ArgValue) {
            $CmdArgs.AddRange(@($ArgName, $ArgValue)) | Out-Null
        }
    }

    $Ranges = @(($MinX, "-minX"), ($MaxX, "-maxX"), ($MinY, "-minY"), ($MaxY, "-maxY"), ($MaxAutoY, "-maxAutoMaxY"))
    foreach ($Entity in $Ranges) {
        $ArgValue, $ArgName = $Entity[0], $Entity[1]
        if ($ArgValue) {
            $CmdArgs.AddRange(@($ArgName, $ArgValue)) | Out-Null
        }
    }

    if ($Preset -eq "ThreadTime") {
        $StatNameList = @("FrameTime", "GameThreadTime", "RenderThreadTime", "RHIThreadTime")
    } elseif ($Preset -eq "Workload") {
        $StatNameList = @("RHI/DrawCalls", "RHI/PrimitivesDrawn", "RDGCount/Passes", "GPUSceneInstanceCount", "LightCount/All")
    } elseif ($Preset -eq "CPU") {
        $StatNameList = @("AndroidCPU/CPUFreqMHzGroup0", "AndroidCPU/CPUFreqMHzGroup1", "AndroidCPU/CPUFreqMHzGroup2", "AndroidCPU/CPUTemp",
                          "AndroidCPU/CPUFreqPercentageGroup0", "AndroidCPU/CPUFreqPercentageGroup1", "AndroidCPU/CPUFreqPercentageGroup2")
    } elseif ($Preset -eq "Memory") {
        $StatNameList = @("AndroidMemory/Mem_RSS", "AndroidMemory/Mem_Swap", "AndroidMemory/Mem_TotalUsed",
                          "RayTracingGeometry/TotalResidentSizeMB")
    } else {
        if (-not $StatName) {
            Write-Error("Please specify stat name for comparing.")
            return
        }

        $StatNameList = @($StatName)
    }

    # Create output folder if it does not exist.
    New-Item -ItemType Directory -Force -Path $OutputFolderPath | Out-Null

    # We could only set one stat for comparing multiple csv-profiles.
    foreach ($StatName in $StatNameList) {
        $FileName = $StatName.Replace("/", "_")
        if ($OutputNamePrefix) {
            $OutputFileName = "$OutputNamePrefix`_$FileName.svg"
        } else {
            $OutputFileName = "$FileName.svg"
        }

        $OutputFilePath = Join-Path $OutputFolderPath $OutputFileName

        $ArgList = $CmdArgs.Clone()
        $ArgList.AddRange(@("-o", $OutputFilePath, "-stats", $StatName)) | Out-Null

        if ($Title) {
            # Resolve placeholder {0} in title with stat name.
            # Note: Can't use named placeholder with PowerShell 7.4. Therefore, format with indexed placeholder instead.
            $FigureTitle = ($Title -f $StatName).Clone()

            # Note: We need to explicitly add quotes to figure title; otherwise ' ' would be replaced with ';' if we invoke csvtosvg by Start-Process.
            $ArgList.AddRange(@("-title", "`"$FigureTitle`"")) | Out-Null
        }

        Start-Process -FilePath CSVToSVG -ArgumentList $ArgList -WorkingDirectory . -PassThru -NoNewWindow
    }
}

<#
.SYNOPSIS
    Enable Vulkan debug markers for Debug/Develop built apk.
.NOTES
    We didn't configure start emitting RHI debug markers from commandline because it might slow down the app launch.
    Therefore, we use Start/Stop-UnrealDebugMarkerEmission to control emission of markers.
.LINK
    https://github.com/EpicGames/UnrealEngine/blob/release/Engine/Source/Runtime/VulkanRHI/Private/VulkanDevice.cpp#L485
#>
function Enable-UnrealDebugMarkers {
    $LastCommandLine = adb shell getprop debug.ue.commandline
    adb shell setprop debug.ue.commandline.bak "'$LastCommandLine'"
    adb shell setprop debug.ue.commandline "-forcevulkanddrawmarkers"
    Show-UnrealCommandLine
}

<#
.SYNOPSIS
Disable Vulkan debug markers.
#>
function Disable-UnrealDebugMarkers {
    $LastCommandLine = adb shell getprop debug.ue.commandline.bak
    adb shell setprop debug.ue.commandline "'$LastCommandLine'"
    adb shell setprop debug.ue.commandline.bak "''"
    Show-UnrealCommandLine
}

<#
.SYNOPSIS
Start emitting RHI debug markers of draw calls and RDG passes.

.NOTES
Previously, we need to set following CVars for different event types individually:
    r.ShowMaterialDrawEvents 1
    r.EmitMeshDrawEvents 1
    r.Nanite.ShowMeshDrawEvents 1
    r.RDG.Events 3

Now, we could set r.RHISetGPUCaptureOptions directly.
https://github.com/EpicGames/UnrealEngine/blob/2d53fcab0066b1f16dd956b227720841cad0f6f7/Engine/Source/Runtime/RHI/Private/RHI.cpp#L72
#>
function Start-UnrealDebugMarkerEmission {
    uecmd r.RHISetGPUCaptureOptions 1
}

<#
.SYNOPSIS
Stop emitting RHI debug markers of draw calls and RDG passes.
#>
function Stop-UnrealDebugMarkerEmission {
    uecmd r.RHISetGPUCaptureOptions 0
}

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

<#
.SYNOPSIS
Enable TCP connection between UnrealInsight and UnrealEditor.

.NOTES
Need at least one UnrealEditor instance for connecting UnrealInsight. (No need to open the same uproject of built apk)
#>
function Connect-UnrealInsight {
    param (
        [switch] $Memory,
        [switch] $LoadTime,
        [switch] $Stats
    )

    # Pass through TCP connections made on device over USB.
    adb reverse tcp:1980 tcp:1980

    $LastCommandLine = adb shell getprop debug.ue.commandline
    adb shell setprop debug.ue.commandline.bak "'$LastCommandLine'"

    # Detailed arguments https://dev.epicgames.com/documentation/en-us/unreal-engine/unreal-insights-reference-in-unreal-engine-5
    $Channels = [System.Collections.ArrayList]@("Default", "GPU")

    if ($Memory) {
        $Channels.Add('Memory') | Out-Null
    }

    if ($LoadTime) {
        $Channels.Add('LoadTime') | Out-Null
    }

    if ($Stats) {
        $Channels.Add('Stats') | Out-Null
    }

    $ChannelStr = $Channels -join ','

    adb shell setprop debug.ue.commandline "'-tracehost=127.0.0.1 -trace=$ChannelStr'"
    $UECmdLine = adb shell getprop debug.ue.commandline
    Write-Host "UnrealInsight config: $UECmdLine"

    $EditorProcess = Get-Process UnrealEditor -ErrorAction SilentlyContinue
    if ($EditorProcess) {
        Write-Host 'Found running UnrealEditor. Ready to connect UnrealInsight after launching apk.'
    } else {
        Write-Warning 'Not found any running process of UnrealEditor.'
        Write-Warning 'Remember to start UnrealEditor before connecting UnrealInsight!'
    }
}

function Disconnect-UnrealInsight {
    $LastCommandLine = adb shell getprop debug.ue.commandline.bak
    adb shell setprop debug.ue.commandline "'$LastCommandLine'"
    adb shell setprop debug.ue.commandline.bak "''"
}

<#
.SYNOPSIS
Save console variables to csv.
#>
function Save-UnrealCVars {
    param (
        [string] $OutputFileName = 'ConsoleVars.csv',
        [string] $OutputFolderPath = '.',
        [switch] $KeepFilesOnDevice
    )

    adb shell "logcat -c"
    uecmd DumpCVars -csv

    $Log = adb shell "logcat UE:D *:S -d | grep 'Saved/Logs/ConsoleVars.csv' | tail -1"
    Write-Host ">>$Log>>"
    if (-not ($Log -match "../../../((\w+)/(.+))/ConsoleVars.csv")) {
        Write-Warning "Can't find dumped data"
        return
    }

    $PackageName = Get-FocusedPackageName
    $AppName = $Matches.2
    $ParentFolderPath = "/storage/emulated/0/UnrealGame/$AppName"
    $FoundInEmulatedFolder = adb shell "ls $ParentFolderPath > dev/null 2>&1 && echo 'True'"
    if (-not $FoundInEmulatedFolder) {
        $ParentFolderPath = "/sdcard/Android/data/$PackageName/files/UnrealGame/$AppName"
    }

    $RelativePath = $Matches.1
    $DeviceOutFolderPath = ("$ParentFolderPath/$RelativePath").Replace('\', '/')
    $DeviceOutFillePath = "$DeviceOutFolderPath/ConsoleVars.csv"

    Write-Host $DeviceOutFillePath
    adb pull $DeviceOutFillePath "$OutputFolderPath/$OutputFileName"

    if (-not $KeepFilesOnDevice) {
        Write-Host "Clean ConsoleVars.csv on device."
        adb shell rm -r $DeviceOutFillePath
    }
}


# https://docs.unrealengine.com/5.0/en-US/gpudump-viewer-tool-in-unreal-engine/
function Save-UnrealGPUDump {
    param (
        [string] $OutputFolderPath = '.',
        [switch] $KeepFilesOnDevice
    )

    adb shell "logcat -c"
    uecmd DumpGPU

    $Log = adb shell "logcat UE:D *:S -d | grep 'DumpGPU dumped rendering cvars' | tail -1"
    Write-Host $Log
    if (-not ($Log -match "../../../((\w+)/(.+))/Base/ConsoleVariables.csv")) {
        Write-Warning "Can't find dumped data"
        return
    }

    $PackageName = Get-FocusedPackageName
    $AppName = $Matches.2
    $ParentFolderPath = "/sdcard/Android/data/$PackageName/files/UnrealGame/$AppName"

    $RelativePath = $Matches.1
    $DeviceOutFolderPath = ("$ParentFolderPath/$RelativePath").Replace('\', '/')

    Write-Host "Wait for dumping..."
    # TODO: Check status and redirect dumping progress to terminal.

    # Wait for dumping process. Typically it will show following two lines:
    # LogDumpGPU: Display: DumpGPU status = dumping
    # LogDumpGPU: Display: DumpGPU status = ok
    adb logcat -m 2 -e 'DumpGPU status' | Out-Null

    $FolderName = Split-Path -Leaf $DeviceOutFolderPath
    New-Item -ItemType Directory -Force -Path $OutputFolderPath | Out-Null
    Write-Host "Pulling GPUDump '$DeviceOutFolderPath'"
    adb pull $DeviceOutFolderPath "$OutputFolderPath/$FolderName"

    if (-not $KeepFilesOnDevice) {
        Write-Host "Clean GPUDump on device."
        adb shell rm -r $DeviceOutFolderPath
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

Set-Alias -Name uec2s -Value Convert-UnrealCsvToSvg
Set-Alias -Name uecd2s -Value Convert-UnrealCsvDirToSvg
Set-Alias -Name uest -Value Switch-UnrealStats
Set-Alias -Name ueshow -Value Show-UnrealRenderFeature
Set-Alias -Name uehide -Value Hide-UnrealRenderFeature