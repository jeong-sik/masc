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

let top_level_json_key_present path key =
  match Yojson.Safe.from_file path with
  | `Assoc fields -> List.mem_assoc key fields
  | _ -> Alcotest.fail "keeper meta must remain a JSON object"

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

let test_identity_keys_are_canonical () =
  let before = counter_total () in
  Keeper_meta_json.warn_unknown_keeper_meta_keys
    ~path:"/test/identity.json"
    (`Assoc
      [ ("name", `String "identity")
      ; ("agent_name", `String "identity")
      ; ("trace_id", `String "trace-identity")
      ; ("tool_access", `List [])
      ; ("instructions", `String "preserve operator guidance")
      ]);
  let after = counter_total () in
  Alcotest.(check (float 0.0001))
    "identity keys are canonical persisted keeper meta keys"
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

let test_persisted_multimodal_policy_is_canonical_before_warn () =
  let path = Filename.temp_file "masc-legacy-keeper-meta-" ".json" in
  Fun.protect
    ~finally:(fun () ->
      if Sys.file_exists path then Sys.remove path)
    (fun () ->
      Fs_compat.save_file
        path
        {|{"name":"legacy-mm","agent_name":"legacy-mm","trace_id":"trace-legacy-mm","tool_access":[],"multimodal_policy":"Delegate"}|};
      let before = counter_total () in
      (match Keeper_meta_store.read_meta_file_path path with
       | Ok (Some meta) ->
         Alcotest.(check string) "keeper name" "legacy-mm" meta.name;
         Alcotest.(check string)
           "multimodal policy"
           "delegate"
           (Keeper_types_profile.multimodal_policy_to_string meta.multimodal_policy)
       | Ok None -> Alcotest.fail "expected keeper meta"
       | Error err -> Alcotest.fail ("read_meta_file_path failed: " ^ err));
      let after = counter_total () in
      Alcotest.(check (float 0.0001))
        "persisted multimodal policy is canonical before unknown-key warning"
        before
        after;
      Alcotest.(check bool)
        "read path keeps persisted multimodal_policy key"
        true
        (top_level_json_key_present path "multimodal_policy"))

let test_config_keys_are_warned_before_parse () =
  let path = Filename.temp_file "masc-config-key-keeper-meta-" ".json" in
  Fun.protect
    ~finally:(fun () ->
      if Sys.file_exists path then Sys.remove path)
    (fun () ->
      Fs_compat.save_file
        path
        {|{"name":"config-key","agent_name":"config-key","trace_id":"trace-config-key","tool_access":[],"goal":"legacy profile goal"}|};
      let before = counter_total () in
      (match Keeper_meta_store.read_meta_file_path path with
       | Ok (Some meta) -> Alcotest.(check string) "keeper name" "config-key" meta.name
       | Ok None -> Alcotest.fail "expected keeper meta"
       | Error err -> Alcotest.fail ("read_meta_file_path failed: " ^ err));
      let after = counter_total () in
      Alcotest.(check bool)
        "TOML-owned config keys are warned before parse, not silently dropped"
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
            "identity keys are canonical"
            `Quick
            test_identity_keys_are_canonical
        ; Alcotest.test_case
            "counter still ticks on genuine unknown"
            `Quick
            test_counter_ticks_on_genuine_unknown_key
        ; Alcotest.test_case
            "persisted multimodal policy is canonical before warning"
            `Quick
            test_persisted_multimodal_policy_is_canonical_before_warn
        ; Alcotest.test_case
            "config keys are warned before parse"
            `Quick
            test_config_keys_are_warned_before_parse
        ] )
    ]
;;
