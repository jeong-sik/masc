type runtime_snapshot = {
  judge_online : bool;
  refreshing : bool;
  status : string;
  degraded_reason : string option;
  cached_judgments_visible : bool;
  generated_at : string option;
  generated_at_unix : float option;
  expires_at : string option;
  expires_at_unix : float option;
  model_used : string option;
  keeper_name : string;
  last_error : string option;
  compute_in_flight : int;
  last_compute_duration_sec : float option;
  last_compute_timeout_sec : float option;
  last_compute_outcome : string option;
  last_compute_reason : string option;
}

(** State of the in-flight compute cycle.

    The previous [int] counter was a workaround: a single integer could
    be over-decremented by a fired-too-late [Eio.Switch.on_release]
    callback (or under-decremented when the callback never fired under
    parent-fiber cancellation), and a [max 0] clamp had to ride
    alongside to mask the underflow. PR #20479 attempted to replace the
    clamp with [Eio.Switch.on_release] as the single source of truth,
    but [on_release] is *not* a total correctness primitive under
    parent-fibre cancellation in Eio 5.x — a parent switch failing
    before child release callbacks run leaves the counter stuck at 1.
    That is the failure mode observed in the fleet logs between
    2026-06-08 07:00-08:48Z (57× [in_flight_after=1] stuck events).

    The fix replaces the int counter with a typed state machine
    ([compute_in_flight_state]) and derives the in-flight read from
    that state under [with_lock]. [mark_compute_start] advances
    [cycle_id] monotonically; a second [mark_compute_start] before
    [mark_compute_finish] is a routine log + replace (not a panic),
    preserving the typed invariant that the previous int counter could
    not hold. *)
type compute_in_flight_state =
  | Idle
  | In_flight of { started_at : float; cycle_id : int }


type state = {
  mutex : Eio.Mutex.t;
  mutable started : bool;
  mutable refreshing : bool;
  mutable judge_online : bool;
  mutable runtime_status : string;
  mutable degraded_reason : string option;
  mutable generated_at_unix : float option;
  mutable expires_at_unix : float option;
  mutable generated_at : string option;
  mutable expires_at : string option;
  mutable model_used : string option;
  mutable last_error : string option;
  mutable compute_state : compute_in_flight_state;
  mutable next_cycle_id : int;
  mutable last_compute_duration_sec : float option;
  mutable last_compute_timeout_sec : float option;
  mutable last_compute_outcome : string option;
  mutable last_compute_reason : string option;
  mutable next_compute_after_unix : float option;
  mutable last_disk_load_unix : float option;
  mutable judgments : (string, Yojson.Safe.t) Hashtbl.t;
}

(* #9880 facet 4: per-cycle counter for empty [response.model] in
   governance compute_judgments.  Mirrors the keeper-side
   [masc_after_turn_response_model_empty_total] introduced by
   #10083; separate metric name keeps governance vs keeper
   attribution clean while sharing the [unknown_provider]
   marker string so metric queries can union-aggregate across both. *)
let governance_response_model_empty_metric =
  "masc_governance_response_model_empty_total"

let governance_compute_total_metric =
  "masc_governance_judge_compute_total"

let governance_compute_duration_metric =
  "masc_governance_judge_compute_duration_seconds"

let governance_compute_in_flight_metric =
  "masc_governance_judge_compute_in_flight"

let () =
  Otel_metric_store.register_counter
    ~name:governance_response_model_empty_metric
    ~help:
      "Count of governance compute_judgments cycles where \
       [response.model] was empty.  Labels: \
       [source=telemetry_resolved | unknown_source]."
    ();
  Otel_metric_store.register_counter
    ~name:governance_compute_total_metric
    ~help:
      "Count of governance judge compute_judgments attempts. Labels: \
       [outcome=ok|error, reason=ok|timeout|error|cancelled]."
    ();
  Otel_metric_store.register_histogram
    ~name:governance_compute_duration_metric
    ~help:
      "Observed governance judge compute_judgments duration in seconds. \
       Labels: [outcome=ok|error, reason=ok|timeout|error|cancelled]."
    ();
  Otel_metric_store.register_gauge
    ~name:governance_compute_in_flight_metric
    ~help:"Current in-flight governance judge compute_judgments attempts."
    ()

type governance_model_source =
  | Response_model
  | Telemetry_resolved
  | Unknown_source

let governance_model_source_to_string = function
  | Response_model -> "response_model"
  | Telemetry_resolved -> "telemetry_resolved"
  | Unknown_source -> "unknown_source"

let resolve_governance_model_used ~raw_model ~canonical_model_id =
  if String.trim raw_model <> "" then "runtime", Response_model
  else
    match canonical_model_id with
    | Some id ->
        let trimmed = String.trim id in
        if trimmed <> "" then "runtime", Telemetry_resolved
        else "runtime", Unknown_source
    | None -> "runtime", Unknown_source

let governance_dir base_path =
  Filename.concat
    (Workspace_utils.masc_dir_from_base_path ~base_path)
    "governance"

