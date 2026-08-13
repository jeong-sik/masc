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

(* RFC-0378 §5.3b: one wire key. The codebase scope carries the canonical
   slug itself — literally the partitioned store's directory name and the
   same value the co-view context hands the keeper — validated by the same
   acceptance the address mint applies. The full-URL and repo_id
   spellings are gone: a display name and a catalog id are projection
   labels, not addresses. *)
type ide_scope =
  | Scope_codebase of { slug : string }
  | Scope_keeper_lane of { keeper_id : string }

(* Keeper-lane reads still address the repo-unattributed store directory:
   production paths stopped writing there (RFC-0378 rung B — keeper facts'
   durable SSOT is turn-records/tool_calls), so this serves pre-existing
   rows until rung E deletes them with the directory. *)
let partition_of_ide_scope = function
  | Scope_codebase { slug } -> Ide_paths.By_url slug
  | Scope_keeper_lane _ -> Ide_paths.Legacy_default
;;

(* One shape for the two declared scopes, so both the absent-scope and
   present-scope resolvers below classify identically. *)
let scope_params uri =
  nonempty_query_param uri "codebase", nonempty_query_param uri "keeper_lane"
;;

let resolve_declared_scope ~params =
  match params with
  | Some slug, None ->
    if Agent_observation.Code_address.valid_codebase slug
    then Ok (Scope_codebase { slug })
    else
      Error
        (ide_error
           "invalid_codebase"
           "codebase must be a canonical host_path slug (e.g. github.com_owner_repo)")
  | None, Some keeper_id ->
    (* [keeper_id] is a filter value compared against stored event fields,
       never a filesystem path, so no registry lookup gates it: validating
       against currently-active keepers would hide the history of any
       keeper that is offline or renamed. An unknown id returns an
       explicitly keeper_lane-scoped empty result. *)
    Ok (Scope_keeper_lane { keeper_id })
  | Some _, Some _ ->
    Error
      (ide_error
         "conflicting_ide_scope"
         "IDE scope must specify exactly one of codebase or keeper_lane")
  | None, None ->
    Error
      (ide_error "missing_ide_scope" "IDE scope is required; pass codebase or keeper_lane")
;;

let resolve_ide_scope_for_query ~state:_ ~uri =
  resolve_declared_scope ~params:(scope_params uri)
;;

let resolve_optional_ide_scope_for_query ~state:_ ~uri =
  match scope_params uri with
  | None, None -> Ok None
  | params -> Result.map Option.some (resolve_declared_scope ~params)
;;
