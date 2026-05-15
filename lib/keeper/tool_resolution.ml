(** Tool_resolution — unified resolution behind the 15-fold OR membership check.

    RFC-0080 Phase 2 shim. Wraps the existing sources behind a single [resolve]
    function that returns a typed [resolution]. Every call site that previously
    used [is_known_policy_tool_name] now goes through [resolve].

    Behaviour: identical short-circuit order as the original 15-fold OR in
    [Keeper_tool_policy_config.is_known_policy_tool_name]. The first source
    that admits the name determines the [tried_source] tag. If none admit,
    all tried sources are collected in [Unknown.tried].

    @since 2.219.0 — RFC-0080 *)

(* ── Types ────────────────────────────────────────────────────────── *)

type tried_source =
  | Dispatch_table              (** S1: Tool_dispatch.is_registered *)
  | Tool_name_variant           (** S2: Tool_name.of_string *)
  | Alias_route                 (** S3: Keeper_tool_alias.route *)
  | Alias_internal              (** S4: Keeper_tool_alias.is_known_internal *)
  | Alias_masc_to_internal      (** S5: Keeper_tool_alias.public_masc_to_internal *)
  | Registry_internal_candidate (** S6: Keeper_tool_registry.keeper_internal_candidate_tool_names *)
  | Registry_core_tools         (** S7: Keeper_tool_registry.effective_core_tools *)
  | Registry_admin_dispatched   (** S8: Keeper_tool_registry.keeper_admin_dispatched_tools *)
  | Shard_schema                (** S9: Tool_shard.all_keeper_tool_schemas name extraction *)
  | Surface of Tool_catalog_surfaces.surface  (** S10-13: Tool_catalog_surfaces.is_on_surface *)

type resolution =
  | Resolved of { canonical : string ; via : tried_source ;
                  surface : Tool_catalog_surfaces.surface option }
  | Alias_to of { from_ : string ; canonical : string ; via : tried_source }
  | Unknown of { name : string ; tried : tried_source list }

(* ── Helpers ──────────────────────────────────────────────────────── *)

let tool_schema_names schemas =
  List.map (fun (schema : Masc_domain.tool_schema) -> schema.name) schemas

let string_of_tried_source = function
  | Dispatch_table -> "dispatch_table"
  | Tool_name_variant -> "tool_name_variant"
  | Alias_route -> "alias_route"
  | Alias_internal -> "alias_internal"
  | Alias_masc_to_internal -> "alias_masc_to_internal"
  | Registry_internal_candidate -> "registry_internal_candidate"
  | Registry_core_tools -> "registry_core_tools"
  | Registry_admin_dispatched -> "registry_admin_dispatched"
  | Shard_schema -> "shard_schema"
  | Surface s -> Printf.sprintf "surface:%s" (Tool_catalog_surfaces.surface_to_string s)

let string_of_tried sources =
  String.concat ", " (List.map string_of_tried_source sources)

(* ── Resolve ──────────────────────────────────────────────────────── *)

let resolve name =
  let normalized = Keeper_tool_alias.strip_mcp_masc_prefix name in
  (* Collect sources in short-circuit order; return on first hit. *)
  if Tool_dispatch.is_registered normalized then
    Resolved { canonical = normalized; via = Dispatch_table; surface = None }
  else if Option.is_some (Tool_name.of_string normalized) then
    Resolved { canonical = normalized; via = Tool_name_variant; surface = None }
  else if Option.is_some (Keeper_tool_alias.route normalized) then
    Alias_to { from_ = normalized; canonical = normalized; via = Alias_route }
  else if Keeper_tool_alias.is_known_internal normalized then
    Resolved { canonical = normalized; via = Alias_internal; surface = None }
  else begin
    match Keeper_tool_alias.public_masc_to_internal normalized with
    | Some internal ->
        Alias_to { from_ = normalized; canonical = internal; via = Alias_masc_to_internal }
    | None ->
      if List.mem normalized (Keeper_tool_registry.keeper_internal_candidate_tool_names) then
        Resolved { canonical = normalized; via = Registry_internal_candidate; surface = None }
      else if List.mem normalized (Keeper_tool_registry.effective_core_tools ()) then
        Resolved { canonical = normalized; via = Registry_core_tools; surface = None }
      else if List.mem normalized Keeper_tool_registry.keeper_admin_dispatched_tools then
        Resolved { canonical = normalized; via = Registry_admin_dispatched; surface = None }
      else if List.mem normalized (tool_schema_names Tool_shard.all_keeper_tool_schemas) then
        Resolved { canonical = normalized; via = Shard_schema; surface = None }
      else begin
        (* RFC-0084 §1.3 + §6 D2 — surface coverage gate.
           [Tool_catalog_surfaces.surface] has 8 variants. 7 are
           admit-checked here; [Keeper_denied] is excluded (must-deny
           semantics — checked separately in PR-7 capability gate, not
           an admission source). *)
        let surfaces_to_check =
          [ Tool_catalog_surfaces.Public_mcp
          ; Tool_catalog_surfaces.Spawned_agent
          ; Tool_catalog_surfaces.Local_worker
          ; Tool_catalog_surfaces.Session_min
          ; Tool_catalog_surfaces.Admin
          ; Tool_catalog_surfaces.Keeper_internal
          ; Tool_catalog_surfaces.System_internal
          ]
        in
        let _excluded_must_deny : Tool_catalog_surfaces.surface list =
          (* PR-7 will route [Keeper_denied] through the capability gate
             before admission; do not list it as an admit surface here. *)
          [ Tool_catalog_surfaces.Keeper_denied ]
        in
        let rec check_surfaces = function
          | [] ->
              let tried =
                [ Dispatch_table; Tool_name_variant; Alias_route
                ; Alias_internal; Alias_masc_to_internal
                ; Registry_internal_candidate; Registry_core_tools
                ; Registry_admin_dispatched; Shard_schema
                ]
                @ List.map (fun s -> Surface s) surfaces_to_check
              in
              Unknown { name; tried }
          | surface :: rest ->
              if Tool_catalog_surfaces.is_on_surface surface normalized then
                Resolved { canonical = normalized; via = Surface surface; surface = Some surface }
              else
                check_surfaces rest
        in
        check_surfaces surfaces_to_check
      end
  end

