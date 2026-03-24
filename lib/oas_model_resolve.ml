(** OAS model label resolution — resolve model labels to max_context and
    API key availability using OAS Provider_registry directly.

    Replaces Model_spec convenience accessors for callers that only need
    scalar values (max_context, model_id) from model label strings.
    Goes through OAS Cascade_config.parse_model_string which uses
    Provider_registry as SSOT, bypassing Model_spec.model_spec entirely.

    @since 2.135.0 — inference-to-oas migration (Phase 1) *)

let default_registry = Llm_provider.Provider_registry.default ()

(** Extract provider name from a "provider:model_id" label string.
    Returns None if the label has no colon or is malformed. *)
let provider_name_of_label (label : string) : string option =
  match String.index_opt label ':' with
  | None -> None
  | Some idx ->
    if idx = 0 then None
    else Some (String.sub label 0 idx |> String.trim |> String.lowercase_ascii)

(** Resolve max_context for a model label by looking up the OAS Provider_registry.
    Falls back to 128_000 if the provider is unknown. *)
let max_context_of_label (label : string) : int =
  match provider_name_of_label label with
  | None -> 128_000
  | Some pname ->
    match Llm_provider.Provider_registry.find default_registry pname with
    | Some entry -> entry.max_context
    | None -> 128_000

(** Resolve max_context for the first available model in a label list.
    "Available" means the provider's API key env var is set (or not required).
    Falls back to 128_000 if no model is available. *)
let resolve_primary_max_context (labels : string list) : int =
  let rec find = function
    | [] -> 128_000
    | label :: rest ->
      match provider_name_of_label label with
      | None -> find rest
      | Some pname ->
        match Llm_provider.Provider_registry.find default_registry pname with
        | None -> find rest
        | Some entry ->
          if entry.is_available () then entry.max_context
          else find rest
  in
  find labels

(** Resolve model_id for the first available model in a label list.
    Returns the model_id portion of "provider:model_id".
    Falls back to empty string if no model is available. *)
let resolve_primary_model_id (labels : string list) : string =
  let model_id_of_label label =
    match String.index_opt label ':' with
    | None -> ""
    | Some idx ->
      if idx >= String.length label - 1 then ""
      else String.sub label (idx + 1) (String.length label - idx - 1) |> String.trim
  in
  let rec find = function
    | [] -> ""
    | label :: rest ->
      match provider_name_of_label label with
      | None -> find rest
      | Some pname ->
        match Llm_provider.Provider_registry.find default_registry pname with
        | None -> find rest
        | Some entry ->
          if entry.is_available () then model_id_of_label label
          else find rest
  in
  find labels

(** Resolve the default local model label and model_id.
    Uses Provider_adapter for configured label, then validates via OAS registry.
    Returns (label, model_id) or falls back to "glm:auto". *)
let default_local_model_label_and_id () : string * string =
  let fallback = ("glm:auto", Env_config.Glm.default_model) in
  let try_label label =
    match provider_name_of_label label with
    | None -> None
    | Some pname ->
      match Llm_provider.Provider_registry.find default_registry pname with
      | None -> None
      | Some entry ->
        if entry.is_available () then
          let model_id = match String.index_opt label ':' with
            | None -> ""
            | Some idx ->
              String.sub label (idx + 1) (String.length label - idx - 1) |> String.trim
          in
          Some (label, model_id)
        else None
  in
  (* Try configured default first *)
  match Provider_adapter.configured_default_model_label_result () with
  | Ok label -> (
    match try_label label with
    | Some pair -> pair
    | None ->
      (* Try execution fallback chain *)
      let labels = Provider_adapter.preferred_execution_model_labels () in
      match List.find_map try_label labels with
      | Some pair -> pair
      | None -> fallback)
  | Error _ ->
    let labels = Provider_adapter.preferred_execution_model_labels () in
    match List.find_map try_label labels with
    | Some pair -> pair
    | None -> fallback

(** Check that at least one model label in the list has its API key available.
    Returns [Ok ()] if at least one is available or the list is empty.
    Returns [Error msg] listing the missing env vars if none are available. *)
let ensure_api_keys_for_labels (labels : string list) : (unit, string) result =
  if labels = [] then Ok ()
  else
    let any_available = List.exists (fun label ->
      match provider_name_of_label label with
      | None ->
          (* Label without "provider:model" format (e.g. cascade name "default").
             Treat as available — the cascade resolves providers at runtime. *)
          true
      | Some pname ->
        if pname = "custom" then
          (* custom:model@url is self-hosted; always considered available *)
          true
        else
          match Llm_provider.Provider_registry.find default_registry pname with
          | None -> false
          | Some entry -> entry.is_available ()
    ) labels in
    if any_available then Ok ()
    else
      let missing = List.filter_map (fun label ->
        match provider_name_of_label label with
        | None -> None
        | Some pname ->
          if pname = "custom" then None  (* self-hosted, no API key needed *)
          else
            match Llm_provider.Provider_registry.find default_registry pname with
            | None -> Some (Printf.sprintf "%s (unknown provider)" pname)
            | Some entry ->
              if entry.defaults.api_key_env = "" then None
              else if entry.is_available () then None
              else Some entry.defaults.api_key_env
      ) labels in
      Error (Printf.sprintf "No valid/available model specs for labels: %s (missing: %s)"
        (String.concat ", " labels)
        (String.concat ", " missing))

(* ── Cascade model resolution ──────────────────────────── *)

(* Locate config/cascade.json via CWD or ME_ROOT.
   Inlined from Oas_worker.default_config_path to avoid circular dependency. *)
let cascade_config_path () : string option =
  let base dir name = Filename.concat (Filename.concat dir "config") name in
  let cwd = Sys.getcwd () in
  let me_root =
    Sys.getenv_opt "ME_ROOT"
    |> Option.value
         ~default:(Sys.getenv_opt "HOME" |> Option.value ~default:"/tmp")
  in
  let masc_root = Filename.concat me_root "workspace/yousleepwhen/masc-mcp" in
  let candidates =
    [ base cwd "cascade.json";
      base masc_root "cascade.json" ]
  in
  List.find_opt Sys.file_exists candidates

(* JSON loading and profile resolution delegated to OAS Cascade_config.
   OAS maintains an Eio.Mutex-protected, mtime-based cache. *)

(** Resolve model label strings from a cascade name by reading cascade.json.
    Delegates to OAS Cascade_config for JSON loading and profile resolution.
    Falls back to "default_models" then ["llama:auto"; "glm:auto"] if absent. *)
let models_of_cascade_name (cascade_name : string) : string list =
  let defaults = ["llama:auto"; "glm:auto"] in
  let config_path = cascade_config_path () in
  Llm_provider.Cascade_config.resolve_model_strings
    ?config_path
    ~name:cascade_name
    ~defaults
    ()
