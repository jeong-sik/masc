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

(* A free argv token names a remote only when it is written as one. The
   canonicaliser alone accepts [owner/repo] with [owner] in the host slot, so
   canonicalising every token reported API endpoint paths
   ([repos/o/r/pulls/1/update-branch]), [-C] paths ([tmp/pr34356]) and gh's
   [OWNER/REPO] shorthand to the judge as unregistered repositories: 250 of
   the 480 require_human rationales in 2026-09 cite that (#34401). *)
let remote_reference_of_token token =
  if Agent_observation.remote_url_syntax token
  then canonical_repository_id token
  else None
;;

(* gh documents its [-R]/[--repo] value as [[HOST/]OWNER/REPO]
   (gh 2.87 [--help]) with the host defaulting to github.com, and also
   accepts a full URL there. A value in none of those shapes names no
   repository; the judge then sees no reference rather than a wrong one. *)
let gh_default_host = "github.com"

let gh_repo_flag_reference value =
  match remote_reference_of_token value with
  | Some canonical_id -> Some canonical_id
  | None ->
    (match String.split_on_char '/' value with
     | [ owner; repo ] when owner <> "" && repo <> "" ->
       canonical_repository_id
         (Printf.sprintf "https://%s/%s/%s" gh_default_host owner repo)
     | [ host; owner; repo ] when host <> "" && owner <> "" && repo <> "" ->
       canonical_repository_id (Printf.sprintf "https://%s/%s/%s" host owner repo)
     | _ -> None)
;;

(* Every spelling pflag accepts for gh's repo flag: [-R v], [-Rv],
   [--repo v], [--repo=v]. Each hit is the index of the token that carries
   the value, and the value as written. *)
let gh_repo_flag_values argv =
  let attached_long = "--repo=" in
  let attached_short = "-R" in
  let rec walk index acc = function
    | [] -> List.rev acc
    | ("-R" | "--repo") :: value :: rest ->
      walk (index + 2) ((index + 1, value) :: acc) rest
    | token :: rest when String.starts_with ~prefix:attached_long token ->
      let n = String.length attached_long in
      walk (index + 1) ((index, String.sub token n (String.length token - n)) :: acc) rest
    | token :: rest
      when String.length token > String.length attached_short
           && String.starts_with ~prefix:attached_short token ->
      let n = String.length attached_short in
      walk (index + 1) ((index, String.sub token n (String.length token - n)) :: acc) rest
    | _ :: rest -> walk (index + 1) acc rest
  in
  walk 0 [] argv
;;

(* Repository references in argv order: tokens written as remotes anywhere,
   plus gh's repo flag values. A full URL handed to the flag is already a
   remote token, so rows are keyed by argument index to keep one per token. *)
let repository_reference_candidates argv =
  let remote_tokens =
    List.filter_mapi
      (fun argument_index argument ->
         Option.map
           (fun canonical_id -> argument_index, argument, canonical_id)
           (remote_reference_of_token argument))
      argv
  in
  match argv with
  | "gh" :: _ ->
    let flagged =
      List.filter_map
        (fun (argument_index, value) ->
           Option.map
             (fun canonical_id -> argument_index, value, canonical_id)
             (gh_repo_flag_reference value))
        (gh_repo_flag_values argv)
    in
    List.sort_uniq
      (fun (a, _, _) (b, _, _) -> Int.compare a b)
      (remote_tokens @ flagged)
  | _ -> remote_tokens
;;

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
  match repository_reference_candidates argv with
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
        (match remote_reference_of_token argument with
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
