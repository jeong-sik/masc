; The nameserver a microVM guest on the default network is handed: which
; addresses a guest can use, who names it (runtime.toml [sandbox] before the
; host's resolver), and the boot that refuses when none is usable.
(test
 (name test_keeper_microvm_dns)
 (modules test_keeper_microvm_dns)
 (libraries masc_test_deps ipaddr))
