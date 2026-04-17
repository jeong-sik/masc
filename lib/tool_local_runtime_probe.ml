(** Tool_local_runtime_probe -- native Ollama timing and warm-state diagnostics. *)

include Tool_local_runtime_http

type ollama_loaded_model = {
  name : string option;
  model : string option;
  size_vram_bytes : int option;
  context_length : int option;
  expires_at : string option;
}

type ollama_probe_run = {
  run_index : int;
  http_status : int option;
  wall_clock_ms : int;
  total_duration_ms : float option;
  load_duration_ms : float option;
  prompt_eval_count : int option;
  prompt_eval_duration_ms : float option;
  prompt_tokens_per_second : float option;
  eval_count : int option;
  eval_duration_ms : float option;
  generation_tokens_per_second : float option;
  done_flag : bool option;
  done_reason : string option;
  thinking_present : bool;
  response_preview : string option;
  response_chars : int option;
  error : string option;
}

let bool_opt_to_json = Json_util.bool_opt_to_json

let clamp ~min_value ~max_value value = max min_value (min max_value value)

let trim_to_option raw =
  let trimmed = String.trim raw in
  if trimmed = "" then None else Some trimmed

let normalize_ollama_server_url raw =
  let trimmed = String.trim raw in
  let rec strip_trailing_slashes value =
    let len = String.length value in
    if len > 0 && Char.equal value.[len - 1] '/' then
      strip_trailing_slashes (String.sub value 0 (len - 1))
    else
      value
  in
  strip_trailing_slashes trimmed

let ollama_ps_url server_url =
  normalize_ollama_server_url server_url
  ^ Masc_network_defaults.ollama_api_ps_path

let ollama_generate_url server_url =
  normalize_ollama_server_url server_url
  ^ Masc_network_defaults.ollama_api_generate_path

let ollama_http_error operation http_status =
  match http_status with
  | Some code -> Printf.sprintf "ollama %s returned http %d" operation code
  | None -> Printf.sprintf "ollama %s returned http unknown" operation

let ns_to_ms value =
  value |> Option.map (fun ns -> float_of_int ns /. 1_000_000.0)

let tok_per_second ~count ~duration_ms =
  match count, duration_ms with
  | Some token_count, Some elapsed_ms when token_count > 0 && elapsed_ms > 0.0 ->
      Some (float_of_int token_count /. (elapsed_ms /. 1000.0))
  | _ -> None

let collapse_preview text =
  text
  |> String.map (function '\n' | '\r' | '\t' -> ' ' | ch -> ch)
  |> String.trim

let truncate_text ?(max_len = 160) text =
  if String.length text <= max_len then
    text
  else
    String.sub text 0 max_len ^ "...[truncated]"

let default_probe_timeout_sec = 6
let default_ps_timeout_sec = 2

let string_or_fallback candidates =
  let rec loop = function
    | [] -> None
    | getter :: rest -> (
        match getter () with Some _ as value -> value | None -> loop rest)
  in
  loop candidates

let loaded_model_name (model : ollama_loaded_model) =
  string_or_fallback
    [
      (fun () -> model.name);
      (fun () -> model.model);
    ]

