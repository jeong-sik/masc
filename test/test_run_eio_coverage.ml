(** Run Eio Module Coverage Tests

    Tests for run record types and JSON serialization:
    - run_record type
    - JSON roundtrip functions
*)

open Alcotest

module Run_eio = Masc.Run_eio

(* ============================================================
   run_record Type Tests
   ============================================================ *)

let test_run_record_basic () =
  let r : Run_eio.run_record = {
    task_id = "task-001";
    agent_name = None;
    plan = "# Plan\n- Step 1";
    created_at = "2024-01-01T10:00:00Z";
    updated_at = "2024-01-01T10:00:00Z";
  } in
  check string "task_id" "task-001" r.task_id;
  check bool "agent_name None" true (r.agent_name = None)

let test_run_record_with_agent () =
  let r : Run_eio.run_record = {
    task_id = "task-002";
    agent_name = Some "claude";
    plan = "Do the thing";
    created_at = "2024-01-01T09:00:00Z";
    updated_at = "2024-01-01T11:00:00Z";
  } in
  match r.agent_name with
  | Some a -> check string "agent_name" "claude" a
  | None -> fail "expected Some"

(* ============================================================
   JSON Serialization Tests
   ============================================================ *)

let test_run_record_json_roundtrip () =
  let original : Run_eio.run_record = {
    task_id = "rt-001";
    agent_name = Some "claude";
    plan = "# Plan Content";
    created_at = "2024-01-01T10:00:00Z";
    updated_at = "2024-01-01T12:00:00Z";
  } in
  let json = Run_eio.run_record_to_json original in
  match Run_eio.run_record_of_json json with
  | Some decoded ->
      check string "task_id" original.task_id decoded.task_id;
      check string "plan" original.plan decoded.plan
  | None -> fail "json decode failed"

let test_run_record_json_none_agent () =
  let original : Run_eio.run_record = {
    task_id = "rt-002";
    agent_name = None;
    plan = "";
    created_at = "2024-01-01T10:00:00Z";
    updated_at = "2024-01-01T10:00:00Z";
  } in
  let json = Run_eio.run_record_to_json original in
  match Run_eio.run_record_of_json json with
  | Some decoded ->
      check bool "agent_name None" true (decoded.agent_name = None)
  | None -> fail "json decode failed"

(* ============================================================
   Eio Helpers
   ============================================================ *)

