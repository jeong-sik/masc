(** Pure field selection, quoting and grouping for admitted world events. *)

let board_event_kind_label = function
  | Keeper_world_observation.Board_post_created -> "post_created"
  | Keeper_world_observation.Board_post_updated -> "post_updated"
  | Keeper_world_observation.Board_comment_added _ -> "comment_added"
  | Keeper_world_observation.Board_reaction_changed _ -> "reaction_changed"
  | Keeper_world_observation.Board_vote_cast _ -> "vote_cast"
  | Keeper_world_observation.Fusion_completed -> "fusion_completed"
  | Keeper_world_observation.Schedule_due _ -> "schedule_due"
  | Keeper_world_observation.External_attention _ -> "external_attention"
  | Keeper_world_observation.Completion_authority_rejected _ ->
    "completion_authority_rejected"
  | Keeper_world_observation.Task_outcome _ -> "task_outcome"
  | Keeper_world_observation.Task_cancelled _ -> "task_cancelled"
  | Keeper_world_observation.Delegate_completed _ -> "keeper_delegate_completed"
  | Keeper_world_observation.Composition_completed ->
    "keeper_composition_completed"
  | Keeper_world_observation.Ask_answered_row _ -> "ask_answered"
;;

let quote_prompt_field value =
  let buf = Buffer.create (String.length value + 2) in
  Buffer.add_char buf '"';
  String.iter
    (function
      | '"' -> Buffer.add_string buf "\\\""
      | '\\' -> Buffer.add_string buf "\\\\"
      | '\n' -> Buffer.add_string buf "\\n"
      | '\r' -> Buffer.add_string buf "\\r"
      | '\t' -> Buffer.add_string buf "\\t"
      | c -> Buffer.add_char buf c)
    value;
  Buffer.add_char buf '"';
  Buffer.contents buf

let format_prompt_row fields =
  fields
  |> List.map (fun (name, value) -> name ^ "=" ^ quote_prompt_field value)
  |> String.concat " "
  |> ( ^ ) "- "
;;

let approval_observation_fields
      (approval : Keeper_world_observation.pending_approval_observation)
  =
  [ "approval_id", approval.approval_id
  ; "status", "pending"
  ; "tool", approval.tool_name
  ; "sequence", string_of_int approval.sequence
  ; ( "requested_at"
    , Masc_domain.iso8601_of_unix_seconds approval.requested_at )
  ]
  @ (match approval.task_id with
     | None -> []
     | Some task_id -> [ "task_id", task_id ])
  @ (match approval.goal_id with
     | None -> []
     | Some goal_id -> [ "goal_id", goal_id ])
;;

let board_reaction_fields
    (reaction : Keeper_world_observation.board_reaction_event) =
  [ "reaction", if reaction.reacted then "added" else "removed"
  ; ( "target"
    , Board.reaction_target_type_to_string reaction.target_type
      ^ ":"
      ^ reaction.target_id )
  ; "user", reaction.user_id
  ; "emoji", reaction.emoji
  ]
;;

