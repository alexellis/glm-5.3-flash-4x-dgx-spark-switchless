# RigMark receipts

These are RigMark outputs from controlled runs against the raw vLLM endpoints.
They contain unedited generated output and complete timing samples, not only
headline medians. Site-specific hostnames in receipt metadata are normalised
to rank labels before publication.

| Receipt | SHA-256 |
|---|---|
| `glm53-redhat-nvfp4-tp4-static-k7-low-20260905T191914Z.json` | `79ff5182b439eadbc70510bc2fdf7cf2d6f112350b9f1081d5f607184d186ff2` |
| `glm53-libert-nvfp4-tp2-adaptive-low-20260905T183114Z.json` | `c53c3c7cfc982b19c78a2af915f7d168ce0cb9cac9546a39ba1c328523951326` |
| `glm53-nccl-standalone-master-tp4-20260912.json` | `f518209fd60e767d9c120ba071aace2a758bca0dc4876b855177aa8d90513d3d` |
| `glm53-nccl-legacy-hardened-tp4-20260912.json` | `48d69adca14e76dabc073c7c72e7600f77a43ae5ffd3f213c12de6cad3b82956` |
| `glm53-nccl-v0.0.1-tp4-20260912.json` | `7f9c9cc1f617f5e183950127f1e3b716edec4dc23c731876366fde64dea89b46` |

Both receipts identify clean RigMark Git revision
`d8353e93b274e8d880ab14a5df2a55c87d7bee16`, protocol 1.0.0, and comparison ID
`2026-09-05-glm-tp2-tp4-rigmark-v1`. RigMark's strict comparison accepts the
pair without `--allow-mismatch`.

Reproduce the table from a RigMark checkout:

```bash
./rigmark compare --card \
  PATH/TO/glm53-libert-nvfp4-tp2-adaptive-low-20260905T183114Z.json \
  PATH/TO/glm53-redhat-nvfp4-tp4-static-k7-low-20260905T191914Z.json
```

The 12 September receipts are a strict NCCL-only A/B at TP4. Both identify
clean RigMark revision `d8353e93b274e8d880ab14a5df2a55c87d7bee16`, protocol
1.0.0, and comparison ID `2026-09-12-nccl-patch-ab-v1`. Hardware, serving
runtime, model, drafter, cache, scheduler, template, and request settings were
held constant; only the verified NCCL candidate changed.

```bash
./rigmark compare --card \
  PATH/TO/glm53-nccl-standalone-master-tp4-20260912.json \
  PATH/TO/glm53-nccl-legacy-hardened-tp4-20260912.json
```

Both passed 15/15 output gates. The comparison is a practical tie: hardened
is -2% code, -1% prose, +3% structured, +1% 64k cold prefill, +2% cached
replay, and -3% C4 aggregate throughput.

The third receipt is the final regression arm using the public
`switchless-nccl` v0.0.1 release binary, SHA-256 `78cb8387…`. Compare it to the
local hardened qualification arm:

```bash
./rigmark compare --card \
  PATH/TO/glm53-nccl-legacy-hardened-tp4-20260912.json \
  PATH/TO/glm53-nccl-v0.0.1-tp4-20260912.json
```

Both passed 15/15 gates. Release versus local hardened was +0.4% code, +2.0%
prose, -0.1% structured, -0.6% 64k cold prefill, and -0.7% cached replay. C4
was +10.8%, but the three-round ranges overlapped heavily; concurrency medians
are retained as observed scheduler variance, not attributed to the binary.
