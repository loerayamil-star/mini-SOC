# Mini-SOC — Fase 1: Wazuh Manager + agentes

Este proyecto lo hice como tercer pilar de mi portafolio técnico (SOC-DFIR). En esta fase
despliego **Wazuh 4.14.x** (single-node, all-in-one) en un LXC nuevo de mi Proxmox casero y
conecto mis 3 LXCs existentes (Pi-hole, NPM, Homepage) como agentes. Mi objetivo no es tener
un SOC como caja negra: es poder explicar cada decisión de diseño — por qué Wazuh, por qué
este sizing, por qué este orden de despliegue.

> **Estado:** scripts preparados, ejecución PENDIENTE de instalar el módulo de RAM de 8GB
> (decisión que tomé el 16-sep-2026: no ejecutar con los 8GB actuales — el sizing asume 16GB).

## Quick Start (el día de la ejecución)

```bash
# 0. Desde mi laptop: copiar los scripts al host Proxmox
scp -r scripts/ root@192.168.0.232:/root/fase1-scripts/
ssh root@192.168.0.232

# 1. Precheck de solo lectura (aborta si la RAM nueva no está instalada)
bash /root/fase1-scripts/01-precheck-host.sh

# 2. Único cambio al host: parámetro de kernel que exige el indexador
bash /root/fase1-scripts/02-prep-host.sh

# 3. Crear el LXC 103 (pide confirmación antes de crear)
bash /root/fase1-scripts/03-crear-lxc.sh

# 4. Instalar Wazuh dentro del LXC
pct push 103 /root/fase1-scripts/04-instalar-wazuh.sh /root/04-instalar-wazuh.sh
pct enter 103 && bash /root/04-instalar-wazuh.sh

# 5. Agentes, en este orden y con snapshot antes de cada uno (ver checkpoints):
#    Homepage (102) -> NPM (101) -> Pi-hole (100)
```

Entre cada paso hay verificaciones que sigo a mano: la guía completa está en
[docs/fase1-checkpoints.md](docs/fase1-checkpoints.md) — **el Quick Start no la sustituye**,
los checkpoints A1–A4 son compuertas de "pasa / no pasa".

## Prerrequisitos

- **El módulo de RAM de 8GB DDR3 FÍSICAMENTE instalado** en el OptiPlex (16GB totales) — no
  solo comprado. El script 01 lo verifica y aborta si detecta menos de ~12GB; esa fue mi
  decisión explícita para no ejecutar al límite de recursos.
- **Acceso SSH como root al host Proxmox** (`root@192.168.0.232`). Con contraseña basta;
  una llave `ed25519` con `ssh-copy-id` es más cómodo.
- **Proxmox VE 9.x** (los scripts usan `pct`/`pveam`/`pvesm` con la sintaxis actual; en mi
  host corre 9.2.2).
- Salida a internet desde el host y los LXCs (descarga de la plantilla Debian 12 y de los
  paquetes de Wazuh).

## Nota de transparencia — construcción asistida por IA

Los scripts de despliegue de este repo fueron generados con asistencia de Claude Code, bajo
decisiones de arquitectura, sizing y división de trabajo que definí yo explícitamente (qué
automatizar, contra qué límite de recursos dimensionar, en qué orden tocar mi infraestructura
y con qué checkpoints). Las reglas de detección de la Fase 3 en adelante las escribo yo
directamente, no Claude — ese es el aprendizaje que no delego.

## Orden de ejecución

Sigo [docs/fase1-checkpoints.md](docs/fase1-checkpoints.md) paso a paso — ahí están los
checkpoints de verificación (A1–A4) entre cada script. Resumen del orden:

| # | Script | Dónde se corre | Qué hace |
|---|---|---|---|
| 1 | `scripts/01-precheck-host.sh` | Host Proxmox (SSH a 192.168.0.232) | Solo lectura: verifica RAM≈16GB, CTID 103 libre, disco, plantilla Debian 12 |
| 2 | `scripts/02-prep-host.sh` | Host Proxmox | Único cambio al host: `vm.max_map_count=262144` (lo exige el indexador; un LXC no puede fijarlo) |
| 3 | `scripts/03-crear-lxc.sh` | Host Proxmox | Crea el LXC 103 con el sizing de abajo + snapshot `pre-wazuh-install` |
| 4 | `scripts/04-instalar-wazuh.sh` | Dentro del LXC 103 | Instalador oficial all-in-one + ajuste de heap a 2GB + verificación de servicios |
| 5 | `scripts/05-instalar-agente.sh` | Dentro de cada LXC existente | Agente Wazuh apuntando al Manager. Orden: **Homepage (102) → NPM (101) → Pi-hole (100)** |

