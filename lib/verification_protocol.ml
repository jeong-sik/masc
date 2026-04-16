(** Verification_protocol -- Cross-agent verification workflow orchestration.

    Bridges task FSM transitions (AwaitingVerification state) with:
    - Board system (Direct visibility posts to verifiers)
    - SSE events (masc:verification:requested, :verdict, :rejected)
    - Verification storage (.masc/verifications/)

    @since Phase B+C *)

let on_submit_for_verification ~(config : Coord.config)
    ~(task : Types.task) ~verification_id ~evidence_refs =
  let base_path = config.Coord.base_path in
  let criteria = List.map (fun s -> Verification.Custom s)
    (match task.contract with
     | Some c -> c.verify_gate_evidence
     | None -> []) in
  let worker = match task.task_status with
    | AwaitingVerification { assignee; _ } -> assignee
    | _ -> "unknown" in
  let _req =
    Verification.create_request ~base_path ~task_id:task.id
      ~output:(`Assoc [
        ("evidence_refs", `List (List.map (fun s -> `String s) evidence_refs));
        ("task_title", `String task.title);
      ])
      ~criteria ~worker () in
  let meta_json = `Assoc [
    ("type", `String "verification_request");
    ("task_id", `String task.id);
    ("verification_id", `String verification_id);
    ("worker", `String worker);
    ("evidence_refs", `List (List.map (fun s -> `String s) evidence_refs));
    ("criteria", `List (List.map Verification.criterion_to_yojson criteria));
  ] in
  let _post = Board_dispatch.create_post
    ~author:"system"
    ~content:(Printf.sprintf "Verification requested for task %s (%s) by %s"
      task.id task.title worker)
    ~title:(Printf.sprintf "Verify: %s" task.title)
    ~post_kind:Board.System_post
    ~meta_json
    ~visibility:Board.Internal
    ~hearth:"verification"
    () in
  Subscriptions.push_event_to_sessions (`Assoc [
    ("type", `String "masc/verification/requested");
    ("task_id", `String task.id);
    ("verification_id", `String verification_id);
    ("worker", `String worker);
    ("evidence_refs", `List (List.map (fun s -> `String s) evidence_refs));
    ("timestamp", `Float (Time_compat.now ()));
  ]);
  ignore base_path

let on_approve_verification ~(config : Coord.config)
    ~task_id ~verifier ~verification_id ~notes =
  let base_path = config.Coord.base_path in
  (* Update Verification.ml state machine: Pending -> Completed Pass.
     Issue #7544. *)
  (if verification_id <> "" then
    match Verification.submit_verdict ~base_path
            ~req_id:verification_id ~verifier
            ~verdict:Verification.Pass with
    | Ok _ -> ()
    | Error e ->
      Log.Task.error
        "verification submit_verdict failed (task=%s vrf=%s verifier=%s): %s"
        task_id verification_id verifier e);
  let meta_json = `Assoc [
    ("type", `String "verification_verdict");
    ("task_id", `String task_id);
    ("verification_id", `String verification_id);
    ("verdict", `String "approved");
  ] in
  let _post = Board_dispatch.create_post
    ~author:verifier
    ~content:(Printf.sprintf "Approved task %s (vrf:%s)%s"
      task_id verification_id
      (if notes = "" then "" else " — " ^ notes))
    ~post_kind:Board.System_post
    ~meta_json
    ~visibility:Board.Internal
    ~hearth:"verification"
    () in
  Subscriptions.push_event_to_sessions (`Assoc [
    ("type", `String "masc/verification/verdict");
    ("task_id", `String task_id);
    ("verification_id", `String verification_id);
    ("verifier", `String verifier);
    ("verdict", `String "approved");
    ("notes", `String notes);
    ("timestamp", `Float (Time_compat.now ()));
  ])

let on_reject_verification ~(config : Coord.config)
    ~task_id ~verifier ~verification_id ~reason =
  let base_path = config.Coord.base_path in
  (* Update Verification.ml state machine: Pending -> Completed (Fail reason).
     Issue #7544. *)
  (if verification_id <> "" then
    match Verification.submit_verdict ~base_path
            ~req_id:verification_id ~verifier
            ~verdict:(Verification.Fail reason) with
    | Ok _ -> ()
    | Error e ->
      Log.Task.error
        "verification submit_verdict failed (task=%s vrf=%s verifier=%s): %s"
        task_id verification_id verifier e);
  let meta_json = `Assoc [
    ("type", `String "verification_verdict");
    ("task_id", `String task_id);
    ("verification_id", `String verification_id);
    ("verdict", `String "rejected");
  ] in
  let _post = Board_dispatch.create_post
    ~author:verifier
    ~content:(Printf.sprintf "Rejected task %s (vrf:%s): %s"
      task_id verification_id reason)
    ~post_kind:Board.System_post
    ~meta_json
    ~visibility:Board.Internal
    ~hearth:"verification"
    () in
  Subscriptions.push_event_to_sessions (`Assoc [
    ("type", `String "masc/verification/rejected");
    ("task_id", `String task_id);
    ("verification_id", `String verification_id);
    ("verifier", `String verifier);
    ("reason", `String reason);
    ("timestamp", `Float (Time_compat.now ()));
  ])

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
             let _post = Board_dispatch.create_post
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
               () in
             Subscriptions.push_event_to_sessions (`Assoc [
               ("type", `String "masc/verification/timeout");
               ("task_id", `String task.id);
               ("verification_id", `String verification_id);
               ("assignee", `String assignee);
               ("timestamp", `Float now);
             ])
           | _ -> ())
        | _ -> ()
      ) backlog.tasks
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Log.Task.error "verification timeout check failed: %s"
        (Printexc.to_string exn)
