(** RFC-0476 §3.6: the startup sweep keeps the checkpoint objects a root head
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

let journal_input_head = Keeper_journal_preparation.input_checkpoint_basename

let with_root f =
  let root = Filename.temp_dir "checkpoint-object-sweep-" "" in
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () -> f root)

let journal_inputs_dir root = Filename.concat root "journal-inputs"

let session_dir root session_id =
  Filename.concat (Masc.Keeper_fs.session_store_path_for_runtime_root root) session_id

let sweep_result root =
  Sweep.run ~runtime_root:root ~journal_inputs_dir:(journal_inputs_dir root) ~journal_input_head

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
    ; context = Agent_core.Context.create_sync (); pending_input = None; mcp_sessions = []
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

let test_every_root_keeps_what_it_reaches () = with_root (fun root ->
  let main = "trace-main" and gated = "trace-gated" and copied = "trace-copied" in
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
  let accepted = save_turns ~root ~session_id:main ~marker:"accepted" 2 in
  write
    (List.fold_left Filename.concat (session_dir root main)
       [ Checkpoint.retained_dirname; (accepted.content :> string) ^ ".json" ])
    accepted.head_bytes;
  let gate = save_turns ~root ~session_id:gated ~marker:"gate" 2 in
  hold_in_gate_preparation root ~keeper_name:"gate-keeper" ~session_id:gated gate;
  let journal = save_turns ~root ~session_id:copied ~marker:"journal" 2 in
  write
    (List.fold_left Filename.concat (journal_inputs_dir root) [ "adoption-1"; journal_input_head ])
    journal.head_bytes;
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
  (* Files beside the session directories and the journal inputs. *)
  write (session_dir root main ^ ".checkpoint.lock") "";
  write (Filename.concat (journal_inputs_dir root) ".DS_Store") "";
  let report = sweep root in
  check int "sessions with objects" 3 report.sessions;
  check int "canonical, archive, retained, Gate and journal heads" 5 report.roots;
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
  loads root copied journal;
  check bool "a file not named as an object is left" true (Sys.file_exists notes);
  check bool "a digest under another prefix is left" true (Sys.file_exists misplaced))

(* The store writes through a session root that is a link at the root's
   physical location; the sweep resolves the link as the store does. *)
let test_a_linked_session_root_is_swept () = with_root (fun root ->
  ignore (save_turns ~root ~session_id:"trace-linked" ~marker:"unnamed" 1 : O.plan);
  let configured = Masc.Keeper_fs.session_store_path_for_runtime_root root in
  let physical = Filename.concat root "physical-traces" in
  Unix.rename configured physical;
  Unix.symlink physical configured;
  check bool "the objects are in the linked directory" true (object_files root "trace-linked" <> []);
  let report = sweep root in
  check int "the session behind the link" 1 report.sessions;
  check (list string) "its unnamed objects are removed" [] (object_files root "trace-linked"))

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
         | Sweep.Owner_stores_unreadable _ | Listing_failed _ | Root_unreadable _ | Segment_unreachable _ ->
           false)))
    [ (fun (_ : O.plan) -> "not a head")
    ; (fun (plan : O.plan) ->
        Masc_test_deps.checkpoint_head_bytes_with_field plan.head_bytes "version"
          (`Int (Agent_core.Checkpoint.checkpoint_version + 1))) ]

let test_a_journal_head_it_cannot_read_removes_nothing () = with_root (fun root ->
  ignore (save_turns ~root ~session_id:"trace-refused" ~marker:"unnamed" 2 : O.plan);
  write (List.fold_left Filename.concat (journal_inputs_dir root) [ "adoption-1"; journal_input_head ]) "not a head";
  refused root ~expect:(function
    | Sweep.Root_unusable _ -> true
    | Sweep.Owner_stores_unreadable _ | Listing_failed _ | Root_unreadable _ | Segment_unreachable _ -> false))

let test_a_segment_it_cannot_follow_removes_nothing () = with_root (fun root ->
  let current = save_turns ~root ~session_id:"trace-refused" ~marker:"current" (O.turns_per_segment + 1) in
  write (canonical root "trace-refused") current.head_bytes;
  ignore (save_turns ~root ~session_id:"trace-refused" ~marker:"unnamed" 1 : O.plan);
  (match current.head.history.segment with
   | Some last -> Sys.remove (object_path root "trace-refused" last.segment)
   | None -> fail "the canonical must have a segment");
  refused root ~expect:(function
    | Sweep.Segment_unreachable _ -> true
    | Sweep.Owner_stores_unreadable _ | Listing_failed _ | Root_unreadable _ | Root_unusable _ -> false))

let test_an_unread_operation_store_removes_nothing () = with_root (fun root ->
  ignore (save_turns ~root ~session_id:"trace-refused" ~marker:"unnamed" 2 : O.plan);
  (* A registered keeper whose store was moved aside may hold a Gate head. *)
  register root "moved-aside";
  refused root ~expect:(function
    | Sweep.Owner_stores_unreadable (Retained.Store_missing _) -> true
    | Sweep.Owner_stores_unreadable
        ( Retained.Store_unreadable _ | Metadata_unreadable _ | Prior_input_history_unavailable _
        | Keeper_shares_store_directory _ )
    | Listing_failed _ | Root_unreadable _ | Root_unusable _ | Segment_unreachable _ ->
      false))

let () =
  run "keeper_checkpoint_object_sweep"
    [ ( "sweep"
      , [ test_case "every root keeps what it reaches" `Quick test_every_root_keeps_what_it_reaches
        ; test_case "a linked session root is swept" `Quick test_a_linked_session_root_is_swept
        ; test_case "an earlier version is not a root" `Quick test_an_earlier_version_is_not_a_root
        ; test_case "a head it cannot read removes nothing" `Quick
            test_a_head_it_cannot_read_removes_nothing
        ; test_case "a journal head it cannot read removes nothing" `Quick
            test_a_journal_head_it_cannot_read_removes_nothing
        ; test_case "a segment it cannot follow removes nothing" `Quick
            test_a_segment_it_cannot_follow_removes_nothing
        ; test_case "an unread operation store removes nothing" `Quick
            test_an_unread_operation_store_removes_nothing
        ] ) ]
