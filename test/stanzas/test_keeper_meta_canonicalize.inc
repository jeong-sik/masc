; Boot-time keeper meta canonicalization
; (Keeper_meta_store.migrate_retired_keeper_meta_keys +
; Keeper_meta_json.unknown_keeper_meta_keys): #23929's continuity purge left
; retired keys in .masc/keepers/*.json, re-warning on every read; the boot
; pass removes only the explicitly retired keys from every persisted file.

(test
 (name test_keeper_meta_canonicalize)
 (modules test_keeper_meta_canonicalize)
 (libraries masc_test_deps))
