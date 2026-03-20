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

let states : (string, state) Hashtbl.t = Hashtbl.create 4

let with_lock st f =
  Eio.Mutex.use_rw ~protect:true st.mutex f

let get_state base_path =
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
      st

let enabled () =
  match Sys.getenv_opt "MASC_OPERATOR_JUDGE_ENABLED" with
  | Some raw -> (
      match String.lowercase_ascii (String.trim raw) with
      | "1" | "true" | "yes" | "on" -> true
      | _ -> false)
  | None -> false

let interval_sec () =
  match Sys.getenv_opt "MASC_OPERATOR_JUDGE_INTERVAL_SEC" with
  | Some raw -> (
      try max 15 (int_of_string (String.trim raw)) with Failure _ -> 60)
  | None -> 60

let room_ttl_sec () =
  match Sys.getenv_opt "MASC_OPERATOR_JUDGE_ROOM_TTL_SEC" with
  | Some raw -> (
      try max 15 (int_of_string (String.trim raw)) with Failure _ -> 60)
  | None -> 60

let session_ttl_sec () =
  match Sys.getenv_opt "MASC_OPERATOR_JUDGE_SESSION_TTL_SEC" with
  | Some raw -> (
      try max 30 (int_of_string (String.trim raw)) with Failure _ -> 300)
  | None -> 300

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

let allowed_action_type = function
  | "broadcast" | "room_pause" | "room_resume" | "social_sweep" | "lodge_tick"
  | "team_note" | "team_broadcast" | "team_task_inject"
  | "team_worker_spawn_batch" | "team_stop"
  | "keeper_message" | "keeper_probe" | "keeper_recover"
  | "swarm_run_continue" | "swarm_run_rerun" | "swarm_run_abandon" ->
      true
  | _ -> false

let confirm_required = function
  | "room_pause" | "team_stop" | "team_task_inject"
  | "team_worker_spawn_batch" | "swarm_run_continue"
  | "swarm_run_rerun" | "swarm_run_abandon" ->
      true
  | _ -> false

let build_recommended_action ~actor ~target_type ~target_id json =
  let action_type =
    json |> member "action_type" |> to_string_option |> Option.map String.trim
  in
  match action_type with
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
            ("decision_engine", `String "resident_operator_judge");
            ("authoritative", `Bool true);
          ])
  | _ -> None

let prompt_for_facts facts_json =
  Printf.sprintf
    "You are the resident operator judge for a MASC control room.\n\
     Read only the factual operator snapshot JSON below.\n\
     Produce concise, operational judgments for the room and any team sessions that need attention.\n\
     Do not repeat raw facts. Do not invent evidence, ids, or actions. Omit entries when you are not confident.\n\
     Allowed action_type values: broadcast, room_pause, room_resume, social_sweep, lodge_tick, team_note, team_broadcast, team_task_inject, team_worker_spawn_batch, team_stop, keeper_message, keeper_probe, keeper_recover, swarm_run_continue, swarm_run_rerun, swarm_run_abandon.\n\
     Output strict JSON only with this shape:\n\
     {\n\
       \"room\": {\n\
         \"summary\": string,\n\
         \"confidence\": number,\n\
         \"evidence_refs\": string[],\n\
         \"disagreement_with_truth\": boolean,\n\
         \"recommended_action\": {\n\
           \"action_type\": string,\n\
           \"severity\": \"warn\"|\"bad\",\n\
           \"reason\": string,\n\
           \"suggested_payload\": object\n\
         } | null\n\
       } | null,\n\
       \"sessions\": [\n\
         {\n\
           \"session_id\": string,\n\
           \"summary\": string,\n\
           \"confidence\": number,\n\
           \"evidence_refs\": string[],\n\
           \"disagreement_with_truth\": boolean,\n\
           \"recommended_action\": {\n\
             \"action_type\": string,\n\
             \"severity\": \"warn\"|\"bad\",\n\
             \"reason\": string,\n\
             \"suggested_payload\": object\n\
           } | null\n\
         }\n\
       ]\n\
     }\n\n\
     Facts:\n%s"
    (Yojson.Safe.to_string facts_json)

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
          (Operator_judgment.record config ~surface:"command.warroom"
             ~target_type:Operator_judgment.Room ~target_id:None ~summary
             ~confidence ?model_name:(Some model_used)
             ?recommended_action:
               (build_recommended_action ~actor:keeper_name ~target_type:"room"
                  ~target_id:None (json |> member "recommended_action"))
             ~evidence_refs:(parse_string_list json "evidence_refs")
             ~disagreement_with_truth:
               (json |> member "disagreement_with_truth" |> to_bool_option
               |> Option.value ~default:false)
             ~generated_at ~generated_at_unix
             ~fresh_until:(iso_of_unix fresh_until_unix)
             ~fresh_until_unix ~keeper_name ())
  | _ -> None

