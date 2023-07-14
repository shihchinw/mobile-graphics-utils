# Quick Setup

1. Copy **AdbGamePerf** folder to one of the module search paths `$env:PSModulePath`.

   Ex. %USERPROFILE%/Documents/PowerShell/Modules

2. For development, use `Import-Module AdbGamePerf -Verbose -Force` to reload latest source.
3. For deployment, add following lines to the $PROFILE file:
   ```
   Import-Module AdbGamePerf
   Import-AGPConfig
   ```

# Usage Summary

For more details and examples of each command, please use `Get-Help` to get detailed descriptions.

## Android

|Command|Alias|Usage|
|-|-|-|
|Get-FocusedPackageName||Get name of focused package|
|Get-PackageNameList||Get names of installed packages on device|
|Save-DeviceScreenCap||Save screen capture on device to local PC|
|Save-DeviceScreenRecord||Save screen recording on device to local PC|
|Start-DeviceApp||Start application on device|
|Stop-DeviceApp||Stop application on device|
|Wait-DeviceApp||Wait for application on device with time out|
|Start-Perfetto||Start capturing Perfetto trace|
|Start-AndroidProfiler|saap|Launch installed Android profiler|
|Watch-Logcat|wl|Watch logcat of specific application|
|Show-MemoryInfo||Show memory info of focused package or whole system|
|Watch-MemoryInfo||Watch certain type of memory info from focused application|


## Mali

|Command|Alias|Usage|
|-|-|-|
|Start-StreamlineGator|sasg|Install and launch gator for following TCP connection|
|Save-StreamlineCapture|svsc|Save Streamline profile via headless capturing|
|Enable-LightWeightInterceptor|lwi|Enable interceptor to add Streamline annotations|
|Invoke-PerformanceAdvisor|ipa|Invoke Performance Advisor to generate report from Streamline capture|
|Invoke-MaliOfflineCompiler||Invoke offline compiler to compile a folder of shaders|


## Unreal Engine

|Command|Alias|Usage|
|-|-|-|
|Invoke-UnrealCommand|uecmd|Send console command to connected device|
|Start-UnrealFPSChart||Start FPS chart data capture on device|
|Stop-UnrealFPSChart||Stop FPS chart data capture on device|
|Start-UnrealStatFile||Start a statistics capture|
|Stop-UnrealStatFile||Stop current statistics capture|
|Start-UnrealInsight||Start a insight capture|
|Stop-UnrealInsight||Stop current insight capture and pull file to local PC|
|Save-UnrealGPUDump||Save GPU dump and pull files to local PC|
|Show-UnrealLogcat|uelog|Show logcat messages related to Unreal engine|
|Show-UnrealSynthBenchmark||Show results of SynthBenchmark|
|Switch-UnrealStats|uest|Toggle stat display on device screen|
|Show-UnrealRenderFeature|ueshow|Show rendering features|
|Hide-UnrealRenderFeature|uehide|Hide rendering features|