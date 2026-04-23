(** Keeper_tool_policy — tool access control, presets, and allowed-tool resolution.

    Preset definitions are loaded from [config/tool_policy.toml] at startup
    via {!Keeper_tool_policy_config}.  See that module for the config format.

    Consumes [Keeper_tool_registry] for candidate aggregation and core tools.
    Produces the access-policy types and functions used by the dispatch layer. *)

open Keeper_types
open Keeper_alerting
open Keeper_tool_registry

(* -- E6: .masc/ write protection whitelist ----------------------------- *)
(* Keeper-writable path prefixes.  Everything else is structurally
   blocked (Absence > Prohibition). Trust input data (reputation, economy,
   stress, tasks) must NOT be in writable paths.
   Phase B2 / Plan Part 2.5 Axis 4. *)

let keeper_writable_prefixes = [
  Playground_paths.all_playgrounds_prefix ^ "/";  (* coding workspace *)
  ".masc/decision_audit/";   (* self audit logs — forensics, not trust input *)
  ".worktrees/";             (* git worktree workspace — repo-root, not .masc/ *)
]

(** Collapse [.] and [..] segments in a path to prevent traversal bypasses
    such as [.masc/playground/../reputation/].
    Does not resolve symlinks — pure lexical normalisation. *)
let normalize_path path =
  let segments = String.split_on_char '/' path in
  let rec collapse acc = function
    | [] -> List.rev acc
    | "." :: rest -> collapse acc rest
    | ".." :: rest ->
      (match acc with
       | [] -> collapse [] rest   (* already at root — drop *)
       | _ :: tl -> collapse tl rest)
    | seg :: rest -> collapse (seg :: acc) rest
  in
  let collapsed = collapse [] segments in
  String.concat "/" collapsed

let is_masc_write_allowed path =
  let path = normalize_path path in
  List.exists (fun prefix ->
    String.length path >= String.length prefix
    && String.sub path 0 (String.length prefix) = prefix
  ) keeper_writable_prefixes

(* -- Config-driven preset resolution -------------------------------- *)

(* Loaded by init_policy_config at server startup.
   None = config not yet loaded (init_policy_config not yet called). *)
let policy_config : Keeper_tool_policy_config.t option ref = ref None

let policy_config_for_validation () = !policy_config

let init_policy_config ~base_path =
  match Keeper_tool_policy_config.load ~base_path with
  | Ok cfg ->
    policy_config := Some cfg;
    Log.Keeper.info "tool policy config loaded: %d presets, %d groups"
      (List.length (Keeper_tool_policy_config.preset_names cfg))
      (List.length (Keeper_tool_policy_config.group_names cfg));
    Ok ()
  | Error msg ->
    Error msg

let preset_name_of_tool_preset = function
  | Minimal -> "minimal"
  | Social -> "social"
  | Messaging -> "messaging"
  | Dispatch -> "dispatch"
  | Coding -> "coding"
  | Research -> "research"
  | Delivery -> "delivery"
  | Full -> "full"

(* ── Privileged operation gates ------------------------------------ *)

let preset_allows_privileged_operations = function
  | Coding | Delivery | Full -> true
  | Minimal | Social | Messaging | Research -> false

let allows_workflow_for_preset (preset : tool_preset) : bool =
  preset_allows_privileged_operations preset

let allows_shell_write_for_preset (preset : tool_preset) : bool =
  preset_allows_privileged_operations preset

(* ── Git clone config accessors (config-driven) ──────────────── *)

let git_clone_allowed_orgs () : string list =
  match !policy_config with
  | None -> []
  | Some cfg -> Keeper_tool_policy_config.git_clone_allowed_orgs cfg

let git_clone_denied_repos () : string list =
  match !policy_config with
  | None -> []
  | Some cfg -> Keeper_tool_policy_config.git_clone_denied_repos cfg

let clone_depth () : int =
  match !policy_config with
  | None -> 0
  | Some cfg -> Keeper_tool_policy_config.clone_depth cfg

let clone_timeout_sec () : float =
  match !policy_config with
  | None -> 120.0
  | Some cfg -> Keeper_tool_policy_config.clone_timeout_sec cfg

let push_timeout_sec () : float =
  match !policy_config with
  | None -> 60.0
  | Some cfg -> Keeper_tool_policy_config.push_timeout_sec cfg