El orden de los agentes lo elegí a propósito: del menos crítico al más crítico para mi red.
Pi-hole va al final porque es el DNS de TODA mi casa — si algo sale mal ahí, se cae la
resolución de nombres de todos los dispositivos.

## Sizing del LXC 103 — por qué elegí cada número

| Recurso | Valor | Justificación |
|---|---|---|
| RAM | 6144 MB (+512 swap) | El all-in-one en régimen estable usa ~4–4.5GB con heap ajustado: indexador (OpenSearch, heap fijado a 2GB), manager (~0.5–1GB), dashboard (Node.js, ~0.5–1GB), filebeat (~0.2GB). 6GB da margen de picos y deja ~6GB libres en el host de 16GB. |
| vCPU | 2 | Con 3 agentes el volumen de eventos es mínimo. En LXC es un tope, no una reserva — quedan 2 núcleos del i5-4570 para el host y los otros LXCs. |
| Disco | 30 GB | Con 3 agentes de homelab, el indexador acumula MBs/día, no GBs. Alcanza para meses; la retención fina se ajusta en Fase 2. |
| Tipo | No privilegiado + `nesting=1` | Mínimo privilegio. `nesting` es necesario para systemd en contenedores no privilegiados. |
| IP | 192.168.0.56 estática | Siguiente en la secuencia (.53 Pi-hole, .54 NPM, .55 Homepage). Se registra `wazuh.home` en Pi-hole. |
| Arranque | `onboot=1` | El SOC debe levantarse solo tras un corte de luz. |

**Contexto oficial:** Wazuh recomienda 8GB/8vCPU para 50–100 agentes y documenta 4GB/2vCPU
como mínimo para 1–25. Yo tengo **3 agentes** — mi sizing está entre el mínimo y el
recomendado, ajustado a la realidad de mi host, no copiado de la documentación empresarial.

## Decisiones de diseño que ya tomé (y no reabro sin repensarlas en serio)

Estas decisiones las documenté con detalle completo en mis notas privadas de arquitectura
(`contexto_minisoc.md` y `contexto_homelab.md`, que no forman parte de este repo porque
contienen detalle interno de mi infraestructura). Lo esencial para entender este repo:

- **Wazuh, no Azure Sentinel** — Sentinel cobra por GB ingerido y podría agotar mi crédito de
  Azure for Students sin que me diera cuenta; además, correr Wazuh en mi propia
  infraestructura me obliga a entender cada pieza (agentes, reglas, indexador, dashboard) en
  vez de consumir un servicio ya armado. Eso vale más en mi portafolio.
- **All-in-one, no arquitectura distribuida** — single-node soporta ~100 endpoints (tengo 3),
  y el asistente oficial genera los certificados TLS entre indexador/servidor/dashboard
  automáticamente, que es la parte más propensa a error si se hace a mano.
- **Dashboard de Wazuh FUERA de mi reverse proxy (NPM)** — accedo directo por
  `https://wazuh.home`. Es la misma lógica con la que mantengo Proxmox desacoplado del
  reverse proxy: trae su propio SSL y autenticación. Meterlo tras NPM lo evaluaré en mi fase
  de SSL local, no ahora.

## Riesgos que conozco y acepto

1. **HDD, no SSD:** el indexador es intensivo en I/O; instalación y búsquedas en el dashboard
   serán lentas. Aceptable para mi homelab.
2. **Sin UPS todavía:** un corte de luz durante escritura del indexador puede corromper
   índices. Mitigación parcial: snapshots. Desaparece cuando configure NUT con el UPS que ya
   elegí.
3. **AIO en LXC no privilegiado:** puede haber fricción (systemd/límites). El instalador
   puede requerir `-i` (ignorar checks de hardware, no detecta bien los límites del
   contenedor). Fallback documentado en los checkpoints: recrear como privilegiado — decisión
   aparte, cambia el perfil de seguridad.
4. **Credenciales del instalador:** se imprimen UNA vez al final de `wazuh-install.sh`. Las
   guardo de inmediato (el script 04 me lo recuerda). Nunca se commitean a este repo.

## Mantenimiento

El LXC 103 entra al ciclo mensual que ya tengo definido para todo mi homelab: snapshot
`pre-update-mes-año` antes de cada actualización, `apt dist-upgrade` nunca `apt upgrade` en el
host Proxmox, y limpieza de snapshots 2–3 días después de confirmar estabilidad.

## Fases siguientes

Fase 2 (fuentes de datos y decoders por servicio) y Fase 3 (reglas de detección XML — esas
las escribo yo, no Claude: es el corazón del aprendizaje) arrancan solo cuando el entregable
de esta fase esté verificado: Manager funcionando, dashboard accesible, 3 agentes *Active*.

## Licencia

[MIT](LICENSE).