(** Legacy single-file path (for fallback reads). *)
let judgments_path base_path =
  Filename.concat (governance_dir base_path) "judgments.jsonl"

(** Date-split store: [.masc/governance/judgments/YYYY-MM/DD.jsonl].
    Cached per base_dir so all callers share the same Eio.Mutex. *)
let judgments_store_cache : (string, Dated_jsonl.t) Hashtbl.t = Hashtbl.create 4
let states : (string, state) Hashtbl.t = Hashtbl.create 4

(** Mutex for outer [states] and [judgments_store_cache] Hashtbls.
    Inner per-state mutex protects per-keeper operations. *)
let outer_mu = Eio.Mutex.create ()
let with_outer_rw f = Eio_guard.with_mutex outer_mu f

let get_judgments_store base_path : Dated_jsonl.t =
  with_outer_rw (fun () ->
    let dir = Filename.concat (governance_dir base_path) "judgments" in
    match Hashtbl.find_opt judgments_store_cache dir with
    | Some store -> store
    | None ->
      let store = Dated_jsonl.create ~base_dir:dir () in
      Hashtbl.replace judgments_store_cache dir store;
      store)

let with_lock (st : state) f =
  Eio.Mutex.use_rw ~protect:true st.mutex f


let interval_sec () = Env_config.Dashboard_config.governance_judge_interval_sec

let cache_ttl_sec () =
  float_of_int (max (interval_sec () * 4) 600)

let timeout_failure_backoff_sec () =
  let interval = float_of_int (interval_sec ()) in
  Float.min 300.0 (Float.max 60.0 (interval *. 5.0))

let empty_judgment_reload_cooldown_sec = 30.0

let enabled () = Env_config.Dashboard_config.governance_judge_enabled

let keeper_name = "governance-judge"
let backoff_status = "Backoff: local slots saturated"

let status_online = "online"
let status_refreshing = "refreshing"
let status_stale_visible = "stale_visible"
let status_offline = "offline"
let status_backoff = "backoff"


let degraded_reason_of_error message =
  let lower = String.lowercase_ascii message in
  if
    String_util.contains_substring lower "unparseable"
    || String_util.contains_substring lower "structurally invalid"
    || String_util.contains_substring lower "invalid json"
    || String_util.contains_substring lower "guardrail_state"
  then
    "judge_output_invalid"
  else if
    String_util.contains_substring lower "timeout"
    || String_util.contains_substring lower "timed out"
    || String_util.contains_substring lower "deadline"
  then
    "timeout"
  else
    "error"

let cached_judgments_still_fresh ~now_ts (st : state) =
  match st.expires_at_unix with
  | Some expires_at -> expires_at > now_ts
  | None -> false

let cached_result_still_fresh ~now_ts (st : state) =
  cached_judgments_still_fresh ~now_ts st
  && (Option.is_some st.generated_at
      || Option.is_some st.generated_at_unix
      || Option.is_some st.model_used)

let mark_fresh_cache_served (st : state) =
  st.refreshing <- false;
  st.judge_online <- true;
  if st.runtime_status <> status_stale_visible then begin
    st.runtime_status <- status_online;
    st.degraded_reason <- None;
    st.last_error <- None;
    st.next_compute_after_unix <- None
  end

let mark_refresh_failure ~now_ts (st : state) ~message =
  st.refreshing <- false;
  (* Preserve the last good snapshot while its TTL is still valid. A slow
     or timing-out judge should degrade to stale-but-visible rather than
     immediately flipping the dashboard offline. *)
  let cache_fresh = cached_judgments_still_fresh ~now_ts st in
  let degraded_reason = degraded_reason_of_error message in
  st.judge_online <- cache_fresh;
  st.runtime_status <-
    (if cache_fresh then status_stale_visible else status_offline);
  st.degraded_reason <- Some degraded_reason;
  st.last_error <- Some message;
  st.next_compute_after_unix <-
    (if String.equal degraded_reason "timeout"
     then Some (now_ts +. timeout_failure_backoff_sec ())
     else None)

let timeout_backoff_remaining_sec ~now_ts (st : state) =
  match st.next_compute_after_unix with
  | Some next when next > now_ts -> Some (next -. now_ts)
  | Some _ ->
    st.next_compute_after_unix <- None;
    None
  | None ->
    None

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
            runtime_status = status_offline;
            degraded_reason = None;
            generated_at_unix = None;
            expires_at_unix = None;
            generated_at = None;
            expires_at = None;
            model_used = None;
            last_error = None;
            compute_state = Idle;
            next_cycle_id = 0;
            last_compute_duration_sec = None;
            last_compute_timeout_sec = None;
            last_compute_outcome = None;
            last_compute_reason = None;
            next_compute_after_unix = None;
            last_disk_load_unix = None;
          judgments = Hashtbl.create 32;
        }
      in
      Hashtbl.add states base_path st;
      st)

let key_of kind id = kind ^ ":" ^ id

let judgment_key json =
  let kind = Json_util.get_string_with_default json ~key:"target_kind" ~default:"" in
  let id = Json_util.get_string_with_default json ~key:"target_id" ~default:"" in
  key_of kind id

