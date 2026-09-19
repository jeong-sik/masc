(** Tests for {!Masc.Keeper_turn_boundaries} (RFC librarian-lifecycle §4.6):
    the line a finished keeper turn leaves to say where its saved atom history
    ended, and the line that says a history holds no atom, which
    {!Masc.Keeper_history_clear} leaves once it has emptied one and a turn
    leaves when it starts from one. *)

open Alcotest

module Boundaries = Masc.Keeper_turn_boundaries
module Wire = Masc.Keeper_memory_os_types
module Window = Runtime_model_input_tail_window
module Types = Agent_core.Types

let keeper_id = "keeper"

let with_temp_keepers f =
  let path = Filename.temp_file "turn-boundaries-" ".dir" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree path)
    (fun () -> f path)
;;

let message ~role text : Types.message =
  { role
  ; content = [ Types.Text text ]
  ; name = None
  ; tool_call_id = None
  ; metadata = []
  }
;;

let record
      ?(turn = 1)
      ?(trace_id = "trace")
      ?(history_at_start = Boundaries.Continued_history)
      position
  : Boundaries.record
  =
  { Boundaries.recorded_at = 200.0
  ; event =
      Boundaries.Turn_ended
        { turn_ref = Ids.Turn_ref.make ~trace_id ~absolute_turn:turn
        ; history_at_start
        ; position
        }
  }
;;

let history_empty ?(trace_id = "trace") () : Boundaries.record =
  { Boundaries.recorded_at = 200.0; event = Boundaries.History_empty { trace_id } }
;;

let atom_history = Boundaries.Atom_history { end_atom = 2; last_atom_digest = "digest" }

let every_position =
  [ atom_history
  ; Boundaries.Empty_atom_history
  ; Boundaries.No_atom_history
  ; Boundaries.Stale_noop
  ]
;;

let every_history_at_start = [ Boundaries.Fresh_history; Boundaries.Continued_history ]

let print_record fmt written =
  Format.pp_print_string fmt (Yojson.Safe.to_string (Boundaries.record_to_json written))
;;

let record_equal (left : Boundaries.record) (right : Boundaries.record) =
  Float.equal left.recorded_at right.recorded_at
  &&
  match left.event, right.event with
  | ( Boundaries.Turn_ended
        { turn_ref = left_ref; history_at_start = left_start; position = left_position }
    , Boundaries.Turn_ended
        { turn_ref = right_ref; history_at_start = right_start; position = right_position }
    ) ->
    Ids.Turn_ref.equal left_ref right_ref
    && left_start = right_start
    && left_position = right_position
  | ( Boundaries.History_empty { trace_id = left_trace }
    , Boundaries.History_empty { trace_id = right_trace } ) ->
    String.equal left_trace right_trace
  | Boundaries.Turn_ended _, Boundaries.History_empty _
  | Boundaries.History_empty _, Boundaries.Turn_ended _ -> false
;;

let record_t : Boundaries.record testable = testable print_record record_equal

let position_t : Boundaries.position testable =
  testable (fun fmt position -> print_record fmt (record position)) ( = )
;;

let test_every_position_kind_round_trips () =
  List.iter
    (fun history_at_start ->
       List.iter
         (fun position ->
            let written = record ~history_at_start position in
            match Boundaries.record_of_json (Boundaries.record_to_json written) with
            | Ok decoded -> check record_t "round trip" written decoded
            | Error error ->
              failf "round trip rejected: %s" (Wire.wire_error_to_string error))
         every_position)
    every_history_at_start;
  let written = history_empty () in
  match Boundaries.record_of_json (Boundaries.record_to_json written) with
  | Ok decoded -> check record_t "an empty history round trips" written decoded
  | Error error -> failf "round trip rejected: %s" (Wire.wire_error_to_string error)
;;

(* The wire form is a contract with lines already on disk, so it is pinned as
   text: the tag that lets a later kind of line be a new constructor, no
   session id beside the turn reference that already carries the trace id, and
   the two tokens a reader branches on. *)
