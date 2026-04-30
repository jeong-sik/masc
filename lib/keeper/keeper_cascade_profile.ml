(** See {!Keeper_cascade_profile} interface for rationale. *)

(** SSOT variant for the 1+1 cascade model.

    One keeper-assignable bootstrap profile ({!Big_three}) and one system-only
    profile ({!Tool_rerank}). Historical phase-routing, judge, evaluator, and
    local names are logical route keys, not live catalog profiles.

    Adding a new profile is a compile-time event: add a variant here, then
    exhaustive [match] sites flag every consumer that needs to handle it.
    Personal/playground-only cascades must NOT be added here — they live in
    [$MASC_BASE_PATH/.masc/playground/.../cascade.json] only. *)
type t =
  | Big_three
  | Tool_rerank

let to_string = function
  | Big_three -> "big_three"
  | Tool_rerank -> "tool_rerank"

let all = [ Big_three; Tool_rerank ]

(** All known cascade profile names, derived from the variant. Consumers
    that still operate on strings can use this list; new code should
    take {!t} directly. *)
let known_cascades = List.map to_string all

let default = Big_three
let default_name = to_string default

type logical_use = Cascade_routes.logical_use =
  | Keeper_turn
  | Phase_recovery
  | Phase_buffer
  | Tool_required
  | Governance_judge
  | Operator_judge
  | Cross_verifier
  | Verifier
  | Autoresearch
  | Adversarial_reviewer
  | Auto_responder
  | Routing
  | Openai_compat
  | Persona_generation
  | Provider_benchmark
  | Tool_rerank_use

let logical_use_key = Cascade_routes.logical_use_key
let logical_use_of_string_opt = Cascade_routes.logical_use_of_string_opt
let configured_route_targets = Cascade_routes.configured_route_targets
let cascade_name_for_use = Cascade_routes.cascade_name_for_use

type runtime_name = Runtime_name of string

let runtime_name_to_string (Runtime_name value) = value

let of_string_opt (raw : string) : t option =
  match String.trim raw |> String.lowercase_ascii with
  | "" -> Some default
  | "big_three" -> Some Big_three
  | "tool_rerank" -> Some Tool_rerank
  | _ -> None

let canonical (raw : string) : t =
  match of_string_opt raw with
  | Some t -> t
  | None -> default

let catalog_entries ?config_path () =
  let path_opt =
    match config_path with
    | Some path -> Some path
    | None -> Config_dir_resolver.cascade_path_opt ()
  in
  match path_opt with
  | None -> None
  | Some path -> (
      match Cascade_config_loader.load_catalog ~config_path:path with
      | Ok entries -> Some entries
      | Error _ -> None)

let catalog_entries_result ?config_path () =
  let path_opt =
    match config_path with
    | Some path -> Some path
    | None -> Config_dir_resolver.cascade_path_opt ()
  in
  match path_opt with
  | None -> Error "cascade catalog path is not resolved"
  | Some path ->
      Cascade_config_loader.load_catalog ~config_path:path

let catalog_names ?config_path () =
  match catalog_entries ?config_path () with
  | Some entries ->
      List.map (fun (entry : Cascade_config_loader.catalog_entry) -> entry.name)
        entries
  | None -> []

let catalog_names_result ?config_path () =
  match catalog_entries_result ?config_path () with
  | Error _ as err -> err
  | Ok entries ->
      Ok
        (List.map
           (fun (entry : Cascade_config_loader.catalog_entry) -> entry.name)
           entries)

(** #10259 — degraded fallback for the keeper cascade-name validator.

    Materializer regressions of the form
    [unknown field "X" in profile Y] make the full catalog load fail even
    though [cascade.toml] is parseable and already enumerates every
    cascade the operator has configured.  In that state
    {!catalog_names_result} returns [Error _], the validator collapses to
    the compile-time reserved list, and operator-defined cascades like
    [ollama_only] get reconcile-rejected fleet-wide while the runtime
    keeps running on a stale cached catalog — silent regression, log
    spam only.

    [catalog_names_with_toml_fallback] decouples the cascade-name accept
    list from strict materialization:

    - On [Ok catalog]: forward the live names ([Live_catalog]).
    - On [Error _]: parse [cascade.toml] with a lenient reader that
      enumerates only top-level table sections; if the TOML is
      parseable, return those names tagged
      [Toml_section_fallback { catalog_error }] so callers can still
      surface the degraded mode in WARN logs.
    - If neither path produces names, return [Error _] with both errors
      attached for diagnosis.

    The validator wires this in so that a materializer field-whitelist
    regression no longer manifests as "every keeper config rejected" —
    it stays as a WARN about the materializer, which is the correct
    blast radius. *)
type catalog_names_source =
  | Live_catalog
  | Toml_section_fallback of { catalog_error : string }

