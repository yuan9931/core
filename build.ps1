[CmdletBinding()]
Param(
    [Parameter(Position=0,Mandatory=$false,ValueFromRemainingArguments=$true)]
    [string[]]$BuildArguments,

    # Skip loading the Visual Studio developer environment (vcvars64).
    # Only needed when this shell has already initialised it.
    [switch]$NoMSVC,

    # Skip downloading the prebuilt native dependencies (SDL3 / OpenAL).
    [switch]$NoRestoreDeps,

    # Always delete the CMake cache instead of repairing it only when poisoned.
    [switch]$CleanCMakeCache
)

Write-Output "PowerShell $($PSVersionTable.PSEdition) version $($PSVersionTable.PSVersion)"

Set-StrictMode -Version 2.0; $ErrorActionPreference = "Stop"; $ConfirmPreference = "None"; trap { Write-Error $_ -ErrorAction Continue; exit 1 }

# Resolve the script directory BEFORE it is used as a path. Guarded so the script
# still behaves when dot-sourced or pasted into a shell.
if ([string]::IsNullOrEmpty($PSScriptRoot)) {
    $PSScriptRoot = if ($MyInvocation.MyCommand.Path) { Split-Path $MyInvocation.MyCommand.Path -Parent } else { (Get-Location).Path }
}

# NUKE locates RootDirectory by walking UP from the *current working directory*
# looking for the '.nuke' directory. This script never changed directory, so it
# only worked when launched from inside the repository (which is what build.cmd
# does). Launching it from anywhere else made _build.exe die with:
#   TypeInitializationException: Could not locate '.nuke' directory/file
# Walk up from the script's own location to find the root, then move there.
$RepoRoot = $PSScriptRoot
while ($RepoRoot -and -not (Test-Path (Join-Path $RepoRoot '.nuke'))) {
    $parent = Split-Path $RepoRoot -Parent
    if ($parent -eq $RepoRoot -or [string]::IsNullOrEmpty($parent)) { break }
    $RepoRoot = $parent
}
if (-not $RepoRoot -or -not (Test-Path (Join-Path $RepoRoot '.nuke'))) {
    throw "Could not locate the repository root (no '.nuke' directory found in any parent of '$PSScriptRoot')."
}
[System.IO.Directory]::SetCurrentDirectory($RepoRoot)
Set-Location -LiteralPath $RepoRoot

###########################################################################
# CONFIGURATION
###########################################################################

$BuildProjectFile = Join-Path $PSScriptRoot 'build/_build.csproj'
$TempDirectory = Join-Path $PSScriptRoot '.nuke/temp'

$DotNetGlobalFile = Join-Path $PSScriptRoot 'global.json'
$DotNetInstallUrl = "https://dot.net/v1/dotnet-install.ps1"
$DotNetChannel = "STS"

$env:DOTNET_CLI_TELEMETRY_OPTOUT = 1
$env:DOTNET_NOLOGO = 1

###########################################################################
# HELPERS
###########################################################################

function ExecSafe([scriptblock] $cmd) {
    & $cmd
    if ($LASTEXITCODE) { exit $LASTEXITCODE }
}

function Write-Step([string] $message) {
    Write-Output "==> $message"
}