let test_the_line_a_turn_writes () =
  check string "a continued turn that ended an atom history"
    {|{"kind":"turn_ended","recorded_at":200.0,"turn_ref":"trace#1","history_at_start":"continued","position":{"kind":"atom_history","end_atom":2,"last_atom_digest":"digest"}}|}
    (Yojson.Safe.to_string (Boundaries.record_to_json (record atom_history)));
  check string "a fresh turn whose save was a stale no-op"
    {|{"kind":"turn_ended","recorded_at":200.0,"turn_ref":"trace#1","history_at_start":"fresh","position":{"kind":"stale_noop"}}|}
    (Yojson.Safe.to_string
       (Boundaries.record_to_json
          (record ~history_at_start:Boundaries.Fresh_history Boundaries.Stale_noop)))
;;

(* The line is not a turn's, so it names the trace and nothing of a turn: no
   turn reference, and no position, since a history with no atom has only one.
   Its kind says what the writer saw and not that the writer was a clear. *)
let test_the_line_for_an_empty_history () =
  check string "an empty history"
    {|{"kind":"history_empty","recorded_at":200.0,"trace_id":"trace"}|}
    (Yojson.Safe.to_string (Boundaries.record_to_json (history_empty ())))
;;

let fields_of label (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields -> fields
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    failf "%s is not an object" label
;;

let without name fields = List.filter (fun (key, _) -> not (String.equal key name)) fields

let replacing name value fields =
  List.map (fun (key, old) -> if String.equal key name then key, value else key, old) fields
;;

(* The line for [written] with its fields passed through [edit]. *)
let with_fields edit written : Yojson.Safe.t =
  `Assoc (edit (fields_of "record" (Boundaries.record_to_json written)))
;;

(* The line for [written] with the fields of its position passed through
   [edit]. *)
let with_position edit written : Yojson.Safe.t =
  with_fields
    (List.map (fun (key, value) ->
       if String.equal key "position"
       then key, `Assoc (edit (fields_of "position" value))
       else key, value))
    written
;;

(* A rejection is compared by where and why, so a line refused for another
   defect than the one the case plants does not pass. *)
let check_rejection label ~path ~reason json =
  match Boundaries.record_of_json json with
  | Ok _ -> failf "%s: accepted" label
  | Error error ->
    check string label
      (Wire.wire_error_to_string { Wire.path; reason })
      (Wire.wire_error_to_string error)
;;

let test_decode_refuses_what_its_kind_does_not_carry () =
  check_rejection "a kind this build does not know"
    ~path:[ Wire.Wire_field "position"; Wire.Wire_field "kind" ]
    ~reason:(Wire.Unknown_token "somewhere_else")
    (with_position
       (replacing "kind" (`String "somewhere_else"))
       (record Boundaries.No_atom_history));
  check_rejection "an atom history without its digest"
    ~path:[ Wire.Wire_field "position" ]
    ~reason:
      (Wire.Field_set_mismatch { missing = [ "last_atom_digest" ]; unexpected = [] })
    (with_position (without "last_atom_digest") (record atom_history));
  check_rejection "an empty history that names an end"
    ~path:[ Wire.Wire_field "position" ]
    ~reason:(Wire.Field_set_mismatch { missing = []; unexpected = [ "end_atom" ] })
    (with_position
       (fun fields -> fields @ [ "end_atom", `Int 2 ])
       (record Boundaries.Empty_atom_history));
  check_rejection "a kind of line this build does not know"
    ~path:[ Wire.Wire_field "kind" ]
    ~reason:(Wire.Unknown_token "no_such_line")
    (with_fields (replacing "kind" (`String "no_such_line")) (record atom_history));
  (* A kind names its own field set: a turn's fields under another kind are the
     wrong fields, not a turn line with a different tag. *)
  check_rejection "a turn's fields under the kind of an empty history"
    ~path:[]
    ~reason:
      (Wire.Field_set_mismatch
         { missing = [ "trace_id" ]
         ; unexpected = [ "history_at_start"; "position"; "turn_ref" ]
         })
    (with_fields (replacing "kind" (`String "history_empty")) (record atom_history));
  check_rejection "an empty history that does not name its trace"
    ~path:[]
    ~reason:(Wire.Field_set_mismatch { missing = [ "trace_id" ]; unexpected = [] })
    (with_fields (without "trace_id") (history_empty ()));
  check_rejection "an empty history that states a position"
    ~path:[]
    ~reason:(Wire.Field_set_mismatch { missing = []; unexpected = [ "position" ] })
    (with_fields
       (fun fields -> fields @ [ "position", `Assoc [ "kind", `String "empty_atom_history" ] ])
       (history_empty ()));
  check_rejection "a line without its kind"
    ~path:[]
    ~reason:(Wire.Field_set_mismatch { missing = [ "kind" ]; unexpected = [] })
    (with_fields (without "kind") (record atom_history));
  check_rejection "a line that does not say how its history began"
    ~path:[]
    ~reason:(Wire.Field_set_mismatch { missing = [ "history_at_start" ]; unexpected = [] })
    (with_fields (without "history_at_start") (record atom_history));
  (* The trace id lives in [turn_ref]. A second copy beside it is a field this
     line does not carry. *)
  check_rejection "a line that repeats the trace id as a session id"
    ~path:[]
    ~reason:(Wire.Field_set_mismatch { missing = []; unexpected = [ "session_id" ] })
    (with_fields (fun fields -> fields @ [ "session_id", `String "trace" ]) (record atom_history));
  check_rejection "a line with a field no reader knows"
    ~path:[]
    ~reason:(Wire.Field_set_mismatch { missing = []; unexpected = [ "extra" ] })
    (with_fields (fun fields -> fields @ [ "extra", `Null ]) (record atom_history))
