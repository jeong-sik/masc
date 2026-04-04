(** Risk_digest — Structural risk signals for supervisor digest.

    All computations are deterministic structural checks.
    No LLM judge or probabilistic inference. *)

type evidence_gap = {
  required_count : int;
  present_count : int;
  missing : string list;
}

type drift_signal =
  | Cascade_length_change of { original : int; current : int }

type unsafe_edit_signal =
  | Autonomous_execution_scope of string
  | Zero_repair_budget
  | High_risk_class

type t = {
  evidence_gap : evidence_gap;
  drift_risk : drift_signal list;
  unsafe_edit_risk : unsafe_edit_signal list;
  ambiguity : string option;
}

(* --- Evidence gap computation --- *)

let compute_evidence_gap (session : Team_session_types.session) : evidence_gap =
  match session.delivery_contract with
  | None ->
      { required_count = 0; present_count = 0; missing = [] }
  | Some dc ->
      let required = dc.required_artifacts in
      let present = dc.evidence_refs in
      let required_count = List.length required in
      let present_set =
        List.fold_left
          (fun acc ref_str -> List.cons (String.lowercase_ascii ref_str) acc)
          [] present
      in
      let missing =
        List.filter
          (fun artifact ->
            not
              (List.exists
                 (fun ref_str ->
                   String.equal (String.lowercase_ascii artifact) ref_str)
                 present_set))
          required
      in
      let present_count = required_count - List.length missing in
      { required_count; present_count; missing }

(* --- Drift risk computation --- *)

(** Check structural drift signals for the session. *)
let compute_drift_risk (session : Team_session_types.session)
    (_worker_cards : Operator_digest_types.worker_card list) : drift_signal list =
  let signals = ref [] in
  let original_policy_width =
    match Team_session_types.effective_runtime_policy_ref session with
    | Some _ -> 1
    | None -> List.length session.model_cascade
  in
  let planned_count = List.length session.planned_workers in
  if
    original_policy_width > 0
    && planned_count > 0
    && planned_count > original_policy_width
  then
    signals :=
      Cascade_length_change
        { original = original_policy_width; current = planned_count }
      :: !signals;
  List.rev !signals

(* --- Unsafe edit risk computation --- *)

let compute_unsafe_edit_risk (session : Team_session_types.session)
    (worker_cards : Operator_digest_types.worker_card list) : unsafe_edit_signal list =
  let signals = ref [] in
  (* Check repair_budget = 0 *)
  (match session.delivery_contract with
  | Some dc when dc.repair_budget = 0 ->
      signals := Zero_repair_budget :: !signals
  | _ -> ());
  (* Check for high risk_level in worker cards *)
  List.iter
    (fun (card : Operator_digest_types.worker_card) ->
      match card.risk_level with
      | Some level
        when String.equal (String.lowercase_ascii level) "high"
             || String.equal (String.lowercase_ascii level) "critical" ->
          if not (List.mem High_risk_class !signals) then
            signals := High_risk_class :: !signals
      | _ -> ())
    worker_cards;
  (* Check for autonomous execution scope in planned workers instead of tool name heuristic *)
  List.iter
    (fun (pw : Team_session_types.planned_worker) ->
      match pw.execution_scope with
      | Some Team_session_types_enums.Autonomous ->
          signals := Autonomous_execution_scope pw.spawn_agent :: !signals
      | _ -> ())
    session.planned_workers;
  List.rev !signals

(* --- Ambiguity computation --- *)

let compute_ambiguity (session : Team_session_types.session) : string option =
  if
    Option.is_none session.delivery_contract
    && List.length session.planned_workers > 2
  then
    Some
      "Multi-worker session without delivery_contract — acceptance criteria \
       undefined"
  else None

(* --- Main computation --- *)

let compute ~(session : Team_session_types.session)
    ~(worker_cards : Operator_digest_types.worker_card list) : t =
  {
    evidence_gap = compute_evidence_gap session;
    drift_risk = compute_drift_risk session worker_cards;
    unsafe_edit_risk = compute_unsafe_edit_risk session worker_cards;
    ambiguity = compute_ambiguity session;
  }

(* --- JSON serialization --- *)

let evidence_gap_to_yojson (eg : evidence_gap) : Yojson.Safe.t =
  `Assoc
    [
      ("required_count", `Int eg.required_count);
      ("present_count", `Int eg.present_count);
      ("missing", `List (List.map (fun s -> `String s) eg.missing));
      ( "gap_ratio",
        `Float
          (if eg.required_count = 0 then 0.0
           else
             float_of_int (eg.required_count - eg.present_count)
             /. float_of_int eg.required_count) );
    ]

let drift_signal_to_yojson (signal : drift_signal) : Yojson.Safe.t =
  match signal with
  | Cascade_length_change { original; current } ->
      `Assoc
        [
          ("type", `String "cascade_length_change");
          ("original", `Int original);
          ("current", `Int current);
        ]

let unsafe_edit_signal_to_yojson (signal : unsafe_edit_signal) : Yojson.Safe.t =
  match signal with
  | Autonomous_execution_scope worker_name ->
      `Assoc
        [
          ("type", `String "autonomous_execution_scope");
          ("worker_name", `String worker_name);
          (* Legacy alias for older consumers that still key off tool_name. *)
          ("tool_name", `String worker_name);
        ]
  | Zero_repair_budget ->
      `Assoc [ ("type", `String "zero_repair_budget") ]
  | High_risk_class ->
      `Assoc [ ("type", `String "high_risk_class") ]

let to_yojson (t : t) : Yojson.Safe.t =
  `Assoc
    [
      ("evidence_gap", evidence_gap_to_yojson t.evidence_gap);
      ("drift_risk", `List (List.map drift_signal_to_yojson t.drift_risk));
      ( "unsafe_edit_risk",
        `List (List.map unsafe_edit_signal_to_yojson t.unsafe_edit_risk) );
      ( "ambiguity",
        match t.ambiguity with
        | Some msg -> `String msg
        | None -> `Null );
      ("signal_count",
        `Int
          (List.length t.drift_risk
           + List.length t.unsafe_edit_risk
           + (if t.evidence_gap.missing <> [] then 1 else 0)
           + (if Option.is_some t.ambiguity then 1 else 0)));
    ]
