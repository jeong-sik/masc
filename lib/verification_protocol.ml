(** Verification_protocol -- Cross-agent verification workflow orchestration.

    Bridges task FSM transitions (AwaitingVerification state) with:
    - Board system (Direct visibility posts to verifiers)
    - SSE events (masc:verification:requested, :verdict, :rejected)
    - Verification storage (.masc/verifications/)

    @since Phase B+C *)

(* Fail-closed by types: [~assignee] is passed directly by the caller,
   which already destructures [AwaitingVerification { assignee; _ }]. Removes
   the prior "unknown" fallback that violated Silent Failure 금지. Issue #7547.

   Contract source rules (must stay aligned with [task_contract] in
   types_core.ml):
   - [criteria]: the operator-facing "must be true" statements →
     [task.contract.completion_contract] wrapped in [Verification.Custom].
   - [evidence_refs]: the artefact list the verifier expects to see →
     [task.contract.verify_gate_evidence], passed in by the caller at
     [tool_task.ml] so this function does not reach into task.contract
   twice for different fields. *)
type submit_request_spec =
  { criteria : Verification.criterion list
  ; output : Yojson.Safe.t
  ; request_kind : string
  ; request_summary : string
  ; next_action : string
  ; board_type : string
  ; board_title : string
  ; board_content : string
  }

let first_line text =
  match String.index_opt text '\n' with
  | Some i -> String.sub text 0 i
  | None -> text

let deliverable_claims_completion ~task_id deliverable =
  let normalized =
    deliverable
    |> String.trim
    |> String.lowercase_ascii
    |> first_line
  in
  normalized <> ""
  && (String.starts_with
        ~prefix:(String.lowercase_ascii task_id ^ " completed")
        normalized
      || String.starts_with ~prefix:"completed" normalized)

