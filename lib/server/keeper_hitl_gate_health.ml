(* The keeper_hitl_gate section of /health?full=1 (task-1665, design D1).

   The aggregation is pure and closed over the queue's typed states: the
   queue's variants are matched exhaustively and no status string is ever
   compared, so a new queue state fails to compile here instead of silently
   counting as something else. The server route and the tests read one
   function.

   Status vocabulary is the shared health grade vocabulary so the operator
   rollup picks the section up by its ordinary parse:
   - ok — open asks working as designed: held calls, queued asks, a summary
     not yet requested, and judgments the live process is finalizing. They
     are visible through the counts and [oldest] without raising the
     workspace's overall grade, because a manual-mode workspace owing a
     human answer is normal operation, not a degraded subsystem.
   - warning + operator action — [exact_bound_residual] rows: asks the
     classification cannot attribute to boot recovery or the live
     finalizer, which a restart leaves behind (design B3's gap). Only an
     operator unblocks those.
   - unavailable + operator action — the durable queue could not be read;
     an unread authority never counts as an empty gate. *)

let schema = "masc.keeper_hitl_gate.v1"

(* What one open ask looks like as a candidate for the section's [oldest]:
   enough to answer "what has been waiting, on what, for how long". A live
   wait carries the tool call id and its wait budget; a durable entry is a
   queued request, not a held call, so both stay absent. *)
type oldest_candidate =
  { kind : string
  ; keeper : string
  ; tool : string
  ; tool_call_id : string option
  ; asked_at : float
  ; timeout_sec : float option
  }

let candidate_of_wait (w : Keeper_tool_approval_registry.pending) =
  { kind = "held_call"
  ; keeper = w.keeper_name
  ; tool = w.tool_name
  ; tool_call_id = Some w.tool_call_id
  ; asked_at = w.asked_at
  ; timeout_sec = Some w.timeout_sec
  }

let candidate_of_entry
      (entry : Keeper_approval_queue_rules_types.pending_approval) =
  { kind = "queued_ask"
  ; keeper = entry.keeper_name
  ; tool = entry.tool_name
  ; tool_call_id = None
  ; asked_at = entry.requested_at
  ; timeout_sec = None
  }

let oldest_json ~now = function
  | None -> `Null
  | Some candidate ->
    `Assoc
      ([ ("kind", `String candidate.kind)
       ; ("keeper", `String candidate.keeper)
       ; ("tool", `String candidate.tool)
       ]
       @ (match candidate.tool_call_id with
          | Some id -> [ ("tool_call_id", `String id) ]
          | None -> [])
       @ [ ("asked_at", `Float candidate.asked_at)
         ; ("age_sec", `Float (max 0.0 (now -. candidate.asked_at)))
         ; ( "timeout_sec"
           , match candidate.timeout_sec with
             | Some t -> `Float t
             | None -> `Null )
         ])

