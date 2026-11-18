# Registruje GavraSupabase_Watchdog: svakih 5 minuta proverava Supabase stack i Funnel :8443.
# Pokrenuti jednom kao isti korisnik (Bojan). Može da se ponavlja bez štete.

$ErrorActionPreference = "Stop"

$ServiceDir = $PSScriptRoot
$Watchdog = Join-Path $ServiceDir "supabase_watchdog.ps1"
$TaskName = "GavraSupabase_Watchdog"

if (-not (Test-Path $Watchdog)) {
    throw "Nedostaje $Watchdog"
}

$taskArgs = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $Watchdog

$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument $taskArgs `
    -WorkingDirectory $ServiceDir

$repeat = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes 5) `
    -RepetitionDuration (New-TimeSpan -Days 9999)

$logon = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME

$principalLimited = New-ScheduledTaskPrincipal `
    -UserId $env:USERNAME `
    -LogonType Interactive `
    -RunLevel Limited

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 8)

$registered = $false
foreach ($principal in @($principalLimited, $null)) {
    try {
        $task = New-ScheduledTask -Action $action -Trigger @($repeat, $logon) -Settings $settings
        if ($principal) { $task.Principal = $principal }
        Register-ScheduledTask -TaskName $TaskName -InputObject $task -Force | Out-Null
        $registered = $true
        break
    } catch {
        Write-Warning "Register sa principalom nije uspeo: $_"
    }
}

if (-not $registered) { throw "Registracija taska nije uspela." }
Write-Host "OK: $TaskName registrovan (svakih 5 min + na logon)."
