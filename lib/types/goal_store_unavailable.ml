(* RFC-0444 §2.1: the value a goal store this build cannot read produces.

   It lives in masc_types, below both masc_workspace and masc_goal, because
   the task-creation contract in masc_workspace carries it
   ([Workspace_task_create.Goal_source_unavailable]) while the store that
   builds it, masc_goal, depends on masc_workspace. [Goal_store] re-exports
   every constructor so store callers keep writing [Goal_store.Schema_rejected]. *)

type t =
  { file : string
  ; reason : reason
  ; mirror : mirror_status
  ; reset_step : reset_step
  }

and reason =
  | Missing_after_init
  | Unreadable of Unix.error
  | Not_json of string
  | Schema_rejected of { field : string; detail : string }

and mirror_status =
  | Mirror_absent
  | Mirror_unreadable of Unix.error
  | Mirror_decodes of { goal_count : int; updated_at : string }
  | Mirror_rejected of reason

and reset_step =
  | Repair_field of string
  | Reset_goal_store
  | Restore_permission

(* {1 Wire names}

   The constructor name in lowercase snake case. These are the tokens the
   RFC-0444 envelope carries in [reason], [mirror.status] and [reset_step];
   the TS union (PR-3) and [Tui_decode] variant (PR-4) parse them exactly. *)

let reason_name = function
  | Missing_after_init -> "missing_after_init"
  | Unreadable _ -> "unreadable"
  | Not_json _ -> "not_json"
  | Schema_rejected _ -> "schema_rejected"

let mirror_status_name = function
  | Mirror_absent -> "mirror_absent"
  | Mirror_unreadable _ -> "mirror_unreadable"
  | Mirror_decodes _ -> "mirror_decodes"
  | Mirror_rejected _ -> "mirror_rejected"

let reset_step_name = function
  | Repair_field _ -> "repair_field"
  | Reset_goal_store -> "reset_goal_store"
  | Restore_permission -> "restore_permission"

(* {1 Rendering}

   One line for surfaces whose terminus is a string (prompt fragments, WARN
   lines). Render at the very end; never branch on the output. *)

let reason_to_string = function
  | Missing_after_init ->
      "missing_after_init (goals.json is absent while its .last-good mirror exists)"
  | Unreadable error -> "unreadable (" ^ Unix.error_message error ^ ")"
  | Not_json detail -> "not_json (" ^ detail ^ ")"
  | Schema_rejected { field; detail } ->
      Printf.sprintf "schema_rejected field=%s (%s)" field detail

let mirror_status_to_string = function
  | Mirror_absent -> "absent"
  | Mirror_unreadable error -> "unreadable (" ^ Unix.error_message error ^ ")"
  | Mirror_decodes { goal_count; updated_at } ->
      Printf.sprintf "decodes goal_count=%d updated_at=%s" goal_count updated_at
  | Mirror_rejected reason -> "rejected " ^ reason_to_string reason

let reset_step_to_string = function
  | Repair_field field -> "repair field " ^ field
  | Reset_goal_store -> "reset the goal store"
  | Restore_permission -> "restore read permission on the file"

let to_string { file; reason; mirror; reset_step } =
  Printf.sprintf "goal_store: unavailable reason=%s file=%s mirror=%s reset=%s"
    (reason_to_string reason)
    file
    (mirror_status_to_string mirror)
    (reset_step_to_string reset_step)

(* {1 Durable codec}

   RFC-0444 PR-5: a skipped verifier scan keeps the whole value in the
   verification-runs store, so a row read back after a restart is the same
   value the scan saw. This codec loses nothing — every [Unix.error], every
   detail string, the mirror's inner reason — which the wire envelope
   ([Goal_unavailable_envelope], masc_goal) deliberately does not carry. The
   [kind] tokens are the wire names above; every other member is exact, and
   an object with a member this build does not know is refused. A
   [Unix.error] is itself an object whose [kind] is its lowercase name;
   [EUNKNOWNERR] alone adds an integer [code] member. *)

