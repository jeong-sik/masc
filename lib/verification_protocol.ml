(** Verification_protocol -- Cross-agent verification workflow orchestration.

    Bridges task FSM transitions (AwaitingVerification state) with:
    - Board system (Direct visibility posts to verifiers)
    - SSE events (masc:verification:requested, :verdict, :rejected)
    - Verification storage (.masc/verifications/)

    @since Phase B+C *)

(* Bridge types_core.evidence_criterion → Verification.criterion.
   Same shape; types are distinct to respect the masc_coord/masc_mcp lib
   boundary. Issue #7548. *)
let evidence_criterion_to_verification_criterion
    : Types.evidence_criterion -> Verification.criterion = function
  | Types.Schema_match j -> Verification.Schema_match j
  | Types.Contains s -> Verification.Contains s
  | Types.Not_contains s -> Verification.Not_contains s
  | Types.Custom s -> Verification.Custom s

(* Fail-closed by types: [~assignee] is passed directly by the caller,
   which already destructures [AwaitingVerification { assignee; _ }]. Removes
   the prior "unknown" fallback that violated Silent Failure 금지. Issue #7547. *)
let on_submit_for_verification ~(config : Coord.config)
    ~(task : Types.task) ~assignee ~verification_id ~evidence_refs =
  let base_path = config.Coord.base_path in
  let criteria =
    match task.contract with
    | Some c -> List.map evidence_criterion_to_verification_criterion c.verify_gate_evidence
    | None -> []
  in
  let _req =
    Verification.create_request ~base_path ~task_id:task.id
      ~output:(`Assoc [
        ("evidence_refs", `List (List.map (fun s -> `String s) evidence_refs));
        ("task_title", `String task.title);
      ])
      ~criteria ~worker:assignee () in
  let meta_json = `Assoc [
    ("type", `String "verification_request");
    ("task_id", `String task.id);
    ("verification_id", `String verification_id);
    ("worker", `String assignee);
    ("evidence_refs", `List (List.map (fun s -> `String s) evidence_refs));
    ("criteria", `List (List.map Verification.criterion_to_yojson criteria));
  ] in
  let _post = Board_dispatch.create_post
    ~author:"system"
    ~content:(Printf.sprintf "Verification requested for task %s (%s) by %s"
      task.id task.title assignee)
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
    ("worker", `String assignee);
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
        | Types.AwaitingVerification { assignee; verification_id; submitted_at } ->
          (* Deadline is derived from contract + submitted_at.
             Issue #7552: deadline no longer inlined on variant. *)
          let deadline_sec = match task.contract with
            | Some { verification_deadline_sec = Some s; _ } -> Some s
            | _ -> None
          in
          (match deadline_sec with
           | Some sec ->
             let submitted_ts = Types.parse_iso8601_opt submitted_at in
             (match submitted_ts with
              | Some ts when now > ts +. float_of_int sec ->
                let dl_iso =
                  let tm = Unix.gmtime (ts +. float_of_int sec) in
                  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
                    (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
                    tm.tm_hour tm.tm_min tm.tm_sec
                in
                let _post = Board_dispatch.create_post
                  ~author:"system"
                  ~content:(Printf.sprintf
                    "Verification timeout: task %s (%s) by %s — no verifier responded within deadline %s"
                    task.id task.title assignee dl_iso)
                  ~title:(Printf.sprintf "Timeout: %s" task.title)
                  ~post_kind:Board.System_post
                  ~meta_json:(`Assoc [
                    ("type", `String "verification_timeout");
                    ("task_id", `String task.id);
                    ("verification_id", `String verification_id);
                    ("assignee", `String assignee);
                    ("deadline", `String dl_iso);
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
           | None -> ())
        | _ -> ()
      ) backlog.tasks
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Log.Task.error "verification timeout check failed: %s"
        (Printexc.to_string exn)
