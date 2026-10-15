# =============================================================================
# DOCKERFILE - GATEWAY NGINX
# =============================================================================
# Imagen base oficial de Nginx para linux/amd64
# =============================================================================

FROM nginx:1.25-alpine

# Copiar configuración personalizada
COPY nginx.conf /etc/nginx/nginx.conf

# Exponer puerto 8080
EXPOSE 8080

# Health check
HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

# Comando por defecto
CMD ["nginx", "-g", "daemon off;"]
