#!/usr/bin/env bash
#
# 04-instalar-wazuh.sh — Instala Wazuh all-in-one DENTRO del LXC 103.
#
# Cómo llegar aquí (desde el host):
#   pct push 103 /root/fase1-scripts/04-instalar-wazuh.sh /root/04-instalar-wazuh.sh
#   pct enter 103
#   bash /root/04-instalar-wazuh.sh
#
# Qué hace y por qué:
#   1. Instalador oficial 'wazuh-install.sh -a' (rama 4.14): single-node con los 3
#      componentes (indexador + servidor + dashboard) en este contenedor. Se usa el
#      asistente porque genera los certificados TLS entre componentes solo — la parte
#      más propensa a error si se hace a mano, y de bajo valor de aprendizaje.
#   2. Ajuste post-instalación del heap JVM del indexador a 2GB FIJOS. El default de
#      OpenSearch toma ~50% de la RAM visible (3GB de los 6GB del LXC) — demasiado
#      para 3 agentes y le roba margen al manager y al dashboard.
#
set -euo pipefail

WAZUH_BRANCH=4.14
HEAP=2g

# --- Guardas: solo dentro del LXC de Wazuh ------------------------------------
if command -v pct >/dev/null 2>&1; then
    echo "[FALLA] Estás en el HOST Proxmox, no dentro del LXC. Usa 'pct enter 103'." >&2
    exit 1
fi
if [[ "$(systemd-detect-virt 2>/dev/null || true)" != "lxc" ]]; then
    echo "[FALLA] Esto no es un contenedor LXC. Este script es solo para el LXC 103." >&2
    exit 1
fi
if [[ "$(hostname)" != "wazuh" ]]; then
    echo "[FALLA] Hostname '$(hostname)' ≠ 'wazuh'. ¿Seguro que es el LXC 103? Aborto." >&2
    exit 1
fi

echo "=== Instalación de Wazuh $WAZUH_BRANCH (all-in-one) en $(hostname) ==="
echo
echo "AVISO IMPORTANTE ANTES DE EMPEZAR:"
echo "  Al final, el instalador imprime las credenciales 'admin' UNA SOLA VEZ."
echo "  Tenlas guardadas en tu gestor de contraseñas ANTES de cerrar esta terminal."
echo "  (Respaldo cifrado: wazuh-install-files.tar en este directorio; dentro está"
echo "   wazuh-passwords.txt. No lo borres hasta confirmar que guardaste todo.)"
echo
read -rp "¿Continuar con la instalación? (escribe 'si'): " RESP
[[ "$RESP" == "si" ]] || { echo "Cancelado."; exit 1; }

# --- Descarga y ejecución del asistente oficial -------------------------------
apt-get update
apt-get install -y curl

cd /root
curl -sO "https://packages.wazuh.com/$WAZUH_BRANCH/wazuh-install.sh"

echo
echo "Corriendo el instalador (en HDD tarda un buen rato — no lo interrumpas)..."
if ! bash wazuh-install.sh -a; then
    cat >&2 <<'EOF'

[FALLA] El instalador terminó con error. Caso común en LXC: el check de hardware
        no detecta bien los límites del contenedor. Si el error de arriba es de
        requisitos de CPU/RAM, reintenta ignorando los checks (seguro aquí porque
        el sizing ya se validó a mano en el Checkpoint A1):

            bash /root/wazuh-install.sh -a -i

        Si el error es OTRO (certificados, red, servicios), NO reintentes a ciegas:
        lee /var/log/wazuh-install.log y trae el error a una sesión de diagnóstico.
EOF
    exit 1
fi

# --- Ajuste de heap del indexador ---------------------------------------------
echo
echo "Fijando heap del indexador a $HEAP (antes: $(grep -E '^-Xm[sx]' /etc/wazuh-indexer/jvm.options | tr '\n' ' '))..."
sed -i "s/^-Xms.*/-Xms$HEAP/; s/^-Xmx.*/-Xmx$HEAP/" /etc/wazuh-indexer/jvm.options
# Xms=Xmx a propósito: heap fijo evita pausas de resize del GC y hace el consumo predecible.
systemctl restart wazuh-indexer
echo "Esperando a que el indexador vuelva (30-90s en HDD)..."
for i in $(seq 1 18); do
    sleep 10
    systemctl is-active --quiet wazuh-indexer && break
done

# --- Verificación de los 4 servicios ------------------------------------------
echo
echo "--- Estado de servicios ---"
FALLO=0
for svc in wazuh-indexer wazuh-manager filebeat wazuh-dashboard; do
    if systemctl is-active --quiet "$svc"; then
        echo "  [OK]    $svc activo"
    else
        echo "  [FALLA] $svc NO activo — revisa: journalctl -u $svc -n 50"
        FALLO=1
    fi
done
(( FALLO == 0 )) || exit 1

cat <<'EOF'

=== Instalación completada ===

Ahora, desde la laptop (checklist de docs/fase1-checkpoints.md):
  1. GUARDA LAS CREDENCIALES impresas arriba por el instalador (si ya cerraste el
     scroll: tar -axf /root/wazuh-install-files.tar wazuh-install-files/wazuh-passwords.txt -O)
  2. Abre https://wazuh.home (acepta el certificado autofirmado) y haz login.
  3. Prueba de fuego: desde el host, 'pct reboot 103' y verifica que todo vuelve solo.
  4. Solo entonces: Checkpoint A3 y agentes (script 05, orden 102 -> 101 -> 100).
EOF
