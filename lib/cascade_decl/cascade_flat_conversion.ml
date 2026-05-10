(** Flat cascade.toml → 5-layer declarative TOML conversion logic (RFC-0058 Phase 4).

    Extracted from the CLI tool so that both the executable and unit tests
    can link against the same conversion code without duplicating logic.

    @stability Internal *)

open Cascade_declarative_types

(* --- Provider registry (cascade_prefix → protocol info) --- *)

type provider_info = {
  id : string;
  protocol : string;
  transport_kind : [ `Cli of string | `Http of string ];
  is_non_interactive : bool;
}

let provider_registry : provider_info list = [
  { id = "claude_code"; protocol = "anthropic-cli";
    transport_kind = `Cli "claude"; is_non_interactive = true };
  { id = "codex_cli"; protocol = "openai-http";
    transport_kind = `Cli "codex"; is_non_interactive = true };
  { id = "gemini_cli"; protocol = "google-cli";
    transport_kind = `Cli "gemini"; is_non_interactive = true };
  { id = "kimi_cli"; protocol = "kimi-cli";
    transport_kind = `Cli "kimi"; is_non_interactive = true };
  { id = "glm-coding"; protocol = "openai-http";
    transport_kind = `Http "https://open.bigmodel.cn/api/paas/v4";
    is_non_interactive = false };
  { id = "ollama"; protocol = "ollama-http";
    transport_kind = `Http "http://localhost:11434";
    is_non_interactive = false };
  { id = "claude"; protocol = "anthropic-http";
    transport_kind = `Http "https://api.anthropic.com";
    is_non_interactive = false };
  { id = "openai"; protocol = "openai-http";
    transport_kind = `Http "https://api.openai.com";
    is_non_interactive = false };
  { id = "gemini"; protocol = "openai-http";
    transport_kind = `Http "https://generativelanguage.googleapis.com";
    is_non_interactive = false };
  { id = "kimi"; protocol = "openai-http";
    transport_kind = `Http "https://api.moonshot.cn";
    is_non_interactive = false };
  { id = "glm"; protocol = "openai-http";
    transport_kind = `Http "https://open.bigmodel.cn/api/paas/v4";
    is_non_interactive = false };
  { id = "openrouter"; protocol = "openai-http";
    transport_kind = `Http "https://openrouter.ai/api/v1";
    is_non_interactive = false };
]

let info_of_prefix (prefix : string) : provider_info option =
  List.find_opt (fun p -> p.id = prefix) provider_registry

(* --- Model string parsing --- *)

let parse_model_string (s : string) : string * string =
  match String.split_on_char ':' s with
  | prefix :: rest -> (prefix, String.concat ":" rest)
  | _ -> (s, s)

(* --- TOML emission helpers --- *)

let quote (s : string) : string =
  Printf.sprintf "\"%s\"" (String.concat "\\\"" (String.split_on_char '"' s))

let emit_string_field (name : string) (value : string) : string =
  Printf.sprintf "%s = %s\n" name (quote value)

let emit_int_field (name : string) (value : int) : string =
  Printf.sprintf "%s = %d\n" name value

let emit_bool_field (name : string) (value : bool) : string =
  Printf.sprintf "%s = %s\n" name (if value then "true" else "false")

let emit_string_list (name : string) (items : string list) : string =
  let formatted = List.map quote items in
  Printf.sprintf "%s = [%s]\n" name (String.concat ", " formatted)

let emit_section (title : string) : string =
  Printf.sprintf "\n[%s]\n" title

(* --- Auto-model detection --- *)

(* "auto" is a provider-level routing sentinel: the provider chooses the
   model at runtime.  It is NOT a real model and must not produce a
   [models.auto] entry, a binding, or a tier strategy. *)
let is_auto_model (api_name : string) : bool =
  String.lowercase_ascii api_name = "auto"

(* --- Unique model ID generation --- *)

let make_model_id (api_name : string) : string =
  let sanitized =
    api_name
    |> String.map (fun c -> match c with '.' | ' ' | '/' | ':' -> '-' | _ -> c)
  in
  if sanitized = "" then "unnamed"
  else sanitized

(* --- Flat TOML reading --- *)

type flat_model_entry = {
  model_string : string;
  supports_tool_choice : bool option;
  weight : int;
}

type flat_profile = {
  name : string;
  models : flat_model_entry list;
  temperature : float option;
  max_tokens : int option;
  thinking_enabled : bool option;
  keeper_assignable : bool;
  fallback_cascade : string option;
  required_capability_profile : string option;
}