let unix_error_name = function
  | Unix.E2BIG -> "e2big"
  | Unix.EACCES -> "eacces"
  | Unix.EAGAIN -> "eagain"
  | Unix.EBADF -> "ebadf"
  | Unix.EBUSY -> "ebusy"
  | Unix.ECHILD -> "echild"
  | Unix.EDEADLK -> "edeadlk"
  | Unix.EDOM -> "edom"
  | Unix.EEXIST -> "eexist"
  | Unix.EFAULT -> "efault"
  | Unix.EFBIG -> "efbig"
  | Unix.EINTR -> "eintr"
  | Unix.EINVAL -> "einval"
  | Unix.EIO -> "eio"
  | Unix.EISDIR -> "eisdir"
  | Unix.EMFILE -> "emfile"
  | Unix.EMLINK -> "emlink"
  | Unix.ENAMETOOLONG -> "enametoolong"
  | Unix.ENFILE -> "enfile"
  | Unix.ENODEV -> "enodev"
  | Unix.ENOENT -> "enoent"
  | Unix.ENOEXEC -> "enoexec"
  | Unix.ENOLCK -> "enolck"
  | Unix.ENOMEM -> "enomem"
  | Unix.ENOSPC -> "enospc"
  | Unix.ENOSYS -> "enosys"
  | Unix.ENOTDIR -> "enotdir"
  | Unix.ENOTEMPTY -> "enotempty"
  | Unix.ENOTTY -> "enotty"
  | Unix.ENXIO -> "enxio"
  | Unix.EPERM -> "eperm"
  | Unix.EPIPE -> "epipe"
  | Unix.ERANGE -> "erange"
  | Unix.EROFS -> "erofs"
  | Unix.ESPIPE -> "espipe"
  | Unix.ESRCH -> "esrch"
  | Unix.EXDEV -> "exdev"
  | Unix.EWOULDBLOCK -> "ewouldblock"
  | Unix.EINPROGRESS -> "einprogress"
  | Unix.EALREADY -> "ealready"
  | Unix.ENOTSOCK -> "enotsock"
  | Unix.EDESTADDRREQ -> "edestaddrreq"
  | Unix.EMSGSIZE -> "emsgsize"
  | Unix.EPROTOTYPE -> "eprototype"
  | Unix.ENOPROTOOPT -> "enoprotoopt"
  | Unix.EPROTONOSUPPORT -> "eprotonosupport"
  | Unix.ESOCKTNOSUPPORT -> "esocktnosupport"
  | Unix.EOPNOTSUPP -> "eopnotsupp"
  | Unix.EPFNOSUPPORT -> "epfnosupport"
  | Unix.EAFNOSUPPORT -> "eafnosupport"
  | Unix.EADDRINUSE -> "eaddrinuse"
  | Unix.EADDRNOTAVAIL -> "eaddrnotavail"
  | Unix.ENETDOWN -> "enetdown"
  | Unix.ENETUNREACH -> "enetunreach"
  | Unix.ENETRESET -> "enetreset"
  | Unix.ECONNABORTED -> "econnaborted"
  | Unix.ECONNRESET -> "econnreset"
  | Unix.ENOBUFS -> "enobufs"
  | Unix.EISCONN -> "eisconn"
  | Unix.ENOTCONN -> "enotconn"
  | Unix.ESHUTDOWN -> "eshutdown"
  | Unix.ETOOMANYREFS -> "etoomanyrefs"
  | Unix.ETIMEDOUT -> "etimedout"
  | Unix.ECONNREFUSED -> "econnrefused"
  | Unix.EHOSTDOWN -> "ehostdown"
  | Unix.EHOSTUNREACH -> "ehostunreach"
  | Unix.ELOOP -> "eloop"
  | Unix.EOVERFLOW -> "eoverflow"
  | Unix.EUNKNOWNERR _ -> "eunknownerr"

