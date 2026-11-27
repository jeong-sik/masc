; Fixture seeder for scripts/harness_rbac_live_e2e_smoke.sh.
; Deliberately omits masc_test_deps so multi-account bootstrapping never
; publishes single-user runtime access.

(executable
 (name rbac_live_e2e_seed)
 (modules rbac_live_e2e_seed)
 (libraries
  eio
  eio.unix
  eio_main
  masc
  masc.auth
  masc.config
  masc.crypto_rng
  masc.fs_compat
  masc.masc_types
  masc.runtime
  masc.server
  unix
  yojson))
