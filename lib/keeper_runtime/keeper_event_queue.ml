type urgency =
  | Immediate
  | Normal
  | Low

let urgency_rank = function
  | Immediate -> 0
  | Normal -> 1
  | Low -> 2

type post_id = string

type board_stimulus_kind =
  | Post_created
  | Comment_added
  | Reaction_changed of board_reaction_change

and board_reaction_target_type =
  | Reaction_post
  | Reaction_comment

and board_reaction_change = {
  target_type : board_reaction_target_type;
  target_id : string;
  user_id : string;
  emoji : string;
  reacted : bool;
}

type board_stimulus = {
  kind : board_stimulus_kind;
  author : string;
  title : string;
  content : string;
  hearth : string option;
  updated_at : float option;
}

type stimulus_payload =
  | Board_signal of board_stimulus
  | Bootstrap
  | No_progress_recovery
  | Fusion_completed of fusion_completion
      (* RFC-0266: an async [masc_fusion] deliberation finished. Wakes the
         calling keeper so the resolved answer arrives as actionable turn
         input on its next cycle, instead of being discovered passively. *)
  | Bg_completed of bg_job_completion
      (* RFC-0290: a generic background job finished. Mirrors [Fusion_completed]
         — wakes the calling keeper so the outcome arrives as actionable turn
         input. Phase 1 adds the variant only; no producer emits it yet
         (executor lands in RFC-0290 Phase 3). *)
  | Schedule_due of scheduled_wake
      (* A scheduled automation request reached its due time and explicitly
         targets this keeper. The scheduler/consumer side owns timing,
         approval, and payload validation; this queue payload only carries the
         typed wake and operator-authored message. *)
  | Connector_attention of connector_attention
      (* RFC-connector-ambient-attention-wake: an ambient connector message
         recorded as external attention. Carries the [event_id] pointer (not
         content). Dormant — no producer emits it yet (handle_ambient enqueuer
         lands in P3), same staging as [Bg_completed] above. *)
  | Hitl_resolved of hitl_resolution
      (* A HITL approval this keeper enqueued — and then skipped cycles on via
         [has_pending_for_keeper -> Skip Approval_pending] — was resolved. Wakes
         the keeper so it re-evaluates and proceeds on its next cycle instead of
         stalling until an unrelated stimulus, no-progress recovery, or the
         30-minute approval janitor. Mirrors [Fusion_completed]/[Bg_completed]:
         a HITL decision is an async completion the waiting keeper must be
         notified of. *)
  | Goal_verification_failed of goal_verification_failure
      (* A goal completion verification was rejected for a goal assigned to this
         keeper. Wakes the keeper lane so it resumes the goal after the phase
         returns to [executing], instead of discovering the rejection only via
         unrelated board/task activity. *)