let catalog_names_with_toml_fallback ?config_path () =
  let path_opt =
    match config_path with
    | Some path -> Some path
    | None -> Config_dir_resolver.cascade_path_opt ()
  in
  match path_opt with
  | None -> Error "cascade catalog path is not resolved"
  | Some path -> (
      match Cascade_config_loader.load_catalog ~config_path:path with
      | Ok entries ->
          let names =
            List.map
              (fun (entry : Cascade_config_loader.catalog_entry) -> entry.name)
              entries
          in
          Ok (names, Live_catalog)
      | Error catalog_error -> (
          match
            Cascade_toml_materializer.toml_section_names_result
              ~config_path:path
          with
          | Ok [] ->
              Error
                (Printf.sprintf
                   "live catalog unavailable: %s; toml section fallback \
                    returned no cascade profile names"
                   catalog_error)
          | Ok names ->
              Ok (names, Toml_section_fallback { catalog_error })
          | Error toml_error ->
              Error
                (Printf.sprintf
                   "live catalog unavailable: %s; toml section fallback \
                    also failed: %s"
                   catalog_error toml_error)))

let is_system_only_cascade raw =
  let name = String.trim raw in
  match catalog_entries () with
  | None -> false
  | Some entries ->
      List.exists
        (fun (entry : Cascade_config_loader.catalog_entry) ->
          String.equal entry.name name && not entry.keeper_assignable)
        entries

let keeper_catalog_names ?config_path () =
  match catalog_entries ?config_path () with
  | Some entries ->
      entries
      |> List.filter_map
           (fun (entry : Cascade_config_loader.catalog_entry) ->
             if entry.keeper_assignable then Some entry.name else None)
  | None -> []

let system_catalog_names ?config_path () =
  match catalog_entries ?config_path () with
  | Some entries ->
      entries
      |> List.filter_map
           (fun (entry : Cascade_config_loader.catalog_entry) ->
             if entry.keeper_assignable then None else Some entry.name)
  | None -> []

(** Track which (cascade, target) pairs we have already logged as
    invalid fallback_cascade hints so the WARN line fires once per
    process — not once per keeper turn. *)
let logged_invalid_fallback : (string * string, unit) Hashtbl.t =
  Hashtbl.create 4

let fallback_cascade_for ?config_path name =
  let trimmed_name = String.trim name in
  if String.equal trimmed_name "" then None
  else
    match catalog_entries ?config_path () with
    | None -> None
    | Some entries ->
        let catalog_names =
          List.map
            (fun (entry : Cascade_config_loader.catalog_entry) -> entry.name)
            entries
        in
        let entry_opt =
          List.find_opt
            (fun (entry : Cascade_config_loader.catalog_entry) ->
              String.equal entry.name trimmed_name)
            entries
        in
        (match entry_opt with
         | None -> None
         | Some entry ->
             (match entry.fallback_cascade with
              | None -> None
              | Some target ->
                  if String.equal target trimmed_name then None
                  else if List.mem target catalog_names then Some target
                  else begin
                    let key = (trimmed_name, target) in
                    if not (Hashtbl.mem logged_invalid_fallback key) then begin
                      Hashtbl.add logged_invalid_fallback key ();
                      Log.Misc.warn
                        "[CascadeConfig] profile %s declares \
                         fallback_cascade=%s which is not in the live \
                         catalog; ignoring hint"
                        trimmed_name target
                    end;
                    None
                  end))

let canonicalize_with_catalog ~catalog raw =
  match String.trim raw with
  | "" -> Cascade_routes.fallback_name_for_catalog Keeper_turn ~catalog
  | trimmed -> (
      if List.mem trimmed catalog then trimmed
      else match of_string_opt trimmed with
      | Some profile ->
          let name = to_string profile in
          if catalog = [] || List.mem name catalog then name
          else Cascade_routes.fallback_name_for_catalog Keeper_turn ~catalog
      | None ->
          match logical_use_of_string_opt trimmed with
          | Some use -> Cascade_routes.fallback_name_for_catalog use ~catalog
          | None -> Cascade_routes.fallback_name_for_catalog Keeper_turn ~catalog)

let normalize_declared_name (raw : string) : string =
  let trimmed = String.trim raw in
  if String.equal trimmed "" then
    cascade_name_for_use Keeper_turn
  else
    match of_string_opt trimmed with
    | Some t -> to_string t
    | None -> (
        match logical_use_of_string_opt trimmed with
        | Some use -> cascade_name_for_use use
        | None -> trimmed)

let resolve_live_with_catalog ~catalog raw =
  let trimmed = String.trim raw in
  let normalized =
    if List.mem trimmed catalog then trimmed
    else
      match of_string_opt trimmed with
      | Some t ->
          let name = to_string t in
          if catalog = [] || List.mem name catalog then name
          else Cascade_routes.fallback_name_for_catalog Keeper_turn ~catalog
      | None -> (
          match logical_use_of_string_opt trimmed with
          | Some use -> Cascade_routes.fallback_name_for_catalog use ~catalog
          | None -> trimmed)
  in
  if List.mem normalized catalog then normalized
  else Cascade_routes.fallback_name_for_catalog Keeper_turn ~catalog

let resolve_live ?config_path raw =
  resolve_live_with_catalog ~catalog:(catalog_names ?config_path ()) raw

let canonicalize (raw : string) : string =
  canonicalize_with_catalog ~catalog:(catalog_names ()) raw

let runtime_name_of_string raw = Runtime_name (canonicalize raw)

let models_key_t t = to_string t ^ "_models"
let temperature_key_t t = to_string t ^ "_temperature"
let max_tokens_key_t t = to_string t ^ "_max_tokens"

let models_key name = canonicalize name ^ "_models"
let temperature_key name = canonicalize name ^ "_temperature"
let max_tokens_key name = canonicalize name ^ "_max_tokens"
