(* Deterministic offline checkpoint purge. These tests pin the
   rule contract, and above all that a purge keeps every atom and the last one
   byte-exact: four stores count in atoms, and a purge that renumbered them
   left goo-yang-bong sending its whole 16 MB history on every turn
   (2026-09-22). *)

module Purge = Masc.Keeper_checkpoint_purge
module Types = Agent_core.Types
module Writer = Masc.Keeper_turn_log_writer

let text_message role text : Types.message =
  { origin = Llm_provider.Types.Conversation;  role; content = [ Types.Text text ]; name = None; tool_call_id = None; metadata = [] }

let block_message role content : Types.message =
  { origin = Llm_provider.Types.Conversation;  role; content; name = None; tool_call_id = None; metadata = [] }

let tool_use id : Types.content_block =
  Types.ToolUse { id; name = "test_tool"; input = `Assoc [ "id", `String id ] }

let tool_result ?(content = "raw tool output") id : Types.content_block =
  Types.ToolResult
    { tool_use_id = id
    ; content
    ; outcome = Types.Tool_succeeded
    ; json = Some (`Assoc [ "ok", `Bool true ])
    ; content_blocks = None
    }

let cycle id =
  [ block_message Types.Assistant [ tool_use id ]
  ; { (block_message Types.Tool [ tool_result id ]) with tool_call_id = Some id }
  ]

let unsigned_thinking text : Types.content_block =
  Types.Thinking { content = text; signature = None }

let no_tail_config = { Purge.default_config with keep_recent_messages = 0 }