and fusion_completion = {
  run_id : string;
  ok : bool;  (* judge synthesized vs denied/sink_failed/aborted. *)
  resolved_answer : string;
  (* judge resolved answer; a failure label when [ok = false]. *)
  board_post_id : string;
  (* correlates to the sink's board evidence post; "" if none was created. *)
}

and bg_job_completion = {
  bg_run_id : string;
  bg_kind : bg_job_kind;
  bg_outcome : bg_job_outcome;
  bg_board_post_id : string;
  (* correlates to an optional board evidence post; "" if none was created. *)
}

and bg_job_kind = Subprocess
      (* RFC-0290: closed sum of background job kinds (v1 = [Subprocess]); a new
         kind forces every match to add an arm rather than defaulting. *)

and hitl_resolution_decision =
  | Hitl_approved
  | Hitl_rejected
  | Hitl_edited

and hitl_resolution = {
  approval_id : string;
  (* the resolved pending-approval id; correlates to the queue entry. *)
  decision : hitl_resolution_decision;
  (* resolved decision label carried for observability, not control flow — the
     keeper re-evaluates from its own state once the approval is gone from the
     queue. *)
}

and bg_job_outcome =
  | Bg_ok of string  (* result payload *)
  | Bg_failed of string  (* failure label *)

and connector_attention = { event_id : string }
      (* RFC-connector-ambient-attention-wake: pointer into
         [Keeper_external_attention] for the ambient message; content/surface
         read from that store on the turn path. *)

and scheduled_wake = {
  schedule_id : string;
  due_at : float;
  payload_digest : string;
  title : string option;
  message : string;
}

and goal_verification_failure = {
  goal_id : string;
  request_id : string;
  goal_title : string;
  phase : string;
  metric : string option;
  target_value : string option;
  rejected_by : string;
  note : string option;
  evidence_refs : string list;
}

let fusion_completion_post_id (fc : fusion_completion) =
  if String.equal fc.board_post_id "" then "fusion-run:" ^ fc.run_id
  else fc.board_post_id

let bg_job_completion_post_id (c : bg_job_completion) =
  if String.equal c.bg_board_post_id "" then "bg-run:" ^ c.bg_run_id
  else c.bg_board_post_id

let schedule_due_post_id (sw : scheduled_wake) = "schedule-due:" ^ sw.schedule_id

let hitl_resolution_post_id (r : hitl_resolution) = "hitl-approval:" ^ r.approval_id

let goal_verification_failure_post_id (failure : goal_verification_failure) =
  "goal-verification-failed:" ^ failure.goal_id ^ ":" ^ failure.request_id

let hitl_resolution_decision_to_string = function
  | Hitl_approved -> "approve"
  | Hitl_rejected -> "reject"
  | Hitl_edited -> "edit"

let hitl_resolution_decision_of_string = function
  | "approve" -> Ok Hitl_approved
  | "reject" -> Ok Hitl_rejected
  | "edit" -> Ok Hitl_edited
  | other -> Error (Printf.sprintf "unknown hitl_resolution decision: %s" other)

let bg_job_kind_to_string = function
  | Subprocess -> "subprocess"

let bg_job_kind_of_string = function
  | "subprocess" -> Ok Subprocess
  | other -> Error (Printf.sprintf "unknown bg_job_kind: %s" other)

type stimulus = {
  post_id : post_id;
  urgency : urgency;
  arrived_at : float;
  payload : stimulus_payload;
}

type t =
  { front : stimulus list
  ; back_rev : stimulus list
  ; length : int
  }

let empty : t = { front = []; back_rev = []; length = 0 }

let length q = q.length

let is_empty q = q.length = 0

let enqueue (queue : t) (s : stimulus) : t =
  { queue with back_rev = s :: queue.back_rev; length = queue.length + 1 }

let stimulus_identity_equal a b =
  String.equal a.post_id b.post_id && a.urgency = b.urgency && a.payload = b.payload

let to_list (queue : t) : stimulus list =
  match queue.back_rev with
  | [] -> queue.front
  | back_rev -> queue.front @ List.rev back_rev

let of_list (items : stimulus list) : t =
  { front = items; back_rev = []; length = List.length items }

let dequeue (queue : t) : (stimulus * t) option =
  match queue.front with
  | s :: rest -> Some (s, { queue with front = rest; length = queue.length - 1 })
  | [] ->
    (match List.rev queue.back_rev with
     | [] -> None
     | s :: rest -> Some (s, { front = rest; back_rev = []; length = queue.length - 1 }))

let prepend_list stimuli queue =
  match stimuli with
  | [] -> queue
  | _ ->
    { front = stimuli @ to_list queue
    ; back_rev = []
    ; length = queue.length + List.length stimuli
    }

let remove_by_post_id post_id queue =
  let removed, kept =
    queue
    |> to_list
    |> List.partition (fun stimulus -> String.equal stimulus.post_id post_id)
  in
  removed, of_list kept

let uniq_stimuli stimuli =
  List.fold_left
    (fun acc stimulus ->
       if List.exists (stimulus_identity_equal stimulus) acc
       then acc
       else stimulus :: acc)
    []
    stimuli
  |> List.rev

let dedup_by_identity queue = queue |> to_list |> uniq_stimuli |> of_list

let remove_by_post_id_pair post_id left right =
  let left_removed, left' = remove_by_post_id post_id left in
  let right_removed, right' = remove_by_post_id post_id right in
  uniq_stimuli (left_removed @ right_removed), left', right'

let dedup_by_post_id ?(window_seconds = 60.0) (queue : t) : t =
  let within_window a b =
    Float.abs (a.arrived_at -. b.arrived_at) <= window_seconds
  in
  let rec aux acc = function
    | [] -> List.rev acc
    | s :: rest ->
        let later =
          List.filter
            (fun s' -> not (s'.post_id = s.post_id && within_window s s'))
            rest
        in
        aux (s :: acc) later
  in
  of_list (aux [] (to_list queue))

let sort_by_urgency (queue : t) : t =
  queue
  |> to_list
  |> List.stable_sort
       (fun a b -> Int.compare (urgency_rank a.urgency) (urgency_rank b.urgency))
  |> of_list

let payload_kind_label = function
  | Board_signal _ -> "board_signal"
  | Bootstrap -> "bootstrap"
  | No_progress_recovery -> "no_progress_recovery"
  | Fusion_completed _ -> "fusion_completed"
  | Bg_completed _ -> "bg_completed"
  | Schedule_due _ -> "schedule_due"
  | Connector_attention _ -> "connector_attention"
  | Hitl_resolved _ -> "hitl_resolved"
  | Goal_verification_failed _ -> "goal_verification_failed"

let is_board_signal = function
  | Board_signal _ -> true
  | Bootstrap | No_progress_recovery | Fusion_completed _ | Bg_completed _
  | Schedule_due _ | Connector_attention _ | Hitl_resolved _
  | Goal_verification_failed _ ->
    false

let drain_board_window ?(window_sec = 2.0) (queue : t) : stimulus list * t =
  let now = Unix.gettimeofday () in
  let is_board_in_window s =
    is_board_signal s.payload && Float.abs (now -. s.arrived_at) <= window_sec
  in
  let board, rest = List.partition is_board_in_window (to_list queue) in
  (to_list (sort_by_urgency (of_list board)), of_list rest)

let summary (queue : t) : string =
  Printf.sprintf "%d stimulus%s pending"
    queue.length
    (if queue.length = 1 then "" else "es")

let urgency_to_string = function
  | Immediate -> "immediate"
  | Normal -> "normal"
  | Low -> "low"

let urgency_of_string = function
  | "immediate" -> Ok Immediate
  | "normal" -> Ok Normal
  | "low" -> Ok Low
  | value -> Error (Printf.sprintf "unknown urgency: %s" value)

let board_stimulus_kind_to_string = function
  | Post_created -> "post_created"
  | Comment_added -> "comment_added"
  | Reaction_changed _ -> "reaction_changed"

let board_stimulus_kind_of_string = function
  | "post_created" -> Ok Post_created
  | "comment_added" -> Ok Comment_added
  | "reaction_changed" ->
    Error "reaction_changed board stimulus requires reaction payload fields"
  | value -> Error (Printf.sprintf "unknown board stimulus kind: %s" value)

let board_reaction_target_type_to_string = function
  | Reaction_post -> "post"
  | Reaction_comment -> "comment"

let board_reaction_target_type_of_string = function
  | "post" -> Ok Reaction_post
  | "comment" -> Ok Reaction_comment
  | value -> Error (Printf.sprintf "unknown board reaction target type: %s" value)

let option_json f = function
  | Some value -> f value
  | None -> `Null

let ( let* ) = Result.bind

let board_reaction_change_fields (reaction : board_reaction_change) =
  [ "reaction_target_type", `String (board_reaction_target_type_to_string reaction.target_type)
  ; "reaction_target_id", `String reaction.target_id
  ; "reaction_user_id", `String reaction.user_id
  ; "reaction_emoji", `String reaction.emoji
  ; "reaction_active", `Bool reaction.reacted
  ]

let assoc_fields ~context = function
  | `Assoc fields -> Ok fields
  | _ -> Error (Printf.sprintf "%s must be a JSON object" context)

let required_field ~context name fields =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "%s missing required field %s" context name)

let optional_field name fields =
  match List.assoc_opt name fields with
  | Some `Null | None -> None
  | Some value -> Some value

let string_of_json ~context = function
  | `String value -> Ok value
  | _ -> Error (Printf.sprintf "%s must be a string" context)

let bool_of_json ~context = function
  | `Bool value -> Ok value
  | _ -> Error (Printf.sprintf "%s must be a boolean" context)

let float_of_json ~context = function
  | `Float value -> Ok value
  | `Int value -> Ok (float_of_int value)
  | _ -> Error (Printf.sprintf "%s must be a number" context)

let optional_string_field ~context name fields =
  match optional_field name fields with
  | None -> Ok None
  | Some json ->
    let* value = string_of_json ~context:(context ^ "." ^ name) json in
    Ok (Some value)

let optional_float_field ~context name fields =
  match optional_field name fields with
  | None -> Ok None
  | Some json ->
    let* value = float_of_json ~context:(context ^ "." ^ name) json in
    Ok (Some value)

let string_field ~context name fields =
  let* json = required_field ~context name fields in
  string_of_json ~context:(context ^ "." ^ name) json

let string_list_field ~context name fields =
  let* json = required_field ~context name fields in
  match json with
  | `List items ->
    let rec loop acc = function
      | [] -> Ok (List.rev acc)
      | item :: rest ->
        let* value = string_of_json ~context:(context ^ "." ^ name) item in
        loop (value :: acc) rest
    in
    loop [] items
  | _ -> Error (Printf.sprintf "%s.%s must be a JSON list" context name)

let bool_field ~context name fields =
  let* json = required_field ~context name fields in
  bool_of_json ~context:(context ^ "." ^ name) json

let float_field ~context name fields =
  let* json = required_field ~context name fields in
  float_of_json ~context:(context ^ "." ^ name) json

let payload_to_yojson = function
  | Board_signal board ->
    `Assoc
      ([ "kind", `String "board_signal"
       ; "board_kind", `String (board_stimulus_kind_to_string board.kind)
       ; "author", `String board.author
       ; "title", `String board.title
       ; "content", `String board.content
       ; "hearth", option_json (fun value -> `String value) board.hearth
       ; "updated_at_unix", option_json (fun value -> `Float value) board.updated_at
       ]
       @
       (match board.kind with
       | Post_created | Comment_added -> []
       | Reaction_changed reaction -> board_reaction_change_fields reaction))
  | Bootstrap -> `Assoc [ "kind", `String "bootstrap" ]
  | No_progress_recovery -> `Assoc [ "kind", `String "no_progress_recovery" ]
  | Fusion_completed fusion ->
    `Assoc
      [ "kind", `String "fusion_completed"
      ; "run_id", `String fusion.run_id
      ; "ok", `Bool fusion.ok
      ; "resolved_answer", `String fusion.resolved_answer
      ; "board_post_id", `String fusion.board_post_id
      ]
  | Bg_completed c ->
    let ok, payload =
      match c.bg_outcome with Bg_ok s -> (true, s) | Bg_failed s -> (false, s)
    in
    `Assoc
      [ "kind", `String "bg_completed"
      ; "run_id", `String c.bg_run_id
      ; "job_kind", `String (bg_job_kind_to_string c.bg_kind)
      ; "ok", `Bool ok
      ; "payload", `String payload
      ; "board_post_id", `String c.bg_board_post_id
      ]
  | Schedule_due sw ->
    `Assoc
      [ "kind", `String "schedule_due"
      ; "schedule_id", `String sw.schedule_id
      ; "due_at_unix", `Float sw.due_at
      ; "payload_digest", `String sw.payload_digest
      ; "title", option_json (fun value -> `String value) sw.title
      ; "message", `String sw.message
      ]
  | Connector_attention ca ->
    `Assoc
      [ "kind", `String "connector_attention"
      ; "event_id", `String ca.event_id
      ]
  | Hitl_resolved r ->
    `Assoc
      [ "kind", `String "hitl_resolved"
      ; "approval_id", `String r.approval_id
      ; "decision", `String (hitl_resolution_decision_to_string r.decision)
      ]
  | Goal_verification_failed failure ->
    `Assoc
      [ "kind", `String "goal_verification_failed"
      ; "goal_id", `String failure.goal_id
      ; "request_id", `String failure.request_id
      ; "goal_title", `String failure.goal_title
      ; "phase", `String failure.phase
      ; "metric", option_json (fun value -> `String value) failure.metric
      ; "target_value", option_json (fun value -> `String value) failure.target_value
      ; "rejected_by", `String failure.rejected_by
      ; "note", option_json (fun value -> `String value) failure.note
      ; "evidence_refs", `List (List.map (fun value -> `String value) failure.evidence_refs)
      ]

