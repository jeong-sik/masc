module Live = Masc_tui_keeper_chat_live
module Projection = Masc_tui_keeper_chat_projection

(* Everything this hands out came off the wire, so it is scrubbed of terminal
   control bytes on the way out rather than on the way in. Scrubbing each
   fragment as it arrives would not be sound: an escape can be split across two
   deltas, and neither half looks like one. The accumulated string is where the
   sequence is whole and can be caught. *)
let safe_line text = Projection.terminal_safe_text text
let safe_block text = Projection.terminal_safe_text ~preserve_newlines:true text

type phase =
  | Waiting
  | Working
  | Stream_ended
  | Stream_failed of string

type interrupt =
  | Not_requested
  | Signal_sent of { turn_id : int option; signalled_at_ns : int64 }
  | Signal_declined of string
  | Signal_error of string

type tool_outcome =
  | Started
  | Awaiting_result
  | Returned
  | Failed
  | Never_returned
  | Outcome_unrecorded

type tool_activity =
  { call_id : string option
  ; execution_id : string option
  ; tool_name : string
  ; args : string
  ; subject : string option
  ; outcome : tool_outcome
  ; duration : string option
  }

type skill_state =
  | Skill_calling
  | Skill_served_pending
  | Skill_served_only
  | Skill_delivered
  | Skill_used
  | Skill_failed
  | Skill_evidence_missing
  | Skill_evidence_unavailable

type skill_activity =
  { skill_name : string
  ; skill_tool_use_id : string option
  ; turn_ref : string option
  ; content_revision : string option
  ; runtime_id : string option
  ; state : skill_state
  ; actions : string list
  ; detail : string option
  }

type tool_block =
  { activities : tool_activity list
  ; omitted_steps : int
  }

type tool_projection_mode =
  | Compact
  | Full

type tool_projection =
  { activities : tool_activity list
  ; header : string option
  ; details : string list
  ; hidden_activity_rows : int
  ; omitted_steps : int
  ; summary_outcome : tool_outcome option
  }

(* Mutable stream state stays private. The typed activity handed to history
   and rendering below is immutable, so neither consumer has to infer an
   outcome from these two booleans. *)
type live_tool_call =
  { local_id : int
  ; started_at : float
      (** When TOOL_CALL_START arrived. A turn age says how long the turn has
          run; only this says whether the thing it is in right now has been
          running that whole time. *)
  ; occurrence : Live.tool_occurrence
  ; call_id : string option
  ; execution_id : string option
  ; tool_name : string
  ; args : string
  ; ended : bool
  ; result_ready : bool
  ; failed : bool
  ; duration : string option
        (** Not on the wire: the durable transcript's [dur], folded in by
            {!note_tool_outcome} once the loaded rows carry it. *)
  }

(* [call_id] and [tool_name] are also fields of [tool_activity] above. OCaml
   resolves an unannotated field access to the last record type that declares
   the name, which is this one, so a lambda over [tool_activity list] that
   reads either field has to say the type it is over. #30231 landed two such
   lambdas without annotations and main did not compile. *)
type awaiting_approval =
  { call_id : string
  ; tool_name : string
  ; question : string
  ; (* Why the call was held. attached under the question so the reader who
       answers [y]/[n] from this pane sees the reason the approval list
       screen shows. *)
    because : string
  }

type approval_outcome =
  | Approved
  | Denied
  | Timed_out
  | Displaced
  | Approval_other of string

type approval_settlement =
  { settled_tool_name : string
  ; settled_outcome : approval_outcome
  }

type unreadable =
  { count : int
  ; last_detail : string
  }

(* One stretch of the turn as it arrived. The three accumulators above answer
   "what did the turn say / think / call" as totals; the trail answers "in what
   order". A tool-call round interleaves them -- reasoning, then a call, then
   more reasoning -- and flattening that into three blocks is what made a long
   turn read as one wall of text with its calls listed elsewhere. Text and
   thinking nodes own their bytes; a tool node only names the call, whose
   record lives in [reversed_tool_calls] and keeps updating after later nodes
   have opened (arguments stream in, the result lands). *)
type trail_node =
  | Node_thinking of Buffer.t
  | Node_text of Buffer.t
  | Node_tool of int
  | Node_superseded of
      { attempt : int
      ; nodes : trail_node list  (** In arrival order. *)
      }
      (** Everything one earlier runtime attempt produced, kept whole when
          the next attempt began (RFC-0412 §3.3): the reader was reading it,
          so it stays, marked. One block per superseded attempt, siblings in
          the trail, never nested. *)

(* The recorded reply (KEEPER_REPLY_DETAILS): the visible text, how the turn
   ended, and the turn it was recorded under. *)
type reply =
  { reply_text : string
  ; reply_outcome : Masc.Keeper_turn_outcome.t
  ; reply_turn_ref : string
  }

(* Tool calls are held newest-first so opening one is a prepend; [tool_calls]
   reverses on read. Appending an argument fragment walks the list, which a
   turn's handful of calls makes cheap enough -- the list is short and the
   fragments are what arrive often. *)
