# CRISDEV-UDP v3.0 — servidor Hysteria v1 con menú

Instalador y menú para el servidor UDP (QUIC) de la app **CRISDEV Tunnel**. Autenticación por **HWID y contraseña a la vez**.

## Instalar

```bash
bash install_udp.sh      # pregunta lo necesario, instala y abre el menú
crisudp                  # después, desde cualquier carpeta
```

Guarda el script como archivo (no lo ejecutes con `bash <(wget ...)`), así se instala el comando `crisudp`.
Si quieres otro nombre para el comando, cambia `CMD_NAME` al inicio del script **antes** de instalar.

## Menú

| # | Opción | Qué hace |
|---|---|---|
| 1 | Instalar / reinstalar | Pregunta IP, puertos, OBFS, modo de autenticación y contraseña |
| 2 | Ver datos para la app | Lo que debe poner el cliente |
| **3** | **Crear OBFS + HWID + contraseña** | **Todo en uno:** OBFS nuevo, contraseña nueva y modo "las dos a la vez" |
| 4 | Cambiar OBFS | Propone uno aleatorio (Enter) o escribes el tuyo |
| 5 | Autenticación | HWID + contraseña / solo HWID / solo contraseña |
| 6 | Cambiar contraseña | |
| 7 | Administrar HWID | Nuevo, renovar, eliminar, listar, borrar vencidos |
| 8 | Puerto / rango / puertos QoS | |
| 9–11 | Reiniciar, detener, logs | |
| 12 | Diagnóstico completo | Servicio, puerto, config, certificado, firewall, kernel, logs |
| 13 | Desinstalar | Servicio, config, HWID, certificados **y reglas de firewall** |

Los cambios de **modo, contraseña y HWID se aplican al instante**, sin reiniciar (el servidor lee esos datos en cada conexión). Cambiar OBFS o puertos sí reinicia el servicio.

## Cómo conecta la app

| Modo | En la app |
|---|---|
| HWID + contraseña (por defecto) | Con la contraseña escrita entra por contraseña; con la contraseña **vacía** entra por su HWID (debe estar en la lista y no vencido) |
| Solo HWID | Contraseña vacía |
| Solo contraseña | La contraseña (o `usuario:contraseña`) |

Los demás datos (servidor, puerto o rango, OBFS, Up/Down, buffer 8388608) los muestra la opción 2.

## Seguridad

- La contraseña y el OBFS **nunca quedan vacíos**: el menú propone uno aleatorio y valida que tenga 4–128 caracteres (`A-Z a-z 0-9 . _ @ -`).
- Un HWID vencido o que no está en la lista no entra, aunque exista el archivo.
- Archivos de estado y HWID con permisos `600` (solo root).

## Convivencia con otros programas

- Las redirecciones de puertos van en una cadena propia (`CRISUDP_NAT`) puesta **primera** en `PREROUTING`: gana sobre redirecciones genéricas de otros programas (por ejemplo UDP Custom) para sus puertos.
- El instalador **rechaza** un rango que se cruce con otra redirección (por ejemplo la del panel `el_tioNel`) o con un servicio UDP que ya escuche ahí. Usa un rango distinto o ninguno (`0`).
- Los puertos QoS (443, 53, 123, 4500) que ya use otro servicio se omiten solos.

## Desinstalar

```bash
crisudp          # opción 13
# o
bash install_udp.sh --remove
```

También limpia las reglas que dejaba el instalador anterior (REDIRECT global e `iptables-persistent`).

## Cambios respecto a la versión anterior

- Menú, creación de OBFS y autenticación HWID + contraseña (antes: contraseña fija y usuarios `cris`/`root`/`admin` sin control).
- El firewall se aplica al arrancar el servicio y se quita al pararlo (ya no usa `iptables-persistent` ni deja reglas huérfanas).
- Config del servidor: `recv_window_client` (el `recv_window` anterior es una clave de **cliente** y el servidor la ignoraba); sin `idle_timeout` (también de cliente); `up`/`down` solo en `*_mbps`.
- El binario se verifica con el SHA256 oficial de GitHub, también cuando se baja desde un espejo.
- Ya no toca `ip_forward` ni `rp_filter`.
- `check_udp.sh` ahora llama al diagnóstico del menú.

## Soporte

- 📱 App: [CRISDEV Tunnel](https://play.google.com/store/apps/details?id=com.doriaxvpn.unlimited)
- 💬 Telegram: [t.me/crisis1823](https://t.me/crisis1823)
