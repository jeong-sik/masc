(test
 (name test_keeper_toml_loader)
 (modules test_keeper_toml_loader)
 ; masc.fs_compat because the staged-write failure is one of its own:
 ; edit_keeper_toml_fields_strict_staged returns Fs_compat's
 ; atomic_replace_failure, so anything that reports the failure has to link
 ; the module that names it. #31230 removed the wrapper that used to spell it
 ; for callers, which is the right direction -- the dependency was always
 ; there and is now written down.
 (libraries alcotest masc.fs_compat masc.keeper_toml))
