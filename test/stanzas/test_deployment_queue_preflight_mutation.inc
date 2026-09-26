;; Compile the production helper and a counterpart whose sole source change
;; omits the queue scan. This is test-only; neither binary has a bypass flag.
(rule
 (targets deployment_preflight_queue_omitted.ml deployment_preflight_queue_omitted.json)
 (deps test_deployment_queue_preflight_mutation.py ../bin/deployment_preflight_helper.ml)
 (action
  (run python3 %{dep:test_deployment_queue_preflight_mutation.py}
   --generate --source %{dep:../bin/deployment_preflight_helper.ml}
   --mutant-source deployment_preflight_queue_omitted.ml
   --evidence deployment_preflight_queue_omitted.json)))

;; Same explicit libraries as bin/dune's deployment_preflight_helper stanza.
(executable
 (name deployment_preflight_queue_omitted)
 (modules deployment_preflight_queue_omitted)
 (libraries
  masc
  masc.server
  masc.host_config
  masc.keeper_runtime
  masc.masc_schedule
  masc.masc_tool_blob_store
  masc.fusion_core
  masc.run_registry_core
  masc.masc_types
  masc.masc_core
  masc.config_dir_resolver
  masc.board_handlers
  fs_compat
  cmdliner
  unix
  yojson))

(rule
 (alias runtest-test_deployment_queue_preflight_mutation)
 (deps
  test_deployment_queue_preflight_mutation.py
  ../bin/deployment_preflight_helper.ml
  ../bin/deployment_preflight_helper.exe
  deployment_preflight_queue_omitted.ml
  deployment_preflight_queue_omitted.json
  deployment_preflight_queue_omitted.exe)
 (action
  (run python3 %{dep:test_deployment_queue_preflight_mutation.py}
   --source %{dep:../bin/deployment_preflight_helper.ml}
   --mutant-source %{dep:deployment_preflight_queue_omitted.ml}
   --evidence %{dep:deployment_preflight_queue_omitted.json}
   --normal %{dep:../bin/deployment_preflight_helper.exe}
   --mutant %{dep:deployment_preflight_queue_omitted.exe})))

(alias
 (name runtest)
 (deps (alias runtest-test_deployment_queue_preflight_mutation)))
