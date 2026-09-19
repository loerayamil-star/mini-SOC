#!/usr/bin/env bash
#
# 01-instalar-agente-host.sh — Instala el agente Wazuh DIRECTO en el host Proxmox.
#
# Distinto de scripts/05-instalar-agente.sh (Fase 1): ese script se niega a correr en el
# host a propósito, porque en la Fase 1 el alcance eran solo los 3 LXCs. Este es el 4to
# agente, decidido explícitamente en la planeación de la Fase 2 (ver docs/fase2-fuentes-datos.md)
# para cubrir SSH del host y FIM de /etc/pve.
#
# Uso (en el host Proxmox, como root):
#   bash 01-instalar-agente-host.sh
#
set -euo pipefail

MANAGER_IP=192.168.0.56
AGENT_NAME=proxmox-host
AGENT_GROUP=proxmox-host   # preasigna el grupo al instalar -- ver manager/shared/proxmox-host/agent.conf

# --- Guardas ------------------------------------------------------------------
if ! command -v pct >/dev/null 2>&1; then
    echo "[FALLA] No encuentro 'pct'. Esto no parece el host Proxmox. Aborto." >&2
    exit 1
fi
if [[ "$(systemd-detect-virt 2>/dev/null || true)" == "lxc" ]]; then
    echo "[FALLA] Estás dentro de un LXC, no en el host. Usa 05-instalar-agente.sh (Fase 1)." >&2
    exit 1
fi
if dpkg -s wazuh-agent >/dev/null 2>&1; then
    echo "[FALLA] wazuh-agent ya está instalado aquí. ¿Corriste esto dos veces?" >&2
    exit 1
fi

echo "=== Agente Wazuh en el HOST Proxmox -> grupo '$AGENT_GROUP' (Manager $MANAGER_IP) ==="
echo
echo "Este es un cambio directo al host físico (igual de sensible que el sysctl de la Fase 1)."
read -rp "¿Confirmas que ya pasaste el checkpoint del checklist de Fase 2 para este paso? (escribe 'si'): " RESP
[[ "$RESP" == "si" ]] || { echo "Cancelado."; exit 1; }

# --- Repo oficial de Wazuh ----------------------------------------------------
apt-get update
apt-get install -y curl gnupg apt-transport-https

curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | \
    gpg --no-default-keyring --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg --import
chmod 644 /usr/share/keyrings/wazuh.gpg
echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" \
    > /etc/apt/sources.list.d/wazuh.list
apt-get update

# --- Instalación: WAZUH_AGENT_GROUP preasigna el grupo desde el arranque -------
WAZUH_MANAGER="$MANAGER_IP" WAZUH_AGENT_NAME="$AGENT_NAME" WAZUH_AGENT_GROUP="$AGENT_GROUP" \
    apt-get install -y wazuh-agent

systemctl daemon-reload
systemctl enable wazuh-agent
systemctl start wazuh-agent

# --- Verificación de conexión con el Manager ----------------------------------
echo "Esperando la conexión con el Manager (hasta 60s)..."
CONECTADO=0
for i in $(seq 1 12); do
    sleep 5
    if grep -q "Connected to the server" /var/ossec/logs/ossec.log 2>/dev/null; then
        CONECTADO=1; break
    fi
done
if (( CONECTADO )); then
    echo "[OK] Agente conectado al Manager."
else
    echo "[AVISO] Aún no veo 'Connected to the server' en /var/ossec/logs/ossec.log."
    echo "        Revisa ese log y la vista de agentes del dashboard antes de continuar."
fi

# --- Desactivar el repo: actualizaciones del agente solo deliberadas ----------
sed -i 's/^deb/#deb/' /etc/apt/sources.list.d/wazuh.list
apt-get update >/dev/null
echo "[OK] Repo de Wazuh desactivado (reactívalo para actualizar agente y Manager JUNTOS)."

cat <<'EOF'

=== Agente del host Proxmox instalado ===

Antes de continuar (checklist de docs/fase2-checkpoints.md):
  1. En el dashboard de Wazuh: el agente 'proxmox-host' aparece Active y en el grupo correcto.
  2. Los otros 3 agentes (pihole, npm, homepage) y sus LXCs siguen sanos -- este paso no
     debió tocarlos, pero confírmalo.
  3. Solo entonces: 02-desplegar-config-manager.sh (aplica decoders/rules/agent.conf).
EOF