let submit_request_spec ~(config : Coord.config) ~(task : Types.task)
    ~assignee ~evidence_refs =
  let request_kind, request_summary, next_action, board_type, board_title, board_content =
    match Planning_eio.load config ~task_id:task.id with
    | Ok plan_ctx
      when deliverable_claims_completion ~task_id:task.id plan_ctx.deliverable ->
        ( "conflict_triage",
          "Conflict verification required: board / planning / mutation path disagree.",
          "Reconcile board / planning / mutation surfaces before ordinary approval.",
          "verification_conflict_request",
          Printf.sprintf "Conflict verify: %s" task.title,
          Printf.sprintf
            "Conflict verification required for task %s (%s) by %s. Do not approve as ordinary merged-PR verification; reconcile board / planning / mutation surfaces first."
            task.id task.title assignee )
    | Ok _ | Error _ ->
        ( "normal",
          "",
          "",
          "verification_request",
          Printf.sprintf "Verify: %s" task.title,
          Printf.sprintf "Verification requested for task %s (%s) by %s"
            task.id task.title assignee )
  in
  let criteria = List.map (fun s -> Verification.Custom s)
    (match task.contract with
     | Some c -> c.completion_contract
     | None -> []) in
  let output =
    `Assoc [
      ("evidence_refs", `List (List.map (fun s -> `String s) evidence_refs));
      ("task_title", `String task.title);
      ("request_kind", `String request_kind);
      ("request_summary", `String request_summary);
      ("next_action", `String next_action);
    ]
  in
  { criteria
  ; output
  ; request_kind
  ; request_summary
  ; next_action
  ; board_type
  ; board_title
  ; board_content
  }

let warn_contract_gap (task : Types.task) =
  (* Observability for #8272: tasks submitted without a contract land in
     storage with empty completion_contract + empty evidence, which the
     dashboard renders as "—". Surface this as a warn so operators can
     trace the gap back to the task creation site instead of only
     noticing it in the UI. No behavior change. *)
  (match task.contract with
   | None ->
     Log.Task.warn
       "[verification-submit] task=%s has no contract — completion_contract \
        and evidence will be empty in the verification record"
       task.id
   | Some c when c.completion_contract = [] && c.verify_gate_evidence = [] ->
     Log.Task.warn
       "[verification-submit] task=%s has a contract but both \
       completion_contract and verify_gate_evidence are empty"
       task.id
   | Some _ -> ())

let create_submit_request ~(config : Coord.config)
    ~(task : Types.task) ~assignee ~verification_id ~evidence_refs =
  let base_path = config.Coord.base_path in
  warn_contract_gap task;
  let spec = submit_request_spec ~config ~task ~assignee ~evidence_refs in
  match
    Verification.create_request ~base_path ~task_id:task.id ~request_id:verification_id
      ~output:spec.output ~criteria:spec.criteria ~worker:assignee ()
  with
  | Ok _ -> Ok ()
  | Error e ->
    Log.Task.error
      "verification create_request failed (task=%s vrf=%s): %s"
      task.id verification_id e;
    Error e

let notify_submit_for_verification ~(config : Coord.config)
    ~(task : Types.task) ~assignee ~verification_id ~evidence_refs =
  let spec = submit_request_spec ~config ~task ~assignee ~evidence_refs in
  let meta_json = `Assoc [
    ("type", `String spec.board_type);
    ("task_id", `String task.id);
    ("verification_id", `String verification_id);
    ("worker", `String assignee);
    ("evidence_refs", `List (List.map (fun s -> `String s) evidence_refs));
    ("criteria", `List (List.map Verification.criterion_to_yojson spec.criteria));
    ("request_kind", `String spec.request_kind);
    ("next_action", `String spec.next_action);
  ] in
  let () =
    match Board_dispatch.create_post
      ~author:"system"
      ~content:spec.board_content
      ~title:spec.board_title
      ~post_kind:Board.System_post
      ~meta_json
      ~visibility:Board.Internal
      ~hearth:"verification"
      ()
    with
    | Ok _ -> ()
    | Error e ->
      Log.Task.error
        "board post failed (task=%s vrf=%s): %s"
        task.id verification_id (Board_types.show_board_error e)
  in
  Subscriptions.push_event_to_sessions (`Assoc [
    ("type", `String "masc/verification/requested");
    ("task_id", `String task.id);
    ("verification_id", `String verification_id);
    ("worker", `String assignee);
    ("evidence_refs", `List (List.map (fun s -> `String s) evidence_refs));
    ("timestamp", `Float (Time_compat.now ()));
  ]);
  ()

let on_submit_for_verification ~(config : Coord.config)
    ~(task : Types.task) ~assignee ~verification_id ~evidence_refs =
  match create_submit_request ~config ~task ~assignee ~verification_id ~evidence_refs with
  | Error e -> Error e
  | Ok () ->
    notify_submit_for_verification ~config ~task ~assignee ~verification_id ~evidence_refs;
    Ok ()

let record_approve_verification ~(config : Coord.config)
    ~task_id ~verifier ~verification_id ~notes =
  let base_path = config.Coord.base_path in
  (* Update Verification.ml state machine: Pending -> Completed Pass.
     Issue #7544. *)
  if verification_id = "" then
    Error "verification_id is required for approval verdict persistence"
  else
    match
      Verification.submit_verdict
        ~base_path
        ~req_id:verification_id
        ~verifier
        ~verdict:Verification.Pass
    with
    | Ok updated ->
      Verification.attribution_of_request updated
      |> Option.iter Dashboard_attribution.record;
      Ok ()
    | Error e ->
      Log.Task.error
        "verification submit_verdict failed (task=%s vrf=%s verifier=%s): %s"
        task_id verification_id verifier e;
      Error e

let notify_approve_verification ~task_id ~verifier ~verification_id ~notes =
  let meta_json = `Assoc [
    ("type", `String "verification_verdict");
    ("task_id", `String task_id);
    ("verification_id", `String verification_id);
    ("verdict", `String "approved");
  ] in
  let () =
    match Board_dispatch.create_post
      ~author:verifier
      ~content:(Printf.sprintf "Approved task %s (vrf:%s)%s"
        task_id verification_id
        (if notes = "" then "" else " — " ^ notes))
      ~post_kind:Board.System_post
      ~meta_json
      ~visibility:Board.Internal
      ~hearth:"verification"
      ()
    with
    | Ok _ -> ()
    | Error e ->
      Log.Task.error
        "board post failed (task=%s vrf=%s): %s"
        task_id verification_id (Board_types.show_board_error e)
  in
  Subscriptions.push_event_to_sessions (`Assoc [
    ("type", `String "masc/verification/verdict");
    ("task_id", `String task_id);
    ("verification_id", `String verification_id);
    ("verifier", `String verifier);
    ("verdict", `String "approved");
    ("notes", `String notes);
    ("timestamp", `Float (Time_compat.now ()));
  ])

