#!/usr/bin/env bash
# Collect sensitive node diagnostics through temporary OpenShift debug pods.
set -uo pipefail
umask 077
prompt_color= timer_color= node_color= reset_prompt= reset_timer=
if [[ -z ${NO_COLOR:-} && ${TERM:-dumb} != dumb ]]; then
    if [[ -t 2 ]]; then prompt_color=$'\033[36m'; reset_prompt=$'\033[0m'; fi
    if [[ -t 1 ]]; then timer_color=$'\033[32m'; node_color=$'\033[34m'; reset_timer=$'\033[0m'; fi
fi


if ! command -v oc >/dev/null; then
    echo 'Error: oc is required.' >&2
    exit 1
fi
context=$(oc config current-context) || exit 1
namespace=$(oc config view --minify --context="$context" -o 'jsonpath={..namespace}') || exit 1
namespace=${namespace:-default}
printf '%sLocal directory for sosreports: %s' "$prompt_color" "$reset_prompt" >&2
read -r destination || exit 1
if [[ -z $destination || ! -d $destination || ! -w $destination ]]; then
    echo 'Error: provide an existing writable directory.' >&2
    exit 1
fi
destination=$(cd -- "$destination" && pwd -P) || exit 1
printf '%sRemove each node archive after verifying the local copy? [y/N] %s' "$prompt_color" "$reset_prompt" >&2
read -r remove_archive || exit 1
case $remove_archive in
    y|Y|yes|YES) remove_archive=yes ;;
    *) remove_archive=no ;;
esac
printf '%sCombine copied reports into one tar.gz archive? [y/N] %s' "$prompt_color" "$reset_prompt" >&2
read -r combine_reports || exit 1
case $combine_reports in
    y|Y|yes|YES) combine_reports=yes ;;
    *) combine_reports=no ;;
esac
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
total_start=$SECONDS
failed=0
node_count=0
reports=()
bundle_created=
while IFS= read -r node; do
    [[ -n $node ]] || continue
    ((node_count += 1))
    node_start=$SECONDS
    printf '%s=== %s ===%s\n' "$node_color" "$node" "$reset_timer"
    : > "$work/debug.log"
    oc --context="$context" debug "$node" --to-namespace="$namespace" -- sleep 86400 > >(tee "$work/debug.log" >&2) 2>&1 &
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
        failed=1
    else
        # Toolbox may ask whether to update an already cached image. Keep the
        # installed image; sos itself runs non-interactively with --batch.
        if printf 'n\n' | oc --context="$context" -n "$namespace" exec -i "$pod" -- chroot /host toolbox sos report --batch -e openshift --all-logs 2>&1 | tee "$work/sos.log"; then
            archive=$(grep -oE '/host/var/tmp/[^[:space:]]+\.tar\.(xz|gz|bz2|zst)' "$work/sos.log" | tail -n 1 || :)
            if [[ ! $archive =~ ^/host/var/tmp/sosreport-[^/]+\.tar\.(xz|gz|bz2|zst)$ ]]; then
                echo "Error: could not identify the generated archive for $node" >&2
                failed=1
            elif [[ -e $destination/${archive##*/} ]]; then
                echo "Error: local archive already exists: $destination/${archive##*/}" >&2
                failed=1
            elif oc --context="$context" -n "$namespace" cp "$pod:$archive" "$destination/${archive##*/}"; then
                echo "Copied to $destination/${archive##*/}"
                reports+=("${archive##*/}")
                if [[ $remove_archive == yes ]]; then
                    remote_hash=$(oc --context="$context" -n "$namespace" exec "$pod" -- sha256sum -- "$archive") || remote_hash=
                    local_hash=$(sha256sum -- "$destination/${archive##*/}") || local_hash=
                    if [[ -z $remote_hash || -z $local_hash || ${remote_hash%% *} != "${local_hash%% *}" ]]; then
                        echo "Error: checksum verification failed for $node; node archive retained" >&2
                        failed=1
                    elif oc --context="$context" -n "$namespace" exec "$pod" -- rm -- "$archive"; then
                        echo "Removed node archive $archive"
                    else
                        echo "Error: could not remove node archive $archive" >&2
                        failed=1
                    fi
                fi
            else
                echo "Error: copy failed for $node; archive remains on the node at ${archive#/host}" >&2
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
    elapsed=$((SECONDS - node_start))
    printf '%sTotal time for %s: %02d:%02d:%02d%s\n' "$timer_color" "$node" "$((elapsed / 3600))" "$((elapsed % 3600 / 60))" "$((elapsed % 60))" "$reset_timer"
done <<< "$nodes"
if [[ $combine_reports == yes ]]; then
    if (( ${#reports[@]} == 0 )); then
        echo 'Error: no copied reports to combine' >&2
        failed=1
    elif bundle=$(mktemp "$destination/openshift-sosreports-XXXXXXXX.tar.gz"); then
        if tar -C "$destination" -czf "$bundle" -- "${reports[@]}"; then
            bundle_created=$bundle
            echo "Combined reports: $bundle"
        else
            echo 'Error: failed to create combined archive' >&2
            rm -f -- "$bundle"
            failed=1
        fi
    else
        echo 'Error: could not create combined archive in destination' >&2
        failed=1
    fi
fi
total_bytes=0
sizes_valid=yes
for report in "${reports[@]}"; do
    if size=$(stat -c %s -- "$destination/$report"); then
        ((total_bytes += size))
    else
        echo "Error: could not determine size of $destination/$report" >&2
        sizes_valid=no
        failed=1
    fi
done
if [[ $sizes_valid == yes ]]; then
    printf '%sTotal copied report size: %s (%d bytes)%s\n' "$timer_color" "$(numfmt --to=iec-i --suffix=B "$total_bytes")" "$total_bytes" "$reset_timer"
fi
if [[ -n $bundle_created ]]; then
    if size=$(stat -c %s -- "$bundle_created"); then
        printf '%sCombined archive size: %s (%d bytes)%s\n' "$timer_color" "$(numfmt --to=iec-i --suffix=B "$size")" "$size" "$reset_timer"
    else
        echo "Error: could not determine size of $bundle_created" >&2
        failed=1
    fi
fi
printf '%sTotal nodes: %d%s\n' "$timer_color" "$node_count" "$reset_timer"
elapsed=$((SECONDS - total_start))
printf '%sTotal elapsed: %02d:%02d:%02d%s\n' "$timer_color" "$((elapsed / 3600))" "$((elapsed % 3600 / 60))" "$((elapsed % 60))" "$reset_timer"
exit "$failed"
