(* RFC-0351 S1: deterministic offline checkpoint purge. The rules were
   measured live on one Keeper's checkpoint (1,315 -> 579 messages, -28.0%
   bytes); these tests pin the rule contract so the checked-in tool cannot
   drift from what was validated. *)

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

let run ?(config = no_tail_config) messages =
  match Purge.purge_messages ~config messages with
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

let test_duplicate_collapse_keeps_first_and_last () =
  let wake = text_message Types.User "(autonomous wake)" in
  let messages =
    [ wake
    ; text_message Types.Assistant "reply-a"
    ; wake
    ; text_message Types.Assistant "reply-b"
    ; wake
    ; wake
    ]
  in
  let purged, report = run messages in
  Alcotest.(check int) "two middles dropped" 2 report.duplicates_dropped;
  Alcotest.(check (list string))
    "first and last occurrence survive in order"
    [ "(autonomous wake)"; "reply-a"; "reply-b"; "(autonomous wake)" ]
    (message_texts purged)

let test_duplicates_below_threshold_survive () =
  let wake = text_message Types.User "(autonomous wake)" in
  let messages = [ wake; text_message Types.Assistant "reply"; wake ] in
  let _purged, report = run messages in
  Alcotest.(check int) "pair is under the threshold" 0 report.duplicates_dropped

let test_duplicate_tool_cycles_are_never_collapsed () =
  (* Byte-identical cycles differ only in tool_use_id here — but even truly
     repeated payloads must stay: R1 is scoped to text-only ordinary
     messages. *)
  let messages = cycle "a" @ cycle "b" @ cycle "c" in
  let purged, report = run messages in
  Alcotest.(check int) "no cycle collapsed" 0 report.duplicates_dropped;
  Alcotest.(check int) "all cycle messages survive" 6 (List.length purged)

let test_reasoning_strip_scope () =
  let messages =
    [ block_message Types.Assistant [ unsigned_thinking "t1"; Types.Text "answer" ]
    ; block_message Types.Assistant [ unsigned_thinking "t2" ]
    ; block_message Types.Assistant [ signed_thinking "t3"; Types.Text "signed" ]
    ]
  in
  let purged, report = run messages in
  Alcotest.(check int) "unsigned blocks stripped" 2 report.reasoning_blocks_stripped;
  Alcotest.(check int) "thinking-only message dropped" 1 report.reasoning_messages_dropped;
  Alcotest.(check (list string))
    "text survives; signed thinking is untouched"
    [ "answer"; "<thinking>|signed" ]
    (message_texts purged)

(* Contract change: R2 used to skip any message carrying a ToolUse, so the
   assistant message that opens a tool cycle kept its unsigned reasoning. On an
   agentic keeper that is almost every assistant message — measured on the
   that checkpoint, 418 of 422 surviving unsigned Thinking blocks (490,370 B,
   41.0% of the file) were held by this rule. Unsigned reasoning carries no
   signature to replay, so the exemption bought nothing. *)
let test_unsigned_reasoning_inside_tool_cycle_is_stripped () =
  let messages =
    [ block_message Types.Assistant [ unsigned_thinking "pre-tool"; tool_use "a" ]
    ; { (block_message Types.Tool [ tool_result "a" ]) with tool_call_id = Some "a" }
    ]
  in
  let purged, report = run messages in
  Alcotest.(check int)
    "unsigned reasoning is stripped even beside a tool_use"
    1
    report.reasoning_blocks_stripped;
  Alcotest.(check int) "no cycle message dropped" 2 (List.length purged);
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
    ]
  in
  let purged, report = run messages in
  Alcotest.(check int)
    "signed reasoning beside a tool_use is untouched"
    0
    report.reasoning_blocks_stripped;
  Alcotest.(check int) "no cycle message dropped" 2 (List.length purged);
  match List.hd purged with
  | { Types.content = [ Types.Thinking { signature = Some _; _ }; Types.ToolUse _ ]; _ } ->
    ()
  | other ->
    Alcotest.failf
      "signed thinking must replay byte-exact, got %s"
      (Types.show_message other)

(* An assistant progress frame can sit inside an already-open tool cycle
   without carrying either anchor. Once its unsigned reasoning is stripped,
   dropping that empty interstitial frame leaves the ToolUse/ToolResult pair
   intact. *)
