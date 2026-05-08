open Yojson.Safe.Util

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
  mutable compute_in_flight : int;
  mutable last_compute_duration_sec : float option;
  mutable last_compute_timeout_sec : float option;
  mutable last_compute_outcome : string option;
  mutable last_compute_reason : string option;
  mutable last_disk_load_unix : float option;
  mutable judgments : (string, Yojson.Safe.t) Hashtbl.t;
}

(* #9880 facet 4: per-cycle counter for empty [response.model] in
   governance compute_judgments.  Mirrors the keeper-side
   [masc_after_turn_response_model_empty_total] introduced by
   #10083; separate metric name keeps governance vs keeper
   attribution clean while sharing the [unknown_provider]
   sentinel string so PromQL can union-aggregate across both. *)
let governance_response_model_empty_metric =
  "masc_governance_response_model_empty_total"

let governance_compute_total_metric =
  "masc_governance_judge_compute_total"

let governance_compute_duration_metric =
  "masc_governance_judge_compute_duration_seconds"

let governance_compute_in_flight_metric =
  "masc_governance_judge_compute_in_flight"

let () =
  Prometheus.register_counter
    ~name:governance_response_model_empty_metric
    ~help:
      "Count of governance compute_judgments cycles where \
       [response.model] was empty.  Labels: \
       [source=telemetry_resolved | unknown_sentinel]."
    ();
  Prometheus.register_counter
    ~name:governance_compute_total_metric
    ~help:
      "Count of governance judge compute_judgments attempts. Labels: \
       [outcome=ok|error, reason=ok|timeout|error|cancelled]."
    ();
  Prometheus.register_histogram
    ~name:governance_compute_duration_metric
    ~help:
      "Observed governance judge compute_judgments duration in seconds. \
       Labels: [outcome=ok|error, reason=ok|timeout|error|cancelled]."
    ();
  Prometheus.register_gauge
    ~name:governance_compute_in_flight_metric
    ~help:"Current in-flight governance judge compute_judgments attempts."
    ()

type governance_model_source =
  | Response_model
  | Telemetry_resolved
  | Unknown_sentinel

let governance_model_source_to_string = function
  | Response_model -> "response_model"
  | Telemetry_resolved -> "telemetry_resolved"
  | Unknown_sentinel -> "unknown_sentinel"

let resolve_governance_model_used ~raw_model ~canonical_model_id =
  if String.trim raw_model <> "" then raw_model, Response_model
  else
    match canonical_model_id with
    | Some id ->
        let trimmed = String.trim id in
        if trimmed <> "" then trimmed, Telemetry_resolved
        else "unknown_provider", Unknown_sentinel
    | None -> "unknown_provider", Unknown_sentinel

let governance_dir base_path =
  Filename.concat
    (Coord_utils.masc_dir_from_base_path ~base_path)
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

let ensure_dir path =
  Fs_compat.mkdir_p path

let iso_of_unix = Dashboard_utils.iso_of_unix
let parse_iso_opt = Dashboard_utils.parse_iso_opt

let now_iso () = Masc_domain.now_iso ()
let option_to_yojson = Json_util.option_to_yojson

let interval_sec () = Env_config.Dashboard_config.governance_judge_interval_sec

let cache_ttl_sec () =
  float_of_int (max (interval_sec () * 4) 600)

let empty_judgment_reload_cooldown_sec = 30.0

let enabled () = Env_config.Dashboard_config.governance_judge_enabled

let keeper_name = "governance-judge"
let backoff_status = "Backoff: local slots saturated"

let status_online = "online"
let status_refreshing = "refreshing"
let status_stale_visible = "stale_visible"
let status_offline = "offline"
let status_backoff = "backoff"

let contains_substring haystack needle =
  String_util.contains_substring haystack needle

let degraded_reason_of_error message =
  let lower = String.lowercase_ascii message in
  if
    contains_substring lower "unparseable"
    || contains_substring lower "structurally invalid"
    || contains_substring lower "invalid json"
    || contains_substring lower "guardrail_state"
  then
    "judge_output_invalid"
  else if
    contains_substring lower "timeout"
    || contains_substring lower "timed out"
    || contains_substring lower "deadline"
  then
    "timeout"
  else
    "error"

