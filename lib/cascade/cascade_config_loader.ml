(** JSON config loading with mtime-based hot-reload.

    Loads and caches cascade profile JSON files.  The cache is keyed by
    file path and invalidated when the file mtime changes.

    @since 0.59.0
    @since 0.92.0 extracted from Cascade_config *)

let config_cache : (string, float * Yojson.Safe.t) Hashtbl.t =
  Hashtbl.create 4

(** Stdlib Mutex — no Eio dependency. Keep the critical section limited to
    cache access so file I/O and JSON parsing do not block unrelated fibers
    longer than necessary when called from an Eio domain. *)
let config_cache_mu = Mutex.create ()

let with_cache_lock f =
  Mutex.lock config_cache_mu;
  Fun.protect ~finally:(fun () -> Mutex.unlock config_cache_mu) f

let invalidate_cache_entry path =
  with_cache_lock (fun () -> Hashtbl.remove config_cache path)

let ensure_materialized_json path =
  match Cascade_toml_materializer.ensure_materialized_json ~config_path:path with
  | Ok { wrote_json; _ } ->
      if wrote_json then invalidate_cache_entry path;
      Ok ()
  | Error _ as err -> err

let read_json_file path =
  let ic = open_in path in
  let content =
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
         let len = in_channel_length ic in
         let buf = Bytes.create len in
         really_input ic buf 0 len;
         Bytes.to_string buf)
  in
  Yojson.Safe.from_string content

let load_json path =
  let rec load_current () =
    let mtime = (Unix.stat path).Unix.st_mtime in
    match with_cache_lock (fun () ->
        match Hashtbl.find_opt config_cache path with
        | Some (cached_mtime, json) when Float.equal cached_mtime mtime ->
          Some json
        | _ -> None)
    with
    | Some json -> Ok json
    | None ->
      let json = read_json_file path in
      let refreshed_mtime = (Unix.stat path).Unix.st_mtime in
      if not (Float.equal refreshed_mtime mtime) then
        load_current ()
      else
        (* Keep the critical section to Hashtbl access only. Any Eio-aware
           work (traceln in particular) must run OUTSIDE the Stdlib.Mutex
           because traceln can suspend the fiber while the lock is held,
           blocking unrelated fibers on the domain.
           Ref: memory/feedback_eio-traceln-outside-critical-section.md *)
        let outcome =
          with_cache_lock (fun () ->
              match Hashtbl.find_opt config_cache path with
              | Some (cached_mtime, cached_json)
                when Float.equal cached_mtime refreshed_mtime ->
                `Returning_cached cached_json
              | prior ->
                Hashtbl.replace config_cache path (refreshed_mtime, json);
                `Installed_new (Option.map fst prior))
        in
        (match outcome with
         | `Returning_cached cached_json -> Ok cached_json
         | `Installed_new prior_mtime ->
             (* Observability: trace first-load vs reload so operators
                editing cascade.json can verify their change took effect.
                Keeping this at traceln (stderr) matches existing OAS
                convention (see Cascade_config.apply_provider_filter). *)
             (match prior_mtime with
              | None ->
                  Eio.traceln
                    "[CascadeConfig] loaded %s mtime=%.0f"
                    path refreshed_mtime
              | Some old_mtime ->
                  Eio.traceln
                    "[CascadeConfig] reloaded %s old_mtime=%.0f new_mtime=%.0f"
                    path old_mtime refreshed_mtime);
             Ok json)
  in
  match ensure_materialized_json path with
  | Error _ as err -> err
  | Ok () ->
      (try load_current () with
       | Sys_error msg -> Error msg
       | Unix.Unix_error (err, fn, arg) ->
           Error (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message err))
       | Yojson.Json_error msg -> Error (Printf.sprintf "JSON error: %s" msg)
       | End_of_file -> Error "unexpected end of file")

(** A model entry with an optional weight for weighted cascade selection.
    Weight defaults to 1 when not specified (backward compatible). *)
type weighted_entry = {
  model: string;
  weight: int;
  supports_tool_choice: bool option;
}

let parse_weight_field = function
  | `Int i when i > 0 -> i
  | `Float f when f > 0.0 ->
    let i = int_of_float f in
    if i > 0 && Float.equal f (float_of_int i) then i else 1
  | _ -> 1

