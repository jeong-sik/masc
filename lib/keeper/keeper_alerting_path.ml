(** Keeper_alerting path safety and tool output helpers. *)

include Keeper_path_rejection

(** Operator-facing telemetry — single call site for all path-rejection
    counters.  The [kind] label is derived from the constructor name,
    eliminating hard-coded label strings scattered across the resolver. *)
let rejection_to_telemetry (r : keeper_path_rejection) : unit =
  let kind =
    match r with
    | Path_required -> "path_required"
    | Invalid_lexical_endpoint -> "invalid_lexical_endpoint"
    | Invalid_normalized_path_projection _ -> "invalid_normalized_path_projection"
    | Allowed_paths_normalized_empty _ -> "allowed_paths_normalized_empty"
    | Outside_sandbox _ -> "out_of_roots"
  in
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string PathRejection)
    ~labels:[ "kind", kind ]
    ()
;;

let project_root_of_config (config : Workspace.config) : string =
  let base = config.base_path in
  if Filename.basename base = Common.masc_dirname then Filename.dirname base else base
;;

let strip_trailing_slashes = Env_config_core.strip_trailing_slashes

let normalize_path_for_check (path : string) : string =
  try Fs_compat.realpath path with
  | Unix.Unix_error _ ->
    (* Walk up the directory tree until we find an ancestor that exists and
       can be resolved via realpath, then reconstruct the suffix.
       This handles symlinks (e.g., /tmp -> /private/tmp on macOS) even when
       intermediate directories do not exist on disk.
       Tail-recursive to avoid stack overflow on deep untrusted paths. *)
    let rec collect_suffix p acc =
      let parent = Filename.dirname p in
      if parent = p
      then
        (* Reached filesystem root without a successful realpath. *)
        p, acc
      else (
        match
          try Some (Fs_compat.realpath p) with
          | Unix.Unix_error _ -> None
        with
        | Some resolved -> resolved, acc
        | None -> collect_suffix parent (Filename.basename p :: acc))
    in
    let resolved_base, suffix_parts = collect_suffix path [] in
    List.fold_left Filename.concat resolved_base suffix_parts
;;

let normalize_path_for_check_stripped path =
  normalize_path_for_check path |> strip_trailing_slashes
;;

let allowed_path_projection ~(root : string) (path : string) =
  let raw = String.trim path in
  if raw = ""
  then None
  else (
    let candidate = if Filename.is_relative raw then Filename.concat root raw else raw in
    let candidate = strip_trailing_slashes candidate in
    let normalized = normalize_path_for_check candidate |> strip_trailing_slashes in
    if normalized = "" then None else Some (candidate, normalized))
;;

let normalize_allowed_path_for_check ~root path =
  allowed_path_projection ~root path |> Option.map snd
;;

let valid_child_name = Fs_compat.is_capability_leaf

type absolute_path_components =
  { anchor : string
  ; components : string list
  }

type allowed_root_projection =
  { normalized_path : string
  ; normalized_components : absolute_path_components
  ; capability_components : absolute_path_components
  }

let absolute_path_components path =
  if Filename.is_relative path || String.equal path ""
  then None
  else
    let rec collect current components =
      let parent = Filename.dirname current in
      if String.equal parent current
      then Some { anchor = current; components }
      else
        let component = Filename.basename current in
        if valid_child_name component
        then collect parent (component :: components)
        else None
    in
    collect path []
;;

let rec drop_component_prefix prefix components =
  match prefix, components with
  | [], suffix -> Some suffix
  | expected :: prefix_rest, actual :: components_rest
    when String.equal expected actual ->
    drop_component_prefix prefix_rest components_rest
  | _ -> None
;;

let relative_components_under
      ~(root : absolute_path_components)
      ~(target : absolute_path_components)
  =
  if String.equal root.anchor target.anchor
  then drop_component_prefix root.components target.components
  else None
;;

