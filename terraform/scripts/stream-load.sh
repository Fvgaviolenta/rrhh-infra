#!/usr/bin/env bash
# Prueba de carga del stream (fase 3 de streaming): escribe <total> marcas sintéticas directo en
# rrhh-events con PutRecords, en lotes de 100 y un lote por segundo, para ver la curva en el
# dashboard rrhh-streaming. Empresa ficticia "carga-prueba": no toca datos de ningún tenant real.
# Uso:  scripts/stream-load.sh [--dry-run] <total>    (STREAM_NAME cambia el stream; por defecto rrhh-events)
#       --dry-run imprime un lote JSON por línea y no llama a AWS.
set -euo pipefail

uso() {
  echo "uso: $0 [--dry-run] <total>   (total: entero mayor que 0)" >&2
  exit 2
}

DRY_RUN=0
if [[ ${1:-} == "--dry-run" ]]; then
  DRY_RUN=1
  shift
fi
[[ $# -eq 1 ]] || uso
TOTAL=$1
[[ $TOTAL =~ ^[1-9][0-9]*$ ]] || uso

STREAM=${STREAM_NAME:-rrhh-events}
TENANT="carga-prueba"
CORRIDA=$(date -u +%Y%m%d%H%M%S)-$$
LOTE_MAX=100

# Un registro de PutRecords; Data es el sobre de rrhh-asistencia como texto JSON (comillas escapadas).
registro() {
  local n=$1 ahora=$2
  local sobre
  sobre=$(printf '{\\"eventId\\":\\"carga-%s-%d\\",\\"eventType\\":\\"asistencia.marca.registrada\\",\\"tenantId\\":\\"%s\\",\\"occurredAt\\":\\"%s\\",\\"aggregateId\\":\\"carga-%s-%d\\",\\"payload\\":{\\"trabajadorId\\":\\"carga-%d\\",\\"tipo\\":\\"ENTRADA\\",\\"origen\\":\\"carga\\",\\"zona\\":\\"America/Santiago\\"}}' \
    "$CORRIDA" "$n" "$TENANT" "$ahora" "$CORRIDA" "$n" "$n")
  printf '{"PartitionKey":"%s","Data":"%s"}' "$TENANT" "$sobre"
}

enviados=0
fallidos=0
n=0
while ((n < TOTAL)); do
  ahora=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  registros=""
  i=0
  while ((i < LOTE_MAX && n < TOTAL)); do
    n=$((n + 1))
    i=$((i + 1))
    registros+="${registros:+,}$(registro "$n" "$ahora")"
  done
  lote=$(printf '{"StreamName":"%s","Records":[%s]}' "$STREAM" "$registros")

  if ((DRY_RUN)); then
    echo "$lote"
    continue
  fi

  fallo=$(aws kinesis put-records --cli-binary-format raw-in-base64-out --cli-input-json "$lote" \
    --query FailedRecordCount --output text)
  fallidos=$((fallidos + fallo))
  enviados=$((enviados + i - fallo))
  ((n < TOTAL)) && sleep 1
done

if ((!DRY_RUN)); then
  echo "$enviados enviados, $fallidos fallidos"
fi
