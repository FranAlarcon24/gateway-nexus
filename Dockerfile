FROM nginx:1.27-alpine

# La configuración va dentro de la imagen (nada de bind mounts en el compose)
COPY nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 8080
