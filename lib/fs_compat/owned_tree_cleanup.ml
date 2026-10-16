type directory =
  { path : string; device : int; inode : int; owner_uid : int; permissions : int }

external remove_bound_tree : directory array -> unit = "caml_masc_owned_tree_remove"

let remove chain =
  let valid_directory directory =
    not (Filename.is_relative directory.path)
    && not (String.contains directory.path '\000')
    && directory.owner_uid = Unix.getuid ()
    && directory.permissions land 0o022 = 0
  in
  let rec valid_children parent = function
    | [] -> true
    | child :: rest ->
      Filename.dirname child.path = parent.path
      && Capability_leaf.is_valid (Filename.basename child.path)
      && valid_directory child && valid_children child rest
  in
  match chain with
  | [] | [_] -> Error "cleanup requires a retained root and strict descendant"
  | root :: children ->
    let canonical_spelling = match String.split_on_char '/' root.path with
      | "" :: parts -> List.for_all Capability_leaf.is_valid parts
      | _ -> false in
    if not (canonical_spelling && valid_directory root && valid_children root children)
    then Error "cleanup directory chain is not a private owned descendant"
    else
      try remove_bound_tree (Array.of_list chain); Ok () with
      | Unix.Unix_error (error, operation, path) ->
        Error (Printf.sprintf "%s(%s): %s" operation path (Unix.error_message error))
