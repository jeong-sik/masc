let rec canonical_request_json = function
  | `Assoc fields ->
    fields
    |> List.map (fun (key, value) -> key, canonical_request_json value)
    |> List.stable_sort (fun (left, _) (right, _) -> String.compare left right)
    |> fun canonical -> `Assoc canonical
  | `List items -> `List (List.map canonical_request_json items)
  | other -> other
;;

let request_fingerprint (input : Yojson.Safe.t) =
  let canonical_json = canonical_request_json input |> Yojson.Safe.to_string in
  Digestif.SHA256.(digest_string canonical_json |> to_hex)
;;