let is_within_root_norm ~(root_norm : string) (path : string) : bool =
  let normalized = normalize_path_for_check path |> strip_trailing_slashes in
  match absolute_path_components root_norm, absolute_path_components normalized with
  | Some root, Some target -> Option.is_some (relative_components_under ~root ~target)
  | None, _ | _, None -> false
;;

let is_within_allowed_norms ~(target_norm : string) (allowed_norms : string list) : bool =
  match absolute_path_components target_norm with
  | None -> false
  | Some target ->
    List.exists
      (fun allowed_norm ->
         match absolute_path_components allowed_norm with
         | None -> false
         | Some root -> Option.is_some (relative_components_under ~root ~target))
      allowed_norms
;;

type confined_path =
  { root : string
  ; root_identity : resource_identity option
  ; anchor_root : string
  ; root_relative_path : string
  ; target_components : string list
  ; endpoint_components : string list
  ; lexical_leaf : string option
  ; host_path : string
  ; containment_path : string
  }

and resource_identity =
  { device : Int64.t
  ; inode : Int64.t
  }

type path_effect_operation =
  | Atomic_replace_entry
  | Patch_then_atomic_replace_entry
  | Append_pinned_resource
  | Create_entry_exclusive

type path_effect_parent_scope =
  { parent_components : string list
  ; resource : resource_identity
  ; create_missing_parents : string list
  ; created_directory_permissions : int
  }

type path_effect_locator =
  { root : string
  ; root_resource : resource_identity
  ; target_components : string list
  ; endpoint_components : string list
  ; leaf : string
  ; parent : path_effect_parent_scope option
  ; target_resource : resource_identity option
  ; source : path_effect_source option
  }

and path_effect_source =
  { components : string list
  ; resource : resource_identity
  }

type path_effect =
  { operation : path_effect_operation
  ; locator : path_effect_locator
  ; result_file_permissions : int option
  }

type path_effect_projection_error =
  | Allowed_root_identity_unavailable of { root : string }
  | Invalid_parent_component of
      { index : int
      ; value : string
      }
  | Invalid_missing_parent_component of
      { index : int
      ; value : string
      }
  | Target_has_no_lexical_leaf
  | Parent_scope_does_not_cover_target of
      { parent_components : string list
      ; create_missing_parents : string list
      ; target_parent_components : string list
      }
  | Patch_source_has_no_endpoint
  | Recovery_target_invalid of Fs_compat.atomic_replace_recovery_target_error

type atomic_replace_projection =
  { gate_effect : path_effect
  ; recovery_target : Fs_compat.atomic_replace_recovery_target
  }

type confined_path_endpoint =
  | Lexical_entry
  | Follow_referent

let relative_path_of_components = function
  | [] -> "."
  | components -> String.concat Filename.dir_sep components
;;

let confined_root (target : confined_path) = target.root
let confined_anchor_root (target : confined_path) = target.anchor_root
let confined_root_relative_path (target : confined_path) = target.root_relative_path
let confined_relative_components (target : confined_path) = target.target_components
let confined_relative_path (target : confined_path) =
  relative_path_of_components target.target_components
;;
let confined_host_path (target : confined_path) = target.host_path
let confined_containment_path (target : confined_path) = target.containment_path
let confined_endpoint_components (target : confined_path) = target.endpoint_components
let confined_endpoint_relative_path (target : confined_path) =
  relative_path_of_components target.endpoint_components
;;

