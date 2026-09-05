#!/bin/bash
# Sonda del flujo de pago de hardcoregames.co. Corre por cron cada 5 minutos
# y avisa por Telegram (via webhook de n8n) cuando el pago deja de funcionar.
#
# Por que una sonda y no leer logs: el 21/08/2026 el boton de pagar estuvo
# 11 horas devolviendo 403 por CSRF y `docker logs hc-django` estaba
# completamente limpio -- un 403 del middleware no pasa por el handler
# django.request. Golpear el endpoint es la unica senal fiable.
#
# Por que no se alerta por "no hay ventas hace X horas": se midieron los
# huecos reales de 30 dias y hay pausas normales de hasta 23.8 horas. Ese
# umbral no existe sin gritar en falso casi a diario.
#
# Las sondas NO ensucian datos: los tres endpoints fallan la validacion
# antes de crear ninguna fila en products_transactions.

set -u

WEBHOOK="https://n8n.srv936408.hstgr.cloud/webhook/alerta-pago"
STATE_DIR="/opt/hardcoregames/monitor"
STATE="$STATE_DIR/pago.state"
LAST_ALERT="$STATE_DIR/pago.last-alert"
LOG="$STATE_DIR/pago.log"
FALLOS_ANTES_DE_ALERTAR=2      # 2 chequeos seguidos = 5 min de fallo real
REALERTAR_CADA_SEGUNDOS=3600  # mientras siga caido, recordar 1 vez por hora

mkdir -p "$STATE_DIR"

FALLOS=""

# --- 1. Bold: el endpoint que firma cada pago -------------------------------
# 400 + "Missing required fields" = sano (la vista recibe el POST y valida).
# 403 = CSRF (el fallo del 21/08). 5xx/000 = caido.
TMP=$(mktemp)
CODE=$(curl -s -o "$TMP" -w '%{http_code}' -m 20 -X POST \
  "https://admin.hardcoregames.co/products/generateHashBold/" \
  -H 'Content-Type: application/json' -d '{"amount":1000}')
BODY=$(head -c 160 "$TMP" | tr -d '\n'); rm -f "$TMP"
if [ "$CODE" != "400" ] || ! printf '%s' "$BODY" | grep -q "Missing required fields"; then
  FALLOS="${FALLOS}- Bold (generateHashBold): HTTP $CODE, esperado 400. Respuesta: ${BODY:0:120}
"
fi

# --- 2. Sistecredito --------------------------------------------------------
TMP=$(mktemp)
CODE_SC=$(curl -s -o "$TMP" -w '%{http_code}' -m 20 -X POST \
  "https://admin.hardcoregames.co/products/sistecreditoCreate/" \
  -H 'Content-Type: application/json' -d '{"amount":1}')
BODY_SC=$(head -c 160 "$TMP" | tr -d '\n'); rm -f "$TMP"
if [ "$CODE_SC" != "400" ]; then
  FALLOS="${FALLOS}- Sistecredito (sistecreditoCreate): HTTP $CODE_SC, esperado 400. Respuesta: ${BODY_SC:0:120}
"
fi

# --- 3. La pagina de checkout y su bundle -----------------------------------
CODE_CO=$(curl -s -o /dev/null -w '%{http_code}' -m 20 -L "https://www.hardcoregames.co/checkout")
if [ "$CODE_CO" != "200" ]; then
  FALLOS="${FALLOS}- La pagina /checkout responde HTTP $CODE_CO
"
fi

BUNDLE=$(curl -s -m 20 "https://www.hardcoregames.co/" | grep -oE 'assets/index-[^"]*\.js|_next/static/chunks/[^"]*\.js' | head -1)
if [ -n "$BUNDLE" ]; then
  CODE_JS=$(curl -s -o /dev/null -w '%{http_code}' -m 20 "https://www.hardcoregames.co/$BUNDLE")
  if [ "$CODE_JS" != "200" ]; then
    FALLOS="${FALLOS}- El bundle $BUNDLE responde HTTP $CODE_JS (la tienda no carga)
"
  fi
else
  FALLOS="${FALLOS}- No se encontro el bundle JS en el index.html de la tienda
"
fi

# --- estado y notificacion --------------------------------------------------
notificar() {
  curl -s -m 20 -X POST "$WEBHOOK" --data-urlencode "text=$1" >/dev/null 2>&1
}

AHORA=$(date -u '+%Y-%m-%d %H:%M UTC')
PREVIO=$(cat "$STATE" 2>/dev/null || echo "OK:0")
PREV_ESTADO=${PREVIO%%:*}
PREV_N=${PREVIO##*:}

if [ -z "$FALLOS" ]; then
  if [ "$PREV_ESTADO" = "FAIL" ] && [ "$PREV_N" -ge "$FALLOS_ANTES_DE_ALERTAR" ] 2>/dev/null; then
    notificar "OK - HARDCORE GAMES: el pago volvio a funcionar ($AHORA). Todas las sondas responden lo esperado."
  fi
  echo "OK:0" > "$STATE"
  rm -f "$LAST_ALERT"
  echo "$AHORA OK" >> "$LOG"
  exit 0
fi

N=$((PREV_N + 1))
[ "$PREV_ESTADO" = "FAIL" ] || N=1
echo "FAIL:$N" > "$STATE"
echo "$AHORA FAIL($N) ${FALLOS//$'\n'/ | }" >> "$LOG"

[ "$N" -lt "$FALLOS_ANTES_DE_ALERTAR" ] && exit 0

ULTIMA=$(cat "$LAST_ALERT" 2>/dev/null || echo 0)
AHORA_TS=$(date +%s)
if [ "$N" -gt "$FALLOS_ANTES_DE_ALERTAR" ] && [ $((AHORA_TS - ULTIMA)) -lt "$REALERTAR_CADA_SEGUNDOS" ]; then
  exit 0
fi
echo "$AHORA_TS" > "$LAST_ALERT"

notificar "ALERTA - HARDCORE GAMES: el boton de pagar NO esta funcionando ($AHORA, $N chequeos seguidos).

$FALLOS
Que revisar en el VPS:
  docker logs --tail 50 hc-django
  curl -s -o /dev/null -w '%{http_code}' -X POST https://admin.hardcoregames.co/products/generateHashBold/ -H 'Content-Type: application/json' -d '{\"amount\":1000}'
Un 403 = falta @csrf_exempt en la vista. Un 5xx = mirar la traza. 000 = el contenedor no responde."
