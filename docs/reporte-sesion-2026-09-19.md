# Reporte de sesión — 19 de septiembre de 2026

**Proyecto:** Mini-SOC (tercer pilar del portafolio: SOC-DFIR)
**Fase:** 2 — Fuentes de datos (decoders, reglas base, configuración centralizada)
**Alcance de la sesión:** planeación y preparación de configs/scripts. **No se tocó
infraestructura real.**

---

## Diagnóstico

- Investigué contra documentación oficial y fuentes públicas el formato real de cada fuente
  antes de escribir nada: log de Pi-hole v6 (`/var/log/pihole/pihole.log`, sigue en formato
  dnsmasq/syslog), log de NPM en Docker (formato propio, no Apache combined), módulo
  `docker-listener` de Wazuh (wodle oficial vía socket de Docker) y opciones para vigilar
  `/etc/pve` en el host Proxmox.
- **Gap detectado contra el alcance de la Fase 1:** `contexto_minisoc.md` pide monitorear SSH
  del host Proxmox y cambios en `/etc/pve`, pero la Fase 1 solo instaló agentes en los 3 LXCs
  — el host físico se quedó sin agente. Sin un 4to agente ahí, esas dos fuentes son
  técnicamente imposibles de cubrir.
- **Limitación técnica real encontrada y documentada, no escondida:** la línea `gravity
  blocked` de dnsmasq no repite la IP del cliente que originó el bloqueo — solo aparece en la
  línea `query` precedente. Atribuir bloqueos a un dispositivo específico requeriría
  correlación por PID, fuera del alcance de un decoder simple; la regla de picos de bloqueo
  quedó basada en volumen total de la red, no por cliente, con esa limitación anotada.

## Decisiones tomadas (confirmadas contigo antes de escribir nada)

1. **Se agrega un 4to agente Wazuh, instalado directo en el host Proxmox.** Footprint ~35MB
   RAM, insignificante. Es un cambio de alcance real sobre la Fase 1, así que quedó como su
   propio checkpoint (B1), separado de los 3 agentes ya existentes.
2. **NPM corre en Docker** dentro del LXC 101 (confirmado por ti) — el decoder se diseñó
   contra la ruta de un bind mount del volumen de logs, no contra una instalación nativa.
   Quedó marcado explícitamente como "a confirmar contra la ruta real" porque no tengo acceso
   en vivo para verificarlo.
3. **FIM (File Integrity Monitoring) sobre `/etc/pve`** en vez de intentar parsear un log de
   auditoría de Proxmox que no existe de forma confiable para "quién cambió qué" — es el
   mecanismo correcto de Wazuh para este caso, no un log tradicional.
4. **SSH del host no necesita decoder ni reglas custom** — al ser Debian, hereda el ruleset
   stock de Wazuh para sshd/PAM (incluida la regla de fuerza bruta) apenas se instale el
   agente. Cero trabajo adicional ahí.
5. **Configuración centralizada por grupos de Wazuh** (`pihole`, `npm`, `homepage`,
   `proxmox-host`) en vez de tocar cada agente a mano — es el mecanismo oficial de Wazuh y el
   patrón que se reutilizará si se agrega la Micro PC al cluster más adelante.
6. **Todo el contenido custom en los dos archivos canónicos** (`local_decoder.xml`,
   `local_rules.xml`), IDs de reglas arrancando en 100000 — convención oficial de Wazuh.

## Ejecución (lo producido, aprobado el plan completo antes de generar los archivos)

| Archivo | Contenido |
|---|---|
| `docs/fase2-fuentes-datos.md` | Decisiones y el porqué de cada una de las 4 fuentes |
| `docs/fase2-checkpoints.md` | Guía manual: checkpoints B1–B4, verificación funcional por fuente, recordatorio de que 3 reglas están marcadas como pendientes de calibrar |
| `manager/decoders/local_decoder.xml` | Decoders custom: Pi-hole (query/blocked), NPM (access log) |
| `manager/rules/local_rules.xml` | Reglas base de categorización + 3 reglas de ejemplo con umbral de partida (picos Pi-hole, fuerza bruta NPM, crash-loop Docker) + regla de FIM sobre `/etc/pve` |
| `manager/shared/{pihole,npm,homepage,proxmox-host}/agent.conf` | Config centralizada por grupo (localfile, wodle docker-listener, syscheck) |
| `scripts/fase2/01-instalar-agente-host.sh` | Instala el agente en el host Proxmox (variante de la Fase 1, guarda invertida) |
| `scripts/fase2/02-desplegar-config-manager.sh` | Aplica decoders/reglas/configs en el Manager — respalda lo existente y **valida sintaxis (`wazuh-manager -t`) antes de reiniciar el servicio**, para no tumbar el Manager con un XML mal formado |
| `scripts/fase2/03-asignar-grupos.sh` | Asigna los 4 agentes a sus grupos correspondientes |

**Verificación de la sesión:** los 6 archivos XML pasaron `xmllint --noout` (tras corregir un
error real: comentarios XML no admiten doble guion `--`, lo encontré con el propio validador y
lo corregí en los 6 archivos). Los 3 scripts pasaron `bash -n` y quedaron ejecutables.

## Resultado

- Fase 2 empaquetada y lista para ejecución manual, condicionada a que la Fase 1 esté
  ejecutada y verificada primero.
- Infraestructura real intacta: cero conexiones al Proxmox durante la sesión.
- **Puntos que quedan explícitamente marcados como "confirmar el día de la ejecución"**, no
  como garantizados: la ruta exacta del bind mount de logs de NPM, el formato real de esas
  líneas de log, y los nombres de campo JSON reales que produce `docker-listener` en la
  versión instalada. El checklist B4 los cubre uno por uno.
- Pendiente fuera de esta sesión: la calibración de los 3 umbrales marcados
  `mini_soc_needs_tuning` — es trabajo tuyo (Fase 3), no mío.

---

*Sesión conducida con Claude Code (planeación, investigación técnica y generación de
configs/scripts; decisiones de arquitectura y aprobaciones: Yamil).*