module Workspace = Masc.Workspace

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Array.iter (fun name -> rm_rf (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
    end else
      Unix.unlink path

let make_test_dir () =
  let unique_id = Printf.sprintf "masc_run_test_%d_%d"
    (Unix.getpid ())
    (int_of_float (Unix.gettimeofday () *. 1000000.)) in
  let tmp_dir = Filename.concat (Filename.get_temp_dir_name ()) unique_id in
  (try Unix.mkdir tmp_dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  tmp_dir

let with_initialized_masc f =
  let tmp_dir = make_test_dir () in
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let config = Workspace.default_config tmp_dir in
  let _ = Workspace.init config ~agent_name:None in
  Fun.protect
    ~finally:(fun () ->
      try
        let _ = Workspace.reset config in
        rm_rf tmp_dir
      with _ -> ())
    (fun () -> f config)

(* ============================================================
   Eio IO Tests: init / read_run / write_run
   ============================================================ *)

let test_init_run () =
  with_initialized_masc @@ fun config ->
  match Run_eio.init config ~task_id:"task-init-001" ~agent_name:(Some "claude") with
  | Ok run ->
      check string "task_id" "task-init-001" run.task_id;
      (match run.agent_name with
       | Some a -> check string "agent_name" "claude" a
       | None -> fail "expected agent_name")
  | Error e -> failf "init failed: %s" e

let test_init_run_no_agent () =
  with_initialized_masc @@ fun config ->
  match Run_eio.init config ~task_id:"task-init-002" ~agent_name:None with
  | Ok run ->
      check string "task_id" "task-init-002" run.task_id;
      check bool "no agent" true (run.agent_name = None)
  | Error e -> failf "init failed: %s" e

let test_read_nonexistent () =
  with_initialized_masc @@ fun config ->
  match Run_eio.read_run config "nonexistent-task" with
  | Error _ -> ()
  | Ok _ -> fail "expected error"

(* ============================================================
   Eio IO Tests: update_plan
   ============================================================ *)

let test_update_plan () =
  with_initialized_masc @@ fun config ->
  ignore (Run_eio.init config ~task_id:"task-plan-001" ~agent_name:(Some "gemini"));
  match Run_eio.update_plan config ~task_id:"task-plan-001" ~content:"# New Plan\n- Step 1\n- Step 2" with
  | Ok run ->
      check bool "plan updated" true (String.length run.plan > 0)
  | Error e -> failf "update_plan failed: %s" e

(* ============================================================
   Eio IO Tests: get / list
   ============================================================ *)

let test_get_run () =
  with_initialized_masc @@ fun config ->
  ignore (Run_eio.init config ~task_id:"task-get-001" ~agent_name:(Some "gemini"));
  match Run_eio.get config ~task_id:"task-get-001" with
  | Ok json ->
      let open Yojson.Safe.Util in
      (* get returns: { "run": {...}, "plan": ... } *)
      let run = json |> member "run" in
      let task_id = run |> member "task_id" |> to_string in
      check string "task_id" "task-get-001" task_id;
      check bool "has plan" true (json |> member "plan" |> to_string |> String.length >= 0)
  | Error e -> failf "get failed: %s" e

let test_get_nonexistent () =
  with_initialized_masc @@ fun config ->
  match Run_eio.get ~agent_name:"keeper-auto" config ~task_id:"nonexistent" with
  | Error e -> failf "get should auto-create missing run: %s" e
  | Ok json ->
      let open Yojson.Safe.Util in
      let run = json |> member "run" in
      check string "task_id" "nonexistent" (run |> member "task_id" |> to_string);
      check string "agent_name" "keeper-auto" (run |> member "agent_name" |> to_string);
      check bool "run.json created" true
        (Sys.file_exists (Run_eio.run_json_path config "nonexistent"))

let test_list_empty () =
  with_initialized_masc @@ fun config ->
  let json = Run_eio.list config in
  let open Yojson.Safe.Util in
  let runs = json |> member "runs" |> to_list in
  check int "empty list" 0 (List.length runs)

let test_list_multiple () =
  with_initialized_masc @@ fun config ->
  ignore (Run_eio.init config ~task_id:"task-list-001" ~agent_name:(Some "a1"));
  ignore (Run_eio.init config ~task_id:"task-list-002" ~agent_name:(Some "a2"));
  let json = Run_eio.list config in
  let open Yojson.Safe.Util in
  let runs = json |> member "runs" |> to_list in
  check int "two runs" 2 (List.length runs)

(* ============================================================
   JSON Deserialization Edge Cases
   ============================================================ *)

let test_run_record_of_json_missing_field () =
  (* Missing required fields should return None *)
  let json = `Assoc [("task_id", `String "t1")] in
  match Run_eio.run_record_of_json json with
  | None -> ()  (* created_at missing *)
  | Some _ -> fail "expected None for incomplete json"

let test_run_record_of_json_invalid_type () =
  (* Wrong type should return None *)
  let json = `String "not an object" in
  match Run_eio.run_record_of_json json with
  | None -> ()
  | Some _ -> fail "expected None for invalid type"

(* ============================================================
   Error Path Tests
   ============================================================ *)

let test_update_plan_nonexistent () =
  with_initialized_masc @@ fun config ->
  match Run_eio.update_plan config ~task_id:"nonexistent-task" ~content:"plan" with
  | Error _ -> ()
  | Ok _ -> fail "expected error"

(* ============================================================
   Additional JSON Tests
   ============================================================ *)

let test_run_record_json_all_fields () =
  let original : Run_eio.run_record = {
    task_id = "all-fields";
    agent_name = Some "agent";
    plan = "# My Plan\n- Step 1\n- Step 2";
    created_at = "2024-01-01T00:00:00Z";
    updated_at = "2024-01-02T00:00:00Z";
  } in
  let json = Run_eio.run_record_to_json original in
  let open Yojson.Safe.Util in
  check string "task_id" "all-fields" (json |> member "task_id" |> to_string);
  check string "agent_name" "agent" (json |> member "agent_name" |> to_string);
  check string "created_at" "2024-01-01T00:00:00Z" (json |> member "created_at" |> to_string)

(* ============================================================
   Edge Cases for IO Functions
   ============================================================ *)

let test_init_run_idempotent () =
  with_initialized_masc @@ fun config ->
  (* Init same task twice should work (overwrite) *)
  ignore (Run_eio.init config ~task_id:"task-idem" ~agent_name:(Some "first"));
  match Run_eio.init config ~task_id:"task-idem" ~agent_name:(Some "second") with
  | Ok run ->
      (* Second init should succeed and update agent *)
      ();
      (match run.agent_name with
       | Some a -> check string "agent" "second" a
       | None -> fail "expected agent")
  | Error e -> failf "init failed: %s" e

let test_get_run_with_updated_plan () =
  with_initialized_masc @@ fun config ->
  ignore (Run_eio.init config ~task_id:"task-plan-get" ~agent_name:(Some "claude"));
  ignore (Run_eio.update_plan config ~task_id:"task-plan-get" ~content:"# Updated Plan\n- New step");
  match Run_eio.get config ~task_id:"task-plan-get" with
  | Ok json ->
      let open Yojson.Safe.Util in
      let plan = json |> member "plan" |> to_string in
      check bool "plan updated" true (String.length plan > 0)
  | Error e -> failf "get failed: %s" e

(* ============================================================
   Test Runners
   ============================================================ *)

let () =
  run "Run Eio Coverage" [
    "run_record", [
      test_case "basic" `Quick test_run_record_basic;
      test_case "with agent" `Quick test_run_record_with_agent;
    ];
    "json_roundtrip", [
      test_case "run_record" `Quick test_run_record_json_roundtrip;
      test_case "run_record none agent" `Quick test_run_record_json_none_agent;
    ];
    "eio_init_read", [
      test_case "init run" `Quick test_init_run;
      test_case "init no agent" `Quick test_init_run_no_agent;
      test_case "read nonexistent" `Quick test_read_nonexistent;
    ];
    "eio_update", [
      test_case "update plan" `Quick test_update_plan;
    ];
    "eio_get_list", [
      test_case "get run" `Quick test_get_run;
      test_case "get nonexistent" `Quick test_get_nonexistent;
      test_case "list empty" `Quick test_list_empty;
      test_case "list multiple" `Quick test_list_multiple;
    ];
    "json_edge_cases", [
      test_case "run_record missing field" `Quick test_run_record_of_json_missing_field;
      test_case "run_record invalid type" `Quick test_run_record_of_json_invalid_type;
    ];
    "error_paths", [
      test_case "update plan nonexistent" `Quick test_update_plan_nonexistent;
    ];
    "additional_json", [
      test_case "run_record all fields" `Quick test_run_record_json_all_fields;
    ];
    "io_edge_cases", [
      test_case "init idempotent" `Quick test_init_run_idempotent;
      test_case "get with updated plan" `Quick test_get_run_with_updated_plan;
    ];
  ]
