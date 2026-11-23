#!/usr/bin/env bash
#
# CRISDEV-UDP v3.0 - instalador + menu (Hysteria v1)
#
#   bash install_udp.sh        la primera vez instala y abre el menu
#   crisudp                    despues, desde cualquier carpeta
#   bash install_udp.sh --help
#
# Autenticacion: HWID y/o contraseña, las dos a la vez (modo por defecto).
# Los cambios de HWID / contraseña / modo se aplican al instante, sin reiniciar.
#

###
# CONFIGURACION (valores por defecto; lo que dejes vacio se pregunta al instalar)
###

# IP o dominio del VPS. Vacio = se detecta la IP publica.
DOMAIN=""

# OBFS: vacio = el menu propone uno aleatorio (Enter para aceptarlo).
OBFS=""

# Contraseña: vacio = el menu propone una aleatoria (Enter para aceptarla).
PASSWORD=""

# Nombre del comando del menu. Si quieres otro nombre, cambia SOLO esta linea ANTES de instalar.
CMD_NAME="crisudp"

# udp | wechat-video | faketcp  (debe coincidir con la app)
PROTOCOL="udp"

DEFAULT_PORT="36712"
DEFAULT_RANGE="20000-50000"          # salto de puertos (Port Hopping)
DEFAULT_EXTRA="443 53 123 4500"      # puertos prioritarios (QoS) que tambien se redirigen

# Ancho de banda REAL de tu VPS. Si declaras mas de lo que tiene, BBR/Brutal se descontrola.
UP_MBPS=100
DOWN_MBPS=100

# Ventanas QUIC del servidor (en Hysteria v1 el servidor usa recv_window_conn y recv_window_client)
RECV_WINDOW_CONN=15728640            # >= UDP_BUFFER de la app (8 MB)
RECV_WINDOW_CLIENT=67108864
MAX_CONN_CLIENT=0

# Version de Hysteria v1 (la v1 esta congelada: 1.3.5 es la ultima)
HY_VERSION="v1.3.5"

###
# RUTAS (ROOT solo para pruebas; en uso normal queda vacio)
###

ROOT="${CRISUDP_ROOT:-}"
SCRIPT_NAME="$(basename "$0")"
SCRIPT_ARGS=("$@")

EXECUTABLE_INSTALL_PATH="$ROOT/usr/local/bin/hysteria"
SYSTEMD_SERVICES_DIR="$ROOT/etc/systemd/system"
SERVICE_NAME="hysteria-server.service"
CONFIG_DIR="$ROOT/etc/hysteria"
STATE="$CONFIG_DIR/panel.conf"
CONF_JSON="$CONFIG_DIR/config.json"
AUTH_SH="$CONFIG_DIR/auth.sh"
HWIDS="$CONFIG_DIR/hwids"
SYSCTL_FILE="$ROOT/etc/sysctl.d/99-hysteria-udp.conf"
FW_SCRIPT="$ROOT/usr/local/sbin/${CMD_NAME}-fw"
PANEL_DEST="$ROOT/usr/local/sbin/${CMD_NAME}-panel"
PANEL_LINK="$ROOT/usr/local/bin/${CMD_NAME}"
FW_CHAIN="CRISUDP_NAT"

OPERATION=""
VERSION=""
FORCE=""
LOCAL_FILE=""
ARCH=""

###
# UTILIDADES
###

if [ -t 1 ] || [ -n "${CRISUDP_COLOR:-}" ]; then
  C_G='\033[1;32m'; C_R='\033[1;31m'; C_Y='\033[1;33m'; C_B='\033[1;36m'; C_W='\033[1;37m'; C_D='\033[0;37m'; C_O='\033[0m'
else C_G=''; C_R=''; C_Y=''; C_B=''; C_W=''; C_D=''; C_O=''; fi

ok(){   printf '%b✔%b %s\n' "$C_G" "$C_O" "$*"; }
info(){ printf '%bℹ%b %s\n' "$C_B" "$C_O" "$*"; }
warn(){ printf '%b⚠%b %s\n' "$C_Y" "$C_O" "$*"; }
fail(){ printf '%b✘%b %s\n' "$C_R" "$C_O" "$*" >&2; }

has_command(){ command -v "$1" >/dev/null 2>&1; }
ask(){ local __v="$1"; IFS= read -r -p "$2" "$__v" || printf -v "$__v" ''; }
pause(){ [ -t 0 ] || return 0; echo; local _; ask _ "Presiona ENTER para continuar..."; }
confirm_word(){ [ -n "${CRISUDP_YES:-}" ] && return 0; local c; ask c "$2 Escribe $1 para confirmar: "; [ "$c" = "$1" ]; }
rand_str(){ head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c "${1:-16}"; }

valid_port(){ [[ "${1:-}" =~ ^[0-9]+$ ]] && [ "$((10#$1))" -ge 1 ] && [ "$((10#$1))" -le 65535 ]; }
valid_secret(){ [[ "${1:-}" =~ ^[A-Za-z0-9._@-]{4,128}$ ]]; }
valid_hwid(){ local h="${1:-}"; [ -n "$h" ] && [ "${#h}" -le 64 ] && [[ "$h" =~ ^[^[:space:]\|]+$ ]]; }
valid_range(){
  [[ "${1:-}" =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]] || return 1
  local a=$((10#${BASH_REMATCH[1]})) b=$((10#${BASH_REMATCH[2]}))
  [ "$a" -ge 1 ] && [ "$b" -le 65535 ] && [ "$a" -le "$b" ]
}
days_left(){ local e t; e="$(date -u -d "$1" +%s 2>/dev/null)" || { echo -9999; return; }
  t="$(date -u -d "$(date +%F)" +%s)"; echo $(( (e - t) / 86400 )); }

public_ip(){
  local ip=""
  has_command curl && ip="$(command curl -4 -fsS --max-time 4 https://api.ipify.org 2>/dev/null || true)"
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  printf '%s' "${ip:-?}"
}

svc(){ has_command systemctl && systemctl "$@"; }
svc_active(){ has_command systemctl && systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; }
is_installed(){ [ -x "$EXECUTABLE_INSTALL_PATH" ] && [ -f "$STATE" ]; }
ufw_on(){ has_command ufw && ufw status 2>/dev/null | grep -q '^Status: active'; }

# ---- estado (clave=valor en /etc/hysteria/panel.conf, solo root)
st_get(){ [ -f "$STATE" ] || return 0; grep -m1 "^$1=" "$STATE" | cut -d= -f2-; }
st_set(){
  mkdir -p "$CONFIG_DIR"; [ -f "$STATE" ] || : > "$STATE"
  grep -v "^$1=" "$STATE" > "$STATE.tmp" || true
  printf '%s=%s\n' "$1" "$2" >> "$STATE.tmp"; mv "$STATE.tmp" "$STATE"; chmod 600 "$STATE"
}

###
# ENTORNO
###

check_permission(){
  [ -n "${CRISUDP_TEST:-}" ] && return 0
  [ "$(id -u)" -eq 0 ] && return 0
  if has_command sudo; then
    info "No eres root: se reejecuta con sudo."
    exec sudo -E bash "$0" "${SCRIPT_ARGS[@]}"
  fi
  fail "Ejecuta este script como root."; exit 13
}

check_environment(){
  if [ "$(uname)" != "Linux" ]; then fail "Este script solo soporta Linux."; exit 95; fi
  case "$(uname -m)" in
    i386|i686) ARCH=386;;
    amd64|x86_64) ARCH=amd64;;
    armv5tel|armv6l|armv7|armv7l) ARCH=arm;;
    armv8|aarch64) ARCH=arm64;;
    mips|mipsle|mips64|mips64le) ARCH=mipsle;;
    s390x) ARCH=s390x;;
    *) fail "Arquitectura no soportada: $(uname -m)"; exit 8;;
  esac
  [ -d /run/systemd/system ] || warn "No detecto systemd: el servicio puede no arrancar."
  if ! has_command curl; then
    has_command apt-get && { apt-get update -qq >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl >/dev/null 2>&1; }
  fi
  if ! has_command openssl; then
    has_command apt-get && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssl >/dev/null 2>&1
  fi
  has_command curl && has_command openssl || { fail "Faltan curl/openssl y no pude instalarlos."; exit 65; }
}

