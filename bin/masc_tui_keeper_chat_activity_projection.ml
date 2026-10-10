module Projection = Masc_tui_keeper_chat_projection

let safe_line text = Projection.terminal_safe_text text

type tool_outcome =
  | Started
  | Awaiting_result
  | Returned
  | Native_running
  | Native_ended
      (** The provider ended its native tool step; optional native completion
          metadata is separate from a MASC execution receipt. *)
  | Native_failed
      (** The provider's own report says its native tool step did not
          succeed: an error, a decline or a nonzero exit. A provider
          observation, not a MASC execution receipt. *)
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
  ; native_completion : Runtime_native_tools.completion option
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

type skill_invocation =
  | Instruction_read
  | Composition_run of { tool_name : string }

type skill_activity =
  { skill_name : string
  ; invocation : skill_invocation option
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

let subject_of ~tool_name ~args =
  if String.equal (String.trim args) "" then None
  else Masc.Keeper_chat_tool_trail.tool_subject ~name:tool_name ~args

let nonblank = function
  | Some value when String.trim value <> "" -> Some value
  | Some _ | None -> None

let make_tool_activity ?native_completion ?execution_id ~call_id ~tool_name ~args ~outcome
    ~duration () =
  let call_id = nonblank call_id in
  let execution_id = nonblank execution_id in
  { call_id
  ; execution_id
  ; tool_name
  ; args
  ; subject = subject_of ~tool_name ~args
  ; outcome
  ; native_completion
  ; duration
  }

(* Whether the provider's own report says its native step did not succeed.
   An absent, unread or unrecognized status says nothing either way, so only
   a reported error, a reported decline or a nonzero exit counts. *)
let native_report_says_failed (completion : Runtime_native_tools.completion option) =
  match completion with
  | None -> false
  | Some completion ->
      let open Runtime_native_tools in
      (match completion.outcome with
       | Error_reported | Decline_reported | Result_received {is_error=Some true} -> true
       | End_observed | Completion_reported
       | Result_received {is_error=None | Some false} | Unrecognized_status _ -> false)
      || Option.fold ~none:false ~some:(fun code -> code <> 0) completion.exit_code

let tool_block ?(omitted_steps = 0) activities : tool_block =
  { activities; omitted_steps }

let finished_marker = "✓"

let marker_of_outcome = function
  | Started -> "◌"
  | Awaiting_result -> "▶"
  | Returned -> finished_marker
  | Native_running -> "◌"
  | Native_ended -> "■"
  | Native_failed | Failed -> "\xe2\x9c\x97"
  | Never_returned -> "○"
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
let with_native_exit_code (completion : Runtime_native_tools.completion) status =
  match completion.exit_code with
  | None -> status
  | Some code -> Printf.sprintf "%s; exit %d" status code

(* Only words this module writes. The compact and full views hand their rows
   to the phrase dresser, which colours a clause by the words it finds, so a
   provider's own status word ("not_failed") would be painted as a failure
   there while the call itself reads as ended. *)
let native_completion_status (completion : Runtime_native_tools.completion) =
  let open Runtime_native_tools in
  with_native_exit_code completion
    (match completion.outcome with
     | End_observed -> "native ended; outcome not reported"
     | Completion_reported -> "native completion reported"
     | Error_reported -> "native error reported"
     | Decline_reported -> "native declined"
     | Result_received {is_error=None} -> "native result received; error flag not reported"
     | Result_received {is_error=Some false} -> "native result received; no error reported"
     | Result_received {is_error=Some true} -> "native error reported"
     | Unrecognized_status _ -> "native status unrecognized")

(* The status plus the provider's word for one the decoder does not know.
   That word is payload, so only the results view draws it, as plain text. *)
let native_completion_summary (completion : Runtime_native_tools.completion) =
  let open Runtime_native_tools in
  match completion.outcome with
  | Unrecognized_status status ->
      with_native_exit_code completion ("native status unrecognized: " ^ safe_line status)
  | End_observed | Completion_reported | Error_reported | Decline_reported
  | Result_received _ -> native_completion_status completion

let native_activity_summary (activity : tool_activity) =
  match activity.outcome with
  | Native_ended | Native_failed ->
      Some (native_completion_status
        (Option.value activity.native_completion ~default:Runtime_native_tools.end_observed))
  | Started | Awaiting_result | Returned | Native_running | Failed | Never_returned
  | Outcome_unrecorded -> None

let render_activity_rows (activities : tool_activity list) =
  let name_width =
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
      let trailer = match native_activity_summary activity, activity.duration with
        | None, duration -> duration
        | Some summary, None -> Some summary
        | Some summary, Some duration -> Some (summary ^ " · " ^ duration)
      in
      match activity.subject with
      | None ->
          safe_line
            (with_trailer
               (Printf.sprintf "%s %s" marker
                  (display_tool_name activity.tool_name))
               trailer)
      | Some subject ->
          safe_line
            (with_trailer
               (Printf.sprintf "%s %s %s" marker
                  (pad_to name_width (display_tool_name activity.tool_name))
                  subject)
               trailer))
    activities