let parse_session_judgment ~config ~generated_at ~generated_at_unix ~model_used json =
  match json with
  | `Assoc _ -> (
      match json |> member "session_id" |> to_string_option with
      | Some session_id when String.trim session_id <> "" ->
          let summary =
            normalize_text
              (json |> member "summary" |> to_string_option
              |> Option.value ~default:"")
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
              generated_at_unix +. float_of_int (session_ttl_sec ())
            in
            Some
              (Operator_judgment.record config ~surface:"command.swarm"
                 ~target_type:Operator_judgment.Team_session
                 ~target_id:(Some session_id) ~summary ~confidence
                 ?model_name:(Some model_used)
                 ?recommended_action:
                   (build_recommended_action ~actor:keeper_name
                      ~target_type:"team_session" ~target_id:(Some session_id)
                      (json |> member "recommended_action"))
                 ~evidence_refs:(parse_string_list json "evidence_refs")
                 ~disagreement_with_truth:
                   (json |> member "disagreement_with_truth" |> to_bool_option
                   |> Option.value ~default:false)
                 ~generated_at ~generated_at_unix
                 ~fresh_until:(iso_of_unix fresh_until_unix)
                 ~fresh_until_unix ~keeper_name ())
      | _ -> None)
  | _ -> None

let compute_judgments ~facts_json =
  let _timeout_sec = Env_config.Llm.operator_judge_timeout_seconds in
  let prompt = prompt_for_facts facts_json in
  match
    Oas_worker.run_named ~cascade_name:"operator_judge"
      ~goal:prompt ~max_turns:1
      ~temperature:0.2 ~max_tokens:4096 ()
  with
  | Error message -> Error message
  | Ok result -> (
      let response = result.Oas_worker.response in
      try Ok (response.Llm_provider.Types.model,
              Yojson.Safe.from_string (Llm_provider.Types.text_of_response response))
      with
      | Yojson.Json_error msg ->
          Error (Printf.sprintf "Operator judge returned invalid JSON: %s" msg)
      | exn ->
          Error (Printf.sprintf "Operator judge parse error: %s" (Printexc.to_string exn)))

let refresh_once ~(config : Room.config) ~build_facts =
  let st = get_state config.base_path in
  with_lock st (fun () -> st.refreshing <- true);
  match compute_judgments ~facts_json:(build_facts ()) with
  | Error message ->
      with_lock st (fun () ->
          st.refreshing <- false;
          st.judge_online <- false;
          st.last_error <- Some message)
  | Ok (model_used, result_json) ->
      let generated_at_unix = Unix.gettimeofday () in
      let generated_at = iso_of_unix generated_at_unix in
      let expires_at =
        iso_of_unix
          (generated_at_unix +. float_of_int (max (room_ttl_sec ()) (session_ttl_sec ())))
      in
      let room_judgment =
        parse_room_judgment ~config ~generated_at ~generated_at_unix
          ~model_used result_json
      in
      let session_judgments =
        match result_json |> member "sessions" with
        | `List items ->
            items
            |> List.filter_map
                 (parse_session_judgment ~config ~generated_at
                    ~generated_at_unix ~model_used)
        | _ -> []
      in
      let has_any =
        Option.is_some room_judgment || session_judgments <> []
      in
      with_lock st (fun () ->
          st.refreshing <- false;
          st.judge_online <- has_any;
          st.generated_at <- Some generated_at;
          st.expires_at <- Some expires_at;
          st.model_used <- Some model_used;
          st.last_error <- None)

let start ~sw ~clock ~(config : Room.config) ~build_facts () =
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
        let rec loop () =
          refresh_once ~config ~build_facts;
          Eio.Time.sleep clock (float_of_int (interval_sec ()));
          loop ()
        in
        loop ())
