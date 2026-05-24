(** Phonebook TOML parser — reads the simplified phonebook TOML schema.

    Parses providers, models, and tier-groups ONLY. No routes, tiers,
    bindings, or aliases. All routing logic is in {!Cascade_routing_policy}.

    Uses [Otoml] (same as existing {!Cascade_declarative_parser}) for
    TOML parsing. Hot-reload is handled by {!Cascade_config_loader}.

    Convention: [Otoml.find_opt tbl Fun.id path] returns a raw [Otoml.t]
    for sub-tables. Typed getters like [Otoml.find_opt tbl Otoml.get_string]
    return the extracted value directly. *)

open Cascade_phonebook_types

type parse_error =
  { path : string
  ; message : string
  }
[@@deriving show]

let error path message = [ { path; message } ]

let ( let* ) x f = Result.bind x f

let partition_results
    (results : ('a, parse_error list) result list)
    : ('a list, parse_error list) result =
  let oks, errs =
    List.partition_map
      (function
        | Ok x -> Either.Left x
        | Error e -> Either.Right e)
      results
  in
  if errs <> [] then Error (List.concat errs) else Ok oks

(* ── Thinking Control Format ─────────────────────────────────── *)

let thinking_format_of_string (s : string)
    : (cascade_thinking_control_format, string) result =
  match s with
  | "no_thinking_control" | "none" -> Ok No_thinking_control
  | "thinking_object" -> Ok Thinking_object
  | "reasoning_effort" -> Ok Reasoning_effort
  | "reasoning_param" -> Ok Reasoning_param
  | "chat_template_kwargs" -> Ok Chat_template_kwargs
  | "reasoning_content" -> Ok Reasoning_content
  | _ ->
    Error
      (Printf.sprintf
         "unknown thinking_control_format %S: expected one of \
          none, thinking_object, reasoning_effort, reasoning_param, \
          chat_template_kwargs, reasoning_content"
         s)

(* ── Defaults ────────────────────────────────────────────────── *)

let parse_defaults (tbl : Otoml.t) : (cascade_phonebook_defaults, parse_error list) result =
  let max_output =
    Otoml.find_or ~default:4096 tbl Otoml.get_integer [ "max_output_tokens" ]
  in
  let thinking_budget =
    Otoml.find_or ~default:8192 tbl Otoml.get_integer [ "default_thinking_budget" ]
  in
  Ok { max_output_tokens = max_output; default_thinking_budget = thinking_budget }

(* ── Provider ────────────────────────────────────────────────── *)

let parse_provider (id : string) (tbl : Otoml.t)
    : (cascade_phonebook_provider, parse_error list) result =
  let path = Printf.sprintf "providers.%s" id in
  let* endpoint =
    match Otoml.find_opt tbl Otoml.get_string [ "endpoint" ] with
    | Some e -> Ok e
    | None -> Error (error (path ^ ".endpoint") "required field missing")
  in
  let protocol_str =
    Otoml.find_or ~default:"openai-http" tbl Otoml.get_string [ "protocol" ]
  in
  let flavor_str =
    Otoml.find_or ~default:"openai" tbl Otoml.get_string [ "flavor" ]
  in
  let auth_env = Otoml.find_opt tbl Otoml.get_string [ "auth_env" ] in
  let note = Otoml.find_opt tbl Otoml.get_string [ "note" ] in
  (try
     let protocol = protocol_of_string protocol_str in
     let flavor = flavor_of_string flavor_str in
     Ok { id; endpoint; protocol; flavor; auth_env; note }
   with Failure msg ->
     Error (error path msg))

(* ── Model Capabilities ──────────────────────────────────────── *)

let parse_model_capabilities (tbl : Otoml.t) (path : string)
    : (phonebook_model_capabilities, parse_error list) result =
  let int_opt key = Otoml.find_opt tbl Otoml.get_integer [ key ] in
  let bool_field key = Otoml.find_or ~default:false tbl Otoml.get_boolean [ key ] in
  let thinking_str =
    Otoml.find_or ~default:"none" tbl Otoml.get_string [ "thinking_control_format" ]
  in
  let* thinking_format =
    match thinking_format_of_string thinking_str with
    | Ok f -> Ok f
    | Error msg -> Error (error (path ^ ".thinking_control_format") msg)
  in
  Ok
    { max_output_tokens = int_opt "max_output_tokens"
    ; supports_tool_choice = bool_field "supports_tool_choice"
    ; supports_extended_thinking = bool_field "supports_extended_thinking"
    ; supports_reasoning_budget = bool_field "supports_reasoning_budget"
    ; thinking_control_format = thinking_format
    ; supports_image_input = bool_field "supports_image_input"
    ; supports_structured_output = bool_field "supports_structured_output"
    ; supports_native_streaming = bool_field "supports_native_streaming"
    }

(* ── Model ───────────────────────────────────────────────────── *)

let parse_model (id : string) (tbl : Otoml.t)
    : (cascade_phonebook_model, parse_error list) result =
  let path = Printf.sprintf "models.%s" id in
  let* provider =
    match Otoml.find_opt tbl Otoml.get_string [ "provider" ] with
    | Some p -> Ok p
    | None -> Error (error (path ^ ".provider") "required field missing")
  in
  let* model_id =
    match Otoml.find_opt tbl Otoml.get_string [ "model_id" ] with
    | Some m -> Ok m
    | None -> Error (error (path ^ ".model_id") "required field missing")
  in
  let note = Otoml.find_opt tbl Otoml.get_string [ "note" ] in
  let capabilities =
    match Otoml.find_opt tbl Fun.id [ "capabilities" ] with
    | Some cap_tbl ->
      (match parse_model_capabilities cap_tbl (path ^ ".capabilities") with
       | Ok caps -> Ok caps
       | Error errs -> Error errs)
    | None -> Ok phonebook_model_capabilities_default
  in
  let* capabilities = capabilities in
  Ok { id; provider; model_id; capabilities; note }

(* ── Tier-Group ──────────────────────────────────────────────── *)

let parse_diversity_constraint (s : string) : (diversity_constraint, string) result =
  match s with
  | "diverse_from_primary" -> Ok Diverse_from_primary
  | "same_provider" -> Ok Same_provider
  | "any_available" -> Ok Any_available
  | _ ->
    Error
      (Printf.sprintf
         "unknown diversity constraint %S: expected one of \
          diverse_from_primary, same_provider, any_available"
         s)

let parse_tier_group (name : string) (tbl : Otoml.t)
    : (cascade_phonebook_tier_group, parse_error list) result =
  let path = Printf.sprintf "tier-groups.%s" name in
  let* members =
    match Otoml.find_opt tbl (Otoml.get_array Otoml.get_string) [ "members" ] with
    | Some m -> Ok m
    | None -> Error (error (path ^ ".members") "required field missing")
  in
  let weight = Otoml.find_or ~default:100 tbl Otoml.get_integer [ "weight" ] in
  let constraint_result =
    match Otoml.find_opt tbl Otoml.get_string [ "constraint" ] with
    | Some s ->
      (match parse_diversity_constraint s with
       | Ok c -> Ok (Some c)
       | Error msg -> Error [ { path = path ^ ".constraint"; message = msg } ])
    | None -> Ok None
  in
  let* constraint_ = constraint_result in
  let note = Otoml.find_opt tbl Otoml.get_string [ "note" ] in
  Ok { name; members; weight; constraint_; note }

(* ── Table key extraction ────────────────────────────────────── *)

let table_keys_of (tbl : Otoml.t) : string list =
  match Otoml.get_table tbl with
  | exception Otoml.Type_error _ -> []
  | entries -> List.map fst entries

(* ── Top-level parser ────────────────────────────────────────── *)

(** Parse a phonebook TOML document into typed [cascade_phonebook].

    Top-level TOML structure:
    {v
    [defaults]
    max_output_tokens = 4096
    default_thinking_budget = 8192

    [providers.runpod-llama]
    endpoint = "..."
    protocol = "openai-http"
    flavor = "llama-cpp"
    auth_env = "RUNPOD_API_TOKEN"

    [models.qwen3-235b]
    provider = "runpod-llama"
    model_id = "qwen3-235b-a22b"
    capabilities = { ... }

    [tier-groups.primary]
    members = ["qwen3-235b"]
    weight = 100
    v} *)
let parse_phonebook (toml : Otoml.t)
    : (cascade_phonebook, parse_error list) result =
  (* Defaults *)
  let defaults_result =
    match Otoml.find_opt toml Fun.id [ "defaults" ] with
    | Some defaults_tbl -> parse_defaults defaults_tbl
    | None ->
      Ok { max_output_tokens = 4096; default_thinking_budget = 8192 }
  in
  (* Providers *)
  let providers_result =
    match Otoml.find_opt toml Fun.id [ "providers" ] with
    | Some providers_tbl ->
      let provider_ids = table_keys_of providers_tbl in
      let results =
        List.filter_map
          (fun id ->
             match Otoml.find_opt providers_tbl Fun.id [ id ] with
             | Some tbl -> Some (parse_provider id tbl)
             | None -> None)
          provider_ids
      in
      partition_results results
    | None -> Ok []
  in
  (* Models *)
  let models_result =
    match Otoml.find_opt toml Fun.id [ "models" ] with
    | Some models_tbl ->
      let model_ids = table_keys_of models_tbl in
      let results =
        List.filter_map
          (fun id ->
             match Otoml.find_opt models_tbl Fun.id [ id ] with
             | Some tbl -> Some (parse_model id tbl)
             | None -> None)
          model_ids
      in
      partition_results results
    | None -> Ok []
  in
  (* Tier-groups *)
  let tier_groups_result =
    match Otoml.find_opt toml Fun.id [ "tier-groups" ] with
    | Some tg_tbl ->
      let tg_names = table_keys_of tg_tbl in
      let results =
        List.filter_map
          (fun name ->
             match Otoml.find_opt tg_tbl Fun.id [ name ] with
             | Some tbl -> Some (parse_tier_group name tbl)
             | None -> None)
          tg_names
      in
      partition_results results
    | None -> Ok []
  in
  (* Combine with cross-reference validation *)
  match defaults_result, providers_result, models_result, tier_groups_result with
  | Ok defaults, Ok providers, Ok models, Ok tier_groups ->
    let provider_ids =
      List.map (fun (p : cascade_phonebook_provider) -> p.id) providers
    in
    let model_ids =
      List.map (fun (m : cascade_phonebook_model) -> m.id) models
    in
    let provider_ref_errors =
      List.filter_map
        (fun (m : cascade_phonebook_model) ->
           if List.mem m.provider provider_ids then None
           else
             Some
               { path = Printf.sprintf "models.%s.provider" m.id
               ; message =
                 Printf.sprintf
                   "references undefined provider %S (available: %s)"
                   m.provider (String.concat ", " provider_ids)
               })
        models
    in
    let member_ref_errors =
      List.concat_map
        (fun (tg : cascade_phonebook_tier_group) ->
           List.filter_map
             (fun mid ->
                if List.mem mid model_ids then None
                else
                  Some
                    { path =
                      Printf.sprintf "tier-groups.%s.members" tg.name
                    ; message =
                      Printf.sprintf
                        "references undefined model %S (available: %s)"
                        mid (String.concat ", " model_ids)
                    })
             tg.members)
        tier_groups
    in
    let cross_errors = provider_ref_errors @ member_ref_errors in
    if cross_errors = [] then Ok { defaults; providers; models; tier_groups }
    else Error cross_errors
  | _ ->
    let all_errors =
      (match defaults_result with Error e -> e | _ -> [])
      @ (match providers_result with Error e -> e | _ -> [])
      @ (match models_result with Error e -> e | _ -> [])
      @ (match tier_groups_result with Error e -> e | _ -> [])
    in
    Error all_errors
