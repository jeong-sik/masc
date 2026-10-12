# Event queue transition and wire boundary

PR #42095. Base c0878f76f77e5737587b099e77526da2e474e9c0.
Code head 393fc7cece104b5111cba0bbe9b2d61b18459d11.

The original 2280-line module mixes immutable durable transitions, strict current JSON decoding and schedule occurrence projection. Its private canonical core owns state data, exact identity/replay rules and admission validation (1321 lines). The private wire owner reuses those same validators for current snapshots, full receipts, compact witnesses and transition outbox entries (818 lines). The public module retains schedule occurrence projection and the existing interface (155 lines).

Both private modules belong to the separate masc.keeper_runtime library; they are not modules of the parent masc library. The core interface exposes the immutable state record internally to its wire owner. The unchanged public keeper_event_queue_state.mli keeps t abstract. These source/type-check results do not establish installation visibility; no installation was performed.

Core source is byte-identical to the original prefix after moving the schema constant and its adjoining blank line to wire and normalizing its final newline. Wire source is byte-identical to the original codec block after adding its core import, Result binding and moved schema constant. Schedule projection tail and public interface are byte-identical. No parser policy, field, state transition, storage effect or compatibility reader was added.

Focused build `opam exec -- dune build test/test_keeper_event_queue_state_v2.exe` completed exit 0. The first build failed because the private modules were registered in the parent library; they were moved to their owning library before successful compilation.

Existing executable `_build/default/test/test_keeper_event_queue_state_v2.exe --color=never` completed exit 0: run 8TTVI8B1, 39 PASS. Tests cover strict current schema and optional scope decode, exact source incarnation, terminal completion/failure replay, real-file durable reload and WAL recovery, uncertain rename durability, schedule occurrence projection and state-change observation. Persistence cases use isolated temporary directories, not live Keeper state.

Evidence does not claim full CI, deployment, installation, live runtime behavior, formal GitHub approval or merge. The baseline candidate remains partially improved pending deeper semantic audit. Falling below 2000 lines does not complete its campaign scope.
