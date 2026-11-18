# Periodična provera lokalnog Supabase stacka + Tailscale Funnel :8443.
# Prati obrazac osrm-service/osrm_watchdog.ps1.
#
# Registruje se kao Scheduled Task GavraSupabase_Watchdog (svakih 5 min).
# Ne dira ništa ako je sve zdravo.

$ErrorActionPreference = "Continue"

$ServiceDir = $PSScriptRoot
$LogFile = "$ServiceDir\supabase_watchdog.log"
$TailscaleExe = "C:\Program Files\Tailscale\tailscale.exe"
$FunnelHost = "win-vfeglqf71ss.tail61b7a2.ts.net"
$MutexName = "Global\GavraSupabaseService"
$AnonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.wvpiRR29qYZhlZfXV-3ldHNFwkRzCTYnIypwz1Ym64M"

function Log($msg) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
}

function Rotate-LogIfNeeded {
    if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt 1MB)) {
        $bak = "$LogFile.bak"
        if (Test-Path $bak) { Remove-Item $bak -Force -ErrorAction SilentlyContinue }
        Move-Item $LogFile $bak -Force -ErrorAction SilentlyContinue
    }
}

function Test-KongApi {
    # Mali endpoint (limit=1) - /rest/v1/ vraća ceo OpenAPI spec i prespor je.
    try {
        $code = & curl.exe -sS -o NUL -w "%{http_code}" --connect-timeout 5 --max-time 10 `
            -H "apikey: $AnonKey" `
            "http://127.0.0.1:54321/rest/v1/v3_vozila?select=registracija&limit=1" 2>$null
        return ($code -match '^(200|401|403|404)$')
    } catch {
        return $false
    }
}

function Get-SupabaseContainers {
    return @(docker ps -a --filter "name=supabase_" --format "{{.Names}}" 2>$null | Where-Object { $_ })
}

function Get-RunningSupabaseContainers {
    return @(docker ps --filter "name=supabase_" --format "{{.Names}}" 2>$null | Where-Object { $_ })
}

function Start-StoppedContainers {
    $all = Get-SupabaseContainers
    $running = Get-RunningSupabaseContainers
    $stopped = $all | Where-Object { $running -notcontains $_ }
    foreach ($c in $stopped) {
        Log "Startujem zaustavljeni kontejner: $c"
        docker start $c 2>&1 | ForEach-Object { Log "  docker: $_" }
    }
    return $stopped.Count
}

function Test-FunnelConfigured {
    if (-not (Test-Path $TailscaleExe)) { return $false }
    $status = & $TailscaleExe funnel status 2>&1 | Out-String
    return ($status -match ":8443")
}

function Enable-Funnel {
    if (-not (Test-Path $TailscaleExe)) {
        Log "GREŠKA: Tailscale nije pronađen."
        return
    }
    & $TailscaleExe funnel --bg --https=8443 http://127.0.0.1:54321 2>&1 | ForEach-Object { Log "  tailscale: $_" }
}

function Test-FunnelPublicHttps {
    $ip = $null
    $output = nslookup $FunnelHost 8.8.8.8 2>&1 | Out-String
    $ips = [regex]::Matches($output, '\b(?:\d{1,3}\.){3}\d{1,3}\b') | ForEach-Object { $_.Value } | Select-Object -Unique
    foreach ($candidate in $ips) {
        if ($candidate -eq "8.8.8.8" -or $candidate -match '^(100|127)\.') { continue }
        $ip = $candidate; break
    }
    if (-not $ip) { return $false }
    try {
        $code = & curl.exe -sS -o NUL -w "%{http_code}" --http1.1 --connect-timeout 8 --max-time 15 `
            --resolve "${FunnelHost}:8443:${ip}" `
            -H "apikey: $AnonKey" `
            "https://${FunnelHost}:8443/rest/v1/" 2>$null
        return ($code -match '^(200|401|404)$')
    } catch {
        return $false
    }
}

Rotate-LogIfNeeded

$mutex = New-Object System.Threading.Mutex($false, $MutexName)
$taken = $false
try {
    $taken = $mutex.WaitOne(0)
    if (-not $taken) { exit 0 }

    $kongOk = Test-KongApi
    $funnelOk = Test-FunnelConfigured

    if ($kongOk -and $funnelOk) {
        $httpsOk = Test-FunnelPublicHttps
        if (-not $httpsOk) {
            Log "PROBLEM: javni HTTPS :8443 ne odgovara. Recikliram Funnel..."
            & $TailscaleExe funnel --https=8443 off 2>&1 | ForEach-Object { Log "  tailscale: $_" }
            Start-Sleep -Seconds 3
            Enable-Funnel
            exit 0
        }

        $now = Get-Date
        $lastOkStamp = Join-Path $ServiceDir ".supabase_watchdog_ok"
        $shouldLogOk = $true
        if (Test-Path $lastOkStamp) {
            $prev = Get-Item $lastOkStamp
            if (($now - $prev.LastWriteTime).TotalMinutes -lt 30) { $shouldLogOk = $false }
        }
        if ($shouldLogOk) {
            Log "OK: Kong API + Funnel :8443 + javni HTTPS ($FunnelHost)"
            Set-Content -Path $lastOkStamp -Value $now.ToString("o")
        }
        exit 0
    }

    if (-not $kongOk) {
        $running = Get-RunningSupabaseContainers
        $all = Get-SupabaseContainers
        Log "PROBLEM: Kong API ne odgovara (kontejneri: $($running.Count)/$($all.Count) pokrenuto)"
        $started = Start-StoppedContainers
        if ($started -gt 0) {
            Log "Sačekao start, proveravam ponovo..."
            Start-Sleep -Seconds 20
            if (Test-KongApi) { Log "Kong API se oporavio." }
            else { Log "Kong API i dalje ne odgovara posle starta kontejnera." }
        } else {
            Log "Svi kontejneri rade, a Kong ne odgovara - restartujem kong+db..."
            docker restart supabase_kong_gavra_android supabase_db_gavra_android 2>&1 | ForEach-Object { Log "  docker: $_" }
        }
    }

    if (-not (Test-FunnelConfigured)) {
        Log "PROBLEM: Funnel :8443 nije podešen. Podešavam..."
        Enable-Funnel
    }
} finally {
    if ($taken) { $mutex.ReleaseMutex() | Out-Null }
    $mutex.Dispose()
}
