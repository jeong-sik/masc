; Boot-time keeper meta canonicalization
; (Keeper_meta_store.canonicalize_persisted_meta_files +
; Keeper_meta_json.unknown_keeper_meta_keys): #23929's continuity purge left
; retired keys in .masc/keepers/*.json, re-warning on every read; the boot
; pass converges every persisted file onto the canonical serializer key set.

(test
 (name test_keeper_meta_canonicalize)
 (modules test_keeper_meta_canonicalize)
 (libraries masc_test_deps))