type t =
  { keeper_name : string
  ; request_id : string
  ; started_at : float
        (* When the request left, not when the run started. The wait before
           RUN_STARTED is the part that hid a 63-minute hang (masc #29229), so
           the age has to cover it. *)
  ; text_buffer : Buffer.t
  ; thinking_buffer : Buffer.t
  ; mutable reversed_tool_calls : live_tool_call list
  ; mutable reversed_trail : trail_node list
  ; mutable next_tool_local_id : int
  ; mutable phase : phase
  ; mutable interrupt : interrupt
  ; mutable checkpoints : int
  ; mutable unreadable_count : int
  ; mutable last_unreadable : string
  ; mutable awaiting : awaiting_approval option
  ; mutable last_approval_settlement : approval_settlement option
  ; (* What the server said when it took the request, and how long its chat
       queue was at that moment. [None] until the acceptance arrives, which is
       the window this exists for: a wait of minutes used to read as "waiting
       for the run to start" whether the keeper was busy with something else
       or the run was stuck. *)
    mutable admission : (Live.admission * int) option
  ; mutable attempt : int
        (* 0-based runtime attempt the growing trail belongs to. *)
  ; mutable reply : reply option
        (* Not a trail node: the server streams the reply text as deltas --
           chunked at the end when nothing streamed -- so the text is already
           in the trail. [drawn] reconciles the two. *)
  ; mutable revision : int
        (* Bumped by every mutation: the memo key for anything drawn from
           this transcript. *)
  }

let create ~keeper_name ~request_id ~started_at =
  { keeper_name
  ; request_id
  ; started_at
  ; text_buffer = Buffer.create 1024
  ; thinking_buffer = Buffer.create 256
  ; reversed_tool_calls = []
  ; reversed_trail = []
  ; next_tool_local_id = 0
  ; phase = Waiting
  ; interrupt = Not_requested
  ; checkpoints = 0
  ; unreadable_count = 0
  ; last_unreadable = ""
  ; awaiting = None
  ; last_approval_settlement = None
  ; admission = None
  ; attempt = 0
  ; reply = None
  ; revision = 0
  }

let revision t = t.revision
let bump t = t.revision <- t.revision + 1

(* Consecutive deltas of one kind are one stretch; a delta of another kind in
   between closes it. Coalescing here rather than at draw time keeps the trail
   bounded by the turn's shape (rounds), not by its chunking on the wire. *)
let trail_thinking t text =
  (match t.reversed_trail with
   | Node_thinking buffer :: _ -> Buffer.add_string buffer text
   | (Node_text _ | Node_tool _ | Node_superseded _) :: _ | [] ->
       let buffer = Buffer.create 256 in
       Buffer.add_string buffer text;
       t.reversed_trail <- Node_thinking buffer :: t.reversed_trail)

let trail_text t text =
  (match t.reversed_trail with
   | Node_text buffer :: _ -> Buffer.add_string buffer text
   | (Node_thinking _ | Node_tool _ | Node_superseded _) :: _ | [] ->
       let buffer = Buffer.create 256 in
       Buffer.add_string buffer text;
       t.reversed_trail <- Node_text buffer :: t.reversed_trail)

let keeper_name t = t.keeper_name
let request_id t = t.request_id
let started_at t = t.started_at
let attempt t = t.attempt
let reply t = t.reply
let phase t = t.phase
let interrupt t = t.interrupt
let note_interrupt t interrupt =
  t.interrupt <- interrupt;
  bump t
let text t = safe_block (Buffer.contents t.text_buffer)
let thinking t = safe_block (Buffer.contents t.thinking_buffer)

let awaiting_approval t = t.awaiting

let unreadable t =
  if t.unreadable_count = 0 then None
  else Some { count = t.unreadable_count; last_detail = t.last_unreadable }

(* How far the call got. Argument fragments arrive before the call is closed,
   and the result lands after that, so the three states are distinguishable
   and worth distinguishing: a row stuck at the middle marker is a tool that
   is running, which is exactly what an operator is waiting to know. *)
let subject_of ~tool_name ~args =
  if String.equal (String.trim args) "" then None
  else Masc.Keeper_chat_tool_trail.tool_subject ~name:tool_name ~args

let nonblank = function
  | Some value when String.trim value <> "" -> Some value
  | Some _ | None -> None

let make_tool_activity ?execution_id ~call_id ~tool_name ~args ~outcome
    ~duration () =
  let call_id = nonblank call_id in
  let execution_id = nonblank execution_id in
  { call_id
  ; execution_id
  ; tool_name
  ; args
  ; subject = subject_of ~tool_name ~args
  ; outcome
  ; duration
  }

let activity_of_live_call (call : live_tool_call) =
  make_tool_activity ?execution_id:call.execution_id
    ~call_id:call.call_id ~tool_name:call.tool_name
    ~args:call.args
    ~outcome:
      (if call.failed then Failed
       else if call.result_ready then Returned
       else if call.ended then Awaiting_result
       else Started)
    ~duration:call.duration ()

let tool_calls t =
  List.rev t.reversed_tool_calls |> List.map activity_of_live_call

let tool_block ?(omitted_steps = 0) activities : tool_block =
  { activities; omitted_steps }

(* Which reasoning lines the pane shows, kept here rather than in the drawing
   because it is a question about the content. The whole trail, minus the runs
   of blank lines models emit: reasoning is the only part of a live turn the
   durable transcript does not keep, so one line out of it would say what the
   keeper concluded without saying how it got there. *)
let thinking_lines t =
  Buffer.contents t.thinking_buffer
  |> String.split_on_char '\n'
  |> List.filter (fun line -> String.trim line <> "")

let finished_marker = "✓"

let marker_of_outcome = function
  | Started -> "◌"
  | Awaiting_result -> "▶"
  | Returned -> finished_marker
  | Failed -> "\xe2\x9c\x97"
  | Never_returned -> "!"
  | Outcome_unrecorded -> "?"

let pad_to width text =
  let length = String.length text in
  if length >= width then text else text ^ String.make (width - length) ' '

(* The longest registered tool name is 48 bytes
   (masc_operator_board_attention_quarantine_requeue), so a 64-byte cap
   carries every real name intact. A name past it is not spelling: on
   2026-08-29 glm-5-turbo degenerated and wrote loop counters into the name
   field ("Execute1" + the digits 1..1000, kilobytes long), and [name_width]
   then padded every row in the block to that length. Head and tail are both
   kept for the same reason [compact_request_id] keeps both: the prefix
   names the tool the model meant, the suffix carries the degenerate tail
   ("...e+0061"). *)
let tool_name_display_cap = 64

let display_tool_name name =
  let length = String.length name in
  if length <= tool_name_display_cap then name
  else String.sub name 0 48 ^ ".." ^ String.sub name (length - 14) 14

(* One formatter for rows drawn live and rows read back from the transcript.
   The names are padded to a common column so a block of calls lines up, which
   is only meaningful within one block -- hence the width is computed per
   call. A trailer, when a row has one, goes after the subject: it is the
   part only a persisted step knows (how long the call took), and a row
   without one draws exactly as before. *)
let render_activity_rows (activities : tool_activity list) =
  let name_width =
    (* [awaiting_approval] is declared after [tool_activity] and reuses
       [tool_name], so an unannotated [activity] here resolves to the later
       record and drags the whole list with it. The parameter annotation above
       does not reach inside the lambda. *)
    List.fold_left
      (fun widest (activity : tool_activity) ->
        max widest (String.length (display_tool_name activity.tool_name)))
      0 activities
  in
  let with_trailer text = function
    | None -> text
    | Some trailer -> Printf.sprintf "%s \xc2\xb7 %s" text trailer
  in
  List.map
    (fun (activity : tool_activity) ->
      let marker = marker_of_outcome activity.outcome in
      match activity.subject with
      | None ->
          safe_line
            (with_trailer
               (Printf.sprintf "%s %s" marker
                  (display_tool_name activity.tool_name))
               activity.duration)
      | Some subject ->
          safe_line
            (with_trailer
               (Printf.sprintf "%s %s %s" marker
                  (pad_to name_width (display_tool_name activity.tool_name))
                  subject)
               activity.duration))
    activities

let plural count noun =
  Printf.sprintf "%d %s%s" count noun (if count = 1 then "" else "s")

let omitted_steps_row count =
  Printf.sprintf "(%s not carried by the transcript)" (plural count "step")



(* The one outcome a folded block reads as. The order is the order of what a
   reader needs to know first: a call that failed outranks one still out,
   which outranks one whose end was never recorded. Both the summary glyph and
   the summary colour come from here, so the two cannot say different things
   about the same block. *)
let compact_outcome (activities : tool_activity list) =
  if List.exists (fun activity -> activity.outcome = Failed) activities then
    Failed
  else if
    List.exists (fun activity -> activity.outcome = Awaiting_result) activities
  then Awaiting_result
  else if
    List.exists
      (fun activity ->
        activity.outcome = Started || activity.outcome = Never_returned)
      activities
  then Started
  else if
    List.exists
      (fun activity -> activity.outcome = Outcome_unrecorded)
      activities
  then Outcome_unrecorded
  else Returned

let compact_marker activities = marker_of_outcome (compact_outcome activities)

(* The descriptor registry already owns the model-facing name. Reusing it
   here keeps the summary on the same vocabulary the Keeper saw (Read, Edit,
   Execute, ...), instead of deriving categories from spelling conventions.
   A trace from an older or external provider may name no registered tool; in
   that case the exact safe name is more useful than an invented "Other". *)
(* One reading of the registry for both questions a row asks of a name: what
   to call the call, and what family of work it is. A descriptor may carry
   several internal aliases and one public name, so the public lookup is
   tried first. *)
let descriptor_of_tool_name name : Masc.Keeper_tool_descriptor.t option =
  match Masc.Keeper_tool_descriptor.find_public name with
  | Some _ as found -> found
  | None -> (
      match Masc.Keeper_tool_descriptor.public_descriptors_for_internal name with
      | descriptor :: _ -> Some descriptor
      | [] -> None)

let canonical_tool_name (activity : tool_activity) =
  match descriptor_of_tool_name activity.tool_name with
  | Some descriptor -> descriptor.public_name
  | None -> safe_line (display_tool_name activity.tool_name)

(* The outcomes worth naming a tool for.

   A fold that says "28 returned, 1 failed" beside eight tool names leaves the
   reader to open the details to learn which one broke. The counts are the
   same information either way; the name is what turns the line into an
   answer. Only the outcomes someone acts on carry names -- a reader chasing
   a failure needs the tool, a reader seeing 28 successes does not. *)
let names_its_tools = function
  | Failed | Never_returned | Awaiting_result -> true
  | Started | Returned | Outcome_unrecorded -> false
;;

(* Distinct tool names for one outcome, each with its count when it repeats.
   Order follows first appearance, so the line reads in the order the calls
   were made. *)
let tools_for_outcome outcome activities =
  List.filter (fun activity -> activity.outcome = outcome) activities
  |> List.fold_left
       (fun counts activity ->
         let name = canonical_tool_name activity in
         let rec increment reversed = function
           | [] -> List.rev ((name, 1) :: reversed)
           | (existing, count) :: rest when String.equal existing name ->
             List.rev_append reversed ((existing, count + 1) :: rest)
           | entry :: rest -> increment (entry :: reversed) rest
         in
         increment [] counts)
       []
  |> List.map (fun (name, count) ->
       if count = 1 then name else Printf.sprintf "%s %d" name count)
;;

let compact_outcome_parts (activities : tool_activity list) =
  let count outcome =
    List.fold_left
      (fun total activity ->
        if activity.outcome = outcome then total + 1 else total)
      0 activities
  in
  [ Started, "running"
  ; Awaiting_result, "awaiting result"
  ; Returned, "returned"
  ; Failed, "failed"
  ; Never_returned, "never returned"
  ; Outcome_unrecorded, "outcome unrecorded"
  ]
  |> List.filter_map (fun (outcome, label) ->
         match count outcome with
         | 0 -> None
         | count ->
           let counted = Printf.sprintf "%d %s" count label in
           if not (names_its_tools outcome)
           then Some counted
           else (
             match tools_for_outcome outcome activities with
             | [] -> Some counted
             | names -> Some (counted ^ ": " ^ String.concat ", " names)))
;;

let compact_tool_parts (activities : tool_activity list) =
  let add counts activity =
    let name = canonical_tool_name activity in
    let rec increment reversed = function
      | [] -> List.rev ((name, 1) :: reversed)
      | (existing, count) :: rest when String.equal existing name ->
          List.rev_append reversed ((existing, count + 1) :: rest)
      | entry :: rest -> increment (entry :: reversed) rest
    in
    increment [] counts
  in
  List.fold_left add [] activities
  |> List.map (fun (name, count) -> Printf.sprintf "%s %d" name count)

let compact_tool_mix activities =
  String.concat " · " (compact_tool_parts activities)

type activity_kind =
  | Skill_activity
  | Delegate_activity
  | Keeper_activity
  | Fusion_activity
  | Tool_activity

(* Which family a registered tool belongs to, read from the descriptor that
   owns it. The spelling tests this replaces counted [keeper_code_query] and
   [keeper_webmcp_call] as Keeper work because their names begin with the
   process that hosts them; one is a code search and the other an MCP call,
   and they now count as the tools they are.

   Written out rather than left to a catch-all so a new handler stops the
   build here and is placed on purpose. *)
let handler_activity_kind handler =
  let open Masc.Keeper_tool_descriptor in
  match handler with
  | Tool_masc_fusion_dispatch | Tool_masc_fusion_status -> Fusion_activity
  | Tool_keeper_spawn_dispatch | Tool_masc_keeper_dispatch -> Keeper_activity
  | Tool_execute
  | Tool_search_files
  | Tool_read_file
  | Tool_edit_file
  | Tool_write_file
  | Tool_time_now
  | Tool_lane_status
  | Tool_tools_list
  | Tool_capability_search
  | Tool_context_status
  | Tool_artifact_read
  | Tool_memory_search
  | Tool_memory_retract
  | Tool_memory_write
  | Tool_library_search
  | Tool_library_read
  | Tool_surface_read
  | Tool_surface_post
  | Tool_person_note_set
  | Tool_ide_annotate
  | Tool_voice_dispatch
  | Tool_task_dispatch
  | Tool_board_dispatch
  | Tool_masc_task_dispatch
  | Tool_masc_plan_dispatch
  | Tool_masc_run_dispatch
  | Tool_masc_agent_dispatch
  | Tool_masc_workspace_dispatch
  | Tool_masc_misc_dispatch
  | Tool_web_search
  | Tool_web_fetch
  | Tool_masc_control_dispatch
  | Tool_masc_agent_timeline_dispatch
  | Tool_masc_schedule_dispatch
  | Tool_keeper_code_query_dispatch
  | Tool_keeper_webmcp_dispatch
  | Tool_masc_file_dispatch
  | Tool_masc_library_dispatch
  | Tool_masc_local_runtime_dispatch
  | Tool_analyze_image -> Tool_activity

(* Delegation stands apart from the rest of the keeper family because it is
   the one call that moves work to another Keeper. [masc_keeper_status] and
   [masc_keeper_list] read state, and a fold that counts them together with a
   handoff says a turn delegated when it only looked. *)
let keeper_tool_activity_kind = function
  | Keeper_tool_name.Keeper_delegate | Keeper_tool_name.Keeper_delegate_cancel
    -> Delegate_activity
  | Keeper_tool_name.Keeper_audit
  | Keeper_tool_name.Keeper_clear
  | Keeper_tool_name.Keeper_delegate_list
  | Keeper_tool_name.Keeper_delegate_status
  | Keeper_tool_name.Keeper_down
  | Keeper_tool_name.Keeper_list
  | Keeper_tool_name.Keeper_msg
  | Keeper_tool_name.Keeper_reset
  | Keeper_tool_name.Keeper_sandbox_start
  | Keeper_tool_name.Keeper_sandbox_stop
  | Keeper_tool_name.Keeper_status
  | Keeper_tool_name.Keeper_up -> Keeper_activity

let activity_kind (activity : tool_activity) =
  let name = activity.tool_name in
  if
    String.equal name Masc.Keeper_tool_composition_catalog.skill_tool_name
    || Option.is_some
         (Masc.Keeper_tool_composition_catalog.skill_source_of_tool_name name)
  then Skill_activity
  else
    match Keeper_tool_name.of_string name with
    | Some keeper_tool -> keeper_tool_activity_kind keeper_tool
    | None -> (
        match descriptor_of_tool_name name with
        | None -> Tool_activity
        | Some descriptor -> handler_activity_kind descriptor.runtime_handler)

let make_skill_activity ?skill_tool_use_id ?turn_ref ?content_revision
    ?runtime_id ?detail ~skill_name ~state ~actions () =
  { skill_name = safe_line skill_name
  ; skill_tool_use_id = Option.map safe_line (nonblank skill_tool_use_id)
  ; turn_ref = Option.map safe_line (nonblank turn_ref)
  ; content_revision = Option.map safe_line (nonblank content_revision)
  ; runtime_id = Option.map safe_line (nonblank runtime_id)
  ; state
  ; actions = List.map safe_line actions
  ; detail = Option.map safe_line (nonblank detail)
  }

let skill_activity_of_tool (activity : tool_activity) =
  match activity_kind activity with
  | Tool_activity | Delegate_activity | Keeper_activity | Fusion_activity ->
      None
  | Skill_activity ->
      let state =
        match activity.outcome with
        | Started | Awaiting_result | Never_returned -> Skill_calling
        | Returned -> Skill_served_pending
        | Failed -> Skill_failed
        | Outcome_unrecorded -> Skill_evidence_missing
      in
      let skill_name =
        Option.value activity.subject
          ~default:(display_tool_name activity.tool_name)
      in
      Some
        (make_skill_activity ?skill_tool_use_id:activity.call_id
           ~skill_name ~state ~actions:[] ())

let skill_state_label = function
  | Skill_calling -> "CALLING"
  | Skill_served_pending -> "SERVED \xc2\xb7 DELIVERY PENDING"
  | Skill_served_only -> "SERVED ONLY \xc2\xb7 DELIVERY NOT RECORDED"
  | Skill_delivered -> "DELIVERED \xc2\xb7 NO ACTION OBSERVED"
  | Skill_used -> "DELIVERED \xc2\xb7 USED"
  | Skill_failed -> "FAILED"
  | Skill_evidence_missing -> "EVIDENCE MISSING"
  | Skill_evidence_unavailable -> "EVIDENCE UNAVAILABLE"

let short_proof value =
  let value = safe_line value in
  if String.length value <= 18 then value
  else
    String.sub value 0 8 ^ "\xe2\x80\xa6"
    ^ String.sub value (String.length value - 8) 8

let skill_rows ~full (activity : skill_activity) =
  let action_count = List.length activity.actions in
  let summary =
    Printf.sprintf "**%s** \xc2\xb7 **%s**%s"
      activity.skill_name
      (skill_state_label activity.state)
      (if action_count = 0 then ""
       else Printf.sprintf " \xc2\xb7 %s" (plural action_count "action"))
  in
  if not full then [ summary ]
  else
    let actions =
      List.map
        (fun action ->
          Printf.sprintf "  \xe2\x86\xb3 **%s** \xc2\xb7 observed action" action)
        activity.actions
    in
    let proof_parts =
      List.filter_map Fun.id
        [ Option.map (fun turn -> "turn=" ^ turn) activity.turn_ref
        ; Option.map (fun id -> "use=" ^ short_proof id)
            activity.skill_tool_use_id
        ; Option.map (fun runtime -> "runtime=" ^ runtime) activity.runtime_id
        ; Option.map (fun revision -> "rev=" ^ short_proof revision)
            activity.content_revision
        ]
    in
    let proof =
      match proof_parts with
      | [] -> []
      | parts -> [ "  proof \xc2\xb7 " ^ String.concat " \xc2\xb7 " parts ]
    in
    let detail =
      match activity.detail with
      | None -> []
      | Some detail -> [ "  " ^ detail ]
    in
    summary :: actions @ proof @ detail

(* Generic tools are already named by [compact_tool_mix]. These tags retain
   the operational kind a compact fold used to erase. A handoff reads as
   [Delegate] rather than [Keeper] -- it replaces that clause instead of
   adding one, so the fold does not grow. *)
let compact_activity_kinds activities =
  let count kind =
    List.fold_left
      (fun total activity ->
        if activity_kind activity = kind then total + 1 else total)
      0 activities
  in
  [ Skill_activity, "Skill"
  ; Delegate_activity, "Delegate"
  ; Keeper_activity, "Keeper"
  ; Fusion_activity, "Fusion"
  ]
  |> List.filter_map (fun (kind, label) ->
       match count kind with
       | 0 -> None
       | count -> Some (Printf.sprintf "%s %d" label count))

(* Both projections retain the same typed activities. [Full] is the shipping
   view and therefore stays byte-compatible with the old formatter. [Compact]
   folds only the presentation rows; it reports exactly how many detail rows
   it hid and keeps failures/open calls visible in its outcome summary. *)
(* The block's rollup, on a line of its own. [folded] is how many detail rows
   sit behind it: zero when the details are drawn underneath, and the count
   when they are not. A rollup reading "0 details folded" would describe a
   fold that is not there.

   [outcomes] is passed rather than derived because the two modes count
   different calls: folded, the trouble gets a line of its own and the rollup
   speaks for what is left; unfolded, every call is visible and the rollup
   speaks for all of them.

   Assembled from parts instead of one format string so a part with nothing
   to say drops out, rather than leaving an empty clause between two
   separators. *)
let inventory_row ~folded ~outcomes activities =
  let parts =
    (Printf.sprintf "Tools %d" (List.length activities)
     :: compact_activity_kinds activities)
    @ compact_tool_parts activities
    @ outcomes
    @ (if folded = 0 then [] else [ plural folded "detail" ^ " folded" ])
  in
  safe_line
    (Printf.sprintf "%s %s"
       (compact_marker activities)
       (String.concat " \xc2\xb7 "
          (List.filter (fun part -> String.trim part <> "") parts)))

(* A block is a header and the calls under it. Which of the two a mode drops
   is the whole of the difference: [Compact] keeps the header and folds the
   calls away, [Full] keeps both. Neither draws a header over a single call --
   a summary of one call is that call, said twice. *)
let project_tool_block mode (block : tool_block) =
  let full_activity_rows = render_activity_rows block.activities in
  let header, activity_rows, hidden_activity_rows, summary_outcome =
    match mode, block.activities with
    | (Full | Compact), ([] | [ _ ]) -> None, full_activity_rows, 0, None
    | Full, activities ->
        ( Some
            (inventory_row ~folded:0
               ~outcomes:(compact_outcome_parts activities)
               activities)
        , full_activity_rows
        , 0
        (* Nothing is behind a fold, so the block has no folded state for its
           colour to stand for. The header carries its own mark in the text. *)
        , None )
    | Compact, activities ->
        let hidden_activity_rows = List.length full_activity_rows in
        (* What ran and what came of it are two questions, and one line
           answered both: a run of names and counts, then a run of outcomes
           and counts, five clauses deep with nowhere for the eye to land.
           Calls that returned belong with the inventory -- they are what ran,
           finished. Everything still open or failed gets a line of its own
           under its own mark, so a block's trouble is a line rather than a
           clause in the middle of one. *)
        let inventory_activities, trouble_activities =
          List.partition
            (fun activity ->
               match activity.outcome with
               | Returned -> true
               (* Not trouble. The history loader writes this for a call with
                  no execution_id and for a step whose status field is absent
                  or unknown -- a gap in the bookkeeping, not a call that
                  failed or is still out. A scrollback block of five calls
                  with one missing id would otherwise get a line of its own
                  saying so, on a block where nothing went wrong. *)
               | Outcome_unrecorded -> true
               | Started | Awaiting_result | Failed | Never_returned -> false)
            activities
        in
        (* Splitting costs a row, so it is worth it only while the fold still
           saves one: at two calls a split block draws the two rows Full
           draws, and Full's rows carry each call's subject and duration. *)
        let trouble_activities =
          if List.length activities > 2 then trouble_activities else []
        in
        let inventory_activities =
          match trouble_activities with
          | [] -> activities
          | _ :: _ -> inventory_activities
        in
        (* The mark is the block's own: compact_outcome tests exactly the four
           outcomes this list holds, so the two calls cannot disagree while
           the row exists. It is here to give the clause a line to start on,
           not to say something the block glyph did not. *)
        let trouble_rows =
          match trouble_activities with
          | [] -> []
          | trouble ->
            [ safe_line
                (Printf.sprintf "%s %s" (compact_marker trouble)
                   (String.concat ", " (compact_outcome_parts trouble)))
            ]
        in
        ( Some
            (inventory_row ~folded:hidden_activity_rows
               ~outcomes:(compact_outcome_parts inventory_activities)
               activities)
        , trouble_rows
        , hidden_activity_rows
        , Some (compact_outcome activities) )
  in
  let details =
    if block.omitted_steps = 0 then activity_rows
    else activity_rows @ [ omitted_steps_row block.omitted_steps ]
  in
  { activities = block.activities
  ; header
  ; details
  ; hidden_activity_rows
  ; omitted_steps = block.omitted_steps
  ; summary_outcome
  }

let tool_rows t =
  let projection = project_tool_block Full (tool_block (tool_calls t)) in
  (* The calls, not the rollup over them: a caller asking for rows wants one
     row per call, and the header is a fifth thing on a list of four. *)
  projection.details

type trail_item =
  | Trail_thinking of string list
  | Trail_skill of skill_activity
  | Trail_tools of tool_block
  | Trail_text of string
  | Trail_superseded of
      { attempt : int
      ; items : trail_item list
      }

(* The turn in arrival order, one item per stretch. Consecutive tool calls
   render as one block so their names align, same as [tool_rows]; a call whose
   arguments or result landed after later stretches opened still reads its
   current record, because the node names the call and the record keeps
   updating. Blank stretches are dropped here so the pane never budgets a row
   for an empty heading. *)
let trail t =
  let call_of local_id =
    List.find_opt
      (fun (call : live_tool_call) -> call.local_id = local_id)
      t.reversed_tool_calls
  in
  let flush_tools acc group =
    let flush_generic acc generic =
      match generic with
      | [] -> acc
      | activities ->
          Trail_tools (tool_block (List.rev activities)) :: acc
    in
    let rec split acc generic = function
      | [] -> flush_generic acc generic
      | activity :: rest -> (
          match skill_activity_of_tool activity with
          | None -> split acc (activity :: generic) rest
          | Some skill ->
              let acc = flush_generic acc generic in
              split (Trail_skill skill :: acc) [] rest)
    in
    group |> List.rev |> List.map activity_of_live_call |> split acc []
  in
  let rec walk acc group = function
    | [] -> List.rev (flush_tools acc group)
    | Node_tool local_id :: rest -> (
        match call_of local_id with
        | Some call -> walk acc (call :: group) rest
        | None -> walk acc group rest)
    | Node_superseded { attempt; nodes } :: rest ->
        let acc = flush_tools acc group in
        let acc =
          match walk [] [] nodes with
          | [] -> acc
          | items -> Trail_superseded { attempt; items } :: acc
        in
        walk acc [] rest
    | Node_thinking buffer :: rest ->
        let acc = flush_tools acc group in
        let lines =
          Buffer.contents buffer
          |> String.split_on_char '\n'
          |> List.filter (fun line -> String.trim line <> "")
          |> List.map safe_line
        in
        let acc =
          match lines with [] -> acc | lines -> Trail_thinking lines :: acc
        in
        walk acc [] rest
    | Node_text buffer :: rest ->
        let acc = flush_tools acc group in
        let text = safe_block (Buffer.contents buffer) in
        let acc =
          if String.trim text = "" then acc else Trail_text text :: acc
        in
        walk acc [] rest
  in
  walk [] [] (List.rev t.reversed_trail)

type status_kind =
  | Progress
  | Attention
  | Approval of approval_outcome

let approval_outcome_of_string = function
  | "approve" | "approved" -> Approved
  | "deny" | "denied" -> Denied
  | "timed_out" -> Timed_out
  | "displaced" -> Displaced
  | other -> Approval_other other

let approval_outcome_to_string = function
  | Approved -> "approved"
  | Denied -> "denied"
  | Timed_out -> "timed out"
  | Displaced -> "displaced"
  | Approval_other other -> safe_line other

(* The oldest call still open. Two calls in flight are rare and the older one
   is the one a watcher is waiting on. *)
let oldest_open_call t =
  t.reversed_tool_calls
  |> List.filter (fun (call : live_tool_call) -> not call.ended)
  |> List.fold_left
       (fun acc (call : live_tool_call) ->
         match acc with
         | Some (older : live_tool_call) when older.started_at <= call.started_at -> acc
         | Some _ | None -> Some call)
       None
;;

let phase_text ~now t =
  match t.phase with
  | Waiting -> (
      (* The wait before RUN_STARTED is the one an operator cannot read from
         the outside. Saying which of the two it is -- the keeper's queue, or a
         run that should already have begun -- is the difference between slow
         and stuck. The queue length is the server's count of the whole queue,
         so it is drawn as that and not as "how many are ahead of you". *)
      match t.admission with
      | None -> "waiting for the run to start"
      | Some (Live.Queued, queue_length) ->
          Printf.sprintf "queued \xc2\xb7 %s in the keeper's queue"
            (plural queue_length "message")
      | Some (Live.Running, _) -> "accepted; the run is starting"
      | Some (Live.Settled, _) ->
          (* The server had already run this operation and replayed its
             outcome. Nothing is waiting on a run that finished. *)
          "accepted; replaying an operation that already ran")
  | Working when Option.is_some t.awaiting ->
      (* The turn is not working, it is waiting on a person. Saying "working"
         here would read as a slow tool rather than a question on screen. *)
      "held at a tool call, waiting for your answer"
  | Working ->
      let activities = tool_calls t in
      let calls = List.length activities in
      (* The row exists to answer "is this slow or stuck", and the count alone
         cannot: seven tools reads the same whether all seven returned and the
         model is writing, or two are still out. The outcome is on every
         activity and this row was dropping it.

         Named rather than counted, and placed before the mix: the question is
         which call is still out, the names are few -- a round holds a handful
         -- and a long tool mix is what a narrow row loses first. *)
      let still_running =
        List.filter
          (fun activity ->
            match activity.outcome with
            | Started | Awaiting_result -> true
            | Returned | Failed | Never_returned | Outcome_unrecorded -> false)
          activities
      in
      let running =
        match still_running with
        | [] -> ""
        | running ->
            Printf.sprintf " · still running: %s"
              (String.concat ", " (compact_tool_parts running))
      in
      (* The turn age alone cannot tell a slow tool from a stall. This says how
         long the call it is sitting in has been open, which is the number that
         stops moving when something is stuck.

         Beside the names rather than after the mix (#32955 put it there before
         the names existed): the two describe the same open calls, and the mix
         is long enough to push whatever follows it off a narrow row. *)
      let in_this_call =
        match oldest_open_call t with
        | None -> ""
        | Some call -> (
          match Masc_tui_message_layout.age_text ~now ~since:call.started_at with
          | None -> ""
          | Some age -> Printf.sprintf " · in this call %s" age)
      in
      let work =
        if calls = 0 then "working" ^ in_this_call
        else
          Printf.sprintf "working · %s%s%s · %s"
            (plural calls "tool") running in_this_call
            (compact_tool_mix activities)
      in
      (* A checkpoint means the turn ran out of context and carried on rather
         than stopping. An operator watching a turn take a long time is owed
         the difference between that and a stall. *)
      if t.checkpoints = 0 then work
      else
        Printf.sprintf "%s, continued past %d context checkpoint(s)" work
          t.checkpoints
  | Stream_ended -> "stream ended; settling the outcome"
  | Stream_failed message -> "stream reported an error: " ^ message

(* Says what was sent, not what became of the turn. A signalled turn parked in
   an uncancellable section keeps running, and reading the signal as the
   outcome is what hid a 63-minute hang (masc #29229). The stream ending is
   what ends the turn, so the row says the turn is still streaming. *)
let interrupt_text t =
  match t.interrupt with
  | Not_requested -> None
  | Signal_sent { turn_id = None; signalled_at_ns = _ } ->
      Some "interrupt signalled; still streaming until it stops"
  | Signal_sent { turn_id = Some turn_id; signalled_at_ns = _ } ->
      Some
        (Printf.sprintf
           "interrupt signalled for turn %d; still streaming until it stops"
           turn_id)
  | Signal_declined reason -> Some ("interrupt was not signalled: " ^ reason)
  | Signal_error detail -> Some ("interrupt request got no answer: " ^ detail)

let unreadable_text t =
  if t.unreadable_count = 0 then None
  else
    Some
      (Printf.sprintf
         "%d live stream diagnostic(s) (last: %s); the recorded outcome is \
          unaffected"
         t.unreadable_count t.last_unreadable)

(* An age, not a duration budget: the row says how long this turn has been
   outstanding so a watcher can tell slow from stuck. Rendered from a clock the
   caller passes rather than one read here, so a test can state the instant.
   A clock that moved backwards says nothing instead of a negative age. *)
let elapsed_text ~now t =
  Masc_tui_message_layout.age_text ~now ~since:t.started_at

let progress_text ~now t =
  match elapsed_text ~now t with
  | None -> phase_text ~now t
  | Some age -> Printf.sprintf "%s · %s" (phase_text ~now t) age

(* The question, as an Attention row. It is the one row an operator has to act
   on, so it is styled like the others that need them rather than like
   progress. *)
let awaiting_text t =
  Option.map
    (fun (awaiting : awaiting_approval) ->
      let base = Printf.sprintf "%s  [y] allow  [n] deny" awaiting.question in
      match awaiting.because with
      | "" -> base
      | because -> Printf.sprintf "%s\n  because %s" base because)
    t.awaiting

let status_rows ~now t =
  [ Some (Progress, progress_text ~now t)
  ; Option.map (fun text -> (Attention, text)) (awaiting_text t)
  ; Option.map
      (fun settlement ->
        ( Approval settlement.settled_outcome
        , Printf.sprintf "approval %s · %s"
            (approval_outcome_to_string settlement.settled_outcome)
            settlement.settled_tool_name ))
      t.last_approval_settlement
  ; Option.map (fun text -> (Attention, text)) (interrupt_text t)
  ; Option.map (fun text -> (Attention, text)) (unreadable_text t)
  ]
  |> List.filter_map (fun row -> row)
  |> List.map (fun (kind, text) -> (kind, safe_line text))

(* Rewrite the one call [call_id] names, leaving the rest as they are. A
   fragment for an id that never opened is dropped rather than opening a
   nameless row -- same call the connector trail makes. *)
type call_update =
  | Call_updated
  | Call_missing
  | Call_ambiguous
  | Call_conflicting

let update_local_call t local_id f =
  t.reversed_tool_calls <-
    List.map
      (fun (call : live_tool_call) ->
        if call.local_id = local_id then f call else call)
      t.reversed_tool_calls
;;

let update_unique_call t ~call_id ~eligible f =
  match
    List.filter
      (fun (call : live_tool_call) ->
        Option.exists (String.equal call_id) call.call_id && eligible call)
      t.reversed_tool_calls
  with
  | [ call ] ->
      update_local_call t call.local_id f;
      Call_updated
  | [] -> Call_missing
  | _ :: _ :: _ -> Call_ambiguous
;;

let note_unreadable t detail =
  t.unreadable_count <- t.unreadable_count + 1;
  t.last_unreadable <- detail
;;

let same_occurrence
    (left : Live.tool_occurrence)
    (right : Live.tool_occurrence) =
  left.stream_scope = right.stream_scope && left.block_index = right.block_index
;;

let provider_correlation_conflicts left right =
  match left, right with
  | Some left, Some right -> not (String.equal left right)
  | Some _, None | None, Some _ | None, None -> false
;;

let occurrence_correlation_conflicts left right =
  provider_correlation_conflicts left.Live.provider_message_id
    right.Live.provider_message_id
;;

let occurrence_label (occurrence : Live.tool_occurrence) =
  Printf.sprintf "%d/%d" occurrence.stream_scope occurrence.block_index
;;

let update_occurrence t occurrence f =
  match
    List.find_opt
      (fun (call : live_tool_call) -> same_occurrence call.occurrence occurrence)
      t.reversed_tool_calls
  with
  | None -> Call_missing
  | Some call
    when occurrence_correlation_conflicts call.occurrence occurrence
         || provider_correlation_conflicts
              call.call_id occurrence.tool_call_id ->
    Call_conflicting
  | Some call ->
    update_local_call t call.local_id f;
    Call_updated
;;

let apply_tool_result t ~(occurrence : Live.tool_occurrence) ~execution_id =
  match
    List.find_opt
      (fun (call : live_tool_call) -> same_occurrence call.occurrence occurrence)
      t.reversed_tool_calls
  with
  | None ->
    note_unreadable t
      (Printf.sprintf
         "KEEPER_TOOL_RESULT_READY names no stream occurrence %s"
         (occurrence_label occurrence))
  | Some { failed = true; _ } ->
    note_unreadable t
      (Printf.sprintf
         "KEEPER_TOOL_RESULT_READY targets quarantined stream occurrence %s"
         (occurrence_label occurrence))
  | Some call
    when occurrence_correlation_conflicts call.occurrence occurrence
         || provider_correlation_conflicts
              call.call_id occurrence.tool_call_id ->
    note_unreadable t
      (Printf.sprintf
         "KEEPER_TOOL_RESULT_READY provider correlation conflicts for stream occurrence %s"
         (occurrence_label occurrence))
  | Some { execution_id = Some recorded; _ }
    when String.equal recorded execution_id ->
    ()
  | Some { execution_id = Some recorded; _ } ->
    note_unreadable t
      (Printf.sprintf
         "KEEPER_TOOL_RESULT_READY conflicts for stream occurrence %s: %s != %s"
         (occurrence_label occurrence) recorded execution_id)
  | Some _ ->
    (match
       List.find_opt
         (fun (call : live_tool_call) ->
            Option.exists (String.equal execution_id) call.execution_id)
         t.reversed_tool_calls
     with
     | Some owner ->
       note_unreadable t
         (Printf.sprintf
            "KEEPER_TOOL_RESULT_READY execution %s already belongs to stream occurrence %s, not %s"
            execution_id (occurrence_label owner.occurrence)
            (occurrence_label occurrence))
     | None ->
       (match
          update_occurrence t occurrence (fun call ->
            { call with
              result_ready = true
            ; execution_id = Some execution_id
            ; ended = true
            })
        with
        | Call_updated -> ()
        | Call_missing ->
          note_unreadable t
            "KEEPER_TOOL_RESULT_READY occurrence disappeared during update"
        | Call_ambiguous ->
          note_unreadable t
            "KEEPER_TOOL_RESULT_READY occurrence became ambiguous during update"
        | Call_conflicting ->
          note_unreadable t
            "KEEPER_TOOL_RESULT_READY occurrence conflicted during update"))
;;

let apply_delta ~now t (delta : Live.delta) =
  match delta with
  | Live.Run_started -> (
      match t.phase with
      | Waiting -> t.phase <- Working
      (* A second RUN_STARTED is a stream defect the strict decode reports as
         Duplicate_run_start. Nothing to draw differently for it here, and
         moving a finished turn back to Working would be wrong. *)
      | Working | Stream_ended | Stream_failed _ -> ())
  | Live.Accepted { admission; queue_length } ->
      (* Recorded, not acted on: the phase still moves on RUN_STARTED. This
         only answers "why has it not started yet". *)
      t.admission <- Some (admission, queue_length)
  | Live.Runtime_attempt_started ->
      (* The per-attempt totals start over; the trail does not. What the
         earlier attempt produced -- finished stretches and the one still
         growing -- is folded into one superseded node so the reader keeps
         what they were reading and can see which attempt it belonged to
         (RFC-0412 §3.3). Tool evidence stays where it was: the calls remain
         in [reversed_tool_calls] and the superseded node still names them. *)
      Buffer.clear t.text_buffer;
      Buffer.clear t.thinking_buffer;
      (* Only the nodes since the last boundary fold; earlier superseded
         blocks stay where they are, so blocks are siblings -- one per
         superseded attempt, each keeping its number -- and never nest.
         [reversed_trail] is newest-first, so consing while walking towards
         the older blocks leaves [since] in arrival order. *)
      let since, older =
        let rec split acc = function
          | (Node_superseded _ :: _) as older -> (acc, older)
          | node :: rest -> split (node :: acc) rest
          | [] -> (acc, [])
        in
        split [] t.reversed_trail
      in
      (match since with
       | [] -> ()
       | nodes ->
           t.reversed_trail <- Node_superseded { attempt = t.attempt; nodes } :: older);
      t.attempt <- t.attempt + 1;
      t.awaiting <- None;
      (match t.phase with
       | Waiting | Working -> t.phase <- Working
       | Stream_ended | Stream_failed _ -> ())
  | Live.Text text ->
      Buffer.add_string t.text_buffer text;
      trail_text t text
  | Live.Thinking text ->
      Buffer.add_string t.thinking_buffer text;
      trail_thinking t text
  | Live.Tool_started { occurrence; tool_name } ->
      (match
         List.find_opt
           (fun (call : live_tool_call) -> same_occurrence call.occurrence occurrence)
           t.reversed_tool_calls
       with
       | Some call
         when String.equal call.tool_name tool_name
              && not
                   (provider_correlation_conflicts
                      call.call_id occurrence.tool_call_id)
              && not
                   (occurrence_correlation_conflicts
                      call.occurrence occurrence) ->
         ()
       | Some _ ->
         note_unreadable t
           (Printf.sprintf
              "TOOL_CALL_START conflicts with stream occurrence %s"
              (occurrence_label occurrence))
       | None ->
         let local_id = t.next_tool_local_id in
         t.next_tool_local_id <- local_id + 1;
         t.reversed_tool_calls <-
           { local_id
           ; started_at = now
           ; occurrence
           ; call_id = occurrence.tool_call_id
           ; execution_id = None
           ; tool_name
           ; args = ""
           ; ended = false
           ; result_ready = false
           ; failed = false
           ; duration = None
           }
           :: t.reversed_tool_calls;
         t.reversed_trail <- Node_tool local_id :: t.reversed_trail)
  | Live.Tool_args { occurrence; fragment } ->
      (match update_occurrence t occurrence (fun call ->
         if call.ended
         then call
         else
             let args =
               match fragment with
               | Live.Args_delta delta -> call.args ^ delta
               | Live.Args_snapshot snapshot -> snapshot
             in
             { call with args }) with
       | Call_updated -> ()
       | Call_missing ->
         note_unreadable t
           (Printf.sprintf "TOOL_CALL_ARGS names no stream occurrence %s"
              (occurrence_label occurrence))
       | Call_ambiguous -> ()
       | Call_conflicting ->
         note_unreadable t
           (Printf.sprintf
              "TOOL_CALL_ARGS provider correlation conflicts for stream occurrence %s"
              (occurrence_label occurrence)))
  | Live.Tool_ended { occurrence } ->
      (match update_occurrence t occurrence (fun call -> { call with ended = true }) with
       | Call_updated -> ()
       | Call_missing ->
         note_unreadable t
           (Printf.sprintf "TOOL_CALL_END names no stream occurrence %s"
              (occurrence_label occurrence))
       | Call_ambiguous -> ()
       | Call_conflicting ->
         note_unreadable t
           (Printf.sprintf
              "TOOL_CALL_END provider correlation conflicts for stream occurrence %s"
              (occurrence_label occurrence)))
  | Live.Tool_result { occurrence; execution_id } ->
      apply_tool_result t ~occurrence ~execution_id
  | Live.Stream_protocol_error { quarantined_occurrence; detail } ->
      (match quarantined_occurrence with
       | None -> note_unreadable t ("stream protocol: " ^ detail)
       | Some occurrence ->
         (match
            update_occurrence t occurrence (fun call ->
              { call with failed = true; ended = true })
          with
          | Call_updated -> note_unreadable t ("stream protocol: " ^ detail)
          | Call_missing ->
            note_unreadable t
              (Printf.sprintf
                 "stream protocol quarantine names no occurrence %s: %s"
                 (occurrence_label occurrence) detail)
          | Call_ambiguous -> ()
          | Call_conflicting ->
            note_unreadable t
              (Printf.sprintf
                 "stream protocol quarantine provider correlation conflicts for occurrence %s: %s"
                 (occurrence_label occurrence) detail)))
  | Live.Approval_requested { call_id; tool_name; args; question; because } ->
      (* The arguments go on the call's own row, which the pane already draws;
         the prompt carries the question. *)
      (match args with
       | "" -> ()
       | args ->
         (match
            update_unique_call t ~call_id
              ~eligible:(fun call -> not call.result_ready && not call.failed)
              (fun call -> { call with args })
          with
          | Call_updated | Call_missing | Call_ambiguous | Call_conflicting -> ()));
      t.last_approval_settlement <- None;
      t.awaiting <- Some { call_id; tool_name; question; because }
  | Live.Approval_settled { call_id; outcome } ->
      (* Cleared whatever the answer was, including none: the prompt is over
         either way, and leaving it up would ask again for a call that has
         already been decided. Guarded by id so a late settle for a superseded
         call cannot clear a prompt now waiting on a different one. *)
      (match t.awaiting with
       | Some awaiting when String.equal awaiting.call_id call_id ->
           t.awaiting <- None;
           t.last_approval_settlement <-
             Some
               { settled_tool_name = awaiting.tool_name
               ; settled_outcome = approval_outcome_of_string outcome
               }
       | Some _ | None -> ())
  | Live.Checkpoint -> t.checkpoints <- t.checkpoints + 1
  | Live.External_effect_completed ->
      (* The turn handed work to something outside it and that work finished.
         It is not a turn outcome: the run says when it ends. *)
      ()
  | Live.Run_failed { message } -> t.phase <- Stream_failed message
  | Live.Run_finished -> t.phase <- Stream_ended
  | Live.Reply_details { reply; turn_outcome; turn_ref } ->
      t.reply <-
        Some { reply_text = reply; reply_outcome = turn_outcome; reply_turn_ref = turn_ref }
  | Live.Undecodable detail ->
      note_unreadable t detail

let apply ~now t delta =
  bump t;
  apply_delta ~now t delta

(* The same fold the live path runs one delta at a time, over a whole log. A
   transcript rebuilt from a log is equal to one that grew with it -- pinned
   by test -- which is what lets a settled or reloaded turn be drawn by the
   projection the live turn used. *)
let of_log ~now (log : Masc_tui_keeper_chat_log.t) =
  let t =
    create
      ~keeper_name:(Masc_tui_keeper_chat_log.keeper_name log)
      ~request_id:(Masc_tui_keeper_chat_log.request_id log)
      ~started_at:(Masc_tui_keeper_chat_log.started_at log)
  in
  List.iter
    (fun (entry : Masc_tui_keeper_chat_log.entry) -> apply ~now t entry.delta)
    (Masc_tui_keeper_chat_log.entries log);
  t
;;

(* What the durable transcript knows about a call that the wire did not
   carry: how it ended and how long it took. Matched by execution id, the
   server-owned identity both records share. A fact the wire already had is
   not taken back: the durable [Never_returned] and the unrecorded outcome
   say less than the stream saw, and the stream's word stands. *)
let note_tool_outcome t ~execution_id ~outcome ~duration =
  match
    List.find_opt
      (fun (call : live_tool_call) ->
        Option.equal String.equal call.execution_id (Some execution_id))
      t.reversed_tool_calls
  with
  | None -> false
  | Some call ->
      let updated =
        match outcome with
        | Returned -> { call with result_ready = true; ended = true }
        | Failed -> { call with failed = true; ended = true }
        | Started | Awaiting_result | Never_returned | Outcome_unrecorded -> call
      in
      let updated =
        match duration with
        | Some _ -> { updated with duration }
        | None -> updated
      in
      update_local_call t call.local_id (fun _ -> updated);
      bump t;
      true

let turn_status_text ~reply ~turn_ref (outcome : Masc.Keeper_turn_outcome.t) =
  match outcome with
  | Masc.Keeper_turn_outcome.Visible_reply when String.trim reply <> "" -> reply
  | Masc.Keeper_turn_outcome.Visible_reply ->
      Printf.sprintf "Turn completed with non-text visible content (turn %s)" turn_ref
  | Masc.Keeper_turn_outcome.Continuation_checkpoint ->
      Printf.sprintf "Continuation checkpoint recorded (turn %s)" turn_ref
  | Masc.Keeper_turn_outcome.Terminal_effect_settled ->
      Printf.sprintf "Reply delivered by a terminal tool (turn %s)" turn_ref
  | Masc.Keeper_turn_outcome.Awaiting_gate_approval ->
      (* Deferred, not stalled: the turn continues once the gate answers
         (#33126). *)
      Printf.sprintf "승인 후 턴을 이어서 진행합니다 (turn %s)" turn_ref
  | Masc.Keeper_turn_outcome.No_visible_reply ->
      Printf.sprintf "Turn completed without a visible reply (turn %s)" turn_ref
;;

type drawn =
  | Drawn_thinking of string list
  | Drawn_skill of skill_activity
  | Drawn_tools of tool_block
  | Drawn_text of string
  | Drawn_reply of string
  | Drawn_status of string

type drawn_item =
  { superseded : int option
  ; drawn : drawn
  }

(* The trail, flattened, with the recorded reply reconciled against what
   streamed. Superseded blocks are siblings in the trail, never nested (see
   [trail_item]), so one level of flattening is the whole of it. *)
let drawn t =
  let rec flatten superseded = function
    | Trail_thinking lines -> [ { superseded; drawn = Drawn_thinking lines } ]
    | Trail_skill skill -> [ { superseded; drawn = Drawn_skill skill } ]
    | Trail_tools block -> [ { superseded; drawn = Drawn_tools block } ]
    | Trail_text text -> [ { superseded; drawn = Drawn_text text } ]
    | Trail_superseded { attempt; items } ->
        List.concat_map (flatten (Some attempt)) items
  in
  let items = List.concat_map (flatten None) (trail t) in
  let current_text = function
    | { superseded = None; drawn = Drawn_text _ } -> true
    | { superseded = Some _; _ }
    | { superseded = None
      ; drawn =
          ( Drawn_thinking _ | Drawn_skill _ | Drawn_tools _ | Drawn_reply _
          | Drawn_status _ )
      } ->
        false
  in
  (* The recorded reply is the terminal message's text
     ([Agent_core.Types.text_of_content result.response.content], normalized),
     not the whole turn's: a turn that said "Let me check." before its tool
     round and "Done." after records "Done.". So only the last stretch of the
     current attempt is the one the reply stands for; the stretches before it
     are the turn's earlier rounds and stay as they streamed. *)
  let last_text =
    List.fold_left
      (fun (index, last) item ->
        (index + 1, if current_text item then Some index else last))
      (0, None) items
    |> snd
  in
  match t.reply with
  | None -> items
  | Some { reply_text; reply_outcome = Masc.Keeper_turn_outcome.Visible_reply; _ }
    when String.trim reply_text <> "" -> (
      (* Which turn this reply belongs to was decided before it got here, by
         the log this transcript projects: a log is one operation's
         ([Masc_tui_keeper_chat_log.request_id]), a live frame reaches the
         log of the in-flight request it was streamed for (matched on the
         request's identity, not its words), and a journal is read per
         operation into the log created with that id. So a reply on this
         transcript is this operation's, and the operation records one reply:
         the terminal message, the last stretch of the current attempt. The
         record is the store's text for it and stands where that stretch
         was, typed as the record -- whatever the stream's copy read. *)
      let reply_item = { superseded = None; drawn = Drawn_reply (safe_block reply_text) } in
      match last_text with
      | None ->
          (* Nothing streamed for the reply: the record is all there is. *)
          items @ [ reply_item ]
      | Some last ->
          List.mapi (fun index item -> if index = last then reply_item else item) items)
  | Some { reply_text; reply_outcome; reply_turn_ref } ->
      (* Nothing is chunked for a control outcome, and a visible reply with
         no text has nothing to chunk: the one row that says how the turn
         ended comes from the recorded reply. *)
      items
      @ [ { superseded = None
          ; drawn =
              Drawn_status
                (safe_block
                   (turn_status_text ~reply:reply_text ~turn_ref:reply_turn_ref
                      reply_outcome))
          } ]
;;
