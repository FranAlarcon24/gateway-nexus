FROM nginx:1.27-alpine

# La configuración va dentro de la imagen (nada de bind mounts en el compose)
COPY nginx.conf /etc/nginx/nginx.conf

EXPOSE 8080
