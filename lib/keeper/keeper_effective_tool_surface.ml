type tool_origin =
  | Descriptor of { group : string }
  | Instruction_skill
  | Composition_skill of
      { provenance : Keeper_skill_catalog.provenance option }
  | Composition_control

type tool =
  { name : string
  ; origin : tool_origin
  }

type tool_delivery =
  | Tools_delivered
  | Tools_suppressed_runtime_unsupported

type skill_load_reason =
  | Catalog_default
  | Keeper_profile
  | Task of { task_id : string }

type projection_basis =
  | Computed_current

type t =
  { projection_basis : projection_basis
  ; keeper_name : string
  ; runtime_id : string
  ; official_client_kind : string
  ; tool_delivery : tool_delivery
  ; native_posture : Runtime_native_tools.posture option
  ; skill_names : string list option
  ; unavailable_skill_names : Keeper_skill_catalog.configured_name_unavailable list
  ; current_task_id : string option
  ; skill_snapshot_revision : Skill_catalog_snapshot.snapshot_revision
  ; skill_resource_read_max_bytes : int option
  ; instruction_skills : Skill_reference.t list
  ; composition_skills : Skill_reference.t list
  ; skill_profiles : Keeper_skill_observability.profile list
  ; skill_load_reasons : (Skill_reference.t * skill_load_reason list) list
  ; tool_surface_bytes : int
  ; skill_tool_surface_bytes : int
  ; skill_discovery_bytes : int
  ; skill_eager_body_bytes : int
  ; skill_body_bytes : int
        (* Documents the catalog could not read, by the directory they were
           found in. They are here because this is the surface that answers
           "what can this Keeper call": a skill that was left out is absent
           from that answer, and absence with no reason beside it reads as a
           skill that was never written. *)
  ; skills_left_out : string list
  ; tools : tool list
  ; tool_surface_sha256 : string option
  }

type unavailable =
  { keeper_name : string
  ; reason : string
  ; detail : string
  }

type outcome =
  | Available of t
  | Unavailable of unavailable

let client_kind (runtime : Runtime.t) =
  match runtime.execution with
  | Runtime_execution.Agent_core _ -> "agent_core"
  | Runtime_execution.Codex_app_server _ -> "codex"
  | Runtime_execution.Claude_code _ -> "claude_code"
  | Runtime_execution.Antigravity_cli _ -> "antigravity"
;;

let descriptor_schema_tool (descriptor : Keeper_tool_descriptor.t) name =
  Tool_bridge.agent_core_tool_of_masc_with_execution_env
    ~name
    ~description:descriptor.description
    ~input_schema:descriptor.input_schema
    (fun _ _ -> invalid_arg "schema-only Keeper tool cannot execute")
;;

let descriptor_rows descriptors =
  List.concat_map
    (fun (descriptor : Keeper_tool_descriptor.t) ->
       let group =
         Keeper_tool_descriptor.keeper_tool_group_to_string
           descriptor.keeper_tool_group
       in
       List.map
         (fun name ->
            ( { name; origin = Descriptor { group } }
            , descriptor_schema_tool descriptor name ))
         (Keeper_tool_descriptor.keeper_model_names descriptor))
    descriptors
;;

let composition_rows skill_catalog =
  let skill_compositions =
    Keeper_skill_catalog.compositions skill_catalog
    |> List.map (fun (composition : Keeper_skill_catalog.composition) ->
      composition.entry, composition.provenance)
  in
  Keeper_tool_composition_surface.schema_tool_rows ~skill_compositions ()
  |> List.map (fun (origin, (schema_tool : Agent_core.Tool.t)) ->
       let name = schema_tool.schema.name in
       let origin =
         match origin with
         | Keeper_tool_composition_surface.Declared_composition provenance ->
           Composition_skill { provenance }
         | Keeper_tool_composition_surface.Async_status
         | Keeper_tool_composition_surface.Async_cancel -> Composition_control
       in
       { name; origin }, schema_tool)
;;

