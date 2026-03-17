(** Lodge Cascade — local heartbeat model-pool loader.

    Reads provider:model arrays from config/llm_cascade.json.
    Entries requiring API keys are skipped when the key is not set.
    Invalid entries are ignored with a warning.

    The file is hot-reloaded via a simple mtime cache.
    When the file or requested key is missing, built-in defaults are used. *)

open Printf

type cascade_result = {
  response : string;
  llm_used : string;
  duration_ms : int;
}

let config_cache : (string, float * Yojson.Safe.t) Hashtbl.t = Hashtbl.create 4

let load_json_file path =
  try
    let st = Unix.stat path in
    let mtime = st.Unix.st_mtime in
    match Hashtbl.find_opt config_cache path with
    | Some (cached_mtime, json) when Float.equal cached_mtime mtime -> Ok json
    | _ ->
        let content = Fs_compat.load_file path in
        let json = Yojson.Safe.from_string content in
        Hashtbl.replace config_cache path (mtime, json);
        Ok json
  with
  | Sys_error msg -> Error msg
  | Unix.Unix_error (err, fn, arg) ->
      Error (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message err))
  | exn -> Error (Printexc.to_string exn)

let default_config_path () =
  let candidates =
    let cwd_candidate =
      Filename.concat (Sys.getcwd ()) "config/llm_cascade.json"
    in
    let me_root_candidate =
      let me =
        Sys.getenv_opt "ME_ROOT"
        |> Option.value
             ~default:(Sys.getenv_opt "HOME" |> Option.value ~default:"/tmp")
      in
      Filename.concat
        (Filename.concat me "workspace/yousleepwhen/masc-mcp")
        "config/llm_cascade.json"
    in
    [ cwd_candidate; me_root_candidate ]
  in
  match List.find_opt Sys.file_exists candidates with
  | Some path -> path
  | None -> (
      match candidates with
      | first :: _ -> first
      | [] -> Filename.concat (Sys.getcwd ()) "config/llm_cascade.json")

(** Build a provider:model label, filtering out empty models. *)
let label provider model =
  if model = "" then None
  else Some (Printf.sprintf "%s:%s" provider model)

(** Build a label list, discarding entries with empty models. *)
let labels_of pairs =
  List.filter_map (fun (p, m) -> label p m) pairs

let default_model_strings ~cascade_name =
  let llama_model = Env_config.Llama.default_model in
  let glm_model = Env_config.Llm.default_model in
  let glm_flash = Env_config.Llm.flash_model in
  (* llama + glm:auto — Glm_pool selects model at runtime *)
  let llama_glm =
    (if llama_model <> "" then [ Printf.sprintf "llama:%s" llama_model ] else [])
    @ [ "glm:auto" ]
  in
  match cascade_name with
  (* heartbeat — llama first, glm fallback *)
  | "heartbeat_action" | "heartbeat_wake" -> llama_glm
  (* sentinel — llama first, glm fallback *)
  | "sentinel_board" | "sentinel_task" | "sentinel_keeper" -> llama_glm
  (* lodge subsystems — llama first, glm fallback *)
  | "lodge_direct" | "lodge_context_rewrite" | "lodge_trait_gen"
  | "lodge_comment" | "lodge_agent_match" ->
      llama_glm
  (* gardener — llama first, glm fallback *)
  | "gardener_spawn" -> llama_glm
  (* classification — local llama, glm fallback *)
  | "classification" | "context_router" | "capability_match" -> llama_glm
  (* theory of mind — local llama, glm fallback *)
  | "tom" -> llama_glm
  (* verifier — local llama, glm fallback *)
  | "verifier" -> llama_glm
  (* trpg — local llama, glm fallback *)
  | "trpg_intent" -> llama_glm
  (* briefing — llama first, flash-tier cloud chain, glm fallback *)
  | "briefing" ->
      (if llama_model <> "" then [ Printf.sprintf "llama:%s" llama_model ] else [])
      @ labels_of [ ("glm", glm_flash); ("gemini", Env_config.Gemini.flash_model) ]
      @ [ "glm:auto" ]
  | "governance_judge" | "operator_judge" -> llama_glm
  (* walph — default execution models *)
  | "walph" -> llama_glm
  (* auto_responder — agent_type-specific cascades *)
  | "auto_responder_claude" ->
      labels_of [ ("claude", Env_config.Claude.default_model) ]
      @ [ "glm:auto" ]
  | "auto_responder_gemini" ->
      labels_of [ ("gemini", Env_config.Gemini.flash_model) ]
      @ [ "glm:auto" ]
  | "auto_responder_glm" ->
      labels_of [ ("glm", glm_model) ]
      @ [ "glm:auto" ]
  | "auto_responder" -> llama_glm
  (* spawn glm — cloud cascade via Glm_pool *)
  | "spawn_glm" ->
      labels_of [ ("glm", glm_model); ("glm", glm_flash) ]
      @ [ "glm:auto" ]
  (* topic extraction — fast local model, glm fallback *)
  | "topic_extraction" ->
      labels_of [ ("ollama", glm_flash) ]
      @ [ "glm:auto" ]
  (* unregistered cascade: llama + glm as safety net *)
  | _ -> llama_glm

