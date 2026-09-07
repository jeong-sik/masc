let ( let* ) = Result.bind

let exact_fields expected = function
  | `Assoc fields as json ->
      if List.sort String.compare (List.map fst fields) = List.sort String.compare expected
      then Ok json
      else Error "missing, duplicate, or unexpected fields"
  | _ -> Error "expected an object"

let require_string json name =
  match Yojson.Safe.Util.member name json with
  | `String value -> Ok value
  | _ -> Error (name ^ " must be a string")

type t =
  | Direct_operation of Keeper_operation_id.t
  | Autonomous_admission of Uuidm.t

let direct_operation value = Direct_operation value
let autonomous_admission value = Autonomous_admission value

let compare a b =
  match a, b with
  | Direct_operation a, Direct_operation b ->
      String.compare (Keeper_operation_id.to_string a)
        (Keeper_operation_id.to_string b)
  | Autonomous_admission a, Autonomous_admission b -> Uuidm.compare a b
  | Direct_operation _, Autonomous_admission _ -> -1
  | Autonomous_admission _, Direct_operation _ -> 1

let equal a b = compare a b = 0

let to_json = function
  | Direct_operation value ->
      `Assoc [ "kind", `String "direct_operation"
             ; "id", `String (Keeper_operation_id.to_string value) ]
  | Autonomous_admission value ->
      `Assoc [ "kind", `String "autonomous_admission"
             ; "id", `String (Uuidm.to_string value) ]

let of_json json =
  let* json = exact_fields [ "kind"; "id" ] json in
  let* kind = require_string json "kind" in
  let* value = require_string json "id" in
  match kind with
  | "direct_operation" ->
      Keeper_operation_id.of_string value |> Result.map direct_operation
  | "autonomous_admission" ->
      (match Uuidm.of_string value with
       | Some id -> Ok (autonomous_admission id)
       | None -> Error "autonomous admission ID must be a UUID")
  | _ -> Error "unknown repetition scope origin"
