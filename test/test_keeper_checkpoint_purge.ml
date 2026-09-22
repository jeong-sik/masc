(* RFC-0351 S1: deterministic offline checkpoint purge. These tests pin the
   rule contract, and above all that a purge keeps every atom and the last one
   byte-exact: four stores count in atoms, and a purge that renumbered them
   left goo-yang-bong sending its whole 16 MB history on every turn
   (2026-09-22). *)

module Purge = Masc.Keeper_checkpoint_purge
module Types = Agent_core.Types
module Keeper_transcript_unit = Masc.Keeper_transcript_unit

let text_message role text : Types.message =
  { role; content = [ Types.Text text ]; name = None; tool_call_id = None; metadata = [] }

let block_message role content : Types.message =
  { role; content; name = None; tool_call_id = None; metadata = [] }

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

let tool_error_result ?(content = "raw tool error") id : Types.content_block =
  Types.ToolResult
    { tool_use_id = id
    ; content
    ; outcome =
        Types.Tool_failed
          { failure_kind = Types.Recoverable_tool_error; error_class = None }
    ; json = Some (`Assoc [ "error", `String "boom" ])
    ; content_blocks = None
    }

let error_cycle id =
  [ block_message Types.Assistant [ tool_use id ]
  ; { (block_message Types.Tool [ tool_error_result id ]) with tool_call_id = Some id }
  ]

let unsigned_thinking text : Types.content_block =
  Types.Thinking { content = text; signature = None }

let signed_thinking text : Types.content_block =
  Types.Thinking { content = text; signature = Some "sig" }

(* Trailing distinct filler so the interesting prefix sits outside the
   protected tail without disabling the tail protection itself. *)
let filler n =
  List.init n (fun i -> text_message Types.User (Printf.sprintf "filler-%d" i))

let no_tail_config = { Purge.default_config with keep_recent_messages = 0 }

