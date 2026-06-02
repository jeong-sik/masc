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
  | Tool_name_variant           (** S2: Tool_name.of_string *)
  | Public_descriptor           (** S3: Keeper_tool_descriptor.find_public *)
  | Alias_internal              (** S4: Keeper_tool_alias.is_known_internal *)
  | Alias_masc_to_internal      (** S5: Keeper_tool_alias.public_masc_to_internal *)
  | Registry_internal_candidate (** S6: Keeper_tool_registry.keeper_internal_candidate_tool_names *)
  | Registry_core_tools         (** S7: Keeper_tool_registry.effective_core_tools *)
  | Shard_schema                (** S8: Tool_shard.all_keeper_tool_schemas name extraction *)
  | Descriptor_registry         (** S8.5: Keeper_tool_descriptor.all_descriptors public_name —
                                    flat SSOT incl. internal_descriptors (masc_keeper_* live here) *)

type resolution =
  | Resolved of { canonical : string ; via : tried_source }
  | Alias_to of { from_ : string ; canonical : string ; via : tried_source }
  | Unknown of { name : string ; tried : tried_source list }

(* ── Helpers ──────────────────────────────────────────────────────── *)

let tool_schema_names schemas =
  List.map (fun (schema : Masc_domain.tool_schema) -> schema.name) schemas

let string_of_tried_source = function
  | Dispatch_table -> "dispatch_table"
  | Tool_name_variant -> "tool_name_variant"
  | Public_descriptor -> "public_descriptor"
  | Alias_internal -> "alias_internal"
  | Alias_masc_to_internal -> "alias_masc_to_internal"
  | Registry_internal_candidate -> "registry_internal_candidate"
  | Registry_core_tools -> "registry_core_tools"
  | Shard_schema -> "shard_schema"
  | Descriptor_registry -> "descriptor_registry"

let string_of_tried sources =
  String.concat ", " (List.map string_of_tried_source sources)

(* ── Resolve ──────────────────────────────────────────────────────── *)

let resolve name =
  let normalized = Keeper_tool_alias.strip_mcp_masc_prefix name in
  (* Collect sources in short-circuit order; return on first hit. *)
  if Tool_dispatch.is_registered normalized then
    Resolved { canonical = normalized; via = Dispatch_table }
  else if Option.is_some (Tool_name.of_string normalized) then
    Resolved { canonical = normalized; via = Tool_name_variant }
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
        else begin
          match Keeper_tool_alias.public_masc_to_internal normalized with
          | Some internal ->
              Alias_to
                { from_ = normalized; canonical = internal; via = Alias_masc_to_internal }
          | None ->
              if List.mem normalized Keeper_tool_registry.keeper_internal_candidate_tool_names
              then
                Resolved
                  { canonical = normalized; via = Registry_internal_candidate }
              else if List.mem normalized (Keeper_tool_registry.effective_core_tools ())
              then
                Resolved
                  { canonical = normalized; via = Registry_core_tools }
              else if
                List.mem normalized (tool_schema_names Tool_shard.all_keeper_tool_schemas)
              then Resolved { canonical = normalized; via = Shard_schema }
              else if
                List.exists
                  (fun (d : Keeper_tool_descriptor.t) ->
                    String.equal d.Keeper_tool_descriptor.public_name normalized)
                  (Keeper_tool_descriptor.all_descriptors ())
              then
                (* Flat descriptor registry. Descriptor-backed tools live in
                   [public_descriptors @ internal_descriptors]. masc_keeper_*
                   (dispatched via Keeper_tool_surface.dispatch, not the handler
                   registry) sit in internal_descriptors and were orphaned from
                   resolution when #19797 purged the surface lists. This flat-name
                   source restores admission without touching dispatch — resolve
                   is a validity gate; [via] is only used for the error string. *)
                Resolved
                  { canonical = normalized; via = Descriptor_registry }
              else
                (* The per-actor surface coverage gate (RFC-0084 §1.3) was
                   removed in the surface-cut refactor: the [surface] type and
                   its lists are deleted, and keeper tools resolve through the
                   flat Descriptor_registry source above. A name that reaches
                   here is admitted by no source — Unknown. *)
                Unknown
                  { name
                  ; tried =
                      [ Dispatch_table
                      ; Tool_name_variant
                      ; Public_descriptor
                      ; Alias_internal
                      ; Alias_masc_to_internal
                      ; Registry_internal_candidate
                      ; Registry_core_tools
                      ; Shard_schema
                      ; Descriptor_registry
                      ]
                  }
        end

