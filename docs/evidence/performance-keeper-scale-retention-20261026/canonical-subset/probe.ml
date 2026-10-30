type canonical_json_error =
  | Duplicate_object_key of string
  | Non_finite_float

let canonical_json value =
  let rec normalize = function
    | `Assoc fields ->
      let rec loop seen normalized = function
        | [] ->
          normalized
          |> List.sort (fun (left, _) (right, _) -> String.compare left right)
          |> fun fields -> Ok (`Assoc fields)
        | (name, value) :: rest ->
          if List.mem name seen
          then Error (Duplicate_object_key name)
          else
            (match normalize value with
             | Error _ as error -> error
             | Ok value -> loop (name :: seen) ((name, value) :: normalized) rest)
      in
      loop [] [] fields
    | `List values ->
      let rec loop normalized = function
        | [] -> Ok (`List (List.rev normalized))
        | value :: rest ->
          (match normalize value with
           | Error _ as error -> error
           | Ok value -> loop (value :: normalized) rest)
      in
      loop [] values
    | `Float value when not (Float.is_finite value) ->
      Error Non_finite_float
    | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _) as value ->
      Ok value
  in
  normalize value
;;


let () = match Yojson.Safe.from_file Sys.argv.(1) with
| `List values -> List.iter (fun value -> match canonical_json value with
 | Ok value -> print_endline (Yojson.Safe.to_string value)
 | Error _ -> failwith "canonicalization failed") values
| _ -> failwith "expected list"
