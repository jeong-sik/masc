; A keeper's microVM guest size: the typed spelling, the per-dimension
; resolution against the runtime.toml [sandbox] default, the keeper TOML
; fields, and the decision to adopt or replace a running guest.
(test
 (name test_keeper_microvm_guest_size)
 (modules test_keeper_microvm_guest_size)
 (libraries masc_test_deps))
