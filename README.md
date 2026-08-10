# hardcoregames-infra

Configuracion de infraestructura del VPS `srv936408.hstgr.cloud` (148.230.87.252).
No hay CI/CD: todos los despliegues son manuales.

## Contenido

| Ruta | Que es |
|---|---|
| `docker-compose.yml` | Stack de la aplicacion: hc-django, hc-fastapi, hc-frontend. Vive en `/root/hc/` en el VPS. Proyecto compose: `hc`. |
| `traefik-n8n/docker-compose.yml` | Traefik y n8n. En el VPS `/root/docker-compose.yml` es un **symlink** a este archivo. Proyecto compose: `root`. |

El symlink existe para que el archivo quede versionado sin cambiar el directorio
del proyecto compose. Si se moviera de verdad, el proyecto pasaria a llamarse
`traefik-n8n` y compose consideraria huerfanos a `root-traefik-1` y `root-n8n-1`.

## Secretos

Los `.env` NO estan en git (ver `.gitignore`). Viven solo en el VPS:

- `/root/hc/hc-django.env`, `/root/hc/hc-fastapi.env` (modo 600)
- `/root/.env` para `SUBDOMAIN`, `DOMAIN_NAME`, `SSL_EMAIL`, `GENERIC_TIMEZONE`

Se reconstruyen desde un contenedor vivo con:

    docker inspect <c> --format '{{range .Config.Env}}{{println .}}{{end}}' > /tmp/c.env
    docker image inspect <c>:latest --format '{{range .Config.Env}}{{println .}}{{end}}' > /tmp/i.env
    grep -vxF -f /tmp/i.env /tmp/c.env

## Desplegar

    cd /opt/hardcoregames/repos/<servicio>
    git fetch && git log HEAD..origin/<rama> --oneline   # revisar antes de nada
    docker build -t hc-<servicio>:latest .
    cd /root/hc && docker compose up -d <servicio>

Siempre etiquetar la imagen anterior antes de sustituirla:

    docker tag hc-<servicio>:latest hc-<servicio>:rollback-AAAAMMDD

## Por que compose y no docker run

El 2026-08-10 la API publica dio 504. `hc-fastapi` se habia recreado con
`docker run --network hc-net` y se conecto a `n8n_evoapi` despues. Traefik lo
leyo en esa ventana, no encontro endpoint en la red pedida por la etiqueta
`traefik.docker.network` y aplico su fallback de primera-red-disponible, fijando
el servicio a `172.21.0.5`, que Traefik no puede enrutar.

Compose adjunta todas las redes declaradas antes de arrancar el contenedor, asi
que la ventana desaparece. `--providers.docker.network` NO lo resuelve: es
redundante con la etiqueta que ya llevan los contenedores y comparte el mismo
fallback.

## Redes y TLS

- `n8n_evoapi` (172.20.x): la unica que Traefik ve. Todo lo publicado va aqui.
- `hc-net` (172.21.x): red interna de la app, incluye `hc-postgres`. Traefik NO
  tiene interfaz en ella.
- Resolver ACME `mytlschallenge`, reto HTTP-01 sobre el entrypoint `web`,
  almacenado en el volumen `traefik_data` (`/letsencrypt/acme.json`).
- El redirect global `web` -> `websecure` no rompe HTTP-01: Traefik atiende
  `/.well-known/acme-challenge/` antes del middleware de redirect.

## Canario de HTTP-01

El resolver `lestaging` apunta al directorio de staging de Let's Encrypt y
guarda en `/letsencrypt/acme-staging.json`, archivo distinto del de produccion.
El router `acmestagingtest` lo usa sobre `Host(srv936408.hstgr.cloud)` con
`service=noop@internal`: ningun cliente visita ese hostname.

Validado el 2026-08-10: staging emitio el certificado correctamente, lo que
demuestra que Let's Encrypt alcanza el puerto 80 desde fuera y que el redirect
global `web` -> `websecure` no tapa `/.well-known/acme-challenge/`.

Se deja puesto a proposito, como canario permanente. Quitarlo costaria otra
recreacion de Traefik, que tumba TODO el stack unos segundos, a cambio de nada.
Ese hostname sirve un certificado de staging, asi que un navegador avisara si
alguien entra: es lo esperado.

## Pendiente

- `--api.insecure=true` expone el dashboard en el puerto 8080 dentro de
  `n8n_evoapi`. No esta publicado al host, pero cualquier contenedor de esa red
  lo alcanza.

## Prueba de regresion

    curl -s 'https://api.hardcoregames.co/products/filter?console_id=2,1&limit=200'

Debe devolver 143 productos con 143 `id_product` unicos. Ojo: la clave es
`id_product`, no `id`.