let parse_supports_tool_choice_field = function
  | `Bool b -> Some b
  | _ -> None

let parse_weighted_item = function
  | `String s ->
    Some { model = String.trim s; weight = 1; supports_tool_choice = None }
  | `Assoc fields ->
    let open Yojson.Safe.Util in
    let json = `Assoc fields in
    (match json |> member "model" with
     | `String s when String.trim s <> "" ->
       let w = parse_weight_field (json |> member "weight") in
       let stc =
         parse_supports_tool_choice_field
           (json |> member "supports_tool_choice")
       in
       Some { model = String.trim s; weight = w; supports_tool_choice = stc }
     | _ -> None)
  | _ -> None

type catalog_entry = {
  name : string;
  keeper_assignable : bool;
  fallback_cascade : string option;
}

module StringMap = Map.Make (String)

type catalog_field =
  | Schema_field
  | Keeper_assignable_field
  | Fallback_cascade_field

let catalog_key_specs =
  [
    ("_models", Schema_field);
    ("_temperature", Schema_field);
    ("_max_tokens", Schema_field);
    ("_api_key_env", Schema_field);
    ("_strategy", Schema_field);
    ("_max_cycles", Schema_field);
    ("_backoff_base_ms", Schema_field);
    ("_backoff_cap_ms", Schema_field);
    ("_ollama_max_concurrent", Schema_field);
    ("_cli_max_concurrent", Schema_field);
    ("_tiers", Schema_field);
    ("_sticky_ttl_ms", Schema_field);
    ("_keep_alive", Schema_field);
    ("_num_ctx", Schema_field);
    ("_keeper_assignable", Keeper_assignable_field);
    ("_fallback_cascade", Fallback_cascade_field);
  ]

let split_catalog_key key =
  let key_len = String.length key in
  if key_len = 0 || key.[0] = '_' then None
  else
    List.find_map
      (fun (suffix, field) ->
        let suffix_len = String.length suffix in
        if key_len > suffix_len
           && String.sub key (key_len - suffix_len) suffix_len = suffix
        then Some (String.sub key 0 (key_len - suffix_len), field)
        else None)
      catalog_key_specs

type catalog_builder = {
  has_schema_field : bool;
  keeper_assignable : bool option;
  fallback_cascade : string option;
}

let empty_catalog_builder = {
  has_schema_field = false;
  keeper_assignable = None;
  fallback_cascade = None;
}

let update_catalog_builder builder field value =
  match field with
  | Schema_field -> { builder with has_schema_field = true }
  | Keeper_assignable_field ->
      let keeper_assignable =
        match value with
        | `Bool b -> Some b
        | _ -> builder.keeper_assignable
      in
      { builder with keeper_assignable }
  | Fallback_cascade_field ->
      let fallback_cascade =
        match value with
        | `String s ->
            let trimmed = String.trim s in
            if String.equal trimmed "" then None else Some trimmed
        | _ -> builder.fallback_cascade
      in
      { builder with fallback_cascade }

let load_catalog ~config_path =
  match load_json config_path with
  | Error _ as err -> err
  | Ok (`Assoc fields) ->
      let builders =
        List.fold_left
          (fun acc (key, value) ->
            match split_catalog_key key with
            | None -> acc
            | Some (name, field) ->
                let prior =
                  match StringMap.find_opt name acc with
                  | Some builder -> builder
                  | None -> empty_catalog_builder
                in
                StringMap.add name (update_catalog_builder prior field value) acc)
          StringMap.empty
          fields
      in
      let entries =
        builders
        |> StringMap.bindings
        |> List.filter_map (fun (name, builder) ->
               if not builder.has_schema_field then None
               else
                 Some
                   {
                     name;
                     keeper_assignable =
                       Option.value builder.keeper_assignable ~default:true;
                     fallback_cascade = builder.fallback_cascade;
                   })
      in
      Ok entries
  | Ok _ -> Ok []

let load_profile_weighted ~config_path ~name =
  let key = name ^ "_models" in
  match load_json config_path with
  | Error msg ->
      Eio.traceln
        "[CascadeConfig] load_profile_weighted: %s (profile=%s, path=%s)"
        msg name config_path;
      []
  | Ok json ->
    let open Yojson.Safe.Util in
    match json |> member key with
    | `List items -> List.filter_map parse_weighted_item items
    | _ -> []

let load_profile ~config_path ~name =
  load_profile_weighted ~config_path ~name
  |> List.map (fun e -> e.model)

(* ── Inference parameter resolution ───────────────────── *)

type inference_params = {
  temperature: float option;
  max_tokens: int option;
  keep_alive: string option;
  (** Ollama [keep_alive] override: integer seconds ("-1", "3600") or
      duration string ("5m", "30m"). Honored only when the resolved
      provider is Ollama. *)
  num_ctx: int option;
  (** Ollama [num_ctx] override: per-request KV cache allocation in
      tokens. Honored only when the resolved provider is Ollama. *)
}

let read_float_field json key =
  let open Yojson.Safe.Util in
  match json |> member key with
  | `Float f -> Some f
  | `Int i -> Some (float_of_int i)
  | _ -> None

let read_int_field json key =
  let open Yojson.Safe.Util in
  match json |> member key with
  | `Int i -> Some i
  | `Float f -> Some (int_of_float f)
  | _ -> None

let read_string_field json key =
  let open Yojson.Safe.Util in
  match json |> member key with
  | `String s when String.trim s <> "" -> Some (String.trim s)
  | _ -> None

