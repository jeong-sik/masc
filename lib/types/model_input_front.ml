type t =
  | At_atom of string
  | After_history of string
  | Empty_history

let equal left right =
  match left, right with
  | At_atom left, At_atom right | After_history left, After_history right ->
    String.equal left right
  | Empty_history, Empty_history -> true
  | (At_atom _ | After_history _ | Empty_history), _ -> false
;;

let to_json = function
  | At_atom digest -> `Assoc [ "kind", `String "at_atom"; "digest", `String digest ]
  | After_history digest ->
    `Assoc [ "kind", `String "after_history"; "digest", `String digest ]
  | Empty_history -> `Assoc [ "kind", `String "empty_history" ]
;;

let valid_digest = String_util.is_lowercase_sha256_hex

let of_json = function
  | `Assoc fields ->
    let exact names = List.sort String.compare (List.map fst fields) = names in
    (match List.assoc_opt "kind" fields, List.assoc_opt "digest" fields with
     | Some (`String "at_atom"), Some (`String digest)
       when exact [ "digest"; "kind" ] && valid_digest digest -> Ok (At_atom digest)
     | Some (`String "after_history"), Some (`String digest)
       when exact [ "digest"; "kind" ] && valid_digest digest -> Ok (After_history digest)
     | Some (`String "empty_history"), None when exact [ "kind" ] -> Ok Empty_history
     | Some _, Some _ | Some _, None | None, Some _ | None, None ->
       Error "model_input_front: invalid kind, digest, or fields")
  | _ -> Error "model_input_front: expected an object"
;;

let validate ~transmitted_atoms ~total_atoms front =
  if transmitted_atoms < 0 || total_atoms < transmitted_atoms then
    Error "model_input_front: invalid atom counts"
  else
    match front with
    | At_atom digest when transmitted_atoms > 0 && valid_digest digest -> Ok ()
    | After_history digest
      when transmitted_atoms = 0 && total_atoms > 0 && valid_digest digest -> Ok ()
    | Empty_history when transmitted_atoms = 0 -> Ok ()
    | At_atom _ | After_history _ | Empty_history ->
      Error "model_input_front: position does not match atom counts"
;;

let permits_empty = function
  | After_history _ | Empty_history -> true
  | At_atom _ -> false
;;