let parse_flat_models (toml : Otoml.t) (profile_name : string) :
    flat_model_entry list =
  let models_raw =
    match Otoml.find_opt toml (Otoml.get_array Fun.id) [ "models" ] with
    | Some items ->
      List.filter_map (fun item ->
        match item with
        | Otoml.TomlString s ->
          Some { model_string = s; supports_tool_choice = None; weight = 1 }
        | Otoml.TomlTable fields | Otoml.TomlInlineTable fields ->
          let model_string =
            List.find_map (function
              | "model", Otoml.TomlString s -> Some s
              | _ -> None) fields
            |> function Some s -> s | None -> ""
          in
          let supports_tool_choice =
            List.find_map (function
              | "supports_tool_choice", Otoml.TomlBoolean b -> Some b
              | _ -> None) fields
          in
          let weight =
            List.find_map (function
              | "weight", Otoml.TomlInteger i -> Some i
              | _ -> None) fields
            |> function Some w -> w | None -> 1
          in
          if model_string <> "" then
            Some { model_string; supports_tool_choice; weight }
          else None
        | _ -> None
      ) items
    | None -> []
  in
  models_raw

let parse_flat_profile (name : string) (tbl : Otoml.t) : flat_profile =
  let models = parse_flat_models tbl name in
  let temperature = Otoml.find_opt tbl Otoml.get_float [ "temperature" ] in
  let max_tokens = Otoml.find_opt tbl Otoml.get_integer [ "max_tokens" ] in
  let thinking_enabled =
    Otoml.find_opt tbl Otoml.get_boolean [ "thinking_enabled" ]
  in
  let keeper_assignable =
    Otoml.find_or ~default:false tbl Otoml.get_boolean [ "keeper_assignable" ]
  in
  let fallback_cascade =
    Otoml.find_opt tbl Otoml.get_string [ "fallback_cascade" ]
  in
  let required_capability_profile =
    Otoml.find_opt tbl Otoml.get_string [ "required_capability_profile" ]
  in
  { name; models; temperature; max_tokens; thinking_enabled;
    keeper_assignable; fallback_cascade; required_capability_profile }

let parse_routes_table (toml : Otoml.t) : (string * string) list =
  match Otoml.find_opt toml Fun.id [ "routes" ] with
  | None -> []
  | Some routes_tbl ->
    let entries = Otoml.get_table routes_tbl in
    List.filter_map (fun (name, value) ->
      match value with
      | Otoml.TomlString target -> Some (name, target)
      | _ -> None
    ) entries

(* --- Conversion logic --- *)

type conversion_result = {
  providers : (string * provider_info) list;
  models : (string * string * string) list;
  bindings : (string * string) list;
  profiles : flat_profile list;
  routes : (string * string) list;
}

