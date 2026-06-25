#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="lyrion"
SELECTOR="app=lyrion"
POD=""
CONTAINER="lyrion"
RPC_PORT="9000"
WAIT_SECS="3"
TAIL_LINES="120"
WAIT_IDLE=1
WAIT_TIMEOUT_SECS="600"
ABORT_RUNNING=0

usage() {
	cat <<'EOF'
Trigger dedicated FreeRadio scan through LMS JSON-RPC (external scanner.pl).

Usage:
  scripts/dev-trigger-scan-k8s.sh [options]

Options:
  -n, --namespace <ns>     Kubernetes namespace (default: lyrion)
  -l, --selector <label>   Pod label selector (default: app=lyrion)
  -p, --pod <name>         Pod name (overrides selector lookup)
  -c, --container <name>   Container name (default: lyrion)
  -r, --rpc-port <port>    LMS JSON-RPC port in pod (default: 9000)
  --no-wait-idle           Do not wait for existing scanner job to finish
  --wait-timeout <seconds> Max wait for idle scanner (default: 600)
  --abort-running          Abort currently running scan before triggering
  -w, --wait <seconds>     Seconds to wait before log tail (default: 3)
  -t, --tail-lines <n>     Number of scanner.log lines to show (default: 120)
  -h, --help               Show this help

This sends:
  ["rescan", "external", "file:///freeradio"]
EOF
}

while (($#)); do
	case "$1" in
		-n|--namespace)
			NAMESPACE="$2"; shift 2 ;;
		-l|--selector)
			SELECTOR="$2"; shift 2 ;;
		-p|--pod)
			POD="$2"; shift 2 ;;
		-c|--container)
			CONTAINER="$2"; shift 2 ;;
		-r|--rpc-port)
			RPC_PORT="$2"; shift 2 ;;
		--no-wait-idle)
			WAIT_IDLE=0; shift ;;
		--wait-timeout)
			WAIT_TIMEOUT_SECS="$2"; shift 2 ;;
		--abort-running)
			ABORT_RUNNING=1; shift ;;
		-w|--wait)
			WAIT_SECS="$2"; shift 2 ;;
		-t|--tail-lines)
			TAIL_LINES="$2"; shift 2 ;;
		-h|--help)
			usage; exit 0 ;;
		*)
			echo "Unknown option: $1" >&2
			usage
			exit 1 ;;
	esac
done

command -v kubectl >/dev/null 2>&1 || { echo "kubectl not found in PATH" >&2; exit 1; }

if [[ -z "$POD" ]]; then
	POD="$(kubectl -n "$NAMESPACE" get pod -l "$SELECTOR" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')"
fi

if [[ -z "${POD:-}" ]]; then
	echo "No running pod found in namespace '$NAMESPACE' (selector: $SELECTOR)" >&2
	exit 1
fi

PAYLOAD='{"id":1,"method":"slim.request","params":["",["rescan","external","file:///freeradio"]]}'
ABORT_PAYLOAD='{"id":1,"method":"slim.request","params":["",["abortscan"]]}'

scanner_running() {
	kubectl -n "$NAMESPACE" exec "$POD" -c "$CONTAINER" -- sh -lc \
		"ps -ef | grep -q '[s]canner\\.pl'"
}

if scanner_running; then
	echo "Detected running scanner job."
	kubectl -n "$NAMESPACE" exec "$POD" -c "$CONTAINER" -- sh -lc \
		"ps -ef | grep '[s]canner\\.pl'"

	if [[ "$ABORT_RUNNING" -eq 1 ]]; then
		echo "Aborting running scan..."
		kubectl -n "$NAMESPACE" exec "$POD" -c "$CONTAINER" -- sh -lc \
			"curl -sS -X POST 'http://127.0.0.1:${RPC_PORT}/jsonrpc.js' -H 'Content-Type: application/json' -d '$ABORT_PAYLOAD'" >/dev/null
	fi

	if [[ "$WAIT_IDLE" -eq 1 ]]; then
		echo "Waiting for scanner to become idle (timeout ${WAIT_TIMEOUT_SECS}s)..."
		elapsed=0
		while scanner_running; do
			sleep 2
			elapsed=$((elapsed + 2))
			if [[ "$elapsed" -ge "$WAIT_TIMEOUT_SECS" ]]; then
				echo "Timed out waiting for scanner idle." >&2
				exit 2
			fi
		done
	fi
fi

echo "Triggering scan in pod: $NAMESPACE/$POD (container: $CONTAINER)"
kubectl -n "$NAMESPACE" exec "$POD" -c "$CONTAINER" -- sh -lc \
	"curl -sS -X POST 'http://127.0.0.1:${RPC_PORT}/jsonrpc.js' -H 'Content-Type: application/json' -d '$PAYLOAD'"

sleep "$WAIT_SECS"

echo
echo "--- scanner.log (tail $TAIL_LINES) ---"
kubectl -n "$NAMESPACE" exec "$POD" -c "$CONTAINER" -- sh -lc \
	"tail -n '$TAIL_LINES' /config/logs/scanner.log"
