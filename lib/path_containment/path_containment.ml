type t =
  | Inside
  | Outside
  | Undecidable of string

let home_guard_bypass_enabled = function
  | Some ("1" | "true") -> true
  | Some _ | None -> false

let split_components path = String.split_on_char '/' path

let join_absolute segments = "/" ^ String.concat "/" segments

let absolute_components raw =
  if String.equal raw "" then Error "empty path"
  else if Char.equal raw.[0] '/' then Ok (split_components raw)
  else
    match Sys.getcwd () with
    | cwd -> Ok (split_components cwd @ split_components raw)
    | exception (Sys_error msg | Unix.Unix_error (_, _, msg)) ->
        Error (Printf.sprintf "relative path %S with no reachable cwd: %s" raw msg)

let resolve raw =
  let ( let* ) = Result.bind in
  let* components = absolute_components raw in
  let rec walk ~symlink_hops resolved_rev pending =
    match pending with
    | [] -> Ok (List.rev resolved_rev)
    | ("" | ".") :: rest -> walk ~symlink_hops resolved_rev rest
    | ".." :: rest ->
        let parent_rev = match resolved_rev with _ :: parent -> parent | [] -> [] in
        walk ~symlink_hops parent_rev rest
    | component :: rest ->
        let candidate =
          join_absolute (List.rev_append resolved_rev [ component ])
        in
        (match Unix.lstat candidate with
         | { Unix.st_kind = Unix.S_LNK; _ } ->
             if symlink_hops >= 40 then
               Error (Printf.sprintf "too many symbolic links while resolving %S" raw)
             else
               (match Unix.readlink candidate with
                | target ->
                    let target_components = split_components target in
                    let target_base =
                      if Filename.is_relative target then resolved_rev else []
                    in
                    walk ~symlink_hops:(symlink_hops + 1) target_base
                      (target_components @ rest)
                | exception (Unix.Unix_error (error, fn, arg)) ->
                    Error
                      (Printf.sprintf "%s(%S): %s" fn arg
                         (Unix.error_message error))
                | exception Sys_error msg -> Error msg)
         | { Unix.st_kind; _ }
           when (not (List.is_empty rest)) && st_kind <> Unix.S_DIR ->
             Error
               (Printf.sprintf "%S is not a directory while resolving %S"
                  candidate raw)
         | _ -> walk ~symlink_hops (component :: resolved_rev) rest
         | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
             walk ~symlink_hops (component :: resolved_rev) rest
         | exception Unix.Unix_error (error, fn, arg) ->
             Error
               (Printf.sprintf "%s(%S): %s" fn arg (Unix.error_message error))
         | exception Sys_error msg -> Error msg)
  in
  walk ~symlink_hops:0 [] components

let rec starts_with_components ~prefix segments =
  match prefix, segments with
  | [], _ -> true
  | _, [] -> false
  | p :: prest, s :: srest ->
      String.equal p s && starts_with_components ~prefix:prest srest

let classify ~root ~path =
  match resolve root with
  | Error reason -> Undecidable (Printf.sprintf "root: %s" reason)
  | Ok root_segments ->
      (match resolve path with
       | Error reason -> Undecidable (Printf.sprintf "path: %s" reason)
       | Ok path_segments ->
           if starts_with_components ~prefix:root_segments path_segments then
             Inside
           else Outside)