;;

let test_decode_refuses_values_no_writer_writes () =
  check_rejection "an empty history of no trace"
    ~path:[ Wire.Wire_field "trace_id" ]
    ~reason:Wire.Blank_string
    (with_fields (replacing "trace_id" (`String " ")) (history_empty ()));
  check_rejection "an atom history that ends before its first atom"
    ~path:[ Wire.Wire_field "position"; Wire.Wire_field "end_atom" ]
    ~reason:Wire.Not_positive
    (with_position (replacing "end_atom" (`Int 0)) (record atom_history));
  check_rejection "a blank digest"
    ~path:[ Wire.Wire_field "position"; Wire.Wire_field "last_atom_digest" ]
    ~reason:Wire.Blank_string
    (with_position (replacing "last_atom_digest" (`String " ")) (record atom_history));
  check_rejection "a history start neither fresh nor continued"
    ~path:[ Wire.Wire_field "history_at_start" ]
    ~reason:(Wire.Unknown_token "sometimes")
    (with_fields (replacing "history_at_start" (`String "sometimes")) (record atom_history));
  check_rejection "a turn reference with no turn number"
    ~path:[ Wire.Wire_field "turn_ref" ]
    ~reason:(Wire.Not_a_turn_ref "no-turn-number")
    (with_fields (replacing "turn_ref" (`String "no-turn-number")) (record atom_history));
  check_rejection "a time that is not finite"
    ~path:[ Wire.Wire_field "recorded_at" ]
    ~reason:Wire.Not_finite
    (with_fields (replacing "recorded_at" (`Float Float.infinity)) (record atom_history))
;;

let position_of label messages =
  match Boundaries.position_of_messages messages with
  | Ok position -> position
  | Error detail -> failf "%s: %s" label detail
;;

(* The position speaks the window's atom vocabulary, so the expected end is what
   the window itself reports for the same messages: its atom count and its
   opening digest of the last atom. *)
let test_position_agrees_with_the_window () =
  check position_t "no message is no atom" Boundaries.Empty_atom_history
    (position_of "empty history" []);
  check position_t "a pinned message is not an atom" Boundaries.Empty_atom_history
    (position_of "system only" [ message ~role:Types.System "system" ]);
  let history =
    [ message ~role:Types.User "question"
    ; message ~role:Types.Assistant "calling a tool"
    ; message ~role:Types.Tool "tool result"
    ]
  in
  let _labelled, atom_count = Window.annotate history in
  check int "the tool result joins the atom its assistant opened" 2 atom_count;
  match Window.atom_opening_digest history (atom_count - 1) with
  | None -> fail "the window has no opening digest for the last atom"
  | Some last_atom_digest ->
    check position_t "the end is the window's atom count and last opening digest"
      (Boundaries.Atom_history { end_atom = atom_count; last_atom_digest })
      (position_of "user, assistant and tool" history)
;;

