type tool_origin =
  | Descriptor of { group : string }
  | Instruction_skill
  | Composition_skill of { source : string }
  | Composition_plan
  | Composition_control

type tool =
  { name : string
  ; origin : tool_origin
  }

type t =
  { keeper_name : string
  ; runtime_id : string
  ; official_client_kind : string
  ; native_posture : Runtime_native_tools.posture option
  ; tool_groups : string list
  ; current_task_id : string option
  ; instruction_skills : string list
  ; composition_skills : string list
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

let composition_origin name =
  if String.equal name Keeper_tool_composition_catalog.skill_tool_name
  then Instruction_skill
  else match Keeper_tool_composition_catalog.skill_source_of_tool_name name with
  | Some source -> Composition_skill { source }
  | None when
      String.equal name Keeper_tool_composition_surface.plan_execute_tool_name ->
    Composition_plan
  | None -> Composition_control
;;

let composition_rows skill_catalog =
  Keeper_tool_composition_surface.schema_tools
    ~skill_composition_entries:
      (Keeper_skill_catalog.composition_entries skill_catalog)
    ~instruction_skills:(Keeper_skill_catalog.instruction_entries skill_catalog)
    ()
  |> List.map (fun (schema_tool : Agent_core.Tool.t) ->
    let name = schema_tool.schema.name in
    { name; origin = composition_origin name }, schema_tool)
;;

let validate_task_skills ~task_skill_names ~skill_catalog =
  match Keeper_skill_catalog.instruction_names_for skill_catalog task_skill_names with
  | Ok instruction_skills -> Ok instruction_skills
  | Error (Keeper_skill_catalog.Missing_named_skill { name }) ->
    Error
      ( "declared_skill_missing"
      , Printf.sprintf "current task declares missing skill %S" name )
;;

let project
      ~keeper_name
      ~runtime_id
      ~official_client_kind
      ~native_posture
      ~tool_groups
      ~current_task_id
      ~task_skill_names
      ~skill_catalog
  =
  let surface = Keeper_tool_descriptor.tool_groups_to_surface tool_groups in
  let descriptors =
    Keeper_tool_descriptor.model_visible_descriptors_for_surface ~surface
  in
  let rows = descriptor_rows descriptors @ composition_rows skill_catalog in
  let tools = List.map fst rows in
  let schema_tools = List.map snd rows in
  match validate_task_skills ~task_skill_names ~skill_catalog with
  | Error _ as error -> error
  | Ok instruction_skills ->
    let composition_skills =
      Keeper_skill_catalog.composition_entries skill_catalog
      |> List.map (fun (entry : Keeper_tool_composition_catalog.entry) -> entry.name)
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

let unavailable keeper_name (reason, detail) =
  Unavailable { keeper_name; reason; detail }
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
     | Ok task_skill_names ->
       (match Keeper_run_tools_setup.load_skill_catalog ~base_path:config.base_path with
        | Error error ->
          unavailable
            keeper_name
            ("skill_catalog_unreadable", Agent_core.Error.to_string error)
        | Ok skill_catalog ->
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
                     ~native_posture
                     ~tool_groups:meta.tool_groups
                     ~current_task_id
                     ~task_skill_names
                     ~skill_catalog
                 with
                 | Ok surface -> Available surface
                 | Error error -> unavailable keeper_name error)))))
;;

let string_list values = `List (List.map (fun value -> `String value) values)

let origin_to_yojson = function
  | Descriptor { group } ->
    `Assoc [ "kind", `String "descriptor"; "group", `String group ]
  | Instruction_skill -> `Assoc [ "kind", `String "instruction_skill" ]
  | Composition_skill { source } ->
    `Assoc
      [ "kind", `String "composition_skill"; "skill_source", `String source ]
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
      ; ( "native_posture"
        , match surface.native_posture with
          | None -> `Null
          | Some posture -> `String (Runtime_native_tools.to_string posture) )
      ; "tool_groups", string_list surface.tool_groups
      ; ( "current_task_id"
        , match surface.current_task_id with
          | None -> `Null
          | Some task_id -> `String task_id )
      ; "instruction_skills", string_list surface.instruction_skills
      ; "composition_skills", string_list surface.composition_skills
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
