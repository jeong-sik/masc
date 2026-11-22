open Alcotest

module Workspace = Masc.Workspace

let keeper_name = "scope-keeper"

let with_workspace f =
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key None @@ fun () ->
  Masc_test_deps.with_process_env Env_config_core.config_dir_env_key None @@ fun () ->
  Eio_main.run @@ fun _env ->
  let base_path = Filename.temp_dir "librarian-stores-" "" in
  Config_dir_resolver.reset ();
  Fun.protect ~finally:(fun () ->
    Config_dir_resolver.reset ();
    Fs_compat.remove_tree base_path) (fun () ->
    let config = Workspace.default_config base_path in
    let (_ : string) = Workspace.init config ~agent_name:None in
    f config)
;;

(* Memory events are keyed by claim-hash memory ids, so a same-name keeper
   created after a purge would count the deleted keeper's retrievals as its own
   unless the sidecar goes with the keeper. *)
let test_purge_removes_memory_events () =
  with_workspace @@ fun a ->
  let module Events = Masc.Keeper_memory_os_events in
  Fs_compat.mkdir_p (Filename.dirname
    (Config_dir_resolver.runtime_toml_path_for_base_path ~base_path:a.base_path));
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:a.base_path in
  let path = Events.path_for_keepers_dir ~keepers_dir ~keeper_id:keeper_name in
  let retrieved trace_id : Events.event =
    { recorded_at = 1.0; memory_id = "sha256:" ^ String.make 64 'a'; trace_id
    ; kind = Events.Retrieved { query = "pdf pages" } } in
  let append trace_id = match Events.append ~keepers_dir ~keeper_id:keeper_name
      (retrieved trace_id) with
    | Ok () -> ()
    | Error error -> fail (Events.append_error_to_string error) in
  let trace_ids () = match Events.read ~keepers_dir ~keeper_id:keeper_name with
    | Ok rows -> List.map (fun (_, decoded) -> match decoded with
        | Ok (event : Events.event) -> event.trace_id
        | Error error -> fail (Events.read_error_to_string error)) rows
    | Error error -> fail (Events.file_read_error_to_string error) in
  append "trace-before";
  check bool "events sidecar written" true (Sys.file_exists path);
  (match Server_dashboard_http_delete_actions.For_testing.purge_keeper_artifacts
    a ~keeper_name ~remove_configuration:false
    { Masc.Keeper_shutdown_types.requested_name = keeper_name } with
   | Ok () -> ()
   | Error detail -> failf "artifact purge: %s" detail);
  check bool "events sidecar removed" false (Sys.file_exists path);
  append "trace-after";
  check (list string) "a same-name keeper sees only its own events"
    [ "trace-after" ] (trace_ids ())
;;

(* [Workspace.init] makes the runtime root, so it is removed first: the
   reads below must not bring it back. *)
(* The Keeper's Memory writer, the commit lines it wrote, and a claim written
   through it by the Keeper. *)
module Writers = Masc.Librarian_writers
module Commit_log = Masc.Librarian_log_store
module Cleanup = Server_dashboard_http_keeper_memory_cleanup

let memory_id_of = Masc.Keeper_memory_os_types.memory_id_of_claim

let writers (config : Workspace.config) =
  match Masc.Keeper_memory_writers.find ~base_path:config.base_path with
  | Some writers -> writers
  | None -> fail "the workspace has no Memory writers"
;;

let commit_log_path (config : Workspace.config) =
  Commit_log.path_for_keepers_dir
    ~keepers_dir:(Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.base_path)
    ~keeper_id:keeper_name
;;

let commits config =
  match
    Commit_log.fold (commit_log_path config) ~init:[] ~f:(fun seen (scanned : Commit_log.scanned) ->
      match scanned.line with
      | Ok (Committed commit) -> commit :: seen
      | Ok (Started _) -> seen
      | Error (_ : Commit_log.undecodable) -> fail "a commit line does not decode")
  with
  | Ok seen -> List.rev seen
  | Error error -> fail (Masc.Private_jsonl_scan.error_to_string error)
