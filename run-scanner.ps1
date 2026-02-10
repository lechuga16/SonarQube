param(
  [string]$WhitelistPath = "whitelist.json",
  [switch]$KeepGenerated
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $root

$whitelistFull = Join-Path $root $WhitelistPath
if (!(Test-Path $whitelistFull)) {
  Write-Error "No existe el archivo de whitelist: $whitelistFull"
  exit 1
}

$whitelist = Get-Content $whitelistFull -Raw | ConvertFrom-Json
if (-not $whitelist.projects -or $whitelist.projects.Count -eq 0) {
  Write-Error "whitelist.json debe contener 'projects' con al menos una entrada."
  exit 1
}

$hostPaths = @()
$seen = @{}
foreach ($proj in $whitelist.projects) {
  $hostPath = $proj.hostPath
  if ([string]::IsNullOrWhiteSpace($hostPath)) {
    continue
  }

  $key = $hostPath.ToLowerInvariant()
  if (-not $seen.ContainsKey($key)) {
    $seen[$key] = $true
    $hostPaths += $hostPath
  }
}

if ($hostPaths.Count -eq 0) {
  Write-Error "No se encontraron hostPath validos en 'projects'."
  exit 1
}

$mounts = @()
for ($i = 0; $i -lt $hostPaths.Count; $i++) {
  $host = $hostPaths[$i].Replace('\', '/')
  $container = "/work/src$($i + 1)"
  $mounts += [pscustomobject]@{
    host = $host
    container = $container
  }
}

$generatedWhitelist = [pscustomobject]@{
  mounts = $mounts
  projects = $whitelist.projects
}

$generatedWhitelistPath = Join-Path $root "whitelist.generated.json"
$generatedWhitelist | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 $generatedWhitelistPath

$volLines = @()
foreach ($m in $mounts) {
  $volLines += "      - `"$($m.host):$($m.container):ro`""
}

$compose = @"
services:
  scanner:
    build:
      context: .
      dockerfile: Dockerfile.scanner
    image: sonarqube_scanner_local
    container_name: sonarqube_scanner
    user: root
    env_file:
      - .env
    environment:
      SONAR_HOST_URL: http://sonarqube:9000
      SONAR_USER_HOME: /work/.sonar
      SONAR_WORK_ROOT: /work/.scannerwork
    working_dir: /work
    entrypoint:
      - /bin/sh
      - -c
      - |
        mkdir -p /work/.sonar /work/.scannerwork
        chown -R scanner-cli:scanner-cli /work/.sonar /work/.scannerwork
        chmod +x /work/process-projects.sh
        su scanner-cli -c "sh /work/process-projects.sh"
    volumes:
      - "./process-projects.sh:/work/process-projects.sh:ro"
      - "./whitelist.generated.json:/work/whitelist.json:ro"
      - "scanner_cache:/work/.sonar"
      - "scanner_work:/work/.scannerwork"
$($volLines -join "`n")

volumes:
  scanner_cache:
  scanner_work:
"@

$generatedComposePath = Join-Path $root "docker-compose.generated.yml"
$compose | Set-Content -Encoding UTF8 $generatedComposePath

docker compose -f $generatedComposePath run --rm scanner

if (-not $KeepGenerated) {
  Remove-Item $generatedComposePath -ErrorAction SilentlyContinue
  Remove-Item $generatedWhitelistPath -ErrorAction SilentlyContinue
}
