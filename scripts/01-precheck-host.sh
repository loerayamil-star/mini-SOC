#!/usr/bin/env bash
#
# 01-precheck-host.sh — Checkpoint A1: recon de SOLO LECTURA en el host Proxmox.
# No modifica nada. Corre esto ANTES que cualquier otro script de la Fase 1.
#
# Por qué existe: el sizing del LXC de Wazuh (6GB RAM) se calculó asumiendo que el
# módulo adicional de 8GB DDR3 ya está instalado (16GB totales). Si eso no es
# cierto, TODO el plan cambia — este script lo verifica antes de tocar nada.
#
set -euo pipefail

CTID=103                 # ID que usará el LXC de Wazuh
MIN_RAM_MB=12000         # umbral: 16GB reales reportan ~15-16000MB; 8GB reportan ~7900
MIN_DISK_GB=40           # 30GB del LXC + margen de trabajo

ok()   { echo "  [OK]    $*"; }
warn() { echo "  [AVISO] $*"; }
fail() { echo "  [FALLA] $*"; }

echo "=== Fase 1 / Checkpoint A1 — Precheck del host Proxmox ==="
echo

# --- 0. ¿Estamos realmente en el host Proxmox? -------------------------------
if ! command -v pct >/dev/null 2>&1; then
    fail "No encuentro el comando 'pct'. Esto no parece el host Proxmox."
    fail "Corre este script vía SSH en root@192.168.0.232, no en la laptop."
    exit 1
fi
ok "Host Proxmox detectado: $(pveversion)"
echo

# --- 1. RAM total (la verificación que decide si se ejecuta la fase) ---------
RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
echo "--- RAM ---"
free -h | sed 's/^/  /'
if (( RAM_MB < MIN_RAM_MB )); then
    fail "RAM total: ${RAM_MB}MB — el módulo de 8GB NO está instalado (o no fue detectado)."
    fail "El sizing de la Fase 1 asume 16GB. DETENTE AQUÍ (decisión del 16-sep-2026)."
    exit 1
fi
ok "RAM total: ${RAM_MB}MB — consistente con 16GB instalados."
echo

# --- 2. CTID 103 libre --------------------------------------------------------
echo "--- Contenedores existentes ---"
pct list | sed 's/^/  /'
if pct status "$CTID" >/dev/null 2>&1; then
    fail "El CTID $CTID ya existe. Elige otro ID o investiga qué es antes de seguir."
    exit 1
fi
ok "CTID $CTID libre."
echo

# --- 3. Espacio en el almacenamiento -----------------------------------------
# Se reporta todo el estado de storage; el LXC necesita ~30GB + margen.
echo "--- Almacenamiento (pvesm status, en KiB) ---"
pvesm status | sed 's/^/  /'
AVAIL_GB=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
if (( AVAIL_GB < MIN_DISK_GB )); then
    warn "Raíz del host con ${AVAIL_GB}GB libres (< ${MIN_DISK_GB}GB). Revisa arriba en qué"
    warn "storage vivirán los 30GB del LXC (local-lvm suele ser un pool aparte de la raíz)."
else
    ok "Raíz del host con ${AVAIL_GB}GB libres."
fi
echo

# --- 4. Plantilla Debian 12 ---------------------------------------------------
echo "--- Plantilla Debian 12 ---"
if pveam list local 2>/dev/null | grep -q 'debian-12-standard'; then
    ok "Plantilla ya descargada: $(pveam list local | grep debian-12-standard | awk '{print $1}')"
else
    warn "Plantilla debian-12-standard no descargada aún. El script 03 la descarga solo"
    warn "(pveam update && pveam download). Disponibles en el repositorio:"
    pveam update >/dev/null 2>&1 || true
    pveam available --section system 2>/dev/null | grep debian-12-standard | sed 's/^/    /' || \
        warn "No pude listar el repositorio (¿sin internet?). Verifica conectividad."
fi
echo

# --- 5. vm.max_map_count (lo que el script 02 va a cambiar) -------------------
echo "--- Kernel ---"
CURRENT_MMC=$(sysctl -n vm.max_map_count)
if (( CURRENT_MMC >= 262144 )); then
    ok "vm.max_map_count=$CURRENT_MMC — ya cumple; el script 02 será un no-op."
else
    warn "vm.max_map_count=$CURRENT_MMC — el indexador exige 262144. Lo fija el script 02."
fi
echo

# --- 6. Pendiente viejo del homelab: onboot de los LXCs existentes ------------
# Solo se REPORTA (este script no cambia nada). Si algún LXC crítico está en
# onboot=0, tras un corte de luz no se levanta solo — decide tú si activarlo:
#   pct set <ID> --onboot 1
echo "--- Arranque automático (onboot) de los LXCs existentes ---"
for id in 100 101 102; do
    ONBOOT=$(pct config "$id" 2>/dev/null | awk '/^onboot:/{print $2}')
    if [[ "${ONBOOT:-0}" == "1" ]]; then
        ok "LXC $id: onboot activado."
    else
        warn "LXC $id: onboot DESACTIVADO (o sin definir). Considera: pct set $id --onboot 1"
    fi
done
echo

echo "=== Precheck terminado. Compara contra la lista A1 de docs/fase1-checkpoints.md ==="
echo "=== Si todo está en verde, el siguiente paso es 02-prep-host.sh (Checkpoint A2). ==="
