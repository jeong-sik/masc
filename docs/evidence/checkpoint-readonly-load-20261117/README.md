# Checkpoint snapshot loading without an encoding memo

Baseline: `ea0b8d1fd284fad784557373fd82e8565a774b10`. The three Core source files are bound by `source-manifest.json`. The native fixture compiles their complete baseline/candidate implementations, including both Objects MLIs, under isolated module names. Only dependency aliases are prefixed; there is no synthetic decoder or implementation copied into the test. `typing.json` records seven successful native compilations with OCaml 5.5.2 and fatal warnings 4/8/32/69. Existing prebuilt dependencies are distinct from a complete product build; `native-dependencies.json` records the compiler, explicit native archives/sibling `.a` files and selected CMIs. Their source equivalence to the baseline and exhaustive C/system-library provenance are not asserted.

`Checkpoint_objects.load` fills a memo with decoded messages **and their encoded bytes**. A caller that creates a memo solely for one read and then discards it does not need that encoded copy. The new `load_read_only` still reads and hashes every object, checks bundle slices, decodes every message, and checks the same counts, chains, segments and header. It keeps decoded messages rather than encoded entries and does not create the memo's arrays. The existing memo-loading path remains available and retains its reuse behavior. The adjacent existing MLI statement about a different memo was corrected to match existing behavior: a different memo encodes loaded records once; loaded bytes are not published unchecked to the process's encoding tables.

For a read-only bundle slice, the parser gets an owned byte buffer copied directly from that slice. Installed OCaml 5.5.2 `Lexing.from_string` differs by input only in `lex_buffer` and `lex_buffer_len`; the helper initializes an empty string lexer and replaces those public mutable fields with the slice's buffer/length. This avoids the intermediate `String.sub` string while retaining the same final-input lexer state. It neither copies the entire bundle for each message nor borrows a mutable/shared bundle buffer. A plain chunked `Lexing.from_function` prototype changed error coordinates near refill boundaries and was rejected.

## Native observations

`observed.json`: **105 assertions passed**, using synthetic data only. The test covers equal checkpoint wire results; preserved existing memo byte counts and subsequent saves; memo preservation after a failed read; open messages; segmented history; missing/corrupt objects; malformed message JSON, trailing bundle bytes and count/chain mismatches. Forty-six direct slice cases compare actual old/new codec results and exact errors, including blank/EOF input, large numbers, escaping, trailing junk and refill-boundary positions.

| Messages × text bytes | Baseline memo load allocation | Candidate memo load allocation | Read-only allocation |
| ---: | ---: | ---: | ---: |
| 4 × 0 | 60,152 B | 60,824 B | 60,048 B |
| 4 × 16 | 60,344 B | 61,016 B | 60,176 B |
| 32 × 128 | 282,456 B | 284,248 B | 275,344 B |
| 16 × 65,536 | 4,352,088 B | 4,353,240 B | 3,302,160 B |
| 16 × 262,144 | 16,955,800 B | 16,956,952 B | 12,760,144 B |

The generic loader adds small callback/record overhead to the preserved memo path (+672 B for four tiny messages, +1,152 B for 16 large messages). Read-only loading saves only 104/168 B for the two tiny cases. For the 4 MiB large-text fixture, it allocates about 24.7% less. This is a bounded source-function result, not an unconditional allocation or application-speed claim.

One offline union traversal of `(checkpoint, memo)` counts 8,396,496 reachable bytes for that large case. The read-only checkpoint alone counts 4,197,128 bytes. Individual overlapping roots are not added. In the ordinary discarded-memo caller, the baseline memo itself can die after loading; this comparison does not assert a permanent production leak.

The fixture also forces GC **inside its disposable read-object port** and samples live-word growth at object-read boundaries: 6,297,392 B baseline versus 3,150,408 B read-only for the large case. These are sampled boundaries, not a peak-memory measurement or a server-heap attribution. All CPU numbers in the JSON include this instrumentation and sequential execution order; no CPU improvement is claimed. The in-memory object port omits filesystem-read allocations.

## Replay and limits

`replay.py --native-config CONFIG.json --out IGNORED_OUTPUT` accepts explicit existing compile/link argv prefixes. The compile prefix must supply required include paths and fatal warnings, and include `-I {out}`. The link prefix must supply existing dependency archives and `-o {out}/test_checkpoint_readonly.exe`. `{out}` is replaced without shell evaluation. The helper verifies frozen source hashes, compiles whole source bodies under the documented aliases, and runs under a disposable `MASC_BASE_PATH` with the HOME-write guard escape absent. The local observed run used a private environment configuration; this configurable helper was actually used for that run, but it does not provision or rebuild dependencies. Dependency identity must be checked separately when reproducing the recorded environment.

No Dune, product build, CI, server request, provider call or live-process GC/heap walk was performed. The native result is Core API evidence. MASC caller integration and its separate typing limitation are documented in the caller layer. No claim is made about whole-product integration, installed binaries, current large RSS or all checkpoint CPU samples.
