-- Tabla de historial de la rotacion de ofertas de la semana.
--
-- NO es una tabla de Django: no tiene modelo, ni migracion, ni aparece en el
-- admin. La app 'products' no tiene migraciones (ver README / skill de
-- arquitectura), asi que se crea con SQL directo. Solo la escribe
-- scripts/rotate-week-offers.sh.
--
-- Aplicar con:
--   docker exec -i hc-postgres psql -U hardcoregames -d hardcoregames -v ON_ERROR_STOP=1 < scripts/week-offers-history.sql

CREATE TABLE IF NOT EXISTS hc_week_offers_history (
    id          serial PRIMARY KEY,
    id_product  integer NOT NULL REFERENCES products_products(id_product) ON DELETE CASCADE,
    week_start  date NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS hc_woh_unique ON hc_week_offers_history (id_product, week_start);
CREATE INDEX IF NOT EXISTS hc_woh_last ON hc_week_offers_history (id_product, week_start DESC);

COMMENT ON TABLE hc_week_offers_history IS 'Historial de rotacion de ofertas de la semana. La escribe /root/hc/scripts/rotate-week-offers.sh (cron domingos 05:00 UTC). NO es una tabla de Django, no tiene modelo ni migracion.';