let omitted_steps_row count =
  Printf.sprintf "(%s not carried by the transcript)" (Masc_tui_message_layout.count_noun count "step")



(* The one outcome a folded block reads as. The order is the order of what a
   reader needs to know first: a call that failed outranks one still out,
   which outranks one whose end was never recorded. Both the summary glyph and
   the summary colour come from here, so the two cannot say different things
   about the same block. *)
let compact_outcome (activities : tool_activity list) =
  if List.exists (fun activity -> activity.outcome = Failed) activities then
    Failed
  else if List.exists (fun activity -> activity.outcome = Native_failed) activities
  then Native_failed
  else if
    List.exists (fun activity -> activity.outcome = Awaiting_result) activities
  then Awaiting_result
  else if
    List.exists
      (fun activity ->
        activity.outcome = Started)
      activities
  then Started
  else if List.exists (fun activity -> activity.outcome = Native_running) activities
  then Native_running
  else if List.exists (fun activity -> activity.outcome = Never_returned) activities
  then Never_returned
  else if
    List.exists
      (fun activity -> activity.outcome = Outcome_unrecorded)
      activities
  then Outcome_unrecorded
  else if List.exists (fun activity -> activity.outcome = Native_ended) activities
  then Native_ended
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
  | Failed | Native_failed | Never_returned | Awaiting_result -> true
  | Started | Native_running | Returned | Native_ended | Outcome_unrecorded -> false
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

(* The word the rollup counts an outcome by. One place, so the sheet's
   legend prints the word the row does. *)
let outcome_label = function
  | Started -> "running"
  | Awaiting_result -> "awaiting result"
  | Returned -> "returned"
  | Native_running -> "native running"
  | Native_ended -> "native ended"
  | Native_failed -> "native failed"
  | Failed -> "failed"
  | Never_returned -> "result not seen"
  | Outcome_unrecorded -> "outcome unrecorded"

let received_marker = "↩"

(* Every outcome, in the order the rollup lists them: what is still moving
   first, then what finished, then what nothing can be said about. *)
let all_outcomes =
  [ Started; Awaiting_result; Returned; Native_running; Native_ended; Native_failed; Failed
  ; Never_returned; Outcome_unrecorded ]

let compact_outcome_parts (activities : tool_activity list) =
  let count outcome =
    List.fold_left
      (fun total activity ->
        if activity.outcome = outcome then total + 1 else total)
      0 activities
  in
  let ordinary = List.map (fun outcome -> outcome, outcome_label outcome) all_outcomes
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
  in
  ordinary @ List.filter_map (fun (activity : tool_activity) ->
    Option.map (fun summary -> display_tool_name activity.tool_name ^ ": " ^ summary)
      (native_activity_summary activity)) activities
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
  | Tool_masc_fusion_dispatch | Tool_masc_fusion_status | Tool_masc_fusion_decision -> Fusion_activity
  | Tool_keeper_spawn_dispatch | Tool_masc_keeper_dispatch -> Keeper_activity
  | Tool_lane_addon _
  | Tool_execute
  | Tool_search_files
  | Tool_read_file
  | Tool_edit_file
  | Tool_write_file
  | Tool_lane_status
  | Tool_tools_list
  | Tool_capability_search
  | Tool_context_status
  | Tool_peer_artifact
  | Tool_artifact_read
  | Tool_skill_validate
  | Tool_skill_publish
  | Tool_workspace_memory_read
  | Tool_memory_search
  | Tool_memory_retract
  | Tool_memory_write
  | Tool_constitution_write
  | Tool_constitution_read
  | Tool_constitution_remove
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
  | Tool_browser_tabs
  | Tool_browser_read
  | Tool_browser_session
  | Tool_browser_goto
  | Tool_browser_act
  | Tool_browser_instruct
  | Tool_browser_interact
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

