# MiloClaw Weixin Plugin Installer

param(
    [int]$MaxRetries = 3
)
$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "  MiloClaw Weixin Plugin Installer" -ForegroundColor Cyan
Write-Host ""

# Installation directory
$InstallDir = Join-Path $env:USERPROFILE "miloclaw"
$OpenClawDir = Join-Path $InstallDir ".openclaw"
$ConfigFile = Join-Path $OpenClawDir "openclaw.json"

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

function Install-WeixinPlugin {
    Write-Host "Installing Weixin plugin..." -ForegroundColor Magenta

    Push-Location $InstallDir
    try {
        if (-not (Wait-PodmanReady -TimeoutSeconds 30 -IntervalSeconds 3)) {
            Write-Host "Warning: Podman machine is not ready" -ForegroundColor Yellow
            Write-Info "You can run plugin install manually later:"
            Write-Host "  cd `$InstallDir" -ForegroundColor Cyan
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

# ============================================================================
# Main
# ============================================================================

if (-not (Test-Path $InstallDir)) {
    Write-Host "Error: MiloClaw installation directory not found at $InstallDir" -ForegroundColor Red
    exit 1
}

$weixinPluginSuccess = Install-WeixinPlugin

if (-not $weixinPluginSuccess) {
    Write-Host "Weixin plugin setup failed or skipped." -ForegroundColor Yellow
}

$BatPath = Join-Path $InstallDir "start-miloclawgateway-podman-compose.bat"
if (Test-Path $BatPath) {
    Write-Step "Running start-miloclawgateway-podman-compose.bat..."
    Start-Process -FilePath $BatPath -WorkingDirectory $InstallDir
    Write-Success "Startup bat launched"
} else {
    Write-Host "Warning: $BatPath not found." -ForegroundColor Yellow
}

$gatewayToken = ""
if (Test-Path $ConfigFile) {
    try {
        $jsonText = Get-Content $ConfigFile -Raw
        $config = $jsonText | ConvertFrom-Json
        $gatewayToken = $config.gateway.auth.token
    } catch {
        Write-Host "Warning: Could not read gateway token from config." -ForegroundColor Yellow
    }
}

$webUrl = "http://localhost:18988/#token=$gatewayToken"

$serviceReady = Wait-HttpReady -Url "http://127.0.0.1:18988/" -TimeoutSeconds 300 -IntervalSeconds 3
if ($serviceReady) {
    Start-Sleep -Seconds 2
    Start-Process $webUrl
    Write-Success "Opened MiloClaw in browser"
} else {
    Write-Host "Web page is not ready yet, you can open it manually later: $webUrl" -ForegroundColor Yellow
}

Write-Host "Done." -ForegroundColor Green
