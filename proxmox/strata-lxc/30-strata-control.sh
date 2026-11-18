#!/usr/bin/env bash
# 30-strata-control.sh - start/stop/status/logs for the Strata container.
# Run on the Proxmox host as root.
#
#   bash 30-strata-control.sh start|stop|restart|status|logs
#
# Stopping frees the 56 GiB RAM and the GPU, which is what you want before
# running anything else on the card.
set -euo pipefail

CTID="${CTID:-121}"
STRATA_DIR="${STRATA_DIR:-/opt/Strata}"
RUN_SCRIPT="${RUN_SCRIPT:-run-iq3_s.sh}"
ACTION="${1:-status}"

[ "$(id -u)" -eq 0 ] || { echo "run as root on the Proxmox host"; exit 1; }
pct status "$CTID" >/dev/null 2>&1 || { echo "CT $CTID does not exist"; exit 1; }

running() { [ "$(pct status "$CTID" | awk '{print $2}')" = "running" ]; }
has_unit() { pct exec "$CTID" -- systemctl list-unit-files strata.service >/dev/null 2>&1; }

start() {
  running || pct start "$CTID"
  for _ in $(seq 1 20); do pct exec "$CTID" -- true >/dev/null 2>&1 && break; sleep 1; done
  if pct exec "$CTID" -- pgrep -f "$STRATA_DIR/engine/strata" >/dev/null 2>&1; then
    echo "an engine is already running (probably the setup window)."
    echo "stop it there first (Ctrl+C in the tmux session) to avoid two engines and an OOM kill."
    return 1
  fi
  if has_unit && pct exec "$CTID" -- systemctl cat strata.service >/dev/null 2>&1; then
    pct exec "$CTID" -- systemctl start strata
  else
    echo "strata.service not installed; run the setup inside the container first"
    pct exec "$CTID" -- bash -c 'cd "$1" && nohup "./$2" >/var/log/strata.log 2>&1 &' _ "$STRATA_DIR" "$RUN_SCRIPT" || true
  fi
  echo "CT $CTID started"
  status
}

stop() {
  if running; then
    if has_unit && pct exec "$CTID" -- systemctl cat strata.service >/dev/null 2>&1; then
      pct exec "$CTID" -- systemctl stop strata || true
    else
      pct exec "$CTID" -- pkill -f "$STRATA_DIR" || true
    fi
    pct stop "$CTID"
    echo "CT $CTID stopped (RAM and GPU released)"
  else
    echo "CT $CTID already stopped"
  fi
}

status() {
  if running; then
    echo "CT $CTID: running"
    pct exec "$CTID" -- bash -c '
      if systemctl is-active --quiet strata; then echo "service: active"; else echo "service: inactive"; fi
      free -h | awk "/^Mem:/{print \"memory: \"\$3\" used / \"\$2}"
      curl -fsS --max-time 3 http://127.0.0.1:8080/health 2>/dev/null | head -c 200 || echo "api: no answer yet"
      echo
    '
  else
    echo "CT $CTID: stopped"
  fi
}

case "$ACTION" in
  start)   start ;;
  stop)    stop ;;
  restart) stop; start ;;
  status)  status ;;
  logs)    pct exec "$CTID" -- journalctl -u strata -n 100 --no-pager ;;
  *) echo "usage: $0 start|stop|restart|status|logs"; exit 1 ;;
esac
