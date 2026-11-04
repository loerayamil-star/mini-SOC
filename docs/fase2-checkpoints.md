# Fase 2 — Guía de ejecución manual con checkpoints

Requisito previo: la Fase 1 debe estar completamente verificada (Manager funcionando, 3
agentes Active) — sigue [fase1-checkpoints.md](fase1-checkpoints.md) primero si no lo has
hecho. Esta guía asume que ya tienes eso.

---

## Checkpoint B1 — Agente nuevo en el host Proxmox

Este es el único paso de esta fase que toca el host físico directamente (no un LXC ni el
Manager). Decisión tomada explícitamente en la planeación: sin este agente no hay forma de
cubrir SSH del host ni cambios en `/etc/pve`.

```bash
# Desde la laptop: copiar el script al host
scp scripts/fase2/01-instalar-agente-host.sh root@<IP_PROXMOX>:/root/

# En el host:
ssh root@<IP_PROXMOX>
bash /root/01-instalar-agente-host.sh
```

- [ ] El agente `proxmox-host` aparece **Active** en el dashboard de Wazuh
- [ ] Los 3 agentes de la Fase 1 (pihole, npm, homepage) siguen Active — este paso no debió
      tocarlos, pero confírmalo
- [ ] `free -h` en el host: la RAM sigue en rango sano (el agente pesa ~35MB, no debería
      notarse)

---

## Checkpoint B2 — Desplegar decoders, reglas y configs de grupo en el Manager

```bash
# Desde la laptop: copiar el árbol de configuración completo al host, y de ahí al LXC 103
scp -r manager/ root@<IP_PROXMOX>:/root/fase2-source/
ssh root@<IP_PROXMOX>

# En el host: pasar el árbol al LXC (pct push no soporta directorios completos)
mkdir -p /root/fase2-config
tar -C /root/fase2-source -cf - manager | pct exec 103 -- tar -C /root/fase2-config -xf -
pct push 103 /root/fase2-source/../scripts/fase2/02-desplegar-config-manager.sh /root/02-desplegar-config-manager.sh
pct push 103 /root/fase2-source/../scripts/fase2/03-asignar-grupos.sh /root/03-asignar-grupos.sh

pct enter 103
bash /root/02-desplegar-config-manager.sh
```

- [ ] `wazuh-manager -t` (dentro del script) valida la sintaxis SIN errores antes de que el
      script toque el servicio — si falla aquí, el script se detiene solo y no reinicia nada
- [ ] `wazuh-manager` activo tras el reinicio
- [ ] Existe el respaldo en `/root/backup-fase2-<fecha>/` (por si hay que revertir)
- [ ] Los 4 grupos (`pihole`, `npm`, `homepage`, `proxmox-host`) aparecen en
      Management → Groups del dashboard — si `agent_groups -a -g proxmox-host` falla por el
      guion en el nombre (no verificado contra una instalación real), renómbralo a
      `proxmox_host` de forma consistente en `agent.conf` y en `03-asignar-grupos.sh`

**Si algo sale mal aquí:** restaura desde el respaldo (comando exacto lo imprime el propio
script si la validación falla) y no sigas al siguiente paso hasta resolverlo — un Manager con
reglas rotas afecta a los 4 agentes a la vez.

---

## Checkpoint B3 — Asignar agentes a sus grupos

```bash
# Dentro del LXC 103 (ya estás ahí si vienes del paso anterior)
bash /root/03-asignar-grupos.sh
```

- [ ] Los 4 agentes (`pihole`, `npm`, `homepage`, `proxmox-host`) quedan asignados a su grupo
      correspondiente (el script lo verifica al final con `agent_groups -s`)
- [ ] En el dashboard, cada agente muestra su grupo correcto en Management → Agents

---

## Checkpoint B4 — Confirmar rutas reales antes de dar por buena la config

