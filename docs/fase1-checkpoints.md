# Fase 1 — Guía de ejecución manual con checkpoints

Sigue este documento en orden el día de la ejecución. Cada checkpoint es una compuerta:
**si algo no pasa, DETENTE ahí** — no sigas al siguiente script "a ver si funciona".

Requisito previo global: **el módulo de RAM de 8GB ya instalado** (16GB totales en el OptiPlex).
El script 01 lo verifica y aborta si no.

---

## Paso 0 — Acceso al host

Desde la laptop, entra por SSH al Proxmox:

```bash
ssh root@192.168.0.232
```

Copia la carpeta `scripts/` al host (desde la laptop):

```bash
scp -r scripts/ root@192.168.0.232:/root/fase1-scripts/
```

---

## Checkpoint A1 — Recon de solo lectura

En el host:

```bash
bash /root/fase1-scripts/01-precheck-host.sh
```

El script no cambia nada. Revisa su salida contra esta lista — **todas deben cumplirse**:

- [ ] RAM total ≈ 16GB (si muestra ~8GB, el módulo no está instalado o no fue detectado → STOP)
- [ ] CTID 103 libre (no aparece en `pct list`)
- [ ] Almacenamiento local con ≥ 40GB libres (30 del LXC + margen)
- [ ] Plantilla `debian-12-standard` disponible o descargable (el script te dice cuál)
- [ ] Anotado el estado de `onboot` de los LXCs 100, 101 y 102 (pendiente viejo del homelab:
      si alguno está en `onboot: 0` o sin definir, actívalo:
      `pct set <ID> --onboot 1` — decisión tuya, el script solo lo reporta)

**Pasa A1 → continúa. No pasa → detente y resuelve primero.**

---

## Checkpoint A2 — Único cambio al host físico

Esto modifica un parámetro de kernel del Proxmox (lo exige el indexador de Wazuh y los LXCs
no pueden fijarlo por sí mismos). Es inocuo para los demás LXCs — solo sube un límite de
mapeos de memoria por proceso.

```bash
bash /root/fase1-scripts/02-prep-host.sh
```

- [ ] Al final, `sysctl vm.max_map_count` muestra `262144`

---

## Crear el LXC 103

```bash
bash /root/fase1-scripts/03-crear-lxc.sh
```

El script pide confirmación antes de crear. Al terminar:

- [ ] `pct list` muestra el 103 corriendo con hostname `wazuh`
- [ ] `pct exec 103 -- ping -c2 192.168.0.53` responde (red y DNS del contenedor OK)
- [ ] Existe el snapshot: `pct listsnapshot 103` muestra `pre-wazuh-install`

**Paso manual — DNS local:** en la UI de Pi-hole (`http://pihole.home/admin` →
Settings → Local DNS Records) registra:

- [ ] `wazuh.home` → `192.168.0.56`

---

## Instalar Wazuh (dentro del LXC 103)

```bash
pct enter 103
bash /root/fase1-scripts/04-instalar-wazuh.sh   # cópialo dentro antes, o usa: pct push
```

(Para copiarlo dentro: `pct push 103 /root/fase1-scripts/04-instalar-wazuh.sh /root/04-instalar-wazuh.sh`)

- [ ] **GUARDA LAS CREDENCIALES**: el instalador imprime usuario/contraseña `admin` UNA sola vez
      al final. Guárdalas en tu gestor de contraseñas ANTES de cerrar la terminal.
      (Respaldo: quedan cifradas en `wazuh-install-files.tar` en el directorio donde corriste
      el instalador — no lo borres hasta confirmar que guardaste todo.)
- [ ] Los 4 servicios activos: `systemctl status wazuh-indexer wazuh-manager filebeat wazuh-dashboard`
- [ ] Dashboard carga: `https://wazuh.home` (o `https://192.168.0.56`) desde la laptop —
      acepta el certificado autofirmado, login con las credenciales guardadas
- [ ] Prueba de fuego: reinicia el LXC (`pct reboot 103` desde el host) y verifica que los
      4 servicios levantan solos y el dashboard vuelve a cargar (tarda 2–4 min en HDD)

**Si el instalador falla por checks de hardware** (común en LXC: no detecta bien los límites
del contenedor): reintenta con `bash wazuh-install.sh -a -i`. El `-i` ignora los checks — es
seguro aquí porque el sizing ya se validó a mano en A1.