let make_skill_activity ?invocation ?skill_tool_use_id ?turn_ref
    ?content_revision ?runtime_id ?detail ~skill_name ~state ~actions () =
  { skill_name = safe_line skill_name
  ; invocation =
      Option.map
        (function
          | Instruction_read -> Instruction_read
          | Composition_run { tool_name } ->
              Composition_run { tool_name = safe_line tool_name })
        invocation
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
        | Started | Awaiting_result | Native_running -> Skill_calling
        | Returned -> Skill_served_pending
        | Failed -> Skill_failed
        | Native_ended | Native_failed | Never_returned | Outcome_unrecorded ->
            Skill_evidence_missing
      in
      (* [activity_kind] admitted the call as a skill on one of two names:
         the read tool, or a composition's own tool. A composition tool is
         named after its skill, so the name says which skill ran even when
         the arguments have not arrived. *)
      let invocation, named_by_tool =
        match
          Masc.Keeper_tool_composition_catalog.skill_name_of_tool_name
            activity.tool_name
        with
        | Some skill -> Composition_run { tool_name = activity.tool_name }, skill
        | None -> Instruction_read, display_tool_name activity.tool_name
      in
      let skill_name = Option.value activity.subject ~default:named_by_tool in
      Some
        (make_skill_activity ~invocation ?skill_tool_use_id:activity.call_id
           ~skill_name ~state ~actions:[] ())

(* One phrase per state, and no interpunct inside one.

   The separator on this row does three jobs at once: it parts the state from
   the skill name, the name from the action count, and it used to part a
   state's own two words from each other. So "SERVED ONLY · DELIVERY NOT
   RECORDED" gave a reader no way to tell, from the row, whether that was one
   state or two. A phrase with two facts in it uses a comma.

   A skill's life is three steps -- the model reads it, the server records
   that the text was delivered, the model then uses a tool because of it --
   and each phrase names how far along it got, in those three words. The
   earlier phrases (보냈고 확인 중, 받고 안 씀, 받아서 씀) named the same
   steps from the server's side, as sending and receiving, and the operator
   reading the pane could not say who sent what to whom ("받아서 뭘 쓴다는
   거야", 2026-09-14).

   The last three are not steps of that life. [Skill_failed] is the read
   itself failing. [Skill_evidence_missing] is this pane never seeing the
   read come back -- the turn ended, or the pane opened after the call --
   and the old word, 증거 없음, read as a verdict on the skill when it was a
   fact about the pane. [Skill_evidence_unavailable] is a skill record the
   server sent in a shape this build cannot read. *)
let skill_state_label ?invocation state =
  (* An instruction skill is read; a composition is run. The three states
     before delivery say which, and the rest are the same for both. *)
  let read, done_ =
    match invocation with
    | Some (Composition_run _) -> "실행 중", "실행됨"
    | Some Instruction_read | None -> "읽는 중", "읽음"
  in
  match state with
  | Skill_calling -> read
  | Skill_served_pending -> done_ ^ ", 전달 확인 중"
  | Skill_served_only -> done_ ^ ", 전달 기록 없음"
  | Skill_delivered -> "전달됨, 도구 안 씀"
  | Skill_used -> "전달됨, 도구 씀"
  | Skill_failed -> "실패"
  | Skill_evidence_missing -> "결과 못 봄"
  | Skill_evidence_unavailable -> "기록 형식 안 맞음"

(* Every state, in the order of the skill's life, then the three that are
   not steps of it. *)
let all_skill_states =
  [ Skill_calling
  ; Skill_served_pending
  ; Skill_served_only
  ; Skill_delivered
  ; Skill_used
  ; Skill_failed
  ; Skill_evidence_missing
  ; Skill_evidence_unavailable
  ]

(* The two words a full skill row draws beside its ids and its actions,
   named once so the legend explains the words the row prints. *)
let proof_word = "proof"
let observed_action_word = "observed action"

(* What each mark and phrase on a tool or skill row means, for the help
   sheet, in the shape the other legends take: the mark or phrase as the row
   draws it, and what it says. Built from the same functions and words the
   rows use, so the sheet cannot explain a mark the pane no longer draws. *)
let legend =
  let outcome_meaning = function
    | Started -> "arguments still arriving"
    | Awaiting_result -> "arguments sent, result not back yet"
    | Returned -> "result came back"
    | Native_running -> "native step running"
    | Native_ended -> "native step ended; provider report shown when available, not a MASC execution receipt"
    | Native_failed -> "provider reported an error, a decline or a nonzero exit for its native step; not a MASC execution receipt"
    | Failed -> "the tool answered with a failure"
    | Never_returned ->
        "no result was seen in this view before the attempt ended; this \
         does not establish that the tool failed"
    | Outcome_unrecorded ->
        "the stored record has no outcome field; a gap in the record, not \
         a failure"
  in
  let skill_meaning = function
    | Skill_calling -> "the model asked to read the skill; nothing back yet"
    | Skill_served_pending ->
        "the skill text came back; the server's delivery record is not read yet"
    | Skill_served_only ->
        "the skill text came back; the server has no record of delivering it"
    | Skill_delivered ->
        "the server recorded the delivery; no tool call followed from it"
    | Skill_used ->
        "the server recorded the delivery and the tool calls the model made \
         because of it (the rows marked observed action)"
    | Skill_failed -> "reading the skill failed"
    | Skill_evidence_missing ->
        "this pane never saw the read come back; says nothing about the skill"
    | Skill_evidence_unavailable ->
        "the server's skill record is in a shape this build cannot read"
  in
  List.map
    (fun outcome ->
      marker_of_outcome outcome ^ " " ^ outcome_label outcome, outcome_meaning outcome)
    all_outcomes
  @ [ received_marker ^ " received",
      "a result is present; receipt alone does not establish success" ]
  @ List.map
      (fun state -> skill_state_label state, skill_meaning state)
      all_skill_states
  @ (let composition = Composition_run { tool_name = "" } in
     List.filter_map
       (fun state ->
         let run_word = skill_state_label ~invocation:composition state in
         if String.equal run_word (skill_state_label state) then None
         else
           Some
             ( run_word,
               "as above, for a composition: the skill ran as its own tool \
                rather than being read as text" ))
       all_skill_states)
  @ [ ( proof_word
      , "the ids behind a skill row: use= the read call, turn= the turn, \
         runtime= who ran it, rev= the skill text's revision" )
    ; (observed_action_word, "a tool call the server attributes to the skill above it")
    ]

let short_proof value =
  let value = safe_line value in
  if String.length value <= 18 then value
  else
    String.sub value 0 8 ^ "\xe2\x80\xa6"
    ^ String.sub value (String.length value - 8) 8

(* The full rows of one invocation: state and name, then each observed
   action, the proof coordinates and the detail. State first, then which
   skill, then what came of it -- the Gate row's order, because the pane
   should not read left to right one way on one kind of row and the other
   way on the next. *)
let skill_full_rows (activity : skill_activity) =
  let action_count = List.length activity.actions in
  let summary =
    Printf.sprintf "**%s** \xc2\xb7 **%s**%s"
      (skill_state_label ?invocation:activity.invocation activity.state)
      activity.skill_name
      (if action_count = 0 then ""
       else Printf.sprintf " \xc2\xb7 %s" (Masc_tui_message_layout.count_noun action_count "action"))
  in
  begin
    let actions =
      List.map
        (fun action ->
          Printf.sprintf "  \xe2\x86\xb3 **%s** \xc2\xb7 %s" action observed_action_word)
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
      | parts -> [ "  " ^ proof_word ^ " \xc2\xb7 " ^ String.concat " \xc2\xb7 " parts ]
    in
    let detail =
      match activity.detail with
      | None -> []
      | Some detail -> [ "  " ^ detail ]
    in
    summary :: actions @ proof @ detail
  end

(* Which of a skill's invocations in one block did not come off. The
   compact row names a skill and how many times it was triggered; that a
   trigger failed, or that the pane could not read its evidence, is the one
   thing about a trigger that is not "it happened", so it is the one thing
   said beside the count. *)
let skill_trigger_problem (activity : skill_activity) =
  match activity.state with
  | Skill_failed | Skill_evidence_missing | Skill_evidence_unavailable -> true
  | Skill_calling | Skill_served_pending | Skill_served_only | Skill_delivered
  | Skill_used -> false

(* Compact: one row per skill named in the block, in the order each was
   first triggered, with how many times. A turn that ran one composition
   seven times said the same row seven times; the tool block under it folded
   its twelve calls into one line, and this is the same fold.

   The row carries no lifecycle word: whether the text was delivered or a
   tool followed is bookkeeping a reader of the chat does not act on, and
   [full] keeps it. A trigger that failed, or evidence the pane could not
   read, is said with the state's own words. *)
let skill_compact_rows (activities : skill_activity list) =
  let names =
    List.fold_left
      (fun names activity ->
        if List.mem activity.skill_name names then names
        else activity.skill_name :: names)
      [] activities
    |> List.rev
  in
  List.map
    (fun name ->
      let mine = List.filter (fun a -> String.equal a.skill_name name) activities in
      let count = List.length mine in
      let problems = List.filter skill_trigger_problem mine in
      let times = if count = 1 then "" else Printf.sprintf " \xc3\x97%d" count in
      let problem =
        match problems with
        | [] -> ""
        | [ one ] when count = 1 ->
            Printf.sprintf " \xc2\xb7 %s" (skill_state_label ?invocation:one.invocation one.state)
        | first :: _ ->
            Printf.sprintf " \xc2\xb7 %s %d"
              (skill_state_label ?invocation:first.invocation first.state)
              (List.length problems)
      in
      Printf.sprintf "**%s**%s%s" name times problem)
    names

let skill_rows ~full (activities : skill_activity list) =
  if full then List.concat_map skill_full_rows activities
  else skill_compact_rows activities

(* The state one row of several invocations answers to: the worst of them,
   so a block with one failed trigger among seven draws in the failure's
   colour. Order: what went wrong, then what is still moving, then how far
   a finished one got. *)
let skill_block_state (activities : skill_activity list) =
  let rank = function
    | Skill_failed -> 0
    | Skill_evidence_unavailable -> 1
    | Skill_evidence_missing -> 2
    | Skill_calling -> 3
    | Skill_served_pending -> 4
    | Skill_served_only -> 5
    | Skill_delivered -> 6
    | Skill_used -> 7
  in
  List.fold_left
    (fun worst activity ->
      if rank activity.state < rank worst then activity.state else worst)
    Skill_used activities

(* The kind a run of calls amounts to, when the names alone do not show it.
   [compact_tool_mix] on the same line already names every distinct tool with
   its count, so a tag over a single name is that name's number said twice --
   on one live screen every [Keeper N] was exactly the count of one
   [keeper_*] tool named a few clauses along, in all eight blocks that had
   one. A tag is drawn only where it adds several names up.

   A handoff reads as [Delegate] rather than [Keeper]: it replaces that
   clause instead of adding one, so the fold does not grow. *)
let compact_activity_kinds activities =
  let of_kind kind =
    List.filter (fun activity -> activity_kind activity = kind) activities
  in
  [ Skill_activity, "Skill"
  ; Delegate_activity, "Delegate"
  ; Keeper_activity, "Keeper"
  ; Fusion_activity, "Fusion"
  ]
  |> List.filter_map (fun (kind, label) ->
       let members = of_kind kind in
       let names =
         List.sort_uniq String.compare (List.map canonical_tool_name members)
       in
       match names with
       (* Nothing of this kind ran, or one tool did and the rollup already
          names it with the same number a few clauses along. A tag adds up
          what the names leave separate, and there is nothing to add up. *)
       | [] | [ _ ] -> None
       | _ :: _ :: _ ->
           Some (Printf.sprintf "%s %d" label (List.length members)))

(* Both projections retain the same typed activities. [Full] is the shipping
   view and therefore stays byte-compatible with the old formatter. [Compact]
   folds only the presentation rows; the count of what it hid is the call
   count it already carries, and it keeps failures/open calls visible in its
   outcome summary. *)
(* The block's rollup, on a line of its own.

   Three counts have left this line for the same reason, and the reason is
   worth keeping: a number the same line already gives costs width and buys
   a second place to disagree. "N details folded" was the count at the head.
   [Keeper 1] over a single [keeper_*] name was that name's own number. And
   the head itself, [Tools N], was the sum of the name counts beside it --
   on a block where every call returned it was also the [N returned] that
   closes the line, so one screen read "Tools 9 ... 9 returned" six times.
   The row is drawn under the transcript's own TOOLS label, which says what
   kind of row it is, so the word was the label a second time as well.

   What the line keeps is what nothing else says: how it went (the mark),
   what ran (the names and their counts), and what came of it (the
   outcomes).

   [outcomes] is passed rather than derived because the two modes count
   different calls: folded, the trouble gets a line of its own and the rollup
   speaks for what is left; unfolded, every call is visible and the rollup
   speaks for all of them.

   Assembled from parts instead of one format string so a part with nothing
   to say drops out, rather than leaving an empty clause between two
   separators. *)
let inventory_row ~outcomes activities =
  let parts =
    compact_activity_kinds activities @ compact_tool_parts activities @ outcomes
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
            (inventory_row
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
               | Native_ended -> true
               | Outcome_unrecorded -> true
               | Started | Native_running | Awaiting_result | Native_failed | Failed
               | Never_returned -> false)
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
            (inventory_row
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
