type parse_error =
  | Invalid_json of string
  | Not_object

(* A provider can bind the same key twice inside one tool-argument object. The
   rule for resolving that lives in [Json_object_keys] because the payload a
   tool sends back needs the same answer; see there for why the first binding
   wins. Applying it here means the value the tool receives is the value the
   checkpoint encoder can store, instead of one it refuses after the tool has
   already run (#31677). *)
let validate_object = function
  | `Assoc _ as input -> Ok (Json_object_keys.deduplicate input)
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