(* A purge with no boundary log, no Librarian working state and no Librarian
   position: only the history's own end names a message. *)
let purge_plain ~config messages =
  Purge.purge_messages
    ~config
    ~trace_id:"trace-purge-plain"
    ~boundary_lines:[]
    ~continuity:None
    ~progress:None
    messages

let purge_checkpoint ~config (checkpoint : Agent_core.Checkpoint.t) =
  Purge.purge
    ~config
    ~trace_id:checkpoint.session_id
    ~boundary_lines:[]
    ~continuity:None
    ~progress:None
    checkpoint

let run ?(config = no_tail_config) messages =
  match purge_plain ~config messages with
  | Ok result -> result
  | Error _ -> Alcotest.fail "purge rejected a structurally valid fixture"

let message_texts messages =
  List.map
    (fun (m : Types.message) ->
       String.concat
         "|"
         (List.map
            (function
              | Types.Text t -> t
              | Types.Thinking _ -> "<thinking>"
              | Types.ToolUse { id; _ } -> "use:" ^ id
              | Types.ToolResult { tool_use_id; content; _ } ->
                "result:" ^ tool_use_id ^ ":" ^ content
              | _ -> "<other>")
            m.content))
    messages

let atom_count messages = snd (Runtime_model_input_tail_window.annotate messages)

let history_end messages =
  match Masc.Keeper_turn_boundaries.position_of_messages messages with
  | Ok (Masc.Keeper_turn_boundaries.Atom_history { end_atom; last_atom_digest }) ->
    end_atom, last_atom_digest
  | Ok _ -> Alcotest.fail "fixture history has no atoms"
  | Error detail -> Alcotest.fail detail

(* The shape goo-yang-bong's history had: the same wake cue opening turn after
   turn, and replies that were nothing but unsigned reasoning. Every one of
   them opens an atom, so every one stays. *)
let test_repeated_messages_all_survive () =
  let wake = text_message Types.User "(autonomous wake)" in
  let messages =
    [ wake
    ; text_message Types.Assistant "reply-a"
    ; wake
    ; block_message Types.Assistant [ unsigned_thinking "only reasoning" ]
    ; wake
    ; text_message Types.Assistant "reply-b"
    ; wake
    ; wake
    ]
  in
  let purged, _report = run messages in
  Alcotest.(check (list string))
    "every message survives, in order"
    [ "(autonomous wake)"
    ; "reply-a"
    ; "(autonomous wake)"
    ; "<thinking>"
    ; "(autonomous wake)"
    ; "reply-b"
    ; "(autonomous wake)"
    ; "(autonomous wake)"
    ]
    (message_texts purged)

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

let test_reasoning_strip_scope () =
  let messages =
    [ block_message Types.Assistant [ unsigned_thinking "t1"; Types.Text "answer" ]
    ; block_message Types.Assistant [ unsigned_thinking "t2" ]
    ; block_message Types.Assistant [ signed_thinking "t3"; Types.Text "signed" ]
    ]
  in
  let purged, report = run messages in
  Alcotest.(check int) "unsigned block stripped beside text" 1
    report.reasoning_blocks_stripped;
  Alcotest.(check (list string))
    "text survives; a reasoning-only reply and signed thinking are untouched"
    [ "answer"; "<thinking>"; "<thinking>|signed" ]
    (message_texts purged)

(* Contract change: R2 used to skip any message carrying a ToolUse, so the
   assistant message that opens a tool cycle kept its unsigned reasoning. On an
   agentic keeper that is almost every assistant message — measured on the
   that checkpoint, 418 of 422 surviving unsigned Thinking blocks (490,370 B,
   41.0% of the file) were held by this rule. Unsigned reasoning carries no
   signature to replay, so the exemption bought nothing. *)
let test_unsigned_reasoning_inside_tool_cycle_is_stripped () =
  (* The trailing turn keeps the cycle out of the last atom, which is always
     returned byte-exact. *)
  let messages =
    [ block_message Types.Assistant [ unsigned_thinking "pre-tool"; tool_use "a" ]
    ; { (block_message Types.Tool [ tool_result "a" ]) with tool_call_id = Some "a" }
    ; text_message Types.User "after"
    ]
  in
  let purged, report = run messages in
  Alcotest.(check int)
    "unsigned reasoning is stripped even beside a tool_use"
    1
    report.reasoning_blocks_stripped;
  Alcotest.(check int) "no message dropped" 3 (List.length purged);
  (match List.hd purged with
   | { Types.content = [ Types.ToolUse { id; _ } ]; _ } ->
     Alcotest.(check string) "the tool_use itself survives" "a" id
   | other ->
     Alcotest.failf
       "expected a lone surviving ToolUse, got %s"
       (Types.show_message other))

(* The safety line the old guard was reaching for, pinned where it belongs:
   per block, by signature — not per message, by "has a tool_use". *)
let test_signed_reasoning_inside_tool_cycle_is_kept () =
  let messages =
    [ block_message Types.Assistant [ signed_thinking "pre-tool"; tool_use "a" ]
    ; { (block_message Types.Tool [ tool_result "a" ]) with tool_call_id = Some "a" }
    ; text_message Types.User "after"
    ]
  in
  let purged, report = run messages in
  Alcotest.(check int)
    "signed reasoning beside a tool_use is untouched"
    0
    report.reasoning_blocks_stripped;
  Alcotest.(check int) "no message dropped" 3 (List.length purged);
  match List.hd purged with
  | { Types.content = [ Types.Thinking { signature = Some _; _ }; Types.ToolUse _ ]; _ } ->
    ()
  | other ->
    Alcotest.failf
      "signed thinking must replay byte-exact, got %s"
      (Types.show_message other)

(* An assistant progress frame can sit inside an already-open tool cycle
   without carrying either anchor. It opens an atom like any assistant
   message, so a frame that is nothing but unsigned reasoning stays whole
   rather than being emptied or removed. *)
let test_thinking_only_interstitial_cycle_message_is_kept () =
  let messages =
    [ block_message Types.Assistant [ tool_use "a" ]
    ; block_message Types.Assistant [ unsigned_thinking "only-thinking" ]
    ; { (block_message Types.Tool [ tool_result "a" ]) with tool_call_id = Some "a" }
    ; text_message Types.User "after"
    ]
  in
  let purged, report = run messages in
  Alcotest.(check int) "nothing to strip without emptying" 0
    report.reasoning_blocks_stripped;
  Alcotest.(check int) "every message kept" 4 (List.length purged);
  Alcotest.(check (list string)) "the interstitial frame is untouched"
    [ "use:a"; "<thinking>"; "result:a:" ^ Purge.cleared_tool_result_content; "after" ]
    (message_texts purged);
  match Masc.Keeper_transcript_unit.validate purged with
  | Ok () -> ()
  | Error _ -> Alcotest.fail "keeping the interstitial broke tool pairing"

let test_tool_result_clear_preserves_pairing () =
  let messages = cycle "a" @ [ text_message Types.User "after" ] in
  let purged, report = run messages in
  Alcotest.(check int) "one result cleared" 1 report.tool_results_cleared;
  (match List.nth purged 1 with
   | { Types.content = [ Types.ToolResult { tool_use_id; content; json; content_blocks; outcome } ]; _ } ->
     Alcotest.(check string) "pairing id kept" "a" tool_use_id;
     Alcotest.(check string)
       "content replaced by the marker"
       Purge.cleared_tool_result_content
       content;
     Alcotest.(check bool) "json dropped" true (Option.is_none json);
     Alcotest.(check bool) "blocks dropped" true (Option.is_none content_blocks);
     (match outcome with
      | Types.Tool_succeeded -> ()
      | _ -> Alcotest.fail "typed outcome must survive the clear")
   | _ -> Alcotest.fail "cleared cycle lost its ToolResult block");
  match Masc.Keeper_transcript_unit.validate purged with
  | Ok () -> ()
  | Error _ -> Alcotest.fail "cleared cycle no longer validates"

let test_error_tool_result_is_never_cleared () =
  (* R3 clears successful payloads only: an error result is feedback and
     lesson evidence, so its payload, json, and outcome all survive. *)
  let messages = error_cycle "a" @ cycle "b" @ [ text_message Types.User "after" ] in
  let purged, report = run messages in
  Alcotest.(check int)
    "only the successful result is cleared"
    1
    report.tool_results_cleared;
  (match List.nth purged 1 with
   | { Types.content = [ Types.ToolResult { content; json; outcome; _ } ]; _ } ->
     Alcotest.(check string) "error payload survives" "raw tool error" content;
     Alcotest.(check bool) "error json untouched" true (Option.is_some json);
     (match outcome with
      | Types.Tool_failed _ -> ()
      | _ -> Alcotest.fail "error outcome must survive the purge")
   | _ -> Alcotest.fail "error cycle lost its ToolResult block");
  let twice, _ = run purged in
  Alcotest.(check (list string))
    "preserved errors make the second purge the identity too"
    (message_texts purged)
    (message_texts twice)

let test_protected_tail_is_byte_exact () =
  let wake = text_message Types.User "(autonomous wake)" in
  let config = { Purge.default_config with keep_recent_messages = 4 } in
  let tail =
    [ wake
    ; wake
    ; wake
    ; block_message Types.Assistant [ unsigned_thinking "tail"; Types.Text "t" ]
    ]
  in
  let messages = filler 3 @ tail in
  let purged, report = run ~config messages in
  Alcotest.(check int) "tail reasoning survives" 0 report.reasoning_blocks_stripped;
  Alcotest.(check int) "nothing dropped" 7 (List.length purged)

let test_cycle_overlapping_protected_tail_is_untouched () =
  let config = { Purge.default_config with keep_recent_messages = 1 } in
  (* The cycle's final message falls inside the protected tail; the whole
     cycle must be exempt from R3. *)
  let messages = [ text_message Types.User "head" ] @ cycle "a" in
  let _purged, report = run ~config messages in
  Alcotest.(check int) "overlapping cycle not cleared" 0 report.tool_results_cleared

let test_purge_is_idempotent () =
  let wake = text_message Types.User "(autonomous wake)" in
  let reply thinking =
    block_message Types.Assistant [ unsigned_thinking thinking; Types.Text "same answer" ]
  in
  let messages =
    [ wake; wake; wake ]
    @ cycle "a"
    @ [ reply "t1"; reply "t2"; reply "t3" ]
    @ [ wake ]
  in
  let once, _ = run messages in
  let twice, second_report = run once in
  Alcotest.(check (list string))
    "second purge is the identity"
    (message_texts once)
    (message_texts twice);
  Alcotest.(check int)
    "no further reasoning"
    0
    second_report.reasoning_blocks_stripped;
  Alcotest.(check int) "no further clears" 0 second_report.tool_results_cleared

(* Purge is the operator's recovery tool and a broken transcript is what it is
   reached for. Refusing left one move: edit the checkpoint JSON by hand, which
   is what 2026-09-01 came down to. The break is dropped rather than preserved,
   because a preserved break returns a transcript that still cannot be saved
   while reporting success. *)
let test_broken_structure_is_recovered_not_refused () =
  let orphan =
    { (block_message Types.Tool [ tool_result "ghost" ]) with
      tool_call_id = Some "ghost"
    }
  in
  match purge_plain ~config:no_tail_config [ orphan ] with
  | Error (Purge.Invalid_input_structure _) ->
    Alcotest.fail "the recovery tool refused the transcript it exists for"
  | Error _ -> Alcotest.fail "orphan tool_result misclassified"
  | Ok (purged, report) ->
    Alcotest.(check int) "the orphan is gone" 0 (List.length purged);
    Alcotest.(check int)
      "and the cost is reported"
      1
      report.Purge.messages_dropped_at_structural_break

(* The output of a recovery must be saveable, which is the whole point: a
   keeper stuck on a break has to be able to checkpoint again afterwards. *)
let test_recovered_output_is_structurally_sound () =
  (* The live shape: a second tool_use opens while the first cycle is still
     unanswered, which is Overlapping_tool_cycle. Two keepers sat on exactly
     this on 2026-09-01. *)
  let messages =
    cycle "a"
    @ cycle "b"
    @ [ block_message Types.Assistant [ tool_use "c1" ]
      ; block_message Types.Assistant [ tool_use "c2" ]
      ; { (block_message Types.Tool [ tool_result "c1" ]) with
          tool_call_id = Some "c1"
        }
      ; { (block_message Types.Tool [ tool_result "c2" ]) with
          tool_call_id = Some "c2"
        }
      ]
  in
  match purge_plain ~config:no_tail_config messages with
  | Error _ -> Alcotest.fail "the split cycle was refused"
  | Ok (purged, report) ->
    Alcotest.(check bool)
      "the survivors validate"
      true
      (Result.is_ok (Keeper_transcript_unit.validate purged));
    Alcotest.(check bool)
      "and something was dropped to get there"
      true
      (report.Purge.messages_dropped_at_structural_break > 0)

(* A sound transcript keeps its open tail: crash recovery depends on it, and
   this is the path every ordinary purge takes. *)
let test_sound_input_drops_nothing_at_a_break () =
  match purge_plain ~config:no_tail_config (cycle "a" @ cycle "b") with
  | Error _ -> Alcotest.fail "a sound transcript was refused"
  | Ok (_, report) ->
    Alcotest.(check int)
      "nothing dropped at a break there is not"
      0
      report.Purge.messages_dropped_at_structural_break

let test_config_bounds_are_enforced () =
  match
    purge_plain
      ~config:{ no_tail_config with keep_recent_messages = -1 }
      [ text_message Types.User "x" ]
  with
  | Error (Purge.Invalid_config _) -> ()
  | _ -> Alcotest.fail "negative keep_recent_messages was accepted"

let checkpoint_fixture () =
    Agent_core.Checkpoint.
      { version = checkpoint_version
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
      ; mcp_sessions = []
      ; working_context = None
      }

let test_checkpoint_fields_pass_through () =
  let checkpoint = checkpoint_fixture () in
  match purge_checkpoint ~config:no_tail_config checkpoint with
  | Error _ -> Alcotest.fail "checkpoint purge failed"
  | Ok (purged, report) ->
    Alcotest.(check int) "no message removed" report.messages_before
      report.messages_after;
    Alcotest.(check bool) "the fixture gives the purge something to change" true
      (report.reasoning_blocks_stripped > 0 && report.tool_results_cleared > 0);
    Alcotest.(check string)
      "session identity unchanged"
      checkpoint.session_id
      purged.Agent_core.Checkpoint.session_id;
    Alcotest.(check int)
      "turn watermark unchanged"
      checkpoint.turn_count
      purged.Agent_core.Checkpoint.turn_count

(* RFC librarian-lifecycle §10-2. Each case is the code counterpart of one
   model in [specs/bug-models/LibrarianRead-purge-trim*.cfg]: the model says
   what a purge that ignores the rule loses, the case says the rule here
   refuses or moves the position the way the surviving model does. *)
module Progress = Masc.Keeper_librarian_progress
module Boundaries = Masc.Keeper_turn_boundaries
module Range = Masc.Keeper_librarian_range
module Window = Runtime_model_input_tail_window

let fixture_trace = (checkpoint_fixture ()).Agent_core.Checkpoint.session_id
let fixture_boundary_lines_seen = 7

let rewritten_fixture () =
  let checkpoint = checkpoint_fixture () in
  match purge_checkpoint ~config:no_tail_config checkpoint with
  | Error _ -> Alcotest.fail "checkpoint purge failed"
  | Ok (purged, _) -> checkpoint.messages, purged.Agent_core.Checkpoint.messages
;;

let atom_position messages =
  match Boundaries.position_of_messages messages with
  | Ok (Boundaries.Atom_history { end_atom; last_atom_digest }) -> end_atom, last_atom_digest
  | Ok _ -> Alcotest.fail "fixture history has no atoms"
  | Error detail -> Alcotest.fail detail
;;

(* A position [end_atom] atoms into [messages], as a round would have written
   it: the digest is the opening of atom [end_atom - 1]. *)
let progress_at ?(trace_id = fixture_trace) messages ~end_atom : Progress.t =
  let last_atom_digest =
    match Window.atom_opening_digest messages (end_atom - 1) with
    | Some digest -> digest
    | None -> Alcotest.failf "fixture history has no atom %d" (end_atom - 1)
  in
  { position = { trace_id; end_atom; last_atom_digest }
  ; boundary_lines_seen = fixture_boundary_lines_seen
  }
;;

let rebase ?(trace_id = fixture_trace) ~progress ~before ~after () =
  Purge.librarian_rebase ~progress ~trace_id ~before ~after
;;

(* The fixture rewritten with its position at the end: the messages before
   and after, the position given, and the pair the rebase answered. *)
let rebased_at_end () =
  let before, after = rewritten_fixture () in
  let progress = progress_at before ~end_atom:(atom_count before) in
  match rebase ~progress:(Some progress) ~before ~after () with
  | Ok (Purge.Rebased { before = moved_from; after = moved_to }) ->
    before, after, progress, moved_from, moved_to
  | Ok Purge.No_progress -> Alcotest.fail "a position was given and none came back"
  | Error refusal -> Alcotest.fail (Purge.refusal_to_string refusal)
;;

(* [LibrarianRead-purge-trim-buggy.cfg] loses an atom because the purge
   keeps the position; [-by-turns-buggy.cfg] loses one because it asks
   whether every turn ended, while a turn that saved and died leaves an atom
   no line names. The rule asks about atoms and never reads the log: an
   atom short of the end refuses, whatever the log says. *)
let test_librarian_rebase_refuses_unread_atoms () =
  let before, after = rewritten_fixture () in
  let count = atom_count before in
  let progress = progress_at before ~end_atom:(count - 1) in
  match rebase ~progress:(Some progress) ~before ~after () with
  | Error (Purge.Unread_atoms_present { end_atom; atom_count }) ->
    Alcotest.(check int) "the position that refused" (count - 1) end_atom;
    Alcotest.(check int) "against the history's atoms" count atom_count
  | Error refusal -> Alcotest.fail (Purge.refusal_to_string refusal)
  | Ok _ -> Alcotest.fail "a rewrite over an unread atom was allowed"
;;

(* A purge keeps the history's end, so the position at the end comes back as
   it was: the same atom count, the same digest. *)
let test_librarian_rebase_keeps_the_position_at_the_end () =
  let before, after, progress, moved_from, moved_to = rebased_at_end () in
  let end_atom, last_atom_digest = atom_position before in
  Alcotest.(check (pair int string)) "the rewritten end is the old end"
    (end_atom, last_atom_digest) (atom_position after);
  Alcotest.(check bool) "the rebase hands back the position it was given" true
    (moved_from == progress);
  Alcotest.(check int) "end_atom is unchanged" end_atom moved_to.position.end_atom;
  Alcotest.(check string) "the digest is unchanged" last_atom_digest
    moved_to.position.last_atom_digest;
  Alcotest.(check string) "the trace is unchanged" fixture_trace
    moved_to.position.trace_id
;;

(* [LibrarianRead-purge-trim-counting-lines-buggy.cfg] loses an atom because
   the purge raises the counted lines to the log's length and swallows a
   restart line no round has seen. The count is not the purge's to set. *)
let test_librarian_rebase_keeps_boundary_lines_seen () =
  let _before, _after, _progress, _moved_from, moved_to = rebased_at_end () in
  Alcotest.(check int) "boundary_lines_seen is untouched" fixture_boundary_lines_seen
    moved_to.boundary_lines_seen
;;

(* The end line the last turn wrote stays in the log after the purge, and it
   still names the rewritten history's end: its end_atom and digest are the
   position's. So the next round has nothing to read and does not stop, and
   the durable consumer finds that line as the position's witness rather than
   stopping on [Progress_boundary_missing]. *)
let test_librarian_rebase_leaves_nothing_to_read () =
  let before, after, old_progress, _moved_from, moved_to = rebased_at_end () in
  let old_end_line =
    match Boundaries.position_of_messages before with
    | Ok position ->
      { Boundaries.recorded_at = 100.0
      ; event =
          Boundaries.Turn_ended
            { turn_ref = Ids.Turn_ref.make ~trace_id:fixture_trace ~absolute_turn:1
            ; history_at_start = Boundaries.Continued_history
            ; position
            }
      }
    | Error detail -> Alcotest.fail detail
  in
  let select progress =
    Range.select
      ~trace_id:fixture_trace
      ~lines:[ 1, Ok old_end_line ]
      ~progress:(Some progress)
      ~messages:after
      Range.All_unread
  in
  let old_end = atom_position before in
  (match old_end_line.event with
   | Boundaries.Turn_ended
       { position = Boundaries.Atom_history { end_atom; last_atom_digest }; _ } ->
     Alcotest.(check (pair int string)) "the old end line names the rewritten end"
       (atom_position after) (end_atom, last_atom_digest);
     Alcotest.(check (pair int string)) "and the position it witnesses"
       (moved_to.position.end_atom, moved_to.position.last_atom_digest)
       (end_atom, last_atom_digest)
   | _ -> Alcotest.fail "the fixture end line is not an atom position");
  Alcotest.(check (pair int string)) "the old position is the rebased one" old_end
    (old_progress.position.end_atom, old_progress.position.last_atom_digest);
  match select moved_to with
  | Range.Nothing_to_read -> ()
  | Range.Read _ | Range.Baseline _ | Range.Position_in_other_trace _ ->
    Alcotest.fail "the position found something to read in a fully read history"
  | Range.Stop _ -> Alcotest.fail "the position stopped the round on the rewritten history"
;;

let test_librarian_rebase_without_a_position () =
  let before, after = rewritten_fixture () in
  match rebase ~progress:None ~before ~after () with
  | Ok Purge.No_progress -> ()
  | Ok (Purge.Rebased _) -> Alcotest.fail "no position was given and one came back"
  | Error refusal -> Alcotest.fail (Purge.refusal_to_string refusal)
;;

let test_librarian_rebase_refuses_another_trace () =
  let before, after = rewritten_fixture () in
  let progress = progress_at ~trace_id:"trace-other" before ~end_atom:(atom_count before) in
  match rebase ~progress:(Some progress) ~before ~after () with
  | Error (Purge.Position_in_other_trace trace_id) ->
    Alcotest.(check string) "names the position's trace" "trace-other" trace_id
  | Error refusal -> Alcotest.fail (Purge.refusal_to_string refusal)
  | Ok _ -> Alcotest.fail "a position of another trace was moved"
;;

let test_librarian_rebase_refuses_a_position_beyond_the_history () =
  let before, after = rewritten_fixture () in
  let count = atom_count before in
  (* A position one past the end, with the digest a round would have left at
     the real end: the digest is not what refuses here. *)
  let at_end = progress_at before ~end_atom:count in
  let progress = { at_end with position = { at_end.position with end_atom = count + 1 } } in
  match rebase ~progress:(Some progress) ~before ~after () with
  | Error (Purge.Position_beyond_history { end_atom; atom_count }) ->
    Alcotest.(check int) "the position that refused" (count + 1) end_atom;
    Alcotest.(check int) "against the history's atoms" count atom_count
  | Error refusal -> Alcotest.fail (Purge.refusal_to_string refusal)
  | Ok _ -> Alcotest.fail "a position past the history was moved"
;;

let test_librarian_rebase_refuses_another_history_at_the_same_end () =
  let before, after = rewritten_fixture () in
  let count = atom_count before in
  let at_end = progress_at before ~end_atom:count in
  let held = "another-history-digest" in
  let progress =
    { at_end with
      position = { at_end.position with last_atom_digest = held }
    }
  in
  let _, history = atom_position before in
  match rebase ~progress:(Some progress) ~before ~after () with
  | Error (Purge.Position_in_other_history digests) ->
    Alcotest.(check string) "names the held digest" held digests.held;
    Alcotest.(check string) "names the checkpoint digest" history digests.history
  | Error refusal -> Alcotest.fail (Purge.refusal_to_string refusal)
  | Ok _ -> Alcotest.fail "a position from another same-length history was moved"
;;

let test_librarian_rebase_refuses_a_rewrite_with_no_atoms () =
  let before, _after = rewritten_fixture () in
  let progress = progress_at before ~end_atom:(atom_count before) in
  match rebase ~progress:(Some progress) ~before ~after:[] () with
  | Error Purge.Rewrite_leaves_no_atoms -> ()
  | Error refusal -> Alcotest.fail (Purge.refusal_to_string refusal)
  | Ok _ -> Alcotest.fail "a position was moved into a history with no atom"
;;

let rec workspace_contents dir =
  Sys.readdir dir
  |> Array.to_list
  |> List.sort String.compare
  |> List.concat_map (fun name ->
    let path = Filename.concat dir name in
    if Sys.is_directory path then
      (path, None) :: workspace_contents path
    else [ path, Some (In_channel.with_open_bin path In_channel.input_all) ])

let test_cli_workspace ?(linked_worktree = false) cluster_name () =
  Eio_main.run @@ fun env ->
  let owner_root = Filename.temp_dir "checkpoint-purge-cli-" "" |> Unix.realpath in
  let base_path =
    if not linked_worktree then owner_root
    else
      let main_root = Filename.concat owner_root "main" in
      let worktree_root = Filename.concat owner_root "worktree" in
      Unix.mkdir main_root 0o700;
      Unix.mkdir (Filename.concat main_root ".git") 0o700;
      Unix.mkdir worktree_root 0o700;
      Out_channel.with_open_text (Filename.concat worktree_root ".git") (fun output ->
        Printf.fprintf output "gitdir: %s/.git/worktrees/checkpoint-purge\n" main_root);
      worktree_root
  in
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree owner_root)
    (fun () ->
      Masc_test_deps.with_process_env Env_config_core.base_path_env_key None @@ fun () ->
      Masc_test_deps.with_process_env "MASC_CLUSTER_NAME" cluster_name @@ fun () ->
      let config = Masc.Workspace.default_config base_path in
      let checkpoint = checkpoint_fixture () in
      let session_dir = Masc.Keeper_fs.keeper_session_dir config checkpoint.session_id in
      let runtime_root = Masc.Workspace.masc_root_dir config in
      let checkpoint_path =
        Masc.Keeper_checkpoint_store.agent_core_checkpoint_path
          ~session_dir ~session_id:checkpoint.session_id
      in
      (match Masc.Keeper_checkpoint_store.save_agent_core_classified
        ~session_dir ~history_retained:0 checkpoint with
       | Ok (Masc.Keeper_checkpoint_store.Saved _) -> ()
       | Ok (Masc.Keeper_checkpoint_store.Stale_noop _) ->
           Alcotest.fail "fixture checkpoint was not saved"
       | Error detail -> Alcotest.failf "fixture checkpoint: %s" detail);
      let original = In_channel.with_open_bin checkpoint_path In_channel.input_all in
      let before = workspace_contents owner_root in
      let runtime_keepers_dir = Masc.Workspace.keepers_runtime_dir config in
      let write_progress ~end_atom =
        match
          Progress.write
            ~keepers_dir:runtime_keepers_dir
            ~keeper_id:checkpoint.agent_name
            (progress_at checkpoint.messages ~end_atom)
        with
        | Ok () -> ()
        | Error error -> Alcotest.fail (Progress.write_error_to_string error)
      in
      let read_progress () =
        match
          Progress.read ~keepers_dir:runtime_keepers_dir ~keeper_id:checkpoint.agent_name
        with
        | Ok (Some progress) -> progress
        | Ok None -> Alcotest.fail "the Librarian position is gone"
        | Error error -> Alcotest.fail (Progress.read_error_to_string error)
      in
      let run_cli ?(from_cwd = false) ?(exit_code = 0) args =
        let runtime_base_path =
          Masc.Workspace.runtime_base_path (Masc.Workspace.Explicit base_path)
        in
        let executable =
          Sys.getenv "MASC_TEST_CHECKPOINT_PURGE_EXE"
          |> Config_dir_resolver.absolute_path
        in
        let child_env =
          [ "HOME=" ^ owner_root
          ; "XDG_CONFIG_HOME=" ^ owner_root
            (* [--apply] takes the workspace writer lease; its file goes
               under the test's own root, not the machine's temp dir. *)
          ; "MASC_BASE_PATH_LEASE_DIR=" ^ owner_root
          ]
          @ (if from_cwd then [] else [ "MASC_BASE_PATH=" ^ runtime_base_path ])
          @ (match cluster_name with
             | None -> []
             | Some name -> [ "MASC_CLUSTER_NAME=" ^ name ])
        in
        let output =
          Eio.Process.parse_out
            ~cwd:Eio.Path.(Eio.Stdenv.fs env / base_path)
            ~env:(Array.of_list child_env)
            ~is_success:(Int.equal exit_code)
            (Eio.Stdenv.process_mgr env) Eio.Buf_read.take_all
            ([ executable
             ; "--trace"; checkpoint.session_id; "--keep-recent"; "0"
             ] @ args)
        in
        Alcotest.(check bool) "CLI reports the producer checkpoint" true
          (List.mem ("checkpoint: " ^ checkpoint_path)
             (String.split_on_char '\n' output));
        print_string output;
        output
      in
      let run_cli ?from_cwd ?exit_code args =
        let (_ : string) = run_cli ?from_cwd ?exit_code args in
        ()
      in
      run_cli [ "--base"; base_path ];
      Alcotest.(check (list (pair string (option string))))
        "dry-run leaves all workspace files and directories unchanged"
        before (workspace_contents owner_root);
      run_cli [];
      Alcotest.(check (list (pair string (option string))))
        "MASC_BASE_PATH dry-run uses the same workspace without writes"
        before (workspace_contents owner_root);
      run_cli ~from_cwd:true [];
      Alcotest.(check (list (pair string (option string))))
        "no base or recorded default uses current workspace without writes"
        before (workspace_contents owner_root);
      (* RFC librarian-lifecycle §10-2 at the CLI: a position short of the
         end refuses the apply and writes nothing; a position at the end stays
         where it was, because the purge keeps the history's end. *)
      let atoms = atom_count checkpoint.messages in
      write_progress ~end_atom:(atoms - 1);
      let before_refused = workspace_contents owner_root in
      run_cli ~exit_code:1 [ "--base"; base_path; "--apply" ];
      Alcotest.(check (list (pair string (option string))))
        "a refused apply writes nothing"
        before_refused (workspace_contents owner_root);
      write_progress ~end_atom:atoms;
      run_cli [ "--base"; base_path; "--apply" ];
      let backup_dirs =
        Sys.readdir runtime_root |> Array.to_list
        |> List.filter (String.starts_with
             ~prefix:("backups-checkpoint-purge-" ^ checkpoint.session_id ^ "-"))
      in
      let backup_dir = match backup_dirs with
        | [ name ] -> Filename.concat runtime_root name
        | names -> Alcotest.failf "expected one backup in runtime root, got %d"
                     (List.length names)
      in
      let backup = Filename.concat backup_dir (checkpoint.session_id ^ ".json") in
      Alcotest.(check string) "backup preserves every original byte" original
        (In_channel.with_open_bin backup In_channel.input_all);
      (match Masc.Keeper_checkpoint_store.load_agent_core
        ~session_dir ~session_id:checkpoint.session_id with
       | Error _ -> Alcotest.fail "applied checkpoint is not readable"
       | Ok purged ->
           Alcotest.(check int) "actual CLI keeps every message"
             (List.length checkpoint.messages) (List.length purged.messages);
           Alcotest.(check bool) "and rewrote something" true
             (Agent_core.Checkpoint.to_string purged
              <> Agent_core.Checkpoint.to_string checkpoint);
           Alcotest.(check int) "apply preserves turn watermark" checkpoint.turn_count
             purged.turn_count;
           Alcotest.(check string) "apply preserves session identity" checkpoint.session_id
             purged.session_id;
           let moved = read_progress () in
           Alcotest.(check int) "apply leaves the Librarian position at the end"
             atoms moved.position.end_atom;
           Alcotest.(check int) "which is still the history's end"
             (atom_count purged.messages) moved.position.end_atom;
           Alcotest.(check int) "apply leaves boundary_lines_seen alone"
             fixture_boundary_lines_seen moved.boundary_lines_seen))

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
            { turn_ref = Ids.Turn_ref.make ~trace_id:fixture_trace ~absolute_turn
            ; history_at_start = Boundaries.Continued_history
            ; position = Boundaries.Atom_history { end_atom; last_atom_digest }
            }
      } )