let pr_create_timeout_sec () : float =
  match !policy_config with
  | None -> 30.0
  | Some cfg -> Keeper_tool_policy_config.pr_create_timeout_sec cfg

(* ── GH cache config accessors (config-driven) ─────────────── *)

let gh_cache_ttl_sec () : float =
  match !policy_config with
  | None -> 120.0
  | Some cfg -> Keeper_tool_policy_config.gh_cache_ttl_sec cfg

let gh_cache_fetch_page_size () : int =
  match !policy_config with
  | None -> 100
  | Some cfg -> Keeper_tool_policy_config.gh_cache_fetch_page_size cfg

let gh_cache_fetch_timeout_sec () : float =
  match !policy_config with
  | None -> 10.0
  | Some cfg -> Keeper_tool_policy_config.gh_cache_fetch_timeout_sec cfg

let gh_cache_max_alternatives () : int =
  match !policy_config with
  | None -> 20
  | Some cfg -> Keeper_tool_policy_config.gh_cache_max_alternatives cfg

let gh_cache_max_output_bytes () : int =
  match !policy_config with
  | None -> 8192
  | Some cfg -> Keeper_tool_policy_config.gh_cache_max_output_bytes cfg

(* ── Preset subsumption (config-driven) ──────────────────────── *)

let preset_can_satisfy ~(agent_preset : string) ~(required_preset : string) : bool =
  match !policy_config with
  | None -> false
  | Some cfg ->
    Keeper_tool_policy_config.preset_can_satisfy cfg ~agent_preset ~required_preset

(** Return configured preset names (excluding "full") for schema enum generation. *)
let configured_preset_names () : string list =
  match !policy_config with
  | None -> []
  | Some cfg ->
    Keeper_tool_policy_config.preset_names cfg
    |> List.filter (fun n -> not (String.equal n "full"))

(* ── Denied-tool set (O(1) lookup) ────────────────────────────── *)

let keeper_denied_set : (string, unit) Hashtbl.t =
  let tbl = Hashtbl.create 32 in
  List.iter (fun name -> Hashtbl.replace tbl name ())
    (Tool_catalog.tools_for_surface Tool_catalog.Keeper_denied);
  tbl

let dedupe_tool_schemas (schemas : Types.tool_schema list) =
  let seen = Hashtbl.create (max 16 (List.length schemas)) in
  List.filter
    (fun (schema : Types.tool_schema) ->
      if Hashtbl.mem seen schema.name then
        false
      else (
        Hashtbl.replace seen schema.name ();
        true))
    schemas

let is_keeper_denied (name : string) : bool =
  Hashtbl.mem keeper_denied_set name

(* ── Schema injection filter ──────────────────────────────────── *)

let keeper_mcp_context_required_tools =
  Tool_schemas_inline.schemas
  |> List.map (fun (schema : Types.tool_schema) -> schema.name)

let is_keeper_mcp_context_required name =
  List.mem name keeper_mcp_context_required_tools
  || Tool_dispatch.is_mcp_context_required name

let keeper_supported_keeper_masc_tools =
  [ "masc_keeper_list"
  ; "masc_keeper_status"
  ; "masc_keeper_msg"
  ; "masc_keeper_msg_result"
  ]

let keeper_supported_masc_schemas (schemas : Types.tool_schema list) =
  let supported_in_keeper name =
    if Tool_dispatch.is_registered name then
      true
    else if not (Tool_dispatch.is_tag_registry_initialized ()) then
      true
    else
      match Tool_dispatch.lookup_tag name with
      | Some Tool_dispatch.Mod_inline
      | Some Tool_dispatch.Mod_compact
      | Some Tool_dispatch.Mod_operator
      | Some Tool_dispatch.Mod_control ->
          false
      | Some Tool_dispatch.Mod_keeper ->
          List.mem name keeper_supported_keeper_masc_tools
      | Some _ -> true
      | None -> false
  in
  (* masc_board_* tools that have keeper_board_* wrappers with auto-injected
     author/voter fields. Exposing both leads to the LLM calling the raw
     masc_* variant without the required author, causing "author is required". *)
  let has_keeper_board_wrapper name =
    let eq v = String.equal name (Tool_name.Masc.to_string v) in
    eq Tool_name.Masc.Board_comment
    || eq Tool_name.Masc.Board_post
    || eq Tool_name.Masc.Board_vote
    || eq Tool_name.Masc.Board_delete
  in
  List.filter (fun (s : Types.tool_schema) ->
      String.starts_with ~prefix:"masc_" s.name
      && not (is_keeper_mcp_context_required s.name)
      && supported_in_keeper s.name
      && not (is_keeper_denied s.name)
      && not (has_keeper_board_wrapper s.name))
      schemas

