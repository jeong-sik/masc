# Speaker authority before display name

Base9cc461ec18be1779d0c39b7d2490b28bbe64ff03.

History user speaker classification read nonblank speaker_name first, so even
explicit Owner authority became Named (external sender in TUI). Unknown or
missing authority with a name also became a named identity despite the existing
comment saying unrecognised authority stays unresolved. Connector surface/name
are presentation/correlation facts, not owner authority.

Use existing Keeper_chat_store.authority_of_label closed Owner/External/Keeper
codec. Owner becomes Operator regardless of name. External/Keeper retain named
speaker when usable, otherwise unresolved ID. Absent/unknown authority stays
unresolved even with a display name. Original content/source/turn ownership is
unchanged; no new substring or inferred-author heuristic added.

Direct bounded probe /tmp/masc-speaker-authority-20261012/{probe.py,parent.ml,current.ml,parent.log,current.log}.
Actual shared authority type/label codec and actual history field helpers +
selected speaker classification block interpreted. Minimal History speaker type;
no full history row/parser/TUI integration or real persisted corpus executed.
Parent exit2: owner name overrode explicit operator authority.
Current exit0: owner wins, external/keeper names preserved, unknown/missing
stays unresolved, blank external and id-as-name stay unresolved. Fixture adds
classification decisions, unexecuted; no wording/layout/row-order checks added.

Production/fixture syntax-only parsing and diff check pass. No full typecheck,
build/CI/provider/runtime/UI/screenshots/installation/formal approval/merge proof.
Full multi-provider speech/thinking/tool/interleaving/broadcast goal remains active.
