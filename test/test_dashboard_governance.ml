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

let test_empty_governance_structure () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Room_utils.default_config dir in
      ignore (Lib.Room.init config ~agent_name:(Some "dashboard"));
      let json =
        Lib.Dashboard_governance.dashboard_json ~base_path:dir ~limit:20 ~offset:0
          ~status_filter:None
      in
      let open Yojson.Safe.Util in
      let _gen = json |> member "generated_at" |> to_string in
      let summary = json |> member "summary" in
      check int "cases_open is 0" 0 (summary |> member "cases_open" |> to_int);
      check int "pending_ruling is 0" 0 (summary |> member "pending_ruling" |> to_int);
      check int "ready_auto_execute is 0" 0
        (summary |> member "ready_auto_execute" |> to_int);
      check int "needs_human_gate is 0" 0
        (summary |> member "needs_human_gate" |> to_int);
      check int "executed is 0" 0 (summary |> member "executed" |> to_int);
      check int "blocked is 0" 0 (summary |> member "blocked" |> to_int);
      check int "ready_to_execute equals ready_auto_execute" 0
        (summary |> member "ready_to_execute" |> to_int);
      check bool "oldest_open_case_age_s is null" true
        (summary |> member "oldest_open_case_age_s" = `Null);
      check bool "last_activity_age_s is null" true
        (summary |> member "last_activity_age_s" = `Null);
      let items = json |> member "items" |> to_list in
      check int "items empty" 0 (List.length items);
      let activity = json |> member "activity" |> to_list in
      check int "activity empty" 0 (List.length activity);
      let judge = json |> member "judge" in
      check bool "judge_online is false when no judge started" false
        (judge |> member "judge_online" |> to_bool);
      check string "keeper_name is governance-judge" "governance-judge"
        (judge |> member "keeper_name" |> to_string);
      check bool "model_used is null when no judge started" true
        (judge |> member "model_used" = `Null);
      let judgments = json |> member "judgments" |> to_list in
      check int "judgments empty" 0 (List.length judgments);
      let pending = json |> member "pending_actions" |> to_list in
      check int "pending_actions empty" 0 (List.length pending))

let test_governance_dir_created_before_read () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      let masc = Filename.concat dir ".masc" in
      let gov = Filename.concat masc "governance" in
      let judgments = Filename.concat gov "judgments" in
      (* Before ensure_dir: directories do not exist *)
      check bool ".masc/governance does not exist yet" false (Sys.file_exists gov);
      (* Simulate what start() now does: ensure_dir calls Fs_compat.mkdir_p *)
      Unix.mkdir masc 0o755;
      Unix.mkdir gov 0o755;
      Unix.mkdir judgments 0o755;
      check bool ".masc/governance exists" true (Sys.file_exists gov && Sys.is_directory gov);
      check bool ".masc/governance/judgments exists" true
        (Sys.file_exists judgments && Sys.is_directory judgments);
      (* read_recent on empty dir returns [] — dashboard_json should still work *)
      Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Room_utils.default_config dir in
      ignore (Lib.Room.init config ~agent_name:(Some "dashboard"));
      let json =
        Lib.Dashboard_governance.dashboard_json ~base_path:dir ~limit:20 ~offset:0
          ~status_filter:None
      in
      let open Yojson.Safe.Util in
      let items = json |> member "items" |> to_list in
      check int "items empty after dir init" 0 (List.length items))

let () =
  run "dashboard_governance"
    [
      ( "projection",
        [
          test_case "empty governance structure" `Quick
            test_empty_governance_structure;
        ] );
      ( "init",
        [
          test_case "governance dirs created before read" `Quick
            test_governance_dir_created_before_read;
        ] );
    ]
