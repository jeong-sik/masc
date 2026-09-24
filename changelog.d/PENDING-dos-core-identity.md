### Added

- `masc_dos_load`, `masc_dos_screen` and the `/health` build object
  (`ocaml_dos_core`) name the linked ocaml-dos core: the source digest the
  core computed at its build, the digest pinned for `OCAML_DOS_SHA`, and a
  `matches_pin` flag. A server built against an older opam copy of the core
  no longer looks identical to one built against the pin (#38826).
