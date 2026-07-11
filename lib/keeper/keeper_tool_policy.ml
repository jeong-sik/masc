(** Keeper_tool_policy — keeper tool surface and denylist resolution.

    Tool access is descriptor/registry driven with denylist filtering only.
    Policy group classification and config-driven groups have been removed.

    Consumes [Keeper_tool_registry] for candidate aggregation and core tools.
    Produces the access-policy types and functions used by the dispatch layer. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_alerting

open Keeper_tool_registry

(* -- E6: .masc/ write protection whitelist ----------------------------- *)
(* Keeper-writable path prefixes.  Everything else is structurally
   blocked (Absence > Prohibition). Trust input data (reputation, economy,
   stress, tasks) must NOT be in writable paths.
   Phase B2 / Plan Part 2.5 Axis 4. *)

let keeper_writable_prefixes = [
  Playground_paths.all_playgrounds_prefix ^ "/";  (* playground workspace *)
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
    String.starts_with path ~prefix
  ) keeper_writable_prefixes

(* -- Policy group resolution removed ----------------------------- *)
(* Config-driven policy groups (tool_policy.toml) have been deleted.
   Tool access is now descriptor/registry driven with denylist filtering.
   See keeper_tool_policy_config removal PR. *)

let dedupe_tool_schemas (schemas : Masc_domain.tool_schema list) =
  let seen = Hashtbl.create (max 16 (List.length schemas)) in
  List.filter
    (fun (schema : Masc_domain.tool_schema) ->
      if Hashtbl.mem seen schema.name then
        false
      else (
        Hashtbl.replace seen schema.name ();
        true))
    schemas

let is_keeper_model_board_route name =
  match Tool_name.Board_name.of_string name with
  | None -> true
  | Some board_name ->
    (match Keeper_tool_name.board_projection_of_masc_board_name board_name with
     | Keeper_tool_name.Direct_masc -> true
     | Keeper_tool_name.Keeper_wrapper _ | Keeper_tool_name.External_only -> false)
;;

(* ── Schema injection filter ──────────────────────────────────── *)

let keeper_safe_inline_tools () =
  Keeper_tool_descriptor.keeper_safe_inline_names ()

let is_keeper_safe_inline_tool name =
  List.mem name (keeper_safe_inline_tools ())

let is_keeper_mcp_context_required name =
  let stripped = Keeper_tool_alias.strip_mcp_masc_prefix name in
  not (is_keeper_safe_inline_tool stripped)
  && Keeper_tool_descriptor_resolution.capability_has
       Tool_capability.Mcp_context_required
       name

let keeper_supported_keeper_masc_tools =
  [ "masc_keeper_list"
  ; "masc_keeper_status"
  ; "masc_keeper_msg"
  ; "masc_keeper_msg_result"
  ; "masc_keeper_msg_cancel"
  ; "masc_keeper_msg_queue"
  ]

let keeper_supported_masc_schemas (schemas : Masc_domain.tool_schema list) =
  (* #19797 follow-up: keeper-management-tool identification is keeper-owned,
     not derived from a [Tool_dispatch] tag. Membership in
     [Keeper_types_profile.schemas] is the SSOT registration set that
     [Keeper_tool_surface] registers from — an exact name match, NOT a
     "masc_keeper_" prefix classifier (CLAUDE.md workaround signature #2).
     Sourced from the low-level types module (already open) rather than
     [Keeper_tool_surface] to avoid a module dependency cycle. These tools
     are MCP-client-only except the read/msg subset safe keeper-to-keeper. *)
  let is_keeper_management_tool name =
    List.exists
      (fun (s : Masc_domain.tool_schema) -> String.equal s.name name)
      Keeper_types_profile.schemas
  in
  let is_descriptor_backed_tool name =
    match Keeper_tool_descriptor.descriptors_for_internal name with
    | _ :: _ -> true
    | [] -> false
  in
  let supported_in_keeper name =
    if is_keeper_safe_inline_tool name then
      true
    else if is_keeper_management_tool name then
      (* Reliable pre-init too: [Keeper_tool_surface.schemas] is a static list,
         independent of tag-registry initialization. Placed before the
         [is_registered]/not-initialized fallbacks so management tools are
         never over-exposed during boot. *)
      List.mem name keeper_supported_keeper_masc_tools
    else if is_descriptor_backed_tool name then
      (* Descriptor-backed in-process tools are dispatched by
         Keeper_tool_runtime, not the legacy Tool_dispatch tag registry.
         Requiring a Tool_dispatch tag here admits a name into
         keeper_allowed_tool_names via descriptor_candidate_tool_names, while
         dropping the schema from keeper_universe_model_tools. OAS then sees a
         ghost tool: keeper_tools_list says it exists, but Agent.run has no
         Tool.t for it. *)
      true
    else if Tool_dispatch.is_registered name then
      true
    else if not (Tool_dispatch.is_tag_registry_initialized ()) then
      true
    else
      (match Tool_dispatch.lookup_tag name with
       (* Privileged / internal surfaces denied from keeper exposure. *)
       | Some Tool_dispatch.Mod_inline
       | Some Tool_dispatch.Mod_compact
       | Some Tool_dispatch.Mod_operator
       | Some Tool_dispatch.Mod_control ->
           false
       (* Keeper-allowed surfaces enumerated explicitly (no [Some _ ->]
          wildcard) so that adding a new [Tool_dispatch.module_tag] variant
          fails to compile here, forcing a deliberate keeper-exposure
          decision (default deny) rather than being silently injected into
          every keeper's schema set and made executable. CLAUDE.md "FSM
          Sparse Match" rule (no catch-all on a security boundary) +
          RFC-0006 (keeper surface) + RFC-0042 (closed-sum discipline). This
          arm set is exactly what the former [Some _ -> true] admitted, so
          runtime behaviour is unchanged. *)
       | Some Tool_dispatch.Mod_plan
       | Some Tool_dispatch.Mod_local_runtime
       | Some Tool_dispatch.Mod_run
       | Some Tool_dispatch.Mod_agent
       | Some Tool_dispatch.Mod_task
       | Some Tool_dispatch.Mod_state
       | Some Tool_dispatch.Mod_agent_timeline
       | Some Tool_dispatch.Mod_schedule
       | Some Tool_dispatch.Mod_misc
       | Some Tool_dispatch.Mod_library
       | Some Tool_dispatch.Mod_recurring
       | Some Tool_dispatch.Mod_external
       | Some Tool_dispatch.Mod_shard
       | Some Tool_dispatch.Mod_keeper_task ->
           true
       | None -> false)
  in
  List.filter (fun (s : Masc_domain.tool_schema) ->
      String.starts_with ~prefix:"masc_" s.name
      && not (is_keeper_mcp_context_required s.name)
      && supported_in_keeper s.name
      && is_keeper_model_board_route s.name)
      schemas

let keeper_supported_masc_tool_names_from_schemas schemas =
  keeper_supported_masc_schemas schemas
  |> List.map (fun (schema : Masc_domain.tool_schema) -> schema.name)
  |> dedupe_tool_names

type descriptor_coverage =
  | Projected
  | Dispatch_only
  | Missing_descriptor
  | Missing_canonical_schema
  | Duplicate_descriptors

let missing_canonical_schema_names descriptors =
  descriptors
  |> List.filter_map (fun (descriptor : Keeper_tool_descriptor.t) ->
    match descriptor.input_schema_source with
    | Keeper_tool_descriptor.Missing_canonical_registry ->
      Some descriptor.internal_name
    | Keeper_tool_descriptor.Descriptor_owned
    | Keeper_tool_descriptor.Canonical_registry -> None)
  |> List.sort_uniq String.compare
;;

let descriptor_coverage_for_internal_name name =
  match Keeper_tool_descriptor.descriptors_for_internal name with
  | [] -> Missing_descriptor
  | [ descriptor ] ->
    (match descriptor.Keeper_tool_descriptor.input_schema_source with
     | Keeper_tool_descriptor.Missing_canonical_registry -> Missing_canonical_schema
     | Keeper_tool_descriptor.Descriptor_owned
     | Keeper_tool_descriptor.Canonical_registry ->
       if List.mem name (Keeper_tool_descriptor.keeper_candidate_names descriptor)
       then Projected
       else Dispatch_only)
  | _ :: _ :: _ -> Duplicate_descriptors
;;

let inject_masc_schemas (schemas : Masc_domain.tool_schema list) =
  let supported = keeper_supported_masc_schemas schemas in
  let projected, missing, missing_schemas, duplicates =
    List.fold_left
      (fun (projected, missing, missing_schemas, duplicates)
           (schema : Masc_domain.tool_schema) ->
         match descriptor_coverage_for_internal_name schema.name with
         | Projected -> schema :: projected, missing, missing_schemas, duplicates
         | Dispatch_only -> projected, missing, missing_schemas, duplicates
         | Missing_descriptor ->
           projected, schema.name :: missing, missing_schemas, duplicates
         | Missing_canonical_schema ->
           projected, missing, schema.name :: missing_schemas, duplicates
         | Duplicate_descriptors ->
           projected, missing, missing_schemas, schema.name :: duplicates)
      ([], [], [], [])
      supported
  in
  let missing = List.sort_uniq String.compare missing in
  let missing_schemas =
    (missing_schemas
     @ missing_canonical_schema_names (Keeper_tool_descriptor.all_descriptors ()))
    |> List.sort_uniq String.compare
  in
  let duplicates = List.sort_uniq String.compare duplicates in
  (match missing, missing_schemas, duplicates with
   | [], [], [] -> ()
   | _, _, _ ->
     Log.Keeper.emit
       Log.Error
       ~keeper_name:"system"
       ~category:Log.Tool
       ~details:
         (`Assoc
            [ "error_kind", `String "invalid_keeper_tool_descriptor_coverage"
            ; "tool_names", Json_util.json_string_list missing
            ; "missing_schema_tool_names", Json_util.json_string_list missing_schemas
            ; "duplicate_tool_names", Json_util.json_string_list duplicates
            ])
       "keeper tool schema projection rejected");
  set_masc_schemas (List.rev projected)

let is_keeper_maintenance_only_tool name =
  List.mem name (Keeper_tool_descriptor.keeper_maintenance_only_names ())

(* ── Candidate aggregation (descriptor-driven) ────────────────── *)

let descriptor_candidate_tool_names () =
  Keeper_tool_descriptor.all_descriptors ()
  |> List.concat_map Keeper_tool_descriptor.keeper_candidate_names
  |> List.filter is_keeper_model_board_route
  |> dedupe_tool_names

let keeper_base_candidate_tool_names () =
  (* Candidate existence is registry/descriptor driven.
     Denylist filtering only; no secondary allowlist layer. *)
  dedupe_tool_names
    ( effective_core_tools ()
    @ descriptor_candidate_tool_names ()
    )
  |> List.filter is_keeper_model_board_route
  |> List.filter (fun name -> not (is_keeper_maintenance_only_tool name))

module StringSet = Set_util.StringSet

(* ── Access lookup (O(1) per tool) ────────────────────────────── *)

type tool_access_lookup = {
  candidate_names : string list;
  candidate_set : StringSet.t;
  allow_set : StringSet.t;
  deny_set : StringSet.t;
}

let tool_name_set names =
  List.fold_left (fun acc name -> StringSet.add name acc) StringSet.empty names

let expand_descriptor_aliases name =
  let stripped = Keeper_tool_alias.strip_mcp_masc_prefix name in
  let canonical =
    match Keeper_tool_descriptor_resolution.canonical_internal_name_for_tool_name stripped with
    | Some internal_name -> internal_name
    | None -> stripped
  in
  [ name; stripped; canonical ]
  @ Keeper_tool_descriptor_resolution.public_names_for_internal canonical
  |> dedupe_tool_names

let expanded_tool_name_set names =
  names |> List.concat_map expand_descriptor_aliases |> tool_name_set

let tool_access_lookup_of_meta (meta : keeper_meta) =
  (* [allow_set] is retained for compatibility/telemetry consumers that still
     inspect the field. Runtime execution uses candidate_set - deny_set so
     empty or narrow [tool_access] cannot hide descriptor-backed board/voice
     tools. *)
  let base = keeper_base_candidate_tool_names () in
  let candidate_names = dedupe_tool_names base in
  let candidate_set = tool_name_set candidate_names in
  let deny_set = expanded_tool_name_set meta.tool_denylist in
  let allow_names =
    if meta.tool_access = [] then
      candidate_names
    else
      meta.tool_access
      |> List.filter (fun name -> StringSet.mem name candidate_set)
      |> List.filter (fun name -> not (StringSet.mem name deny_set))
      |> dedupe_tool_names
  in
  {
    candidate_names;
    candidate_set;
    allow_set = tool_name_set allow_names;
    deny_set;
  }

(** Candidate reachability: a tool is reachable iff it is a registered
    candidate and not denied. Per-keeper [tool_access]/allow does NOT gate
    execution at runtime — only the denylist bites. This is the single reach
    predicate; the former [filter_by_access] was a byte-identical alias and
    was removed. Core tools and BM25-discovered tools use this gate. *)
let filter_by_universe ~(lookup : tool_access_lookup) (name : string) : bool =
  StringSet.mem name lookup.candidate_set
  && not (StringSet.mem name lookup.deny_set)

(** Execution gate: core tools bypass candidate_set; all other tools must be
    registered candidates and not denied.
    All tools must exist in candidate_set — rejects hallucinated tool names. *)
let can_execute ~(lookup : tool_access_lookup) (name : string) : bool =
  if not (is_keeper_model_board_route name) then
    false
  else if Keeper_tool_registry.is_core_always_tool name then
    (* Core tools bypass candidate_set — only deny_set blocks them *)
    not (StringSet.mem name lookup.deny_set)
  else if not (StringSet.mem name lookup.candidate_set) then
    false
  else
    filter_by_universe ~lookup name

(* ── Public query functions ───────────────────────────────────── *)

let keeper_masc_tool_names (meta : keeper_meta) : string list =
  let lookup = tool_access_lookup_of_meta meta in
  masc_schemas_snapshot ()
  |> List.filter_map (fun (schema : Masc_domain.tool_schema) ->
    if filter_by_universe ~lookup schema.name
    then Some schema.name
    else None)

(* ── Layer 2: Universe (all executable tools, policy-independent) ── *)

(** Universe masc_* schemas: candidate minus denied, no policy filter.
    Used by make_tools to build Tool.t for BM25 retrieval scope. *)
let keeper_universe_masc_tool_schemas (meta : keeper_meta) : Masc_domain.tool_schema list =
  let lookup = tool_access_lookup_of_meta meta in
  masc_schemas_snapshot ()
  |> List.filter (fun (schema : Masc_domain.tool_schema) ->
    filter_by_universe ~lookup schema.name)

(** Recovery minimum tools: non-removable shards only.
    Used in Failing phase to guarantee minimum tool availability.
    Phase B2: TLA+ RecoveryFloorMaintained invariant.

    INTENTIONAL: this bypasses the normal access/deny filtering.
    In Failing phase the keeper must retain a guaranteed floor of tools
    regardless of custom allowlist, deny-list, or policy config.  The floor is
    determined solely by shard removability (structural, not policy). *)
(** Essential tools always available in Failing recovery,
    on top of [removable=false] shard floor. Mirrors [masc.essential]
    hardcoded in this module. Sync regression: any drift is caught by
    [test_failing_minimum_essential.ml].

    Rationale (board P1, 9 keepers × 0 claimable web search):
    a Failing keeper still needs to check workspace state, look up
    information for recovery, and defer to operator approval. Removing
    these from the recovery floor caused task contracts that require
    web search to become unclaimable when any keeper entered
    decision_layer >= 2.

    Note: WebSearch / WebFetch are the public_names used by the keeper
    agent; masc_web_search / masc_web_fetch are keeper-internal and
    are not exposed as operator MCP tool calls. *)
let essential_masc_minimum_names : string list = [
  "masc_status";
  "WebSearch";
  "WebFetch";
]

let failing_minimum_tool_names () : string list =
  let shard_floor =
    Tool_shard.recovery_minimum_shard_names ()
    |> Tool_shard.tools_of_shards
    |> List.map (fun (t : Masc_domain.tool_schema) -> t.Masc_domain.name)
  in
  shard_floor @ essential_masc_minimum_names
  |> List.filter is_keeper_model_board_route
  |> List.sort_uniq String.compare

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
    |> List.filter (fun name -> filter_by_universe ~lookup name)
    |> dedupe_tool_names

(** Universe tool names: candidates minus denied, no policy filter. Equal to
    [keeper_allowed_tool_names] in the Running phase (both are candidate − deny);
    they diverge only via allowed's write_done/Failing guards. BM25 indexes this
    set for progressive disclosure. The explicit [from_core] union is a defensive
    floor: it is currently subsumed by [from_candidates] (core_always ⊆
    effective_core_tools ⊆ candidate_names), kept only to survive future changes
    to candidate construction. It does NOT guard a masc_schemas startup race —
    core_always_tools is a static list independent of the injected-schema ref. *)
let keeper_universe_tool_names (meta : keeper_meta) : string list =
  let lookup = tool_access_lookup_of_meta meta in
  let from_candidates =
    lookup.candidate_names
    |> List.filter (fun name -> filter_by_universe ~lookup name)
  in
  let from_core =
    Keeper_tool_registry.core_always_tools
    |> List.filter is_keeper_model_board_route
    |> List.filter (fun name -> not (StringSet.mem name lookup.deny_set))
  in
  dedupe_tool_names (from_candidates @ from_core)

(** Search scope for BM25 progressive disclosure. Output-identical to
    [keeper_universe_tool_names] (candidate ∪ core_always, minus denied); kept as
    a named alias for call-site clarity at the search-index boundary. *)
let keeper_tool_search_scope = keeper_universe_tool_names

let descriptor_model_tool_schemas () =
  Keeper_tool_descriptor.model_visible_descriptors ()
  |> List.concat_map (fun (descriptor : Keeper_tool_descriptor.t) ->
    Keeper_tool_descriptor.keeper_model_names descriptor
    |> List.filter is_keeper_model_board_route
    |> List.map (fun name ->
      { Masc_domain.name
      ; description = descriptor.description
      ; input_schema = descriptor.input_schema
      }))
  |> dedupe_tool_schemas

(** The model schema surface is descriptor-only. Shard and injected schemas
    remain handler/schema inputs, but never act as a permissive exposure
    fallback when a descriptor is absent. *)
let all_keeper_schemas () : Masc_domain.tool_schema list =
  descriptor_model_tool_schemas ()

(** Filter schemas by a set of allowed names.  Uses Hashtbl for O(1) lookup
    instead of List.mem (O(n) per schema). *)
let filter_schemas_by_names (names : string list)
    (schemas : Masc_domain.tool_schema list) : Masc_domain.tool_schema list =
  let name_set = tool_name_set names in
  schemas
  |> List.filter (fun (tool : Masc_domain.tool_schema) -> StringSet.mem tool.name name_set)
  |> dedupe_tool_schemas

(** Scoped model tool schemas for BM25 indexing.
    Returns schemas for the active descriptor/registry surface minus denied tools. *)
let keeper_model_tool_schemas (meta : keeper_meta) : Masc_domain.tool_schema list =
  let scoped = keeper_tool_search_scope meta in
  all_keeper_schemas ()
  |> filter_schemas_by_names scoped

(** Universe model tool schemas for make_tools.
    Returns schemas for all universe tools so Agent.run() can call them. *)
let keeper_universe_model_tools (meta : keeper_meta) : Masc_domain.tool_schema list =
  let universe = keeper_universe_tool_names meta in
  all_keeper_schemas ()
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
  let properties = match Json_util.get_object schema "properties" with
  | Some (`Assoc props) -> props
  | _ -> []
  in
  let enums =
    properties
    |> List.filter_map (fun (name, field_schema) ->
      match Json_util.get_array field_schema "enum" with
      | Some (`List values) ->
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
  match Json_util.get_array schema "required" with
  | Some (`List reqs) ->
    let names = List.filter_map (function
      | `String v -> Some v
      | _ -> None
    ) reqs in
    if names = [] then ""
    else "required: " ^ String.concat ", " names
  | _ -> ""

(** Lookup tool description by name from the descriptor-owned model surface.
    Returns [Some first_sentence] + optional enum/required hints if found, [None] otherwise.
    Non-descriptor schemas cannot re-enter the model prompt through hints. *)
let tool_hint_of (name : string) : string option =
  let all_schemas = descriptor_model_tool_schemas () in
  match List.find_opt (fun (s : Masc_domain.tool_schema) -> s.name = name) all_schemas with
  | Some s ->
    let base = first_sentence s.description in
    let enums = enum_hints_of_schema s.Masc_domain.input_schema in
    let required = required_hints_of_schema s.Masc_domain.input_schema in
    let parts = ref [base] in
    if enums <> "" then parts := !parts @ ["[" ^ enums ^ "]"];
    if required <> "" then parts := !parts @ [required];
    Some (String.concat " " !parts)
  | None -> None
