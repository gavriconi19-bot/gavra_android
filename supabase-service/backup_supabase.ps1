# Dnevni backup lokalnog Supabase stacka - laptop je single source of truth.
#
# Radi pg_dump -Fc (custom format) cele postgres baze iz supabase_db kontejnera
# i cuva dump + kopiju .env.admin u $BackupDir. Cuva poslednjih $KeepDays dana.
#
# Registruje se kao Scheduled Task GavraSupabase_Backup (dnevno).
# Restore: pg_restore -U postgres -d postgres -c <fajl>.dump  (u supabase_db kontejneru)

$ErrorActionPreference = "Continue"

$ServiceDir  = $PSScriptRoot
$RepoRoot    = Split-Path $ServiceDir -Parent
$LogFile     = "$ServiceDir\backup_supabase.log"
$BackupDir   = "C:\gavra-backups"
$KeepDays    = 14
$Container   = "supabase_db_gavra_android"
$MutexName   = "Global\GavraSupabaseBackup"

function Log($msg) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
}

$mutex = New-Object System.Threading.Mutex($false, $MutexName)
if (-not $mutex.WaitOne(0)) {
    Log "Drugi backup vec radi, izlazim."
    exit 0
}

try {
    if (-not (Test-Path $BackupDir)) {
        New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
    }

    # Da li kontejner radi?
    $running = docker inspect -f '{{.State.Running}}' $Container 2>$null
    if ($running -ne "true") {
        Log "GRESKA: kontejner $Container ne radi - backup preskocen."
        exit 1
    }

    $stamp   = Get-Date -Format "yyyyMMdd_HHmm"
    $dumpOut = "$BackupDir\gavra_db_$stamp.dump"

    Log "Backup start -> $dumpOut"
    # Dump u /tmp unutar kontejnera (lozinka iz POSTGRES_PASSWORD env varijable
    # kontejnera), pa docker cp na host - izbegava binarni stdout problem.
    $inner = "/tmp/gavra_backup_$stamp.dump"
    docker exec $Container sh -c "PGPASSWORD=`$POSTGRES_PASSWORD pg_dump -U supabase_admin -d postgres -Fc -f $inner" 2>&1 | ForEach-Object { Log "  pg_dump: $_" }
    if ($LASTEXITCODE -ne 0) {
        Log "GRESKA: pg_dump pao sa kodom $LASTEXITCODE."
        exit 1
    }
    docker cp "${Container}:$inner" "$dumpOut" 2>&1 | ForEach-Object { Log "  docker cp: $_" }
    docker exec $Container rm -f $inner 2>&1 | Out-Null

    if (-not (Test-Path $dumpOut) -or (Get-Item $dumpOut).Length -lt 1KB) {
        Log "GRESKA: dump fajl je prazan ili ne postoji."
        exit 1
    }
    $sizeMB = [math]::Round((Get-Item $dumpOut).Length / 1MB, 1)
    Log "Backup OK: $dumpOut ($sizeMB MB)"

    # .env.admin - kljucevi neophodni za restore celog stacka
    $adminEnv = Join-Path $RepoRoot ".env.admin"
    if (Test-Path $adminEnv) {
        Copy-Item $adminEnv "$BackupDir\env_admin_$stamp.txt" -Force
        Log "Kopiran .env.admin -> env_admin_$stamp.txt"
    }

    # Retention: brisi starije od $KeepDays dana
    $cutoff = (Get-Date).AddDays(-$KeepDays)
    Get-ChildItem $BackupDir -File | Where-Object { $_.LastWriteTime -lt $cutoff } | ForEach-Object {
        Log "Brisem stari backup: $($_.Name)"
        Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
    }

    Log "Backup zavrsen."
} finally {
    $mutex.ReleaseMutex() | Out-Null
}