let convert (toml : Otoml.t) : conversion_result =
  let top_entries = Otoml.get_table toml in
  let reserved = [ "routes"; "profiles"; "comment" ] in
  let profiles =
    List.filter_map (fun (name, value) ->
      if List.mem name reserved then None
      else
        let tbl =
          match value with
          | Otoml.TomlTable fields -> Otoml.TomlTable fields
          | Otoml.TomlInlineTable fields -> Otoml.TomlInlineTable fields
          | _ -> value
        in
        Some (parse_flat_profile name tbl)
    ) top_entries
  in
  let provider_set = Hashtbl.create 16 in
  let model_set = Hashtbl.create 32 in
  let bindings = ref [] in
  List.iter (fun (p : flat_profile) ->
    List.iter (fun (m : flat_model_entry) ->
      let prefix, api_name = parse_model_string m.model_string in
      if not (Hashtbl.mem provider_set prefix) then
        (match info_of_prefix prefix with
         | Some info -> Hashtbl.add provider_set prefix info
         | None ->
           Hashtbl.add provider_set prefix
             { id = prefix; protocol = "openai-http";
               transport_kind = `Http "https://unknown";
               is_non_interactive = false });
      (* "auto" is a provider routing sentinel, not a real model.
         Skip model and binding creation; tier members keep the
         original "prefix:auto" string. *)
      if not (is_auto_model api_name) then begin
        let model_key = make_model_id api_name in
        if not (Hashtbl.mem model_set model_key) then
          Hashtbl.add model_set model_key (api_name, prefix);
        bindings := (prefix, model_key) :: !bindings
      end
    ) p.models
  ) profiles;
  let providers =
    Hashtbl.fold (fun k v acc -> (k, v) :: acc) provider_set []
    |> List.sort (fun (a, _) (b, _) -> String.compare a b)
  in
  let models =
    Hashtbl.fold (fun k (api, prefix) acc -> (k, api, prefix) :: acc)
      model_set []
    |> List.sort (fun (a, _, _) (b, _, _) -> String.compare a b)
  in
  let routes = parse_routes_table toml in
  { providers; models;
    bindings = List.sort_uniq compare (List.rev !bindings);
    profiles; routes }

(* --- TOML emission --- *)

let emit_providers (providers : (string * provider_info) list) : string =
  let buf = Buffer.create 2048 in
  Buffer.add_string buf "## ── Layer 1: Providers ──────────────────────────────────────────\n";
  List.iter (fun (_prefix, info) ->
    Buffer.add_string buf (emit_section ("providers." ^ info.id));
    Buffer.add_string buf (emit_string_field "protocol" info.protocol);
    (match info.transport_kind with
     | `Cli cmd ->
       Buffer.add_string buf (emit_string_field "command" cmd);
       if info.is_non_interactive then
         Buffer.add_string buf (emit_bool_field "is-non-interactive" true)
     | `Http url ->
       Buffer.add_string buf (emit_string_field "endpoint" url));
  ) providers;
  Buffer.contents buf

let emit_models (models : (string * string * string) list) : string =
  let buf = Buffer.create 2048 in
  Buffer.add_string buf "\n## ── Layer 2: Models ────────────────────────────────────────────\n";
  List.iter (fun (key, api_name, _prefix) ->
    Buffer.add_string buf (emit_section ("models." ^ key));
    Buffer.add_string buf (emit_string_field "api-name" api_name);
    Buffer.add_string buf (emit_int_field "max-context" 128000);
    Buffer.add_string buf (emit_bool_field "tools-support" true)
  ) models;
  Buffer.contents buf

let emit_bindings (bindings : (string * string) list) : string =
  let buf = Buffer.create 2048 in
  Buffer.add_string buf "\n## ── Layer 3: Provider×Model Bindings ───────────────────────────\n";
  let first_for_provider = Hashtbl.create 16 in
  List.iter (fun (provider_id, model_key) ->
    let section = Printf.sprintf "%s.%s" provider_id model_key in
    Buffer.add_string buf (emit_section section);
    let is_first =
      if not (Hashtbl.mem first_for_provider provider_id) then
        (Hashtbl.add first_for_provider provider_id true; true)
      else false
    in
    if is_first then
      Buffer.add_string buf (emit_bool_field "is-default" true)
  ) bindings;
  Buffer.contents buf

let emit_tiers (profiles : flat_profile list) : string =
  let buf = Buffer.create 4096 in
  Buffer.add_string buf "\n## ── Layer 5: Tiers ──────────────────────────────────────────────\n";
  List.iter (fun (p : flat_profile) ->
    let members =
      List.map (fun (m : flat_model_entry) ->
        let prefix, api_name = parse_model_string m.model_string in
        if is_auto_model api_name then
          (* "auto" — no model entry, keep original "prefix:auto" *)
          Printf.sprintf "%s:auto" prefix
        else
          let model_key = make_model_id api_name in
          Printf.sprintf "%s.%s" prefix model_key
      ) p.models
    in
    Buffer.add_string buf (emit_section ("tier." ^ p.name));
    Buffer.add_string buf (emit_string_list "members" members);
    Buffer.add_string buf (emit_string_field "strategy" "failover");
    (match p.max_tokens with
     | Some mt -> Buffer.add_string buf (emit_int_field "max-concurrent" (max 1 (mt / 1000)))
     | None -> ())
  ) profiles;
  Buffer.contents buf

let emit_tier_groups (profiles : flat_profile list) : string =
  let buf = Buffer.create 2048 in
  let groups_with_fallback =
    List.filter_map (fun (p : flat_profile) ->
      match p.fallback_cascade with
      | Some fb -> Some (p.name, fb)
      | None -> None
    ) profiles
  in
  if groups_with_fallback <> [] then begin
    Buffer.add_string buf "\n## ── Layer 5b: Tier-Groups (fallback chains) ────────────────────\n";
    List.iter (fun (name, fallback) ->
      let group_name = Printf.sprintf "%s-with-%s" name fallback in
      Buffer.add_string buf (emit_section ("tier-group." ^ group_name));
      Buffer.add_string buf (emit_string_list "tiers"
        [ name; fallback ]);
      Buffer.add_string buf (emit_string_field "strategy" "priority_tier");
      Buffer.add_string buf (emit_bool_field "fallback" true)
    ) groups_with_fallback
  end;
  Buffer.contents buf

let emit_routes (routes : (string * string) list)
    (profiles : flat_profile list) : string =
  let buf = Buffer.create 2048 in
  if routes <> [] then begin
    Buffer.add_string buf "\n## ── Routes ──────────────────────────────────────────────────────\n";
    List.iter (fun (name, target) ->
      let is_profile =
        List.exists (fun (p : flat_profile) -> p.name = target) profiles
      in
      let resolved =
        if is_profile then "tier." ^ target else target
      in
      Buffer.add_string buf (emit_section ("routes." ^ name));
      Buffer.add_string buf (emit_string_field "target" resolved)
    ) routes
  end;
  Buffer.contents buf

let emit_header () : string =
  "## Declarative cascade configuration (RFC-0058 v2 5-layer schema).\n\
   ## Auto-generated by cascade_flat_to_declarative from flat-format TOML.\n\
   ## Do not edit the structure — regenerate from flat source if needed.\n"

let convert_and_emit (toml : Otoml.t) : string =
  let result = convert toml in
  let buf = Buffer.create 8192 in
  Buffer.add_string buf (emit_header ());
  Buffer.add_string buf (emit_providers result.providers);
  Buffer.add_string buf (emit_models result.models);
  Buffer.add_string buf (emit_bindings result.bindings);
  Buffer.add_string buf (emit_tiers result.profiles);
  Buffer.add_string buf (emit_tier_groups result.profiles);
  Buffer.add_string buf (emit_routes result.routes result.profiles);
  Buffer.contents buf
