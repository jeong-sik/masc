open Alcotest
module Async = Masc.Keeper_msg_async

let () = Mirage_crypto_rng_unix.use_default ()
let caller = "durable-inventory-test"

let rec rm_rf path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Sys.readdir path
    |> Array.iter (fun name -> rm_rf (Filename.concat path name));
    Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
;;

let with_temp_base prefix f =
  let path = Filename.temp_file prefix "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  Fun.protect ~finally:(fun () -> rm_rf path) (fun () -> f path)
;;

let accepted_request_id = function
  | Ok { Async.acceptance = Async.Durably_accepted; request_id } -> request_id
  | Ok outcome -> fail (Async.submit_outcome_to_json outcome |> Yojson.Safe.to_string)
  | Error error -> fail (Async.submit_error_to_json error |> Yojson.Safe.to_string)
;;

let record_dir = function
  | Some path -> Filename.dirname path
  | None -> fail "safe request id did not produce an active record path"
;;

let active_dir ~base_path =
  Async.For_testing.active_record_path ~base_path ~request_id:"record"
  |> record_dir
;;

let projected_ownership ~base_path ~request_id =
  Server_async_request_observability.project ~base_path
  |> Yojson.Safe.Util.member "requests"
  |> Yojson.Safe.Util.to_list
  |> List.find (fun row ->
    String.equal
      request_id
      (Yojson.Safe.Util.member "request_id" row |> Yojson.Safe.Util.to_string))
  |> Yojson.Safe.Util.member "worker_ownership"
  |> Yojson.Safe.Util.to_string
;;

let test_reads_disk_only_entry () =
  with_temp_base "keeper-msg-durable-inventory-" (fun base_path ->
    Eio_main.run
    @@ fun _env ->
    Eio.Switch.run
    @@ fun sw ->
    let started, resolve_started = Eio.Promise.create () in
    let release, resolve_release = Eio.Promise.create () in
    let request_id =
      Async.submit
        ~background_sw:sw
        ~base_path
        ~caller
        ~keeper_name:"inventory-keeper"
        ~f:(fun _request_sw ->
          Eio.Promise.resolve resolve_started ();
          Eio.Promise.await release;
          Masc.Keeper_types_profile.tool_result_ok "done")
        ()
      |> accepted_request_id
    in
    Eio.Promise.await started;
    check
      string
      "current process owns worker"
      "runtime_owned"
      (projected_ownership ~base_path ~request_id);
    Async.For_testing.forget ~base_path ~caller ~request_id;
    (match Async.read_durable_active_inventory ~base_path with
     | Ok { entries = [ entry ]; record_errors = [] } ->
       check string "exact request id" request_id entry.request_id;
       check string "exact keeper" "inventory-keeper" entry.keeper_name;
       check bool "exact running status" true
         (match entry.status with Async.Running -> true | _ -> false)
     | Ok _ -> fail "expected one exact active entry"
     | Error _ -> fail "durable active inventory read was rejected");
    check
      string
      "disk row does not invent worker ownership"
      "disk_only_ownership_unknown"
      (projected_ownership ~base_path ~request_id);
    Eio.Promise.resolve resolve_release ();
    Eio.Fiber.yield ())
;;

