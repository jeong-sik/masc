(* Deterministic offline checkpoint purge. See the .mli for the
   rule contract. The implementation works on the closed units produced by
   [Keeper_transcript_unit.partition] so a tool cycle is one indivisible item
   from the first line to the last. *)

type config =
  { keep_recent_messages : int
  ; strip_thinking : bool
  ; clear_tool_results : bool
  }

let default_config =
  { keep_recent_messages = 20; strip_thinking = true; clear_tool_results = true }
;;

let cleared_tool_result_content =
  "[old tool result content cleared by keeper checkpoint purge]"
;;

type report =
  { messages_before : int
  ; messages_after : int
  ; reasoning_blocks_stripped : int
  ; tool_results_cleared : int
  ; messages_dropped_at_structural_break : int
  }

type purge_error =
  | Repetition_boundary_invalid of string
  | Invalid_config of string
  | Invalid_input_structure of Keeper_transcript_unit.structural_error
  | Invalid_output_structure of Keeper_transcript_unit.structural_error
  | Atom_count_changed of
      { before : int
      ; after : int
      }
  | Kept_atom_rewritten of { atom : int }
  | Continuity_no_longer_fits of Librarian_continuity_snapshot.error

let purge_error_to_string = function
  | Repetition_boundary_invalid detail -> "repetition boundary invalid: " ^ detail
  | Invalid_config detail -> "invalid config: " ^ detail
  | Invalid_input_structure structural ->
    Keeper_transcript_unit.show_structural_error structural
  | Invalid_output_structure structural ->
    "purge produced invalid structure: "
    ^ Keeper_transcript_unit.show_structural_error structural
  | Atom_count_changed { before; after } ->
    Printf.sprintf "purge changed the atom count (%d -> %d)" before after
  | Kept_atom_rewritten { atom } ->
    Printf.sprintf
      "purge rewrote the message opening atom %d, which the history's end or a \
       turn-boundary line names"
      atom
  | Continuity_no_longer_fits error ->
    "the Librarian working state fits the history before the purge and not after it: "
    ^ Librarian_continuity_snapshot.error_to_string error
;;

(* One purge work item: an ordinary message or a whole closed tool cycle.
   [flat_last] is the index of the item's last message in the original list,
   used for the count-based protected tail. *)
type item =
  { unit_ : Keeper_transcript_unit.closed_unit
  ; flat_last : int
  }

let is_assistant (message : Agent_core.Types.message) =
  match message.role with
  | Agent_core.Types.Assistant -> true
  | Agent_core.Types.User | Agent_core.Types.System | Agent_core.Types.Tool -> false
;;

