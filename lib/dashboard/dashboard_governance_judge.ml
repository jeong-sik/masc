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
  mutable last_disk_load_unix : float option;
  mutable judgments : (string, Yojson.Safe.t) Hashtbl.t;
}

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

let now_iso () = Types.now_iso ()
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
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  if needle_len = 0 then true
  else if needle_len > haystack_len then false
  else
    let rec loop index =
      if index + needle_len > haystack_len then false
      else if String.sub haystack index needle_len = needle then true
      else loop (index + 1)
    in
    loop 0

let degraded_reason_of_error message =
  let lower = String.lowercase_ascii message in
  if
    contains_substring lower "timeout"
    || contains_substring lower "timed out"
    || contains_substring lower "deadline"
  then
    "timeout"
  else
    "error"

let cached_judgments_still_fresh ~now_ts (st : state) =
  match st.expires_at_unix with
  | Some expires_at -> expires_at > now_ts
  | None -> false

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

let normalize_text raw =
  raw |> String.trim |> String.split_on_char '\n' |> List.map String.trim
  |> List.filter (fun item -> item <> "") |> String.concat " " |> String.trim

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

let parse_item_judgment ~generated_at ~expires_at ~model_used json =
  let target_kind =
    json |> member "kind" |> to_string_option |> Option.value ~default:""
    |> String.lowercase_ascii
  in
  let target_id = json |> member "id" |> to_string_option |> Option.value ~default:"" in
  if target_kind = "" || target_id = "" then None
  else
    let summary =
      normalize_text (json |> member "summary" |> to_string_option |> Option.value ~default:"")
    in
    if summary = "" then None
    else
      let confidence =
        match json |> member "confidence" with
        | `Float value -> max 0.0 (min 1.0 value)
        | `Int value -> max 0.0 (min 1.0 (float_of_int value))
        | _ -> 0.0
      in
      let evidence_refs = parse_string_list json "evidence_refs" in
      let recommended_action = parse_recommended_action json in
      let guardrail_state =
        match json |> member "guardrail_state" with
        | `Assoc _ as state_json ->
            Some
              (`Assoc
                [
                  ("requires_human_gate", state_json |> member "requires_human_gate");
                  ("pending_confirm_token", state_json |> member "pending_confirm_token");
                  ("ready_to_execute", state_json |> member "ready_to_execute");
                ])
        | _ -> None
      in
      Some
        (`Assoc
          [
            ("judgment_id", `String (Uuidm.to_string (Uuidm.v4_gen (Random.State.make_self_init ()) ())));
            ("target_kind", `String target_kind);
            ("target_id", `String target_id);
            ("status", `String "active");
            ("summary", `String summary);
            ("confidence", `Float confidence);
            ("generated_at", `String generated_at);
            ("expires_at", `String expires_at);
            ("model_used", `String model_used);
            ("keeper_name", `String keeper_name);
            ("evidence_refs", `List (List.map (fun item -> `String item) evidence_refs));
            ("recommended_action", option_to_yojson (fun value -> value) recommended_action);
            ("guardrail_state", option_to_yojson (fun value -> value) guardrail_state);
          ])

let prompt_for_facts facts_json =
  match
    Prompt_registry.render_prompt_template "dashboard.governance_judge"
      [ ("facts_json", Yojson.Safe.to_string facts_json) ]
  with
  | Ok value -> value
  | Error _ -> Prompt_registry.get_prompt "dashboard.governance_judge"

let compute_judgments
    ~(masc_tools : Types.tool_schema list)
    ~(dispatch : name:string -> args:Yojson.Safe.t -> bool * string)
    ~build_facts =
  let timeout_s = Float.of_int Env_config.Inference.dashboard_governance_judge_timeout_seconds in
  match
    (* build_facts() is moved inside the bridge so a deadlock in
       get_agents_status is bounded by [timeout_s]
       rather than hanging the daemon fiber indefinitely (#8319). *)
    Masc_oas_bridge.run_safe ~timeout_s (fun () ->
      let factual_json = build_facts () in
      let prompt = prompt_for_facts factual_json in
      Oas_worker.run_named_with_masc_tools ~cascade_name:"governance_judge"
        ~goal:prompt ~masc_tools ~dispatch ~max_turns:3
        ~approval:Approval_callbacks.auto_approve
        ()
    )
  with
  | Error err -> Error (Oas.Error.to_string err)
  | Ok result -> (
      let response = result.Oas_worker.response in
      try
        (* LLMs frequently wrap JSON in ```json … ``` markdown fences despite
           explicit prompt instructions. Lenient_json strips fences, repairs
           trailing commas, unwraps double-stringified JSON, and falls back
           to {raw: string} only after all recovery transforms fail. *)
        let raw_text = Oas_response.text_of_response response in
        let parsed = Llm_provider.Lenient_json.parse raw_text in
        match parsed with
        | `Assoc [("raw", `String _)] ->
            Error "Governance judge returned unparseable response (Lenient_json fallback hit)"
        | _ ->
            let generated_at = now_iso () in
            let expires_at = iso_of_unix (Unix.gettimeofday () +. cache_ttl_sec ()) in
            let items =
              match parsed |> member "items" with
              | `List rows -> rows
              | _ -> []
            in
            let judgments =
              items
              |> List.filter_map
                   (parse_item_judgment ~generated_at ~expires_at
                      ~model_used:response.model)
            in
            Ok (response.model, generated_at, expires_at, judgments)
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
  try
    let capacity =
      Cascade_config.local_capacity_for_selections ~sw ~net
        [ "governance_judge" ]
    in
    capacity.all_discovered && capacity.endpoints_found > 0
    && capacity.process_available <= 0
  with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
    Log.Governance.warn
      "capacity check failed in should_backoff: %s"
      (Printexc.to_string exn);
    false

let refresh_once ~sw ~net
    ~(masc_tools : Types.tool_schema list)
    ~(dispatch : name:string -> args:Yojson.Safe.t -> bool * string)
    ~base_path ~build_facts =
  let st = get_state base_path in
  (* Cycle-start log so an operator can confirm the daemon fiber is alive.
     Previously every branch was silent in steady state — a hung daemon was
     indistinguishable from a healthy one producing zero events (#8319). *)
  Log.Governance.debug "refresh_once: cycle start";
  if should_backoff ~sw ~net then begin
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
      Log.Governance.debug "backoff: local slots saturated (first cycle)"
  end
  else begin
    with_lock st (fun () ->
        st.refreshing <- true;
        st.runtime_status <- status_refreshing;
        st.degraded_reason <- None);
    match compute_judgments ~masc_tools ~dispatch ~build_facts with
    | Ok (model_used, generated_at, expires_at, judgments) ->
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
            st.generated_at_unix <- Some (Types.parse_iso8601 generated_at);
            st.expires_at <- Some expires_at;
            st.expires_at_unix <- Some (Types.parse_iso8601 expires_at);
            st.model_used <- Some model_used;
            st.last_error <- None;
            st.last_disk_load_unix <- Some (Unix.gettimeofday ());
            List.iter
              (fun json -> Hashtbl.replace st.judgments (judgment_key json) json)
              judgments)
    | Error message ->
        Log.Governance.warn
          "refresh_once: compute_judgments failed: %s"
          message;
        with_lock st (fun () ->
            mark_refresh_failure ~now_ts:(Unix.gettimeofday ()) st ~message)
  end

let start ~sw ~clock ~net ~base_path
    ~(masc_tools : Types.tool_schema list)
    ~(dispatch : name:string -> args:Yojson.Safe.t -> bool * string)
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
            Log.Governance.debug "backoff: sleeping %.0fs (consecutive=%d)" sleep_s n;
          Eio.Time.sleep clock sleep_s;
          loop ()
        in
        loop ())
