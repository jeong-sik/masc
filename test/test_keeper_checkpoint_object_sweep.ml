(** The startup sweep keeps the checkpoint objects a root head
    reaches and removes the rest of a session's [objects/]. *)

open Alcotest
module O = Agent_core.Checkpoint_objects
module Object_store = Masc.Keeper_checkpoint_object_store
module Checkpoint = Masc.Keeper_checkpoint_store
module Sweep = Masc.Keeper_checkpoint_object_sweep
module Retained = Masc.Keeper_retained_checkpoint_sweep
module Store = Keeper_chat_operation_store
module Execution = Keeper_semantic_execution
module Operation = Keeper_chat_operation
module Turn_log = Masc.Keeper_turn_log
module Turn_store = Masc.Keeper_turn_log_store
module Commit_store = Masc.Librarian_log_store
module Unread = Masc.Keeper_unread_turn_bundles

let string_ok = function Ok value -> value | Error detail -> fail detail
let store_ok = function Ok value -> value | Error error -> fail (Store.error_to_string error)

let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | { Unix.st_kind = (Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK); _ } ->
    Sys.remove path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let rec mkdir_p path =
  if not (Sys.file_exists path) then (mkdir_p (Filename.dirname path); Unix.mkdir path 0o755)

let write path contents =
  mkdir_p (Filename.dirname path);
  Out_channel.with_open_bin path (fun channel -> Out_channel.output_string channel contents)

let with_root f =
  let root = Filename.temp_dir "checkpoint-object-sweep-" "" in
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () -> f root)

let session_dir root session_id =
  Filename.concat (Masc.Keeper_fs.session_store_path_for_runtime_root root) session_id

