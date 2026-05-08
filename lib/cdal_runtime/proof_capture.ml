type trace_entry =
  { ts : float
  ; tool_name : string
  ; input : Yojson.Safe.t
  ; tool_use_id : string
  ; planned_index : int
  ; batch_index : int
  ; batch_size : int
  ; concurrency_class : string
  ; output : string option
  ; error : string option
  ; duration_ms : int option
  }

type pending_tool =
  { start_ts : float
  ; tool_use_id : string
  ; tool_name : string
  ; input : Yojson.Safe.t
  ; planned_index : int
  ; batch_index : int
  ; batch_size : int
  ; concurrency_class : string
  }

type state =
  { run_id : string
  ; store : Proof_store.config
  ; contract : Risk_contract.t
  ; mode_decision : Mode_resolver.decision
  ; capability_snapshot : Cdal_proof.capability_snapshot
  ; scope : string option
  ; mutable started_at : float
  ; mutable ended_at : float
  ; mutable provider_snapshot : Cdal_proof.provider_snapshot
  ; mutable pending_tool : pending_tool option
  ; mutable trace_count : int
  ; mutable enforcer : Mode_enforcer.state option
  }

let generate_run_id () =
  let now = Unix.gettimeofday () in
  let rand = Random.bits () land 0xFFFFFF in
  Printf.sprintf "cdal-%d-%06x" (int_of_float (now *. 1000.0)) rand
;;

let create ~store ~contract ~mode_decision ~capability_snapshot ?scope () =
  let run_id = generate_run_id () in
  Proof_store.init_run store ~run_id;
  { run_id
  ; store
  ; contract
  ; mode_decision
  ; capability_snapshot
  ; scope
  ; started_at = 0.0
  ; ended_at = 0.0
  ; provider_snapshot =
      { provider_name = "unknown"; model_id = "unknown"; api_version = None }
  ; pending_tool = None
  ; trace_count = 0
  ; enforcer = None
  }
;;

let run_id st = st.run_id
let set_enforcer st e = st.enforcer <- Some e

let flush_trace st entry =
  st.trace_count <- st.trace_count + 1;
  let trace_id = Printf.sprintf "trace-%04d" st.trace_count in
  let json =
    `Assoc
      [ "ts", `Float entry.ts
      ; "tool_use_id", `String entry.tool_use_id
      ; "tool_name", `String entry.tool_name
      ; "input", entry.input
      ; "planned_index", `Int entry.planned_index
      ; "batch_index", `Int entry.batch_index
      ; "batch_size", `Int entry.batch_size
      ; "concurrency_class", `String entry.concurrency_class
      ; ( "output"
        , match entry.output with
          | Some s -> `String s
          | None -> `Null )
      ; ( "error"
        , match entry.error with
          | Some s -> `String s
          | None -> `Null )
      ; ( "duration_ms"
        , match entry.duration_ms with
          | Some d -> `Int d
          | None -> `Null )
      ]
  in
  Proof_store.append_tool_trace st.store ~run_id:st.run_id ~trace_id json
;;

let complete_pending_tool st ~output ~error =
  match st.pending_tool with
  | None -> ()
  | Some pending ->
    let now = Unix.gettimeofday () in
    let duration_ms = int_of_float ((now -. pending.start_ts) *. 1000.0) in
    flush_trace
      st
      { ts = pending.start_ts
      ; tool_use_id = pending.tool_use_id
      ; tool_name = pending.tool_name
      ; input = pending.input
      ; planned_index = pending.planned_index
      ; batch_index = pending.batch_index
      ; batch_size = pending.batch_size
      ; concurrency_class = pending.concurrency_class
      ; output
      ; error
      ; duration_ms = Some duration_ms
      };
    st.pending_tool <- None
;;

let hooks st =
  let open Hooks in
  { before_turn =
      Some
        (fun event ->
          (match event with
           | BeforeTurn { turn = 1; _ } -> st.started_at <- Unix.gettimeofday ()
           | BeforeTurn _ -> ()
           | _ -> ());
          Continue)
  ; before_turn_params = None
  ; after_turn =
      Some
        (fun event ->
          (match event with
           | AfterTurn { response; _ } ->
             st.provider_snapshot
             <- { provider_name =
                    (match st.provider_snapshot.provider_name with
                     | "unknown" -> "detected"
                     | p -> p)
                ; model_id = response.Types.model
                ; api_version = None
                }
           | _ -> ());
          Continue)
  ; pre_tool_use =
      Some
        (fun event ->
          (match event with
           | PreToolUse { tool_use_id; tool_name; input; schedule; _ } ->
             complete_pending_tool st ~output:None ~error:None;
             st.pending_tool
             <- Some
                  { start_ts = Unix.gettimeofday ()
                  ; tool_use_id
                  ; tool_name
                  ; input
                  ; planned_index = schedule.planned_index
                  ; batch_index = schedule.batch_index
                  ; batch_size = schedule.batch_size
                  ; concurrency_class = schedule.concurrency_class
                  }
           | _ -> ());
          Continue)
  ; post_tool_use =
      Some
        (fun event ->
          (match event with
           | PostToolUse { output; _ } ->
             let output_str, error_str =
               match output with
               | Ok { Types.content; _ } -> Some content, None
               | Error { Types.message; _ } -> None, Some message
             in
             complete_pending_tool st ~output:output_str ~error:error_str
           | _ -> ());
          Continue)
  ; post_tool_use_failure =
      Some
        (fun event ->
          (match event with
           | PostToolUseFailure { error; _ } ->
             complete_pending_tool st ~output:None ~error:(Some error)
           | _ -> ());
          Continue)
  ; on_stop =
      Some
        (fun event ->
          (match event with
           | OnStop _ -> st.ended_at <- Unix.gettimeofday ()
           | _ -> ());
          Continue)
  ; on_idle = None
  ; on_idle_escalated = None
  ; on_error =
      Some
        (fun event ->
          (match event with
           | OnError _ -> st.ended_at <- Unix.gettimeofday ()
           | _ -> ());
          Continue)
  ; on_tool_error = None
  ; pre_compact = None
  ; post_compact = None
  ; on_context_compacted = None
  }
