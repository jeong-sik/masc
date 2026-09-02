[@@@warning "-32-69"]
module Tui_decode = Masc.Tui_decode
module Metrics_tail = Masc_tui_metrics_tail

(** TUI shared types — split from masc_tui.ml (#3808) *)

(** Agent type with status (from Tui_decode) *)
type agent = Tui_decode.agent

(** Task type (from Tui_decode) *)
type task = Tui_decode.task

(** Event for the event log *)
(* The five states the refresh loop can put the TUI in. It was a string
   with a catch-all at each of the five render sites, so a typo rendered
   as [disconnected] and a new state would have too. *)
type connection_status =
  | Disconnected
  | Connecting
  | Reconnecting
  | Degraded
  | Connected

let connection_status_label = function
  | Connected -> "connected"
  | Degraded -> "degraded"
  | Connecting -> "connecting..."
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

type workspace_identity =
  | Workspace_identity_unread
  | Workspace_identity_match
  | Workspace_identity_mismatch of
      { local_base_path : string
      ; server_base_path : string
      }

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
  | Sent_by_operator of string
      (** The person reading this pane. ["you"], or ["you \xc2\xb7 <surface>"]
          where the line came in from somewhere other than the dashboard. *)
  | Sent_by_other of string
      (** Anyone else: another agent's broadcast, a connector, a second
          operator. Named as the server named them, with the surface it
          arrived on. *)

type msg_role =
  | Message_user of message_author
      (** A row addressed to the keeper by a person or another agent. *)
  | Message_keeper
  | Message_autonomous
      (** A keeper reply produced by an autonomous turn rather than a message
          sent from this chat. *)
  | Message_status
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
         | Memory_hidden -> Some "memory:off"
         | Memory_full -> Some "memory:full")
      ; (* The clock-free gutter is the resting layout: the speaker mark and
           label retain who/what, while timestamps and request ids remain one
           keypress away. Name only the denser projection's added metadata so
           the header explains what changed instead of describing the default
           as though something were missing. *)
        (match origin with
         | Masc_tui_message_layout.Origin_bare -> None
         | Masc_tui_message_layout.Origin_inline -> Some "metadata:inline"
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

(* Start from the resting clock-free gutter, then add a short inline clock,
   then give the full timestamp and request id a row of their own. One key
   walks from the densest conversation toward progressively more metadata. *)
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
  me_memory_summary: string option;
      (** Producer-built compact text for a Memory journal row. [None] for
          ordinary conversation and neutral system rows; renderers never
          recover this boundary by splitting display text. *)
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

let chat_projected_timeline_ats messages =
  let first_known_by_request =
    List.fold_left
      (fun known (row : msg_entry) ->
        let request_id = row.me_request_id in
        if String.equal request_id "" || List.mem_assoc request_id known
        then known
        else
          match message_display_at row with
          | Some at -> (request_id, at) :: known
          | None -> known)
      [] messages
  in
  let rec project floors reversed = function
    | [] -> List.rev reversed
    | row :: rest ->
        let request_id = row.me_request_id in
        let raw_at = message_display_at row in
        if String.equal request_id ""
        then project floors (raw_at :: reversed) rest
        else
          let projected_at =
            match List.assoc_opt request_id floors, raw_at with
            | None, Some at -> Some at
            | None, None -> List.assoc_opt request_id first_known_by_request
            | Some None, _ -> None
            | Some (Some floor), Some at -> Some (Float.max floor at)
            | Some (Some floor), None -> Some floor
          in
          let floors =
            (request_id, projected_at) :: List.remove_assoc request_id floors
          in
          project floors (projected_at :: reversed) rest
  in
  project [] [] messages
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

let same_turn_user left right =
  match left.me_role, right.me_role with
  | Message_user _, Message_user _ ->
      String.equal left.me_request_id right.me_request_id
      && String.equal left.me_text right.me_text
  | (Message_keeper | Message_autonomous | Message_status | Message_error
    | Message_tool | Message_thinking | Message_memory | Message_skill _), _
  | _, (Message_keeper | Message_autonomous | Message_status | Message_error
       | Message_tool | Message_thinking | Message_memory | Message_skill _) ->
      false
;;

let append_chat_timeline_row items row =
  if row.me_role = Message_memory
  then items @ [ Chat_memory row ]
  else if String.equal row.me_request_id ""
  then items @ [ Chat_unowned row ]
  else
    let rec append reversed = function
      | [] ->
          List.rev
            (Chat_turn
               { ct_request_id = row.me_request_id
               ; ct_turn_sequence = row.me_turn_sequence
               ; ct_rows = [ row ]
               }
             :: reversed)
      | Chat_turn turn :: rest
        when String.equal turn.ct_request_id row.me_request_id ->
          let rows =
            if List.exists (same_turn_user row) turn.ct_rows
            then turn.ct_rows
            else order_chat_turn_rows (turn.ct_rows @ [ row ])
          in
          let ct_turn_sequence =
            match turn.ct_turn_sequence, row.me_turn_sequence with
            | None, sequence | sequence, None -> sequence
            | Some left, Some right when Int.equal left right -> Some left
            | Some _, Some _ -> None
          in
          List.rev_append reversed
            (Chat_turn { turn with ct_turn_sequence; ct_rows = rows } :: rest)
      | item :: rest -> append (item :: reversed) rest
    in
    append [] items
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
  let items =
    List.fold_left append_chat_timeline_row [] (loaded @ visible_session)
  in
  { ctl_items = items }
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
let chat_live_insertion_index ~request_id ~timeline_at positioned_messages =
  let lower_bound =
    List.fold_left
      (fun (index, lower_bound) ((row : msg_entry), _) ->
        ( index + 1
        , if String.equal row.me_request_id request_id
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

let msg_anchor entry =
  { ma_identity = entry.me_identity
  ; ma_session_user_slot =
      (match entry.me_identity, entry.me_role with
       | Session_row { request_id; turn_phase; operation_seq }, Message_user _ ->
           Some (request_id, turn_phase, operation_seq)
       | (Persisted_row _ | Persisted_legacy_row _), Message_user _ -> None
       | (Persisted_row _ | Persisted_legacy_row _ | Session_row _),
         (Message_keeper | Message_autonomous | Message_status | Message_error
         | Message_tool | Message_skill _ | Message_thinking | Message_memory) ->
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
    (Message_keeper | Message_autonomous | Message_status | Message_error
    | Message_tool | Message_skill _ | Message_thinking | Message_memory)
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

type overview_snapshot = {
  ov_workspace_health: workspace_health;
  ov_cluster: string;
  ov_project: string;
  ov_keepers: int;  (** [keeper_briefs] the briefing carried *)
  ov_mcp_agents: int;  (** [agent_briefs]: MCP clients, not keepers *)
  ov_incident_count: int;
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

type planning_snapshot = Tui_decode.planning_snapshot
  = {
  pl_goals: planning_goal list;
  pl_rollup: planning_rollup;
  pl_backlog: planning_backlog;
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
  | Planning_filter_active, (Goal_phase.Executing | Goal_phase.Verifying) -> true
  | Planning_filter_completed, Goal_phase.Completed -> true
  | Planning_filter_dropped, Goal_phase.Dropped -> true
  | Planning_filter_active, (Goal_phase.Completed | Goal_phase.Dropped)
  | Planning_filter_completed, (Goal_phase.Executing | Goal_phase.Verifying | Goal_phase.Dropped)
  | Planning_filter_dropped, (Goal_phase.Executing | Goal_phase.Verifying | Goal_phase.Completed) ->
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
    | Goal_phase.Completed -> 2
    | Goal_phase.Dropped -> 3
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
let lowercase_contains ~needle haystack =
  let needle = String.lowercase_ascii needle in
  let haystack = String.lowercase_ascii haystack in
  let n = String.length needle and h = String.length haystack in
  if n = 0
  then true
  else
    let rec at i =
      i + n <= h && (String.equal (String.sub haystack i n) needle || at (i + 1))
    in
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
   the hint. *)
let identity_preamble ~keeper ~notice =
  ("  Move with the arrows and press enter to connect " ^ keeper
   ^ ", R to ask again what tools exist, T to switch the row off or on.")
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

(** Top-level TUI surface. *)
(* A picture currently on the terminal. Only the drawn case: a refusal has
   nothing to draw, and putting one here would take the screen away from the
   frame to show a message the frame is the only thing that can show. Refusals
   go to the pane as text, like every other thing that did not happen. *)
type image_shown = {
  image_path : string;
  image_bytes : int;
}

type surface =
  | Overview
  | Acting
  | Keepers of keeper_mode
  | Memory
  | Lanes
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

(* The Tab cycle and the strip drawn above every surface share this order,
   so the strip cannot disagree with where Tab actually goes. Labels are the
   strip's spelling. Keepers stands for every keeper sub-mode; Planning owns
   its Goal view, the Task Review queue, and the Verdicts the judge recorded.
   Those two remain distinct internal surfaces because each has a different
   API and permission boundary, but neither is a second top-level
   destination. Verdicts is the far half of Task Review -- one lists what is
   waiting for a ruling and the other what was ruled -- and a top-level tab
   called "Harness" said neither. *)
let surface_ring : (surface * string) list =
  [ (Overview, "Overview");
    (Acting, "Activity");
    (Keepers Keeper_list, "Keepers");
    (Memory, "Memory");
    (Approvals, "Approvals");
    (Board, "Board");
    (Planning, "Planning");
    (Repositories, "Workspace");
    (Runtime, "Runtime");
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
   the ring stop that answers "what happened" is one. *)
let surface_ring_index (view : surface) =
  let family =
    match view with
    | Keepers _ -> Keepers Keeper_list
    | Verification | Harness -> Planning
    | Changes | Connectors | Schedules | Fusion -> Keepers Keeper_list
    | Lanes -> Runtime
    | Code -> Repositories
    | Resources | Tools -> Config
    | System_logs -> Acting
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
  | Memory | Lanes | Schedules | Verification | Harness | Fusion
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

let runtime_listing_chrome ~error = listing_chrome ~error + 2
let system_log_listing_chrome ~error = listing_chrome ~error + 1

(** Dashboard state *)
(* A request that has been POSTed and has not settled, with when it went out
   and the live transcript decoded from its stream. Both ride with the request
   rather than in structures keyed by id: Keepers can stream concurrently, and
   a single live slot lets the later stream replace the earlier one's tool
   rows. *)
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
  ; live : Masc_tui_keeper_chat_transcript.t
  }

(* Which workspace the Code surface reads. The workspace routes resolve each
   through its own query axis: a keeper's playground via [?keeper=] (where a
   Changes row's clone-relative path lives), a registered repository via
   [?repo_id=] (what a Repositories row names). *)
type code_workspace_scope =
  | Code_scope_project
  | Code_scope_keeper of string
  | Code_scope_repo of string

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
  | Config_themes

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

type runtime_param_edit_mode = Friendly_value | Advanced_json

type runtime_param_edit =
  { rpe_key : string
  ; rpe_value_type : string
  ; rpe_draft : string
  ; rpe_replace_on_type : bool
  ; rpe_mode : runtime_param_edit_mode
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
     | _ -> parse_json ())

type state = {
  mutable agents: agent list;
  mutable tasks: task list;
  (* The full domain rows the Overview list is projected from, kept so the
     detail view can show a task after it turns terminal -- the active list
     drops exactly those rows. Replaced wholesale with [tasks] on each load. *)
  mutable tasks_domain: Masc_domain.task list;
  mutable task_focus: pane_focus;
  (* The [?] help overlay: open replaces the surface body until Esc/? closes
     it. The scroll survives only while it is open. *)
  mutable help_open: bool;
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
  (* The roster beside a keeper surface costs the chat 30 columns for a
     list the reader may already know. Hidden is a choice they make, not a
     width the terminal forces, so it survives resizing. *)
  mutable roster_pane_hidden: bool;
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
     the next key takes the picture away and repaints everything. *)
  mutable image_open: image_shown option;
  (* The [:] command palette: a typed filter over jump targets. Query and
     cursor live only while it is open. *)
  mutable palette_open: bool;
  mutable palette_query: string;
  mutable palette_cursor: int;
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
  mutable prompts_snapshot: Tui_decode.prompts_snapshot option;
  mutable prompts_error: string option;
  mutable prompts_cursor: int;
  mutable prompts_show_fragments: bool;
  mutable prompts_show_runtime_assets: bool;
  mutable prompts_librarian_input: (string * string list) option;
  mutable prompts_librarian_input_error: string option;
  mutable prompts_librarian_input_loading: bool;
  (* Rows of coloured segments, the shape the Code surface keeps, so the two
     surfaces read the same file the same way. Plain text is derived where it
     is needed rather than stored beside them: two copies of the same rows
     drift the moment one is rebuilt and the other is not. *)
  mutable runtime_config_view: (string * (string * string) list list) option;
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
  mutable keeper_sandbox_view: (string * Masc_tui_keeper_sandbox.t) option;
  mutable keeper_sandbox_view_error: string option;
  mutable keeper_sandbox_logs: (string * Masc_tui_keeper_sandbox.logs) option;
  mutable keeper_sandbox_logs_error: (string * string) option;
  mutable keeper_sandbox_logs_generation: int;
  mutable keeper_sandbox_logs_inflight: (string * int) option;
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
  mutable last_refresh: float;
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
  mutable keeper_calls: Tui_decode.keeper_calls_snapshot option;
  mutable keeper_calls_error: string option;
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
  (* One answer at a time. The draft carries the ask it belongs to, so moving
     the cursor cannot post an answer under the wrong question. *)
  mutable ask_draft: Masc_tui_ask_projection.draft option;
  mutable pending_ask_submit: string option;
  mutable ask_submit_inflight: bool;
  (* The tool calls keepers are holding, drawn above the operator actions on
     the same surface. Live registry state on the server; refreshed with the
     surface. *)
  mutable keeper_tool_approvals: Tui_decode.keeper_tool_approval list;
  mutable keeper_tool_approvals_error: string option;
  (* Which keepers are mid-turn right now, from GET /api/v1/keepers/turns.
     Rides the same tick as the approvals above, for the same reason: the
     "answering now" badge is drawn from every surface, so it cannot wait
     for the operator to open the keeper list. *)
  mutable keeper_turns: Tui_decode.keeper_turn_row list;
  mutable keeper_turns_error: string option;
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
  (* Keepers whose approval gate runs every call unasked. Names only: the
     wire carries (keeper, mode) pairs and [auto] is the absent default, so
     what the pane needs is exactly the yolo set. *)
  mutable keeper_yolo_names: string list;
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
  mutable board_draft: Buffer.t;
  mutable board_compose_armed: bool;
  mutable board_compose_reply_to: string option;
  (* One send at a time: the gate a slow server needs so s-s cannot post
     the same draft twice, and the completion knows it owns the clear. *)
  mutable board_post_inflight: bool;
  mutable board_post_error: string option;
  (* A vote armed for a second keypress: which post, and up or down. The
     cursor can move between the two presses, so the post id is captured at
     arm time and a press on a different row re-arms for that row. *)
  mutable board_vote_armed: (string * bool) option;
  mutable planning: planning_snapshot option;
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
  mutable standalone_lanes: Tui_decode.standalone_lanes_snapshot option;
  mutable standalone_lanes_error: string option;
  mutable standalone_lanes_generation: int;
  (* Run drill-down under the standalone observation rows. [lane_runs] is the
     summary page of the lane named in [lanes_mode]; payloads stay behind the
     per-run detail fetch, so the list never holds one. *)
  mutable lanes_mode: lanes_mode;
  mutable lanes_standalone_cursor: int;
  mutable lane_runs: Tui_decode.lane_run_summary list option;
  mutable lane_runs_error: string option;
  mutable lane_runs_cursor: int;
  mutable lane_runs_scroll: int;
  mutable lane_run_detail: Tui_decode.lane_run_detail option;
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
  mutable tools_error: string option;
  mutable skills_catalog: Tui_decode.skills_catalog option;
  mutable skills_catalog_error: string option;
  mutable tools_scroll: int;
  mutable tools_skill_cursor: int;
  mutable tools_skill_evidence: (string * Yojson.Safe.t) option;
  mutable tools_async_observation: Yojson.Safe.t option;
  mutable tools_async_observation_error: string option;
  mutable connectors: Tui_decode.connector_snapshot option;
  mutable connectors_error: string option;
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
  mutable repositories_scroll: int;
  mutable repositories_cursor: int;
  mutable memory_health: Tui_decode.memory_health_snapshot option;
  mutable memory_health_error: string option;
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
  mutable memory_facts_category: string option;
  mutable repository_changes_open: bool;
  mutable repository_changes_scope: Tui_decode.repository_change_scope option;
  mutable repository_changes: Tui_decode.repository_change_snapshot option;
  mutable repository_changes_error: string option;
  mutable repository_changes_scroll: int;
  mutable repository_changes_cursor: int;
  (* Code surface: one directory level at a time through the lazy /children
     route; the file arrives whole and is lexed once at load. *)
  mutable code_dir: string;
  mutable code_entries: Tui_decode.workspace_tree_node list;
  mutable code_entries_error: string option;
  mutable code_cursor: int;
  mutable code_file: (string * (string * string) list list) option;
  mutable code_file_error: string option;
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
  mutable code_history: (string * code_history_listing) option;
  mutable code_history_error: string option;
  mutable code_history_open: bool;
  mutable code_history_scroll: int;
  (* The file pane's diff view: d on an open file swaps the content for what
     the working tree holds against HEAD, keyed the same way. One overlay at
     a time -- opening this closes the history and vice versa. *)
  mutable code_diff: (string * Tui_decode.git_diff) option;
  mutable code_diff_error: string option;
  mutable code_diff_open: bool;
  mutable code_diff_scroll: int;
  (* The file pane's notes view: m on an open file (repository scope only --
     the annotation routes are scoped by the server-minted codebase slug,
     which only a Repositories row carries) swaps the content for the notes
     anchored to the file. *)
  mutable code_notes: (string * Tui_decode.ide_annotation list) option;
  mutable code_notes_error: string option;
  mutable code_notes_open: bool;
  mutable code_notes_scroll: int;
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
  (* The feature-proof reading. Kept beside its error rather than collapsed
     into an option: a report that failed to load must not draw as a report
     with no features, which reads as "nothing is proven". *)
  mutable observer: observer_status;
  mutable mcp_session: string option;
      (** The MCP session the server issued, kept across streams: the server
          holds it after a stream closes, so reopening the feed and calling
          tools reuse it rather than minting one per attempt. Cleared when
          the server refuses it. *)
  mutable acting: Masc_tui_acting.entry list;  (** newest first, at most [acting_retained_entries] *)
  mutable acting_dropped: int;  (** events that fell off the end of [acting] *)
  mutable acting_undecodable: int;  (** frames the feed reader could not read *)
  mutable acting_undecodable_last: string option;  (** why, for the most recent one *)
  mutable acting_scroll: int;  (** rows from the newest, 0 = pinned to the newest *)
  mutable acting_unseen: int;  (** events that arrived while scrolled away from the newest *)
  mutable acting_filter: Masc_tui_acting.filter;
  mutable verification: Tui_decode.verification_snapshot option;
  mutable verification_error: string option;
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
  mutable msg_input: Buffer.t;
  (* Images staged with :attach, sent with the next message and cleared by the
     send. Held next to the draft because they are part of the same unsent
     message: switching keepers or abandoning the draft must not leave an image
     attached to whatever is typed later. *)
  mutable msg_attachments: Masc_tui_keeper_chat_projection.attachment list;
  mutable msg_target_keeper_name: string option;
  mutable msg_return: keeper_chat_return;
  mutable msg_drafts: (string * string) list;
  mutable msg_history: msg_entry list;
  (* The first local submission clock for each request. A queued row keeps this
     clock when it becomes active and when a transcript refresh replaces the
     session copy. It is presentation metadata, never an ordering key. *)
  mutable msg_submission_times: (string * float) list;
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
     copy lives in [msg_inflight]; this slot only chooses what the pane draws.
     Never authoritative -- the recorded reply comes from the strict
     whole-body decode. *)
  mutable msg_live: Masc_tui_keeper_chat_transcript.t option;
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
  mutable detail_scroll: int;
  workspace: string;
  port: int;
  refresh_interval: float;
}

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
  Option.map (fun entry -> entry.live) (inflight_for_keeper state keeper_name)
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

(** One keeper as the Keepers surface reads it: durable pause from the
    metadata row, live runtime from the roster. *)
let keeper_reading (state : state) (keeper : keeper) :
    Masc_tui_keeper_control.reading =
  { name = keeper.k_name
  ; paused = keeper.k_paused
  ; liveness =
      Masc_tui_keeper_control.liveness_of_roster state.keeper_roster
        keeper.k_name
  }

let selected_keeper (state : state) =
  List.nth_opt state.keepers state.keeper_cursor

(** The standalone lane row under the cursor, when the cursor is in the
    standalone section. *)
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

(** The next target both the input path and footer agree is safe to select.
    A pending request or live transcript stays pinned to its Keeper until that
    turn settles. A retained roster is not enough after a failed refresh:
    switching is disabled until the roster is readable again. *)
let next_keeper_message_target (state : state) =
  if
    Option.is_some state.keepers_error
    || Option.is_some state.msg_live
    || state.msg_inflight <> []
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
  agents = [];
  tasks = [];
  tasks_domain = [];
  task_focus = Left_pane;
  help_open = false;
  agenda_open = false;
  agenda_scroll = 0;
  hints_visible = true;
  answering_open = false;
  answering_scroll = 0;
  answering_cursor = 0;
  keeper_turn_finishes = [];
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
  roster_pane_hidden = false;
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
  image_open = None;
  palette_open = false;
  palette_query = "";
  palette_cursor = 0;
  search = None;
  search_last = "";
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
  prompts_snapshot = None;
  prompts_error = None;
  prompts_cursor = 0;
  prompts_show_fragments = false;
  prompts_show_runtime_assets = false;
  prompts_librarian_input = None;
  prompts_librarian_input_error = None;
  prompts_librarian_input_loading = false;
  runtime_config_view = None;
  runtime_config_jump_section = None;
  config_models_rows = [];
  config_models_cursor = 0;
  runtime_config_view_error = None;
  runtime_config_cursor = 0;
  config_scroll = 0;
  detail_tab = Detail_info;
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
  quit_armed = false;
  last_action = None;
  fleet_safety = None;
  fleet_safety_error = None;
  connection_status = Disconnected;
  last_refresh = 0.0;
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
  ask_draft = None;
  pending_ask_submit = None;
  ask_submit_inflight = false;
  keeper_tool_approvals = [];
  keeper_tool_approvals_error = None;
  keeper_turns = [];
  keeper_turns_error = None;
  gate_pending = [];
  gate_modes = None;
  gate_queue_unavailable = None;
  gate_rules = [];
  gate_rules_unavailable = None;
  gate_error = None;
  keeper_yolo_names = [];
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
  board_post_inflight = false;
  board_post_error = None;
  board_vote_armed = None;
  planning = None;
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
  standalone_lanes = None;
  standalone_lanes_error = None;
  standalone_lanes_generation = 0;
  lanes_mode = Lanes_overview;
  lanes_standalone_cursor = 0;
  lane_runs = None;
  lane_runs_error = None;
  lane_runs_cursor = 0;
  lane_runs_scroll = 0;
  lane_run_detail = None;
  lane_run_detail_error = None;
  lane_run_detail_scroll = 0;
  keeper_secrets = [];
  lanes_error = None;
  lanes_action_error = None;
  system_logs = None;
  system_logs_error = None;
  tools_inventory = None;
  tools_error = None;
  skills_catalog = None;
  skills_catalog_error = None;
  tools_scroll = 0;
  tools_skill_cursor = 0;
  tools_skill_evidence = None;
  tools_async_observation = None;
  tools_async_observation_error = None;
  connectors = None;
  connectors_error = None;
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
  repositories_scroll = 0;
  repositories_cursor = 0;
  memory_health = None;
  memory_health_error = None;
  memory_health_scroll = 0;
  memory_health_cursor = 0;
  memory_facts_keeper = None;
  memory_facts = None;
  memory_facts_error = None;
  memory_facts_cursor = 0;
  memory_facts_scroll = 0;
  memory_facts_category = None;
  repository_changes_open = false;
  repository_changes_scope = None;
  repository_changes = None;
  repository_changes_error = None;
  repository_changes_scroll = 0;
  repository_changes_cursor = 0;
  code_dir = "";
  code_entries = [];
  code_entries_error = None;
  code_cursor = 0;
  code_file = None;
  code_file_error = None;
  code_file_scroll = 0;
  code_file_cursor = 0;
  code_lsp_note = None;
  code_jump_back = [];
  code_file_hscroll = 0;
  code_file_max_width = 0;
  code_focus_file = Left_pane;
  code_history = None;
  code_history_error = None;
  code_history_open = false;
  code_history_scroll = 0;
  code_diff = None;
  code_diff_error = None;
  code_diff_open = false;
  code_diff_scroll = 0;
  code_notes = None;
  code_notes_error = None;
  code_notes_open = false;
  code_notes_scroll = 0;
  code_scope = Code_scope_project;
  code_target_line = None;
  changes_keeper = None;
  changes = None;
  changes_error = None;
  changes_cursor = 0;
  changes_scroll = 0;
  changes_diff_row = None;
  changes_diff_scroll = 0;
  changes_tree_diff = None;
  changes_tree_diff_error = None;
  changes_tree_diff_path = None;
  harness = None;
  harness_error = None;
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
  observer = Observer_off;
  mcp_session = None;
  acting = [];
  acting_dropped = 0;
  acting_undecodable = 0;
  acting_undecodable_last = None;
  acting_scroll = 0;
  acting_unseen = 0;
  acting_filter = Masc_tui_acting.Turns;
  verification = None;
  verification_error = None;
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
  msg_target_keeper_name = None;
  msg_return = Keeper_chat_return_detail;
  msg_drafts = [];
  msg_history = [];
  msg_submission_times = [];
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
  msg_origin_display = Masc_tui_message_layout.Origin_bare;
  msg_tool_visibility = tool_visibility;
  msg_spill = None;
  msg_queued = Masc_tui_keeper_chat_queue.empty;
  msg_inflight = [];
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

let chat_rows_for (state : state) keeper_name =
  let promoted_request_id =
    Option.map
      (fun entry -> entry.sent_request.request_id)
      (promoted_inflight_for_keeper state keeper_name)
  in
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
  let queued_request_ids =
    Masc_tui_keeper_chat_queue.waiting_for_keeper state.msg_queued ~keeper_name
    |> List.map (fun item -> item.Masc_tui_keeper_chat_queue.request.request_id)
  in
  chat_timeline ~loaded ~session ~queued_request_ids |> chat_timeline_rows

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
   whatever the first load happened to reach (#31089). *)
let merge_paged_history ~(paged : msg_entry list) ~(fresh : msg_entry list) =
  match oldest_at fresh with
  | None -> paged
  | Some at ->
    List.filter (fun (entry : msg_entry) -> entry.me_at < at) paged @ fresh

let set_msg_scroll (state : state) rows =
  let rows = max 0 rows in
  if rows = 0 then begin
    state.msg_scroll <- 0;
    state.msg_scroll_pin <- None
  end
  else begin
    if state.msg_scroll = 0 then
      state.msg_scroll_pin <-
        (match state.msg_target_keeper_name with
         | None -> None
         | Some keeper_name ->
           (match List.rev (chat_rows_for state keeper_name) with
            | newest :: _ -> Some (msg_anchor newest)
            | [] -> None));
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
  (* Both surfaces worked out the row they could actually draw and then threw
     it away: the drawing clamped for display while the stored value kept
     climbing, so coming back up took one keypress per step taken past the
     end. Same report the diff already makes. *)
  | Resource_scroll of int
  | Approval_detail_scroll of int

let apply_clamped_scroll (state : state) = function
  | Overview_events value -> state.overview_event_scroll <- value
  | Task_detail value -> state.task_detail_scroll <- value
  | Board_read value -> state.board_scroll <- value
  | Message_scroll value -> set_msg_scroll state value
  | Schedule_detail_scroll value -> state.schedule_scroll <- value
  | Keeper_detail value -> state.detail_scroll <- value
  | Keeper_calls value -> state.keeper_calls_scroll <- value
  | Acting value -> state.acting_scroll <- value
  | Verification_detail_scroll value ->
      state.verification_detail_scroll <- value
  | Harness_detail_scroll value -> state.harness_detail_scroll <- value
  | Fusion_detail_scroll value -> state.fusion_scroll <- value
  | Runtime_detail_scroll value -> state.runtime_detail_scroll <- value
  | System_log_detail_scroll value -> state.system_logs_detail_scroll <- value
  | Planning_detail_scroll value -> state.planning_scroll <- value
  | Lane_run_detail_scroll value -> state.lane_run_detail_scroll <- value
  | Changes_diff_scroll value -> state.changes_diff_scroll <- value
  | Resource_scroll value -> state.resource_scroll <- value
  | Approval_detail_scroll value -> state.approval_detail_scroll <- value

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
              | None -> store.Tui_decode.mos_facts
              | Some category ->
                  List.filter
                    (fun (fact : Tui_decode.memory_fact) ->
                      String.equal fact.Tui_decode.mf_category category)
                    store.Tui_decode.mos_facts
            in
            List.map (fun fact -> Memory_row_fact fact) facts
      in
      let source_rows, invalidation_rows =
        match snapshot.Tui_decode.mfs_source with
        | Tui_decode.Memory_store_read_error _ | Tui_decode.Memory_store_absent
          ->
            ([], [])
        | Tui_decode.Memory_store_present store ->
            ( List.map
                (fun fact -> Memory_row_source_fact fact)
                store.Tui_decode.mss_facts
            , List.map
                (fun row -> Memory_row_invalidation row)
                store.Tui_decode.mss_invalidations )
      in
      ordinary @ source_rows @ invalidation_rows

(* The categories the loaded ordinary store actually holds, distinct and
   sorted -- the [c] cycle walks these. Read from the rows, never from a
   list this side hardcodes: the taxonomy is the server's, and a category it
   adds appears here without a code change. *)
let memory_fact_categories (state : state) : string list =
  match state.memory_facts with
  | None -> []
  | Some snapshot -> (
      match snapshot.Tui_decode.mfs_ordinary with
      | Tui_decode.Memory_store_read_error _ | Tui_decode.Memory_store_absent
        ->
          []
      | Tui_decode.Memory_store_present store ->
          store.Tui_decode.mos_facts
          |> List.map (fun (fact : Tui_decode.memory_fact) ->
               fact.Tui_decode.mf_category)
          |> List.sort_uniq String.compare)

(* All -> first category -> ... -> last -> All. A [current] that is no
   longer among [categories] (the snapshot refreshed under the filter)
   restarts at All rather than guessing a neighbour. *)
let next_memory_category (current : string option) (categories : string list)
    : string option =
  match current with
  | None -> ( match categories with [] -> None | first :: _ -> Some first)
  | Some current ->
      let rec after = function
        | [] -> None
        | candidate :: rest ->
            if String.equal candidate current then
              (match rest with [] -> None | next :: _ -> Some next)
            else after rest
      in
      after categories

let scrolled_surface_rows (state : state) : surface -> scrolled option =
  let listing ~error count =
    Some
      { sc_count = count
      ; sc_chrome = listing_chrome ~error
      ; sc_overflow_takes_row = false
      ; sc_preview_keep = None
      }
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
  | Harness ->
      if Option.is_some state.harness_detail then None
      else
        listing ~error:state.harness_error
          (match state.harness with
           | None -> 0
           | Some s -> List.length s.Tui_decode.hs_verdicts)
  | Repositories ->
      if state.repository_changes_open then
        listing ~error:state.repository_changes_error
          (match state.repository_changes with
           | None -> 0
           | Some s -> List.length s.Tui_decode.rcs_changes)
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
        (* Fleet rows plus the detail panel of the row the cursor names. The
           panel is one scroll unit: its own height follows the render, and
           search only needs to land on rows that exist. *)
        listing ~error:state.memory_health_error
          (match state.memory_health with
           | None -> 0
           | Some s -> List.length s.Tui_decode.mhs_keepers + 1)
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
  | Code when state.repository_changes_open ->
      listing ~error:state.repository_changes_error
        (match state.repository_changes with
         | None -> 0
         | Some s -> List.length s.Tui_decode.rcs_changes)
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
        ; sc_chrome = runtime_listing_chrome ~error:state.runtime_surface_error
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
         | Config_runtime | Config_params | Config_prompts | Config_themes ->
           (match state.runtime_config_view with
            | None -> 0
            | Some (_, rows) -> List.length rows))
  (* Acting counts rows the drawing builds out of formatted text, not rows the
     state holds; counting them here would be a second copy of the formatting,
     so it reports a [clamped_scroll] instead. Overview, Keepers, Board,
     Planning and Schedules move a cursor or a detail pane rather than a plain
     list. *)
  | Overview | Acting | Keepers _ | Board | Approvals | Planning | Schedules
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
let surface_row_texts (state : state) : surface -> string list option = function
  | Keepers Keeper_list ->
      Some (List.map (fun (k : keeper) -> k.k_name) state.keepers)
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
          (fun s ->
            List.map (fun k -> k.Tui_decode.mkh_keeper_id)
              s.Tui_decode.mhs_keepers
            @ [ "memory detail" ])
          state.memory_health
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
        Option.map
          (fun (_, rows) ->
            List.map
              (fun segments -> String.concat "" (List.map fst segments))
              rows)
          state.code_file
      else
        Some
          (List.map
             (fun (n : Tui_decode.workspace_tree_node) -> n.Tui_decode.wt_label)
             state.code_entries)
  (* Cursorless or otherwise-navigated surfaces: no row list to search. *)
  | Overview | Acting | Keepers _ | Board | Approvals | Planning | Schedules
  | Fusion | Resources | Changes | Config | Tools ->
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

let keeper_message_status_rows (state : state) =
  let unavailable_target =
    match state.msg_target_keeper_name with
    | Some keeper_name when keeper_available_for_new_message state keeper_name
      -> 0
    | Some _ | None -> 1
  in
  List.length state.msg_inflight
  + unavailable_target
  + (match state.msg_live with
     | None -> 0
     | Some live
       when state.msg_target_keeper_name
            <> Some (Masc_tui_keeper_chat_transcript.keeper_name live) ->
         (* Another keeper's live turn draws nothing on this screen, so it
            must reserve nothing -- the counter mirrors the pane. *)
         0
     | Some live ->
         (* Same call the drawing makes, so the budget cannot count a
            different number of rows than the pane draws. The age in the
            progress row changes the text, never the row count, so the
            two clock reads cannot disagree on the number. *)
         List.length
           (Masc_tui_keeper_chat_transcript.status_rows
              ~now:(Unix.gettimeofday ()) live))
  + (match state.msg_target_keeper_name with
     | Some keeper_name
       when Option.is_some (promoted_inflight_for_keeper state keeper_name) ->
         2
     | Some _ | None -> 0)
  + (match state.msg_target_keeper_name with
     | Some keeper_name ->
         Masc_tui_keeper_chat_queue.waiting_for_keeper state.msg_queued
           ~keeper_name
         |> keeper_message_pending_status_rows
     | None -> 0)
  (* Pending input owns one USER-shaped header/body slot below the causal
     transcript. When its turn starts those two rows are handed to the active
     USER one-for-one, so the text does not jump through an older turn's
     tool/output block. *)
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


(* Command-palette jump targets. Surfaces come from the same ring the strip
   draws; keepers come from the loaded roster, so the palette can only offer
   a chat the roster can open. *)
type palette_action =
  | Palette_goto of surface
  | Palette_config of config_pane
  | Palette_chat of string
  | Palette_task of string
  | Palette_board_post of string
  (* (question, symbol): a language-server question about a name on the
     Code pane's cursor line — the K/D candidates ride the palette as
     entries so one keypress can also be a choice among several names. *)
  | Palette_lsp of string * string

(* Prefix match: the lowercased label starts with the query. An empty query
   is a prefix of everything. *)
let palette_starts_with ~needle haystack =
  let h = String.lowercase_ascii haystack in
  let n = String.length needle in
  String.length h >= n && String.equal (String.sub h 0 n) needle

let palette_contains ~needle haystack =
  let h = String.lowercase_ascii haystack in
  let n = String.length needle and hl = String.length h in
  if n = 0 then true
  else begin
    let found = ref false in
    for start = 0 to hl - n do
      if (not !found) && String.equal (String.sub h start n) needle then
        found := true
    done;
    !found
  end

(* The identifier names on the file pane's cursor line, in reading order,
   first occurrence only. The open file already carries its lexed segments,
   so the scan skips what the lexer called a keyword, a string, a comment,
   or a number -- those offer no name a language server answers about --
   rather than keeping a second keyword list that could drift. *)
let code_cursor_line_symbols (state : state) =
  match state.code_file with
  | None -> []
  | Some (_, rows) -> (
      match List.nth_opt rows state.code_file_cursor with
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

let palette_entries (state : state) =
  [ "settings", Palette_config Config_params ]
  @ [ "go Task Review", Palette_goto Verification ]
  @ [ "go Lanes", Palette_goto Lanes ]
  @ [ "go Schedules", Palette_goto Schedules ]
  @ [ "go Fusion", Palette_goto Fusion ]
  @ [ "go Code", Palette_goto Code ]
  @ [ "go Resources", Palette_goto Resources ]
  @ [ "go Tools", Palette_goto Tools ]
  @ [ "go Logs", Palette_goto System_logs ]
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
  @ List.map
      (fun (p : board_post) ->
        ("post " ^ p.bp_title, Palette_board_post p.bp_id))
      state.board_posts
  @ (* With a file focused on the Code surface, the cursor line's names are
       askable: K/D pre-fill the matching prefix, and [palette_matches] ranks
       a label that starts with the query first, so these lead the list. *)
  (if state.view = Code && state.code_focus_file = Right_pane then
     List.concat_map
       (fun name ->
         [ ("def " ^ name, Palette_lsp ("definition", name));
           ("hover " ^ name, Palette_lsp ("hover", name)) ])
       (code_cursor_line_symbols state)
   else [])

(* Subsequence match: every query character appears in order. "kadm" finds
   "keeper adm-race". *)
let palette_subsequence ~needle haystack =
  let h = String.lowercase_ascii haystack in
  let hl = String.length h and nl = String.length needle in
  let rec walk hi ni =
    if ni >= nl then true
    else if hi >= hl then false
    else if Char.equal h.[hi] needle.[ni] then walk (hi + 1) (ni + 1)
    else walk (hi + 1) ni
  in
  walk 0 0

let palette_matches (state : state) =
  let needle =
    String.lowercase_ascii (String.trim state.palette_query)
  in
  let entries = palette_entries state in
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
