#!/bin/bash
# Backup diario de hardcoregames (hc-postgres) y hc-ventas (hc-ventas-postgres).
# Corre por cron a las 2:50 UTC, antes del cron de SEO (3:30 UTC).
#
# Por que: hasta el 26/08/2026 no habia ningun backup automatico. El unico
# dump que existia era uno hecho a mano el 4 de agosto -- si hc-postgres se
# corrompia se perdian semanas de ventas, usuarios y cuentas de producto.
#
# pg_dump corre DENTRO del contenedor usando POSTGRES_USER/POSTGRES_DB, las
# variables que ya trae la imagen postgres -- este script no guarda ninguna
# credencial.

set -u

BACKUP_DIR="/opt/hardcoregames/backups"
DATE="$(date -u +%Y%m%d-%H%M%S)"
RETENTION_DIAS=30
LOG="$BACKUP_DIR/backup.log"

mkdir -p "$BACKUP_DIR"
log() { echo "$(date -u '+%Y-%m-%d %H:%M:%S UTC') $*" >> "$LOG"; }

FALLOS=""

backup_container() {
  local container="$1" label="$2"
  local tmp="/tmp/${label}-${DATE}.dump"
  local dest="${BACKUP_DIR}/${label}-${DATE}.dump"

  if ! docker ps --format '{{.Names}}' | grep -qx "$container"; then
    log "AVISO: $container no esta corriendo, se salta $label"
    FALLOS="${FALLOS}${label}(contenedor caido); "
    return
  fi

  if ! docker exec "$container" bash -c "pg_dump -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" -F c -f '$tmp' && pg_restore --list '$tmp' >/dev/null"; then
    log "ERROR: pg_dump/verificacion fallo para $label"
    FALLOS="${FALLOS}${label}(dump fallo); "
    docker exec "$container" rm -f "$tmp" 2>/dev/null
    return
  fi

  docker cp "$container:$tmp" "$dest" 2>>"$LOG"
  docker exec "$container" rm -f "$tmp"

  if [ ! -s "$dest" ]; then
    log "ERROR: $dest quedo vacio o no se copio"
    FALLOS="${FALLOS}${label}(copia fallo); "
    return
  fi

  gzip -k "$dest"
  sha256sum "$dest" > "${dest}.sha256"
  log "OK: $label -> $(basename "$dest") ($(du -h "$dest" | cut -f1))"
}

backup_container hc-postgres hc
backup_container hc-ventas-postgres hc-ventas

find "$BACKUP_DIR" -maxdepth 1 -type f \( -name '*.dump' -o -name '*.dump.gz' -o -name '*.sha256' \) -mtime +"$RETENTION_DIAS" -print -delete >> "$LOG" 2>&1

if [ -n "$FALLOS" ]; then
  log "BACKUP CON FALLOS: $FALLOS"
  exit 1
fi
log "Backup diario completado sin errores"