let unix_error_of_name name =
  match name with
  | "e2big" -> Ok Unix.E2BIG
  | "eacces" -> Ok Unix.EACCES
  | "eagain" -> Ok Unix.EAGAIN
  | "ebadf" -> Ok Unix.EBADF
  | "ebusy" -> Ok Unix.EBUSY
  | "echild" -> Ok Unix.ECHILD
  | "edeadlk" -> Ok Unix.EDEADLK
  | "edom" -> Ok Unix.EDOM
  | "eexist" -> Ok Unix.EEXIST
  | "efault" -> Ok Unix.EFAULT
  | "efbig" -> Ok Unix.EFBIG
  | "eintr" -> Ok Unix.EINTR
  | "einval" -> Ok Unix.EINVAL
  | "eio" -> Ok Unix.EIO
  | "eisdir" -> Ok Unix.EISDIR
  | "emfile" -> Ok Unix.EMFILE
  | "emlink" -> Ok Unix.EMLINK
  | "enametoolong" -> Ok Unix.ENAMETOOLONG
  | "enfile" -> Ok Unix.ENFILE
  | "enodev" -> Ok Unix.ENODEV
  | "enoent" -> Ok Unix.ENOENT
  | "enoexec" -> Ok Unix.ENOEXEC
  | "enolck" -> Ok Unix.ENOLCK
  | "enomem" -> Ok Unix.ENOMEM
  | "enospc" -> Ok Unix.ENOSPC
  | "enosys" -> Ok Unix.ENOSYS
  | "enotdir" -> Ok Unix.ENOTDIR
  | "enotempty" -> Ok Unix.ENOTEMPTY
  | "enotty" -> Ok Unix.ENOTTY
  | "enxio" -> Ok Unix.ENXIO
  | "eperm" -> Ok Unix.EPERM
  | "epipe" -> Ok Unix.EPIPE
  | "erange" -> Ok Unix.ERANGE
  | "erofs" -> Ok Unix.EROFS
  | "espipe" -> Ok Unix.ESPIPE
  | "esrch" -> Ok Unix.ESRCH
  | "exdev" -> Ok Unix.EXDEV
  | "ewouldblock" -> Ok Unix.EWOULDBLOCK
  | "einprogress" -> Ok Unix.EINPROGRESS
  | "ealready" -> Ok Unix.EALREADY
  | "enotsock" -> Ok Unix.ENOTSOCK
  | "edestaddrreq" -> Ok Unix.EDESTADDRREQ
  | "emsgsize" -> Ok Unix.EMSGSIZE
  | "eprototype" -> Ok Unix.EPROTOTYPE
  | "enoprotoopt" -> Ok Unix.ENOPROTOOPT
  | "eprotonosupport" -> Ok Unix.EPROTONOSUPPORT
  | "esocktnosupport" -> Ok Unix.ESOCKTNOSUPPORT
  | "eopnotsupp" -> Ok Unix.EOPNOTSUPP
  | "epfnosupport" -> Ok Unix.EPFNOSUPPORT
  | "eafnosupport" -> Ok Unix.EAFNOSUPPORT
  | "eaddrinuse" -> Ok Unix.EADDRINUSE
  | "eaddrnotavail" -> Ok Unix.EADDRNOTAVAIL
  | "enetdown" -> Ok Unix.ENETDOWN
  | "enetunreach" -> Ok Unix.ENETUNREACH
  | "enetreset" -> Ok Unix.ENETRESET
  | "econnaborted" -> Ok Unix.ECONNABORTED
  | "econnreset" -> Ok Unix.ECONNRESET
  | "enobufs" -> Ok Unix.ENOBUFS
  | "eisconn" -> Ok Unix.EISCONN
  | "enotconn" -> Ok Unix.ENOTCONN
  | "eshutdown" -> Ok Unix.ESHUTDOWN
  | "etoomanyrefs" -> Ok Unix.ETOOMANYREFS
  | "etimedout" -> Ok Unix.ETIMEDOUT
  | "econnrefused" -> Ok Unix.ECONNREFUSED
  | "ehostdown" -> Ok Unix.EHOSTDOWN
  | "ehostunreach" -> Ok Unix.EHOSTUNREACH
  | "eloop" -> Ok Unix.ELOOP
  | "eoverflow" -> Ok Unix.EOVERFLOW
  | other -> Error (Printf.sprintf "unknown unix error name %S" other)

let kind_member = "kind"

let object_members = function
  | `Assoc members -> Ok members
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
    Error "expected an object"

(* Every member named, none extra, none missing. *)
let exact_members ~required members =
  let names = List.map fst members in
  let missing = List.filter (fun name -> not (List.mem name names)) required in
  let unknown = List.filter (fun name -> not (List.mem name required)) names in
  match missing, unknown with
  | [], [] -> Ok ()
  | _ ->
    Error
      (Printf.sprintf "members mismatch (missing=[%s] unknown=[%s])"
         (String.concat "," missing) (String.concat "," unknown))

let string_member name members =
  match List.assoc_opt name members with
  | Some (`String value) -> Ok value
  | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _) ->
    Error (Printf.sprintf "member %s must be a string" name)
  | None -> Error (Printf.sprintf "missing member %s" name)

