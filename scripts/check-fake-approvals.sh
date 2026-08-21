#!/bin/bash
# Detecta ventas aprobadas por Sistecredito que en realidad NUNCA se cobraron
# -- el mismo patron que paso el 20/08/2026 con davidz102030@gmail.com: la
# pasarela quedo en modo sandbox (SISTECREDITO_SANDBOX=true) y aprobo la
# transaccion sin tocar ningun banco, entregando el producto gratis.
#
# Por que re-consultar a Sistecredito y no confiar en nuestra propia base:
# nuestra fila "approved" es exactamente lo que quedaria mal si el bug se
# repite. La unica fuente que no miente es la pasarela misma, vía
# GetTransactionResponse -- el campo sandbox.isActive es la prueba directa
# de si hubo dinero real. Es la misma verificacion manual que se hizo para
# confirmar el caso de David, ahora automatizada.
#
# Cron cada 5 min. No corre nada destructivo, solo lee.

set -u

WEBHOOK="https://n8n.srv936408.hstgr.cloud/webhook/alerta-pago"
STATE_DIR="/opt/hardcoregames/monitor"
ALERTED="$STATE_DIR/ventas-sin-pago.alerted"
LOG="$STATE_DIR/ventas-sin-pago.log"

mkdir -p "$STATE_DIR"
touch "$ALERTED"

SK=$(grep -m1 "^SISTECREDITO_SUBSCRIPTION_KEY=" /root/hc/hc-django.env | cut -d= -f2-)
AK=$(grep -m1 "^SISTECREDITO_STORE_ID=" /root/hc/hc-django.env | cut -d= -f2-)
AT=$(grep -m1 "^SISTECREDITO_VENDOR_ID=" /root/hc/hc-django.env | cut -d= -f2-)

if [ -z "$SK" ] || [ -z "$AK" ] || [ -z "$AT" ]; then
  echo "$(date -u '+%F %T') SIN CREDENCIALES, abortando" >> "$LOG"
  exit 0
fi

notificar() {
  curl -s -m 20 -X POST "$WEBHOOK" --data-urlencode "text=$1" >/dev/null 2>&1
}

# Ventas aprobadas por Sistecredito en las ultimas 48h (margen amplio: cubre
# que el cron se caiga un rato sin perder el caso).
ROWS=$(docker exec hc-postgres psql -U hardcoregames -d hardcoregames -t -A -F'|' -c "
  SELECT id_transaction, ref_payco, amount,
         to_char(date_transaction AT TIME ZONE 'America/Bogota', 'YYYY-MM-DD HH24:MI'),
         COALESCE(u.email, 'desconocido')
  FROM products_transactions t
  LEFT JOIN auth_user u ON u.id = t.user_id_id
  WHERE t.payment_id = 'sistecredito'
    AND t.status = 'approved'
    AND t.ref_payco <> ''
    AND t.date_transaction > now() - interval '48 hours';
")

[ -z "$ROWS" ] && exit 0

while IFS='|' read -r ID REF AMOUNT FECHA EMAIL; do
  [ -z "$ID" ] && continue
  grep -qx "$ID" "$ALERTED" && continue

  RESP=$(curl -s -m 20 "https://api.credinet.co/pay/GetTransactionResponse?transactionId=$REF" \
    -H "SCLocation: 0,0" -H "SCOrigen: Production" -H "country: co" \
    -H "Ocp-Apim-Subscription-Key: $SK" -H "ApplicationKey: $AK" -H "ApplicationToken: $AT")

  IS_SANDBOX=$(echo "$RESP" | grep -o '"isActive":[a-z]*' | head -1 | cut -d: -f2)

  if [ "$IS_SANDBOX" = "true" ]; then
    echo "$ID" >> "$ALERTED"
    echo "$(date -u '+%F %T') ALERTA transaccion $ID ($EMAIL, COP $AMOUNT, $FECHA) es sandbox" >> "$LOG"
    notificar "ALERTA - HARDCORE GAMES: venta aprobada SIN COBRAR de verdad.

Sistecredito confirma que la transaccion $REF quedo en modo sandbox (isActive:true) pese a estar marcada 'approved' en nuestra base -- exactamente el patron del 20/08 con davidz102030@gmail.com.

Comprador: $EMAIL
Monto que deberia haberse cobrado: COP $AMOUNT
Fecha: $FECHA (Colombia)
Transaccion interna: $ID | Sistecredito: $REF

Revisar ya: SISTECREDITO_SANDBOX en /root/hc/hc-django.env
  docker exec hc-django sh -c 'echo \$SISTECREDITO_SANDBOX'
Si dice 'true', ponerlo en 'false' y recrear hc-django."
  elif [ -n "$IS_SANDBOX" ]; then
    # Confirmada como pago real -- se marca vista para no re-consultar cada 5 min.
    echo "$ID" >> "$ALERTED"
  fi
  # Si $RESP no trae isActive (fallo de red, transactionId invalido), no se
  # marca: se reintenta en la proxima corrida.
done <<< "$ROWS"
