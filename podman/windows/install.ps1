# MiloClaw Installer for Windows - PowerShell 5.1 Compatible

param(
    [int]$MaxRetries = 3
)
$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "  MiloClaw Installer" -ForegroundColor Cyan
Write-Host ""

# Installation directory
$InstallDir = Join-Path $env:USERPROFILE "miloclaw"
$OpenClawDir = Join-Path $InstallDir ".openclaw"
$WorkspaceDir = Join-Path $OpenClawDir "workspace"

# File URLs
$MiloClawBaseUrl = "https://raw.githubusercontent.com/ztj7728/miloclaw-installer/refs/heads/main/podman/windows"
$ComposeUrl = "$MiloClawBaseUrl/compose.yml"
$EnvExampleUrl = "$MiloClawBaseUrl/.env.example"
$ConfigUrl = "$MiloClawBaseUrl/.openclaw/openclaw.json"
$StartupBatUrl = "$MiloClawBaseUrl/start-miloclawgateway-podman-compose.bat"

# Gemini skill URLs
$GeminiSkillBaseUrl = "https://raw.githubusercontent.com/ztj7728/gemini-image-generation/refs/heads/main"
# ============================================================================
# Utility Functions
# ============================================================================

function Write-Step {
    param([string]$Message)
    Write-Host "[*] $Message" -ForegroundColor Yellow
}

