### Added

- `masc_msx_meta` reports which ocaml-msx core this server linked — the core's own source digest, the digest at the CI pin, and whether they match — the way the DOS lane's core identity already does. `masc_msx_checkpoint_info` reads a checkpoint slot's metadata (format version, saved-at time, the core digest that wrote it, media names, saved input edge count) without restoring it, so asking what a slot holds no longer replaces the machine every spectator watches (#<PR>).
