FROM nginx:1.27-alpine

# La configuración va dentro de la imagen (nada de bind mounts en el compose)
COPY nginx.conf /etc/nginx/nginx.conf

# Al arrancar, genera la validación de X-API-Key desde la variable API_KEY.
# La imagen oficial ejecuta los scripts de /docker-entrypoint.d/ antes de nginx.
COPY --chmod=755 docker/05-nexo-seguridad.sh /docker-entrypoint.d/05-nexo-seguridad.sh

EXPOSE 8080
