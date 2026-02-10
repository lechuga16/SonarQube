#!/usr/bin/env bash
set -euo pipefail

WHITELIST_PATH="${1:-whitelist.json}"
KEEP_GENERATED="${KEEP_GENERATED:-0}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

WHITELIST_FULL="$ROOT_DIR/$WHITELIST_PATH"
if [[ ! -f "$WHITELIST_FULL" ]]; then
  echo "No existe el archivo de whitelist: $WHITELIST_FULL" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq no esta instalado. Instalarlo e intentar de nuevo." >&2
  exit 1
fi

project_count="$(jq '.projects | length' "$WHITELIST_FULL" 2>/dev/null || echo 0)"
if [[ "$project_count" -eq 0 ]]; then
  echo "whitelist.json debe contener 'projects' con al menos una entrada." >&2
  exit 1
fi

readarray -t host_paths < <(jq -r '.projects[].hostPath // empty' "$WHITELIST_FULL" | awk 'NF' | awk '!seen[tolower($0)]++')
if [[ "${#host_paths[@]}" -eq 0 ]]; then
  echo "No se encontraron hostPath validos en 'projects'." >&2
  exit 1
fi

mounts_json=""
vol_lines=""
for i in "${!host_paths[@]}"; do
  host="${host_paths[$i]}"
  host="${host//\\//}"
  container="/work/src$((i + 1))"

  mounts_json+="{\"host\":\"$host\",\"container\":\"$container\"}"
  if [[ $i -lt $((${#host_paths[@]} - 1)) ]]; then
    mounts_json+=","
  fi

  vol_lines+="      - \"$host:$container:ro\"\n"
done

generated_whitelist="$ROOT_DIR/whitelist.generated.json"
cat >"$generated_whitelist" <<EOF
{
  "mounts": [$mounts_json],
  "projects": $(jq -c '.projects' "$WHITELIST_FULL")
}
EOF

generated_compose="$ROOT_DIR/docker-compose.generated.yml"
cat >"$generated_compose" <<EOF
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
$(printf "%b" "$vol_lines")

volumes:
  scanner_cache:
  scanner_work:
EOF

docker compose -f "$generated_compose" run --rm scanner

if [[ "$KEEP_GENERATED" -ne 1 ]]; then
  rm -f "$generated_compose" "$generated_whitelist"
fi
