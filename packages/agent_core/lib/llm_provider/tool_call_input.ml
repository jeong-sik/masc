type parse_error =
  | Invalid_json of string
  | Not_object

(* A provider can bind the same key twice inside one tool-argument object.
   JSON itself does not forbid it, [Yojson] keeps both bindings in the assoc
   list, and [Yojson.Safe.Util.member] answers with the first one. So the tool
   runs on the first binding while the checkpoint encoder -- which refuses a
   repeated key outright -- fails the whole turn afterwards, and the recovery
   copy stores that call with its input emptied (#31677).

   The ambiguity is resolved here, at the boundary that turns provider text
   into an executable input: the first binding is kept and the later ones are
   dropped, so the value the tool receives is the value the encoder stores.
   Keeping the FIRST binding is what preserves today's execution result --
   [member] already read that one. The dropped names are handed back so a
   caller can report that the provider sent them. *)
let rec deduplicate json =
  match json with
  | `Assoc fields ->
    let _bound, dropped, rev_fields =
      List.fold_left
        (fun (bound, dropped, rev_fields) (name, value) ->
          if List.mem name bound
          then bound, name :: dropped, rev_fields
          else (
            let value, nested = deduplicate value in
            ( name :: bound
            , List.rev_append nested dropped
            , (name, value) :: rev_fields )))
        ([], [], [])
        fields
    in
    `Assoc (List.rev rev_fields), List.rev dropped
  | `List values ->
    let dropped, rev_values =
      List.fold_left
        (fun (dropped, rev_values) value ->
          let value, nested = deduplicate value in
          List.rev_append nested dropped, value :: rev_values)
        ([], [])
        values
    in
    `List (List.rev rev_values), List.rev dropped
  | (`String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null) as leaf ->
    leaf, []
;;

let validate_object = function
  | `Assoc _ as input -> Ok (deduplicate input)
  | `List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null ->
    Error Not_object
;;

let parse_object raw =
  match Yojson.Safe.from_string raw with
  | input -> validate_object input
  | exception Yojson.Json_error message -> Error (Invalid_json message)
;;

let%test "a repeated key keeps its first binding and is reported" =
  match parse_object {|{"owner":"first","owner":"second"}|} with
  | Ok (`Assoc [ ("owner", `String "first") ], [ "owner" ]) -> true
  | Ok _ | Error _ -> false
;;

let%test "the kept binding is the one Yojson member already reads" =
  (* The execution result must not move: the tool ran on [member]'s answer
     before this boundary resolved anything. *)
  let raw = {|{"limit":10,"limit":99}|} in
  let read_by_member =
    Yojson.Safe.Util.member "limit" (Yojson.Safe.from_string raw)
  in
  match parse_object raw with
  | Ok (`Assoc [ ("limit", kept) ], [ "limit" ]) -> kept = read_by_member
  | Ok _ | Error _ -> false
;;

let%test "a repeat nested under a kept key is resolved too" =
  match parse_object {|{"a":{"b":1,"b":2}}|} with
  | Ok (`Assoc [ ("a", `Assoc [ ("b", `Int 1) ]) ], [ "b" ]) -> true
  | Ok _ | Error _ -> false
;;

let%test "a repeat inside a list element is resolved too" =
  match parse_object {|{"xs":[{"k":1,"k":2}]}|} with
  | Ok (`Assoc [ ("xs", `List [ `Assoc [ ("k", `Int 1) ] ]) ], [ "k" ]) -> true
  | Ok _ | Error _ -> false
;;

let%test "an object that binds every key once is returned unchanged" =
  match parse_object {|{"a":1,"b":2}|} with
  | Ok (`Assoc [ ("a", `Int 1); ("b", `Int 2) ], []) -> true
  | Ok _ | Error _ -> false
;;

let%test "a non-object payload is still refused" =
  match parse_object {|[1,2]|} with
  | Error Not_object -> true
  | Ok _ | Error (Invalid_json _) -> false
;;
