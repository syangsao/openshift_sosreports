# Test run

On 2026-11-19, `collect-sosreports.sh` was run against the current kubeconfig context for the `luke` OpenShift cluster. It used the `default` debug namespace and copied reports into a local `sosreports/` directory.

| Node | Result |
| --- | --- |
| `arbiter.syangsao.net` | Report generated and copied; sos reported 26.03 MiB. |
| `control01.syangsao.net` | Report generated and copied; local archive approximately 161 MiB. |
| `control02.syangsao.net` | Report generated and copied; sos reported 164.81 MiB. |

The run completed successfully in approximately 16 minutes using sos 4.11.2 and `--all-logs`. Toolbox used the cached support-tools image rather than updating it. Sos reported that some commands were skipped because required services or kernel modules were unavailable; missing configuration files were also reported. The reports themselves are not included in this repository.
