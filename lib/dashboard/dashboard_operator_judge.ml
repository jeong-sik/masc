open Yojson.Safe.Util

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

let room_ttl_sec () = Env_config.Operator.room_ttl_sec

let session_ttl_sec () = Env_config.Operator.session_ttl_sec

let iso_of_unix unix_ts =
  let tm = Unix.gmtime unix_ts in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday tm.Unix.tm_hour
    tm.Unix.tm_min tm.Unix.tm_sec

let runtime_status base_path =
  let st = get_state base_path in
  with_lock st (fun () ->
      {
        enabled = enabled ();
        judge_online = st.judge_online;
        refreshing = st.refreshing;
        generated_at = st.generated_at;
        expires_at = st.expires_at;
        model_used = st.model_used;
        keeper_name;
        last_error = st.last_error;
      })

let normalize_text raw =
  raw |> String.trim |> String.split_on_char '\n' |> List.map String.trim
  |> List.filter (fun item -> item <> "") |> String.concat " " |> String.trim

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

let allowed_action_type = Operator_approval.is_allowed

let confirm_required = Operator_approval.confirm_required

let build_recommended_action ~actor ~target_type ~target_id json =
  match json with
  | `Assoc _ ->
      let action_type =
        json |> member "action_type" |> to_string_option |> Option.map String.trim
      in
      (match action_type with
      | Some action_type when action_type <> "" && allowed_action_type action_type ->
          let severity =
            json |> member "severity" |> to_string_option
            |> Option.value ~default:"warn"
          in
          let reason =
            normalize_text
              (json |> member "reason" |> to_string_option |> Option.value ~default:"")
          in
          let suggested_payload =
            match json |> member "suggested_payload" with
            | `Assoc _ as value -> value
            | _ -> `Assoc []
          in
          let preview =
            `Assoc
              [
                ("actor", `String actor);
                ("action_type", `String action_type);
                ("target_type", `String target_type);
                ("target_id", Option.fold ~none:`Null ~some:(fun v -> `String v) target_id);
                ("payload", suggested_payload);
              ]
          in
          Some
            (`Assoc
              [
                ("action_type", `String action_type);
                ("target_type", `String target_type);
                ("target_id", Option.fold ~none:`Null ~some:(fun v -> `String v) target_id);
                ("severity", `String severity);
                ("reason", `String reason);
                ("confirm_required", `Bool (confirm_required action_type));
                ("suggested_payload", suggested_payload);
                ("preview", preview);
                ("provenance", `String "judgment");
                ("authoritative", `Bool true);
              ])
      | _ -> None)
  | _ -> None

let prompt_for_facts facts_json =
  match
    Prompt_registry.render_prompt_template "dashboard.operator_judge"
      [ ("facts_json", Yojson.Safe.to_string facts_json) ]
  with
  | Ok value -> value
  | Error _ -> Prompt_registry.get_prompt "dashboard.operator_judge"

let parse_room_judgment ~config ~generated_at ~generated_at_unix ~model_used json =
  match json with
  | `Assoc _ ->
      let summary =
        normalize_text
          (json |> member "summary" |> to_string_option |> Option.value ~default:"")
      in
      if summary = "" then None
      else
        let confidence =
          match json |> member "confidence" with
          | `Float value -> value
          | `Int value -> float_of_int value
          | _ -> 0.0
        in
        let fresh_until_unix =
          generated_at_unix +. float_of_int (room_ttl_sec ())
        in
        Some
          (Operator_judgment.record config ~surface:"command.namespace"
             ~target_type:Operator_judgment.Coord ~target_id:None ~summary
             ~confidence ?model_name:(Some model_used)
             ?recommended_action:
               (build_recommended_action ~actor:keeper_name ~target_type:"root"
                  ~target_id:None (json |> member "recommended_action"))
             ~evidence_refs:(parse_string_list json "evidence_refs")
             ~disagreement_with_truth:
               (json |> member "disagreement_with_truth" |> to_bool_option
               |> Option.value ~default:false)
             ~generated_at ~generated_at_unix
             ~fresh_until:(iso_of_unix fresh_until_unix)
             ~fresh_until_unix ~keeper_name ())
  | _ -> None

let compute_judgments
    ~(masc_tools : Types.tool_schema list)
    ~(dispatch : name:string -> args:Yojson.Safe.t -> bool * string)
    ~facts_json =
  let timeout_s = Float.of_int Env_config.Inference.operator_judge_timeout_seconds in
  let prompt = prompt_for_facts facts_json in
  match
    Masc_oas_bridge.run_safe ~timeout_s (fun () ->
      Oas_worker.run_named_with_masc_tools ~cascade_name:"operator_judge"
        ~goal:prompt ~masc_tools ~dispatch ~max_turns:3
        ~approval:Approval_callbacks.auto_approve
        ()
    )
  with
  | Error err -> Error (Oas.Error.to_string err)
  | Ok result -> (
      let response = result.Oas_worker.response in
      try
        (* See dashboard_governance_judge.ml for rationale: LLMs frequently
           wrap JSON in ```json … ``` markdown fences. Lenient_json strips
           fences and applies other deterministic recovery transforms. *)
        let raw_text = Oas_response.text_of_response response in
        match Llm_provider.Lenient_json.parse raw_text with
        | `Assoc [("raw", `String _)] ->
            Error "Operator judge returned unparseable response (Lenient_json fallback hit)"
        | parsed -> Ok (response.model, parsed)
      with
      | Yojson.Json_error msg ->
          Error (Printf.sprintf "Operator judge returned invalid JSON: %s" msg)
      | exn ->
          Error (Printf.sprintf "Operator judge parse error: %s" (Printexc.to_string exn)))

let should_backoff ~sw ~net =
  try
    let capacity =
      Cascade_config.local_capacity_for_selections ~sw ~net
        [ "operator_judge" ]
    in
    capacity.all_discovered && capacity.endpoints_found > 0
    && capacity.process_available <= 0
  with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
    Log.Dashboard.warn
      "operator: capacity check failed in should_backoff: %s"
      (Printexc.to_string exn);
    false

let refresh_once ~sw ~net
    ~(masc_tools : Types.tool_schema list)
    ~(dispatch : name:string -> args:Yojson.Safe.t -> bool * string)
    ~(config : Coord.config) ~build_facts =
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
    match compute_judgments ~masc_tools ~dispatch ~facts_json:(build_facts ()) with
    | Error message ->
        with_lock st (fun () ->
            st.refreshing <- false;
            st.judge_online <- false;
            st.last_error <- Some message)
    | Ok (model_used, result_json) ->
        let generated_at_unix = Unix.gettimeofday () in
        let generated_at = iso_of_unix generated_at_unix in
        let expires_at =
          iso_of_unix (generated_at_unix +. float_of_int (room_ttl_sec ()))
        in
        let room_judgment =
          parse_room_judgment ~config ~generated_at ~generated_at_unix
            ~model_used result_json
        in
        let has_any = Option.is_some room_judgment in
        with_lock st (fun () ->
            st.refreshing <- false;
            st.judge_online <- has_any;
            st.generated_at <- Some generated_at;
            st.expires_at <- Some expires_at;
            st.model_used <- Some model_used;
            st.last_error <- None)
  end

let start ~sw ~clock ~net ~(config : Coord.config)
    ~(masc_tools : Types.tool_schema list)
    ~(dispatch : name:string -> args:Yojson.Safe.t -> bool * string)
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
