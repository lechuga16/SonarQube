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

  local normalized_host="$(strip_trailing_slash "$(normalize_windows_path "$host_path_raw")")"
  local lower_host="$(to_lower "$normalized_host")"

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

SONAR_DOCKER_URL="${SONAR_DOCKER_URL:-http://sonarqube:9000}"
WHITELIST_FILE="/work/${SINGLE_WHITELIST_FILE:-whitelist.json}"
 
echo "🔍 Iniciando procesamiento de proyectos..."

# 0) Validaciones básicas
if [[ -z "${SONAR_TOKEN:-}" ]]; then
  echo "❌ SONAR_TOKEN no está definido dentro del contenedor"
  exit 1
fi

if [[ ! -f "$WHITELIST_FILE" ]]; then
  echo "❌ No se encuentra $WHITELIST_FILE"
  exit 1
fi

# 1) Configurar montajes disponibles para mapear rutas del host
declare -a MOUNT_HOSTS=()
declare -a MOUNT_HOSTS_LOWER=()
declare -a MOUNT_CONTAINERS=()

readarray -t mount_entries < <(jq -c '.mounts[]?' "$WHITELIST_FILE")

for mount_entry in "${mount_entries[@]}"; do
  host_dir=$(jq -r '.host // empty' <<<"$mount_entry")
  container_dir=$(jq -r '.container // empty' <<<"$mount_entry")

  if [[ -z "$host_dir" || -z "$container_dir" ]]; then
    echo "⚠️  Montaje inválido (host/container requeridos): $mount_entry"
    continue
  fi

  host_norm="$(strip_trailing_slash "$(normalize_windows_path "$host_dir")")"
  container_norm="$(strip_trailing_slash "$container_dir")"

  if [[ -z "$host_norm" || -z "$container_norm" ]]; then
    echo "⚠️  Montaje inválido tras normalizar: $mount_entry"
    continue
  fi

  MOUNT_HOSTS+=("$host_norm")
  MOUNT_HOSTS_LOWER+=("$(to_lower "$host_norm")")
  MOUNT_CONTAINERS+=("$container_norm")

  if [[ ! -d "$container_norm" ]]; then
    echo "⚠️  El contenedor no ve $container_norm (verifica docker-compose.yml)"
  fi
done

if [[ ${#MOUNT_HOSTS[@]} -eq 0 ]]; then
  while IFS='=' read -r env_key env_value; do
    [[ -z "$env_value" ]] && continue
    index="${env_key#MOUNT_SRC}"
    [[ "$index" == "$env_key" ]] && continue
    [[ -z "$index" ]] && continue

    host_norm="$(strip_trailing_slash "$(normalize_windows_path "$env_value")")"
    container_norm="/work/src$index"

    MOUNT_HOSTS+=("$host_norm")
    MOUNT_HOSTS_LOWER+=("$(to_lower "$host_norm")")
    MOUNT_CONTAINERS+=("$container_norm")

    if [[ ! -d "$container_norm" ]]; then
      echo "⚠️  El contenedor no ve $container_norm (verifica docker-compose.yml)"
    fi
  done < <(env | grep -E '^MOUNT_SRC[0-9]+=' | sort)
fi

if [[ ${#MOUNT_HOSTS[@]} -eq 0 ]]; then
  echo "❌ No hay montajes válidos (verifica whitelist.json o variables MOUNT_SRCn)"
  exit 1
fi

# 2) Espera a que SonarQube esté listo (status must be UP)
echo "⏳ Esperando a que SonarQube esté listo en $SONAR_DOCKER_URL ..."
for i in {1..60}; do
  # Intentamos obtener el JSON de estado. Usamos jq para extraer .status cuando esté disponible.
  resp=$(curl -fsS "$SONAR_DOCKER_URL/api/system/status" 2>/dev/null || true)
  if [[ -n "$resp" ]]; then
    status=$(jq -r '.status // empty' <<<"$resp" 2>/dev/null || true)
    if [[ "$status" == "UP" ]]; then
      echo "✅ SonarQube listo (status=UP)"
      break
    else
      # Mostrar estado intermedio (STARTING, etc.) para debugging
      echo "⏳ SonarQube status: ${status:-unknown} (esperando UP)..."
    fi
  else
    echo "⏳ SonarQube no responde aún (intentos: $i)..."
  fi

  sleep 5
  [[ $i -eq 60 ]] && { echo "❌ Timeout esperando SonarQube"; exit 1; }
done

# 3) Leer whitelist
readarray -t projects < <(jq -c '.projects[]' "$WHITELIST_FILE")
echo "📋 Procesando ${#projects[@]} proyectos..."

# 4) Iterar proyectos
for proj in "${projects[@]}"; do
  path=$(jq -r '.path // empty' <<<"$proj")
  project_key=$(jq -r '.projectKey // empty' <<<"$proj")
  host_path=$(jq -r '.hostPath // empty' <<<"$proj")
  # hostPath define la ruta absoluta del proyecto en el host (obligatoria)

  if [[ -z "$host_path" ]]; then
    echo "⚠️  hostPath no definido en la entrada: $proj"
    continue
  fi

  base_path="$(map_host_path_to_container "$host_path")"
  if [[ -z "$base_path" ]]; then
    echo "⚠️  No se pudo mapear hostPath='$host_path'"
    continue
  fi

  normalized_subpath="${path#/}"
  if [[ -n "$normalized_subpath" ]]; then
    full_path="$base_path/$normalized_subpath"
  else
    full_path="$base_path"
  fi

  [[ ! -d "$full_path" ]] && { echo "⚠️  No existe: $full_path"; continue; }

  # projectKey por defecto: nombre de carpeta
  project_key_default="$(basename -- "$full_path")"
  project_key="${project_key:-$project_key_default}"

  # Normalizar display_label con backslashes
  display_label="$(normalize_windows_path "$host_path")"
  if [[ -n "$normalized_subpath" ]]; then
    display_label="$display_label\\$normalized_subpath"
  fi

  echo "🔍 Analizando: $display_label -> $full_path (projectKey=$project_key)"

  cd "$full_path"

  if [[ ! -f "sonar-project.properties" ]]; then
    echo "❌ No se encuentra sonar-project.properties en $full_path (el volumen es RO)"
    echo "   Crea el archivo en el repo y reintenta."
    continue
  fi

  scanner_args=()

  echo "🚀 Ejecutando sonar-scanner en $full_path"
  if sonar-scanner \
      -D"sonar.host.url=$SONAR_DOCKER_URL" \
      -D"sonar.token=$SONAR_TOKEN" \
      "${scanner_args[@]}"; then
    echo "✅ Completado: $display_label"
  else
    echo "❌ Falló: $display_label"
  fi
done