# If dotnet CLI is installed globally and it matches requested version, use for execution
if ($null -ne (Get-Command "dotnet" -ErrorAction SilentlyContinue) -and `
     $(dotnet --version) -and $LASTEXITCODE -eq 0) {
    $env:DOTNET_EXE = (Get-Command "dotnet").Path
}
else {
    # Download install script (use the shell script on non-Windows hosts)
    New-Item -ItemType Directory -Path $TempDirectory -Force | Out-Null

    # If global.json exists, load expected version
    $DotNetVersion = $null
    if (Test-Path $DotNetGlobalFile) {
        $DotNetGlobal = $(Get-Content $DotNetGlobalFile | Out-String | ConvertFrom-Json)
        if ($DotNetGlobal.PSObject.Properties["sdk"] -and $DotNetGlobal.sdk.PSObject.Properties["version"]) {
            $DotNetVersion = $DotNetGlobal.sdk.version
        }
    }

    if ($IsWindows -or (-not (Test-Path Variable:IsWindows))) {
        $DotNetInstallFile = Join-Path $TempDirectory 'dotnet-install.ps1'
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        (New-Object System.Net.WebClient).DownloadFile($DotNetInstallUrl, $DotNetInstallFile)

        $DotNetDirectory = Join-Path $TempDirectory 'dotnet-win'
        if (-not $DotNetVersion) {
            ExecSafe { & powershell $DotNetInstallFile -InstallDir $DotNetDirectory -Channel $DotNetChannel -NoPath }
        } else {
            ExecSafe { & powershell $DotNetInstallFile -InstallDir $DotNetDirectory -Version $DotNetVersion -NoPath }
        }
        $env:DOTNET_EXE = Join-Path $DotNetDirectory 'dotnet.exe'
    } else {
        $DotNetInstallFile = Join-Path $TempDirectory 'dotnet-install.sh'
        (New-Object System.Net.WebClient).DownloadFile('https://dot.net/v1/dotnet-install.sh', $DotNetInstallFile)

        $DotNetDirectory = Join-Path $TempDirectory 'dotnet-linux'
        $versionArgs = if ($DotNetVersion) { @('--version', $DotNetVersion) } else { @('--channel', $DotNetChannel) }
        ExecSafe { & bash $DotNetInstallFile @versionArgs --install-dir $DotNetDirectory --no-path }
        $env:DOTNET_EXE = Join-Path $DotNetDirectory 'dotnet'
    }
    $env:PATH = "$DotNetDirectory;$env:PATH"
}

Write-Output "Microsoft (R) .NET SDK version $(& $env:DOTNET_EXE --version)"
Write-Output "Repository root: $RepoRoot"

###########################################################################
# BUILD ENVIRONMENT
#
# Everything below exists because this script previously only succeeded in an
# environment that CI assembles out-of-band, never in a plain shell and not
# reliably in a Developer Command Prompt either. Each step is non-fatal where it
# sensibly can be, so a genuinely broken machine reports a clear cause instead
# of an obscure toolchain error.
###########################################################################

# ---------------------------------------------------------------------------
# Visual Studio developer environment (Windows only).
#
# The win-x64-* CMake presets hardcode CMAKE_C_COMPILER=cl.exe, and
# sources/native/CMakeLists.txt assumes MSVC:
#   add_compile_options($<$<CXX_COMPILER_ID:MSVC>:/MP...>)
#   set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreadedDLL")
# Without vcvars the configure step dies with
#   "The CMAKE_C_COMPILER: cl.exe is not a full path and was not found in the PATH".
# If cl.exe is already resolvable we assume an initialised shell and do nothing.
#
# On Linux/macOS the MSVC block is skipped entirely: ProgramFiles variables do
# not exist there and StrictMode would fail the Join-Path binding.
# ---------------------------------------------------------------------------
$VcVarsCandidates = [System.Collections.Generic.List[string]]::new()
$isWindowsHost = $IsWindows -or (-not (Test-Path Variable:IsWindows))
if ($isWindowsHost) {
    if ($env:VCINSTALLDIR) {
        $VcVarsCandidates.Add((Join-Path $env:VCINSTALLDIR 'Auxiliary\Build\vcvars64.bat'))
    }
    if (${env:ProgramFiles(x86)}) {
        $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
        if (Test-Path $vswhere) {
            $vsInstall = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null
            if ($vsInstall) {
                $VcVarsCandidates.Add((Join-Path $vsInstall 'VC\Auxiliary\Build\vcvars64.bat'))
            }
        }
    }
    foreach ($vsRoot in @("$env:ProgramFiles\Microsoft Visual Studio\2022", "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022")) {
        if (-not $vsRoot) { continue }
        foreach ($edition in @('Enterprise','Professional','Community','BuildTools')) {
            $VcVarsCandidates.Add((Join-Path $vsRoot "$edition\VC\Auxiliary\Build\vcvars64.bat"))
        }
    }
}

# vcvars64.bat sets DOTNET_ROOT. It is filtered out because redirecting the SDK
# root can break the .NET SDK resolution the rest of this script depends on.
$VcVarsSkipVariables = @('DOTNET_ROOT','DOTNET_ROOT(x86)','DOTNET_ROOT_X64','DOTNET_ROOT_X86')

function Import-VcVars {
    param([string] $VcVarsPath)

    $before = @{}
    Get-ChildItem Env: | ForEach-Object { $before[$_.Name] = $_.Value }

    $vcOutput = & cmd.exe /d /s /c "call `"$VcVarsPath`" >nul 2>&1 && set"
    if ($LASTEXITCODE -ne 0) { return $false }

    foreach ($line in $vcOutput) {
        $index = $line.IndexOf('=')
        if ($index -le 0) { continue }
        $name  = $line.Substring(0, $index)
        $value = $line.Substring($index + 1)
        if ($VcVarsSkipVariables -contains $name) { continue }
        if (-not $before.ContainsKey($name) -or $before[$name] -ne $value) {
            Set-Item -Path "Env:$name" -Value $value
        }
    }
    return $true
}

