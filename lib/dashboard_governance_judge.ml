open Yojson.Safe.Util

type runtime_snapshot = {
  judge_online : bool;
  refreshing : bool;
  generated_at : string option;
  expires_at : string option;
  model_used : string option;
  keeper_name : string;
  last_error : string option;
}

type state = {
  mutex : Mutex.t;
  mutable started : bool;
  mutable refreshing : bool;
  mutable judge_online : bool;
  mutable generated_at_unix : float option;
  mutable expires_at_unix : float option;
  mutable generated_at : string option;
  mutable expires_at : string option;
  mutable model_used : string option;
  mutable last_error : string option;
  mutable judgments : (string, Yojson.Safe.t) Hashtbl.t;
}

let governance_dir base_path =
  Filename.concat (Filename.concat base_path ".masc") "governance"

let judgments_path base_path =
  Filename.concat (governance_dir base_path) "judgments.jsonl"

let states : (string, state) Hashtbl.t = Hashtbl.create 4

let with_lock (st : state) f =
  Mutex.lock st.mutex;
  Fun.protect f ~finally:(fun () -> Mutex.unlock st.mutex)

let rec ensure_dir path =
  if not (Sys.file_exists path) then (
    let parent = Filename.dirname path in
    if parent <> path && not (Sys.file_exists parent) then ensure_dir parent;
    try Unix.mkdir path 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())

let iso_of_unix = Dashboard_utils.iso_of_unix
let parse_iso_opt = Dashboard_utils.parse_iso_opt

