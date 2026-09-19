#!/usr/bin/env bash
#
# 02-desplegar-config-manager.sh — Aplica decoders, reglas y configs de grupo DENTRO del LXC 103.
#
# Cómo llegar aquí (desde el host, copia TODO el árbol manager/ del repo primero):
#   pct push 103 /root/fase2-config/manager -- (pct push no soporta directorios; usa uno de:)
#     a) tar -C /root/fase2-source -cf - manager | pct exec 103 -- tar -C /root/fase2-config -xf -
#     b) o monta/copia por scp si el LXC tiene red hacia la laptop
#   pct push 103 scripts/fase2/02-desplegar-config-manager.sh /root/02-desplegar-config-manager.sh
#   pct enter 103
#   bash /root/02-desplegar-config-manager.sh
#
# Espera encontrar, dentro del LXC, el árbol copiado en /root/fase2-config/manager/ con esta
# forma (igual a la del repo):
#   manager/decoders/local_decoder.xml
#   manager/rules/local_rules.xml
#   manager/shared/<grupo>/agent.conf   (para pihole, npm, homepage, proxmox-host)
#
# Seguridad: SIEMPRE respalda lo existente y SIEMPRE valida sintaxis antes de tocar el
# servicio real -- un XML mal formado puede tumbar el Manager y afectar a los 4 agentes que
# ya están reportando.
#
# ADVERTENCIA (auditoría 19-sep-2026): este script SOBRESCRIBE local_decoder.xml y
# local_rules.xml por completo (cp, no merge). Si entre la Fase 1 y ahora escribiste algo a
# mano en esos archivos en el Manager, se pierde -- queda en el respaldo de
# /root/backup-fase2-<fecha>/, pero no se fusiona automáticamente. Revisa ese respaldo antes
# de descartarlo si tocaste esos archivos manualmente en algún momento.
#
set -euo pipefail

SRC=/root/fase2-config/manager
GROUPS=(pihole npm homepage proxmox-host)
TS=$(date +%Y%m%d-%H%M%S)

# --- Guardas: solo dentro del LXC del Manager ---------------------------------
if command -v pct >/dev/null 2>&1; then
    echo "[FALLA] Estás en el HOST Proxmox, no dentro del LXC 103. Usa 'pct enter 103'." >&2
    exit 1
fi
if [[ "$(hostname)" != "wazuh" ]]; then
    echo "[FALLA] Hostname '$(hostname)' ≠ 'wazuh'. ¿Seguro que es el LXC 103? Aborto." >&2
    exit 1
fi
if [[ ! -d "$SRC" ]]; then
    echo "[FALLA] No encuentro $SRC. Copia el árbol manager/ del repo aquí primero (ver" >&2
    echo "        comentario de cabecera de este script para las formas de hacerlo)." >&2
    exit 1
fi
for f in decoders/local_decoder.xml rules/local_rules.xml; do
    [[ -f "$SRC/$f" ]] || { echo "[FALLA] Falta $SRC/$f" >&2; exit 1; }
done

echo "=== Fase 2 — Despliegue de configuración en el Manager ==="
echo

# --- 1. Respaldo de lo existente ----------------------------------------------
# Auditoría 19-sep-2026, Hallazgo E: antes esto usaba '|| true', que esconde CUALQUIER
# error del cp (permisos, disco lleno), no solo el caso normal de "el archivo aún no
# existe" (primera vez que se despliega Fase 2). Si el respaldo falla por otra razón, el
# script debe abortar ANTES de sobrescribir los archivos en vivo, no seguir en silencio.
mkdir -p "/root/backup-fase2-$TS"
for src in /var/ossec/etc/decoders/local_decoder.xml /var/ossec/etc/rules/local_rules.xml; do
    if [[ -f "$src" ]]; then
        if ! cp -a "$src" "/root/backup-fase2-$TS/"; then
            echo "[FALLA] No pude respaldar $src (¿permisos? ¿disco lleno?). Abortando" >&2
            echo "        ANTES de tocar el archivo en vivo — revisa la causa primero." >&2
            exit 1
        fi
    else
        echo "[AVISO] $src no existe todavía (normal en el primer despliegue) — nada que respaldar."
    fi