let resolve_inference_params ~config_path ~name =
  match load_json config_path with
  | Error msg ->
      Eio.traceln
        "[CascadeConfig] resolve_inference_params: %s (name=%s, path=%s)"
        msg name config_path;
      { temperature = None; max_tokens = None;
        keep_alive = None; num_ctx = None }
  | Ok json ->
    let temp =
      match read_float_field json (name ^ "_temperature") with
      | Some _ as v -> v
      | None -> read_float_field json "default_temperature"
    in
    let max_tok =
      match read_int_field json (name ^ "_max_tokens") with
      | Some _ as v -> v
      | None -> read_int_field json "default_max_tokens"
    in
    let keep_alive =
      match read_string_field json (name ^ "_keep_alive") with
      | Some _ as v -> v
      | None -> read_string_field json "default_keep_alive"
    in
    let num_ctx =
      match read_int_field json (name ^ "_num_ctx") with
      | Some n when n > 0 -> Some n
      | _ ->
        (match read_int_field json "default_num_ctx" with
         | Some n when n > 0 -> Some n
         | _ -> None)
    in
    { temperature = temp; max_tokens = max_tok; keep_alive; num_ctx }

(* ── Per-cascade API key env override ────────────────── *)

(** Read an api_key_env override object from JSON.

    The JSON value can be:
    - A string: applies to all providers in the cascade.
      [{"{name}_api_key_env": "ZAI_API_KEY_SB"}]
    - An object mapping provider names to env var names:
      [{"{name}_api_key_env": {"glm": "ZAI_API_KEY_SB", "glm-coding": "ZAI_API_KEY_SB"}}]

    Returns an association list of [(provider_name, env_var_name)].
    The special key ["*"] means "all providers". *)
let read_api_key_env_field json key =
  let open Yojson.Safe.Util in
  match json |> member key with
  | `String s when String.trim s <> "" -> [("*", String.trim s)]
  | `Assoc pairs ->
    List.filter_map (fun (k, v) ->
      match v with
      | `String s when String.trim s <> "" ->
        Some (String.lowercase_ascii (String.trim k), String.trim s)
      | _ -> None
    ) pairs
  | _ -> []

let resolve_api_key_env ~config_path ~name =
  match load_json config_path with
  | Error msg ->
      Eio.traceln
        "[CascadeConfig] resolve_api_key_env: %s (name=%s, path=%s)"
        msg name config_path;
      []
  | Ok json ->
    match read_api_key_env_field json (name ^ "_api_key_env") with
    | [] -> read_api_key_env_field json "default_api_key_env"
    | overrides -> overrides

(* ── Per-cascade pluggable-strategy override ──────────── *)

type strategy_config = {
  kind : string option;
  max_cycles : int option;
  backoff_base_ms : int option;
  backoff_cap_ms : int option;
  ollama_max_concurrent : int option;
  cli_max_concurrent : int option;
  tiers : string list list option;
  sticky_ttl_ms : int option;
}

let read_string_field json key =
  let open Yojson.Safe.Util in
  match json |> member key with
  | `String s when String.trim s <> "" -> Some (String.trim s)
  | _ -> None

(* Read a [string list list] from a JSON [list of list of string].
   Returns [None] when the key is missing or any element has the
   wrong shape; tier configuration must be all-or-nothing to avoid
   silent misroutes. *)
let read_tiers_field json key =
  let open Yojson.Safe.Util in
  match json |> member key with
  | `Null -> None
  | `List outer ->
    let parse_tier = function
      | `List inner ->
        let strs = List.filter_map (function
            | `String s when String.trim s <> "" -> Some (String.trim s)
            | _ -> None) inner
        in
        if List.length strs = List.length inner && strs <> [] then Some strs
        else None
      | _ -> None
    in
    let tiers = List.filter_map parse_tier outer in
    if List.length tiers = List.length outer && tiers <> [] then Some tiers
    else None
  | _ -> None

let empty_strategy_config = {
  kind = None;
  max_cycles = None;
  backoff_base_ms = None;
  backoff_cap_ms = None;
  ollama_max_concurrent = None;
  cli_max_concurrent = None;
  tiers = None;
  sticky_ttl_ms = None;
}

let resolve_strategy_config ~config_path ~name =
  match load_json config_path with
  | Error msg ->
      Eio.traceln
        "[CascadeConfig] resolve_strategy_config: %s (name=%s, path=%s)"
        msg name config_path;
      empty_strategy_config
  | Ok json ->
    {
      kind = read_string_field json (name ^ "_strategy");
      max_cycles = read_int_field json (name ^ "_max_cycles");
      backoff_base_ms = read_int_field json (name ^ "_backoff_base_ms");
      backoff_cap_ms = read_int_field json (name ^ "_backoff_cap_ms");
      ollama_max_concurrent =
        read_int_field json (name ^ "_ollama_max_concurrent");
      cli_max_concurrent =
        read_int_field json (name ^ "_cli_max_concurrent");
      tiers = read_tiers_field json (name ^ "_tiers");
      sticky_ttl_ms = read_int_field json (name ^ "_sticky_ttl_ms");
    }