(* What a reader asks of [history_at_start] is whether the atoms this turn saved
   are numbered from zero, so it is read off the history the turn started from
   and not off whether a checkpoint file was there. A keeper is created with a
   checkpoint that holds no message, and a cleared history is a checkpoint too:
   both used to be written as a continued history, which left a new keeper's
   trace with no line to say its history began at atom zero. *)
let test_a_history_with_no_atom_is_a_fresh_start () =
  let history_at_start_t : Boundaries.history_at_start testable =
    testable
      (fun fmt start -> print_record fmt (record ~history_at_start:start atom_history))
      ( = )
  in
  check history_at_start_t "no message" Boundaries.Fresh_history
    (Boundaries.history_at_start_of_messages []);
  check history_at_start_t "pinned messages only" Boundaries.Fresh_history
    (Boundaries.history_at_start_of_messages [ message ~role:Types.System "system" ]);
  check history_at_start_t "one atom" Boundaries.Continued_history
    (Boundaries.history_at_start_of_messages
       [ message ~role:Types.System "system"; message ~role:Types.User "question" ])
;;

(* A turn that reaches the boundary line with no saved checkpoint is one of two
   things, and the checkpoint owner says which: an official client, which keeps
   no Agent-Core checkpoint, or an agent-core turn whose save was a stale no-op.
   The second used to be written as the first. *)
let test_a_turn_without_a_saved_checkpoint () =
  let position_without_checkpoint checkpoint_owner =
    match
      Masc.Keeper_agent_run_finalize_response.turn_boundary_position
        ~checkpoint_owner
        None
    with
    | Ok position -> position
    | Error detail -> failf "no checkpoint has no messages to reject: %s" detail
  in
  check position_t "an official client has no atom history" Boundaries.No_atom_history
    (position_without_checkpoint Runtime_execution.Official_client);
  check position_t "an agent-core turn saved nothing of its own" Boundaries.Stale_noop
    (position_without_checkpoint Runtime_execution.Masc_agent_core)
;;

let read_lines ~keepers_dir =
  match Boundaries.read ~keepers_dir ~keeper_id with
  | Error message -> failf "turn boundary store: %s" message
  | Ok lines ->
    List.map
      (fun (line, result) ->
         match result with
         | Ok written -> line, written
         | Error error ->
           failf "turn boundary line %d: %s" line (Boundaries.read_error_to_string error))
      lines
;;

let test_appended_lines_read_back_in_order () =
  with_temp_keepers @@ fun keepers_dir ->
  check int "a keeper with no finished turn has no line" 0
    (List.length (read_lines ~keepers_dir));
  let written =
    List.mapi (fun index position -> record ~turn:(index + 1) position) every_position
    @ [ history_empty () ]
  in
  List.iter
    (fun line ->
       match Boundaries.append ~keepers_dir ~keeper_id line with
       | Ok () -> ()
       | Error error -> failf "append: %s" (Boundaries.append_error_to_string error))
    written;
  check (list (pair int record_t)) "one numbered line per append, in the order appended"
    (List.mapi (fun index line -> index + 1, line) written)
    (read_lines ~keepers_dir);
  check string "the file the RFC names" "keeper.turn-boundaries.jsonl"
    (Filename.basename (Boundaries.path_for_keepers_dir ~keepers_dir ~keeper_id))
;;

(* [Ids.Turn_ref.make] takes an empty trace id and [Ids.Turn_ref.of_string]
   refuses it, so writing such a line would leave a row no reader decodes. *)
let test_a_line_no_reader_decodes_is_not_written () =
  with_temp_keepers @@ fun keepers_dir ->
  List.iter
    (fun (label, unreadable) ->
       match Boundaries.append ~keepers_dir ~keeper_id unreadable with
       | Error (Boundaries.Invalid_record _) -> ()
       | Error (Boundaries.Write_failed _ as error) ->
         failf
           "%s: refused for the wrong reason: %s"
           label
           (Boundaries.append_error_to_string error)
       | Ok () -> failf "%s: written" label)
    [ "a turn reference no reader can parse", record ~trace_id:"" Boundaries.No_atom_history
    ; "an empty history of no trace", history_empty ~trace_id:"" ()
    ];
  check int "nothing was written" 0 (List.length (read_lines ~keepers_dir))