let path_effect_projection_error_to_string = function
  | Allowed_root_identity_unavailable { root } ->
    Printf.sprintf
      "filesystem allowed root identity unavailable for Gate effect: %s"
      root
  | Invalid_parent_component { index; value } ->
    Printf.sprintf
      "filesystem effect parent component %d is invalid: %S"
      index
      value
  | Invalid_missing_parent_component { index; value } ->
    Printf.sprintf
      "filesystem effect missing-parent component %d is invalid: %S"
      index
      value
  | Target_has_no_lexical_leaf ->
    "filesystem effect target has no lexical leaf"
  | Parent_scope_does_not_cover_target
      { parent_components
      ; create_missing_parents
      ; target_parent_components
      } ->
    Printf.sprintf
      "filesystem effect parent scope does not cover target: parent=%s missing=%s target_parent=%s"
      (relative_path_of_components parent_components)
      (relative_path_of_components create_missing_parents)
      (relative_path_of_components target_parent_components)
  | Patch_source_has_no_endpoint ->
    "filesystem patch source has no confined endpoint"
  | Recovery_target_invalid error ->
    Fs_compat.atomic_replace_recovery_target_error_to_string error
;;

let atomic_replace_gate_effect projection = projection.gate_effect
let atomic_replace_recovery_target projection = projection.recovery_target

let resource_identity_of_unix_path path =
  try
    let stat = Unix.stat path in
    Some
      { device = Int64.of_int stat.Unix.st_dev
      ; inode = Int64.of_int stat.Unix.st_ino
      }
  with
  | Unix.Unix_error _ -> None
;;

let resource_identity_of_eio_stat (stat : Eio.File.Stat.t) =
  { device = stat.dev; inode = stat.ino }
;;

let equal_resource_identity left right =
  Int64.equal left.device right.device && Int64.equal left.inode right.inode
;;