let model_key_of_cascade cascade_name = cascade_name ^ "_models"

let read_model_strings ~config_path ~cascade_name =
  let key = model_key_of_cascade cascade_name in
  match load_json_file config_path with
  | Error msg ->
      eprintf
        "[cascade] config load failed for %s: %s — using built-in defaults\n%!"
        key msg;
      default_model_strings ~cascade_name
  | Ok json -> (
      let open Yojson.Safe.Util in
      match json |> member key with
      | `List items ->
          let parsed =
            List.filter_map
              (function
                | `String s -> Some (String.trim s)
                | other ->
                    eprintf
                      "[cascade] %s: ignoring non-string entry %s\n%!"
                      key (Yojson.Safe.to_string other);
                    None)
              items
          in
          if parsed = [] then (
            eprintf
              "[cascade] %s: empty model list — using built-in defaults\n%!" key;
            default_model_strings ~cascade_name)
          else parsed
      | `Null ->
          eprintf
            "[cascade] %s not found in %s — using built-in defaults\n%!" key
            config_path;
          default_model_strings ~cascade_name
      | other ->
          eprintf
            "[cascade] %s must be a string list, got %s — using built-in defaults\n%!"
            key (Yojson.Safe.to_string other);
          default_model_strings ~cascade_name)

let get_cascade ?(config_path = "") ~cascade_name () :
    Llm_client.model_spec list =
  let path =
    if String.length config_path > 0 then config_path else default_config_path ()
  in
  let configured = read_model_strings ~config_path:path ~cascade_name in
  let specs = Llm_client.available_model_specs_of_strings configured in
  if specs <> [] then specs
  else
    let defaults = default_model_strings ~cascade_name in
    if configured = defaults then (
      eprintf
        "[cascade] %s: no callable models from built-in defaults\n%!"
        cascade_name;
      [])
    else (
      eprintf
        "[cascade] %s: configured models unavailable — retrying built-in defaults\n%!"
        cascade_name;
      Llm_client.available_model_specs_of_strings defaults)

let call ~cascade_name ~prompt
    ?(config_path = "") ?(temperature = 0.3) ?(timeout_sec = 30)
    ?(max_tokens = 500) ?(accept = fun _ -> true) ?system () =
  let specs = get_cascade ~config_path ~cascade_name () in
  if specs = [] then
    Error (Printf.sprintf "[cascade] no callable models for %s" cascade_name)
  else
    match
      Llm_client.run_prompt_cascade ~temperature
        ~timeout_sec ~model_specs:specs ~max_tokens ~accept ?system ~prompt ()
    with
    | Ok resp ->
        Ok
          {
            response = Llm_client.text_of_response resp;
            llm_used = resp.Llm_client.model_used;
            duration_ms = resp.Llm_client.latency_ms;
          }
    | Error msg -> Error msg