let int_member name members =
  match List.assoc_opt name members with
  | Some (`Int value) -> Ok value
  | Some (`Null | `Bool _ | `Intlit _ | `Float _ | `String _ | `Assoc _ | `List _) ->
    Error (Printf.sprintf "member %s must be an integer" name)
  | None -> Error (Printf.sprintf "missing member %s" name)

let member name members =
  match List.assoc_opt name members with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "missing member %s" name)

let ( let* ) = Result.bind

(* One [Unix.error] as an object. [kind] is the token above; [EUNKNOWNERR],
   the one constructor whose identity is a number, carries that number as
   its own [code] member. No member packs two facts into a string a reader
   would have to split. *)
let unix_error_to_yojson error : Yojson.Safe.t =
  let kind = kind_member, `String (unix_error_name error) in
  match error with
  | Unix.EUNKNOWNERR code -> `Assoc [ kind; "code", `Int code ]
  | Unix.E2BIG | Unix.EACCES | Unix.EAGAIN | Unix.EBADF | Unix.EBUSY | Unix.ECHILD
  | Unix.EDEADLK | Unix.EDOM | Unix.EEXIST | Unix.EFAULT | Unix.EFBIG | Unix.EINTR
  | Unix.EINVAL | Unix.EIO | Unix.EISDIR | Unix.EMFILE | Unix.EMLINK
  | Unix.ENAMETOOLONG | Unix.ENFILE | Unix.ENODEV | Unix.ENOENT | Unix.ENOEXEC
  | Unix.ENOLCK | Unix.ENOMEM | Unix.ENOSPC | Unix.ENOSYS | Unix.ENOTDIR
  | Unix.ENOTEMPTY | Unix.ENOTTY | Unix.ENXIO | Unix.EPERM | Unix.EPIPE | Unix.ERANGE
  | Unix.EROFS | Unix.ESPIPE | Unix.ESRCH | Unix.EXDEV | Unix.EWOULDBLOCK
  | Unix.EINPROGRESS | Unix.EALREADY | Unix.ENOTSOCK | Unix.EDESTADDRREQ
  | Unix.EMSGSIZE | Unix.EPROTOTYPE | Unix.ENOPROTOOPT | Unix.EPROTONOSUPPORT
  | Unix.ESOCKTNOSUPPORT | Unix.EOPNOTSUPP | Unix.EPFNOSUPPORT | Unix.EAFNOSUPPORT
  | Unix.EADDRINUSE | Unix.EADDRNOTAVAIL | Unix.ENETDOWN | Unix.ENETUNREACH
  | Unix.ENETRESET | Unix.ECONNABORTED | Unix.ECONNRESET | Unix.ENOBUFS | Unix.EISCONN
  | Unix.ENOTCONN | Unix.ESHUTDOWN | Unix.ETOOMANYREFS | Unix.ETIMEDOUT
  | Unix.ECONNREFUSED | Unix.EHOSTDOWN | Unix.EHOSTUNREACH | Unix.ELOOP
  | Unix.EOVERFLOW ->
    `Assoc [ kind ]

let unix_error_of_yojson json =
  let* members = object_members json in
  let* kind = string_member kind_member members in
  match kind with
  | "eunknownerr" ->
    let* () = exact_members ~required:[ kind_member; "code" ] members in
    let* code = int_member "code" members in
    Ok (Unix.EUNKNOWNERR code)
  | named ->
    let* () = exact_members ~required:[ kind_member ] members in
    unix_error_of_name named

let reason_to_yojson reason : Yojson.Safe.t =
  let kind = kind_member, `String (reason_name reason) in
  match reason with
  | Missing_after_init -> `Assoc [ kind ]
  | Unreadable error -> `Assoc [ kind; "error", unix_error_to_yojson error ]
  | Not_json detail -> `Assoc [ kind; "detail", `String detail ]
  | Schema_rejected { field; detail } ->
    `Assoc [ kind; "field", `String field; "detail", `String detail ]

let reason_of_yojson json =
  let* members = object_members json in
  let* kind = string_member kind_member members in
  match kind with
  | "missing_after_init" ->
    let* () = exact_members ~required:[ kind_member ] members in
    Ok Missing_after_init
  | "unreadable" ->
    let* () = exact_members ~required:[ kind_member; "error" ] members in
    let* error_json = member "error" members in
    let* error = unix_error_of_yojson error_json in
    Ok (Unreadable error)
  | "not_json" ->
    let* () = exact_members ~required:[ kind_member; "detail" ] members in
    let* detail = string_member "detail" members in
    Ok (Not_json detail)
  | "schema_rejected" ->
    let* () = exact_members ~required:[ kind_member; "field"; "detail" ] members in
    let* field = string_member "field" members in
    let* detail = string_member "detail" members in
    Ok (Schema_rejected { field; detail })
  | other -> Error (Printf.sprintf "unknown goal store reason %S" other)

let mirror_status_to_yojson mirror : Yojson.Safe.t =
  let kind = kind_member, `String (mirror_status_name mirror) in
  match mirror with
  | Mirror_absent -> `Assoc [ kind ]
  | Mirror_unreadable error -> `Assoc [ kind; "error", unix_error_to_yojson error ]
  | Mirror_decodes { goal_count; updated_at } ->
    `Assoc [ kind; "goal_count", `Int goal_count; "updated_at", `String updated_at ]
  | Mirror_rejected reason -> `Assoc [ kind; "reason", reason_to_yojson reason ]

let mirror_status_of_yojson json =
  let* members = object_members json in
  let* kind = string_member kind_member members in
  match kind with
  | "mirror_absent" ->
    let* () = exact_members ~required:[ kind_member ] members in
    Ok Mirror_absent
  | "mirror_unreadable" ->
    let* () = exact_members ~required:[ kind_member; "error" ] members in
    let* error_json = member "error" members in
    let* error = unix_error_of_yojson error_json in
    Ok (Mirror_unreadable error)
  | "mirror_decodes" ->
    let* () = exact_members ~required:[ kind_member; "goal_count"; "updated_at" ] members in
    let* goal_count = int_member "goal_count" members in
    let* updated_at = string_member "updated_at" members in
    Ok (Mirror_decodes { goal_count; updated_at })
  | "mirror_rejected" ->
    let* () = exact_members ~required:[ kind_member; "reason" ] members in
    let* reason_json = member "reason" members in
    let* reason = reason_of_yojson reason_json in
    Ok (Mirror_rejected reason)
  | other -> Error (Printf.sprintf "unknown goal store mirror status %S" other)

let reset_step_to_yojson reset_step : Yojson.Safe.t =
  let kind = kind_member, `String (reset_step_name reset_step) in
  match reset_step with
  | Repair_field field -> `Assoc [ kind; "field", `String field ]
  | Reset_goal_store | Restore_permission -> `Assoc [ kind ]

let reset_step_of_yojson json =
  let* members = object_members json in
  let* kind = string_member kind_member members in
  match kind with
  | "repair_field" ->
    let* () = exact_members ~required:[ kind_member; "field" ] members in
    let* field = string_member "field" members in
    Ok (Repair_field field)
  | "reset_goal_store" ->
    let* () = exact_members ~required:[ kind_member ] members in
    Ok Reset_goal_store
  | "restore_permission" ->
    let* () = exact_members ~required:[ kind_member ] members in
    Ok Restore_permission
  | other -> Error (Printf.sprintf "unknown goal store reset step %S" other)

let record_to_yojson { file; reason; mirror; reset_step } : Yojson.Safe.t =
  `Assoc
    [ "file", `String file
    ; "reason", reason_to_yojson reason
    ; "mirror", mirror_status_to_yojson mirror
    ; "reset_step", reset_step_to_yojson reset_step
    ]

let record_of_yojson json =
  let* members = object_members json in
  let* () = exact_members ~required:[ "file"; "reason"; "mirror"; "reset_step" ] members in
  let* file = string_member "file" members in
  let* reason_json = member "reason" members in
  let* reason = reason_of_yojson reason_json in
  let* mirror_json = member "mirror" members in
  let* mirror = mirror_status_of_yojson mirror_json in
  let* reset_json = member "reset_step" members in
  let* reset_step = reset_step_of_yojson reset_json in
  Ok { file; reason; mirror; reset_step }