let test_thinking_only_interstitial_cycle_message_is_dropped () =
  let messages =
    [ block_message Types.Assistant [ tool_use "a" ]
    ; block_message Types.Assistant [ unsigned_thinking "only-thinking" ]
    ; { (block_message Types.Tool [ tool_result "a" ]) with tool_call_id = Some "a" }
    ; text_message Types.User "after"
    ]
  in
  let purged, report = run messages in
  Alcotest.(check int) "unsigned reasoning stripped" 1 report.reasoning_blocks_stripped;
  Alcotest.(check int) "empty interstitial dropped" 1 report.reasoning_messages_dropped;
  Alcotest.(check int) "pairing intact" 3 (List.length purged);
  match Masc.Keeper_transcript_unit.validate purged with
  | Ok () -> ()
  | Error _ -> Alcotest.fail "dropping the interstitial broke tool pairing"

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
  let messages = error_cycle "a" @ cycle "b" in
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
  Alcotest.(check int) "tail duplicates survive" 0 report.duplicates_dropped;
  Alcotest.(check int) "tail reasoning survives" 0 report.reasoning_blocks_stripped;
  Alcotest.(check int) "nothing dropped" 7 (List.length purged)

let test_cycle_overlapping_protected_tail_is_untouched () =
  let config = { Purge.default_config with keep_recent_messages = 1 } in
  (* The cycle's final message falls inside the protected tail; the whole
     cycle must be exempt from R3. *)
  let messages = [ text_message Types.User "head" ] @ cycle "a" in
  let _purged, report = run ~config messages in
  Alcotest.(check int) "overlapping cycle not cleared" 0 report.tool_results_cleared

let test_strip_revealed_duplicates_collapse_in_one_pass () =
  (* Three assistant replies that differ only in their reasoning become
     byte-identical once R2 strips them; R1 must see the stripped form in the
     same pass (measured on that checkpoint: the reverse ordering left
     229 duplicates for a second run to find). *)
  let reply thinking =
    block_message Types.Assistant [ unsigned_thinking thinking; Types.Text "same answer" ]
  in
  let messages =
    [ reply "t1"
    ; text_message Types.User "q1"
    ; reply "t2"
    ; text_message Types.User "q2"
    ; reply "t3"
    ]
  in
  let purged, report = run messages in
  Alcotest.(check int) "three blocks stripped" 3 report.reasoning_blocks_stripped;
  Alcotest.(check int) "middle stripped duplicate dropped" 1 report.duplicates_dropped;
  Alcotest.(check (list string))
    "first and last stripped occurrence survive"
    [ "same answer"; "q1"; "q2"; "same answer" ]
    (message_texts purged)

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
  Alcotest.(check int) "no further duplicates" 0 second_report.duplicates_dropped;
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
  match Purge.purge_messages ~config:no_tail_config [ orphan ] with
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
  match Purge.purge_messages ~config:no_tail_config messages with
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
  match Purge.purge_messages ~config:no_tail_config (cycle "a" @ cycle "b") with
  | Error _ -> Alcotest.fail "a sound transcript was refused"
  | Ok (_, report) ->
    Alcotest.(check int)
      "nothing dropped at a break there is not"
      0
      report.Purge.messages_dropped_at_structural_break

let test_config_bounds_are_enforced () =
  (match
     Purge.purge_messages
       ~config:{ no_tail_config with dup_threshold = 1 }
       [ text_message Types.User "x" ]
   with
   | Error (Purge.Invalid_config _) -> ()
   | _ -> Alcotest.fail "dup_threshold 1 was accepted");
  match
    Purge.purge_messages
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
          ; text_message Types.User "(autonomous wake)"
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
  match Purge.purge ~config:no_tail_config checkpoint with
  | Error _ -> Alcotest.fail "checkpoint purge failed"
  | Ok (purged, report) ->
    Alcotest.(check int) "one middle dropped" 1 report.duplicates_dropped;
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
  match Purge.purge ~config:no_tail_config checkpoint with
  | Error _ -> Alcotest.fail "checkpoint purge failed"
  | Ok (purged, _) -> checkpoint.messages, purged.Agent_core.Checkpoint.messages
;;

let atom_count messages = snd (Window.annotate messages)

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

(* [LibrarianRead-purge-trim-at-end.cfg]: at the end, the position moves to
   the end of the rewritten history. *)
