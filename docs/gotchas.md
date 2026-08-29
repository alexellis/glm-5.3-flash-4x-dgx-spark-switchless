# Gotchas — failure modes and their fixes

Hard-won lessons from running this setup. Read this before your first bring-up;
re-read it the first time something behaves oddly.

---

## Fabric

- **Re-apply the fabric after every reboot AND after any docker churn.** The ring
  addressing, MTU, routes, and the `DOCKER-USER` iptables rules are runtime-only.
  A reboot wipes them; docker up/down rewrites `DOCKER-USER` and silently drops
  forwarded ring traffic. Run `scripts/fabric-setup.sh` again.
- **MTU 9000 on both rails, then restart the containers.** Leaving MTU at 1500
  gives you a working ring that runs all-reduce on 1500-byte packets — roughly
  **2.7× slower decode, with no error**. Set MTU 9000 and restart so NCCL
  re-inits at the new MTU. See [`fabric.md`](fabric.md).
- **A jumbo ping is not proof.** `ping -M do -s 8972 <peer>` can pass while the
  RDMA relay is broken. Only a completed NCCL collective (the model serving and
  passing the gate) proves the ring works.

---

## Launch

- **Order: workers 3 → 2 → 1 headless, then head 0.** The head opens the API and
  expects its workers already waiting at the rendezvous.
- **First-collective deadlock.** The switchless ring occasionally **deadlocks at
  the first ring all-reduce** — the logs freeze right after
  `Using PYNCCL all-reduce backends`, memory stays flat, there is **no error**,
  and the IB links all report `PORT_ACTIVE` / GID3 healthy. It is a state wedge,
  not a hardware fault. **Fix: tear down all four containers
  (`docker rm -f glm53_tp4` on every node) and relaunch.** It usually connects
  cleanly on the retry (NCCL init ~0.14 s, "Connected all rings"). A reboot is
  not normally needed, but re-run `fabric-setup.sh` first as a precaution.
- **Always cycle all four ranks together.** Recreating a single rank breaks the
  torch.distributed group. Tear down and relaunch all four.

---

## Memory / KV

- **KV pool capped at 12 GiB (`--kv-cache-memory 12884901888`).** This is
  deliberate. Chasing it higher risks an **OOM hard-hang** on a node — not a clean
  out-of-memory error, but a wedged node that usually needs a power-cycle. Leave
  it at 12 GiB unless you have a specific, tested reason.

---

## Serving / correctness

- **Container "Up" is not "serving".** `docker ps` "Up" and a `/v1/models` 200 are
  not sufficient. Weight load, torch.compile, and cudagraph warmup take a few
  minutes after the container starts. Gate before trusting it.
- **Gate with needle + tool-call + warm decode.** All three, every bring-up. See
  [`recipe.md`](recipe.md) §5. `scripts/gate.sh` runs them.
- **Cold first turns are not a regression.** The first requests after a start
  decode slowly and report `cached=0` — that is an empty prefix cache, not a
  fault. Warm it with a throwaway turn before quoting decode t/s, or you will
  misread a cold number as a regression.

---

## Client

- **GLM-5.3 reasoning turns can return nothing under a low output cap.** If your
  client hardcodes a small `max_output_tokens`, GLM can spend the whole budget
  inside `<think>` and never emit the deliverable. Give reasoning turns a generous
  output budget (see [`recipe.md`](recipe.md) §6 for the opencode-specific
  environment-variable fix, and the server-side `max_tokens`-floor alternative).

---

## Quick checklist

- [ ] `fabric-setup.sh` after **every reboot** and after **docker churn**.
- [ ] MTU **9000** on both rails, then restart containers (else ~2.7× slower, silent).
- [ ] Launch order: **workers 3 → 2 → 1, then head 0**.
- [ ] First collective can deadlock → **tear down all 4 + retry**.
- [ ] Always cycle **all four** ranks together.
- [ ] KV pool **12 GiB** — higher risks an OOM hard-hang.
- [ ] Gate with **needle + tool-call + warm decode**; a jumbo ping is not proof.
- [ ] Give reasoning turns a **generous output-token budget** or they land nothing.
- [ ] Cold first turns = empty prefix cache, **not** a regression — warm before quoting t/s.
