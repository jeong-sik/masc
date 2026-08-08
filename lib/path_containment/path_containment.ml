type t =
  | Inside
  | Outside
  | Undecidable of string

(* Lexical pass: drop empty and ["."] components, fold [".."] against what has
   been accumulated. Folding past the root keeps the root, matching how the
   kernel treats ["/.."]. *)
let split_normalized absolute =
  let fold acc component =
    match component with
    | "" | "." -> acc
    | ".." -> (match acc with _ :: rest -> rest | [] -> [])
    | _ -> component :: acc
  in
  String.split_on_char '/' absolute |> List.fold_left fold [] |> List.rev

let join segments = "/" ^ String.concat "/" segments

(* [Unix.realpath] raises when the path does not exist, and a write target
   usually does not exist yet. Resolve the longest existing prefix so a symlink
   anywhere along it is followed, then put the components that do not exist back
   on top: they cannot be symlinks, because they are not there. *)
let resolve_existing_prefix segments =
  let rec walk prefix tail =
    match Unix.realpath (join prefix) with
    | resolved -> Ok (split_normalized resolved @ tail)
    | exception (Unix.Unix_error _ | Sys_error _) -> (
        match prefix with
        | [] -> Error (Printf.sprintf "no existing prefix resolves for %S" (join segments))
        | _ ->
            let dropped = List.nth prefix (List.length prefix - 1) in
            let shorter = List.filteri (fun i _ -> i < List.length prefix - 1) prefix in
            walk shorter (dropped :: tail))
  in
  walk segments []

let absolutize raw =
  let trimmed = String.trim raw in
  if String.length trimmed = 0 then Error "empty path"
  else if Char.equal trimmed.[0] '/' then Ok trimmed
  else
    match Sys.getcwd () with
    | cwd -> Ok (Filename.concat cwd trimmed)
    | exception (Sys_error msg | Unix.Unix_error (_, _, msg)) ->
        Error (Printf.sprintf "relative path %S with no reachable cwd: %s" trimmed msg)

let canonical_segments raw =
  match absolutize raw with
  | Error _ as error -> error
  | Ok absolute -> resolve_existing_prefix (split_normalized absolute)

(* Component-wise, so a sibling that merely extends the root's spelling does not
   count as contained. *)
let rec starts_with_components ~prefix segments =
  match prefix, segments with
  | [], _ -> true
  | _, [] -> false
  | p :: prest, s :: srest ->
      String.equal p s && starts_with_components ~prefix:prest srest

let classify ~root ~path =
  match canonical_segments root with
  | Error reason -> Undecidable (Printf.sprintf "root: %s" reason)
  | Ok root_segments -> (
      match canonical_segments path with
      | Error reason -> Undecidable (Printf.sprintf "path: %s" reason)
      | Ok path_segments ->
          if starts_with_components ~prefix:root_segments path_segments then Inside
          else Outside)