let test_librarian_rebase_moves_the_position_to_the_rewritten_end () =
  let _before, after, progress, moved_from, moved_to = rebased_at_end () in
  let end_atom, last_atom_digest = atom_position after in
  Alcotest.(check bool) "the rebase hands back the position it moved" true
    (moved_from == progress);
  Alcotest.(check int) "end_atom is the rewritten end" end_atom
    moved_to.position.end_atom;
  Alcotest.(check string) "the digest opens the rewritten last atom" last_atom_digest
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

(* [LibrarianRead-purge-trim-at-end-live.cfg]: the old end line stays in the
   log after the purge. Against the rebased position it is not a cut point
   (its end_atom is past the rewritten history), so the next round has
   nothing to read and does not stop; against the old position the same
   round stops on the mismatch, which is why a rewrite is never installed
   without its rebase. *)
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
  (match select moved_to with
   | Range.Nothing_to_read -> ()
   | Range.Read _ | Range.Baseline _ | Range.Position_in_other_trace _ ->
     Alcotest.fail "the rebased position found something to read in a fully read history"
   | Range.Stop _ -> Alcotest.fail "the rebased position stopped the round");
  match select old_progress with
  | Range.Stop (Range.Position_mismatch { atom_count = rewritten_atoms; _ }) ->
    Alcotest.(check int) "the old position is past the rewritten history"
      (atom_count after) rewritten_atoms
  | Range.Stop (Range.Unreadable_line _) -> Alcotest.fail "the old end line was refused"
  | Range.Nothing_to_read | Range.Read _ | Range.Baseline _ | Range.Position_in_other_trace _ ->
    Alcotest.fail "the old position did not stop on the rewritten history"
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
      let runtime_entries = Sys.readdir runtime_root |> Array.to_list in
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
         end refuses the apply and writes nothing; a position at the end is
         moved to the rewritten end after the checkpoint is installed. *)
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
        |> List.filter (fun name -> not (List.mem name runtime_entries))
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
           Alcotest.(check int) "actual CLI removes the middle duplicate" 2
             (List.length purged.messages);
           Alcotest.(check int) "apply preserves turn watermark" checkpoint.turn_count
             purged.turn_count;
           Alcotest.(check string) "apply preserves session identity" checkpoint.session_id
             purged.session_id;
           let moved = read_progress () in
           Alcotest.(check int) "apply moves the Librarian position to the rewritten end"
             (atom_count purged.messages) moved.position.end_atom;
           Alcotest.(check int) "apply leaves boundary_lines_seen alone"
             fixture_boundary_lines_seen moved.boundary_lines_seen))

let () =
  Alcotest.run
    "keeper checkpoint purge"
    [ ( "rules"
      , [ Alcotest.test_case
            "duplicate collapse keeps first and last"
            `Quick
            test_duplicate_collapse_keeps_first_and_last
        ; Alcotest.test_case
            "duplicates below threshold survive"
            `Quick
            test_duplicates_below_threshold_survive
        ; Alcotest.test_case
            "tool cycles are never collapsed"
            `Quick
            test_duplicate_tool_cycles_are_never_collapsed
        ; Alcotest.test_case "reasoning strip scope" `Quick test_reasoning_strip_scope
        ; Alcotest.test_case
            "unsigned reasoning inside a tool cycle is stripped"
            `Quick
            test_unsigned_reasoning_inside_tool_cycle_is_stripped
        ; Alcotest.test_case
            "signed reasoning inside a tool cycle is kept"
            `Quick
            test_signed_reasoning_inside_tool_cycle_is_kept
        ; Alcotest.test_case
            "a thinking-only interstitial cycle message is dropped"
            `Quick
            test_thinking_only_interstitial_cycle_message_is_dropped
        ; Alcotest.test_case
            "tool result clear preserves pairing"
            `Quick
            test_tool_result_clear_preserves_pairing
        ; Alcotest.test_case
            "error tool result is never cleared"
            `Quick
            test_error_tool_result_is_never_cleared
        ; Alcotest.test_case
            "strip-revealed duplicates collapse in one pass"
            `Quick
            test_strip_revealed_duplicates_collapse_in_one_pass
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
            "librarian_rebase_moves_the_position_to_the_rewritten_end"
            `Quick
            test_librarian_rebase_moves_the_position_to_the_rewritten_end
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
