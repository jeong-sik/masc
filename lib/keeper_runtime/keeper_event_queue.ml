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

and board_post_kind =
  | Human_post
  | Automation_post
  | System_post

and board_latest_external = {
  latest_author : string;
  latest_preview : string;
}

and board_thread_snapshot = {
  self_commented : bool;
  new_external_since : int;
  latest_external : board_latest_external option;
}

type board_stimulus = {
  kind : board_stimulus_kind;
  author : string;
  title : string;
  content : string;
  preview : string;
  hearth : string option;
  post_kind : board_post_kind;
  updated_at : float;
  explicit_mention : bool;
  matched_targets : string list;
  thread_snapshot : board_thread_snapshot;
}

type board_stimulus_error =
  | Non_finite_board_updated_at of float
  | Negative_new_external_since of int
  | Missing_latest_external of int
  | Explicit_mention_without_targets
  | Matched_targets_without_explicit_mention of string list

let board_stimulus_error_to_string = function
  | Non_finite_board_updated_at value ->
    Printf.sprintf "Board delivery updated_at must be finite, got %.17g" value
  | Negative_new_external_since count ->
    Printf.sprintf "Board delivery new_external_since must be non-negative, got %d" count
  | Missing_latest_external count ->
    Printf.sprintf
      "Board delivery with %d new external comments requires latest comment evidence"
      count
  | Explicit_mention_without_targets ->
    "Board delivery explicit mention requires at least one matched target"
  | Matched_targets_without_explicit_mention targets ->
    Printf.sprintf
      "Board delivery has matched targets without an explicit mention: [%s]"
      (String.concat "," targets)

let validate_board_stimulus board =
  if not (Float.is_finite board.updated_at)
  then Error (Non_finite_board_updated_at board.updated_at)
  else if board.thread_snapshot.new_external_since < 0
  then Error (Negative_new_external_since board.thread_snapshot.new_external_since)
  else if
    board.thread_snapshot.new_external_since > 0
    && Option.is_none board.thread_snapshot.latest_external
  then Error (Missing_latest_external board.thread_snapshot.new_external_since)
  else if board.explicit_mention && board.matched_targets = []
  then Error Explicit_mention_without_targets
  else if (not board.explicit_mention) && board.matched_targets <> []
  then Error (Matched_targets_without_explicit_mention board.matched_targets)
  else Ok ()

type stimulus_payload =
  | Board_signal of board_stimulus
  | Board_attention of board_attention
  | Bootstrap
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
      (* A nonblocking HITL approval this keeper enqueued was resolved. Wakes
         the keeper so it re-evaluates and proceeds on its next independent
         cycle instead of waiting for unrelated stimulus, no-progress recovery,
         or the 30-minute approval janitor. Blocking approvals resume their
         resolver directly and do not emit this duplicate wake. Mirrors
         [Fusion_completed]/[Bg_completed]: a HITL decision is an async
         completion the waiting keeper must be notified of. *)
  | Failure_judgment of failure_judgment
      (* RFC-0313 W2: a turn failure routed [Escalate_judgment] — a
         deterministic failure class where mechanical retry/rotation cannot
         change the outcome. Surfaces on the keeper's next turn as prompt
         input for an LLM-boundary verdict. Follows the
         [Fusion_completed] precedent: no
         dedicated turn_reason, so scheduling cooldowns are unchanged and
         the stable per-(runtime, class) post_id lets queue identity dedup
         collapse repeats. *)
  | Manual_compaction_requested
  | Goal_assigned of goal_assignment
      (* RFC-0315 P3 W0: a goal entered this keeper's [active_goal_ids]
         (keeper_up tool args or TOML reconcile). Wakes the keeper ONCE at
         the assignment edge so the new standing objective arrives as
         actionable turn input — before this, an assigned goal was
         discovered only if some unrelated stimulus happened to fire.
         Uses the same no-dedicated-reason pattern as async completions:
         turn_reason; the injected pending observation drives the turn. *)

and board_attention = {
  candidate_id : string;
  signal : board_stimulus;
}