###
# PUERTOS Y CONFLICTOS
###

# puertos UDP ajenos (no loopback) que ya escuchan dentro de lo..hi, salvo $3
udp_listeners_in(){
  ss -lnu 2>/dev/null | awk -v lo="$1" -v hi="$2" -v own="${3:-0}" 'NR>1 {
    a=$4; if (a ~ /^127\./ || a ~ /^\[::1\]/) next
    n=split(a,x,":"); p=x[n]+0; if (p>=lo && p<=hi && p!=own) print p }' | sort -nu | tr '\n' ' ' | sed 's/ $//'
}
# redirecciones NAT ajenas que ya cubren parte de lo..hi (ignora las "catch-all" de casi todos los puertos)
nat_overlaps(){
  has_command iptables || return 0
  iptables -t nat -S 2>/dev/null | grep -v "$FW_CHAIN" | awk -v lo="$1" -v hi="$2" '
    /-j (REDIRECT|DNAT)/ && /--dport/ {
      for (i=1;i<=NF;i++) if ($i=="--dport") { r=$(i+1); n=split(r,x,":"); a=x[1]+0; b=(n>1?x[2]+0:a)
        if (b-a >= 60000) break
        if (a<=hi && b>=lo) { print; break } } }'
}
port_in_use_by_other(){   # puerto base: ocupado por algo que no sea nuestro servicio
  local p="$1" cur; cur="$(st_get PORT)"
  [ "$p" = "$cur" ] && svc_active && return 1
  ss -lnu 2>/dev/null | awk -v p=":$p" '$4 ~ p"$" {f=1} END{exit !f}'
}
# Valida lo-hi (o un solo puerto) contra otros servicios. Devuelve 0 si esta libre.
range_is_free(){   # range_is_free lo hi puerto_base
  local c o
  c="$(udp_listeners_in "$1" "$2" "$3")"
  if [ -n "$c" ]; then fail "Ya hay servicios UDP escuchando en ese rango (puerto(s): $c)."; return 1; fi
  o="$(nat_overlaps "$1" "$2")"
  if [ -n "$o" ]; then fail "Ese rango se cruza con otra redireccion NAT (otro panel o instalador):"; printf '   %s\n' "$o" >&2; return 1; fi
  return 0
}

###
# BINARIO
###

