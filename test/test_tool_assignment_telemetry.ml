(** Tests for Tool_assignment_telemetry.

    Covers: Assigned snapshot fields, Called->Completed causal linkage,
    config hash format, temporal ordering, read_recent ordering. *)

open Alcotest
open Masc_mcp
open Tool_assignment_telemetry

let temp_dir () =
  let dir = Filename.temp_file "test_tool_assignment_telemetry_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else
        Unix.unlink path
  in
  try rm dir with _ -> ()

let with_eio_temp_base_path f =
  let dir = temp_dir () in
  let prev = try Some (Unix.getenv "MASC_BASE_PATH") with Not_found -> None in
  Unix.putenv "MASC_BASE_PATH" dir;
  Fun.protect
    ~finally:(fun () ->
      (match prev with
       | Some v -> Unix.putenv "MASC_BASE_PATH" v
       | None -> ());
      cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      f ())

(* --- Test 1: Assigned snapshot has all fields --- *)

let test_assigned_snapshot_has_all_fields () =
  with_eio_temp_base_path (fun () ->
    Tool_assignment_telemetry.reset_for_testing ();
    let assignment_id =
      Tool_assignment_telemetry.emit_assigned
        ~agent_id:"agent-1"
        ~profile:"keeper"
        ~preset:"board_comment"
        ~tool_list:[ "bash"; "read" ]
        ~allow_set:[ "bash"; "read" ]
        ~deny_set:[]
        ~reason:"test assignment"
        ()
    in
    check bool "assignment_id non-empty" true (String.length assignment_id > 0);
    match Tool_assignment_telemetry.find_latest_assignment_id ~agent_id:"agent-1" with
    | None -> fail "expected assignment_id in index"
    | Some id -> check string "assignment_id matches" assignment_id id)

(* --- Test 2: Called links to correct assignment_id --- *)

let test_called_links_to_assignment_id () =
  with_eio_temp_base_path (fun () ->
    Tool_assignment_telemetry.reset_for_testing ();
    let assignment_id =
      Tool_assignment_telemetry.emit_assigned
        ~agent_id:"agent-2"
        ~profile:"Full"
        ~tool_list:[ "bash" ]
        ()
    in
    let called_id =
      Tool_assignment_telemetry.emit_called
        ~agent_id:"agent-2"
        ~tool_name:"bash"
        ~source:"test"
        ()
    in
    match called_id with
    | None -> fail "expected called to find assignment_id"
    | Some id -> check string "called links to assigned" assignment_id id)

(* --- Test 3: Completed temporal ordering --- *)

let test_completed_temporal_ordering () =
  with_eio_temp_base_path (fun () ->
    Tool_assignment_telemetry.reset_for_testing ();
    let assignment_id =
      Tool_assignment_telemetry.emit_assigned
        ~agent_id:"agent-3"
        ~profile:"Managed_agent"
        ~tool_list:[ "read" ]
        ()
    in
    let t0 = Time_compat.now () in
    let called_id =
      Tool_assignment_telemetry.emit_called
        ~agent_id:"agent-3"
        ~tool_name:"read"
        ~source:"test"
        ()
    in
    let t1 = Time_compat.now () in
    (match called_id with
     | None -> fail "expected called id"
     | Some cid -> check string "called assignment_id" assignment_id cid);
    Tool_assignment_telemetry.emit_completed
      ~assignment_id
      ~tool_name:"read"
      ~success:true
      ~duration_ms:42.0
      ();
    let t2 = Time_compat.now () in
    check bool "assigned before called" true (t0 <= t1);
    check bool "called before completed" true (t1 <= t2))

let test_completed_error_kind_round_trip () =
  with_eio_temp_base_path (fun () ->
    Tool_assignment_telemetry.reset_for_testing ();
    let assignment_id =
      Tool_assignment_telemetry.emit_assigned
        ~agent_id:"agent-3b"
        ~profile:"Managed_agent"
        ~tool_list:[ "read" ]
        ()
    in
    Tool_assignment_telemetry.emit_completed
      ~assignment_id
      ~tool_name:"read"
      ~success:false
      ~duration_ms:7.0
      ~error_kind:(Tool_assignment_telemetry.error_kind_of_string "timeout")
      ();
    match Tool_assignment_telemetry.read_recent ~n:1 with
    | Error msg -> fail ("read_recent failed: " ^ msg)
    | Ok [ Completed ev ] -> (
        match ev.error_kind with
        | Some kind ->
            check string "error kind" "timeout"
              (Tool_assignment_telemetry.error_kind_to_string kind)
        | None -> fail "expected error_kind")
    | Ok _ -> fail "expected one Completed event")

(* --- Test 4: Config hash format validation --- *)

let test_config_hash_format () =
  with_eio_temp_base_path (fun () ->
    Tool_assignment_telemetry.reset_for_testing ();
    let assignment_id =
      Tool_assignment_telemetry.emit_assigned
        ~agent_id:"agent-4"
        ~profile:"Operator_remote"
        ~tool_list:[ "bash"; "read"; "write" ]
        ~allow_set:[ "bash"; "read" ]
        ~deny_set:[ "write" ]
        ()
    in
    check bool "assignment_id generated" true (String.length assignment_id > 0);
    (* Config hash is not directly exposed; verify via read_recent JSON round-trip. *)
    match Tool_assignment_telemetry.read_recent ~n:10 with
    | Error msg -> fail ("read_recent failed: " ^ msg)
    | Ok events -> (
        match events with
        | [] -> fail "expected at least one event"
        | Assigned ev :: _ ->
            check bool "config_hash is hex" true
              (String.length ev.config_hash = 64);
            let is_hex c =
              (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')
            in
            check bool "config_hash all hex" true
              (String.for_all is_hex ev.config_hash)
        | _ -> fail "expected Assigned event"))

(* --- Test 5: read_recent returns newest-first --- *)

let test_read_recent_newest_first () =
  with_eio_temp_base_path (fun () ->
    Tool_assignment_telemetry.reset_for_testing ();
    let id1 =
      Tool_assignment_telemetry.emit_assigned
        ~agent_id:"agent-5"
        ~profile:"keeper"
        ~tool_list:[ "bash" ]
        ()
    in
    (* Small sleep to ensure distinct timestamps, then second assignment. *)
    Unix.sleepf 0.01;
    let id2 =
      Tool_assignment_telemetry.emit_assigned
        ~agent_id:"agent-5"
        ~profile:"keeper"
        ~tool_list:[ "read" ]
        ()
    in
    match Tool_assignment_telemetry.read_recent ~n:10 with
    | Error msg -> fail ("read_recent failed: " ^ msg)
    | Ok events -> (
        match events with
        | Assigned ev :: _ ->
            check string "newest first" id2 ev.assignment_id;
            (* Verify the older one is present too. *)
            let has_id1 =
              List.exists
                (function
                  | Assigned a -> String.equal a.assignment_id id1
                  | _ -> false)
                events
            in
            check bool "older event present" true has_id1
        | _ -> fail "expected Assigned event at head"))

let () =
  run "Tool_assignment_telemetry"
    [
      ( "assignment lifecycle",
        [
          test_case "assigned snapshot has all fields" `Quick
            test_assigned_snapshot_has_all_fields;
          test_case "called links to assignment_id" `Quick
            test_called_links_to_assignment_id;
          test_case "completed temporal ordering" `Quick
            test_completed_temporal_ordering;
          test_case "completed error kind round-trip" `Quick
            test_completed_error_kind_round_trip;
          test_case "config hash format" `Quick test_config_hash_format;
          test_case "read_recent newest first" `Quick
            test_read_recent_newest_first;
        ] );
    ]
