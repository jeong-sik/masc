# Muse completed item authority

Base: `267c83d841a676082146f2038b263959adbfd232`.

The shared stream replay fix did not protect the Muse runtime result. Every
agent Item_completed still overwrote final_text. A replay of m1 after completed
m2 could therefore return m1 as the durable reply although live consumers ignored
its repeated completion.

Muse turn state now retains the typed completed agent item by exact wire ID.
An identical completed item is a no-op for stream publication and final_text.
A changed completed snapshot rejects with Protocol_error; an Item_started for a
completed agent identity also rejects. First single-shot completions remain
accepted, since MSP permits an item that never opened. The scope is agent
messages only; native tools and compaction are not implicitly covered.

Two wire-process fixtures were added: m1 completion, m2 completion, m1 replay
must return m2 and publish each identity once; completed m1 followed by a restart
must reject at item/started. These tests have not been executed.

Validation: syntax-only parsing passed for runtime and fixture, and whitespace
checks passed. No Dune build, provider execution, CI, formal approval, installation
or screenshot verification is claimed. Independent source review requested.

Remaining: delayed first completion of an older item, divergent snapshots at
other provider boundaries, completed native replay and full runtime/UI proof.
