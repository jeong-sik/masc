(** GLM Cloud Multi-Model Load Balancer

    Distributes requests across GLM models with different concurrency limits
    to maximize throughput for MASC social experiments and games.

    Model configuration loaded from config/glm_pool.json at startup.
    Falls back to hardcoded defaults if config file is missing or malformed.

    @since 2.66.0 *)

type glm_model = {
  model_id: string;
  concurrency_limit: int;
  description: string;
}

(** Hardcoded fallback models used when config/glm_pool.json is unavailable. *)
let hardcoded_models : glm_model array = [|
  { model_id = "glm-4.5"; concurrency_limit = 10; description = "High concurrency, general purpose" };
  { model_id = "glm-4.6v"; concurrency_limit = 10; description = "High concurrency, vision-capable" };
  { model_id = "glm-5"; concurrency_limit = 5; description = "Flagship model" };
  { model_id = "glm-4.7"; concurrency_limit = 5; description = "Latest generation" };
  { model_id = "glm-4.6"; concurrency_limit = 3; description = "Balanced performance" };
  { model_id = "glm-4.6v-flashx"; concurrency_limit = 3; description = "Fast variant with vision" };
  { model_id = "glm-4.7-flashx"; concurrency_limit = 3; description = "Fast latest generation" };
|]

(** Parse a single model entry from JSON. Returns None on malformed entries. *)
let parse_model_json (json : Yojson.Safe.t) : glm_model option =
  match json with
  | `Assoc fields ->
      let get_string key =
        match List.assoc_opt key fields with
        | Some (`String s) -> Some s | _ -> None
      in
      let get_int key =
        match List.assoc_opt key fields with
        | Some (`Int n) -> Some n
        | Some (`Float f) -> Some (Float.to_int f)
        | _ -> None
      in
      (match get_string "model_id", get_int "concurrency_limit" with
       | Some model_id, Some concurrency_limit when concurrency_limit > 0 ->
           let description = match get_string "description" with
             | Some d -> d | None -> ""
           in
           Some { model_id; concurrency_limit; description }
       | _ -> None)
  | _ -> None

(** Resolve config file path relative to the MASC MCP project root.
    Priority: DUNE_SOURCEROOT (project root in tests/builds)
    > MASC_WORKSPACE_ROOT (explicit override) > cwd.
    ME_ROOT is the parent workspace, not the project root. *)
let config_file_path () : string =
  let base =
    match Sys.getenv_opt "DUNE_SOURCEROOT" with
    | Some root when String.trim root <> "" -> root
    | _ -> (
        match Sys.getenv_opt "MASC_WORKSPACE_ROOT" with
        | Some root when String.trim root <> "" -> root
        | _ -> Sys.getcwd ())
  in
  Filename.concat base "config/glm_pool.json"

(** Load models from config/glm_pool.json. Returns None on any failure. *)
let load_config_models () : glm_model array option =
  let path = config_file_path () in
  if not (Sys.file_exists path) then begin
    Log.Glm_pool.info "config not found at %s, using hardcoded defaults" path;
    None
  end else
    try
      let content = In_channel.with_open_text path In_channel.input_all in
      let json = Yojson.Safe.from_string content in
      match json with
      | `Assoc fields -> (
          match List.assoc_opt "models" fields with
          | Some (`List items) ->
              let raw_models = List.filter_map parse_model_json items in
              (* Reject duplicate model_id entries — pool accounting assumes uniqueness *)
              let seen = Hashtbl.create (List.length raw_models) in
              let models = List.filter (fun (m : glm_model) ->
                if Hashtbl.mem seen m.model_id then begin
                  Log.Glm_pool.warn "duplicate model_id %s in %s, skipping" m.model_id path;
                  false
                end else begin
                  Hashtbl.replace seen m.model_id ();
                  true
                end
              ) raw_models in
              if models = [] then begin
                Log.Glm_pool.warn "config %s has no valid models, using hardcoded defaults" path;
                None
              end else begin
                let arr = Array.of_list models in
                Log.Glm_pool.info "loaded %d models from %s" (Array.length arr) path;
                Some arr
              end
          | _ ->
              Log.Glm_pool.warn "config %s missing 'models' array, using hardcoded defaults" path;
              None)
      | _ ->
          Log.Glm_pool.warn "config %s is not a JSON object, using hardcoded defaults" path;
          None
    with exn ->
      Log.Glm_pool.warn "failed to load config %s: %s, using hardcoded defaults"
        path (Printexc.to_string exn);
      None

(** Load models from config file, fall back to hardcoded defaults. *)
let base_models : glm_model array =
  match load_config_models () with
  | Some models -> models
  | None -> hardcoded_models

let env_key_for_limit (model_id : string) : string =
  let b = Buffer.create (String.length model_id + 24) in
  Buffer.add_string b "MASC_GLM_POOL_LIMIT_";
  String.iter
    (fun ch ->
      let normalized =
        if
          ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')
         || (ch >= '0' && ch <= '9'))
        then Char.uppercase_ascii ch
        else '_'
      in
      Buffer.add_char b normalized)
    model_id;
  Buffer.contents b

let positive_int_of_string (raw : string) : int option =
  match int_of_string_opt (String.trim raw) with
  | Some n when n > 0 -> Some n
  | _ -> None

