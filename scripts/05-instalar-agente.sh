#!/usr/bin/env bash
#
# 05-instalar-agente.sh — Instala el agente Wazuh DENTRO de un LXC existente.
#
# Uso (orden deliberado: del menos al más crítico para la red — ver checkpoints A3/A4):
#   LXC 102:  bash 05-instalar-agente.sh homepage
#   LXC 101:  bash 05-instalar-agente.sh npm
#   LXC 100:  bash 05-instalar-agente.sh pihole    <- SOLO tras pasar el Checkpoint A4
#
# Cómo llegar aquí (desde el host, ejemplo con el 102):
#   pct snapshot 102 pre-wazuh-agent                                    <- SIEMPRE el snapshot PRIMERO
#   pct push 102 <(echo "$(date -u +%FT%TZ)") /root/.pre-wazuh-agent-snapshot-ok  <- marca verificable
#   pct push 102 /root/fase1-scripts/05-instalar-agente.sh /root/05-instalar-agente.sh
#   pct enter 102
#   bash /root/05-instalar-agente.sh homepage
#
# AUDITORÍA (19-sep-2026, Hallazgo A): antes este script solo PREGUNTABA si ya habías
# tomado el snapshot y aceptaba un "si" tecleado sin verificar nada — no hay forma de que
# un script corriendo DENTRO del LXC compruebe algo con 'pct' (vive en el host, y de
# cualquier forma un LXC no privilegiado no debería tener ese control). La marca de archivo
# de arriba es la verificación real: solo puede existir si el paso de snapshot en el host
# ya corrió.
#
# Qué hace: agrega el repo apt oficial de Wazuh, instala wazuh-agent apuntando al
# Manager (192.168.0.56), lo arranca, verifica la conexión, y DESACTIVA el repo al
# final para que el mantenimiento mensual no suba la versión del agente por accidente
# (agente y Manager deben actualizarse juntos, de forma deliberada).
#
# Footprint del agente: ~35MB de RAM — no compite con el servicio que ya vive aquí.
#
set -euo pipefail

MANAGER_IP=192.168.0.56
AGENT_NAME="${1:-}"

# --- Guardas ------------------------------------------------------------------
case "$AGENT_NAME" in
    homepage|npm|pihole) ;;
    *) echo "Uso: $0 <homepage|npm|pihole>  (nombre con el que se registra en el Manager)" >&2
       exit 1 ;;
esac
if command -v pct >/dev/null 2>&1; then
    echo "[FALLA] Estás en el HOST Proxmox. Entra al LXC con 'pct enter <ID>' primero." >&2
    exit 1
fi
if [[ "$(systemd-detect-virt 2>/dev/null || true)" != "lxc" ]]; then
    echo "[FALLA] Esto no es un contenedor LXC. Aborto." >&2
    exit 1
fi
if [[ "$(hostname)" == "wazuh" ]]; then
    echo "[FALLA] Este es el LXC del Manager — el Manager no lleva agente aparte. Aborto." >&2
    exit 1
fi
if dpkg -s wazuh-agent >/dev/null 2>&1; then
    echo "[FALLA] wazuh-agent ya está instalado aquí. ¿Corriste esto dos veces?" >&2
    exit 1
fi

echo "=== Agente Wazuh -> '$AGENT_NAME' (en $(hostname), Manager $MANAGER_IP) ==="
echo

# Verificación REAL, no una pregunta de confianza: el paso de snapshot en el host debió
# dejar esta marca justo después de 'pct snapshot' (ver comentario de cabecera). Si no
# existe, no hay snapshot confirmado -- no hay excepción a esta regla.
SNAPSHOT_MARKER=/root/.pre-wazuh-agent-snapshot-ok
if [[ ! -f "$SNAPSHOT_MARKER" ]]; then
    echo "[FALLA] No encuentro $SNAPSHOT_MARKER." >&2
    echo "        Eso significa que el paso de snapshot en el HOST no se hizo (o se saltó)." >&2
    echo "        Desde el host: pct snapshot <ID> pre-wazuh-agent" >&2
    echo "                       pct push <ID> <(echo ok) $SNAPSHOT_MARKER" >&2
    exit 1
fi
echo "[OK] Snapshot confirmado (marca de $(cat "$SNAPSHOT_MARKER"))."

# --- Repo oficial de Wazuh ----------------------------------------------------
apt-get update
apt-get install -y curl gnupg apt-transport-https

curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | \
    gpg --no-default-keyring --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg --import
chmod 644 /usr/share/keyrings/wazuh.gpg
echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" \
    > /etc/apt/sources.list.d/wazuh.list
apt-get update

# --- Instalación: las variables de entorno preconfiguran ossec.conf -----------
WAZUH_MANAGER="$MANAGER_IP" WAZUH_AGENT_NAME="$AGENT_NAME" apt-get install -y wazuh-agent

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
    echo "        Causas típicas: puerto 1514/tcp bloqueado, o el Manager caído."
fi

# --- Desactivar el repo: actualizaciones del agente solo deliberadas ----------
sed -i 's/^deb/#deb/' /etc/apt/sources.list.d/wazuh.list
apt-get update >/dev/null
echo "[OK] Repo de Wazuh desactivado (reactívalo quitando el '#' cuando toque actualizar"
echo "     agente y Manager JUNTOS en el mantenimiento mensual)."

cat <<EOF

=== Agente '$AGENT_NAME' instalado ===

Antes de pasar al siguiente LXC, verifica (checklist de docs/fase1-checkpoints.md):
  1. En el dashboard de Wazuh: el agente '$AGENT_NAME' aparece como Active.
  2. El servicio original de ESTE LXC sigue funcionando (dig / proxy / widgets,
     según cuál sea — la lista exacta está en el checklist).
Si algo se degradó: rollback con 'pct rollback <ID> pre-wazuh-agent' desde el host.
EOF