;;

let purge_with ?progress ~boundary_lines ~continuity messages =
  match
    Purge.purge_messages
      ~config:no_tail_config
      ~trace_id:fixture_trace
      ~boundary_lines
      ~continuity
      ~progress
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
let test_a_fitting_working_state_keeps_its_prefix () =
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
  let snapshot =
    match
      Masc.Librarian_continuity_snapshot.capture_checkpoint_prefix
        ~end_atom:3
        ~trace_id:fixture_trace
        ~lines
        ~messages
        ~working_state:"turn one"
        ()
    with
    | Ok snapshot -> snapshot
    | Error error -> Alcotest.fail (Masc.Librarian_continuity_snapshot.error_to_string error)
  in
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
    (report.reasoning_blocks_stripped, report.tool_results_cleared)
;;

(* A recovery drops the broken tail, so the last atom it keeps is the last
   one it returns, not the one the input ended on. *)
let test_recovery_keeps_the_last_atom_it_returns () =
  let last_kept =
    block_message Types.Assistant [ unsigned_thinking "before the break"; Types.Text "kept" ]
  in
  let messages =
    [ text_message Types.User "q"
    ; block_message Types.Assistant [ unsigned_thinking "earlier"; Types.Text "a" ]
    ; text_message Types.User "(autonomous wake)"
    ; last_kept
    ; block_message Types.Assistant [ tool_use "c1" ]
    ; block_message Types.Assistant [ tool_use "c2" ]
    ; { (block_message Types.Tool [ tool_result "c1" ]) with tool_call_id = Some "c1" }
    ; { (block_message Types.Tool [ tool_result "c2" ]) with tool_call_id = Some "c2" }
    ]
  in
  match purge_plain ~config:no_tail_config messages with
  | Error error -> Alcotest.fail (Purge.purge_error_to_string error)
  | Ok (purged, report) ->
    Alcotest.(check bool) "the break was dropped" true
      (report.messages_dropped_at_structural_break > 0);
    Alcotest.(check string) "the last atom it returns opens exactly as before"
      (Types.show_message last_kept)
      (Types.show_message (List.nth purged (List.length purged - 1)));
    Alcotest.(check int) "the earlier reply is still stripped" 1
      report.reasoning_blocks_stripped