let payload_of_yojson json =
  let context = "stimulus.payload" in
  let* fields = assoc_fields ~context json in
  let* kind = string_field ~context "kind" fields in
  match kind with
  | "board_signal" ->
    let* board_kind = string_field ~context "board_kind" fields in
    let* kind =
      match board_kind with
      | "reaction_changed" ->
        let* target_type_raw = string_field ~context "reaction_target_type" fields in
        let* target_type = board_reaction_target_type_of_string target_type_raw in
        let* target_id = string_field ~context "reaction_target_id" fields in
        let* user_id = string_field ~context "reaction_user_id" fields in
        let* emoji = string_field ~context "reaction_emoji" fields in
        let* reacted = bool_field ~context "reaction_active" fields in
        Ok (Reaction_changed { target_type; target_id; user_id; emoji; reacted })
      | _ -> board_stimulus_kind_of_string board_kind
    in
    let* author = string_field ~context "author" fields in
    let* title = string_field ~context "title" fields in
    let* content = string_field ~context "content" fields in
    let* hearth = optional_string_field ~context "hearth" fields in
    let* updated_at = optional_float_field ~context "updated_at_unix" fields in
    Ok (Board_signal { kind; author; title; content; hearth; updated_at })
  | "bootstrap" -> Ok Bootstrap
  | "no_progress_recovery" -> Ok No_progress_recovery
  | "fusion_completed" ->
    let* run_id = string_field ~context "run_id" fields in
    let* ok = bool_field ~context "ok" fields in
    let* resolved_answer = string_field ~context "resolved_answer" fields in
    let* board_post_id = string_field ~context "board_post_id" fields in
    Ok (Fusion_completed { run_id; ok; resolved_answer; board_post_id })
  | "bg_completed" ->
    let* run_id = string_field ~context "run_id" fields in
    let* job_kind_s = string_field ~context "job_kind" fields in
    let* bg_kind = bg_job_kind_of_string job_kind_s in
    let* ok = bool_field ~context "ok" fields in
    let* payload = string_field ~context "payload" fields in
    let* board_post_id = string_field ~context "board_post_id" fields in
    let bg_outcome = if ok then Bg_ok payload else Bg_failed payload in
    Ok
      (Bg_completed
         { bg_run_id = run_id; bg_kind; bg_outcome; bg_board_post_id = board_post_id })
  | "schedule_due" ->
    let* schedule_id = string_field ~context "schedule_id" fields in
    let* due_at = float_field ~context "due_at_unix" fields in
    let* payload_digest = string_field ~context "payload_digest" fields in
    let* title = optional_string_field ~context "title" fields in
    let* message = string_field ~context "message" fields in
    Ok (Schedule_due { schedule_id; due_at; payload_digest; title; message })
  | "connector_attention" ->
    let* event_id = string_field ~context "event_id" fields in
    Ok (Connector_attention { event_id })
  | "hitl_resolved" ->
    let* approval_id = string_field ~context "approval_id" fields in
    let* decision_s = string_field ~context "decision" fields in
    let* decision = hitl_resolution_decision_of_string decision_s in
    Ok (Hitl_resolved { approval_id; decision })
  | "goal_verification_failed" ->
    let* goal_id = string_field ~context "goal_id" fields in
    let* request_id = string_field ~context "request_id" fields in
    let* goal_title = string_field ~context "goal_title" fields in
    let* phase = string_field ~context "phase" fields in
    let* metric = optional_string_field ~context "metric" fields in
    let* target_value = optional_string_field ~context "target_value" fields in
    let* rejected_by = string_field ~context "rejected_by" fields in
    let* note = optional_string_field ~context "note" fields in
    let* evidence_refs = string_list_field ~context "evidence_refs" fields in
    Ok
      (Goal_verification_failed
         { goal_id
         ; request_id
         ; goal_title
         ; phase
         ; metric
         ; target_value
         ; rejected_by
         ; note
         ; evidence_refs
         })
  | value -> Error (Printf.sprintf "unknown stimulus payload kind: %s" value)

