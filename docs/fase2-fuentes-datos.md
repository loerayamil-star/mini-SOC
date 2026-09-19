# Fase 2 — Fuentes de datos: decisiones y por qué de cada una

Sigue a la Fase 1 (Manager + 3 agentes ya funcionando y verificados). Esta fase define QUÉ
logs manda cada servicio más allá de lo que el agente estándar de Wazuh manda por defecto.
Sigue en modo preparación: cero conexión al Proxmox real hasta que la Fase 1 esté ejecutada.

## Alcance: 4 fuentes, no 3

`contexto_minisoc.md` (Fase 2) define 4 fuentes: Pi-hole, NPM, Proxmox host y Homepage/Docker.
La Fase 1 solo agentó los 3 LXCs — el Proxmox host mismo se quedó sin agente. Para cubrir SSH
del host y cambios de configuración en `/etc/pve`, no hay forma de evitarlo: **se necesita un
4to agente, instalado directamente en el host físico**. Es un cambio de alcance real sobre lo
que ejecutó la Fase 1, así que lo traté como su propio checkpoint de aprobación en el checklist
de esta fase, no lo mezclé con los otros 3 agentes que ya existen.

Footprint de ese agente extra: ~35MB de RAM (el mismo footprint que ya se documentó en la Fase
1 para los agentes de LXC) — insignificante contra el margen de ~6GB libres que queda con 16GB
totales y el LXC de Wazuh corriendo.

## 1. Pi-hole (LXC 100)

**Log:** `/var/log/pihole/pihole.log`. Verifiqué que en Pi-hole v6 este archivo sigue
existiendo y sigue en formato estilo-syslog de dnsmasq — no lo reemplazó la base de datos FTL
para este propósito:

```
Sep 16 14:32:10 dnsmasq[123]: query[A] doubleclick.net from 192.168.1.50
Sep 16 14:32:10 dnsmasq[123]: gravity blocked doubleclick.net is 0.0.0.0
```

**Decoder:** propio (`pihole-dnsmasq` → `pihole-query` / `pihole-blocked` en
`manager/decoders/local_decoder.xml`). No encontré un decoder oficial de Pi-hole mergeado en
el ruleset stock de Wazuh 4.14 al momento de escribir esto.

**Limitación honesta que documento, no escondo:** la línea `gravity blocked` de dnsmasq **no
repite la IP del cliente** que hizo la consulta — esa IP solo aparece en la línea `query`
anterior, correlacionada por PID del proceso, no por el mismo evento. Atribuir "qué dispositivo
específico" disparó cada bloqueo requeriría correlación entre dos líneas (fuera del alcance de
un decoder simple). Por eso la regla de detección de picos de bloqueo (Fase 3, la escribes tú)
parte de volumen total de bloqueos en la red en una ventana de tiempo, no por cliente individual
— lo documento como una mejora futura posible, no como algo que ya funciona.

**Config del agente:** `manager/shared/pihole/agent.conf` — un `<localfile>` en formato
`syslog` apuntando a ese log.

## 2. Nginx Proxy Manager (LXC 101, Docker)

Confirmaste que NPM corre en Docker (imagen oficial `jc21/nginx-proxy-manager`) dentro del LXC
101. Sus logs de acceso por proxy-host viven en `/data/logs/proxy-host-<id>_access.log`
**dentro del contenedor**, en un volumen — para que el agente Wazuh (que corre en el LXC, no
dentro del contenedor) pueda leerlos, ese volumen necesita estar mapeado a una ruta real del
sistema de archivos del LXC (bind mount), no solo un volumen interno de Docker.

**Formato:** NPM usa un formato propio, no el "combined" de Apache:

```
[16/Sep/2026:14:32:10 +0000] - 200 200 - GET dash.home "/admin/" [Client 192.168.1.50] [Length 5321] [Gzip -] [Sent-to 192.168.0.55:3000] "Mozilla/5.0" "-"
```

**Advertencia explícita:** armé el decoder contra este formato basado en documentación pública
(no en un log real tuyo) — las versiones de NPM han cambiado este formato antes. El checklist
de esta fase incluye confirmar el formato real contra una línea de tu log de NPM antes de
confiar en el decoder en producción.

**Config del agente:** `manager/shared/npm/agent.conf` con la ruta del bind mount — la ruta
exacta (`/opt/npm/data/logs/...` es un placeholder) hay que confirmarla contra cómo desplegaste
el contenedor de NPM el día de la ejecución.

## 3. Proxmox host (nuevo agente)

- **SSH:** no requiere config custom. El host es Debian — en cuanto se instale el agente ahí,
  hereda automáticamente el ruleset stock de SSH/sudo/PAM de Wazuh (incluye la regla 5763 de
  fuerza bruta SSH, ya lista de fábrica). Cero trabajo adicional de decoders para esto.
- **Cambios de configuración:** uso File Integrity Monitoring (FIM, módulo `syscheck` de
  Wazuh) sobre `/etc/pve` con `realtime="yes"` — no es un log tradicional, es Wazuh vigilando
  el filesystem cluster de Proxmox directamente y generando su propio evento ante cualquier
  cambio. Es más confiable que intentar parsear logs de Proxmox para esto, porque Proxmox no
  tiene un log dedicado de "quién cambió qué" fuera de lo que FIM puede capturar directamente.

**Config del agente:** `manager/shared/proxmox-host/agent.conf` con el bloque `<syscheck>`.

## 4. Homepage/Docker (LXC 102)

Uso el módulo oficial `docker-listener` (wodle) de Wazuh — se conecta al socket de Docker del
LXC 102 y reporta eventos de ciclo de vida de contenedores (start, stop, pause, restart)
directamente, sin necesidad de parsear logs de texto.

**Config del agente:** `manager/shared/homepage/agent.conf` con el wodle activado.

**Nota honesta:** no verifiqué en vivo el nombre exacto de los campos JSON que produce este
wodle en la versión instalada — las reglas de `local_rules.xml` para esta fuente están
marcadas explícitamente como "a confirmar contra un evento real" en el checklist, en vez de
presentarlas como garantizadas.

## Convenciones que seguí

- **Todo el contenido custom va en los dos archivos canónicos del Manager**
  (`local_decoder.xml`, `local_rules.xml`) — es como Wazuh espera que se organice contenido
  propio, en vez de inventar archivos sueltos adicionales.
- **IDs de reglas custom arrancan en 100000** (convención oficial de Wazuh, evita chocar con
  el ruleset stock que se actualiza con cada versión).
- **Configuración por grupos, no por agente:** en vez de tocar el `ossec.conf` de cada LXC/host
  uno por uno, uso los grupos de Wazuh (`pihole`, `npm`, `homepage`, `proxmox-host`) con su
  `agent.conf` compartido en el Manager. Es el mecanismo oficial de "configuración
  centralizada" de Wazuh, y es el patrón que reutilizaré si agrego más LXCs al cluster más
  adelante (la Micro PC pendiente de comprar).

## Qué NO hace esta fase

No hay reglas de detección "reales" con umbrales calibrados todavía — eso es la Fase 3, y la
escribo yo, no Claude (división de trabajo, sección 4 de `contexto_minisoc.md`). Lo que hay
aquí en `local_rules.xml` son las reglas *base* de categorización (identificar qué tipo de
evento es cada línea) más un par de reglas de ejemplo con umbrales de punto de partida,
explícitamente marcadas como material de referencia para que Yo las calibre con datos reales
de mi red, no como el trabajo final de detección.
