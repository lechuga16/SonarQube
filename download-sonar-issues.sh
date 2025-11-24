#!/usr/bin/env bash
set -euo pipefail

# ================================
# CONFIG
# ================================

ENV_FILE=".env"
PROP_FILE="sonar-project.properties"
OUTPUT_FILE="sonar-issues.json"
PAGE_SIZE=500

# ================================
# Cargar sonar.env
# ================================
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: No existe $ENV_FILE" >&2
  exit 1
fi

echo "→ Cargando variables desde $ENV_FILE"
set -o allexport
source "$ENV_FILE"
set +o allexport

# Validar env
if [[ -z "${SONAR_HOST_URL:-}" ]]; then
  echo "ERROR: SONAR_HOST_URL no está definido en $ENV_FILE" >&2
  exit 1
fi

if [[ -z "${SONAR_TOKEN:-}" ]]; then
  echo "ERROR: SONAR_TOKEN no está definido en $ENV_FILE" >&2
  exit 1
fi

# ================================
# Obtener SONAR_PROJECT_KEY desde sonar-project.properties
# ================================
if [[ ! -f "$PROP_FILE" ]]; then
  echo "ERROR: No existe $PROP_FILE" >&2
  exit 1
fi

SONAR_PROJECT_KEY="$(grep -E '^sonar.projectKey=' "$PROP_FILE" | cut -d'=' -f2)"

if [[ -z "$SONAR_PROJECT_KEY" ]]; then
  echo "ERROR: No se pudo obtener sonar.projectKey desde $PROP_FILE" >&2
  exit 1
fi

echo "→ Proyecto detectado: $SONAR_PROJECT_KEY"
echo

# ================================
# Descargar Issues paginados
# ================================
TMP_FILE="$(mktemp)"
PAGE=1
TOTAL=0

echo "→ Descargando issues desde: $SONAR_HOST_URL"
echo "→ Archivo destino: $OUTPUT_FILE"
echo

while true; do
  echo "→ Página $PAGE ..."

  RESPONSE="$(
    curl -sS -u "${SONAR_TOKEN}:" \
      "${SONAR_HOST_URL}/api/issues/search?componentKeys=${SONAR_PROJECT_KEY}&types=BUG,CODE_SMELL,VULNERABILITY&ps=${PAGE_SIZE}&p=${PAGE}"
  )"

  echo "$RESPONSE" >> "$TMP_FILE"

  PAGE_TOTAL=$(echo "$RESPONSE" | jq '.paging.total')
  PAGE_COUNT=$(echo "$RESPONSE" | jq '.issues | length')

  if [[ "$TOTAL" -eq 0 ]]; then
    TOTAL="$PAGE_TOTAL"
  fi

  echo "   Issues página: $PAGE_COUNT / Total: $TOTAL"

  if [[ "$PAGE_COUNT" -eq 0 ]]; then break; fi

  MAX_FETCHED=$(( PAGE * PAGE_SIZE ))
  if [[ "$MAX_FETCHED" -ge "$TOTAL" ]]; then break; fi

  PAGE=$(( PAGE + 1 ))
done

echo
echo "→ Combinando y filtrando resultados..."

# Filtrar solo campos relevantes y excluir issues cerrados
jq -s '
{ 
  issues: (map(.issues) | add | map(select(.status != "CLOSED")) | map({
    key,
    rule,
    severity,
    component,
    line,
    message,
    type,
    status,
    effort,
    creationDate,
    textRange: {
      startLine: .textRange.startLine,
      endLine: .textRange.endLine
    }
  }))
}' "$TMP_FILE" > "$OUTPUT_FILE"

rm -f "$TMP_FILE"

ISSUES_COUNT=$(jq '.issues | length' "$OUTPUT_FILE")
FILE_SIZE=$(du -h "$OUTPUT_FILE" | cut -f1)

echo "✅ Completo → Issues totales: $ISSUES_COUNT"
echo "📄 Archivo generado: $OUTPUT_FILE (tamaño: $FILE_SIZE)"