$msvcReady = $null -ne (Get-Command cl.exe -ErrorAction SilentlyContinue)
if ($msvcReady) {
    Write-Step "MSVC already available: $((Get-Command cl.exe).Source)"
} elseif ($NoMSVC) {
    Write-Step "Skipping MSVC setup (-NoMSVC); cmake will fail if cl.exe is unavailable"
} else {
    $vcVars = $VcVarsCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $vcVars) {
        Write-Warning "No vcvars64.bat found (Visual Studio with the C++ workload is required for the native build)."
    } elseif (Import-VcVars $vcVars) {
        $cl = Get-Command cl.exe -ErrorAction SilentlyContinue
        if ($cl) { Write-Step "MSVC environment loaded from $vcVars" } else { Write-Warning "vcvars64.bat ran but cl.exe is still not resolvable." }
    } else {
        Write-Warning "vcvars64.bat failed: $vcVars"
    }
}

# ---------------------------------------------------------------------------
# Native dependencies.
#
# hashlink's .gitignore excludes /include/sdl and /include/openal, so those dep
# trees are not in the repository. Nothing in the repo downloads them; only the
# CI workflow does, by hand:
#   SDL3-devel-3.4.16-VC.zip   -> include/sdl
#   openal-soft-1.25.2-bin.zip -> include/openal
# Without them cmake fails at hdlls/libs/sdl with "Could not find a package
# configuration file provided by SDL3".
# ---------------------------------------------------------------------------
$NativeSourceRoot = Join-Path $RepoRoot 'sources/native'
$HashlinkInclude  = Join-Path $NativeSourceRoot '3rd/hashlink/include'

function Get-NativeDependencies {
    return @(
        [pscustomobject]@{
            Name     = 'openal'
            Url      = 'https://github.com/kcat/openal-soft/releases/download/1.25.2/openal-soft-1.25.2-bin.zip'
            FileName = 'openal-soft-1.25.2-bin.zip'
            Extract  = 'openal-soft-1.25.2-bin'
        }
        [pscustomobject]@{
            Name     = 'sdl'
            Url      = 'https://github.com/libsdl-org/SDL/releases/download/release-3.4.16/SDL3-devel-3.4.16-VC.zip'
            FileName = 'SDL3-devel-3.4.16-VC.zip'
            Extract  = 'SDL3-3.4.16'
        }
    )
}

function Test-NativeDependencies {
    if (-not (Test-Path $HashlinkInclude)) { return $false }
    foreach ($dep in (Get-NativeDependencies)) {
        if (-not (Test-Path (Join-Path $HashlinkInclude $dep.Name))) { return $false }
    }
    return $true
}

