#!/usr/bin/env bash
# Collect sensitive node diagnostics through temporary OpenShift debug pods.
set -uo pipefail
umask 077

if ! command -v oc >/dev/null; then
    echo 'Error: oc is required.' >&2
    exit 1
fi
context=$(oc config current-context) || exit 1
namespace=$(oc config view --minify --context="$context" -o 'jsonpath={..namespace}') || exit 1
namespace=${namespace:-default}
read -r -p 'Local directory for sosreports: ' destination
if [[ -z $destination || ! -d $destination || ! -w $destination ]]; then
    echo 'Error: provide an existing writable directory.' >&2
    exit 1
fi
destination=$(cd -- "$destination" && pwd -P) || exit 1
nodes=$(oc --context="$context" get nodes -o name) || exit 1
if [[ -z $nodes ]]; then
    echo 'Error: no nodes found.' >&2
    exit 1
fi
work=$(mktemp -d) || exit 1
debug_pid=
cleanup() {
    if [[ -n $debug_pid ]]; then
        kill "$debug_pid" 2>/dev/null || :
        wait "$debug_pid" 2>/dev/null || :
    fi
    rm -rf -- "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "Context: $context; debug namespace: $namespace; destination: $destination"
failed=0
while IFS= read -r node; do
    [[ -n $node ]] || continue
    echo "=== $node ==="
    : > "$work/debug.log"
    oc --context="$context" debug "$node" --to-namespace="$namespace" -- sleep 86400 >"$work/debug.log" 2>&1 &
    debug_pid=$!
    pod=
    for ((attempt=0; attempt<180; attempt++)); do
        pod=$(awk '/Starting pod\// {sub(/^.*Starting pod\//, ""); sub(/ .*/, ""); print; exit}' "$work/debug.log")
        if [[ -n $pod ]] && oc --context="$context" -n "$namespace" get pod "$pod" -o 'jsonpath={.status.containerStatuses[0].ready}' 2>/dev/null | grep -qx true; then
            break
        fi
        if ! kill -0 "$debug_pid" 2>/dev/null; then break; fi
        sleep 1
    done
    if [[ -z $pod ]] || ! oc --context="$context" -n "$namespace" get pod "$pod" -o 'jsonpath={.status.containerStatuses[0].ready}' 2>/dev/null | grep -qx true; then
        echo "Error: debug pod did not become ready for $node" >&2
        cat "$work/debug.log" >&2
        failed=1
    else
        # Toolbox may ask whether to update an already cached image. Keep the
        # installed image; sos itself runs non-interactively with --batch.
        if printf 'n\n' | oc --context="$context" -n "$namespace" exec -i "$pod" -- chroot /host toolbox sos report --batch -e openshift --all-logs 2>&1 | tee "$work/sos.log"; then
            archive=$(grep -oE '/host/var/tmp/[^[:space:]]+\.tar\.(xz|gz|bz2|zst)' "$work/sos.log" | tail -n 1 || :)
            if [[ -z $archive ]]; then
                echo "Error: could not identify the generated archive for $node" >&2
                failed=1
            elif [[ -e $destination/${archive##*/} ]]; then
                echo "Error: local archive already exists: $destination/${archive##*/}" >&2
                failed=1
            elif oc --context="$context" -n "$namespace" cp "$pod:$archive" "$destination/${archive##*/}"; then
                echo "Copied to $destination/${archive##*/}"
            else
                echo "Error: copy failed for $node; archive remains at $archive on the debug pod" >&2
                failed=1
            fi
        else
            echo "Error: sos report failed for $node" >&2
            failed=1
        fi
    fi
    kill "$debug_pid" 2>/dev/null || :
    wait "$debug_pid" 2>/dev/null || :
    debug_pid=
done <<< "$nodes"
exit "$failed"
