let ( let* ) = Result.bind
let object_ = function `Assoc fields -> Ok fields | _ -> Error "expected an object"
let unique fields =
  let names = List.map fst fields in
  if List.length names = List.length (List.sort_uniq String.compare names) then Ok ()
  else Error "duplicate object member"
let exact names json = let* fields = object_ json in
  if List.sort String.compare (List.map fst fields) = List.sort String.compare names then Ok fields
  else Error ("expected exactly fields: " ^ String.concat ", " names)
let traverse f values = List.fold_left (fun acc value ->
  let* acc = acc in let* value = f value in Ok (value :: acc)) (Ok []) values |> Result.map List.rev
let rec canonical = function
  | `Assoc fields -> let* () = unique fields in
      let* fields = traverse (fun (key, value) -> let* value = canonical value in Ok (key, value)) fields in
      Ok (`Assoc (List.sort (fun (a, _) (b, _) -> String.compare a b) fields))
  | `List values -> traverse canonical values |> Result.map (fun values -> `List values)
  | `Float value when not (Float.is_finite value) -> Error "non-finite JSON number"
  | `Float value when Float.is_integer value ->
      (* JSON encodings 1 and 1.0 identify the same normalized request. The
         decimal serializer also handles values beyond native integer range. *)
      let encoded = Printf.sprintf "%.0f" value in
      (try Ok (Yojson.Safe.from_string encoded) with Yojson.Json_error message -> Error message)
  | `Intlit value ->
      (try match Yojson.Safe.from_string value with
        | (`Int _ | `Intlit _) as value -> Ok value
        | _ -> Error "invalid JSON integer"
       with Yojson.Json_error message -> Error message)
  | (`Null | `Bool _ | `Int _ | `Float _ | `String _) as value -> Ok value
