# Antigravity native block ownership

Base: `a4deba5a546bd6b06edcdaf9c228d88e8f9836d1`.

The runtime step decoder permits an absent step index and emits a native
observation with no identity. The Keeper adapter previously opened an anonymous
block, while its finish path only closes named identities. Repeated Active
updates also emitted repeated starts for the same live index.

The adapter now opens a block only for a named identity absent from the live
index map. The map is populated before publication. Unnamed and repeated raw
observations remain recorded; native action observation remains unchanged.
Completion still closes only the matching named block.

The existing CLI protocol fixture now repeats its Active tool update. Its live
native block count remains one; its raw observation count includes both updates
on both fixture turns. This is a stream event contract check, not a TUI layout
or text check.

Validation: `git diff --check` and `ocamlc -stop-after parsing` for the changed
adapter and fixture both exited 0. Parsing proves syntax only. The fixture has
not been executed; no local Dune build, CI, installed runtime, or screenshot
verification was performed. Independent review is requested separately.

Remaining: terminal-turn cleanup of unfinished native blocks and all provider
replay/identity lifecycle cases still require investigation. This change does
not establish overall chat correctness.