(* A purge with no boundary log, no Librarian working state and no turn log:
   only the history's own end names a message. *)
let purge_plain ~config messages =
  Purge.purge_messages
    ~config
    ~trace_id:"trace-purge-plain"
    ~boundary_lines:[]
    ~continuity:None
    ~named:Writer.No_log
    messages

let run ?(config = no_tail_config) messages =
  match purge_plain ~config messages with
  | Ok result -> result
  | Error _ -> Alcotest.fail "purge rejected a structurally valid fixture"

let atom_count messages = snd (Runtime_model_input_tail_window.annotate messages)

let history_end messages =
  match Masc.Keeper_turn_boundaries.position_of_messages messages with
  | Ok (Masc.Keeper_turn_boundaries.Atom_history { end_atom; last_atom_digest }) ->
    end_atom, last_atom_digest
  | Ok _ -> Alcotest.fail "fixture history has no atoms"
  | Error detail -> Alcotest.fail detail

let test_every_atom_survives_a_purge () =
  let wake = text_message Types.User "(autonomous wake)" in
  let messages =
    [ wake
    ; block_message Types.Assistant [ unsigned_thinking "t1"; Types.Text "answer" ]
    ; wake
    ; block_message Types.Assistant [ unsigned_thinking "only reasoning" ]
    ; wake
    ]
    @ [ block_message Types.Assistant [ unsigned_thinking "pre-tool"; tool_use "a" ]
      ; block_message Types.Assistant [ unsigned_thinking "interstitial" ]
      ; { (block_message Types.Tool [ tool_result "a" ]) with tool_call_id = Some "a" }
      ]
    @ [ wake; wake ]
  in
  let purged, report = run messages in
  Alcotest.(check bool) "the purge changed something" true
    (report.reasoning_blocks_stripped > 0 && report.tool_results_cleared > 0);
  Alcotest.(check int) "no message removed" (List.length messages) (List.length purged);
  Alcotest.(check int) "same atom count" (atom_count messages) (atom_count purged);
  Alcotest.(check (pair int string)) "same history end" (history_end messages)
    (history_end purged)

(* With no count-based tail, the last atom is still returned byte-exact. Its
   opening message is what the history's end is keyed by: stripping the
   reasoning from a final reply would move that end, and every position at
   the end of the history -- the Librarian's, the last turn-boundary line, the
   request front -- would stop matching. *)
let test_last_atom_is_kept_with_no_tail () =
  let final_reply =
    block_message Types.Assistant [ unsigned_thinking "last turn"; Types.Text "final" ]
  in
  let messages =
    [ text_message Types.User "q"
    ; block_message Types.Assistant [ unsigned_thinking "earlier"; Types.Text "a" ]
    ; text_message Types.User "(autonomous wake)"
    ; final_reply
    ]
  in
  match purge_plain ~config:no_tail_config messages with
  | Error error -> Alcotest.fail (Purge.purge_error_to_string error)
  | Ok (purged, report) ->
    Alcotest.(check int) "the earlier reply is still stripped" 1
      report.reasoning_blocks_stripped;
    Alcotest.(check string) "the last atom opens exactly as before"
      (Types.show_message final_reply)
      (Types.show_message (List.nth purged 3));
    Alcotest.(check (pair int string)) "same history end" (history_end messages)
      (history_end purged)

let checkpoint_fixture () =
    Agent_core.Checkpoint.
      { provider_binding = None; version = checkpoint_version
      ; session_id = "trace-purge-fixture"
      ; agent_name = "purge-fixture"
      ; model = "test-model"
      ; system_prompt = None
      ; messages =
          [ text_message Types.User "(autonomous wake)"
          ; block_message Types.Assistant [ unsigned_thinking "t"; Types.Text "a" ]
          ; text_message Types.User "(autonomous wake)"
          ; block_message Types.Assistant [ tool_use "x" ]
          ; { (block_message Types.Tool [ tool_result "x" ]) with tool_call_id = Some "x" }
          ; text_message Types.User "(autonomous wake)"
          ]
      ; usage = Types.empty_usage
      ; turn_count = 41
      ; created_at = 1_700_000_000.0
      ; tools = []
      ; tool_choice = None
      ; disable_parallel_tool_use = false
      ; temperature = None
      ; top_p = None
      ; top_k = None
      ; min_p = None
      ; enable_thinking = None
      ; preserve_thinking = None
      ; response_format = Types.Off
      ; reasoning_effort = None
      ; cache_system_prompt = false
      ; context = Agent_core.Context.create_sync ()
      ; pending_input = None
      ; working_context = None
      }

module Boundaries = Masc.Keeper_turn_boundaries
module Range = Masc.Keeper_librarian_range
module Window = Runtime_model_input_tail_window

let fixture_trace = (checkpoint_fixture ()).Agent_core.Checkpoint.session_id

(* A completed turn's line, as the turn driver writes it: [end_atom] atoms,
   and the digest of the message that opens the last of them. *)
let turn_ended_line ~line ~absolute_turn messages ~end_atom : Purge.boundary_line =
  let last_atom_digest =
    match Window.atom_opening_digest messages (end_atom - 1) with
    | Some digest -> digest
    | None -> Alcotest.failf "fixture history has no atom %d" (end_atom - 1)
  in
  ( line
  , Ok
      { Boundaries.recorded_at = 100.0
      ; event =
          Boundaries.Turn_ended
            { task_context = Masc.Keeper_turn_task_context.No_task; turn_ref = Ids.Turn_ref.make ~trace_id:fixture_trace ~absolute_turn
            ; history_at_start = Boundaries.Continued_history
            ; position = Boundaries.Atom_history { end_atom; last_atom_digest }
            }
      } )
;;

let purge_with ?(named = Writer.No_log) ~boundary_lines ~continuity messages =
  match
    Purge.purge_messages
      ~config:no_tail_config
      ~trace_id:fixture_trace
      ~boundary_lines
      ~continuity
      ~named
      messages
  with
  | Ok result -> result
  | Error error -> Alcotest.fail (Purge.purge_error_to_string error)
;;

(* A turn ends on an assistant reply and its line names that reply by
   digest. A failed turn after it leaves the checkpoint past the line, so the
   history's end does not cover the reply: rewritten, the line stops
   matching, and a keeper with no working state sends from the oldest atom. *)
let test_a_turn_end_a_line_names_is_kept () =
  let reply =
    block_message Types.Assistant [ unsigned_thinking "done"; Types.Text "turn one" ]
  in
  let messages =
    [ text_message Types.User "(autonomous wake)"
    ; reply
    ; text_message Types.User "(autonomous wake)"
    ]
    @ cycle "failed-a"
    @ cycle "failed-b"
  in
  let line = turn_ended_line ~line:1 ~absolute_turn:1 messages ~end_atom:2 in
  let front history =
    match
      Masc.Librarian_continuity_snapshot.checkpoint_prefix_range
        ~trace_id:fixture_trace
        ~lines:[ line ]
        ~messages:history
    with
    | Ok range -> Some range.Range.end_atom
    | Error _ -> None
  in
  Alcotest.(check (option int)) "the line matches the history" (Some 2) (front messages);
  let unnamed, _ = purge_with ~boundary_lines:[] ~continuity:None messages in
  Alcotest.(check (option int)) "purged without the line, it matches nothing" None
    (front unnamed);
  let named, _ = purge_with ~boundary_lines:[ line ] ~continuity:None messages in
  Alcotest.(check string) "purged with it, the reply opens exactly as before"
    (Types.show_message reply) (Types.show_message (List.nth named 1));
  Alcotest.(check (option int)) "and the request still starts after that turn" (Some 2)
    (front named)
;;

(* A working state that fits is the request's front, and it holds a digest
   of the bytes it covers. The purge leaves those bytes alone and still
   rewrites the turns after them. *)
let test_a_fitting_working_state_keeps_its_prefix ~with_unread () =
  let first_turn =
    [ text_message Types.User "(autonomous wake)"
    ; block_message Types.Assistant [ unsigned_thinking "look"; tool_use "a" ]
    ; { (block_message Types.Tool [ tool_result "a" ]) with tool_call_id = Some "a" }
    ; block_message Types.Assistant [ unsigned_thinking "done"; Types.Text "one" ]
    ]
  in
  let second_turn =
    [ text_message Types.User "(autonomous wake)"
    ; block_message Types.Assistant [ unsigned_thinking "look again"; tool_use "b" ]
    ; { (block_message Types.Tool [ tool_result "b" ]) with tool_call_id = Some "b" }
    ; block_message Types.Assistant [ Types.Text "two" ]
    ]
  in
  let messages = first_turn @ second_turn in
  let lines =
    [ turn_ended_line ~line:1 ~absolute_turn:1 messages ~end_atom:3
    ; turn_ended_line ~line:2 ~absolute_turn:2 messages ~end_atom:6
    ]
  in
  let capture unread_messages =
    match
      Masc.Librarian_continuity_snapshot.capture_checkpoint_prefix ~unread_messages
        ~end_atom:3
        ~catch_up_end_atom:None
        ~trace_id:fixture_trace
        ~lines
        ~messages
        ~working_state:"turn one"
        ()
    with
    | Ok snapshot -> snapshot
    | Error error -> Alcotest.fail (Masc.Librarian_continuity_snapshot.error_to_string error)
  in
  let base_snapshot = capture [] in
  let snapshot = if not with_unread then base_snapshot else
    let hole = match Masc.Keeper_librarian_unread.for_atom ~trace_id:fixture_trace
      ~history_start_boundary_line:base_snapshot.history_start_boundary_line
      ~atom:1 ~message_in_atom:1 ~messages
      ~reasons:[Masc.Keeper_librarian_input_refusal.Request_body_refused] with
      | Ok hole -> hole | Error detail -> Alcotest.fail detail in
    capture [hole] in
  let fits history =
    Result.is_ok
      (Masc.Librarian_continuity_snapshot.restore
         ~trace_id:fixture_trace
         ~lines
         ~messages:history
         snapshot)
  in
  Alcotest.(check bool) "the working state fits the history" true (fits messages);
  let ignored, _ = purge_with ~boundary_lines:lines ~continuity:None messages in
  Alcotest.(check bool) "purged past it, it no longer fits" false (fits ignored);
  let kept, report = purge_with ~boundary_lines:lines ~continuity:(Some snapshot) messages in
  Alcotest.(check bool) "purged around it, it still fits" true (fits kept);
  Alcotest.(check (list string)) "the turn it covers is byte-exact"
    (List.map Types.show_message first_turn)
    (List.map Types.show_message (List.filteri (fun index _ -> index < 4) kept));
  Alcotest.(check (pair int int)) "and the turn after it is still purged" (1, 1)
    (report.reasoning_blocks_stripped, report.tool_results_cleared);
  if with_unread then (
    let changed = List.mapi (fun index (message : Types.message) -> if index = 2 then
      {message with Types.content=[tool_result ~content:"changed unread original" "a"]}
      else message) messages in
    match Purge.purge_messages ~config:no_tail_config ~trace_id:fixture_trace
      ~boundary_lines:lines ~continuity:(Some snapshot) ~named:Writer.No_log changed with
    | Error (Purge.Continuity_no_longer_fits _) -> ()
    | Error error -> Alcotest.fail (Purge.purge_error_to_string error)
    | Ok _ -> Alcotest.fail "a nonfitting unread source was destructively purged")
;;

let () =
  Alcotest.run
    "keeper_checkpoint_purge_librarian_stores"
    [ ( "atoms"
      , [ Alcotest.test_case
            "every atom survives a purge"
            `Quick
            test_every_atom_survives_a_purge
        ; Alcotest.test_case
            "the last atom is kept with no tail"
            `Quick
            test_last_atom_is_kept_with_no_tail
        ; Alcotest.test_case
            "a turn end a line names is kept"
            `Quick
            test_a_turn_end_a_line_names_is_kept
        ; Alcotest.test_case
            "a fitting working state keeps its prefix"
            `Quick
            (test_a_fitting_working_state_keeps_its_prefix ~with_unread:false)
        ; Alcotest.test_case
            "unread source bytes survive purge and nonfitting source refuses rewrite"
            `Quick
            (test_a_fitting_working_state_keeps_its_prefix ~with_unread:true)
        ] )
    ]