;;

let keeper_remembers config claim =
  match
    Writers.write (writers config) keeper_name ~by:Masc.Librarian_effects.Keeper ~trace:"turn-1"
      (Remember
         { claim
         ; category = Masc.Keeper_memory_os_types.Constraint
         ; basis = Masc.Keeper_memory_os_types.Observed Masc.Keeper_memory_os_types.Transcript
         })
  with
  | Written (_ : Masc.Librarian_log.commit) -> ()
  | Already_held | Already_done | Already_absent | Refused _ | Not_a_snapshot _ | Unavailable _ ->
    fail "the claim of the fixture was not written"
;;

let retraction_text ((retraction : Cleanup.retraction), (result : Cleanup.retraction_result)) =
  match result with
  | Retraction_not_current -> retraction.memory_id ^ ": not current"
  | Retraction_committed commit ->
    Printf.sprintf "%s: retracted, removed %s" retraction.memory_id
      (String.concat ","
         (List.map
            (fun ((fact : Masc.Keeper_memory_os_types.fact), (_ : Masc.Librarian_effects.removal)) ->
               fact.claim)
            commit.effects.removed))
;;

let stopped_text (outcome : Cleanup.retractions_outcome) =
  match outcome.stopped with
  | None -> "not stopped"
  | Some (retraction, why) ->
    retraction.memory_id ^ ": "
    ^ Masc.Keeper_tool_memory_validation.memory_unwritable_to_string why
;;

let port = "the port is 8935"
let owner = "the owner is the release team"

let request ids : Cleanup.current_memory_request =
  { plan_id = "plan-1"
  ; retractions = List.map (fun memory_id : Cleanup.retraction -> { memory_id; reason = "wrong" }) ids
  }
;;

(* An operator's retractions are direct writes to the Keeper's writer, so
   they are lines of the commit log and do not change the snapshot behind
   the writer. *)
let test_operator_retractions_go_through_the_writer () =
  with_workspace @@ fun a ->
  Eio.Switch.run @@ fun sw ->
  Masc_test_deps.ensure_memory_writer ~sw ~config:a keeper_name;
  keeper_remembers a port;
  keeper_remembers a owner;
  let never_written = memory_id_of "never written" in
  let retract request =
    Cleanup.retract_through_writer ~base_path:a.base_path ~keeper:keeper_name ~actor:"operator-1"
      request
  in
  let outcome = retract (request [ memory_id_of port; never_written ]) in
  check string "every retraction was answered" "not stopped" (stopped_text outcome);
  check (list string) "one left Memory and one was never there"
    [ memory_id_of port ^ ": retracted, removed " ^ port; never_written ^ ": not current" ]
    (List.map retraction_text outcome.answered);
  (match List.rev (commits a) with
   | last :: _ ->
     (match last.cause with
      | Direct { by = Operator operator; trace; write = Retract { id; reason } } ->
        check (list string) "the line names the operator, the plan, the fact and the reason"
          [ "operator-1"; "plan-1"; memory_id_of port; "wrong" ]
          [ operator; trace; id; reason ]
      | Direct { by = Keeper | Operator _; write = Remember _ | Supersede _ | Retract _; _ }
      | Adopt _ | Read _ | Make_room _ | Skip _ | Molt_and_synthesize _ | Checkpoint _ ->
        fail "the last commit line is not the operator's retraction");
     (match last.effects.removed with
      | [ ((fact : Masc.Keeper_memory_os_types.fact), Retracted { by = Operator by; reason }) ] ->
        check (list string) "the fact left with the operator's name and reason"
          [ port; "operator-1"; "wrong" ]
          [ fact.claim; by; reason ]
      | _ -> fail "the retraction removed something else")
   | [] -> fail "nothing was committed");
  check int "two claims and one retraction are three lines" 3 (List.length (commits a));
  (match Writers.write (writers a) keeper_name ~by:Masc.Librarian_effects.Keeper ~trace:"turn-2"
           (Retract { id = memory_id_of owner; reason = "moved" })
   with
   | Written (_ : Masc.Librarian_log.commit) -> ()
   | Already_held | Already_done | Already_absent | Refused _ | Not_a_snapshot _ | Unavailable _ ->
     fail "the Keeper's writer did not go on after the operator's retraction");
  let again = retract (request [ memory_id_of port; never_written ]) in
  check (list string) "the same request again finds neither"
    [ memory_id_of port ^ ": not current"; never_written ^ ": not current" ]
    (List.map retraction_text again.answered);
  check int "and commits nothing" 4 (List.length (commits a));
  let unregistered =
    Cleanup.retract_through_writer ~base_path:a.base_path ~keeper:"another-keeper"
      ~actor:"operator-1" (request [ memory_id_of port; never_written ])
  in
  check string "a Keeper out of the registry has no writer"
    (memory_id_of port ^ ": keeper_not_registered")
    (stopped_text unregistered);
  check int "and nothing of the request was answered" 0 (List.length unregistered.answered)
