(** Regression: [warn_unknown_keeper_meta_keys] dangling-then bug.

    Before fix:
      [if unknown <> [] then E1 ; E2]
    parsed as [(if cond then E1) ; E2], so the [Log.Keeper.warn] sequel
    fired on every call, producing the spam line
      "keeper meta <path> has unknown keys: "
    (empty tail = String.concat ", " []) at every dashboard tick across
    14 keepers — observed live 2026-05-05 ~01:50 KST.

    The Otel_metric_store counter [metric_keeper_meta_json_failures] with
    label site=unknown_keys is the only durable side-effect we can
    assert from outside the logger; the structural fix protects both
    the counter and the warn line, so a green counter assertion is
    sufficient evidence that the warn line is also gated. *)

open Masc

let counter_total () =
  Otel_metric_store.metric_total Keeper_metrics.(to_string MetaJsonFailures)

let canonical_only_meta_json () =
  (* Build an `Assoc whose every key is in [canonical_keeper_meta_key_names].
     Values are placeholders — [warn_unknown_keeper_meta_keys] inspects keys
     only. *)
  let placeholder = `String "x" in
  `Assoc
    (List.map
       (fun key -> (key, placeholder))
       Keeper_meta_json.canonical_keeper_meta_key_names)

let test_no_counter_tick_when_all_keys_canonical () =
  let before = counter_total () in
  Keeper_meta_json.warn_unknown_keeper_meta_keys
    ~path:"/test/canonical-only.json"
    (canonical_only_meta_json ());
  let after = counter_total () in
  Alcotest.(check (float 0.0001))
    "metric_keeper_meta_json_failures must not increment when every key is \
     canonical (regression: dangling-then bug fired warn + counter on every \
     call)"
    before
    after

let test_self_model_keys_are_canonical () =
  let before = counter_total () in
  Keeper_meta_json.warn_unknown_keeper_meta_keys
    ~path:"/test/self-model.json"
    (`Assoc
      [ ("name", `String "self-model")
      ; ("agent_name", `String "self-model")
      ; ("trace_id", `String "trace-self-model")
      ; ("tool_access", `List [])
      ; ("instructions", `String "preserve operator guidance")
      ]);
  let after = counter_total () in
  Alcotest.(check (float 0.0001))
    "self-model keys are canonical persisted keeper meta keys"
    before
    after

let test_counter_ticks_on_genuine_unknown_key () =
  (* Sanity: the warn path still fires when a real unknown key is present. *)
  let before = counter_total () in
  Keeper_meta_json.warn_unknown_keeper_meta_keys
    ~path:"/test/has-unknown.json"
    (`Assoc
      [ ("name", `String "x")
      ; ("totally_made_up_field_xyz_42", `Bool true)
      ]);
  let after = counter_total () in
  Alcotest.(check bool)
    "counter increments on genuine unknown key"
    true
    (after > before)

let test_legacy_toml_owned_meta_keys_are_ignored_before_warn () =
  let path = Filename.temp_file "masc-legacy-keeper-meta-" ".json" in
  Fun.protect
    ~finally:(fun () ->
      if Sys.file_exists path then Sys.remove path)
    (fun () ->
      Fs_compat.save_file
        path
        (Yojson.Safe.to_string
           (`Assoc
             [ "name", `String "legacy-mm"
             ; "agent_name", `String "legacy-mm"
             ; "trace_id", `String "trace-legacy-mm"
             ; "tool_access", `List []
             ; "multimodal_policy", `String "Delegate"
             ]));
      let before = counter_total () in
      (match Keeper_meta_store.read_meta_file_path path with
       | Ok (Some meta) ->
         Alcotest.(check string) "keeper name" "legacy-mm" meta.name
       | Ok None -> Alcotest.fail "expected keeper meta"
       | Error err -> Alcotest.fail ("read_meta_file_path failed: " ^ err));
      let after = counter_total () in
      Alcotest.(check (float 0.0001))
        "legacy TOML-owned keys are scrubbed before unknown-key warning"
        before
        after;
      match Safe_ops.read_json_file_safe path with
      | Error err -> Alcotest.fail ("failed to reload keeper meta: " ^ err)
      | Ok (`Assoc fields) ->
        Alcotest.(check bool)
          "read path does not rewrite persisted legacy meta"
          true
          (List.mem_assoc "multimodal_policy" fields)
      | Ok _ -> Alcotest.fail "keeper meta must remain a JSON object")

let fresh_tmpdir () =
  let path = Filename.temp_file "masc-progress-refresh-" ".tmp" in
  Sys.remove path;
  let (_ : string) = Keeper_fs.ensure_dir path in
  path

let cleanup_tmpdir path =
  Fs_compat.remove_tree path

let test_progress_updated_line_failure_is_observable () =
  let dir = fresh_tmpdir () in
  Fun.protect ~finally:(fun () -> cleanup_tmpdir dir) (fun () ->
    let config = Workspace.default_config dir in
    let keeper_name = "progress-refresh-failure" in
    let progress_path =
      Keeper_types_support.keeper_progress_path config keeper_name
    in
    let (_ : string) = Keeper_fs.ensure_dir progress_path in
    let before =
      Otel_metric_store.metric_total
        Keeper_metrics.(to_string ProgressUpdatedLineFailures)
    in
    Keeper_meta_store.refresh_progress_updated_line config keeper_name;
    let after =
      Otel_metric_store.metric_total
        Keeper_metrics.(to_string ProgressUpdatedLineFailures)
    in
    Alcotest.(check bool)
      "progress Updated-line refresh failure increments counter"
      true
      (after > before))

let () =
  Alcotest.run
    "keeper_meta_unknown_keys_warn"
    [ ( "dangling_then_regression"
      , [ Alcotest.test_case
            "no counter tick when all keys canonical"
            `Quick
            test_no_counter_tick_when_all_keys_canonical
        ; Alcotest.test_case
            "self-model keys are canonical"
            `Quick
            test_self_model_keys_are_canonical
        ; Alcotest.test_case
            "counter still ticks on genuine unknown"
            `Quick
            test_counter_ticks_on_genuine_unknown_key
        ; Alcotest.test_case
            "legacy TOML-owned keys are ignored before warning"
            `Quick
            test_legacy_toml_owned_meta_keys_are_ignored_before_warn
        ; Alcotest.test_case
            "progress Updated-line refresh failure is observable"
            `Quick
            test_progress_updated_line_failure_is_observable
        ] )
    ]
;;