let ollama_loaded_model_to_yojson (model : ollama_loaded_model) =
  `Assoc
    [
      ("name", string_opt_to_json model.name);
      ("model", string_opt_to_json model.model);
      ("size_vram_bytes", int_opt_to_json model.size_vram_bytes);
      ("context_length", int_opt_to_json model.context_length);
      ("expires_at", string_opt_to_json model.expires_at);
    ]

let ollama_probe_run_to_yojson (run : ollama_probe_run) =
  `Assoc
    [
      ("run_index", `Int run.run_index);
      ("http_status", int_opt_to_json run.http_status);
      ("wall_clock_ms", `Int run.wall_clock_ms);
      ("total_duration_ms", float_opt_to_json run.total_duration_ms);
      ("load_duration_ms", float_opt_to_json run.load_duration_ms);
      ("prompt_eval_count", int_opt_to_json run.prompt_eval_count);
      ("prompt_eval_duration_ms", float_opt_to_json run.prompt_eval_duration_ms);
      ("prompt_tokens_per_second", float_opt_to_json run.prompt_tokens_per_second);
      ("eval_count", int_opt_to_json run.eval_count);
      ("eval_duration_ms", float_opt_to_json run.eval_duration_ms);
      ("generation_tokens_per_second", float_opt_to_json run.generation_tokens_per_second);
      ("done", bool_opt_to_json run.done_flag);
      ("done_reason", string_opt_to_json run.done_reason);
      ("thinking_present", `Bool run.thinking_present);
      ("response_preview", string_opt_to_json run.response_preview);
      ("response_chars", int_opt_to_json run.response_chars);
      ("error", string_opt_to_json run.error);
    ]

let ollama_loaded_models_of_ps_json json =
  let open Yojson.Safe.Util in
  let items =
    match json with
    | `Assoc _ -> (
        match member "models" json with
        | `List models -> models
        | _ -> [])
    | `List models -> models
    | _ -> []
  in
  items
  |> List.map (fun item ->
         {
           name = string_or_fallback [ (fun () -> string_member item "name"); (fun () -> string_member item "id") ];
           model =
             string_or_fallback
               [
                 (fun () -> string_member item "model");
                 (fun () -> string_member item "name");
                 (fun () -> string_member item "id");
               ];
           size_vram_bytes = int_member item "size_vram";
           context_length = int_member item "context_length";
           expires_at = string_member item "expires_at";
         })
  |> List.map ollama_loaded_model_to_yojson

let prompt_eval_duration_ms_of_run_json json =
  let open Yojson.Safe.Util in
  match member "prompt_eval_duration_ms" json with
  | `Float value -> Some value
  | `Int value -> Some (float_of_int value)
  | `Intlit value -> Option.map float_of_int (parse_int_opt value)
  | _ -> None

let ollama_probe_run_of_generate_json ~run_index ~http_status ~wall_clock_ms json =
  let open Yojson.Safe.Util in
  let duration_ms key = int_member json key |> ns_to_ms in
  let response =
    match member "response" json |> to_string_option with
    | Some value ->
        let preview = value |> collapse_preview |> truncate_text in
        Some preview
    | None -> None
  in
  let response_chars =
    match member "response" json |> to_string_option with
    | Some value -> Some (String.length value)
    | None -> None
  in
  let prompt_eval_count = int_member json "prompt_eval_count" in
  let prompt_eval_duration_ms = duration_ms "prompt_eval_duration" in
  let eval_count = int_member json "eval_count" in
  let eval_duration_ms = duration_ms "eval_duration" in
  {
    run_index;
    http_status;
    wall_clock_ms;
    total_duration_ms = duration_ms "total_duration";
    load_duration_ms = duration_ms "load_duration";
    prompt_eval_count;
    prompt_eval_duration_ms;
    prompt_tokens_per_second =
      tok_per_second ~count:prompt_eval_count ~duration_ms:prompt_eval_duration_ms;
    eval_count;
    eval_duration_ms;
    generation_tokens_per_second =
      tok_per_second ~count:eval_count ~duration_ms:eval_duration_ms;
    done_flag = member "done" json |> to_bool_option;
    done_reason = string_member json "done_reason";
    thinking_present =
      (match member "thinking" json with
      | `Null -> false
      | `String value -> String.trim value <> ""
      | `List [] -> false
      | `Assoc [] -> false
      | _ -> true);
    response_preview = response;
    response_chars;
    error = None;
  }

let failed_probe_run ~run_index ~http_status ~wall_clock_ms ~error =
  {
    run_index;
    http_status;
    wall_clock_ms;
    total_duration_ms = None;
    load_duration_ms = None;
    prompt_eval_count = None;
    prompt_eval_duration_ms = None;
    prompt_tokens_per_second = None;
    eval_count = None;
    eval_duration_ms = None;
    generation_tokens_per_second = None;
    done_flag = None;
    done_reason = None;
    thinking_present = false;
    response_preview = None;
    response_chars = None;
    error = Some error;
  }

let kv_cache_assessment_json run_jsons =
  let runs =
    run_jsons
    |> List.filter_map (fun json ->
           match prompt_eval_duration_ms_of_run_json json with
           | Some duration_ms ->
               let run_index =
                 match Yojson.Safe.Util.member "run_index" json with
                 | `Int value -> Some value
                 | `Intlit value -> parse_int_opt value
                 | _ -> None
               in
               Some (run_index, duration_ms)
           | None -> None)
  in
  match runs with
  | [] | [ _ ] ->
      `Assoc
        [
          ("signal", `String "insufficient_data");
          ("baseline_run_index", `Null);
          ("best_repeat_run_index", `Null);
          ("baseline_prompt_eval_duration_ms", `Null);
          ("best_repeat_prompt_eval_duration_ms", `Null);
          ("prompt_eval_duration_reduction_ratio", `Null);
          ( "note",
            `String
              "Need at least two successful runs with prompt_eval_duration_ms to infer repeated-prefix reuse." );
        ]
  | (baseline_run_index, baseline_ms) :: rest ->
      let best_repeat_run_index, best_repeat_ms =
        match rest with
        | first_repeat :: remaining_repeats ->
            List.fold_left
              (fun ((_best_idx, best_ms) as best) candidate ->
                let _candidate_idx, candidate_ms = candidate in
                if candidate_ms < best_ms then
                  candidate
                else
                  best)
              first_repeat remaining_repeats
        | [] -> (None, baseline_ms)
      in
      let reduction_ratio =
        if baseline_ms > 0.0 then
          Some ((baseline_ms -. best_repeat_ms) /. baseline_ms)
        else
          None
      in
      let signal, note =
        match reduction_ratio with
        | Some ratio when ratio >= 0.35 ->
            ( "likely_reused",
              "Prompt evaluation time dropped materially on a repeated prompt. Timing suggests warm repeated-prefix reuse." )
        | Some ratio when ratio >= 0.15 ->
            ( "possible_reuse",
              "Prompt evaluation time improved on a repeated prompt, but not enough to treat as a strong signal." )
        | Some _ ->
            ( "no_visible_reuse",
              "Repeated prompt evaluation time did not improve enough to show an obvious reuse signal." )
        | None ->
            ( "insufficient_data",
              "Prompt evaluation duration was missing or zero, so reuse could not be inferred." )
      in
      `Assoc
        [
          ("signal", `String signal);
          ("baseline_run_index", int_opt_to_json baseline_run_index);
          ("best_repeat_run_index", int_opt_to_json best_repeat_run_index);
          ("baseline_prompt_eval_duration_ms", `Float baseline_ms);
          ("best_repeat_prompt_eval_duration_ms", `Float best_repeat_ms);
          ("prompt_eval_duration_reduction_ratio", float_opt_to_json reduction_ratio);
          ("note", `String note);
          ( "limitation",
            `String
              "Inference only: stable Ollama APIs expose warm state and timings, not direct KV occupancy or hit-rate." );
        ]

let default_probe_prompt () =
  let line =
    "This is a repeated-prefix timing probe for Ollama native generate. Respond with exactly READY."
  in
  String.concat "\n"
    [
      line;
      line;
      line;
      line;
      line;
      line;
      line;
      line;
    ]

let fetch_ollama_ps ?(timeout_sec = 8) ~server_url () =
  let url = ollama_ps_url server_url in
  match http_get_json_with_status ~timeout_sec url with
  | Ok (http_status, json) ->
      if http_status <> Some 200 then
        (http_status, [], Some (ollama_http_error "ps" http_status))
      else
        let models =
          ollama_loaded_models_of_ps_json json
          |> List.filter_map (fun item ->
                 match item with
                 | `Assoc _ -> (
                     let open Yojson.Safe.Util in
                     Some
                       {
                         name = item |> member "name" |> to_string_option;
                         model = item |> member "model" |> to_string_option;
                         size_vram_bytes = int_member item "size_vram_bytes";
                         context_length = int_member item "context_length";
                         expires_at = item |> member "expires_at" |> to_string_option;
                       })
                 | _ -> None)
        in
        (http_status, models, None)
  | Error err -> (None, [], Some err)

let select_effective_model ~requested_model loaded_models =
  match Option.bind requested_model trim_to_option with
  | Some model_id -> Some model_id
  | None -> (
      match loaded_models with
      | model :: _ -> loaded_model_name model
      | [] -> (
          match trim_to_option Env_config_runtime.Ollama.default_model with
          | Some configured -> Some configured
          | None -> None))

let model_is_loaded model_id loaded_models =
  List.exists
    (fun loaded ->
      match loaded_model_name loaded with
      | Some candidate -> String.equal candidate model_id
      | None -> false)
    loaded_models

let should_attempt_generate_probe ~before_status ~before_error =
  match before_status, before_error with
  | Some 200, _ -> true
  | _, Some _ -> false
  | _ -> true

let request_body_json ~keep_alive ~model_id ~prompt ~max_tokens =
  let fields =
    [
      Some ("model", `String model_id);
      Some ("prompt", `String prompt);
      Some ("stream", `Bool false);
      (match Option.bind keep_alive trim_to_option with
      | Some value -> Some ("keep_alive", `String value)
      | None -> None);
      Some
        ( "options",
          `Assoc
            [
              ("temperature", `Float 0.0);
              ("num_predict", `Int max_tokens);
            ] );
    ]
    |> List.filter_map Fun.id
  in
  `Assoc fields |> Yojson.Safe.to_string

let run_single_probe ~keep_alive ~server_url ~model_id ~prompt ~max_tokens ~timeout_sec
    ~run_index =
  let url = ollama_generate_url server_url in
  let started = Time_compat.now () in
  match
    http_post_json_text_with_status ~timeout_sec ~url
      ~body_json:(request_body_json ~keep_alive ~model_id ~prompt ~max_tokens)
  with
  | Error err ->
      failed_probe_run ~run_index ~http_status:None
        ~wall_clock_ms:(int_of_float ((Time_compat.now () -. started) *. 1000.0))
        ~error:err
  | Ok (http_status, payload) ->
      let wall_clock_ms =
        int_of_float ((Time_compat.now () -. started) *. 1000.0)
      in
      if http_status <> Some 200 then
        failed_probe_run ~run_index ~http_status ~wall_clock_ms
          ~error:
            (Printf.sprintf "ollama generate returned http %s"
               (match http_status with
               | Some code -> string_of_int code
               | None -> "unknown"))
      else
        match Yojson.Safe.from_string payload with
        | exception Yojson.Json_error msg ->
            failed_probe_run ~run_index ~http_status ~wall_clock_ms
              ~error:("invalid ollama generate json: " ^ msg)
        | json ->
            ollama_probe_run_of_generate_json ~run_index ~http_status
              ~wall_clock_ms json

let runtime_ollama_probe_json ?server_url ?model ?prompt ?(probe_runs = 2)
    ?keep_alive ?(max_tokens = 16)
    ?(timeout_sec = default_probe_timeout_sec)
    ?(ps_timeout_sec = default_ps_timeout_sec) () =
  let server_url =
    Option.bind server_url trim_to_option
    |> Option.value ~default:Env_config_runtime.Ollama.server_url
    |> normalize_ollama_server_url
  in
  let prompt =
    Option.bind prompt trim_to_option |> Option.value ~default:(default_probe_prompt ())
  in
  let probe_runs = clamp ~min_value:1 ~max_value:4 probe_runs in
  let max_tokens = clamp ~min_value:1 ~max_value:128 max_tokens in
  let timeout_sec = clamp ~min_value:3 ~max_value:300 timeout_sec in
  let ps_timeout_sec = clamp ~min_value:1 ~max_value:30 ps_timeout_sec in
  let before_status, loaded_before, before_error =
    fetch_ollama_ps ~timeout_sec:ps_timeout_sec ~server_url ()
  in
  let effective_model = select_effective_model ~requested_model:model loaded_before in
  let runs, run_errors =
    match effective_model with
    | None -> ([], [ "No Ollama model was requested, loaded, or configured via OLLAMA_DEFAULT_MODEL." ])
    | Some _ when not (should_attempt_generate_probe ~before_status ~before_error) ->
        ([], [])
    | Some model_id ->
        let completed_runs =
          List.init probe_runs (fun idx -> idx + 1)
          |> List.map (fun run_index ->
                 run_single_probe ~keep_alive ~server_url ~model_id ~prompt
                   ~max_tokens ~timeout_sec ~run_index)
        in
        let run_errors =
          completed_runs
          |> List.filter_map (fun run -> run.error)
        in
        (completed_runs, run_errors)
  in
  let after_status, loaded_after, after_error =
    fetch_ollama_ps ~timeout_sec:ps_timeout_sec ~server_url ()
  in
  let runs_json = List.map ollama_probe_run_to_yojson runs in
  let kv_cache_assessment = kv_cache_assessment_json runs_json in
  let effective_model_loaded_before =
    match effective_model with
    | Some model_id -> model_is_loaded model_id loaded_before
    | None -> false
  in
  let effective_model_loaded_after =
    match effective_model with
    | Some model_id -> model_is_loaded model_id loaded_after
    | None -> false
  in
  let observations =
    []
    |> (fun items ->
         if effective_model_loaded_before then
           "Effective model was already resident before the probe according to /api/ps."
           :: items
         else items)
    |> (fun items ->
         if not effective_model_loaded_before && effective_model_loaded_after then
           "Probe appears to have loaded the model into Ollama residency."
           :: items
         else items)
    |> (fun items ->
         match runs with
         | first :: _ when Option.value ~default:0.0 first.load_duration_ms >= 1000.0 ->
             "First run reported a noticeable load_duration_ms, suggesting a colder path."
             :: items
         | first :: _ when Option.value ~default:max_float first.load_duration_ms <= 100.0 ->
             "First run load_duration_ms was small, which is consistent with a warm model."
             :: items
         | _ -> items)
    |> (fun items ->
         match Yojson.Safe.Util.member "signal" kv_cache_assessment with
         | `String "likely_reused" ->
             "Repeated prompt_eval_duration_ms dropped enough to suggest repeated-prefix reuse."
             :: items
         | `String "possible_reuse" ->
             "Repeated prompt_eval_duration_ms improved, but the signal is moderate rather than decisive."
             :: items
         | `String "no_visible_reuse" ->
             "Repeated prompt_eval_duration_ms did not show a strong reuse improvement."
             :: items
         | _ -> items)
    |> List.rev
  in
  let errors =
    List.filter_map (fun item -> item) [ before_error; after_error ] @ run_errors
  in
  `Assoc
    [
      ("source", `String "ollama native runtime");
      ("server_url", `String server_url);
      ("ps_endpoint", `String (ollama_ps_url server_url));
      ("generate_endpoint", `String (ollama_generate_url server_url));
      ("configured_default_model", string_opt_to_json (trim_to_option Env_config_runtime.Ollama.default_model));
      ("requested_model", string_opt_to_json (Option.bind model trim_to_option));
      ("effective_model", string_opt_to_json effective_model);
      ("probe_runs_requested", `Int probe_runs);
      ("probe_runs_completed", `Int (List.length runs));
      ("keep_alive", string_opt_to_json (Option.bind keep_alive trim_to_option));
      ("max_tokens", `Int max_tokens);
      ("timeout_sec", `Int timeout_sec);
      ("ps_timeout_sec", `Int ps_timeout_sec);
      ("prompt_chars", `Int (String.length prompt));
      ("prompt_preview", `String (prompt |> collapse_preview |> truncate_text ~max_len:200));
      ("ps_http_status_before", int_opt_to_json before_status);
      ("ps_http_status_after", int_opt_to_json after_status);
      ("loaded_models_before", `List (List.map ollama_loaded_model_to_yojson loaded_before));
      ("loaded_models_after", `List (List.map ollama_loaded_model_to_yojson loaded_after));
      ("model_loaded_before_probe", `Bool effective_model_loaded_before);
      ("model_loaded_after_probe", `Bool effective_model_loaded_after);
      ("runs", `List runs_json);
      ("kv_cache_assessment", kv_cache_assessment);
      ("observations", `List (List.map (fun item -> `String item) observations));
      ("errors", `List (List.map (fun item -> `String item) errors));
      ( "limitations",
        `List
          [
            `String
              "This probe can observe warm-state and timing deltas, but not direct KV cache occupancy or hit-rate.";
            `String
              "A repeated-prefix signal is inference from prompt_eval_duration_ms, not a stable Ollama-native cache metric.";
          ] );
      ("probe_ok", `Bool (errors = [] && runs <> []));
    ]
