type retention = Exact_next_block

type t =
  { retention : retention
  ; payload : Yojson.Safe.t
  }

type malformed_reason =
  | Invalid_json
  | Expected_object
  | Duplicate_field of string
  | Unexpected_field of string
  | Unsupported_schema
  | Unsupported_version
  | Unsupported_retention
  | Missing_payload

type decoded =
  | Not_replay
  | Malformed_replay of malformed_reason
  | Replay of t

let schema = "oas.provider_replay"
let wire_prefix = schema ^ ".v1:"

let first_duplicate fields =
  let rec loop seen = function
    | [] -> None
    | (name, _) :: rest ->
      if List.mem name seen then Some name else loop (name :: seen) rest
  in
  loop [] fields
;;

let first_unexpected ~allowed fields =
  fields
  |> List.find_map (fun (name, _) -> if List.mem name allowed then None else Some name)
;;

let exact_object_fields ~allowed = function
  | `Assoc fields ->
    (match first_duplicate fields with
     | Some name -> Error (Duplicate_field name)
     | None ->
       (match first_unexpected ~allowed fields with
        | Some name -> Error (Unexpected_field name)
        | None -> Ok fields))
  | `List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null ->
    Error Expected_object
;;

let encode_exact_next_block ~payload =
  wire_prefix
  ^ Yojson.Safe.to_string
      (`Assoc
          [ "schema", `String schema
          ; "version", `Int 1
          ; "retention", `String "exact_next_block"
          ; "payload", payload
          ])
;;

let decode data =
  if not (String.starts_with ~prefix:wire_prefix data)
  then Not_replay
  else (
    let encoded =
      String.sub
        data
        (String.length wire_prefix)
        (String.length data - String.length wire_prefix)
    in
    try
      match
        Yojson.Safe.from_string encoded
        |> exact_object_fields ~allowed:[ "schema"; "version"; "retention"; "payload" ]
      with
      | Error reason -> Malformed_replay reason
      | Ok fields ->
        (match List.assoc_opt "schema" fields with
         | Some (`String value) when String.equal value schema ->
           (match List.assoc_opt "version" fields with
            | Some (`Int 1) ->
              (match List.assoc_opt "retention" fields with
               | Some (`String "exact_next_block") ->
                 (match List.assoc_opt "payload" fields with
                  | Some payload -> Replay { retention = Exact_next_block; payload }
                  | None -> Malformed_replay Missing_payload)
               | Some _ | None -> Malformed_replay Unsupported_retention)
            | Some _ | None -> Malformed_replay Unsupported_version)
         | Some _ | None -> Malformed_replay Unsupported_schema)
    with
    | Yojson.Json_error _ -> Malformed_replay Invalid_json)
;;