let keeper_supported_masc_tool_names_from_schemas schemas =
  keeper_supported_masc_schemas schemas
  |> List.map (fun (schema : Types.tool_schema) -> schema.name)
  |> dedupe_tool_names

let inject_masc_schemas (schemas : Types.tool_schema list) =
  masc_schemas_ref := keeper_supported_masc_schemas schemas

let select_existing_masc_tool_names names =
  let injected = injected_masc_tool_names () in
  names
  |> List.filter (fun name -> List.mem name injected)
  |> dedupe_tool_names

let keeper_maintenance_only_tools =
  [ "masc_heartbeat" ]

let is_keeper_maintenance_only_tool name =
  List.mem name keeper_maintenance_only_tools

(* ── Candidate aggregation (config-driven) ────────────────────── *)

let keeper_base_candidate_tool_names () =
  let config_tools =
    match !policy_config with
    | None -> []
    | Some cfg -> Keeper_tool_policy_config.all_group_tools cfg
  in
  dedupe_tool_names
    ( config_tools
    @ keeper_internal_candidate_tool_names
    @ injected_masc_tool_names () )
  |> List.filter (fun name -> not (is_keeper_maintenance_only_tool name))

(** Resolve a named group from tool_policy.toml.  Returns the hardcoded
    fallback when config is not loaded. *)
let resolve_policy_group ~(fallback : string list) (group_name : string) : string list =
  match !policy_config with
  | Some cfg ->
    (match Keeper_tool_policy_config.resolve_group cfg group_name with
     | Some tools -> dedupe_tool_names tools
     | None ->
       Log.Keeper.warn "tool_policy group %S not found, using fallback (%d tools)"
         group_name (List.length fallback);
       fallback)
  | None -> fallback

(** Optional tools that require explicit opt-in via also_allow.
    Reads [groups.optional] from tool_policy.toml; falls back to
    hardcoded list when config is absent. *)
let keeper_optional_tool_names () =
  resolve_policy_group ~fallback:[ "keeper_board_delete" ] "optional"

(** Tools allowed on the keeper's last turn.
    Reads [groups.last_turn_safe] from tool_policy.toml. *)
let last_turn_safe_tool_names () =
  resolve_policy_group
    ~fallback:[ "keeper_board_post"; "keeper_board_comment";
                "keeper_context_status"; "extend_turns";
                "keeper_time_now"; "keeper_broadcast" ]
    "last_turn_safe"

let explicit_optional_candidate_tool_names (meta : keeper_meta) =
  let requested =
    match meta.tool_access with
    | Preset { also_allow; _ } -> also_allow
    | Custom allowlist -> allowlist
  in
  let optional = keeper_optional_tool_names () in
  requested
  |> List.filter (fun name -> List.mem name optional)
  |> dedupe_tool_names

(* ── Presets (config-driven) ───────────────────────────────────── *)

let preset_allowlist preset =
  let name = preset_name_of_tool_preset preset in
  match !policy_config with
  | None ->
    Log.Keeper.error
      "tool policy config not loaded; preset '%s' returns empty. \
       Call init_policy_config at startup." name;
    []
  | Some cfg ->
    let injected = injected_masc_tool_names () in
    let injected_lookup = Hashtbl.create (List.length injected) in
    List.iter (fun n -> Hashtbl.replace injected_lookup n ()) injected;
    let masc_filter tool_name = Hashtbl.mem injected_lookup tool_name in
    match Keeper_tool_policy_config.resolve_preset cfg name ~masc_filter () with
    | Some Keeper_tool_policy_config.All_candidates ->
      (* all_candidates = true: return full candidate set *)
      keeper_base_candidate_tool_names ()
    | Some (Keeper_tool_policy_config.Subset tools) -> dedupe_tool_names tools
    | None ->
      Log.Keeper.warn "preset '%s' not defined in config/tool_policy.toml, returning empty" name;
      []