let on_approve_verification ~(config : Coord.config)
    ~task_id ~verifier ~verification_id ~notes =
  match
    record_approve_verification ~config ~task_id ~verifier ~verification_id ~notes
  with
  | Error e -> Error e
  | Ok () ->
    notify_approve_verification ~task_id ~verifier ~verification_id ~notes;
    Ok ()

let record_reject_verification ~(config : Coord.config)
    ~task_id ~verifier ~verification_id ~reason =
  let base_path = config.Coord.base_path in
  (* Update Verification.ml state machine: Pending -> Completed (Fail reason).
     Issue #7544. *)
  if verification_id = "" then
    Error "verification_id is required for rejection verdict persistence"
  else
    match
      Verification.submit_verdict
        ~base_path
        ~req_id:verification_id
        ~verifier
        ~verdict:(Verification.Fail reason)
    with
    | Ok updated ->
      Verification.attribution_of_request updated
      |> Option.iter Dashboard_attribution.record;
      Ok ()
    | Error e ->
      Log.Task.error
        "verification submit_verdict failed (task=%s vrf=%s verifier=%s): %s"
        task_id verification_id verifier e;
      Error e

let notify_reject_verification ~task_id ~verifier ~verification_id ~reason =
  let meta_json = `Assoc [
    ("type", `String "verification_verdict");
    ("task_id", `String task_id);
    ("verification_id", `String verification_id);
    ("verdict", `String "rejected");
  ] in
  let () =
    match Board_dispatch.create_post
      ~author:verifier
      ~content:(Printf.sprintf "Rejected task %s (vrf:%s): %s"
        task_id verification_id reason)
      ~post_kind:Board.System_post
      ~meta_json
      ~visibility:Board.Internal
      ~hearth:"verification"
      ()
    with
    | Ok _ -> ()
    | Error e ->
      Log.Task.error
        "board post failed (task=%s vrf=%s): %s"
        task_id verification_id (Board_types.show_board_error e)
  in
  Subscriptions.push_event_to_sessions (`Assoc [
    ("type", `String "masc/verification/rejected");
    ("task_id", `String task_id);
    ("verification_id", `String verification_id);
    ("verifier", `String verifier);
    ("reason", `String reason);
    ("timestamp", `Float (Time_compat.now ()));
  ])

let on_reject_verification ~(config : Coord.config)
    ~task_id ~verifier ~verification_id ~reason =
  match
    record_reject_verification ~config ~task_id ~verifier ~verification_id ~reason
  with
  | Error e -> Error e
  | Ok () ->
    notify_reject_verification ~task_id ~verifier ~verification_id ~reason;
    Ok ()

let check_timeouts ~(config : Coord.config) =
  if not (Env_config_runtime.Verification.fsm_enabled ()) then ()
  else
    try
      let backlog = Coord.read_backlog config in
      let now = Time_compat.now () in
      List.iter (fun (task : Types.task) ->
        match task.task_status with
        | Types.AwaitingVerification { assignee; verification_id; deadline = Some dl; _ } ->
          (match Types.parse_iso8601_opt dl with
           | Some deadline_ts when now > deadline_ts ->
             let () =
               match Board_dispatch.create_post
                 ~author:"system"
                 ~content:(Printf.sprintf
                   "Verification timeout: task %s (%s) by %s — no verifier responded within deadline %s"
                   task.id task.title assignee dl)
                 ~title:(Printf.sprintf "Timeout: %s" task.title)
                 ~post_kind:Board.System_post
                 ~meta_json:(`Assoc [
                   ("type", `String "verification_timeout");
                   ("task_id", `String task.id);
                   ("verification_id", `String verification_id);
                   ("assignee", `String assignee);
                   ("deadline", `String dl);
                 ])
                 ~visibility:Board.Internal
                 ~hearth:"verification"
                 ()
               with
               | Ok _ -> ()
               | Error e ->
                 Log.Task.error
                   "board post failed (task=%s vrf=%s): %s"
                   task.id verification_id (Board_types.show_board_error e)
             in
             Subscriptions.push_event_to_sessions (`Assoc [
               ("type", `String "masc/verification/timeout");
               ("task_id", `String task.id);
               ("verification_id", `String verification_id);
               ("assignee", `String assignee);
               ("timestamp", `Float now);
             ])
           | Some _ -> ()
           | None -> ())
        | Todo | Claimed _ | InProgress _ | AwaitingVerification { deadline = None; _ } | Done _ | Cancelled _ -> ()
      ) backlog.tasks
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Log.Task.error "verification timeout check failed: %s"
        (Printexc.to_string exn)
