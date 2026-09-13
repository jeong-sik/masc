# DOS value changes through optional Lane packages

This small export proves three recorded outcomes on a frozen host: an actual
DOS guest changed from 0 to 1 and a separate package derived +1/up; removing
one derived package preserved the same DOS owner's progress; and the selected
metric evidence remained readable after final detach. It is historical evidence,
not a new execution or a qualification of today's deployment.

| Input | Exact source |
| --- | --- |
| Native host | `97aa42db44586bf29160fc9895cc2eb6903352db` |
| Dashboard | `4d4889433d26c390232d8affaa62200e1c5ccfe4` (same Dashboard subtree as that host) |
| New value-difference package/image | `4e45af54e726776838a1da01b33e2e1c7050b08b`; [image CI](https://github.com/jeong-sik/masc/actions/runs/34714170036) |
| DOS execution package/image | `e0d4e0c35ae9b550d53a952c3340709f2deac4c6`; [DOS CI](https://github.com/jeong-sik/masc/actions/runs/34699775204) |
| DOS named-output manifest | `97aa42db44586bf29160fc9895cc2eb6903352db`; adds the `guest` output, with execution bytes from the DOS source above |
| Statistics package/image | `a534bd96e36106df1a2bfc6a8a352ff342b27e98`; [image CI](https://github.com/jeong-sik/masc/actions/runs/34697003041) |

The native executable SHA-256 was
`c543d77522e8ca109184c66f9fdf02bc57f765169663ccc703f89d6b8b8162d2`.
Source labels are recorded separately from package revisions and actor identity.
The new package used the existing TOML `lane_output` bindings:
DOS `guest` → value-difference `difference` → statistics.
No host dispatcher or domain-specific Dashboard change was made for the metric.

## Three inspectable claims

| Claim | Original bytes in the archive |
| --- | --- |
| **0→1 becomes +1/up with both original endpoints.** | `evidence/0008.raw` identifies the initial owners; `0012/0013` hold the exact action request and confirmation; `0029.raw` names the frozen metric row. Its original metric record, both producer packets, both DOS records, raw STATE.BIN and VGA blobs are included. |
| **Derived removal preserves the same DOS owner.** | `0030/0031` remove only statistics, then `0033/0034/0035` show counter 2 with the original DOS and metric owners. `0042` identifies restored statistics; `0043/0044` remove only the metric. `0046/0047/0048` show counter 3 with the same DOS and restored-statistics owners, no statistics row, incomplete input and an unknown cursor. |
| **The frozen metric survives final detach.** | `0067.raw` records all five historical workers detached; `0068.raw` still contains the exact selected +1 row. The original frozen bundle and referenced observation bytes resolve by SHA-256. `summary.json` records zero server exit and normal absence for all five containers, without force removal. |

Each numeric label means `evidence/<number>.json` (request/status/hash receipt)
and `.raw` (unchanged response body). The [manifest](manifest.json) maps all 72
archived files to their original relative paths, lengths, SHA-256 and purpose.
Thirteen content-addressed blobs include packets, guest state, VGA images,
guest build digests and the frozen evidence bundle. A `.json` store suffix does
not imply JSON content; the verifier reads raw bytes before interpreting them.

The actual browser captures show [the +1 fields](value-plus-one.png),
[missing metric coverage](metric-missing.png), and
[the retained metric after detach](frozen-after-detach.png).
Their hashes are joined to the original browser response/capture records.

## Offline verification

With Python 3 and Pillow available, run:

```sh
python3 verify.py
python3 negative_controls.py
```

The reader does not extract archive paths, use the network, import the product,
or open paths contained in recorded responses. It checks archive/file/screenshot
hashes, endpoint source identity against the metric binding, nonempty and unique
upstream coverage, original endpoint and named-port identity, unchanged DOS ownership,
request→receipt→actual executor, all pixels of the four selected 320×200 VGA
states (0–3), honest missing input, final Slice membership and recorded cleanup.
[verification.json](verification.json) contains the result.

Five [negative controls](negative-controls.json) change only in-memory copies:
a replaced DOS executor, a fabricated zero count for missing input, a lost
frozen row, an endpoint source that differs from its binding, and empty upstream
coverage. The endpoint controls rehash the changed retained observation, frozen
bundle and HTTP receipt, then require the exact source/coverage rejection. They
therefore reach those semantic checks beyond earlier digest and row-equality
checks. These corrupted inputs are not runtime observations.
Optimized Python execution is rejected because assertions must remain enabled.

Authentication files, login receipts, tokens, runtime configuration files,
executables, image archives and unselected screenshots are excluded. Original
absolute paths inside selected responses remain provenance; they are never
opened by the offline reader. Source labels and source-file digests in the
manifest derive from the independently audited run, with the original process
record's SHA recorded; that path-bearing record is not exported. This small
bundle does not reauthenticate CI artifacts or the executable itself.

Other rows in the original Slice responses can reference material outside this
selected export. This verifier promises only the three claims above, not a full
history export. The broader run also exercised same-cursor rereads and metric
reinstallation; this smaller bundle does not independently qualify those paths.
No metric row in this actual run crossed an intervening input gap. No complete
interval/event total, causal inference, productivity gain, Keeper reasoning,
commercial game compatibility, performance isolation or production deployment
is claimed. The guest is the project's homebrew DOS counter/VGA program.
