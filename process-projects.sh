#!/usr/bin/env bash
set -euo pipefail

SONAR_HOST_URL="${SONAR_HOST_URL:-http://sonarqube:9000}"
WHITELIST_FILE="/work/whitelist.json"

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

# 1) Espera a que SonarQube esté listo
echo "⏳ Esperando a que SonarQube esté listo en $SONAR_HOST_URL ..."
for i in {1..60}; do
  if curl -fsS "$SONAR_HOST_URL/api/system/status" >/dev/null 2>&1; then
    echo "✅ SonarQube listo"
    break
  fi
  sleep 5
  [[ $i -eq 60 ]] && { echo "❌ Timeout esperando SonarQube"; exit 1; }
done

# 2) Leer whitelist
readarray -t projects < <(jq -c '.projects[]' "$WHITELIST_FILE")
default_exclusions=$(jq -r '.defaults.exclusions // [] | join(",")' "$WHITELIST_FILE")

echo "📋 Procesando ${#projects[@]} proyectos..."

# 3) Iterar proyectos
for proj in "${projects[@]}"; do
  root=$(jq -r '.root' <<<"$proj")
  path=$(jq -r '.path' <<<"$proj")
  project_key=$(jq -r '.projectKey // empty' <<<"$proj")
  has_excls=$(jq -r 'has("exclusions")' <<<"$proj")

  case "$root" in
    personal) container_base="/work/personal" ;;
    *) echo "⚠️  root inválido '$root' (usa 'personal')" && continue ;;
  esac

  full_path="$container_base/$path"
  [[ ! -d "$full_path" ]] && { echo "⚠️  No existe: $full_path"; continue; }

  # projectKey por defecto: nombre de carpeta
  project_key="${project_key:-$(basename "$full_path")}"
  echo "🔍 Analizando: $root/$path (projectKey=$project_key)"

  cd "$full_path"

  if [[ ! -f "sonar-project.properties" ]]; then
    echo "❌ No se encuentra sonar-project.properties en $full_path (el volumen es RO)"
    echo "   Crea el archivo en el repo y reintenta."
    continue
  fi

  # Exclusiones inline si fueron definidas en el JSON (tienen prioridad sobre defaults)
  scanner_args=()
  if [[ "$has_excls" == "true" ]]; then
    excl_joined=$(jq -r '.exclusions | join(",")' <<<"$proj")
    [[ -n "$excl_joined" ]] && scanner_args+=(-D"sonar.exclusions=$excl_joined")
  fi

  echo "🚀 Ejecutando sonar-scanner en $full_path"
  if sonar-scanner \
      -D"sonar.host.url=$SONAR_HOST_URL" \
      -D"sonar.token=$SONAR_TOKEN" \
      "${scanner_args[@]}"; then
    echo "✅ Completado: $root/$path"
  else
    echo "❌ Falló: $root/$path"
  fi
done
