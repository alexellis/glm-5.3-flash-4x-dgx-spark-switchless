# Operator runbook

The site transition is two commands. Do not launch ranks by hand unless
diagnosing a failed preflight.

```bash
cp scripts/cluster.env.example scripts/cluster.env
# Edit the local inventory, service units, remote paths, and expected hashes.

./scripts/cluster-up.sh
./scripts/cluster-status.sh
./scripts/cluster-down.sh
```

`cluster-up.sh` owns the order that caused earlier manual failures:

1. Stop supervised competing stacks before touching Docker.
2. Remove all four stale TP4 containers.
3. Reapply the runtime-only fabric after the final Docker teardown.
4. Verify host identity, launcher/template hashes, empty GPUs, and RDMA links.
5. Launch ranks 3, 2, and 1 before rank 0.
6. Require shard progress within 90 seconds and report every five seconds.
7. Require the API within 15 minutes and report progress every 15 seconds.
8. Run the long-context, tool-call, image, and decode gate.

The script never retries indefinitely. On a collective or start-up failure it
prints the tail from every rank and exits with the containers preserved for
diagnosis.

To stop TP4 and deliberately return to the site's configured supervised stacks:

```bash
./scripts/cluster-down.sh --restore-defaults
```