;;

(* The log lives in the config keepers directory, outside the runtime
   directory the purge removes: without a plan entry a purged keeper leaves it
   to a later keeper with the same name. *)
let test_purge_plan_removes_the_turn_boundary_log () =
  let module Shutdown = Masc.Keeper_shutdown_types in
  let context = { Shutdown.requested_name = keeper_id } in
  let plan = Shutdown.dashboard_purge_artifact_plan ~keeper_name:keeper_id context in
  check bool "plan removes the turn boundary log" true
    (List.exists (fun entry -> entry = Shutdown.Keeper_turn_boundaries_artifact) plan)
;;

(* A store whose last append never completed: it ends mid-line, and refuses
   every append until process-start recovery truncates the torn tail. *)
let plant_torn_tail ~keepers_dir =
  let torn = {|{"kind":"turn_ended"|} in
  Fs_compat.mkdir_p keepers_dir;
  let store =
    Unix.openfile
      (Boundaries.path_for_keepers_dir ~keepers_dir ~keeper_id)
      [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ]
      0o600
  in
  let written = Unix.write_substring store torn 0 (String.length torn) in
  Unix.close store;
  check int "the fixture line was written whole" (String.length torn) written;
  match Boundaries.read ~keepers_dir ~keeper_id with
  | Ok [ (1, Error Boundaries.Incomplete_line) ] -> ()
  | Ok _ | Error _ -> fail "the fixture store does not end mid-line"
;;

(* {1 The clear} *)

module Clear = Masc.Keeper_history_clear
module Context = Masc.Keeper_context_core

let cleared_trace = "trace-cleared"
let runtime_id = "test-runtime"

let conversation =
  [ message ~role:Types.System "pinned"
  ; message ~role:Types.User "question"
  ; message ~role:Types.Assistant "answer"
  ]
;;

let is_system (saved : Types.message) =
  match saved.role with
  | Types.System -> true
  | Types.User | Types.Assistant | Types.Tool -> false
;;

let at_turn_count turn_count (context : Context.working_context)
  : Context.working_context
  =
  { Keeper_types.checkpoint =
      { (Context.checkpoint_of_context context) with Agent_core.Checkpoint.turn_count }
  }
;;

(* A keeper whose checkpoint on disk holds [conversation] at [turn_count], and
   the keepers directory its boundary lines go to. *)
let with_saved_history ~turn_count f =
  Eio_main.run
  @@ fun env ->
  if not (Fs_compat.has_fs ()) then Fs_compat.set_fs (Eio.Stdenv.fs env);
  with_temp_keepers
  @@ fun keepers_dir ->
  let base_dir = Filename.temp_dir "history-clear-" "" in
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree base_dir)
    (fun () ->
       let session = Context.create_session ~session_id:cleared_trace ~base_dir in
       let context =
         Context.append_many (Context.create ~eio:true ~system_prompt:"system") conversation
         |> at_turn_count turn_count
       in
       (match
          Context.save_agent_core_checkpoint_classified
            ~runtime_id
            ~keeper_name:keeper_id
            ~session
            ~agent_name:keeper_id
            ~ctx:context
        with
        | Ok (_, Masc.Keeper_checkpoint_store.Saved _) -> ()
        | Ok (_, Masc.Keeper_checkpoint_store.Stale_noop _) ->
          fail "the fixture checkpoint was not saved"
        | Error error ->
          failf
            "the fixture checkpoint was not saved: %s"
            (Context.checkpoint_write_error_to_string
               ~persistence_error_to_string:Fun.id
               error));
       f ~keepers_dir ~base_dir ~session context)
;;

let saved_messages ~base_dir =
  match Context.load_context_from_checkpoint ~trace_id:cleared_trace ~base_dir with
  | _session, Some context -> Context.messages_of_context context
  | _session, None -> fail "the checkpoint is gone"
;;

let clear ~keepers_dir ~session context =
  Clear.clear
    ~keepers_dir
    ~runtime_id
    ~keeper_name:keeper_id
    ~session
    ~preserve_system:true
    context
;;

