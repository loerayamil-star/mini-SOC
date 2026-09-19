#!/usr/bin/env bash
#
# 03-crear-lxc.sh — Crea el LXC 103 para Wazuh Manager en el host Proxmox.
#
# Sizing (justificación completa en README.md — calculado contra 16GB totales):
#   6144MB RAM + 512MB swap · 2 vCPU · 30GB disco · Debian 12
#   No privilegiado + nesting=1 (systemd lo requiere en contenedores no privilegiados)
#   IP estática 192.168.0.56/24 · gw .1 · DNS .53 (Pi-hole) · onboot=1
#
# Al final crea el snapshot 'pre-wazuh-install' — punto de retorno limpio antes
# de instalar nada dentro.
#
set -euo pipefail

# --- Parámetros (edita aquí si tu realidad difiere) ---------------------------
CTID=103
HOSTNAME=wazuh
STORAGE=local-lvm        # verifica con 'pvesm status' (salida del script 01)
DISK_GB=30
RAM_MB=6144
SWAP_MB=512
CORES=2
IP=192.168.0.56/24
GW=192.168.0.1
DNS=192.168.0.53         # Pi-hole — el LXC resuelve .home desde el día uno
BRIDGE=vmbr0

# ------------------------------------------------------------------------------
if ! command -v pct >/dev/null 2>&1; then
    echo "[FALLA] Esto no parece el host Proxmox. Aborto." >&2; exit 1
fi
if pct status "$CTID" >/dev/null 2>&1; then
    echo "[FALLA] El CTID $CTID ya existe. Aborto (¿ya corriste este script?)." >&2; exit 1
fi
if ! pvesm status | awk '{print $1}' | grep -qx "$STORAGE"; then
    echo "[FALLA] El storage '$STORAGE' no existe en este host. Edita la variable" >&2
    echo "        STORAGE al inicio del script (mira 'pvesm status')." >&2; exit 1
fi

# --- Plantilla Debian 12: usar la local o descargar la más reciente -----------
TEMPLATE=$(pveam list local 2>/dev/null | awk '/debian-12-standard/{print $1}' | sort | tail -1)
if [[ -z "$TEMPLATE" ]]; then
    echo "Plantilla debian-12-standard no encontrada localmente. Descargando la más reciente..."
    pveam update
    LATEST=$(pveam available --section system | awk '/debian-12-standard/{print $2}' | sort | tail -1)
    [[ -n "$LATEST" ]] || { echo "[FALLA] No hay debian-12-standard en el repositorio." >&2; exit 1; }
    pveam download local "$LATEST"
    TEMPLATE="local:vztmpl/$LATEST"
fi
echo "[OK] Plantilla: $TEMPLATE"

# --- Contraseña de root del contenedor (no queda en el historial de bash) -----
echo
read -rsp "Contraseña de root para el LXC $CTID (guárdala en tu gestor): " CT_PASS; echo
read -rsp "Repítela: " CT_PASS2; echo
[[ "$CT_PASS" == "$CT_PASS2" && -n "$CT_PASS" ]] || { echo "[FALLA] No coinciden o vacía." >&2; exit 1; }

# --- Confirmación final -------------------------------------------------------
cat <<EOF

Se va a crear:
  CTID $CTID · hostname '$HOSTNAME' · $TEMPLATE
  RAM ${RAM_MB}MB + ${SWAP_MB}MB swap · $CORES vCPU · ${DISK_GB}GB en $STORAGE
  IP $IP (gw $GW, DNS $DNS) en $BRIDGE
  No privilegiado, nesting=1, onboot=1
EOF
read -rp "¿Crear el LXC? (escribe 'si' para confirmar): " RESP
[[ "$RESP" == "si" ]] || { echo "Cancelado. No se creó nada."; exit 1; }

# --- Creación -----------------------------------------------------------------
pct create "$CTID" "$TEMPLATE" \
    --hostname "$HOSTNAME" \
    --password "$CT_PASS" \
    --storage "$STORAGE" --rootfs "$STORAGE:$DISK_GB" \
    --memory "$RAM_MB" --swap "$SWAP_MB" --cores "$CORES" \
    --net0 "name=eth0,bridge=$BRIDGE,ip=$IP,gw=$GW" \
    --nameserver "$DNS" \
    --unprivileged 1 --features nesting=1 \
    --onboot 1

echo "[OK] LXC $CTID creado. Arrancando..."
pct start "$CTID"

# Darle unos segundos a que la red del contenedor levante antes de verificar.
sleep 8
echo "--- Verificación de red desde dentro del contenedor ---"
if pct exec "$CTID" -- ping -c 2 -W 3 "$DNS" >/dev/null 2>&1; then
    echo "[OK] El LXC alcanza a Pi-hole ($DNS)."
else
    echo "[AVISO] El LXC no respondió al ping hacia $DNS todavía. Revisa 'pct exec $CTID -- ip a'"
    echo "        antes de continuar — sin red no tiene caso instalar Wazuh."
fi

# --- Snapshot de punto limpio -------------------------------------------------
pct snapshot "$CTID" pre-wazuh-install --description "Fase 1: LXC recién creado, antes de instalar Wazuh"
echo "[OK] Snapshot 'pre-wazuh-install' creado."

cat <<'EOF'

Siguientes pasos (ver docs/fase1-checkpoints.md):
  1. Registrar wazuh.home -> 192.168.0.56 en Local DNS de Pi-hole (paso manual, UI).
  2. Copiar el instalador dentro:  pct push 103 /root/fase1-scripts/04-instalar-wazuh.sh /root/04-instalar-wazuh.sh
  3. Entrar y correrlo:            pct enter 103  &&  bash /root/04-instalar-wazuh.sh
EOF
