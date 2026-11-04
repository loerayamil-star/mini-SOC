# Reporte de sesión — 16 de septiembre de 2026

**Proyecto:** Mini-SOC (tercer pilar del portafolio: SOC-DFIR)
**Fase:** 1 — Infraestructura base (Wazuh Manager + agentes)
**Alcance de la sesión:** planeación y preparación de scripts. **No se tocó infraestructura real.**

---

## Diagnóstico

- **Versión objetivo:** Wazuh 4.14.x, verificada contra la documentación oficial en la sesión
  (no de memoria). El requisito "recomendado" oficial del all-in-one (8GB RAM / 8 vCPU) aplica
  a despliegues de 50–100 agentes; el mínimo documentado es 4GB / 2 vCPU para 1–25. Este
  despliegue tendrá **3 agentes**, así que el sizing se calculó entre ambos valores contra la
  RAM real del host, no copiado de la documentación empresarial.
- **Restricción de recursos evaluada:** el host (Dell OptiPlex 9020, i5-4570) tiene hoy 8GB de
  RAM, compartidos entre Proxmox (~1–1.5GB) y 3 LXCs existentes (~2GB asignados). Margen real
  para Wazuh con 8GB: ~4–4.5GB — viable pero al límite (host a ~90% de RAM comprometida).
- **Estado del entorno de trabajo:** el repo del proyecto estaba vacío; la laptop no tiene
  llaves SSH configuradas hacia el Proxmox (queda como paso 0 del día de ejecución).

## Decisiones tomadas (con su porqué)

1. **Ejecutar solo después de instalar el módulo de RAM de 8GB** ($100 MXN, ya decidido
   previamente). Elimina el riesgo principal de la fase por un costo mínimo. Todo el sizing
   asume 16GB; el script de precheck aborta si detecta menos de ~12GB, así que no se puede
   ejecutar por accidente con la RAM vieja. Queda documentado un sizing de contingencia
   (4GB + heap 1GB) por si la decisión cambiara, con sus tradeoffs.
2. **Sizing del LXC 103:** 6144MB RAM + 512MB swap, 2 vCPU (tope, no reserva), 30GB disco,
   Debian 12 no privilegiado con `nesting=1`, IP estática <IP_WAZUH>, `onboot=1`, heap del
   indexador fijado a 2GB post-instalación (el default de OpenSearch tomaría ~3GB, el 50% de
   la RAM del contenedor — excesivo para 3 agentes). Justificación completa en el README.
3. **Instalador all-in-one oficial (`wazuh-install.sh -a`), no arquitectura distribuida:**
   single-node soporta ~100 endpoints y el asistente genera los certificados TLS entre
   indexador/servidor/dashboard — la parte más propensa a error si se hace a mano.
4. **Dashboard de Wazuh fuera de NPM:** acceso directo por `https://wazuh.home`, siguiendo la
   misma lógica del desacople de Proxmox del reverse proxy (SSL y autenticación propios).
   Se reevalúa en la Fase 3 de SSL del homelab.
5. **Orden de instalación de agentes: Homepage → NPM → Pi-hole.** Del menos al más crítico:
   Pi-hole es el DNS de toda la red y va al final, con checkpoint de aprobación propio (A4)
   y consciencia de que su rollback implica ~1 minuto sin DNS en la casa.
6. **Cambio de alcance a mitad de sesión (decisión de Yamil):** de ejecución en vivo vía SSH a
   preparación de scripts para ejecución manual futura, con aprobación archivo por archivo.
7. **Requisito a nivel host identificado:** `vm.max_map_count=262144` debe fijarse en el host
   Proxmox (los LXC heredan el kernel y no pueden cambiarlo). Es el único cambio al host
   físico de toda la fase y tiene su propio checkpoint (A2).

## Ejecución (lo producido)

| Archivo | Contenido |
|---|---|
| `README.md` | Sizing justificado, decisiones de diseño, riesgos aceptados, orden de ejecución |
| `docs/fase1-checkpoints.md` | Guía manual completa: checkpoints A1–A4, pasos no-script (DNS local, credenciales, snapshots), verificaciones funcionales por servicio, rollback, verificación end-to-end |
| `scripts/01-precheck-host.sh` | Recon de solo lectura del host; aborta si RAM < 12GB; reporta CTID libre, disco, plantilla, `onboot` de los LXCs existentes |
| `scripts/02-prep-host.sh` | Sysctl `vm.max_map_count` persistente (idempotente, con confirmación) |
| `scripts/03-crear-lxc.sh` | Creación del LXC 103 con el sizing acordado + snapshot `pre-wazuh-install` |
| `scripts/04-instalar-wazuh.sh` | All-in-one dentro del 103 + ajuste de heap a 2GB + verificación de los 4 servicios |
| `scripts/05-instalar-agente.sh` | Agente genérico parametrizado por nombre, con guardas de contexto, confirmación de snapshot previo, verificación de conexión y desactivación del repo apt al final (actualizaciones de agente solo deliberadas, junto con el Manager) |

Características transversales de los scripts: `set -euo pipefail`, guardas que verifican dónde
corren (host vs contenedor, hostname correcto), pausas de confirmación antes de acciones
irreversibles, y verificación con criterio pasa/no-pasa al final de cada uno.

**Verificación de la sesión:** los 5 scripts pasan `bash -n` (sintaxis válida) y quedaron
ejecutables. No hay más verificación posible sin infraestructura — la validación real ocurre
el día de la ejecución, guiada por los checkpoints.

## Resultado

- Fase 1 empaquetada y lista para ejecución manual, sin dependencia de tener Claude Code
  corriendo ese día.
- Infraestructura real intacta: cero conexiones al Proxmox durante la sesión.
- **Bloqueante único para ejecutar:** comprar e instalar el módulo de RAM de 8GB.
- Pendientes del día de ejecución: copiar `scripts/` al host por `scp`, y seguir
  `docs/fase1-checkpoints.md` de principio a fin.
- Fuera de alcance de esta sesión (decisión de Yamil): `git init` y primer commit — los hará
  manualmente.

## Conexión educativa (SC-900)

La fase ejercita el Modelo de Responsabilidad Compartida en su extremo on-premises: sin
proveedor cloud, el operador es responsable del 100% del stack — desde el parámetro de kernel
del hipervisor hasta las credenciales del dashboard. Los checkpoints A1–A4 son una aplicación
práctica de "verificar explícitamente" (Zero Trust) al proceso de despliegue mismo.

---

*Sesión conducida con Claude Code (planeación y generación de scripts; decisiones de
arquitectura y aprobaciones: Yamil).*