let tool_policy_of_meta (meta : keeper_meta) =
  let allow =
    match meta.tool_access with
    | Preset { preset; also_allow } ->
        Tool_access_policy.Names (preset_allowlist preset @ also_allow)
    | Custom allowlist ->
        Tool_access_policy.Names allowlist
  in
  {
    Tool_access_policy.allow;
    deny = Tool_access_policy.Names meta.tool_denylist;
  }

module StringSet = Set.Make (String)

(* ── Access lookup (O(1) per tool) ────────────────────────────── *)

type tool_access_lookup = {
  candidate_names : string list;
  candidate_set : StringSet.t;
  allow_set : StringSet.t;
  deny_set : StringSet.t;
}

let tool_name_set names =
  List.fold_left (fun acc name -> StringSet.add name acc) StringSet.empty names

let tool_access_lookup_of_meta (meta : keeper_meta) =
  let candidate_names =
    dedupe_tool_names
      (keeper_base_candidate_tool_names () @ explicit_optional_candidate_tool_names meta)
  in
  let candidate_set = tool_name_set candidate_names in
  let allow_names =
    Tool_access_policy.resolve
      ~candidates:candidate_names
      (tool_policy_of_meta meta)
    |> List.filter (fun name -> StringSet.mem name candidate_set)
    |> dedupe_tool_names
  in
  {
    candidate_names;
    candidate_set;
    allow_set = tool_name_set allow_names;
    deny_set = tool_name_set meta.tool_denylist;
  }

let filter_by_access ~(lookup : tool_access_lookup) (name : string) : bool =
  StringSet.mem name lookup.candidate_set
  && StringSet.mem name lookup.allow_set
  && not (StringSet.mem name lookup.deny_set)

(** Universe check: candidate minus denied, ignoring policy allowlist.
    Core tools and BM25-discovered tools use this gate at execution time. *)
let filter_by_universe ~(lookup : tool_access_lookup) (name : string) : bool =
  StringSet.mem name lookup.candidate_set
  && not (StringSet.mem name lookup.deny_set)

(** Execution gate: core tools bypass policy, others require policy allowlist.
    All tools must exist in candidate_set — rejects hallucinated tool names. *)
let can_execute ~(lookup : tool_access_lookup) (name : string) : bool =
  if Keeper_tool_registry.is_core_always_tool name then
    (* Core tools bypass candidate_set — only deny_set blocks them *)
    not (StringSet.mem name lookup.deny_set)
  else if not (StringSet.mem name lookup.candidate_set) then
    false
  else
    filter_by_access ~lookup name

(* ── Public query functions ───────────────────────────────────── *)

let keeper_masc_tool_names (meta : keeper_meta) : string list =
  let lookup = tool_access_lookup_of_meta meta in
  !masc_schemas_ref
  |> List.filter_map (fun (schema : Types.tool_schema) ->
    if filter_by_access ~lookup schema.name
    then Some schema.name
    else None)

let keeper_masc_tool_schemas (meta : keeper_meta) : Types.tool_schema list =
  let lookup = tool_access_lookup_of_meta meta in
  !masc_schemas_ref
  |> List.filter (fun (schema : Types.tool_schema) -> filter_by_access ~lookup schema.name)

(* ── Layer 2: Universe (all executable tools, policy-independent) ── *)

(** Universe masc_* schemas: candidate minus denied, no policy filter.
    Used by make_tools to build Tool.t for BM25 retrieval scope. *)
let keeper_universe_masc_tool_schemas (meta : keeper_meta) : Types.tool_schema list =
  let lookup = tool_access_lookup_of_meta meta in
  !masc_schemas_ref
  |> List.filter (fun (schema : Types.tool_schema) ->
    filter_by_universe ~lookup schema.name)

let keeper_default_model_tools (_meta : keeper_meta) : Types.tool_schema list =
  keeper_model_tools @ keeper_voice_tool_schemas
  @ [ keeper_tool_search_schema ]

(** Recovery minimum tools: non-removable shards only.
    Used in Failing phase to guarantee minimum tool availability.
    Phase B2: TLA+ RecoveryFloorMaintained invariant.

    INTENTIONAL: this bypasses the normal access/deny filtering.
    In Failing phase the keeper must retain a guaranteed floor of tools
    regardless of preset, deny-list, or policy config.  The floor is
    determined solely by shard removability (structural, not policy). *)