;;

let test_operator_retractions_without_writers () =
  with_workspace @@ fun a ->
  let outcome =
    Cleanup.retract_through_writer ~base_path:a.base_path ~keeper:keeper_name ~actor:"operator-1"
      (request [ memory_id_of port ])
  in
  check string "a process that started no writers" (memory_id_of port ^ ": no_writer_in_process")
    (stopped_text outcome)
;;

(* The writer holds the commit log and its lock while the Keeper is in the
   registry. The purge ends it first, and does not remove the files of a
   Keeper that is registered. *)
let test_purge_ends_the_memory_writer_first () =
  with_workspace @@ fun a ->
  Eio.Switch.run @@ fun sw ->
  Fs_compat.mkdir_p (Filename.dirname
    (Config_dir_resolver.runtime_toml_path_for_base_path ~base_path:a.base_path));
  Masc_test_deps.ensure_memory_writer ~sw ~config:a keeper_name;
  keeper_remembers a port;
  let purge () =
    Server_dashboard_http_delete_actions.For_testing.purge_keeper_artifacts
      a ~keeper_name ~remove_configuration:false
      { Masc.Keeper_shutdown_types.requested_name = keeper_name }
  in
  check bool "a registered Keeper is not purged" true (Result.is_error (purge ()));
  check bool "its commit log is where it was" true (Sys.file_exists (commit_log_path a));
  check int "and its writer goes on" 1 (List.length (Writers.statuses (writers a)));
  Masc.Keeper_registry.For_testing.unregister ~base_path:a.base_path keeper_name;
  (match purge () with
   | Ok () -> ()
   | Error detail -> failf "artifact purge: %s" detail);
  check int "the writer has ended" 0 (List.length (Writers.statuses (writers a)));
  check bool "the commit log is removed" false (Sys.file_exists (commit_log_path a))
;;

module Act = Server_dashboard_http_keeper_memory_act
module Digest = Agent_core.Checkpoint_objects

let hex (digest : Digest.digest) = (digest :> string)

let stop_text : Masc.Librarian_store.stop -> string = function
  | Log_diverged { expected; observed } ->
    Printf.sprintf "the log names %s and the file is %s" (hex expected) (hex observed)
  | Memory_unreadable -> "memory unreadable"
  | Log_unreadable -> "log unreadable"
  | Store_unwritable -> "store unwritable"
  | Raised { detail } -> "raised: " ^ detail
;;

