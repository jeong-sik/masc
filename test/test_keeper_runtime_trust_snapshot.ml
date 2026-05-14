module K = Masc_mcp.Keeper_runtime_trust_snapshot
module P = Masc_mcp.Prometheus

let rec remove_tree path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let rec mkdir_p dir =
  if dir = "" || dir = "." || dir = "/"
  then ()
  else if Sys.file_exists dir
  then ()
  else (
    mkdir_p (Filename.dirname dir);
    Unix.mkdir dir 0o755)
;;

let temp_dir () =
  let dir = Filename.temp_file "runtime_trust_decision_drop_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir
;;

let write_file path content =
  mkdir_p (Filename.dirname path);
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () -> output_string oc content)
;;

let with_env name value f =
  let old = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect
    ~finally:(fun () ->
      match old with
      | Some v -> Unix.putenv name v
      | None -> Unix.putenv name "")
    f
;;

let make_meta name : Masc_mcp.Keeper_types.keeper_meta =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
          [ "name", `String name
          ; "trace_id", `String ("trace-" ^ name)
          ; "goal", `String "test goal"
          ])
  with
  | Ok meta -> meta
  | Error err -> Alcotest.fail ("meta fixture failed: " ^ err)
;;

let drop_value reason =
  P.metric_value_or_zero
    P.metric_persistence_read_drops
    ~labels:[ "surface", "keeper_runtime_trust_decision_log"; "reason", reason ]
    ()
;;

let test_snapshot_counts_malformed_decision_rows () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> remove_tree base_dir)
    (fun () ->
       with_env "MASC_BASE_PATH" base_dir
       @@ fun () ->
       let config = Masc_mcp.Coord.default_config base_dir in
       let keeper_name = "runtime-trust-decision-drop" in
       let meta = make_meta keeper_name in
       let path = Masc_mcp.Keeper_types.keeper_decision_log_path config keeper_name in
       let entry_error = Safe_ops.persistence_read_drop_reason_entry_load_error in
       let invalid_payload = Safe_ops.persistence_read_drop_reason_invalid_payload in
       let before_entry_error = drop_value entry_error in
       let before_invalid_payload = drop_value invalid_payload in
       write_file
         path
         (String.concat
            "\n"
            [ Yojson.Safe.to_string
                (`Assoc
                    [ "turn_id", `Int 11
                    ; "turn_verdict", `String "run"
                    ; "telemetry", `Assoc [ "selected_model", `String "test-model" ]
                    ])
            ; Yojson.Safe.to_string (`List [])
            ; "{not-json"
            ]
          ^ "\n");
       let snapshot = K.snapshot_json ~config ~meta in
       let open Yojson.Safe.Util in
       Alcotest.(check int)
         "falls back to older valid decision"
         11
         (snapshot |> member "latest_decision" |> member "turn_id" |> to_int);
       Alcotest.(check string)
         "selected model survives fallback"
         "test-model"
         (snapshot |> member "selected_model" |> to_string);
       Alcotest.(check (float 0.001))
         "malformed json increments entry error"
         1.0
         (drop_value entry_error -. before_entry_error);
       Alcotest.(check (float 0.001))
         "non-object row increments invalid payload"
         1.0
         (drop_value invalid_payload -. before_invalid_payload))
;;

let () =
  Alcotest.run
    "keeper_runtime_trust_snapshot"
    [ ( "decision_log_read_drops"
      , [ Alcotest.test_case
            "malformed decision rows increment drop metrics"
            `Quick
            test_snapshot_counts_malformed_decision_rows
        ] )
    ]
;;