let test_reports_terminal_residue () =
  with_temp_base "keeper-msg-durable-inventory-terminal-" (fun base_path ->
    Eio_main.run
    @@ fun _env ->
    Eio.Switch.run
    @@ fun sw ->
    let settled, resolve_settled = Eio.Promise.create () in
    let request_id =
      Async.submit
        ~on_worker_settled:(fun settlement ->
          Eio.Promise.resolve resolve_settled settlement)
        ~background_sw:sw
        ~base_path
        ~caller
        ~keeper_name:"terminal-keeper"
        ~f:(fun _request_sw ->
          Masc.Keeper_types_profile.tool_result_ok "done")
        ()
      |> accepted_request_id
    in
    (match Eio.Promise.await settled with
     | Async.Status_settlement
         { entry = { status = Async.Done _; _ }
         ; durability = Async.Durable
         ; origin = Async.Transition_commit
         } ->
       ()
     | _ -> failf "request %s did not settle durably" request_id);
    (match Async.read_durable_active_inventory ~base_path with
     | Ok { entries = []; record_errors = [] } -> ()
     | Ok _ -> fail "canonical terminal partition leaked into active inventory"
     | Error _ -> fail "terminal-only durable inventory read was rejected");
    let active_path =
      Filename.concat (active_dir ~base_path) (request_id ^ ".json")
    in
    let terminal_path =
      Async.For_testing.terminal_record_path ~base_path ~request_id
      |> function
      | Some path -> path
      | None -> fail "safe request id did not produce a terminal path"
    in
    Fs_compat.save_file active_path (Fs_compat.load_file terminal_path);
    match Async.read_durable_active_inventory ~base_path with
    | Ok
        { entries = []
        ; record_errors =
            [ { request_id = Some residue_id
              ; kind = Async.Record_terminal_status (Async.Done _)
              ; _
              }
            ]
        } when String.equal residue_id request_id ->
      ()
    | Ok _ -> fail "terminal residue was projected as a current operation"
    | Error _ -> fail "terminal residue rejected the whole inventory")
;;

let completed_request ~base_path ~sw ~request_context =
  let settled, resolve_settled = Eio.Promise.create () in
  let request_id =
    Async.submit
      ~request_context
      ~on_worker_settled:(fun settlement -> Eio.Promise.resolve resolve_settled settlement)
      ~background_sw:sw
      ~base_path
      ~caller
      ~keeper_name:"context-keeper"
      ~f:(fun _request_sw -> Masc.Keeper_types_profile.tool_result_ok "done")
      ()
    |> accepted_request_id
  in
  (match Eio.Promise.await settled with
   | Async.Status_settlement
       { entry = { status = Async.Done _; _ }
       ; durability = Async.Durable
       ; origin = Async.Transition_commit
       } ->
     request_id
   | _ -> failf "request %s did not settle durably" request_id)
;;

let rewrite_request_context request_context json =
  match json with
  | `Assoc fields ->
    `Assoc
      (List.map
         (fun (name, value) ->
            if String.equal name "request_context"
            then name, request_context
            else name, value)
         fields)
  | _ -> fail "durable request record is not an object"
;;

let test_conflicting_partition_request_context_is_unreadable () =
  with_temp_base "keeper-msg-context-conflict-" (fun base_path ->
    Eio_main.run
    @@ fun _env ->
    Eio.Switch.run
    @@ fun sw ->
    let request_id =
      completed_request
        ~base_path
        ~sw
        ~request_context:
          [ "mission_id", `String "mission-a"
          ; "origin_run_id", `String "origin-run"
          ]
    in
    let terminal_path =
      Async.For_testing.terminal_record_path ~base_path ~request_id
      |> Option.get
    in
    let active_path = Filename.concat (active_dir ~base_path) (request_id ^ ".json") in
    let same_context_in_another_object_order =
      Yojson.Safe.from_file terminal_path
      |> rewrite_request_context
           (`Assoc
              [ "origin_run_id", `String "origin-run"
              ; "mission_id", `String "mission-a"
              ])
    in
    Fs_compat.mkdir_p (Filename.dirname active_path);
    Yojson.Safe.to_file active_path same_context_in_another_object_order;
    (match Async.poll ~base_path ~caller request_id with
     | Async.Found { status = Async.Done _; _ } -> ()
     | _ -> fail "request context object order changed immutable identity");
    let conflicting =
      Yojson.Safe.from_file terminal_path
      |> rewrite_request_context
           (`Assoc
              [ "origin_run_id", `String "origin-run"
              ; "mission_id", `String "mission-b"
              ])
    in
    Yojson.Safe.to_file active_path conflicting;
    match Async.poll ~base_path ~caller request_id with
    | Async.Unreadable reason ->
      check
        string
        "immutable request context conflict"
        "conflicting request identities coexist across persistence partitions"
        reason
    | Async.Found _ -> fail "conflicting request context was accepted"
    | Async.Absent -> fail "conflicting request context disappeared"
    | Async.Rejected _ -> fail "conflicting request context was access-rejected")
