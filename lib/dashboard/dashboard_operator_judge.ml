type runtime_snapshot = {
  enabled : bool;
  judge_online : bool;
  refreshing : bool;
  generated_at : string option;
  expires_at : string option;
  model_used : string option;
  keeper_name : string;
  last_error : string option;
}

let record_operator_judgment_ref =
  ref (fun _config ~surface:_ ~target_type_str:_ ~target_id:_ ~summary:_ ~confidence:_
           ?model_name:_ ?recommended_action:_ ~evidence_refs:_ ~disagreement_with_truth:_
           ~generated_at:_ ~generated_at_unix:_ ~fresh_until:_ ~fresh_until_unix:_
           ~keeper_name:_ () ->
    ())

let register_record_operator_judgment fn =
  record_operator_judgment_ref := fn

type state = {
  mutex : Eio.Mutex.t;
  mutable started : bool;
  mutable refreshing : bool;
  mutable judge_online : bool;
  mutable generated_at : string option;
  mutable expires_at : string option;
  mutable model_used : string option;
  mutable last_error : string option;
}

let keeper_name = "operator-judge"
let backoff_status = "Backoff: local slots saturated"

let states : (string, state) Hashtbl.t = Hashtbl.create 4

(** Mutex for outer [states] Hashtbl. Inner per-state mutex for per-keeper ops. *)
let outer_mu = Eio.Mutex.create ()
let with_outer_rw f = Eio_guard.with_mutex outer_mu f

let with_lock st f =
  Eio.Mutex.use_rw ~protect:true st.mutex f

let member_action_type = "action_type"
let member_severity = "severity"
let member_reason = "reason"
let member_suggested_payload = "suggested_payload"
let member_summary = "summary"
let member_confidence = "confidence"
let member_recommended_action = "recommended_action"
let member_disagreement_with_truth = "disagreement_with_truth"
let key_action_type = "action_type"
let key_target_type = "target_type"
let key_target_id = "target_id"
let key_actor = "actor"
let key_severity = "severity"
let key_reason = "reason"
let key_payload = "payload"
let key_suggested_payload = "suggested_payload"
let key_preview = "preview"
let key_provenance = "provenance"
let key_authoritative = "authoritative"
let key_confirm_required = "confirm_required"
let key_raw = "raw"
let keeper_name_operator_judge = "operator-judge"
let backoff_status_slots_saturated = "Backoff: local slots saturated"
let severity_warn = "warn"
let provenance_judgment = "judgment"
let judge_label_operator = "Operator"
let model_used_runtime = "runtime"
let prompt_dashboard_operator_judge = "dashboard.operator_judge"
let field_facts_json = "facts_json"


let get_state base_path =
  with_outer_rw (fun () ->
    match Hashtbl.find_opt states base_path with
    | Some st -> st
    | None ->
        let st =
          {
            mutex = Eio.Mutex.create ();
            started = false;
            refreshing = false;
            judge_online = false;
            generated_at = None;
            expires_at = None;
            model_used = None;
            last_error = None;
          }
        in
        Hashtbl.add states base_path st;
        st)

let enabled () = Env_config.Operator.judge_enabled

let interval_sec () = Env_config.Operator.judge_interval_sec

let workspace_ttl_sec () = Env_config.Operator.workspace_ttl_sec

let session_ttl_sec () = Env_config.Operator.session_ttl_sec

let runtime_status base_path =
  let st = get_state base_path in
  with_lock st (fun () ->
      {
        enabled = enabled ();
        judge_online = st.judge_online;
        refreshing = st.refreshing;
        generated_at = st.generated_at;
        expires_at = st.expires_at;
        model_used = None;
        keeper_name;
        last_error = st.last_error;
      })

let normalize_text = Dashboard_http_helpers.normalize_text

let parse_string_list json key =
  match Json_util.assoc_member_opt key json with
  | Some (`List items) ->
      items
      |> List.filter_map (function
             | `String value ->
                 let trimmed = String.trim value in
                 if trimmed = "" then None else Some trimmed
             | _ -> None)
  | _ -> []

let allowed_action_type = Operator_approval.is_allowed

let confirm_required = Operator_approval.confirm_required

