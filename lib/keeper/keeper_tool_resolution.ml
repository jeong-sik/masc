(** Keeper_tool_resolution — unified policy tool-name resolution.

    RFC-0080 Phase 2. Wraps the existing policy admission sources behind a
    single [resolve] function that returns a typed [resolution].

    Behaviour: preserve the short-circuit order of the current policy
    admission chain. The first source that admits the name determines the
    [tried_source] tag. If none admit, all tried sources are collected in
    [Unknown.tried].

    @since 2.219.0 — RFC-0080 *)

(* ── Types ────────────────────────────────────────────────────────── *)

type tried_source =
  | Dispatch_table              (** S1: Tool_dispatch.is_registered *)
  | Public_descriptor           (** S3: Keeper_tool_descriptor.find_public *)
  | Alias_internal              (** S4: Keeper_tool_alias.is_known_internal *)
  | Registry_internal_candidate (** S5: Keeper_tool_registry.keeper_internal_candidate_tool_names *)
  | Registry_core_tools         (** S6: Keeper_tool_registry.effective_core_tools *)
  | Tool_schema                 (** S7: policy tool-schema inventory name extraction *)
  | Descriptor_registry         (** S7.5: registered names projected by
                                    Keeper_tool_descriptor.all_descriptors *)
  | System_internal             (** S8: Tool_catalog_surfaces.is_system_internal_hidden —
                                    system-internal tools (masc_gc, masc_reset,
                                    masc_cleanup_zombies, …) dispatched via tool_misc and
                                    hidden from keeper surfaces. Real tools, not
                                    stale/hallucinated tokens, so the prompt-token integrity
                                    scanner must not flag or strip them. *)

type resolution =
  | Resolved of { canonical : string ; via : tried_source }
  | Alias_to of { from_ : string ; canonical : string ; via : tried_source }
  | Unknown of { name : string ; tried : tried_source list }

(* ── Helpers ──────────────────────────────────────────────────────── *)

let tool_schema_names schemas =
  List.map (fun (schema : Masc_domain.tool_schema) -> schema.name) schemas

let policy_tool_schemas =
  Tool_shard.all_keeper_tool_schemas @ Tool_schemas_inline.schemas

let string_of_tried_source = function
  | Dispatch_table -> "dispatch_table"
  | Public_descriptor -> "public_descriptor"
  | Alias_internal -> "alias_internal"
  | Registry_internal_candidate -> "registry_internal_candidate"
  | Registry_core_tools -> "registry_core_tools"
  | Tool_schema -> "tool_schema"
  | Descriptor_registry -> "descriptor_registry"
  | System_internal -> "system_internal"

let string_of_tried sources =
  String.concat ", " (List.map string_of_tried_source sources)

(* ── Resolve ──────────────────────────────────────────────────────── *)

let resolve name =
  let normalized = Keeper_tool_alias.strip_mcp_masc_prefix name in
  (* Collect sources in short-circuit order; return on first hit. *)
  if Tool_dispatch.is_registered normalized then
    Resolved { canonical = normalized; via = Dispatch_table }
  else
    match Keeper_tool_descriptor.find_public normalized with
    | Some descriptor ->
      Alias_to
        { from_ = normalized
        ; canonical = descriptor.Keeper_tool_descriptor.internal_name
        ; via = Public_descriptor
        }
    | None ->
      if Keeper_tool_alias.is_known_internal normalized then
        Resolved { canonical = normalized; via = Alias_internal }
      else if
        List.mem normalized Keeper_tool_registry.keeper_internal_candidate_tool_names
      then Resolved { canonical = normalized; via = Registry_internal_candidate }
      else if List.mem normalized (Keeper_tool_registry.effective_core_tools ()) then
        Resolved { canonical = normalized; via = Registry_core_tools }
      else if
        List.mem normalized (tool_schema_names policy_tool_schemas)
      then Resolved { canonical = normalized; via = Tool_schema }
      else if
        List.exists
          (fun (d : Keeper_tool_descriptor.t) ->
             List.mem normalized (Keeper_tool_descriptor.registered_names d))
          (Keeper_tool_descriptor.all_descriptors ())
      then
        (* This resolver validates names embedded in prompt/continuity text; it
           does not grant Keeper execution. Registered dispatch-only names must
           therefore remain valid without entering the candidate projection. *)
        Resolved { canonical = normalized; via = Descriptor_registry }
      else if Tool_catalog_surfaces.is_system_internal_hidden normalized then
        (* System-internal tools (masc_gc, masc_reset, masc_cleanup_zombies, …)
           are dispatched directly via tool_misc and hidden from keeper surfaces,
           so they appear in no keeper-facing registry above. They are real
           tools, not stale/hallucinated names, so the prompt-token integrity
           scanner must treat them as valid (otherwise it strips them from
           continuity prose and emits a per-render WARN — observed as ~33/day of
           false "stripped masc token masc_gc" for keeper taskmaster). resolve is
           a validity gate whose only callers are that scanner/sanitizer, so this
           does not widen keeper tool admission. *)
        Resolved { canonical = normalized; via = System_internal }
      else
        (* The per-actor surface coverage gate (RFC-0084 §1.3) was removed in
           the surface-cut refactor: the [surface] type and its lists are
           deleted, and keeper tools resolve through the flat Descriptor_registry
           source above. A name that reaches here is admitted by no source —
           Unknown. *)
        Unknown
          { name
          ; tried =
              [ Dispatch_table
              ; Public_descriptor
              ; Alias_internal
              ; Registry_internal_candidate
              ; Registry_core_tools
              ; Tool_schema
              ; Descriptor_registry
              ; System_internal
              ]
          }