let now_iso () = Types.now_iso ()
let option_to_yojson f = function Some value -> f value | None -> `Null

let interval_sec () =
  match Sys.getenv_opt "MASC_DASHBOARD_GOVERNANCE_JUDGE_INTERVAL_SEC" with
  | Some raw -> (
      try max 15 (int_of_string (String.trim raw)) with Failure _ -> 60)
  | None -> 60

let cache_ttl_sec () = float_of_int (interval_sec () * 2)

let enabled () =
  match Sys.getenv_opt "MASC_DASHBOARD_GOVERNANCE_JUDGE_ENABLED" with
  | Some raw -> (
      match String.lowercase_ascii (String.trim raw) with
      | "0" | "false" | "no" | "off" -> false
      | _ -> true)
  | None -> true

let keeper_name = "operator-judge"

let get_state base_path =
  match Hashtbl.find_opt states base_path with
  | Some st -> st
  | None ->
      let st =
        {
          mutex = Mutex.create ();
          started = false;
          refreshing = false;
          judge_online = false;
          generated_at_unix = None;
          expires_at_unix = None;
          generated_at = None;
          expires_at = None;
          model_used = None;
          last_error = None;
          judgments = Hashtbl.create 32;
        }
      in
      Hashtbl.add states base_path st;
      st

let key_of kind id = kind ^ ":" ^ id

let judgment_key json =
  let kind = json |> member "target_kind" |> to_string in
  let id = json |> member "target_id" |> to_string in
  key_of kind id

let judgment_generated_at json =
  json |> member "generated_at" |> to_string_option |> parse_iso_opt
  |> Option.value ~default:0.0

let load_latest_from_disk base_path =
  let path = judgments_path base_path in
  if not (Sys.file_exists path) then Hashtbl.create 32
  else
    let table = Hashtbl.create 32 in
    In_channel.with_open_text path In_channel.input_lines
    |> List.iter (fun line ->
           let trimmed = String.trim line in
           if trimmed <> "" then
             try
               let json = Yojson.Safe.from_string trimmed in
               let status = json |> member "status" |> to_string_option in
               if status = Some "active" then
                 let key = judgment_key json in
                 match Hashtbl.find_opt table key with
                 | Some current
                   when judgment_generated_at current >= judgment_generated_at json -> ()
                 | _ -> Hashtbl.replace table key json
             with
             | Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> ()
             | exn -> Log.Governance.warn "load_latest_from_disk parse: %s" (Printexc.to_string exn));
    table

let latest_judgments base_path =
  let st = get_state base_path in
  with_lock st (fun () ->
      if Hashtbl.length st.judgments = 0 then st.judgments <- load_latest_from_disk base_path;
      Hashtbl.to_seq_values st.judgments |> List.of_seq)

let runtime_status base_path =
  let st = get_state base_path in
  with_lock st (fun () ->
      {
        judge_online =
          st.judge_online
          &&
          (match st.expires_at_unix with
          | Some expires_at -> Unix.gettimeofday () < expires_at
          | None -> false);
        refreshing = st.refreshing;
        generated_at = st.generated_at;
        expires_at = st.expires_at;
        model_used = st.model_used;
        keeper_name;
        last_error = st.last_error;
      })

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

let allowed_tool tool =
  List.mem tool
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
      let resolved_tool = action_json |> member "resolved_tool" |> to_string_option in
      let resolved_tool =
        match resolved_tool with
        | Some tool when allowed_tool tool -> Some tool
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
  Printf.sprintf
    "You are the resident governance judge for a MASC supervisor dashboard.\n\
     Read only the factual snapshot JSON below.\n\
     Do not invent links, evidence, or actions.\n\
     If evidence is insufficient, omit the item from output.\n\
     You are not a heuristic generator. Only produce judgments you can justify directly from the facts.\n\
     Output strict JSON only with this shape:\n\
     {\n\
       \"items\": [\n\
         {\n\
           \"kind\": \"debate|consensus\",\n\
           \"id\": string,\n\
           \"summary\": string,\n\
           \"confidence\": number,\n\
           \"evidence_refs\": string[],\n\
           \"recommended_action\": {\n\
             \"action_kind\": string,\n\
             \"resolved_tool\": string,\n\
             \"target_type\": string,\n\
             \"target_id\": string|null,\n\
             \"reason\": string,\n\
             \"payload_preview\": object\n\
           } | null,\n\
           \"guardrail_state\": {\n\
             \"requires_human_gate\": boolean,\n\
             \"pending_confirm_token\": string|null,\n\
             \"ready_to_execute\": boolean\n\
           }\n\
         }\n\
       ]\n\
     }\n\n\
     Facts:\n%s"
    (Yojson.Safe.to_string facts_json)

let compute_judgments ~base_path:_ ~factual_json =
  let specs = Lodge_cascade.get_cascade ~cascade_name:"governance_judge" () in
  if specs = [] then Error "No governance_judge model is available."
  else
    let timeout_sec = Env_config.Llm.dashboard_governance_judge_timeout_seconds in
    let prompt = prompt_for_facts factual_json in
    match
      Llm_client.run_prompt_cascade ~temperature:0.2 ~timeout_sec
        ~model_specs:specs ~max_tokens:4096 ~prompt ()
    with
    | Error message -> Error message
    | Ok response -> (
        try
          let parsed = Yojson.Safe.from_string response.content in
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
                    ~model_used:response.model_used)
          in
          Ok (response.model_used, generated_at, expires_at, judgments)
        with
        | Yojson.Json_error msg ->
            Error (Printf.sprintf "Governance judge returned invalid JSON: %s" msg)
        | exn ->
            Error (Printf.sprintf "Governance judge parse error: %s" (Printexc.to_string exn)))

let append_judgments base_path judgments =
  ensure_dir (governance_dir base_path);
  let path = judgments_path base_path in
  let oc =
    open_out_gen [ Open_creat; Open_text; Open_append ] 0o644 path
  in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () ->
      List.iter
        (fun json ->
          output_string oc (Yojson.Safe.to_string json);
          output_char oc '\n')
        judgments)

let refresh_once ~base_path ~build_facts =
  let st = get_state base_path in
  with_lock st (fun () -> st.refreshing <- true);
  match compute_judgments ~base_path ~factual_json:(build_facts ()) with
  | Ok (model_used, generated_at, expires_at, judgments) ->
      append_judgments base_path judgments;
      with_lock st (fun () ->
          st.refreshing <- false;
          st.judge_online <- true;
          st.generated_at <- Some generated_at;
          st.generated_at_unix <- Some (Types.parse_iso8601 generated_at);
          st.expires_at <- Some expires_at;
          st.expires_at_unix <- Some (Types.parse_iso8601 expires_at);
          st.model_used <- Some model_used;
          st.last_error <- None;
          List.iter
            (fun json -> Hashtbl.replace st.judgments (judgment_key json) json)
            judgments)
  | Error message ->
      with_lock st (fun () ->
          st.refreshing <- false;
          st.judge_online <- false;
          st.last_error <- Some message)

let start ~sw ~clock ~base_path ~build_facts () =
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
        let rec loop () =
          refresh_once ~base_path ~build_facts;
          Eio.Time.sleep clock (float_of_int (interval_sec ()));
          loop ()
        in
        loop ())
