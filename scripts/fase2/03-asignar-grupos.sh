#!/usr/bin/env bash
#
# 03-asignar-grupos.sh — Asigna los agentes existentes a sus grupos de configuración.
#
# Corre DENTRO del LXC 103 (Manager), después de 02-desplegar-config-manager.sh.
#
# Los agentes pihole/npm/homepage se instalaron en la Fase 1 sin grupo (grupo "default").
# El agente proxmox-host, si se instaló con 01-instalar-agente-host.sh de esta fase, ya trae
# su grupo preasignado (WAZUH_AGENT_GROUP) -- este script lo confirma en vez de reasignarlo.
#
# PRERREQUISITO EXPLÍCITO: este script asume que los agentes de la Fase 1 se registraron con
# los nombres EXACTOS "pihole", "npm", "homepage" (así quedaron con WAZUH_AGENT_NAME en
# scripts/05-instalar-agente.sh). Si alguno se reinstaló con otro nombre, este script lo
# salta con un [AVISO], no falla duro -- revisa la salida.
#
# NOTA HONESTA (auditoría 19-sep-2026, Hallazgo J): el parseo de 'agent_control -l' y
# 'agent_groups -s -i' de abajo asume el formato de salida documentado públicamente para
# Wazuh 4.14, pero NO lo verifiqué contra una instalación real (mismo tipo de suposición que
# ya estaba marcada para NPM y docker-listener, y se me había pasado marcarla aquí también).
# Si el parseo no encuentra nada, revisa el formato real con 'agent_control -l' a mano antes
# de asumir que el agente no existe.
#
set -euo pipefail

declare -A AGENT_GROUP=(
    [pihole]=pihole
    [npm]=npm
    [homepage]=homepage
    [proxmox-host]=proxmox-host
)

if command -v pct >/dev/null 2>&1; then
    echo "[FALLA] Estás en el HOST Proxmox, no dentro del LXC 103. Usa 'pct enter 103'." >&2
    exit 1
fi
if [[ "$(hostname)" != "wazuh" ]]; then
    echo "[FALLA] Hostname '$(hostname)' ≠ 'wazuh'. Aborto." >&2
    exit 1
fi

echo "=== Fase 2 — Asignación de agentes a grupos ==="
echo
echo "--- Agentes registrados en el Manager ---"
/var/ossec/bin/agent_control -l
echo

for name in "${!AGENT_GROUP[@]}"; do
    group="${AGENT_GROUP[$name]}"
    # agent_control -l lista "ID: <id>, Name: <name>, IP: ..., Active/Disconnected"
    id=$(/var/ossec/bin/agent_control -l | grep -i "Name: $name," | sed -n 's/.*ID: \([0-9]*\).*/\1/p' | head -1)
    if [[ -z "$id" ]]; then
        echo "[AVISO] No encuentro un agente llamado '$name' registrado. Sáltalo o revisa el"
        echo "        nombre con el que se instaló (WAZUH_AGENT_NAME)."
        continue
    fi
    current_group=$(/var/ossec/bin/agent_groups -s -i "$id" 2>/dev/null | tail -1)
    if [[ "$current_group" == "$group" ]]; then
        echo "[OK] Agente '$name' (ID $id) ya está en el grupo '$group'."
        continue
    fi
    echo "Asignando agente '$name' (ID $id) al grupo '$group'..."
    /var/ossec/bin/agent_groups -a -i "$id" -g "$group" -q
    echo "[OK] '$name' (ID $id) -> grupo '$group'."
done

echo
echo "--- Verificación final ---"
/var/ossec/bin/agent_groups -s

cat <<'EOF'

=== Grupos asignados ===

Siguiente paso (checklist de docs/fase2-checkpoints.md):
  1. Cada agente debe recibir su config nueva en minutos (push automático de Wazuh).
     Verifica en el dashboard: Management -> Groups -> <grupo> -> el agent.conf correcto.
  2. Genera un evento de prueba por fuente (una consulta bloqueada en Pi-hole, un 404 vía
     NPM, detener y levantar un contenedor de Homepage, tocar un archivo en /etc/pve) y
     confirma que aparece la alerta correspondiente en Security Events del dashboard.
  3. Si NPM no genera nada: lo más probable es que la ruta del log en su agent.conf no
     coincide con el bind mount real -- confírmala y corrige antes de seguir.
EOF