;;

let collect_evidence_refs st =
  match st.enforcer with
  | None -> []
  | Some enforcer ->
    let refs = ref [] in
    let effects = Mode_enforcer.effect_evidence enforcer in
    if effects <> []
    then (
      let json = `List (List.map Effect_evidence.to_json effects) in
      Proof_store.write_evidence st.store ~run_id:st.run_id ~ref_id:"effects" json;
      refs
      := Proof_store.make_ref ~run_id:st.run_id ~subpath:"evidence/effects.json" :: !refs);
    let violations = Mode_enforcer.violations enforcer in
    if violations <> []
    then (
      let json = `List (List.map Mode_enforcer.violation_to_yojson violations) in
      Proof_store.write_evidence st.store ~run_id:st.run_id ~ref_id:"mode_violations" json;
      refs
      := Proof_store.make_ref ~run_id:st.run_id ~subpath:"evidence/mode_violations.json"
         :: !refs);
    let snapshots = Mode_enforcer.token_snapshots enforcer in
    if snapshots <> []
    then (
      let json =
        `List
          (List.map
             (fun (s : Mode_enforcer.token_snapshot) ->
                `Assoc
                  [ "turn", `Int s.turn
                  ; "input_tokens", `Int s.input_tokens
                  ; "output_tokens", `Int s.output_tokens
                  ; ( "cost_usd"
                    , match s.cost_usd with
                      | Some c -> `Float c
                      | None -> `Null )
                  ])
             snapshots)
      in
      Proof_store.write_evidence st.store ~run_id:st.run_id ~ref_id:"token_usage" json;
      refs
      := Proof_store.make_ref ~run_id:st.run_id ~subpath:"evidence/token_usage.json"
         :: !refs);
    (match Mode_enforcer.review_warning enforcer with
     | Some warning ->
       let json =
         `Assoc
           [ "warning", `String warning
           ; "effective_mode", Execution_mode.to_yojson st.mode_decision.effective_mode
           ]
       in
       Proof_store.write_evidence st.store ~run_id:st.run_id ~ref_id:"review_warning" json;
       refs
       := Proof_store.make_ref ~run_id:st.run_id ~subpath:"evidence/review_warning.json"
          :: !refs
     | None -> ());
    List.rev !refs
;;

let finalize st ~result_status =
  complete_pending_tool st ~output:None ~error:None;
  let now = Unix.gettimeofday () in
  if st.started_at = 0.0 then st.started_at <- now;
  if st.ended_at = 0.0 then st.ended_at <- now;
  let tool_trace_refs =
    List.init st.trace_count (fun i ->
      Proof_store.make_ref
        ~run_id:st.run_id
        ~subpath:(Printf.sprintf "tool_traces/trace-%04d.jsonl" (i + 1)))
  in
  let proof : Cdal_proof.t =
    { schema_version = Cdal_proof.schema_version_current
    ; run_id = st.run_id
    ; contract_id = Risk_contract.contract_id st.contract
    ; requested_execution_mode = st.contract.runtime_constraints.requested_execution_mode
    ; effective_execution_mode = st.mode_decision.effective_mode
    ; mode_decision_source = st.mode_decision.source
    ; risk_class = st.contract.runtime_constraints.risk_class
    ; provider_snapshot = st.provider_snapshot
    ; capability_snapshot = st.capability_snapshot
    ; tool_trace_refs
    ; raw_evidence_refs = collect_evidence_refs st
    ; checkpoint_ref = None
    ; result_status
    ; started_at = st.started_at
    ; ended_at = st.ended_at
    ; scope = st.scope
    }
  in
  Proof_store.write_manifest st.store ~run_id:st.run_id proof;
  Proof_store.write_contract st.store ~run_id:st.run_id st.contract;
  proof
;;