function Write-Success {
    param([string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Write-Info {
    param([string]$Message)
    Write-Host "[i] $Message" -ForegroundColor Cyan
}

function Write-Retry {
    param([string]$Message)
    Write-Host "[↻] $Message" -ForegroundColor Magenta
}

function Test-Command {
    param([string]$Command)
    try {
        Get-Command $Command -ErrorAction Stop | Out-Null
        return $true
    } catch {
        return $false
    }
}

function New-RandomToken {
    param(
        [int]$Length = 48
    )

    $chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    $bytes = New-Object byte[] ($Length)
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $result = -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
    return $result
}

function Read-ApiKey {
    param(
        [string]$PromptText = "Please Enter MiloClaw Key"
    )

    do {
        $apiKey = Read-Host -Prompt $PromptText
        if ([string]::IsNullOrWhiteSpace($apiKey)) {
            Write-Host "Not allowed to be empty" -ForegroundColor Yellow
        }
    } while ([string]::IsNullOrWhiteSpace($apiKey))

    return $apiKey.Trim()
}

function Set-EnvValue {
    param(
        [string]$EnvFile,
        [string]$Key,
        [string]$Value
    )

    if (-not (Test-Path $EnvFile)) {
        throw ".env file not found: $EnvFile"
    }

    $content = Get-Content $EnvFile -Raw

    if ($content -match "(?m)^$([regex]::Escape($Key))=") {
        $content = [regex]::Replace(
            $content,
            "(?m)^$([regex]::Escape($Key))=.*$",
            "$Key=$Value"
        )
    } else {
        if (-not $content.EndsWith("`n")) {
            $content += "`n"
        }
        $content += "$Key=$Value`n"
    }

    [System.IO.File]::WriteAllText($EnvFile, $content, (New-Object System.Text.UTF8Encoding($false)))
}

function Ensure-JsonPathObject {
    param(
        [Parameter(Mandatory = $true)]$ParentObject,
        [Parameter(Mandatory = $true)][string]$PropertyName
    )

    $prop = $ParentObject.PSObject.Properties[$PropertyName]
    if (-not $prop -or $null -eq $prop.Value) {
        $ParentObject | Add-Member -MemberType NoteProperty -Name $PropertyName -Value ([pscustomobject]@{}) -Force
    }
}

function Ensure-JsonProperty {
    param(
        [Parameter(Mandatory = $true)]$ParentObject,
        [Parameter(Mandatory = $true)][string]$PropertyName,
        [Parameter(Mandatory = $true)]$Value
    )

    $prop = $ParentObject.PSObject.Properties[$PropertyName]
    if ($prop) {
        $ParentObject.$PropertyName = $Value
    } else {
        $ParentObject | Add-Member -MemberType NoteProperty -Name $PropertyName -Value $Value -Force
    }
}

function Update-OpenClawConfig {
    param(
        [string]$ConfigFile,
        [string]$Token,
        [string]$ApiKey
    )

    if (-not (Test-Path $ConfigFile)) {
        throw "Config file not found: $ConfigFile"
    }

    $jsonText = Get-Content $ConfigFile -Raw
    $config = $jsonText | ConvertFrom-Json

    if (-not $config) {
        $config = [pscustomobject]@{}
    }

    # gateway.auth.token
    Ensure-JsonPathObject -ParentObject $config -PropertyName "gateway"
    Ensure-JsonPathObject -ParentObject $config.gateway -PropertyName "auth"
    Ensure-JsonProperty -ParentObject $config.gateway.auth -PropertyName "token" -Value $Token

    # agents.defaults.memorySearch.remote.apiKey
    Ensure-JsonPathObject -ParentObject $config -PropertyName "agents"
    Ensure-JsonPathObject -ParentObject $config.agents -PropertyName "defaults"
    Ensure-JsonPathObject -ParentObject $config.agents.defaults -PropertyName "memorySearch"
    Ensure-JsonPathObject -ParentObject $config.agents.defaults.memorySearch -PropertyName "remote"
    Ensure-JsonProperty -ParentObject $config.agents.defaults.memorySearch.remote -PropertyName "apiKey" -Value $ApiKey

    # models.providers.MiloClaw.apiKey
    Ensure-JsonPathObject -ParentObject $config -PropertyName "models"
    Ensure-JsonPathObject -ParentObject $config.models -PropertyName "providers"
    Ensure-JsonPathObject -ParentObject $config.models.providers -PropertyName "MiloClaw"
    Ensure-JsonProperty -ParentObject $config.models.providers."MiloClaw" -PropertyName "apiKey" -Value $ApiKey

    # skills.entries.gemini-image-generation.env.GEMINI_API_KEY
    Ensure-JsonPathObject -ParentObject $config -PropertyName "skills"
    Ensure-JsonPathObject -ParentObject $config.skills -PropertyName "entries"
    Ensure-JsonPathObject -ParentObject $config.skills.entries -PropertyName "gemini-image-generation"
    Ensure-JsonPathObject -ParentObject $config.skills.entries."gemini-image-generation" -PropertyName "env"
    Ensure-JsonProperty -ParentObject $config.skills.entries."gemini-image-generation".env -PropertyName "GEMINI_API_KEY" -Value $ApiKey

    $newJson = $config | ConvertTo-Json -Depth 100
    [System.IO.File]::WriteAllText($ConfigFile, $newJson, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-FileFromUrl {
    param([string]$Url, [string]$Destination)

    $fileName = Split-Path $Destination -Leaf
    Write-Step "Downloading $fileName..."

    $parentDir = Split-Path $Destination -Parent
    if (-not (Test-Path $parentDir)) {
        New-Item -ItemType Directory -Force -Path $parentDir | Out-Null
    }

    $oldProgressPreference = $ProgressPreference
    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
    } finally {
        $ProgressPreference = $oldProgressPreference
    }

    Write-Success "$fileName downloaded"
}

function New-DesktopUrlShortcut {
    param(
        [string]$Name,
        [string]$Url
    )

    $desktop = [Environment]::GetFolderPath("Desktop")
    $shortcutPath = Join-Path $desktop "$Name.url"

    $content = @"
[InternetShortcut]
URL=$Url
"@

    Set-Content -Path $shortcutPath -Value $content -Encoding ASCII
    Write-Success "Desktop shortcut created: $shortcutPath"
}

function New-Shortcut {
    param(
        [string]$TargetPath,
        [string]$ShortcutPath,
        [string]$WorkingDirectory = ""
    )

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($ShortcutPath)
    $shortcut.TargetPath = $TargetPath

    if ($WorkingDirectory) {
        $shortcut.WorkingDirectory = $WorkingDirectory
    }

    $shortcut.Save()
}

function Wait-PodmanReady {
    param(
        [int]$TimeoutSeconds = 90,
        [int]$IntervalSeconds = 3
    )

    Write-Step "Waiting for Podman machine to become ready..."

    $start = Get-Date
    while (((Get-Date) - $start).TotalSeconds -lt $TimeoutSeconds) {
        try {
            $machineJson = podman machine list --format json 2>$null
            if (-not [string]::IsNullOrWhiteSpace($machineJson)) {
                $machines = $machineJson | ConvertFrom-Json
                $runningMachine = $machines | Where-Object { $_.Running -eq $true } | Select-Object -First 1

                if ($runningMachine) {
                    podman info *> $null
                    if ($LASTEXITCODE -eq 0) {
                        Write-Success "Podman machine '$($runningMachine.Name)' is running and ready"
                        return $true
                    }
                }
            }
        } catch {
        }

        Start-Sleep -Seconds $IntervalSeconds
    }

    return $false
}

function Wait-HttpReady {
    param(
        [string]$Url,
        [int]$TimeoutSeconds = 180,
        [int]$IntervalSeconds = 3
    )

    Write-Step "Waiting for web page to become available: $Url"

    $start = Get-Date
    while (((Get-Date) - $start).TotalSeconds -lt $TimeoutSeconds) {
        try {
            $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -Method Get -TimeoutSec 5

            if ($resp.StatusCode -eq 200 -and -not [string]::IsNullOrWhiteSpace($resp.Content)) {
                Write-Success "Web page is reachable and returned content: $Url"
                return $true
            }
        } catch {
        }

        Start-Sleep -Seconds $IntervalSeconds
    }

    Write-Host "Warning: Web page did not become ready within timeout: $Url" -ForegroundColor Yellow
    return $false
}

function Wait-PortReady {
    param(
        [string]$Hostname = "127.0.0.1",
        [int]$Port,
        [int]$TimeoutSeconds = 300,
        [int]$IntervalSeconds = 2
    )

    Write-Step "Waiting for TCP service on ${Hostname}:$Port"

    $start = Get-Date
    while (((Get-Date) - $start).TotalSeconds -lt $TimeoutSeconds) {
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $async = $client.BeginConnect($Hostname, $Port, $null, $null)
            $success = $async.AsyncWaitHandle.WaitOne(2000, $false)

            if ($success -and $client.Connected) {
                $client.EndConnect($async)
                $client.Close()
                Write-Success "Port $Port is open on $Hostname"
                return $true
            }

            $client.Close()
        } catch {
        }

        Start-Sleep -Seconds $IntervalSeconds
    }

    Write-Host "Warning: Port $Port did not become ready within timeout" -ForegroundColor Yellow
    return $false
}

# ============================================================================
# Install Functions
# ============================================================================

function Install-Tool {
    param(
        [string]$Name,
        [string]$WingetId,
        [string]$Command
    )

    Write-Host "Checking $Name..." -ForegroundColor Magenta

    if (Test-Command $Command) {
        $version = & $Command --version 2>$null
        Write-Success "$Name found: $version"
        return
    }

    Write-Step "Installing $Name via winget..."
    winget install -e --id $WingetId --accept-package-agreements --accept-source-agreements

    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")

    if (Test-Command $Command) {
        Write-Success "$Name installed"
    } else {
        Write-Host "Error: $Name installation failed or not in PATH" -ForegroundColor Red
        Write-Host "Please restart PowerShell and run this script again" -ForegroundColor Yellow
        exit 1
    }
}

function Initialize-PodmanMachine {
    Write-Host "Checking Podman machine..." -ForegroundColor Magenta

    try {
        $machines = @()
        $machineJson = podman machine list --format json 2>$null

        if (-not [string]::IsNullOrWhiteSpace($machineJson)) {
            $machines = $machineJson | ConvertFrom-Json
        }

        if (-not $machines -or $machines.Count -eq 0) {
            Write-Step "Initializing Podman machine..."
            podman machine init
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to initialize Podman machine"
            }

            $machineJson = podman machine list --format json 2>$null
            if (-not [string]::IsNullOrWhiteSpace($machineJson)) {
                $machines = $machineJson | ConvertFrom-Json
            }
        }

        $runningMachine = $machines | Where-Object { $_.Running -eq $true } | Select-Object -First 1

        if ($runningMachine) {
            Write-Info "Podman machine '$($runningMachine.Name)' is already running"
        } else {
            Write-Step "Starting Podman machine..."
            podman machine start
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to start Podman machine"
            }
        }

        if (-not (Wait-PodmanReady -TimeoutSeconds 90 -IntervalSeconds 3)) {
            throw "Podman machine did not become ready within timeout"
        }

    } catch {
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Try running these commands manually:" -ForegroundColor Yellow
        Write-Host "  podman machine init" -ForegroundColor Cyan
        Write-Host "  podman machine start" -ForegroundColor Cyan
        Write-Host "  podman info" -ForegroundColor Cyan
        exit 1
    }
}

function Initialize-ProjectFiles {
    Write-Host "Setting up project files..." -ForegroundColor Magenta

    @($InstallDir, $OpenClawDir) | ForEach-Object {
        if (-not (Test-Path $_)) {
            New-Item -ItemType Directory -Force -Path $_ | Out-Null
        }
    }
    Write-Success "Directory structure created"

    $composeFile = Join-Path $InstallDir "compose.yml"
    $envExampleFile = Join-Path $InstallDir ".env.example"
    $envFile = Join-Path $InstallDir ".env"
    $configFile = Join-Path $OpenClawDir "openclaw.json"

    Get-FileFromUrl -Url $ComposeUrl -Destination $composeFile
    Get-FileFromUrl -Url $EnvExampleUrl -Destination $envExampleFile
    Get-FileFromUrl -Url $ConfigUrl -Destination $configFile

    if (-not (Test-Path $envFile)) {
        Copy-Item $envExampleFile $envFile -Force
        $content = Get-Content $envFile -Raw
        $content = $content -replace "`r`n", "`n"
        [System.IO.File]::WriteAllText($envFile, $content, (New-Object System.Text.UTF8Encoding($false)))
        Write-Success "Created .env file from .env.example"
    } else {
        Write-Info ".env already exists, keeping current file"
    }
}

function Install-GeminiImageSkill {
    param(
        [string]$WorkspaceDir
    )

    Write-Host "Installing gemini-image-generation skill..." -ForegroundColor Magenta

    $skillRoot = Join-Path $WorkspaceDir "skills\gemini-image-generation"
    $scriptDir = Join-Path $skillRoot "scripts"

    New-Item -ItemType Directory -Force -Path $skillRoot | Out-Null
    New-Item -ItemType Directory -Force -Path $scriptDir | Out-Null

    Get-FileFromUrl -Url "$GeminiSkillBaseUrl/SKILL.md" -Destination (Join-Path $skillRoot "SKILL.md")
    Get-FileFromUrl -Url "$GeminiSkillBaseUrl/package.json" -Destination (Join-Path $skillRoot "package.json")
    Get-FileFromUrl -Url "$GeminiSkillBaseUrl/scripts/edit-image.mjs" -Destination (Join-Path $scriptDir "edit-image.mjs")
    Get-FileFromUrl -Url "$GeminiSkillBaseUrl/scripts/gemini-image-runtime.mjs" -Destination (Join-Path $scriptDir "gemini-image-runtime.mjs")
    Get-FileFromUrl -Url "$GeminiSkillBaseUrl/scripts/generate-image.mjs" -Destination (Join-Path $scriptDir "generate-image.mjs")

    Write-Success "gemini-image-generation skill installed"
}

function Invoke-PodmanComposePull {
    param([int]$MaxRetries = 3)

    Write-Host "Pulling container images..." -ForegroundColor Magenta

    $attempt = 0
    $success = $false

    Push-Location $InstallDir
    try {
        while ($attempt -lt $MaxRetries -and -not $success) {
            $attempt++

            if ($attempt -eq 1) {
                Write-Info "This may take several minutes..."
            } else {
                Write-Host ""
                Write-Retry "Retry attempt $attempt of $MaxRetries"
                Write-Info "Waiting 5 seconds before retry..."
                Start-Sleep -Seconds 5
            }

            if (-not (Wait-PodmanReady -TimeoutSeconds 30 -IntervalSeconds 3)) {
                if ($attempt -lt $MaxRetries) {
                    Write-Host "Podman machine is not ready, will retry..." -ForegroundColor Yellow
                    continue
                } else {
                    Write-Host "Error: Podman machine is not ready" -ForegroundColor Red
                    return $false
                }
            }

            podman compose pull

            if ($LASTEXITCODE -eq 0) {
                $success = $true
                Write-Success "Images pulled successfully"
            } else {
                if ($attempt -lt $MaxRetries) {
                    Write-Host "Pull failed, will retry..." -ForegroundColor Yellow
                } else {
                    Write-Host "Error: Failed to pull images after $MaxRetries attempts" -ForegroundColor Red
                    Write-Host ""
                    Write-Info "Common solutions:"
                    Write-Host "  1. Check your network connection" -ForegroundColor Cyan
                    Write-Host "  2. Verify Podman is ready: podman info" -ForegroundColor Cyan
                    Write-Host "  3. Run manually: cd $InstallDir && podman compose pull" -ForegroundColor Cyan
                    return $false
                }
            }
        }

        return $success

    } finally {
        Pop-Location
    }
}


function Install-WeixinPlugin {
    Write-Host "Installing Weixin plugin..." -ForegroundColor Magenta

    Push-Location $InstallDir
    try {
        if (-not (Wait-PodmanReady -TimeoutSeconds 30 -IntervalSeconds 3)) {
            Write-Host "Warning: Podman machine is not ready" -ForegroundColor Yellow
            Write-Info "You can run plugin install manually later:"
            Write-Host "  cd $InstallDir" -ForegroundColor Cyan
            Write-Host '  podman compose run --rm openclaw-cli plugins install "@tencent-weixin/openclaw-weixin"' -ForegroundColor Cyan
            Write-Host "  podman compose run --rm openclaw-cli channels login --channel openclaw-weixin" -ForegroundColor Cyan
            return $false
        }

        $oldErrorAction = $ErrorActionPreference
        $ErrorActionPreference = "Continue"

        # 直接运行不捕获输出，避免破坏 PowerShell 5.1 下的 Console VT100 (ANSI 渲染) 状态
        podman compose run --rm openclaw-cli plugins install "@tencent-weixin/openclaw-weixin"
        $installExitCode = $LASTEXITCODE

        $ErrorActionPreference = $oldErrorAction

        if ($installExitCode -ne 0) {
            Write-Info "Weixin plugin install returned an error (might already exist), attempting update..."
            podman compose run --rm openclaw-cli plugins update "openclaw-weixin"
            if ($LASTEXITCODE -ne 0) {
                Write-Host "Warning: Weixin plugin update failed" -ForegroundColor Yellow
                return $false
            }
        }

        # 强制开启 TTY 并且使用 Start-Process 绕过 PowerShell 的内置输出捕获，让其直接打印回控制台界面
        $oldEncoding = [Console]::OutputEncoding
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8

        $loginArgs = "compose run --rm -it -e FORCE_COLOR=1 -e TERM=xterm-256color openclaw-cli channels login --channel openclaw-weixin"
        $proc = Start-Process -FilePath "podman" -ArgumentList $loginArgs -NoNewWindow -Wait -PassThru

        [Console]::OutputEncoding = $oldEncoding

        if ($proc.ExitCode -ne 0) {
            Write-Host "Warning: Weixin channel login failed" -ForegroundColor Yellow
            return $false
        }

        Write-Success "Weixin plugin installed and channel logged in"
        return $true
    } finally {
        Pop-Location
    }
}


function Invoke-OpenClawSetup {
    Write-Host "Running OpenClaw setup..." -ForegroundColor Magenta

    Push-Location $InstallDir
    try {
        if (-not (Wait-PodmanReady -TimeoutSeconds 30 -IntervalSeconds 3)) {
            Write-Host "Warning: Podman machine is not ready" -ForegroundColor Yellow
            Write-Info "You can run setup manually later: cd $InstallDir && podman compose up openclaw-init && podman compose run --rm openclaw-cli setup"
            return $false
        }

        podman compose up openclaw-init
        podman compose run --rm openclaw-cli setup

        if ($LASTEXITCODE -eq 0) {
            Write-Success "Setup completed"
            return $true
        } else {
            Write-Host "Warning: Setup failed" -ForegroundColor Yellow
            Write-Info "You can run it manually: cd $InstallDir && podman compose up openclaw-init && podman compose run --rm openclaw-cli setup"
            return $false
        }
    } finally {
        Pop-Location
    }
}

function Install-StartupBat {
    param(
        [string]$InstallDir
    )

    $batPath = Join-Path $InstallDir "start-miloclawgateway-podman-compose.bat"
    Get-FileFromUrl -Url $StartupBatUrl -Destination $batPath
    return $batPath
}

function Install-StartupShortcut {
    param(
        [string]$BatPath,
        [string]$InstallDir
    )

    $startupDir = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup"
    if (-not (Test-Path $startupDir)) {
        New-Item -ItemType Directory -Force -Path $startupDir | Out-Null
    }

    $shortcutPath = Join-Path $startupDir "MiloClaw.lnk"
    New-Shortcut -TargetPath $BatPath -ShortcutPath $shortcutPath -WorkingDirectory $InstallDir
    Write-Success "Startup shortcut created: $shortcutPath"
}

function Start-MiloClawBat {
    param(
        [string]$BatPath,
        [string]$InstallDir
    )

    Write-Step "Running start-miloclawgateway-podman-compose.bat..."
    Start-Process -FilePath $BatPath -WorkingDirectory $InstallDir
    Write-Success "Startup bat launched"
}

# ============================================================================
# Main
# ============================================================================

Write-Host "[OK] Windows detected" -ForegroundColor Green
Write-Host ""

if (-not (Test-Command "winget")) {
    Write-Host "Error: winget not found" -ForegroundColor Red
    Write-Host "Install from: https://www.microsoft.com/store/productId/9NBLGGH4NNS1" -ForegroundColor Yellow
    exit 1
}
Write-Success "winget found"
Write-Host ""

if (Test-Command "wsl") {
    Write-Success "WSL detected"
} else {
    Write-Info "WSL not detected (optional, but recommended)"
    Write-Info "To install: wsl --install"
}
Write-Host ""

Install-Tool -Name "Podman" -WingetId "RedHat.Podman" -Command "podman"
Write-Host ""

Install-Tool -Name "Docker Compose" -WingetId "Docker.DockerCompose" -Command "docker-compose"
Write-Host ""

Initialize-PodmanMachine
Write-Host ""

Initialize-ProjectFiles
Write-Host ""

$apiKey = Read-ApiKey
Write-Host ""

$gatewayToken = New-RandomToken -Length 48
Write-Success "Random gateway token generated"
Write-Host ""

$envFile = Join-Path $InstallDir ".env"
Set-EnvValue -EnvFile $envFile -Key "OPENCLAW_GATEWAY_TOKEN" -Value $gatewayToken
Write-Success ".env updated with OPENCLAW_GATEWAY_TOKEN"
Write-Host ""

$configFile = Join-Path $OpenClawDir "openclaw.json"
Update-OpenClawConfig -ConfigFile $configFile -Token $gatewayToken -ApiKey $apiKey
Write-Success "openclaw.json updated"
Write-Host ""

Install-GeminiImageSkill -WorkspaceDir $WorkspaceDir
Write-Host ""

$webUrl = "http://localhost:18988/#token=$gatewayToken"
New-DesktopUrlShortcut -Name "MiloClaw" -Url $webUrl
Write-Host ""

$pullSuccess = Invoke-PodmanComposePull -MaxRetries $MaxRetries

if (-not $pullSuccess) {
    Write-Host ""
    Write-Host "Installation incomplete - image pull failed" -ForegroundColor Red
    Write-Host "Project files are ready at: $InstallDir" -ForegroundColor Yellow
    Write-Host "You can complete the setup manually:" -ForegroundColor Yellow
    Write-Host "  cd $InstallDir" -ForegroundColor Cyan
    Write-Host "  podman info" -ForegroundColor Cyan
    Write-Host "  podman compose pull" -ForegroundColor Cyan
    Write-Host "  podman compose run --rm openclaw-cli setup" -ForegroundColor Cyan
    exit 1
}
Write-Host ""
$setupSuccess = Invoke-OpenClawSetup
Write-Host ""
$weixinPluginSuccess = Install-WeixinPlugin
Write-Host ""

$startupBat = Install-StartupBat -InstallDir $InstallDir
Write-Host ""

Install-StartupShortcut -BatPath $startupBat -InstallDir $InstallDir
Write-Host ""

Start-MiloClawBat -BatPath $startupBat -InstallDir $InstallDir
Write-Host ""

$serviceReady = Wait-HttpReady -Url "http://127.0.0.1:18988/" -TimeoutSeconds 300 -IntervalSeconds 3
if ($serviceReady) {
    Start-Sleep -Seconds 2
    Start-Process $webUrl
    Write-Success "Opened MiloClaw in browser"
} else {
    Write-Host "Web page is not ready yet, you can open it manually later: $webUrl" -ForegroundColor Yellow
}
Write-Host ""

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "    Installation Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Success "MiloClaw installed to: $InstallDir"
Write-Host ""
Write-Host "Quick Start:" -ForegroundColor Yellow
Write-Host "  cd $InstallDir" -ForegroundColor Cyan
Write-Host "  podman compose up -d" -ForegroundColor Cyan
Write-Host ""
Write-Host "View logs:" -ForegroundColor Yellow
Write-Host "  podman compose logs -f" -ForegroundColor Cyan
Write-Host ""
Write-Host "Stop services:" -ForegroundColor Yellow
Write-Host "  podman compose down" -ForegroundColor Cyan
Write-Host ""
Write-Host "Gateway URL:" -ForegroundColor Yellow
Write-Host "  $webUrl" -ForegroundColor Cyan
Write-Host ""

if (-not $setupSuccess) {
    Write-Host "Note: Setup step had issues, but images are ready" -ForegroundColor Yellow
    Write-Host "You can run setup manually or start services directly" -ForegroundColor Yellow
    Write-Host ""
}