let timeout_sec_of_error message =
  let marker = "timed out after " in
  let lower = String.lowercase_ascii message in
  match String_util.find_substring lower marker with
  | None -> None
  | Some marker_idx ->
      let start = marker_idx + String.length marker in
      let len = String.length lower in
      let rec find_stop idx =
        if idx >= len then idx
        else
          match lower.[idx] with
          | '0' .. '9' | '.' -> find_stop (idx + 1)
          | _ -> idx
      in
      let stop = find_stop start in
      if stop <= start then None
      else
        String.sub lower start (stop - start)
        |> float_of_string_opt

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
    st.last_error <- None
  end

let mark_refresh_failure ~now_ts (st : state) ~message =
  st.refreshing <- false;
  (* Preserve the last good snapshot while its TTL is still valid. A slow
     or timing-out judge should degrade to stale-but-visible rather than
     immediately flipping the dashboard offline. *)
  let cache_fresh = cached_judgments_still_fresh ~now_ts st in
  st.judge_online <- cache_fresh;
  st.runtime_status <-
    (if cache_fresh then status_stale_visible else status_offline);
  st.degraded_reason <- Some (degraded_reason_of_error message);
  st.last_error <- Some message

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
            compute_in_flight = 0;
            last_compute_duration_sec = None;
            last_compute_timeout_sec = None;
            last_compute_outcome = None;
            last_compute_reason = None;
            last_disk_load_unix = None;
          judgments = Hashtbl.create 32;
        }
      in
      Hashtbl.add states base_path st;
      st)

let key_of kind id = kind ^ ":" ^ id

let judgment_key json =
  let kind = json |> member "target_kind" |> to_string in
  let id = json |> member "target_id" |> to_string in
  key_of kind id

let judgment_generated_at json =
  json |> member "generated_at" |> to_string_option |> parse_iso_opt
  |> Option.value ~default:0.0

let normalize_disk_recommended_action judgment =
  match judgment |> member "recommended_action" with
  | `Assoc action_fields ->
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
                 ("resolved_tool", option_to_yojson (fun item -> `String item) canonical_tool)
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
      let status = json |> member "status" |> to_string_option in
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
    match j |> member "expires_at" |> to_string_option with
    | Some iso ->
      (match Dashboard_utils.parse_iso_opt (Some iso) with
       | Some ts -> ts > now
       | None -> true)
    | None -> true)
  |> List.sort (fun a b ->
    Float.compare (judgment_generated_at b) (judgment_generated_at a))
  |> List.filteri (fun i _ -> i < limit)

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
        model_used = st.model_used;
        keeper_name;
        last_error = st.last_error;
        compute_in_flight = st.compute_in_flight;
        last_compute_duration_sec = st.last_compute_duration_sec;
        last_compute_timeout_sec = st.last_compute_timeout_sec;
        last_compute_outcome = st.last_compute_outcome;
        last_compute_reason = st.last_compute_reason;
      })

let runtime_status base_path =
  runtime_status_at ~now_ts:(Unix.gettimeofday ()) base_path

let parse_string_list json key =
  match json |> member key with
  | `List items ->
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
      "masc_governance_status";
      "masc_execution_orders";
      "masc_execute_dry_run";
      "masc_execute";
      "masc_operator_confirm";
    ]

let parse_recommended_action json =
  let action_json = json |> member "recommended_action" in
  match action_json with
  | `Assoc _ ->
      let resolved_tool =
        action_json |> member "resolved_tool" |> to_string_option
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
            ("action_kind", action_json |> member "action_kind");
            ("resolved_tool", option_to_yojson (fun value -> `String value) resolved_tool);
            ("target_type", action_json |> member "target_type");
            ("target_id", action_json |> member "target_id");
            ( "reason",
              `String
                (normalize_text
                   (action_json |> member "reason" |> to_string_option
                  |> Option.value ~default:"")) );
            ("payload_preview", action_json |> member "payload_preview");
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
  match json |> member "guardrail_state" with
  | `Assoc fields ->
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
  | `Null -> Error "missing guardrail_state"
  | _ -> Error "invalid guardrail_state: expected object"

let parse_item_judgment ~generated_at ~expires_at ~model_used json =
  let target_kind =
    json |> member "kind" |> to_string_option |> Option.value ~default:""
    |> String.lowercase_ascii
  in
  let target_id = json |> member "id" |> to_string_option |> Option.value ~default:"" in
  if target_kind = "" || target_id = "" then Ok None
  else
    let summary =
      normalize_text (json |> member "summary" |> to_string_option |> Option.value ~default:"")
    in
    if summary = "" then Ok None
    else
      let confidence =
        match json |> member "confidence" with
        | `Float value -> max 0.0 (min 1.0 value)
        | `Int value -> max 0.0 (min 1.0 (float_of_int value))
        | _ -> 0.0
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
                   ("model_used", `String model_used);
                   ("keeper_name", `String keeper_name);
                   ( "evidence_refs",
                     `List (List.map (fun item -> `String item) evidence_refs) );
                   ( "recommended_action",
                     option_to_yojson (fun value -> value) recommended_action );
                   ("guardrail_state", guardrail_state);
                 ]))

