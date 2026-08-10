#!/usr/bin/env bash
# vm-bridge.sh — manage the tmux bridge that lets the VS Code agent terminal
# reach the Fedora VM (poc-openclaw-01) despite the local-subnet network block.
#
# The VS Code integrated terminal cannot reach the VM's local subnet
# (192.168.64.0/24) — a regression that appeared after a VS Code upgrade.
# A tmux server started from an interactive Terminal.app shell runs in a
# working network context. The agent sends commands into the tmux session
# via `tmux send-keys` and reads captured output from files in /tmp.
#
# Usage:
#   ./vm-bridge.sh start   — start the tmux bridge session (idempotent)
#   ./vm-bridge.sh stop    — kill the tmux bridge session
#   ./vm-bridge.sh status  — show bridge + VM + fleet status
#   ./vm-bridge.sh run "<cmd>"  — run a command on the VM via the bridge,
#                                 print output when done
#
# Requires:
#   - tart (VM hypervisor) — the VM must already be running
#   - tmux
#   - SSH access to admin@<VM_IP> (passwordless / key-based)
#
# Environment variables (override via export):
#   VM_NAME     default: poc-openclaw-01
#   VM_USER     default: admin
#   VM_IP       default: 192.168.64.3   (Tart's default subnet)
#   TMUX_SESSION default: vm
#   VM_WORKSPACE default: /mnt/workspace  (VirtioFS mount path on the VM)

set -euo pipefail

VM_NAME="${VM_NAME:-poc-openclaw-01}"
VM_USER="${VM_USER:-admin}"
VM_IP="${VM_IP:-192.168.64.3}"
TMUX_SESSION="${TMUX_SESSION:-vm}"
VM_WORKSPACE="${VM_WORKSPACE:-/mnt/workspace}"

SSH_CMD="ssh -o ConnectTimeout=5 -o BatchMode=yes ${VM_USER}@${VM_IP}"

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

tmux_session_exists() {
  tmux has-session -t "$TMUX_SESSION" 2>/dev/null
}

vm_reachable() {
  $SSH_CMD 'echo ok' >/dev/null 2>&1
}

# -----------------------------------------------------------------------------
# start — create the tmux bridge session if it doesn't exist
# -----------------------------------------------------------------------------
bridge_start() {
  if tmux_session_exists; then
    echo "tmux session '${TMUX_SESSION}' already exists."
  else
    echo "Creating tmux session '${TMUX_SESSION}'..."
    tmux new-session -d -s "$TMUX_SESSION"
    sleep 1
    echo "tmux session '${TMUX_SESSION}' created."
  fi

  if vm_reachable; then
    echo "VM ${VM_NAME} (${VM_IP}) is reachable."
  else
    echo "WARNING: VM ${VM_NAME} (${VM_IP}) is not reachable via SSH."
    echo "         Is the VM running? Start it with: tart run ${VM_NAME} --no-graphics &"
    return 1
  fi
}

# -----------------------------------------------------------------------------
# stop — kill the tmux bridge session
# -----------------------------------------------------------------------------
bridge_stop() {
  if tmux_session_exists; then
    tmux kill-session -t "$TMUX_SESSION"
    echo "tmux session '${TMUX_SESSION}' killed."
  else
    echo "tmux session '${TMUX_SESSION}' does not exist."
  fi
}

# -----------------------------------------------------------------------------
# status — show bridge, VM, and fleet status
#
# NOTE: VM reachability and fleet status are queried THROUGH the tmux bridge
# (not directly), because the caller may be a VS Code agent terminal that
# cannot reach the VM's local subnet. If the bridge session doesn't exist,
# we fall back to a direct SSH attempt.
# -----------------------------------------------------------------------------
bridge_status() {
  echo "=== tmux bridge ==="
  if tmux_session_exists; then
    tmux ls 2>&1
  else
    echo "No tmux session '${TMUX_SESSION}'. Run: $0 start"
  fi
  echo

  if tmux_session_exists; then
    echo "=== VM reachability (via bridge) ==="
    bridge_run 'uname -r; uptime' 2>&1
    echo
    echo "=== Fleet (rootless podman, via bridge) ==="
    bridge_run 'podman ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"' 2>&1 || true
  else
    echo "=== VM reachability (direct) ==="
    if vm_reachable; then
      echo "VM ${VM_NAME} (${VM_IP}): reachable"
      $SSH_CMD 'uname -r; uptime' 2>&1
      echo
      echo "=== Fleet (rootless podman) ==="
      $SSH_CMD 'podman ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"' 2>&1 || true
    else
      echo "VM ${VM_NAME} (${VM_IP}): NOT reachable"
    fi
  fi
}

# -----------------------------------------------------------------------------
# run "<cmd>" — run a command on the VM via the bridge, print output when done
#
# The command is sent into the tmux pane as an SSH invocation. The tmux
# server runs in a network context that CAN reach the VM, so we do NOT
# require direct reachability from the caller. We only require that the
# tmux session exists.
# -----------------------------------------------------------------------------
bridge_run() {
  local cmd="${1:-}"
  if [ -z "$cmd" ]; then
    echo "Usage: $0 run \"<command>\"" >&2
    return 2
  fi

  if ! tmux_session_exists; then
    echo "tmux session '${TMUX_SESSION}' does not exist. Run: $0 start" >&2
    return 1
  fi

  local outfile="/tmp/vm-bridge-$$.out"
  local marker="__BRIDGE_DONE_${$}__"

  # Send the command into the tmux pane; capture output to a file on the host.
  # The marker line tells us when the command has finished.
  tmux send-keys -t "$TMUX_SESSION" \
    "${SSH_CMD} '${cmd}' > ${outfile} 2>&1; echo ${marker} >> ${outfile}" Enter

  # Wait for the marker to appear (poll, up to ~5 min)
  local waited=0
  while [ "$waited" -lt 300 ]; do
    if [ -f "$outfile" ] && grep -q "$marker" "$outfile" 2>/dev/null; then
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done

  if [ "$waited" -ge 300 ]; then
    echo "TIMEOUT waiting for command to finish (5 min). Partial output:" >&2
  fi

  # Print output (strip the marker line)
  sed "/${marker}/d" "$outfile" 2>/dev/null || true
  rm -f "$outfile"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
case "${1:-}" in
  start)  bridge_start ;;
  stop)   bridge_stop ;;
  status) bridge_status ;;
  run)    shift; bridge_run "$*" ;;
  *)
    echo "Usage: $0 {start|stop|status|run \"<cmd>\"}" >&2
    exit 2
    ;;
esac