(* Classification mirrors the boundaries the product already acts on,
   without importing the gate's admission semantics into this projection:

   - [Not_requested] / [Pending] — the pair boot recovery re-admits
     (keeper_gate's classify: summary ready + exact unbound). [Pending]
     additionally names a summary worker claim, which [Pending_start] —
     the same row holding an orphaned or live start reservation — reports
     separately so the operator can tell an unclaimed ask from a claimed
     one.
   - [Finalizable] — an exact attempt with provable completion or a
     durable no-dispatch release over a non-ready summary attempt. The
     active process finalizes these; a restart re-admits them through the
     same proof. Working as designed, never an attention row.
   - [Residual] — everything else. A restart leaves these behind (design
     B3's gap): an exact attempt bound without a completion or release
     proof, or a non-ready disposition over an unbound exact attempt.
     Only an operator unblocks them.

   Exhaustive on both matched types: a new constructor lands in [Residual]
   until an arm is written for it — the compiler says so, the section never
   silently miscounts. *)
type entry_class =
  | Not_requested
  | Pending
  | Pending_start
  | Finalizable
  | Residual

let classify_entry ~is_live
    (entry : Keeper_approval_queue_rules_types.pending_approval)
    =
  let module Q = Keeper_approval_queue_rules_types in
  let exact_proof_of_completion = function
    | Q.Exact_bound
        { status = (Q.Exact_completed | Q.Exact_released_before_dispatch); _ }
      -> true
    | Q.Exact_unbound | Q.Exact_bound _ -> false
  in
  match entry.summary_attempt_disposition with
  | Q.Summary_attempt_ready ->
    (match entry.summary_status, entry.exact_attempt with
     | Q.Summary_not_requested, Q.Exact_unbound -> Not_requested
     | Q.Summary_pending, Q.Exact_unbound -> Pending
     | ( Q.Summary_not_requested
       | Q.Summary_pending
       | Q.Summary_available _
       | Q.Summary_failed _ )
     , ( Q.Exact_unbound
       | Q.Exact_bound _ ) ->
       Residual)
  | Q.Summary_attempt_in_flight ->
    (* The judgment call itself: [bind] writes the exact attempt as
       [Exact_dispatch_uncertain], which is no proof of completion, for the
       whole provider call. The row is the live finalizer's own work exactly
       while this process holds the admission for it; the same row without
       that admission is what a restart strands, and only then is it a
       residual. *)
    if exact_proof_of_completion entry.exact_attempt || is_live entry
    then Finalizable
    else Residual
  | Q.Summary_attempt_pre_worker_unavailable
      { reason_code = Q.Summary_pre_worker_start_reserved; _ } ->
    (* A start reservation is held before any exact attempt is bound, so the
       codec only admits it over [Exact_unbound]. A live reservation is the
       finalizer's claim; an orphaned one is reclaimed by boot recovery
       without an operator. Both are [Pending_start]. *)
    (match entry.exact_attempt with
     | Q.Exact_unbound -> Pending_start
     | Q.Exact_bound _ -> Residual)
  | ( Q.Summary_attempt_identity_unbound
    | Q.Summary_attempt_persistence_uncertain
    | Q.Summary_attempt_pre_worker_unavailable
        { reason_code =
            ( Q.Summary_pre_worker_auto_judge_unavailable
            | Q.Summary_pre_worker_mode_state_invalid )
        ; _
        } ) ->
    if exact_proof_of_completion entry.exact_attempt
    then Finalizable
    else Residual
  | Q.Summary_attempt_settled ->
    if exact_proof_of_completion entry.exact_attempt
    then Finalizable
    else Residual

type counts =
  { not_requested : int
  ; pending : int
  ; pending_start : int
  ; finalizable : int
  ; residual : int
  }

let zero_counts = { not_requested = 0; pending = 0; pending_start = 0; finalizable = 0; residual = 0 }

let fold_entry ~is_live counts entry =
  match classify_entry ~is_live entry with
  | Not_requested -> { counts with not_requested = counts.not_requested + 1 }
  | Pending -> { counts with pending = counts.pending + 1 }
  | Pending_start -> { counts with pending_start = counts.pending_start + 1 }
  | Finalizable -> { counts with finalizable = counts.finalizable + 1 }
  | Residual -> { counts with residual = counts.residual + 1 }

let section_fields ~counts_complete ~status ~status_reasons
    ~operator_action_required ~operator_action_reasons ~waits ~entries
    ~answered_total ~timed_out_total ~late_uncertain ~is_live ~now =
  let counts = List.fold_left (fold_entry ~is_live) zero_counts entries in
  let oldest =
    match
      List.map candidate_of_wait waits @ List.map candidate_of_entry entries
    with
    | [] -> None
    | candidates ->
      Some
        (List.hd
           (List.sort
              (fun left right -> compare left.asked_at right.asked_at)
              candidates))
  in
  `Assoc
    ([ ("schema", `String schema)
     ; ("status", `String status)
     ; ("approvals_open", `Int (List.length waits))
     ; ("oldest", oldest_json ~now oldest)
     ; ("summary_not_requested", `Int counts.not_requested)
     ; ("summary_pending", `Int counts.pending)
     ; ("summary_pending_start", `Int counts.pending_start)
     ; ("summary_finalizable", `Int counts.finalizable)
     ; ("exact_bound_residual", `Int counts.residual)
     ; ("late_uncertain", `Int late_uncertain)
     ; ("answered_total", `Int answered_total)
     ; ("timed_out_total", `Int timed_out_total)
     ; ("counts_complete", `Bool counts_complete)
     ; ("operator_action_required", `Bool operator_action_required)
     ; ( "operator_action_reasons"
       , `List (List.map (fun r -> `String r) operator_action_reasons) )
     ; ( "status_reasons"
       , `List (List.map (fun r -> `String r) status_reasons) )
     ])