;;

(* A second tool_use opens while the first is unanswered: the break a
   recovery drops, and everything after it. *)
let overlapping_cycles () =
  [ block_message Types.Assistant [ tool_use "c1" ]
  ; block_message Types.Assistant [ tool_use "c2" ]
  ; { (block_message Types.Tool [ tool_result "c1" ]) with tool_call_id = Some "c1" }
  ; { (block_message Types.Tool [ tool_result "c2" ]) with tool_call_id = Some "c2" }
  ]
;;

(* masc #37772. Two turns: the first ends after two atoms and its line says
   so; the second asks, answers, and then breaks on an overlapping tool cycle.
   The broken turn still ended, and the Librarian read to its end. *)
let broken_second_turn () =
  let first_turn =
    [ text_message Types.User "q1"; block_message Types.Assistant [ Types.Text "a1" ] ]
  in
  let before_the_break =
    [ text_message Types.User "q2"
    ; block_message Types.Assistant [ unsigned_thinking "t2"; Types.Text "a2" ]
    ]
  in
  let messages = first_turn @ before_the_break @ overlapping_cycles () in
  let lines =
    [ turn_ended_line ~line:1 ~absolute_turn:1 messages ~end_atom:2
    ; turn_ended_line ~line:2 ~absolute_turn:2 messages ~end_atom:(atom_count messages)
    ]
  in
  let progress =
    { (progress_at messages ~end_atom:(atom_count messages)) with boundary_lines_seen = 2 }
  in
  first_turn, before_the_break, messages, lines, progress
