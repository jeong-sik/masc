(** IDE observation scope — see [server_ide_scope.mli]. *)

type ide_error =
  { code : string
  ; message : string
  }

let ide_error code message = { code; message }

let nonempty_query_param uri key =
  match Uri.get_query_param uri key with
  | Some raw ->
    let value = String.trim raw in
    if String.equal value "" then None else Some value
  | None -> None
;;

type ide_scope =
  | Scope_canonical_url of
      { raw : string
      ; slug : string
      }
  | Scope_repo_id of
      { repo_id : string
      ; slug : string
      }
  | Scope_keeper_lane of { keeper_id : string }

(* Keeper-lane reads address the repo-unattributed observation bucket
   ([_orphan/] on disk). A keeper turn is a keeper-timeline fact, not a
   repo fact: turn events and coordination tool events carry no file, so
   they are written without a [By_url] partition. Before this scope
   existed, read routes could only address [By_url] partitions, which made
   that data unreachable from any API while it kept accumulating — the
   read/write split-brain from the 2026-07-07 IDE observation audit. *)
let partition_of_ide_scope = function
  | Scope_canonical_url { slug; _ } | Scope_repo_id { slug; _ } ->
    Ide_paths.By_url slug
  | Scope_keeper_lane _ -> Ide_paths.Legacy_default
;;

let base_path_of_state state = (Mcp_server.workspace_config state).base_path

(* One shape for the three declared scopes, so both the absent-scope and
   present-scope resolvers below classify identically. *)
let scope_params uri =
  ( nonempty_query_param uri "canonical_url"
  , nonempty_query_param uri "repo_id"
  , nonempty_query_param uri "keeper_lane" )
;;

let resolve_declared_scope ~state ~params =
  match params with
  | Some raw, None, None ->
    (match Ide_paths.canonical_url_of_remote raw with
     | Some slug -> Ok (Scope_canonical_url { raw; slug })
     | None -> Error (ide_error "invalid_canonical_url" "canonical_url is invalid"))
  | None, Some repo_id, None ->
    (match Repo_store.find_url_by_id ~base_path:(base_path_of_state state) repo_id with
     | Error message -> Error (ide_error "repository_catalog_unavailable" message)
     | Ok None ->
       Error
         (ide_error "unmatched_repo_id" "repo_id does not match a configured repository")
     | Ok (Some url) ->
       (match Ide_paths.canonical_url_of_remote url with
        | Some slug -> Ok (Scope_repo_id { repo_id; slug })
        | None -> Error (ide_error "no_canonical_url" "repo_id has no valid canonical URL")))
  | None, None, Some keeper_id ->
    (* [keeper_id] is a filter value compared against stored event fields,
       never a filesystem path, so no registry lookup gates it: validating
       against currently-active keepers would hide the history of any
       keeper that is offline or renamed. An unknown id returns an
       explicitly keeper_lane-scoped empty result. *)
    Ok (Scope_keeper_lane { keeper_id })
  | Some _, Some _, _ | Some _, _, Some _ | _, Some _, Some _ ->
    Error
      (ide_error
         "conflicting_ide_scope"
         "IDE scope must specify exactly one of repo_id, canonical_url, or keeper_lane")
  | None, None, None ->
    Error
      (ide_error
         "missing_ide_scope"
         "IDE scope is required; pass repo_id, canonical_url, or keeper_lane")
;;

let resolve_ide_scope_for_query ~state ~uri =
  resolve_declared_scope ~state ~params:(scope_params uri)
;;

let resolve_optional_ide_scope_for_query ~state ~uri =
  match scope_params uri with
  | None, None, None -> Ok None
  | params -> Result.map Option.some (resolve_declared_scope ~state ~params)
;;