is_elf(){ [ -f "$1" ] && [ "$(head -c 4 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "7f454c46" ]; }

# Compara el SHA256 con hashes.txt del GitHub OFICIAL. 0 = coincide, 1 = NO coincide, 2 = no se pudo comprobar
verify_hash(){   # verify_hash archivo version
  local f="hysteria-linux-$ARCH" tmp h got
  tmp="$(mktemp)" || return 2
  if ! command curl -L -fsS --max-time 20 -o "$tmp" "https://github.com/apernet/hysteria/releases/download/$2/hashes.txt" 2>/dev/null; then rm -f "$tmp"; return 2; fi
  h="$(awk -v n="$f" '{x=$2; sub(/^\*/,"",x); sub(/^.*\//,"",x); if (x==n) {print $1; exit}}' "$tmp")"
  rm -f "$tmp"; [ -n "$h" ] || return 2
  got="$(sha256sum "$1" | cut -d' ' -f1)"
  [ "$h" = "$got" ]
}

download_hysteria(){   # download_hysteria version destino
  local v="$1" dest="$2" f="hysteria-linux-$ARCH" u rc
  local path="apernet/hysteria/releases/download/$v/$f"
  # Si el VPS no llega a github.com, los espejos suelen funcionar (el hash se comprueba igual contra GitHub oficial)
  local urls=( "https://github.com/$path" "https://kkgithub.com/$path" "https://mirror.ghproxy.com/https://github.com/$path"
               "https://hub.gitmirror.com/https://github.com/$path" "https://ghproxy.com/https://github.com/$path" )
  for u in "${urls[@]}"; do
    info "Descargando: $u"
    if command curl -L -fsS --connect-timeout 15 --max-time 180 -H 'Cache-Control: no-cache' -o "$dest" "$u" 2>/dev/null && is_elf "$dest"; then
      verify_hash "$dest" "$v"; rc=$?
      if [ "$rc" -eq 0 ]; then ok "Binario descargado y verificado (SHA256)."; return 0; fi
      if [ "$rc" -eq 2 ]; then warn "No pude comprobar el SHA256 (GitHub oficial inaccesible). Se continua sin verificar."; return 0; fi
      warn "El SHA256 NO coincide con el oficial. Se descarta y se prueba otra URL."
    else
      warn "Descarga invalida o fallida desde esa URL."
    fi
    rm -f "$dest"
  done
  fail "No se pudo descargar el binario de Hysteria."
  info "Bajalo a mano y ejecuta:  bash $SCRIPT_NAME -l /ruta/hysteria-linux-$ARCH"
  return 11
}

perform_install_binary(){
  if [ -n "$LOCAL_FILE" ]; then
    is_elf "$LOCAL_FILE" || { fail "$LOCAL_FILE no es un binario ELF."; return 1; }
    info "Instalacion local: $LOCAL_FILE (SHA256: $(sha256sum "$LOCAL_FILE" | cut -d' ' -f1))"
    install -Dm755 "$LOCAL_FILE" "$EXECUTABLE_INSTALL_PATH" || return 1
    ok "Binario instalado."; return 0
  fi
  local tmp; tmp="$(mktemp)" || return 1
  if ! download_hysteria "${VERSION:-$HY_VERSION}" "$tmp"; then rm -f "$tmp"; return 1; fi
  install -Dm755 "$tmp" "$EXECUTABLE_INSTALL_PATH" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"; ok "Binario instalado en $EXECUTABLE_INSTALL_PATH"
}

###
# CERTIFICADOS
###

setup_ssl(){
  mkdir -p "$CONFIG_DIR"
  local dom ip san
  dom="$(st_get DOMAIN)"
  if [ -f "$CONFIG_DIR/crisudp.server.crt" ] && [ -f "$CONFIG_DIR/crisudp.server.key" ] && [ -f "$CONFIG_DIR/crisudp.ca.crt" ] \
     && [ "$(st_get CERT_DOMAIN)" = "$dom" ]; then
    info "Certificados existentes para $dom: se conservan."; return 0
  fi
  info "Generando certificados (CA + servidor, 10 años) para $dom ..."
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  if [[ "$dom" =~ ^[0-9.]+$ ]]; then san="IP:$dom"; [ -n "$ip" ] && [ "$ip" != "$dom" ] && san="$san,IP:$ip"
  else san="DNS:$dom"; [ -n "$ip" ] && san="$san,IP:$ip"; fi
  openssl genrsa -out "$CONFIG_DIR/crisudp.ca.key" 2048 >/dev/null 2>&1 || { fail "openssl fallo (CA key)."; return 1; }
  openssl req -new -x509 -days 3650 -key "$CONFIG_DIR/crisudp.ca.key" \
    -subj "/C=US/ST=CRISDEV/L=CRISDEV/O=CRISDEV Networks, Inc./CN=CRISDEV Root CA" \
    -out "$CONFIG_DIR/crisudp.ca.crt" >/dev/null 2>&1 || { fail "openssl fallo (CA)."; return 1; }
  openssl req -newkey rsa:2048 -nodes -keyout "$CONFIG_DIR/crisudp.server.key" \
    -subj "/C=US/ST=CRISDEV/L=CRISDEV/O=CRISDEV Networks, Inc./CN=$dom" \
    -out "$CONFIG_DIR/crisudp.server.csr" >/dev/null 2>&1 || { fail "openssl fallo (server key)."; return 1; }
  openssl x509 -req -extfile <(printf 'subjectAltName=%s' "$san") -days 3650 \
    -in "$CONFIG_DIR/crisudp.server.csr" -CA "$CONFIG_DIR/crisudp.ca.crt" -CAkey "$CONFIG_DIR/crisudp.ca.key" \
    -CAcreateserial -out "$CONFIG_DIR/crisudp.server.crt" >/dev/null 2>&1 || { fail "openssl fallo (server cert)."; return 1; }
  chmod 600 "$CONFIG_DIR"/*.key
  # compatibilidad con clientes / scripts antiguos
  cp -f "$CONFIG_DIR/crisudp.ca.crt" "$CONFIG_DIR/hysteria.ca.crt"
  cp -f "$CONFIG_DIR/crisudp.server.crt" "$CONFIG_DIR/hysteria.server.crt"
  cp -f "$CONFIG_DIR/crisudp.server.key" "$CONFIG_DIR/hysteria.server.key"
  st_set CERT_DOMAIN "$dom"
  ok "Certificados generados."
}

###
# KERNEL (buffers UDP para QUIC)
###

setup_kernel_params(){
  info "Ajustando parametros del kernel para QUIC/UDP ..."
  mkdir -p "$(dirname "$SYSCTL_FILE")"
  cat > "$SYSCTL_FILE" <<EOF
# CRISDEV-UDP - parametros del kernel para Hysteria v1 (generado por install_udp.sh)
# (ip_forward y rp_filter ya no se tocan: Hysteria termina el trafico en el propio VPS y el REDIRECT no los necesita)
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 16777216
net.core.wmem_default = 16777216
net.core.netdev_max_backlog = 65536
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_ecn = 1
net.netfilter.nf_conntrack_udp_timeout = 60
net.netfilter.nf_conntrack_udp_timeout_stream = 120
EOF
  # -e: ignora claves que este kernel no tenga (p. ej. conntrack sin cargar) en vez de abortar
  has_command sysctl && sysctl -e -p "$SYSCTL_FILE" >/dev/null 2>&1 || true
  ok "Parametros del kernel aplicados."
}

###
# ARCHIVOS DEL SERVICIO
###

# Autenticacion externa: Hysteria la llama en cada conexion nueva:  auth.sh <addr> <auth> <send> <recv>
# Lee el modo / contraseña / lista de HWID EN VIVO: los cambios del menu no requieren reiniciar.
write_auth(){
  mkdir -p "$CONFIG_DIR"
  cat > "$AUTH_SH" <<'AUTH_EOF'
#!/bin/sh
# CRISDEV-UDP - autenticacion por contraseña y/o HWID (exit 0 = permitir)
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
CONF="@CONF@"
LIST="@LIST@"
a="$2"
[ -n "$a" ] || exit 1
[ "${#a}" -le 128 ] || exit 1
[ "$(printf '%s' "$a" | wc -l)" -eq 0 ] || exit 1
mode="$(grep -m1 '^AUTHMODE=' "$CONF" 2>/dev/null | cut -d= -f2-)"
pass="$(grep -m1 '^PASSWORD=' "$CONF" 2>/dev/null | cut -d= -f2-)"
# contraseña sola o como usuario:contraseña
if [ "$mode" != hwid ] && [ -n "$pass" ]; then
  [ "$a" = "$pass" ] && exit 0
  case "$a" in *:"$pass") exit 0;; esac
fi
# HWID creado en el menu y no vencido
if [ "$mode" != password ]; then
  [ -r "$LIST" ] || exit 1
  exp="$(A="$a" awk -F'|' '$1==ENVIRON["A"]{print $2; exit}' "$LIST")"
  [ -n "$exp" ] || exit 1
  e="$(printf '%s' "$exp" | tr -d -)"
  [ "$e" -ge "$(date +%Y%m%d)" ] 2>/dev/null && exit 0
fi
exit 1
AUTH_EOF
  sed -i "s#@CONF@#$STATE#; s#@LIST@#$HWIDS#" "$AUTH_SH"
  chown root:root "$AUTH_SH" 2>/dev/null || true; chmod 755 "$AUTH_SH"
  [ -f "$HWIDS" ] || : > "$HWIDS"; chmod 600 "$HWIDS"
}

write_config(){
  local port obfs up down proto
  port="$(st_get PORT)"; obfs="$(st_get OBFS)"; up="$(st_get UP)"; down="$(st_get DOWN)"; proto="$(st_get PROTOCOL)"; proto="${proto:-$PROTOCOL}"
  [ -n "$port" ] && [ -n "$obfs" ] || { fail "Falta puerto u OBFS (usa la opcion 1 del menu)."; return 1; }
  mkdir -p "$CONFIG_DIR"
  cat > "$CONF_JSON" <<EOF
{
  "listen": ":$port",
  "protocol": "$proto",
  "cert": "$CONFIG_DIR/crisudp.server.crt",
  "key": "$CONFIG_DIR/crisudp.server.key",
  "up_mbps": ${up:-$UP_MBPS},
  "down_mbps": ${down:-$DOWN_MBPS},
  "disable_udp": false,
  "obfs": "$obfs",
  "recv_window_conn": $RECV_WINDOW_CONN,
  "recv_window_client": $RECV_WINDOW_CLIENT,
  "max_conn_client": $MAX_CONN_CLIENT,
  "auth": {
    "mode": "external",
    "config": { "cmd": "$AUTH_SH" }
  }
}
EOF
  chmod 600 "$CONF_JSON"
}

# Redireccion de puertos + apertura del puerto. Se aplica al arrancar el servicio y se quita al pararlo
# (sin iptables-persistent, y sin dejar reglas huerfanas al desinstalar).
write_fw(){
  local rg ex port proto
  rg="$(st_get RANGE)"; rg="${rg/-/:}"; ex="$(st_get EXTRA)"; port="$(st_get PORT)"; proto="$(st_get PROTOCOL)"; proto="${proto:-$PROTOCOL}"
  mkdir -p "$(dirname "$FW_SCRIPT")"
  cat > "$FW_SCRIPT" <<'FW_EOF'
#!/bin/sh
# CRISDEV-UDP: redirige el rango y los puertos QoS al puerto real y abre el puerto base.  Uso: add | del
PORT="@PORT@"
RANGE="@RANGE@"
EXTRA="@EXTRA@"
PROTO="@PROTO@"
CH=@CHAIN@
napply(){
  IPT="$1"
  [ -n "$RANGE$EXTRA" ] || return 0
  command -v "$IPT" >/dev/null 2>&1 || return 0
  "$IPT" -t nat -N $CH 2>/dev/null || true
  "$IPT" -t nat -F $CH || return 1
  if [ -n "$RANGE" ]; then
    "$IPT" -t nat -A $CH -p udp --dport "$RANGE" -j REDIRECT --to-ports "$PORT" || return 1
  fi
  for X in $EXTRA; do
    "$IPT" -t nat -A $CH -p udp --dport "$X" -j REDIRECT --to-ports "$PORT" || return 1
  done
  # primero en PREROUTING: gana sobre redirecciones genericas de otros programas (p. ej. UDP Custom)
  "$IPT" -t nat -C PREROUTING -j $CH 2>/dev/null || "$IPT" -t nat -I PREROUTING 1 -j $CH || return 1
}
nremove(){
  IPT="$1"
  command -v "$IPT" >/dev/null 2>&1 || return 0
  while "$IPT" -t nat -D PREROUTING -j $CH 2>/dev/null; do :; done
  "$IPT" -t nat -F $CH 2>/dev/null; "$IPT" -t nat -X $CH 2>/dev/null; return 0
}
iapply(){
  IPT="$1"
  command -v "$IPT" >/dev/null 2>&1 || return 0
  for P in udp $( [ "$PROTO" = faketcp ] && echo tcp ); do
    "$IPT" -C INPUT -p "$P" --dport "$PORT" -j ACCEPT 2>/dev/null || "$IPT" -I INPUT 1 -p "$P" --dport "$PORT" -j ACCEPT
  done
}
iremove(){
  IPT="$1"
  command -v "$IPT" >/dev/null 2>&1 || return 0
  for P in udp tcp; do
    while "$IPT" -D INPUT -p "$P" --dport "$PORT" -j ACCEPT 2>/dev/null; do :; done
  done
}
case "$1" in
  add)
    nremove iptables; napply iptables || echo "aviso: no pude crear la redireccion NAT (iptables)" >&2
    iapply iptables
    nremove ip6tables; napply ip6tables >/dev/null 2>&1 || true
    iapply ip6tables >/dev/null 2>&1 || true
    exit 0 ;;
  del)
    nremove iptables; nremove ip6tables; iremove iptables; iremove ip6tables
    exit 0 ;;
  *) exit 2 ;;
esac
FW_EOF
  sed -i "s#@PORT@#$port#; s#@RANGE@#$rg#; s#@EXTRA@#$ex#; s#@PROTO@#$proto#; s#@CHAIN@#$FW_CHAIN#" "$FW_SCRIPT"
  chmod 755 "$FW_SCRIPT"
}

write_unit(){
  mkdir -p "$SYSTEMD_SERVICES_DIR"
  cat > "$SYSTEMD_SERVICES_DIR/$SERVICE_NAME" <<EOF
[Unit]
Description=CRISDEV-UDP Service (Hysteria V1)
After=network.target network-online.target
Wants=network-online.target

[Service]
User=root
Group=root
WorkingDirectory=$CONFIG_DIR
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStartPre=+$FW_SCRIPT add
ExecStart=$EXECUTABLE_INSTALL_PATH -config $CONF_JSON server
ExecStopPost=+$FW_SCRIPT del
Restart=always
RestartSec=5
LimitNOFILE=1048576
LimitNPROC=512
OOMScoreAdjust=-100

[Install]
WantedBy=multi-user.target
EOF
}

redirs_text(){ local r e; r="$(st_get RANGE)"; e="$(st_get EXTRA)"; printf '%s' "${r:+rango $r}${r:+${e:+ + }}${e:+puertos $e}"; }

# regenera todo y reinicia
apply(){
  write_auth; write_config || return 1; write_fw; write_unit
  svc daemon-reload >/dev/null 2>&1 || true
  svc enable "$SERVICE_NAME" >/dev/null 2>&1 || true
  svc restart "$SERVICE_NAME" >/dev/null 2>&1
  sleep 2
  if svc_active; then
    ok "Servicio activo en UDP :$(st_get PORT)"
    if [ -n "$(st_get RANGE)$(st_get EXTRA)" ]; then
      if iptables -t nat -S "$FW_CHAIN" >/dev/null 2>&1; then ok "Redireccion UDP -> $(st_get PORT): $(redirs_text)"
      else warn "No se pudo crear la redireccion de puertos (mira: journalctl -u hysteria-server)"; fi
    fi
  else
    fail "El servicio no arranco. Revisa: journalctl -u hysteria-server -n 50 --no-pager"
    return 1
  fi
}

open_ufw(){
  local p="$1"
  if ufw_on; then ufw allow "$p/udp" >/dev/null 2>&1 && ok "UFW: abierto $p/udp"; fi
  info "Recuerda abrir tambien el puerto/rango UDP en el firewall de tu proveedor de VPS."
}

###
# MOSTRAR DATOS
###

auth_label(){ case "$(st_get AUTHMODE)" in hwid) echo "Solo HWID";; password) echo "Solo contraseña";; *) echo "HWID + contraseña (las dos a la vez)";; esac; }

show_data(){
  is_installed || { warn "CRISDEV-UDP no esta instalado."; return 0; }
  local mode rg; mode="$(st_get AUTHMODE)"; rg="$(st_get RANGE)"
  echo
  printf '%b ---- Datos para la app (CRISDEV Tunnel / CRIS UDP) ----%b\n' "$C_W" "$C_O"
  printf ' %-18s %s\n' "Servidor:" "$(st_get DOMAIN)"
  printf ' %-18s %s\n' "Puerto o rango:" "${rg:-$(st_get PORT)}  (tambien directo: $(st_get PORT)${rg:+, $(st_get EXTRA)})"
  printf ' %-18s %s\n' "Protocolo:" "CRIS UDP ($(st_get PROTOCOL))"
  printf ' %-18s %s\n' "OBFS:" "$(st_get OBFS)"
  printf ' %-18s %s\n' "Autenticacion:" "$(auth_label)"
  case "$mode" in
    hwid)     printf ' %-18s %s\n' "En la app:" "contraseña VACIA (se usa el HWID del dispositivo)";;
    password) printf ' %-18s %s\n' "Contraseña:" "$(st_get PASSWORD)";;
    *)        printf ' %-18s %s\n' "Contraseña:" "$(st_get PASSWORD)   (o vacia: entra por HWID)";;
  esac
  printf ' %-18s %s\n' "Up/Down Mbps:" "$(st_get UP)/$(st_get DOWN)"
  printf ' %-18s %s\n' "UDP Buffer:" "8388608 (8 MB)"
  printf ' %-18s %s\n' "HWID autorizados:" "$(hw_count)"
  echo
  if [ "$mode" != password ]; then info "Los HWID se crean en el menu: opcion 7. Entran solo los de la lista y no vencidos."; fi
  [ -z "$rg" ] || info "Abre UDP $rg $(st_get EXTRA) en el firewall del proveedor del VPS."
}

###
# PREGUNTAS (instalacion y "todo en uno")
###

# $1 = variable destino, $2 = texto, $3 = valor por defecto (se muestra y Enter lo acepta)
ask_default(){ local __t; ask __t " $2 [$3]: "; printf -v "$1" '%s' "${__t:-$3}"; }

ask_obfs(){      # deja el resultado en $NEW_OBFS.  ask_obfs fresh = propone uno NUEVO aleatorio
  local def; def="$(st_get OBFS)"
  [ "${1:-}" = fresh ] && def=""
  [ -n "$def" ] || def="${OBFS:-$(rand_str 16)}"
  while true; do
    ask_default NEW_OBFS "OBFS (Enter = aceptar, o escribe el tuyo)" "$def"
    valid_secret "$NEW_OBFS" && return 0
    fail "OBFS: solo letras, numeros . _ @ - (4 a 128 caracteres)."
  done
}
ask_authmode(){  # deja el resultado en $NEW_MODE
  local def="${1:-both}" n
  echo " Autenticacion:"
  echo "   [1] HWID + contraseña (las dos a la vez)"
  echo "   [2] Solo HWID"
  echo "   [3] Solo contraseña"
  case "$def" in hwid) n=2;; password) n=3;; *) n=1;; esac
  local o; ask o " Elige [$n]: "; o="${o:-$n}"
  case "$o" in 2) NEW_MODE=hwid;; 3) NEW_MODE=password;; *) NEW_MODE=both;; esac
}
ask_password(){  # deja el resultado en $NEW_PASS.  ask_password fresh = propone una NUEVA aleatoria
  local def; def="$(st_get PASSWORD)"
  [ "${1:-}" = fresh ] && def=""
  [ -n "$def" ] || def="${PASSWORD:-$(rand_str 14)}"
  while true; do
    ask_default NEW_PASS "Contraseña (Enter = aceptar, o escribe la tuya)" "$def"
    valid_secret "$NEW_PASS" && return 0
    fail "Contraseña: solo letras, numeros . _ @ - (4 a 128 caracteres)."
  done
}
# Normaliza una lista de puertos extra (valida y descarta los ocupados). Resultado en $NEW_EXTRA
check_extra(){   # check_extra "443 53" puerto_base
  local list="${1//,/ }" own="$2" p out="" n=0
  NEW_EXTRA=""
  for p in $list; do
    if ! valid_port "$p"; then fail "Puerto invalido: $p"; return 1; fi
    p=$((10#$p))
    [ "$p" = "$own" ] && continue
    case " $out " in *" $p "*) continue;; esac
    if [ -n "$(udp_listeners_in "$p" "$p" "$own")" ] || [ -n "$(nat_overlaps "$p" "$p")" ]; then
      warn "El puerto UDP $p ya lo usa otro servicio o redireccion: se omite."; continue
    fi
    n=$((n + 1)); [ "$n" -le 8 ] || { fail "Maximo 8 puertos extra."; return 1; }
    out="$out $p"
  done
  NEW_EXTRA="${out# }"
}

ask_ports(){     # puerto base, rango y puertos extra -> NEW_PORT NEW_RANGE NEW_EXTRA
  local dp dr de rg ex
  dp="$(st_get PORT)"; dp="${dp:-$DEFAULT_PORT}"
  while true; do
    ask_default NEW_PORT "Puerto UDP base" "$dp"
    if ! valid_port "$NEW_PORT"; then fail "Puerto invalido."; continue; fi
    NEW_PORT=$((10#$NEW_PORT))
    if port_in_use_by_other "$NEW_PORT"; then fail "El puerto UDP $NEW_PORT ya esta en uso por otro programa."; continue; fi
    break
  done
  if [ -n "$(st_get PORT)" ]; then dr="$(st_get RANGE)"; else dr="$DEFAULT_RANGE"; fi
  while true; do
    ask rg " Rango de puertos para salto (0 = sin rango) [${dr:-0}]: "; rg="${rg// /}"; rg="${rg:-${dr:-0}}"
    if [ "$rg" = 0 ]; then NEW_RANGE=""; break; fi
    if ! valid_range "$rg"; then fail "Rango invalido. Usa el formato 20000-50000 (de 1 a 65535, menor-mayor)."; continue; fi
    local lo=$((10#${rg%-*})) hi=$((10#${rg#*-}))
    [ "$lo" -lt 1024 ] && warn "Incluye puertos bajos: algunas operadoras los filtran."
    range_is_free "$lo" "$hi" "$NEW_PORT" || { info "Elige otro rango."; continue; }
    NEW_RANGE="$lo-$hi"; break
  done
  if [ -n "$(st_get PORT)" ]; then de="$(st_get EXTRA)"; else de="$DEFAULT_EXTRA"; fi
  while true; do
    ask ex " Puertos extra QoS, ej. 443 53 123 4500 (0 = ninguno) [${de:-0}]: "; ex="${ex:-${de:-0}}"
    if [ "${ex// /}" = 0 ]; then NEW_EXTRA=""; break; fi
    check_extra "$ex" "$NEW_PORT" && break
  done
}

###
# INSTALAR
###

install_self(){
  local src; src="$(readlink -f "${BASH_SOURCE[0]:-$0}" 2>/dev/null || echo "$0")"
  if [ ! -f "$src" ] || [ ! -r "$src" ]; then
    warn "No pude copiar el script (se ejecuto con bash <(...)): guardalo como archivo y ejecutalo de nuevo para tener el comando '$CMD_NAME'."
    return 0
  fi
  if [ "$src" != "$(readlink -f "$PANEL_DEST" 2>/dev/null)" ]; then install -Dm755 "$src" "$PANEL_DEST" || return 1; fi
  mkdir -p "$(dirname "$PANEL_LINK")"; ln -sfn "$PANEL_DEST" "$PANEL_LINK"
}

perform_install(){
  info "== Instalacion de CRISDEV-UDP (Hysteria v1) =="
  local ip dom
  ip="$(public_ip)"; dom="${DOMAIN:-$(st_get DOMAIN)}"; dom="${dom:-$ip}"
  echo
  ask_default dom "IP o dominio del VPS" "$dom"
  [ -n "$dom" ] || { fail "Falta la IP o el dominio."; return 1; }
  ask_ports
  ask_obfs
  ask_authmode "$(st_get AUTHMODE)"
  NEW_PASS=""
  if [ "$NEW_MODE" != hwid ]; then ask_password; fi
  local up down du dd
  du="$(st_get UP)"; dd="$(st_get DOWN)"; du="${du:-$UP_MBPS}"; dd="${dd:-$DOWN_MBPS}"
  ask_default up "Subida Mbps reales de tu VPS" "$du"
  ask_default down "Bajada Mbps reales de tu VPS" "$dd"
  [[ "$up" =~ ^[0-9]+$ ]] && [ "$up" -gt 0 ] || up="$UP_MBPS"
  [[ "$down" =~ ^[0-9]+$ ]] && [ "$down" -gt 0 ] || down="$DOWN_MBPS"

  perform_install_binary || return 1
  mkdir -p "$CONFIG_DIR"
  st_set DOMAIN "$dom"; st_set PORT "$NEW_PORT"; st_set RANGE "$NEW_RANGE"; st_set EXTRA "$NEW_EXTRA"
  st_set OBFS "$NEW_OBFS"; st_set AUTHMODE "$NEW_MODE"; st_set PASSWORD "$NEW_PASS"
  st_set UP "$up"; st_set DOWN "$down"; st_set PROTOCOL "$PROTOCOL"
  setup_ssl || return 1
  setup_kernel_params
  open_ufw "$NEW_PORT"
  apply || return 1
  install_self
  show_data
  echo
  if [ -x "$PANEL_LINK" ] || [ -L "$PANEL_LINK" ]; then ok "Para abrir el menu cuando quieras, escribe:  $CMD_NAME"; fi
}

###
# HWID
###

hw_count(){ local n; n="$(grep -c . "$HWIDS" 2>/dev/null || true)"; echo "${n:-0}"; }
hw_list(){
  local h e left st col n=0
  [ -s "$HWIDS" ] || { warn "No hay HWID creados."; return 0; }
  while IFS='|' read -r h e; do
    [ -n "$h" ] || continue; n=$((n + 1)); left="$(days_left "$e")"
    if [ "$left" -lt 0 ]; then st="VENCIDO"; col="$C_R"; else st="ACTIVO"; col="$C_G"; fi
    printf ' %b%2s)%b %-34s %s %4sd  %b%s%b\n' "$C_D" "$n" "$C_O" "$h" "$e" "$left" "$col" "$st" "$C_O"
  done < "$HWIDS"
}
hw_pick(){   # lista numerada y deja el HWID elegido en $PICKED
  local names=() sel
  [ -s "$HWIDS" ] || { warn "No hay HWID creados."; return 1; }
  mapfile -t names < <(cut -d'|' -f1 "$HWIDS" | grep .)
  hw_list
  ask sel " HWID (numero o texto exacto): "
  if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "${#names[@]}" ]; then PICKED="${names[$((sel - 1))]}"; else PICKED="$sel"; fi
  [ -n "$PICKED" ] && A="$PICKED" awk -F'|' '$1==ENVIRON["A"]{f=1} END{exit !f}' "$HWIDS" || { fail "Ese HWID no esta en la lista."; return 1; }
}
hw_put(){    # hw_put hwid YYYY-MM-DD   (reemplaza si ya existe)
  touch "$HWIDS"
  A="$1" awk -F'|' '$1!=ENVIRON["A"]' "$HWIDS" > "$HWIDS.tmp"
  printf '%s|%s\n' "$1" "$2" >> "$HWIDS.tmp"; mv "$HWIDS.tmp" "$HWIDS"; chmod 600 "$HWIDS"
}
hw_days(){   # pide dias; resultado en $DAYS
  ask DAYS " Dias de duracion [30]: "; DAYS="${DAYS:-30}"
  [[ "$DAYS" =~ ^[0-9]+$ ]] && [ "$DAYS" -ge 1 ] && [ "$DAYS" -le 3650 ] || { fail "Dias invalidos (1-3650)."; return 1; }
}
hw_new(){
  local h exp
  ask h " HWID del dispositivo (tal cual lo manda la app): "
  valid_hwid "$h" || { fail "HWID invalido (vacio, con espacios, con '|' o mayor a 64 caracteres)."; return 1; }
  hw_days || return 1
  exp="$(date -d "+$DAYS days" +%F)"
  hw_put "$h" "$exp"
  ok "HWID autorizado hasta $exp ($DAYS dias). Ya puede conectar, sin reiniciar nada."
  [ "$(st_get AUTHMODE)" = password ] && warn "Estas en modo 'Solo contraseña': cambia el modo (opcion 5) para que los HWID funcionen."
  return 0
}
hw_renew(){
  hw_pick || return 1
  local cur today base new
  hw_days || return 1
  cur="$(A="$PICKED" awk -F'|' '$1==ENVIRON["A"]{print $2; exit}' "$HWIDS")"; today="$(date +%F)"; base="$cur"
  [[ "$cur" < "$today" ]] && base="$today"
  new="$(date -d "$base +$DAYS days" +%F)"
  hw_put "$PICKED" "$new"; ok "Renovado: vence el $new ($(days_left "$new") dias)."
}
hw_remove(){
  hw_pick || return 1
  local a; ask a " Eliminar '$PICKED'? [s/N]: "
  case "$a" in s|S|y|Y) A="$PICKED" awk -F'|' '$1!=ENVIRON["A"]' "$HWIDS" > "$HWIDS.tmp"; mv "$HWIDS.tmp" "$HWIDS"; chmod 600 "$HWIDS"
                         ok "Eliminado. (Si estaba conectado, se corta al reconectar.)";; *) info "Sin cambios.";; esac
}
hw_clean(){
  local h e n=0
  [ -s "$HWIDS" ] || { info "No hay HWID."; return 0; }
  : > "$HWIDS.tmp"
  while IFS='|' read -r h e; do
    [ -n "$h" ] || continue
    if [ "$(days_left "$e")" -lt 0 ]; then n=$((n + 1)); else printf '%s|%s\n' "$h" "$e" >> "$HWIDS.tmp"; fi
  done < "$HWIDS"
  mv "$HWIDS.tmp" "$HWIDS"; chmod 600 "$HWIDS"
  [ "$n" -gt 0 ] && ok "Eliminados $n HWID vencido(s)." || info "No hay HWID vencidos."
}
hw_menu(){
  local op
  while true; do
    clear 2>/dev/null || true
    draw_title "ADMINISTRAR HWID"
    printf ' %bModo:%b %s   %bHWID:%b %s\n' "$C_D" "$C_W" "$(auth_label)" "$C_D" "$C_W" "$(hw_count)"
    draw_dash
    draw_item 1 "NUEVO HWID"
    draw_item 2 "RENOVAR HWID"
    draw_item 3 "ELIMINAR HWID"
    draw_item 4 "LISTAR HWID"
    draw_item 5 "BORRAR VENCIDOS"
    draw_back
    ask op "$(printf '\n%b Ingresa una Opcion: %b' "$C_D" "$C_O")"
    case "$op" in
      1) hw_new; pause;; 2) hw_renew; pause;; 3) hw_remove; pause;;
      4) echo; hw_list; pause;; 5) hw_clean; pause;;
      0) return 0;; *) echo " Opcion invalida"; sleep 1;;
    esac
  done
}

###
# ACCIONES DEL MENU
###

# 3) Todo en uno: crea el OBFS y deja activos HWID + contraseña
quick_setup(){
  is_installed || { warn "Primero instala (opcion 1)."; return 0; }
  info "Crea un OBFS nuevo y deja HWID + contraseña activos a la vez."
  ask_obfs fresh; ask_password fresh
  st_set OBFS "$NEW_OBFS"; st_set PASSWORD "$NEW_PASS"; st_set AUTHMODE both
  apply || return 1
  show_data
  local a; ask a " Quieres autorizar un HWID ahora? [s/N]: "
  case "$a" in s|S|y|Y) hw_new;; esac
  warn "Actualiza el OBFS y la contraseña en la app de tus clientes."
}
change_obfs(){
  is_installed || { warn "Primero instala (opcion 1)."; return 0; }
  info "OBFS actual: $(st_get OBFS)"
  ask_obfs fresh
  [ "$NEW_OBFS" = "$(st_get OBFS)" ] && { info "Sin cambios."; return 0; }
  st_set OBFS "$NEW_OBFS"; apply && { show_data; warn "Pon el mismo OBFS en la app de tus clientes."; }
}
change_auth(){
  is_installed || { warn "Primero instala (opcion 1)."; return 0; }
  info "Modo actual: $(auth_label)"
  ask_authmode "$(st_get AUTHMODE)"
  if [ "$NEW_MODE" != hwid ] && [ -z "$(st_get PASSWORD)" ]; then ask_password; st_set PASSWORD "$NEW_PASS"; fi
  st_set AUTHMODE "$NEW_MODE"
  ok "Modo: $(auth_label). Aplicado al instante (sin reiniciar)."
  if [ "$NEW_MODE" != password ] && [ "$(hw_count)" = 0 ]; then warn "No hay HWID creados todavia: opcion 7."; fi
}
change_password(){
  is_installed || { warn "Primero instala (opcion 1)."; return 0; }
  [ "$(st_get AUTHMODE)" = hwid ] && warn "Estas en modo 'Solo HWID': la contraseña no se usa hasta que cambies el modo (opcion 5)."
  ask_password fresh; st_set PASSWORD "$NEW_PASS"
  ok "Contraseña cambiada y aplicada al instante: $NEW_PASS"
  warn "Actualizala en la app de tus clientes."
}
change_ports(){
  is_installed || { warn "Primero instala (opcion 1)."; return 0; }
  local r e; r="$(st_get RANGE)"; e="$(st_get EXTRA)"
  info "Actual: puerto $(st_get PORT) | rango ${r:-ninguno} | extra ${e:-ninguno}"
  ask_ports
  st_set PORT "$NEW_PORT"; st_set RANGE "$NEW_RANGE"; st_set EXTRA "$NEW_EXTRA"
  open_ufw "$NEW_PORT"
  apply && { show_data; warn "Pon el nuevo puerto o rango en la app de tus clientes."; }
}

diag(){
  is_installed || { warn "CRISDEV-UDP no esta instalado."; return 0; }
  DG_W=0; DG_F=0
  local port rg ex up down cert exp n v cur
  d_ok(){ ok "$*"; }
  d_warn(){ warn "$*"; DG_W=$((DG_W + 1)); }
  d_fail(){ fail "$*"; DG_F=$((DG_F + 1)); }
  port="$(st_get PORT)"; rg="$(st_get RANGE)"; ex="$(st_get EXTRA)"
  v="$(timeout 3 "$EXECUTABLE_INSTALL_PATH" -v 2>/dev/null | head -1)"
  echo "===== Diagnostico CRISDEV-UDP ====="; [ -n "$v" ] && info "Binario: $v"

  echo; echo "1. Servicio"
  if svc_active; then d_ok "ACTIVO ($SERVICE_NAME)"; else d_fail "INACTIVO: usa REINICIAR (opcion 9) y mira los logs (opcion 11)"; fi
  if svc is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then d_ok "Arranca solo al encender el VPS"; else d_warn "No esta habilitado para arrancar solo: usa REINICIAR (opcion 9)"; fi
  if grep -q '^Restart=always' "$SYSTEMD_SERVICES_DIR/$SERVICE_NAME" 2>/dev/null; then d_ok "Restart=always (se recupera si se cae)"; else d_warn "Sin Restart=always: usa REINICIAR (opcion 9) para regenerar la unidad"; fi

  echo; echo "2. Puerto UDP"
  if ss -lnu 2>/dev/null | awk -v p=":$port" '$4 ~ p"$" {f=1} END{exit !f}'; then d_ok "Escuchando en UDP :$port"
  else d_fail "Nada escucha en UDP :$port (servicio caido o puerto ocupado)"; fi

  echo; echo "3. Configuracion"
  if [ -f "$CONF_JSON" ]; then
    up="$(st_get UP)"; down="$(st_get DOWN)"
    if [[ "$up" =~ ^[0-9]+$ ]] && [ "$up" -gt 0 ] && [[ "$down" =~ ^[0-9]+$ ]] && [ "$down" -gt 0 ]; then d_ok "Up/Down declarados: $up/$down Mbps (deben ser los reales de tu VPS)"
    else d_fail "up/down Mbps invalidos"; fi
    if [ -n "$(st_get OBFS)" ]; then d_ok "OBFS configurado"; else d_fail "OBFS vacio: el trafico queda sin ofuscar"; fi
    grep -q '"recv_window_conn"' "$CONF_JSON" && grep -q '"recv_window_client"' "$CONF_JSON" && d_ok "Ventanas QUIC presentes" || d_warn "Faltan las ventanas QUIC en config.json"
    if [ -x "$AUTH_SH" ]; then d_ok "Autenticacion externa: auth.sh presente"; else d_fail "Falta auth.sh: usa REINICIAR (opcion 9)"; fi
    d_ok "Modo: $(auth_label)"
    case "$(st_get AUTHMODE)" in
      hwid) n="$(hw_count)"; [ "$n" -gt 0 ] && d_ok "$n HWID autorizado(s)" || d_warn "0 HWID autorizados: nadie podra conectar (opcion 7)";;
      password) [ -n "$(st_get PASSWORD)" ] && d_ok "Contraseña configurada" || d_fail "Contraseña vacia: nadie podra conectar";;
      *) [ -n "$(st_get PASSWORD)" ] && d_ok "Contraseña configurada" || d_fail "Contraseña vacia"
         n="$(hw_count)"; [ "$n" -gt 0 ] && d_ok "$n HWID autorizado(s)" || d_warn "0 HWID autorizados (solo entran con contraseña)";;
    esac
  else d_fail "No existe $CONF_JSON: usa REINICIAR (opcion 9)"; fi

  echo; echo "4. Certificado"
  cert="$CONFIG_DIR/crisudp.server.crt"
  if [ -f "$cert" ] && [ -f "$CONFIG_DIR/crisudp.server.key" ]; then
    exp="$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2)"
    if ! openssl x509 -checkend 0 -noout -in "$cert" >/dev/null 2>&1; then d_fail "Certificado VENCIDO ($exp): reinstala (opcion 1)"
    elif ! openssl x509 -checkend 2592000 -noout -in "$cert" >/dev/null 2>&1; then d_warn "El certificado vence en menos de 30 dias ($exp)"
    else d_ok "Certificado valido hasta: $exp"; fi
    [ -f "$CONFIG_DIR/crisudp.ca.crt" ] && d_ok "Certificado raiz crisudp.ca.crt presente"
  else d_fail "Faltan los certificados en $CONFIG_DIR: reinstala (opcion 1)"; fi

  echo; echo "5. Firewall y redireccion de puertos"
  if svc_active; then
    if [ -n "$rg$ex" ]; then
      if iptables -t nat -S "$FW_CHAIN" >/dev/null 2>&1; then
        [ -z "$rg" ] || { iptables -t nat -S "$FW_CHAIN" 2>/dev/null | grep -q -- "--dport ${rg/-/:} " && d_ok "Salto de puertos activo: UDP $rg -> $port" || d_warn "No encuentro la regla del rango $rg"; }
        for n in $ex; do iptables -t nat -S "$FW_CHAIN" 2>/dev/null | grep -q -- "--dport $n " && d_ok "Puerto extra UDP $n -> $port" || d_warn "No encuentro la regla del puerto extra $n"; done
      else d_fail "Faltan las reglas NAT: usa REINICIAR (opcion 9)"; fi
    else info "Sin rango ni puertos extra (solo el puerto $port)."; fi
  else info "Servicio detenido: las reglas se crean al arrancar."; fi
  if ufw_on; then
    if ufw status 2>/dev/null | grep -Eq "^$port/udp[[:space:]]+ALLOW"; then d_ok "UFW permite $port/udp"; else d_warn "UFW activo pero sin regla para $port/udp: ufw allow $port/udp"; fi
  else info "UFW inactivo (no se comprueba)."; fi
  info "Recuerda: el puerto${rg:+, el rango}${ex:+ y los puertos extra} UDP tambien deben estar abiertos en el firewall del proveedor."

  echo; echo "6. Kernel (buffers UDP)"
  cur="$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0)"
  if [[ "$cur" =~ ^[0-9]+$ ]] && [ "$cur" -ge 67108864 ]; then d_ok "rmem_max=$cur (>= 64 MB)"
  else d_warn "rmem_max=$cur: bajo para QUIC. Reinstala (opcion 1) para aplicar los parametros del kernel"; fi

  echo; echo "7. Ultimos logs"
  journalctl -u hysteria-server -n 8 --no-pager 2>/dev/null || info "Sin logs."
  echo
  if [ "$DG_F" -eq 0 ] && [ "$DG_W" -eq 0 ]; then ok "Todo en orden."
  else warn "Resultado: $DG_F error(es), $DG_W advertencia(s)."; fi
  unset -f d_ok d_warn d_fail
}

# ---- reglas del instalador anterior de CRIS (iptables-persistent / REDIRECT global): se quitan si existen
remove_legacy_rules(){
  has_command iptables || return 0
  local p r port
  for port in 36712 "$(st_get PORT)"; do
    [ -n "$port" ] || continue
    for r in "20000:50000" 443 53 123 4500; do
      while iptables -t nat -D PREROUTING -p udp --dport "$r" -j REDIRECT --to-port "$port" 2>/dev/null; do :; done
      while iptables -D INPUT -p udp --dport "$r" -j ACCEPT 2>/dev/null; do :; done
    done
    for p in udp tcp; do
      while iptables -D INPUT -p "$p" --dport "$port" -j ACCEPT 2>/dev/null; do :; done
    done
  done
  return 0
}

perform_remove(){
  info "== Desinstalar CRISDEV-UDP =="
  confirm_word BORRAR "Se borra el servicio, la configuracion (incluidos los HWID), los certificados y las reglas de firewall." \
    || { info "Sin cambios."; return 0; }
  svc disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
  [ -x "$FW_SCRIPT" ] && "$FW_SCRIPT" del >/dev/null 2>&1
  remove_legacy_rules
  rm -f "$SYSTEMD_SERVICES_DIR/$SERVICE_NAME" "$SYSTEMD_SERVICES_DIR/hysteria-server@.service"
  rm -f "$EXECUTABLE_INSTALL_PATH" "$FW_SCRIPT" "$SYSCTL_FILE"
  rm -rf "$CONFIG_DIR"
  rm -f "$PANEL_LINK" "$PANEL_DEST"
  svc daemon-reload >/dev/null 2>&1 || true
  ok "CRISDEV-UDP desinstalado por completo (servicio, config, HWID, certificados y reglas de firewall)."
  info "Los buffers de red del kernel siguen aplicados hasta el proximo reinicio (son inofensivos)."
}

###
# MENU
###

W=54
calc_w(){ local c; c="$(tput cols 2>/dev/null || echo 54)"; [[ "$c" =~ ^[0-9]+$ ]] || c=54; [ "$c" -gt 54 ] && c=54; [ "$c" -lt 40 ] && c=40; W="$c"; }
rep_char(){ local i out=""; for ((i = 0; i < $2; i++)); do out+="$1"; done; printf '%s' "$out"; }
draw_hl(){ printf '%b%s%b\n' "$C_R" "$(rep_char '=' "$W")" "$C_O"; }
draw_dash(){ printf '%b%s%b\n' "$C_R" "$(rep_char '-' "$W")" "$C_O"; }
draw_title(){ local t="$1" pad; calc_w; pad=$(( (W - ${#t}) / 2 )); [ "$pad" -lt 0 ] && pad=0
  draw_hl; printf '%*s%b%s%b\n' "$pad" "" "$C_D" "$t" "$C_O"; draw_hl; }
draw_item(){ local col="${3:-$C_W}"; printf ' %b[%s]%b>%b %b%s%b\n' "$C_D" "$1" "$C_R" "$C_O" "$col" "$2" "$C_O"; }
draw_back(){ draw_hl; printf ' %b[0]%b %b %s %b\n' "$C_D" "$C_O" '\033[41;1;37m' "${1:-Volver}" "$C_O"; draw_hl; }
tag(){ if [ "$1" = on ]; then printf '%b[ON]%b' "$C_G" "$C_O"; else printf '%b[OFF]%b' "$C_R" "$C_O"; fi; }

menu(){
  local op st
  while true; do
    clear 2>/dev/null || true
    draw_title "CRISDEV-UDP  v3.0"
    if is_installed; then
      svc_active && st=on || st=off
      printf ' %bUDP :%b %s  ' "$C_D" "$C_W" "$(st_get PORT)"; tag "$st"; echo
      printf ' %bAuth:%b %s\n' "$C_D" "$C_W" "$(auth_label)"
      printf ' %bRango:%b %s   %bHWID:%b %s\n' "$C_D" "$C_W" "$(st_get RANGE | sed 's/^$/-/')" "$C_D" "$C_W" "$(hw_count)"
    else printf ' %bCRISDEV-UDP sin instalar%b\n' "$C_D" "$C_O"; fi
    draw_dash
    draw_item 1 "INSTALAR / REINSTALAR"
    draw_item 2 "VER DATOS PARA LA APP"
    draw_item 3 "CREAR OBFS + HWID + CONTRASEÑA (todo en uno)"
    draw_item 4 "CAMBIAR OBFS"
    draw_item 5 "AUTENTICACION (modo HWID / contraseña)"
    draw_item 6 "CAMBIAR CONTRASEÑA"
    draw_item 7 "ADMINISTRAR HWID"
    draw_item 8 "PUERTO / RANGO / PUERTOS QoS"
    draw_dash
    draw_item 9 "REINICIAR"
    draw_item 10 "DETENER"
    draw_item 11 "VER LOGS"
    draw_item 12 "DIAGNOSTICO COMPLETO"
    draw_item 13 "[!] DESINSTALAR" '\033[38;5;208m'
    draw_back "SALIR"
    ask op "$(printf '\n%b Ingresa una Opcion: %b' "$C_D" "$C_O")"
    case "$op" in
      1) FORCE=1; perform_install; pause;;
      2) show_data; pause;;
      3) quick_setup; pause;;
      4) change_obfs; pause;;
      5) change_auth; pause;;
      6) change_password; pause;;
      7) is_installed && hw_menu || { warn "Primero instala (opcion 1)."; pause; };;
      8) change_ports; pause;;
      9) if is_installed; then apply; else warn "No esta instalado."; fi; pause;;
      10) svc stop "$SERVICE_NAME" 2>/dev/null; warn "Detenido (vuelve a arrancar con Reiniciar)."; pause;;
      11) journalctl -u hysteria-server -n 50 --no-pager 2>/dev/null || info "Sin logs."; pause;;
      12) diag; pause;;
      13) perform_remove; pause; is_installed || return 0;;
      0) return 0;;
      *) echo " Opcion invalida"; sleep 1;;
    esac
  done
}

###
# ARGUMENTOS
###

show_usage_and_exit(){
  cat <<EOF

  $SCRIPT_NAME - CRISDEV-UDP v3.0 (Hysteria v1, con menu)

  Uso:
    bash $SCRIPT_NAME                 instala (si falta) y abre el menu
    $CMD_NAME                         abre el menu (despues de instalar)
    $CMD_NAME --diag                  diagnostico completo
    bash $SCRIPT_NAME -f              reinstalar
    bash $SCRIPT_NAME -l <archivo>    instalar con un binario hysteria local (sin descargar)
    bash $SCRIPT_NAME --version vX    instalar esa version de Hysteria v1
    bash $SCRIPT_NAME --remove        desinstalar todo (servicio, config, HWID y reglas de firewall)
    bash $SCRIPT_NAME -h              esta ayuda

EOF
  exit 0
}

parse_arguments(){
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --remove) OPERATION=remove;;
      --diag|--check-server) OPERATION=diag;;
      --menu) OPERATION=menu;;
      --version) VERSION="${2:-}"; [ -n "$VERSION" ] || { fail "Falta la version."; exit 22; }; shift
                 [[ "$VERSION" == v* ]] || { fail "La version debe empezar con 'v' (ej: v1.3.5)."; exit 22; };;
      -f|--force) FORCE=1;;
      -l|--local) LOCAL_FILE="${2:-}"; [ -n "$LOCAL_FILE" ] || { fail "Falta el archivo para -l."; exit 22; }; shift;;
      -h|--help) show_usage_and_exit;;
      *) fail "Opcion desconocida '$1'. Prueba: $SCRIPT_NAME --help"; exit 22;;
    esac
    shift
  done
}

main(){
  parse_arguments "$@"
  check_permission
  check_environment
  case "${OPERATION:-auto}" in
    remove) perform_remove;;
    diag)   diag;;
    menu)   menu;;
    *)
      if is_installed && [ -z "$FORCE" ] && [ -z "$LOCAL_FILE" ] && [ -z "$VERSION" ]; then menu
      else perform_install && { pause; menu; }; fi;;
  esac
}

main "$@"