;;

let stated_by ~(progress : Progress.t) lines messages =
  let end_atom, last_atom_digest = atom_position messages in
  Option.map
    (fun (line, _recorded_at, _turn_ref) -> line)
    (Boundaries.witness_line
       ~through:progress.boundary_lines_seen
       ~trace_id:fixture_trace
       ~end_atom
       ~last_atom_digest
       lines)
;;

(* Without a position nothing needs a line, and the recovery keeps every
   closed unit ahead of the break -- half of the second turn, an end no line
   states. With one, it goes back to the first turn's end, which a line the
   position counted states, and the rebase moves the position there: the
   Librarian finds its line through the same lookup it reads by. Moved to
   the break instead, the position would stop every round
   ([specs/bug-models/LibrarianRead-purge-trim-anywhere-live-buggy.cfg]). *)
let test_recovery_ends_where_a_counted_line_states_the_end () =
  let first_turn, before_the_break, messages, lines, progress = broken_second_turn () in
  let at_break, _ = purge_with ~boundary_lines:lines ~continuity:None messages in
  Alcotest.(check int) "without a position it ends at the break"
    (List.length (first_turn @ before_the_break)) (List.length at_break);
  Alcotest.(check (option int)) "an end no counted line states" None
    (stated_by ~progress lines at_break);
  let recovered, report =
    purge_with ~progress ~boundary_lines:lines ~continuity:None messages
  in
  Alcotest.(check (list string)) "with one it ends at the first turn's end, byte-exact"
    (List.map Types.show_message first_turn) (List.map Types.show_message recovered);
  Alcotest.(check int) "and counts what it cut as dropped"
    (List.length messages - List.length first_turn)
    report.messages_dropped_at_structural_break;
  match rebase ~progress:(Some progress) ~before:messages ~after:recovered () with
  | Ok (Purge.Rebased { before = _; after }) ->
    Alcotest.(check int) "the position moves to that end" 2 after.position.end_atom;
    Alcotest.(check (option int)) "and stands on the line that states it" (Some 1)
      (stated_by ~progress:after lines recovered)
  | Ok Purge.No_progress -> Alcotest.fail "a position was given and none came back"
  | Error refusal -> Alcotest.fail (Purge.refusal_to_string refusal)