**Si el indexador no arranca en contenedor no privilegiado** (errores de systemd/permisos en
sus logs): NO improvises. El fallback es recrear el 103 como privilegiado, pero eso cambia el
perfil de seguridad del contenedor — trae la decisión de vuelta a una sesión con Claude o
documenta tú el tradeoff antes de hacerlo.

---

## Checkpoint A3 — Antes del primer agente

Solo cruza esta línea si TODO lo anterior está en verde. A partir de aquí se tocan los LXCs
que ya funcionan.

Regla por cada LXC, sin excepción: **snapshot ANTES de instalar**.

### Agente 1 — Homepage (LXC 102, el menos crítico)

```bash
# En el host:
pct snapshot 102 pre-wazuh-agent
pct push 102 /root/fase1-scripts/05-instalar-agente.sh /root/05-instalar-agente.sh
pct enter 102
bash /root/05-instalar-agente.sh homepage
```

- [ ] Agente aparece **Active** en el dashboard de Wazuh (Agents management → Summary)
- [ ] Homepage sigue funcionando: `http://dash.home` carga CON todos sus widgets
      (Proxmox, Pi-hole — si un widget falla, algo se rompió)
- [ ] Docker sigue sano dentro del 102: `docker ps` muestra los contenedores de siempre

### Agente 2 — NPM (LXC 101)

```bash
pct snapshot 101 pre-wazuh-agent
pct push 101 /root/fase1-scripts/05-instalar-agente.sh /root/05-instalar-agente.sh
pct enter 101
bash /root/05-instalar-agente.sh npm
```

- [ ] Agente **Active** en el dashboard
- [ ] NPM sigue proxyando: `http://dash.home` y `http://pihole.home/admin` cargan desde la laptop
- [ ] La UI de NPM (`http://192.168.0.54:81`) responde

### Checkpoint A4 — Antes de Pi-hole (LXC 100)

**Este es el DNS de toda la red.** Antes de tocarlo:

- [ ] Los otros 2 agentes llevan un rato estables (sugerencia: espera al menos unos minutos
      y confirma que siguen *Active* y sus servicios sanos)
- [ ] Sabes que el rollback (restaurar snapshot) implica ~1 minuto sin DNS en toda la casa
- [ ] Tienes a la mano el DNS de respaldo por si acaso: el router ya entrega 1.1.1.1 como
      secundario, así que la red sobrevive una caída corta de Pi-hole

### Agente 3 — Pi-hole (LXC 100)

```bash
pct snapshot 100 pre-wazuh-agent
pct push 100 /root/fase1-scripts/05-instalar-agente.sh /root/05-instalar-agente.sh
pct enter 100
bash /root/05-instalar-agente.sh pihole
```

- [ ] Agente **Active** en el dashboard
- [ ] Pi-hole sigue resolviendo: desde la laptop, `dig @192.168.0.53 google.com` responde
- [ ] Pi-hole sigue bloqueando: `dig @192.168.0.53 doubleclick.net` devuelve `0.0.0.0`
- [ ] La UI (`http://pihole.home/admin`) carga y muestra estadísticas moviéndose

---

## Rollback (si un servicio se degrada tras instalar su agente)

```bash
# En el host — <ID> = 100, 101 o 102:
pct stop <ID>
pct rollback <ID> pre-wazuh-agent
pct start <ID>
```

En Pi-hole esto significa ~1 min sin DNS en la red. Después del rollback, NO reintentes a
ciegas: anota el síntoma exacto (logs en `/var/ossec/logs/ossec.log` dentro del LXC, y el
estado del servicio afectado) y tráelo a una sesión de diagnóstico.

---

## Verificación end-to-end de la fase (entregable)

- [ ] `https://wazuh.home` carga y el login funciona
- [ ] Los 4 servicios de Wazuh activos tras un reinicio completo del LXC 103
- [ ] Dashboard muestra **3 agentes Active**: homepage, npm, pihole
- [ ] Pi-hole resuelve y bloquea; NPM proxea; Homepage carga con widgets
- [ ] `free -h` en el host muestra ≥ 2GB disponibles con todo corriendo
- [ ] Snapshots de rollback presentes en los 4 LXCs (`pct listsnapshot <ID>`)

## Limpieza posterior (días después, con todo estable)

- [ ] 2–3 días después, borra los snapshots `pre-wazuh-*` (mismo criterio que el
      mantenimiento mensual): `pct delsnapshot <ID> <nombre>`
- [ ] Anota la fecha de despliegue para incorporar el 103 al ciclo mensual de mantenimiento
