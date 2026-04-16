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
  ignore config;
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
  ignore config;
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
