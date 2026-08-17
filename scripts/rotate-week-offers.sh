#!/usr/bin/env bash
#
# Rota las 12 "ofertas de la semana" de www.hardcoregames.co.
#
# Cron: domingos 05:00 UTC = domingo 00:00 hora de Colombia, que es exactamente
# el instante al que apunta el contador de /week-offers (el bloque hcTick del
# bundle calcula el proximo domingo a medianoche).
#
# Elige los N productos elegibles que llevan MAS tiempo sin aparecer en la
# seccion (los que nunca han salido van primero) y registra lo elegido en
# hc_week_offers_history, de modo que no se repite ninguno hasta agotar el pool.
#
# Elegible = tiene al menos una variante con stock > 0, precio > 0 y
# precio_descuento > 0 con descuento real (precio > precio_descuento), y
# calification >= MIN_CALIFICATION. Son los mismos filtros que aplica el
# endpoint /products/week-offers de hc-fastapi, asi que ningun producto rotado
# puede acabar mostrando la insignia "OFERTA ESPECIAL" sin descuento visible.
#
# Uso:
#   rotate-week-offers.sh              rota de verdad
#   rotate-week-offers.sh --dry-run    solo muestra a quien elegiria
#
# Variables de entorno opcionales: CANTIDAD (12), MIN_CALIFICATION (4)

set -euo pipefail

CANTIDAD="${CANTIDAD:-12}"
MIN_CALIFICATION="${MIN_CALIFICATION:-4}"
MIN_DESCUENTO="${MIN_DESCUENTO:-30}"   # % minimo, para que ninguna semana salga floja
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

# Domingo al que pertenece esta rotacion. Si el script corre en su horario
# normal (domingo 05:00 UTC) es hoy mismo; si se lanza a mano cualquier otro
# dia, es el domingo que viene. Misma formula que el contador del frontend.
SEMANA="(CURRENT_DATE + ((7 - EXTRACT(DOW FROM CURRENT_DATE)::int) % 7))::date"

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$*"; }

db() { docker exec -i hc-postgres psql -U hardcoregames -d hardcoregames -v ON_ERROR_STOP=1 "$@"; }

# CTE compartido por el dry-run y la rotacion real: deja en "candidatos" el pool
# elegible ya ordenado por antiguedad de aparicion.
read -r -d '' CANDIDATOS <<SQL || true
WITH pool AS (
    SELECT g.producto_id AS id_product,
           MIN(g.precio)           FILTER (WHERE g.precio > 0)           AS precio,
           MIN(g.precio_descuento) FILTER (WHERE g.precio_descuento > 0) AS precio_desc
      FROM products_gamedetail g
     WHERE g.stock > 0
     GROUP BY g.producto_id
),
elegibles AS (
    SELECT p.id_product, p.title, p.calification, pool.precio, pool.precio_desc,
           round(100.0 * (pool.precio - pool.precio_desc) / pool.precio) AS pct
      FROM pool
      JOIN products_products p ON p.id_product = pool.id_product
     WHERE pool.precio      IS NOT NULL
       AND pool.precio_desc IS NOT NULL
       AND pool.precio > pool.precio_desc
       AND p.calification >= ${MIN_CALIFICATION}
       AND round(100.0 * (pool.precio - pool.precio_desc) / pool.precio) >= ${MIN_DESCUENTO}
),
-- La recencia se mide POR TITULO, no por id_product. En catalogo hay 22 titulos
-- con dos id distintos (p.ej. "EA FC24" 7 y 8); si midieramos por id, la semana
-- siguiente entraria el gemelo y el mismo juego saldria dos semanas seguidas.
-- Agrupando por titulo, cualquiera de los dos ids cuenta como "ya salio" y el
-- titulo no vuelve hasta que le toca turno. Repetirse pasadas varias semanas si
-- esta permitido: es como se recicla el pool.
recencia_titulo AS (
    SELECT lower(btrim(p.title)) AS tkey, MAX(h.week_start) AS ultima_vez
      FROM hc_week_offers_history h
      JOIN products_products p ON p.id_product = h.id_product
     GROUP BY 1
),
con_recencia AS (
    SELECT e.*,
           COALESCE(r.ultima_vez, DATE '1970-01-01') AS ultima_vez,
           -- Desempate pseudoaleatorio pero determinista: misma semana, misma
           -- seleccion (el dry-run coincide con lo que hara el cron). Evita que
           -- las primeras semanas se lleven lo mejor y las ultimas las sobras,
           -- que es lo que pasaba ordenando por calification/id.
           md5(e.id_product::text || ${SEMANA}::text) AS mezcla
      FROM elegibles e
      LEFT JOIN recencia_titulo r ON r.tkey = lower(btrim(e.title))
),
-- Y dentro de una misma semana, un solo representante por titulo (el de mejor
-- descuento), para que la seccion nunca liste el mismo juego dos veces.
candidatos AS (
    SELECT DISTINCT ON (lower(btrim(title))) *
      FROM con_recencia
     ORDER BY lower(btrim(title)), pct DESC, id_product ASC
)
SQL