let failing_minimum_tool_names () : string list =
  Tool_shard.recovery_minimum_shard_names ()
  |> Tool_shard.tools_of_shards
  |> List.map (fun (t : Types.tool_schema) -> t.Types.name)

let keeper_allowed_tool_names ?(write_done = false)
    ?(phase = Keeper_state_machine.Running) (meta : keeper_meta) :
    string list =
  if write_done then
    []
  else if phase = Keeper_state_machine.Failing
          && Keeper_decision_audit.decision_layer_level () >= 2
  then
    failing_minimum_tool_names ()
  else
    let lookup = tool_access_lookup_of_meta meta in
    lookup.candidate_names
    |> List.filter (fun name -> filter_by_access ~lookup name)
    |> dedupe_tool_names

(** Universe tool names: candidates minus denied, no policy filter.
    Superset of keeper_allowed_tool_names.  BM25 indexes this set so
    progressive disclosure can discover tools beyond the active preset.
    Core tools are always included even if masc_schemas haven't been
    injected yet (startup race) or the tool is not in any preset. *)
let keeper_universe_tool_names (meta : keeper_meta) : string list =
  let lookup = tool_access_lookup_of_meta meta in
  let from_candidates =
    lookup.candidate_names
    |> List.filter (fun name -> filter_by_universe ~lookup name)
  in
  let from_core =
    Keeper_tool_registry.core_always_tools
    |> List.filter (fun name -> not (StringSet.mem name lookup.deny_set))
  in
  dedupe_tool_names (from_candidates @ from_core)

