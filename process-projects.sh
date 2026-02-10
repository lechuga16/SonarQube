#!/usr/bin/env bash
set -euo pipefail

normalize_windows_path() {
  local raw="${1:-}"
  raw="${raw//\\/\/}"
  echo "$raw"
}

strip_trailing_slash() {
  local value="${1:-}"
  while [[ -n "$value" && "$value" != "/" && "$value" == */ ]]; do
    value="${value%/}"
  done
  echo "$value"
}

to_lower() {
  tr '[:upper:]' '[:lower:]' <<<"${1:-}"
}

map_host_path_to_container() {
  local host_path_raw="${1:-}"
  [[ -z "$host_path_raw" ]] && return 0

  local normalized_host
  normalized_host="$(strip_trailing_slash "$(normalize_windows_path "$host_path_raw")")"
  local lower_host
  lower_host="$(to_lower "$normalized_host")"

  local best_match=""
  local best_len=-1

  for idx in "${!MOUNT_HOSTS[@]}"; do
    local base="${MOUNT_HOSTS[$idx]}"
    local base_lower="${MOUNT_HOSTS_LOWER[$idx]}"
    local container_base="${MOUNT_CONTAINERS[$idx]}"
    local base_len=${#base}

    if [[ "$lower_host" == "$base_lower"* ]]; then
      if (( base_len > best_len )); then
        local suffix="${normalized_host:base_len}"
        local candidate="$container_base$suffix"
        candidate="$(strip_trailing_slash "$candidate")"
        best_match="$candidate"
        best_len=$base_len
      fi
    fi
  done

  [[ -n "$best_match" ]] && echo "$best_match"
}

SONAR_HOST_URL="${SONAR_HOST_URL:-http://sonarqube:9000}"
SONAR_USER_HOME="${SONAR_USER_HOME:-/work/.sonar}"
SONAR_WORK_ROOT="${SONAR_WORK_ROOT:-/work/.scannerwork}"
SONAR_WAIT_TIMEOUT_SECONDS="${SONAR_WAIT_TIMEOUT_SECONDS:-300}"
SONAR_WAIT_INTERVAL_SECONDS="${SONAR_WAIT_INTERVAL_SECONDS:-5}"
SCAN_PARALLELISM="${SCAN_PARALLELISM:-1}"
WHITELIST_FILE="/work/whitelist.json"

log_info() { echo "[INFO] $*"; }
log_warn() { echo "[WARN] $*"; }
log_error() { echo "[ERROR] $*"; }

validate_whitelist() {
  local file="$1"
  local -a errors=()
  local -a mount_hosts_lower=()

  if ! jq -e 'type=="object"' "$file" >/dev/null 2>&1; then
    errors+=("La raiz debe ser un objeto JSON.")
  fi

  if ! jq -e '.projects | type=="array" and length>0' "$file" >/dev/null 2>&1; then
    errors+=("projects debe ser un arreglo con al menos un elemento.")
  fi

  if ! jq -e '.mounts | type=="array" and length>0' "$file" >/dev/null 2>&1; then
    errors+=("mounts debe ser un arreglo con al menos un elemento.")
  fi

  local invalid_projects
  invalid_projects="$(jq '[.projects[]? | select((.hostPath|type)!="string" or (.hostPath|length)==0)] | length' "$file")"
  if [[ "$invalid_projects" -gt 0 ]]; then
    errors+=("Cada project debe tener hostPath string no vacio.")
  fi

  local invalid_path
  invalid_path="$(jq '[.projects[]? | select(has("path") and (.path|type)!="string")] | length' "$file")"
  if [[ "$invalid_path" -gt 0 ]]; then
    errors+=("path debe ser string cuando este presente.")
  fi

  local invalid_project_key
  invalid_project_key="$(jq '[.projects[]? | select(has("projectKey") and (.projectKey|type)!="string")] | length' "$file")"
  if [[ "$invalid_project_key" -gt 0 ]]; then
    errors+=("projectKey debe ser string cuando este presente.")
  fi

  local invalid_mounts
  invalid_mounts="$(jq '[.mounts[]? | select((.host|type)!="string" or (.host|length)==0 or (.container|type)!="string" or (.container|length)==0)] | length' "$file")"
  if [[ "$invalid_mounts" -gt 0 ]]; then
    errors+=("Cada mount debe tener host y container (strings no vacios).")
  fi

  readarray -t mount_hosts_lower < <(jq -r '.mounts[]?.host // empty' "$file" | awk 'NF' | tr '[:upper:]' '[:lower:]')

  if [[ ${#mount_hosts_lower[@]} -gt 0 ]]; then
    local -a uncovered=()
    while IFS= read -r host_path; do
      [[ -z "$host_path" ]] && continue
      local normalized
      normalized="$(normalize_windows_path "$host_path")"
      local lower
      lower="$(to_lower "$normalized")"
      local matched=0
      for base in "${mount_hosts_lower[@]}"; do
        if [[ "$lower" == "$base"* ]]; then
          matched=1
          break
        fi
      done
      if (( matched == 0 )); then
        uncovered+=("$host_path")
      fi
    done < <(jq -r '.projects[]?.hostPath // empty' "$file")

    if (( ${#uncovered[@]} > 0 )); then
      errors+=("Los siguientes hostPath no estan cubiertos por ningun mount.host:")
      for item in "${uncovered[@]}"; do
        errors+=("  - $item")
      done
    fi
  fi

  if (( ${#errors[@]} > 0 )); then
    log_error "whitelist.json no cumple el esquema esperado (ver whitelist.schema.json):"
    for msg in "${errors[@]}"; do
      log_error "- $msg"
    done
    exit 1
  fi
}

ensure_number() {
  local value="${1:-}"
  local fallback="${2:-}"
  if [[ -z "$value" || ! "$value" =~ ^[0-9]+$ ]]; then
    echo "$fallback"
  else
    echo "$value"
  fi
}

SONAR_WAIT_TIMEOUT_SECONDS="$(ensure_number "$SONAR_WAIT_TIMEOUT_SECONDS" 300)"
SONAR_WAIT_INTERVAL_SECONDS="$(ensure_number "$SONAR_WAIT_INTERVAL_SECONDS" 5)"
SCAN_PARALLELISM="$(ensure_number "$SCAN_PARALLELISM" 1)"

if (( SONAR_WAIT_INTERVAL_SECONDS == 0 )); then
  SONAR_WAIT_INTERVAL_SECONDS=5
fi

log_info "Iniciando procesamiento de proyectos..."

if [[ -z "${SONAR_TOKEN:-}" ]]; then
  log_error "SONAR_TOKEN no esta definido dentro del contenedor"
  exit 1
fi

if [[ ! -f "$WHITELIST_FILE" ]]; then
  log_error "No se encuentra $WHITELIST_FILE"
  exit 1
fi

if ! jq -e . "$WHITELIST_FILE" >/dev/null 2>&1; then
  log_error "El archivo $WHITELIST_FILE no es JSON valido"
  exit 1
fi

validate_whitelist "$WHITELIST_FILE"

# Configurar montajes disponibles para mapear rutas del host
declare -a MOUNT_HOSTS=()
declare -a MOUNT_HOSTS_LOWER=()
declare -a MOUNT_CONTAINERS=()

readarray -t mount_entries < <(jq -c '.mounts[]?' "$WHITELIST_FILE")

if [[ ${#mount_entries[@]} -eq 0 ]]; then
  log_error "No hay montajes definidos en $WHITELIST_FILE"
  exit 1
fi

for mount_entry in "${mount_entries[@]}"; do
  host_dir="$(jq -r '.host // empty' <<<"$mount_entry")"
  container_dir="$(jq -r '.container // empty' <<<"$mount_entry")"

  if [[ -z "$host_dir" || -z "$container_dir" ]]; then
    log_warn "Montaje invalido (host/container requeridos): $mount_entry"
    continue
  fi

  host_norm="$(strip_trailing_slash "$(normalize_windows_path "$host_dir")")"
  container_norm="$(strip_trailing_slash "$container_dir")"

  if [[ -z "$host_norm" || -z "$container_norm" ]]; then
    log_warn "Montaje invalido tras normalizar: $mount_entry"
    continue
  fi

  MOUNT_HOSTS+=("$host_norm")
  MOUNT_HOSTS_LOWER+=("$(to_lower "$host_norm")")
  MOUNT_CONTAINERS+=("$container_norm")

  if [[ ! -d "$container_norm" ]]; then
    log_warn "El contenedor no ve $container_norm (verifica los montajes)"
  fi
done

if [[ ${#MOUNT_HOSTS[@]} -eq 0 ]]; then
  log_error "No hay montajes validos (verifica whitelist.json)"
  exit 1
fi

mkdir -p "$SONAR_USER_HOME" "$SONAR_WORK_ROOT" || true

log_info "Esperando a que SonarQube este listo en $SONAR_HOST_URL ..."
max_attempts=$(( (SONAR_WAIT_TIMEOUT_SECONDS + SONAR_WAIT_INTERVAL_SECONDS - 1) / SONAR_WAIT_INTERVAL_SECONDS ))
for ((i=1; i<=max_attempts; i++)); do
  resp="$(curl -fsS "$SONAR_HOST_URL/api/system/status" 2>/dev/null || true)"
  if [[ -n "$resp" ]]; then
    status="$(jq -r '.status // empty' <<<"$resp" 2>/dev/null || true)"
    if [[ "$status" == "UP" ]]; then
      log_info "SonarQube listo (status=UP)"
      break
    else
      log_info "SonarQube status: ${status:-unknown} (esperando UP)..."
    fi
  else
    log_info "SonarQube no responde aun (intentos: $i)..."
  fi

  sleep "$SONAR_WAIT_INTERVAL_SECONDS"
  if [[ $i -eq $max_attempts ]]; then
    log_error "Timeout esperando SonarQube"
    exit 1
  fi
done

readarray -t projects < <(jq -c '.projects[]' "$WHITELIST_FILE")
log_info "Procesando ${#projects[@]} proyectos..."

scan_project() {
  local proj="$1"

  local path
  path="$(jq -r '.path // empty' <<<"$proj")"
  local project_key
  project_key="$(jq -r '.projectKey // empty' <<<"$proj")"
  local host_path
  host_path="$(jq -r '.hostPath // empty' <<<"$proj")"

  if [[ -z "$host_path" ]]; then
    log_warn "hostPath no definido en la entrada: $proj"
    return 1
  fi

  local base_path
  base_path="$(map_host_path_to_container "$host_path")"
  if [[ -z "$base_path" ]]; then
    log_warn "No se pudo mapear hostPath='$host_path'"
    return 1
  fi

  local normalized_subpath="${path#/}"
  local full_path
  if [[ -n "$normalized_subpath" ]]; then
    full_path="$base_path/$normalized_subpath"
  else
    full_path="$base_path"
  fi

  if [[ ! -d "$full_path" ]]; then
    log_warn "No existe: $full_path"
    return 1
  fi

  local project_key_default
  project_key_default="$(basename -- "$full_path")"
  project_key="${project_key:-$project_key_default}"

  local display_label
  display_label="$(normalize_windows_path "$host_path")"
  if [[ -n "$normalized_subpath" ]]; then
    display_label="$display_label\\$normalized_subpath"
  fi

  log_info "Analizando: $display_label -> $full_path (projectKey=$project_key)"

  if [[ ! -f "$full_path/sonar-project.properties" ]]; then
    log_warn "No se encuentra sonar-project.properties en $full_path"
    log_warn "Crea el archivo en el repo y reintenta."
    return 1
  fi

  local work_dir="$SONAR_WORK_ROOT/$project_key"
  mkdir -p "$work_dir" || true

  log_info "Ejecutando sonar-scanner en $full_path"
  if sonar-scanner \
      -D"sonar.host.url=$SONAR_HOST_URL" \
      -D"sonar.token=$SONAR_TOKEN" \
      -D"sonar.userHome=$SONAR_USER_HOME" \
      -D"sonar.working.directory=$work_dir" \
      -D"sonar.projectBaseDir=$full_path"; then
    log_info "Completado: $display_label"
    return 0
  fi

  log_error "Fallo: $display_label"
  return 1
}

failures=0
pids=()

if (( SCAN_PARALLELISM <= 1 )); then
  for proj in "${projects[@]}"; do
    if ! scan_project "$proj"; then
      failures=$((failures + 1))
    fi
  done
else
  log_info "Paralelismo habilitado: $SCAN_PARALLELISM"
  for proj in "${projects[@]}"; do
    scan_project "$proj" &
    pids+=("$!")

    while (( $(jobs -pr | wc -l) >= SCAN_PARALLELISM )); do
      sleep 1
    done
  done

  for pid in "${pids[@]}"; do
    if ! wait "$pid"; then
      failures=$((failures + 1))
    fi
  done
fi

if (( failures > 0 )); then
  log_error "Finalizado con errores: $failures"
  exit 1
fi

log_info "Finalizado correctamente"
