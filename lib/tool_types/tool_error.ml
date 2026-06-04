type t =
  | Not_found of { what : string }
  | Permission_denied of { path : string }
  | Invalid_input of { detail : string }
  | Resource_exhausted of { resource : string; detail : string }
  | Timeout of { stage : string; elapsed_sec : float }
  | Cancelled of { reason : string }
  | Internal_error of { detail : string; exn : exn option }

let kind = function
  | Not_found _ -> "not_found"
  | Permission_denied _ -> "permission_denied"
  | Invalid_input _ -> "invalid_input"
  | Resource_exhausted _ -> "resource_exhausted"
  | Timeout _ -> "timeout"
  | Cancelled _ -> "cancelled"
  | Internal_error _ -> "internal_error"

let to_json t =
  let k = ("kind", `String (kind t)) in
  match t with
  | Not_found { what } ->
      `Assoc [ k; ("what", `String what) ]
  | Permission_denied { path } ->
      `Assoc [ k; ("path", `String path) ]
  | Invalid_input { detail } ->
      `Assoc [ k; ("detail", `String detail) ]
  | Resource_exhausted { resource; detail } ->
      `Assoc [ k; ("resource", `String resource); ("detail", `String detail) ]
  | Timeout { stage; elapsed_sec } ->
      `Assoc [ k; ("stage", `String stage); ("elapsed_sec", `Float elapsed_sec) ]
  | Cancelled { reason } ->
      `Assoc [ k; ("reason", `String reason) ]
  | Internal_error { detail; exn = _ } ->
      (* `exn` deliberately omitted from wire format — it stays in-process
         for debug logs only. *)
      `Assoc [ k; ("detail", `String detail) ]

let to_string t =
  match t with
  | Not_found { what } ->
      Printf.sprintf "not_found: %s" what
  | Permission_denied { path } ->
      Printf.sprintf "permission_denied: %s" path
  | Invalid_input { detail } ->
      Printf.sprintf "invalid_input: %s" detail
  | Resource_exhausted { resource; detail } ->
      Printf.sprintf "resource_exhausted[%s]: %s" resource detail
  | Timeout { stage; elapsed_sec } ->
      Printf.sprintf "timeout[%s]: %.3fs" stage elapsed_sec
  | Cancelled { reason } ->
      Printf.sprintf "cancelled: %s" reason
  | Internal_error { detail; exn = _ } ->
      Printf.sprintf "internal_error: %s" detail

let of_exn ?detail exn =
  let default_detail () =
    match detail with
    | Some d -> d
    | None -> Printexc.to_string exn
  in
  match exn with
  | Stdlib.Not_found ->
      Not_found { what = default_detail () }
  | Failure msg ->
      let d = match detail with Some d -> d | None -> msg in
      Internal_error { detail = d; exn = Some exn }
  | Sys_error msg ->
      let d = match detail with Some d -> d | None -> msg in
      Internal_error { detail = d; exn = Some exn }
  | Unix.Unix_error (Unix.EACCES, _, path) ->
      let p = if path = "" then default_detail () else path in
      Permission_denied { path = p }
  | Unix.Unix_error (Unix.ENOENT, _, path) ->
      let p = if path = "" then default_detail () else path in
      Not_found { what = p }
  | Unix.Unix_error ((Unix.EMFILE | Unix.ENFILE), op, _) ->
      Resource_exhausted { resource = "fd"; detail = op }
  | _ ->
      Internal_error { detail = default_detail (); exn = Some exn }