let act_text : Act.answer -> string = function
  | Acted Open -> "open"
  | Acted Booting -> "booting"
  | Acted No_writer -> "no writer"
  | Acted (Stopped stop) -> "stopped: " ^ stop_text stop
  | Refused Nothing_to_resume -> "refused: nothing to resume"
  | Refused Not_stopped -> "refused: not stopped"
  | Refused Snapshot_mismatch -> "refused: snapshot mismatch"
  | Refused Snapshot_unreadable -> "refused: snapshot unreadable"
  | Refused Not_replaced -> "refused: not replaced"
  | Refused Turn_log_unread -> "refused: turn log unread"
  | Refused (Not_the_head { now }) ->
    "refused: not the head, now "
    ^ (match now with
       | Some target -> Yojson.Safe.to_string (Act.target_json target)
       | None -> "none")
  | Refused Not_the_faulted_line -> "refused: not the faulted line"
  | Refused Turn_log_stopped_on_line -> "refused: the turn log is stopped on the line"
  | Refused Content_unread -> "refused: content unread"
  | Refused (Act_unavailable (Store_stopped stop)) -> "refused: stopped: " ^ stop_text stop
  | Refused (Act_unavailable Keeper_retired) -> "refused: keeper not registered"
  | No_writers -> "no writers"
;;

let test_act_route_and_requests () =
  check (option string) "the route names its Keeper" (Some "fixture-keeper")
    (Act.route "/api/v1/keepers/fixture-keeper/memory/act");
  check (option string) "a longer path is another route" None
    (Act.route "/api/v1/keepers/fixture-keeper/memory/act/now");
  check bool "an operator needs Admin" true (Act.permission = Masc_domain.CanAdmin);
  let digest = Digest.digest_of_bytes "a snapshot" in
  let parsed body =
    match Act.parse body with
    | Ok Resume -> "resume"
    | Ok (Adopt { observed }) -> "adopt " ^ hex observed
    | Ok (Restart_reading { observed }) ->
      "restart " ^ Masc.Keeper_turn_log.Log_id.to_string observed
    | Ok (Skip_item { target }) -> "skip " ^ Yojson.Safe.to_string (Act.target_json target)
    | Ok (Skip_line { offset }) -> Printf.sprintf "skip the line at %d" offset
    | Error (_ : string) -> "refused"
  in
  let log_id = String.make 32 'e' in
  check string "resume" "resume" (parsed {|{"action":"resume"}|});
  check string "adopt names the snapshot" ("adopt " ^ hex digest)
    (parsed (Printf.sprintf {|{"action":"adopt","observed":"%s"}|} (hex digest)));
  check string "adopt without a snapshot" "refused" (parsed {|{"action":"adopt"}|});
  check string "a snapshot that is not a digest" "refused"
    (parsed {|{"action":"adopt","observed":"abc"}|});
  check string "resume with another field" "refused"
    (parsed (Printf.sprintf {|{"action":"resume","observed":"%s"}|} (hex digest)));
  check string "another action" "refused" (parsed {|{"action":"skip"}|});
  check string "not JSON" "refused" (parsed "resume");
  check string "a restart names the turn log" ("restart " ^ log_id)
    (parsed (Printf.sprintf {|{"observed":"%s","action":"restart_reading"}|} log_id));
  check string "a restart without one" "refused" (parsed {|{"action":"restart_reading"}|});
  check string "a turn log id that is not one" "refused"
    (parsed {|{"action":"restart_reading","observed":"abc"}|});
  let head_item =
    Printf.sprintf {|{"kind":"head_item","turn_log":"%s","line":120,"store":"chat","at":3}|} log_id
  in
  check string "a skip names the head item" ("skip " ^ head_item)
    (parsed (Printf.sprintf {|{"action":"skip_item","target":%s}|} head_item));
  check string "or a unit that does not read, in any order"
    (Printf.sprintf {|skip {"kind":"unreadable_unit","turn_log":"%s","line":7}|} log_id)
    (parsed
       (Printf.sprintf {|{"target":{"line":7,"turn_log":"%s","kind":"unreadable_unit"},"action":"skip_item"}|}
          log_id));
  check string "an item without its store" "refused"
    (parsed
       (Printf.sprintf {|{"action":"skip_item","target":{"kind":"head_item","turn_log":"%s","line":1,"at":0}}|}
          log_id));
  check string "a store that is not one" "refused"
    (parsed
       (Printf.sprintf
          {|{"action":"skip_item","target":{"kind":"head_item","turn_log":"%s","line":1,"store":"disk","at":0}}|}
          log_id));
  check string "a negative offset" "refused"
    (parsed
       (Printf.sprintf {|{"action":"skip_item","target":{"kind":"unreadable_unit","turn_log":"%s","line":-1}}|}
          log_id));
  check string "a unit with an item's fields" "refused"
    (parsed
       (Printf.sprintf
          {|{"action":"skip_item","target":{"kind":"unreadable_unit","turn_log":"%s","line":1,"store":"chat","at":0}}|}
          log_id));
  check string "a skip with a turn log id instead" "refused"
    (parsed (Printf.sprintf {|{"action":"skip_item","observed":"%s"}|} log_id));
  check string "a skip of a line names its offset, in any order" "skip the line at 4096"
    (parsed {|{"offset":4096,"action":"skip_line"}|});
  check string "a line skip without its offset" "refused" (parsed {|{"action":"skip_line"}|});
  check string "a negative line offset" "refused" (parsed {|{"action":"skip_line","offset":-1}|});
  check string "an offset that is not a number" "refused"
    (parsed {|{"action":"skip_line","offset":"4096"}|});
  check string "an offset on another action" "refused" (parsed {|{"action":"resume","offset":0}|})
