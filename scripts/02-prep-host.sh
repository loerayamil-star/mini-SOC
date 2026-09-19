#!/usr/bin/env bash
#
# 02-prep-host.sh — Checkpoint A2: ÚNICO cambio al host Proxmox de toda la Fase 1.
#
# Qué hace: fija vm.max_map_count=262144 (persistente tras reinicios).
#
# Por qué: el indexador de Wazuh (OpenSearch) mapea muchos segmentos de índice en
# memoria y exige ese mínimo de mapeos por proceso; con el default (65530) se niega
# a arrancar. Los contenedores LXC comparten el kernel del host y NO pueden fijar
# este parámetro por sí mismos — tiene que hacerse aquí y lo heredan todos.
#
# Riesgo para los demás LXCs: ninguno práctico. Solo sube un límite superior; no
# reserva memoria ni cambia el comportamiento de procesos que no lo necesiten.
#
set -euo pipefail

TARGET=262144
CONF=/etc/sysctl.d/99-wazuh-indexer.conf

if ! command -v pct >/dev/null 2>&1; then
    echo "[FALLA] Esto no parece el host Proxmox (no existe 'pct'). Aborto." >&2
    exit 1
fi

CURRENT=$(sysctl -n vm.max_map_count)
echo "vm.max_map_count actual: $CURRENT — objetivo: $TARGET"

if (( CURRENT >= TARGET )) && [[ -f "$CONF" ]]; then
    echo "[OK] Ya está aplicado y persistido en $CONF. Nada que hacer."
    exit 0
fi

echo
echo "Se va a escribir $CONF y aplicar el cambio en vivo."
read -rp "¿Continuar? (escribe 'si' para confirmar): " RESP
[[ "$RESP" == "si" ]] || { echo "Cancelado. No se cambió nada."; exit 1; }

# Persistente: sobrevive reinicios del host (sysctl.d se aplica en cada arranque).
printf '# Requerido por wazuh-indexer (OpenSearch) en el LXC 103 — Fase 1 Mini-SOC\nvm.max_map_count=%s\n' "$TARGET" > "$CONF"

# En vivo: sin esperar al próximo reinicio.
sysctl --system >/dev/null

FINAL=$(sysctl -n vm.max_map_count)
if (( FINAL >= TARGET )); then
    echo "[OK] vm.max_map_count=$FINAL aplicado y persistido en $CONF."
    echo "Siguiente paso: 03-crear-lxc.sh"
else
    echo "[FALLA] El valor sigue en $FINAL tras aplicar. Revisa si otro archivo en" >&2
    echo "        /etc/sysctl.d/ lo está pisando (se aplican en orden alfabético)." >&2
    exit 1
fi