let stimulus_to_yojson (stimulus : stimulus) =
  `Assoc
    [ "post_id", `String stimulus.post_id
    ; "urgency", `String (urgency_to_string stimulus.urgency)
    ; "arrived_at_unix", `Float stimulus.arrived_at
    ; "payload", payload_to_yojson stimulus.payload
    ]

let stimulus_of_yojson json =
  let context = "stimulus" in
  let* fields = assoc_fields ~context json in
  let* post_id = string_field ~context "post_id" fields in
  let* urgency_s = string_field ~context "urgency" fields in
  let* urgency = urgency_of_string urgency_s in
  let* arrived_at = float_field ~context "arrived_at_unix" fields in
  let* payload_json = required_field ~context "payload" fields in
  let* payload = payload_of_yojson payload_json in
  Ok { post_id; urgency; arrived_at; payload }

let schema = "keeper.event_queue.v1"

let queue_to_yojson queue =
  `Assoc
    [ "schema", `String schema
    ; "length", `Int (length queue)
    ; "items", `List (List.map stimulus_to_yojson (to_list queue))
    ]

let list_of_json ~context f = function
  | `List items ->
    let rec loop acc = function
      | [] -> Ok (List.rev acc)
      | item :: rest ->
        let* parsed = f item in
        loop (parsed :: acc) rest
    in
    loop [] items
  | _ -> Error (Printf.sprintf "%s must be a JSON list" context)

let queue_of_yojson json =
  let context = "keeper event queue snapshot" in
  let* fields = assoc_fields ~context json in
  let* schema_value = string_field ~context "schema" fields in
  if not (String.equal schema_value schema)
  then Error (Printf.sprintf "unsupported keeper event queue schema: %s" schema_value)
  else (
    let* items_json = required_field ~context "items" fields in
    let* items = list_of_json ~context:"keeper event queue snapshot.items" stimulus_of_yojson items_json in
    Ok (of_list items))
