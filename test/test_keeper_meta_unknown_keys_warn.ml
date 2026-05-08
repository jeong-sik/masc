(** Regression: [warn_unknown_keeper_meta_keys] dangling-then bug.

    Before fix:
      [if unknown <> [] then E1 ; E2]
    parsed as [(if cond then E1) ; E2], so the [Log.Keeper.warn] sequel
    fired on every call, producing the spam line
      "keeper meta <path> has unknown keys: "
    (empty tail = String.concat ", " []) at every dashboard tick across
    14 keepers — observed live 2026-05-05 ~01:50 KST.

    The Prometheus counter [metric_keeper_meta_json_failures] with
    label site=unknown_keys is the only durable side-effect we can
    assert from outside the logger; the structural fix protects both
    the counter and the warn line, so a green counter assertion is
    sufficient evidence that the warn line is also gated. *)

open Masc_mcp

let counter_total () =
  Prometheus.metric_total Masc_mcp.Keeper_metrics.metric_keeper_meta_json_failures

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

let fresh_tmpdir () =
  let path = Filename.temp_file "masc-progress-refresh-" ".tmp" in
  Sys.remove path;
  Keeper_types.mkdir_p path;
  path

let cleanup_tmpdir path =
  ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote path)))

let test_progress_updated_line_failure_is_observable () =
  let dir = fresh_tmpdir () in
  Fun.protect ~finally:(fun () -> cleanup_tmpdir dir) (fun () ->
    let config = Coord.default_config dir in
    let keeper_name = "progress-refresh-failure" in
    let progress_path = Keeper_types.keeper_progress_path config keeper_name in
    Keeper_types.mkdir_p progress_path;
    let before =
      Prometheus.metric_total
        Masc_mcp.Keeper_metrics.metric_keeper_progress_updated_line_failures
    in
    Keeper_meta_store.refresh_progress_updated_line config keeper_name;
    let after =
      Prometheus.metric_total
        Masc_mcp.Keeper_metrics.metric_keeper_progress_updated_line_failures
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
            "counter still ticks on genuine unknown"
            `Quick
            test_counter_ticks_on_genuine_unknown_key
        ; Alcotest.test_case
            "progress Updated-line refresh failure is observable"
            `Quick
            test_progress_updated_line_failure_is_observable
        ] )
    ]
;;
