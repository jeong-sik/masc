open Keeper_approval_queue_rules_types

let string_list_member name = function
  | `Assoc fields ->
    (match List.assoc_opt name fields with
     | Some (`List values) ->
       let rec strings acc = function
         | [] -> Some (List.rev acc)
         | `String value :: rest -> strings (value :: acc) rest
         | _ :: _ -> None
       in
       strings [] values
     | Some _ | None -> None)
  | _ -> None
;;

let execute_envelope input =
  match input with
  | `Assoc fields ->
    (match
       ( List.assoc_opt "schema" fields
       , List.assoc_opt "input" fields
       , List.assoc_opt "cwd" fields
       , List.assoc_opt "sandbox_profile" fields
       , List.assoc_opt "sandbox_target" fields )
     with
     | ( Some (`String "masc.keeper_gate.request.v1")
       , Some execute_input
       , Some (`String cwd)
       , Some (`String sandbox_profile)
       , Some (`String sandbox_target) ) ->
       Some (execute_input, cwd, sandbox_profile, sandbox_target)
     | _ -> None)
  | _ -> None
;;

let canonical_repository_id = Agent_observation.canonical_url_of_remote

let repository_catalog_match repositories canonical_id =
  List.filter
    (fun (repository : Repo_manager_types.repository) ->
       match canonical_repository_id repository.url with
       | Some candidate -> String.equal candidate canonical_id
       | None -> false)
    repositories
;;

let repository_reference_json ~catalog ~argument_index ~raw ~canonical_id =
  let catalog_match =
    match catalog with
    | Error detail ->
      `Assoc
        [ "state", `String "catalog_unavailable"
        ; "detail", `String detail
        ]
    | Ok repositories ->
      (match repository_catalog_match repositories canonical_id with
       | [] -> `Assoc [ "state", `String "unregistered" ]
       | [ repository ] ->
         `Assoc
           [ "state", `String "registered"
           ; "repository_id", `String repository.id
           ]
       | matches ->
         `Assoc
           [ "state", `String "ambiguous"
           ; ( "repository_ids"
             , `List
                 (List.map
                    (fun (repository : Repo_manager_types.repository) ->
                       `String repository.id)
                    matches) )
           ])
  in
  `Assoc
    [ "argument_index", `Int argument_index
    ; "raw", `String raw
    ; "canonical_id", `String canonical_id
    ; "catalog_match", catalog_match
    ]
;;

let repository_references_json ~base_path argv =
  let candidates =
    List.filter_mapi
      (fun argument_index argument ->
         Option.map
           (fun canonical_id -> argument_index, argument, canonical_id)
           (canonical_repository_id argument))
      argv
  in
  match candidates with
  | [] ->
    `Assoc
      [ "state", `String "no_references"
      ; "items", `List []
      ]
  | candidates ->
    let catalog = Repo_store.load_all ~base_path in
    let references =
      List.map
        (fun (argument_index, raw, canonical_id) ->
           repository_reference_json
             ~catalog
             ~argument_index
             ~raw
             ~canonical_id)
        candidates
    in
    `Assoc
      [ ( "state"
        , `String
            (match catalog with
             | Error _ -> "catalog_unavailable"
             | Ok _ -> "available") )
      ; "items", `List references
      ]
;;

let explicit_git_clone_destination ~cwd argv =
  match argv with
  | "git" :: "clone" :: _ ->
    let rec after_repository = function
      | [] -> None
      | argument :: rest ->
        (match canonical_repository_id argument with
         | None -> after_repository rest
         | Some _ ->
           (match rest with
            | destination :: _ when not (String.starts_with ~prefix:"-" destination) ->
              Some destination
            | _ -> None))
    in
    Option.map
      (fun destination ->
         let absolute_path =
           if Filename.is_relative destination
           then Filename.concat cwd destination
           else destination
         in
         `Assoc
           [ "argument", `String destination
           ; "absolute_path", `String absolute_path
           ; ( "state"
             , `String (if Sys.file_exists absolute_path then "present" else "absent") )
           ])
      (after_repository argv)
  | _ -> None
;;

let task_link_json (entry : pending_approval) =
  let request =
    `Assoc
      [ "source", `String "approval_request"
      ; "task_id", Json_util.string_opt_to_json entry.task_id
      ; "goal_id", Json_util.string_opt_to_json entry.goal_id
      ]
  in
  let config = Workspace.default_config entry.audit_base_path in
  match Workspace_backlog.read_backlog_r config with
  | Error detail ->
    `Assoc
      [ "state", `String "backlog_unavailable"
      ; "request", request
      ; "detail", `String detail
      ]
  | Ok backlog ->
    let active_task_ids =
      Workspace_task.active_owned_task_ids_for_agent
        config
        ~agent_name:entry.keeper_name
        backlog
    in
    let task_goal_index = Workspace_goal_index.build_task_goal_index_for_config config in
    let linked_goal_ids =
      let task_ids =
        match entry.task_id with
        | None -> active_task_ids
        | Some task_id -> task_id :: active_task_ids
      in
      task_ids
      |> List.concat_map (fun task_id ->
           Option.value (Hashtbl.find_opt task_goal_index task_id) ~default:[])
    in
    let goal_ids =
      (match entry.goal_id with
       | None -> linked_goal_ids
       | Some goal_id -> goal_id :: linked_goal_ids)
      |> List.sort_uniq String.compare
    in
    let state =
      match entry.task_id, active_task_ids with
      | None, [] -> "unbound"
      | None, _ :: _ -> "request_link_missing"
      | Some task_id, active when List.mem task_id active -> "consistent"
      | Some _, _ -> "request_link_stale"
    in
    `Assoc
      [ "state", `String state
      ; "request", request
      ; ( "active_task_ids"
        , `List (List.map (fun task_id -> `String task_id) active_task_ids) )
      ; "linked_goal_ids", `List (List.map (fun goal_id -> `String goal_id) goal_ids)
      ]
;;

let for_approval (entry : pending_approval) =
  let execution =
    match execute_envelope entry.input with
    | None -> `Assoc [ "state", `String "not_execute" ]
    | Some (execute_input, cwd, sandbox_profile, sandbox_target) ->
      let argv = string_list_member "argv" execute_input in
      `Assoc
        ([ "state", `String "resolved"
         ; "cwd", `String cwd
         ; "cwd_scope", `String "keeper_execute_resolved"
         ; "sandbox_profile", `String sandbox_profile
         ; "sandbox_target", `String sandbox_target
         ; ( "repository_references"
           , match argv with
             | Some argv ->
               repository_references_json ~base_path:entry.audit_base_path argv
             | None ->
               `Assoc
                 [ "state", `String "not_structured_argv"
                 ; "items", `List []
                 ] )
         ]
         @ match argv with
           | Some argv ->
             Option.fold
               ~none:[]
               ~some:(fun destination -> [ "git_clone_destination", destination ])
               (explicit_git_clone_destination ~cwd argv)
           | None -> [])
  in
  `Assoc
    [ "schema", `String "masc.keeper_gate.host_context.v1"
    ; "provenance", `String "host_observed"
    ; "task_link", task_link_json entry
    ; "execution", execution
    ]
;;