(* ── Phase 5: full-probe (no short-circuit) ────────────────────────── *)

(** Return every source that would admit [name], in resolution order.
    Unlike [resolve] which short-circuits, this checks every current source.
    Used for source-overlap analysis only. *)
let all_admitting_sources name =
  let normalized = Keeper_tool_alias.strip_mcp_masc_prefix name in
  let sources = ref [] in
  if Tool_dispatch.is_registered normalized then
    sources := Dispatch_table :: !sources;
  if Option.is_some (Keeper_tool_descriptor.find_public normalized) then
    sources := Public_descriptor :: !sources;
  if Keeper_tool_alias.is_known_internal normalized then
    sources := Alias_internal :: !sources;
  if List.mem normalized (Keeper_tool_registry.keeper_internal_candidate_tool_names) then
    sources := Registry_internal_candidate :: !sources;
  if List.mem normalized (Keeper_tool_registry.effective_core_tools ()) then
    sources := Registry_core_tools :: !sources;
  if List.mem normalized (tool_schema_names policy_tool_schemas) then
    sources := Tool_schema :: !sources;
  if
    List.exists
      (fun (d : Keeper_tool_descriptor.t) ->
        List.mem normalized (Keeper_tool_descriptor.registered_names d))
      (Keeper_tool_descriptor.all_descriptors ())
  then sources := Descriptor_registry :: !sources;
  if Tool_catalog_surfaces.is_system_internal_hidden normalized then
    sources := System_internal :: !sources;
  (* The per-actor surface admit sources (RFC-0084 §1.3) were removed in the
     surface-cut refactor — the [surface] type is deleted. *)
  List.rev !sources
;;

(* ── RFC-0084 §1.4 — Runtime routing SSOT entry ──────────────────────── *)

type runtime_decision_outcome =
  | Route_hit of { internal : string }
  | Already_internal of { canonical : string }
  | Miss

(** Single-SSOT entry for runtime tool-name routing.

    Runtime callers should use this typed decision when they need provenance,
    or [canonical_tool_name] / [canonical_tool_name_observed] when they only
    need the pure or telemetry-emitting string projection. *)
let runtime_decision name =
  match Keeper_tool_alias.canonical_resolution name with
  | Keeper_tool_alias.Public_alias { internal } -> Route_hit { internal }
  | Keeper_tool_alias.Internal { canonical } -> Already_internal { canonical }
  | Keeper_tool_alias.Unknown -> Miss

let canonical_tool_name name =
  match runtime_decision name with
  | Route_hit { internal } -> internal
  | Already_internal { canonical } -> canonical
  | Miss -> name
;;

let canonical_tool_name_observed name =
  let stripped = Keeper_tool_alias.strip_mcp_masc_prefix name in
  match runtime_decision name with
  | Route_hit { internal } ->
    Keeper_tool_alias.record_route_outcome ~tool:stripped ~routed_to:internal ~result:"ok";
    internal
  | Already_internal { canonical } ->
    Keeper_tool_alias.record_route_outcome
      ~tool:canonical
      ~routed_to:canonical
      ~result:"ok";
    canonical
  | Miss ->
    Keeper_tool_alias.record_route_outcome ~tool:name ~routed_to:"none" ~result:"miss";
    name
;;

let public_aliases_for_internal_name internal_name =
  Keeper_tool_descriptor_resolution.public_names_for_internal internal_name
;;

let public_alias_guidance_for_internal_call
      ~(allowed_tool_names : string list)
      (tool_name : string)
  : string option
  =
  let stripped = Keeper_tool_alias.strip_mcp_masc_prefix tool_name in
  match Keeper_tool_descriptor.find_public stripped with
  | Some _ -> None
  | None ->
    let canonical = canonical_tool_name stripped in
    (match public_aliases_for_internal_name canonical with
     | [] -> None
     | aliases ->
       let allowed_aliases =
         List.filter (fun alias -> List.mem alias allowed_tool_names) aliases
       in
       let alias_words =
         match allowed_aliases with
         | [] -> aliases
         | _ -> allowed_aliases
       in
       let alias_text = String.concat " or " alias_words in
       let correction =
         match allowed_aliases with
         | _ :: _ -> Printf.sprintf "Use %s instead." alias_text
         | [] ->
           Printf.sprintf
             "No public alias for it is allowed in this turn; do not invent \
              internal tool names. Wait for an allowed tool or report the blocker. \
              Public alias%s: %s."
             (if List.length aliases = 1 then "" else "es")
             alias_text
       in
       Some
         (Printf.sprintf
            "%s is an internal keeper implementation tool name, not a \
             schema-allowed tool. %s"
            stripped
            correction))
;;
