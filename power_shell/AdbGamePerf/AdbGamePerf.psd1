#
# Module manifest for module 'AdbGamePerf'
#
# Generated by: Shih-Chin Weng
#
# Generated on: 2022/12/21
#

@{

# Script module or binary module file associated with this manifest.
RootModule = 'AdbGamePerf.psm1'

# Version number of this module.
ModuleVersion = '0.5.8'

# Supported PSEditions
# CompatiblePSEditions = @()

# ID used to uniquely identify this module
GUID = 'f7ca94a6-7f89-41a3-9415-05c0dcfc5111'

# Author of this module
Author = 'Shih-Chin Weng'

# Company or vendor of this module
CompanyName = 'Unknown'

# Copyright statement for this module
Copyright = '(c) Shih-Chin Weng. All rights reserved.'

# Description of the functionality provided by this module
Description = 'Handy commands for game perf profiling on Android'

# Minimum version of the PowerShell engine required by this module
PowerShellVersion = '5.0'

# Name of the PowerShell host required by this module
# PowerShellHostName = ''

# Minimum version of the PowerShell host required by this module
# PowerShellHostVersion = ''

# Minimum version of Microsoft .NET Framework required by this module. This prerequisite is valid for the PowerShell Desktop edition only.
# DotNetFrameworkVersion = ''

# Minimum version of the common language runtime (CLR) required by this module. This prerequisite is valid for the PowerShell Desktop edition only.
# ClrVersion = ''

# Processor architecture (None, X86, Amd64) required by this module
# ProcessorArchitecture = ''

# Modules that must be imported into the global environment prior to importing this module
# RequiredModules = @()

# Assemblies that must be loaded prior to importing this module
# RequiredAssemblies = @()

# Script files (.ps1) that are run in the caller's environment prior to importing this module.
# ScriptsToProcess = @()

# Type files (.ps1xml) to be loaded when importing this module
# TypesToProcess = @()

# Format files (.ps1xml) to be loaded when importing this module
# FormatsToProcess = @()

# Modules to import as nested modules of the module specified in RootModule/ModuleToProcess
# NestedModules = @()

# Functions to export from this module, for best performance, do not use wildcards and do not delete the entry, use an empty array if there are no functions to export.
FunctionsToExport = @(
    'Import-AGPConfig',
    'Get-FocusedPackageName', 'Get-PackageNameList',
    'Watch-Logcat',
    'Show-MemoryInfo', 'Watch-MemoryInfo',
    'Save-DeviceScreenCap',
    'Save-DeviceScreenRecord',
    'Start-DeviceApp', 'Stop-DeviceApp', 'Wait-DeviceApp',
    'Start-Perfetto', 'Start-AndroidProfiler',
    'Start-StreamlineGator',
    'Enable-LightWeightInterceptor',
    'Invoke-PerformanceAdvisor',
    'Invoke-MaliOfflineCompiler',
    'Save-StreamlineCapture',
    'Invoke-UnrealCommand',
    'Show-UnrealCommandLine',
    'Enable-UnrealCsvProfile', 'Disable-UnrealCsvProfile',
    'Get-UnrealCsvProfile',
    'Convert-UnrealCsvToSvg', 'Convert-UnrealCsvDirToSvg'
    'Enable-UnrealDebugMarkers', 'Disable-UnrealDebugmarkers',
    'Start-UnrealDebugMarkerEmission', 'Stop-UnrealDebugMarkerEmission',
    'Start-UnrealFPSChart', 'Stop-UnrealFPSChart',
    'Start-UnrealStatFile', 'Stop-UnrealStatFile',
    'Start-UnrealInsight', 'Stop-UnrealInsight',
    'Connect-UnrealInsight', 'Disconnect-UnrealInsight',
    'Save-UnrealCVars', 'Save-UnrealGPUDump',
    'Export-UnrealCallStats',
    'Show-UnrealSynthBenchmark',
    'Show-UnrealRenderFeature', 'Hide-UnrealRenderFeature',
    'Switch-UnrealStats')

# Cmdlets to export from this module, for best performance, do not use wildcards and do not delete the entry, use an empty array if there are no cmdlets to export.
CmdletsToExport = @()

# Variables to export from this module
VariablesToExport = '*'

# Aliases to export from this module, for best performance, do not use wildcards and do not delete the entry, use an empty array if there are no aliases to export.
AliasesToExport = @('wl', 'saap', 'sasg', 'svsc', 'ipa', 'lwi', 'uecmd', 'uec2s', 'uecd2s', 'uest', 'ueshow', 'uehide')

# DSC resources to export from this module
# DscResourcesToExport = @()

# List of all modules packaged with this module
# ModuleList = @()

# List of all files packaged with this module
FileList = @('record_android_trace', 'shader_profile.py', 'mali_pa_template_valhall.json')

# Private data to pass to the module specified in RootModule/ModuleToProcess. This may also contain a PSData hashtable with additional module metadata used by PowerShell.
PrivateData = @{

    PSData = @{

        # Tags applied to this module. These help with module discovery in online galleries.
        # Tags = @()

        # A URL to the license for this module.
        # LicenseUri = ''

        # A URL to the main website for this project.
        # ProjectUri = ''

        # A URL to an icon representing this module.
        # IconUri = ''

        # ReleaseNotes of this module
        # ReleaseNotes = ''

        # Prerelease string of this module
        # Prerelease = ''

        # Flag to indicate whether the module requires explicit user acceptance for install/update/save
        # RequireLicenseAcceptance = $false

        # External dependent modules of this module
        # ExternalModuleDependencies = @()

    } # End of PSData hashtable

} # End of PrivateData hashtable

# HelpInfo URI of this module
# HelpInfoURI = ''

# Default prefix for commands exported from this module. Override the default prefix using Import-Module -Prefix.
# DefaultCommandPrefix = ''

}

