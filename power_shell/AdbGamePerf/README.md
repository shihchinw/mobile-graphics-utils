# Quick Setup

1. Copy **AdbGamePerf** folder to one of the module search paths `$env:PSModulePath`.

   Ex. %USERPROFILE%/Documents/PowerShell/Modules

2. For development, use `Import-Module AdbGamePerf -Verbose -Force` to reload latest source.
3. For deployment, add `Import-Module AdbGamePerf` to $PROFILE file.

# Usage Summary

For more details and examples of each command, please use `Get-Help` to get detailed descriptions.

## Android

|Command|Usage|
|-|-|
|Save-DeviceScreenCap|Save screen capture on device to local PC|
|Save-DeviceScreenRecord|Save screen recording on device to local PC|
|Start-Perfetto|Start capturing perfetto trace|
|Start-AndroidProfiler|Launch installed Android profiler|


## Unreal Engine

|Command|Usage|
|-|-|
|Invoke-UnrealCommand|Send console command to connected device|
|Start-UnrealFPSChart|Start FPS chart data capture on device|
|Stop-UnrealFPSChart|Stop FPS chart data capture on device|
|Start-UnrealStatFile|Start a statistics capture|
|Stop-UnrealStatFile|Stop current statistics capture|
|Start-UnrealInsight|Start a insight capture|
|Stop-UnrealInsight|Stop current insight capture and pull file to local PC|
|Show-UnrealLogcat|Show logcat messages related to Unreal engine|
|Show-UnrealSynthBenchmark|Show results of SynthBenchmark|
|Switch-UnrealStats|Toggle stat display on device screen|
|Show-UnrealRenderFeature|Show rendering features|
|Hide-UnrealRenderFeature|Hide rendering features|