let describe_outcome = function
  | Clear.Cleared { cleared_message_count; marker = Ok () } ->
    Printf.sprintf "cleared %d messages, line written" cleared_message_count
  | Clear.Cleared { cleared_message_count; marker = Error detail } ->
    Printf.sprintf "cleared %d messages, line not written: %s" cleared_message_count detail
  | Clear.Superseded { incoming_turn_count; known_turn_count } ->
    Printf.sprintf "superseded: held %d, store has %d" incoming_turn_count known_turn_count
  | Clear.Save_unconfirmed { detail } -> "save unconfirmed: " ^ detail
;;

let test_a_clear_empties_the_history_and_then_says_so () =
  with_saved_history ~turn_count:3
  @@ fun ~keepers_dir ~base_dir ~session context ->
  let before = saved_messages ~base_dir in
  let pinned = List.length (List.filter is_system before) in
  (match clear ~keepers_dir ~session context with
   | Clear.Cleared { cleared_message_count; marker = Ok () } ->
     check int "every conversation message was removed" (List.length before - pinned)
       cleared_message_count
   | (Clear.Cleared { marker = Error _; _ } | Clear.Superseded _ | Clear.Save_unconfirmed _) as
     other -> failf "expected a cleared history: %s" (describe_outcome other));
  let after = saved_messages ~base_dir in
  check int "the pinned messages are kept" pinned (List.length after);
  check bool "nothing but pinned messages is kept" true (List.for_all is_system after);
  check position_t "the saved history holds no atom" Boundaries.Empty_atom_history
    (position_of "cleared history" after);
  match read_lines ~keepers_dir with
  | [ (1, { Boundaries.recorded_at = _; event = Boundaries.History_empty { trace_id } })
    ] ->
    check string "the line names the trace the checkpoint is saved under" cleared_trace
      trace_id
  | lines -> failf "expected one history_empty line, read %d" (List.length lines)
;;

(* The store refuses a checkpoint older than the one it holds: a turn saved
   while the clear held its copy. The clear used to report its message count
   anyway. *)
let test_a_superseded_clear_writes_nothing () =
  with_saved_history ~turn_count:5
  @@ fun ~keepers_dir ~base_dir ~session context ->
  let before = saved_messages ~base_dir in
  (match clear ~keepers_dir ~session (at_turn_count 3 context) with
   | Clear.Superseded { incoming_turn_count; known_turn_count } ->
     check int "the clear held the older checkpoint" 3 incoming_turn_count;
     check int "the store holds the newer one" 5 known_turn_count
   | (Clear.Cleared _ | Clear.Save_unconfirmed _) as other ->
     failf "expected a superseded clear: %s" (describe_outcome other));
  check int "the history on disk is untouched" (List.length before)
    (List.length (saved_messages ~base_dir));
  check int "no line says the history was cleared" 0
    (List.length (read_lines ~keepers_dir))
;;

(* A store that ends mid-line refuses every append. The history is emptied all
   the same, so the outcome has to say the line is missing: the turns that
   follow are refused their lines as well, so until the torn tail is repaired
   nothing explains why the history started over. *)
let test_a_clear_whose_line_is_refused_says_so () =
  with_saved_history ~turn_count:3
  @@ fun ~keepers_dir ~base_dir ~session context ->
  plant_torn_tail ~keepers_dir;
  (match clear ~keepers_dir ~session context with
   | Clear.Cleared { cleared_message_count = _; marker = Error _ } -> ()
   | (Clear.Cleared { marker = Ok (); _ } | Clear.Superseded _ | Clear.Save_unconfirmed _) as
     other -> failf "expected a cleared history with no line: %s" (describe_outcome other));
  check bool "the history was emptied" true
    (List.for_all is_system (saved_messages ~base_dir))
;;

(* {1 The start of a turn} *)

module Turn_helpers = Masc.Keeper_agent_run_turn_helpers

let started_trace = "trace-started"

(* A workspace, and the keepers directory the turns of its keepers write to. *)
let with_workspace f =
  Eio_main.run
  @@ fun _env ->
  let base_path = Filename.temp_dir "turn-start-" "" in
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree base_path)
    (fun () ->
       f
         ~config:(Masc.Workspace.default_config base_path)
         ~keepers_dir:(Config_dir_resolver.keepers_dir_for_base_path ~base_path))
;;

