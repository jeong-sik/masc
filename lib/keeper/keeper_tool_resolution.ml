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
  | Tool_schema                 (** S7: policy tool-schema inventory name extraction *)
  | Descriptor_registry         (** S7.5: registered names projected by
                                    Keeper_tool_descriptor.all_descriptors *)

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
  | Tool_schema -> "tool_schema"
  | Descriptor_registry -> "descriptor_registry"

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
        List.mem normalized (tool_schema_names policy_tool_schemas)
      then Resolved { canonical = normalized; via = Tool_schema }
      else if
        List.exists
          (fun (d : Keeper_tool_descriptor.t) ->
             List.mem normalized (Keeper_tool_descriptor.registered_names d))
          (Keeper_tool_descriptor.all_descriptors ())
      then
        (* This resolver validates names embedded in prompt/continuity text; it
           does not grant Keeper execution. Exact transport aliases therefore
           remain valid without becoming duplicate model tools. *)
        Resolved { canonical = normalized; via = Descriptor_registry }
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
              ; Tool_schema
              ; Descriptor_registry
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
  if List.mem normalized (tool_schema_names policy_tool_schemas) then
    sources := Tool_schema :: !sources;
  if
    List.exists
      (fun (d : Keeper_tool_descriptor.t) ->
        List.mem normalized (Keeper_tool_descriptor.registered_names d))
      (Keeper_tool_descriptor.all_descriptors ())
  then sources := Descriptor_registry :: !sources;
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
