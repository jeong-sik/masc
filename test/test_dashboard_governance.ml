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

let ensure_dir path =
  if not (Sys.file_exists path) then Unix.mkdir path 0o755

let write_legacy_judgments dir jsons =
  let masc = Filename.concat dir ".masc" in
  let gov = Filename.concat masc "governance" in
  ensure_dir masc;
  ensure_dir gov;
  let path = Filename.concat gov "judgments.jsonl" in
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () ->
      List.iter
        (fun json ->
          output_string oc (Yojson.Safe.to_string json);
          output_char oc '\n')
        jsons)

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

let test_dashboard_uses_stored_judgments () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      let judgment =
        `Assoc
          [
            ("judgment_id", `String "judgment-1");
            ("target_kind", `String "task");
            ("target_id", `String "task-123");
            ("status", `String "active");
            ("summary", `String "Review deployment task");
            ("confidence", `Float 0.91);
            ("generated_at", `String "2026-04-03T14:00:00Z");
            ("expires_at", `String "2099-04-03T14:30:00Z");
            ("model_used", `String "test-model");
            ("keeper_name", `String "governance-judge");
            ("evidence_refs", `List [ `String "task:task-123" ]);
            ( "recommended_action",
              `Assoc
                [
                  ("action_kind", `String "execute");
                  ("resolved_tool", `String "masc_execute");
                  ("target_type", `String "task");
                  ("target_id", `String "task-123");
                  ("reason", `String "Looks safe");
                  ("payload_preview", `Assoc [ ("task_id", `String "task-123") ]);
                ] );
            ( "guardrail_state",
              `Assoc
                [
                  ("requires_human_gate", `Bool true);
                  ("pending_confirm_token", `String "confirm-123");
                  ("ready_to_execute", `Bool false);
                ] );
          ]
      in
      write_legacy_judgments dir [ judgment ];
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Room_utils.default_config dir in
      ignore (Lib.Room.init config ~agent_name:(Some "dashboard"));
      let json =
        Lib.Dashboard_governance.dashboard_json ~base_path:dir ~limit:20 ~offset:0
          ~status_filter:None
      in
      let open Yojson.Safe.Util in
      let summary = json |> member "summary" in
      check int "cases_open projected" 1 (summary |> member "cases_open" |> to_int);
      check int "needs_human_gate projected" 1
        (summary |> member "needs_human_gate" |> to_int);
      let items = json |> member "items" |> to_list in
      check int "items projected" 1 (List.length items);
      let item = List.hd items in
      check string "item id" "task-123" (item |> member "id" |> to_string);
      check string "item status" "needs_human_gate" (item |> member "status" |> to_string);
      check string "linked task id" "task-123" (item |> member "linked_task_id" |> to_string);
      let pending_actions = json |> member "pending_actions" |> to_list in
      check int "pending action projected" 1 (List.length pending_actions);
      check string "confirm token forwarded" "confirm-123"
        (List.hd pending_actions |> member "confirm_token" |> to_string);
      let (status, detail) =
        Lib.Dashboard_governance.case_detail_json ~base_path:dir ~case_id:"task-123"
      in
      check bool "case detail found" true (status = `OK);
      check string "case detail id" "task-123"
        (detail |> member "case" |> member "id" |> to_string);
      check string "execution order status" "needs_human_gate"
        (detail |> member "execution_order" |> member "status" |> to_string))

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
          test_case "stored judgments power dashboard" `Quick
            test_dashboard_uses_stored_judgments;
        ] );
    ]
