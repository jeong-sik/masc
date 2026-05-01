open Alcotest
open Masc_mcp

let temp_dir () =
  let dir = Filename.temp_file "test_audit_log_" "" in
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

let assoc_key_count key = function
  | `Assoc fields ->
      List.length (List.filter (fun (field, _) -> String.equal field key) fields)
  | _ -> 0

let test_system_internal_details_deduplicate_canonical_keys () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Coord.default_config base_dir in
      Audit_log.log_system_internal_tool_call config ~agent_id:"codex"
        ~tool_name:"masc_status" ~success:true ~error_msg:None
        ~details:
          (`Assoc
             [
               ("surface", `String "overridden");
               ("tool_name", `String "wrong_name");
               ("source", `String "unit_test");
             ])
        ();
      let entry =
        match Audit_log.read_entries ~n:10 config with
        | [ entry ] -> entry
        | _ -> fail "expected one audit entry"
      in
      check string "canonical surface wins" "system_internal"
        Yojson.Safe.Util.(entry.details |> member "surface" |> to_string);
      check string "canonical tool name wins" "masc_status"
        Yojson.Safe.Util.(entry.details |> member "tool_name" |> to_string);
      check int "surface appears once" 1 (assoc_key_count "surface" entry.details);
      check int "tool_name appears once" 1
        (assoc_key_count "tool_name" entry.details);
      check string "keeps non-canonical fields" "unit_test"
        Yojson.Safe.Util.(entry.details |> member "source" |> to_string))

let entry ~timestamp ~agent_id ~action ~outcome =
  {
    Audit_log.timestamp;
    agent_id;
    action;
    room_id = None;
    details = `Null;
    outcome;
    cost_estimate = None;
    token_count = None;
    trace_id = None;
  }

let test_audit_events_filter_severity_before_paging () =
  let entries =
    [
      entry ~timestamp:1.0 ~agent_id:"keeper-a" ~action:Audit_log.AuthFailure
        ~outcome:(Audit_log.Failure "bad token");
      entry ~timestamp:2.0 ~agent_id:"keeper-b" ~action:Audit_log.AuthSuccess
        ~outcome:Audit_log.Success;
      entry ~timestamp:3.0 ~agent_id:"keeper-c" ~action:Audit_log.AuthSuccess
        ~outcome:Audit_log.Success;
    ]
  in
  let json =
    Audit_log.audit_events_response_json ~severity:"error" ~limit:2 entries
  in
  let open Yojson.Safe.Util in
  check int "one error survives paging" 1 (json |> member "count" |> to_int);
  let rows = json |> member "entries" |> to_list in
  check int "one row" 1 (List.length rows);
  let row = List.hd rows in
  check string "older error retained" "keeper-a" (row |> member "actor" |> to_string);
  check string "severity" "error" (row |> member "severity" |> to_string)

let () =
  run "Audit_log"
    [
      ( "audit_log",
        [
          test_case "system_internal details deduplicate canonical keys" `Quick
            test_system_internal_details_deduplicate_canonical_keys;
          test_case "audit event severity filters before paging" `Quick
            test_audit_events_filter_severity_before_paging;
        ] );
    ]
