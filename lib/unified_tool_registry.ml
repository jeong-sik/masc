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
    - Descriptor handlers derive their tag from the typed runtime handler. *)

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
    yet. The workspace schema inventory owns this dispatch cluster. *)
let workspace_state_tool_names =
  List.map (fun (s : Masc_domain.tool_schema) -> s.name) Tool_schemas_workspace.schemas

let is_workspace_state_tool_name name = List.mem name workspace_state_tool_names

let inline_runtime_tool_names =
  List.map (fun (s : Masc_domain.tool_schema) -> s.name) Tool_schemas_inline.schemas
;;

let is_inline_runtime_tool_name name = List.mem name inline_runtime_tool_names

(** Exact dispatch tag for one typed descriptor handler. *)
let tag_of_runtime_handler
      (handler : Keeper_tool_descriptor.runtime_handler)
  : TD.module_tag
  =
  let open TD in
  let open Keeper_tool_descriptor in
  match handler with
  | Tool_masc_plan_dispatch -> Mod_plan
  | Tool_masc_run_dispatch -> Mod_run
  | Tool_masc_agent_dispatch -> Mod_agent
  | Tool_masc_task_dispatch -> Mod_task
  | Tool_masc_workspace_dispatch -> Mod_state
  | Tool_masc_control_dispatch -> Mod_control
  | Tool_masc_agent_timeline_dispatch -> Mod_agent_timeline
  | Tool_masc_schedule_dispatch -> Mod_schedule
  | Tool_masc_misc_dispatch | Tool_web_search | Tool_web_fetch -> Mod_misc
  | Tool_masc_local_runtime_dispatch -> Mod_local_runtime
  | Tool_masc_library_dispatch -> Mod_library
  | Tool_board_dispatch -> Mod_inline
  | Tool_task_dispatch -> Mod_keeper_task
  | Tool_execute
  | Tool_search_files
  | Tool_read_file
  | Tool_edit_file
  | Tool_write_file
  | Tool_time_now
  | Tool_tools_list
  | Tool_context_status
  | Tool_artifact_read
  | Tool_memory_search
  | Tool_memory_write
  | Tool_library_search
  | Tool_library_read
  | Tool_surface_read
  | Tool_surface_post
  | Tool_person_note_set
  | Tool_ide_annotate
  | Tool_voice_dispatch
  | Tool_masc_keeper_dispatch
  | Tool_masc_fusion_dispatch
  | Tool_masc_fusion_status
  | Tool_analyze_image -> Mod_external

(** Resolve only exact schema or descriptor membership. *)
let tag_of_name name : TD.module_tag option =
  if is_workspace_state_tool_name name then Some TD.Mod_state
  else if is_keeper_task_tool_name name then Some TD.Mod_keeper_task
  else if is_inline_runtime_tool_name name then Some TD.Mod_inline
  else
    match Keeper_tool_descriptor.descriptors_for_internal name with
    | [ descriptor ] -> Some (tag_of_runtime_handler descriptor.runtime_handler)
    | [] ->
      (match Keeper_tool_descriptor.find_public name with
       | Some descriptor -> Some (tag_of_runtime_handler descriptor.runtime_handler)
       | None -> None)
    | _ :: _ :: _ -> invalid_arg ("duplicate tool descriptors for " ^ name)

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
         | None ->
           invalid_arg
             ("visible tool schema has no exact dispatch owner: " ^ schema.name))

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
         register_schema_if_missing
           schema
           (tag_of_runtime_handler descriptor.runtime_handler))

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