(* ── Phase 5: full-probe (no short-circuit) ────────────────────────── *)

(** Return every source that would admit [name], in resolution order.
    Unlike [resolve] which short-circuits, this checks every current source.
    Used for source-overlap analysis only. *)
let all_admitting_sources name =
  let normalized = Keeper_tool_alias.strip_mcp_masc_prefix name in
  let sources = ref [] in
  if Tool_dispatch.is_registered normalized then
    sources := Dispatch_table :: !sources;
  if Option.is_some (Tool_name.of_string normalized) then
    sources := Tool_name_variant :: !sources;
  if Option.is_some (Keeper_tool_descriptor.find_public normalized) then
    sources := Public_descriptor :: !sources;
  if Keeper_tool_alias.is_known_internal normalized then
    sources := Alias_internal :: !sources;
  (match Keeper_tool_alias.public_masc_to_internal normalized with
   | Some _ -> sources := Alias_masc_to_internal :: !sources
   | None -> ());
  if List.mem normalized (Keeper_tool_registry.keeper_internal_candidate_tool_names) then
    sources := Registry_internal_candidate :: !sources;
  if List.mem normalized (Keeper_tool_registry.effective_core_tools ()) then
    sources := Registry_core_tools :: !sources;
  if List.mem normalized (tool_schema_names Tool_shard.all_keeper_tool_schemas) then
    sources := Shard_schema :: !sources;
  if
    List.exists
      (fun (d : Keeper_tool_descriptor.t) ->
        String.equal d.Keeper_tool_descriptor.public_name normalized)
      (Keeper_tool_descriptor.all_descriptors ())
  then sources := Descriptor_registry :: !sources;
  (* The per-actor surface admit sources (RFC-0084 §1.3) were removed in the
     surface-cut refactor — the [surface] type is deleted. *)
  List.rev !sources
;;

(* ── RFC-0084 §1.4 — Runtime routing SSOT entry ──────────────────────── *)

type runtime_decision_outcome =
  | Mcp_mapped of
      { stripped : string
      ; internal : string
      }
  | Route_hit of { internal : string }
  | Already_internal of { canonical : string }
  | Miss

(** Single-SSOT entry for runtime tool-name routing.

    Runtime callers should use this typed decision when they need provenance,
    or [canonical_tool_name] / [canonical_tool_name_observed] when they only
    need the pure or telemetry-emitting string projection. *)
let runtime_decision name =
  match Keeper_tool_alias.canonical_resolution name with
  | Keeper_tool_alias.Public_mcp { stripped; internal } ->
    Mcp_mapped { stripped; internal }
  | Keeper_tool_alias.Public_alias { internal } -> Route_hit { internal }
  | Keeper_tool_alias.Internal { canonical } -> Already_internal { canonical }
  | Keeper_tool_alias.Unknown -> Miss

let canonical_tool_name name =
  match runtime_decision name with
  | Mcp_mapped { internal; _ } -> internal
  | Route_hit { internal } -> internal
  | Already_internal { canonical } -> canonical
  | Miss -> name
;;

let canonical_tool_name_observed name =
  let stripped = Keeper_tool_alias.strip_mcp_masc_prefix name in
  match runtime_decision name with
  | Mcp_mapped { internal; _ } ->
    Keeper_tool_alias.record_route_outcome ~tool:stripped ~routed_to:internal ~result:"ok";
    internal
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
      ~(visible_tool_names : string list)
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
       let visible_aliases =
         List.filter (fun alias -> List.mem alias visible_tool_names) aliases
       in
       let alias_words =
         match visible_aliases with
         | [] -> aliases
         | _ -> visible_aliases
       in
       let alias_text = String.concat " or " alias_words in
       let correction =
         match visible_aliases with
         | _ :: _ -> Printf.sprintf "Use %s instead." alias_text
         | [] ->
           Printf.sprintf
             "No public alias for it is visible in this turn; do not invent \
              internal tool names. Wait for a visible tool or report the blocker. \
              Public alias%s: %s."
             (if List.length aliases = 1 then "" else "es")
             alias_text
       in
       Some
         (Printf.sprintf
            "%s is an internal keeper implementation tool name, not a \
             schema-visible tool. %s"
            stripped
            correction))
;;