(* Where the Memory writers' commit logs are. *)
let memory_dir root = Filename.concat root "memory"

let sweep_result root =
  Sweep.run ~runtime_root:root ~memory_dir:(memory_dir root)

let sweep root =
  match sweep_result root with Ok report -> report | Error error -> fail (Sweep.error_to_string error)

let message role text =
  Agent_core.Types.
    { origin = Llm_provider.Types.Conversation; role; content = [ Text text ]; name = None
    ; tool_call_id = None; metadata = [] }

let checkpoint ?system_prompt ~session_id messages =
  Agent_core.Checkpoint.
    { provider_binding = None; version = checkpoint_version; session_id; agent_name = "sweep-agent"
    ; model = "test-model"; system_prompt; messages; usage = Agent_core.Types.empty_usage
    ; turn_count = List.length messages; created_at = 1000.0; tools = []; tool_choice = None
    ; disable_parallel_tool_use = false; temperature = None; top_p = None; top_k = None
    ; min_p = None; reasoning_effort = None; enable_thinking = None; preserve_thinking = None
    ; response_format = Agent_core.Types.Off; cache_system_prompt = false
    ; context = Agent_core.Context.create_sync (); pending_input = None
    ; working_context = None }

(* [turns] closed turns of one question and answer each, saved one after the
   other into the session's objects, so more than a segment's worth of them
   leaves segments. The last save's plan. *)
let save_turns ?system_prompt ~root ~session_id ~marker turns =
  let session_dir = session_dir root session_id in
  mkdir_p session_dir;
  let memo = O.create_memo () in
  let rec save index previous messages =
    let messages =
      messages
      @ [ message Agent_core.Types.User (Printf.sprintf "%s ask %d" marker index)
        ; message Agent_core.Types.Assistant (Printf.sprintf "%s answer %d" marker index) ]
    in
    let plan =
      match O.plan_save memo ?previous O.Turn_closes (checkpoint ?system_prompt ~session_id messages) with
      | Ok plan -> plan
      | Error error -> fail (Agent_core.Error.to_string error)
    in
    (match Object_store.write ~session_dir plan.objects with
     | Ok (_ : int) -> ()
     | Error error -> fail (Object_store.write_error_to_string error));
    if index = turns then plan else save (index + 1) (Some plan.head) plan.decoded.messages
  in
  save 1 None []

(* [checkpoint] as an earlier binary wrote it: one whole document at the
   version before this one. *)
let earlier_document (checkpoint : Agent_core.Checkpoint.t) =
  match Agent_core.Checkpoint.to_json checkpoint with
  | `Assoc fields ->
    Yojson.Safe.to_string
      (`Assoc
        (List.map
           (fun (name, value) ->
              if String.equal name "version"
              then name, `Int (Agent_core.Checkpoint.checkpoint_version - 1)
              else name, value)
           fields))
  | _ -> fail "a checkpoint document is an object"

let canonical root session_id =
  Checkpoint.agent_core_checkpoint_path ~session_dir:(session_dir root session_id) ~session_id

let object_path root session_id digest =
  Object_store.path ~session_dir:(session_dir root session_id) digest

(* Every object file a session holds, by name. *)
let object_files root session_id =
  let objects = Filename.concat (session_dir root session_id) Object_store.dirname in
  if not (Sys.file_exists objects) then []
  else
    Sys.readdir objects |> Array.to_list
    |> List.concat_map (fun prefix -> Sys.readdir (Filename.concat objects prefix) |> Array.to_list)
    |> List.sort String.compare

(* The head loads back whole from what the session holds. *)
let loads root session_id (plan : O.plan) =
  match O.head_of_string plan.head_bytes with
  | Error error -> fail (O.load_error_to_string error)
  | Ok head ->
    (match O.load (O.create_memo ()) ~read_object:(Object_store.read ~session_dir:(session_dir root session_id)) head with
     | Ok checkpoint ->
       check int "the head loads every message" (List.length plan.decoded.messages)
         (List.length checkpoint.messages)
     | Error error -> fail (O.load_error_to_string error))

let register root keeper_name =
  write
    (Filename.concat (Filename.concat root Common.keepers_runtime_dirname)
       (Keeper_runtime_root_entry.keeper_basename ~keeper_name Keeper_runtime_root_entry.Metadata))
    "{}"

(* A direct operation waiting on its Gate binding holds [plan]'s head in the
   keeper's operation store. *)
let hold_in_gate_preparation root ~keeper_name ~session_id (plan : O.plan) =
  register root keeper_name;
  let path =
    Store.path_for_keeper
      ~keepers_runtime_dir:(Filename.concat root Common.keepers_runtime_dirname)
      ~keeper_name
  in
  mkdir_p (Filename.dirname path);
  let store = Store.open_or_create ~path |> store_ok in
  Fun.protect ~finally:(fun () -> Store.close store |> store_ok) (fun () ->
    let operation_id = Operation.Operation_id.of_string "sweep-gate" |> string_ok in
    let input =
      match Operation.canonical_json (`Assoc [ "message", `String "approve first" ]) with
      | Ok input -> input
      | Error _ -> fail "invalid canonical input fixture"
    in
    ignore
      (Store.submit store ~now:10. ~operation_id ~source:(`Assoc [ "channel", `String "dashboard" ]) ~input
       |> store_ok);
    let operation =
      match Store.claim_next store ~now:11. |> store_ok with
      | Some operation -> operation
      | None -> fail "gate operation was not queued"
    in
    let reference =
      Keeper_checkpoint_ref.of_persisted
        ~trace_id:(Keeper_id.Trace_id.of_string session_id |> string_ok)
        ~turn_count:plan.head.header.turn_count ~sha256:(plan.content :> string)
      |> Result.map_error Checkpoint.checkpoint_ref_create_error_to_string
      |> string_ok
    in
    let binding =
      Execution.gate_binding
        ~preparation:(Execution.Prepared_agent_core { reference; canonical_checkpoint_bytes = plan.head_bytes })
        ~approval_ids:[ "approval-1" ] ~obligations:[] ~runtime_suffix:None
      |> string_ok
    in
    ignore
      (Store.defer_direct_gate_reconciliation store ~now:12. ~operation_id
         ~execution_digest:operation.execution_digest ~binding ~diagnostic:"held in the store"
       |> store_ok))

(* The one bundle a save of one turn closed. *)
let only_bundle (plan : O.plan) =
  match plan.head.history.turns with
  | [ turn ] -> turn.bundle
  | _ -> fail "one closed turn"

let log_id hex =
  match Turn_log.Log_id.of_string (String.make 32 hex) with
  | Some id -> id
  | None -> fail "a turn log id is 32 hexadecimal characters"

(* The Keeper whose turn log and commit log the sweep reads. *)
let reader = "reader"
let reader_log = log_id 'c'

let turn_log_path root =
  Turn_store.path_for_keepers_dir
    ~keepers_dir:(Filename.concat root Common.keepers_runtime_dirname)
    ~keeper_id:reader

let commit_log_path root =
  Commit_store.path_for_keepers_dir ~keepers_dir:(memory_dir root) ~keeper_id:reader

let mark ~trace closed_messages = Masc_test_deps.turn_log_mark ~trace_id:trace ~closed_messages

let append_line root ~at_end line =
  let path = turn_log_path root in
  mkdir_p (Filename.dirname path);
  match Turn_store.append ~path ~at_end (line, []) with
  | Ok appended -> appended
  | Error (_ : Turn_store.append_error) -> fail "a turn log line was not appended"

(* The reader's turn log, started in [trace] before any message. Its end. *)
let start_log root ~trace =
  (append_line root ~at_end:0
     (Turn_log.Log_started { id = reader_log; at = 1.0; mark = mark ~trace 0 }))
    .Turn_store.new_end

(* One completed turn of [trace] after [closed] closed messages, appended at
   [at_end]: its [Opened] line, then a [Closed] line whose own content is the
   two messages of [bundle]. Where the [Opened] line starts, and the log's new
   end. *)
let append_turn root ~at_end ~trace ~closed bundle =
  let opened =
    append_line root ~at_end
      (Turn_log.Opened
         { at = 2.0
         ; turn_ref = Ids.Turn_ref.make ~trace_id:trace ~absolute_turn:((closed / 2) + 1)
         ; runtime = "fixture"
         ; task = Turn_log.No_task
         ; stimuli = []
         ; baseline = mark ~trace closed
         })
  in
  let closing =
    append_line root ~at_end:opened.Turn_store.new_end
      (Turn_log.Closed
         { turn = opened.Turn_store.last_at
         ; at = 3.0
         ; outcome = Turn_log.Completed
         ; after = mark ~trace (closed + 2)
         ; unattributed = []
         ; own = [ { Turn_log.bundle; skip = 0; take = 2 } ]
         })
  in
  opened.Turn_store.last_at, closing.Turn_store.new_end

(* The reader's commit log ends in a line saying it reads [turn_log] next at
   [turn_log_offset]. *)
let commit_tail root ~turn_log ~turn_log_offset =
  let path = commit_log_path root in
  mkdir_p (Filename.dirname path);
  match
    Commit_store.append ~path ~at_end:0
      (Masc.Librarian_log.Started
         { at = 4.0
         ; turn_log
         ; snapshot = O.digest_of_bytes "snapshot"
         ; revision = 0
         ; turn_log_offset
         ; covered = mark ~trace:"trace-reader" 0
         })
  with
  | Ok (_ : Commit_store.appended) -> ()
  | Error (_ : Commit_store.append_error) -> fail "the commit log line was not appended"

let test_every_root_keeps_what_it_reaches () = with_root (fun root ->
  let main = "trace-main" and gated = "trace-gated" in
  (* The canonical's turns before its last segment are named only through
     that segment and the one before it. *)
  let current = save_turns ~root ~session_id:main ~marker:"current" ((2 * O.turns_per_segment) + 6) in
  (match current.head.history.segment with
   | Some last ->
     check int "two segments of two messages a turn" (2 * 2 * O.turns_per_segment) last.segment_messages
   | None -> fail "the canonical must have segments");
  write (canonical root main) current.head_bytes;
  let archived = save_turns ~root ~session_id:main ~marker:"archived" 2 in
  write
    (Filename.concat (session_dir root main)
       (Checkpoint.agent_core_history_snapshot_id_of_checkpoint archived.decoded))
    archived.head_bytes;
  (* The store links a history archive to the canonical it copies. *)
  Unix.link (canonical root main)
    (Filename.concat (session_dir root main)
       (Checkpoint.agent_core_history_snapshot_id_of_checkpoint
          { current.decoded with Agent_core.Checkpoint.created_at = 2000.0 }));
  (* A retained checkpoint an earlier binary wrote as a whole document. *)
  write
    (List.fold_left Filename.concat (session_dir root main) [ Checkpoint.retained_dirname; "earlier.json" ])
    (earlier_document archived.decoded);
  let accepted = save_turns ~root ~session_id:main ~marker:"accepted" 2 in
  write
    (List.fold_left Filename.concat (session_dir root main)
       [ Checkpoint.retained_dirname; (accepted.content :> string) ^ ".json" ])
    accepted.head_bytes;
  let gate = save_turns ~root ~session_id:gated ~marker:"gate" 2 in
  hold_in_gate_preparation root ~keeper_name:"gate-keeper" ~session_id:gated gate;
  (* Objects no head names: one turn saved without a head, so its plan
     lists every object the save wrote. Its own system prompt leaves its tools
     object the only one a root also names. *)
  let orphan = save_turns ~system_prompt:"orphan prompt" ~root ~session_id:main ~marker:"orphan" 1 in
  let shared = orphan.head.header_objects.tools in
  let unreached =
    List.filter
      (fun ((digest : O.digest), _) -> not (String.equal (digest :> string) (shared :> string)))
      orphan.objects
  in
  (* Entries the sweep does not own. *)
  let objects = Filename.concat (session_dir root main) Object_store.dirname in
  let notes = List.fold_left Filename.concat objects [ "ab"; "notes.txt" ] in
  let misplaced = List.fold_left Filename.concat objects [ "00"; String.make 64 'f' ] in
  write notes "operator notes";
  write misplaced "a digest under another prefix";
  (* A file beside the session directories. *)
  write (session_dir root main ^ ".checkpoint.lock") "";
  let report = sweep root in
  check int "sessions with objects" 2 report.sessions;
  check int "canonical, two archives, retained and Gate heads" 5 report.roots;
  check int "what no root reaches is removed" (List.length unreached) report.removed;
  check (list string) "no failures" [] report.failures;
  List.iter
    (fun (digest, _) ->
       check bool "an unreached object is removed" false (Sys.file_exists (object_path root main digest)))
    unreached;
  check bool "an object a root also names is kept" true (Sys.file_exists (object_path root main shared));
  loads root main current;
  loads root main archived;
  loads root main accepted;
  loads root gated gate;
  check bool "a file not named as an object is left" true (Sys.file_exists notes);
  check bool "a digest under another prefix is left" true (Sys.file_exists misplaced))

(* The store writes through a session root that is a link at the root's
   physical location; the sweep resolves the link as the store does. *)
let test_a_linked_session_root_is_swept () = with_root (fun root ->
  let kept = save_turns ~root ~session_id:"trace-linked" ~marker:"kept" 2 in
  write (canonical root "trace-linked") kept.head_bytes;
  let orphan = save_turns ~system_prompt:"orphan prompt" ~root ~session_id:"trace-linked" ~marker:"unnamed" 1 in
  let configured = Masc.Keeper_fs.session_store_path_for_runtime_root root in
  let physical = Filename.concat root "physical-traces" in
  Unix.rename configured physical;
  Unix.symlink physical configured;
  let report = sweep root in
  check int "the session behind the link" 1 report.sessions;
  check int "the canonical behind the link is a root" 1 report.roots;
  (* The store reads the session at its physical place. *)
  Unix.unlink configured;
  Unix.rename physical configured;
  loads root "trace-linked" kept;
  check bool "the orphan's bundle is removed" false
    (Sys.file_exists
       (object_path root "trace-linked"
          (match orphan.head.history.turns with
           | [ turn ] -> turn.bundle
           | _ -> fail "one closed turn"))))

let test_an_earlier_version_is_not_a_root () = with_root (fun root ->
  let session_id = "trace-superseded" in
  let earlier = save_turns ~root ~session_id ~marker:"earlier" 3 in
  write (canonical root session_id)
    (Masc_test_deps.checkpoint_head_bytes_with_field earlier.head_bytes "version"
       (`Int (Agent_core.Checkpoint.checkpoint_version - 1)));
  let stored = object_files root session_id in
  let report = sweep root in
  check int "no current root" 0 report.roots;
  check int "every object of the earlier head is removed" (List.length stored) report.removed;
  check (list string) "nothing is left" [] (object_files root session_id))

(* A session listed before the refused one holds only objects no head names:
   they stay too, because every root is read before anything is removed. *)
let refused root ~expect =
  ignore (save_turns ~root ~session_id:"trace-early" ~marker:"early" 1 : O.plan);
  let early = object_files root "trace-early" in
  let before = object_files root "trace-refused" in
  check bool "the session holds objects" true (before <> []);
  (match sweep_result root with
   | Ok _ -> fail "the sweep must stop"
   | Error error -> check bool (Sweep.error_to_string error) true (expect error));
  check (list string) "nothing is removed" before (object_files root "trace-refused");
  check (list string) "nothing is removed in an earlier session" early (object_files root "trace-early")

let test_a_head_it_cannot_read_removes_nothing () =
  List.iter
    (fun head_bytes -> with_root (fun root ->
       let unnamed = save_turns ~root ~session_id:"trace-refused" ~marker:"unnamed" 2 in
       write (canonical root "trace-refused") (head_bytes unnamed);
       refused root ~expect:(function
         | Sweep.Root_unusable _ -> true
         | Sweep.Owner_stores_unreadable _ | Listing_failed _ | Root_unreadable _ | Segment_unreachable _
         | Unread_lines_unreadable _ ->
           false)))
    [ (fun (_ : O.plan) -> "not a head")
    ; (fun (plan : O.plan) ->
        Masc_test_deps.checkpoint_head_bytes_with_field plan.head_bytes "version"
          (`Int (Agent_core.Checkpoint.checkpoint_version + 1))) ]

let test_a_retained_entry_that_is_not_a_directory_removes_nothing () = with_root (fun root ->
  ignore (save_turns ~root ~session_id:"trace-refused" ~marker:"unnamed" 2 : O.plan);
  write (Filename.concat (session_dir root "trace-refused") Checkpoint.retained_dirname) "not a directory";
  refused root ~expect:(function
    | Sweep.Listing_failed _ -> true
    | Sweep.Owner_stores_unreadable _ | Root_unreadable _ | Root_unusable _ | Segment_unreachable _
    | Unread_lines_unreadable _ -> false))

let test_a_segment_it_cannot_follow_removes_nothing () = with_root (fun root ->
  let current = save_turns ~root ~session_id:"trace-refused" ~marker:"current" (O.turns_per_segment + 1) in
  write (canonical root "trace-refused") current.head_bytes;
  ignore (save_turns ~root ~session_id:"trace-refused" ~marker:"unnamed" 1 : O.plan);
  (match current.head.history.segment with
   | Some last -> Sys.remove (object_path root "trace-refused" last.segment)
   | None -> fail "the canonical must have a segment");
  refused root ~expect:(function
    | Sweep.Segment_unreachable _ -> true
    | Sweep.Owner_stores_unreadable _ | Listing_failed _ | Root_unreadable _ | Root_unusable _
    | Unread_lines_unreadable _ -> false))

let test_an_unread_operation_store_removes_nothing () = with_root (fun root ->
  ignore (save_turns ~root ~session_id:"trace-refused" ~marker:"unnamed" 2 : O.plan);
  (* A registered keeper whose store was moved aside may hold a Gate head. *)
  register root "moved-aside";
  refused root ~expect:(function
    | Sweep.Owner_stores_unreadable (Retained.Store_missing _) -> true
    | Sweep.Owner_stores_unreadable
        ( Retained.Store_unreadable _ | Metadata_unreadable _ | Prior_input_history_unavailable _
        | Keeper_shares_store_directory _ )
    | Listing_failed _ | Root_unreadable _ | Root_unusable _ | Segment_unreachable _
    | Unread_lines_unreadable _ ->
      false))

(* Two closed turns of one session whose bundles no head names: only the
   turn-log lines the reader has yet to read keep them. The commit log tail
   says where those lines start, when it places the reader in this log. *)
let test_unread_lines_keep_what_they_point_at () =
  List.iter
    (fun (label, tail, first_kept, second_kept) -> with_root (fun root ->
       let session_id = "trace-reader" in
       let first, second =
         match (save_turns ~root ~session_id ~marker:"turn" 2).head.history.turns with
         | [ first; second ] -> first.bundle, second.bundle
         | _ -> fail "two closed turns"
       in
       let started = start_log root ~trace:session_id in
       let (_ : int), first_end = append_turn root ~at_end:started ~trace:session_id ~closed:0 first in
       let second_at, log_end = append_turn root ~at_end:first_end ~trace:session_id ~closed:2 second in
       tail root ~second_at ~log_end;
       ignore (sweep root : Sweep.report);
       check bool (label ^ ": the first turn's bundle") first_kept
         (Sys.file_exists (object_path root session_id first));
       check bool (label ^ ": the second turn's bundle") second_kept
         (Sys.file_exists (object_path root session_id second))))
    [ ( "read through the first turn"
      , (fun root ~second_at ~log_end:_ -> commit_tail root ~turn_log:reader_log ~turn_log_offset:second_at)
      , false
      , true )
    ; ( "read through the log's end"
      , (fun root ~second_at:_ ~log_end -> commit_tail root ~turn_log:reader_log ~turn_log_offset:log_end)
      , false
      , false )
    ; "no commit log", (fun _ ~second_at:_ ~log_end:_ -> ()), true, true
    ; ( "a tail naming another turn log"
      , (fun root ~second_at ~log_end:_ -> commit_tail root ~turn_log:(log_id 'd') ~turn_log_offset:second_at)
      , true
      , true )
    ; ( "an offset inside a line"
      , (fun root ~second_at ~log_end:_ ->
          commit_tail root ~turn_log:reader_log ~turn_log_offset:(second_at + 1))
      , true
      , true )
    ; ( "a commit log that does not decode"
      , (fun root ~second_at:_ ~log_end:_ -> write (commit_log_path root) "not a commit line\n")
      , true
      , true ) ]

(* A [Reset] line's bundles belong to the trace before it and a [Closed]
   line's to the trace after it. *)
let test_a_line_keeps_its_bundles_in_its_own_trace () = with_root (fun root ->
  let before = "trace-before" and after = "trace-after" in
  let before_plan = save_turns ~root ~session_id:before ~marker:"before" 1 in
  let closed_before = only_bundle before_plan in
  let closed_after = only_bundle (save_turns ~root ~session_id:after ~marker:"after" 1) in
  let started = start_log root ~trace:before in
  let reset =
    append_line root ~at_end:started
      (Turn_log.Reset
         { at = 5.0
         ; cause = Turn_log.Unannounced
         ; before = mark ~trace:before 2
         ; after = mark ~trace:after 0
         ; closed_before = [ { Turn_log.bundle = closed_before; skip = 0; take = 2 } ]
         })
  in
  ignore (append_turn root ~at_end:reset.Turn_store.new_end ~trace:after ~closed:0 closed_after : int * int);
  ignore (sweep root : Sweep.report);
  check bool "the reset keeps its bundle in the trace before it" true
    (Sys.file_exists (object_path root before closed_before));
  check bool "the turn after it keeps its bundle in its own trace" true
    (Sys.file_exists (object_path root after closed_after));
  check bool "what no line names is removed" false
    (Sys.file_exists (object_path root before before_plan.head.header_objects.system_prompt)))

let unread_lines_refused = function
  | Sweep.Unread_lines_unreadable error -> Some error
  | Sweep.Owner_stores_unreadable _ | Listing_failed _ | Root_unreadable _ | Root_unusable _
  | Segment_unreachable _ ->
    None

let test_a_turn_log_it_cannot_read_removes_nothing () = with_root (fun root ->
  ignore (save_turns ~root ~session_id:"trace-refused" ~marker:"unnamed" 2 : O.plan);
  write (turn_log_path root) "not a turn log line\n";
  refused root ~expect:(fun error ->
    match unread_lines_refused error with
    | Some (Unread.Turn_log_unreadable _) -> true
    | Some (Unread.Listing_failed _ | Unread.Line_undecodable _) | None -> false))

let test_an_unread_line_it_cannot_decode_removes_nothing () = with_root (fun root ->
  ignore (save_turns ~root ~session_id:"trace-refused" ~marker:"unnamed" 2 : O.plan);
  ignore (start_log root ~trace:"trace-refused" : int);
  Out_channel.with_open_gen [ Open_wronly; Open_append; Open_binary ] 0o644 (turn_log_path root) (fun channel ->
    Out_channel.output_string channel "not a turn log line\n");
  refused root ~expect:(fun error ->
    match unread_lines_refused error with
    | Some (Unread.Line_undecodable _) -> true
    | Some (Unread.Listing_failed _ | Unread.Turn_log_unreadable _) | None -> false))

let () =
  run "keeper_checkpoint_object_sweep"
    [ ( "sweep"
      , [ test_case "every root keeps what it reaches" `Quick test_every_root_keeps_what_it_reaches
        ; test_case "a linked session root is swept" `Quick test_a_linked_session_root_is_swept
        ; test_case "an earlier version is not a root" `Quick test_an_earlier_version_is_not_a_root
        ; test_case "a head it cannot read removes nothing" `Quick
            test_a_head_it_cannot_read_removes_nothing
        ; test_case "a retained entry that is not a directory removes nothing" `Quick
            test_a_retained_entry_that_is_not_a_directory_removes_nothing
        ; test_case "a segment it cannot follow removes nothing" `Quick
            test_a_segment_it_cannot_follow_removes_nothing
        ; test_case "an unread operation store removes nothing" `Quick
            test_an_unread_operation_store_removes_nothing
        ] )
    ; ( "unread turn-log lines"
      , [ test_case "unread lines keep what they point at" `Quick test_unread_lines_keep_what_they_point_at
        ; test_case "a line keeps its bundles in its own trace" `Quick
            test_a_line_keeps_its_bundles_in_its_own_trace
        ; test_case "a turn log it cannot read removes nothing" `Quick
            test_a_turn_log_it_cannot_read_removes_nothing
        ; test_case "an unread line it cannot decode removes nothing" `Quick
            test_an_unread_line_it_cannot_decode_removes_nothing
        ] ) ]
