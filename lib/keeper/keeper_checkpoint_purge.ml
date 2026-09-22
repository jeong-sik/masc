(* Deterministic offline checkpoint purge (RFC-0351 S1). See the .mli for the
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

type rebase =
  | No_progress
  | Rebased of
      { before : Keeper_librarian_progress.t
      ; after : Keeper_librarian_progress.t
      }

type refusal =
  | Unread_atoms_present of
      { end_atom : int
      ; atom_count : int
      }
  | Position_beyond_history of
      { end_atom : int
      ; atom_count : int
      }
  | Position_in_other_trace of string
  | Position_in_other_history of
      { held : string
      ; history : string
      }
  | Rewrite_leaves_no_atoms
  | Position_unreadable of string
  | Position_invariant_violation of string

let refusal_to_string = function
  | Unread_atoms_present { end_atom; atom_count } ->
    Printf.sprintf
      "the Librarian has read %d of %d atoms; the rewrite would clear tool output \
       and reasoning in atoms it has not read yet"
      end_atom
      atom_count
  | Position_beyond_history { end_atom; atom_count } ->
    Printf.sprintf
      "the Librarian position (%d) lies past the history's %d atoms; it is not a \
       place in this checkpoint, and the keeper's Librarian files need a purge"
      end_atom
      atom_count
  | Position_in_other_trace trace_id ->
    Printf.sprintf "the Librarian position belongs to trace %s" trace_id
  | Position_in_other_history { held; history } ->
    Printf.sprintf
      "the Librarian position belongs to another history (position digest %s, history \
       digest %s)"
      held
      history
  | Rewrite_leaves_no_atoms -> "the rewritten history has no atom to hold a position in"
  | Position_unreadable detail -> "checkpoint position unavailable: " ^ detail
  | Position_invariant_violation detail ->
    "checkpoint position invariant violated: " ^ detail
;;

let librarian_rebase ~(progress : Keeper_librarian_progress.t option) ~trace_id ~before ~after =
  match progress with
  | None -> Ok No_progress
  | Some progress ->
    if not (String.equal progress.position.trace_id trace_id)
    then Error (Position_in_other_trace progress.position.trace_id)
    else (
      match Keeper_turn_boundaries.position_of_messages before with
      | Error detail -> Error (Position_unreadable detail)
      | Ok
          (Keeper_turn_boundaries.Atom_history
            { end_atom = atom_count; last_atom_digest = history_digest }) ->
        let end_atom = progress.position.end_atom in
        if end_atom < atom_count
        then Error (Unread_atoms_present { end_atom; atom_count })
        else if end_atom > atom_count
        then Error (Position_beyond_history { end_atom; atom_count })
        else if not (String.equal progress.position.last_atom_digest history_digest)
        then
          Error
            (Position_in_other_history
               { held = progress.position.last_atom_digest; history = history_digest })
        else (
          match Keeper_turn_boundaries.position_of_messages after with
          | Error detail -> Error (Position_unreadable detail)
          | Ok (Keeper_turn_boundaries.Atom_history { end_atom; last_atom_digest }) ->
            Ok
              (Rebased
                 { before = progress
                 ; after =
                     { progress with
                       position = { progress.position with end_atom; last_atom_digest }
                     }
                 })
          | Ok Keeper_turn_boundaries.Empty_atom_history -> Error Rewrite_leaves_no_atoms
          | Ok Keeper_turn_boundaries.No_atom_history ->
            Error
              (Position_invariant_violation
                 "position_of_messages(after) answered no_atom_history")
          | Ok Keeper_turn_boundaries.Stale_noop ->
            Error
              (Position_invariant_violation
                 "position_of_messages(after) answered stale_noop"))
      | Ok Keeper_turn_boundaries.Empty_atom_history ->
        Error (Unread_atoms_present { end_atom = progress.position.end_atom; atom_count = 0 })
      | Ok Keeper_turn_boundaries.No_atom_history ->
        Error
          (Position_invariant_violation
             "position_of_messages(before) answered no_atom_history")
      | Ok Keeper_turn_boundaries.Stale_noop ->
        Error
          (Position_invariant_violation
             "position_of_messages(before) answered stale_noop"))
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
         | _ -> block :: kept, stripped)
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
             ({ content; json; content_blocks; _ } as result) ->
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
         | _ -> block)
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
    (fun ((_line, record) : boundary_line) ->
       match record with
       | Ok
           { Keeper_turn_boundaries.recorded_at = _
           ; event =
               Keeper_turn_boundaries.Turn_ended
                 { turn_ref
                 ; history_at_start = _
                 ; position =
                     Keeper_turn_boundaries.Atom_history
                       { end_atom; last_atom_digest = _ }
                 }
           } ->
         if String.equal (Ids.Turn_ref.trace_id turn_ref) trace_id && end_atom >= 1
         then Some (end_atom - 1)
         else None
       | Ok
           { Keeper_turn_boundaries.recorded_at = _
           ; event =
               ( Keeper_turn_boundaries.Turn_ended
                   { turn_ref = _
                   ; history_at_start = _
                   ; position =
                       ( Keeper_turn_boundaries.Empty_atom_history
                       | Keeper_turn_boundaries.No_atom_history
                       | Keeper_turn_boundaries.Stale_noop )
                   }
               | Keeper_turn_boundaries.History_restarted _ )
           }
       | Error _ -> None)
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

let purge_messages ~config ~trace_id ~boundary_lines ~continuity messages =
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
      (* On a sound input the suffix is the open tail crash recovery needs, and
         it is kept. On a broken one it starts at the break. *)
      let dropped_at_break =
        if recovering then List.length protected_suffix else 0
      in
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
        | None -> None
        | Some snapshot ->
          (match
             Librarian_continuity_snapshot.restore
               ~trace_id
               ~lines:boundary_lines
               ~messages
               snapshot
           with
           | Ok _ -> Some snapshot
           | Error _ -> None)
      in
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
         it. *)
      let protected_from =
        let count_based = messages_before - config.keep_recent_messages in
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

let purge ~config ~trace_id ~boundary_lines ~continuity (ckpt : Agent_core.Checkpoint.t) =
  match purge_messages ~config ~trace_id ~boundary_lines ~continuity ckpt.messages with
  | Error error -> Error error
  | Ok (messages, report) ->
    Ok ({ ckpt with Agent_core.Checkpoint.messages }, report)
;;