let judgment_generated_at json =
  Json_util.get_string json "generated_at" |> Dashboard_utils.parse_iso_opt
  |> Option.value ~default:0.0

let normalize_disk_recommended_action judgment =
  match Json_util.assoc_member_opt "recommended_action" judgment with
  | Some (`Assoc action_fields) ->
      let canonical_tool =
        match List.assoc_opt "resolved_tool" action_fields with
        | Some (`String tool) ->
            let tool = tool |> String.trim |> String.lowercase_ascii in
            if tool = "" then None else Some tool
        | _ -> None
      in
      let normalized_action =
        `Assoc
          (List.map
             (fun (key, value) ->
               if String.equal key "resolved_tool" then
                 ("resolved_tool", Json_util.option_to_yojson (fun item -> `String item) canonical_tool)
               else
                 (key, value))
             action_fields)
      in
      (match judgment with
       | `Assoc fields ->
           `Assoc
             (List.map
                (fun (key, value) ->
                  if String.equal key "recommended_action" then
                    ("recommended_action", normalized_action)
                  else
                    (key, value))
                fields)
       | other -> other)
  | _ -> judgment

let load_judgments_into_table jsons =
  let table = Hashtbl.create 32 in
  List.iter (fun json ->
    try
      let status = Json_util.get_string json "status" in
      if status = Some "active" then
        let key = judgment_key json in
        match Hashtbl.find_opt table key with
        | Some current
          when judgment_generated_at current >= judgment_generated_at json -> ()
        | _ -> Hashtbl.replace table key json
    with
    | Yojson.Safe.Util.Type_error _ -> ()
    | exn -> Log.Governance.warn "load_latest_from_disk parse: %s" (Printexc.to_string exn)
  ) jsons;
  table

(** Load latest judgments.
    Tries date-split store first; falls back to legacy single file. *)
let load_latest_from_disk base_path =
  let store = get_judgments_store base_path in
  let jsons = Dated_jsonl.read_recent store 10_000 in
  if jsons <> [] then
    load_judgments_into_table jsons
  else
    (* Legacy fallback *)
    let path = judgments_path base_path in
    if not (Sys.file_exists path) then Hashtbl.create 32
    else
      let content = Fs_compat.load_file path in
      let legacy_jsons =
        String.split_on_char '\n' content
        |> List.filter (fun line -> String.trim line <> "")
        |> List.filter_map (fun line ->
            try Some (Yojson.Safe.from_string line)
            with Yojson.Json_error _ -> None)
      in
      load_judgments_into_table legacy_jsons

let latest_judgments base_path =
  let st = get_state base_path in
  with_lock st (fun () ->
      if Hashtbl.length st.judgments = 0 then begin
        let should_reload =
          match st.last_disk_load_unix with
          | None -> true
          | Some last_load ->
              Unix.gettimeofday () -. last_load >= empty_judgment_reload_cooldown_sec
        in
        if should_reload then begin
          st.judgments <- load_latest_from_disk base_path;
          st.last_disk_load_unix <- Some (Unix.gettimeofday ())
        end
      end;
      Hashtbl.to_seq_values st.judgments |> List.of_seq)

let fresh_judgments_json ~base_path ~limit =
  let now = Unix.gettimeofday () in
  latest_judgments base_path
  |> List.map normalize_disk_recommended_action
  |> List.filter (fun j ->
    match Json_util.get_string j "expires_at" with
    | Some iso ->
      (match Dashboard_utils.parse_iso_opt (Some iso) with
       | Some ts -> ts > now
       | None -> true)
    | None -> true)
  |> List.sort (fun a b ->
    Float.compare (judgment_generated_at b) (judgment_generated_at a))
  |> List.filteri (fun i _ -> i < limit)

(** Read the in-flight count derived from [compute_state].

    The state machine in {!compute_in_flight_state} is the source of
    truth: {!mark_compute_start} is the only site that transitions
    [Idle] → [In_flight] (setting the gauge to 1.0) and
    {!mark_compute_finish} is the only site that transitions
    [In_flight] → [Idle] (setting the gauge to 0.0).  No probe of
    [Eio.Switch] lifecycle is required — the cycle body's outcome
    path (success / error / cancelled / exception) reaches
    [mark_compute_finish] deterministically, so the read path is a
    pure projection of [compute_state] onto [int].  PR #20479's
    [Eio.Switch.on_release] callback is no longer required (and was
    not total under parent-fibre cancellation, which is why 57×
    [in_flight_after=1] events still appeared in the 2026-06-08 fleet
    log after the PR merge).  The state machine replaces both the
    [max 0 (... - 1)] clamp and the [Eio.Switch.on_release]
    fire-and-forget bookkeeping: a transition is a typed
    {!compute_in_flight_state} assignment, so the compiler enforces
    that every site in the cycle body's outcome path lands on a
    state that [read_in_flight] can project to the correct count. *)
