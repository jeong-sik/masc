# Keeper settings SSOT repair

The old module-load values ignored TOML loaded during server startup. Eight settings now read the existing env > boot override > default authority at the consumer boundary. The settings projection uses those same readers. Environment-only constants were not changed.

`baseline-readers.txt` and `candidate-readers.txt` come from separate OCaml 5.5.1 native processes. Each process loaded the production config modules, then wrote the eight values to the real `Config_boot_overrides` store. The old readers stayed at all eight defaults; the repaired readers returned all eight configured values. A later explicit environment value also won in the repaired process. `reader-probe.ml` is the exact candidate probe. Changed config modules were compiled in a temporary directory and linked with cached dependency objects; hashes and scope are in `manifest.json`.

This does not execute server boot or the TOML-to-file-rotation path. `test_runtime_toml_overrides` now contains that integration case: actual temporary TOML load, settings projection, Runtime_params consumers, 17-byte metrics rotation, two backups, and environment precedence. It remains unrun under the external coding session's no-Dune/full-build workflow. Changed OCaml sources pass parsing; diff whitespace passes. Independent source review caught and verified repair of alias-based test callers.