;;

(* The Keeper's turn log is replaced from outside. Reading stands in the old
   one, and the operator restarts it on the file that is there now. *)
let test_operator_restarts_reading () =
  with_workspace @@ fun a ->
  Eio.Switch.run @@ fun sw ->
  Masc_test_deps.ensure_memory_writer ~sw ~config:a keeper_name;
  let act action = Act.act ~base_path:a.base_path ~keeper:keeper_name ~actor:"operator-1" action in
  let turns_path =
    Masc.Keeper_turn_log_store.path_for_keepers_dir ~keepers_dir:(Workspace.keepers_runtime_dir a)
      ~keeper_id:keeper_name
  in
  let start =
    match Masc.Keeper_turn_log_store.read_start turns_path with
    | Ok (Some start) -> start
    | Ok None | Error (_ : Masc.Keeper_turn_log_store.read_error) -> fail "the Keeper has no turn log"
  in
  let replaced =
    match Masc.Keeper_turn_log.Log_id.of_string (String.make 32 'e') with
    | Some id -> id
    | None -> fail "the test log id is not 32 hexadecimal characters"
  in
  check string "the file reading stands in" "refused: not replaced"
    (act_text (act (Restart_reading { observed = start.id })));
  Sys.remove turns_path;
  (match
     Masc.Keeper_turn_log_store.append ~path:turns_path ~at_end:0
       (Log_started { id = replaced; at = start.at +. 1.0; mark = start.mark }, [])
   with
   | Ok (_ : Masc.Keeper_turn_log_store.appended) -> ()
   | Error (_ : Masc.Keeper_turn_log_store.append_error) -> fail "the new turn log was not written");
  check string "an id the file does not name" "refused: not replaced"
    (act_text (act (Restart_reading { observed = start.id })));
  let before = List.length (commits a) in
  check string "the id the file names" "open"
    (act_text (act (Restart_reading { observed = replaced })));
  (match List.rev (commits a) with
   | last_line :: _ ->
     (match last_line.cause with
      | Skip { hole = Turn_log_replaced { from; to_ } } ->
        check (pair string string) "the line names both files"
          (Masc.Keeper_turn_log.Log_id.to_string start.id, String.make 32 'e')
          (Masc.Keeper_turn_log.Log_id.to_string from, Masc.Keeper_turn_log.Log_id.to_string to_);
        check int "and reads the new one from its first line" 0 last_line.turn_log_offset
      | Direct _ | Read _ | Make_room _ | Adopt _ | Skip _ | Molt_and_synthesize _ | Checkpoint _ -> fail "the last commit line is not the restart")
   | [] -> fail "nothing was committed");
  check int "one line was appended" (before + 1) (List.length (commits a));
  check string "the file it now reads" "refused: not replaced"
    (act_text (act (Restart_reading { observed = replaced })))