let read_in_flight (st : state) : int =
  with_lock st (fun () ->
      match st.compute_state with
      | Idle -> 0
      | In_flight _ -> 1)

let runtime_status_at ~now_ts base_path =
  let st = get_state base_path in
  with_lock st (fun () ->
      let cache_fresh = cached_judgments_still_fresh ~now_ts st in
      let status =
        if st.refreshing then status_refreshing
        else
          match st.runtime_status with
          | value when value = status_online && cache_fresh -> status_online
          | value when value = status_stale_visible && cache_fresh ->
              status_stale_visible
          | value when value = status_backoff -> status_backoff
          | _ when st.judge_online && cache_fresh -> status_online
          | _ -> status_offline
      in
      let judge_online =
        match status with
        | value when value = status_online || value = status_stale_visible -> true
        | value when value = status_refreshing -> st.judge_online && cache_fresh
        | _ -> false
      in
      let degraded_reason =
        match status with
        | value when value = status_backoff -> Some "backoff"
        | value when value = status_stale_visible || value = status_offline ->
            (match st.degraded_reason, st.last_error with
             | Some reason, _ -> Some reason
             | None, Some message -> Some (degraded_reason_of_error message)
             | None, None -> None)
        | _ -> None
      in
      {
        judge_online;
        refreshing = st.refreshing;
        status;
        degraded_reason;
        cached_judgments_visible =
          cache_fresh
          && (status = status_stale_visible || status = status_backoff);
        generated_at = st.generated_at;
        generated_at_unix = st.generated_at_unix;
        expires_at = st.expires_at;
        expires_at_unix = st.expires_at_unix;
        model_used = None;
        keeper_name;
        last_error = st.last_error;
        compute_in_flight = (match st.compute_state with Idle -> 0 | In_flight _ -> 1);
        last_compute_duration_sec = st.last_compute_duration_sec;
        last_compute_timeout_sec = st.last_compute_timeout_sec;
        last_compute_outcome = st.last_compute_outcome;
        last_compute_reason = st.last_compute_reason;
      })

let runtime_status base_path =
  runtime_status_at ~now_ts:(Unix.gettimeofday ()) base_path

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

let normalize_text = Dashboard_http_helpers.normalize_text

let normalize_allowed_tool_name value =
  value |> String.trim |> String.lowercase_ascii

let allowed_tool tool =
  List.mem (normalize_allowed_tool_name tool)
    [
      (* RFC-0182: masc_execute / masc_execute_dry_run removed (dead). *)
      "masc_operator_action";
      "masc_operator_confirm";
      "masc_operator_snapshot";
      "masc_surface_audit";
    ]