(* ── Legacy adapter ───────────────────────────────────────────────── *)

let is_known_policy_tool_name name =
  match resolve name with
  | Resolved _ | Alias_to _ -> true
  | Unknown _ -> false

(* ── Phase 5: full-probe (no short-circuit) ────────────────────────── *)

(** Return every source that would admit [name], in resolution order.
    Unlike [resolve] which short-circuits, this checks all 13 sources.
    Used for source-overlap analysis only. *)
let all_admitting_sources name =
  let normalized = Keeper_tool_alias.strip_mcp_masc_prefix name in
  let sources = ref [] in
  if Tool_dispatch.is_registered normalized then
    sources := Dispatch_table :: !sources;
  if Option.is_some (Tool_name.of_string normalized) then
    sources := Tool_name_variant :: !sources;
  if Option.is_some (Keeper_tool_alias.route normalized) then
    sources := Alias_route :: !sources;
  if Keeper_tool_alias.is_known_internal normalized then
    sources := Alias_internal :: !sources;
  (match Keeper_tool_alias.public_masc_to_internal normalized with
   | Some _ -> sources := Alias_masc_to_internal :: !sources
   | None -> ());
  if List.mem normalized (Keeper_tool_registry.keeper_internal_candidate_tool_names) then
    sources := Registry_internal_candidate :: !sources;
  if List.mem normalized (Keeper_tool_registry.effective_core_tools ()) then
    sources := Registry_core_tools :: !sources;
  if List.mem normalized Keeper_tool_registry.keeper_admin_dispatched_tools then
    sources := Registry_admin_dispatched :: !sources;
  if List.mem normalized (tool_schema_names Tool_shard.all_keeper_tool_schemas) then
    sources := Shard_schema :: !sources;
  (* RFC-0084 §1.3 + §6 D2 — admit-only surfaces (Keeper_denied excluded). *)
  let surfaces_to_check =
    [ Tool_catalog_surfaces.Public_mcp
    ; Tool_catalog_surfaces.Spawned_agent
    ; Tool_catalog_surfaces.Local_worker
    ; Tool_catalog_surfaces.Session_min
    ; Tool_catalog_surfaces.Admin
    ; Tool_catalog_surfaces.Keeper_internal
    ; Tool_catalog_surfaces.System_internal
    ]
  in
  List.iter (fun surface ->
    if Tool_catalog_surfaces.is_on_surface surface normalized then
      sources := Surface surface :: !sources
  ) surfaces_to_check;
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

    PR-6 moves the pure routing decision below [Keeper_tool_disclosure]
    so runtime callers can converge on one low-dependency entry without
    creating a module cycle. [Keeper_tool_disclosure] delegates its legacy
    pure canonicalisation to this function for parity during migration.

    PR-7~9 migrate keeper turn, MCP server, and tag-dispatch callers from
    [Keeper_tool_disclosure.canonical_tool_name] to this entry. PR-11
    removes the legacy wrapper in favour of this one. *)
let runtime_decision name =
  let stripped = Keeper_tool_alias.strip_mcp_masc_prefix name in
  match Keeper_tool_alias.public_masc_to_internal stripped with
  | Some internal -> Mcp_mapped { stripped; internal }
  | None ->
    (match Keeper_tool_alias.route stripped with
     | Some r -> Route_hit { internal = r.internal_name }
     | None ->
       if Keeper_tool_alias.is_known_internal stripped
       then Already_internal { canonical = stripped }
       else Miss)
