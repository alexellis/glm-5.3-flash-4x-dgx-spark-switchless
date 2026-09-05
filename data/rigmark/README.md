# RigMark receipts

These are unedited RigMark outputs from controlled runs against the raw vLLM
endpoints. They contain generated output and complete timing samples, not only
headline medians.

| Receipt | SHA-256 |
|---|---|
| `glm53-redhat-nvfp4-tp4-static-k7-low-20260905T191914Z.json` | `79ff5182b439eadbc70510bc2fdf7cf2d6f112350b9f1081d5f607184d186ff2` |
| `glm53-libert-nvfp4-tp2-adaptive-low-20260905T183114Z.json` | `c53c3c7cfc982b19c78a2af915f7d168ce0cb9cac9546a39ba1c328523951326` |

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