let parse_recommended_action json =
  let m key src = Option.value ~default:`Null (Json_util.assoc_member_opt key src) in
  match Json_util.assoc_member_opt "recommended_action" json with
  | Some (`Assoc _ as action_json) ->
      let resolved_tool =
        Json_util.get_string action_json "resolved_tool"
        |> Option.map normalize_allowed_tool_name
      in
      let resolved_tool =
        match resolved_tool with
        | Some tool when tool <> "" && allowed_tool tool -> Some tool
        | _ -> None
      in
      Some
        (`Assoc
          [
            ("action_kind", m "action_kind" action_json);
            ("resolved_tool", Json_util.option_to_yojson (fun value -> `String value) resolved_tool);
            ("target_type", m "target_type" action_json);
            ("target_id", m "target_id" action_json);
            ( "reason",
              `String
                (normalize_text
                   (Json_util.get_string_with_default action_json ~key:"reason" ~default:"")) );
            ("payload_preview", m "payload_preview" action_json);
          ])
  | _ -> None

type governance_response_parse_failure =
  | Lenient_fallback of string
  | Structural_error of string

let parse_lenient_governance_json raw_text =
  let parsed = Llm_provider.Lenient_json.parse raw_text in
  match parsed with
  | `Assoc [("raw", `String raw)] -> (
      match Judge_json_recovery.extract_balanced_object raw with
      | Some block -> (
          try
            match Llm_provider.Lenient_json.parse block with
            | `Assoc [ ("raw", `String recovered_raw) ] ->
                Error (Lenient_fallback recovered_raw)
            | parsed -> Ok parsed
          with
          | Yojson.Json_error _ -> Error (Lenient_fallback raw)
          | Failure _ -> Error (Lenient_fallback raw))
      | None -> Error (Lenient_fallback raw))
  | _ -> Ok parsed

let parse_required_guardrail_state json =
  match Json_util.assoc_member_opt "guardrail_state" json with
  | Some (`Assoc fields) ->
      let required_field name =
        match List.assoc_opt name fields with
        | Some value -> Ok value
        | None -> Error (Printf.sprintf "missing guardrail_state.%s" name)
      in
      let requires_human_gate = required_field "requires_human_gate" in
      let pending_confirm_token = required_field "pending_confirm_token" in
      let ready_to_execute = required_field "ready_to_execute" in
      (match requires_human_gate, pending_confirm_token, ready_to_execute with
       | Ok (`Bool _ as requires_human_gate),
         Ok ((`String _ | `Null) as pending_confirm_token),
         Ok (`Bool _ as ready_to_execute) ->
           Ok
             (`Assoc
               [
                 ("requires_human_gate", requires_human_gate);
                 ("pending_confirm_token", pending_confirm_token);
                 ("ready_to_execute", ready_to_execute);
               ])
       | Error reason, _, _ | _, Error reason, _ | _, _, Error reason ->
           Error reason
       | _ ->
           Error
             "invalid guardrail_state: expected requires_human_gate bool, \
              pending_confirm_token string|null, ready_to_execute bool")
  | None | Some `Null -> Error "missing guardrail_state"
  | _ -> Error "invalid guardrail_state: expected object"

let parse_item_judgment ~generated_at ~expires_at ~model_used:_ json =
  let target_kind =
    Json_util.get_string_with_default json ~key:"kind" ~default:""
    |> String.lowercase_ascii
  in
  let target_id = Json_util.get_string_with_default json ~key:"id" ~default:"" in
  if target_kind = "" || target_id = "" then Ok None
  else
    let summary =
      normalize_text (Json_util.get_string_with_default json ~key:"summary" ~default:"")
    in
    if summary = "" then Ok None
    else
      let confidence =
        Json_util.get_float json "confidence"
        |> Option.value ~default:0.0
        |> fun v -> max 0.0 (min 1.0 v)
      in
      let evidence_refs = parse_string_list json "evidence_refs" in
      let recommended_action = parse_recommended_action json in
      match parse_required_guardrail_state json with
      | Error reason ->
          Error
            (Printf.sprintf "item %s:%s %s" target_kind target_id reason)
      | Ok guardrail_state ->
          Ok
            (Some
               (`Assoc
                 [
                   ( "judgment_id",
                     `String
                       (Uuidm.to_string
                          (Uuidm.v4_gen (Random.State.make_self_init ()) ())) );
                   ("target_kind", `String target_kind);
                   ("target_id", `String target_id);
                   ("status", `String "active");
                   ("summary", `String summary);
                   ("confidence", `Float confidence);
                   ("generated_at", `String generated_at);
                   ("expires_at", `String expires_at);
                   ("model_used", `Null);
                   ("keeper_name", `String keeper_name);
                   ( "evidence_refs",
                     `List (List.map (fun item -> `String item) evidence_refs) );
                   ( "recommended_action",
                     Json_util.option_to_yojson (fun value -> value) recommended_action );
                   ("guardrail_state", guardrail_state);
                 ]))

let parse_governance_response ~raw_text ~generated_at ~expires_at ~model_used =
  match parse_lenient_governance_json raw_text with
  | Error _ as error -> error
  | Ok parsed -> (
      match parsed with
      | `Assoc _ -> (
          match Json_util.assoc_member_opt "items" parsed with
          | Some (`List rows) ->
              let rec loop acc = function
                | [] -> Ok (List.rev acc)
                | row :: rest -> (
                    match
                      parse_item_judgment ~generated_at ~expires_at ~model_used row
                    with
                    | Error reason -> Error (Structural_error reason)
                    | Ok None -> loop acc rest
                    | Ok (Some judgment) -> loop (judgment :: acc) rest)
              in
              loop [] rows
          | _ ->
              Error
                (Structural_error
                   "expected top-level items array in judge response"))
      | _ ->
          Error
            (Structural_error
               "expected top-level JSON object in judge response"))

let parse_governance_response_for_testing =
  parse_governance_response

let prompt_for_facts facts_json =
  match
    Prompt_registry.render_prompt_template "dashboard.governance_judge"
      [ ("facts_json", Yojson.Safe.to_string facts_json) ]
  with
  | Ok value -> value
  | Error _ -> Prompt_registry.get_prompt "dashboard.governance_judge"

let compute_judgments
    ~(masc_tools : Masc_domain.tool_schema list)
    ~(dispatch : name:string -> args:Yojson.Safe.t -> Tool_result.result)
    ~base_path
    ~build_facts =
  let runtime_id =
    Runtime.get_default_runtime_id ()
  in
  match
    (* build_facts() is moved inside the bridge so a deadlock in
       get_agents_status is bounded by the resolved timeout rather
       than hanging the daemon fiber indefinitely (#8319).
       #9629: caller uses run_with_caller so this judge resolves its
       budget through Env_config_oas_bridge
       and surfaces in the per-caller Otel_metric_store counter. *)
    Masc_oas_bridge.run_with_caller
      ~caller:Env_config_oas_bridge.Governance_judge (fun () ->
      let factual_json = build_facts () in
      let prompt = prompt_for_facts factual_json in
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
        let raw_text = Agent_sdk_response.text_of_response response in
        let generated_at = Masc_domain.now_iso () in
        let expires_at = Masc_domain.iso8601_of_unix_seconds (Unix.gettimeofday () +. cache_ttl_sec ()) in
        (* #9880: keep the internal fallback/counter for empty OAS model
           metadata, but do not project concrete model names into MASC-owned
           dashboard or judgment JSON. *)
        let canonical_model_id =
          match response.telemetry with
          | Some { canonical_model_id = Some id; _ } -> Some id
          | _ -> None
        in
        let resolved_model, model_source =
          resolve_governance_model_used ~raw_model:response.model
            ~canonical_model_id
        in
        begin
          match model_source with
          | Response_model -> ()
          | Telemetry_resolved | Unknown_source ->
              let source = governance_model_source_to_string model_source in
              Otel_metric_store.inc_counter
                governance_response_model_empty_metric
                ~labels:[ ("source", source) ]
                ();
              Log.Governance.warn
                "compute_judgments: response.model empty -> fallback=%s (#9880)"
                source;
        end;
        match
          parse_governance_response ~raw_text ~generated_at ~expires_at
            ~model_used:resolved_model
        with
        | Ok judgments -> Ok (resolved_model, generated_at, expires_at, judgments)
        | Error (Lenient_fallback raw) ->
            let msg =
              Judge_diagnostics.record_lenient_fallback
                ~judge_label:"Governance" raw
            in
            Log.Governance.warn "%s" msg;
            Error msg
        | Error (Structural_error reason) ->
            let msg =
              Judge_diagnostics.record_unparseable_response
                ~judge_label:"Governance" ~reason raw_text
            in
            Log.Governance.warn "%s" msg;
            Error msg
      with
      | Yojson.Json_error msg ->
          Error (Printf.sprintf "Governance judge returned invalid JSON: %s" msg)
      | exn ->
          Error (Printf.sprintf "Governance judge parse error: %s" (Printexc.to_string exn)))

(** Append judgments to date-split store.
    Thread-safe via Dated_jsonl internal mutex. *)
let append_judgments base_path judgments =
  let store = get_judgments_store base_path in
  List.iter (fun json -> Dated_jsonl.append store json) judgments

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

(* Record a new in-flight cycle.

   The state-machine invariant: this is the *only* site that
   transitions [compute_state] to [In_flight _] (and sets the gauge
   to 1.0).  [mark_compute_finish] is the *only* site that
   transitions back to [Idle] (and sets the gauge to 0.0).  No
   [Eio.Switch.on_release] callback is registered — the previous
   design (PR #20479) relied on [Eio.Switch.on_release] to fire on
   every cycle exit, but the 2026-06-08 fleet log shows 57× cycles
   with [reason=exception duration=0.000s in_flight_after=1], which
   is the signature of a cycle body that raises synchronously before
   the on_release callback can fire (the parent switch stays alive
   waiting for child fibers, so the [on_release] handler is delayed
   past the cycle's [mark_compute_finish] log emission and the
   counter never recovers to 0).

   The previous [Idle → In_flight → In_flight] case (concurrent
   start) is reduced to a routine log + force-overwrite: the new
   cycle replaces the old one.  In production, [refresh_once] is
   driven by a single sequential loop, so concurrent starts are
   impossible; this branch exists to give a paper trail in the
   anomaly case.

   The ~sw argument is removed: the state machine no longer tracks
   the switch identity (Eio 1.3 does not expose a public
   is-closed probe, and we do not need one — see {!read_in_flight}). *)
let mark_compute_start (st : state) : int =
  with_lock st (fun () ->
      let cycle_id = st.next_cycle_id in
      st.next_cycle_id <- st.next_cycle_id + 1;
      (match st.compute_state with
       | Idle -> ()
       | In_flight { cycle_id = prev_id; _ } ->
           Log.Governance.routine
             "mark_compute_start: previous cycle_id=%d still live; replacing with cycle_id=%d"
             prev_id cycle_id);
      st.compute_state <- In_flight { started_at = Unix.gettimeofday (); cycle_id };
      Otel_metric_store.set_gauge governance_compute_in_flight_metric 1.0;
      cycle_id)

(* docs/spec/18-log-severity-taxonomy.md § 3.6 (outcome-carrying line at a
   static level): the compute-finish line embeds a runtime [outcome=%s], so its
   severity must be derived from that outcome rather than hardcoded [Info] — an
   errored compute logged at [Info] hides under the noise floor with no
   companion WARN/ERROR. A genuine "error" outcome is degraded-with-auto-recovery
   (the next [refresh_once] retries) → [Warn]. A graceful cancellation
   (reason="cancelled", e.g. shutdown / superseded refresh) is not
   operator-actionable → [Info]. Success → [Info]. *)
let level_of_compute_outcome ~outcome ~reason : Log.level =
  match outcome with
  | "error" when reason <> "cancelled" -> Log.Warn
  | _ -> Log.Info

(** Reset in-flight state and emit telemetry.

    The [compute_state] transition to [Idle] is the *only* state
    mutation this function performs. The decrement that PR #20479
    delegated to an [Eio.Switch.on_release] callback now lives
    entirely in this function as an explicit state-machine
    transition. The [Eio.Switch.on_release] callback is **not**
    used here: Eio 1.3 does not expose a public is-closed probe,
    and fire-and-forget callbacks are not a total correctness
    primitive under parent cancellation — see
    [lib/core/eio_guard.ml:60-67] for the project's existing
    acknowledgement of that limitation. The state machine
    ([mark_compute_start] / [mark_compute_finish]) is the
    only writer, and a [Cancelled] re-raise that bypasses the
    user-site handler still drops the in-flight count back to
    its pre-start value, but now via an explicit reset at
    outcome time rather than a callback whose firing is not
    guaranteed.

    The [last_compute_duration_sec] / [last_compute_outcome] /
    [last_compute_reason] fields are *last observed*, not
    *current* — they are read by the runtime snapshot and
    represent the most recent terminal cycle, regardless of
    whether a new cycle has since started. *)
let mark_compute_finish (st : state) ~cycle_id ~started_at ~outcome ~reason =
  (* Clamp the elapsed time to >= 0 so a backwards system clock
     adjustment (NTP step, manual change) cannot inject a negative
     duration into the histogram or the [last_compute_duration_sec]
     dashboard surface. *)
  let duration_sec = Float.max 0.0 (Unix.gettimeofday () -. started_at) in
  let labels = [ ("outcome", outcome); ("reason", reason) ] in
  let in_flight =
    with_lock st (fun () ->
        st.last_compute_duration_sec <- Some duration_sec;
        st.last_compute_outcome <- Some outcome;
        st.last_compute_reason <- Some reason;
        (* Reset compute_state to Idle. The switch held by the cycle
           may already be closed (parent cancellation) or still
           open (we are the cycle finishing first); either way, the
           cycle is done. *)
        (match st.compute_state with
         | Idle ->
             (* mark_compute_finish called without a matching start.
                Defensive log; not an error because the user-site
                exception path can re-raise after partial teardown. *)
             Log.Governance.routine
               "mark_compute_finish: state already Idle (cycle ended by external path)"
         | In_flight { cycle_id = current_cid; _ } ->
             if current_cid = cycle_id then st.compute_state <- Idle
             else
               Log.Governance.routine
                 "mark_compute_finish: stale finish cycle_id=%d ignored (current=%d)"
                 cycle_id current_cid);
        Otel_metric_store.set_gauge governance_compute_in_flight_metric 0.0;
        0)
  in
  Otel_metric_store.inc_counter governance_compute_total_metric ~labels ();
  Otel_metric_store.observe_histogram governance_compute_duration_metric
    ~labels duration_sec;
  (* Single emission at the outcome-derived level (never two lines).
     [compute_timeout] is no longer reported by this daemon layer; the
     OAS bridge owns the per-caller structural timeout inside the
     wrapped computation. *)
  Log.Governance.emit
    (level_of_compute_outcome ~outcome ~reason)
    (Printf.sprintf
       "refresh_once: compute_judgments telemetry outcome=%s reason=%s duration=%.3fs in_flight_after=%d"
       outcome reason duration_sec in_flight);
  (duration_sec, in_flight)

let refresh_once ~sw ~net
    ~(masc_tools : Masc_domain.tool_schema list)
    ~(dispatch : name:string -> args:Yojson.Safe.t -> Tool_result.result)
    ~base_path ~build_facts =
  let st = get_state base_path in
  (* Cycle-start log so an operator can confirm the daemon fiber is alive.
     Previously every branch was silent in steady state — a hung daemon was
     indistinguishable from a healthy one producing zero events (#8319). *)
  Log.Governance.routine "refresh_once: cycle start";
  ignore (latest_judgments base_path);
  let served_from_cache =
    let now_ts = Unix.gettimeofday () in
    with_lock st (fun () ->
        if cached_result_still_fresh ~now_ts st then begin
          mark_fresh_cache_served st;
          true
        end else
          false)
  in
  if served_from_cache then
    Log.Governance.routine "refresh_once: fresh cached result; skipping compute"
  else (
    let timeout_backoff_remaining =
      let now_ts = Unix.gettimeofday () in
      with_lock st (fun () ->
          st.refreshing <- false;
          timeout_backoff_remaining_sec ~now_ts st)
    in
    match timeout_backoff_remaining with
    | Some remaining_sec ->
      Log.Governance.routine
        "refresh_once: timeout backoff active; skipping compute for %.0fs"
        remaining_sec
    | None ->
      if should_backoff ~sw ~net
      then begin
    let was_online =
      with_lock st (fun () ->
          let was_online = st.judge_online in
          st.refreshing <- false;
          st.judge_online <- false;
          st.runtime_status <- status_backoff;
          st.degraded_reason <- Some "backoff";
          st.last_error <- Some backoff_status;
          was_online)
    in
    if was_online then
      Log.Governance.info "backoff: local slots saturated, skipping cycle"
    else
        Log.Governance.routine "backoff: local slots saturated (first cycle)"
      end
      else begin
    with_lock st (fun () ->
        st.refreshing <- true;
        st.runtime_status <- status_refreshing;
        st.degraded_reason <- None);
    let started_at = Unix.gettimeofday () in
    (* The in-flight invariant is *not* maintained by an
       [Eio.Switch.on_release] callback — PR #20479's approach,
       which is not total under parent-fibre cancellation — but by
       an explicit typed state-machine transition:

         Idle  --[mark_compute_start]-->  In_flight
         In_flight  --[mark_compute_finish]-->  Idle

       [mark_compute_start] runs first inside the [Eio.Switch.run]
       scope so the in-flight gauge is published *before* any
       provider work begins.  [mark_compute_finish] is called in
       every terminal branch of the cycle (success, error,
       cancelled) to publish the Idle transition.  The typed
       variant makes the illegal state ("In_flight but no running
       cycle") unrepresentable at the type level, removing the need
       for a runtime "is the Switch still alive?" probe (Eio 1.3
       does not export such a probe in its public API anyway).

       The OAS bridge owns the governance/operator judge wall-clock
       budget via [Env_config_oas_bridge], so this daemon layer keeps
       only the typed in-flight invariant and does not add a second
       cycle wrapper. *)
    let cycle_id = mark_compute_start st in
    let compute_result =
      try
        Eio.Switch.run ~name:"governance_judge.compute" (fun _sw ->
            try
              Ok
                (compute_judgments ~masc_tools ~dispatch ~base_path ~build_facts)
            with
            | Eio.Cancel.Cancelled _ as exn ->
                ignore
                  (mark_compute_finish st ~cycle_id ~started_at ~outcome:"error"
                     ~reason:"cancelled");
                raise exn
            | exn ->
                ignore
                  (mark_compute_finish st ~cycle_id ~started_at ~outcome:"error"
                     ~reason:"exception");
                Error
                  (Printf.sprintf "compute_judgments raised: %s"
                     (Printexc.to_string exn)))
      with exn ->
        (* Switch.run itself raised during cleanup (e.g. child-fibre exception
           propagated after callback returned, or parent cancellation before
           callback ran).  mark_compute_finish is idempotent on Idle — safe to
           call even if the inner handler already cleared the state. *)
        ignore
          (mark_compute_finish st ~cycle_id ~started_at ~outcome:"error"
             ~reason:"exception");
        raise exn
    in
    match compute_result with
    | Ok (Ok (model_used, generated_at, expires_at, judgments)) ->
        ignore
          (mark_compute_finish st ~cycle_id ~started_at ~outcome:"ok" ~reason:"ok");
        if judgments = [] then
          Log.Governance.routine
            "refresh_once: ok runtime=redacted judgments=%d"
            0
        else
          Log.Governance.info
            "refresh_once: ok runtime=redacted judgments=%d"
            (List.length judgments);
        append_judgments base_path judgments;
        with_lock st (fun () ->
            st.refreshing <- false;
            st.judge_online <- true;
            st.runtime_status <- status_online;
            st.degraded_reason <- None;
            st.generated_at <- Some generated_at;
            st.generated_at_unix <- Some (Masc_domain.parse_iso8601 generated_at);
            st.expires_at <- Some expires_at;
            st.expires_at_unix <- Some (Masc_domain.parse_iso8601 expires_at);
            st.model_used <- Some model_used;
            st.last_error <- None;
            st.next_compute_after_unix <- None;
            st.last_disk_load_unix <- Some (Unix.gettimeofday ());
            List.iter
              (fun json -> Hashtbl.replace st.judgments (judgment_key json) json)
              judgments)
    | Ok (Error message) | Error message ->
        let reason = degraded_reason_of_error message in
        let duration_sec, in_flight =
          mark_compute_finish st ~cycle_id ~started_at ~outcome:"error" ~reason
        in
        Log.Governance.warn
          "refresh_once: compute_judgments failed: %s (duration=%.3fs in_flight=%d)"
          message duration_sec in_flight;
        with_lock st (fun () ->
            mark_refresh_failure ~now_ts:(Unix.gettimeofday ()) st ~message)
      end)

let start ~sw ~clock ~net ~base_path
    ~(masc_tools : Masc_domain.tool_schema list)
    ~(dispatch : name:string -> args:Yojson.Safe.t -> Tool_result.result)
    ~build_facts () =
  (* Ensure governance directories exist before first read/write *)
  Fs_compat.mkdir_p (governance_dir base_path);
  Fs_compat.mkdir_p (Filename.concat (governance_dir base_path) "judgments");
  let st = get_state base_path in
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
          refresh_once ~sw ~net ~masc_tools ~dispatch ~base_path ~build_facts;
          if was_backoff then Atomic.incr consecutive_backoffs
          else Atomic.set consecutive_backoffs 0;
          let base = float_of_int (interval_sec ()) in
          let n = Atomic.get consecutive_backoffs in
          let sleep_s =
            if n = 0 then base
            else min (base *. Float.pow 2.0 (float_of_int (min n 5))) 300.0
          in
          if n > 0 then
            Log.Governance.routine "backoff: sleeping %.0fs (consecutive=%d)" sleep_s n;
          Eio.Time.sleep clock sleep_s;
          loop ()
        in
        loop ())