(* Who voted which way on what. [author] on the row is already the voter
   (the signal's actor); [voter] is repeated here so the vote row reads on its
   own, the way the reaction row carries [user]. *)
let board_vote_fields (vote : Board_dispatch.board_vote_change) =
  [ "vote", Board.vote_direction_to_string vote.direction
  ; ( "target"
    , match vote.target with
      | Board_dispatch.Vote_on_post post_id -> "post:" ^ post_id
      | Board_dispatch.Vote_on_comment comment_id -> "comment:" ^ comment_id )
  ; "voter", vote.voter
  ]
;;

let board_event_note_fields = function
  | Keeper_world_observation.Board_reaction_changed reaction ->
    board_reaction_fields reaction
  | Keeper_world_observation.Board_vote_cast vote -> board_vote_fields vote
  | Keeper_world_observation.External_attention observation ->
    [ "external_origin"
    , Keeper_counterpart_observation.origin_to_string observation.origin
    ; "external_channel", observation.channel
    ; "external_authority"
    , Keeper_counterpart_observation.authority_to_string observation.authority
    ]
    @ (match observation.workspace_id with
       | None -> []
       | Some workspace_id -> [ "external_workspace_id", workspace_id ])
    @ (match observation.user_id with
       | None -> []
       | Some user_id -> [ "external_user_id", user_id ])
    @ (match observation.user_name with
       | None -> []
       | Some user_name -> [ "external_user_name", user_name ])
  | Keeper_world_observation.Board_post_created
  | Keeper_world_observation.Board_post_updated
  | Keeper_world_observation.Board_comment_added _
  | Keeper_world_observation.Fusion_completed
  | Keeper_world_observation.Schedule_due _
  | Keeper_world_observation.Completion_authority_rejected _
  | Keeper_world_observation.Task_outcome _
  | Keeper_world_observation.Task_cancelled _ ->
    (* No side fact: the row is its own complete account. *)
    []
  (* [reply_full] restates the original reply exactly when the row's
     preview cut at [delegate_reply_preview_max_len]: the tail is where
     exact export objects and code fences live, and this note is the
     row's only lossless copy. The cut test compares the trimmed bytes
     the preview measured, so a padded short reply stays note-free and
     an uncropped reply is never rendered twice. [Delegate_no_reply] and
     [Delegate_failed] keep no note: their content is short by
     construction and the row already carries it whole. *)
  | Keeper_world_observation.Delegate_completed
      (Keeper_event_queue.Delegate_replied reply) ->
    if
      String.length (String.trim reply)
      > Keeper_world_observation.delegate_reply_preview_max_len
    then [ "reply_full", reply ]
    else []
  | Keeper_world_observation.Delegate_completed
      (Keeper_event_queue.Delegate_no_reply
      | Keeper_event_queue.Delegate_failed _) ->
    (* No side fact: these payloads are short by construction and the
       row already carries them whole; see the note above. *)
    []
  (* The answer is the row's title and preview; there is no side fact to add. *)
  | Keeper_world_observation.Ask_answered_row _
  | Keeper_world_observation.Composition_completed -> []
;;

let board_event_fields
    (event : Keeper_world_observation.pending_board_event) =
  let event_label = board_event_kind_label event.event_kind in
  let fields =
    [ "event", event_label
    ; "post_id", event.post_id
    ; "post_kind", Board.post_kind_to_string event.post_kind
    ; "title", Keeper_types_profile.short_preview ~max_len:80 event.title
    ; "author", event.author
    ]
  in
  let fields =
    match event.hearth with
    | Some hearth when String.trim hearth <> "" -> fields @ [ "hearth", hearth ]
    | _ -> fields
  in
  let fields =
    if event.explicit_mention then
      let mention_fields =
        match event.matched_targets with
        | [] -> []
        | xs -> [ "mention_targets", String.concat ", " xs ]
      in
      fields @ (("mention", "explicit") :: mention_fields)
    else fields
  in
  let fields = fields @ board_event_note_fields event.event_kind in
  (* [new_replies_since_own] counts replies that arrived after this Keeper's own
     comment, so it is stated only when there is an own comment to count from.
     The author of the post is the case that has none: [check_self_comment_status]
     answers [`Never], and the observation still fills
     [latest_external_author]/[latest_external_preview] with the commenter and
     what they said, because a wake that names no content is one the author has
     to spend a masc_board_post_get on before it can act.

     The replies are the end of the thread, in the order the thread read pages
     through, and the row repeats on every wake until this Keeper comments
     again. So the row names where they start and the two ids at either end
     rather than every id: its size does not grow with the thread. The reader
     that last read up to some id can tell from the newest id whether anything
     came after it, and the offset is what masc_board_post_get takes to start
     there. Nothing here records what the reader has read. *)
  let fields =
    match event.replies_after_own_comment with
    | None -> fields
    | Some { Keeper_world_observation_board_signal.comment_offset; oldest; newer } ->
      let newest =
        List.fold_left (fun (_ : Board.Comment_id.t) id -> id) oldest newer
      in
      fields
      @ [ "new_replies_since_own", string_of_int (List.length (oldest :: newer))
        ; "new_replies_comment_offset", string_of_int comment_offset
        ; "oldest_new_reply_id", Board.Comment_id.to_string oldest
        ; "newest_new_reply_id", Board.Comment_id.to_string newest
        ]
  in
  let fields =
    match event.latest_external_author, event.latest_external_preview with
    | Some author, Some preview ->
      fields @ [ "latest_external_author", author; "latest_external_preview", preview ]
    | Some author, None -> fields @ [ "latest_external_author", author ]
    | None, _ -> fields
  in
  fields @ [ "preview", event.preview ]
;;

let format_board_event_text
    (event : Keeper_world_observation.pending_board_event) : string =
  format_prompt_row (board_event_fields event)
;;

let format_scheduled_automation_item
    (item : Keeper_world_observation.scheduled_automation_item) : string =
  let payload_kind =
    match item.payload_kind with
    | None -> "unknown"
    | Some kind -> kind
  in
  format_prompt_row
    [ "schedule_id", item.schedule_id
    ; "action", item.action
    ; "status", item.status
    ; "payload", payload_kind
    ; "recurrence", item.recurrence_summary
    ; "due_at", Masc_domain.iso8601_of_unix_seconds item.due_at
    ]
;;

let scheduled_wake_fields ~occurrence_id
    (wake : Keeper_event_queue.scheduled_wake) =
  let title_field =
    match wake.title with
    | None -> []
    | Some title -> [ "title", title ]
  in
  [ "schedule_id", wake.schedule_id
  ; "due_at_unix", Printf.sprintf "%.17g" wake.due_at
  ; "payload_digest", wake.payload_digest
  ; "occurrence_id", occurrence_id
  ]
  @ title_field
  @ [ "message", wake.message ]
;;

type scheduled_wake_group =
  { wake : Keeper_event_queue.scheduled_wake
  ; first_occurrence_id : string
  ; first_due_at : float
  ; last_occurrence_id : string
  ; last_due_at : float
  ; occurrence_count : int
  }

let same_scheduled_wake_series
      (left : Keeper_event_queue.scheduled_wake)
      (right : Keeper_event_queue.scheduled_wake)
  =
  String.equal left.schedule_id right.schedule_id
  && String.equal left.schedule_instance_id right.schedule_instance_id
  && String.equal left.payload_digest right.payload_digest
;;

let group_scheduled_wake_events events =
  let add_event groups (event : Keeper_world_observation.pending_board_event) =
    match event.event_kind with
    | Keeper_world_observation.Schedule_due wake ->
      let rec update prefix = function
        | [] ->
          List.rev_append
            prefix
            [ { wake
              ; first_occurrence_id = event.post_id
              ; first_due_at = wake.due_at
              ; last_occurrence_id = event.post_id
              ; last_due_at = wake.due_at
              ; occurrence_count = 1
              }
            ]
        | group :: rest when same_scheduled_wake_series group.wake wake ->
          let first_occurrence_id, first_due_at =
            if wake.due_at < group.first_due_at
            then event.post_id, wake.due_at
            else group.first_occurrence_id, group.first_due_at
          in
          let last_occurrence_id, last_due_at =
            if wake.due_at > group.last_due_at
            then event.post_id, wake.due_at
            else group.last_occurrence_id, group.last_due_at
          in
          List.rev_append
            prefix
            ({ group with
               first_occurrence_id
             ; first_due_at
             ; last_occurrence_id
             ; last_due_at
             ; occurrence_count = group.occurrence_count + 1
             }
             :: rest)
        | group :: rest -> update (group :: prefix) rest
      in
      update [] groups
    | Keeper_world_observation.Board_post_created
  | Keeper_world_observation.Board_post_updated
    | Keeper_world_observation.Board_comment_added _
    | Keeper_world_observation.Board_reaction_changed _
    | Keeper_world_observation.Board_vote_cast _
    | Keeper_world_observation.Fusion_completed
    | Keeper_world_observation.External_attention _
    | Keeper_world_observation.Completion_authority_rejected _
    | Keeper_world_observation.Task_outcome _
    | Keeper_world_observation.Task_cancelled _
    | Keeper_world_observation.Delegate_completed _
    | Keeper_world_observation.Ask_answered_row _
    | Keeper_world_observation.Composition_completed -> groups
  in
  List.fold_left add_event [] events
;;

let scheduled_wake_group_fields group =
  if group.occurrence_count = 1
  then scheduled_wake_fields ~occurrence_id:group.first_occurrence_id group.wake
  else
    let title_field =
      match group.wake.title with
      | None -> []
      | Some title -> [ "title", title ]
    in
    [ "schedule_id", group.wake.schedule_id
    ; "occurrence_count", string_of_int group.occurrence_count
    ; "first_due_at_unix", Printf.sprintf "%.17g" group.first_due_at
    ; "last_due_at_unix", Printf.sprintf "%.17g" group.last_due_at
    ; "first_occurrence_id", group.first_occurrence_id
    ; "last_occurrence_id", group.last_occurrence_id
    ; "payload_digest", group.wake.payload_digest
    ]
    @ title_field
    @ [ "message", group.wake.message ]
;;
