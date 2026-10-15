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

## After a rank exits

This recipe has no runtime watchdog: `rank-launcher.sh` starts each container
with `--restart no`, and `cluster-up.sh` does not keep running after its gate
passes. A separate site-installed supervisor may behave differently. Before
rerunning `cluster-up.sh`, capture the exited container on the affected node;
the start script removes stale TP4 containers and their logs.

```bash
docker inspect glm53_tp4 --format \
  'status={{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} finished={{.State.FinishedAt}}'
docker logs --timestamps --tail 200 glm53_tp4
journalctl -k -b --no-pager | grep -Ei 'out of memory|oom|nvrm|xid|mlx|infiniband' | tail -80
```

Replace `glm53_tp4` if you changed `CONTAINER_NAME` in `cluster.env`.
Run the same checks on the other ranks if the cause is not clear from rank 0.
Exit 137 alone does not establish an OOM: an operator stop or forced removal
can also produce it. Keep the timestamps and inspect `OOMKilled` and the host
kernel log before assigning a cause.

To stop TP4 and deliberately return to the site's configured supervised stacks:

```bash
./scripts/cluster-down.sh --restore-defaults
```