Dos cosas de esta fase se armaron sin acceso en vivo a tu infraestructura — confírmalas ahora:

- [ ] **NPM:** ¿la ruta del bind mount en `manager/shared/npm/agent.conf`
      (`/opt/npm/data/logs/...`) coincide con cómo mapeaste el volumen de logs del contenedor
      de NPM en el LXC 101? Si no, corrige la ruta en ese `agent.conf`, cópialo de nuevo a
      `/var/ossec/etc/shared/npm/agent.conf` en el LXC 103, y no hace falta reiniciar el
      manager para esto (los `agent.conf` de grupo se recargan solos).
- [ ] **NPM (formato):** captura una línea real de
      `proxy-host-<id>_access.log` y compárala contra el formato asumido en
      `manager/decoders/local_decoder.xml` (comentario de cabecera del decoder `npm-access`).
      Si difiere, el decoder no va a matchear nada — ajusta el regex antes de seguir.
- [ ] **Docker-listener:** genera un evento real (`docker stop`/`docker start` de cualquier
      contenedor del LXC 102) y en el dashboard revisa el JSON crudo del evento en Security
      Events → busca por agente `homepage`. Compara los nombres de campo reales
      (`Action`, `Type`, `Actor.Attributes.name`, etc.) contra lo que asume
      `manager/rules/local_rules.xml`. Ajusta los `<field name="...">` si no coinciden.
      **Además (auditoría 19-sep-2026, Hallazgo H):** antes de confiar en el decoder
      `<decoded_as>json</decoded_as>` que escribí, revisa si Wazuh ya trae un decoder propio
      para la salida de `docker-listener` (es un módulo first-party, es probable que sí —
      no lo verifiqué). Búscalo con
      `grep -rl docker /var/ossec/ruleset/decoders/ /var/ossec/ruleset/rules/` dentro del
      LXC 103. Si existe uno stock, úsalo en vez del mío (evita reglas duplicadas o que
      nunca disparen por un nombre de decoder equivocado).

---

## Verificación funcional por fuente (prueba de fuego de cada una)

- [ ] **Pi-hole:** desde cualquier dispositivo de la red, visita un dominio que sepas que
      Pi-hole bloquea. Confirma que aparece un evento con regla 100001 (`pihole,dns_blocked`)
      en el dashboard.
- [ ] **NPM:** solicita una ruta que dé 404 a través de un dominio proxied por NPM. Confirma
      evento con regla 100101.
- [ ] **Homepage/Docker:** `docker stop <contenedor>` y luego `docker start <contenedor>` en
      el LXC 102. Confirma evento con regla 100201.
- [ ] **Proxmox host (⚠️ la prueba más importante de esta fase — no la saltes):** edita
      cualquier archivo trivial dentro de `/etc/pve` (ej. toca un comentario en la config de
      un LXC) y confirma evento con regla 100300, con `report_changes` mostrando el diff.
      **`/etc/pve` es un filesystem FUSE (pmxcfs), no uno normal — `realtime="yes"` (basado
      en inotify) puede no funcionar sobre FUSE de forma confiable (Hallazgo G de la
      auditoría, sin verificar contra una prueba real hasta que hagas ESTA).** Si tras un
      par de minutos no aparece nada: prueba `whodata` o cae a un barrido programado más
      frecuente — las dos alternativas están documentadas en el comentario de
      `manager/shared/proxmox-host/agent.conf`.
- [ ] **SSH del host:** intenta un login SSH fallido a propósito contra el host. Confirma que
      aparece con el ruleset stock de sshd (sin necesidad de ninguna regla custom de este
      repo).

## Recordatorio importante

Las reglas 100002, 100102 y 100202 de `local_rules.xml` están marcadas explícitamente como
`mini_soc_needs_tuning` — son puntos de partida razonables, no umbrales calibrados contra tu
red real. Calibrarlos con datos reales (Fase 3) es trabajo tuyo, no mío.