(* Reasoning strip: remove unsigned reasoning blocks. Signed thinking and
   [RedactedThinking] replay byte-exact on tool turns and are kept — that
   distinction lives in the match below, which is the whole safety argument.

   The strip originally also skipped any assistant message carrying a ToolUse
   (#25537). That outer guard had no rationale of its own: the commit message
   justified it with "providers replay [signed thinking] byte-exact", which the
   [signature = None] pattern already enforces per block. On an agentic keeper
   the guard swallows nearly everything — measured on a live Keeper checkpoint
   after a full purge, 418 of 422 surviving unsigned Thinking blocks (490,370 B,
   41.0% of the 1,196,574 B file) sat in messages that also carried a ToolUse.
   Unsigned thinking additionally cannot be replayed to Anthropic in that
   position at all: extended-thinking replay requires the signature, so these
   blocks originate from non-Anthropic runtimes and are inert bulk on the wire. *)
let strip_reasoning_blocks (message : Agent_core.Types.message) =
  let kept, stripped =
    List.fold_left
      (fun (kept, stripped) block ->
         match block with
         | Agent_core.Types.Thinking { signature = None; _ }
         | Agent_core.Types.ReasoningDetails _ -> kept, stripped + 1
         | Agent_core.Types.Thinking { signature = Some _;_} | Agent_core.Types.Text _
         | Agent_core.Types.RedactedThinking _ | Agent_core.Types.ToolUse _
         | Agent_core.Types.ToolReference _ | Agent_core.Types.ToolResult _ | Agent_core.Types.Image _ | Agent_core.Types.Document _
         | Agent_core.Types.Audio _ -> block :: kept, stripped)
      ([], 0)
      message.content
  in
  { message with Agent_core.Types.content = List.rev kept }, stripped
;;

(* Tool-result clear: replace a SUCCESSFUL tool result's payload with the fixed marker while
   keeping the [tool_use_id] pairing and the typed delivery outcome.
   Failed results ([Tool_failed]) are exempt: their payload is the feedback
   the keeper reads on later turns and the only lesson evidence the librarian
   could learn from, and the exemption is a type-level distinction (the typed
   outcome), not content classification — RFC-0351 §2 permits judging by
   type. *)
let clear_tool_result_blocks (message : Agent_core.Types.message) =
  let cleared_count = ref 0 in
  let content =
    List.map
      (fun block ->
         match block with
         | Agent_core.Types.ToolResult { outcome = Agent_core.Types.Tool_failed _; _ }
           -> block
         | Agent_core.Types.ToolResult
             ({ content
              ; json
              ; content_blocks
              ; outcome = Agent_core.Types.Tool_succeeded
              ; _
              } as result) ->
           if String.equal content cleared_tool_result_content
              && Option.is_none json
              && Option.is_none content_blocks
           then block
           else (
             incr cleared_count;
             Agent_core.Types.ToolResult
               { result with
                 content = cleared_tool_result_content
               ; json = None
               ; content_blocks = None
               })
         | Agent_core.Types.Text _ | Agent_core.Types.Thinking _
         | Agent_core.Types.ReasoningDetails _ | Agent_core.Types.RedactedThinking _
         | Agent_core.Types.ToolUse _ | Agent_core.Types.ToolReference _ | Agent_core.Types.Image _ | Agent_core.Types.Document _
         | Agent_core.Types.Audio _ -> block)
      message.content
  in
  { message with Agent_core.Types.content }, !cleared_count
;;

type boundary_line =
  int * (Keeper_turn_boundaries.record, Keeper_turn_boundaries.read_error) result

(* The atom each completed turn of [trace_id] ended on, [end_atom - 1]: its
   turn-boundary line holds the digest of that atom's opening message, and
   the request front, the Librarian's range and its witness lookup all find
   the line by that digest. A line that cannot be read names nothing anyone
   can match, so it adds nothing to keep. *)
let atoms_named_by_boundaries ~trace_id (lines : boundary_line list) =
  List.filter_map
    (fun ((_line, decoded) : boundary_line) ->
       match decoded with
       | Error (_ : Keeper_turn_boundaries.read_error) -> None
       | Ok record ->
         (match Keeper_turn_boundaries.atom_position_stated ~trace_id record with
          | Some (_turn_ref, end_atom, _digest) when end_atom >= 1 -> Some (end_atom - 1)
          | Some _ | None -> None))
    lines
;;

(* The reasoning strip over one assistant message, never emptying it. A
   message whose only content is unsigned reasoning opens an atom; removing it
   would renumber every atom after it (goo-yang-bong, 2026-09-22), and
   stripping it to nothing would leave an assistant message no provider
   accepts. It stays as it was. *)
let strip_reasoning_keeping_the_message message =
  let stripped, count = strip_reasoning_blocks message in
  match stripped.Agent_core.Types.content with
  | [] -> message, 0
  | _ :: _ -> stripped, count
;;

(* A purge that dropped messages at a structural break shrinks the head. Two
   things hang on that one answer and have to agree: [purge_messages] lifts
   the turn-log rule, and [turn_log_line] asks for the [Reset] line that names
   all the head holds before the change. *)
let shrinks_the_head ~dropped_at_break = dropped_at_break > 0
;;

let purge_messages ~config ~trace_id ~boundary_lines ~continuity ~named messages =
  if config.keep_recent_messages < 0
  then
    Error
      (Invalid_config
         (Printf.sprintf
            "keep_recent_messages must be >= 0 (got %d)"
            config.keep_recent_messages))
  else (
    (* A structurally broken input is the case this tool exists for, and it
       used to be the one case it refused. A keeper whose stored transcript
       carries a break cannot save a checkpoint, so it fails every turn at the
       same message; edgar.a.poe spent 32 consecutive turns on a single split
       tool cycle before it was repaired by hand on 2026-09-01.

       Quarantine alone would not help: it moves the break into the protected
       suffix, which purge preserves verbatim, so the output would still be
       unsaveable and the caller would be told it succeeded. Recovery therefore
       drops the offending cycle and everything after it, and reports how many
       messages that cost. *)
    let inherited_break =
      match Keeper_transcript_unit.validate messages with
      | Ok () -> None
      | Error structural -> Some structural
    in
    let recovering = Option.is_some inherited_break in
    match Keeper_transcript_unit.partition ~quarantine:recovering messages with
    | Error structural -> Error (Invalid_input_structure structural)
    | Ok { closed_prefix; protected_suffix } ->
        (* On a sound input the suffix is the open tail crash recovery needs,
           and it is kept. On a broken one it starts at the break. *)
        let protected_suffix = if recovering then [] else protected_suffix in
        let messages_before = List.length messages in
        (* The history the output keeps: all of it, or on a recovery the closed
           units ahead of the break. Atoms are counted on this history, so a
           recovery keeps the last atom it returns, not one it drops. *)
        let retained =
          if recovering
          then List.concat_map Keeper_transcript_unit.messages_of_closed_unit closed_prefix
          else messages
        in
        let dropped_at_break = messages_before - List.length retained in
        let labelled, atom_count = Runtime_model_input_tail_window.annotate retained in
        let opener_of_atom = Array.make atom_count None in
        List.iteri
          (fun index (_message, label) ->
             match label with
             | Runtime_model_input_tail_window.Atom atom ->
               (match opener_of_atom.(atom) with
                | None -> opener_of_atom.(atom) <- Some index
                | Some _ -> ())
             | Runtime_model_input_tail_window.Pinned -> ())
          labelled;
        (* The atoms whose opening message is kept byte-exact, because a record
           names each by that message's digest: the last atom, which every
           position at the history's end names, and the atom each completed
           turn ended on, which its boundary line names. Everything else may be
           rewritten; none of it is removed. *)
        let kept_atoms =
          (if atom_count > 0 then [ atom_count - 1 ] else [])
          @ List.filter
              (fun atom -> atom < atom_count)
              (atoms_named_by_boundaries ~trace_id boundary_lines)
          |> List.sort_uniq Int.compare
        in
        let kept_message = Array.make (List.length retained) false in
        List.iter
          (fun atom ->
             Option.iter (fun index -> kept_message.(index) <- true) opener_of_atom.(atom))
          kept_atoms;
        (* A continuity snapshot that fits this history holds a digest of the
           bytes of the atoms it covers, and once caught up it is the request's
           front: the turn sends its working state in place of those atoms.
           Rewritten, the snapshot would stop fitting ([Prefix_changed]) and the
           Librarian would write a working state again, from atom 0 and one
           completed turn per round, and each request until it caught up would
           carry no working state; a snapshot still catching up would start
           over. So everything ahead of its end stays byte-exact. A snapshot
           that does not fit is written again from atom 0 whatever the purge
           does, so it holds nothing back. *)
        let fitting_continuity =
          match continuity with
          | None -> Ok None
          | Some snapshot ->
            (match
               Librarian_continuity_snapshot.restore
                 ~trace_id
                 ~lines:boundary_lines
                 ~messages
                 snapshot
             with
             | Ok _ -> Ok (Some snapshot)
             | Error error ->
               if snapshot.unread_messages = [] then Ok None
               else Error (Continuity_no_longer_fits error))
        in
        match fitting_continuity with
        | Error error -> Error error
        | Ok fitting_continuity ->
        Option.iter
          (fun (snapshot : Librarian_continuity_snapshot.t) ->
             let covered_until =
               match
                 if snapshot.end_atom < atom_count
                 then opener_of_atom.(snapshot.end_atom)
                 else None
               with
               | Some opener -> opener
               | None -> List.length retained
             in
             for index = 0 to covered_until - 1 do
               kept_message.(index) <- true
             done)
          fitting_continuity;
        (* A message the turn log has not named is read from this head by the
           next unit, so it goes out as it is. A purge that shrinks the head
           gets the [Reset] line that names all the head holds, before the
           change ([turn_log_line], [Keeper_turn_log_reset.run]). The rule is
           lifted on that same answer, so a purge with no such line never
           rewrites what no line has named. *)
        (match named with
         | Keeper_turn_log_writer.Named_below below
           when not (shrinks_the_head ~dropped_at_break) ->
           for index = below to List.length retained - 1 do
             kept_message.(index) <- true
           done
         | Keeper_turn_log_writer.Named_below _ | Keeper_turn_log_writer.No_log -> ());
        let items =
          let flat_index = ref (-1) in
          List.map
            (fun unit_ ->
               let unit_messages = Keeper_transcript_unit.messages_of_closed_unit unit_ in
               flat_index := !flat_index + List.length unit_messages;
               { unit_; flat_last = !flat_index })
            closed_prefix
        in
        (* The last atom goes out whole along with the count-based tail. A turn
           that ends in more tool messages than [keep_recent_messages] puts its
           opening assistant message outside the count-based tail; this reaches
           it. The tail is counted on [retained], the history this returns and
           the one [flat_last] indexes: a recovery's dropped tail is not in it. *)
        let protected_from =
          let count_based = List.length retained - config.keep_recent_messages in
          match if atom_count > 0 then opener_of_atom.(atom_count - 1) else None with
          | Some opener -> min count_based opener
          | None -> count_based
        in
        let protected item = item.flat_last >= protected_from in
        let reasoning_blocks_stripped = ref 0 in
        let tool_results_cleared = ref 0 in
        let rewrite ~in_cycle index message =
          if kept_message.(index)
          then message
          else (
            let message =
              if in_cycle && config.clear_tool_results
              then (
                let cleared_message, cleared = clear_tool_result_blocks message in
                tool_results_cleared := !tool_results_cleared + cleared;
                cleared_message)
              else message
            in
            if config.strip_thinking && is_assistant message
            then (
              let kept, stripped = strip_reasoning_keeping_the_message message in
              reasoning_blocks_stripped := !reasoning_blocks_stripped + stripped;
              kept)
            else message)
        in
        let purge_item item =
          let unit_messages = Keeper_transcript_unit.messages_of_closed_unit item.unit_ in
          if protected item
          then unit_messages
          else (
            (* The reasoning strip reaches into a tool cycle too: the assistant
               message that opens one is grouped here, never in
               [Ordinary_message], so without it unsigned reasoning on tool turns
               would survive a full purge. *)
            let in_cycle =
              match item.unit_ with
              | Keeper_transcript_unit.Ordinary_message _ -> false
              | Keeper_transcript_unit.Closed_tool_cycle _ -> true
            in
            let first = item.flat_last - List.length unit_messages + 1 in
            List.mapi
              (fun offset message -> rewrite ~in_cycle (first + offset) message)
              unit_messages)
        in
        let purged = List.concat_map purge_item items @ protected_suffix in
        (* The rules above keep every atom, every kept opener and a fitting
           snapshot's bytes; this states it rather than trusting them to go on
           doing so. *)
        let kept_atoms_intact () =
          let _labelled, purged_atom_count =
            Runtime_model_input_tail_window.annotate purged
          in
          if purged_atom_count <> atom_count
          then Error (Atom_count_changed { before = atom_count; after = purged_atom_count })
          else (
            let before = Runtime_model_input_tail_window.atom_opening_digest retained in
            let after = Runtime_model_input_tail_window.atom_opening_digest purged in
            match
              List.find_opt
                (fun atom -> not (Option.equal String.equal (before atom) (after atom)))
                kept_atoms
            with
            | Some atom -> Error (Kept_atom_rewritten { atom })
            | None ->
              (match fitting_continuity with
               | None -> Ok ()
               | Some snapshot ->
                 (match
                    Librarian_continuity_snapshot.restore
                      ~trace_id
                      ~lines:boundary_lines
                      ~messages:purged
                      snapshot
                  with
                  | Ok _ -> Ok ()
                  | Error error -> Error (Continuity_no_longer_fits error))))
        in
        (match Keeper_transcript_unit.validate purged with
         | Error structural -> Error (Invalid_output_structure structural)
         | Ok () ->
           (match kept_atoms_intact () with
            | Error _ as error -> error
            | Ok () ->
              Ok
                ( purged
                , { messages_before
                  ; messages_after = List.length purged
                  ; reasoning_blocks_stripped = !reasoning_blocks_stripped
                  ; tool_results_cleared = !tool_results_cleared
                  ; messages_dropped_at_structural_break = dropped_at_break
                  } ))))
;;

let purge
      ~config
      ~trace_id
      ~boundary_lines
      ~continuity
      ~named
      (ckpt : Agent_core.Checkpoint.t)
  =
  match
    purge_messages ~config ~trace_id ~boundary_lines ~continuity ~named ckpt.messages
  with
  | Error error -> Error error
  | Ok (messages, report) ->
    if report.messages_dropped_at_structural_break = 0 then
      Ok ({ ckpt with Agent_core.Checkpoint.messages }, report)
    else
      Result.map_error
        (fun error -> Repetition_boundary_invalid (Keeper_repetition_judged.error_to_string error))
        (Keeper_repetition_judged.reset_history ckpt.context)
      |> Result.map (fun context ->
           { ckpt with Agent_core.Checkpoint.messages; context }, report)
;;

(* The other half of [shrinks_the_head]: the line [Keeper_turn_log_reset.run]
   writes before the purged head goes in. Every message the purge kept is
   closed in the head it installs, so the mark after the change ends at
   [messages_after]. *)
let turn_log_line (report : report) : Keeper_turn_log_reset.line =
  if shrinks_the_head ~dropped_at_break:report.messages_dropped_at_structural_break
  then
    Keeper_turn_log_reset.Announce
      { cause = Keeper_turn_log.Recovered
      ; after =
          (fun (mark : Keeper_turn_log.mark) ->
             { mark with Keeper_turn_log.closed_messages = report.messages_after })
      }
  else Keeper_turn_log_reset.No_line
;;