;;

(* A line that does not decode stands where the Keeper's turn log ends, and
   reading stops on it. While it is the last line the turn log stops on it
   too, and the act is refused with nothing committed. With a line after it
   that closes a turn, the operator passes it by its offset. *)
let test_operator_skips_a_line () =
  with_workspace @@ fun a ->
  Eio.Switch.run @@ fun sw ->
  Masc_test_deps.ensure_memory_writer ~sw ~config:a keeper_name;
  let act action = Act.act ~base_path:a.base_path ~keeper:keeper_name ~actor:"operator-1" action in
  let keepers_dir = Workspace.keepers_runtime_dir a in
  let turns_path =
    Masc.Keeper_turn_log_store.path_for_keepers_dir ~keepers_dir ~keeper_id:keeper_name
  in
  let length () =
    match Fs_compat.file_size turns_path with
    | Some length -> length
    | None -> fail "the Keeper has no turn log"
  in
  let row = "not json" in
  let offset = length () in
  Out_channel.with_open_gen [ Open_wronly; Open_append; Open_binary ] 0o600 turns_path
    (fun channel -> Out_channel.output_string channel (row ^ "\n"));
  check string "an offset that is not the line's" "refused: not the faulted line"
    (act_text (act (Skip_line { offset = offset + 1 })));
  let before = List.length (commits a) in
  check string "the last line" "refused: the turn log is stopped on the line"
    (act_text (act (Skip_line { offset })));
  check int "is not passed" before (List.length (commits a));
  (* The mark the fixture's turn log starts at: the turn leaves nothing to
     read. *)
  let unmoved : Masc.Keeper_turn_log.mark =
    { trace = "trace-" ^ keeper_name
    ; closed_messages = 0
    ; session = ""
    ; history_bytes = 0
    ; internal_bytes = 0
    ; chat_bytes = 0
    ; external_rows = 0
    }
  in
  Masc_test_deps.append_turn_log_lines ~who:"the turn after the line" ~keepers_dir ~keeper_name
    ~at_end:(length ())
    ( Masc.Keeper_turn_log.Closed
        { turn = offset
        ; at = 2.0
        ; outcome = Completed
        ; after = unmoved
        ; unattributed = []
        ; own = []
        }
    , [] );
  check string "the line's offset" "open" (act_text (act (Skip_line { offset })));
  (match List.rev (commits a) with
   | last_line :: _ ->
     (match last_line.cause with
      | Skip { hole = Line_unreadable { offset = passed; sha } } ->
        check (pair int string) "the line names the line and its bytes"
          (offset, hex (Digest.digest_of_bytes row))
          (passed, hex sha);
        check int "and reading goes on just past it" (offset + String.length row + 1)
          last_line.turn_log_offset
      | Direct _ | Read _ | Make_room _ | Adopt _ | Skip _ | Molt_and_synthesize _ | Checkpoint _ -> fail "the last commit line is not the skip")
   | [] -> fail "nothing was committed");
  check int "one line was appended" (before + 1) (List.length (commits a));
  check string "the same offset again" "refused: not the faulted line"
    (act_text (act (Skip_line { offset })))
;;