and fusion_completion = {
  run_id : string;
  ok : bool;  (* judge synthesized vs denied/sink_failed/aborted. *)
  resolved_answer : string;
  (* judge resolved answer; a failure label when [ok = false]. *)
  board_post_id : string;
  (* correlates to the sink's board evidence post; "" if none was created. *)
  channel : Keeper_continuation_channel.t;
  (* RFC-0320 pattern: the connector conversation the deliberation was started
     from, captured at masc_fusion call time, so the woken keeper can deliver
     the resolved answer back into the originating channel.  [Unrouted] when
     the run was not started from a connector conversation. *)
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
  | Hitl_rejected of string
  | Hitl_edited of Yojson.Safe.t

and hitl_resolution = {
  approval_id : string;
  (* the resolved pending-approval id; correlates to the queue entry. *)
  decision : hitl_resolution_decision;
  (* resolved decision label carried for observability. *)
  channel : Keeper_continuation_channel.t;
  (* RFC-0320: the connector the resolved conversation started on, captured at
     approval-submission time and carried through so a woken keeper can reply
     into it. [Unrouted] when no originating connector was captured. *)
}

and bg_job_outcome =
  | Bg_ok of string  (* result payload *)
  | Bg_failed of string  (* failure label *)

and connector_attention = {
  event_id : string;
      (* RFC-connector-ambient-attention-wake: pointer into
         [Keeper_external_attention] for the ambient message; content/surface
         read from that store on the turn path. *)
  channel : Keeper_continuation_channel.t;
      (* RFC-0320: the connector that raised this attention, so a woken keeper
         replies into the same channel. [Unrouted] when unknown. *)
}

and scheduled_wake = {
  schedule_id : string;
  due_at : float;
  payload_digest : string;
  title : string option;
  message : string;
}

and failure_judgment = {
  fj_runtime_id : string;
  fj_judgment : Keeper_runtime_failure_route.judgment_class;
  fj_provenance : Keeper_runtime_failure_route.judgment_provenance;
  fj_detail : string;
  (* display-only failure summary for the judgment prompt, bounded by
     [Keeper_internal_error.cap_blocker_detail] at the producer. Never
     matched. *)
}

and goal_assignment = {
  ga_goal_id : string;
  ga_goal_title : string;
  (* display-only title resolved from Goal_store at enqueue time. *)
  ga_assigned_by : string;
  (* actor label for the prompt line: tool caller name or
     "toml_reconcile". Display-only; stripped from queue identity so
     repeat assignments of the same goal dedup regardless of actor. *)
}

let fusion_completion_post_id (fc : fusion_completion) =
  if String.equal fc.board_post_id "" then "fusion-run:" ^ fc.run_id
  else fc.board_post_id

let bg_job_completion_post_id (c : bg_job_completion) =
  if String.equal c.bg_board_post_id "" then "bg-run:" ^ c.bg_run_id
  else c.bg_board_post_id

let hitl_resolution_post_id (r : hitl_resolution) = "hitl-approval:" ^ r.approval_id

let failure_judgment_post_id (fj : failure_judgment) =
  (* Stable per (runtime, class, typed boundary) so repeats from the same
     execution boundary collapse under queue identity dedup without merging
     failures that require materially different judgment context. *)
  "failure-judgment:" ^ fj.fj_runtime_id ^ ":"
  ^ Keeper_runtime_failure_route.judgment_class_label fj.fj_judgment
  ^ ":"
  ^ Keeper_runtime_failure_route.judgment_provenance_label fj.fj_provenance

let manual_compaction_post_id = "manual-compaction-request"

let goal_assignment_post_id (ga : goal_assignment) =
  (* Stable per goal: re-assigning the same goal before the keeper consumes
     the first wake collapses under queue identity dedup. *)
  "goal-assigned:" ^ ga.ga_goal_id

let hitl_resolution_decision_to_string = function
  | Hitl_approved -> "approve"
  | Hitl_rejected _ -> "reject"
  | Hitl_edited _ -> "edit"

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

(* Identity projection: durable-event identity must ignore display-only
   payload fields, or repeats of the same event with volatile text (token
   counts, addresses, timestamps inside provider error strings) defeat
   [enqueue_if_missing]/[dedup_by_identity] and the queue grows unbounded
   (RFC-0313 W2 loop-safety requirement). Exhaustive on purpose: a new
   payload kind must decide its identity fields here at compile time. *)
let identity_payload = function
  | Failure_judgment fj -> Failure_judgment { fj with fj_detail = "" }
  | Goal_assigned ga ->
    Goal_assigned { ga with ga_goal_title = ""; ga_assigned_by = "" }
  | ( Board_signal _ | Board_attention _ | Bootstrap | Fusion_completed _
    | Bg_completed _ | Schedule_due _ | Connector_attention _ | Hitl_resolved _
    | Manual_compaction_requested
    ) as payload ->
    payload

type stimulus_identity =
  { identity_post_id : post_id
  ; identity_urgency : urgency
  ; identity_payload : stimulus_payload
  }

let stimulus_identity (stimulus : stimulus) =
  { identity_post_id = stimulus.post_id
  ; identity_urgency = stimulus.urgency
  ; identity_payload = identity_payload stimulus.payload
  }

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

let sort_by_urgency (queue : t) : t =
  queue
  |> to_list
  |> List.stable_sort
       (fun a b -> Int.compare (urgency_rank a.urgency) (urgency_rank b.urgency))
  |> of_list

let payload_kind_label = function
  | Board_signal _ -> "board_signal"
  | Board_attention _ -> "board_attention"
  | Bootstrap -> "bootstrap"
  | Fusion_completed _ -> "fusion_completed"
  | Bg_completed _ -> "bg_completed"
  | Schedule_due _ -> "schedule_due"
  | Connector_attention _ -> "connector_attention"
  | Hitl_resolved _ -> "hitl_resolved"
  | Failure_judgment _ -> "failure_judgment"
  | Manual_compaction_requested -> "manual_compaction_requested"
  | Goal_assigned _ -> "goal_assigned"

let is_board_signal = function
  | Board_signal _ | Board_attention _ -> true
  | Bootstrap | Fusion_completed _ | Bg_completed _
  | Schedule_due _ | Connector_attention _ | Hitl_resolved _
  | Failure_judgment _ | Manual_compaction_requested | Goal_assigned _ ->
    false

let drain_board_all (queue : t) : stimulus list * t =
  let board, rest =
    List.partition (fun s -> is_board_signal s.payload) (to_list queue)
  in
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

let board_post_kind_to_string = function
  | Human_post -> "human"
  | Automation_post -> "automation"
  | System_post -> "system"

let board_post_kind_of_string = function
  | "human" -> Ok Human_post
  | "automation" -> Ok Automation_post
  | "system" -> Ok System_post
  | value -> Error (Printf.sprintf "unknown board post kind: %s" value)

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

let board_stimulus_fields board =
  [ "board_kind", `String (board_stimulus_kind_to_string board.kind)
  ; "author", `String board.author
  ; "title", `String board.title
  ; "content", `String board.content
  ; "preview", `String board.preview
  ; "hearth", option_json (fun value -> `String value) board.hearth
  ; "post_kind", `String (board_post_kind_to_string board.post_kind)
  ; "updated_at_unix", `Float board.updated_at
  ; "explicit_mention", `Bool board.explicit_mention
  ; "matched_targets", `List (List.map (fun value -> `String value) board.matched_targets)
  ; "self_commented", `Bool board.thread_snapshot.self_commented
  ; "new_external_since", `Int board.thread_snapshot.new_external_since
  ; ( "latest_external"
    , option_json
        (fun latest ->
           `Assoc
             [ "author", `String latest.latest_author
             ; "preview", `String latest.latest_preview
             ])
        board.thread_snapshot.latest_external )
  ]
  @
  match board.kind with
  | Post_created | Comment_added -> []
  | Reaction_changed reaction -> board_reaction_change_fields reaction

let board_stimulus_to_yojson board = `Assoc (board_stimulus_fields board)

let assoc_fields ~context = function
  | `Assoc fields -> Ok fields
  | _ -> Error (Printf.sprintf "%s must be a JSON object" context)

let exact_fields ~context ~expected fields =
  let rec loop seen = function
    | [] -> Ok ()
    | (name, _) :: rest ->
      if not (List.exists (String.equal name) expected)
      then Error (Printf.sprintf "%s contains unknown field %s" context name)
      else if List.exists (String.equal name) seen
      then Error (Printf.sprintf "%s contains duplicate field %s" context name)
      else loop (name :: seen) rest
  in
  loop [] fields

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

let int_of_json ~context = function
  | `Int value -> Ok value
  | _ -> Error (Printf.sprintf "%s must be an integer" context)

let float_of_json ~context = function
  | `Float value when Float.is_finite value -> Ok value
  | `Float _ -> Error (Printf.sprintf "%s must be a finite number" context)
  | `Int value -> Ok (float_of_int value)
  | _ -> Error (Printf.sprintf "%s must be a number" context)

let optional_string_field ~context name fields =
  match optional_field name fields with
  | None -> Ok None
  | Some json ->
    let* value = string_of_json ~context:(context ^ "." ^ name) json in
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

let int_field ~context name fields =
  let* json = required_field ~context name fields in
  int_of_json ~context:(context ^ "." ^ name) json

let payload_to_yojson = function
  | Board_signal board ->
    `Assoc
      ([ "kind", `String "board_signal" ] @ board_stimulus_fields board)
  | Board_attention attention ->
    `Assoc
      ([ "kind", `String "board_attention"
       ; "candidate_id", `String attention.candidate_id
       ]
       @ board_stimulus_fields attention.signal)
  | Bootstrap -> `Assoc [ "kind", `String "bootstrap" ]
  | Fusion_completed fusion ->
    `Assoc
      [ "kind", `String "fusion_completed"
      ; "run_id", `String fusion.run_id
      ; "ok", `Bool fusion.ok
      ; "resolved_answer", `String fusion.resolved_answer
      ; "board_post_id", `String fusion.board_post_id
      ; "channel", Keeper_continuation_channel.to_yojson fusion.channel
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
      ; "channel", Keeper_continuation_channel.to_yojson ca.channel
      ]
  | Hitl_resolved r ->
    `Assoc
      ([ "kind", `String "hitl_resolved"
       ; "approval_id", `String r.approval_id
       ; "decision", `String (hitl_resolution_decision_to_string r.decision)
       ; "channel", Keeper_continuation_channel.to_yojson r.channel
       ]
       @
       match r.decision with
       | Hitl_approved -> []
       | Hitl_rejected rationale -> [ "rationale", `String rationale ]
       | Hitl_edited input -> [ "edited_input", input ])
  | Failure_judgment fj ->
    `Assoc
      [ "kind", `String "failure_judgment"
      ; "runtime_id", `String fj.fj_runtime_id
      ; "judgment_class",
        `String (Keeper_runtime_failure_route.judgment_class_label fj.fj_judgment)
      ; ( "provenance"
        , Keeper_runtime_failure_route.judgment_provenance_to_yojson fj.fj_provenance )
      ; "detail", `String fj.fj_detail
      ]
  | Manual_compaction_requested ->
    `Assoc [ "kind", `String "manual_compaction_requested" ]
  | Goal_assigned ga ->
    `Assoc
      [ "kind", `String "goal_assigned"
      ; "goal_id", `String ga.ga_goal_id
      ; "goal_title", `String ga.ga_goal_title
      ; "assigned_by", `String ga.ga_assigned_by
      ]

(* A queue identity must have one total projection for both equality and its
   durable digest.  Polymorphic equality over [float] is not reflexive for
   NaN, while JSON rendering can distinguish [-0.] from [0.] even though
   OCaml equality does not.  [Hitl_edited] also admits nested Yojson values,
   so normalising only the known timestamp fields is insufficient.

   This closed tree preserves every Yojson constructor and association-list
   position and normalises both signed zeroes to the same value. Non-finite
   values are rejected at the typed durable boundary. The tagged JSON encoder below is
   injective over this tree; an operator-authored JSON string or object cannot
   collide with an encoded float or constructor tag. *)
type canonical_identity_json =
  | Identity_null
  | Identity_bool of bool
  | Identity_int of int
  | Identity_intlit of string
  | Identity_float of canonical_identity_float
  | Identity_string of string
  | Identity_assoc of (string * canonical_identity_json) list
  | Identity_list of canonical_identity_json list

and canonical_identity_float =
  | Identity_zero
  | Identity_nonzero_bits of int64

let canonical_identity_float value =
  match classify_float value with
  | FP_zero -> Ok Identity_zero
  | FP_normal | FP_subnormal ->
    Ok (Identity_nonzero_bits (Int64.bits_of_float value))
  | FP_nan | FP_infinite ->
    Error "durable stimulus identity contains a non-finite float"

let rec canonical_identity_json_of_yojson
  : Yojson.Safe.t -> (canonical_identity_json, string) result
=
  function
  | `Null -> Ok Identity_null
  | `Bool value -> Ok (Identity_bool value)
  | `Int value -> Ok (Identity_int value)
  | `Intlit value -> Ok (Identity_intlit value)
  | `Float value ->
    let* value = canonical_identity_float value in
    Ok (Identity_float value)
  | `String value -> Ok (Identity_string value)
  | `Assoc fields ->
    let rec loop reversed = function
      | [] -> Ok (Identity_assoc (List.rev reversed))
      | (name, value) :: rest ->
        let* value = canonical_identity_json_of_yojson value in
        loop ((name, value) :: reversed) rest
    in
    loop [] fields
  | `List values ->
    let rec loop reversed = function
      | [] -> Ok (Identity_list (List.rev reversed))
      | value :: rest ->
        let* value = canonical_identity_json_of_yojson value in
        loop (value :: reversed) rest
    in
    loop [] values

let rec canonical_identity_json_to_yojson = function
  | Identity_null -> `List [ `String "null" ]
  | Identity_bool value -> `List [ `String "bool"; `Bool value ]
  | Identity_int value ->
    `List [ `String "int"; `String (string_of_int value) ]
  | Identity_intlit value -> `List [ `String "intlit"; `String value ]
  | Identity_float Identity_zero ->
    `List [ `String "float64"; `String "zero" ]
  | Identity_float (Identity_nonzero_bits bits) ->
    `List [ `String "float64_bits"; `String (Printf.sprintf "%016Lx" bits) ]
  | Identity_string value -> `List [ `String "string"; `String value ]
  | Identity_assoc fields ->
    `List
      [ `String "assoc"
      ; `List
          (List.map
             (fun (name, value) ->
                `List [ `String name; canonical_identity_json_to_yojson value ])
             fields)
      ]
  | Identity_list values ->
    `List
      [ `String "list"
      ; `List (List.map canonical_identity_json_to_yojson values)
      ]

type canonical_stimulus_identity =
  { canonical_post_id : post_id
  ; canonical_urgency : urgency
  ; canonical_payload : canonical_identity_json
  }

let canonical_stimulus_identity_result stimulus =
  let identity = stimulus_identity stimulus in
  let* canonical_payload =
    identity.identity_payload
    |> payload_to_yojson
    |> canonical_identity_json_of_yojson
  in
  Ok
    { canonical_post_id = identity.identity_post_id
    ; canonical_urgency = identity.identity_urgency
    ; canonical_payload
    }

let stimulus_identity_to_yojson identity =
  `Assoc
    [ "post_id", `String identity.canonical_post_id
    ; "urgency", `String (urgency_to_string identity.canonical_urgency)
    ; "payload", canonical_identity_json_to_yojson identity.canonical_payload
    ]

let stimulus_identity_id_result stimulus =
  let* identity = canonical_stimulus_identity_result stimulus in
  let canonical =
    identity |> stimulus_identity_to_yojson
    |> Yojson.Safe.to_string
  in
  Ok
    ("keeper-stimulus:v2:sha256:"
     ^ Digestif.SHA256.(digest_string canonical |> to_hex))

let invalid_identity operation detail =
  invalid_arg (Printf.sprintf "%s: %s" operation detail)

let stimulus_identity_id stimulus =
  match stimulus_identity_id_result stimulus with
  | Ok identity -> identity
  | Error detail -> invalid_identity "stimulus_identity_id" detail

let stimulus_identity_equal_result left right =
  let* left = canonical_stimulus_identity_result left in
  let* right = canonical_stimulus_identity_result right in
  Ok (left = right)

let stimulus_identity_equal left right =
  match stimulus_identity_equal_result left right with
  | Ok equal -> equal
  | Error detail -> invalid_identity "stimulus_identity_equal" detail

let validate_stimulus stimulus =
  if not (Float.is_finite stimulus.arrived_at)
  then Error "durable stimulus arrived_at must be finite"
  else
    let* () =
      match stimulus.payload with
      | Board_signal board | Board_attention { signal = board; _ } ->
        validate_board_stimulus board
        |> Result.map_error board_stimulus_error_to_string
      | Bootstrap
      | Fusion_completed _
      | Bg_completed _
      | Schedule_due _
      | Connector_attention _
      | Hitl_resolved _
      | Failure_judgment _
      | Manual_compaction_requested
      | Goal_assigned _ ->
        Ok ()
    in
    Result.map (fun _ -> ()) (canonical_stimulus_identity_result stimulus)

module Stimulus_identity_id_set = Set.Make (String)

let uniq_stimuli stimuli =
  let _, reversed =
    List.fold_left
      (fun (seen, acc) stimulus ->
         let identity_id = stimulus_identity_id stimulus in
         if Stimulus_identity_id_set.mem identity_id seen
         then seen, acc
         else Stimulus_identity_id_set.add identity_id seen, stimulus :: acc)
      (Stimulus_identity_id_set.empty, [])
      stimuli
  in
  List.rev reversed

let dedup_by_identity queue = queue |> to_list |> uniq_stimuli |> of_list

let remove_by_post_id_pair post_id left right =
  let left_removed, left' = remove_by_post_id post_id left in
  let right_removed, right' = remove_by_post_id post_id right in
  uniq_stimuli (left_removed @ right_removed), left', right'

let continuation_channel_field fields =
  let* json = required_field ~context:"stimulus.payload" "channel" fields in
  Keeper_continuation_channel.of_yojson json

let payload_of_yojson json =
  let context = "stimulus.payload" in
  let* fields = assoc_fields ~context json in
  let* kind = string_field ~context "kind" fields in
  let parse_board_stimulus ~additional_fields () =
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
    let board_fields =
      [ "kind"
      ; "board_kind"
      ; "author"
      ; "title"
      ; "content"
      ; "preview"
      ; "hearth"
      ; "post_kind"
      ; "updated_at_unix"
      ; "explicit_mention"
      ; "matched_targets"
      ; "self_commented"
      ; "new_external_since"
      ; "latest_external"
      ]
    in
    let reaction_fields =
      match kind with
      | Post_created | Comment_added -> []
      | Reaction_changed _ ->
        [ "reaction_target_type"
        ; "reaction_target_id"
        ; "reaction_user_id"
        ; "reaction_emoji"
        ; "reaction_active"
        ]
    in
    let* () =
      exact_fields
        ~context
        ~expected:(board_fields @ additional_fields @ reaction_fields)
        fields
    in
    let* author = string_field ~context "author" fields in
    let* title = string_field ~context "title" fields in
    let* content = string_field ~context "content" fields in
    let* preview = string_field ~context "preview" fields in
    let* hearth = optional_string_field ~context "hearth" fields in
    let* post_kind_raw = string_field ~context "post_kind" fields in
    let* post_kind = board_post_kind_of_string post_kind_raw in
    let* updated_at = float_field ~context "updated_at_unix" fields in
    let* explicit_mention = bool_field ~context "explicit_mention" fields in
    let* matched_targets = string_list_field ~context "matched_targets" fields in
    let* self_commented = bool_field ~context "self_commented" fields in
    let* new_external_since = int_field ~context "new_external_since" fields in
    let* latest_external_json = required_field ~context "latest_external" fields in
    let* latest_external =
      match latest_external_json with
      | `Null -> Ok None
      | `Assoc latest_fields ->
        let latest_context = context ^ ".latest_external" in
        let* () =
          exact_fields
            ~context:latest_context
            ~expected:[ "author"; "preview" ]
            latest_fields
        in
        let* latest_author = string_field ~context:latest_context "author" latest_fields in
        let* latest_preview = string_field ~context:latest_context "preview" latest_fields in
        Ok (Some { latest_author; latest_preview })
      | _ -> Error (context ^ ".latest_external must be an object or null")
    in
    let board =
      { kind
      ; author
      ; title
      ; content
      ; preview
      ; hearth
      ; post_kind
      ; updated_at
      ; explicit_mention
      ; matched_targets
      ; thread_snapshot = { self_commented; new_external_since; latest_external }
      }
    in
    let* () =
      validate_board_stimulus board
      |> Result.map_error board_stimulus_error_to_string
    in
    Ok board
  in
  match kind with
  | "board_signal" ->
    let* signal = parse_board_stimulus ~additional_fields:[] () in
    Ok (Board_signal signal)
  | "board_attention" ->
    let* candidate_id = string_field ~context "candidate_id" fields in
    if String.equal candidate_id ""
    then Error "stimulus.payload.candidate_id must not be empty"
    else
      let* signal = parse_board_stimulus ~additional_fields:[ "candidate_id" ] () in
      Ok (Board_attention { candidate_id; signal })
  | "bootstrap" ->
    let* () = exact_fields ~context ~expected:[ "kind" ] fields in
    Ok Bootstrap
  | "fusion_completed" ->
    let* () =
      exact_fields
        ~context
        ~expected:[ "kind"; "run_id"; "ok"; "resolved_answer"; "board_post_id"; "channel" ]
        fields
    in
    let* run_id = string_field ~context "run_id" fields in
    let* ok = bool_field ~context "ok" fields in
    let* resolved_answer = string_field ~context "resolved_answer" fields in
    let* board_post_id = string_field ~context "board_post_id" fields in
    let* channel = continuation_channel_field fields in
    Ok (Fusion_completed { run_id; ok; resolved_answer; board_post_id; channel })
  | "bg_completed" ->
    let* () =
      exact_fields
        ~context
        ~expected:[ "kind"; "run_id"; "job_kind"; "ok"; "payload"; "board_post_id" ]
        fields
    in
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
    let* () =
      exact_fields
        ~context
        ~expected:[ "kind"; "schedule_id"; "due_at_unix"; "payload_digest"; "title"; "message" ]
        fields
    in
    let* schedule_id = string_field ~context "schedule_id" fields in
    let* due_at = float_field ~context "due_at_unix" fields in
    let* payload_digest = string_field ~context "payload_digest" fields in
    let* title = optional_string_field ~context "title" fields in
    let* message = string_field ~context "message" fields in
    Ok (Schedule_due { schedule_id; due_at; payload_digest; title; message })
  | "connector_attention" ->
    let* () =
      exact_fields ~context ~expected:[ "kind"; "event_id"; "channel" ] fields
    in
    let* event_id = string_field ~context "event_id" fields in
    let* channel = continuation_channel_field fields in
    Ok (Connector_attention { event_id; channel })
  | "hitl_resolved" ->
    let* approval_id = string_field ~context "approval_id" fields in
    let* decision_s = string_field ~context "decision" fields in
    let* decision =
      match decision_s with
      | "approve" ->
        let* () =
          exact_fields
            ~context
            ~expected:[ "kind"; "approval_id"; "decision"; "channel" ]
            fields
        in
        Ok Hitl_approved
      | "reject" ->
        let* () =
          exact_fields
            ~context
            ~expected:[ "kind"; "approval_id"; "decision"; "channel"; "rationale" ]
            fields
        in
        let* rationale = string_field ~context "rationale" fields in
        Ok (Hitl_rejected rationale)
      | "edit" ->
        let* () =
          exact_fields
            ~context
            ~expected:[ "kind"; "approval_id"; "decision"; "channel"; "edited_input" ]
            fields
        in
        let* input = required_field ~context "edited_input" fields in
        Ok (Hitl_edited input)
      | other -> Error (Printf.sprintf "unknown hitl_resolution decision: %s" other)
    in
    let* channel = continuation_channel_field fields in
    Ok (Hitl_resolved { approval_id; decision; channel })
  | "failure_judgment" ->
    let* () =
      exact_fields
        ~context
        ~expected:[ "kind"; "runtime_id"; "judgment_class"; "provenance"; "detail" ]
        fields
    in
    let* runtime_id = string_field ~context "runtime_id" fields in
    let* judgment_label = string_field ~context "judgment_class" fields in
    let* judgment =
      match Keeper_runtime_failure_route.judgment_class_of_label judgment_label with
      | Some judgment -> Ok judgment
      | None ->
        Error (Printf.sprintf "unknown failure_judgment class: %s" judgment_label)
    in
    let* provenance =
      match List.assoc_opt "provenance" fields with
      | Some json ->
        let* provenance =
          Keeper_runtime_failure_route.judgment_provenance_of_yojson json
        in
        (match provenance with
         | Keeper_runtime_failure_route.Legacy_unattributed ->
           Error
             "stimulus.payload.provenance legacy_unattributed is outside the v4 queue authority"
         | Keeper_runtime_failure_route.Oas_api_error
         | Keeper_runtime_failure_route.Oas_provider_error
         | Keeper_runtime_failure_route.Oas_agent_error
         | Keeper_runtime_failure_route.Oas_mcp_error
         | Keeper_runtime_failure_route.Oas_config_error
         | Keeper_runtime_failure_route.Oas_serialization_error
         | Keeper_runtime_failure_route.Oas_io_error
         | Keeper_runtime_failure_route.Oas_orchestration_error
         | Keeper_runtime_failure_route.Oas_internal_error
         | Keeper_runtime_failure_route.Masc_internal_error
         | Keeper_runtime_failure_route.Completion_contract ->
           Ok provenance)
      | None -> Error "stimulus.payload missing required field provenance"
    in
    let* detail = string_field ~context "detail" fields in
    Ok
      (Failure_judgment
         { fj_runtime_id = runtime_id
         ; fj_judgment = judgment
         ; fj_provenance = provenance
         ; fj_detail = detail
         })
  | "manual_compaction_requested" ->
    let* () = exact_fields ~context ~expected:[ "kind" ] fields in
    Ok Manual_compaction_requested
  | "goal_assigned" ->
    let* () =
      exact_fields
        ~context
        ~expected:[ "kind"; "goal_id"; "goal_title"; "assigned_by" ]
        fields
    in
    let* goal_id = string_field ~context "goal_id" fields in
    let* goal_title = string_field ~context "goal_title" fields in
    let* assigned_by = string_field ~context "assigned_by" fields in
    Ok
      (Goal_assigned
         { ga_goal_id = goal_id
         ; ga_goal_title = goal_title
         ; ga_assigned_by = assigned_by
         })
  | value -> Error (Printf.sprintf "unknown stimulus payload kind: %s" value)

let board_stimulus_of_yojson json =
  let* fields = assoc_fields ~context:"board stimulus" json in
  let* payload = payload_of_yojson (`Assoc (("kind", `String "board_signal") :: fields)) in
  match payload with
  | Board_signal board -> Ok board
  | Board_attention _
  | Bootstrap
  | Fusion_completed _
  | Bg_completed _
  | Schedule_due _
  | Connector_attention _
  | Hitl_resolved _
  | Failure_judgment _
  | Manual_compaction_requested
  | Goal_assigned _ ->
    Error "board stimulus codec produced a non-Board payload"

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
  let* () =
    exact_fields
      ~context
      ~expected:[ "post_id"; "urgency"; "arrived_at_unix"; "payload" ]
      fields
  in
  let* post_id = string_field ~context "post_id" fields in
  let* urgency_s = string_field ~context "urgency" fields in
  let* urgency = urgency_of_string urgency_s in
  let* arrived_at = float_field ~context "arrived_at_unix" fields in
  let* payload_json = required_field ~context "payload" fields in
  let* payload = payload_of_yojson payload_json in
  let stimulus = { post_id; urgency; arrived_at; payload } in
  let* () = validate_stimulus stimulus in
  Ok stimulus

let schema = "keeper.event_queue.v4"

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
  let* () = exact_fields ~context ~expected:[ "schema"; "length"; "items" ] fields in
  let* schema_value = string_field ~context "schema" fields in
  if not (String.equal schema_value schema)
  then Error (Printf.sprintf "unsupported keeper event queue schema: %s" schema_value)
  else (
    let* declared_length = int_field ~context "length" fields in
    let* items_json = required_field ~context "items" fields in
    let* items = list_of_json ~context:"keeper event queue snapshot.items" stimulus_of_yojson items_json in
    if declared_length < 0
    then Error "keeper event queue snapshot.length must not be negative"
    else if declared_length <> List.length items
    then
      Error
        (Printf.sprintf
           "keeper event queue snapshot length mismatch: declared=%d actual=%d"
           declared_length
           (List.length items))
    else Ok (of_list items))
