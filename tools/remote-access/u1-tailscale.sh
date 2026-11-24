#!/bin/bash
# Remote access for the Snapmaker U1: Tailscale runs on the printer itself (userspace networking – the U1 kernel has
# no TUN device) and shares the home network (subnet router), so the Kobra S1 and the P1S are reachable on the way too.
#
#   tools/remote-access/u1-tailscale.sh install   [U1-IP]   copy Tailscale to the printer and start it
#   tools/remote-access/u1-tailscale.sh login     [U1-IP]   print the login link (open it on the phone)
#   tools/remote-access/u1-tailscale.sh status    [U1-IP]   is it running, which address, which routes
#   tools/remote-access/u1-tailscale.sh uninstall [U1-IP]   stop and remove everything again
#
# Nothing of the printer's own software is changed: the files live in /userdata/tailscale, a cron entry
# (/etc/crontabs/root) starts the daemon after a reboot (init scripts added later are not run by the U1's boot).
# tailscaled runs with the lowest CPU priority and a memory limit, so Klipper keeps its timing.
# A Snapmaker firmware update removes the cron entry; run "install" again afterwards.
set -euo pipefail

CMD=${1:-status}
HOST=${2:-192.168.68.57}
VERSION=${TS_VERSION:-1.104.7}
DIR=/userdata/tailscale
SOCK=/run/tailscale/tailscaled.sock
SSH_OPTS=(-o ConnectTimeout=8 -o ServerAliveInterval=10)

remote() { ssh "${SSH_OPTS[@]}" "root@$HOST" "$@"; }

# The home network the printer is in (e.g. 192.168.68.0/22), from the printer's own route table.
subnet() {
  remote "ip -4 route show dev wlan0 scope link 2>/dev/null | awk '{print \$1}' | head -1"
}

case "$CMD" in
install)
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  url="https://pkgs.tailscale.com/stable/tailscale_${VERSION}_arm64.tgz"
  echo "Lade $url"
  curl -fsSL "$url" -o "$tmp/ts.tgz"
  expected=$(curl -fsSL "$url.sha256" | awk '{print $1}')
  actual=$(shasum -a 256 "$tmp/ts.tgz" | awk '{print $1}')
  [ "$expected" = "$actual" ] || { echo "Prüfsumme stimmt nicht ($actual ≠ $expected)"; exit 1; }
  echo "Prüfsumme ok. Kopiere auf den Drucker ($HOST) nach $DIR …"
  # Plain tar options only (the printer's tar may be BusyBox).
  remote "mkdir -p $DIR/state $DIR/unpack && tar xzf - -C $DIR/unpack && mv -f $DIR/unpack/tailscale_${VERSION}_arm64/tailscale $DIR/unpack/tailscale_${VERSION}_arm64/tailscaled $DIR/ && rm -rf $DIR/unpack" < "$tmp/ts.tgz"
  remote "cat > $DIR/ensure.sh" <<'EOF'
#!/bin/sh
# Starts tailscaled if it is not running (called by cron every minute; does nothing when it runs).
D=/userdata/tailscale
pidof tailscaled >/dev/null 2>&1 && exit 0
[ -f "$D/disabled" ] && exit 0
mkdir -p /run/tailscale
# Keep the log small.
[ -f "$D/tailscaled.log" ] && [ "$(wc -c < "$D/tailscaled.log")" -gt 1000000 ] && mv "$D/tailscaled.log" "$D/tailscaled.log.1"
GOMEMLIMIT=80MiB GOGC=50 nohup nice -n 19 "$D/tailscaled" --tun=userspace-networking --statedir="$D/state" \
  --socket=/run/tailscale/tailscaled.sock --port=41641 >> "$D/tailscaled.log" 2>&1 &
EOF
  remote "chmod +x $DIR/ensure.sh $DIR/tailscale $DIR/tailscaled && mkdir -p /etc/crontabs && touch /etc/crontabs/root \
    && (grep -q '$DIR/ensure.sh' /etc/crontabs/root || echo '* * * * * $DIR/ensure.sh' >> /etc/crontabs/root) \
    && rm -f $DIR/disabled && $DIR/ensure.sh && sleep 3 && pidof tailscaled >/dev/null && echo 'tailscaled läuft.'"
  echo "Weiter mit: $0 login $HOST"
  ;;
login)
  net=$(subnet)
  echo "Heimnetz: $net"
  # "up" prints the login link and waits; the timeout ends the wait, the login itself happens in the browser.
  remote "$DIR/tailscale --socket=$SOCK up --hostname=snapmaker-u1 --advertise-routes=$net --accept-dns=false --timeout=15s 2>&1 || true" \
    | grep -Eo 'https://login\.tailscale\.com/[^ ]+' | head -1 || true
  ;;
status)
  remote "pidof tailscaled >/dev/null && echo 'tailscaled läuft' || echo 'tailscaled läuft nicht'; \
    [ -x $DIR/tailscale ] && $DIR/tailscale --socket=$SOCK status 2>&1 | head -12; \
    [ -x $DIR/tailscale ] && $DIR/tailscale --socket=$SOCK ip -4 2>/dev/null; \
    grep -q '$DIR/ensure.sh' /etc/crontabs/root 2>/dev/null && echo 'Autostart: an' || echo 'Autostart: aus'"
  ;;
uninstall)
  remote "touch $DIR/disabled 2>/dev/null; [ -x $DIR/tailscale ] && $DIR/tailscale --socket=$SOCK logout 2>/dev/null; \
    killall tailscaled 2>/dev/null; sed -i '\#$DIR/ensure.sh#d' /etc/crontabs/root 2>/dev/null; rm -rf $DIR; echo 'Tailscale entfernt.'"
  ;;
*)
  echo "Unbekannt: $CMD (install | login | status | uninstall)"; exit 2 ;;
esac
