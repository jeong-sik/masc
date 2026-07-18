type t =
  | Targets of string list
  | Broadcast
  | Thread_participants of string list
  | Discoverable

let canonical_identities identities =
  identities
  |> List.filter_map (fun identity ->
    match String.lowercase_ascii (String.trim identity) with
    | "" -> None
    | canonical -> Some canonical)
  |> List.sort_uniq String.compare
;;

let targets identities =
  match canonical_identities identities with
  | [] -> Error "Board Targets audience requires at least one identity"
  | canonical -> Ok (Targets canonical)
;;

let thread_participants identities =
  Thread_participants (canonical_identities identities)
;;

let broadcast = Broadcast
let discoverable = Discoverable

let to_yojson = function
  | Targets identities ->
    `Assoc
      [ "kind", `String "targets"
      ; "identities", `List (List.map (fun identity -> `String identity) identities)
      ]
  | Broadcast -> `Assoc [ "kind", `String "broadcast" ]
  | Thread_participants identities ->
    `Assoc
      [ "kind", `String "thread_participants"
      ; "identities", `List (List.map (fun identity -> `String identity) identities)
      ]
  | Discoverable -> `Assoc [ "kind", `String "discoverable" ]
;;

let exact_fields ~context expected fields =
  let names = List.map fst fields in
  let actual = List.sort_uniq String.compare names in
  let expected = List.sort_uniq String.compare expected in
  if List.length names <> List.length actual
  then Error (context ^ " contains duplicate fields")
  else if actual = expected
  then Ok ()
  else Error (context ^ " fields do not match the audience schema")
;;

let identities_of_json ~context fields =
  match List.assoc_opt "identities" fields with
  | Some (`List values) ->
    let rec collect acc = function
      | [] -> Ok (List.rev acc)
      | `String identity :: rest when not (String.equal identity "") ->
        collect (identity :: acc) rest
      | _ -> Error (context ^ ".identities must contain only non-empty strings")
    in
    Result.bind (collect [] values) (fun identities ->
      let canonical = canonical_identities identities in
      if identities = canonical
      then Ok canonical
      else Error (context ^ ".identities must be canonical, sorted, and unique"))
  | Some _ -> Error (context ^ ".identities must be an array")
  | None -> Error (context ^ " is missing identities")
;;

let of_yojson = function
  | `Assoc fields ->
    let context = "Board signal audience" in
    (match List.assoc_opt "kind" fields with
     | Some (`String "targets") ->
       Result.bind (exact_fields ~context [ "kind"; "identities" ] fields) (fun () ->
         Result.bind (identities_of_json ~context fields) targets)
     | Some (`String "broadcast") ->
       Result.map (fun () -> Broadcast) (exact_fields ~context [ "kind" ] fields)
     | Some (`String "thread_participants") ->
       Result.bind (exact_fields ~context [ "kind"; "identities" ] fields) (fun () ->
         Result.map
           (fun identities -> Thread_participants identities)
           (identities_of_json ~context fields))
     | Some (`String "discoverable") ->
       Result.map (fun () -> Discoverable) (exact_fields ~context [ "kind" ] fields)
     | Some (`String unknown) ->
       Error (Printf.sprintf "%s.kind is unknown: %S" context unknown)
     | Some _ -> Error (context ^ ".kind must be a string")
     | None -> Error (context ^ " is missing kind"))
  | _ -> Error "Board signal audience must be an object"
;;