let project
      ~keeper_name
      ~runtime_id
      ~skills_left_out
      ~official_client_kind
      ~tool_delivery
      ~native_posture
      ~skill_names
      ~current_task_id
      ~task_skill_references
      ~(task_selection : Keeper_task_skill_turn.t option)
      ~skill_snapshot
  =
  let global_skill_catalog, _projection_diagnostics =
    Keeper_skill_catalog.of_snapshot skill_snapshot
  in
  let skill_resource_read_max_bytes =
    match Skill_catalog_snapshot.config_state skill_snapshot with
    | Configured { config; _ } ->
      Option.map
        Skill_source_config.resource_read_max_bytes_to_int
        config.resource_read_max_bytes
    | Config_rejected _ | Config_unreadable _ -> None
  in
  let task_selection =
    match task_selection with
    | Some selection -> Ok selection
    | None ->
      Keeper_task_skill_turn.resolve ~snapshot:skill_snapshot task_skill_references
  in
  match task_selection with
  | Error _ as error -> error
  | Ok task_selection ->
    let capability_surface =
      Keeper_capability_surface.create
        ~skill_names
        ~global_skill_catalog
        ~skill_inventory:(Keeper_skill_inventory.of_snapshot skill_snapshot)
        ~task_skills:(Keeper_task_skill_turn.skills task_selection)
    in
    let descriptors = Keeper_capability_surface.descriptors capability_surface in
    let turn_skill_projection =
      Keeper_capability_surface.skill_projection capability_surface
    in
    let skill_catalog = Keeper_capability_surface.skill_catalog capability_surface in
    let readable_instruction_skills =
      Keeper_skill_catalog.skills skill_catalog
      |> List.filter_map (fun (skill : Keeper_skill_catalog.skill) ->
           match skill.reference, skill.surface with
           | Some reference, Keeper_skill_catalog.Instruction ->
             let resource_location =
               match skill.provenance with
               | Some
                   { source_root = Some source_root
                   ; resource_read_max_bytes = Some resource_read_max_bytes
                   ; directory
                   ; _
                   } ->
                 Some
                   Keeper_tool_composition_surface.
                     { source_root; directory; resource_read_max_bytes }
               | Some { source_root = None; _ }
               | Some { resource_read_max_bytes = None; _ }
               | None ->
                 None
             in
             Some
               (Keeper_tool_composition_surface.instruction_skill
                  ?resource_location
                  ~reference
                  ~description:skill.description
                  ~body:skill.body
                  ())
           | None, _ | Some _, Keeper_skill_catalog.Composition _ ->
             None)
    in
    let instruction_skills =
      List.map
        (fun (skill : Keeper_tool_composition_surface.instruction_skill) ->
           skill.reference)
        readable_instruction_skills
    in
    let composition_skills =
      Keeper_skill_catalog.skills skill_catalog
      |> List.filter_map (fun (skill : Keeper_skill_catalog.skill) ->
           match skill.reference, skill.surface with
           | Some reference, Keeper_skill_catalog.Composition _ ->
             Some reference
           | None, _ | Some _, Keeper_skill_catalog.Instruction -> None)
    in
    let instruction_rows =
      match readable_instruction_skills with
      | [] -> []
      | skills ->
        let schema_tool =
          Keeper_tool_composition_surface.instruction_skill_schema_tool
            ~instruction_skills:skills
        in
        [ { name = schema_tool.schema.name; origin = Instruction_skill }, schema_tool ]
    in
    let composition_rows = composition_rows skill_catalog in
    let rows =
      descriptor_rows descriptors @ instruction_rows @ composition_rows
    in
    let instruction_skills, composition_skills, tools, schema_tools =
      match tool_delivery with
      | Tools_delivered ->
        instruction_skills, composition_skills, List.map fst rows, List.map snd rows
      | Tools_suppressed_runtime_unsupported -> [], [], [], []
    in
    let skill_profiles =
      match tool_delivery with
      | Tools_delivered -> Keeper_skill_observability.of_catalog skill_catalog
      | Tools_suppressed_runtime_unsupported -> []
    in
    let global_references =
      Keeper_skill_catalog.skills global_skill_catalog
      |> List.filter_map (fun (skill : Keeper_skill_catalog.skill) -> skill.reference)
    in
    let skill_load_reasons =
      List.map
        (fun (profile : Keeper_skill_observability.profile) ->
           let task_reasons =
             Keeper_task_skill_turn.task_ids_for_reference
               task_selection
               profile.reference
             |> List.map (fun task_id -> Task { task_id })
           in
           let selection_reason =
             match skill_names with
             | Some _ -> [ Keeper_profile ]
             | None ->
               if List.exists (Skill_reference.equal profile.reference) global_references
               then [ Catalog_default ]
               else []
           in
           profile.reference, task_reasons @ selection_reason)
        skill_profiles
    in
    let tool_surface_bytes =
      List.fold_left
        (fun total tool ->
           total + Keeper_skill_observability.tool_component_bytes tool)
        0
        schema_tools
    in
    let skill_tool_surface_bytes =
      let is_skill_row = function
        | { origin = (Instruction_skill | Composition_skill _ | Composition_control); _ }, _ ->
          true
        | { origin = Descriptor _; _ }, _ -> false
      in
      match tool_delivery with
      | Tools_suppressed_runtime_unsupported -> 0
      | Tools_delivered ->
        instruction_rows @ composition_rows
        |> List.filter is_skill_row
        |> List.fold_left
             (fun total (_, tool) ->
                total + Keeper_skill_observability.tool_component_bytes tool)
             0
    in
    let skill_body_bytes =
      List.fold_left
        (fun total (profile : Keeper_skill_observability.profile) ->
           total + profile.body_bytes)
        0
        skill_profiles
    in
    let skill_discovery_bytes =
      List.fold_left
        (fun total (profile : Keeper_skill_observability.profile) ->
           total + profile.discovery_bytes)
        0
        skill_profiles
    in
    let skill_eager_body_bytes =
      List.fold_left
        (fun total (profile : Keeper_skill_observability.profile) ->
           total + profile.eager_body_bytes)
        0
        skill_profiles
    in
    let tool_surface_sha256 =
      Option.map
        (fun native_posture ->
           Keeper_official_client_session_store.tool_surface_sha256
             ~native_posture
             schema_tools)
        native_posture
    in
    Ok
      { projection_basis = Computed_current
      ; keeper_name
      ; runtime_id
      ; official_client_kind
      ; tool_delivery
      ; native_posture
      ; skill_names
      ; unavailable_skill_names =
          Keeper_skill_catalog.configured_names_unavailable turn_skill_projection
      ; current_task_id
      ; skill_snapshot_revision =
          Skill_catalog_snapshot.snapshot_revision skill_snapshot
      ; skill_resource_read_max_bytes
      ; instruction_skills
      ; composition_skills
      ; skill_profiles
      ; skill_load_reasons
      ; tool_surface_bytes
      ; skill_tool_surface_bytes
      ; skill_discovery_bytes
      ; skill_eager_body_bytes
      ; skill_body_bytes
        (* Both sides added to this record and neither replaced the other:
           main (#31092) brought the profile and byte fields above, and this
           branch made [skills_left_out] also name what the turn could not
           reach. Keeping one would drop the other's answer. *)
      ; skills_left_out =
          skills_left_out
          @ List.map
              Keeper_skill_catalog.turn_unavailable_to_string
              turn_skill_projection.unavailable
      ; tools
      ; tool_surface_sha256
      }
;;

let resolve_runtime keeper_name =
  let runtime_id =
    Option.value
      (Runtime.runtime_id_for_keeper keeper_name)
      ~default:(Runtime.get_default_runtime_id ())
  in
  match Runtime.get_runtime_by_id runtime_id with
  | Some runtime -> Ok (runtime_id, runtime)
  | None ->
    Error
      ( "runtime_not_concrete"
      , Printf.sprintf
          "runtime assignment %S is a lane or is not materialized; no exact official-client posture can be projected"
          runtime_id )
;;

let resolve_native_posture ~base_path ~keeper_name (runtime : Runtime.t) =
  match runtime.execution with
  | Runtime_execution.Agent_core _ -> Ok None
  | Runtime_execution.Claude_code _ ->
    Keeper_official_client_host.resolve_native_posture
      ~base_path
      ~keeper_name
      ~client_label:"Claude Code"
      ~default:Runtime_native_tools.claude_code_default
      ~none_supported:true
    |> Result.map Option.some
  | Runtime_execution.Codex_app_server _ ->
    Keeper_official_client_host.resolve_native_posture
      ~base_path
      ~keeper_name
      ~client_label:"Codex"
      ~default:Runtime_native_tools.codex_default
      ~none_supported:false
    |> Result.map Option.some
  | Runtime_execution.Antigravity_cli _ ->
    Keeper_official_client_host.resolve_native_posture
      ~base_path
      ~keeper_name
      ~client_label:"Antigravity"
      ~default:Runtime_native_tools.antigravity_default
      ~none_supported:false
    |> Result.map Option.some
;;

let runtime_tool_delivery (runtime : Runtime.t) =
  match runtime.execution with
  | Runtime_execution.Codex_app_server _
  | Runtime_execution.Antigravity_cli _ -> Tools_delivered
  | Runtime_execution.Claude_code _ ->
    if runtime.model.tools_support
    then Tools_delivered
    else Tools_suppressed_runtime_unsupported
  | Runtime_execution.Agent_core provider_config ->
    let capabilities =
      match Llm_provider.Provider_config.capabilities_for_config_model provider_config with
      | Some capabilities -> capabilities
      | None ->
        Llm_provider.Capabilities.capabilities_of_kind provider_config.kind
    in
    if capabilities.supports_tools
    then Tools_delivered
    else Tools_suppressed_runtime_unsupported
;;

let unavailable keeper_name (reason, detail) =
  Unavailable { keeper_name; reason; detail }
;;

let published_skill_snapshot ~base_path =
  match Skill_catalog_snapshot_service.find_workspace_of_base_path ~base_path with
  | Error error ->
    Error
      ( "skill_snapshot_invalid_workspace"
      , Config_dir_resolver.canonical_base_path_error_to_string error )
  | Ok None ->
    Error ("skill_snapshot_not_registered", "Skill snapshot is not registered")
  | Ok (Some workspace) ->
    (match Skill_catalog_snapshot_service.current ~workspace with
     | None ->
       Error ("skill_snapshot_uninitialized", "Skill snapshot is not published")
     | Some snapshot ->
       let _catalog, diagnostics = Keeper_skill_catalog.of_snapshot snapshot in
       let skills_left_out =
         List.map
           (fun (diagnostic : Keeper_skill_catalog.projection_diagnostic) ->
              Printf.sprintf
                "%s: %s"
                (Skill_catalog_snapshot.identity_to_yojson diagnostic.identity
                 |> Yojson.Safe.to_string)
                (Keeper_skill_catalog.error_to_string diagnostic.error))
           diagnostics
       in
       Ok (snapshot, skills_left_out))
;;

let resolve ~config ~keeper_name =
  match Keeper_meta_store.read_meta config keeper_name with
  | Error detail -> unavailable keeper_name ("keeper_meta_unreadable", detail)
  | Ok None ->
    unavailable keeper_name ("keeper_not_found", "Keeper metadata does not exist")
  | Ok (Some meta) ->
    let current_task_id =
      Option.map Keeper_id.Task_id.to_string meta.current_task_id
    in
    (match
       Keeper_types_profile.load_keeper_profile_defaults_result_for_base_path
         ~base_path:config.base_path
         keeper_name
     with
     | Error error ->
       unavailable
         keeper_name
         ( "keeper_profile_unreadable"
         , Keeper_types_profile.keeper_toml_load_error_to_string error )
     | Ok profile_defaults ->
    (match published_skill_snapshot ~base_path:config.base_path with
     | Error error -> unavailable keeper_name error
     | Ok (skill_snapshot, skills_left_out) ->
       (match
          Keeper_task_skill_turn.resolve_observations
            ~snapshot:skill_snapshot
            ~current_task:
              (Keeper_world_observation_inputs.read_current_task ~config ~meta)
            ~held_task_skills:
              (Keeper_world_observation_inputs.read_held_task_skills ~config ~meta)
        with
        | Error error ->
          unavailable
            keeper_name
            ( "task_skill_selection_unavailable"
            , Keeper_task_skill_turn.error_to_string error )
        | Ok task_selection ->
          (match resolve_runtime keeper_name with
           | Error error -> unavailable keeper_name error
           | Ok (runtime_id, runtime) ->
             (match
                resolve_native_posture
                  ~base_path:config.base_path
                  ~keeper_name
                  runtime
              with
              | Error error ->
                unavailable
                  keeper_name
                  ("native_posture_rejected", Agent_core.Error.to_string error)
              | Ok native_posture ->
                (match
                   project
                     ~keeper_name
                     ~runtime_id
                     ~official_client_kind:(client_kind runtime)
                     ~tool_delivery:(runtime_tool_delivery runtime)
                     ~native_posture
                     ~skill_names:profile_defaults.skill_names
                     ~current_task_id
                     ~skills_left_out
                     ~task_skill_references:[]
                     ~task_selection:(Some task_selection)
                     ~skill_snapshot
                 with
                 | Ok surface -> Available surface
                 | Error error ->
                   unavailable
                     keeper_name
                     ( Keeper_task_skill_turn.error_code error
                     , Keeper_task_skill_turn.error_to_string error )))))))
;;

let string_list values = `List (List.map (fun value -> `String value) values)
let reference_list values = Skill_reference.list_to_yojson values

