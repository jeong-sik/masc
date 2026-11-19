open Keeper_memory_os_types

let ( let* ) = Result.bind

(* A closed set of tokens. Writing is a total match, so a new constructor
   does not compile until it has a token. Reading goes through the list of
   every value: a value missing from its list is written and then refused,
   which the round trip test of every line shows. *)
let of_token ~token_of values field fields =
  let* token = wire_string_field field fields in
  match List.find_opt (fun value -> String.equal (token_of value) token) values with
  | Some value -> Ok value
  | None -> wire_fail [ Wire_field field ] (Unknown_token token)
;;

let object_fields = function
  | `Assoc fields -> Ok fields
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    wire_here Expected_object
;;

let list_field field fields decode =
  let* items = wire_list_field field fields in
  let rec collect index decoded = function
    | [] -> Ok (List.rev decoded)
    | item :: rest ->
      let* value = wire_at_element field index (decode item) in
      collect (index + 1) (value :: decoded) rest
  in
  collect 0 [] items
;;
