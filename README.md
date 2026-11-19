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
./collect-sosreports.sh
```

Enter the destination directory when prompted. The script processes nodes sequentially and shows debug pod and sos output as it runs. It prints the elapsed time for each node and the total elapsed time at the end. It enables the `openshift` plugin and collects all logs; archives can be large. It continues to the next node after a failure and exits nonzero if any node fails.

The script keeps the debug pod open for the copy and cleans it up afterward. Reports are also left in `/var/tmp` on each node. Toolbox uses an existing cached support-tools image when it asks whether to update it. Review toolbox and registry configuration if collection fails.

**Reports contain sensitive system information.** Restrict access to the destination and review archives before sharing them.

See [test run](TEST-RUN.md) for the observed cluster test.
