#!/usr/bin/env bash
# Servidores oficiales 24/7 de Línea Cero en una máquina Ubuntu (Oracle Cloud Always Free).
#
# Se ejecuta solo al crear la máquina (script de inicialización de Oracle):
#   #!/bin/bash
#   curl -fsSL https://raw.githubusercontent.com/Alex-Robles26/linea-cero/main/servidor/instalar.sh | bash
#
# O a mano, por SSH:  curl -fsSL <misma URL> | sudo bash
#
# Qué hace:
#   - descarga el servidor de la última versión publicada en GitHub (ARM64 o x86_64),
#   - abre los puertos UDP del juego en el cortafuegos de Ubuntu,
#   - arranca una partida por línea de /opt/lineacero/servidores.conf (cada una en su puerto),
#     que se reinicia sola si se cae y al encender la máquina,
#   - comprueba cada hora si hay una versión nueva y se actualiza sola.
set -euo pipefail

REPO="Alex-Robles26/linea-cero"
DIR="/opt/lineacero"
if [ "$(id -u)" -ne 0 ]; then
  echo "Ejecuta con sudo"; exit 1
fi
export DEBIAN_FRONTEND=noninteractive

echo "== Paquetes"
apt-get update -y -q || true
apt-get install -y -q curl ca-certificates iptables-persistent fontconfig >/dev/null || \
  apt-get install -y -q curl ca-certificates fontconfig >/dev/null || true

echo "== Usuario y carpeta"
id -u lineacero >/dev/null 2>&1 || useradd --system --home-dir "$DIR/home" --create-home --shell /usr/sbin/nologin lineacero
mkdir -p "$DIR/home"

# Partidas: puerto | modo | mapa | bots | nombre. Una máquina pequeña (1 núcleo) solo lleva la primera.
if [ ! -f "$DIR/servidores.conf" ]; then
  cat > "$DIR/servidores.conf" <<'EOF'
# puerto|modo|mapa|bots|nombre   (modos: tdm, br, competitive, sd, koth, ctf, dm)
24570|tdm|presa|9|Oficial · Por equipos
24571|br|valle|23|Oficial · Zona Cero
24572|competitive|fundicion|9|Oficial · Competitivo 5c5
EOF
fi
if [ "$(nproc)" -lt 2 ]; then
  sed -i '/^2457[1-9]|/s/^/#/' "$DIR/servidores.conf"
fi

echo "== Programa de actualización"
cat > "$DIR/actualizar.sh" <<'EOF'
#!/usr/bin/env bash
# Descarga el servidor de la última versión de GitHub si cambió y reinicia las partidas.
set -euo pipefail
REPO="Alex-Robles26/linea-cero"
DIR="/opt/lineacero"
case "$(uname -m)" in
  aarch64|arm64) ARCH="arm64" ;;
  *) ARCH="x86_64" ;;
esac
TAG=$(curl -fsSI "https://github.com/$REPO/releases/latest" | tr -d '\r' | sed -n 's#^[Ll]ocation: .*/tag/##p' | tail -1)
[ -n "$TAG" ] || { echo "No se pudo leer la última versión"; exit 0; }
if [ -f "$DIR/version" ] && [ "$(cat "$DIR/version")" = "$TAG" ] && [ -x "$DIR/servidor" ]; then
  echo "Ya está en $TAG"; exit 0
fi
echo "Descargando $TAG ($ARCH)"
curl -fL --retry 3 -o "$DIR/servidor.nuevo" "https://github.com/$REPO/releases/download/$TAG/lineacero-server-$ARCH"
chmod +x "$DIR/servidor.nuevo"
mv -f "$DIR/servidor.nuevo" "$DIR/servidor"
echo "$TAG" > "$DIR/version"
chown -R lineacero: "$DIR"
"$DIR/aplicar.sh"
EOF

cat > "$DIR/aplicar.sh" <<'EOF'
#!/usr/bin/env bash
# Crea o reinicia una partida por línea de servidores.conf y apaga las que ya no están.
set -euo pipefail
DIR="/opt/lineacero"
WANT=()
while IFS='|' read -r PORT MODE MAP BOTS NAME; do
  case "$PORT" in ''|\#*) continue ;; esac
  PORT=$(echo "$PORT" | tr -d ' ')
  printf 'MODE=%s\nMAP=%s\nBOTS=%s\nNAME=%s\n' "$MODE" "$MAP" "$BOTS" "$NAME" > "$DIR/partida-$PORT.env"
  # Cortafuegos de Ubuntu (Oracle trae una regla REJECT al final de INPUT).
  iptables -C INPUT -p udp --dport "$PORT" -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p udp --dport "$PORT" -j ACCEPT
  WANT+=("lineacero@$PORT")
done < "$DIR/servidores.conf"
command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1 || true
chown -R lineacero: "$DIR"
systemctl daemon-reload
for unit in $(systemctl list-units --all --plain --no-legend 'lineacero@*.service' | awk '{print $1}'); do
  keep=0
  for w in "${WANT[@]}"; do [ "$unit" = "$w.service" ] && keep=1; done
  [ "$keep" = 1 ] || systemctl disable --now "$unit" || true
done
for w in "${WANT[@]}"; do
  systemctl enable "$w" >/dev/null 2>&1
  systemctl restart "$w"
done
EOF
chmod +x "$DIR/actualizar.sh" "$DIR/aplicar.sh"

echo "== Servicios"
cat > /etc/systemd/system/lineacero@.service <<'EOF'
[Unit]
Description=Línea Cero: servidor oficial en el puerto UDP %i
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=lineacero
WorkingDirectory=/opt/lineacero
EnvironmentFile=/opt/lineacero/partida-%i.env
ExecStart=/opt/lineacero/servidor --headless -- --server --port=%i --mode=${MODE} --map=${MAP} --bots=${BOTS} --server_name=${NAME}
Restart=always
RestartSec=5
Nice=-5
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/opt/lineacero
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/lineacero-actualizar.service <<'EOF'
[Unit]
Description=Línea Cero: buscar una versión nueva del servidor
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/lineacero/actualizar.sh
EOF

cat > /etc/systemd/system/lineacero-actualizar.timer <<'EOF'
[Unit]
Description=Línea Cero: actualización automática cada hora

[Timer]
OnBootSec=1min
OnUnitActiveSec=1h
RandomizedDelaySec=5min

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable lineacero-actualizar.timer >/dev/null 2>&1
"$DIR/actualizar.sh"
# If the binary was already current, actualizar.sh skipped aplicar.sh: start the matches anyway.
"$DIR/aplicar.sh"
systemctl start lineacero-actualizar.timer

IP=$(curl -fs --max-time 5 https://api.ipify.org || echo "TU_IP")
echo
echo "== Listo. Servidores oficiales en $IP:"
grep -v '^#' "$DIR/servidores.conf" | while IFS='|' read -r PORT MODE MAP BOTS NAME; do
  [ -n "$PORT" ] && echo "   $NAME  ->  $IP:$PORT"
done
echo "   Abre esos puertos UDP en la Security List de Oracle (Ingress, 0.0.0.0/0, UDP 24570-24572)."
echo "   Registros: journalctl -u 'lineacero@*' -f      Cambiar partidas: nano $DIR/servidores.conf && sudo $DIR/aplicar.sh"
