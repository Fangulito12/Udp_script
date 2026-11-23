#!/usr/bin/env bash
# Diagnostico CRISDEV-UDP. Ahora vive dentro del menu (opcion 12); este archivo solo lo llama.
# Si cambiaste CMD_NAME en install_udp.sh, cambia tambien el nombre aqui.
CMD="$(command -v crisudp 2>/dev/null || true)"
[ -n "$CMD" ] || { echo "No encuentro el comando 'crisudp'. Instala primero:  bash install_udp.sh"; exit 1; }
exec "$CMD" --diag
