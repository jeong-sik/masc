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
        let ic = open_in path in
        Fun.protect
          ~finally:(fun () -> close_in_noerr ic)
          (fun () ->
            let n = in_channel_length ic in
            let buf = Bytes.create n in
            really_input ic buf 0 n;
            let json = Yojson.Safe.from_string (Bytes.to_string buf) in
            Hashtbl.replace config_cache path (mtime, json);
            Ok json)
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
  | None -> List.hd candidates

let default_model_strings ~cascade_name =
  match cascade_name with
  | "heartbeat_action" | "heartbeat_wake" ->
      [
        "llama:qwen3.5-35b-a3b-ud-q8-xl";
        Printf.sprintf "glm:%s" Env_config.Llm.default_model;
      ]
  | "sentinel_board" | "sentinel_task" | "sentinel_keeper" ->
      [ Printf.sprintf "glm:%s" Env_config.Llm.default_model ]
  | "gardener_spawn" | "lodge_context_rewrite" | "lodge_trait_gen"
  | "lodge_comment" | "lodge_agent_match" | "lodge_direct" ->
      [ Printf.sprintf "glm:%s" Env_config.Llm.default_model ]
  | "spawn_glm" ->
      [ "glm:glm-4.7"; "glm:glm-4.7-flash"; "glm:glm-5"; "glm:glm-5-code" ]
  | _ -> []

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
    if configured = defaults then []
    else (
      eprintf
        "[cascade] %s: configured models unavailable — retrying built-in defaults\n%!"
        cascade_name;
      Llm_client.available_model_specs_of_strings defaults)