let parse_governance_response ~raw_text ~generated_at ~expires_at ~model_used =
  match parse_lenient_governance_json raw_text with
  | Error _ as error -> error
  | Ok parsed -> (
      match parsed with
      | `Assoc _ -> (
          match parsed |> member "items" with
          | `List rows ->
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
    ~(dispatch : name:string -> args:Yojson.Safe.t -> Tool_result.t)
    ~build_facts =
  let cascade_name =
    Keeper_cascade_profile.cascade_name_for_use
      Keeper_cascade_profile.Governance_judge
  in
  match
    (* build_facts() is moved inside the bridge so a deadlock in
       get_agents_status is bounded by the resolved timeout rather
       than hanging the daemon fiber indefinitely (#8319).
       #9629: caller migrated from legacy run_safe to run_with_caller
       so this judge resolves its budget through Env_config_oas_bridge
       and surfaces in the per-caller Prometheus counter. *)
    Masc_oas_bridge.run_with_caller
      ~caller:Env_config_oas_bridge.Governance_judge (fun () ->
      let factual_json = build_facts () in
      let prompt = prompt_for_facts factual_json in
      Oas_worker.run_named_with_masc_tools ~cascade_name
        ~goal:prompt ~masc_tools ~dispatch ~max_turns:3
        ~approval:Approval_callbacks.auto_approve
        ()
    )
  with
  | Error err -> Error (Agent_sdk.Error.to_string err)
  | Ok result -> (
      let response = result.Oas_worker.response in
      try
        let raw_text = Agent_sdk_response.text_of_response response in
        let generated_at = now_iso () in
        let expires_at = iso_of_unix (Unix.gettimeofday () +. cache_ttl_sec ()) in
        (* #9880 facet 4: 17% of yesterday's judgment records had
           [model_used = ""] because OAS transports occasionally
           return [response.model = ""] (Kimi/Codex CLI silent
           failure path; CompletionContractViolation
           retry-exhausted synthetic responses).  An empty
           [model_used] field destroys attribution downstream
           (cost rollups, per-model latency p50/p99, daily
           judgments-by-model breakdown).

           Same shape as keeper-side fix #10083: layered
           fallback (raw → telemetry canonical_model_id → named
           sentinel) plus a counter so the operator can see WHICH
           transport leaked.  Sentinel matches the keeper-side
           string [unknown_provider] so dashboards can
           union-aggregate empty-model events across both callers. *)
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
          | Telemetry_resolved | Unknown_sentinel ->
              let source = governance_model_source_to_string model_source in
              Prometheus.inc_counter
                governance_response_model_empty_metric
                ~labels:[ ("source", source) ]
                ();
              Log.Governance.warn
                "compute_judgments: response.model empty → fallback=%s resolved=%s (#9880)"
                source resolved_model;
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

let should_backoff ~sw ~net =
  let cascade_name =
    Keeper_cascade_profile.cascade_name_for_use
      Keeper_cascade_profile.Governance_judge
  in
  try
    let capacity =
      Cascade_config.local_capacity_for_selections ~sw ~net
        [ cascade_name ]
    in
    capacity.all_discovered && capacity.endpoints_found > 0
    && capacity.process_available <= 0
  with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
    Log.Governance.warn
      "capacity check failed in should_backoff: %s"
      (Printexc.to_string exn);
    false

let mark_compute_start (st : state) =
  (* Publish the gauge inside the lock so concurrent refresh_once runs
     can't interleave the read/write and end with a stale value
     overwriting the freshest count. *)
  with_lock st (fun () ->
      st.compute_in_flight <- st.compute_in_flight + 1;
      Prometheus.set_gauge governance_compute_in_flight_metric
        (float_of_int st.compute_in_flight);
      st.compute_in_flight)

let mark_compute_finish (st : state) ~started_at ~outcome ~reason
    ~timeout_sec =
  (* Clamp the elapsed time to >= 0 so a backwards system clock
     adjustment (NTP step, manual change) cannot inject a negative
     duration into the histogram or the [last_compute_duration_sec]
     dashboard surface. *)
  let duration_sec = Float.max 0.0 (Unix.gettimeofday () -. started_at) in
  let labels = [ ("outcome", outcome); ("reason", reason) ] in
  let in_flight =
    with_lock st (fun () ->
        st.compute_in_flight <- max 0 (st.compute_in_flight - 1);
        st.last_compute_duration_sec <- Some duration_sec;
        st.last_compute_timeout_sec <- timeout_sec;
        st.last_compute_outcome <- Some outcome;
        st.last_compute_reason <- Some reason;
        Prometheus.set_gauge governance_compute_in_flight_metric
          (float_of_int st.compute_in_flight);
        st.compute_in_flight)
  in
  Prometheus.inc_counter governance_compute_total_metric ~labels ();
  Prometheus.observe_histogram governance_compute_duration_metric
    ~labels duration_sec;
  Log.Governance.info
    "refresh_once: compute_judgments telemetry outcome=%s reason=%s duration=%.3fs timeout_budget=%s in_flight_after=%d"
    outcome reason duration_sec
    (match timeout_sec with
     | Some value -> Printf.sprintf "%.1fs" value
     | None -> "unknown")
    in_flight;
  (duration_sec, in_flight)

let refresh_once ~sw ~net
    ~(masc_tools : Masc_domain.tool_schema list)
    ~(dispatch : name:string -> args:Yojson.Safe.t -> Tool_result.t)
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
  else if should_backoff ~sw ~net then begin
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
    let timeout_budget =
      Some
        (Env_config_oas_bridge.timeout_sec
           ~caller:Env_config_oas_bridge.Governance_judge ())
    in
    ignore (mark_compute_start st);
    let compute_result =
      try compute_judgments ~masc_tools ~dispatch ~build_facts with
      | Eio.Cancel.Cancelled _ as exn ->
          ignore
            (mark_compute_finish st ~started_at ~outcome:"error"
               ~reason:"cancelled" ~timeout_sec:timeout_budget);
          raise exn
      | exn ->
          Error
            (Printf.sprintf "compute_judgments raised: %s"
               (Printexc.to_string exn))
    in
    match compute_result with
    | Ok (model_used, generated_at, expires_at, judgments) ->
        ignore
          (mark_compute_finish st ~started_at ~outcome:"ok" ~reason:"ok"
             ~timeout_sec:timeout_budget);
        if judgments = [] then
          Log.Governance.routine
            "refresh_once: ok model=%s judgments=%d"
            model_used 0
        else
          Log.Governance.info
            "refresh_once: ok model=%s judgments=%d"
            model_used (List.length judgments);
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
            st.last_disk_load_unix <- Some (Unix.gettimeofday ());
            List.iter
              (fun json -> Hashtbl.replace st.judgments (judgment_key json) json)
              judgments)
    | Error message ->
        let reason = degraded_reason_of_error message in
        let timeout_sec =
          match timeout_sec_of_error message with
          | Some value -> Some value
          | None -> timeout_budget
        in
        let duration_sec, in_flight =
          mark_compute_finish st ~started_at ~outcome:"error" ~reason
            ~timeout_sec
        in
        Log.Governance.warn
          "refresh_once: compute_judgments failed: %s (duration=%.3fs timeout_budget=%s in_flight=%d)"
          message duration_sec
          (match timeout_sec with
           | Some value -> Printf.sprintf "%.1fs" value
           | None -> "unknown")
          in_flight;
        with_lock st (fun () ->
            mark_refresh_failure ~now_ts:(Unix.gettimeofday ()) st ~message)
  end

let start ~sw ~clock ~net ~base_path
    ~(masc_tools : Masc_domain.tool_schema list)
    ~(dispatch : name:string -> args:Yojson.Safe.t -> Tool_result.t)
    ~build_facts () =
  (* Ensure governance directories exist before first read/write *)
  ensure_dir (governance_dir base_path);
  ensure_dir (Filename.concat (governance_dir base_path) "judgments");
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
