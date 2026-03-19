(** Keeper_types_resident — model selection, path utilities,
    and JSONL append/rotation helpers.

    Extracted from keeper_types.ml to reduce file size.
    Depends only on Keeper_config (no Keeper_types dependency). *)

include Keeper_config

(* Duplicated from Keeper_types to avoid circular dependency. *)
let mkdir_p_ path =
  Fs_compat.mkdir_p path

let keeper_dir_ (config : Room.config) =
  let d = Filename.concat (Filename.concat config.base_path ".masc") "perpetual-keepers" in
  mkdir_p_ d;
  d

let session_base_dir_ (config : Room.config) =
  Filename.concat (Filename.concat config.base_path ".masc") "perpetual"

let model_specs_of_strings (model_strs : string list) :
    (Llm_types.model_spec list, string) result =
  let rec go acc = function
    | [] -> Ok (List.rev acc)
    | s :: rest -> (
        match Llm_cascade.model_spec_of_string s with
        | Ok spec -> go (spec :: acc) rest
        | Error e -> Error (Printf.sprintf "Bad model spec %s: %s" s e))
  in
  go [] model_strs

let env_present name =
  match Sys.getenv_opt name with
  | Some value -> String.trim value <> ""
  | None -> false

let ollama_port_listening () =
  try
    let sock = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
    Fun.protect
      ~finally:(fun () -> try Unix.close sock with Unix.Unix_error _ -> ())
      (fun () ->
        Unix.connect sock (Unix.ADDR_INET (Unix.inet_addr_loopback, 11434));
        true)
  with Unix.Unix_error _ ->
    false

let model_spec_is_local_runtime (model : Llm_types.model_spec) =
  match model.provider with
  | Llm_types.Llama -> true
  | _ -> false

let model_spec_is_available (model : Llm_types.model_spec) =
  match model.provider with
  | Llm_types.Llama -> true
  | _ -> true

let keeper_fallback_model_labels () =
  let gemini_available =
    match Provider_adapter.resolve_gemini_direct_auth () with
    | Provider_adapter.Gemini_api_key
    | Provider_adapter.Gemini_vertex_adc _ -> true
    | Provider_adapter.Gemini_auth_missing _ -> false
  in
  let families_with_availability =
    [
      (env_present "ZAI_API_KEY", Provider_adapter.Glm_family);
      (gemini_available, Provider_adapter.Gemini_family);
      (env_present "ANTHROPIC_API_KEY", Provider_adapter.Claude_family);
    ]
  in
  families_with_availability
  |> List.filter_map (fun (enabled, family) ->
    if enabled then
      match Provider_adapter.default_model_label_for_family family with
      | Ok label -> Some label
      | Error _ -> None
    else None)

let maybe_append_keeper_fallback_models (models : string list) =
  match model_specs_of_strings models with
  | Error _ -> models
  | Ok specs ->
      let all_local = specs <> [] && List.for_all model_spec_is_local_runtime specs in
      let any_available = List.exists model_spec_is_available specs in
      if (not all_local) || any_available then
        models
      else
        let extra =
          keeper_fallback_model_labels ()
          |> List.filter (fun label -> not (List.mem label models))
        in
        if extra = [] then models else models @ extra

let ensure_api_keys (models : Llm_types.model_spec list) : (unit, string) result =
  let missing =
    List.filter_map (fun (m : Llm_types.model_spec) ->
      match m.api_key_env with
      | None -> None
      | Some env ->
          let v = Sys.getenv_opt env |> Option.value ~default:"" in
          if v = "" then Some env else None)
      models
  in
  match missing with
  | [] -> Ok ()
  | xs ->
      Error (Printf.sprintf "Missing API key env vars: %s" (String.concat ", " xs))

let keeper_metrics_path config name =
  Filename.concat (keeper_dir_ config) (name ^ ".metrics.jsonl")

let keeper_memory_bank_path config name =
  Filename.concat (keeper_dir_ config) (name ^ ".memory.jsonl")

let keeper_session_dir config trace_id =
  Filename.concat (session_base_dir_ config) trace_id

let keeper_history_path config trace_id =
  Filename.concat (keeper_session_dir config trace_id) "history.jsonl"

let keeper_policy_log_path config name =
  Filename.concat (keeper_dir_ config) (name ^ ".policy.jsonl")

let keeper_feedback_log_path config name =
  Filename.concat (keeper_dir_ config) (name ^ ".feedback.jsonl")

let keeper_dataset_export_path config name =
  Filename.concat (keeper_dir_ config) (name ^ ".dataset.json")

let keeper_alerts_path config =
  Filename.concat (keeper_dir_ config) "_alerts.jsonl"

let keeper_alert_retry_path config =
  Filename.concat (keeper_dir_ config) "_alerts.retry.jsonl"

let keeper_alert_deadletter_path config =
  Filename.concat (keeper_dir_ config) "_alerts.deadletter.jsonl"

(** Rotate [path] if it exceeds the configured size threshold.
    Keeps at most [max_rotated] numbered backups (.1, .2, ...). *)
let maybe_rotate_file path =
  let max_bytes = Env_config.KeeperMetrics.max_file_bytes in
  let max_rotated = Env_config.KeeperMetrics.max_rotated_files in
  if max_bytes <= 0 then ()
  else
    match (try Some (Unix.stat path) with Unix.Unix_error _ -> None) with
    | None -> ()
    | Some st ->
        if st.Unix.st_size >= max_bytes then begin
          for i = max_rotated downto 2 do
            let src = Printf.sprintf "%s.%d" path (i - 1) in
            let dst = Printf.sprintf "%s.%d" path i in
            (try Sys.rename src dst with Sys_error _ -> ())
          done;
          let rotated = Printf.sprintf "%s.1" path in
          (try Sys.rename path rotated with Sys_error _ -> ())
        end

let append_jsonl_line path (json : Yojson.Safe.t) =
  maybe_rotate_file path;
  let line = utf8_repair_string (Yojson.Safe.to_string json) ^ "\n" in
  let fd =
    Unix.openfile path [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_APPEND] 0o644
  in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
      let _ = Unix.write_substring fd line 0 (String.length line) in
      ())
