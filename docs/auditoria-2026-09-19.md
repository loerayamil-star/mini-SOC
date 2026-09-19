# Auditoría de seguridad y riesgo de ejecución — 19 de septiembre de 2026

**Alcance:** todo lo producido en Fase 1 + Fase 2 (8 scripts, 6 archivos XML/conf, 6 docs).
**Postura:** revisor externo escéptico, no el mismo autor validando su propio trabajo.
**Resultado:** 9 hallazgos reales, 2 de severidad alta. Cero secretos expuestos. Fixes
aplicados directamente sobre los archivos existentes, con tu aprobación.

---

## Metodología

Releí los 8 scripts y 6 XML/conf completos, línea por línea, simulando modos de fallo (qué
pasa si un comando falla a la mitad, si se corre dos veces, si el operador se equivoca).
Corrí `grep` contra todo el repo y el historial completo de `git log --all -p` buscando
patrones de credenciales/secretos. Revisé permisos de archivo en disco. Reconsideré cada
suposición técnica que no había verificado contra una instalación Wazuh real.

## Hallazgos y fixes aplicados

| # | Severidad | Hallazgo | Fix aplicado |
|---|---|---|---|
| A | 🔴 Alta | `05-instalar-agente.sh` solo PREGUNTABA si el snapshot existía (un "si" tecleado bastaba) — no había verificación real | El paso de snapshot en el host ahora deja una marca de archivo dentro del LXC; el script la verifica y se niega a instalar sin ella |
| B | 🟡 Media | `03-crear-lxc.sh` puede fallar entre `pct create` y `pct start`, dejando un CTID bloqueado sin snapshot ni camino de recuperación documentado | Comando de recuperación (`pct destroy 103 --purge`) documentado en el checklist |
| C | 🔴 Alta | `04-instalar-wazuh.sh` no tenía guarda contra correrse dos veces (sí la tenían los demás scripts de instalación) | Guarda `dpkg -s wazuh-manager` agregada, igual que en los demás |
| D | 🟡 Media | El ajuste de heap del indexador (`sed`) podía fallar en silencio si el formato del archivo cambiaba, dejando el heap por defecto sin avisar | Verificación explícita con `grep` de que el cambio se aplicó, falla ruidosamente si no |
| E | 🟡 Media | El respaldo en `02-desplegar-config-manager.sh` (Fase 2) usaba `\|\| true`, escondiendo cualquier error real del backup, no solo "archivo no existe" | Distingue explícitamente "no existe todavía" (aceptable) de "existe pero no se pudo copiar" (aborta) |
| F | 🟡 Media | Los `agent.conf` de grupo (Fase 2) nunca se validaban como XML antes de desplegarse, a diferencia de `local_decoder.xml`/`local_rules.xml` | Validación `xmllint` agregada por cada `agent.conf` antes de copiarlo |
| G | 🔴 **La más seria** | `/etc/pve` es un filesystem FUSE (pmxcfs), no uno normal — `realtime="yes"` de Wazuh depende de `inotify`, que tiene problemas de compatibilidad conocidos con FUSE. No lo había considerado ni verificado; la fuente de datos de FIM sobre Proxmox podría no funcionar nunca, en silencio | Advertencia extensa en `manager/shared/proxmox-host/agent.conf` con plan B documentado (`whodata` o barrido programado más frecuente); la prueba de fuego de esta fuente en el checklist quedó marcada como la más importante de la fase |
| H | 🟡 Media | El decoder custom para `docker-listener` (`<decoded_as>json</decoded_as>`) asume que no hay decoder stock, pero al ser un módulo first-party de Wazuh es probable que sí lo tenga — no lo verifiqué | Paso explícito en el checklist B4 para buscar un decoder stock antes de confiar en el custom |
| I | 🟡 Media | La tabla de sizing del README presentaba el desglose de RAM por componente (manager, dashboard, filebeat) como si fuera dato documentado; en realidad es estimación mía, no citada | Nota explícita en el README distinguiendo lo sourceado (heap del indexador, total) de lo estimado (desglose por componente) |
| J | 🟡 Media | `03-asignar-grupos.sh` asumía el formato de salida de `agent_control -l`/`agent_groups -s -i` sin la misma advertencia que sí tenían NPM y Docker | Nota honesta agregada, mismo estándar que el resto del repo |

## Verificaciones que salieron limpias (no todo era un problema)

- **Cero credenciales, tokens o secretos hardcodeados** en ningún script, config, ni en el
  historial completo de `git log --all -p`.
- Las contraseñas se piden interactivamente con `read -s` (no quedan en el historial de bash
  ni se escriben a archivo).
- Las regex de los decoders no tienen cuantificadores anidados — sin riesgo de ReDoS.
- **No hay ninguna regla conectada a active-response todavía** — no existe hoy una ruta de
  "log malicioso → ejecución de comando". Ese riesgo aparecerá el día que se agregue
  respuesta automática (Fase 4+), momento en el que cualquier campo pasado a un comando de
  shell deberá sanearse explícitamente.
- Los permisos de archivo en disco (664/775 en vez de 644/755) son un artefacto del umask de
  mi shell local, no algo fijado por Claude — y git no rastrea ese bit, así que no se
  propaga a quien clone el repo. Bajo riesgo, no ameritó cambio de contenido.

## Riesgo documentado, no corregido con código (por elección, ya aprobado)

El Manager de Wazuh centralizado es ahora un punto de control root-equivalente sobre los 4
sistemas (los 3 LXCs + el host Proxmox). No cambia la arquitectura ya aprobada, pero se
documentó explícitamente en el README como riesgo aceptado, con la consecuencia concreta de
que el Manager (no NPM) será la prioridad cuando llegue la fase de SSL local.

## Archivos modificados en esta auditoría

`scripts/05-instalar-agente.sh`, `scripts/04-instalar-wazuh.sh`,
`scripts/fase2/02-desplegar-config-manager.sh`, `scripts/fase2/03-asignar-grupos.sh`,
`manager/shared/proxmox-host/agent.conf`, `docs/fase1-checkpoints.md`,
`docs/fase2-checkpoints.md`, `README.md`. Todos revalidados con `bash -n` / `xmllint` tras
los cambios.

## Lo que sigue

Con esta auditoría cerrada, el trabajo de Fase 1 + Fase 2 queda en el estado más honesto y
verificado posible sin acceso en vivo al Proxmox. Los puntos que dependen de una instalación
real (G, H, y los ya marcados de NPM) están señalizados con fuerza en los checklists — no se
pueden cerrar del todo hasta que se ejecuten de verdad.

---

*Sesión conducida con Claude Code, actuando como revisor externo escéptico del propio
trabajo previo, a petición explícita de Yamil. Decisiones de qué corregir: Yamil.*