ORDEN="ORDER BY ultima_vez ASC, mezcla ASC LIMIT ${CANTIDAD}"

# --- comprobacion de tamano del pool -----------------------------------------
DISPONIBLES=$(db -tAc "${CANDIDATOS} SELECT count(*) FROM candidatos;")
SIN_USAR=$(db -tAc "${CANDIDATOS} SELECT count(*) FROM candidatos WHERE ultima_vez = DATE '1970-01-01';")
log "pool elegible: ${DISPONIBLES} productos (calification >= ${MIN_CALIFICATION}, descuento >= ${MIN_DESCUENTO}%, con stock, sin titulos repetidos)"
log "de esos, ${SIN_USAR} no han salido nunca (~$((SIN_USAR / CANTIDAD)) semanas antes de empezar a repetir)"

if [ "${DISPONIBLES}" -lt "${CANTIDAD}" ]; then
    log "ERROR: solo hay ${DISPONIBLES} productos elegibles y se necesitan ${CANTIDAD}."
    log "ERROR: no se rota nada; las ofertas actuales se quedan como estan. Revisar stock y descuentos."
    exit 1
fi

# --- dry run ------------------------------------------------------------------
if [ "${DRY_RUN}" -eq 1 ]; then
    log "DRY RUN - estos serian los ${CANTIDAD} elegidos, no se modifica nada:"
    db -c "${CANDIDATOS}
           SELECT id_product, title, calification,
                  precio, precio_desc,
                  round(100.0 * (precio - precio_desc) / precio) AS pct,
                  -- OJO: este alias NO puede llamarse ultima_vez. Postgres
                  -- resuelve los alias de salida antes que las columnas de
                  -- entrada, asi que el ORDER BY compartido ordenaria por este
                  -- texto ('2026-08-16' < 'nunca') en vez de por la fecha, y el
                  -- dry-run mostraria una seleccion distinta a la real.
                  CASE WHEN ultima_vez = DATE '1970-01-01' THEN 'nunca'
                       ELSE ultima_vez::text END AS ultima_aparicion
             FROM candidatos ${ORDEN};"
    exit 0
fi

# --- rotacion real ------------------------------------------------------------
# Todo en una transaccion: si algo falla, las ofertas de la semana pasada siguen
# intactas en vez de quedar el sitio con cero ofertas.
log "rotando ${CANTIDAD} ofertas..."
db <<SQL
BEGIN;

CREATE TEMP TABLE _elegidos ON COMMIT DROP AS
${CANDIDATOS}
SELECT id_product FROM candidatos ${ORDEN};

UPDATE products_products SET oferta_semana = false WHERE oferta_semana;

UPDATE products_products SET oferta_semana = true
 WHERE id_product IN (SELECT id_product FROM _elegidos);

INSERT INTO hc_week_offers_history (id_product, week_start)
SELECT id_product, ${SEMANA} FROM _elegidos
    ON CONFLICT (id_product, week_start) DO NOTHING;

COMMIT;
SQL

log "ofertas de la semana activas tras la rotacion:"
db -c "SELECT p.id_product, p.title, p.calification
         FROM products_products p
        WHERE p.oferta_semana
        ORDER BY p.calification DESC, p.id_product;"

ACTIVAS=$(db -tAc "SELECT count(*) FROM products_products WHERE oferta_semana;")
log "rotacion aplicada: ${ACTIVAS} ofertas activas"

# --- refrescar el snapshot de prerender ---------------------------------------
# /week-offers tiene snapshot en el prerender SEO, que se regenera a las 03:30
# UTC. Como rotamos a las 05:00, sin esto los crawlers verian las ofertas de la
# semana pasada durante casi 24 h. Los usuarios reales no se ven afectados (el
# React pide /products/week-offers en vivo), pero Google si.
SEO_SCRIPT=/root/frontend/www.hardcoregames.co/scripts/regenerate-seo.sh
if [ -x "${SEO_SCRIPT}" ]; then
    log "regenerando snapshot SEO..."
    if "${SEO_SCRIPT}" >> /opt/hardcoregames/seo/regenerate.log 2>&1; then
        log "snapshot SEO regenerado"
    else
        log "AVISO: fallo la regeneracion SEO. La rotacion SI se aplico correctamente."
        log "AVISO: revisar /opt/hardcoregames/seo/regenerate.log"
    fi
else
    log "AVISO: no existe ${SEO_SCRIPT}; el prerender de /week-offers quedara"
    log "AVISO: desfasado hasta la regeneracion diaria de las 03:30 UTC."
fi

log "hecho"