(* The section for a queue this process can read. Design D1's attention
   threshold for a live wait (age over timeout_sec * 2) cannot fire: a wait
   that outlives its budget is no longer in the registry at all, so live
   waits never drive attention — the durable residual does. *)
let aggregate ~now ~is_live ~waits ~entries ~unread_entries ~answered_total
    ~timed_out_total ~late_uncertain =
  let counts = List.fold_left (fold_entry ~is_live) zero_counts entries in
  (* Each reason is an operator-only condition: a residual row, a consumed
     late answer whose delivery is unknown, and rows the queue could not
     read (their counts are a lower bound, not a total). *)
  let attention =
    (if counts.residual > 0 then
       [ Printf.sprintf "exact_bound_residual=%d" counts.residual ]
     else [])
    @ (if late_uncertain > 0 then
         [ Printf.sprintf "late_uncertain=%d" late_uncertain ]
       else [])
    @
    if unread_entries > 0 then
      [ Printf.sprintf "pending_rows_unreadable=%d" unread_entries ]
    else []
  in
  let status = if attention <> [] then "warning" else "ok" in
  section_fields ~counts_complete:(unread_entries = 0) ~status
    ~status_reasons:attention
    ~operator_action_required:(attention <> [])
    ~operator_action_reasons:attention
    ~waits ~entries ~answered_total ~timed_out_total ~late_uncertain ~is_live
    ~now

let no_workspace_json ~now ~waits ~answered_total ~timed_out_total
    ~late_uncertain () =
  (* No workspace state: the live-wait side stays real, the durable side is
     not zero but unread, and snapshot_not_ready is the grade that says so
     without demanding an operator. *)
  section_fields ~counts_complete:false ~status:"snapshot_not_ready"
    ~status_reasons:[ "workspace_state_not_ready" ]
    ~operator_action_required:false ~operator_action_reasons:[]
    ~waits ~entries:[] ~answered_total ~timed_out_total ~late_uncertain
    ~is_live:(fun _ -> false)
    ~now

let queue_unreadable_json ~error =
  (* An unread authority is not an empty gate. Reporting counts here would
     silently read as "nothing pending", so the section goes unavailable and
     demands the operator. *)
  `Assoc
    [ ("schema", `String schema)
    ; ("status", `String "unavailable")
    ; ("approvals_open", `Int 0)
    ; ("oldest", `Null)
    ; ("summary_not_requested", `Int 0)
    ; ("summary_pending", `Int 0)
    ; ("summary_pending_start", `Int 0)
    ; ("summary_finalizable", `Int 0)
    ; ("exact_bound_residual", `Int 0)
    ; ("late_uncertain", `Int 0)
    ; ("answered_total", `Int 0)
    ; ("timed_out_total", `Int 0)
    ; ("counts_complete", `Bool false)
    ; ("operator_action_required", `Bool true)
    ; ( "operator_action_reasons"
      , `List [ `String "approval_queue_unreadable" ] )
    ; ( "status_reasons"
      , `List
          [ `String (Printf.sprintf "approval_queue_unreadable: %s" error) ] )
    ]

let late_journal_unavailable_json ~error =
  (* The late-approval journal fences every late-answer write while it is
     unreadable, so an operator must act; a bare status would drop out of
     the rollup's operator_action_reasons. *)
  `Assoc
    [ ("schema", `String schema)
    ; ("status", `String "unavailable")
    ; ("counts_complete", `Bool false)
    ; ("operator_action_required", `Bool true)
    ; ("operator_action_reasons", `List [ `String "late_approval_journal_unavailable" ])
    ; ( "status_reasons"
      , `List
          [ `String (Printf.sprintf "late_approval_journal_unavailable: %s" error) ] )
    ]
