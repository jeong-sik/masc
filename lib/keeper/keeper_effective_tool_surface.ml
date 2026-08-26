type tool_origin =
  | Descriptor of { group : string }
  | Instruction_skill
  | Composition_skill of
      { provenance : Keeper_skill_catalog.provenance option }
  | Composition_plan
  | Composition_control

type tool =
  { name : string
  ; origin : tool_origin
  }

type tool_delivery =
  | Tools_delivered
  | Tools_suppressed_runtime_unsupported

type t =
  { keeper_name : string
  ; runtime_id : string
  ; official_client_kind : string
  ; tool_delivery : tool_delivery
  ; native_posture : Runtime_native_tools.posture option
  ; tool_groups : string list
  ; current_task_id : string option
  ; instruction_skills : Skill_reference.t list
  ; composition_skills : Skill_reference.t list
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
  Keeper_tool_composition_surface.schema_tool_rows
    ~skill_compositions
    ()
  |> List.map (fun (origin, (schema_tool : Agent_core.Tool.t)) ->
    let name = schema_tool.schema.name in
    let origin =
      match origin with
      | Keeper_tool_composition_surface.Declared_composition provenance ->
        Composition_skill { provenance }
      | Keeper_tool_composition_surface.Plan_execute -> Composition_plan
      | Keeper_tool_composition_surface.Async_status
      | Keeper_tool_composition_surface.Async_cancel -> Composition_control
    in
    { name; origin }, schema_tool)
;;

let project
      ~keeper_name
      ~runtime_id
      ~official_client_kind
      ~tool_delivery
      ~native_posture
      ~tool_groups
      ~current_task_id
      ~task_skill_references
      ~skill_snapshot
  =
  let skill_catalog, _projection_diagnostics =
    Keeper_skill_catalog.of_snapshot skill_snapshot
  in
  let surface = Keeper_tool_descriptor.tool_groups_to_surface tool_groups in
  let descriptors =
    Keeper_tool_descriptor.model_visible_descriptors_for_surface ~surface
  in
  match Keeper_task_skill_turn.resolve ~snapshot:skill_snapshot task_skill_references with
  | Error _ as error -> error
  | Ok task_selection ->
    let task_instruction_skills =
      List.map
        (fun (selected : Keeper_task_skill_turn.selected) ->
           let resource_location =
             match selected.skill.provenance with
             | Some { source_root = Some source_root; directory; _ } ->
               Some Keeper_tool_composition_surface.{ source_root; directory }
             | Some { source_root = None; _ }
             | None ->
               None
           in
           Keeper_tool_composition_surface.instruction_skill
             ?resource_location
             ~reference:selected.reference
             ~description:selected.skill.description
             ~body:selected.skill.body
             ())
        task_selection.selected
    in
    let global_instruction_skills =
      Keeper_skill_catalog.skills skill_catalog
      |> List.filter_map (fun (skill : Keeper_skill_catalog.skill) ->
           match skill.reference, skill.model_invocable, skill.surface with
           | Some reference, true, Keeper_skill_catalog.Instruction ->
             let resource_location =
               match skill.provenance with
               | Some { source_root = Some source_root; directory; _ } ->
                 Some Keeper_tool_composition_surface.{ source_root; directory }
               | Some { source_root = None; _ }
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
           | None, _, _
           | Some _, false, _
           | Some _, true, Keeper_skill_catalog.Composition _ ->
             None)
    in
    let readable_instruction_skills =
      Keeper_tool_composition_surface.merge_instruction_skills
        ~task:task_instruction_skills
        ~global:global_instruction_skills
    in
    let instruction_skills =
      List.map
        (fun skill -> skill.Keeper_tool_composition_surface.reference)
        readable_instruction_skills
    in
    let composition_skills =
      Keeper_skill_catalog.skills skill_catalog
      |> List.filter_map (fun (skill : Keeper_skill_catalog.skill) ->
           match skill.reference, skill.model_invocable, skill.surface with
           | Some reference, true, Keeper_skill_catalog.Composition _ ->
             Some reference
           | None, _, _
           | Some _, false, _
           | Some _, true, Keeper_skill_catalog.Instruction ->
             None)
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
    let rows =
      descriptor_rows descriptors
      @ instruction_rows
      @ composition_rows skill_catalog
    in
    let instruction_skills, composition_skills, tools, schema_tools =
      match tool_delivery with
      | Tools_delivered ->
        instruction_skills, composition_skills, List.map fst rows, List.map snd rows
      | Tools_suppressed_runtime_unsupported -> [], [], [], []
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
      { keeper_name
      ; runtime_id
      ; official_client_kind
      ; tool_delivery
      ; native_posture
      ; tool_groups = Option.value ~default:[] tool_groups
      ; current_task_id
      ; instruction_skills
      ; composition_skills
      ; tools
      ; tool_surface_sha256
      }
;;

let task_skills config current_task_id =
  match current_task_id with
  | None -> Ok []
  | Some task_id ->
    (match
       Workspace.get_tasks_safe config
       |> List.find_opt (fun (task : Masc_domain.task) ->
         String.equal task.id task_id)
     with
     | Some task -> Ok task.skills
     | None ->
       Error
         ( "current_task_missing"
         , Printf.sprintf "Keeper metadata names missing task %S" task_id ))
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
     | Some snapshot -> Ok snapshot)
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
    (match task_skills config current_task_id with
     | Error error -> unavailable keeper_name error
     | Ok task_skill_references ->
       (match published_skill_snapshot ~base_path:config.base_path with
        | Error error -> unavailable keeper_name error
        | Ok skill_snapshot ->
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
                     ~tool_groups:meta.tool_groups
                     ~current_task_id
                     ~task_skill_references
                     ~skill_snapshot
                 with
                 | Ok surface -> Available surface
                 | Error error ->
                   unavailable
                     keeper_name
                     ( Keeper_task_skill_turn.error_code error
                     , Keeper_task_skill_turn.error_to_string error ))))))
;;

let string_list values = `List (List.map (fun value -> `String value) values)
let reference_list values = Skill_reference.list_to_yojson values

let tool_delivery_to_yojson = function
  | Tools_delivered -> `Assoc [ "status", `String "delivered" ]
  | Tools_suppressed_runtime_unsupported ->
    `Assoc
      [ "status", `String "suppressed"
      ; "reason", `String "runtime_tools_unsupported"
      ]

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
  | Composition_plan -> `Assoc [ "kind", `String "composition_plan" ]
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
      ; "keeper_name", `String surface.keeper_name
      ; "runtime_id", `String surface.runtime_id
      ; "official_client_kind", `String surface.official_client_kind
      ; "tool_delivery", tool_delivery_to_yojson surface.tool_delivery
      ; ( "native_posture"
        , match surface.native_posture with
          | None -> `Null
          | Some posture -> `String (Runtime_native_tools.to_string posture) )
      ; "tool_groups", string_list surface.tool_groups
      ; ( "current_task_id"
        , match surface.current_task_id with
          | None -> `Null
          | Some task_id -> `String task_id )
      ; "instruction_skills", reference_list surface.instruction_skills
      ; "composition_skills", reference_list surface.composition_skills
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