;;

(* A line past [boundary_lines_seen] is not one the position took in, so it
   is no place to move it: the Librarian would not find it there either. *)
let test_recovery_passes_over_a_line_the_position_has_not_counted () =
  let first_turn, before_the_break, messages, lines, progress = broken_second_turn () in
  let uncounted =
    turn_ended_line ~line:3 ~absolute_turn:3 messages
      ~end_atom:(atom_count (first_turn @ before_the_break))
  in
  let recovered, _ =
    purge_with
      ~progress
      ~boundary_lines:(lines @ [ uncounted ])
      ~continuity:None
      messages
  in
  Alcotest.(check int) "it goes back to the counted turn end"
    (List.length first_turn) (List.length recovered)
;;

(* No counted line states an end ahead of the break: every end the recovery
   could leave would strand the position, so it is refused. *)
let test_recovery_without_a_counted_end_is_refused () =
  let _first_turn, _before_the_break, messages, lines, progress = broken_second_turn () in
  let only_the_broken_turn = List.filter (fun (line, _) -> line = 2) lines in
  match
    Purge.purge_messages
      ~config:no_tail_config
      ~trace_id:fixture_trace
      ~boundary_lines:only_the_broken_turn
      ~continuity:None
      ~progress:(Some progress)
      messages
  with
  | Error (Purge.Recovery_end_unwitnessed { boundary_lines_seen }) ->
    Alcotest.(check int) "it names the lines it looked through" 2 boundary_lines_seen
  | Error error -> Alcotest.fail (Purge.purge_error_to_string error)
  | Ok _ -> Alcotest.fail "a recovery was allowed to strand the position"