done
echo "[OK] Respaldo de los local_*.xml existentes en /root/backup-fase2-$TS/"

# --- 2. Copiar los nuevos decoders y reglas -----------------------------------
cp "$SRC/decoders/local_decoder.xml" /var/ossec/etc/decoders/local_decoder.xml
cp "$SRC/rules/local_rules.xml" /var/ossec/etc/rules/local_rules.xml
chown wazuh:wazuh /var/ossec/etc/decoders/local_decoder.xml /var/ossec/etc/rules/local_rules.xml
echo "[OK] local_decoder.xml y local_rules.xml copiados."

# --- 3. VALIDAR sintaxis ANTES de tocar el servicio ---------------------------
echo
echo "--- Validando sintaxis (wazuh-manager -t) ---"
if ! /var/ossec/bin/wazuh-manager -t; then
    echo
    echo "[FALLA] La validación de sintaxis falló. NO se reinició el manager." >&2
    echo "        Restaura el respaldo si hace falta:" >&2
    echo "          cp /root/backup-fase2-$TS/local_decoder.xml /var/ossec/etc/decoders/" >&2
    echo "          cp /root/backup-fase2-$TS/local_rules.xml /var/ossec/etc/rules/" >&2
    exit 1
fi
echo "[OK] Sintaxis válida."

# --- 4. Crear grupos y copiar cada agent.conf ---------------------------------
for g in "${GROUPS[@]}"; do
    if [[ ! -f "$SRC/shared/$g/agent.conf" ]]; then
        echo "[AVISO] No hay $SRC/shared/$g/agent.conf -- salto el grupo '$g'."
        continue
    fi
    # Auditoría 19-sep-2026, Hallazgo F: local_decoder.xml y local_rules.xml pasan por
    # 'wazuh-manager -t' arriba, pero los agent.conf de grupo NO se validaban antes de
    # desplegarse -- un XML mal formado aquí (por ejemplo, al editar a mano la ruta real
    # de NPM en el checklist B4) se aplicaría sin que nada lo detecte.
    if command -v xmllint >/dev/null 2>&1; then
        if ! xmllint --noout "$SRC/shared/$g/agent.conf"; then
            echo "[FALLA] $SRC/shared/$g/agent.conf tiene XML inválido. NO se despliega." >&2
            exit 1
        fi
    else
        echo "[AVISO] xmllint no está disponible -- no pude validar la sintaxis de"
        echo "        $SRC/shared/$g/agent.conf. Instálalo (apt-get install -y libxml2-utils)"
        echo "        o revisa el archivo a mano antes de confiar en este despliegue."
    fi
    if ! /var/ossec/bin/agent_groups -l 2>/dev/null | grep -qx "$g"; then
        /var/ossec/bin/agent_groups -a -g "$g" -q
        echo "[OK] Grupo '$g' creado."
    else
        echo "[OK] Grupo '$g' ya existía."
    fi
    mkdir -p "/var/ossec/etc/shared/$g"
    cp "$SRC/shared/$g/agent.conf" "/var/ossec/etc/shared/$g/agent.conf"
    chown -R wazuh:wazuh "/var/ossec/etc/shared/$g"
    echo "[OK] agent.conf del grupo '$g' aplicado."
done

# --- 5. Reiniciar el manager ---------------------------------------------------
echo
echo "Reiniciando wazuh-manager..."
systemctl restart wazuh-manager
sleep 5
if systemctl is-active --quiet wazuh-manager; then
    echo "[OK] wazuh-manager activo tras el reinicio."
else
    echo "[FALLA] wazuh-manager no quedó activo. Revisa: journalctl -u wazuh-manager -n 50" >&2
    exit 1
fi

cat <<'EOF'

=== Configuración desplegada ===

Siguiente paso: 03-asignar-grupos.sh (asigna los agentes existentes a sus grupos).
EOF
