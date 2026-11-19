# OpenShift sosreport collection

Collect an sos report from every node in the current OpenShift kubeconfig context. The script uses `oc debug`, runs `sos report` through the node's toolbox, and copies each archive to the local machine with `oc cp`.

## Requirements

- Bash and an authenticated `oc` client with permission to list nodes and create and access privileged node debug pods in the current namespace.
- A working kubelet on each node, sufficient disk space on the nodes and the local host, and access to the RHEL support-tools image used by toolbox. Disconnected clusters may need a configured mirror.
- An existing writable local destination directory.

## Run

```bash
git clone https://github.com/syangsao/openshift_sosreports.git
cd openshift_sosreports
oc config current-context
./collect-openshift-sosreports.sh
```

Enter the destination directory when prompted. The script processes nodes sequentially and shows debug pod and sos output as it runs. It prints the elapsed time for each node, the total node count, total copied report size, combined archive size if created, and total elapsed time. It enables the `openshift` plugin and collects all logs; archives can be large. It continues to the next node after a failure and exits nonzero if any node fails.

Prompts, node headings, the node count, and elapsed times are colored when displayed on a terminal. Set `NO_COLOR` to disable colors; redirected output is plain text.

The script keeps the debug pod open for the copy and cleans it up afterward. It asks whether to remove each node's archive after copying; the default is to retain it in `/var/tmp`. If removal is selected, the script verifies the local copy's SHA-256 checksum before deleting the node archive. Failed copies or checksum checks leave the node archive in place. Toolbox uses an existing cached support-tools image when it asks whether to update it. Review toolbox and registry configuration if collection fails.

You can also choose to combine the reports successfully copied during the current run into one `openshift-sosreports-*.tar.gz` file in the destination directory. Individual reports remain in place. If some nodes fail, the combined archive contains only the successful copies, and the script still exits nonzero.

**Reports contain sensitive system information.** Restrict access to the destination and review archives before sharing them.

See [test run](TEST-RUN.md) for the observed cluster test.