;;

(* A position in another trace is not moved into this history (the rebase
   refuses it), so it asks for no line here and the recovery ends at the
   break. *)
let test_recovery_ignores_a_position_of_another_trace () =
  let first_turn, before_the_break, messages, lines, progress = broken_second_turn () in
  let elsewhere =
    { progress with position = { progress.position with trace_id = "trace-elsewhere" } }
  in
  let recovered, _ =
    purge_with ~progress:elsewhere ~boundary_lines:lines ~continuity:None messages
  in
  Alcotest.(check int) "it ends at the break"
    (List.length (first_turn @ before_the_break)) (List.length recovered)
;;

(* A sound history is not cut, position or not: its end does not move. *)
let test_a_sound_history_is_not_cut_for_a_position () =
  let first_turn, before_the_break, _messages, lines, progress = broken_second_turn () in
  let sound = first_turn @ before_the_break in
  let purged, report =
    purge_with ~progress ~boundary_lines:lines ~continuity:None sound
  in
  Alcotest.(check int) "every message stays" (List.length sound) (List.length purged);
  Alcotest.(check int) "nothing dropped" 0 report.messages_dropped_at_structural_break
;;

(* Two turns ended ahead of the break, and a line the position counted
   states each end. The recovery keeps the later: the longest history the
   position can stand on. *)
let two_ended_turns_then_a_break () =
  let first_turn =
    [ text_message Types.User "q1"; block_message Types.Assistant [ Types.Text "a1" ] ]
  in
  let second_turn =
    [ text_message Types.User "q2"; block_message Types.Assistant [ Types.Text "a2" ] ]
  in
  let messages =
    first_turn @ second_turn @ [ text_message Types.User "q3" ] @ overlapping_cycles ()
  in
  let progress =
    { (progress_at messages ~end_atom:(atom_count messages)) with boundary_lines_seen = 3 }
  in
  first_turn, second_turn, messages, progress
;;

let test_recovery_keeps_the_latest_counted_turn_end () =
  let first_turn, second_turn, messages, progress = two_ended_turns_then_a_break () in
  let lines =
    [ turn_ended_line ~line:1 ~absolute_turn:1 messages ~end_atom:2
    ; turn_ended_line ~line:2 ~absolute_turn:2 messages ~end_atom:4
    ; turn_ended_line ~line:3 ~absolute_turn:3 messages ~end_atom:(atom_count messages)
    ]
  in
  let recovered, _ = purge_with ~progress ~boundary_lines:lines ~continuity:None messages in
  Alcotest.(check (list string)) "it keeps both ended turns"
    (List.map Types.show_message (first_turn @ second_turn))
    (List.map Types.show_message recovered)
;;

(* A line with the end count of the second turn but another history's digest
   is not the second turn's end: the Librarian would not find the position on
   it, so the recovery does not stop there. *)
let test_recovery_needs_the_digest_as_well_as_the_count () =
  let first_turn, _second_turn, messages, progress = two_ended_turns_then_a_break () in
  let of_another_history : Purge.boundary_line =
    ( 2
    , Ok
        { Boundaries.recorded_at = 100.0
        ; event =
            Boundaries.Turn_ended
              { turn_ref = Ids.Turn_ref.make ~trace_id:fixture_trace ~absolute_turn:2
              ; history_at_start = Boundaries.Continued_history
              ; position =
                  Boundaries.Atom_history
                    { end_atom = 4; last_atom_digest = "a digest of another history" }
              }
        } )
  in
  let lines =
    [ turn_ended_line ~line:1 ~absolute_turn:1 messages ~end_atom:2
    ; of_another_history
    ; turn_ended_line ~line:3 ~absolute_turn:3 messages ~end_atom:(atom_count messages)
    ]
  in
  let recovered, _ = purge_with ~progress ~boundary_lines:lines ~continuity:None messages in
  Alcotest.(check (list string)) "it goes back to the first turn's end"
    (List.map Types.show_message first_turn)
    (List.map Types.show_message recovered)
;;

(* A position short of the history's end is not moved: the rebase refuses it
   for its unread atoms. The recovery then ends at the break and asks no line
   of it, so that refusal, not a missing turn end, is what the operator
   reads. *)
let test_recovery_leaves_an_unread_position_to_the_rebase () =
  let first_turn, before_the_break, messages, lines, _progress = broken_second_turn () in
  let short =
    { (progress_at messages ~end_atom:(atom_count messages - 1)) with
      boundary_lines_seen = 2
    }
  in
  let only_the_broken_turn = List.filter (fun (line, _) -> line = 2) lines in
  let recovered, _ =
    purge_with ~progress:short ~boundary_lines:only_the_broken_turn ~continuity:None messages
  in
  Alcotest.(check int) "it ends at the break"
    (List.length (first_turn @ before_the_break)) (List.length recovered);
  match rebase ~progress:(Some short) ~before:messages ~after:recovered () with
  | Error (Purge.Unread_atoms_present _) -> ()
  | Error refusal -> Alcotest.fail (Purge.refusal_to_string refusal)
  | Ok _ -> Alcotest.fail "a position with unread atoms was moved"
;;

(* The protected tail is the last [keep_recent_messages] messages of the
   history the recovery returns, not of the input it cut. *)
