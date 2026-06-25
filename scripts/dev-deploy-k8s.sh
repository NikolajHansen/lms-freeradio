#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

NAMESPACE="lyrion"
SELECTOR="app=lyrion"
POD=""
CONTAINER="lyrion"
TARGET_DIR="/config/cache/InstalledPlugins/Plugins/FreeRadio"
RESTART=0

usage() {
	cat <<'EOF'
Package and deploy FreeRadio directly to a running Lyrion pod.

Usage:
  scripts/dev-deploy-k8s.sh [options]

Options:
  -n, --namespace <ns>     Kubernetes namespace (default: lyrion)
  -l, --selector <label>   Pod label selector (default: app=lyrion)
  -p, --pod <name>         Pod name (overrides selector lookup)
  -c, --container <name>   Container name for kubectl cp/exec (default: lyrion)
  -t, --target <path>      Plugin target dir in container
                           (default: /config/cache/InstalledPlugins/Plugins/FreeRadio)
  -r, --restart            Restart pod after deploy (delete selected pod)
  -h, --help               Show this help

Examples:
  scripts/dev-deploy-k8s.sh
  scripts/dev-deploy-k8s.sh --restart
  scripts/dev-deploy-k8s.sh -n lyrion -l app=lyrion
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
		-t|--target)
			TARGET_DIR="$2"; shift 2 ;;
		-r|--restart)
			RESTART=1; shift ;;
		-h|--help)
			usage; exit 0 ;;
		*)
			echo "Unknown option: $1" >&2
			usage
			exit 1 ;;
	esac
done

command -v kubectl >/dev/null 2>&1 || { echo "kubectl not found in PATH" >&2; exit 1; }

echo "Packaging plugin ZIP..."
bash "$ROOT/scripts/package.sh" >/dev/null

VERSION=$(grep -oP '<version>\K[^<]+' "$ROOT/install.xml")
ZIP_PATH="$ROOT/lms-freeradio-${VERSION}.zip"
if [[ ! -f "$ZIP_PATH" ]]; then
	echo "Expected ZIP not found: $ZIP_PATH" >&2
	exit 1
fi

if [[ -z "$POD" ]]; then
	POD="$(kubectl -n "$NAMESPACE" get pod -l "$SELECTOR" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')"
fi

if [[ -z "${POD:-}" ]]; then
	echo "No running pod found in namespace '$NAMESPACE' (selector: $SELECTOR)" >&2
	exit 1
fi

echo "Deploying to pod: $NAMESPACE/$POD (container: $CONTAINER)"

TARGET_PARENT="$(dirname "$TARGET_DIR")"
REMOTE_TMP="$TARGET_PARENT/.freeradio-deploy-$$"
BACKUP_DIR="${TARGET_DIR}.bak.$(date +%s)"

kubectl -n "$NAMESPACE" exec "$POD" -c "$CONTAINER" -- sh -lc "mkdir -p '$REMOTE_TMP'"
kubectl -n "$NAMESPACE" cp --no-preserve "$ZIP_PATH" "$POD:$REMOTE_TMP/" -c "$CONTAINER"
kubectl -n "$NAMESPACE" cp --no-preserve "$ROOT/Plugins/FreeRadio" "$POD:$REMOTE_TMP/FreeRadio" -c "$CONTAINER"
# install.xml lives at repo root; copy it into the plugin dir so PluginManager picks up <importmodule>
kubectl -n "$NAMESPACE" cp --no-preserve "$ROOT/install.xml" "$POD:$REMOTE_TMP/FreeRadio/install.xml" -c "$CONTAINER"

kubectl -n "$NAMESPACE" exec "$POD" -c "$CONTAINER" -- sh -lc "
	set -e
	if [ -d '$TARGET_DIR' ]; then
		rm -rf '$BACKUP_DIR'
		mv '$TARGET_DIR' '$BACKUP_DIR'
	fi
	mv '$REMOTE_TMP/FreeRadio' '$TARGET_DIR'
	rm -rf '$REMOTE_TMP'
"

echo "Deployed FreeRadio to: $TARGET_DIR"
echo "Local ZIP artifact: $ZIP_PATH"

if [[ "$RESTART" -eq 1 ]]; then
	echo "Restarting pod $POD..."
	kubectl -n "$NAMESPACE" delete pod "$POD" --wait=false >/dev/null
	echo "Pod deleted; controller will recreate it."
fi

echo "Done."