;;

let test_duplicate_request_context_is_rejected_at_submit_and_decode () =
  with_temp_base "keeper-msg-context-duplicates-" (fun base_path ->
    Eio_main.run
    @@ fun _env ->
    Eio.Switch.run
    @@ fun sw ->
    let worker_ran = ref false in
    (match
       Async.submit
         ~request_context:
           [ "mission_id", `String "mission-a"
           ; "mission_id", `String "mission-b"
           ]
         ~background_sw:sw
         ~base_path
         ~caller
         ~keeper_name:"context-keeper"
         ~f:(fun _request_sw ->
           worker_ran := true;
           Masc.Keeper_types_profile.tool_result_ok "unexpected")
         ()
     with
     | Error (Async.Submit_invalid_request_context _) -> ()
     | Error error ->
       failf
         "wrong duplicate-context rejection: %s"
         (Async.submit_error_to_json error |> Yojson.Safe.to_string)
     | Ok _ -> fail "duplicate request context was accepted");
    check bool "invalid context starts no worker" false !worker_ran;
    let request_id =
      completed_request
        ~base_path
        ~sw
        ~request_context:[ "mission_id", `String "mission-a" ]
    in
    let terminal_path =
      Async.For_testing.terminal_record_path ~base_path ~request_id
      |> Option.get
    in
    let duplicate_context =
      `Assoc
        [ "mission_id", `String "mission-a"
        ; "mission_id", `String "mission-b"
        ]
    in
    Yojson.Safe.from_file terminal_path
    |> rewrite_request_context duplicate_context
    |> Yojson.Safe.to_file terminal_path;
    match Async.poll ~base_path ~caller request_id with
    | Async.Unreadable _ -> ()
    | Async.Found _ -> fail "persisted duplicate request context was decoded"
    | Async.Absent -> fail "persisted duplicate request context disappeared"
    | Async.Rejected _ -> fail "persisted duplicate request context was access-rejected")
;;

let test_non_json_numbers_are_rejected_at_submit_and_decode () =
  with_temp_base "keeper-msg-context-numbers-" (fun base_path ->
    Eio_main.run
    @@ fun _env ->
    Eio.Switch.run
    @@ fun sw ->
    let worker_runs = ref 0 in
    let invalid_values =
      [ `Intlit "not-a-number"; `Float Float.nan; `Float Float.infinity ]
    in
    List.iter
      (fun invalid_value ->
         match
           Async.submit
             ~request_context:[ "invalid_number", invalid_value ]
             ~background_sw:sw
             ~base_path
             ~caller
             ~keeper_name:"context-keeper"
             ~f:(fun _request_sw ->
               incr worker_runs;
               Masc.Keeper_types_profile.tool_result_ok "unexpected")
             ()
         with
         | Error (Async.Submit_invalid_request_context _) -> ()
         | Error error ->
           failf
             "wrong non-JSON number rejection: %s"
             (Async.submit_error_to_json error |> Yojson.Safe.to_string)
         | Ok _ -> fail "non-JSON request context number was accepted")
      invalid_values;
    check int "invalid numbers start no worker" 0 !worker_runs;
    let request_id =
      completed_request
        ~base_path
        ~sw
        ~request_context:[ "valid_large_integer", `Intlit "9223372036854775808" ]
    in
    let terminal_path =
      Async.For_testing.terminal_record_path ~base_path ~request_id
      |> Option.get
    in
    Yojson.Safe.from_file terminal_path
    |> rewrite_request_context (`Assoc [ "invalid_number", `Intlit "not-a-number" ])
    |> Yojson.Safe.to_file terminal_path;
    match Async.poll ~base_path ~caller request_id with
    | Async.Unreadable _ -> ()
    | Async.Found _ -> fail "persisted non-JSON request context number was decoded"
    | Async.Absent -> fail "persisted non-JSON request context number disappeared"
    | Async.Rejected _ ->
      fail "persisted non-JSON request context number was access-rejected")
