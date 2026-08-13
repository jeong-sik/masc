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

(* RFC-0378 §5.3b/§5.2: one wire key, one store. The scope carries the
   canonical slug itself — the store directory name and the co-view
   value — validated by the same acceptance the address mint applies.
   The keeper-lane scope died with the orphan store it existed to
   reach: keeper facts' durable record is the keeper tool_calls and
   turn-records stores. *)
type ide_scope = Scope_codebase of { slug : string }

let codebase_of_ide_scope (Scope_codebase { slug }) = slug

let resolve_declared_scope ~params =
  match params with
  | Some slug ->
    if Agent_observation.Code_address.valid_codebase slug
    then Ok (Scope_codebase { slug })
    else
      Error
        (ide_error
           "invalid_codebase"
           "codebase must be a canonical host_path slug (e.g. example.com_owner_repo)")
  | None ->
    Error (ide_error "missing_ide_scope" "IDE scope is required; pass codebase=<slug>")
;;

let resolve_ide_scope_for_query ~state:_ ~uri =
  resolve_declared_scope ~params:(nonempty_query_param uri "codebase")
;;

let resolve_optional_ide_scope_for_query ~state:_ ~uri =
  match nonempty_query_param uri "codebase" with
  | None -> Ok None
  | Some _ as params -> Result.map Option.some (resolve_declared_scope ~params)
;;
