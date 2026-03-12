(** Dashboard governance regression tests. *)

module Lib = Masc_mcp

open Alcotest

let test_dir () =
  let tmp = Filename.temp_file "masc_dashboard_governance" "" in
  Sys.remove tmp;
  Unix.mkdir tmp 0o755;
  tmp

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Sys.readdir path |> Array.iter (fun f -> rm (Filename.concat path f));
        Unix.rmdir path
      end else
        Sys.remove path
  in
  rm dir

let write_pending_confirm config =
  let operator_dir = Filename.concat (Lib.Room_utils.masc_dir config) "operator" in
  Lib.Room_utils.mkdir_p operator_dir;
  let path = Filename.concat operator_dir "pending_confirms.json" in
  let entry =
    `Assoc
      [
        ("token", `String "opc_test_pending_confirm");
        ("trace_id", `String "opsd_test_trace");
        ("actor", `String "dashboard");
        ("action_type", `String "task_inject");
        ("target_type", `String "room");
        ("target_id", `Null);
        ("payload", `Assoc [ ("title", `String "Injected governance task") ]);
        ("delegated_tool", `String "masc_add_task");
        ("created_at", `String (Lib.Types.now_iso ()));
        ("expires_at", `Null);
      ]
  in
  Lib.Room_utils.write_json config path (`List [ entry ])

let test_dashboard_governance_exposes_pending_confirm_envelope () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      let config = Lib.Room_utils.default_config dir in
      ignore (Lib.Room.init config ~agent_name:(Some "dashboard"));
      write_pending_confirm config;
      let json =
        Lib.Dashboard_governance.dashboard_json ~base_path:dir ~limit:20 ~offset:0
          ~status_filter:None
      in
      let open Yojson.Safe.Util in
      let summary = json |> member "pending_confirm_summary" in
      let envelope = json |> member "pending_confirm_envelope" in
      let pending_actions = json |> member "pending_actions" |> to_list in
      check int "pending summary total" 1 (summary |> member "total_count" |> to_int);
      check int "pending summary visible" 1 (summary |> member "visible_count" |> to_int);
      check int "pending envelope items" 1
        (envelope |> member "items" |> to_list |> List.length);
      check int "pending actions count" 1 (List.length pending_actions);
      check string "pending action token propagated" "opc_test_pending_confirm"
        (List.hd pending_actions |> member "confirm_token" |> to_string))

let () =
  run "dashboard_governance"
    [
      ( "projection",
        [
          test_case "pending confirm envelope" `Quick
            test_dashboard_governance_exposes_pending_confirm_envelope;
        ] );
    ]