let build_recommended_action ~actor ~target_type ~target_id json =
  match json with
  | `Assoc _ ->
      let action_type =
        Json_util.get_string json member_action_type |> Option.map String.trim
      in
      (match action_type with
      | Some action_type when action_type <> "" && allowed_action_type action_type ->
          let severity =
            Json_util.get_string_with_default json ~key:member_severity ~default:severity_warn
          in
          let reason =
            normalize_text
              (Json_util.get_string_with_default json ~key:member_reason ~default:"")
          in
          let suggested_payload =
            match Json_util.assoc_member_opt member_suggested_payload json with
            | Some (`Assoc _ as value) -> value
            | _ -> `Assoc []
          in
          let preview =
            `Assoc
              [
                (key_actor, `String actor);
                (key_action_type, `String action_type);
                (key_target_type, `String target_type);
                (key_target_id, Option.fold ~none:`Null ~some:(fun v -> `String v) target_id);
                (key_payload, suggested_payload);
              ]
          in
          Some
            (`Assoc
              [
                (key_action_type, `String action_type);
                (key_target_type, `String target_type);
                (key_target_id, Option.fold ~none:`Null ~some:(fun v -> `String v) target_id);
                (key_severity, `String severity);
                (key_reason, `String reason);
                (key_confirm_required, `Bool (confirm_required action_type));
                (key_suggested_payload, suggested_payload);
                (key_preview, preview);
                (key_provenance, `String provenance_judgment);
                (key_authoritative, `Bool true);
              ])
      | _ -> None)
  | _ -> None

let prompt_for_facts facts_json =
  match
    Prompt_registry.render_prompt_template prompt_dashboard_operator_judge
      [ (field_facts_json, Yojson.Safe.to_string facts_json) ]
  with
  | Ok value -> value
  | Error _ -> Prompt_registry.get_prompt prompt_dashboard_operator_judge

let parse_workspace_judgment ~config ~generated_at ~generated_at_unix ~model_used:_ json =
  match json with
  | `Assoc _ ->
      let summary =
        normalize_text
          (Json_util.get_string_with_default json ~key:member_summary ~default:"")
      in
      if summary = "" then None
      else
        let confidence =
          Json_util.get_float json member_confidence
          |> Option.value ~default:0.0
        in
        let fresh_until_unix =
          generated_at_unix +. float_of_int (workspace_ttl_sec ())
        in
        (!record_operator_judgment_ref) config ~surface:"command.namespace"
             ~target_type_str:"workspace" ~target_id:None ~summary
             ~confidence ?model_name:None
             ?recommended_action:
               (build_recommended_action ~actor:keeper_name ~target_type:"workspace"
                  ~target_id:None (Option.value ~default:`Null (Json_util.assoc_member_opt member_recommended_action json)))
             ~evidence_refs:(parse_string_list json "evidence_refs")
             ~disagreement_with_truth:
               (Json_util.get_bool json member_disagreement_with_truth
               |> Option.value ~default:false)
             ~generated_at ~generated_at_unix
             ~fresh_until:(Masc_domain.iso8601_of_unix_seconds fresh_until_unix)
             ~fresh_until_unix ~keeper_name ();
        Some ()
  | _ -> None

let compute_judgments
    ~(masc_tools : Masc_domain.tool_schema list)
    ~(dispatch : name:string -> args:Yojson.Safe.t -> Tool_result.result)
    ~base_path
    ~facts_json =
  let prompt = prompt_for_facts facts_json in
  let runtime_id =
    Runtime.get_default_runtime_id ()
  in
  match
    (* #9629: caller uses run_with_caller so this judge inherits
       Operator_judge's per-caller default and surfaces in the
       Otel_metric_store counter. *)
    Masc_oas_bridge.run_with_caller
      ~caller:Env_config_oas_bridge.Operator_judge (fun () ->
      Keeper_turn_driver_wrappers.run_named_with_masc_tools ~runtime_id
        ~base_path ~goal:prompt ~masc_tools ~dispatch
        ~accept:Keeper_tool_response.response_has_text_or_tool_progress
        ~approval:Approval_callbacks.auto_approve
        ()
    )
  with
  | Error err -> Error (Agent_sdk.Error.to_string err)
  | Ok result -> (
      let response = result.Runtime_agent.response in
      try
        (* See dashboard_governance_judge.ml for rationale: LLMs frequently
           wrap JSON in ```json … ``` markdown fences. Lenient_json strips
           fences and applies other deterministic recovery transforms. *)
        let raw_text = Agent_sdk_response.text_of_response response in
        match Llm_provider.Lenient_json.parse raw_text with
        | `Assoc [(key_raw, `String raw)] ->
            (* #9774: include a preview so the failure diagnostic doesn't
               require enabling raw provider logging. *)
            let msg =
              Judge_diagnostics.record_lenient_fallback ~judge_label:judge_label_operator raw
            in
            Log.Governance.warn "%s" msg;
            Error msg
        | parsed ->
            let _ = response.model in
            Ok (model_used_runtime, parsed)
      with
      | Yojson.Json_error msg ->
          Error (Printf.sprintf "Operator judge returned invalid JSON: %s" msg)
      | exn ->
          Error (Printf.sprintf "Operator judge parse error: %s" (Printexc.to_string exn)))

let should_backoff ~sw:_ ~net:_ =
  (* RFC-0206 single-binding: the deleted
     [Runtime_runtime.local_capacity_for_selections] probed local-runtime
     endpoint queues live. Under single-binding the runtime pool tracks lease
     saturation directly, so back off when every configured concurrency slot on
     a healthy runtime is already leased.
     NB: this reads MASC's own lease accounting ([allocated_slots]), not the
     server-reported queue depth ([process_available]) the old probe used — a
     documented semantic shift, not a removal. Restoring a true live server-queue
     probe is RFC-shaped follow-up. *)
  let configured = Local_runtime_pool.configured_capacity () in
  configured > 0
  && Local_runtime_pool.healthy_runtime_count () > 0
  && Local_runtime_pool.allocated_slots () >= configured

let refresh_once ~sw ~net
    ~(masc_tools : Masc_domain.tool_schema list)
    ~(dispatch : name:string -> args:Yojson.Safe.t -> Tool_result.result)
    ~(config : Workspace.config) ~build_facts =
  let st = get_state config.base_path in
  if should_backoff ~sw ~net then
    let was_online =
      with_lock st (fun () ->
          let was_online = st.judge_online in
          st.refreshing <- false;
          st.judge_online <- false;
          st.last_error <- Some backoff_status;
          was_online)
    in
    if was_online then
      Log.Dashboard.info "operator: backoff: local slots saturated, skipping cycle"
  else begin
    with_lock st (fun () -> st.refreshing <- true);
    match compute_judgments ~masc_tools ~dispatch ~base_path:config.base_path
            ~facts_json:(build_facts ()) with
    | Error message ->
        with_lock st (fun () ->
            st.refreshing <- false;
            st.judge_online <- false;
            st.last_error <- Some message)
    | Ok (model_used, result_json) ->
        let generated_at_unix = Unix.gettimeofday () in
        let generated_at = Masc_domain.iso8601_of_unix_seconds generated_at_unix in
        let expires_at =
          Masc_domain.iso8601_of_unix_seconds (generated_at_unix +. float_of_int (workspace_ttl_sec ()))
        in
        let workspace_judgment =
          parse_workspace_judgment ~config ~generated_at ~generated_at_unix
            ~model_used result_json
        in
        let has_any = Option.is_some workspace_judgment in
        with_lock st (fun () ->
            st.refreshing <- false;
            st.judge_online <- has_any;
            st.generated_at <- Some generated_at;
            st.expires_at <- Some expires_at;
            st.model_used <- Some model_used;
            st.last_error <- None)
  end

let start ~sw ~clock ~net ~(config : Workspace.config)
    ~(masc_tools : Masc_domain.tool_schema list)
    ~(dispatch : name:string -> args:Yojson.Safe.t -> Tool_result.result)
    ~build_facts () =
  let st = get_state config.base_path in
  let should_start =
    with_lock st (fun () ->
        if st.started || not (enabled ()) then false
        else (
          st.started <- true;
          true))
  in
  if should_start then
    Eio.Fiber.fork_daemon ~sw (fun () ->
        let consecutive_backoffs = Atomic.make 0 in
        let rec loop () =
          let was_backoff = should_backoff ~sw ~net in
          refresh_once ~sw ~net ~masc_tools ~dispatch ~config ~build_facts;
          if was_backoff then Atomic.incr consecutive_backoffs
          else Atomic.set consecutive_backoffs 0;
          let base = float_of_int (interval_sec ()) in
          let n = Atomic.get consecutive_backoffs in
          let sleep_s =
            if n = 0 then base
            else min (base *. Float.pow 2.0 (float_of_int (min n 5))) 300.0
          in
          if n > 0 then
            Log.Dashboard.debug "operator: backoff: sleeping %.0fs (consecutive=%d)" sleep_s n;
          Eio.Time.sleep clock sleep_s;
          loop ()
        in
        loop ())