let limit_for_model ~(model_id : string) ~(default : int) : int =
  let env_key = env_key_for_limit model_id in
  match Sys.getenv_opt env_key with
  | None -> default
  | Some raw -> (
      match positive_int_of_string raw with
      | Some limit ->
          if limit <> default then
            Log.Glm_pool.info "pool limit override: %s=%d (%s)" model_id limit env_key;
          limit
      | None ->
          Log.Glm_pool.warn
            "invalid pool limit override ignored: %s=%S (expected positive int)"
            env_key raw;
          default )

(** Runtime model table with personal overrides from env/profile. *)
let available_models : glm_model array =
  Array.map
    (fun model ->
      let resolved =
        limit_for_model ~model_id:model.model_id ~default:model.concurrency_limit
      in
      if resolved = model.concurrency_limit then model
      else { model with concurrency_limit = resolved })
    base_models

(** Pool state: tracks in-flight requests per model. *)
type pool_state = {
  mutable in_flight: int array;  (* Parallel to available_models *)
  mutable last_index: int;       (* For round-robin selection *)
}

(** Global pool state (lazy initialization). *)
let pool_state = lazy (
  let len = Array.length available_models in
  { in_flight = Array.make len 0; last_index = 0 }
)

let get_pool () = Lazy.force pool_state

(** Find model index by model_id, returns -1 if not found. *)
let find_model_index (model_id : string) : int =
  let rec loop i =
    if i >= Array.length available_models then -1
    else if String.equal (String.lowercase_ascii available_models.(i).model_id)
                    (String.lowercase_ascii model_id) then i
    else loop (i + 1)
  in
  loop 0

(** Check if a model_id is in our pool. *)
let is_pool_model (model_id : string) : bool =
  find_model_index model_id >= 0

(** Select best model using least-loaded strategy.
    Returns model_id with lowest in_flight/concurrency_ratio.
    Falls back to round-robin if all at capacity. *)
let select_model () : string =
  let pool = get_pool () in
  let len = Array.length available_models in

  (* Find model with best availability ratio *)
  let best_idx = ref 0 in
  let best_ratio = ref max_float in

  for i = 0 to len - 1 do
    let model = available_models.(i) in
    let in_flight = pool.in_flight.(i) in
    let ratio = float_of_int in_flight /. float_of_int model.concurrency_limit in
    (* Also consider that we can still add requests if under limit *)
    if ratio < !best_ratio && in_flight < model.concurrency_limit then begin
      best_ratio := ratio;
      best_idx := i
    end
  done;

  (* If best_ratio is still max_float, all models at capacity - use round-robin *)
  if !best_ratio = max_float then begin
    pool.last_index <- (pool.last_index + 1) mod len;
    available_models.(pool.last_index).model_id
  end else
    available_models.(!best_idx).model_id

(** Select a specific model if requested and available,
    otherwise fall back to pool selection. *)
let select_model_preferring (preferred : string option) : string =
  match preferred with
  | None -> select_model ()
  | Some model_id ->
    (* If the requested model is in pool and has capacity, use it *)
    let idx = find_model_index model_id in
    if idx >= 0 then begin
      let pool = get_pool () in
      let model = available_models.(idx) in
      if pool.in_flight.(idx) < model.concurrency_limit then
        model_id
      else
        (* Requested model at capacity, select from pool *)
        select_model ()
    end else
      (* Not a pool model, use as-is *)
      model_id

(** Increment in-flight count for a model.
    Call before making the API request. *)
let acquire (model_id : string) : unit =
  let idx = find_model_index model_id in
  if idx >= 0 then begin
    let pool = get_pool () in
    pool.in_flight.(idx) <- pool.in_flight.(idx) + 1;
    (* Debug logging *)
    let model = available_models.(idx) in
    Log.Glm_pool.debug "acquire %s: %d/%d"
      model_id pool.in_flight.(idx) model.concurrency_limit
  end

(** Decrement in-flight count for a model.
    Call after API response or error. *)
let release (model_id : string) : unit =
  let idx = find_model_index model_id in
  if idx >= 0 then begin
    let pool = get_pool () in
    let new_count = max 0 (pool.in_flight.(idx) - 1) in
    pool.in_flight.(idx) <- new_count;
    let model = available_models.(idx) in
    Log.Glm_pool.debug "release %s: %d/%d"
      model_id new_count model.concurrency_limit
  end

(** Execute a GLM request with automatic load balancing.
    Selects best model, tracks in-flight requests, and handles cleanup.

    Usage:
    {[
      Glm_pool.with_model (fun model_id ->
        (* make API call with model_id *)
        ...
      )
    ]}
*)
let with_model (preferred_model : string option) (f : string -> 'a) : 'a =
  let model_id = select_model_preferring preferred_model in
  acquire model_id;
  try
    let result = f model_id in
    release model_id;
    result
  with exn ->
    release model_id;
    raise exn

(** Get pool statistics for monitoring. *)
let get_stats () : (string * int * int) list =
  let pool = get_pool () in
  Array.mapi (fun i model ->
    (model.model_id, pool.in_flight.(i), model.concurrency_limit)
  ) available_models
  |> Array.to_list

(** Total capacity across all pool models. *)
let total_capacity : int =
  Array.fold_left (fun acc m -> acc + m.concurrency_limit) 0 available_models

(** Current total in-flight requests. *)
let current_load () : int =
  let pool = get_pool () in
  Array.fold_left (fun acc n -> acc + n) 0 pool.in_flight

(** Check if pool has available capacity (any model under limit). *)
let has_capacity () : bool =
  let pool = get_pool () in
  let len = Array.length available_models in
  let rec loop i =
    if i >= len then false
    else if pool.in_flight.(i) < available_models.(i).concurrency_limit then true
    else loop (i + 1)
  in
  loop 0
