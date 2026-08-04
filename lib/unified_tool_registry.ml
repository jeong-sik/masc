(** Unified Tool Registry Ratchet — P0-1.

    Single registration flow over the raw MCP schema inventory and the
    descriptor-owned Keeper handler inventory.

    The flow registers a dispatch tag (+ schema) for every name that does not
    already have one, then enforces the startup invariant that every
    LLM-visible schema resolves to a tag.

    Design notes:
    - We never overwrite an existing tag. Modules that already register via
      [Tool_spec] keep their precise tag; this ratchet only fills the gaps.
    - [Mod_keeper_task] is introduced as the canonical tag for the closed
      keeper task-operation cluster. Real execution still flows through the
      keeper internal runtime, but the tag makes the cluster first-class in
      the unified registry.
    - Descriptors and other keeper-internal handlers are classified as
      [Mod_external] for registry-completeness; they are not dispatched
      through the neutral Tool substrate. *)

module TD = Tool_dispatch

(** Closed set of keeper task-operation names handled by
    [Keeper_tool_task_runtime.handle_keeper_task_tool]. Derived from
    [Keeper_tool_name] so the registry and the typed handler cluster stay
    in sync. *)
let keeper_task_tool_names =
  List.map
    Keeper_tool_name.to_string
    Keeper_tool_name.
      [ Tasks_list
      ; Tasks_audit
      ; Broadcast
      ; Task_create
      ; Task_claim
      ; Task_done
      ]

let is_keeper_task_tool_name name = List.mem name keeper_task_tool_names

(** Workspace state tools are handled by [Tool_workspace.dispatch] and share
    [Mod_state] even when the module-load [Tool_spec] side effect has not run
    yet. The schema facade is the owned source for this dispatch cluster. *)
let workspace_state_tool_names =
  List.map (fun (s : Masc_domain.tool_schema) -> s.name) Tool_schemas_workspace.schemas

let is_workspace_state_tool_name name = List.mem name workspace_state_tool_names

(** Derive a dispatch tag from a tool name. This is the ratchet fallback used
    for naming-rule clusters and schema-owned closed clusters; any name it
    returns [None] for must either be invisible or be handled by an explicit
    [Tool_spec] registration that already populated the tag registry. *)
let tag_of_name name : TD.module_tag option =
  let open TD in
  let prefix p = String.starts_with ~prefix:p name in
  if is_workspace_state_tool_name name then Some Mod_state
  else if prefix "masc_plan_" then Some Mod_plan
  else if prefix "masc_run_" then Some Mod_run
  else if prefix "masc_agent_" then Some Mod_agent
  else if prefix "masc_task_" then Some Mod_task
  else if prefix "masc_workspace_" then Some Mod_state
  else if prefix "masc_control_" then Some Mod_control
  else if prefix "masc_agent_timeline_" then Some Mod_agent_timeline
  else if prefix "masc_schedule_" then Some Mod_schedule
  else if prefix "masc_misc_" then Some Mod_misc
  else if prefix "masc_local_runtime_" then Some Mod_local_runtime
  else if prefix "masc_library_" then Some Mod_library
  else if prefix "masc_operator_" then Some Mod_operator
  else if prefix "masc_external_" then Some Mod_external
  else if prefix "masc_inline_" then Some Mod_inline
  else if prefix "masc_compact_" then Some Mod_compact
  else if prefix "masc_board_" then Some Mod_inline
  else if prefix "masc_keeper_" then Some Mod_external
  else if is_keeper_task_tool_name name then Some Mod_keeper_task
  else if prefix "keeper_" then Some Mod_external
  else if
    List.mem
      name
      [ "tool_execute"
      ; "tool_read_file"
      ; "tool_edit_file"
      ; "tool_write_file"
      ; "tool_search_files"
      ]
  then Some Mod_external
  else None

(** Register a tag + schema only if the name is not already in the tag
    registry. Existing [Tool_spec] registrations are preserved. *)
let register_schema_if_missing (schema : Masc_domain.tool_schema) tag =
  if Option.is_none (TD.lookup_tag schema.name)
  then TD.register_module_tag ~schemas:[ schema ] ~tag

(** 1. Register every LLM-visible schema from [Config.raw_all_tool_schemas]
    that does not already have a tag. *)
let register_visible_raw_schemas () =
  Config.raw_all_tool_schemas
  |> List.iter (fun (schema : Masc_domain.tool_schema) ->
       if Tool_catalog.is_visible schema.name
       then
         match tag_of_name schema.name with
         | Some tag -> register_schema_if_missing schema tag
         | None -> register_schema_if_missing schema TD.Mod_external)

(** 2. Register each descriptor's internal handler name with the schema owned
    by that descriptor. Model aliases are canonicalised before dispatch and
    never receive fabricated placeholder schemas. *)
let register_descriptor_handlers () =
  Keeper_tool_descriptor.all_descriptors ()
  |> List.iter (fun (descriptor : Keeper_tool_descriptor.t) ->
         let schema : Masc_domain.tool_schema =
           { name = descriptor.internal_name
           ; description = descriptor.description
           ; input_schema = descriptor.input_schema
           }
         in
         match tag_of_name schema.name with
         | Some tag -> register_schema_if_missing schema tag
         | None -> register_schema_if_missing schema TD.Mod_external)

(** Run the complete unified registration flow. Safe to call multiple times
    (subsequent calls are no-ops for already-registered names). *)
let register_all () =
  register_visible_raw_schemas ();
  register_descriptor_handlers ()

(** Names of LLM-visible schemas that still lack a dispatch tag. Empty when
    the ratchet is complete. *)
let visible_schemas_missing_tags () =
  Config.visible_tool_schemas ()
  |> List.filter (fun (s : Masc_domain.tool_schema) ->
       Option.is_none (TD.lookup_tag s.name))
  |> List.map (fun (s : Masc_domain.tool_schema) -> s.name)

(** Startup invariant: every LLM-visible schema has a dispatch tag.
    Raises [Failure] if the invariant is violated so boot cannot proceed
    with a half-registered surface. *)
let enforce_visible_tag_coverage () =
  match visible_schemas_missing_tags () with
  | [] -> ()
  | missing ->
    let msg =
      Printf.sprintf
        "P0-1 invariant violation: %d LLM-visible schema(s) lack a dispatch tag: %s"
        (List.length missing)
        (String.concat ", " missing)
    in
    Log.Server.error "%s" msg;
    failwith msg