let skill_load_reason_to_yojson = function
  | Catalog_default -> `Assoc [ "kind", `String "catalog_default" ]
  | Keeper_profile -> `Assoc [ "kind", `String "keeper_profile" ]
  | Task { task_id } ->
    `Assoc [ "kind", `String "task"; "task_id", `String task_id ]
;;

let skill_profile_to_yojson surface profile =
  let reasons =
    surface.skill_load_reasons
    |> List.find_map (fun (reference, reasons) ->
         if Skill_reference.equal reference profile.Keeper_skill_observability.reference
         then Some reasons
         else None)
    |> Option.value ~default:[]
  in
  match Keeper_skill_observability.to_yojson profile with
  | `Assoc fields ->
    `Assoc
      (fields
       @ [ ( "load_reasons"
           , `List (List.map skill_load_reason_to_yojson reasons) ) ])
  | _ -> assert false
;;

let tool_delivery_to_yojson = function
  | Tools_delivered -> `Assoc [ "status", `String "delivered" ]
  | Tools_suppressed_runtime_unsupported ->
    `Assoc
      [ "status", `String "suppressed"
      ; "reason", `String "runtime_tools_unsupported"
      ]

let projection_basis_to_string = function
  | Computed_current -> "computed_current"
;;

let origin_to_yojson = function
  | Descriptor { group } ->
    `Assoc [ "kind", `String "descriptor"; "group", `String group ]
  | Instruction_skill -> `Assoc [ "kind", `String "instruction_skill" ]
  | Composition_skill { provenance } ->
    `Assoc
      [ "kind", `String "composition_skill"
      ; ( "skill_provenance"
        , match provenance with
          | Some provenance -> Keeper_skill_catalog.provenance_to_yojson provenance
          | None -> `Null )
      ]
  | Composition_control -> `Assoc [ "kind", `String "composition_control" ]
;;

let to_yojson = function
  | Unavailable { keeper_name; reason; detail } ->
    `Assoc
      [ "status", `String "unavailable"
      ; "keeper_name", `String keeper_name
      ; "reason", `String reason
      ; "detail", `String detail
      ]
  | Available surface ->
    `Assoc
      [ "status", `String "available"
      ; ( "projection_basis"
        , `String (projection_basis_to_string surface.projection_basis) )
      ; "keeper_name", `String surface.keeper_name
      ; "runtime_id", `String surface.runtime_id
      ; "official_client_kind", `String surface.official_client_kind
      ; "tool_delivery", tool_delivery_to_yojson surface.tool_delivery
      ; ( "native_posture"
        , match surface.native_posture with
          | None -> `Null
          | Some posture -> `String (Runtime_native_tools.to_string posture) )
      ; ( "skill_selection"
        , match surface.skill_names with
          | None -> `Assoc [ "mode", `String "all" ]
          | Some names ->
            `Assoc
              [ "mode", `String "names"
              ; "names", string_list names
              ] )
      ; ( "unavailable_skill_names"
        , `List
            (List.map
               Keeper_skill_catalog.configured_name_unavailable_to_yojson
               surface.unavailable_skill_names) )
      ; ( "current_task_id"
        , match surface.current_task_id with
          | None -> `Null
          | Some task_id -> `String task_id )
      ; ( "skill_snapshot_revision"
        , `String
            (Skill_catalog_snapshot.snapshot_revision_to_string
               surface.skill_snapshot_revision) )
      ; ( "skill_resource_read_max_bytes"
        , match surface.skill_resource_read_max_bytes with
          | Some max_bytes -> `Int max_bytes
          | None -> `Null )
      ; "instruction_skills", reference_list surface.instruction_skills
      ; "composition_skills", reference_list surface.composition_skills
      ; ( "skill_profiles"
        , `List
            (List.map (skill_profile_to_yojson surface) surface.skill_profiles) )
      ; "tool_surface_bytes", `Int surface.tool_surface_bytes
      ; "skill_tool_surface_bytes", `Int surface.skill_tool_surface_bytes
      ; "skill_discovery_bytes", `Int surface.skill_discovery_bytes
      ; "skill_eager_body_bytes", `Int surface.skill_eager_body_bytes
      ; "skill_body_bytes", `Int surface.skill_body_bytes
      ; "skills_left_out", string_list surface.skills_left_out
      ; "count", `Int (List.length surface.tools)
      ; ( "tools"
        , `List
            (List.map
               (fun tool ->
                  `Assoc
                    [ "name", `String tool.name
                    ; "origin", origin_to_yojson tool.origin
                    ])
               surface.tools) )
      ; ( "tool_surface_sha256"
        , match surface.tool_surface_sha256 with
          | None -> `Null
          | Some digest -> `String digest )
      ]
;;

module For_testing = struct
  let project = project
end