let start_turn ~config history_at_start =
  Turn_helpers.record_empty_history_at_turn_start
    ~config
    ~keeper_name:keeper_id
    ~trace_id:started_trace
    history_at_start
;;

let turn_start_failures () =
  Masc.Otel_metric_store.metric_value_or_zero
    Keeper_metrics.(to_string TurnBoundaryFailures)
    ~labels:[ "keeper", keeper_id; "site", "turn_start" ]
    ()
;;

(* The turn has saved nothing yet. Whatever it saves first, and whether or not
   it reaches its end, the store already says its atoms are numbered from
   zero. *)
let test_a_turn_that_starts_from_no_atom_says_so () =
  with_workspace
  @@ fun ~config ~keepers_dir ->
  start_turn ~config Boundaries.Fresh_history;
  match read_lines ~keepers_dir with
  | [ (1, { Boundaries.recorded_at = _; event = Boundaries.History_empty { trace_id } }) ]
    -> check string "the line names the turn's trace" started_trace trace_id
  | lines -> failf "expected one empty-history line, read %d" (List.length lines)
;;

(* The end an earlier line states is where this turn starts. *)
let test_a_turn_that_continues_a_history_writes_nothing () =
  with_workspace
  @@ fun ~config ~keepers_dir ->
  start_turn ~config Boundaries.Continued_history;
  check int "no line" 0 (List.length (read_lines ~keepers_dir))
;;

(* The turn has not run yet, and a line the store refuses is no reason not to
   run it: the refusal is counted, nothing is raised, and the store is left as
   it was. *)
let test_a_refused_line_does_not_stop_the_turn () =
  with_workspace
  @@ fun ~config ~keepers_dir ->
  plant_torn_tail ~keepers_dir;
  let before = turn_start_failures () in
  start_turn ~config Boundaries.Fresh_history;
  check (float 0.0001) "the refusal is counted" (before +. 1.0) (turn_start_failures ());
  match Boundaries.read ~keepers_dir ~keeper_id with
  | Ok [ (1, Error Boundaries.Incomplete_line) ] -> ()
  | Ok _ | Error _ -> fail "the refused line changed the store"
;;

let () =
  run
    "keeper_turn_boundaries"
    [ ( "codec"
      , [ test_case "every position kind round trips" `Quick
            test_every_position_kind_round_trips
        ; test_case "the line a turn writes" `Quick test_the_line_a_turn_writes
        ; test_case "the line for an empty history" `Quick
            test_the_line_for_an_empty_history
        ; test_case "refuses what its kind does not carry" `Quick
            test_decode_refuses_what_its_kind_does_not_carry
        ; test_case "refuses values no writer writes" `Quick
            test_decode_refuses_values_no_writer_writes
        ] )
    ; ( "position"
      , [ test_case "agrees with the window" `Quick test_position_agrees_with_the_window
        ; test_case "a history with no atom is a fresh start" `Quick
            test_a_history_with_no_atom_is_a_fresh_start
        ; test_case "a turn without a saved checkpoint" `Quick
            test_a_turn_without_a_saved_checkpoint
        ] )
    ; ( "store"
      , [ test_case "appended lines read back in order" `Quick
            test_appended_lines_read_back_in_order
        ; test_case "a line no reader decodes is not written" `Quick
            test_a_line_no_reader_decodes_is_not_written
        ; test_case "the purge plan removes the log" `Quick
            test_purge_plan_removes_the_turn_boundary_log
        ] )
    ; ( "clear"
      , [ test_case "empties the history and then says so" `Quick
            test_a_clear_empties_the_history_and_then_says_so
        ; test_case "a superseded clear writes nothing" `Quick
            test_a_superseded_clear_writes_nothing
        ; test_case "a clear whose line is refused says so" `Quick
            test_a_clear_whose_line_is_refused_says_so
        ] )
    ; ( "turn start"
      , [ test_case "a turn that starts from no atom says so" `Quick
            test_a_turn_that_starts_from_no_atom_says_so
        ; test_case "a turn that continues a history writes nothing" `Quick
            test_a_turn_that_continues_a_history_writes_nothing
        ; test_case "a refused line does not stop the turn" `Quick
            test_a_refused_line_does_not_stop_the_turn
        ] )
    ]
;;
