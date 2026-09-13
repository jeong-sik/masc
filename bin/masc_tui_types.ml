[@@@warning "-32-69"]
module Tui_decode = Masc.Tui_decode
module Metrics_tail = Masc_tui_metrics_tail
module Rows = Masc_tui_rows

(* A poll shares the current read; an explicit refresh owns a new one.
   Only the owning response can settle that source and publish its result. *)
module Snapshot_read : sig
  type request
  type t
  type intent = Poll | Refresh

  val idle : t
  val start : intent:intent -> t -> t * request option
  val settle : t -> request -> t option
end = struct
  type request = int
  type t = { next : int; pending : request option }
  type intent = Poll | Refresh

  let idle = { next = 0; pending = None }

  let start ~intent state =
    match intent, state.pending with
    | Poll, Some _ -> state, None
    | (Poll | Refresh), _ ->
      let request = state.next in
      { next = request + 1; pending = Some request }, Some request

  let settle state request =
    match state.pending with
    | Some pending when pending = request -> Some { state with pending = None }
    | Some _ | None -> None
end

(** TUI shared types — split from masc_tui.ml (#3808) *)

(** Agent type with status (from Tui_decode) *)
type agent = Tui_decode.agent

(** Task type (from Tui_decode) *)
type task = Tui_decode.task

(** Event for the event log *)
(* The six states the refresh loop can put the TUI in. It was a string
   with a catch-all at each of the five render sites, so a typo rendered
   as [disconnected] and a new state would have too. *)
type connection_status =
  | Disconnected
  | Connecting
  | Booting
  | Reconnecting
  | Degraded
  | Connected

let connection_status_label = function
  | Connected -> "connected"
  | Degraded -> "degraded"
  | Connecting -> "connecting..."
  | Booting -> "server booting..."
  | Reconnecting -> "reconnecting..."
  | Disconnected -> "disconnected"
;;

(* A successful probe is the current server even when the peer address did not
   change. A failed probe is unread, not permission to present the previous
   process as current. Keeping this projection pure lets the same-port restart
   rule be tested without a live server. *)
let server_identity_of_refresh
    (reading : (Tui_decode.server_identity, string) result) =
  match reading with
  | Ok current -> Some current
  | Error _ -> None
;;

(* A probe that answered but says [state_ready = false] is a server still
   replaying its stores behind an open port. Surfaces asked of it wait out
   their timeouts and come back as failures, which reads as a dead server.
   The honest reading is "booting", and the honest action is to ask nothing
   but the probe until it says ready. A probe without the field is an older
   server: neither booting nor vouched for, so it is served as before. *)
let server_is_booting
    (reading : (Tui_decode.server_identity, string) result) =
  match reading with
  | Ok { Tui_decode.sid_state_ready = Some false; _ } -> true
  | Ok { Tui_decode.sid_state_ready = Some true | None; _ } | Error _ -> false
;;

type workspace_identity =
  | Workspace_identity_unread
  | Workspace_identity_match
  | Workspace_identity_mismatch of
      { local_base_path : string
      ; server_base_path : string
      }

(* Whether the rows kept from this workspace's own directory -- agents, tasks,
   keepers, their logs -- were read from it. They are read only once the server
   says it serves this workspace, and cleared again when it serves another, and
   both leave the lists empty with no error beside them. An empty roster alone
   therefore cannot say "no keepers"; this says whether it may. *)
type local_workspace_reading =
  | Local_workspace_unread
  | Local_workspace_read

let canonical_path path =
  if String.equal path ""
  then ""
  else
    try Unix.realpath path with
    | Unix.Unix_error _ -> path
;;

let workspace_identity_of_refresh ~local_base_path reading =
  match reading with
  | Error _ -> Workspace_identity_unread
  | Ok identity ->
    let local_base_path = canonical_path local_base_path in
    let server_base_path = canonical_path identity.Tui_decode.sid_base_path in
    if String.equal local_base_path "" || String.equal server_base_path ""
    then Workspace_identity_unread
    else if String.equal local_base_path server_base_path
    then Workspace_identity_match
    else Workspace_identity_mismatch { local_base_path; server_base_path }
;;

type event = {
  timestamp: string;
  event_type: string;
  content: string;
}

(* How long the footer keeps saying what the last keypress did. Long enough
   to read after coming back from $EDITOR, short enough that it is still
   about the key the operator just pressed. *)
let last_action_window_s = 12.0

(* The one key the Overview event panel folds identical neighbours by; the
   renderer and both scroll handlers must count the same folded rows or the
   scroll range and the drawn range drift apart. *)
let overview_event_collapse_key event =
  event.event_type ^ "\x00" ^ event.content
;;

(** Keeper metadata (from Tui_decode) *)
type keeper = Tui_decode.keeper
type keeper_runtime = Tui_decode.keeper_runtime

(** A single metrics/log entry (from Tui_decode) *)
type log_entry = Tui_decode.log_entry

(** Who addressed the keeper, on a row the keeper did not write.

    The server has always said which of the two this is -- [speaker_authority]
    on the wire, {!Masc_tui_keeper_chat_history.speaker} after decoding -- and
    the pane collapsed both into the display label. Everything downstream then
    had to ask the label: the style did not ask at all and drew the two alike,
    and the message recall asked with [String.equal label "you"], which is
    false for the operator's own lines that arrived on any surface but the
    dashboard.

    Each arm carries the label to draw. The label is a rendering of the fact;
    the constructor is the fact. *)
type message_author =
  | Sent_by_operator of { surface : string option }
      (** The person reading this pane, and the door they came in by when it
          was not the dashboard -- an operator can write to a keeper from a
          connector. Apart for the same reason as the arm below, and it was
          joined here while that one was split: at a ten-cell column
          ["you \xc2\xb7 broadcast"] was cut to ["yo\xe2\x80\xa6dcast"],
          losing the speaker to keep the tail of the surface. *)
  | Sent_by_other of
      { speaker : string
      ; surface : string option
      }
      (** Anyone else: another agent's broadcast, a connector, a second
          operator. Kept apart rather than joined here because the speaker
          column is narrower than the pair: joined, the fit cuts the middle of
          one string and the tail it favours is the surface, so the row keeps
          which door it came in by and loses who came through it. Whoever
          knows the column decides. *)

type msg_role =
  | Message_user of message_author
      (** A row addressed to the keeper by a person or another agent. *)
  | Message_keeper
  | Message_autonomous
      (** A keeper reply produced by an autonomous turn rather than a message
          sent from this chat. *)
  | Message_status
      (** What the server says happened to this turn: an approval moving
          through its phases, a delivery that failed and recovered. Transcript,
          and it belongs to a request. *)
  | Message_local
      (** The pane answering something the operator typed at it -- the command
          list, a [/find] that matched nothing, a [/interrupt] with no turn to
          interrupt. It never left this machine and belongs to no request.

          Separate from {!Message_status} because the two read as one lane
          otherwise, and they are not: twenty lines of [/help] landed between
          two approval phases under the same badge. The gate rows were moved
          once before for the same reason, out of the journal lane where they
          interleaved with memory commits. *)
  | Message_error
  | Message_tool
      (** The tool calls of one finished turn, as the row block the live pane
          drew while it ran. The strict stream decode carries no tool
          information, so without this a turn that read six files and edited
          two scrolls back looking like one answered from memory. *)
  | Message_skill of Masc_tui_keeper_chat_transcript.skill_state
      (** Exact Skill lifecycle evidence for one turn. Kept apart from a
          generic tool row because [keeper_skill] returning proves content was
          served, while delivery and observed actions are separate facts. *)
  | Message_thinking
      (** The reasoning of one autonomous turn as the transcript carried it:
          the lines the server kept and the count it withheld. Drawn with the
          live pane's thinking style, so a turn the keeper ran on its own and
          one watched live read alike. *)
  | Message_memory
      (** One Memory OS journal pass in its explicit auxiliary producer lane. *)

type reasoning_visibility =
  | Reasoning_hidden
  | Reasoning_folded
  | Reasoning_full

type tool_visibility =
  | Tools_compact
  | Tools_full

(* How much of the Librarian/Memory journal the chat pane draws. Summary is
   the resting state: one header line per journal pass, so the conversation
   keeps the pane and the change itself stays one keypress away. *)
type memory_visibility =
  | Memory_hidden
  | Memory_summary
  | Memory_full

let reasoning_visibility_to_string = function
  | Reasoning_hidden -> "hidden"
  | Reasoning_folded -> "folded"
  | Reasoning_full -> "full"
;;

let tool_visibility_to_string = function
  | Tools_compact -> "compact"
  | Tools_full -> "full"
;;

let memory_visibility_to_string = function
  | Memory_hidden -> "hidden"
  | Memory_summary -> "summary"
  | Memory_full -> "full"
;;

(* From the resting summary toward more, then none, then back: the first
   press answers "what changed exactly", the second clears the lane, the
   third restores the default. *)
let next_memory_visibility = function
  | Memory_summary -> Memory_full
  | Memory_full -> Memory_hidden
  | Memory_hidden -> Memory_summary
;;

let origin_display_to_string = function
  | Masc_tui_message_layout.Origin_row -> "row"
  | Masc_tui_message_layout.Origin_inline -> "inline"
  | Masc_tui_message_layout.Origin_bare -> "off"
;;

let origin_display_of_string = function
  | "row" -> Some Masc_tui_message_layout.Origin_row
  | "inline" -> Some Masc_tui_message_layout.Origin_inline
  | "off" -> Some Masc_tui_message_layout.Origin_bare
  | _ -> None
;;

(* The chat modes worth a place in the header.

   Reasoning starts hidden, tools compact, and the memory journal at its
   one-line summary, so the answer remains the strongest level in the pane.
   At rest those defaults say nothing unusual and therefore cost no header
   width.

   So only a mode away from its default appears. That is exactly when the
   operator needs reminding: reasoning is missing from the pane because they
   hid it, not because the keeper stopped thinking. At rest the header is what
   it was before any of these modes existed.

   Discovery lives in the footer and the help overlay, which name Ctrl-R,
   Ctrl-D, Ctrl-N, and Ctrl-F whether or not a mode is on. *)
let chat_visibility_summary ~memory ~reasoning ~tools ~origin =
  let parts =
    List.filter_map Fun.id
      [ (match memory with
         | Memory_summary -> None
         (* Named for the rows it governs, which the pane labels JOURNAL and
            the footer reaches with Ctrl-N:journal. It read "memory" here and
            "journal" there, so pressing the key and looking for what moved
            meant knowing the two words were one axis. *)
         | Memory_hidden -> Some "journal:off"
         | Memory_full -> Some "journal:full")
      ; (* The short clock is the resting layout. It was the bare gutter, on
           the grounds that a clock on every row was noise -- and it was, back
           when it drew on every row. It is now drawn only where the minute
           moved, which over 531 captured rows left it blank on 45% of them,
           and a gutter that spends seventeen cells without saying when
           anything happened is the emptier column of the two.

           So the header names the two projections away from it: the bare
           gutter, because a pane with no clock at all should say that it is
           the reader's choice, and the full row. *)
        (match origin with
         | Masc_tui_message_layout.Origin_bare -> Some "metadata:off"
         | Masc_tui_message_layout.Origin_inline -> None
         | Masc_tui_message_layout.Origin_row -> Some "metadata:full")
      ; (match reasoning with
         | Reasoning_hidden -> None
         | (Reasoning_folded | Reasoning_full) as mode ->
             Some ("reasoning:" ^ reasoning_visibility_to_string mode))
      ; (match tools with
         | Tools_compact -> None
         | Tools_full -> Some "tools:full")
      ]
  in
  String.concat " " parts
;;

let next_reasoning_visibility = function
  | Reasoning_hidden -> Reasoning_folded
  | Reasoning_folded -> Reasoning_full
  | Reasoning_full -> Reasoning_hidden
;;

(* One key walks the whole axis, and the walk is unchanged: from the resting
   short clock to the full timestamp and request id on a row of their own,
   then to the bare gutter, then back. What moved is where it rests -- see
   [chat_visibility_summary]. Every stop is still reachable, and the two ends
   are still one press apart from each other. *)
let next_origin_display = function
  | Masc_tui_message_layout.Origin_bare -> Masc_tui_message_layout.Origin_inline
  | Masc_tui_message_layout.Origin_inline -> Masc_tui_message_layout.Origin_row
  | Masc_tui_message_layout.Origin_row -> Masc_tui_message_layout.Origin_bare
;;

let toggle_tool_visibility = function
  | Tools_compact -> Tools_full
  | Tools_full -> Tools_compact
;;

(* The chat header shows the effective stances, including their defaults. A
   blank label here is worse than repetition: this is the surface where the
   operator decides whether to send work, and AUTO/YOLO plus the Gate mode
   change what can happen after that send. A Keeper-level [workspace] value is
   inheritance, so resolve it through the workspace observation rather than
   printing a setting that is not itself a mode. *)
let keeper_chat_mode_labels ~yolo ~keeper_gate_mode ~workspace_gate_mode =
  let chat_mode = if yolo then "YOLO" else "AUTO" in
  let gate_mode =
    match keeper_gate_mode with
    | Some mode when not (String.equal mode "workspace") -> mode
    | Some _ | None -> Option.value ~default:"?" workspace_gate_mode
  in
  chat_mode, gate_mode
;;

(* Usage coverage can be warming independently of the catalog. Missing time
   therefore means unavailable, not "never used" -- the latter would claim a
   lifetime fact from a bounded retained ledger. *)
let skill_last_used_label = function
  | Some value when String.trim value <> "" -> value
  | Some _ | None -> "time unavailable"
;;

type chat_turn_phase =
  | Turn_input
  | Turn_progress
  | Turn_tool
  | Turn_output

type msg_identity =
  | Persisted_row of string
  | Persisted_legacy_row of
      { request_id : string
      ; operation_seq : int
      }
  | Session_row of
      { request_id : string
      ; turn_phase : chat_turn_phase
      ; operation_seq : int
      }

(** Request-correlated message history entry. [me_turn_phase], rather than the
    display role or timestamp, is the ordering authority inside one turn. *)
(* The typed half of a Gate status row: which approval it belongs to, which
   step it is, the tool the approval is for, and what the gated call asked
   for. *)
type gate_step = {
  gs_approval_id: string;
  gs_phase: Masc.Keeper_chat_store.approval_lifecycle_phase;
      (** The store's closed sum, parsed once by the history decoder. *)
  gs_tool: string option;
  gs_summary: string option;
}

type msg_entry = {
  me_role: msg_role;
  me_identity: msg_identity;
  me_turn_phase: chat_turn_phase;
  me_turn_sequence: int option;
      (** Absolute Keeper turn sequence from a persisted turn_ref. This is the
          stable tie-breaker when causal frontiers share one display clock.
          Request identity, not this sequence, groups rows into a turn. *)
  me_operation_seq: int;
      (** Structural producer position within one request. Inside that request,
          timestamps never move rows; phase then this sequence is the order. *)
  me_text: string;
  me_image: Masc_tui_image_preview.preview;
  me_memory_summary: string option;
      (** Producer-built compact text for a Memory journal row. [None] for
          ordinary conversation and neutral system rows; renderers never
          recover this boundary by splitting display text. *)
  me_gate: gate_step option;
      (** The typed approval step behind a Gate status row. Carried so a run
          of steps can be folded back into the one approval they describe;
          [None] on every other row, including other status rows, which must
          not be folded with them. *)
  me_submitted_at: float option;
      (** First local Enter time for an operator input. Preserved when the
          durable transcript replaces the session copy and used as that input
          phase's source clock; never set on tool or output rows. *)
  me_tool_block: Masc_tui_keeper_chat_transcript.tool_block option;
  me_skill_activity: Masc_tui_keeper_chat_transcript.skill_activity option;
  me_timestamp: string;
  me_keeper_name: string;
  me_request_id: string;
  (* Producer observation time. Conversation and auxiliary rows share one
     chronological surface. Within a request, later phases clamp to the latest
     earlier-phase clock before the rows merge with parallel lanes. *)
  me_at: float;
}

(* A run of journal rows says one thing: where the memory ended up. Each row
   in summary mode still wraps to about two lines, so three commits in a row
   took six lines of a pane whose whole point is the conversation. The newest
   row carries the current revision, so it is the one kept; the ones before it
   are counted, and Ctrl-N still opens all of them.

   Full mode is not folded: it exists to show every commit. *)
let fold_memory_summary_runs ~visibility entries =
  match visibility with
  | Memory_hidden | Memory_full -> entries
  | Memory_summary ->
    let annotate folded (entry, extra) =
      if folded = 0 then (entry, extra)
      else
        ( { entry with
            me_memory_summary =
              Option.map
                (fun summary -> Printf.sprintf "%s · +%d earlier" summary folded)
                entry.me_memory_summary
          }
        , extra )
    in
    let rec go acc run = function
      | [] -> (
        match run with
        | [] -> List.rev acc
        | newest :: older -> List.rev (annotate (List.length older) newest :: acc))
      | ((entry, _) as row) :: rest -> (
        match entry.me_role with
        | Message_memory -> go acc (row :: run) rest
        | Message_user _ | Message_keeper | Message_autonomous | Message_status
        | Message_local | Message_error | Message_tool | Message_skill _
        | Message_thinking -> (
          match run with
          | [] -> go (row :: acc) [] rest
          | newest :: older ->
            go (row :: annotate (List.length older) newest :: acc) [] rest))
    in
    go [] [] entries
;;

(* Compact folds only a successfully settled approval. Its durable identity
   survives the continuation's new request id, so prose or a tool block between
   lifecycle steps cannot make the same approval occupy several status rows.
   All non-Gate rows keep their original position and text. Problems and
   unresolved operations remain complete; Full restores every original step. *)
let project_gate_history ~visibility entries =
  match visibility with
  | Tools_full -> entries
  | Tools_compact ->
      let module Approvals = Map.Make (struct
        type t = string * string
        let compare = Stdlib.compare
      end) in
      let key entry =
        match entry.me_role, entry.me_gate with
        | Message_status, Some gate
          when entry.me_keeper_name <> "" && gate.gs_approval_id <> "" ->
            Some (entry.me_keeper_name, gate.gs_approval_id)
        | _ -> None
      in
      let _, groups = List.fold_left (fun (index, groups) (entry, _) ->
        let groups = match key entry, entry.me_gate with
          | Some key, Some gate ->
              Approvals.update key (fun previous ->
                Some ((index, gate) :: Option.value ~default:[] previous)) groups
          | _ -> groups
        in index + 1, groups) (0, Approvals.empty) entries
      in
      let compact = Approvals.map (fun reversed ->
        let steps = List.rev reversed in
        let phases = List.map (fun (_, gate) -> gate.gs_phase) steps in
        let has_problem, last_outcome =
          List.fold_left (fun (problem, last) phase ->
            let open Masc.Keeper_chat_store in
            match phase with
            | Approval_replay_failed | Approval_replay_indeterminate
            | Approval_replay_applied_with_warning | Approval_resolved_rejected ->
                true, Some phase
            | Approval_requested | Approval_resolved_approved
            | Approval_replay_applied -> problem, Some phase
            | Approval_continuation_recorded -> problem, last
            (* The turn that received the replay failed. The run stays open
               so the row is seen; not an outcome, so [last] holds. *)
            | Approval_continuation_failed -> true, last)
            (false, None) phases
        in
        match reversed, has_problem, last_outcome with
        | (last_index, newest) :: _ :: _, false,
          Some Masc.Keeper_chat_store.Approval_replay_applied ->
            let summary = List.find_map (fun (_, gate) -> gate.gs_summary) reversed in
            Option.map (fun text ->
              last_index, Printf.sprintf "%s · %d steps · Ctrl-D" text (List.length steps))
              (Masc_tui_gate_text.fold_line ~phases ~tool:newest.gs_tool ~summary)
        | _ -> None) groups
      in
      List.filter_mapi (fun index ((entry, extra) as row) ->
        match Option.bind (key entry) (fun key -> Approvals.find_opt key compact) with
        | Some (Some (last_index, text)) ->
            if index = last_index then Some ({ entry with me_text = text }, extra)
            else None
        | Some None | None -> Some row) entries
;;

type chat_turn = {
  ct_request_id: string;
  ct_turn_sequence: int option;
  ct_rows: msg_entry list;
}

type chat_timeline_item =
  | Chat_turn of chat_turn
  | Chat_unowned of msg_entry
  | Chat_memory of msg_entry
      (** Explicit auxiliary journal lane. Memory rows have no conversational
          request owner; their recorded time places them between conversation
          rows without making them part of a turn. *)

type chat_timeline = {
  ctl_items: chat_timeline_item list;
}

(* The row's source clock before causal projection. Request rows are projected
   to a nondecreasing phase frontier by [chat_timeline_rows]. *)
let message_display_at row =
  let valid at = Float.is_finite at && at > 0. in
  match row.me_submitted_at with
  | Some at when valid at -> Some at
  | Some _ | None -> if valid row.me_at then Some row.me_at else None
;;

(* One moment per row, with a floor per request id so a turn's rows cannot
   read as moving backwards.

   Both tables were assoc lists. A conversation carries about as many request
   ids as it has turns, and the floor list was rebuilt with
   [List.remove_assoc] on every row: 561 rows over 200 turns walked a hundred
   thousand pairs to answer a question that is one lookup per row. The tables
   are created and dropped inside the call, so this is still a map from rows
   to moments and nothing outside sees them. *)
let chat_projected_timeline_ats messages =
  let first_known_by_request = Hashtbl.create 64 in
  List.iter
    (fun (row : msg_entry) ->
      let request_id = row.me_request_id in
      if (not (String.equal request_id ""))
         && not (Hashtbl.mem first_known_by_request request_id)
      then
        (* A row without a moment does not claim the id: a later row of the
           same request can still be the first known one. *)
        match message_display_at row with
        | Some at -> Hashtbl.replace first_known_by_request request_id at
        | None -> ())
    messages;
  let floors = Hashtbl.create 64 in
  let rec project reversed = function
    | [] -> List.rev reversed
    | (row : msg_entry) :: rest ->
        let request_id = row.me_request_id in
        let raw_at = message_display_at row in
        if String.equal request_id ""
        then project (raw_at :: reversed) rest
        else
          let projected_at =
            (* A floor recorded as [None] is a request known to have no
               moment, which is not the same as a request not seen yet. *)
            match Hashtbl.find_opt floors request_id, raw_at with
            | None, Some at -> Some at
            | None, None -> Hashtbl.find_opt first_known_by_request request_id
            | Some None, _ -> None
            | Some (Some floor), Some at -> Some (Float.max floor at)
            | Some (Some floor), None -> Some floor
          in
          Hashtbl.replace floors request_id projected_at;
          project (projected_at :: reversed) rest
  in
  project [] messages
;;

type msg_anchor =
  { ma_identity : msg_identity
  ; ma_session_user_slot :
      (string * chat_turn_phase * int) option
      (** A local USER row is replaced by the server's persisted copy after
          terminal refresh. Its server row id cannot be known at submission,
          so this exact turn slot is the one permitted cross-identity match.
          Other rows remain identity-only anchors. *)
  }

let chat_turn_phase_of_role = function
  | Message_user _ -> Turn_input
  | Message_status | Message_thinking | Message_memory | Message_skill _ ->
      Turn_progress
  (* A row the pane wrote in answer to a command. It is in no turn, and
     Turn_output is the phase that sorts it where it was typed. *)
  | Message_local -> Turn_output
  | Message_tool -> Turn_tool
  | Message_keeper | Message_autonomous | Message_error -> Turn_output
;;

let chat_turn_phase_rank = function
  | Turn_input -> 0
  | Turn_progress -> 1
  | Turn_tool -> 2
  | Turn_output -> 3
;;

let order_chat_turn_rows rows =
  List.stable_sort
    (fun left right ->
      let phase =
        Int.compare
          (chat_turn_phase_rank left.me_turn_phase)
          (chat_turn_phase_rank right.me_turn_phase)
      in
      if phase <> 0
      then phase
      else Int.compare left.me_operation_seq right.me_operation_seq)
    rows
;;

(* A turn while it is being assembled. The rows arrive in the order the
   conversation carries them and are ordered once, when the turn is finished;
   [order_chat_turn_rows] is a stable sort, so sorting once over the arrival
   order lands every row where sorting after each arrival did.

   [ctb_user_texts] is what recognises a user line the transcript already
   holds. Two user rows of one request with the same text are one line
   submitted twice -- the session copy and the server's persisted copy -- and
   only one belongs on screen. Within a turn the request id is fixed, so the
   text alone is the question, and the table answers it without walking the
   turn. Non-user rows never fold: two tool rows with the same text are two
   calls. *)
type chat_turn_builder = {
  ctb_request_id : string;
  mutable ctb_rows_rev : msg_entry list;
  mutable ctb_turn_sequence : int option;
  ctb_user_texts : (string, unit) Hashtbl.t;
}

type chat_timeline_slot =
  | Slot_turn of chat_turn_builder
  | Slot_unowned of msg_entry
  | Slot_memory of msg_entry

let is_user_row row =
  match row.me_role with
  | Message_user _ -> true
  | Message_keeper | Message_autonomous | Message_status | Message_local
  | Message_error | Message_tool | Message_thinking | Message_memory
  | Message_skill _ ->
      false
;;

(* Two rows of one turn can disagree about which turn of the conversation it
   was. A disagreement is not a tie to break: the turn stops claiming a
   number rather than picking one of them. *)
let merge_turn_sequence held arriving =
  match held, arriving with
  | None, sequence | sequence, None -> sequence
  | Some left, Some right when Int.equal left right -> Some left
  | Some _, Some _ -> None
;;

(* The conversation's rows as turns, journal lines and unowned lines, in the
   order each first appears.

   Assembling this walked the items built so far for every row and rebuilt
   the list to put one row in one turn, so a conversation cost the square of
   its length. The table finds the turn a row belongs to in one lookup; the
   slots keep the order the walk found. *)
let chat_timeline_slots rows =
  let slots_rev = ref [] in
  let builders : (string, chat_turn_builder) Hashtbl.t = Hashtbl.create 64 in
  List.iter
    (fun (row : msg_entry) ->
      if row.me_role = Message_memory
      then slots_rev := Slot_memory row :: !slots_rev
      else if String.equal row.me_request_id ""
      then slots_rev := Slot_unowned row :: !slots_rev
      else
        match Hashtbl.find_opt builders row.me_request_id with
        | Some builder ->
            (* The sequence is merged even when the row itself folds into a
               line already held: a duplicate still carries what it knows
               about which turn this was. *)
            builder.ctb_turn_sequence <-
              merge_turn_sequence builder.ctb_turn_sequence row.me_turn_sequence;
            let folds =
              is_user_row row && Hashtbl.mem builder.ctb_user_texts row.me_text
            in
            if not folds
            then begin
              if is_user_row row
              then Hashtbl.replace builder.ctb_user_texts row.me_text ();
              builder.ctb_rows_rev <- row :: builder.ctb_rows_rev
            end
        | None ->
            let user_texts = Hashtbl.create 4 in
            if is_user_row row then Hashtbl.replace user_texts row.me_text ();
            let builder =
              { ctb_request_id = row.me_request_id
              ; ctb_rows_rev = [ row ]
              ; ctb_turn_sequence = row.me_turn_sequence
              ; ctb_user_texts = user_texts
              }
            in
            Hashtbl.replace builders row.me_request_id builder;
            slots_rev := Slot_turn builder :: !slots_rev)
    rows;
  List.rev_map
    (function
      | Slot_memory row -> Chat_memory row
      | Slot_unowned row -> Chat_unowned row
      | Slot_turn builder ->
          Chat_turn
            { ct_request_id = builder.ctb_request_id
            ; ct_turn_sequence = builder.ctb_turn_sequence
            ; ct_rows = order_chat_turn_rows (List.rev builder.ctb_rows_rev)
            })
    !slots_rev
;;

type projected_chat_row =
  { pcr_row : msg_entry
  ; pcr_at : float option
  ; pcr_turn_sequence : int option
  ; pcr_lane_rank : int
  ; pcr_request_id : string
  }

let compare_optional_turn_sequence left right =
  match left, right with
  | Some left, Some right -> Int.compare left right
  | Some _, None -> -1
  | None, Some _ -> 1
  | None, None -> 0
;;

let compare_projected_chat_row_tie left right =
  let by_turn_sequence =
    compare_optional_turn_sequence left.pcr_turn_sequence
      right.pcr_turn_sequence
  in
  if by_turn_sequence <> 0
  then by_turn_sequence
  else
    let by_lane = Int.compare left.pcr_lane_rank right.pcr_lane_rank in
    if by_lane <> 0
    then by_lane
    else if String.equal left.pcr_request_id ""
            || not
                 (String.equal
                    left.pcr_request_id
                    right.pcr_request_id)
    then 0
    else
      let left = left.pcr_row in
      let right = right.pcr_row in
      let by_phase =
        Int.compare
          (chat_turn_phase_rank left.me_turn_phase)
          (chat_turn_phase_rank right.me_turn_phase)
      in
      if by_phase <> 0
      then by_phase
      else Int.compare left.me_operation_seq right.me_operation_seq
;;

let compare_projected_chat_rows left right =
  match left.pcr_at, right.pcr_at with
  | Some left_at, Some right_at ->
      let by_time = Float.compare left_at right_at in
      if by_time <> 0
      then by_time
      else compare_projected_chat_row_tie left right
  | Some _, None -> -1
  | None, Some _ -> 1
  | None, None -> compare_projected_chat_row_tie left right
;;

let chat_timeline ~loaded ~session ~queued_request_ids =
  let queued request_id =
    List.exists (String.equal request_id) queued_request_ids
  in
  let visible_session =
    List.filter (fun row -> not (queued row.me_request_id)) session
  in
  { ctl_items = chat_timeline_slots (loaded @ visible_session) }
;;

(* Which lane a chat row belongs to, asked of the row rather than of where it
   happens to sit.

   The pane draws nine kinds of row on one clock: what a person said, what the
   keeper answered, what an autonomous turn answered, its thinking, its tool
   block, its skills, a memory commit, a status line, an error. Another agent's
   broadcast and an external request arrive on the same clock and belong to no
   turn at all. Laid out flat they are in the right order and in no order that
   says what produced what.

   The timeline already sorts rows this way to place them
   ({!chat_timeline_slots}); this is the same question asked of one row, so a
   renderer can draw the boundary without rebuilding the timeline. *)
type chat_row_lane =
  | Lane_turn of string
      (** Produced inside the turn with this request id. *)
  | Lane_unowned
      (** No request owns it: another agent's broadcast, a system line. It
          shares the clock with a turn without being part of one, and drawing
          it inside the turn's boundary would say the keeper read it. *)
  | Lane_memory
      (** A memory journal commit. It carries no request either -- the store
          records when it was written, not which turn asked -- so its place is
          beside the turns rather than in one. *)

let chat_row_lane (row : msg_entry) =
  if row.me_role = Message_memory then Lane_memory
  else if String.equal row.me_request_id "" then Lane_unowned
  else Lane_turn row.me_request_id

(* Where a row sits in its turn, for a renderer drawing the turn's edges. *)
type turn_edge =
  | Turn_opens
  | Turn_continues
  | Turn_closes
  | Turn_alone  (** A turn of one row: it opens and closes on the same line. *)
  | Turn_outside  (** Belongs to no turn; nothing to open or close. *)

(* A turn opens once and closes once even when its rows are not adjacent.

   Rows of one request can be separated by a broadcast that arrived mid-turn,
   and comparing each row with its neighbour would then close the turn and
   reopen it around the interruption -- drawing two turns where the keeper took
   one. The edges are the request's first and last row in this list, not the
   gaps between neighbours. *)
(* A bracket says everything between the corners is one turn, and the pane has
   one column to say it in. So a turn can only be bracketed over rows that sit
   together.

   This used to take each request's first and last row anywhere in the list.
   When two turns interleaved, both drew their corners into the same column and
   the claims crossed: on a live pane three [Rail_opens] arrived before any
   close, and the first turn's bracket ran thirty-one minutes past a date
   divider with three other turns' rows inside it. Nothing was left to say
   which turn a [Rail_says] belonged to.

   Rows outside every turn stay transparent. A journal commit or somebody
   else's broadcast draws a siding meeting the line rather than a piece of it,
   so a turn's rows are still together across one -- that is increment 2 of
   RFC-chat-turn-rail-and-side-lanes, and it is why the interruption cases
   below keep one bracket rather than three.

   What this gives up: two rows of one turn, split by another turn's row, now
   draw as two lone rows rather than one bracket. That much is what the column
   can carry -- they are not adjacent, and a corner pair around them would be
   claiming otherwise. *)
let mark_turn_edges rows =
  let edges = Hashtbl.create 16 in
  let close_run = function
    | [] -> ()
    | [ only ] -> Hashtbl.replace edges only Turn_alone
    | opens_at :: rest ->
        Hashtbl.replace edges opens_at Turn_opens;
        let rec mark = function
          | [] -> ()
          | [ closes_at ] -> Hashtbl.replace edges closes_at Turn_closes
          | index :: tl ->
              Hashtbl.replace edges index Turn_continues;
              mark tl
        in
        mark rest
  in
  (* [run] holds the rows of the turn being walked, newest first. *)
  let rec walk running run = function
    | [] -> close_run (List.rev run)
    | (index, row) :: tl -> (
        match chat_row_lane row with
        | Lane_unowned | Lane_memory -> walk running run tl
        | Lane_turn request_id ->
            if
              match running with
              | Some current -> String.equal current request_id
              | None -> false
            then walk running (index :: run) tl
            else (
              close_run (List.rev run);
              walk (Some request_id) [ index ] tl))
  in
  walk None [] (List.mapi (fun index row -> (index, row)) rows);
  List.mapi
    (fun index row ->
      ( row
      , match Hashtbl.find_opt edges index with
        | Some edge -> edge
        | None -> Turn_outside ))
    rows
;;

let chat_timeline_rows timeline =
  let turn_rows turn =
    List.combine turn.ct_rows (chat_projected_timeline_ats turn.ct_rows)
    |> List.map (fun (row, projected_at) ->
      { pcr_row = row
      ; pcr_at = projected_at
      ; pcr_turn_sequence = turn.ct_turn_sequence
      ; pcr_lane_rank = 0
      ; pcr_request_id = turn.ct_request_id
      })
  in
  let rows_of_item = function
    | Chat_turn turn -> turn_rows turn
    | Chat_unowned row ->
        [ { pcr_row = row
          ; pcr_at = message_display_at row
          ; pcr_turn_sequence = row.me_turn_sequence
          ; pcr_lane_rank = 1
          ; pcr_request_id = ""
          }
        ]
    | Chat_memory row ->
        [ { pcr_row = row
          ; pcr_at = message_display_at row
          ; pcr_turn_sequence = row.me_turn_sequence
          ; pcr_lane_rank = 2
          ; pcr_request_id = ""
          }
        ]
  in
  List.concat (List.map rows_of_item timeline.ctl_items)
  |> List.stable_sort compare_projected_chat_rows
  |> List.map (fun projected -> projected.pcr_row)
;;

let chat_request_timeline_at ~request_id messages =
  let request_rows =
    List.filter
      (fun (message : msg_entry) ->
        String.equal message.me_request_id request_id)
      messages
  in
  match List.rev (chat_projected_timeline_ats request_rows) with
  | [] -> None
  | at :: _ -> at
;;

let chat_live_timeline_at ~request_id ~started_at ~request_messages
    positioned_messages =
  match chat_request_timeline_at ~request_id request_messages with
  | Some _ as at -> at
  | None ->
      let valid at = Float.is_finite at && at > 0. in
      let started_at = if valid started_at then Some started_at else None in
      let has_committed_request =
        List.exists
          (fun (message : msg_entry) ->
            String.equal message.me_request_id request_id)
          request_messages
      in
      if not has_committed_request
      then started_at
      else
        List.fold_left
          (fun latest (_, at) ->
            match latest, at with
            | None, at -> at
            | at, None -> at
            | Some latest, Some at -> Some (Float.max latest at))
          started_at positioned_messages
;;

(* Where a live turn with no committed row belongs in an already projected
   message list. The visible clock is the authority, so an auxiliary row may
   sit between committed rows from one request. A live turn has no persisted
   sequence yet; an exact clock tie precedes unowned/Journal rows. Callers that
   already hold committed rows for this request insert after its latest causal
   frontier instead. *)
let chat_block_insertion_index ~bounds ~request_id ~timeline_at
    positioned_messages =
  let lower_bound =
    List.fold_left
      (fun (index, lower_bound) ((row : msg_entry), _) ->
        ( index + 1
        , if String.equal row.me_request_id request_id && bounds row
          then index + 1
          else lower_bound ))
      (0, 0) positioned_messages
    |> snd
  in
  let live_precedes ((row : msg_entry), row_at) =
    match timeline_at, row_at with
    | Some live_at, Some row_at ->
        let by_time = Float.compare live_at row_at in
        if by_time <> 0
        then by_time < 0
        else row.me_role = Message_memory || String.equal row.me_request_id ""
    | Some _, None -> true
    | None, Some _ -> false
    | None, None ->
        row.me_role = Message_memory || String.equal row.me_request_id ""
  in
  let rec find index = function
    | [] -> index
    | positioned :: rest ->
        if index >= lower_bound && live_precedes positioned
        then index
        else find (index + 1) rest
  in
  find 0 positioned_messages
;;

let chat_live_insertion_index ~request_id ~timeline_at positioned_messages =
  chat_block_insertion_index ~bounds:(fun _ -> true) ~request_id ~timeline_at
    positioned_messages
;;

(* A settled block holds the turn's progress, tools and words; the request's
   output rows that stay committed -- a failure the strict decode wrote, a
   local line -- came after all of that, so the block goes after the request's
   last row of any earlier phase and before its output rows. Bounding on every
   row put a failed turn's words under its own error and under whatever turns
   ran in between. *)
let chat_settled_insertion_index ~request_id ~timeline_at positioned_messages =
  chat_block_insertion_index
    ~bounds:(fun row -> row.me_turn_phase <> Turn_output)
    ~request_id ~timeline_at positioned_messages
;;

let msg_anchor entry =
  { ma_identity = entry.me_identity
  ; ma_session_user_slot =
      (match entry.me_identity, entry.me_role with
       | Session_row { request_id; turn_phase; operation_seq }, Message_user _ ->
           Some (request_id, turn_phase, operation_seq)
       | (Persisted_row _ | Persisted_legacy_row _), Message_user _ -> None
       | (Persisted_row _ | Persisted_legacy_row _ | Session_row _),
         (Message_keeper | Message_autonomous | Message_status | Message_local
         | Message_error | Message_tool | Message_skill _ | Message_thinking
         | Message_memory) ->
           None)
  }

let same_msg_anchor anchor entry =
  anchor.ma_identity = entry.me_identity
  ||
  match anchor.ma_session_user_slot, entry.me_role with
  | Some (request_id, turn_phase, operation_seq), Message_user _ ->
      String.equal request_id entry.me_request_id
      && turn_phase = entry.me_turn_phase
      && Int.equal operation_seq entry.me_operation_seq
  | Some _,
    (Message_keeper | Message_autonomous | Message_status | Message_local
    | Message_error | Message_tool | Message_skill _ | Message_thinking
    | Message_memory)
  | None, _ ->
      false

let msg_index_of_anchor entries anchor =
  List.find_mapi
    (fun index entry ->
       if same_msg_anchor anchor entry then Some index else None)
    entries
;;

let msg_entries_after_anchor entries anchor =
  let rec walk found reversed_after = function
    | [] -> if found then Some (List.rev reversed_after) else None
    | entry :: rest ->
        if same_msg_anchor anchor entry
        then walk true [] rest
        else if found
        then walk true (entry :: reversed_after) rest
        else walk false reversed_after rest
  in
  walk false [] entries
;;



(** Attention item for the Overview surface *)
type attention_severity =
  | Attention_critical
  | Attention_bad
  | Attention_warning
  | Attention_info

type attention_item = {
  ai_kind: string;
  ai_severity: attention_severity;
  ai_summary: string;
  ai_target_type: string;
  ai_target_id: string option;
  ai_evidence_ts: float option;
      (** Epoch seconds of the evidence's [log_ts], when the producer stamped
          one (tool-host failures do). The row's age is drawn from it; items
          whose producers stamp no time (a paused keeper, a waiting
          confirmation) carry [None] and show no age. *)
}

(** Who put a post on the board. Mirrors [Board_types.post_kind]: the wire
    strings are ["direct"], ["automation"] and ["system"].

    Worth a column because of the ratio. On this workspace's 2171 posts:
    1561 system, 588 automation, and 22 that a person wrote. Without the
    distinction those 22 are buried in the other 2149 and the board reads as
    machine noise. *)
type board_post_kind =
  | Post_by_person
  | Post_by_automation
  | Post_by_system
  | Post_kind_unknown of string
      (** A kind this build was not taught. Named rather than folded into
          one of the others, so a new kind shows as unfamiliar instead of
          quietly becoming "system". *)

(** Board post (light projection for list view) *)
type board_post = {
  bp_id: string;
  bp_author: string;
  bp_title: string;
  bp_body: string;
  bp_votes: int;
  bp_comment_count: int;
  bp_created_at: string;
  bp_updated_at: float;
      (** Unix seconds of the last move on the post or its comments. The server
          has always sent it; the list drew neither timestamp, so the one
          question a board answers -- what is still alive -- had no column, and
          two of the sort orders ([recent], [updated]) ranked by a number the
          reader could not see. *)
  bp_hearth: string option;
      (** The sub-board it lives in. 24 of them here, and 1550 of 2171 posts
          sit in [verification] alone — a flat list is 71% one topic with
          nothing saying so. *)
  bp_kind: board_post_kind option;
      (** [None] when the row did not say. Not folded into a kind: "the post
          did not state one" and "the post is a system post" are different
          facts, and only one of them is a claim about who wrote it. *)
}

(** Board comment *)
type board_comment = {
  bc_id: string;
  bc_parent_id: string option;
      (** The comment this one answers, when it answers one. The store and the
          wire have carried it since comments existed; the pane decoded a flat
          list, so a reply and the thing it replied to sat at the same
          indent and a thread read as unrelated remarks in clock order. *)
  bc_author: string;
  bc_content: string;
  bc_created_at: string;
}

(** One scheduled-automation row, from the dashboard schedule projection.
    [sch_status] stays a string rather than a variant: the pane projects the
    store's own status vocabulary, and a status this build does not name
    renders as itself rather than disappearing. *)
type schedule_row = {
  sch_schedule_id: string;
  sch_schedule_instance_id: string;
  sch_status: string;
  sch_source: string;
  sch_requested_by: string;
  sch_scheduled_by: string;
  sch_requested_at_iso: string;
  sch_due_at_iso: string option;
  sch_next_due_at_iso: string option;
  sch_expires_at_iso: string option;
  sch_recurrence_summary: string;
  sch_recurrence: Yojson.Safe.t;
  sch_payload_digest: string;
  sch_payload: Yojson.Safe.t;
  sch_payload_kind: string option;
  sch_payload_support: string;
  sch_payload_dispatch_tool: string option;
  sch_payload_target: string option;
  sch_payload_summary: string option;
  sch_last_wake_status: string option;
  sch_last_wake_started_at_iso: string option;
  sch_last_wake_error: string option;
  sch_queue_projection_status: string option;
  sch_queue_pending_count: int option;
  sch_reaction_projection_status: string option;
  sch_reaction_latest_at_iso: string option;
  sch_reaction_kind: string option;
  sch_reaction_keeper_name: string option;
  sch_reaction_stimulus_id: string option;
  sch_reaction_post_id: string option;
  sch_reaction_reason: string option;
  sch_wake_seen: bool option;
      (** Whether the woken Keeper's ledger recorded the stimulus arriving.
          [None] is "the ledger did not say", which is not [Some false] --
          only one of those means something went wrong. Same for the three
          below. *)
  sch_turn_started: bool option;
      (** Whether a turn actually began. This is the field that separates a
          wake that was delivered from one that was acted on; the pane had
          only [sch_reaction_projection_status], a single word for all four
          of these at once. *)
  sch_turn_finished: bool option;
      (** Whether the turn the wake opened reached its boundary. A wake that
          started a turn and one whose turn finished are different facts, and
          the pane said only the first until the ledger recorded the second. *)
  sch_queue_ack_seen: bool option;
  sch_wake_cancelled: bool option;
  sch_stimulus_recorded_at_iso: string option;
  sch_turn_started_recorded_at_iso: string option;
  sch_turn_finished_recorded_at_iso: string option;
  sch_queue_ack_recorded_at_iso: string option;
  sch_wake_cancelled_recorded_at_iso: string option;
  sch_reaction_quarantined: int option;
      (** Ledger records the projection could not match. Nonzero is why a
          status reads worse than the steps below it look. *)
}

let schedule_json_string field = function
  | `Assoc fields ->
      (match List.assoc_opt field fields with
       | Some (`String value) -> value
       | Some _ | None -> "")
  | _ -> ""

let schedule_json_int field = function
  | `Assoc fields ->
      (match List.assoc_opt field fields with
       | Some (`Int value) -> Some value
       | Some _ | None -> None)
  | _ -> None

let schedule_payload_body = function
  | `Assoc fields ->
      (match List.assoc_opt "body" fields with
       | Some (`Assoc _ as body) -> body
       | Some _ | None -> `Assoc [])
  | _ -> `Assoc []

let schedule_update_form_json (row : schedule_row) =
  let body = schedule_payload_body row.sch_payload in
  let recurrence_kind = schedule_json_string "kind" row.sch_recurrence in
  let int_or source fallback =
    Option.value ~default:fallback
      (schedule_json_int source row.sch_recurrence)
  in
  let string_or source fallback =
    let value = schedule_json_string source row.sch_recurrence in
    if String.trim value = "" then fallback else value
  in
  let recurrence_fields =
    [ "recurrence_interval_sec", `Int (int_or "interval_sec" 3600)
    ; "recurrence_hour", `Int (int_or "hour" 9)
    ; "recurrence_minute", `Int (int_or "minute" 0)
    ; "recurrence_second", `Int (int_or "second" 0)
    ; "recurrence_cron", `String (string_or "expression" "0 9 * * *")
    ; "recurrence_timezone",
      `String (string_or "timezone" "Asia/Seoul")
    ]
  in
  let expires =
    Option.bind row.sch_expires_at_iso Time_codec.parse_rfc3339_opt
    |> Option.fold ~none:[] ~some:(fun value -> [ "expires_at_unix", `Float value ])
  in
  `Assoc
    ([ "schedule_id", `String row.sch_schedule_id
     ; "keeper_name", `String (schedule_json_string "keeper_name" body)
     ; "message", `String (schedule_json_string "message" body)
     ; "title", `String (schedule_json_string "title" body)
     ; "urgency",
       `String
         (let value = schedule_json_string "urgency" body in
          if String.trim value = "" then "normal" else value)
     ; "due_at_iso", `String (Option.value ~default:"" row.sch_due_at_iso)
     ; "recurrence_kind", `String recurrence_kind
     ; "source", `String row.sch_source
     ; "allow_unregistered_keeper", `Bool false
     ]
     @ recurrence_fields @ expires)
  |> Yojson.Safe.pretty_to_string

let schedule_create_form_json () =
  `Assoc
    [ "schedule_id", `String ""
    ; "keeper_name", `String ""
    ; "message", `String ""
    ; "title", `String ""
    ; "urgency", `String "normal"
    ; "due_at_iso", `String ""
    ; "recurrence_kind", `String "one_shot"
    ; "recurrence_interval_sec", `Int 3600
    ; "recurrence_hour", `Int 9
    ; "recurrence_minute", `Int 0
    ; "recurrence_second", `Int 0
    ; "recurrence_cron", `String "0 9 * * *"
    ; "recurrence_timezone", `String "Asia/Seoul"
    ; "allow_unregistered_keeper", `Bool false
    ]
  |> Yojson.Safe.pretty_to_string

(** Schedule list snapshot. [scs_request_count] is [None] exactly when the
    store read failed -- the server reports that as [status = "unknown"]
    rather than an empty list, and the pane keeps the two facts apart the
    same way. *)
type schedule_snapshot = {
  scs_status: string;
  scs_read_error: string option;
  scs_request_count: int option;
  scs_truncated: bool;
  scs_next_due_iso: string option;
  scs_rows: schedule_row list;
}

(** One recorded wake attempt of a schedule instance. The list surface carries
    only the newest of these on its row; the whole list arrives from the exact
    schedule lookup. *)
type schedule_wake = {
  swk_status: string;
  swk_started_at_iso: string option;
  swk_finished_at_iso: string option;
  swk_error: string option;
}

(** The exact-lookup wake history for one schedule instance, newest first.
    [swh_retention_per_schedule] is the store's own ceiling on terminal wakes,
    which is what stops [swh_count] from reading as a complete history. *)
type schedule_wake_history = {
  swh_schedule_id: string;
  swh_wakes: schedule_wake list;
  swh_retention_per_schedule: int;
}

(** Board surface sub-mode *)
type board_mode =
  | Board_list
  | Board_read of string
  | Board_compose
      (** New-post draft. The first line of the draft is the title, the rest
          is the body -- the commit-message convention, so one buffer covers
          both fields and no second input mode is needed. Sending is a
          two-step arm, not a key: [esc] offers send-or-discard, so a stray
          Enter during writing cannot publish. *)

(** Shared horizontal pane vocabulary.  Every split surface stores one of
    these instead of inventing a bool or a surface-specific variant. *)
type pane_focus =
  | Left_pane
  | Right_pane

(** Runtime surface sub-mode. [Runtime_lanes] answers "what is each lane
    going to call, in what order" — the failover view. [Runtime_all] answers
    "what can this workspace call at all", which the lane view cannot: a
    runtime no lane names is absent from it entirely, and the roster is where
    an operator finds one to assign. Same snapshot, two questions. *)
(* The order a failover picker should offer runtimes in. What the lane needs
   is a candidate that fails independently of the ones it already has, so a
   different provider outranks a faster model from the same one: two slots on
   one provider go down together, which is the state this picker exists to
   fix. Blocked runtimes sink rather than disappear — a blocked id is a fact
   about the workspace an operator may be looking for, and hiding it answers
   "why is it not in the list" with silence. *)
let rank_runtime_for_lane ~(lane_providers : string list)
      ~(already : string list) (runtime : Tui_decode.runtime_option) =
  let open Tui_decode in
  ( (if List.exists (String.equal runtime.ro_id) already then 1 else 0)
  , (if not runtime.ro_dispatchable then 1 else 0)
  , (if List.exists (String.equal runtime.ro_provider) lane_providers then 1
     else 0)
  , runtime.ro_id )
;;

let runtimes_for_lane_picker ~(lane_providers : string list)
      ~(already : string list) (catalog : Tui_decode.runtime_option list) =
  List.stable_sort
    (fun a b ->
       compare
         (rank_runtime_for_lane ~lane_providers ~already a)
         (rank_runtime_for_lane ~lane_providers ~already b))
    catalog
;;

type runtime_mode =
  | Runtime_lanes
  | Runtime_all

(** Stable identity of the Runtime row opened for detail. The cursor is only a
    position and can move to another runtime after refresh; detail stays bound
    to the exact lane/runtime pair the operator opened. *)
type runtime_detail_target =
  | Runtime_lane_candidate of { lane_id : string; runtime_id : string }
  | Runtime_catalog_entry of { runtime_id : string }

type runtime_probe_annotation =
  | Runtime_probe_note of string
  | Runtime_probe_failure of string

let runtime_probe_status_label = function
  | Tui_decode.Runtime_provider_skipped_cli -> "CLI not probed"
  | Tui_decode.Runtime_provider_skipped_native_auth -> "ADC not probed"
  | status -> Tui_decode.runtime_provider_status_to_string status

let runtime_probe_annotation ~status detail =
  Option.map (fun detail ->
    match status with
    | Tui_decode.Runtime_provider_skipped_cli
    | Tui_decode.Runtime_provider_skipped_native_auth -> Runtime_probe_note detail
    | _ -> Runtime_probe_failure detail) detail

(** Planning surface sub-mode *)
type planning_mode =
  | Planning_list
  | Planning_detail of string

(** Lanes surface sub-mode. The overview lists standalone LLM lane rows;
    [Lanes_run_list] drills into one standalone
    lane's recent durable runs, and [Lanes_run_detail] reads one run's exact
    prompt/output or Verifier request/verdict/tool evidence. The lane id rides
    along so Left/Esc from a run returns to the list it came from. *)
type lanes_mode =
  | Lanes_overview
  | Lanes_run_list of string
  | Lanes_run_detail of string * string

(** One authority for the Fusion surface's list/detail state. The top-level
    [surface] only says Fusion is open; it does not repeat this mode. *)
type fusion_mode =
  | Fusion_list
  | Fusion_detail of string
  | Fusion_historical_detail of Tui_decode.fusion_historical_evidence

(** Actor-scoped pending confirmation from the exact operator projection. *)
type approval_item = Masc_tui_operator_projection.approval_item
  = {
  ap_token: string;
  ap_trace_id: string;
  ap_actor: string;
  ap_action_type: string;
  ap_target_type: string;
  ap_target_id: string option;
  ap_payload: Yojson.Safe.t;
  ap_delegated_tool: string;
  ap_created_at: string;
  ap_expires_at: string option;
  ap_summary: string;
}

type approval_snapshot = Masc_tui_operator_projection.approval_snapshot
  = {
  aps_items: approval_item list;
  aps_actor_filter: string option;
  aps_filter_active: bool;
  aps_visible_count: int;
  aps_total_count: int;
  aps_hidden_count: int;
}

type approval_decision = Masc_tui_operator_projection.approval_decision =
  | Confirm
  | Deny

type pending_approval_action = Masc_tui_operator_projection.pending_approval_action = {
  paa_token: string;
  paa_decision: approval_decision;
}

(* Browsing the questions and answering one are different keyboards. Naming
   the ask in the mode rather than reading it off a cursor means a list that
   refreshes underneath cannot silently move the answer to another question. *)
type ask_answer_mode =
  | Ask_browsing
  | Ask_answering of { aam_ask_id: string }

(* An answer being typed, for the questions a choice cannot answer. The slot
   is what the domain accepts a write through, and it names its own question,
   so an editor left open while the snapshot moves underneath still lands on
   the question it was opened for. *)
type ask_text_entry = {
  ate_slot: Masc_tui_ask_projection.free_text_slot;
  ate_text: string;
}

(** Overview snapshot from /api/v1/dashboard/briefing *)
type workspace_health =
  | Workspace_health_critical
  | Workspace_health_bad
  | Workspace_health_risk
  | Workspace_health_warning
  | Workspace_health_degraded
  | Workspace_health_initializing
  | Workspace_health_ok
  | Workspace_health_unknown

(** What the runtime event feed ([GET /mcp?sse_kind=observer]) is doing.
    The feed is opened once the server has answered a refresh and reopened
    on the refresh cadence after it closes, so an operator reads the same
    row for "no server yet" and "the stream dropped" -- with the reason. *)
type observer_status =
  | Observer_off  (** not opened: no server has answered yet *)
  | Observer_opening  (** initialize and subscribe in flight *)
  | Observer_live of {
      session_id : string;
      since : float;
      events : int;  (** frames received on this stream *)
    }
  | Observer_closed of {
      reason : string;
      at : float;
      events : int;  (** frames the stream delivered before it closed *)
    }

type observer_replay_status =
  | Observer_replay_unobserved
  | Observer_replay_scoped of Sse_wire.observer_handshake
  | Observer_replay_unavailable of string

let observer_replay_description = function
  | Observer_replay_unobserved -> "Replay: not negotiated"
  | Observer_replay_unavailable detail -> "Replay unavailable (live only): " ^ detail
  | Observer_replay_scoped { replay = Sse_wire.Fresh; _ } ->
      "Replay: live from connection; earlier history not loaded"
  | Observer_replay_scoped { replay = Sse_wire.Resumed; _ } ->
      "Replay: retained window resumed; history completeness unknown"
  | Observer_replay_scoped { replay = Sse_wire.Reset Sse_wire.Instance_changed; _ } ->
      "Replay reset: server instance changed; disconnected history not recovered"
  | Observer_replay_scoped { replay = Sse_wire.Reset Sse_wire.Unscoped_cursor; _ } ->
      "Replay reset: previous cursor had no instance; disconnected history not recovered"

(** One event off the feed, kept for the Acting surface. *)
(* How many feed events the TUI keeps. On the live runtime the feed ran at
   about four events a second, so this is a few minutes of scrollback; what
   falls off the end is counted in [acting_dropped], not lost in silence.

   That rate held while every event was something a keeper did. A chat stream
   sends one frame per token, so the two budgets below are separate: this one
   is spent only on events the Acting screen's [Actions] filter shows, and the
   stream frames, heartbeats and snapshots share the smaller one. Trimming by
   arrival alone let a single long reply spend all 1000 and leave the screen
   holding about a second. *)
let acting_retained_entries = 1000

(* Recent context for the [Everything] filter -- enough that the operator can
   see what is streaming without it costing the log its history. Roughly five
   screens at the row heights this TUI draws. *)
let acting_retained_quiet = 200

(** How many Keepers stand in each state the control plane names, counted off
    [keeper_briefs]. The briefing carries a liveness word per Keeper and the
    Overview row used to carry only their number, so a fleet with two Keepers
    that had stopped doing anything and one an operator had paused read the
    same as nine running ones.

    [klc_unreadable] counts rows whose word is missing or outside the
    vocabulary. They are not folded into any state: a Keeper whose liveness
    this build cannot name is a different fact from an idle one, and the row
    says so rather than picking the convenient neighbour. *)
type keeper_liveness_counts = {
  klc_active: int;
  klc_inactive: int;
  klc_offline: int;
  klc_idle: int;
  klc_paused: int;
  klc_unreadable: int;
}

type overview_snapshot = {
  ov_workspace_health: workspace_health;
  ov_cluster: string;
  ov_project: string;
  ov_keepers: int;  (** [keeper_briefs] the briefing carried *)
  ov_keeper_liveness: keeper_liveness_counts;
  ov_mcp_agents: int;  (** [agent_briefs]: MCP clients, not keepers *)
  ov_attention_items: attention_item list;
  ov_top_attention: attention_item option;
  ov_generated_at: string;
}

(** Planning projections from [Tui_decode], which owns the current wire
    contract and its behavioral decoder tests. *)
type system_log_snapshot = Tui_decode.system_log_snapshot
type system_log_entry = Tui_decode.system_log_entry

type planning_goal = Tui_decode.planning_goal
  = {
  pg_id: string;
  pg_title: string;
  pg_phase: Goal_phase.t;
  pg_priority: int;
  pg_due_date: string option;
  pg_metric: string option;
  pg_target_value: string option;
  pg_proof: Tui_decode.goal_proof;
  pg_last_review_note: string option;
  pg_last_review_at: string option;
  pg_created_at: string option;
  pg_updated_at: string option;
}

type planning_rollup = Tui_decode.planning_rollup
  = {
  pr_active: int;
  pr_verifying: int;
  pr_awaiting_confirmation: int;
  pr_done: int;
  pr_dropped: int;
}

type planning_backlog = Tui_decode.planning_backlog
  = {
  pb_todo: int;
  pb_claimed: int;
  pb_running: int;
  pb_done: int;
  pb_cancelled: int;
}

type fleet_safety = Tui_decode.fleet_safety
  = {
  fs_status: string;
  fs_blocker: string option;
  fs_operator_action_required: bool;
  fs_bootable_count: int;
  fs_running_count: int;
  fs_executable_count: int;
  fs_failing_count: int;
  fs_recovering_count: int;
  fs_paused_count: int;
  fs_target_reaction_capacity: int;
  fs_reaction_capacity_shortfall: int;
  fs_bootable_names: string list;
  fs_running_names: string list;
  fs_executable_names: string list;
  fs_active_task_owner_without_fiber_count: int;
  fs_completion_authority_pending_count: int;
}

type planning_goal_history = Tui_decode.planning_goal_history
  = {
  pgh_goal_id: string;
  pgh_title: string option;
  pgh_opened_at: string option;
  pgh_closed_at: string option;
  pgh_final_phase: string option;
  pgh_lifetime_hours: float option;
}

type planning_snapshot = Tui_decode.planning_snapshot
  = {
  pl_goals: planning_goal list;
  pl_rollup: planning_rollup;
  pl_backlog: planning_backlog;
  pl_goal_history: planning_goal_history list;
  pl_generated_at: string;
}

(* Which lifecycle slice the list shows. [Planning_filter_active] is the
   default: dropped goals from long ago are archive, not the working set, and
   a default that showed them read as clutter. *)
type planning_filter =
  | Planning_filter_all
  | Planning_filter_active
  | Planning_filter_completed
  | Planning_filter_dropped

let planning_filter_label = function
  | Planning_filter_all -> "all"
  | Planning_filter_active -> "active"
  | Planning_filter_completed -> "completed"
  | Planning_filter_dropped -> "dropped"

let planning_filter_explanation = function
  | Planning_filter_all -> "all phases"
  | Planning_filter_active -> "executing + verifying"
  | Planning_filter_completed -> "completed only"
  | Planning_filter_dropped -> "dropped only"
;;

let next_planning_filter = function
  | Planning_filter_all -> Planning_filter_active
  | Planning_filter_active -> Planning_filter_completed
  | Planning_filter_completed -> Planning_filter_dropped
  | Planning_filter_dropped -> Planning_filter_all

(* How the visible goals are ordered. [Planning_sort_phase_priority] keeps the
   historical lifecycle-then-priority grouping as the default. *)
type planning_sort =
  | Planning_sort_phase_priority
  | Planning_sort_updated
  | Planning_sort_due

let planning_sort_label = function
  | Planning_sort_phase_priority -> "phase/P1-P5"
  | Planning_sort_updated -> "updated"
  | Planning_sort_due -> "due"

let planning_sort_explanation = function
  | Planning_sort_phase_priority -> "phase order, then P1→P5"
  | Planning_sort_updated -> "most recently updated first"
  | Planning_sort_due -> "earliest due date first; undated last"
;;

let next_planning_sort = function
  | Planning_sort_phase_priority -> Planning_sort_updated
  | Planning_sort_updated -> Planning_sort_due
  | Planning_sort_due -> Planning_sort_phase_priority

let planning_passes_filter filter (goal : planning_goal) =
  match filter, goal.pg_phase with
  | Planning_filter_all, _ -> true
  | Planning_filter_active, (Goal_phase.Executing | Goal_phase.Verifying | Goal_phase.Awaiting_confirmation) -> true
  | Planning_filter_completed, Goal_phase.Completed -> true
  | Planning_filter_dropped, Goal_phase.Dropped -> true
  | Planning_filter_active, (Goal_phase.Completed | Goal_phase.Dropped)
  | Planning_filter_completed, (Goal_phase.Executing | Goal_phase.Verifying | Goal_phase.Awaiting_confirmation | Goal_phase.Dropped)
  | Planning_filter_dropped, (Goal_phase.Executing | Goal_phase.Verifying | Goal_phase.Awaiting_confirmation | Goal_phase.Completed) ->
      false

(* RFC 3339 timestamps and ISO dates compare lexicographically, so the sort
   keys stay strings; [None] always sorts last regardless of direction. *)
let planning_compare_updated_desc left right =
  match left, right with
  | Some left, Some right -> String.compare right left
  | Some _, None -> -1
  | None, Some _ -> 1
  | None, None -> 0

let planning_compare_due_asc left right =
  match left, right with
  | Some left, Some right -> String.compare left right
  | Some _, None -> -1
  | None, Some _ -> 1
  | None, None -> 0

(* Filter first, then sort: the sort only ever sees rows the reader asked
   for. Stable everywhere, so equal keys keep the server's newest-first
   order rather than inventing another timestamp contract in the TUI. *)
let planning_visible_goals ~filter ~sort (goals : planning_goal list)
    : planning_goal list =
  let phase_rank = function
    | Goal_phase.Executing -> 0
    | Goal_phase.Verifying -> 1
    | Goal_phase.Awaiting_confirmation -> 2
    | Goal_phase.Completed -> 3
    | Goal_phase.Dropped -> 4
  in
  let compare =
    match sort with
    | Planning_sort_phase_priority ->
        fun left right ->
          (match
             Int.compare (phase_rank left.pg_phase) (phase_rank right.pg_phase)
           with
           | 0 -> Int.compare left.pg_priority right.pg_priority
           | order -> order)
    | Planning_sort_updated ->
        fun left right ->
          planning_compare_updated_desc left.pg_updated_at right.pg_updated_at
    | Planning_sort_due ->
        fun left right ->
          planning_compare_due_asc left.pg_due_date right.pg_due_date
  in
  List.stable_sort compare (List.filter (planning_passes_filter filter) goals)

type board_sort =
  | Board_hot
  | Board_trending
  | Board_recent
  | Board_updated
  | Board_discussed

let board_sort_label = function
  | Board_hot -> "hot"
  | Board_trending -> "trending"
  | Board_recent -> "recent"
  | Board_updated -> "updated"
  | Board_discussed -> "discussed"

let board_sort_of_string = function
  | "hot" -> Some Board_hot
  | "trending" -> Some Board_trending
  | "recent" -> Some Board_recent
  | "updated" -> Some Board_updated
  | "discussed" -> Some Board_discussed
  | _ -> None

let board_sort_explanation = function
  | Board_hot -> "net votes first; newer breaks ties"
  | Board_trending -> "net votes / √age-hours"
  | Board_recent -> "newest post first"
  | Board_updated -> "latest changed first"
  | Board_discussed -> "most replies first; newer breaks ties"
;;

(** Sub-mode inside the Keepers surface *)
type keeper_mode =
  | Keeper_list
  | Keeper_detail
  | Keeper_logs
  | Keeper_calls
  | Keeper_message
  | Keeper_runtime_pick
      (** Choosing a runtime for the keeper under the roster cursor. *)

(** Which face the detail pane is showing. Tabs inside one panel, cycled
    with [ and ]: different views of the same selected keeper, exactly the
    case a tab earns (unrelated content would want its own surface). *)
type keeper_detail_tab =
  | Detail_info
  | Detail_sandbox
  | Detail_instructions
  | Detail_secrets
  | Detail_github
  | Detail_identity
  | Detail_channels
  | Detail_automation
  | Detail_runs

let keeper_detail_tabs =
  [ Detail_info; Detail_sandbox; Detail_instructions; Detail_secrets; Detail_github
  ; Detail_identity; Detail_channels; Detail_automation; Detail_runs ]

let keeper_detail_tab_label = function
  | Detail_info -> "Info"
  | Detail_sandbox -> "Sandbox"
  | Detail_instructions -> "Settings"
  | Detail_secrets -> "Secrets"
  | Detail_github -> "GitHub"
  | Detail_identity -> "Identity"
  | Detail_channels -> "Channels"
  | Detail_automation -> "Automation"
  | Detail_runs -> "Runs"

(** One line of the Identity tab. A declaration nobody can read is carried
    rather than dropped: an operator who came looking for a provider needs to
    see why it is not on offer, not a shorter list. *)
type identity_provider =
  | Identity_declared of
      { idp_id: string
      ; idp_label: string
      ; idp_tools: string list option
        (** What this service currently offers this Keeper, or [None] when it
            was never attached. An empty list is a third fact -- attached and
            offering nothing -- and reading it as "not attached" would tell an
            operator to consent again for no reason. *)
      ; idp_also_on: string list
        (** Which other Keepers hold this one. A Keeper attaches on its own
            account -- the client is shared, the token is not -- so this is
            the one question a single Keeper's tab cannot answer for itself,
            and answering it by opening each Keeper in turn is how an
            operator loses track of which account went where. *)
      ; idp_enabled: bool option
        (** The on/off switch on an attached row. [None] when the row is not
            attached or the switch store could not be read; the render must
            not show a guess for either. *)
      ; idp_switch_problem: string option
        (** Why the switch state is unknown, when it is. *)
      }
  | Identity_unreadable of { idp_id: string; idp_problem: string }

(** The providers a key can act on, in the order the screen numbers them.
    Both the renderer and the key handler read this, so the number an
    operator sees and the provider a keypress starts cannot drift apart. *)
(* Case-insensitive substring, read rather than rebuilt.

   This used to take a lowercase copy of the haystack and then a [String.sub]
   of it at every position it tried. The row search calls it once per row per
   keystroke, so on a twenty-thousand-line file a single keypress asked the
   allocator for the file again and then for a slice per character of it.

   Folding case per byte the way [String.lowercase_ascii] does -- ASCII A-Z
   and nothing else, so a UTF-8 continuation byte is left alone -- keeps the
   same answers without the copies. *)
let lowercase_byte c =
  if c >= 'A' && c <= 'Z' then Char.unsafe_chr (Char.code c + 32) else c

let lowercase_contains ~needle haystack =
  let n = String.length needle and h = String.length haystack in
  if n = 0 then true
  else if n > h then false
  else
    let rec matches_at i k =
      k >= n
      || Char.equal
           (lowercase_byte (String.unsafe_get haystack (i + k)))
           (lowercase_byte (String.unsafe_get needle k))
         && matches_at i (k + 1)
    in
    let rec at i = i + n <= h && (matches_at i 0 || at (i + 1)) in
    at 0

(** Whether a query names this provider.

    Both the label and the id, because they diverge and an operator knows
    whichever one they know: the screen says "Google Sheets" and the tool
    names say "googlesheets_". Matching one would make the other a query
    that finds nothing while the row is right there. *)
let identity_names ~query (id, label) =
  lowercase_contains ~needle:query label || lowercase_contains ~needle:query id

let identity_connectable ?(query = "") providers =
  List.filter_map
    (function
      | Identity_declared { idp_id; idp_label; _ } ->
        if identity_names ~query (idp_id, idp_label)
        then Some (idp_id, idp_label)
        else None
      | Identity_unreadable _ -> None)
    providers

(** The lines the Identity pane prints above the provider rows.

    Here rather than in the renderer because the key handler has to know how
    far down the pane a provider sits: it moves a cursor over
    [identity_connectable] and then scrolls the pane's lines so that row
    stays visible. A header written in the renderer and counted in the key
    handler is two numbers that drift the first time a line is added. *)
(** What one attempt answered, as pane rows.

    Built here rather than at each side because two places wrapping the same
    text at their own idea of the width would draw a different number of
    lines, and the key handler's idea of where the list starts would stop
    matching the renderer's.

    Wrapped, because the message that matters most is the long one: a
    provider that registers no client says what to make and where to put it,
    and a single truncated line is the half of that sentence an operator
    cannot act on. *)
(** Whether the pane's notice reports something that worked.

    One line reports both -- a refusal to start and an app recorded -- and
    without this they are drawn the same, so a save that succeeded arrives in
    the colour of a failure. *)
(** A pasted value flattened to one line, for a field that holds one.

    Control bytes become a space and runs of space collapse, because a scope
    list copied out of a browser arrives with the newlines that separated
    it and a secret carries the one that ended it.

    Deliberately not the terminal's own single-line helper. That one is for
    drawing untrusted text: it makes a newline visible by writing the four
    characters "\x0A" into the string. Used on input, those four characters
    were stored, sent to Slack as part of a scope name, and came back as
    "Invalid permissions requested".

    Bytes at or above 0x80 are left alone -- they are UTF-8, not control
    characters. *)
let identity_field_paste text =
  let out = Buffer.create (String.length text) in
  String.iter
    (fun c ->
      let code = Char.code c in
      if code < 0x20 || code = 0x7f then Buffer.add_char out ' '
      else Buffer.add_char out c)
    text;
  Buffer.contents out
  |> String.split_on_char ' '
  |> List.filter (fun part -> not (String.equal part ""))
  |> String.concat " "

type identity_notice_kind = Notice_ok | Notice_bad

let identity_notice ~cols detail =
  match detail with
  | None -> []
  | Some (kind, text) ->
    (* Two for this indent, two for the one the pane adds, four for the box
       around it. Wrapping wider than that is a line the frame truncates --
       which is the whole failure this exists to undo. *)
    List.map
      (fun line -> "  " ^ line)
      (Masc_tui_message_layout.wrap_words ~max_cells:(max 20 (cols - 8)) text)
    @
    (* Only on a refusal, and pointing at the key on this pane rather than at
       the dashboard: the form is here now. *)
    (match kind with
     | Notice_ok -> [ "" ]
     | Notice_bad ->
       [ "  A records an app for the row the cursor is on."; "" ])

(** The filter's own two rows: what was typed, and how much of the set is
    left. Built here for the same reason the notice is -- the key handler
    counts these to know where the list starts, and a count that disagreed
    with what is drawn would scroll the cursor to the wrong row. *)
let identity_filter_rows ~providers filter =
  match filter with
  | None -> []
  | Some typed ->
    [ Printf.sprintf "  /%s   %d of %d" typed
        (List.length (identity_connectable ~query:typed providers))
        (List.length (identity_connectable providers))
    ; ""
    ]

(* Each block above the list brings its own trailing blank, so two of them
   do not stack two blanks and none of them leaves the list flush against
   the hint.

   The sentence reads as a duplicate of the tab's own hint row -- [ ]:tab,
   arrows+enter:connect, T:toggle, A:app, /:filter, R:refresh -- and it was
   dropped on that ground, until a 150-column frame showed the hint row does
   not reach the screen at all: the row spends 79 cells on nine tab labels
   before the hint starts, so the title is cut inside "Automation" and the
   keys are never drawn. Until that row is fixed this sentence is the only
   place an operator can read them -- #35539. *)
let identity_preamble ~keeper ~notice =
  ("  Move with arrows, enter to connect " ^ keeper
   ^ ", A: custom app (Client ID), /: filter, R: refresh, T: toggle on/off.")
  :: "" :: notice

(** Which pane line the provider at [index] is drawn on.

    [notice] is what the preamble is carrying: a message about the attempt
    just made belongs where the operator is looking rather than below
    fifty-odd rows they would have to scroll past. It moves the list down,
    so the row a keypress scrolls to moves with it. *)
let identity_provider_line ~notice ~index =
  List.length (identity_preamble ~keeper:"" ~notice) + index

(** The cursor held inside the list it names. A cursor left behind by a
    shorter list answers from the last row rather than from one that is no
    longer there. *)
let identity_cursor_clamped ~query ~providers cursor =
  let count = List.length (identity_connectable ~query providers) in
  if count = 0 then 0 else max 0 (min cursor (count - 1))

(** The provider a keypress on the cursor would start, if any. *)
let identity_cursor_provider ~query ~providers cursor =
  List.nth_opt
    (identity_connectable ~query providers)
    (identity_cursor_clamped ~query ~providers cursor)

(** A login the operator has started but not finished: they have to open
    [ils_url] in a browser, and until they come back nothing has been
    written to the Keeper. *)
(** Which of the three fields is taking keys. Sequential rather than
    clickable: a terminal has no pointer, and tab-between-fields is a second
    idea to explain when enter-to-advance already reads as a form. *)
type identity_app_field = App_client_id | App_client_secret | App_scopes

type identity_app_form = {
  iaf_provider: string;
  iaf_label: string;
  iaf_field: identity_app_field;
  iaf_client_id: string;
  iaf_client_secret: string;
  iaf_scopes: string;
}

(** The form's rows. Built here with the notice and the filter rows so the
    key handler counts the same preamble the renderer draws. The secret is
    shown as dots: a terminal scrolls back, and a credential on screen is a
    credential in the scrollback. *)
let identity_app_form_rows form =
  match form with
  | None -> []
  | Some f ->
    let mark field = if f.iaf_field = field then ">" else " " in
    [ Printf.sprintf "  %s \xec\x95\xb1" f.iaf_label
    ; Printf.sprintf "  %s client id      %s" (mark App_client_id) f.iaf_client_id
    ; Printf.sprintf "  %s client secret  %s" (mark App_client_secret)
        (String.concat "" (List.init (String.length f.iaf_client_secret)
                             (fun _ -> "*")))
    ; Printf.sprintf "  %s scopes         %s" (mark App_scopes) f.iaf_scopes
    ; "  enter 다음 칸 · 마지막 칸에서 enter 저장 · esc 취소"
    ; ""
    ]

type identity_login_started = {
  ils_keeper: string;
  ils_provider: string;
      (** Which service, by id. The label is for a screen; matching on it
          would tie "this login landed" to a display string that a
          declaration is free to change. *)
  ils_label: string;
  ils_url: string;
}

(** Whether the login [login] started has landed: the service it was for now
    reports tools for this Keeper.

    This is what ends the tick's re-asking. A poll with no end condition is a
    poll that runs for the life of the process, so the condition is named
    here and tested rather than being a line inside the message handler. *)
let identity_login_landed ~providers ~login =
  List.exists
    (function
      | Identity_declared { idp_id; idp_tools = Some _; _ } ->
        String.equal idp_id login.ils_provider
      | Identity_declared _ | Identity_unreadable _ -> false)
    providers

(** Where [Esc] returns after the chat pane was opened. Keeping only the three
    legal destinations makes a new Keeper sub-view an explicit compiler error
    instead of silently becoming the detail view. *)
type keeper_chat_return =
  | Keeper_chat_return_list
  | Keeper_chat_return_detail
  | Keeper_chat_return_lanes

(** Where [Esc] returns after the Changes surface was opened. [f] opens it
    from the roster and from the detail, which name the same keeper through
    the same cursor, and only those two: a keeper mode would also admit the
    runtime picker and the chat pane, which are not places to land. *)
type changes_return =
  | Changes_return_list
  | Changes_return_detail
  | Changes_return_chat

(** Top-level TUI surface. *)

type surface =
  | Overview
  | Acting
  | Metrics
  | Keepers of keeper_mode
  | Memory
  | Lanes
  | Clients
  | Board
  | Approvals
  | Planning
  | Schedules
  | Verification
  | Harness
  | Fusion
  | Repositories
  | Code
  | Changes
  | Connectors
  | Runtime
  | Config
  | Resources
  | Tools
  | System_logs

type browser_lane_visibility =
  | Browser_lane_hidden
  | Browser_lane_shown of {
      return_surface : surface;
      return_search : string option;
      return_composer_focused : bool;
    }

(* The Tab cycle and the strip drawn above every surface share this order,
   so the strip cannot disagree with where Tab actually goes. Labels are the
   strip's spelling. Keepers stands for every keeper sub-mode; Planning owns
   its Goal view, the Task Review queue, and the Verdicts the judge recorded.
   Those two remain distinct internal surfaces because each has a different
   API and permission boundary, but neither is a second top-level
   destination. Verdicts is the far half of Task Review -- one lists what is
   waiting for a ruling and the other what was ruled -- and a top-level tab
   called "Harness" said neither. Fusion is a ring stop because a
   deliberation is a destination of its own: the run list is where fusion
   results are read, and before this stop it was reachable only through the
   palette or a deep link, so the surface existed but could not be found. *)
let surface_ring : (surface * string) list =
  [ (Overview, "Overview");
    (Acting, "Activity");
    (Keepers Keeper_list, "Keepers");
    (Memory, "Memory");
    (Approvals, "Approvals");
    (Board, "Board");
    (Planning, "Planning");
    (Fusion, "Fusion");
    (Repositories, "Workspace");
    (Config, "Config");
  ]

(* Ring position of the family a view belongs to. Keeper sub-modes collapse
   onto Keepers, Task Review and Verdicts collapse onto Planning, Changes
   collapses onto Keepers -- its rows are one keeper's file writes, chosen by
   the roster cursor, so it was never a destination of its own. Channels,
   Automation, and Runs are selected-Keeper detail tabs; standalone Lanes
   remain Runtime observation, and Code remains a Workspace child.
   Resources and Tools collapse onto Config: an MCP resource catalog and
   the tool catalog with its receipts and usage are both answers to "what
   is registered here", read rarely and never raced against. System logs
   collapse onto Activity (the Acting surface): tool calls settling and the
   server's own log lines are two readings of the same fleet timeline, and
   the ring stop that answers "what happened" is one. Metrics is a deep-dive
   telemetry surface that collapses onto Overview, off the Tab ring. *)
let surface_ring_index (view : surface) =
  let family =
    match view with
    | Keepers _ -> Keepers Keeper_list
    | Verification | Harness -> Planning
    | Changes | Connectors | Schedules -> Keepers Keeper_list
    | Runtime | Lanes | Clients -> Config
    | Code -> Repositories
    | Resources | Tools -> Config
    | System_logs -> Acting
    | Metrics -> Overview
    | v -> v
  in
  let rec find i = function
    | [] -> 0
    | (surface, _) :: rest -> if surface = family then i else find (i + 1) rest
  in
  find 0 surface_ring

(** What a surface needs loaded to draw itself.

    Declared per surface in one place rather than asked as a separate
    exhaustive match per datum: a surface added later answers every question
    at once, in a record the compiler makes it fill, instead of being spelled
    into one match per fetch and quietly defaulting to false in the one that
    was missed. *)
type surface_needs = {
  needs_transport : bool;
  needs_keeper_roster : bool;
  needs_fleet_safety : bool;
  needs_board : bool;
  needs_planning : bool;
  needs_system_logs : bool;
  needs_keeper_chat : bool;
  needs_operator_approvals : bool;
  needs_asks : bool;
}

let nothing =
  { needs_transport = false;
    needs_keeper_roster = false;
    needs_fleet_safety = false;
    needs_board = false;
    needs_planning = false;
    needs_system_logs = false;
    needs_keeper_chat = false;
    needs_operator_approvals = false;
    needs_asks = false;
  }

(* Each datum is read by the one surface that draws it, so a refresh spends a
   request and a decode on it only while that surface is open. The planning and
   system-log payloads are tens of kilobytes each, and fetching them behind
   every other surface cost that on every tick for rows nobody was looking at. *)
let surface_needs : surface -> surface_needs = function
  | Overview -> { nothing with needs_transport = true }
  (* Its rows come from the acting store and the keeper list, neither of which
     is fetched here. *)
  | Acting -> nothing
  (* Exhaustive over the sub-mode rather than [Keepers _]: the chat pane is
     the one that was missed. It loaded its history when it opened and never
     again, so a message that arrived while it was on screen only appeared
     after leaving and coming back. *)
  | Keepers (Keeper_list | Keeper_detail | Keeper_logs | Keeper_calls)
  (* The picker keeps the roster fresh for the same reason the list does: the
     keeper it is choosing for can leave the roster while it is open. Its
     catalogue has its own loader, fetched when the picker opens. *)
  | Keepers Keeper_runtime_pick ->
      { nothing with needs_keeper_roster = true; needs_fleet_safety = true }
  | Keepers Keeper_message ->
      { nothing with
        needs_keeper_roster = true
      ; needs_fleet_safety = true
      ; needs_keeper_chat = true
      }
  | Board -> { nothing with needs_board = true }
  | Planning -> { nothing with needs_planning = true }
  | System_logs -> { nothing with needs_system_logs = true }
  (* Approvals is where a human answers things, so the questions Keepers put
     to one belong on the same surface: an operator should not have to know
     that "may I run this" and "which way should I go" arrived through
     different machinery. *)
  | Approvals ->
      { nothing with needs_operator_approvals = true; needs_asks = true }
  | Metrics ->
      { nothing with needs_keeper_roster = true; needs_fleet_safety = true }
  | Memory | Lanes | Clients | Schedules | Verification | Harness | Fusion
  | Repositories | Code | Changes | Connectors | Runtime | Config | Resources
  | Tools ->
      nothing

let surface_needs_delta ~previous ~next =
  { needs_transport = next.needs_transport && not previous.needs_transport
  ; needs_keeper_roster =
      next.needs_keeper_roster && not previous.needs_keeper_roster
  ; needs_fleet_safety =
      next.needs_fleet_safety && not previous.needs_fleet_safety
  ; needs_board = next.needs_board && not previous.needs_board
  ; needs_planning = next.needs_planning && not previous.needs_planning
  ; needs_system_logs =
      next.needs_system_logs && not previous.needs_system_logs
  ; needs_keeper_chat =
      next.needs_keeper_chat && not previous.needs_keeper_chat
  ; needs_operator_approvals =
      next.needs_operator_approvals
      && not previous.needs_operator_approvals
  ; needs_asks = next.needs_asks && not previous.needs_asks
  }

let surface_needs_any needs = needs <> nothing

let full_refresh_needs ~scoped_refresh_inflight surface =
  if scoped_refresh_inflight then nothing else surface_needs surface

type full_refresh_intent = Cadence | Revalidate

type scoped_refresh_followup =
  | No_scoped_followup
  | Revalidate_after_scoped

let note_full_refresh_intent ~intent ~full_refresh_inflight
    ~scoped_refresh_inflight followup =
  match intent with
  | Revalidate when full_refresh_inflight || scoped_refresh_inflight ->
      Revalidate_after_scoped
  | Cadence | Revalidate -> followup

let take_scoped_refresh_followup ~full_refresh_inflight
    ~scoped_refresh_inflight = function
  | Revalidate_after_scoped
    when (not full_refresh_inflight) && not scoped_refresh_inflight ->
      (No_scoped_followup, true)
  | (No_scoped_followup | Revalidate_after_scoped) as followup ->
      (followup, false)

(** How far a surface's list can scroll, given the terminal's height.

    A bound belongs where the move happens, and the move is a keypress. The
    drawing used to work it out mid-frame and write the clamped value back
    into the state -- the same four lines copied once per surface -- so
    drawing a frame corrected the state it was drawing from. Declared here,
    the key handler and the drawing read one answer and the drawing only
    reads.

    [None] is a surface whose rows the state cannot count: its row count is
    built by the drawing, out of text the drawing formats. Those report the
    value they used as a {!clamped_scroll} beside the frame instead, so the
    drawing still does not write. *)
type scrolled = {
  sc_count : int;  (** rows of content the surface has *)
  sc_chrome : int;  (** rows it spends on its own frame *)
  sc_overflow_takes_row : bool;
      (** [true] when an overflow indicator is drawn from the remaining body
          instead of already being reserved in [sc_chrome]. *)
  sc_preview_keep : int option;
      (** rows the list keeps when the surface draws a preview under it, or
          [None] when the list has the whole body. A surface that adds a
          preview says so here: the keypress works its bound out from this,
          and a field the record demands cannot be forgotten the way a
          wildcard branch can. *)
}

(* These seven draw the same fixed frame around their content, and spend two
   more rows when a load error is on screen. A conditional overflow row is
   declared separately in [sc_overflow_takes_row]; a surface whose chrome
   moves has to move the typed layout in the same change. *)
let listing_chrome ~error = if Option.is_some error then 9 else 7
let lanes_listing_chrome ~load_error ~action_error =
  listing_chrome ~error:load_error + if Option.is_some action_error then 2 else 0

let runtime_listing_chrome ~error ~action_error ~picker_rows =
  listing_chrome ~error + 2
  + (if Option.is_some action_error then 2 else 0)
  + (match picker_rows with None -> 0 | Some count -> 2 + max 1 count)
let system_log_listing_chrome ~error = listing_chrome ~error + 1

(** Dashboard state *)
(* A request that has been POSTed and has not settled, with when it went out
   and the live transcript decoded from its stream. Both ride with the request
   rather than in structures keyed by id: Keepers can stream concurrently, and
   a single live slot lets the later stream replace the earlier one's tool
   rows. *)
(* One turn as its event log and the transcript that follows it (RFC-0412
   §3.3, stage 3a). The log is the record: every delta the stream or the
   journal delivered, keyed by journal seq. The transcript is its projection,
   kept in step by the two entry points, [turn_log_add] for a live frame and
   [turn_log_add_journaled] for a journal page, each folding a delta into
   the transcript exactly when the log accepted it -- so the transcript is
   always the fold of the log ([Masc_tui_keeper_chat_transcript.of_log], pinned
   by test), each delta folded at its arrival time rather than re-folded at
   every frame. A settled turn is the same value with its log committed; the
   pane draws it through the same projection it drew the live turn with. *)
type turn_log =
  { tl_log : Masc_tui_keeper_chat_log.t
  ; tl_transcript : Masc_tui_keeper_chat_transcript.t
  }

let turn_log_create ~keeper_name ~request_id ~started_at =
  { tl_log = Masc_tui_keeper_chat_log.create ~keeper_name ~request_id ~started_at
  ; tl_transcript =
      Masc_tui_keeper_chat_transcript.create ~keeper_name ~request_id ~started_at
  }
;;

(* The acceptance is the server taking the POST, not a fact about the turn:
   it never went through the bus, carries no seq, and comes again with every
   re-POST after a cut. The transcript reads it (it answers "why has this not
   started"); the log does not keep it, so a resend adds no entry and a log
   that heard nothing but the acceptance has nothing to draw. *)
let turn_log_add ~now turn_log ~seq (delta : Masc_tui_keeper_chat_live.delta) =
  match delta with
  | Masc_tui_keeper_chat_live.Accepted _ ->
      Masc_tui_keeper_chat_transcript.apply ~now turn_log.tl_transcript delta
  | Masc_tui_keeper_chat_live.Run_started | Masc_tui_keeper_chat_live.Text _
  | Masc_tui_keeper_chat_live.Thinking _ | Masc_tui_keeper_chat_live.Tool_started _
  | Masc_tui_keeper_chat_live.Tool_args _ | Masc_tui_keeper_chat_live.Tool_ended _
  | Masc_tui_keeper_chat_live.Tool_result _
  | Masc_tui_keeper_chat_live.Stream_protocol_error _
  | Masc_tui_keeper_chat_live.Approval_requested _
  | Masc_tui_keeper_chat_live.Approval_settled _ | Masc_tui_keeper_chat_live.Checkpoint
  | Masc_tui_keeper_chat_live.External_effect_completed
  | Masc_tui_keeper_chat_live.Reply_details _ | Masc_tui_keeper_chat_live.Run_failed _
  | Masc_tui_keeper_chat_live.Run_finished
  | Masc_tui_keeper_chat_live.Runtime_attempt_started _
  | Masc_tui_keeper_chat_live.Stream_model_started _
  | Masc_tui_keeper_chat_live.Undecodable _ ->
      if Masc_tui_keeper_chat_log.add turn_log.tl_log ~seq delta
      then Masc_tui_keeper_chat_transcript.apply ~now turn_log.tl_transcript delta
;;

(* A v2 journal page: the log's own fold ({!Masc_tui_keeper_chat_log.add_journaled})
   decides which lines are entries -- seq dedup, undrawn positions held --
   and the transcript follows exactly those, each at the line's own journal
   time, so a tool call in a reloaded turn keeps the start time it really
   had. A live frame goes through {!turn_log_add} instead, with the arrival
   clock in place of the journal's. *)
let turn_log_add_journaled turn_log
    (lines : Masc.Keeper_chat_event_log.journaled_event list) =
  List.iter
    (fun ((line : Masc.Keeper_chat_event_log.journaled_event), delta) ->
      Masc_tui_keeper_chat_transcript.apply ~now:line.ts turn_log.tl_transcript delta)
    (Masc_tui_keeper_chat_log.add_journaled turn_log.tl_log lines)
;;

let turn_log_keeper_name turn_log = Masc_tui_keeper_chat_log.keeper_name turn_log.tl_log
let turn_log_request_id turn_log = Masc_tui_keeper_chat_log.request_id turn_log.tl_log
let turn_log_started_at turn_log = Masc_tui_keeper_chat_log.started_at turn_log.tl_log

(* Which loaded turns a refresh fetches journals for: every operation the
   rows name, once, newest first by the earliest row of that operation, minus
   the turns this session already holds as logs (settled, or still streaming)
   and the ones the server has said it cannot serve. The rows are the bound:
   they are one /chat/history body, which the server cuts at the chat store's
   tail window ([Keeper_chat_store.load]), and only direct turns carry an
   [operation_id], so only they are candidates. Each turn is asked for on the
   load that names it -- a load runs when the chat opens, on a refresh key,
   when the keeper appends a turn and when one settles -- and once held it is
   not asked for again, so every load after the first asks only for what is
   new. The older-page path issues no journal reads, so a turn a load does
   not ask for is not rebuilt by anything else; that is why nothing here is
   cut short of the rows. The order is the order the reads run in (the
   launcher reads the targets one after another), so the turns nearest the
   bottom of the pane fill first. Pure, so the choice is testable without a
   server. *)
let journal_fetch_targets ~held ~unavailable
    (candidates : (string * float) list) =
  let earliest = Hashtbl.create 16 in
  List.iter
    (fun (operation_id, at) ->
      match Hashtbl.find_opt earliest operation_id with
      | Some seen when seen <= at -> ()
      | Some _ | None -> Hashtbl.replace earliest operation_id at)
    candidates;
  Hashtbl.fold (fun operation_id at acc -> (operation_id, at) :: acc) earliest []
  |> List.filter (fun (operation_id, _) ->
         not
           (List.exists (String.equal operation_id) held
           || List.exists (String.equal operation_id) unavailable))
  |> List.stable_sort (fun (id_a, at_a) (id_b, at_b) ->
         match Float.compare at_b at_a with
         | 0 -> String.compare id_a id_b
         | order -> order)
;;

(* A committed log stands for its turn once the stream told it how the turn
   ended: a failure, or a finish with the recorded reply. A finish without one
   is a cancelled turn (the server ends a cancelled stream with RUN_FINISHED
   and no KEEPER_REPLY_DETAILS), whose ending the log cannot draw; and a log
   that never heard the end -- the request went without a live view (no Eio
   clock), or the stream was cut and nothing replayed it -- holds part of the
   turn at most. In both the committed rows keep saying what the turn did. *)
let turn_log_holds_the_turn turn_log =
  Masc_tui_keeper_chat_log.committed turn_log.tl_log
  &&
  match Masc_tui_keeper_chat_transcript.phase turn_log.tl_transcript with
  | Masc_tui_keeper_chat_transcript.Stream_failed _ -> true
  | Masc_tui_keeper_chat_transcript.Stream_ended ->
      Option.is_some
        (Masc_tui_keeper_chat_transcript.reply turn_log.tl_transcript)
  | Masc_tui_keeper_chat_transcript.Waiting
  | Masc_tui_keeper_chat_transcript.Working ->
      false
;;

type inflight_phase =
  | Turn_streaming
  | Turn_reconciling

type inflight_origin =
  | Direct_submission
  | Promoted_queue of
      { submission_seq : int
      ; intent : Masc_tui_keeper_chat_queue.intent
      ; causal_parent_request_id : string option
      }

type inflight =
  { sent_request : Masc_tui_keeper_chat_projection.request
  ; submitted_at : float
  ; sent_at : float
  ; origin : inflight_origin
  ; mutable phase : inflight_phase
  ; log : turn_log
  }

(* Which workspace the Code surface reads. The workspace routes resolve each
   through its own query axis: a keeper's playground via [?keeper=] (where a
   Changes row's clone-relative path lives), a registered repository via
   [?repo_id=] (what a Repositories row names). *)
type code_workspace_scope =
  | Code_scope_project
  | Code_scope_keeper of string
  | Code_scope_repo of string

(* Scope and path together name one thing to fetch. The same relative path
   under two scopes is two different things -- two histories, two directory
   listings -- so a request and the reply that comes back for it are the same
   request only when both halves agree.

   The Code pane asks for a directory listing per scope change, and a reply
   that named only the directory was accepted under whichever scope was
   current when it landed. Switch scope while one is in flight at the same
   relative directory and the late reply overwrites the new scope's rows with
   the old scope's (#33946). *)
let code_scope_path_equal (left_scope, left_path) (right_scope, right_path) =
  left_scope = right_scope && String.equal left_path right_path
;;

(* One row of the file pane's history view. Git owns committed history;
   Keeper file changes are durable tool-call facts. They share only their
   timestamp and exact repository address, which is enough to sort a display
   timeline without claiming that an attempted write became a commit. *)
type code_history_entry =
  | Hist_commit of Tui_decode.git_log_row
  | Hist_keeper_change of Tui_decode.file_change

type code_history_listing = {
  chl_entries: code_history_entry list;
  chl_activity_note: string;
      (** Coverage or failure of the durable Keeper-change read. Git commits
          remain visible when this says unavailable. *)
}

(* Which list the Config surface is showing. A bool held two and could not
   hold a third. *)
type config_pane =
  | Config_runtime
  | Config_models
  | Config_params
  | Config_prompts
  | Config_presets
  | Config_themes
  | Config_voice
      (** What voice is actually doing, which runtime.toml alone does not say.
          The [voice] section is 60 lines into a 1,600-line file, and reading
          it answers what is declared rather than what loaded — a config that
          fails to parse looks identical to one that was never written. That
          distinction cost six days once. *)

(* Which section the Tools surface is showing. They used to be one scrolling
   list: five sections concatenated, and the first of them is the effective
   surface, which is one row per tool. At ninety-five tools that list ran to
   326 rows and a terminal draws about twenty, so the four sections behind it
   -- the async broker, skill activations, skill usage, the catalog -- began
   past row 120. Nothing on the screen said they were there.

   The same shape the Config surface already has, and for the same reason. *)
type tools_pane =
  | Tools_surface
  | Tools_async
  | Tools_activations
  | Tools_usage
  | Tools_catalog

type tools_read_part = Tools_inventory_read | Tools_catalog_read | Tools_async_read

type tools_read_inflight =
  { tri_generation : int
  ; tri_keeper : string option
  ; tri_pending : tools_read_part list
  }

type runtime_param_edit_mode = Friendly_value | Advanced_json

type runtime_param_edit =
  { rpe_key : string
  ; rpe_value_type : string
  ; rpe_draft : string
  ; rpe_replace_on_type : bool
  ; rpe_mode : runtime_param_edit_mode
  ; rpe_choices : string list
    (* Carried on the edit so the key handler can ask what this param accepts
       without holding the row it came from. Empty means the reader types the
       value. *)
  }

let runtime_param_type_name value_type =
  String.lowercase_ascii (String.trim value_type)

let runtime_param_value_text ~value_type json_text =
  let parsed =
    try Some (Yojson.Safe.from_string json_text) with
    | Yojson.Json_error _ -> None
  in
  match runtime_param_type_name value_type, parsed with
  | ("bool" | "boolean"), Some (`Bool true) -> "on"
  | ("bool" | "boolean"), Some (`Bool false) -> "off"
  | "string", Some (`String value) -> value
  | _, Some (`String value) -> value
  | _, Some _ | _, None -> json_text

let runtime_param_friendly_text (row : Tui_decode.runtime_param_row) =
  runtime_param_value_text ~value_type:row.rpr_value_type row.rpr_current_json

let runtime_param_edit_of_row ~advanced (row : Tui_decode.runtime_param_row) =
  { rpe_key = row.rpr_key
  ; rpe_value_type = row.rpr_value_type
  ; rpe_draft =
      (if advanced then row.rpr_current_json else runtime_param_friendly_text row)
  ; rpe_replace_on_type = true
  ; rpe_mode = (if advanced then Advanced_json else Friendly_value)
  ; rpe_choices = row.rpr_choices
  }

let runtime_param_edit_append edit text =
  { edit with
    rpe_draft =
      (if edit.rpe_replace_on_type then text else edit.rpe_draft ^ text)
  ; rpe_replace_on_type = false
  }

let runtime_param_edit_backspace edit =
  { edit with
    rpe_draft =
      (if edit.rpe_replace_on_type then ""
       else Masc_tui_message_layout.drop_last_utf8_scalar edit.rpe_draft)
  ; rpe_replace_on_type = false
  }

let runtime_param_edit_clear edit =
  { edit with rpe_draft = ""; rpe_replace_on_type = false }

let runtime_param_edit_toggle_bool edit =
  let next =
    match String.lowercase_ascii (String.trim edit.rpe_draft) with
    | "on" | "true" | "yes" | "1" -> "off"
    | _ -> "on"
  in
  { edit with rpe_draft = next; rpe_replace_on_type = false }

(* Walk a closed set. [step] is +1 or -1; a draft that is not one of the
   choices — a value typed by hand, or the parameterized form of a partly
   closed domain — starts the walk at the first choice rather than being
   silently kept, because the reader pressed a key asking for a different
   value. *)
let runtime_param_edit_cycle_choice edit ~step =
  match edit.rpe_choices with
  | [] -> edit
  | choices ->
    let count = List.length choices in
    let current = String.trim edit.rpe_draft in
    let index =
      let rec find i = function
        | [] -> None
        | c :: rest -> if String.equal c current then Some i else find (i + 1) rest
      in
      find 0 choices
    in
    let next =
      match index with
      | None -> 0
      | Some i -> ((i + step) mod count + count) mod count
    in
    { edit with rpe_draft = List.nth choices next; rpe_replace_on_type = false }

let runtime_param_edit_value edit =
  let parse_json () =
    try Ok (Yojson.Safe.from_string edit.rpe_draft) with
    | Yojson.Json_error detail -> Error ("Invalid JSON value: " ^ detail)
  in
  match edit.rpe_mode with
  | Advanced_json -> parse_json ()
  | Friendly_value ->
    (match runtime_param_type_name edit.rpe_value_type with
     | "bool" | "boolean" ->
       (match String.lowercase_ascii (String.trim edit.rpe_draft) with
        | "on" | "true" | "yes" | "1" -> Ok (`Bool true)
        | "off" | "false" | "no" | "0" -> Ok (`Bool false)
        | _ -> Error "Choose on or off")
     | "int" | "integer" ->
       (match int_of_string_opt (String.trim edit.rpe_draft) with
        | Some value -> Ok (`Int value)
        | None -> Error "Enter a whole number")
     | "float" | "number" ->
       (match float_of_string_opt (String.trim edit.rpe_draft) with
        | Some value when Float.is_finite value -> Ok (`Float value)
        | Some _ | None -> Error "Enter a number")
     | "string" -> Ok (`String edit.rpe_draft)
     | "enum" ->
       (* A named value is sent as-is: the registry owns the grammar, so a
          form this picker does not list (a parameterized one, typed by hand)
          must still reach it and be judged there rather than here. *)
       let value = String.trim edit.rpe_draft in
       if String.equal value "" then Error "Choose a value" else Ok (`String value)
     | _ -> parse_json ())

type memory_sort_order =
  | Sort_recency
  | Sort_last_retrieved
  | Sort_retrieved_count
  | Sort_category
  | Sort_claim

let memory_sort_order_label = function
  | Sort_recency -> "Recency (Newest)"
  | Sort_last_retrieved -> "Last retrieved (Newest)"
  | Sort_retrieved_count -> "Retrieved (Most)"
  | Sort_category -> "Category (A-Z)"
  | Sort_claim -> "Claim (A-Z)"

let next_memory_sort = function
  | Sort_recency -> Sort_last_retrieved
  | Sort_last_retrieved -> Sort_retrieved_count
  | Sort_retrieved_count -> Sort_category
  | Sort_category -> Sort_claim
  | Sort_claim -> Sort_recency

type memory_category_filter =
  | Category_all
  | Category_ordinary of string
  | Category_source
  | Category_dropped

let memory_category_filter_label = function
  | Category_all -> "All"
  | Category_ordinary cat -> cat
  | Category_source -> "source"
  | Category_dropped -> "dropped"

type memory_state =
  | Memory_ordinary
  | Memory_warning
  | Memory_degraded
  | Memory_no_current
  | Memory_source_only
  | Memory_starving
  | Memory_read_error

let memory_state (k : Tui_decode.memory_keeper_health) =
  if Option.is_some k.mkh_read_error || Option.is_some k.mkh_source_read_error
  then Memory_read_error
  else if
    (not k.mkh_snapshot_present)
    && k.mkh_librarian_failures > 0
    && not k.mkh_source_snapshot_present
  then Memory_starving
  else if (not k.mkh_snapshot_present) && k.mkh_source_snapshot_present
  then Memory_source_only
  else if not k.mkh_snapshot_present
  then Memory_no_current
  else if k.mkh_librarian_failures > 0
  then Memory_degraded
  else if
    List.exists
      (fun alert ->
        match Tui_decode.memory_alert_severity alert.Tui_decode.ma_code with
        | `Warn -> true
        | `Error -> false)
      k.mkh_alerts
  then Memory_warning
  else Memory_ordinary

let memory_state_label = function
  | Memory_ordinary -> "ok"
  | Memory_warning -> "warning"
  | Memory_degraded -> "degraded"
  | Memory_no_current -> "no-current"
  | Memory_source_only -> "source-only"
  | Memory_starving -> "STARVING"
  | Memory_read_error -> "read-error"

type memory_overview_sort =
  | Mem_overview_facts
  | Mem_overview_size
  | Mem_overview_delta
  | Mem_overview_state
  | Mem_overview_name
  | Mem_overview_updated

let memory_overview_sort_label = function
  | Mem_overview_facts -> "Facts (Most)"
  | Mem_overview_size -> "Size (Largest)"
  | Mem_overview_delta -> "Delta (Recent changes)"
  | Mem_overview_state -> "State (Attention first)"
  | Mem_overview_name -> "Name (A-Z)"
  | Mem_overview_updated -> "Updated (Newest first)"

let next_memory_overview_sort = function
  | Mem_overview_facts -> Mem_overview_size
  | Mem_overview_size -> Mem_overview_delta
  | Mem_overview_delta -> Mem_overview_state
  | Mem_overview_state -> Mem_overview_name
  | Mem_overview_name -> Mem_overview_updated
  | Mem_overview_updated -> Mem_overview_facts

type metrics_section =
  | Section_fleet
  | Section_resources
  | Section_tools

let next_metrics_section = function
  | Section_fleet -> Section_resources
  | Section_resources -> Section_tools
  | Section_tools -> Section_fleet

let prev_metrics_section = function
  | Section_fleet -> Section_tools
  | Section_resources -> Section_fleet
  | Section_tools -> Section_resources

let metrics_section_label = function
  | Section_fleet -> "Engine & Scheduler"
  | Section_resources -> "Work & Outcomes"
  | Section_tools -> "Memory & Gate Safety"

(* What the [:] palette is for right now. A jump lists every destination
   the strip and roster offer; a choice lists the names on the Code
   cursor line for one language-server question and nothing else -- a
   task whose title happens to spell h-o-v-e-r in order is not an answer
   to "which name?" (RFC-0429 §1.4). *)
type palette_mode =
  | Palette_jump
  | Palette_choice of {
      choice_question : string;  (* "hover", "definition", "references" *)
      choice_line : int;  (* 1-based, what the title says *)
    }

(* Browser reads remain separate from connector routing. A request generation
   belongs to this view instance, so late browser replies cannot replace a
   different source or tab after the operator moves. *)
module Browser_lane_view = struct
  type source = Live | Automation
  type browser = Firefox | Zen
  type client = { client_id : string; browser : browser }
  type discovery = Read_after_discovery | Choose_client
  type tab = { id : int; title : string; url : string; active : bool }
  type page = {
    tab_id : int; title : string; url : string; text : string;
    chars : int; truncated : bool;
  }
  type reading = {
    tabs : tab list; page : page option; source : source; client_id : string option;
    elapsed_ms : float;
  }
  type screenshot = {
    source : source; client_id : string option; tab_id : int; title : string; url : string;
    data : string; elapsed_ms : float; viewport : Browser_lane.Pointer.viewport;
  }
  type scene = { source : source; client_id : string option; tab_id : int;
    content : Masc.Browser_scene.t; elapsed_ms : float }
  type operation = Discover of discovery | Read | Open_session | Close_session | Goto of string | Screenshot of int
    | Read_refresh
    | Scene_read of int
    | Scene_regions of int
    | Scene_refresh of { tab_id : int; scene_view : Browser_lane.scene_view; scope : Browser_lane.node_ref option }
    | Scene_focus of { tab_id : int; target : Browser_lane.node_ref }
    | Scene_click of { tab_id : int; document_id : string; node_id : string; expected_url : string; scope : Browser_lane.node_ref option }
    | Viewport_refresh of { tab_id : int; expected_url : string }
    | Viewport_pointer of { tab_id : int; expected_url : string; action : Browser_lane.interaction }
  type load = Idle | No_browser | Loading of int * operation | Failed of string
  type read_continuation = No_read_continuation | Deferred_read
  type read_view = Text_view | Scene_view of {
    scene_view : Browser_lane.scene_view; scope : Browser_lane.node_ref option }
  type t = {
    clients : client list; selected_client : client option; client_picker : int option;
    source : source; selected_tab : int option; scroll : int;
    reading : reading option; load : load; url_draft : string option;
    scene : scene option; scene_cursor : int;
    read_view : read_view;
    refresh_pending : int option;
    read_continuation : read_continuation;
  }

  let source_name = function Live -> "live" | Automation -> "automation"
  let browser_name = function Firefox -> "Firefox" | Zen -> "Zen"
  let client_id t = match t.source, t.selected_client with
    | Live, Some client -> Some client.client_id
    | Live, None | Automation, _ -> None
  let browser_label t = match t.source, t.selected_client with
    | Automation, _ -> "browser"
    | Live, Some client -> browser_name client.browser
    | Live, None -> "choose browser"
  let context_label t =
    Printf.sprintf "Browser Lane · %s · %s page reader" (source_name t.source) (browser_label t)
  let create () =
    { clients = []; selected_client = None; client_picker = None;
      source = Live; selected_tab = None; scroll = 0;
      reading = None; load = Idle; url_draft = None; scene = None; scene_cursor = 0; read_view = Text_view; refresh_pending = None; read_continuation = No_read_continuation }
  let switch_source source _t = { (create ()) with source }
  let refresh t = { t with selected_tab = None; scroll = 0; scene = None; scene_cursor = 0; read_view = Text_view }
  let after_action t =
    { t with reading = None; scene = None; scene_cursor = 0;
      selected_tab = None; scroll = 0; load = Idle; read_continuation = No_read_continuation }
  let defer_read t = { t with read_continuation = Deferred_read }
  let pending_read t = match t.read_continuation with
    | No_read_continuation -> None | Deferred_read -> Some Read
  let fail_action detail t =
    let url_draft = match t.load with
      | Loading (_, Goto url) -> Some url
      | Loading _ | Idle | No_browser | Failed _ -> t.url_draft
    in
    { t with load = Failed detail; url_draft }
  let awaiting_browser t = match t.load with
    | No_browser -> true
    | Idle | Loading _ | Failed _ -> false
  type read_status = Unread | Reading | Operating | Read_ok | Read_failed | Browser_missing
  let read_status t =
    match t.load, t.reading with
    | No_browser, _ -> Browser_missing
    | Idle, None -> Unread
    | Idle, Some _ -> Read_ok
    | Loading (_, (Read | Read_refresh | Scene_read _ | Scene_regions _ | Scene_focus _ | Scene_refresh _)), _ -> Reading
    | Loading (_, (Discover _ | Open_session | Close_session | Goto _ | Screenshot _ | Scene_click _ | Viewport_refresh _ | Viewport_pointer _)), _ -> Operating
    | Failed _, _ -> Read_failed
  (* The badge in the Browser Lane title. Five of these six name the read the
     lane makes over HTTP, so the sixth -- the one for a browser that is not
     there at all -- is the only one that speaks of something else, and it
     says so.

     Read_failed used to read "Read/action failed", which did two things. It
     left the HTTP family its four siblings belong to, so the badge changed
     shape rather than value when a read failed. And the status line three
     rows down already opens "Read/action failed: " and then gives the
     detail, so the operator read the same phrase twice and only the second
     one told them anything. *)
  let read_status_label = function
    | Unread -> "HTTP unread"
    | Reading -> "HTTP reading"
    | Operating -> "HTTP action"
    | Read_ok -> "HTTP read ok"
    | Read_failed -> "HTTP failed"
    | Browser_missing -> "Browser not connected"
  let busy t = match t.load with Loading _ -> true | Idle | No_browser | Failed _ -> false
  let request_body t =
    `Assoc ([ "lane", `String (source_name t.source) ]
            @ (match client_id t with None -> [] | Some id -> ["clientId", `String id])
            @ (match t.selected_tab with None -> [] | Some id -> ["tabId", `Int id]))
  let selected_client_available t = match t.source, t.selected_client with
    | Automation, _ -> true
    | Live, None -> false
    | Live, Some selected -> List.exists (fun (client : client) -> client = selected) t.clients
  let cadence_operation t =
    if busy t || Option.is_some t.refresh_pending || Option.is_some t.client_picker || Option.is_some t.url_draft
       || not (selected_client_available t) then None
    else match t.selected_tab, t.read_view with
      | None, _ -> None
      | Some tab_id, Scene_view {scene_view;scope} ->
          Some (Scene_refresh {tab_id;scene_view;scope})
      | Some _, Text_view -> Some Read_refresh
  let yield_refresh_to_input t =
    match t.load with
    | Loading (_, (Read_refresh | Scene_refresh _)) -> {t with load = Idle}
    | Loading _ | Idle | No_browser | Failed _ -> t
  let read_view_for_operation operation previous =
    match operation with
    | Read | Read_refresh | Open_session | Close_session | Goto _ -> Text_view
    | Scene_read _ -> Scene_view {scene_view = Browser_lane.Content; scope = None}
    | Scene_regions _ -> Scene_view {scene_view = Browser_lane.Regions; scope = None}
    | Scene_focus {target;_} -> Scene_view {scene_view = Browser_lane.Content; scope = Some target}
    | Scene_click {scope;_} -> Scene_view {scene_view = Browser_lane.Content; scope}
    | Scene_refresh {scene_view;scope;_} -> Scene_view {scene_view;scope}
    | Discover _ | Screenshot _ | Viewport_refresh _ | Viewport_pointer _ -> previous
  let choose_client client t =
    { t with selected_client = Some client; selected_tab = None;
      reading = None; scene = None; scene_cursor = 0; scroll = 0; load = Idle; client_picker = None; read_view = Text_view }
  let accept_clients ~generation result t =
    match t.load with
    | Loading (current, Discover purpose) when current = generation ->
        (match result with
         | Error detail -> { t with clients = []; selected_tab = None; reading = None; scene = None; scene_cursor = 0;
             scroll = 0; client_picker = Some 0; load = Failed detail }, false
         | Ok clients ->
             let next = { t with clients; load = Idle } in
             match t.selected_client, clients, purpose with
             | None, [client], Read_after_discovery -> choose_client client next, true
             | Some _, _, _ when selected_client_available next ->
                 { next with client_picker = (match purpose with Choose_client -> Some 0 | Read_after_discovery -> None) },
                 purpose = Read_after_discovery
             | _, _, _ ->
                 let load = match t.selected_client, clients with
                   | _, [] -> No_browser
                   | Some _, _ -> Failed "Selected browser disconnected; b:choose browser"
                   | None, _ -> Idle
                 in
                 { next with selected_tab = None; reading = None; scene = None; scene_cursor = 0; scroll = 0;
                   client_picker = Some 0; load }, false)
    | Loading _ | Idle | No_browser | Failed _ -> t, false
  let ( let* ) = Result.bind
  let field name = function
    | `Assoc fields -> (match List.assoc_opt name fields with
        | Some value -> Ok value | None -> Error ("missing " ^ name))
    | _ -> Error "expected object"
  let string = function `String s -> Ok s | _ -> Error "expected string"
  let integer = function `Int n when n >= 0 -> Ok n | _ -> Error "expected nonnegative integer"
  let boolean = function `Bool b -> Ok b | _ -> Error "expected boolean"
  let parse_source = function
    | `String "live" -> Ok Live | `String "automation" -> Ok Automation
    | _ -> Error "unknown browser source"
  let get parse name json = let* value = field name json in parse value
  let parse_client json =
    let* client_id = get string "clientId" json in
    let* browser = get (function
      | `String "firefox" -> Ok Firefox | `String "zen" -> Ok Zen
      | _ -> Error "unknown native browser") "browser" json in
    if String.trim client_id = "" then Error "empty browser client ID"
    else Ok { client_id; browser }
  let decode_clients json =
    let* ok = get boolean "ok" json in
    if not ok then let* detail = get string "error" json in Error detail
    else
      let* data = field "data" json in
      let* clients = field "clients" data in
      match clients with
      | `List rows ->
          let rec loop acc = function
            | [] -> Ok (List.rev acc)
            | row :: rest ->
                let* client = parse_client row in
                if List.exists (fun (old : client) -> old.client_id = client.client_id) acc
                then Error "duplicate browser client ID"
                else loop (client :: acc) rest
          in loop [] rows
      | _ -> Error "expected browser clients array"
  let parse_client_id source json =
    let* value = field "clientId" json in
    match source, value with
    | Live, `String id when String.trim id <> "" -> Ok (Some id)
    | Automation, `Null -> Ok None
    | _ -> Error "browser client ID does not match source"
  let parse_tab json =
    let* id = get integer "id" json in
    let* title = get string "title" json in
    let* url = get string "url" json in
    let* active = get boolean "active" json in
    Ok { id; title; url; active }
  let parse_page = function
    | `Null -> Ok None
    | json ->
        let* tab_id = get integer "tabId" json in
        let* title = get string "title" json in
        let* url = get string "url" json in
        let* text = get string "text" json in
        let* chars = get integer "chars" json in
        let* truncated = get boolean "truncated" json in
        Ok (Some { tab_id; title; url; text; chars; truncated })
  let parse_tabs = function
    | `List tabs ->
        let rec loop acc = function
          | [] -> Ok (List.rev acc)
          | json :: rest -> let* tab = parse_tab json in loop (tab :: acc) rest
        in loop [] tabs
    | _ -> Error "expected tabs array"
  let milliseconds = function
    | `Float f when Float.is_finite f && f >= 0. -> Ok f
    | `Int n when n >= 0 -> Ok (float_of_int n)
    | _ -> Error "expected nonnegative elapsed_ms"
  let decode json =
    let* ok = get boolean "ok" json in
    if not ok then let* detail = get string "error" json in Error detail
    else
      let* data = field "data" json in
      let* tabs = get parse_tabs "tabs" data in
      let* page = get parse_page "page" data in
      let* source = get parse_source "source" data in
      let* client_id = parse_client_id source data in
      let* elapsed_ms = get milliseconds "elapsed_ms" data in
      match page with
      | Some page when not (List.exists (fun (tab : tab) -> tab.id = page.tab_id) tabs) ->
          Error "page tab is absent from returned tabs"
      | _ -> Ok { tabs; page; source; client_id; elapsed_ms }
  let decode_screenshot json =
    let* ok = get boolean "ok" json in
    if not ok then let* detail = get string "error" json in Error detail
    else
      let* value = field "data" json in
      let* source = get parse_source "source" value in
      let* client_id = parse_client_id source value in
      let* tab_id = get integer "tabId" value in
      let* title = get string "title" value in
      let* url = get string "url" value in
      let* mime = get string "mimeType" value in
      let* data = get string "data" value in
      let* viewport = get Browser_lane.Pointer.viewport_of_json "viewport" value in
      let* elapsed_ms = get milliseconds "elapsed_ms" value in
      if mime <> "image/png" || data = "" then Error "browser screenshot must contain PNG data"
      else Ok { source; client_id; tab_id; title; url; data; elapsed_ms; viewport }

  let decode_scene json =
    let* ok = get boolean "ok" json in
    if not ok then let* detail = get string "error" json in Error detail
    else
      let* data = field "data" json in
      let* source = get parse_source "source" data in
      let* client_id = parse_client_id source data in
      let* tab_id = get integer "tabId" data in
      let* elapsed_ms = get milliseconds "elapsed_ms" data in
      let* content = Masc.Browser_scene.of_json data in
      Ok {source;client_id;tab_id;content;elapsed_ms}

  (* Deduplicate through a table rather than [List.mem] over what has been
     seen. A scene carries up to 200 nodes (browser_scene_script.ml's
     nodeLimit), and the membership walk made this quadratic in a function
     the page projection then called once per node. *)
  let scene_targets t = match t.scene with
    | None -> []
    | Some scene ->
        let seen = Hashtbl.create 64 in
        List.filter
          (fun (node : Masc.Browser_scene.node) ->
             if Hashtbl.mem seen node.node_id then false
             else (Hashtbl.add seen node.node_id (); true))
          scene.content.nodes

  let selected_scene_target t = List.nth_opt (scene_targets t) t.scene_cursor


  let region_observed (target : Browser_lane.node_ref) (scene : scene) =
    scene.content.document_id = target.document_id
    && List.exists (fun (node : Masc.Browser_scene.node) ->
      node.node_id = target.node_id && match node.kind with Region _ -> true | _ -> false)
      scene.content.nodes

  let publish_scene (scene : scene) t =
    let same_observation = match t.scene with
      | Some previous -> previous.source = scene.source
        && previous.client_id = scene.client_id && previous.tab_id = scene.tab_id
        && previous.content.document_id = scene.content.document_id
        && previous.content.url = scene.content.url
        && previous.content.view = scene.content.view && previous.content.scope = scene.content.scope
      | None -> false in
    let selected_id = if same_observation then
      Option.map (fun (node : Masc.Browser_scene.node) -> node.node_id)
        (selected_scene_target t)
      else None in
    let selected_index = match selected_id with
      | None -> None
      | Some selected ->
        let rec find index = function
          | [] -> None
          | (node : Masc.Browser_scene.node) :: _ when node.node_id = selected -> Some index
          | _ :: rest -> find (index + 1) rest in
        find 0 (scene_targets {t with scene = Some scene}) in
    let reading = Option.map (fun (reading : reading) ->
      { reading with page = None; tabs = List.map (fun (tab : tab) ->
          if tab.id = scene.tab_id then
            {tab with title = scene.content.title; url = scene.content.url}
          else tab) reading.tabs }) t.reading in
    {t with scene = Some scene; reading; load = Idle;
      read_view = Scene_view {scene_view = scene.content.view; scope = scene.content.scope};
      scene_cursor = Option.value ~default:0 selected_index;
      scroll = if Option.is_some selected_index then t.scroll else 0}

  let accept_scene ~generation (result : (scene, string) result) t =
    (* Operator input can supersede a cadence result, but the actual request
       remains in flight until this completion. Do not start another cadence
       read merely because its foreground load label was withdrawn. *)
    let t = if t.refresh_pending = Some generation then {t with refresh_pending = None} else t in
    match t.load with
    | Loading (current, Scene_refresh {tab_id;scene_view;scope}) when current = generation ->
        (match result with
         | Ok scene when scene.source = t.source && scene.client_id = client_id t
                         && scene.tab_id = tab_id && t.selected_tab = Some tab_id
                         && ((scene.content.view = scene_view && scene.content.scope = scope)
                             || (scene.content.view = Browser_lane.Regions && scene.content.scope = None
                                 && match scope with Some target -> not (region_observed target scene) | None -> false)) ->
             publish_scene scene t
         | Ok _ -> {t with scene = None; load = Failed "refreshed scene source, client, tab or scope mismatch"}
         | Error detail -> {t with scene = None; load = Failed detail})
    | Loading (current, ((Scene_read tab_id | Scene_regions tab_id | Scene_focus {tab_id;_} | Scene_click {tab_id;_}) as operation)) when current = generation ->
        let expected_view, expected_scope = match operation with
          | Scene_regions _ -> Browser_lane.Regions, None
          | Scene_focus {target;_} -> Browser_lane.Content, Some target
          | Scene_click {scope;_} -> Browser_lane.Content, scope
          | _ -> Browser_lane.Content, None in
        (match result with
         | Ok scene when scene.source = t.source && scene.client_id = client_id t
                         && scene.tab_id = tab_id && t.selected_tab = Some tab_id
                         && scene.content.view = expected_view && scene.content.scope = expected_scope ->
             publish_scene scene t
         | Ok _ -> {t with scene = None; load = Failed "scene source, client or tab mismatch"}
         | Error detail -> {t with scene = None; load = Failed detail})
    | _ -> t


  type scene_action = Read_region | Click_control

  let scene_target_action (node : Masc.Browser_scene.node) =
    match node.kind with
    | Region _ -> Some Read_region
    | Control { clickable = true; disabled = false; _ } -> Some Click_control
    | Text | Raster | Control _ -> None

  let move_scene_action ~backwards t =
    let actions = scene_targets t |> List.mapi (fun index node -> index, node)
      |> List.filter_map (fun (index, node) ->
        Option.map (fun _ -> index) (scene_target_action node)) in
    let ordered = if backwards then List.rev actions else actions in
    match ordered with
    | [] -> t
    | first :: _ ->
        let next = List.find_opt
          (fun index -> if backwards then index < t.scene_cursor else index > t.scene_cursor)
          ordered in
        { t with scene_cursor = Option.value ~default:first next }

  let scene_context t =
    match t.scene, selected_scene_target t with
    | Some scene, Some node ->
        let target_kind = match node.kind with
          | Region _ -> "region" | Control _ -> "control" | Text -> "text" | Raster -> "raster" in
        let pinned = ["lane",`String (source_name scene.source);"tabId",`Int scene.tab_id;
          "expectedUrl",`String scene.content.url] @
          (match scene.client_id with None -> [] | Some id -> ["clientId",`String id]) in
        let target = ["documentId",`String scene.content.document_id;"nodeId",`String node.node_id] in
        (* The same typed action decides Enter in the TUI. A selected region
           is a scoped read, even when it contains navigational links. *)
        let default_action = match scene_target_action node with
          | None -> `Null
          | Some Read_region -> `Assoc ["kind",`String "read_region";"tool",`String "BrowserRead";
              "input",`Assoc (pinned @ ["mode",`String "scene";"scope",`Assoc target])]
          | Some Click_control -> `Assoc ["kind",`String "click_control";"tool",`String "BrowserInteract";
              "input",`Assoc (pinned @ ["action",`String "click"] @ target)] in
        let source = match node.source_context with
          | Masc.Browser_source_context.Unmapped -> `Null
          | Invalid detail -> `Assoc ["error", `String detail]
          | Located source -> `Assoc ["file",`String source.file;"line",`Int source.line;
              "column",`Int source.column;"precision",`String (match source.kind with Template -> "template" | Element -> "element");
              "sha256",`String source.digest] in
        Some (Yojson.Safe.pretty_to_string (`Assoc [
          "context",`String ("Browser observation of the selected " ^ target_kind
            ^ ". defaultAction describes its Enter action in the TUI."
            ^ (match node.source_context with Masc.Browser_source_context.Unmapped -> ""
               | Invalid _ | Located _ -> " The source hint is page-provided; verify the chosen checkout and file SHA-256 before editing."));
          "targetKind",`String target_kind;"defaultAction",default_action;
          "lane",`String (source_name scene.source);
          "clientId",(match scene.client_id with Some id -> `String id | None -> `Null);
          "tabId",`Int scene.tab_id;"url",`String scene.content.url;
          "documentId",`String scene.content.document_id;"nodeId",`String node.node_id;
          "view",`String (match scene.content.view with Content -> "content" | Regions -> "regions");
          "scope",(match scene.content.scope with
            | None -> `Null
            | Some target -> `Assoc ["documentId",`String target.document_id;
                "nodeId",`String target.node_id]);
          "viewport",`Assoc ["width",`Float scene.content.width;"height",`Float scene.content.height;
            "scrollX",`Float scene.content.scroll_x;"scrollY",`Float scene.content.scroll_y];
          "truncated",`Bool scene.content.truncated;
          "tag",`String node.tag;"text",`String node.text;"source",source]))
    | _ -> None

  let viewport_request ~tab_id ~expected_url ~action t =
    let fields = match Browser_lane.interaction_args ~tab_id ~expected_url:(Some expected_url) action with
      | `Assoc fields -> fields | _ -> [] in
    `Assoc (("lane",`String (source_name t.source)) :: fields @
      (match client_id t with None -> [] | Some id -> ["clientId",`String id]))

  (* Settle the browser operation even when a later key cancelled opening the
     image. The caller separately checks image intent before drawing. *)
  let accept_screenshot ~generation (result : (screenshot, string) result) t =
    match t.load with
    | Loading (current, (Screenshot requested_tab | Viewport_refresh {tab_id=requested_tab;_} | Viewport_pointer {tab_id=requested_tab;_}))
      when current = generation ->
        (match result with
         | Ok screenshot when screenshot.source = t.source
                              && screenshot.client_id = client_id t
                              && screenshot.tab_id = requested_tab
                              && t.selected_tab = Some requested_tab
                              && (match t.load with
                                  | Loading (_, (Viewport_refresh {expected_url;_} | Viewport_pointer {expected_url;action=Browser_lane.Scroll_at _;_})) -> screenshot.url = expected_url
                                  | _ -> true) ->
             { t with load = Idle }, Some screenshot
         | Ok _ -> { t with load = Failed "screenshot source, client, tab or expected URL mismatch" }, None
         | Error detail -> { t with load = Failed detail }, None)
    | Loading _ | Idle | No_browser | Failed _ -> t, None

  let accept ~generation (result : (reading, string) result) t =
    let t = if t.refresh_pending = Some generation then {t with refresh_pending = None} else t in
    match t.load with
    | Loading (current, (Read | Read_refresh)) when current = generation ->
        (match result with
         | Ok reading when reading.source = t.source && reading.client_id = client_id t ->
             let same_page = match t.reading, reading.page with
               | Some previous, Some page ->
                   previous.source = reading.source
                   && previous.client_id = reading.client_id
                   && (match previous.page with
                       | Some prior -> prior.tab_id = page.tab_id && prior.url = page.url
                       | None -> false)
               | _ -> false in
             { t with reading = Some reading; load = Idle; read_view = Text_view;
               scroll = (if same_page then t.scroll else 0);
               selected_tab = Option.map (fun (page : page) -> page.tab_id) reading.page }
         | Ok _ -> { t with load = Failed "browser response source or client mismatch" }
         | Error detail -> { t with load = Failed detail })
    | Loading _ | Idle | No_browser | Failed _ -> t
  let select_tab direction t =
    match t.reading with
    | None -> t
    | Some reading ->
        let count = List.length reading.tabs in
        if count = 0 then t else
        let current =
          let rec find i = function
            | [] -> 0
            | (tab : tab) :: rest ->
                if Some tab.id = t.selected_tab then i else find (i + 1) rest
          in find 0 reading.tabs
        in
        let index = (current + direction + count) mod count in
        match List.nth_opt reading.tabs index with
        | None -> t
        | Some tab -> { t with selected_tab = Some tab.id; scroll = 0; scene = None; scene_cursor = 0; load = Idle; read_view = Text_view }
end

module Browser_history = struct
  let owns_key = function
    | "esc" | "left" | "h" | "[" | "]" | "r" | "y" | "j" | "k" | "up" | "down"
    | "pageup" | "pagedown" | "home" | "s" | "v" | "g" | "o" | "x" | "a" | "l" | "b"
    | "n" | "p" | "\r" | "\n" | "enter" | "\015" -> true
    | _ -> false
  type entry = {
    at : float; execution_id : string; artifact : Tool_output.artifact_ref;
  }
  type selection =
    | Loading
    | Failed of string
    | Observed of Masc.Browser_observation.t
  type content =
    | Listing
    | List_failed of string
    | Entries of { entries : entry list; cursor : int; selection : selection }
  type t = { keeper_name : string; content : content; scroll : int }
  let create keeper_name = {keeper_name;content=Listing;scroll=0}
  let entries (snapshot : Tui_decode.keeper_calls_snapshot) =
    snapshot.kcs_entries |> List.rev |> List.concat_map (fun (call : Tui_decode.keeper_call) ->
      match call.kc_execution_id with
      | None -> []
      | Some execution_id -> call.kc_artifact_refs |> List.filter_map (fun artifact ->
        if artifact.Tool_output.mime = Masc.Browser_observation.mime
        then Some {at=call.kc_at;execution_id;artifact} else None))
  let selected t = match t.content with
    | Entries {entries;cursor;_} -> List.nth_opt entries cursor
    | Listing | List_failed _ -> None
  let select cursor entries t =
    {t with content=Entries {entries;cursor;selection=Loading};scroll=0}
  let move delta t = match t.content with
    | Entries {entries;cursor;_} when entries <> [] ->
        let next = max 0 (min (List.length entries - 1) (cursor + delta)) in
        if next=cursor then None else Some (select next entries t)
    | Entries _ | Listing | List_failed _ -> None
  let accept result t = match t.content with
    | Entries entries -> {t with content=Entries {entries with selection=(match result with
        | Ok observation -> Observed observation | Error detail -> Failed detail)}}
    | Listing | List_failed _ -> t
  let observation t = match t.content with
    | Entries {selection=Observed observation;_} -> Some observation
    | Entries _ | Listing | List_failed _ -> None
  let page_view t =
    let view = Browser_lane_view.create () in
    match observation t with
    | None -> view
    | Some observation ->
      let source = match observation.source with
        | Masc.Browser_surface.Live -> Browser_lane_view.Live
        | Automation -> Browser_lane_view.Automation in
      let client_id = Option.map Browser_lane.client_id_to_string observation.client_id in
      {view with source;selected_tab=Some observation.tab_id;scroll=t.scroll;
       scene=Some {source;client_id;tab_id=observation.tab_id;content=observation.scene;elapsed_ms=0.}}
  let decode_artifact (reference : Tool_output.artifact_ref) json =
    let open Yojson.Safe.Util in
    match member "sha256" json, member "bytes" json, member "content" json with
    | `String hash, `Int bytes, `String content
      when hash=reference.sha256 && bytes=reference.bytes && String.length content=bytes ->
        (match Yojson.Safe.from_string content with
         | scene -> Masc.Browser_observation.of_json scene
         | exception Yojson.Json_error detail -> Error ("Retained scene is not JSON: " ^ detail))
    | _ -> Error "Retained scene response does not match its recorded artifact"
  let context t = match observation t, selected t with
    | Some observation, Some entry -> Some (Yojson.Safe.to_string (`Assoc [
        "kind",`String "retained_browser_observation";
        "keeper",`String t.keeper_name;"execution_id",`String entry.execution_id;
        "observed_at",`Float entry.at;
        "artifact",Tool_output.normalized_artifact_ref_to_json entry.artifact;
        "current",`Bool false;"url",`String observation.scene.url;
        "documentId",`String observation.scene.document_id;
        "truncated",`Bool observation.scene.truncated]))
    | _ -> None
end

let browser_lane_page_layout ~cols (view : Browser_lane_view.t) =
  let wrap text =
    String.split_on_char '\n'
      (Masc_tui_keeper_chat_projection.terminal_safe_text ~preserve_newlines:true text)
    |> List.concat_map (fun line -> if line = "" then [""] else
      Masc_tui_message_layout.wrap_words ~max_cells:(max 1 (cols - 6)) line) in
  match view.scene with
  | Some scene ->
    (* The target index came from re-scanning [scene_targets] for every node,
       and [scene_targets] rebuilt its whole list on each of those scans. The
       index is what the dedup already knows, so it is read once into a table
       keyed by node id. *)
    let target_index = Hashtbl.create 64 in
    List.iteri
      (fun i (node : Masc.Browser_scene.node) ->
         if not (Hashtbl.mem target_index node.node_id)
         then Hashtbl.add target_index node.node_id i)
      (Browser_lane_view.scene_targets view);
    let reversed, _, selected = List.fold_left
      (fun (reversed, offset, selected) (node : Masc.Browser_scene.node) ->
      let index = Hashtbl.find_opt target_index node.node_id in
      (* Text is the reading surface. DOM tags do not help read a paragraph,
         author or timestamp; the selected text still has its observed index
         for n/p and context copying. Controls and regions retain their action
         labels and the same indices as the interaction model. *)
      let label = match node.kind with
        | Text -> None
        | Raster -> Some "image · Ctrl-O"
        | Region role -> Some ("region · " ^ role)
        | Control {disabled=true;_} -> Some "disabled"
        | Control {editable=true;_} -> Some "input"
        | Control _ -> Some "button/link" in
      let prefix = match label, index with
        | _, None -> ""
        | None, Some i ->
            if i = view.scene_cursor then Printf.sprintf "[>%d] " (i + 1) else ""
        | Some label, Some i ->
            Printf.sprintf "[%s%d %s] "
              (if i = view.scene_cursor then ">" else "") (i + 1) label in
      let lines = wrap (prefix ^ node.text) in
      let selected = match selected, index with
        | None, Some i when i = view.scene_cursor -> Some offset
        | _ -> selected in
      List.rev_append lines reversed, offset + List.length lines, selected)
      ([], 0, None) scene.content.nodes in
    List.rev reversed, selected
  | None -> match view.reading with
  | None -> [], None
  | Some reading ->
      match reading.page with
      | None -> [], None
      | Some page ->
          let lines = String.split_on_char '\n'
            (Masc_tui_keeper_chat_projection.terminal_safe_text ~preserve_newlines:true page.text)
          |> List.concat_map (fun line ->
              if line = "" then [""] else
              Masc_tui_message_layout.wrap_words ~max_cells:(max 1 (cols - 6)) line) in
          lines, None

let browser_lane_url_line ~cols draft =
  let safe = Masc_tui_keeper_chat_projection.terminal_safe_text draft in
  "  URL> " ^ Masc_tui_message_layout.input_viewport ~max_cells:(max 1 (cols - 12)) safe ^ "▏"

type workspace_activity_read = {
  war_at : float;
  war_hours : float;
  war_keepers : (string * (Tui_decode.file_change_snapshot, string) result) list;
}

type runtime_config_reading = {
  rcv_path : string;
  rcv_rows : (string * string) list list;
  rcv_metadata : Masc_tui_runtime_config_view.metadata;
}

(* One MSX frame as the server hands it over (RFC-0439 §3.7): native-resolution
   RGB plus what to title it. The spectator downsamples the pixels itself. *)
type msx_menu_mode = Boot_game | Change_disk

type msx_frame = {
  msx_number : int;
  msx_width : int;
  msx_height : int;
  msx_rgb : string;
  msx_mode : string;
  msx_cartridge : string option;
  msx_disk : string option;
  msx_players : string list;  (* who pressed within the server's window, newest first *)
}

(* A container-log read that has been asked for and not answered. The keeper and
   the generation identify it; the stamp says when it was asked, in monotonic
   nanoseconds. *)
type sandbox_logs_request = {
  slr_keeper: string;
  slr_generation: int;
  slr_started_ns: int64;
}

(* Each read has a generation; overlapping reads retain the pending interval's
   start, but only the newest response may clear it or populate the view. *)
type detail_read_request = {
  drr_tab: keeper_detail_tab;
  drr_keeper: string;
  drr_generation: int;
  drr_started_ns: int64;
}

type state = {
  mutable metrics_scroll: int;
  mutable metrics_section: metrics_section;
  mutable agents: agent list;
  mutable tasks: task list;
  (* The full domain rows the Overview list is projected from, kept so the
     detail view can show a task after it turns terminal -- the active list
     drops exactly those rows. Replaced wholesale with [tasks] on each load. *)
  mutable tasks_domain: Masc_domain.task list;
  mutable task_flow: Masc_tui_task_flow.t option;
  mutable task_focus: pane_focus;
  (* The [?] help overlay: open replaces the surface body until Esc/? closes
     it. The scroll survives only while it is open. *)
  mutable help_open: bool;
  mutable keeper_deletions_open: bool;
  mutable keeper_deletions_loading: bool;
  mutable keeper_deletions_generation: int;
  mutable keeper_deletions_cursor: int;
  mutable keeper_deletions_scroll: int;
  mutable keeper_deletions: (Masc_tui_keeper_control.deletion_inventory, string) result option;
  (* The [;] agenda overlay: the strip above the composer says whether there
     is anything, and this says what. Modal like the help sheet, and like it
     the scroll survives only while it is open. *)
  mutable agenda_open: bool;
  mutable agenda_scroll: int;
  (* The [@] answering overlay: the footer badge says that keepers are
     mid-turn, and this says which ones, on which lane, for how long. Modal
     like the agenda sheet, and like it the scroll survives only while it
     is open. *)
  (* Whether footers spell their key hints ([tui].hints_visible at boot,
     [h] on the help sheet for the session). Off leaves "?:help" as the one
     remaining hint -- the door back for the reader who knows the keys. *)
  mutable hints_visible: bool;
  (* Whether a line typed while an earlier one still waits joins that line
     instead of queueing behind it ([tui].coalesce_queued_input at boot). A
     queued line has not been sent, so joining two changes what one turn
     receives rather than what a turn in flight sees. *)
  mutable coalesce_queued_input: bool;
  (* Whether ^Y ending a voice capture also sends what was heard
     ([tui].voice_send_on_stop at boot). Off by default: the transcript lands
     in the draft either way, and that draft is also where a spoken
     half-sentence waits for typing. *)
  mutable voice_send_on_stop: bool;
  mutable answering_open: bool;
  mutable answering_scroll: int;
  (* Cursor over the overlay's actionable rows (running / just finished);
     Enter opens that keeper's chat. An index into the overlay's line list,
     kept on a target row by the key handler. *)
  mutable answering_cursor: int;
  (* Keepers whose turn finished within the glow TTL, newest first, with
     the poll time that saw them finish. Fed by comparing consecutive
     keeper_turns polls; read by the footer glow and the overlay's ✓ rows. *)
  mutable keeper_turn_finishes: (string * float) list;
  mutable keeper_turns_observed_at: float option;
  (* [/context] opens the last observed provider-input inspector. It is an
     overlay rather than another surface because it answers "what is in this
     Keeper's current head" from whichever Keeper surface raised the question.
     The reading is stamped with the requested Keeper and generation so a late
     response cannot replace a newer inspection. *)
  mutable context_inspector_open: bool;
  mutable context_inspector_keeper: string option;
  mutable context_inspector_loading: bool;
  mutable context_inspector_generation: int;
  mutable context_inspector_reading:
    (string * Masc_tui_context_inspector.reading) option;
  mutable context_inspector_tab: Masc_tui_context_inspector.tab;
  mutable context_inspector_cursor: int;
  mutable context_inspector_scroll: int;
  mutable context_inspector_exact: int option;
  (* On the split tabs the detail column owns its own window. The list keeps
     the cursor; this scroll and the focus below say which pane hears j/k, so
     a long retained item is read by moving the right pane, not by chasing the
     list row it used to be pinned beside. *)
  mutable context_inspector_detail_scroll: int;
  mutable context_inspector_focus: pane_focus;
  (* How many rows back from the newest the inspector is reading. [0] is the
     newest; the keys that move it re-fetch the exact provider input for the
     row they name, so every tab describes the turn the operator chose. *)
  mutable context_inspector_turn_back: int;
  (* The roster beside a keeper surface costs the chat 30 columns for a
     list the reader may already know. Hidden is a choice they make, not a
     width the terminal forces, so it survives resizing. *)
  mutable roster_pane_hidden: bool;
  (* The Activity pane on the right edge costs a surface
     [Masc_tui_acting_pane.pane_cols] columns for the fleet's live feed. Same
     contract as the roster: hidden is the reader's choice and survives a
     resize; the width is the terminal's. *)
  mutable acting_pane_hidden: bool;
  (* Rows scrolled into the pane's full list; zero is the overview. The
     renderer clamps it to what the list holds and a toggle resets it. *)
  mutable acting_pane_scroll: int;
  (* Which of the pane's two readings is up. Survives a toggle: a reader
     who put the pane away on Changes gets Changes back. *)
  mutable acting_pane_tab: Masc_tui_acting_pane.tab;
  (* One event-derived projection; live presentation inputs are never cached. *)
  mutable acting_chunk_projection: Masc_tui_acting.chunk_projection option;
  (* The selected keeper's recorded file changes, keyed by keeper name, for
     the pane's Changes tab. Refetched when the feed shows that keeper
     complete a tool call and on the operator cadence. *)
  mutable acting_pane_changes:
    (string, Tui_decode.file_change_snapshot) Masc_tui_fetched.t;
  (* When the answer on screen landed, so the tab can say how old it is. *)
  mutable acting_pane_changes_at: float option;
  (* Derived display phase for the selected long name in the narrow roster.
     The main loop advances it only while that roster is visible. *)
  mutable roster_marquee_frame: int;
  (* The frame the running-turn mark is on. The main loop advances it only
     while some turn is actually running, so a screen with nothing running
     is a screen that stops repainting -- the animation costs nothing when
     there is nothing to say. [-1] is "not animating": the mark falls back
     to its still form rather than freezing on an arbitrary quarter. *)
  mutable activity_frame: int;
  mutable keeper_detail_focus: pane_focus;
  mutable keeper_message_focus: pane_focus;
  (* Current successful /health identity. Every HTTP refresh revalidates it so
     a different process on the same endpoint replaces this projection, while
     a failed probe returns the display to unread rather than showing stale. *)
  mutable server_identity: Tui_decode.server_identity option;
  local_base_path: string;
  mutable workspace_identity: workspace_identity;
  mutable help_scroll: int;
  (* An image the operator asked to see, drawn over the whole terminal rather
     than into a frame. A picture does not live in a row: the terminal keeps
     it in its own layer, and the frame presenter redraws only the rows that
     changed, so a frame drawn on top would clear part of the picture and
     leave the rest. While this is set the loop draws no frames at all, and
     the next key takes the picture away and repaints everything. A refusal
     has nothing to draw, so it never sets this: refusals go to the pane as
     text, like every other thing that did not happen. A plain flag, not a
     record of what was drawn -- the title line above the picture is drawn by
     [draw_image] from its own parameter, and nothing reads the rest. *)
  mutable image_open: bool;
  mutable browser_viewport : (Browser_lane_view.screenshot * string) option;
  mutable image_request_generation: int;
  (* Any new input cancels an outstanding asynchronous image preview. *)
  (* The MSX spectator screen, the image overlay's twin: while [msx_open] is
     set the loop draws no frames and every key belongs to the emulator. The
     machine is [Option] so it exists only once the screen has been opened,
     and it survives closing -- reopening continues the same frame. *)
  mutable msx_open: bool;
  (* RFC-0439 §3.7: the TUI no longer owns a machine. The spectator caches
     the last frame the server handed it and when it last asked. *)
  mutable msx_frame: msx_frame option;
  mutable msx_last_poll_ns: int64;
  (* The load menu (RFC-0439 §3.7): the human picks a game from the cartridge
     inventory to plug into the shared machine. It is an overlay on the MSX
     screen -- while [msx_menu_open] the keyboard drives the picker, not the
     game, so its keys never reach the emulator. [msx_carts] is the inventory
     the [/carts] poll cached; [msx_menu_index] is the highlighted row. *)
  mutable msx_menu_open: bool;
  mutable msx_notice: string option;
  mutable msx_menu_mode: msx_menu_mode;
  mutable msx_carts: string list;
  mutable msx_menu_index: int;
  (* The [:] command palette: a typed filter over jump targets. Query and
     cursor live only while it is open. *)
  mutable palette_open: bool;
  mutable palette_query: string;
  mutable palette_cursor: int;
  mutable palette_mode: palette_mode;
  (* [/] on the roster: a search that moves the cursor, not a filter that
     subsets the list -- every action reads the same [keepers] the rows
     draw, so nothing can act on a hidden row. [Some q] while typing;
     [search_last] feeds n/N after Enter. Every surface that answers
     {!surface_row_texts} searches through the same pair. *)
  mutable search: string option;
  mutable search_last: string;
  (* Detail pane tab, and the per-keeper reads the non-Info tabs show. Each
     read is stamped with the keeper it answers for, so a cursor move cannot
     show one keeper's instructions under another's name. *)
  (* The Config surface: runtime.toml's path and text as the server read
     them, refreshed on entry and after every save. *)
  (* The Resources surface: the MCP resource inventory, and the one read
     the content pane shows, stamped with its uri. [resource_pending_uri]
     rejects a slow reply after the operator has stepped to another row. *)
  (* The Config surface's voice pane: the server's own answer about what
     loaded, and which input device the recorder would use. The device is read
     locally because no server knows it — sox takes whatever macOS calls
     default, and an operator whose captures come back empty is usually
     looking at the wrong microphone. *)
  mutable voice_config: Yojson.Safe.t option;
  mutable voice_config_error: string option;
  mutable voice_input_device: string option;
  mutable resources_list: Masc_tui_mcp.resource list option;
  mutable resources_error: string option;
  mutable resources_cursor: int;
  mutable resource_content:
    (string * Masc_tui_mcp.resource_content list) option;
  mutable resource_content_error: (string * string) option;
  mutable resource_pending_uri: string option;
  mutable resource_scroll: int;
  mutable resource_focus: pane_focus;
  (* The Config surface owns the files the server reads. runtime.toml is one;
     the prompt registry is the other, and a prompt is edited the same way —
     $EDITOR over the effective text, the server persists what comes back. *)
  mutable config_pane: config_pane;
  mutable tools_pane: tools_pane;
  (* The reader's own choice of colours, and where the cursor sits while they
     look. [None] follows whatever the terminal reports, which is what masc
     did before there was a choice to make. *)
  mutable theme_choice: string option;
  mutable theme_cursor: int;
  (* What was in force when the reader entered the themes pane, so Esc can put
     it back. [None] inside [Some] is a real answer -- they were following the
     terminal -- which is why this is an option of an option: the outer one
     says whether a preview is running at all. *)
  mutable theme_before_preview: string option option;
  mutable theme_filter: [ `All | `Dark | `Light ];
  (* The prompt catalog. One value rather than a snapshot option beside an
     error option: the pair could not say "asked, waiting", so this pane drew
     an empty catalog while its first read was in flight. *)
  mutable prompts: (unit, Tui_decode.prompts_snapshot) Masc_tui_fetched.t;
  mutable prompts_cursor: int;
  mutable prompts_show_fragments: bool;
  mutable prompts_show_runtime_assets: bool;
  mutable prompts_librarian_input: (string * string list) option;
  mutable prompts_librarian_input_error: string option;
  mutable prompts_librarian_input_loading: bool;
  (* Prompt presets (#32777). The pane holds the listing, the name being
     typed for a save, the preset armed for a restore, and the last report —
     which stays on screen because it is the only place the skipped keys and
     the runtime.toml outcome are said. *)
  mutable presets_snapshot: Tui_decode.presets_snapshot option;
  mutable presets_error: string option;
  mutable presets_cursor: int;
  (* What the selected preset holds, fetched from /api/v1/presets/show. The
     listing names the overridden prompts; this is the rest of what applying
     one would change.

     One value rather than a pair of options: the pair could not say "asked,
     waiting", which is the state this pane spends its first moments in. *)
  mutable preset_detail: (string, Tui_decode.preset_detail) Masc_tui_fetched.t;
  mutable preset_save_draft: string option;
  mutable preset_restore_armed: string option;
  mutable preset_report: Tui_decode.preset_restore_report option;
  mutable preset_busy: bool;
  (* Rows of coloured segments, the shape the Code surface keeps, so the two
     surfaces read the same file the same way. Plain text is derived where it
     is needed rather than stored beside them: two copies of the same rows
     drift the moment one is rebuilt and the other is not. *)
  mutable runtime_config_view: runtime_config_reading option;
  mutable runtime_config_status_open: bool;
  mutable runtime_config_status_scroll: int;
  (* A source section requested by another surface while runtime.toml is
     loading. The jump is consumed only after the same server-owned source
     lands, so Lanes never needs a second config writer or a guessed path. *)
  mutable runtime_config_jump_section: string option;
  (* The models pane's rows, parsed once when the source lands. The pane and
     the scroll bound have to agree on how many rows exist; deriving the
     count from the source instead made the keys move over 2,317 file lines
     while the pane drew 49 table rows, so [j] left the view still and [k]
     needed thousands of presses to come back. *)
  mutable config_models_rows: Masc_tui_model_runtime_table.row list;
  (* Which row [e] acts on. The pane cannot write a value itself -- the two
     columns come from two tables and a writer would have to know which --
     so [e] hands the file to $EDITOR the way the runtime.toml pane does,
     positioned at this row's [models.NAME]. *)
  mutable config_models_cursor: int;
  mutable runtime_config_view_error: string option;
  (* Absolute source row selected in runtime.toml. The viewport remains
     [config_scroll]; keeping the cursor separate lets j/k skip prose while
     PgUp/PgDn still move by a visible page. *)
  mutable runtime_config_cursor: int;
  mutable config_scroll: int;
  mutable detail_tab: keeper_detail_tab;
  mutable keeper_run_cursor: int;
  mutable detail_reads: detail_read_request list;
  mutable detail_read_generation: int;
  mutable keeper_sandbox_view: (string * Masc_tui_keeper_sandbox.t) option;
  mutable keeper_sandbox_view_error: string option;
  mutable keeper_sandbox_logs: (string * Masc_tui_keeper_sandbox.logs) option;
  mutable keeper_sandbox_logs_error: (string * string) option;
  mutable keeper_sandbox_logs_generation: int;
  (* The container-log read, which is its own read: the operator opens the
     Sandbox tab, waits for its status, and presses o/l later. Its start lives
     with the request rather than beside it, so an in-flight log read cannot
     exist without the stamp that times it, and status and logs pending at once
     are timed apart. *)
  mutable keeper_sandbox_logs_inflight: sandbox_logs_request option;
  mutable keeper_config_view: (string * string list) option;
  mutable keeper_config_view_error: string option;
  mutable github_identity_view: (string * string list) option;
  (* The Identity tab. Stamped with the keeper it was fetched for, like the
     other fetched tabs, so the pane shows loading rather than another
     keeper's answer. The providers are held rather than pre-rendered lines
     because the screen's numbering and the key that acts on it have to come
     out of one list -- see [identity_connectable]. *)
  mutable identity_view: (string * identity_provider list) option;
  mutable identity_view_error: string option;
  mutable identity_login: identity_login_started option;
  (* Which provider the arrows are on. Held rather than derived because a
     screen that renumbered under a moving cursor would start the wrong
     service; [identity_cursor_clamped] is what keeps it inside the list. *)
  mutable identity_cursor: int;
  (* What one attempt answered, as against [identity_view_error], which is
     the list itself failing to load. A refusal from one provider is not a
     reason to take the other fifty-odd off the screen. *)
  mutable identity_attempt_error: (identity_notice_kind * string) option;
  (* [None] is not filtering; [Some ""] is filtering with nothing typed yet,
     which is a different screen from not filtering -- one says the list is
     everything, the other says it is everything so far. *)
  mutable identity_filter: string option;
  (* The app form, when it is open: which provider it is for, which field is
     taking keys, and what has been typed. The secret is held here only
     until it is sent, and cleared with the form -- a field left filled is a
     credential sitting in the process for as long as the pane is up. *)
  mutable identity_app_form: identity_app_form option;
  mutable github_identity_view_error: string option;
  mutable task_cursor: int;
  mutable task_detail_id: string option;
  mutable task_detail_scroll: int;
  mutable tasks_error: string option;
  mutable events: event list;
  mutable overview_event_scroll: int;
  mutable keepers: keeper list;
  mutable keepers_error: string option;
  (* The live roster reading, separate from the durable one above: it answers
     whether a keepalive fiber is running each keeper, which metadata on disk
     cannot. It is typed rather than a plain list because "the roster did not
     arrive" and "the roster arrived without this keeper" license different
     lifecycle actions. *)
  mutable keeper_roster: Masc_tui_keeper_control.roster;
  mutable keeper_roster_error: string option;
  mutable keeper_action_inflight:
    (string * Masc_tui_keeper_control.action) option;
  mutable keeper_action_pending: Masc_tui_keeper_control.pending option;
  mutable keeper_action_serial: int;
  (* The composer occupies the last terminal row on every surface. It is drawn
     whether or not it holds the keystrokes: an input line that appears only
     once it is already receiving text cannot be found by looking. Focus is
     what routes keys into it, and the operator takes and releases that. *)
  mutable composer_focused: bool;
  (* A microphone capture in flight, and the level it is hearing.
     [voice_capture] is the keeper the transcript is bound for, taken when the
     capture starts: the roster cursor moves on its own under a refresh, and a
     transcript that arrived seconds later would otherwise land on whoever is
     selected now.

     [voice_level_db] is the last level read from the growing recording, so an
     operator can see the microphone is hearing them. Without it a dead input
     device and a quiet room look identical — both end as an empty draft. *)
  mutable voice_capture: string option;
  mutable voice_level_db: float option;
  (* What a second ^Y or an Esc asked of the running capture, read by it ten
     times a second. A request rather than a cancellation because the recording
     has to close its file on the way out: killed outright it would leave a
     header with no length in it. *)
  mutable voice_stop_requested: Masc.Voice_bridge.stop_request option;
  (* Continuous mode: the keeper whose row re-arms a capture after each
     transcript, until the operator turns it off. Separate from
     [voice_capture], which is the capture running right now — between two
     utterances the mode is on and no capture is in flight.

     [voice_floor] is the room level measured when the mode started, reused for
     every capture in it. Re-probing costs about 1.15 s of the gap between
     utterances, and a room does not change between two sentences the way it
     changes across a session. *)
  mutable voice_continuous: string option;
  mutable voice_floor: float option;
  (* A top-level [q] arms exit instead of ending the TUI immediately. The next
     unrelated input clears it; a second [q] exits. *)
  mutable quit_armed: bool;
  (* What the last key the operator pressed actually did, and the clock
     reading it was set at. These outcomes go to [add_event], and the event
     log is drawn by Overview alone -- so the operator who pressed [a] on
     Workspace stood on the one surface that could not answer them, and a
     registration that succeeded looked the same as an editor that never
     started. The footer every surface draws answers instead, and only for
     [last_action_window_s]: an outcome that stayed would go on claiming a
     keypress the operator has since forgotten making. *)
  mutable last_action: (string * float) option;
  (* The keeper list holds one row per running keeper, so a keeper that failed
     to start is absent from it rather than shown as failed. This carries the
     fleet's own reading of what is missing. *)
  mutable fleet_safety: fleet_safety option;
  mutable fleet_safety_error: string option;
  mutable connection_status: connection_status;
  mutable local_workspace: local_workspace_reading;
  mutable view: surface;
  (* Where Esc goes back to after following a reference, and what was open
     there. The surfaces print [masc://] references beside the thing they
     name -- a verdict says which task it judged -- and following one is only
     half a move: an operator who cannot get back reads the id, walks over by
     hand, and loses the row they were on.

     One step, not a stack. A second jump replaces the first: the way back
     from two hops is the surface strip, and a stack that grew without a
     screen showing it would be state nobody can see. *)
  mutable followed_from: (surface * string option) option;
  mutable keeper_cursor: int;
  (* The runtime picker: the keeper it is choosing for, its cursor into the
     dispatchable catalogue, and the catalogue itself with where every keeper
     points today. Loaded when the picker opens; absent otherwise. *)
  mutable runtime_pick_keeper: string option;
  mutable runtime_pick_cursor: int;
  mutable runtime_catalog: Tui_decode.runtime_option list;
  mutable runtime_assignments: Tui_decode.runtime_assignment list;
  mutable runtime_catalog_error: string option;
  (* Lazy loads for the two detail panes; the id names which row the answer
     belongs to so a stale load is discarded, not drawn under another item.
     [None] doubles as "in flight" right after entry resets it. *)
  mutable goal_timeline:
    (string * (Tui_decode.goal_timeline, string) result) option;
  mutable task_history:
    (string * (Tui_decode.task_history_event list, string) result) option;
  mutable verification_evidence:
    (string * (Tui_decode.verification_evidence, string) result) option;
  (* One cache is shared by the calls surface and chat full-detail mode. The
     scope and generation are the authority: cursor position is not, because
     palette/Answering can open a chat without moving the roster cursor. *)
  mutable keeper_calls: Tui_decode.keeper_calls_snapshot option;
  mutable keeper_calls_error: string option;
  mutable keeper_calls_keeper: string option;
  mutable keeper_calls_loading: bool;
  mutable keeper_calls_refresh_pending: bool;
  mutable keeper_calls_generation: int;
  mutable keeper_calls_scroll: int;
  mutable log_entries: log_entry list;
  mutable log_error: Metrics_tail.load_error option;
  mutable log_scroll: int;
  mutable live_context: Masc_tui_context_state.t;
  mutable overview: overview_snapshot option;
  mutable overview_error: string option;
  mutable transport: Tui_decode.transport_health option;
  mutable transport_error: string option;
  mutable approval_snapshot: approval_snapshot option;
  mutable approvals_error: string option;
  (* Questions Keepers put to a human, drawn beside the approvals. [None]
     means nothing has been read yet, which is not the same as a fleet with
     no open questions. *)
  mutable asks_snapshot: Masc.Tui_decode.asks_snapshot option;
  mutable asks_error: string option;
  (* Answering happens in its own mode. The surface's own keys are spoken for
     -- arrows walk the approval queue, y and n decide it -- and a question
     needs a key per choice, so entering the mode is what frees them up. *)
  mutable ask_answer_mode: ask_answer_mode;
  mutable ask_cursor: int;
  mutable ask_question_cursor: int;
  mutable ask_question_scroll: int;
  (* One answer at a time. The draft carries the ask it belongs to, so moving
     the cursor cannot post an answer under the wrong question. *)
  mutable ask_draft: Masc_tui_ask_projection.draft option;
  (* Open while the operator types an answer no choice covers. A question the
     server sent with no choices at all can be answered only this way, and
     until this existed the terminal drew "free text welcome" over a keyboard
     that had nowhere to put the text. *)
  mutable ask_text_entry: ask_text_entry option;
  mutable pending_ask_submit: string option;
  mutable ask_submit_inflight: bool;
  (* The tool calls keepers are holding, drawn above the operator actions on
     the same surface. Live registry state on the server; refreshed with the
     surface. *)
  mutable keeper_tool_approvals: Tui_decode.keeper_tool_approval list;
  mutable keeper_tool_approvals_error: string option;
  (* Successful reads of each owning endpoint, independent of roster refresh.
     A failed refresh keeps both the receipt and the previous rows. *)
  mutable keeper_tool_approvals_observed: bool;
  mutable keeper_tool_approvals_read: Snapshot_read.t;
  (* Which keepers are mid-turn right now, from GET /api/v1/keepers/turns.
     Rides the same tick as the approvals above, for the same reason: the
     "answering now" badge is drawn from every surface, so it cannot wait
     for the operator to open the keeper list. *)
  mutable keeper_turns: Tui_decode.keeper_turn_row list;
  mutable keeper_turns_error: string option;
  mutable keeper_turns_inflight: bool;
  (* The durable Gate: approvals that survive nobody watching (external
     service writes among them), plus both lane modes. Refreshed with the
     same surface; answered through the dashboard resolve route. *)
  mutable gate_pending: Tui_decode.gate_pending list;
  mutable gate_modes: Tui_decode.gate_lane_modes option;
  mutable gate_queue_unavailable: string option;
  (* Standing always-allow rules. A rule answers a call before it can become
     a pending ask, so the queue alone cannot show that one exists — an
     operator reading an empty queue has to be told what is answering in its
     place. *)
  mutable gate_rules: Tui_decode.gate_rule list;
  mutable gate_rules_unavailable: string option;
  mutable gate_error: string option;
  mutable gate_snapshot_observed: bool;
  mutable gate_snapshot_read: Snapshot_read.t;
  (* Keepers whose approval gate runs every call unasked. Names only: the
     wire carries (keeper, mode) pairs and [auto] is the absent default, so
     what the pane needs is exactly the yolo set. *)
  mutable keeper_yolo_names: string list;
  mutable keeper_tool_modes_observed: bool;
  mutable keeper_tool_modes_error: string option;
  (* Durable per-keeper Gate settings, as (keeper, value) pairs. Only keepers
     somebody singled out are here, so absence means "follows the workspace"
     rather than "unknown". Distinct from [keeper_yolo_names], which is the
     in-memory stance a restart clears. *)
  mutable keeper_gate_modes: (string * string) list;
  (* Runtime_params registry rows, as the surface reads them: key, current,
     default, and whether somebody moved it. Loaded like the other config
     views rather than kept live -- these change when an operator changes
     them, not on their own. *)
  mutable runtime_params: Tui_decode.runtime_param_row list;
  mutable runtime_params_error: string option;
  mutable runtime_params_loading: bool;
  (* The Runtime params pane is an operator surface, not a passive dump.
     Selection and the in-progress typed value live separately from the shared
     Config scroll used by runtime.toml/prompt bodies. *)
  mutable runtime_params_cursor: int;
  mutable runtime_param_edit: runtime_param_edit option;
  mutable runtime_params_notice: (bool * string) option;
  mutable keeper_gate_judges: (string * string) list;
  mutable approval_flow: Masc_tui_operator_projection.Flow.t;
  (* The list draws each ask on one row; this opens the selected one whole.
     Keyed on the cursor rather than a token so an ask that resolves while it
     is open closes with the row instead of stranding a detail for something
     that is gone. *)
  mutable approval_detail_open: bool;
  mutable approval_detail_scroll: int;
  mutable approval_cursor: int;
  mutable pending_approval_action: pending_approval_action option;
  mutable board_posts: board_post list;
  mutable board_detail:
    (board_post * board_comment list) Masc_tui_board_detail.t;
  mutable board_list_error: string option;
  mutable board_cursor: int;
  mutable msg_find: string;
      (** What [/find] was last given on this pane, or [""] before it is used.
          Kept so the arg-less form continues the same search instead of
          asking for the text again. *)
  mutable msg_find_at: msg_anchor option;
      (** Structural identity of the message [/find] last landed on. The next
          search resolves it in the current causal timeline and starts
          strictly older. An index cannot survive a broadcast or Journal
          backfill inserted ahead of the match. *)
  mutable board_sort: board_sort;
  mutable board_hearth: string option;
      (** Which sub-board the list is narrowed to, or [None] for all of them.
          Sent to the server rather than filtered here: the listing is paged,
          and 1550 of this workspace's 2171 posts sit in [verification] alone,
          so a filter over one page would show a handful of rows and call them
          the hearth. *)
  mutable board_hearths: (string * int) list;
      (** Every hearth on the board and how many posts it holds, busiest
          first, as [/api/v1/board/hearths] counts them.

          This was read off whichever listing had last arrived, which made it
          two things at once and both of them wrong. It could not offer a
          hearth whose posts all fell outside the page, and it had to be
          refreshed only from unnarrowed loads or the cycle collapsed to the
          one hearth already chosen. The board's own census has neither
          problem, and it carries the counts -- so [f] stops being a walk
          through names a reader cannot see the size of. *)
  mutable board_scroll: int;
  mutable board_mode: board_mode;
  mutable board_focus: pane_focus;
  (* Wide terminals normally keep the Board list beside the open post. [z]
     lets the reader spend those columns on a long post or comment instead;
     this is an explicit reading choice, so resizing must not reset it. *)
  mutable board_detail_wide: bool;
  (* The compose draft and its send arm. The arm is the operator's explicit
     answer to "publish what is typed": while it is unset, esc re-offers
     send-or-discard and no other key can send. [board_compose_reply_to]
     names what a sent draft answers -- [None] publishes a new post,
     [Some post_id] adds a comment to that post -- so one pane covers both
     writes and the payload alone decides which. *)
  board_draft: Buffer.t;
  mutable board_compose_armed: bool;
  mutable board_compose_reply_to: string option;
  mutable board_compose_hearth: string option;
  (* One send at a time: the gate a slow server needs so s-s cannot post
     the same draft twice, and the completion knows it owns the clear. *)
  mutable board_post_inflight: bool;
  mutable board_post_error: string option;
  (* A vote armed for a second keypress: which post, and up or down. The
     cursor can move between the two presses, so the post id is captured at
     arm time and a press on a different row re-arms for that row. *)
  mutable board_vote_armed: (string * bool) option;
  mutable planning: planning_snapshot option;
  mutable planning_baseline: planning_snapshot option;
  mutable planning_error: string option;
  mutable planning_cursor: int;
  mutable planning_scroll: int;
  mutable runtime_mode: runtime_mode;
  mutable planning_mode: planning_mode;
  (* Client-side over the already-loaded goals: [f]/[s] re-render without a
     refetch. *)
  mutable planning_filter: planning_filter;
  mutable planning_sort: planning_sort;
  (* A goal lifecycle request armed for a second keypress, and what the last
     one answered. Arming rather than pressing keeps the detail view's plain
     letters safe: c/x/o are lifecycle only once, and any other key disarms. *)
  mutable goal_action_armed:
    (string * Goal_phase.Public_action.t) option;
  mutable goal_action_error: string option;
  (* The schedule list and its cursor. The snapshot keeps the server's
     ok/unknown split so a failed store read never draws as "no schedules". *)
  mutable schedules: schedule_snapshot option;
  mutable schedules_error: string option;
  mutable schedules_read: Snapshot_read.t;
  mutable schedule_cursor: int;
  mutable schedule_scroll: int;
  mutable schedule_detail_id: string option;
  (* The wake history of whichever schedule the detail is open on. Carries the
     schedule id it was asked about so a late answer for a row the reader has
     already left is dropped rather than filed under the new one. *)
  mutable schedule_wake_history: schedule_wake_history option;
  mutable schedule_wake_history_error: (string * string) option;
  mutable schedule_wake_history_inflight: string option;
  (* The selected Keeper's own schedule page, carrying the keeper it was asked
     about. The Automation tab used to filter the fleet page, which caps at its
     own limit with active rows first, so a Keeper whose schedules sat past it
     read as having none. *)
  mutable keeper_schedules: (string * schedule_snapshot) option;
  mutable keeper_schedules_error: (string * string) option;
  mutable keeper_schedules_inflight: string option;
  (* A cancel armed for a second keypress: which schedule. The cursor can move
     between the two presses, so the schedule id is captured at arm time and a
     press on a different row re-arms for that row. *)
  mutable schedule_cancel_armed: string option;
  mutable schedule_cancel_error: string option;
  mutable lanes: Tui_decode.keeper_lanes_snapshot option;
  mutable keeper_lanes_inflight: bool;
  mutable standalone_lanes: Tui_decode.standalone_lanes_snapshot option;
  mutable standalone_lanes_error: string option;
  mutable standalone_lanes_inflight: bool;
  mutable standalone_lanes_generation: int;
  (* The clients roster, off the ring under Runtime the way Lanes is. A
     cursor, not just a scroll: "/" search lands on a row by name, and the
     cursor is where it lands. *)
  mutable clients_surface: Tui_decode.clients_snapshot option;
  mutable clients_surface_error: string option;
  mutable clients_surface_inflight: bool;
  mutable clients_surface_scroll: int;
  mutable clients_surface_cursor: int;
  mutable clients_surface_generation: int;
  (* Run drill-down under the standalone observation rows. [lane_runs] is the
     summary page of the lane named in [lanes_mode]; payloads stay behind the
     per-run detail fetch, so the list never holds one. *)
  mutable lanes_mode: lanes_mode;
  mutable lanes_standalone_cursor: int;
  mutable lane_runs: Tui_decode.lane_run_summary list option;
  mutable lane_runs_error: string option;
  mutable lane_runs_next: (float * string) option;
  mutable lane_runs_total: int option;
  mutable lane_runs_loading: bool;
  mutable lane_runs_generation: int;
  mutable lane_runs_cursor: int;
  mutable lane_runs_scroll: int;
  mutable lane_run_detail: Tui_decode.lane_run_detail option;
  mutable lane_run_detail_generation: int;
  mutable lane_run_detail_error: string option;
  mutable lane_run_detail_scroll: int;
  (* Read from the same composite body as [lanes]. A Keeper the producer has
     not projected is simply absent from this list, which the Secrets tab
     shows as "no projection" rather than as an empty credential set. *)
  mutable keeper_secrets: Tui_decode.keeper_secret_projection list;
  mutable lanes_error: string option;
  mutable lanes_action_error: string option;
  (* What is waiting on a verdict. Loaded when the surface is opened rather
     than on every refresh: it is a queue an operator visits, not a number the
     other surfaces read. *)
  mutable tools_inventory: Tui_decode.tool_snapshot option;
  mutable tools_request_generation: int;
  mutable tools_read_inflight: tools_read_inflight option;
  mutable tools_error: string option;
  mutable skills_catalog: Tui_decode.skills_catalog option;
  mutable skills_catalog_error: string option;
  mutable tools_scroll: int;
  mutable tools_skill_cursor: int;
  mutable tools_skill_evidence: (string * Yojson.Safe.t) option;
  mutable tools_async_observation: Tui_decode.async_request_observation option;
  mutable tools_async_observation_error: string option;
  mutable lane_addons: Masc_tui_lane_addons.t option;
  mutable lane_addons_cached: Masc_tui_lane_addons.t;
  mutable lane_addons_generation: int;
  mutable browser_lane: Browser_lane_view.t option;
  mutable browser_history: Browser_history.t option;
  mutable browser_history_generation: int;
  mutable browser_lane_visibility: browser_lane_visibility;
  mutable browser_lane_generation: int;
  mutable connectors: Tui_decode.connector_snapshot option;
  mutable connectors_error: string option;
  mutable connectors_inflight: bool;
  mutable connectors_scroll: int;
  mutable connectors_cursor: int;
  mutable connectors_binding_cursor: int;
  mutable connector_unbind_armed: (string * string * string) option;
  (* Two server-owned documents joined by exact runtime id: resolved owns
     lanes/provider/model identity, probe owns cached reachability. *)
  mutable runtime_surface: Tui_decode.runtime_surface_snapshot option;
  mutable runtime_surface_error: string option;
  mutable runtime_surface_scroll: int;
  mutable runtime_detail_target: runtime_detail_target option;
  mutable runtime_detail_scroll: int;
  (* The lane a fallback is being added to, and where the picker sits in the
     runtime catalogue. Both are cleared when the picker closes: a cursor kept
     across visits opens the list part-way down for no reason the reader gave. *)
  mutable runtime_lane_pick: string option;
  mutable runtime_lane_pick_cursor: int;
  mutable runtime_lane_error: string option;
  mutable runtime_cursor: int;
  mutable runtime_surface_generation: int;
  mutable runtime_surface_inflight: int option;
  mutable runtime_surface_force_pending: bool;
  mutable repositories: Tui_decode.repository_snapshot option;
  mutable repositories_error: string option;
  mutable repositories_inflight: bool;
  mutable repositories_scroll: int;
  mutable repositories_cursor: int;
  mutable workspace_activity_repo: string option;
  mutable workspace_activity: (string, workspace_activity_read) Masc_tui_fetched.t;
  mutable workspace_activity_cursor: int;
  mutable memory_health: Tui_decode.memory_health_snapshot option;
  mutable memory_health_error: string option;
  mutable memory_health_inflight: bool;
  mutable memory_health_scroll: int;
  mutable memory_health_cursor: int;
  (* The Memory fact browser. [memory_facts_keeper = None] draws the health
     table; [Some name] draws that keeper's fact listing over it. The
     category filter holds a category string exactly as the server spelled
     it -- filtering is equality against the loaded rows, never a
     classification this side invents. *)
  mutable memory_facts_keeper: string option;
  mutable memory_facts: Tui_decode.memory_fact_snapshot option;
  mutable memory_facts_error: string option;
  mutable memory_facts_cursor: int;
  mutable memory_facts_scroll: int;
  mutable memory_facts_category: memory_category_filter;
  mutable memory_facts_sort: memory_sort_order;
  mutable memory_overview_sort: memory_overview_sort;
  mutable repository_changes_open: bool;
  mutable repository_changes_scope: Tui_decode.repository_change_scope option;
  mutable repository_changes: Tui_decode.repository_change_snapshot option;
  mutable repository_changes_error: string option;
  mutable repository_changes_scroll: int;
  mutable repository_changes_cursor: int;
  mutable repository_changes_diff: (string * Tui_decode.git_diff) option;
  mutable repository_changes_diff_error: string option;
  mutable repository_changes_diff_path: string option;
  mutable repository_changes_diff_scroll: int;
  mutable repository_changes_return_chat: bool;
  (* Interactive patch review modal: 3D drop-shadow overlay for reviewing
     and resolving pending code changes, git diffs, and approval gates. *)
  mutable patch_modal_open: bool;
  mutable patch_modal_scroll: int;
  mutable patch_modal_path: string option;
  mutable patch_modal_diff: (string * Tui_decode.git_diff) option;
  mutable patch_modal_error: string option;
  (* Web Link Preview and Rich Embed modal & settings *)
  mutable link_modal_open: bool;
  mutable link_modal_scroll: int;
  mutable link_modal_url: string option;
  mutable link_modal_links: string list;
  mutable link_modal_cursor: int;
  mutable link_previews_mode: [ `Rich | `Compact | `Off ];
  (* Real-time Token Burn Velocity and Financial HUD *)
  mutable burn_hud_visible: bool;
  (* Code surface: one directory level at a time through the lazy /children
     route; the file arrives whole and is lexed once at load. *)
  mutable code_dir: string;
  mutable code_entries: Tui_decode.workspace_tree_node list;
  mutable code_entries_error: string option;
  mutable code_entries_inflight: bool;
  mutable code_cursor: int;
  (* The open file's lexed rows, keyed by its path. One value rather than a
     pair of options: the pair could not say "reading", so a file being
     fetched drew the same blank pane an empty file draws -- and nothing
     matched an arriving answer against the path still on screen, so a slow
     read of one file could replace another the operator had since opened.

     An array, not a list: the diff pane resolves a drawn row's colouring by
     that row's line number in the whole file, so the lookups are scattered
     rather than sequential and a list walked from the front on every one. *)
  mutable code_file: (string, (string * string) list array) Masc_tui_fetched.t;
  mutable code_file_scroll: int;
  (* The line the pane's cursor is on (0-based), the anchor a language-server
     question is asked at. j/k move it; the scroll follows to keep it
     visible. *)
  mutable code_file_cursor: int;
  (* The last language-server answer (or refusal), shown beside the title
     until the next question or file replaces it. *)
  mutable code_lsp_note: string option;
  (* Where a definition jump left from, newest first: scope, directory,
     open file (if any), its cursor and scroll. B walks back through it.
     Bounded so a long session cannot grow it without limit. *)
  mutable code_jump_back:
    (code_workspace_scope * string * string option * int * int) list;
  (* Horizontal offset in display cells, and the widest row's width -- the
     clamp. Measured once at load: measuring ten thousand rows on every
     keypress is what this field exists to avoid. *)
  mutable code_file_hscroll: int;
  mutable code_file_max_width: int;
  mutable code_focus_file: pane_focus;
  (* The file pane's history view: H on an open file swaps the content for
     commits and durable Keeper file changes over that repository address,
     newest first. Keyed by the path they were fetched for so opening another
     file drops a stale listing rather than captioning it. *)
  (* The open file's history, keyed by the scope and the path together: two
     repositories can carry the same relative path, and a slow answer for one
     must not caption the other. *)
  mutable code_history:
    (code_workspace_scope * string, code_history_listing) Masc_tui_fetched.t;
  mutable code_history_open: bool;
  mutable code_history_scroll: int;
  (* The file pane's diff view: d on an open file swaps the content for what
     the working tree holds against HEAD, keyed the same way. One overlay at
     a time -- opening this closes the history and vice versa. *)
  (* The open file's uncommitted diff, keyed by its path. *)
  mutable code_diff: (string, Tui_decode.git_diff) Masc_tui_fetched.t;
  mutable code_diff_open: bool;
  mutable code_diff_scroll: int;
  (* The file pane's notes view: m on an open file swaps the content for
     the memos written as comments in the file itself. Read off the rows
     once at load, like the width above: the memos change when the file
     does, and rebuilding them per frame walks every row of it. *)
  mutable code_memos: Masc_tui_memo.found list;
  mutable code_notes_open: bool;
  mutable code_notes_scroll: int;
  (* The file pane's blame margin: b on an open file fetches who last touched
     each run of lines, and the gutter names the author once per run. Unlike
     the three views above, this does not swap the pane's content -- it is a
     margin beside the code, so it is showing exactly when it is loaded and
     [b] again drops it. No [_open] flag: shown-with-nothing-loaded is not a
     state this can be in. Keyed by path like the others, so opening another
     file drops the margin rather than captioning it wrongly. *)
  (* Who last touched each run of the open file, keyed by its path. One
     value: the pair could not say the blame was being read, so pressing [b]
     on a large file left the margin blank with nothing to distinguish "still
     reading" from "no blame here". *)
  mutable code_blame: (string, Tui_decode.blame_block list) Masc_tui_fetched.t;
  (* Whose workspace the surface reads. One field, one value: a keeper's
     playground and a project repository at the same time is not a
     representable state. *)
  mutable code_scope: code_workspace_scope;
  (* Set by the jump that opens a file at a line; consumed (once) when the
     file arrives, because the load handler owns the scroll reset. *)
  mutable code_target_line: int option;
  (* The keeper whose changes the Changes surface is showing, and what it
     answered. The name is held separately from the snapshot because a
     surface that has asked and not yet heard back is a different state from
     one that has never asked, and the scroll belongs to the list on screen
     rather than to the keeper. *)
  mutable changes_keeper: string option;
  mutable changes: Tui_decode.file_change_snapshot option;
  mutable changes_error: string option;
  (* Which keeper surface [f] was pressed on. Esc leaves Changes for that
     one: the roster and the detail both name a keeper through the same
     cursor, and returning a reader from the detail to the roster drops them
     a level they did not ask to leave. *)
  mutable changes_return: changes_return;
  (* Which row the list marks, and where the window on that list sits. Two
     fields rather than one: the marked row was the window's top row, so the
     rows the window already showed below it could not be marked, and Enter,
     d, v and o all read whichever change happened to be drawn first. *)
  mutable changes_cursor: int;
  mutable changes_scroll: int;
  (* The row whose diff is open, as an index into the loaded list, and how far
     that diff is scrolled. An index rather than a copy of the change: a
     refresh replaces the list, and a copy would keep drawing a change the
     answer no longer holds. Out of range closes the view. *)
  mutable changes_diff_row: int option;
  mutable changes_diff_scroll: int;
  (* The tree's reading of the same file. Held beside the tool-call reading
     rather than replacing it: one says what the keeper tried to write and the
     other what survived, and they disagree often enough that a single field
     would make whichever arrived last look like the whole answer. *)
  mutable changes_tree_diff: Tui_decode.git_diff option;
  mutable changes_tree_diff_error: string option;
  mutable changes_tree_diff_path: string option;
  mutable harness: Tui_decode.harness_snapshot option;
  mutable harness_error: string option;
  mutable harness_inflight: bool;
  mutable harness_scroll: int;
  mutable harness_cursor: int;
  (* The verdict opened from the list. Task id alone is not an identity: the
     same task can pass through several gates, so retain the record timestamp
     with it. *)
  mutable harness_detail: (string * float) option;
  mutable harness_detail_scroll: int;
  mutable fusion_runs: Tui_decode.fusion_snapshot option;
  mutable fusion_error: string option;
  mutable fusion_cursor: int;
  mutable fusion_scroll: int;
  mutable fusion_mode: fusion_mode;
  mutable fusion_runs_generation: int;
  mutable fusion_runs_inflight: int option;
  mutable fusion_detail: Tui_decode.fusion_detail option;
  mutable fusion_detail_error: string option;
  (* A detail GET captures this generation. A late response for a run the
     operator already left cannot replace the exact run now on screen. *)
  mutable fusion_detail_generation: int;
  (* The current generation/run pair already being read. Periodic refreshes
     do not pile another GET on top of it; changing runs still starts a new
     request immediately, whose pair replaces this marker. *)
  mutable fusion_detail_inflight: (int * string) option;
  mutable fusion_historical_detail: Tui_decode.fusion_historical_detail option;
  mutable fusion_historical_inflight: (int * Tui_decode.fusion_historical_evidence) option;
  (* The feature-proof reading. Kept beside its error rather than collapsed
     into an option: a report that failed to load must not draw as a report
     with no features, which reads as "nothing is proven". *)
  mutable observer: observer_status;
  mutable mcp_session: string option;
      (** The MCP session the server issued, kept across streams: the server
          holds it after a stream closes, so reopening the feed and calling
          tools reuse it rather than minting one per attempt. Cleared when
          the server explicitly reports it missing or conflicting. *)
  mutable observer_cursor: Sse_wire.observer_cursor option;
      (** Last applied complete event, scoped to the responding process. *)
  mutable observer_replay: observer_replay_status;
  mutable acting: Masc_tui_acting.entry list;  (** newest first, at most [acting_retained_entries] *)
  mutable acting_dropped: int;  (** events that fell off the end of [acting] *)
  mutable acting_undecodable: int;  (** frames the feed reader could not read *)
  mutable acting_undecodable_last: string option;  (** why, for the most recent one *)
  mutable acting_scroll: int;  (** rows from the newest, 0 = pinned to the newest *)
  mutable acting_unseen: int;  (** events that arrived while scrolled away from the newest *)
  mutable acting_filter: Masc_tui_acting.filter;
  mutable acting_cursor: int;
  mutable acting_detail: Masc_tui_acting.entry option;
  mutable acting_detail_scroll: int;
  mutable verification: Tui_decode.verification_snapshot option;
  mutable verification_error: string option;
  mutable verification_inflight: bool;
  mutable verification_scroll: int;
  mutable verification_cursor: int;
  (* The request being read, not merely the current cursor position. A refresh
     may reorder the queue; retaining the request id prevents the detail pane
     and verdict keys from silently moving to a different task. *)
  mutable verification_detail_request_id: string option;
  mutable verification_detail_scroll: int;
  (* An approve armed for a second keypress: which task. The cursor can move
     between the two presses, so the task id is captured at arm time and a
     press on a different row re-arms for that row. Reject carries no arm --
     its $EDITOR reason form is the confirmation step. *)
  mutable verification_verdict_armed: string option;
  mutable verification_verdict_error: string option;
  mutable system_logs: system_log_snapshot option;
  mutable system_logs_error: string option;
  mutable system_logs_scroll: int;
  mutable system_logs_cursor: int;
  (* The Logs filters. The level floor travels to the server (it decides what
     the page fetches); the category narrows what the fetched page shows, its
     vocabulary being whatever categories the loaded rows carry. *)
  mutable system_logs_min_level: Tui_decode.system_log_level option;
  mutable system_logs_category: string option;
  mutable system_logs_detail_seq: int option;
  mutable system_logs_detail_scroll: int;
  msg_input: Buffer.t;
  (* Images staged with :attach, sent with the next message and cleared by the
     send. Held next to the draft because they are part of the same unsent
     message: switching keepers or abandoning the draft must not leave an image
     attached to whatever is typed later. *)
  mutable msg_attachments: Masc_tui_keeper_chat_projection.attachment list;
  (* Image references staged with :ref (#33728) — a URL the provider fetches
     or a Files-API id. Same lifecycle as [msg_attachments]: part of the unsent
     message, consumed by the send that consumes the draft. *)
  mutable msg_references: Masc_tui_keeper_chat_projection.image_reference list;
  (* Ctrl-O weighs a staged image against a .png the conversation named by
     which is newer, so the batch carries a recency marker: an anchor to the
     history row that was newest when the newest attachment entered the
     composer. [None] is a real answer -- staged while the history was empty,
     so any row it holds now arrived later. Meaningful only while
     [msg_attachments] is non-empty and reset when it clears. *)
  mutable msg_attachments_since: msg_anchor option;
  mutable msg_target_keeper_name: string option;
  mutable msg_return: keeper_chat_return;
  mutable msg_drafts: (string * string) list;
  mutable msg_history: msg_entry list;
  (* How far back the arrows have walked through what this pane sent, and the
     draft they set aside to do it. [None] means the composer holds the
     operator's own text, so pressing down has nothing to give back. *)
  mutable msg_recall_at: int option;
  mutable msg_recall_draft: string;
  (* The waiting line the composer is editing, if the walk stepped onto one.
     [Some request_id] makes the next Enter replace that line instead of
     queueing a second copy of it -- the arrows copy, and a copy of something
     that has not been sent yet would be sent twice.

     Not cleared by typing: editing is exactly typing over what was recalled,
     and clearing it there would put the original back in play. *)
  mutable msg_recall_replaces: Masc_tui_keeper_chat_queue.item option;
  (* The selected Keeper's turn currently streaming, if any. The request-owned
     value lives in [msg_inflight]; this slot only chooses what the pane draws.
     Cleared when the turn settles; the settled value moves to
     [msg_settled_logs]. *)
  mutable msg_live: turn_log option;
  (* The keeper's durable transcript as last loaded, for the keeper the pane is
     showing. Replaced wholesale by a load rather than merged: the server holds
     the record of what was said, and reconciling two copies of it row by row
     needs an identity the two do not share. *)
  mutable msg_loaded: msg_entry list;
  mutable msg_loaded_keeper: string option;
  mutable msg_loaded_error: string option;
  mutable msg_loaded_dropped: int;
  (* Recorded file changes are a separate chat cache. [changes] belongs to the
     Changes surface and follows its own keeper selection; sharing it would
     make visiting one surface change what the other says. The canonical
     execution index is prepared once when a stamped snapshot arrives. *)
  mutable msg_file_changes: Tui_decode.file_change_snapshot option;
  mutable msg_file_changes_keeper: string option;
  mutable msg_file_change_index: Masc_tui_keeper_chat_diff.index;
  mutable msg_file_changes_loading: bool;
  mutable msg_file_changes_refresh_pending: bool;
  mutable msg_file_changes_error: string option;
  mutable msg_file_changes_generation: int;
  mutable msg_memory_visibility: memory_visibility;
  mutable msg_memory_error: string option;
  mutable msg_memory_dropped: int;
  (* Every full-history GET captures this generation. Keeper identity alone is
     not enough after alpha -> beta -> alpha: the first alpha response can
     arrive after the second alpha request and still name the visible Keeper. *)
  mutable msg_history_load_generation: int;
  mutable msg_history_inflight: (int * string) option;
  (* The newest row [msg_scroll] counts back from, by causal row identity, while the
     operator is reading back. Counting from whatever is newest right now made
     the count mean something different every time a reply landed: the new rows
     go on that end, so the same count lands further down and the window slides
     toward text nobody asked to see. Pinned when they scroll off the bottom
     and released when they return to it, which is also how they get back to
     following the turn. *)
  mutable msg_scroll_pin: msg_anchor option;
  (* How many rows above the newest the chat pane is showing. 0 is the bottom,
     where the pane follows a running turn. Held rather than derived: an
     operator reading back should stay where they are while the keeper keeps
     talking. *)
  mutable msg_scroll: int;
  (* Where the next older page starts, and whether one exists. Both come from
     the server rather than being derived here: it owns the rule for what
     "older than this" means across rows that share a timestamp. None with
     [msg_older_exist] true means the pane has not learned a cursor yet. *)
  mutable msg_older_cursor: float option;
  mutable msg_older_exist: bool;
  mutable msg_older_loading: bool;
  mutable msg_older_error: string option;
  (* Presentation-only defaults come from the CLI and can be changed in the
     pane without mutating the transcript. *)
  mutable msg_reasoning_visibility: reasoning_visibility;
  mutable msg_origin_display: Masc_tui_message_layout.origin_display;
  mutable msg_tool_visibility: tool_visibility;
  (* Whether the turn dashboard is folded to its progress line. Folded is the
     default: the block below the conversation grew a row per thing the
     runtime had to say, and those rows sat between the reader and what they
     typed, so the composer read as though the input had not left the
     screen. Folded, the turn keeps one line; the rows that ask the operator
     for something stay whatever this says. *)
  mutable msg_turn_folded: bool;
  (* Messages typed while a turn was running, oldest first, each with the
     keeper it was addressed to. Dispatch is serialized on one in-flight
     request, so a second Enter used to be answered with "already in progress"
     and the text was gone. Holding it and sending it when the turn settles is
     what every other agent console does, and it is what an operator means by
     pressing Enter twice.

     The keeper travels with the text because the operator can switch keepers
     while a turn runs; sending a queued line to whoever happens to be selected
     later would put it in front of the wrong keeper. *)
  (* A paste too big for the composer. The draft carries one line saying what
     it is; the text itself waits here and goes back into the message on the
     way out. Kept beside the draft rather than in it because the draft is
     what the operator reads, and five rows cannot hold four hundred lines. *)
  mutable msg_spill: Masc_tui_paste_spill.t option;
  mutable msg_queued: Masc_tui_keeper_chat_queue.t;
  (* One request per keeper, not one per workspace. Dispatch used to be
     serialized on a single slot because the durable recovery fence held one
     un-acknowledged POST for the whole workspace; with that gone the only
     reason left is per keeper, which is how the server runs turns anyway. *)
  mutable msg_inflight: inflight list;
  (* The turns this session watched settle, oldest first, every keeper
     together. A settled turn stays the log it was and is drawn from it, so
     settling changes a rail, not the rows; the loaded transcript's rows for a
     turn a log holds are left out of the timeline ([chat_rows_for]). Never
     pruned within a session: a reload replaces [msg_loaded], not these. *)
  mutable msg_settled_logs: turn_log list;
  (* Operations whose journal the server said it cannot serve -- unknown,
     pruned, or unreadable -- so a refresh does not ask for them again this
     session. A request that never got an answer is not here: the next
     refresh asks again. *)
  mutable msg_journal_unavailable: string list;
  (* Operations whose journal a fiber is reading right now, so a load that
     arrives before the read returns does not start a second one. *)
  mutable msg_journal_inflight: string list;
  (* The server refused this client's credential for the journal endpoint.
     Said once; no journal is asked for again this session. *)
  mutable msg_journal_reads_refused: bool;
  (* The settled logs held when [msg_scroll_pin] was taken. Their rows were on
     the screen the operator anchored, so they are not rows that arrived
     since; a log held later is. *)
  mutable msg_scroll_pin_settled: turn_log list;
  mutable detail_scroll: int;
  workspace: string;
  port: int;
  refresh_interval: float;
}

(* Which field a typed character lands in.

   Seven fields take letters. Paste named four of them and typing named all
   seven, each with its own guard written where the field was added, so a
   paste into the palette, into row search, or into a preset name went to the
   chat draft the operator was not looking at -- or, with no keeper selected,
   nowhere at all. The operator sees a paste that works on one screen and
   does nothing on the next.

   Both paths read this now. A field added here has to be answered by every
   match over the result, which is what keeps the next field from taking
   letters without taking pasted text.

   The board draft is one of these and the chat composer is not, which reads
   backwards until you look at what a paste has to do in each. Both hold many
   lines, but the composer's paste also classifies a dropped file and spills a
   long paste to a file in the keeper's workspace -- neither of which a board
   post has anywhere to go. What the board draft needs is the text, and that
   is what a case here gives it.

   The chat composer is not one of these. It is the fallback both paths already
   share -- keys reach it through [Composer.classify_key] before this is
   consulted, and a paste reaches it when this says [None] -- and its paste
   path does work these cannot (a dropped file, a spill to disk) that has no
   meaning in a one-line field.

   [compact_viewport] is the frame's, not the state's: a surface the last
   paint had to draw compact is not showing the field, and the two identity
   fields already refused keys on that ground. Passed in rather than read,
   because this module cannot see a frame. *)
(* Browser is an operator reader inside Connectors. A retained
   reader model must not change chrome after the operator leaves its view. *)
let browser_lane_on_screen (state : state) =
  match state.view, state.browser_lane_visibility with
  | Connectors, Browser_lane_shown _ -> state.browser_lane
  | _, Browser_lane_hidden | _, Browser_lane_shown _ -> None

let browser_history_on_screen state =
  Option.bind (browser_lane_on_screen state) (fun _ -> state.browser_history)

let close_browser_history state =
  state.browser_history <- None;
  state.browser_history_generation <- state.browser_history_generation + 1

let leave_browser_lane_for_surface state destination =
  if destination <> state.view then begin
    close_browser_history state;
    state.browser_lane_visibility <- Browser_lane_hidden
  end

let show_browser_lane state =
  close_browser_history state;
  if Option.is_none (browser_lane_on_screen state) then
    state.browser_lane_visibility <- Browser_lane_shown {
      return_surface = state.view;
      return_search = state.search;
      return_composer_focused = state.composer_focused;
    };
  state.browser_lane <- Some (match state.browser_lane with
    | Some view -> view
    | None -> Browser_lane_view.create ());
  state.view <- Connectors;
  state.search <- None

let hide_browser_lane state =
  close_browser_history state;
  match state.browser_lane_visibility with
  | Browser_lane_hidden -> ()
  | Browser_lane_shown previous ->
      state.browser_lane_visibility <- Browser_lane_hidden;
      state.view <- previous.return_surface;
      state.search <- previous.return_search;
      state.composer_focused <- previous.return_composer_focused

(* Discard belongs to this capture until it settles. A later stop/keep key
   must not revive a transcript whose recording the operator abandoned. *)
let request_voice_stop (state : state) request =
  match state.voice_stop_requested with
  | Some Masc.Voice_bridge.Discard -> ()
  | None | Some Masc.Voice_bridge.Keep_what_was_heard ->
      state.voice_stop_requested <- Some request

let release_composer_for_browser_reader (state : state) =
  state.composer_focused <- false;
  state.voice_continuous <- None;
  state.voice_floor <- None;
  state.voice_level_db <- None;
  (* Keep the occupied capture until its callback, so returning to the
     composer cannot start a second microphone while this one shuts down. *)
  if Option.is_some state.voice_capture then
    request_voice_stop state Masc.Voice_bridge.Discard

(* The transcript may already be in the mailbox when the reader opens.
   Settle ownership before deciding whether its text can reach the draft. *)
let settle_voice_transcript (state : state) ~keeper =
  if state.voice_capture <> Some keeper then None
  else begin
    let disposition = Option.value state.voice_stop_requested
        ~default:Masc.Voice_bridge.Keep_what_was_heard in
    state.voice_capture <- None;
    state.voice_level_db <- None;
    Some disposition
  end

type text_input_target =
  | Text_browser_url
  | Text_ask_answer
  | Text_preset_name
  | Text_runtime_param
  | Text_palette
  | Text_row_search
  | Text_identity_app_form
  | Text_identity_filter
  | Text_board_draft

(* The order is the key dispatch's order, which is what an operator already
   experiences: a preset name being typed holds every letter, and the two
   identity fields come last because the surface under them reads letters as
   commands. *)
let text_input_target (state : state) ~compact_viewport =
  let identity_surface =
    state.view = Keepers Keeper_detail
    && state.detail_tab = Detail_identity
    && not compact_viewport
  in
  if state.keeper_deletions_open then None
  else if
    state.view = Config
    && state.config_pane = Config_presets
    && Option.is_some state.preset_save_draft
  then Some Text_preset_name
  else if Option.is_some state.runtime_param_edit then Some Text_runtime_param
  else if state.view = Approvals && not compact_viewport
          && not state.context_inspector_open && Option.is_some state.ask_text_entry
  then Some Text_ask_answer
  else if state.palette_open then Some Text_palette
  else if Option.is_some state.search then Some Text_row_search
  else if state.view = Connectors && not compact_viewport
          && Option.is_some (Option.bind (browser_lane_on_screen state) (fun view -> view.Browser_lane_view.url_draft))
  then Some Text_browser_url
  else if identity_surface && Option.is_some state.identity_app_form then
    Some Text_identity_app_form
  else if identity_surface && Option.is_some state.identity_filter then
    Some Text_identity_filter
  else if state.view = Board && state.board_mode = Board_compose then
    Some Text_board_draft
  else None
;;

(* One reading of the state for both the send path and the footer; the order
   and the reasoning live in [Masc_tui_send_disposition]. *)
type send_disposition =
  Masc_tui_keeper_chat_projection.request Masc_tui_send_disposition.t

(* The keeper the composer is pointed at, since a turn running for another
   keeper does not decide what Enter does here. *)
let inflight_for_keeper state keeper_name =
  List.find_opt
    (fun entry -> String.equal entry.sent_request.keeper_name keeper_name)
    state.msg_inflight
;;

let live_for_keeper state keeper_name =
  Option.map (fun entry -> entry.log) (inflight_for_keeper state keeper_name)
;;

(* Scoped by keeper like every other reading of the settled logs: a request
   id is minted per send, but the rule that one turn has one source is a
   rule per keeper's conversation. *)
let settled_log_for_request state ~keeper_name request_id =
  List.find_opt
    (fun turn_log ->
      String.equal (turn_log_keeper_name turn_log) keeper_name
      && String.equal (turn_log_request_id turn_log) request_id)
    state.msg_settled_logs
;;

let settled_logs_for_keeper state keeper_name =
  List.filter
    (fun turn_log -> String.equal (turn_log_keeper_name turn_log) keeper_name)
    state.msg_settled_logs
;;

(* A settled log takes its place among the others by when its turn started,
   so a turn rebuilt from its journal sits where a turn settled live would
   have. A request already held by a log that stands for its turn is not
   added twice; a log that never heard the turn's end gives way to one that
   did, which is how a cut stream's turn gets its whole record back from the
   journal on the next refresh. The held log itself, fed more lines in place
   (a journal read joining a cut stream's partial log), takes its place
   again: [chat_rows_for] keys its memo on the identity of this list, so a
   log that came to stand for its turn in place has to arrive as a new list
   value, or the memo keeps answering with the loaded rows the log now
   draws. *)
let hold_settled_log state turn_log =
  let request_id = turn_log_request_id turn_log in
  let keeper_name = turn_log_keeper_name turn_log in
  let replaceable =
    match settled_log_for_request state ~keeper_name request_id with
    | Some existing -> existing == turn_log || not (turn_log_holds_the_turn existing)
    | None -> true
  in
  if replaceable then begin
    let started_at = turn_log_started_at turn_log in
    let rec insert = function
      | [] -> [ turn_log ]
      | held :: rest when turn_log_started_at held <= started_at ->
          held :: insert rest
      | later -> turn_log :: later
    in
    state.msg_settled_logs <-
      insert
        (List.filter
           (fun held ->
             not
               (String.equal (turn_log_keeper_name held) keeper_name
               && String.equal (turn_log_request_id held) request_id))
           state.msg_settled_logs)
  end
;;

let remember_journal_unavailable state operation_id =
  if not (List.exists (String.equal operation_id) state.msg_journal_unavailable)
  then state.msg_journal_unavailable <- operation_id :: state.msg_journal_unavailable
;;

let journal_read_started state operation_id =
  if not (List.exists (String.equal operation_id) state.msg_journal_inflight)
  then state.msg_journal_inflight <- operation_id :: state.msg_journal_inflight
;;

let journal_read_finished state operation_id =
  state.msg_journal_inflight <-
    List.filter
      (fun inflight -> not (String.equal inflight operation_id))
      state.msg_journal_inflight
;;

(* Where a journal read starts for this operation: after what a held log of
   it already has (a cut live stream's partial log, or an earlier read of a
   turn still running), or the whole journal. *)
let journal_resume_position state ~keeper_name operation_id =
  match settled_log_for_request state ~keeper_name operation_id with
  | Some held when not (turn_log_holds_the_turn held) ->
      Masc_tui_keeper_chat_log.resume_position held.tl_log
  | Some _ | None -> Masc.Keeper_chat_event_log.Whole_turn
;;

(* Whether the loaded transcript says this turn is over: the keeper's reply,
   or a failure, is on record. A journal that still cannot stand for such a
   turn has nothing more coming -- the settle-time failure is never journaled
   (#33108) -- so it is not worth asking for again. *)
let loaded_turn_has_ended state ~keeper_name request_id =
  Option.exists (String.equal keeper_name) state.msg_loaded_keeper
  && List.exists
       (fun (row : msg_entry) ->
         String.equal row.me_request_id request_id
         &&
         match row.me_role with
         | Message_keeper | Message_autonomous | Message_error -> true
         | Message_user _ | Message_status | Message_local | Message_tool
         | Message_skill _ | Message_thinking | Message_memory ->
             false)
       state.msg_loaded
;;

(* Whether a reasoning row is drawn at all under this visibility. The
   committed rows and the log projection ask this one function, so the two
   cannot disagree about whether THINKING is on the screen. *)
let reasoning_drawn = function
  | Reasoning_hidden -> false
  | Reasoning_folded | Reasoning_full -> true
;;

(* A turn a settled log stands for, as the timeline needs to know it: which
   request, and whether the log carries reasoning. The wire carries reasoning
   only from runtimes that stream it; a runtime that does not leaves the
   durable trace row -- "N reasoning steps, content withheld" -- as the only
   record that the keeper thought at all, and that row stays. *)
type held_turn =
  { ht_request_id : string
  ; ht_reasoning : bool
  }

let held_turn_of_log turn_log =
  { ht_request_id = turn_log_request_id turn_log
  ; ht_reasoning =
      Masc_tui_keeper_chat_transcript.thinking_lines turn_log.tl_transcript <> []
  }
;;

(* The rows a turn's log draws itself: the keeper's words, its tool blocks
   (with the durable outcome and duration folded in by
   [enrich_held_logs_from_rows]), its skills, and its reasoning when it has
   any. What a person said, what the server said about the turn (gate rows),
   what the pane said, and a failure are drawn from the committed rows whether
   or not a log holds the turn -- the log draws none of them. *)
let log_draws_row (held : held_turn) (row : msg_entry) =
  String.equal row.me_request_id held.ht_request_id
  &&
  match row.me_role with
  | Message_keeper | Message_autonomous | Message_tool | Message_skill _ -> true
  | Message_thinking -> held.ht_reasoning
  | Message_user _ | Message_status | Message_local | Message_error
  | Message_memory ->
      false
;;

(* The committed rows the pane still draws once these turns are held by
   settled logs: a turn has one source, and for a held turn that is the log.
   The same list when nothing is held, so the memo above it can tell. *)
let rows_the_logs_do_not_draw ~held rows =
  match held with
  | [] -> rows
  | held ->
      List.filter
        (fun (row : msg_entry) ->
          not (List.exists (fun turn -> log_draws_row turn row) held))
        rows
;;

(* What the durable transcript knows about a held turn's calls that the wire
   did not carry -- outcome and duration -- folded into the log's transcript
   by execution id, so the block a held turn is drawn from says what the
   loaded row it replaces would have said. Run where loaded rows arrive and
   where a journal log is held. *)
let enrich_held_logs_from_rows state ~keeper_name (rows : msg_entry list) =
  List.iter
    (fun turn_log ->
      let request_id = turn_log_request_id turn_log in
      List.iter
        (fun (row : msg_entry) ->
          match row.me_tool_block with
          | Some block when String.equal row.me_request_id request_id ->
              List.iter
                (fun (activity : Masc_tui_keeper_chat_transcript.tool_activity) ->
                  match activity.execution_id with
                  | Some execution_id ->
                      ignore
                        (Masc_tui_keeper_chat_transcript.note_tool_outcome
                           turn_log.tl_transcript ~execution_id
                           ~outcome:activity.outcome ~duration:activity.duration
                          : bool)
                  | None -> ())
                block.Masc_tui_keeper_chat_transcript.activities
          | Some _ | None -> ())
        rows)
    (List.filter turn_log_holds_the_turn (settled_logs_for_keeper state keeper_name))
;;

(* Settling a turn: its log is committed and, when it has anything to draw,
   kept among the settled logs; the pane stops treating it as live. Nothing
   is copied into session rows (RFC-0412 §3.3). Here rather than in the
   executable so the decision is linkable by a test. *)
let settle_turn_log state (entry : inflight) =
  Masc_tui_keeper_chat_log.commit entry.log.tl_log;
  if Masc_tui_keeper_chat_log.entries entry.log.tl_log <> [] then
    hold_settled_log state entry.log;
  match state.msg_live with
  | Some visible
    when String.equal (turn_log_request_id visible) (turn_log_request_id entry.log) ->
      state.msg_live <- None
  | Some _ | None -> ()
;;

(* The strict decode's row for a completed turn, or nothing when the settled
   log stands for the turn and draws its reply itself
   ([Masc_tui_keeper_chat_transcript.drawn]). *)
let completed_turn_row state (request : Masc_tui_keeper_chat_projection.request)
    (completed : Masc_tui_keeper_chat_projection.completed_turn) =
  let log_holds_the_turn =
    Option.exists turn_log_holds_the_turn
      (settled_log_for_request state ~keeper_name:request.keeper_name
         request.request_id)
  in
  if log_holds_the_turn then None
  else
    let role =
      match completed.turn_outcome with
      | Masc_tui_keeper_chat_projection.Visible_reply
        when String.trim completed.reply <> "" ->
          Message_keeper
      | Masc_tui_keeper_chat_projection.Visible_reply
      | Masc_tui_keeper_chat_projection.Continuation_checkpoint
      | Masc_tui_keeper_chat_projection.Terminal_effect_settled
      | Masc_tui_keeper_chat_projection.Awaiting_gate_approval
      | Masc_tui_keeper_chat_projection.No_visible_reply ->
          Message_status
    in
    Some
      ( role
      , Masc_tui_keeper_chat_transcript.turn_status_text ~reply:completed.reply
          ~turn_ref:completed.turn_ref completed.turn_outcome )
;;

let promoted_inflight_for_keeper state keeper_name =
  match inflight_for_keeper state keeper_name with
  | Some ({ origin = Promoted_queue _; _ } as entry) -> Some entry
  | Some { origin = Direct_submission; _ } | None -> None
;;

let send_disposition state ~keeper_name : send_disposition =
  Masc_tui_send_disposition.of_state
    ~inflight:
      (Option.map
         (fun entry -> entry.sent_request)
         (inflight_for_keeper state keeper_name))
    ~waiting:
      (* The line a new one for this keeper would join (last waiting [Next], never
         a steer). Present it as "the keeper is spoken for" so Enter queues onto
         it instead of dispatching past a line the operator has not finished. *)
      (Option.map
         (fun (item : Masc_tui_keeper_chat_queue.item) ->
           item.Masc_tui_keeper_chat_queue.request)
         (Masc_tui_keeper_chat_queue.join_target state.msg_queued ~keeper_name))

(** One keeper as the Keepers surface reads it: durable pause from the
    metadata row, live runtime from the roster. *)
let keeper_reading (state : state) (keeper : keeper) :
    Masc_tui_keeper_control.reading =
  { name = keeper.k_name
  ; paused = keeper.k_paused
  ; liveness =
      (match keeper.k_origin with
       | Tui_decode.Declared_keeper _ -> Masc_tui_keeper_control.Absent
       | Persisted_keeper ->
         Masc_tui_keeper_control.liveness_of_roster state.keeper_roster keeper.k_name)
  }

let acting_flat_entries state =
  List.filter
    (fun entry -> Masc_tui_acting.visible state.acting_filter entry.Masc_tui_acting.ae_event)
    state.acting

let selected_acting_entry state =
  match state.acting_filter with
  | Masc_tui_acting.Turns -> None
  | Actions | Everything -> List.nth_opt (acting_flat_entries state) state.acting_cursor

(* What a pending read says while it is pending.

   The seconds appear only after a couple of them. A read that answers at once
   would otherwise flash a number nobody asked for, and the number exists for
   the reads that do not answer at once: against a live server the Sandbox
   tab's status took between five and sixteen seconds (measured 2026-09-12),
   which is long enough to be read as a stall and keyed at. The footer's
   answering badge spends its elapsed seconds for the same reason. *)
let pending_seconds_floor = 2

let loading_notice ?elapsed_s what =
  match elapsed_s with
  | Some seconds when seconds >= pending_seconds_floor ->
      Printf.sprintf "(%s\xe2\x80\xa6 %ds)" what seconds
  | Some _ | None -> Printf.sprintf "(%s\xe2\x80\xa6)" what

let nanoseconds_per_second = 1_000_000_000L

(* How long a read has been pending, in whole seconds. [now_ns] is an argument
   so the answer is the same every time it is asked with the same reading, and
   the stamp is the read's own rather than the state's: the Sandbox tab's status
   and its container logs are two reads and can be pending at once.

   No clamp, because a monotonic reading cannot go backwards. A wall clock can,
   and the clamp that used to be here turned that into a silent zero. *)
let pending_elapsed_s ~now_ns started_ns =
  Option.map
    (fun since ->
      Int64.to_int (Int64.div (Int64.sub now_ns since) nanoseconds_per_second))
    started_ns

let pending_detail_read (state : state) ~tab ~keeper =
  List.find_opt
    (fun request -> request.drr_tab = tab && String.equal request.drr_keeper keeper)
    state.detail_reads

let detail_read_started state ~tab ~keeper =
  Option.map (fun request -> request.drr_started_ns)
    (pending_detail_read state ~tab ~keeper)

(* A refresh supersedes the response, not the elapsed interval. Periodic OAuth
   polling waits for an in-flight read; explicit refreshes and service switches
   may still supersede it so a pre-mutation response cannot win. *)
let mark_detail_read_started (state : state) ~tab ~keeper ~now_ns =
  let started_ns =
    match pending_detail_read state ~tab ~keeper with
    | Some request -> request.drr_started_ns
    | None -> now_ns
  in
  state.detail_read_generation <- state.detail_read_generation + 1;
  let request =
    { drr_tab = tab; drr_keeper = keeper;
      drr_generation = state.detail_read_generation; drr_started_ns = started_ns }
  in
  state.detail_reads <- request :: List.filter
      (fun pending -> pending.drr_tab <> tab || not (String.equal pending.drr_keeper keeper))
      state.detail_reads;
  request

(* A current terminal answer retires its wait, even off screen or on error.
   Superseded responses cannot retire or populate a newer read. The caller
   still checks selection before putting an accepted answer on screen. *)
let finish_detail_read (state : state) request =
  let current =
    match pending_detail_read state ~tab:request.drr_tab ~keeper:request.drr_keeper with
    | Some pending -> pending.drr_generation = request.drr_generation
    | None -> false
  in
  if current then
    state.detail_reads <-
      List.filter (fun pending -> pending.drr_generation <> request.drr_generation)
        state.detail_reads;
  current

let detail_read_waiting state ~tab ~keeper =
  Option.is_some (pending_detail_read state ~tab ~keeper)
  || (tab = Detail_sandbox
      && match state.keeper_sandbox_logs_inflight with
         | Some request -> String.equal request.slr_keeper keeper
         | None -> false)

let selected_keeper (state : state) =
  List.nth_opt state.keepers state.keeper_cursor

let fusion_snapshot_entries (snapshot : Tui_decode.fusion_snapshot) =
  List.map (fun run -> Tui_decode.Fusion_retained_run run) snapshot.fus_runs
  @ List.map (fun evidence -> Tui_decode.Fusion_historical_evidence evidence)
      snapshot.fus_historical_evidence

let fusion_list_entries (state : state) =
  match state.fusion_runs with
  | None -> []
  | Some snapshot -> fusion_snapshot_entries snapshot

let fusion_entry_identity = function
  | Tui_decode.Fusion_retained_run run -> "run:" ^ run.fur_run_id
  | Tui_decode.Fusion_historical_evidence evidence -> "board:" ^ evidence.fhe_post_id

let selected_fusion_entry state =
  List.nth_opt (fusion_list_entries state) state.fusion_cursor

let fusion_detail_entry_index state =
  fusion_list_entries state
  |> List.find_index (fun entry ->
      match state.fusion_mode, entry with
      | Fusion_detail id, Tui_decode.Fusion_retained_run run ->
          String.equal id run.fur_run_id
      | Fusion_historical_detail reference, Tui_decode.Fusion_historical_evidence candidate ->
          String.equal reference.fhe_post_id candidate.fhe_post_id
          && String.equal reference.fhe_run_id candidate.fhe_run_id
      | _ -> false)

let selected_keeper_runs (state : state) =
  match selected_keeper state, state.fusion_runs with
  | Some keeper, Some snapshot ->
      List.filter (fun (run : Tui_decode.fusion_run) ->
          String.equal run.fur_keeper keeper.k_name) snapshot.fus_runs
  | _ -> []

let selected_keeper_run (state : state) =
  let runs = selected_keeper_runs state in
  let cursor = max 0 (min state.keeper_run_cursor (List.length runs - 1)) in
  Option.map (fun run -> cursor, run) (List.nth_opt runs cursor)

(** The standalone lane row under the cursor, when the cursor is in the
    standalone section. *)
let workspace_activity_rows (state : state) =
  match state.workspace_activity_repo with
  | None -> []
  | Some repo_id ->
      match Masc_tui_fetched.view_for ~equal:String.equal state.workspace_activity ~key:repo_id with
      | Masc_tui_fetched.Absent | Masc_tui_fetched.Loading | Masc_tui_fetched.Failed _ -> []
      | Masc_tui_fetched.Ready reading ->
          List.concat_map (fun (_, result) -> match result with
            | Error _ -> []
            | Ok (snapshot : Tui_decode.file_change_snapshot) ->
                List.filter_map (fun (change : Tui_decode.file_change) ->
                  match change.fc_location with
                  | Tui_decode.Fc_in_repo location when String.equal location.repo_id repo_id ->
                      Some (change, location.relative_path)
                  | Tui_decode.Fc_in_repo _ | Tui_decode.Fc_in_bundle _ | Tui_decode.Fc_at_absolute_path _ -> None)
                  snapshot.fcs_changes) reading.war_keepers
          |> List.sort (fun ((a : Tui_decode.file_change), _) ((b : Tui_decode.file_change), _) ->
              Float.compare b.fc_at a.fc_at)

let workspace_activity_page_rows ~surface_rows = max 1 (surface_rows - 12)

(* The frame, Enter and a completed refresh share the same visible selection,
   including when the latest reading contains fewer rows. *)
let workspace_activity_selection state =
  let rows = workspace_activity_rows state in
  let cursor = max 0 (min state.workspace_activity_cursor (List.length rows - 1)) in
  (rows, cursor, List.nth_opt rows cursor)

let apply_workspace_activity_read state request result =
  state.workspace_activity <-
    Masc_tui_fetched.complete ~equal:String.equal state.workspace_activity
      request result;
  let _, cursor, _ = workspace_activity_selection state in
  state.workspace_activity_cursor <- cursor

let enter_keeper_code_file state ~keeper ~path =
  state.code_scope <- Code_scope_keeper keeper;
  let parent = Filename.dirname path in
  state.code_dir <- (if String.equal parent "." then "" else parent);
  state.code_cursor <- 0;
  state.code_entries <- [];
  state.code_entries_error <- None;
  state.code_file <- Masc_tui_fetched.clear state.code_file;
  state.code_file_cursor <- 0;
  state.code_file_scroll <- 0;
  state.code_file_hscroll <- 0;
  state.code_file_max_width <- 0;
  state.code_target_line <- None;
  state.code_lsp_note <- None;
  state.code_history <- Masc_tui_fetched.clear state.code_history;
  state.code_history_open <- false;
  state.code_history_scroll <- 0;
  state.code_diff <- Masc_tui_fetched.clear state.code_diff;
  state.code_diff_open <- false;
  state.code_diff_scroll <- 0;
  state.code_memos <- [];
  state.code_notes_open <- false;
  state.code_notes_scroll <- 0;
  state.code_blame <- Masc_tui_fetched.clear state.code_blame;
  state.code_focus_file <- Right_pane;
  state.followed_from <- Some (state.view, None);
  state.view <- Code

let selected_standalone_lane (state : state) =
  match state.standalone_lanes with
  | Some snapshot ->
      List.nth_opt snapshot.Tui_decode.sls_lanes state.lanes_standalone_cursor
  | None -> None

(** Row count of the standalone observation matrix, snapshot or not. Every
    mapping between the Lanes overview's two sections and one flat index --
    the "/" search list, its landing, a mouse press -- reads this, so the
    count cannot drift between the list and the landing. *)
let lanes_standalone_count (state : state) =
  match state.standalone_lanes with
  | None -> 0
  | Some snapshot -> List.length snapshot.Tui_decode.sls_lanes

(** Whether a goal lifecycle arm targets this goal. Answered here rather
    than at the renderer so the renderer never reads [pg_id] outside
    [Terminal_text] -- the sanitize guard counts every access, comparison
    included. *)
let goal_action_armed_for (state : state) (goal_id : string) =
  match state.goal_action_armed with
  | Some (armed_goal, armed_action) when String.equal armed_goal goal_id ->
      Some armed_action
  | Some _ | None -> None

(** New Keeper messages require a complete roster observation. [state.keepers]
    may intentionally retain the previous complete roster while a detail or log
    view survives a transient metadata read failure, so membership alone is not
    authorization for an external effect. *)
let keeper_available_for_new_message (state : state) keeper_name =
  Option.is_none state.keepers_error
  && List.exists
       (fun (keeper : keeper) -> String.equal keeper.k_name keeper_name)
       state.keepers

(* The composer is where the operator's keys go: the chat pane, whichever
   half of it has the cursor, or the composer row on another surface once it
   has taken focus. A draft put away by leaving the pane or releasing the
   row is text nobody is typing. *)
let composer_is_live (state : state) =
  state.view = Keepers Keeper_message || state.composer_focused

(* The operator is mid-line for this keeper: the composer is live, holds
   text, and is aimed here. While that is true, a settle should not dispatch
   the keeper's waiting line out from under the line being typed -- holding
   it lets the next Enter fold the two together. The hold ends with the
   compose: the composer emptied or sent, aimed at another keeper, or put
   away (the pane left, the row released), and each of those drains the
   queue so the released line goes then, not at some later settle. Gated on
   the setting: with coalescing off the operator wants every line its own
   turn, so the settle dispatches promptly. *)
let composing_for_keeper (state : state) keeper_name =
  state.coalesce_queued_input
  && composer_is_live state
  && Buffer.length state.msg_input > 0
  && Option.exists (String.equal keeper_name) state.msg_target_keeper_name

(** The next target both the input path and footer agree is safe to select.
    A pending request or live transcript stays pinned to its Keeper until that
    turn settles — this pane's own, which is what the pin is for. A request
    in flight to some other keeper used to disable the switch too, and the
    pane draws exactly that request as an "(also sending to X …)" row: the
    row being on screen meant the key that would take the operator to it was
    refused, which is the one moment it is wanted (#33852). A retained roster
    is not enough after a failed refresh: switching is disabled until the
    roster is readable again. *)
let next_keeper_message_target (state : state) =
  let this_pane_has_a_request_in_flight =
    match state.msg_target_keeper_name with
    | None -> false
    | Some current -> Option.is_some (inflight_for_keeper state current)
  in
  if
    Option.is_some state.keepers_error
    || Option.is_some state.msg_live
    || this_pane_has_a_request_in_flight
  then
    Masc_tui_keeper_selection.No_alternative
  else
    match state.msg_target_keeper_name with
    | None -> Masc_tui_keeper_selection.No_alternative
    | Some current_keeper ->
        Masc_tui_keeper_selection.next_message_target ~current_keeper
          ~keeper_ids:
            (List.map (fun (keeper : keeper) -> keeper.k_name) state.keepers)

(** Create initial state *)
let create_state
    ?(reasoning_visibility = Reasoning_hidden)
    ?(tool_visibility = Tools_compact)
    ~workspace
    ?(local_base_path = "")
    ~port
    ~refresh_interval
    ()
  =
  {
  metrics_scroll = 0;
  metrics_section = Section_fleet;
  agents = [];
  tasks = [];
  tasks_domain = [];
  task_flow = None;
  task_focus = Left_pane;
  help_open = false;
  keeper_deletions_open = false;
  keeper_deletions_loading = false;
  keeper_deletions_generation = 0;
  keeper_deletions_cursor = 0;
  keeper_deletions_scroll = 0;
  keeper_deletions = None;
  agenda_open = false;
  agenda_scroll = 0;
  hints_visible = true;
  coalesce_queued_input = true;
  voice_send_on_stop = false;
  answering_open = false;
  answering_scroll = 0;
  answering_cursor = 0;
  keeper_turn_finishes = [];
  keeper_turns_observed_at = None;
  context_inspector_open = false;
  context_inspector_keeper = None;
  context_inspector_loading = false;
  context_inspector_generation = 0;
  context_inspector_reading = None;
  context_inspector_tab = Masc_tui_context_inspector.Composition;
  context_inspector_cursor = 0;
  context_inspector_scroll = 0;
  context_inspector_exact = None;
  context_inspector_detail_scroll = 0;
  context_inspector_focus = Left_pane;
  context_inspector_turn_back = 0;
  (* The roster comes when it is asked for. Ctrl-L's Activity pane already
     answers "what is every keeper doing right now", and a name-only column
     beside the chat repeated that answer while taking 34 of the
     conversation's cells. Ctrl-B brings it back, and that press is the whole
     cost of being wrong here -- whereas the column was drawn on every frame
     whether or not anyone read it. *)
  roster_pane_hidden = true;
  acting_pane_hidden = false;
  acting_pane_scroll = 0;
  acting_pane_tab = Masc_tui_acting_pane.Tab_fleet;
  acting_chunk_projection = None;
  acting_pane_changes = Masc_tui_fetched.initial;
  acting_pane_changes_at = None;
  roster_marquee_frame = 0;
  activity_frame = -1;
  keeper_detail_focus = Right_pane;
  keeper_message_focus = Right_pane;
  server_identity = None;
  local_base_path;
  workspace_identity =
    (if String.equal local_base_path ""
     then Workspace_identity_match
     else Workspace_identity_unread);
  help_scroll = 0;
  image_open = false;
  browser_viewport = None;
  image_request_generation = 0;
  msx_open = false;
  msx_frame = None;
  msx_last_poll_ns = 0L;
  msx_menu_open = false;
  msx_notice = None;
  msx_menu_mode = Boot_game;
  msx_carts = [];
  msx_menu_index = 0;
  palette_open = false;
  palette_query = "";
  palette_cursor = 0;
  palette_mode = Palette_jump;
  search = None;
  search_last = "";
  voice_config = None;
  voice_config_error = None;
  voice_input_device = None;
  resources_list = None;
  resources_error = None;
  resources_cursor = 0;
  resource_content = None;
  resource_content_error = None;
  resource_pending_uri = None;
  resource_scroll = 0;
  resource_focus = Left_pane;
  config_pane = Config_runtime;
  tools_pane = Tools_surface;
  theme_choice = None;
  theme_cursor = 0;
  theme_before_preview = None;
  theme_filter = `All;
  prompts = Masc_tui_fetched.initial;
  prompts_cursor = 0;
  presets_snapshot = None;
  presets_error = None;
  presets_cursor = 0;
  preset_detail = Masc_tui_fetched.initial;
  preset_save_draft = None;
  preset_restore_armed = None;
  preset_report = None;
  preset_busy = false;
  prompts_show_fragments = false;
  prompts_show_runtime_assets = false;
  prompts_librarian_input = None;
  prompts_librarian_input_error = None;
  prompts_librarian_input_loading = false;
  runtime_config_view = None;
  runtime_config_status_open = false;
  runtime_config_status_scroll = 0;
  runtime_config_jump_section = None;
  config_models_rows = [];
  config_models_cursor = 0;
  runtime_config_view_error = None;
  runtime_config_cursor = 0;
  config_scroll = 0;
  detail_tab = Detail_info;
  keeper_run_cursor = 0;
  detail_reads = [];
  detail_read_generation = 0;
  keeper_sandbox_view = None;
  keeper_sandbox_view_error = None;
  keeper_sandbox_logs = None;
  keeper_sandbox_logs_error = None;
  keeper_sandbox_logs_generation = 0;
  keeper_sandbox_logs_inflight = None;
  keeper_config_view = None;
  keeper_config_view_error = None;
  github_identity_view = None;
  identity_view = None;
  identity_view_error = None;
  identity_login = None;
  identity_cursor = 0;
  identity_attempt_error = None;
  identity_filter = None;
  identity_app_form = None;
  github_identity_view_error = None;
  task_cursor = 0;
  task_detail_id = None;
  task_detail_scroll = 0;
  tasks_error = None;
  events = [];
  overview_event_scroll = 0;
  keepers = [];
  keepers_error = None;
  keeper_roster = Masc_tui_keeper_control.Roster_unobserved;
  keeper_roster_error = None;
  keeper_action_inflight = None;
  keeper_action_pending = None;
  keeper_action_serial = 0;
  composer_focused = false;
  voice_capture = None;
  voice_level_db = None;
  voice_stop_requested = None;
  voice_continuous = None;
  voice_floor = None;
  quit_armed = false;
  last_action = None;
  fleet_safety = None;
  fleet_safety_error = None;
  connection_status = Disconnected;
  local_workspace = Local_workspace_unread;
  view = Overview;
  followed_from = None;
  keeper_cursor = 0;
  runtime_pick_keeper = None;
  runtime_pick_cursor = 0;
  runtime_catalog = [];
  runtime_assignments = [];
  runtime_catalog_error = None;
  goal_timeline = None;
  task_history = None;
  verification_evidence = None;
  keeper_calls = None;
  keeper_calls_error = None;
  keeper_calls_keeper = None;
  keeper_calls_loading = false;
  keeper_calls_refresh_pending = false;
  keeper_calls_generation = 0;
  keeper_calls_scroll = 0;
  log_entries = [];
  log_error = None;
  log_scroll = 0;
  live_context = Masc_tui_context_state.empty;
  overview = None;
  overview_error = None;
  transport = None;
  transport_error = None;
  approval_snapshot = None;
  approvals_error = None;
  asks_snapshot = None;
  asks_error = None;
  ask_answer_mode = Ask_browsing;
  ask_cursor = 0;
  ask_question_cursor = 0;
  ask_question_scroll = 0;
  ask_draft = None;
  ask_text_entry = None;
  pending_ask_submit = None;
  ask_submit_inflight = false;
  keeper_tool_approvals = [];
  keeper_tool_approvals_error = None;
  keeper_tool_approvals_observed = false;
  keeper_tool_approvals_read = Snapshot_read.idle;
  keeper_turns = [];
  keeper_turns_error = None;
  keeper_turns_inflight = false;
  gate_pending = [];
  gate_modes = None;
  gate_queue_unavailable = None;
  gate_rules = [];
  gate_rules_unavailable = None;
  gate_error = None;
  gate_snapshot_observed = false;
  gate_snapshot_read = Snapshot_read.idle;
  keeper_yolo_names = [];
  keeper_tool_modes_observed = false;
  keeper_tool_modes_error = None;
  runtime_params = [];
  runtime_params_error = None;
  runtime_params_loading = false;
  runtime_params_cursor = 0;
  runtime_param_edit = None;
  runtime_params_notice = None;
  keeper_gate_modes = [];
  keeper_gate_judges = [];
  approval_flow = Masc_tui_operator_projection.Flow.initial;
  approval_detail_open = false;
  approval_detail_scroll = 0;
  approval_cursor = 0;
  pending_approval_action = None;
  board_posts = [];
  board_detail = Masc_tui_board_detail.initial;
  board_list_error = None;
  board_cursor = 0;
  msg_find = "";
  msg_find_at = None;
  board_sort = Board_hot;
  board_hearth = None;
  board_hearths = [];
  board_scroll = 0;
  board_mode = Board_list;
  board_focus = Right_pane;
  board_detail_wide = false;
  board_draft = Buffer.create 256;
  board_compose_armed = false;
  board_compose_reply_to = None;
  board_compose_hearth = None;
  board_post_inflight = false;
  board_post_error = None;
  board_vote_armed = None;
  planning = None;
  planning_baseline = None;
  planning_error = None;
  planning_cursor = 0;
  planning_scroll = 0;
  runtime_mode = Runtime_lanes;
  planning_mode = Planning_list;
  planning_filter = Planning_filter_active;
  planning_sort = Planning_sort_phase_priority;
  goal_action_armed = None;
  goal_action_error = None;
  schedules = None;
  schedules_error = None;
  schedules_read = Snapshot_read.idle;
  schedule_cursor = 0;
  schedule_scroll = 0;
  schedule_detail_id = None;
  schedule_wake_history = None;
  schedule_wake_history_error = None;
  schedule_wake_history_inflight = None;
  keeper_schedules = None;
  keeper_schedules_error = None;
  keeper_schedules_inflight = None;
  schedule_cancel_armed = None;
  schedule_cancel_error = None;
  lanes = None;
  keeper_lanes_inflight = false;
  standalone_lanes = None;
  standalone_lanes_error = None;
  standalone_lanes_inflight = false;
  standalone_lanes_generation = 0;
  clients_surface = None;
  clients_surface_error = None;
  clients_surface_inflight = false;
  clients_surface_scroll = 0;
  clients_surface_cursor = 0;
  clients_surface_generation = 0;
  lanes_mode = Lanes_overview;
  lanes_standalone_cursor = 0;
  lane_runs = None;
  lane_runs_error = None;
  lane_runs_next = None;
  lane_runs_total = None;
  lane_runs_loading = false;
  lane_runs_generation = 0;
  lane_runs_cursor = 0;
  lane_runs_scroll = 0;
  lane_run_detail = None;
  lane_run_detail_generation = 0;
  lane_run_detail_error = None;
  lane_run_detail_scroll = 0;
  keeper_secrets = [];
  lanes_error = None;
  lanes_action_error = None;
  system_logs = None;
  system_logs_error = None;
  tools_inventory = None;
  tools_request_generation = 0;
  tools_read_inflight = None;
  tools_error = None;
  skills_catalog = None;
  skills_catalog_error = None;
  tools_scroll = 0;
  tools_skill_cursor = 0;
  tools_skill_evidence = None;
  tools_async_observation = None;
  tools_async_observation_error = None;
  lane_addons = None;
  lane_addons_cached = Masc_tui_lane_addons.initial;
  lane_addons_generation = 0;
  browser_lane = None;
  browser_history = None;
  browser_history_generation = 0;
  browser_lane_visibility = Browser_lane_hidden;
  browser_lane_generation = 0;
  connectors = None;
  connectors_error = None;
  connectors_inflight = false;
  connectors_scroll = 0;
  connectors_cursor = 0;
  connectors_binding_cursor = 0;
  connector_unbind_armed = None;
  runtime_surface = None;
  runtime_surface_error = None;
  runtime_surface_scroll = 0;
  runtime_detail_target = None;
  runtime_detail_scroll = 0;
  runtime_lane_pick = None;
  runtime_lane_pick_cursor = 0;
  runtime_lane_error = None;
  runtime_cursor = 0;
  runtime_surface_generation = 0;
  runtime_surface_inflight = None;
  runtime_surface_force_pending = false;
  repositories = None;
  repositories_error = None;
  repositories_inflight = false;
  repositories_scroll = 0;
  repositories_cursor = 0;
  workspace_activity_repo = None;
  workspace_activity = Masc_tui_fetched.initial;
  workspace_activity_cursor = 0;
  memory_health = None;
  memory_health_error = None;
  memory_health_inflight = false;
  memory_health_scroll = 0;
  memory_health_cursor = 0;
  memory_facts_keeper = None;
  memory_facts = None;
  memory_facts_error = None;
  memory_facts_cursor = 0;
  memory_facts_scroll = 0;
  memory_facts_category = Category_all;
  memory_facts_sort = Sort_recency;
  memory_overview_sort = Mem_overview_facts;
  repository_changes_open = false;
  repository_changes_scope = None;
  repository_changes = None;
  repository_changes_error = None;
  repository_changes_scroll = 0;
  repository_changes_cursor = 0;
  repository_changes_diff = None;
  repository_changes_diff_error = None;
  repository_changes_diff_path = None;
  repository_changes_diff_scroll = 0;
  repository_changes_return_chat = false;
  patch_modal_open = false;
  patch_modal_scroll = 0;
  patch_modal_path = None;
  patch_modal_diff = None;
  patch_modal_error = None;
  link_modal_open = false;
  link_modal_scroll = 0;
  link_modal_url = None;
  link_modal_links = [];
  link_modal_cursor = 0;
  link_previews_mode = `Rich;
  burn_hud_visible = false;
  code_dir = "";
  code_entries = [];
  code_entries_error = None;
  code_entries_inflight = false;
  code_cursor = 0;
  code_file = Masc_tui_fetched.initial;
  code_file_scroll = 0;
  code_file_cursor = 0;
  code_lsp_note = None;
  code_jump_back = [];
  code_file_hscroll = 0;
  code_file_max_width = 0;
  code_memos = [];
  code_focus_file = Left_pane;
  code_history = Masc_tui_fetched.initial;
  code_history_open = false;
  code_history_scroll = 0;
  code_diff = Masc_tui_fetched.initial;
  code_diff_open = false;
  code_diff_scroll = 0;
  code_notes_open = false;
  code_notes_scroll = 0;
  code_blame = Masc_tui_fetched.initial;
  code_scope = Code_scope_project;
  code_target_line = None;
  changes_keeper = None;
  changes = None;
  changes_error = None;
  changes_return = Changes_return_list;
  changes_cursor = 0;
  changes_scroll = 0;
  changes_diff_row = None;
  changes_diff_scroll = 0;
  changes_tree_diff = None;
  changes_tree_diff_error = None;
  changes_tree_diff_path = None;
  harness = None;
  harness_error = None;
  harness_inflight = false;
  harness_scroll = 0;
  harness_cursor = 0;
  harness_detail = None;
  harness_detail_scroll = 0;
  fusion_runs = None;
  fusion_error = None;
  fusion_cursor = 0;
  fusion_scroll = 0;
  fusion_mode = Fusion_list;
  fusion_runs_generation = 0;
  fusion_runs_inflight = None;
  fusion_detail = None;
  fusion_detail_error = None;
  fusion_detail_generation = 0;
  fusion_detail_inflight = None;
  fusion_historical_detail = None;
  fusion_historical_inflight = None;
  observer = Observer_off;
  mcp_session = None;
  observer_cursor = None;
  observer_replay = Observer_replay_unobserved;
  acting = [];
  acting_dropped = 0;
  acting_undecodable = 0;
  acting_undecodable_last = None;
  acting_scroll = 0;
  acting_unseen = 0;
  acting_filter = Masc_tui_acting.Turns;
  acting_cursor = 0;
  acting_detail = None;
  acting_detail_scroll = 0;
  verification = None;
  verification_error = None;
  verification_inflight = false;
  verification_scroll = 0;
  verification_cursor = 0;
  verification_detail_request_id = None;
  verification_detail_scroll = 0;
  verification_verdict_armed = None;
  verification_verdict_error = None;
  system_logs_scroll = 0;
  system_logs_cursor = 0;
  system_logs_min_level = None;
  system_logs_category = None;
  system_logs_detail_seq = None;
  system_logs_detail_scroll = 0;
  msg_input = Buffer.create 256;
  msg_attachments = [];
  msg_references = [];
  msg_attachments_since = None;
  msg_target_keeper_name = None;
  msg_return = Keeper_chat_return_detail;
  msg_drafts = [];
  msg_history = [];
  msg_recall_at = None;
  msg_recall_draft = "";
  msg_recall_replaces = None;
  msg_live = None;
  msg_loaded = [];
  msg_loaded_keeper = None;
  msg_loaded_error = None;
  msg_loaded_dropped = 0;
  msg_file_changes = None;
  msg_file_changes_keeper = None;
  msg_file_change_index = Masc_tui_keeper_chat_diff.empty;
  msg_file_changes_loading = false;
  msg_file_changes_refresh_pending = false;
  msg_file_changes_error = None;
  msg_file_changes_generation = 0;
  msg_memory_visibility = Memory_summary;
  msg_memory_error = None;
  msg_memory_dropped = 0;
  msg_history_load_generation = 0;
  msg_history_inflight = None;
  msg_scroll = 0;
  msg_scroll_pin = None;
  msg_older_cursor = None;
  msg_older_exist = false;
  msg_older_loading = false;
  msg_older_error = None;
  msg_reasoning_visibility = reasoning_visibility;
  (* Chat opens on the answer, not its bookkeeping. The gutter still carries
     the typed speaker/kind; Ctrl-F adds inline, then full timestamp/request
     metadata when the operator needs to trace a turn. *)
  msg_origin_display = Masc_tui_message_layout.Origin_inline;
  msg_tool_visibility = tool_visibility;
  msg_turn_folded = true;
  msg_spill = None;
  msg_queued = Masc_tui_keeper_chat_queue.empty;
  msg_inflight = [];
  msg_settled_logs = [];
  msg_journal_unavailable = [];
  msg_journal_inflight = [];
  msg_journal_reads_refused = false;
  msg_scroll_pin_settled = [];
  detail_scroll = 0;
  workspace;
  port;
  refresh_interval;
}

let visible_system_log_entries (state : state) =
  match state.system_logs with
  | None -> []
  | Some snapshot -> (
      match state.system_logs_category with
      | None -> snapshot.Tui_decode.sys_entries
      | Some wanted ->
          List.filter
            (fun entry ->
               match entry.Tui_decode.sl_category with
               | Some observed -> String.equal wanted observed
               | None -> false)
            snapshot.Tui_decode.sys_entries)

(* The row the renderer draws and the row this counts have to come from one
   predicate. A roster that failed to load leaves stale entries behind, so
   "registered" answers true while the send path is closed; counting on that
   answer hid the unavailable row and left the send hint reading Enter:send. *)
(* The rows the chat pane draws for one Keeper. Durable and session rows join
   only through request ownership. Turn order follows typed turn sequence or
   stable producer order; each turn is Input -> Progress -> Tool -> Output.
   Pending requests are withheld for the separate NEXT lane. Wall clocks never
   decide conversation order. *)
(* What a polled surface can say when it has no rows to draw. Three facts,
   not one: nothing has been read yet, the read failed, or the read came back
   with nothing. The first was drawn as the third -- "nothing waiting on a
   verdict" on a Verification surface that had not yet asked -- so an
   operator read an empty queue off a screen that knew no queue at all. *)
type empty_page =
  | Page_unread
  | Page_failed
  | Page_empty

let empty_page_of ~snapshot ~error =
  match (snapshot, error) with
  | _, Some _ -> Page_failed
  | None, None -> Page_unread
  | Some _, None -> Page_empty

(* The page for a list kept from this workspace's directory, which carries no
   snapshot of its own: the list is empty both before the read and after it. *)
let local_rows_page (state : state) ~error =
  empty_page_of ~error
    ~snapshot:
      (match state.local_workspace with
       | Local_workspace_unread -> None
       | Local_workspace_read -> Some ())

let compute_chat_rows_for (state : state) keeper_name ~promoted_request_id
    ~queued_request_ids =
  let not_promoted row =
    not
      (Option.exists
         (String.equal row.me_request_id)
         promoted_request_id)
  in
  let loaded =
    match state.msg_loaded_keeper with
    | Some loaded_keeper when String.equal loaded_keeper keeper_name ->
        List.filter not_promoted state.msg_loaded
    | Some _ | None -> []
  in
  let session =
    List.filter
      (fun entry ->
        String.equal entry.me_keeper_name keeper_name && not_promoted entry)
      state.msg_history
  in
  let held =
    settled_logs_for_keeper state keeper_name
    |> List.filter turn_log_holds_the_turn
    |> List.map held_turn_of_log
  in
  let loaded = rows_the_logs_do_not_draw ~held loaded in
  let session = rows_the_logs_do_not_draw ~held session in
  chat_timeline ~loaded ~session ~queued_request_ids |> chat_timeline_rows

(* One conversation's rows, computed once per change of its inputs.

   The projection walks every loaded row -- grouping into turns, timeline
   floors, a sort -- and the chat frame asked for it three to four times:
   on every key, every two-second tick and every async message, whether or
   not the conversation had changed. Its inputs are the loaded page, the
   loaded keeper, the session rows, the settled logs (whose held turns leave
   the timeline), and two small readings of the queue and the inflight list:
   which request was promoted out of the queue and which requests still
   wait. The lists are replaced rather than mutated in place
   when the conversation changes, so physical equality on them says whether
   the last answer still holds; the two readings are compared by value, so a
   queue or an inflight turn that changed in a way the rows do not depend on
   (a live turn streaming, another keeper's line) keeps the answer.

   Module state rather than a field on [state], like the renderer's markdown
   cache: a derived reading is not authority, and the input layer that reads
   these rows would otherwise have to invalidate it at every mutation site. *)
type chat_rows_memo = {
  crm_keeper_name : string;
  crm_loaded_keeper : string option;
  crm_loaded : msg_entry list;
  crm_history : msg_entry list;
  crm_settled_logs : turn_log list;
  crm_promoted_request_id : string option;
  crm_queued_request_ids : string list;
  crm_rows : msg_entry list;
}

let chat_rows_memo : chat_rows_memo option ref = ref None

let chat_rows_for (state : state) keeper_name =
  let promoted_request_id =
    Option.map
      (fun entry -> entry.sent_request.request_id)
      (promoted_inflight_for_keeper state keeper_name)
  in
  let queued_request_ids =
    Masc_tui_keeper_chat_queue.waiting_for_keeper state.msg_queued ~keeper_name
    |> List.map (fun item -> item.Masc_tui_keeper_chat_queue.request.request_id)
  in
  match !chat_rows_memo with
  | Some memo
    when String.equal memo.crm_keeper_name keeper_name
         && Option.equal String.equal memo.crm_loaded_keeper
              state.msg_loaded_keeper
         && memo.crm_loaded == state.msg_loaded
         && memo.crm_history == state.msg_history
         && memo.crm_settled_logs == state.msg_settled_logs
         && Option.equal String.equal memo.crm_promoted_request_id
              promoted_request_id
         && List.equal String.equal memo.crm_queued_request_ids
              queued_request_ids ->
      memo.crm_rows
  | Some _ | None ->
      let rows =
        compute_chat_rows_for state keeper_name ~promoted_request_id
          ~queued_request_ids
      in
      chat_rows_memo :=
        Some
          { crm_keeper_name = keeper_name;
            crm_loaded_keeper = state.msg_loaded_keeper;
            crm_loaded = state.msg_loaded;
            crm_history = state.msg_history;
            crm_settled_logs = state.msg_settled_logs;
            crm_promoted_request_id = promoted_request_id;
            crm_queued_request_ids = queued_request_ids;
            crm_rows = rows;
          };
      rows

(* The one place [msg_scroll] moves, so the pin it counts back from cannot be
   forgotten at one of the dozen keys that scroll. Leaving the bottom takes the
   pin; returning to it releases the pin, which is also the gesture for going
   back to following the turn. *)
(* The oldest moment among these rows, or nothing when there are none. *)
let oldest_at (entries : msg_entry list) =
  List.fold_left
    (fun oldest (entry : msg_entry) ->
      match oldest with
      | None -> Some entry.me_at
      | Some at -> Some (Float.min at entry.me_at))
    None entries

(* A refresh brings what is new at the bottom; it does not own the top.

   Rows the operator paged back to are older than anything the fresh window
   carries, so they are kept. Replacing the list with the fresh window alone
   threw them away on every tick, which is why paging back never got past
   whatever the first load happened to reach (#31089).

   The window does not own the middle either. The tail is bounded (100
   user/assistant rows, 400 lines absolute), and a keeper flooding approval
   rows evicts conversation rows the operator was reading: the old rule
   dropped every held row at or after the fresh window's oldest on the
   assumption the window carried it, so the middle of a conversation vanished
   on exactly the tick that pushed it out of the window (#32660). A held row
   survives unless the fresh window actually carries its identity; the
   carried copy replaces it. *)
let merge_paged_history ~(paged : msg_entry list) ~(fresh : msg_entry list) =
  let carried =
    List.fold_left
      (fun acc (entry : msg_entry) -> entry.me_identity :: acc)
      [] fresh
  in
  let held =
    List.filter
      (fun (entry : msg_entry) ->
         not (List.exists (fun identity -> identity = entry.me_identity) carried))
      paged
  in
  List.sort
    (fun (left : msg_entry) (right : msg_entry) ->
       Float.compare left.me_at right.me_at)
    (held @ fresh)

let set_msg_scroll (state : state) rows =
  let rows = max 0 rows in
  if rows = 0 then begin
    state.msg_scroll <- 0;
    state.msg_scroll_pin <- None;
    state.msg_scroll_pin_settled <- []
  end
  else begin
    if state.msg_scroll = 0 then begin
      state.msg_scroll_pin <-
        (match state.msg_target_keeper_name with
         | None -> None
         | Some keeper_name ->
           (match List.rev (chat_rows_for state keeper_name) with
            | newest :: _ -> Some (msg_anchor newest)
            | [] -> None));
      state.msg_scroll_pin_settled <- state.msg_settled_logs
    end;
    state.msg_scroll <- rows
  end

(* Rows the composer needs beyond its first. Folded into the status-row count
   because that one number already sets both the history height and the cursor
   row, so a composer that grew would otherwise push the cursor off the line it
   is editing. *)
let composer_extra_rows (state : state) =
  let lines =
    Masc_tui_message_layout.composer_lines
      ~max_rows:Masc_tui_message_layout.composer_max_rows
      (Buffer.contents state.msg_input)
  in
  max 0 (List.length lines - 1)

(** A scroll a frame had to hold inside what it could show.

    {!scrolled_surface} answers this before the frame is built, for the
    surfaces whose rows the state can count. The rest count rows the drawing
    formats -- lines of a task's notes, of a board post, of a keeper's detail
    -- so the bound is not knowable until the frame exists. Those frames say
    which value they used and the loop stores it, which is not the same as the
    drawing reaching back into the state it is drawing from: the drawing is a
    function of the state again, and every write lives on one side of it. *)
type clamped_scroll =
  | Overview_events of int
  | Task_detail of int
  | Board_read of int
  | Message_scroll of int
  | Schedule_detail_scroll of int
  | Keeper_detail of int
  | Keeper_calls of int
  | Acting of int
  | Acting_selection of int * int
  | Acting_detail_scroll of int
  | Verification_detail_scroll of int
  | Harness_detail_scroll of int
  | Fusion_detail_scroll of int
  | Runtime_detail_scroll of int
  | System_log_detail_scroll of int
  | Planning_detail_scroll of int
  | Lane_run_detail_scroll of int
  (* An open diff's rows are built by the drawing, out of the recorded before
     and after text, so the keypress cannot count them. It steps unbounded and
     the frame reports back what it could actually use: without that report
     the stored value kept climbing past the end of the diff, and coming back
     up took one keypress per step taken past it. *)
  | Changes_diff_scroll of int
  (* The Git Changes file diff is the same shape with its own scroll: the
     rows exist only once the drawing has read the tree, and the keypress
     stepped the stored value past them unbounded. *)
  | Repository_changes_diff_scroll of int
  (* Both surfaces worked out the row they could actually draw and then threw
     it away: the drawing clamped for display while the stored value kept
     climbing, so coming back up took one keypress per step taken past the
     end. Same report the diff already makes. *)
  | Resource_scroll of int
  (* The telemetry sections are lines the drawing formats out of the readings
     it holds, so their count is not knowable at the keypress either. This
     surface was the last one clamping for display without reporting: its
     page key climbed without a ceiling, and coming back from past the end
     took one press per step taken beyond it. Named here so End can reach the
     bottom of a section at all -- without a report there is nothing to
     correct the row it names. *)
  | Metrics_scroll of int
  | Approval_detail_scroll of int
  (* Both modals draw over a surface rather than being one, and both counted
     their rows the same way the diff does: the patch modal out of the recorded
     diff, the link preview out of the card the drawing formats. Neither count
     is knowable at the keypress, which steps by one or jumps to 9999 and lets
     the frame say where that landed. They wrote the answer back from inside
     the drawing instead, which is the one thing the renderer must not do. *)
  | Patch_modal_scroll of int
  | Link_modal_scroll of int

(* What End names on a surface whose rows the drawing counts: a row past any
   real end, so the frame's own clamp reports the last one back. The keypress
   cannot work the number out -- that is what a {!clamped_scroll} is -- and a
   value it can name has to be larger than any surface's rows.

   [max_int] rather than a number someone judged large enough. An MCP resource
   reading carries whatever text the server sent and the frame wraps it, so
   the row count has no ceiling to sit above; a finite sentinel is a row the
   reader can be left at, and it would be left there silently.

   Arithmetic on this value is safe because it does not survive a frame. The
   drawing clamps with [min state.resource_scroll max_scroll] and reports the
   result back through [Resource_scroll], so by the time a page key adds to
   [resource_scroll] it holds the real last row, not this. *)
let clamped_scroll_end = max_int

(* Moving down from [clamped_scroll_end]. The sentinel waits for a frame to
   count the real rows and report them back, and some frames pass without
   counting: a reading that has not arrived, and -- on a narrow terminal with
   the list focused -- a frame that draws no reading at all. A key pressed
   in between would carry the sentinel into [+], so the addition stops here
   instead of wrapping negative and throwing the reader to the top. Moving up
   needs no such care: [max 0] already holds that end. *)
let scroll_down_from scroll ~by =
  if scroll > max_int - by then max_int else scroll + by

let apply_clamped_scroll (state : state) = function
  | Overview_events value -> state.overview_event_scroll <- value
  | Task_detail value -> state.task_detail_scroll <- value
  | Board_read value -> state.board_scroll <- value
  | Message_scroll value -> set_msg_scroll state value
  | Schedule_detail_scroll value -> state.schedule_scroll <- value
  | Keeper_detail value -> state.detail_scroll <- value
  | Keeper_calls value -> state.keeper_calls_scroll <- value
  | Acting value -> state.acting_scroll <- value
  | Acting_selection (scroll, cursor) -> state.acting_scroll <- scroll; state.acting_cursor <- cursor
  | Acting_detail_scroll value -> state.acting_detail_scroll <- value
  | Verification_detail_scroll value ->
      state.verification_detail_scroll <- value
  | Harness_detail_scroll value -> state.harness_detail_scroll <- value
  | Fusion_detail_scroll value -> state.fusion_scroll <- value
  | Runtime_detail_scroll value -> state.runtime_detail_scroll <- value
  | System_log_detail_scroll value -> state.system_logs_detail_scroll <- value
  | Planning_detail_scroll value -> state.planning_scroll <- value
  | Lane_run_detail_scroll value -> state.lane_run_detail_scroll <- value
  | Changes_diff_scroll value -> state.changes_diff_scroll <- value
  | Repository_changes_diff_scroll value ->
      state.repository_changes_diff_scroll <- value
  | Resource_scroll value -> state.resource_scroll <- value
  | Metrics_scroll value -> state.metrics_scroll <- value
  | Approval_detail_scroll value -> state.approval_detail_scroll <- value
  | Patch_modal_scroll value -> state.patch_modal_scroll <- value
  | Link_modal_scroll value -> state.link_modal_scroll <- value

(* Changes draws a preview under its list, so the rows the list can use are
   fewer than the chrome alone says. The number of rows the list keeps lives
   here because both the drawing and the keypress need it; Masc_tui_scroll
   works the split out from it. *)
let changes_preview_keep_rows = 5

(* The over-budget note and its divider, which the Changes drawing puts above
   the list. Chrome the drawing adds conditionally has to be counted here too
   -- a bound worked out from fewer chrome rows than the frame uses lets the
   cursor name a row the frame will not draw. *)
let changes_budget_note_rows (state : state) =
  match state.changes with
  | Some s when s.Tui_decode.fcs_over_budget > 0 -> 2
  | Some _ | None -> 0

(* The strip above the composer: what fires next, and who is blocked on the
   operator. Both are already in the state and neither was readable from the
   surface where the question comes up, so this is a projection rather than a
   new reading.

   A schedule with no due time is not on the clock half. It keeps its row on
   the Schedules surface, which is where a schedule without a time is still
   worth seeing; a strip that draws one wake has to draw the one it can say a
   time for. *)
let agenda (state : state) : Masc_tui_agenda.t =
  let scheduled =
    match state.schedules with
    | None -> []
    | Some snapshot ->
      List.filter_map
        (fun (row : schedule_row) ->
           match row.sch_due_at_iso with
           | None -> None
           | Some at_iso ->
             Some
               { Masc_tui_agenda.at_iso
               ; standing = Masc_tui_agenda.standing_of_wire row.sch_status
               ; who = Option.value row.sch_payload_target ~default:""
               ; what = Option.value row.sch_payload_summary ~default:""
               ; recurrence = row.sch_recurrence_summary
               })
        snapshot.scs_rows
  in
  let awaiting =
    List.map
      (fun (held : Tui_decode.keeper_tool_approval) ->
         { Masc_tui_agenda.asked_by = held.kta_keeper
         ; question = held.kta_tool
         ; asked_at = held.kta_asked_at
         ; timeout_sec = held.kta_timeout_sec
         })
      state.keeper_tool_approvals
  in
  Masc_tui_agenda.project ~scheduled ~awaiting
;;

(* Rows the agenda strip takes from every surface. Added once, here, rather
   than per surface: the strip is drawn by [finish_surface], which every
   surface ends in, so a bound that forgot it would be a bound no surface
   remembered to fix. *)
let agenda_chrome_rows (state : state) =
  (* The overlay lists the same wakes the strip names one of, so the strip
     stands down while it is open rather than saying the first row twice --
     and the panel gets the row. *)
  if state.agenda_open then 0 else Masc_tui_agenda.rows_taken (agenda state)
;;

(* The rows a surface may draw in: the terminal's, less the composer's row and
   less whatever the agenda strip took. One owner, because the frame subtracts
   both before it lays the body out and a surface that measured only the
   composer draws one row too many -- the frame then cuts its last row, which
   is the footer. Every surface lost its key hints, version, base path and port
   the moment a wake or a waiting keeper put the strip on screen. *)
let surface_body_rows (state : state) ~terminal_rows =
  max
    1
    (terminal_rows
     - Masc_tui_composer.rows_for ~terminal_rows
     - agenda_chrome_rows state)
;;

let standalone_lanes_chrome ~row_count ~error ~truncated =
  let evidence_rows = match row_count with None -> 1 | Some count -> count in
  let stale_error_row =
    if Option.is_some row_count && Option.is_some error then 1 else 0
  in
  2 + evidence_rows + stale_error_row + (if truncated then 1 else 0)
;;

let lanes_scrolled (state : state) =
  match state.lanes_mode with
  | Lanes_run_list _ ->
      (* The run list replaces the two-section overview, so the typed model
         counts its rows instead of the Keeper table's. *)
      { sc_count =
          (match state.lane_runs with
           | None -> 0
           | Some runs -> List.length runs)
      ; sc_chrome = listing_chrome ~error:state.lane_runs_error
      ; sc_overflow_takes_row = true
      ; sc_preview_keep = None
      }
  | Lanes_run_detail _ ->
      (* The detail's lines are built by the drawing; the frame reports the
         clamp through [clamped_scroll], so no count is knowable here. *)
      { sc_count = 0
      ; sc_chrome = 0
      ; sc_overflow_takes_row = false
      ; sc_preview_keep = None
      }
  | Lanes_overview ->
  { sc_count = lanes_standalone_count state
  ; sc_chrome =
      standalone_lanes_chrome
        ~row_count:
          (Option.map
             (fun snapshot -> List.length snapshot.Tui_decode.sls_lanes)
             state.standalone_lanes)
        ~error:state.standalone_lanes_error
        ~truncated:
          (match state.standalone_lanes with
           | None -> false
           | Some snapshot -> snapshot.sls_exact_run_projection_truncated)
      + (if Option.is_some state.lanes_action_error then 1 else 0)
  ; sc_overflow_takes_row = true
  ; sc_preview_keep = None
  }

(** Where a left-button press lands on the Standalone-only Lanes overview. *)
type lanes_overview_hit =
  | Lanes_hit_standalone of int  (** index into [sls_lanes] *)
  | Lanes_hit_none  (** chrome, notes and padding: nothing to select *)

(* The first standalone row is the frame's sixth line: surface strip, box top,
   header, divider, matrix heading. [render_lanes_overview] draws in that
   order and this answers a click from the same order -- a row added to either
   section moves both. *)
let lanes_overview_first_standalone_row = 6

let lanes_overview_hit (state : state) ~terminal_rows:_ ~row : lanes_overview_hit =
  if row < lanes_overview_first_standalone_row then Lanes_hit_none
  else
    let standalone_count = lanes_standalone_count state in
    let offset = row - lanes_overview_first_standalone_row in
    if offset < standalone_count then Lanes_hit_standalone offset
    else Lanes_hit_none

(* One browsable row of the Memory fact browser. The three kinds keep their
   sections apart -- an ordinary fact, a fact bound to a file, and a fact
   the store dropped -- while the cursor walks them as one flat list. *)
type memory_fact_row =
  | Memory_row_fact of Tui_decode.memory_fact
  | Memory_row_source_fact of Tui_decode.memory_source_fact
  | Memory_row_invalidation of Tui_decode.memory_invalidation

(* The three palette matchers fold case themselves, on both sides. A caller
   hands them the operator's text as typed; "ADM" and "adm" find the same
   rows, and a new caller cannot forget a step it never had. *)

(* Prefix match: the label starts with the query. An empty query is a prefix
   of everything. *)
let palette_starts_with ~needle haystack =
  String.starts_with
    ~prefix:(String.lowercase_ascii needle)
    (String.lowercase_ascii haystack)

let palette_contains ~needle haystack = lowercase_contains ~needle haystack

let memory_overview_query (state : state) =
    match state.search with
    | Some q -> String.lowercase_ascii (String.trim q)
    | None ->
        if String.length (String.trim state.search_last) > 0 then
          String.lowercase_ascii (String.trim state.search_last)
        else ""


let visible_memory_keepers (state : state) =
  let open Tui_decode in
  let raw_keepers =
    match state.memory_health with
    | None -> []
    | Some s -> s.mhs_keepers
  in
  let sorted_keepers =
    match state.memory_overview_sort with
    | Mem_overview_facts ->
        List.sort
          (fun (a : memory_keeper_health) (b : memory_keeper_health) ->
            if a.mkh_facts <> b.mkh_facts then Stdlib.compare b.mkh_facts a.mkh_facts
            else String.compare a.mkh_keeper_id b.mkh_keeper_id)
          raw_keepers
    | Mem_overview_size ->
        List.sort
          (fun a b ->
            if a.mkh_snapshot_bytes <> b.mkh_snapshot_bytes then
              Stdlib.compare b.mkh_snapshot_bytes a.mkh_snapshot_bytes
            else String.compare a.mkh_keeper_id b.mkh_keeper_id)
          raw_keepers
    | Mem_overview_delta ->
        List.sort
          (fun a b ->
            let da = a.mkh_added + a.mkh_removed in
            let db = b.mkh_added + b.mkh_removed in
            if da <> db then Stdlib.compare db da
            else String.compare a.mkh_keeper_id b.mkh_keeper_id)
          raw_keepers
    | Mem_overview_state ->
        List.sort
          (fun a b ->
            let sa = memory_state a in
            let sb = memory_state b in
            if sa <> sb then Stdlib.compare sb sa
            else String.compare a.mkh_keeper_id b.mkh_keeper_id)
          raw_keepers
    | Mem_overview_updated ->
        List.sort (fun a b ->
            let by_time = Stdlib.compare b.mkh_updated_at a.mkh_updated_at in
            if by_time <> 0 then by_time else String.compare a.mkh_keeper_id b.mkh_keeper_id)
          raw_keepers
    | Mem_overview_name ->
        List.sort
          (fun a b -> String.compare a.mkh_keeper_id b.mkh_keeper_id)
          raw_keepers
  in
  let query = memory_overview_query state in
    if query = "" then sorted_keepers
    else
      List.filter
        (fun k ->
          palette_contains ~needle:query k.mkh_keeper_id
          || palette_contains ~needle:query (memory_state_label (memory_state k)))
        sorted_keepers



let selected_memory_keeper (state : state) =
  let rows = visible_memory_keepers state in
  List.nth_opt rows (max 0 (min state.memory_health_cursor (List.length rows - 1)))

let memory_overview_scrolled ?cursor (state : state) =
  let keepers = visible_memory_keepers state in
  let count = List.length keepers in
  let cursor = Option.value cursor ~default:state.memory_health_cursor in
  let context_rows =
    match List.nth_opt keepers (max 0 (min cursor (count - 1))) with
    | None -> 0
    | Some keeper ->
        (* Divider, snapshot, facts, source, Librarian and Vision, then the
           selected keeper's read errors and server alerts. *)
        6 + List.length keeper.mkh_alerts
        + (if Option.is_some keeper.mkh_read_error then 1 else 0)
        + (if Option.is_some keeper.mkh_source_read_error then 1 else 0)
  in
  { sc_count = count
  ; sc_chrome =
      Masc_tui_frame.chrome_rows
      (* Totals, Librarian, legend, sort, divider, headings, divider. *)
      + 7 + context_rows
      + (if memory_overview_query state <> "" then 1 else 0)
      + (if Option.is_some state.memory_health_error then 2 else 0)
  ; sc_overflow_takes_row = true
  ; sc_preview_keep = None
  }

(* The flat row list the browser's cursor, scroll, and search all read. The
   category filter narrows only ordinary facts: source-bound rows carry no
   category, and hiding them under a category filter would read as the store
   losing them. A store that failed to read or has no snapshot contributes
   no rows here; the render names that state in its section header. *)
let memory_fact_rows (state : state) : memory_fact_row list =
  match state.memory_facts with
  | None -> []
  | Some snapshot ->
      let ordinary =
        match snapshot.Tui_decode.mfs_ordinary with
        | Tui_decode.Memory_store_read_error _ | Tui_decode.Memory_store_absent
          ->
            []
        | Tui_decode.Memory_store_present store ->
            let facts =
              match state.memory_facts_category with
              | Category_all -> store.Tui_decode.mos_facts
              | Category_ordinary category ->
                  List.filter
                    (fun (fact : Tui_decode.memory_fact) ->
                      String.equal fact.Tui_decode.mf_category category)
                    store.Tui_decode.mos_facts
              | Category_source | Category_dropped -> []
            in
            List.map (fun fact -> Memory_row_fact fact) facts
      in
      let source_rows, invalidation_rows =
        match snapshot.Tui_decode.mfs_source with
        | Tui_decode.Memory_store_read_error _ | Tui_decode.Memory_store_absent
          ->
            ([], [])
        | Tui_decode.Memory_store_present store ->
            let src =
              match state.memory_facts_category with
              | Category_all | Category_source ->
                  List.map
                    (fun fact -> Memory_row_source_fact fact)
                    store.Tui_decode.mss_facts
              | Category_ordinary _ | Category_dropped -> []
            in
            let inv =
              match state.memory_facts_category with
              | Category_all | Category_dropped ->
                  List.map
                    (fun row -> Memory_row_invalidation row)
                    store.Tui_decode.mss_invalidations
              | Category_ordinary _ | Category_source -> []
            in
            (src, inv)
      in
      let all_rows = ordinary @ source_rows @ invalidation_rows in
      let query =
        match state.search with
        | Some q -> String.trim q
        | None -> String.trim state.search_last
      in
      let filtered_rows =
        if query = "" then all_rows
        else
          List.filter
            (fun row ->
              let text =
                match row with
                | Memory_row_fact f ->
                    f.Tui_decode.mf_claim ^ " " ^ f.Tui_decode.mf_category ^ " "
                    ^ f.Tui_decode.mf_origin
                | Memory_row_source_fact f ->
                    f.Tui_decode.msf_claim ^ " " ^ f.Tui_decode.msf_path
                | Memory_row_invalidation f ->
                    f.Tui_decode.mi_reason ^ " " ^ f.Tui_decode.mi_source_path
              in
              palette_contains ~needle:query text)
            all_rows
      in
      (match state.memory_facts_sort with
       | Sort_recency ->
           List.sort
             (fun a b ->
               let ts = function
                 | Memory_row_fact f -> f.Tui_decode.mf_last_seen
                 | Memory_row_source_fact f -> f.Tui_decode.msf_first_seen
                 | Memory_row_invalidation f -> f.Tui_decode.mi_invalidated_at
               in
               Stdlib.compare (ts b) (ts a))
             filtered_rows
       | Sort_last_retrieved ->
           (* Facts by their last retrieval, newest first. A fact never
              retrieved, then the source and dropped rows, follow in their
              recency order: the record says nothing about them, so nothing
              is invented. *)
           List.sort
             (fun a b ->
               let key = function
                 | Memory_row_fact f ->
                   (match f.Tui_decode.mf_events.Tui_decode.mfe_last_retrieved_at with
                    | Some at -> (0, at)
                    | None -> (1, f.Tui_decode.mf_last_seen))
                 | Memory_row_source_fact f -> (2, f.Tui_decode.msf_first_seen)
                 | Memory_row_invalidation f -> (2, f.Tui_decode.mi_invalidated_at)
               in
               let g_a, t_a = key a in
               let g_b, t_b = key b in
               if g_a <> g_b then Stdlib.compare g_a g_b else Stdlib.compare t_b t_a)
             filtered_rows
       | Sort_retrieved_count ->
           List.sort
             (fun a b ->
               let key = function
                 | Memory_row_fact f ->
                   ( 0
                   , f.Tui_decode.mf_events.Tui_decode.mfe_retrieved_count
                   , f.Tui_decode.mf_last_seen )
                 | Memory_row_source_fact f -> (1, 0, f.Tui_decode.msf_first_seen)
                 | Memory_row_invalidation f -> (1, 0, f.Tui_decode.mi_invalidated_at)
               in
               let g_a, n_a, t_a = key a in
               let g_b, n_b, t_b = key b in
               if g_a <> g_b then Stdlib.compare g_a g_b
               else if n_a <> n_b then Stdlib.compare n_b n_a
               else Stdlib.compare t_b t_a)
             filtered_rows
       | Sort_category ->
           List.sort
             (fun a b ->
               let cat = function
                 | Memory_row_fact f -> (0, f.Tui_decode.mf_category)
                 | Memory_row_source_fact _ -> (1, "source")
                 | Memory_row_invalidation _ -> (2, "dropped")
               in
               let p_a, c_a = cat a in
               let p_b, c_b = cat b in
               let c = String.compare c_a c_b in
               if c <> 0 then c
               else if p_a <> p_b then Stdlib.compare p_a p_b
               else
                 let claim = function
                   | Memory_row_fact f -> f.Tui_decode.mf_claim
                   | Memory_row_source_fact f -> f.Tui_decode.msf_claim
                   | Memory_row_invalidation f -> f.Tui_decode.mi_reason
                 in
                 String.compare (claim a) (claim b))
             filtered_rows
       | Sort_claim ->
           List.sort
             (fun a b ->
               let claim = function
                 | Memory_row_fact f -> f.Tui_decode.mf_claim
                 | Memory_row_source_fact f -> f.Tui_decode.msf_claim
                 | Memory_row_invalidation f -> f.Tui_decode.mi_reason
               in
               String.compare (claim a) (claim b))
             filtered_rows)

(* The categories the loaded ordinary store and source store actually hold, distinct and
   sorted -- the [c] cycle walks these. Read from the rows, never from a
   list this side hardcodes: the taxonomy is the server's, and a category it
   adds appears here without a code change. *)
let memory_fact_categories (state : state) : memory_category_filter list =
  match state.memory_facts with
  | None -> []
  | Some snapshot ->
      let ordinary_cats =
        match snapshot.Tui_decode.mfs_ordinary with
        | Tui_decode.Memory_store_read_error _ | Tui_decode.Memory_store_absent
          ->
            []
        | Tui_decode.Memory_store_present store ->
            store.Tui_decode.mos_facts
            |> List.map (fun (fact : Tui_decode.memory_fact) ->
                 Category_ordinary fact.Tui_decode.mf_category)
            |> List.sort_uniq Stdlib.compare
      in
      let source_cats =
        match snapshot.Tui_decode.mfs_source with
        | Tui_decode.Memory_store_read_error _ | Tui_decode.Memory_store_absent
          ->
            []
        | Tui_decode.Memory_store_present store ->
            (if store.Tui_decode.mss_facts <> [] then [ Category_source ] else [])
            @ (if store.Tui_decode.mss_invalidations <> [] then [ Category_dropped ] else [])
      in
      ordinary_cats @ source_cats

(* All -> first category -> ... -> last -> All. A [current] that is no
   longer among [categories] (the snapshot refreshed under the filter)
   restarts at All rather than guessing a neighbour. *)
let next_memory_category (current : memory_category_filter)
    (categories : memory_category_filter list) : memory_category_filter =
  match current with
  | Category_all -> (match categories with [] -> Category_all | first :: _ -> first)
  | c ->
      let rec after = function
        | [] -> Category_all
        | candidate :: rest ->
            if candidate = c then
              (match rest with [] -> Category_all | next :: _ -> next)
            else after rest
      in
      after categories

let prev_memory_category (current : memory_category_filter)
    (categories : memory_category_filter list) : memory_category_filter =
  match current with
  | Category_all -> (match List.rev categories with [] -> Category_all | last :: _ -> last)
  | c ->
      let rev = List.rev categories in
      let rec before = function
        | [] -> Category_all
        | candidate :: rest ->
            if candidate = c then
              (match rest with [] -> Category_all | prev :: _ -> prev)
            else before rest
      in
      before rev

type runtime_picker_projection = {
  rlp_lane : string;
  rlp_already : string list;
  rlp_providers : string list;
  rlp_choices : Tui_decode.runtime_option list;
}

(* The picker serves both lane kinds. A conversation lane names its runtime id
   and reads its current order from the runtime surface's resolved lanes; an
   exact-output lane arrives as "exact/<name>" and reads its walk order from
   the standalone-lane observation, which carries the admitted slots. *)
let lane_picker_existing_slots (state : state) (lane : string) =
  let exact_prefix = "exact/" in
  if String.length lane > String.length exact_prefix
     && String.equal (String.sub lane 0 (String.length exact_prefix)) exact_prefix
  then
    let name = String.sub lane (String.length exact_prefix) (String.length lane - String.length exact_prefix) in
    match state.standalone_lanes with
    | None -> []
    | Some snapshot ->
        snapshot.Tui_decode.sls_lanes
        |> List.find_opt (fun (row : Tui_decode.standalone_lane) ->
             String.equal row.Tui_decode.sl_lane_id name)
        |> Option.map (fun row -> row.Tui_decode.sl_admitted_slots)
        |> Option.value ~default:[]
  else
    match state.runtime_surface with
    | None -> []
    | Some snapshot ->
        snapshot.Tui_decode.rss_resolved.rrs_lanes
        |> List.find_opt (fun row -> String.equal row.Tui_decode.rrl_id lane)
        |> Option.map (fun row -> row.Tui_decode.rrl_runtime_ids)
        |> Option.value ~default:[]

let runtime_picker_projection (state : state) =
  Option.map (fun lane ->
    let already = lane_picker_existing_slots state lane in
    let providers = already |> List.filter_map (fun id ->
      state.runtime_catalog
      |> List.find_opt (fun runtime -> String.equal runtime.Tui_decode.ro_id id)
      |> Option.map (fun runtime -> runtime.Tui_decode.ro_provider)) in
    let choices = runtimes_for_lane_picker ~lane_providers:providers ~already state.runtime_catalog
      |> List.filteri (fun i _ -> i >= state.runtime_lane_pick_cursor && i < state.runtime_lane_pick_cursor + 3)
    in
    { rlp_lane = lane; rlp_already = already; rlp_providers = providers; rlp_choices = choices })
    state.runtime_lane_pick

let runtime_surface_listing_chrome state =
  runtime_listing_chrome ~error:state.runtime_surface_error
    ~action_error:state.runtime_lane_error
    ~picker_rows:(Option.map (fun picker -> List.length picker.rlp_choices)
      (runtime_picker_projection state))

let scrolled_surface_rows (state : state) : surface -> scrolled option =
  let listing ~error count =
    Some
      { sc_count = count
      ; sc_chrome = listing_chrome ~error
      ; sc_overflow_takes_row = false
      ; sc_preview_keep = None
      }
  in
  (* One spelling for the overlay's rows. It draws the same list over three
     surfaces, and the count the keys move through has to be the count the
     frame draws, whichever surface it is over. *)
  let repository_changes_listing () =
    listing ~error:state.repository_changes_error
      (match state.repository_changes with
       | None -> 0
       | Some s -> List.length s.Tui_decode.rcs_changes)
  in
  function
  | System_logs ->
      if Option.is_some state.system_logs_detail_seq then None
      else Some
        { sc_count =
            (match state.system_logs with
             | None -> 0
             | Some _ -> List.length (visible_system_log_entries state))
        ; sc_chrome = system_log_listing_chrome ~error:state.system_logs_error
        ; sc_overflow_takes_row = false
        ; sc_preview_keep = None
        }
  | Verification ->
      if Option.is_some state.verification_detail_request_id then None
      else
        listing ~error:state.verification_error
          (match state.verification with
           | None -> 0
           | Some s -> List.length s.Tui_decode.vs_requests)
  | Lanes ->
      (match state.lanes_mode with
       | Lanes_run_detail _ -> None
       | Lanes_overview | Lanes_run_list _ -> Some (lanes_scrolled state))
  | Clients ->
      listing ~error:state.clients_surface_error
        (match state.clients_surface with
         | None -> 0
         | Some snapshot -> List.length snapshot.Tui_decode.cls_clients)
  | Harness ->
      if Option.is_some state.harness_detail then None
      else
        listing ~error:state.harness_error
          (match state.harness with
           | None -> 0
           | Some s -> List.length s.Tui_decode.hs_verdicts)
  | Repositories ->
      if state.repository_changes_open then repository_changes_listing ()
      else
        listing ~error:state.repositories_error
          (match state.repositories with
           | None -> 0
           | Some s -> List.length s.Tui_decode.rs_repositories)
  | Memory ->
      if Option.is_some state.memory_facts_keeper then
        listing ~error:state.memory_facts_error
          (List.length (memory_fact_rows state))
      else
        Some (memory_overview_scrolled state)
  | Changes ->
      Some
        { sc_count =
            (match state.changes with
             | None -> 0
             | Some s -> List.length s.Tui_decode.fcs_changes)
        ; sc_chrome =
            listing_chrome ~error:state.changes_error
            + changes_budget_note_rows state
        ; sc_overflow_takes_row = false
        ; sc_preview_keep = Some changes_preview_keep_rows
        }
  | Code when state.repository_changes_open -> repository_changes_listing ()
  (* [d] on the roster, the detail and the chat pane opens the overlay
     without leaving the Keepers surface, and the frame draws it there. With
     no arm here the surface read as unlisted, so the up-key added its delta
     to the scroll with no bound and stored a negative one; the frame then
     indexed the list with it and the process exited (four times between
     2026-09-05 and 2026-09-11). The three modes are the ones the frame
     draws the overlay over. *)
  | Keepers (Keeper_list | Keeper_detail | Keeper_message)
    when state.repository_changes_open -> repository_changes_listing ()
  | Connectors when Option.is_some (browser_lane_on_screen state) -> None
  | Connectors ->
      listing ~error:state.connectors_error
        (match state.connectors with
         | None -> 0
         | Some s -> List.length s.Tui_decode.cs_connectors)
  | Runtime ->
      if Option.is_some state.runtime_detail_target then None
      else Some
        { sc_count =
            (* The two views draw different lists, and the scroll bound is the
               list being drawn. Reading candidates in both stopped the roster
               at the slot count and left the runtimes past it unreachable. *)
            (match state.runtime_surface, state.runtime_mode with
             | None, _ -> 0
             | Some s, Runtime_lanes ->
                 List.length s.Tui_decode.rss_candidates
             | Some s, Runtime_all ->
                 List.length s.Tui_decode.rss_resolved.Tui_decode.rrs_runtimes)
        ; sc_chrome = runtime_surface_listing_chrome state
        ; sc_overflow_takes_row = false
        ; sc_preview_keep = None
        }
  | Config when state.config_pane = Config_runtime && state.runtime_config_status_open -> None
  | Config when state.config_pane = Config_runtime ->
      Some
        { sc_count = (match state.runtime_config_view with None -> 0 | Some r -> List.length r.rcv_rows)
        ; sc_chrome = 7 + (match state.runtime_config_view with None -> 0 | Some r ->
              List.length (Masc_tui_runtime_config_view.summary_lines r.rcv_metadata))
        ; sc_overflow_takes_row = false
        ; sc_preview_keep = None
        }
  | Config ->
      (* Per pane, because the two panes over the same file are different
         lengths: the source pane draws every line, the models pane draws one
         row per binding plus a header. One count for both let the keys run
         off the end of the shorter one. *)
      listing ~error:state.runtime_config_view_error
        (match state.config_pane with
         | Config_models ->
           (match state.runtime_config_view with
            | None -> 0
            | Some _ -> List.length state.config_models_rows + 1)
         (* The voice pane draws its own short block rather than the config
            file, so it scrolls with the same rule as the rest: whatever the
            renderer laid out. *)
         | Config_runtime | Config_params | Config_prompts | Config_presets
         | Config_themes | Config_voice ->
           (match state.runtime_config_view with
            | None -> 0
            | Some reading -> List.length reading.rcv_rows))
  (* Acting counts rows the drawing builds out of formatted text, not rows the
     state holds; counting them here would be a second copy of the formatting,
     so it reports a [clamped_scroll] instead. Overview, Keepers, Board,
     Planning and Schedules move a cursor or a detail pane rather than a plain
     list. *)
  | Overview | Acting | Metrics | Keepers _ | Board | Approvals | Planning | Schedules
  | Fusion | Resources | Code | Tools ->
      None

(* Callers pass [surface_body_rows], which has already removed the composer
   and agenda strip. Adding the agenda again here makes every key bound one row
   shorter than the renderer whenever the strip is present. *)
let scrolled_surface (state : state) (surface : surface) : scrolled option =
  scrolled_surface_rows state surface
;;

(* The text a "/" search reads for each row: the identifiers an operator
   would type, not the drawn bytes. [Some texts] means the surface is
   searchable and [texts] is the same decoded list the row cursor names, in
   the same order -- a match index is a cursor position. [None] keeps "/"
   closed on that surface. *)
(* One list under one cursor: the calls keepers are holding first (they run
   out in [kta_timeout_sec]; the operator actions keep), then the operator
   actions. The two kinds answer through different routes, so the row is a
   sum the key handler matches on rather than a shape it infers. *)
type approval_row =
  | Keeper_tool_row of Tui_decode.keeper_tool_approval
  | Gate_row of Tui_decode.gate_pending
      (** A durable Gate approval — an external-service write among them.
          It keeps: nobody watching loses nothing. Answered through the
          dashboard resolve route. *)
  | Operator_row of Masc_tui_operator_projection.approval_item

let operator_approval_items (state : state) =
  match state.approval_snapshot with
  | Some snapshot -> snapshot.aps_items
  | None -> []

let approval_items (state : state) =
  List.map (fun held -> Keeper_tool_row held) state.keeper_tool_approvals
  @ List.map (fun pending -> Gate_row pending) state.gate_pending
  @ List.map (fun item -> Operator_row item) (operator_approval_items state)

let is_surface_active (state : state) (s : surface) =
  match s with
  | Metrics -> false
  | Approvals ->
      state.view = Approvals || List.length (approval_items state) > 0
  | _ -> true
;;

let visible_surface_ring (state : state) : (surface * string) list =
  List.filter (fun (s, _) -> is_surface_active state s) surface_ring
;;

let visible_surface_ring_index (state : state) (view : surface) =
  let ring = visible_surface_ring state in
  let family =
    match view with
    | Keepers _ -> Keepers Keeper_list
    | Verification | Harness -> Planning
    | Connectors when Option.is_some (browser_lane_on_screen state) -> Config
    | Changes | Connectors | Schedules -> Keepers Keeper_list
    | Runtime | Lanes | Clients -> Config
    | Code -> Repositories
    | Resources | Tools -> Config
    | System_logs -> Acting
    | Metrics -> Overview
    | v -> v
  in
  let rec find i = function
    | [] -> 0
    | (surface, _) :: rest -> if surface = family then i else find (i + 1) rest
  in
  find 0 ring
;;

let braille_sparkline values =
  if values = [] then "⣀⡠⠤⠶"
  else
    let max_v = List.fold_left max 0.0001 values in
    let levels = [| " "; "⡀"; "⣀"; "⣄"; "⣤"; "⣦"; "⣶"; "⣷"; "⣿" |] in
    let glyphs =
      List.map
        (fun v ->
          let ratio = max 0.0 (min 1.0 (v /. max_v)) in
          let idx = min 8 (int_of_float (ratio *. 8.0)) in
          levels.(idx))
        values
    in
    String.concat "" glyphs
;;

let fleet_token_sparkline (state : state) =
  let tokens =
    List.map (fun (k : keeper) -> float_of_int k.k_total_tokens) state.keepers
  in
  braille_sparkline tokens
;;

let fleet_total_cost_usd (state : state) =
  List.fold_left (fun acc (k : keeper) -> acc +. k.k_total_cost_usd) 0.0 state.keepers
;;

let conversation_urls (state : state) : string list =
  let seen = Hashtbl.create 16 in
  let acc = ref [] in
  let scan (e : msg_entry) =
    let urls = Masc_tui_message_layout.bare_urls e.me_text in
    List.iter
      (fun u ->
         if not (Hashtbl.mem seen u) then begin
           Hashtbl.add seen u ();
           acc := u :: !acc
         end)
      urls
  in
  List.iter scan state.msg_history;
  List.iter scan state.msg_loaded;
  List.rev !acc
;;



let surface_row_texts (state : state) : surface -> string list option = function
  | Keepers Keeper_list ->
      Some (List.map (fun (k : keeper) -> k.k_name) state.keepers)
  | Keepers Keeper_detail when state.context_inspector_open ->
      (* The request tab's item labels, so the surface search (/) walks the
         same rows j/k moves. Other tabs keep no searchable list. *)
      if
        state.context_inspector_tab = Masc_tui_context_inspector.Exact_input
      then
        match state.context_inspector_reading with
        | Some
            ( _
            , { Masc_tui_context_inspector.provider_input = Ok input; _ } ) ->
            let labels =
              List.map
                (fun (item : Masc_tui_context_inspector.exact_input_item) ->
                   Masc_tui_context_inspector.exact_input_label item.kind)
                (Masc_tui_context_inspector.exact_input_items input)
            in
            (match labels with [] -> None | _ -> Some labels)
        | _ -> None
      else None
  | Lanes ->
      (match state.lanes_mode with
       | Lanes_run_list _ | Lanes_run_detail _ -> None
       | Lanes_overview ->
           let standalone =
             match state.standalone_lanes with
             | None -> []
             | Some snapshot ->
                 List.map
                   (fun (lane : Tui_decode.standalone_lane) -> lane.sl_label)
                   snapshot.Tui_decode.sls_lanes
           in
           (match standalone with [] -> None | _ -> Some standalone))
  | Clients ->
      let names =
        match state.clients_surface with
        | None -> []
        | Some snapshot ->
            List.map
              (fun (row : Tui_decode.client_row) -> row.Tui_decode.cr_name)
              snapshot.Tui_decode.cls_clients
      in
      (match names with [] -> None | _ -> Some names)
  | Verification ->
      if Option.is_some state.verification_detail_request_id then None
      else
        Option.map
          (fun s ->
            List.map
              (fun r ->
                r.Tui_decode.vr_task_id ^ " " ^ r.Tui_decode.vr_task_title ^ " "
                ^ r.Tui_decode.vr_submitted_by)
              s.Tui_decode.vs_requests)
          state.verification
  | Harness ->
      Option.map
        (fun s ->
          List.map
            (fun v -> v.Tui_decode.hv_task_id ^ " " ^ v.Tui_decode.hv_task_title)
            s.Tui_decode.hs_verdicts)
        state.harness
  | Repositories ->
      if state.repository_changes_open then
        Option.map
          (fun s ->
            List.map (fun row -> row.Tui_decode.rc_path) s.Tui_decode.rcs_changes)
          state.repository_changes
      else
        Option.map
          (fun s ->
            List.map
              (fun r ->
                r.Tui_decode.rp_name ^ " " ^ r.Tui_decode.rp_default_branch)
              s.Tui_decode.rs_repositories)
          state.repositories
  | Memory ->
      if Option.is_some state.memory_facts_keeper then
        (match memory_fact_rows state with
         | [] -> None
         | rows ->
             Some
               (List.map
                  (function
                    | Memory_row_fact fact ->
                        fact.Tui_decode.mf_category ^ " "
                        ^ fact.Tui_decode.mf_claim
                    | Memory_row_source_fact fact ->
                        fact.Tui_decode.msf_path ^ " "
                        ^ fact.Tui_decode.msf_claim
                    | Memory_row_invalidation row ->
                        row.Tui_decode.mi_source_path ^ " "
                        ^ row.Tui_decode.mi_reason)
                  rows))
      else
        Option.map
          (fun _ ->
            List.map (fun k -> k.Tui_decode.mkh_keeper_id)
              (visible_memory_keepers state))
          state.memory_health
  | Connectors when Option.is_some (browser_lane_on_screen state) -> None
  | Connectors ->
      Option.map
        (fun s ->
          List.map
            (fun c -> c.Tui_decode.cn_id ^ " " ^ c.Tui_decode.cn_display_name)
            s.Tui_decode.cs_connectors)
        state.connectors
  | Runtime ->
      Option.map
        (fun s ->
          List.map
            (fun c ->
              c.Tui_decode.rcr_lane_id ^ " "
              ^ c.Tui_decode.rcr_runtime.Tui_decode.ro_id)
            s.Tui_decode.rss_candidates)
        state.runtime_surface
  | System_logs ->
      Option.map
        (fun _ ->
          visible_system_log_entries state
          |> List.map
            (fun e ->
              e.Tui_decode.sl_module ^ " "
              ^ Option.value ~default:"" e.Tui_decode.sl_keeper
              ^ " " ^ e.Tui_decode.sl_message))
        state.system_logs
  | Code ->
      if state.repository_changes_open then
        Option.map
          (fun s ->
            List.map (fun row -> row.Tui_decode.rc_path) s.Tui_decode.rcs_changes)
          state.repository_changes
      else
      (* The Git changes overlay is a row list of its own. Otherwise, with a
         file focused (and no file overlay over it), "/" searches the file's
         lines; the tree remains the default search list. *)
      if
        state.code_focus_file = Right_pane && not state.code_history_open
        && not state.code_diff_open && not state.code_notes_open
      then
        (match Masc_tui_fetched.current state.code_file with
         | Some (_, Masc_tui_fetched.Ready rows) ->
           Some
             (Array.to_list
                (Array.map
                   (fun segments -> String.concat "" (List.map fst segments))
                   rows))
         (* Nothing to search through while the file is still being read, and
            nothing to search through if it failed. *)
         | Some (_, (Masc_tui_fetched.Loading | Masc_tui_fetched.Failed _))
         | Some (_, Masc_tui_fetched.Absent)
         | None -> None)
      else
        Some
          (List.map
             (fun (n : Tui_decode.workspace_tree_node) -> n.Tui_decode.wt_label)
             state.code_entries)
  (* Cursorless or otherwise-navigated surfaces: no row list to search. *)
  (* The list, and only while the list is the pane: reading a post or
     writing one draws something else, and "/" there would move a cursor
     nobody can see. The text is what identifies a row -- its id, who wrote
     it, its title -- which is what a reader has in mind when they reach for
     the key. *)
  | Board ->
      (match state.board_mode with
       | Board_read _ | Board_compose -> None
       | Board_list ->
           (match state.board_posts with
            | [] -> None
            | posts ->
                Some
                  (List.map
                     (fun (post : board_post) ->
                       post.bp_id ^ " " ^ post.bp_author ^ " " ^ post.bp_title)
                     posts)))
  (* The goals the filter and sort left on screen, in the order they are
     drawn: the cursor counts positions in that list, not in the snapshot. *)
  | Planning ->
      (match state.planning_mode with
       | Planning_detail _ -> None
       | Planning_list ->
           Option.bind state.planning (fun snapshot ->
               match
                 planning_visible_goals ~filter:state.planning_filter
                   ~sort:state.planning_sort snapshot.pl_goals
               with
               | [] -> None
               | goals ->
                   Some
                     (List.map
                        (fun (goal : planning_goal) ->
                          goal.pg_id ^ " " ^ goal.pg_title)
                        goals)))
  (* Approvals is absent on purpose. Its rows would search well, but [n] on
     that surface is deny, unarmed and immediate: offering "/" there invites
     the reflex that follows it, and on this surface that reflex refuses an
     approval instead of stepping to the next match. Verification met the
     same collision and moved its rejection to [x]; until Approvals makes
     that call, the safe answer is no row search. *)
  (* Two lists that grew a row cursor with the jump keys and had no way to be
     searched. Each is named by what an operator has in mind reaching for the
     key: the run and who called it, the file that was written.

     Approvals and Schedules are not here, and the reason is [n]. The key
     that steps to the next match is the key those two surfaces give to
     "deny this approval" and "write a new schedule". A search whose own
     follow-through refuses an approval is worse than no search, so offering
     it there needs a different step key rather than another arm here
     (#35306). *)
  | Fusion -> (
      match state.fusion_mode with
      | Fusion_detail _ | Fusion_historical_detail _ -> None
      | Fusion_list -> (
          match fusion_list_entries state with
          | [] -> None
          | entries ->
              Some
                (List.map
                   (fun entry ->
                     match entry with
                     | Tui_decode.Fusion_retained_run run ->
                         run.Tui_decode.fur_run_id ^ " "
                         ^ run.Tui_decode.fur_keeper ^ " "
                         ^ run.Tui_decode.fur_preset
                     | Tui_decode.Fusion_historical_evidence evidence ->
                         evidence.Tui_decode.fhe_post_id ^ " "
                         ^ evidence.Tui_decode.fhe_title)
                   entries)))
  | Changes -> (
      match state.changes with
      | None -> None
      | Some snapshot -> (
          match snapshot.Tui_decode.fcs_changes with
          | [] -> None
          | changes ->
              (* The address the row is drawn under, read from the one place
                 that spells it. A second match here would find a row under an
                 address the pane never shows. *)
              Some
                (List.map
                   (fun change -> Tui_decode.file_change_address change)
                   changes)))
  (* The list pane only. With the text focused j/k scrolls the reading and
     there is no row cursor for a match to land on, so the same condition the
     cursor arm reads answers here: a search offered on one focus and silent
     on the other would be the drift this pairing exists to prevent. *)
  | Resources when state.resource_focus = Left_pane ->
      Option.map (List.map Masc_tui_mcp.display_name) state.resources_list
  | Overview | Acting | Metrics | Keepers _ | Approvals | Schedules
  | Resources | Config | Tools ->
      None

(* Whether the chat pane is parked somewhere other than the newest row.

   One reader, because two sides act on it: the row budget below reserves a
   line for the notice, and the pane draws it. Counting a row nothing draws
   floats the footer, and drawing one nothing counted pushes a line of
   conversation off the bottom -- the pair of defects the queue rows already
   taught this pane (#29818). Restating the condition in both places is how
   they come apart.

   The fact itself used to live in the footer alone, seventh of nine hints,
   and the footer drops hints from its tail on a narrow terminal: the one
   thing that changes what the arrow keys do was among the first to go. *)
let keeper_message_reading_back (state : state) = state.msg_scroll > 0

type keeper_message_pending_preview_row =
  | Pending_preview_item of int * Masc_tui_keeper_chat_queue.item
  | Pending_preview_omitted of int

let keeper_message_pending_preview items =
  let count = List.length items in
  if count <= 3
  then List.mapi (fun index item -> Pending_preview_item (index + 1, item)) items
  else
    let first = List.nth items 0 in
    let second = List.nth items 1 in
    let newest = List.nth items (count - 1) in
    [ Pending_preview_item (1, first)
    ; Pending_preview_item (2, second)
    ; Pending_preview_omitted (count - 3)
    ; Pending_preview_item (count, newest)
    ]
;;

let keeper_message_pending_status_rows items =
  List.fold_left
    (fun rows -> function
      | Pending_preview_item _ -> rows + 2
      | Pending_preview_omitted _ -> rows + 1)
    0 (keeper_message_pending_preview items)
;;

(* External effects this Keeper handed to the Gate and has not got back.

   Measured over 2026-09-01..03: 2,067 of 35,658 recorded calls were deferred,
   and in 872 of them the Keeper went on to make further calls in the same
   turn. Those rows draw in the chat as ordinary returns, because a deferral
   returns successfully -- the effect is what is outstanding, not the call. The
   pane had no way to say so.

   Read from [gate_pending], which rides every tick from every surface for the
   strip's badge, so this is as current in the chat pane as it is on Approvals.
   A projection of rows already loaded: no new field, no new request. *)
let keeper_effects_at_the_gate (state : state) ~keeper_name =
  List.filter
    (fun (pending : Tui_decode.gate_pending) ->
      String.equal pending.gp_keeper keeper_name)
    state.gate_pending

(* The turn's status rows as the pane will draw them, folding included.

   One function rather than two readings: the budget below counts what this
   returns and the pane draws what this returns, which is the arrangement that
   kept the unavailable row from going missing while the send hint still read
   Enter:send. Folding would have been a second place to disagree. *)
let keeper_message_visible_status_rows (state : state) live ~now =
  let rows = Masc_tui_keeper_chat_transcript.status_rows ~now live in
  if state.msg_turn_folded then
    List.filter
      (fun (kind, _) ->
        Masc_tui_keeper_chat_transcript.status_row_survives_folding kind)
      rows
  else rows

(* How many rows the fold took, which the folded progress line reports so the
   count is never a thing the reader has to notice is missing. *)
let keeper_message_folded_status_count (state : state) live ~now =
  if not state.msg_turn_folded then 0
  else
    List.length (Masc_tui_keeper_chat_transcript.status_rows ~now live)
    - List.length (keeper_message_visible_status_rows state live ~now)

let keeper_message_activity_rows (state : state) =
  match state.msg_target_keeper_name with
  | None -> []
  | Some keeper_name ->
    let own_live_turn = match state.msg_live with
      | Some live when String.equal (turn_log_keeper_name live) keeper_name ->
        Masc_tui_keeper_chat_transcript.phase live.tl_transcript = Masc_tui_keeper_chat_transcript.Working
      | Some _ | None -> false in
    let activity = if own_live_turn then [] else Masc_tui_answering.chat_activity
      ~now:(Unix.gettimeofday ()) ~keeper_name ~error:state.keeper_turns_error
      state.keeper_turns in
    let submitted = match state.msg_live with
      | Some live when String.equal (turn_log_keeper_name live) keeper_name ->
        let transcript = live.tl_transcript in
        (match Masc_tui_keeper_chat_transcript.phase transcript,
               Masc_tui_keeper_chat_transcript.admission transcript with
         | Masc_tui_keeper_chat_transcript.Waiting, Some (Masc_tui_keeper_chat_live.Queued, _) ->
           let other_turn_observed = state.keeper_turns_error = None
             && List.exists (fun (row : Tui_decode.keeper_turn_row) ->
               String.equal row.ktr_keeper_name keeper_name
               && match row.ktr_state with
                 | Tui_decode.Keeper_turn_running
                     { lane = Turn_lane_autonomous | Turn_lane_maintenance; _ } -> true
                 | Keeper_turn_running { lane = Turn_lane_chat_operation; _ }
                 | Keeper_turn_idle | Keeper_turn_unavailable _ -> false)
               state.keeper_turns in
           [if other_turn_observed then
              "Your message is queued behind this Keeper's current turn; start time unknown"
            else "Your message is queued at the server; start time unknown"]
         | Masc_tui_keeper_chat_transcript.Waiting, None ->
           ["Your request is awaiting server acceptance; queue position unknown"]
         | Masc_tui_keeper_chat_transcript.Waiting, Some (Masc_tui_keeper_chat_live.Running, _) ->
           ["Your request was accepted; waiting for its first event"]
         | Masc_tui_keeper_chat_transcript.Waiting, Some (Masc_tui_keeper_chat_live.Settled, _) ->
           ["Your request already settled; replaying its result"]
         | _ -> [])
      | Some _ | None -> []
    in
    let local_count = Masc_tui_keeper_chat_queue.length_for_keeper
      state.msg_queued ~keeper_name in
    activity @ submitted @ (if local_count > 0 then
      [Printf.sprintf "%d %s waiting in this TUI; not sent to the server yet"
        local_count (if local_count = 1 then "message" else "messages")]
      else [])
;;

let keeper_message_status_rows (state : state) =
  let unavailable_target =
    match state.msg_target_keeper_name with
    | Some keeper_name when keeper_available_for_new_message state keeper_name
      -> 0
    | Some _ | None -> 1
  in
  List.length state.msg_inflight
  + List.length (keeper_message_activity_rows state)
  + unavailable_target
  + (match state.msg_live with
     | None -> 0
     | Some live
       when state.msg_target_keeper_name <> Some (turn_log_keeper_name live) ->
         (* Another keeper's live turn draws nothing on this screen, so it
            must reserve nothing -- the counter mirrors the pane. *)
         0
     | Some live ->
         (* Same call the drawing makes, so the budget cannot count a
            different number of rows than the pane draws. The age in the
            progress row changes the text, never the row count, so the
            two clock reads cannot disagree on the number. *)
         List.length
           (keeper_message_visible_status_rows state live.tl_transcript
              ~now:(Unix.gettimeofday ())))
  (* The promoted line and the queued ones are entries in the history now --
     the chat pane appends them to the same stream it scrolls, so the
     conversation holds one time axis. Nothing is reserved for them here:
     rows the history owns are the history's to budget. *)
  (* Pending input owns one USER-shaped header/body slot below the causal
     transcript. When its turn starts those two rows are handed to the active
     USER one-for-one, so the text does not jump through an older turn's
     tool/output block. *)
  (* One row whatever the queue holds, so the reservation cannot drift from
     the drawing: the pane names as many effects as fit on it and truncates
     the rest, the way every other single-line status row does. *)
  (* Folded, the queue is a count on the progress line rather than a row of
     its own -- which is the row #6 asked about, always there whether or not
     anything was waiting on the operator. *)
  + (match state.msg_target_keeper_name with
     | Some keeper_name
       when (not state.msg_turn_folded)
            && keeper_effects_at_the_gate state ~keeper_name <> [] ->
         1
     | Some _ | None -> 0)
  + (if Option.is_some state.msg_loaded_error then 1 else 0)
  + (if state.msg_memory_visibility <> Memory_hidden
        && Option.is_some state.msg_memory_error then 1 else 0)
  + (if state.msg_memory_visibility <> Memory_hidden
        && state.msg_memory_dropped > 0 then 1 else 0)
  + (if state.msg_loaded_dropped > 0 then 1 else 0)
  + (if state.msg_older_loading || Option.is_some state.msg_older_error then 1
     else 0)
  + (if keeper_message_reading_back state then 1 else 0)
  + composer_extra_rows state

(* Support cannot disappear merely because PgUp adds the reading-back notice.
   At the live edge, reserve that possible row only for the support threshold;
   once reading back, it is already part of [keeper_message_status_rows]. The
   rendered history still uses the exact rows it currently draws. *)
let keeper_message_support_status_rows state ~status_rows =
  status_rows + if keeper_message_reading_back state then 0 else 1


(* Command-palette jump targets. Surfaces come from the same ring the strip
   draws; keepers come from the loaded roster, so the palette can only offer
   a chat the roster can open. *)
type gate_lane = Workspace_gate | External_gate

let gate_lane_label = function
  | Workspace_gate -> "Workspace"
  | External_gate -> "Outside services"

let gate_mode_label = function
  | Masc.Keeper_gate_mode.Manual -> "Ask me for each decision"
  | Masc.Keeper_gate_mode.Auto_judge -> "Let Auto Judge decide"
  | Masc.Keeper_gate_mode.Always_allow -> "Allow every call without review"

type palette_action =
  | Palette_browser_lane
  | Palette_hide_browser_lane
  | Palette_msx
  | Palette_lane_addons
  | Palette_goto of surface
  | Palette_config of config_pane
  | Palette_gate_mode of gate_lane * Masc.Keeper_gate_mode.t
  | Palette_chat of string
  | Palette_task of string
  | Palette_board_hearth of string option
  | Palette_board_post of string
  (* (question, symbol): a language-server question about a name on the
     Code pane's cursor line — the K/D candidates ride the palette as
     entries so one keypress can also be a choice among several names. *)
  | Palette_lsp of string * string

(* The identifier names on the file pane's cursor line, in reading order,
   first occurrence only. The open file already carries its lexed segments,
   so the scan skips what the lexer called a keyword, a string, a comment,
   or a number -- those offer no name a language server answers about --
   rather than keeping a second keyword list that could drift. *)
let code_cursor_line_symbols (state : state) =
  match Masc_tui_fetched.current state.code_file with
  | Some (_, Masc_tui_fetched.Ready rows) -> (
      match Rows.at (Rows.of_array rows) state.code_file_cursor with
      | None -> []
      | Some segments ->
          let name_kind kind =
            not
              (List.exists (String.equal kind)
                 [ Masc_tui_code_lexer.kind_keyword;
                   Masc_tui_code_lexer.kind_string;
                   Masc_tui_code_lexer.kind_comment;
                   Masc_tui_code_lexer.kind_number ])
          in
          let starts c =
            (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c = '_'
          in
          let continues c =
            starts c || (c >= '0' && c <= '9') || c = '\''
          in
          let names = ref [] in
          List.iter
            (fun (text, kind) ->
              if name_kind kind then begin
                let n = String.length text in
                let i = ref 0 in
                while !i < n do
                  if starts text.[!i] then begin
                    let j = ref (!i + 1) in
                    while !j < n && continues text.[!j] do
                      incr j
                    done;
                    let name = String.sub text !i (!j - !i) in
                    if not (List.exists (String.equal name) !names) then
                      names := name :: !names;
                    i := !j
                  end
                  else incr i
                done
              end)
            segments;
          List.rev !names)
  (* No open file, still reading, or the read failed: nothing to name. *)
  | Some (_, (Masc_tui_fetched.Loading | Masc_tui_fetched.Failed _))
  | Some (_, Masc_tui_fetched.Absent)
  | None -> []

(* The Code pane asks the server for at most this many entries per directory
   and the server answers a bare list, so a full page is the only sign that a
   directory holds more. The title says so rather than presenting the page as
   the total: masc's own test/ has 955 entries. *)
let workspace_entries_limit =
  Server_routes_http_routes_workspace.max_tree_node_limit

let workspace_entries_count_label total =
  if total = 0 then ""
  else if total >= workspace_entries_limit then
    Printf.sprintf " (%d+, more not listed)" total
  else Printf.sprintf " (%d)" total

(* The prefixes a typed palette line uses to ask the language server, paired
   with the question each names. One list, because two readers use it: the
   entries the palette offers are built from it, and the palette's Enter arm
   parses a typed line with it. A question spelled in one and not the other
   is a line the operator can type and nothing answers. *)
let lsp_question_prefixes =
  [ "def ", "definition"; "hover ", "hover"; "refs ", "references" ]

let palette_entries (state : state) =
  [ "settings", Palette_config Config_params ]
  @ List.concat_map (fun lane ->
      List.map (fun mode ->
        ("gate " ^ gate_lane_label lane ^ " / " ^ gate_mode_label mode,
         Palette_gate_mode (lane, mode)))
        [Masc.Keeper_gate_mode.Manual; Masc.Keeper_gate_mode.Auto_judge; Masc.Keeper_gate_mode.Always_allow])
      [Workspace_gate; External_gate]
  (* Both halves, because they are one reading split in two: Task Review lists
     what waits for a ruling and Task Verdicts what was ruled. They sit one [v]
     apart under Planning, so offering a jump to one and not the other makes the
     nearer half look like the only one there is. *)
  @ [ "go Task Review", Palette_goto Verification ]
  @ [ "go Task Verdicts", Palette_goto Harness ]
  @ [ "go Lanes", Palette_goto Lanes ]
  @ [ "go Clients", Palette_goto Clients ]
  @ [ "go Schedules", Palette_goto Schedules ]
  @ [ "go Code", Palette_goto Code ]
  @ [ "go Resources", Palette_goto Resources ]
  @ [ "go Tools", Palette_goto Tools ]
  @ (match browser_lane_on_screen state with
      | None -> []
      | Some _ -> [ "hide Browser Lane", Palette_hide_browser_lane ])
  @ [ "go Browser Lane", Palette_browser_lane ]
  @ [ "go MSX", Palette_msx ]
  @ [ "go Lane Add-ons", Palette_lane_addons ]
  @ [ "go Logs", Palette_goto System_logs ]
  @ [ "go Metrics", Palette_goto Metrics ]
  @ [ "metrics", Palette_goto Metrics ]
  @ [ "telemetry", Palette_goto Metrics ]
  @ [ "charts", Palette_goto Metrics ]
  @ [ "stats", Palette_goto Metrics ]
  @ List.map
      (fun (surface, label) -> ("go " ^ label, Palette_goto surface))
      surface_ring
  @ List.map
      (fun (keeper : keeper) ->
        ("keeper " ^ keeper.k_name, Palette_chat keeper.k_name))
      state.keepers
  @ List.map
      (fun (t : task) -> ("task " ^ t.id ^ " " ^ t.title, Palette_task t.id))
      state.tasks
  @ [ "hearth all", Palette_board_hearth None ]
  @ List.map (fun (name, count) ->
      (Printf.sprintf "hearth %s (%d posts)" name count, Palette_board_hearth (Some name)))
      state.board_hearths
  @ List.map
      (fun (p : board_post) ->
        ("post " ^ p.bp_title, Palette_board_post p.bp_id))
      state.board_posts
  @ (* With a file focused on the Code surface, the cursor line's names are
       askable: K/D/R pre-fill the matching prefix, and [palette_matches]
       ranks a label that starts with the query first, so these lead the
       list. *)
  (if state.view = Code && state.code_focus_file = Right_pane then
     List.concat_map
       (fun name ->
         List.map
           (fun (prefix, question) -> (prefix ^ name, Palette_lsp (question, name)))
           lsp_question_prefixes)
       (code_cursor_line_symbols state)
   else [])

(* Subsequence match: every query character appears in order. "kadm" finds
   "keeper adm-race". *)
let palette_subsequence ~needle haystack =
  let h = String.lowercase_ascii haystack in
  let n = String.lowercase_ascii needle in
  let hl = String.length h and nl = String.length n in
  let rec walk hi ni =
    if ni >= nl then true
    else if hi >= hl then false
    else if Char.equal h.[hi] n.[ni] then walk (hi + 1) (ni + 1)
    else walk (hi + 1) ni
  in
  walk 0 0

let palette_matches (state : state) =
  let needle = String.trim state.palette_query in
  let entries =
    match state.palette_mode with
    | Palette_jump -> palette_entries state
    | Palette_choice { choice_question; _ } ->
        List.map
          (fun name -> (name, Palette_lsp (choice_question, name)))
          (code_cursor_line_symbols state)
  in
  (* Three ranks, entry order kept inside each: a label that starts with the
     query, then one that contains it, then one that only has its characters
     in order. A K/D pre-fill of "def " therefore lists the cursor line's
     names before a post that merely mentions "deferred". *)
  let rank (label, _) =
    if palette_starts_with ~needle label then Some 0
    else if palette_contains ~needle label then Some 1
    else if palette_subsequence ~needle label then Some 2
    else None
  in
  entries
  |> List.filter_map (fun entry ->
         Option.map (fun r -> (r, entry)) (rank entry))
  |> List.stable_sort (fun (a, _) (b, _) -> Int.compare a b)
  |> List.map snd