;;

let error_kind_by_basename errors basename =
  errors
  |> List.find_map (fun (error : Async.active_inventory_record_error) ->
    if String.equal (Filename.basename error.path) basename
    then Some error.kind
    else None)
;;

let test_reports_malformed_link_non_file_and_name () =
  with_temp_base "keeper-msg-durable-inventory-errors-" (fun base_path ->
    let dir = active_dir ~base_path in
    Fs_compat.mkdir_p dir;
    Fs_compat.save_file (Filename.concat dir "malformed.json") "{";
    Unix.symlink "malformed.json" (Filename.concat dir "link.json");
    Unix.mkdir (Filename.concat dir "directory.json") 0o755;
    Fs_compat.save_file (Filename.concat dir "undeclared.txt") "{}";
    match Async.read_durable_active_inventory ~base_path with
    | Error _ -> fail "record-local failures rejected the whole inventory"
    | Ok { entries; record_errors } ->
      check int "no malformed entry fabricated" 0 (List.length entries);
      check (list string) "record errors have exact path order"
        [ "directory.json"; "link.json"; "malformed.json"; "undeclared.txt" ]
        (List.map
           (fun (error : Async.active_inventory_record_error) ->
              Filename.basename error.path)
           record_errors);
      (match error_kind_by_basename record_errors "malformed.json" with
       | Some (Async.Record_unreadable _) -> ()
       | _ -> fail "malformed JSON was not a typed unreadable record");
      (match error_kind_by_basename record_errors "link.json" with
       | Some (Async.Record_not_regular Unix.S_LNK) -> ()
       | _ -> fail "symbolic link was not reported explicitly");
      (match error_kind_by_basename record_errors "directory.json" with
       | Some (Async.Record_not_regular Unix.S_DIR) -> ()
       | _ -> fail "directory child was not reported explicitly");
      (match error_kind_by_basename record_errors "undeclared.txt" with
       | Some Async.Invalid_record_name -> ()
       | _ -> fail "undeclared record name was not reported explicitly"))
;;

let test_missing_partition_is_empty () =
  with_temp_base "keeper-msg-durable-inventory-empty-" (fun base_path ->
    (match Async.read_durable_active_inventory ~base_path with
     | Ok { entries = []; record_errors = [] } -> ()
     | Ok _ -> fail "missing active partition was not empty"
     | Error _ -> fail "missing active partition was rejected");
    ignore
      (Server_bootstrap_maintenance.recover_keeper_msg_requests_on_startup
         ~base_path
        : Async.recovery_report);
    let recovery =
      Server_async_request_observability.project ~base_path
      |> Yojson.Safe.Util.member "startup_recovery"
    in
    check
      int
      "startup recovery remains observable"
      0
      (Yojson.Safe.Util.member "lost" recovery |> Yojson.Safe.Util.to_int))
;;

let quick name f = test_case name `Quick f

let () =
  run
    "keeper_msg_async durable active inventory"
    [ ( "read"
      , [ quick "reads disk-only exact entry" test_reads_disk_only_entry
        ; quick "reports terminal residue" test_reports_terminal_residue
        ; quick
            "reports malformed and non-regular children"
            test_reports_malformed_link_non_file_and_name
        ; quick
            "conflicting partition context is unreadable"
            test_conflicting_partition_request_context_is_unreadable
        ; quick
            "duplicate context rejects submit and durable decode"
            test_duplicate_request_context_is_rejected_at_submit_and_decode
        ; quick
            "non-JSON numbers reject submit and durable decode"
            test_non_json_numbers_are_rejected_at_submit_and_decode
        ; quick "missing active partition is empty" test_missing_partition_is_empty
        ] )
    ]