(** Preset-scoped universe: preset allowlist + core_always - denied.
    Strict subset of [keeper_universe_tool_names].  Used for BM25 indexing
    to improve signal-to-noise ratio: a Minimal keeper indexes ~30 tools
    instead of 244+.  Execution gate still uses the full universe so
    externally-granted tools (tool_overlay) remain callable.
    See #4637 (Samchon harness: absence > prohibition). *)
let keeper_preset_universe_tool_names (meta : keeper_meta) : string list =
  let lookup = tool_access_lookup_of_meta meta in
  let preset_tools =
    match meta.tool_access with
    | Preset { preset; also_allow } ->
        preset_allowlist preset @ also_allow
    | Custom allowlist -> allowlist
  in
  let from_preset =
    preset_tools
    |> List.filter (fun name ->
         StringSet.mem name lookup.candidate_set
         && not (StringSet.mem name lookup.deny_set))
  in
  let from_core =
    Keeper_tool_registry.core_always_tools
    |> List.filter (fun name -> not (StringSet.mem name lookup.deny_set))
  in
  dedupe_tool_names (from_preset @ from_core)

(** Shared schema assembly: computes the full tool schema list once.
    [masc_schemas_fn] selects policy-filtered or universe-filtered MASC schemas
    depending on the caller's access scope. *)
let all_keeper_schemas ~(masc_schemas_fn : keeper_meta -> Types.tool_schema list)
    (meta : keeper_meta) : Types.tool_schema list =
  (keeper_default_model_tools meta)
  @ Tool_shard.autoresearch_keeper_tools
  @ Tool_shard.coding_tools
  @ Tool_code_write.schemas
  @ Tool_shard.keeper_preflight_tools
  @ Tool_shard.keeper_pr_review_tools
  @ (masc_schemas_fn meta)

(** Filter schemas by a set of allowed names.  Uses Hashtbl for O(1) lookup
    instead of List.mem (O(n) per schema). *)
let filter_schemas_by_names (names : string list)
    (schemas : Types.tool_schema list) : Types.tool_schema list =
  let name_set = tool_name_set names in
  schemas
  |> List.filter (fun (tool : Types.tool_schema) -> StringSet.mem tool.name name_set)
  |> dedupe_tool_schemas

(** Preset-scoped model tool schemas for BM25 indexing.
    Returns schemas only for the preset-scoped universe. *)
let keeper_preset_universe_model_tools (meta : keeper_meta) : Types.tool_schema list =
  let scoped = keeper_preset_universe_tool_names meta in
  all_keeper_schemas ~masc_schemas_fn:keeper_universe_masc_tool_schemas meta
  |> filter_schemas_by_names scoped

let keeper_allowed_model_tools ?(write_done = false) (meta : keeper_meta) :
    Types.tool_schema list =
  let allowed = keeper_allowed_tool_names ~write_done meta in
  if allowed = [] then
    []
  else
    let result =
      all_keeper_schemas ~masc_schemas_fn:keeper_masc_tool_schemas meta
      |> filter_schemas_by_names allowed
    in
    let count = List.length result in
    if count > Keeper_config.tool_policy_count_warn_threshold then
      Log.Keeper.warn
        "tool policy allows %d schemas (~%dKB). Progressive disclosure \
         limits actual LLM context to ~20-40, but universe build cost scales \
         with policy size. Consider a narrower preset or custom allowlist."
        count (count * 470 / 1024);
    result

(** Universe model tool schemas for make_tools.
    Returns schemas for all universe tools so Agent.run() can call them. *)
let keeper_universe_model_tools (meta : keeper_meta) : Types.tool_schema list =
  let universe = keeper_universe_tool_names meta in
  all_keeper_schemas ~masc_schemas_fn:keeper_universe_masc_tool_schemas meta
  |> filter_schemas_by_names universe

(* ── Tool description lookup (for prompt auto-hints) ─────────── *)

(** Extract the first sentence from a tool description.
    Truncates at the first period followed by space/newline/end, or
    [Keeper_config.tool_first_sentence_max_chars] chars, whichever is shorter. *)
let first_sentence desc =
  let max_len = Keeper_config.tool_first_sentence_max_chars in
  let len = String.length desc in
  let cutoff =
    (* Find first '.' followed by space, newline, or end-of-string *)
    let rec find_stop i =
      if i >= len then len
      else if desc.[i] = '.' then
        if i + 1 >= len then i + 1  (* period at end *)
        else if desc.[i + 1] = ' ' || desc.[i + 1] = '\n' then i + 1
        else find_stop (i + 1)
      else find_stop (i + 1)
    in
    let sentence_end = find_stop 0 in
    min sentence_end max_len
  in
  let s = String.sub desc 0 cutoff in
  if cutoff < len then String.trim s else s

(** Extract enum values from a tool's input_schema.
    Returns a compact string like "op=pwd|ls|cat|rg|git_status" or "" if no enums found. *)
let enum_hints_of_schema (schema : Yojson.Safe.t) : string =
  let module U = Yojson.Safe.Util in
  let properties = match U.member "properties" schema with
  | `Assoc props -> props
  | _ -> []
  in
  let enums =
    properties
    |> List.filter_map (fun (name, field_schema) ->
      match U.member "enum" field_schema with
      | `List values ->
        let vals = List.filter_map (function
          | `String v -> Some v
          | _ -> None
        ) values in
        if vals = [] then None
        else Some (Printf.sprintf "%s=%s" name (String.concat "|" vals))
      | _ -> None)
  in
  String.concat ", " enums

(** Extract required fields from a tool's input_schema.
    Returns a compact string like "required: path, content" or "" if no required fields. *)
let required_hints_of_schema (schema : Yojson.Safe.t) : string =
  let module U = Yojson.Safe.Util in
  match U.member "required" schema with
  | `List reqs ->
    let names = List.filter_map (function
      | `String v -> Some v
      | _ -> None
    ) reqs in
    if names = [] then ""
    else "required: " ^ String.concat ", " names
  | _ -> ""

(** Lookup tool description by name from all available schema sources.
    Returns [Some first_sentence] + optional enum/required hints if found, [None] otherwise.
    Searches shard-resolved tools, inline schemas, injected masc_* schemas,
    code-write schemas, voice tools, and tool_search schema. *)
let tool_hint_of (name : string) : string option =
  let all_schemas =
    Tool_shard.keeper_model_tools
    @ Keeper_tool_registry.keeper_voice_tool_schemas
    @ [ Keeper_tool_registry.keeper_tool_search_schema ]
    @ Tool_schemas_inline.schemas
    @ !masc_schemas_ref
    @ Tool_code_write.schemas
  in
  match List.find_opt (fun (s : Types.tool_schema) -> s.name = name) all_schemas with
  | Some s ->
    let base = first_sentence s.description in
    let enums = enum_hints_of_schema s.Types.input_schema in
    let required = required_hints_of_schema s.Types.input_schema in
    let parts = ref [base] in
    if enums <> "" then parts := !parts @ ["[" ^ enums ^ "]"];
    if required <> "" then parts := !parts @ [required];
    Some (String.concat " " !parts)
  | None -> None