let test_recovery_protects_the_tail_of_what_it_returns () =
  let reply_in_the_tail =
    block_message Types.Assistant [ unsigned_thinking "t1"; Types.Text "a1" ]
  in
  let messages =
    [ text_message Types.User "q1"
    ; reply_in_the_tail
    ; text_message Types.User "q2"
    ; block_message Types.Assistant [ Types.Text "a2" ]
    ]
    @ overlapping_cycles ()
  in
  match purge_plain ~config:{ no_tail_config with keep_recent_messages = 3 } messages with
  | Error error -> Alcotest.fail (Purge.purge_error_to_string error)
  | Ok (purged, report) ->
    Alcotest.(check string) "the reply inside the tail is byte-exact"
      (Types.show_message reply_in_the_tail)
      (Types.show_message (List.nth purged 1));
    Alcotest.(check int) "nothing in the returned tail is stripped" 0
      report.Purge.reasoning_blocks_stripped
;;

let () =
  Alcotest.run
    "keeper checkpoint purge"
    [ ( "atoms"
      , [ Alcotest.test_case
            "repeated messages all survive"
            `Quick
            test_repeated_messages_all_survive
        ; Alcotest.test_case
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
            test_a_fitting_working_state_keeps_its_prefix
        ; Alcotest.test_case
            "recovery keeps the last atom it returns"
            `Quick
            test_recovery_keeps_the_last_atom_it_returns
        ; Alcotest.test_case
            "recovery ends where a counted line states the end"
            `Quick
            test_recovery_ends_where_a_counted_line_states_the_end
        ; Alcotest.test_case
            "recovery passes over a line the position has not counted"
            `Quick
            test_recovery_passes_over_a_line_the_position_has_not_counted
        ; Alcotest.test_case
            "recovery without a counted end is refused"
            `Quick
            test_recovery_without_a_counted_end_is_refused
        ; Alcotest.test_case
            "recovery ignores a position of another trace"
            `Quick
            test_recovery_ignores_a_position_of_another_trace
        ; Alcotest.test_case
            "a sound history is not cut for a position"
            `Quick
            test_a_sound_history_is_not_cut_for_a_position
        ; Alcotest.test_case
            "recovery keeps the latest counted turn end"
            `Quick
            test_recovery_keeps_the_latest_counted_turn_end
        ; Alcotest.test_case
            "recovery needs the digest as well as the count"
            `Quick
            test_recovery_needs_the_digest_as_well_as_the_count
        ; Alcotest.test_case
            "recovery leaves an unread position to the rebase"
            `Quick
            test_recovery_leaves_an_unread_position_to_the_rebase
        ; Alcotest.test_case
            "recovery protects the tail of what it returns"
            `Quick
            test_recovery_protects_the_tail_of_what_it_returns
        ] )
    ; ( "rules"
      , [ Alcotest.test_case "reasoning strip scope" `Quick test_reasoning_strip_scope
        ; Alcotest.test_case
            "unsigned reasoning inside a tool cycle is stripped"
            `Quick
            test_unsigned_reasoning_inside_tool_cycle_is_stripped
        ; Alcotest.test_case
            "signed reasoning inside a tool cycle is kept"
            `Quick
            test_signed_reasoning_inside_tool_cycle_is_kept
        ; Alcotest.test_case
            "a thinking-only interstitial cycle message is kept"
            `Quick
            test_thinking_only_interstitial_cycle_message_is_kept
        ; Alcotest.test_case
            "tool result clear preserves pairing"
            `Quick
            test_tool_result_clear_preserves_pairing
        ; Alcotest.test_case
            "error tool result is never cleared"
            `Quick
            test_error_tool_result_is_never_cleared
        ] )
    ; ( "boundaries"
      , [ Alcotest.test_case
            "protected tail is byte exact"
            `Quick
            test_protected_tail_is_byte_exact
        ; Alcotest.test_case
            "cycle overlapping the tail is untouched"
            `Quick
            test_cycle_overlapping_protected_tail_is_untouched
        ; Alcotest.test_case "purge is idempotent" `Quick test_purge_is_idempotent
        ; Alcotest.test_case
            "broken structure is recovered, not refused"
            `Quick
            test_broken_structure_is_recovered_not_refused
        ; Alcotest.test_case
            "recovered output is structurally sound"
            `Quick
            test_recovered_output_is_structurally_sound
        ; Alcotest.test_case
            "sound input drops nothing at a break"
            `Quick
            test_sound_input_drops_nothing_at_a_break
        ; Alcotest.test_case
            "config bounds are enforced"
            `Quick
            test_config_bounds_are_enforced
        ; Alcotest.test_case
            "checkpoint fields pass through"
            `Quick
            test_checkpoint_fields_pass_through
        ] )
    ; ( "librarian rebase (RFC librarian-lifecycle §10-2)"
      , [ Alcotest.test_case
            "librarian_rebase_refuses_unread_atoms"
            `Quick
            test_librarian_rebase_refuses_unread_atoms
        ; Alcotest.test_case
            "librarian_rebase_keeps_the_position_at_the_end"
            `Quick
            test_librarian_rebase_keeps_the_position_at_the_end
        ; Alcotest.test_case
            "librarian_rebase_keeps_boundary_lines_seen"
            `Quick
            test_librarian_rebase_keeps_boundary_lines_seen
        ; Alcotest.test_case
            "librarian_rebase_leaves_nothing_to_read"
            `Quick
            test_librarian_rebase_leaves_nothing_to_read
        ; Alcotest.test_case
            "librarian_rebase_without_a_position"
            `Quick
            test_librarian_rebase_without_a_position
        ; Alcotest.test_case
            "librarian_rebase_refuses_another_trace"
            `Quick
            test_librarian_rebase_refuses_another_trace
        ; Alcotest.test_case
            "librarian_rebase_refuses_a_position_beyond_the_history"
            `Quick
            test_librarian_rebase_refuses_a_position_beyond_the_history
        ; Alcotest.test_case
            "librarian_rebase_refuses_another_history_at_the_same_end"
            `Quick
            test_librarian_rebase_refuses_another_history_at_the_same_end
        ; Alcotest.test_case
            "librarian_rebase_refuses_a_rewrite_with_no_atoms"
            `Quick
            test_librarian_rebase_refuses_a_rewrite_with_no_atoms
        ] )
    ; ( "cli"
      , [ Alcotest.test_case "default cluster: workspace dry-run and apply" `Quick
            (test_cli_workspace None)
        ; Alcotest.test_case "named cluster: workspace dry-run and apply" `Quick
            (test_cli_workspace (Some "  Purge/Cluster  "))
        ; Alcotest.test_case "linked worktree: shared runtime dry-run and apply" `Quick
            (test_cli_workspace ~linked_worktree:true None)
        ] )
    ]