function Restore-NativeDependencies {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    New-Item -ItemType Directory -Path $HashlinkInclude -Force | Out-Null

    foreach ($dep in (Get-NativeDependencies)) {
        $destination = Join-Path $HashlinkInclude $dep.Name
        if (Test-Path $destination) { continue }

        $zipPath = Join-Path $HashlinkInclude $dep.FileName
        Write-Step "Downloading $($dep.Name) from $($dep.Url)"
        try {
            Invoke-WebRequest -Uri $dep.Url -OutFile $zipPath -UseBasicParsing
        } catch {
            Write-Warning "Failed to download $($dep.Name): $($_.Exception.Message)"
            continue
        }

        $extracted = Join-Path $HashlinkInclude $dep.Extract
        try {
            if (Test-Path $extracted) { Remove-Item -Recurse -Force $extracted }
            Expand-Archive -LiteralPath $zipPath -DestinationPath $HashlinkInclude -Force
            if (-not (Test-Path $extracted)) { throw "expected '$extracted' after extracting $($dep.FileName)" }
            Move-Item -LiteralPath $extracted -Destination $destination -Force
        } catch {
            Write-Warning "Failed to extract $($dep.Name): $($_.Exception.Message)"
        } finally {
            if (Test-Path $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
        }
    }
}

if (-not $isWindowsHost) {
    # On Linux the native dependencies come from system packages
    # (libsdl3-dev, libopenal-dev, ... installed by CI); the VC zip bundles
    # below are Windows-only and would break the pkg-config based CMake find.
    Write-Step "Skipping Windows native dependency restore (non-Windows host)"
} elseif (Test-NativeDependencies) {
    Write-Step "Native dependencies present (SDL3, OpenAL)"
} elseif ($NoRestoreDeps) {
    Write-Warning "Native dependencies are missing and -NoRestoreDeps was given; cmake will fail at hdlls/libs/sdl."
} else {
    Restore-NativeDependencies
    if (Test-NativeDependencies) {
        Write-Step "Native dependencies restored"
    } else {
        Write-Warning "Native dependencies are still incomplete; cmake will fail at hdlls/libs/sdl."
    }
}

# ---------------------------------------------------------------------------
# CMake cache repair.
#
# CMake only runs its compiler test the first time, i.e. when no cache exists.
# If a cache was ever written with a non-MSVC linker (an earlier configure that
# picked up MinGW's ld.exe from PATH), CMake silently reuses it forever and the
# MSVC compiler test link fails with:
#   ld.exe: cannot find /nologo: No such file or directory
# A poisoned cache is not self-healing, so drop the tree before configuring.
# ---------------------------------------------------------------------------
$NativeOutputRoot = Join-Path $NativeSourceRoot 'out'
$CMakeCacheFile   = Join-Path $NativeOutputRoot 'build/win-x64-debug/CMakeCache.txt'
$MSVCBinFragment  = 'VC\Tools\MSVC'

function Test-CMakeCachePoisoned {
    if (-not (Test-Path $CMakeCacheFile)) { return $false }
    $contaminated = Get-Content $CMakeCacheFile |
        Select-String -Pattern '^CMAKE_(LINKER|AR|NM|OBJDUMP|OBJCOPY|RANLIB|STRIP|DLLTOOL|READELF|ADDR2LINE):' |
        Where-Object { $_.Line -notmatch [regex]::Escape($MSVCBinFragment) }
    return [bool]$contaminated
}

if ($CleanCMakeCache) {
    if (Test-Path $NativeOutputRoot) {
        Write-Step "Removing $NativeOutputRoot (-CleanCMakeCache)"
        Remove-Item -LiteralPath $NativeOutputRoot -Recurse -Force
    }
} elseif (Test-CMakeCachePoisoned) {
    Write-Step "CMake cache points at a non-MSVC linker/archiver; removing $NativeOutputRoot"
    Remove-Item -LiteralPath $NativeOutputRoot -Recurse -Force
}

# ---------------------------------------------------------------------------
# MDK root.
#
# sources/ModCore.Assets references the DeadCellsCoreModding.MDK NuGet package,
# whose props file requires DCCM_MDK_ROOT and then imports
#   $(DCCM_MDK_ROOT)\build\build.props
# Without it the BuildAssets target fails with "The installed Dead Cells Core
# Modding MDK was not found". CI gets this from the setup-mdk action; the
# project's own bin\core\mdk\install.ps1 does it via
# "DCCMTool internal install-mdk", which persists the variable for the user.
# Here we only set it for this process when that tree has already been built.
# ---------------------------------------------------------------------------
$MdkRoot = Join-Path $RepoRoot 'bin/core/mdk'
if ($env:DCCM_MDK_ROOT) {
    Write-Step "DCCM_MDK_ROOT already set: $env:DCCM_MDK_ROOT"
} elseif (Test-Path (Join-Path $MdkRoot 'build/build.props')) {
    $env:DCCM_MDK_ROOT = $MdkRoot
    Write-Step "DCCM_MDK_ROOT = $MdkRoot"
} else {
    Write-Warning "MDK not found at $MdkRoot; BuildAssets will fail unless the MDK is installed (run bin/core/mdk/install.ps1)."
}

###########################################################################
# EXECUTION
###########################################################################

if (Test-Path env:NUKE_ENTERPRISE_TOKEN) {
    & $env:DOTNET_EXE nuget remove source "nuke-enterprise" > $null
    & $env:DOTNET_EXE nuget add source "https://f.feedz.io/nuke/enterprise/nuget" --name "nuke-enterprise" --username "PAT" --password $env:NUKE_ENTERPRISE_TOKEN > $null
}

ExecSafe { & $env:DOTNET_EXE build $BuildProjectFile /nodeReuse:false /p:UseSharedCompilation=false -nologo -clp:NoSummary --verbosity quiet }
ExecSafe { & $env:DOTNET_EXE run --project $BuildProjectFile --no-build -- $BuildArguments }