(* The snapshot is replaced from outside by one the commit log does not
   name. The next write stops the store, resume finds it stopped again, and
   an adoption of the file's bytes opens it. *)
let test_operator_resumes_and_adopts () =
  with_workspace @@ fun a ->
  Eio.Switch.run @@ fun sw ->
  Masc_test_deps.ensure_memory_writer ~sw ~config:a keeper_name;
  let snapshot_path =
    Masc.Keeper_memory_os_current_layout.path_for_keepers_dir
      ~keepers_dir:(Config_dir_resolver.keepers_dir_for_base_path ~base_path:a.base_path)
      ~keeper_id:keeper_name
  in
  let snapshot_bytes () = In_channel.with_open_bin snapshot_path In_channel.input_all in
  let act action = Act.act ~base_path:a.base_path ~keeper:keeper_name ~actor:"operator-1" action in
  keeper_remembers a port;
  let first = snapshot_bytes () in
  keeper_remembers a owner;
  keeper_remembers a "the probe runs every minute";
  let last = snapshot_bytes () in
  check string "an open store has nothing to resume" "refused: nothing to resume"
    (act_text (act Resume));
  check string "and is not adopted" "refused: not stopped"
    (act_text (act (Adopt { observed = Digest.digest_of_bytes last })));
  Out_channel.with_open_bin snapshot_path (fun channel -> Out_channel.output_string channel first);
  (match
     Writers.write (writers a) keeper_name ~by:Masc.Librarian_effects.Keeper ~trace:"turn-2"
       (Retract { id = memory_id_of owner; reason = "moved" })
   with
   | Unavailable (Store_stopped (Log_diverged _)) -> ()
   | Written _ | Already_held | Already_done | Already_absent | Refused _ | Not_a_snapshot _
   | Unavailable (Store_stopped (Memory_unreadable | Log_unreadable | Store_unwritable | Raised _))
   | Unavailable Keeper_retired ->
     fail "a write on a snapshot the log does not name did not stop the store");
  let diverged =
    "stopped: "
    ^ stop_text
        (Log_diverged
           { expected = Digest.digest_of_bytes last; observed = Digest.digest_of_bytes first })
  in
  check string "resume boots again and finds the same snapshot" diverged (act_text (act Resume));
  check string "bytes the file does not hold are not adopted" "refused: snapshot mismatch"
    (act_text (act (Adopt { observed = Digest.digest_of_bytes last })));
  let before = List.length (commits a) in
  check string "the file's bytes are adopted" "open"
    (act_text (act (Adopt { observed = Digest.digest_of_bytes first })));
  (match List.rev (commits a) with
   | last_line :: _ ->
     (match last_line.cause with
      | Adopt { by; observed } ->
        check (pair string string) "the line names the operator and the snapshot"
          ("operator-1", hex (Digest.digest_of_bytes first))
          (by, hex observed)
      | Direct _ | Read _ | Make_room _ | Skip _ | Molt_and_synthesize _ | Checkpoint _ -> fail "the last commit line is not the adoption")
   | [] -> fail "nothing was committed");
  check int "one line was appended" (before + 1) (List.length (commits a));
  keeper_remembers a owner;
  check string "a Keeper out of the registry is refused" "refused: keeper not registered"
    (act_text
       (Act.act ~base_path:a.base_path ~keeper:"another-keeper" ~actor:"operator-1" Resume))
;;

let test_act_without_writers () =
  with_workspace @@ fun a ->
  check string "a process that started no writers" "no writers"
    (act_text (Act.act ~base_path:a.base_path ~keeper:keeper_name ~actor:"operator-1" Resume))
;;

let () =
  run "Librarian runtime store scope"
    [ "store scope",
        [ test_case "purge removes memory events" `Quick
            test_purge_removes_memory_events
        ; test_case "operator retractions go through the Memory writer" `Quick
            test_operator_retractions_go_through_the_writer
        ; test_case "operator retractions in a process without writers" `Quick
            test_operator_retractions_without_writers
        ; test_case "purge ends the Memory writer first" `Quick
            test_purge_ends_the_memory_writer_first
        ; test_case "the operator's act route and its requests" `Quick test_act_route_and_requests
        ; test_case "an operator restarts reading on a replaced turn log" `Quick
            test_operator_restarts_reading
        ; test_case "an operator skips a line reading stops on" `Quick test_operator_skips_a_line
        ; test_case "an operator resumes and adopts a stopped store" `Quick
            test_operator_resumes_and_adopts
        ; test_case "an operator's action in a process without writers" `Quick
            test_act_without_writers
        ]
    ]