let verify_confined_root_capability target root_dir =
  match target.root_identity with
  | None ->
    Error
      (Printf.sprintf
         "filesystem allowed root identity unavailable during resolution: %s"
         target.root)
  | Some expected ->
    (try
       let stat = Eio.Path.stat ~follow:true root_dir in
       let actual = resource_identity_of_eio_stat stat in
       if stat.kind <> `Directory
       then
         Error
           (Printf.sprintf
              "filesystem allowed root is not a directory: %s"
              target.root)
       else if equal_resource_identity expected actual
       then Ok ()
       else
         Error
           (Printf.sprintf
              "filesystem allowed root changed between resolution and capability acquisition: %s"
              target.root)
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | Eio.Io _ as exn -> Error (Printexc.to_string exn))
;;

let validate_components ~invalid components =
  let rec loop index = function
    | [] -> Ok components
    | component :: rest ->
      if valid_child_name component
      then loop (index + 1) rest
      else Error (invalid ~index ~value:component)
  in
  loop 0 components
;;

let path_effect_parent_scope
      ~parent_components
      ~(resource : Eio.File.Stat.t)
      ~create_missing_parents
      ~created_directory_permissions
  =
  match
    validate_components
      ~invalid:(fun ~index ~value -> Invalid_parent_component { index; value })
      parent_components
  with
  | Error _ as error -> error
  | Ok parent_components ->
    (match
       validate_components
         ~invalid:(fun ~index ~value ->
           Invalid_missing_parent_component { index; value })
         create_missing_parents
     with
     | Error _ as error -> error
     | Ok create_missing_parents ->
       Ok
         { parent_components
         ; resource = resource_identity_of_eio_stat resource
         ; create_missing_parents
         ; created_directory_permissions
         })
;;

let split_last components =
  match List.rev components with
  | [] -> None
  | leaf :: reversed_parent -> Some (List.rev reversed_parent, leaf)
;;

let parent_scope_covers_target
      (parent : path_effect_parent_scope)
      (target : confined_path)
  =
  match split_last target.target_components with
  | None -> Error Target_has_no_lexical_leaf
  | Some (target_parent_components, _leaf) ->
    let projected_parent_components =
      parent.parent_components @ parent.create_missing_parents
    in
    if List.equal String.equal projected_parent_components target_parent_components
    then Ok ()
    else
      Error
        (Parent_scope_does_not_cover_target
           { parent_components = parent.parent_components
           ; create_missing_parents = parent.create_missing_parents
           ; target_parent_components
           })
;;

let path_effect
      ~operation
      ?parent
      ?target_resource
      ?source
      ~result_file_permissions
      target
  =
  match target.root_identity with
  | None ->
    Error (Allowed_root_identity_unavailable { root = target.root })
  | Some root_resource ->
    (match parent with
     | Some scope ->
       (match parent_scope_covers_target scope target with
        | Error _ as error -> error
        | Ok () ->
          (match target.lexical_leaf with
           | None -> Error Target_has_no_lexical_leaf
           | Some leaf ->
             Ok
               { operation
               ; locator =
                   { root = target.root
                   ; root_resource
                   ; target_components = target.target_components
                   ; endpoint_components = target.endpoint_components
                   ; leaf
                   ; parent
                   ; target_resource
                   ; source
                   }
               ; result_file_permissions
               }))
     | None ->
       (match target.lexical_leaf with
        | None -> Error Target_has_no_lexical_leaf
        | Some leaf ->
          Ok
            { operation
            ; locator =
                { root = target.root
                ; root_resource
                ; target_components = target.target_components
                ; endpoint_components = target.endpoint_components
                ; leaf
                ; parent
                ; target_resource
                ; source
                }
            ; result_file_permissions
            }))
;;

let atomic_replace_projection
      ~operation
      ~parent
      ?source
      ~result_file_permissions
      target
  =
  match
    path_effect
      ~operation
      ~parent
      ?source
      ~result_file_permissions:(Some result_file_permissions)
      target
  with
  | Error _ as error -> error
  | Ok gate_effect ->
    let root_resource = gate_effect.locator.root_resource in
    let parent_components =
      parent.parent_components @ parent.create_missing_parents
    in
    (match
       Fs_compat.atomic_replace_recovery_target
         ~allowed_root_path:target.root
         ~allowed_root_device:root_resource.device
         ~allowed_root_inode:root_resource.inode
         ~parent_components
         ~target_leaf:gate_effect.locator.leaf
         ~permissions:result_file_permissions
     with
     | Error error -> Error (Recovery_target_invalid error)
     | Ok recovery_target -> Ok { gate_effect; recovery_target })
;;

let atomic_replace_effect ~parent ~result_file_permissions target =
  atomic_replace_projection
    ~operation:Atomic_replace_entry
    ~parent
    ~result_file_permissions
    target
;;

let patch_then_atomic_replace_effect
      ~parent
      ~(source_resource : Eio.File.Stat.t)
      ~result_file_permissions
      (target : confined_path)
  =
  match target.endpoint_components with
  | [] -> Error Patch_source_has_no_endpoint
  | components ->
    atomic_replace_projection
      ~operation:Patch_then_atomic_replace_entry
      ~parent
      ~source:
        { components
        ; resource = resource_identity_of_eio_stat source_resource
        }
      ~result_file_permissions
      target
;;

let create_entry_exclusive_effect ~parent ~result_file_permissions target =
  path_effect
    ~operation:Create_entry_exclusive
    ~parent
    ~result_file_permissions:(Some result_file_permissions)
    target
;;

let append_pinned_resource_effect target stat =
  path_effect
    ~operation:Append_pinned_resource
    ~target_resource:(resource_identity_of_eio_stat stat)
    ~result_file_permissions:None
    target
;;

let path_effect_operation_to_string = function
  | Atomic_replace_entry -> "atomic_replace_entry"
  | Patch_then_atomic_replace_entry -> "patch_then_atomic_replace_entry"
  | Append_pinned_resource -> "append_pinned_resource"
  | Create_entry_exclusive -> "create_entry_exclusive"
;;

let resource_identity_to_yojson identity =
  `Assoc
    [ "device", `Intlit (Int64.to_string identity.device)
    ; "inode", `Intlit (Int64.to_string identity.inode)
    ]
;;

let path_effect_to_yojson gate_effect =
  let parent =
    match gate_effect.locator.parent with
    | None -> []
    | Some parent ->
      [ ( "parent"
        , `Assoc
            [ ( "relative_path"
              , `String
                  (relative_path_of_components parent.parent_components) )
            ; "resource", resource_identity_to_yojson parent.resource
            ; ( "create_missing_parents"
              , `List
                  (List.map
                     (fun name ->
                        `Assoc
                          [ "name", `String name
                          ; ( "permissions"
                            , `Int parent.created_directory_permissions )
                          ])
                     parent.create_missing_parents) )
            ] )
      ]
  in
  let target_resource =
    match gate_effect.locator.target_resource with
    | None -> []
    | Some identity ->
      [ "target_resource", resource_identity_to_yojson identity ]
  in
  let source =
    match gate_effect.locator.source with
    | None -> []
    | Some source ->
      [ ( "source"
        , `Assoc
            [ ( "relative_path"
              , `String (relative_path_of_components source.components) )
            ; "resource", resource_identity_to_yojson source.resource
            ] )
      ]
  in
  let result =
    match gate_effect.result_file_permissions with
    | None -> []
    | Some permissions ->
      [ ( "result"
        , `Assoc
            [ "kind", `String "regular_file"
            ; "permissions", `Int permissions
            ] )
      ]
  in
  let relative_path =
    relative_path_of_components gate_effect.locator.target_components
  in
  let endpoint_relative_path =
    relative_path_of_components gate_effect.locator.endpoint_components
  in
  `Assoc
    ([ "operation", `String (path_effect_operation_to_string gate_effect.operation)
     ; ( "locator"
       , `Assoc
           ([ "kind", `String "confined_path"
            ; "root", `String gate_effect.locator.root
            ; "root_resource", resource_identity_to_yojson gate_effect.locator.root_resource
            ; "relative_path", `String relative_path
            ; "endpoint_relative_path", `String endpoint_relative_path
            ; "leaf", `String gate_effect.locator.leaf
            ]
            @ parent
            @ target_resource
            @ source) )
     ]
     @ result)
;;

let normalize_confined_endpoint endpoint candidate =
  match endpoint with
  | Follow_referent -> Ok (normalize_path_for_check_stripped candidate)
  | Lexical_entry ->
    let candidate = strip_trailing_slashes candidate in
    let leaf = Filename.basename candidate in
    if not (valid_child_name leaf)
    then Error Invalid_lexical_endpoint
    else
      let parent = Filename.dirname candidate |> normalize_path_for_check_stripped in
      Ok (Filename.concat parent leaf |> strip_trailing_slashes)
;;

(* Build a sandbox boundary error message that teaches the LLM
   *why* the path was rejected — not just *that* it was. Bare "X not allowed"
   triggers retry loops; including the resolved candidate plus the
   sandbox boundary rule lets the keeper correct on the next call without
   re-trying the same broken interpretation. See
   [memory/feedback_tool-error-messages-teach-llm.md]. *)

let resolve_keeper_confined_path
      ~(config : Workspace.config)
      ~(allowed_paths : string list)
      ~(endpoint : confined_path_endpoint)
      ~(raw_path : string)
  : (confined_path, keeper_path_rejection) result
  =
  let raw = String.trim raw_path in
  if raw = ""
  then Error Path_required
  else (
    let root = project_root_of_config config in
    let candidate = if Filename.is_relative raw then Filename.concat root raw else raw in
    match normalize_confined_endpoint endpoint candidate with
    | Error rejection -> Error rejection
    | Ok target_norm ->
      let project_root_norm = normalize_path_for_check_stripped root in
      (match absolute_path_components project_root_norm with
       | None ->
         Error
           (Invalid_normalized_path_projection { path = project_root_norm })
       | Some project_root_components ->
         let allowed_roots =
           let projected_roots =
             if allowed_paths = []
             then [ project_root_norm, project_root_norm ]
             else List.filter_map (allowed_path_projection ~root) allowed_paths
           in
           List.filter_map
             (fun (capability_path, normalized_path) ->
                match absolute_path_components normalized_path with
                | None -> None
                | Some normalized_components ->
                  let capability_path =
                    match
                      normalize_confined_endpoint Lexical_entry capability_path
                    with
                    | Ok lexical_path -> lexical_path
                    | Error Invalid_lexical_endpoint -> normalized_path
                    | Error
                        ( Path_required
                        | Invalid_normalized_path_projection _
                        | Allowed_paths_normalized_empty _
                        | Outside_sandbox _ ) ->
                      normalized_path
                  in
                  let capability_components =
                    Option.value
                      ~default:normalized_components
                      (absolute_path_components capability_path)
                  in
                  Some
                    { normalized_path
                    ; normalized_components
                    ; capability_components
                    })
             projected_roots
         in
         (match allowed_roots with
          | [] ->
            Error
              (Allowed_paths_normalized_empty
                 { count = List.length allowed_paths })
          | _ ->
            (match absolute_path_components target_norm with
             | None ->
               Error
                 (Invalid_normalized_path_projection { path = target_norm })
             | Some endpoint_absolute ->
               (match
                  List.find_map
                    (fun root_projection ->
                       relative_components_under
                         ~root:root_projection.normalized_components
                         ~target:endpoint_absolute
                       |> Option.map (fun endpoint_components ->
                         root_projection, endpoint_components))
                    allowed_roots
                with
                | None -> Error (Outside_sandbox { raw })
                | Some (root_projection, endpoint_components) ->
                  if endpoint = Lexical_entry && endpoint_components = []
                  then Error Invalid_lexical_endpoint
                  else
                    let target_components =
                      match
                        normalize_confined_endpoint Lexical_entry candidate
                      with
                      | Error Invalid_lexical_endpoint -> endpoint_components
                      | Error
                          ( Path_required
                          | Invalid_normalized_path_projection _
                          | Allowed_paths_normalized_empty _
                          | Outside_sandbox _ ) ->
                        endpoint_components
                      | Ok lexical_norm ->
                        (match absolute_path_components lexical_norm with
                         | None -> endpoint_components
                         | Some lexical_absolute ->
                           Option.value
                             ~default:endpoint_components
                             (relative_components_under
                                ~root:
                                  root_projection.normalized_components
                                ~target:lexical_absolute))
                    in
                    let lexical_leaf =
                      split_last target_components |> Option.map snd
                    in
                    let anchor_root, root_relative_path =
                      match
                        relative_components_under
                          ~root:project_root_components
                          ~target:root_projection.capability_components
                      with
                      | Some capability_components ->
                        ( project_root_norm
                        , relative_path_of_components capability_components )
                      | None ->
                        (match
                           relative_components_under
                             ~root:project_root_components
                             ~target:root_projection.normalized_components
                         with
                         | Some root_components ->
                           ( project_root_norm
                           , relative_path_of_components root_components )
                         | None ->
                           (match
                              split_last
                                root_projection.normalized_components.components
                            with
                            | None -> root_projection.normalized_path, "."
                            | Some (_parent_components, leaf) ->
                              ( Filename.dirname
                                  root_projection.normalized_path
                              , leaf )))
                    in
                    Ok
                      { root = root_projection.normalized_path
                      ; root_identity =
                          resource_identity_of_unix_path
                            root_projection.normalized_path
                      ; anchor_root
                      ; root_relative_path
                      ; target_components
                      ; endpoint_components
                      ; lexical_leaf
                      ; host_path = candidate
                      ; containment_path = target_norm
                      })))))
;;

let resolve_keeper_path_within_allowed_roots ~config ~allowed_paths ~raw_path =
  resolve_keeper_confined_path
    ~config
    ~allowed_paths
    ~endpoint:Follow_referent
    ~raw_path
  |> Result.map confined_host_path
;;

let resolve_keeper_target_path = resolve_keeper_path_within_allowed_roots

(* Playground path SSOT lives in [Playground_paths] (masc_config). These
   names preserve the historical keeper-facing API. Do not re-implement
   the literal ".masc/playground" layout here — edit [Playground_paths]
   if it ever changes. *)
let sanitize_keeper_name = Playground_paths.sanitize_keeper_name
let playground_path_of_keeper = Playground_paths.bundle_root
let playground_mind_path = Playground_paths.mind_path
let playground_repos_path = Playground_paths.repos_path
let playground_bundle_paths = Playground_paths.bundle_paths

let sandbox_path_of_meta ~(meta : Keeper_meta_contract.keeper_meta) =
  Keeper_sandbox.allowed_root_rel_of_meta ~meta
;;

let sandbox_bundle_paths_of_meta ~(meta : Keeper_meta_contract.keeper_meta) =
  let root = sandbox_path_of_meta ~meta |> strip_trailing_slashes in
  [ root ^ "/"; root ^ "/mind/"; root ^ "/repos/" ]
;;

let ensure_playground_bundle ~(config : Workspace.config) ~(name : string) : string list =
  let root = project_root_of_config config in
  playground_bundle_paths name
  |> List.map (Filename.concat root)
  |> List.map Keeper_fs.ensure_dir
;;

let ensure_sandbox_bundle ~(config : Workspace.config) ~(meta : Keeper_meta_contract.keeper_meta)
  : string list
  =
  let root = project_root_of_config config in
  sandbox_bundle_paths_of_meta ~meta
  |> List.map (Filename.concat root)
  |> List.map Keeper_fs.ensure_dir
;;

let ensure_sandbox_bundle_for_profile
      ~(config : Workspace.config)
      ~(name : string)
      ~(sandbox_profile : Keeper_types_profile_sandbox.sandbox_profile)
  : string list
  =
  let root = project_root_of_config config in
  let sandbox_root =
    Keeper_sandbox.host_root_rel_of_profile sandbox_profile name |> strip_trailing_slashes
  in
  [ sandbox_root ^ "/"; sandbox_root ^ "/mind/"; sandbox_root ^ "/repos/" ]
  |> List.map (Filename.concat root)
  |> List.map Keeper_fs.ensure_dir
;;

(** Compute effective read allowed_paths from keeper meta.
    Returns the single sandbox root plus any explicit [allowed_paths]
    entries. Every additional path must be listed explicitly in
    [allowed_paths]. *)
let effective_allowed_paths ~(meta : Keeper_meta_contract.keeper_meta) : string list =
  let sandbox_paths = Keeper_sandbox.allowed_path_roots_of_meta ~meta in
  sandbox_paths @ meta.allowed_paths
;;

(** Compute effective write allowed_paths from keeper meta.
    Returns the single sandbox root plus any explicit [allowed_paths]
    entries. Every additional path must be listed explicitly in
    [allowed_paths]. *)
let effective_write_allowed_paths ~(meta : Keeper_meta_contract.keeper_meta) : string list =
  let sandbox_paths = Keeper_sandbox.allowed_path_roots_of_meta ~meta in
  sandbox_paths @ meta.allowed_paths
;;

(** Resolve a path for read-only access within the keeper's effective
    allowlist. The allowlist is usually the keeper sandbox root
    plus any explicit custom paths. *)
let resolve_keeper_read_path
      ~(config : Workspace.config)
      ~(allowed_paths : string list)
      ~(raw_path : string)
  : (string, keeper_path_rejection) result
  =
  resolve_keeper_path_within_allowed_roots ~config ~allowed_paths ~raw_path
;;

let process_status_to_json (st : Unix.process_status) : Yojson.Safe.t =
  Exec_core.process_status_to_json st
;;

let extract_user_messages (ctx_work : Keeper_types.working_context) : string list =
  Keeper_context_runtime.messages_of_context ctx_work
  |> List.filter_map (fun (m : Agent_sdk.Types.message) ->
    if m.role = Agent_sdk.Types.User
    then (
      let c = String.trim (Agent_sdk.Types.text_of_message m) in
      if c = "" then None else Some c)
    else None)
;;
