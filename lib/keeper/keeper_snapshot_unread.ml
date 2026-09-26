type reason =
  | Meta_read_failed of string
  | Row_raised of string

type t = {
  name : string;
  reason : reason;
}

let reason_word = function
  | Meta_read_failed _ -> "meta_read_failed"
  | Row_raised _ -> "row_raised"

let reason_detail = function
  | Meta_read_failed detail | Row_raised detail -> detail

let to_json { name; reason } =
  `Assoc
    [ "name", `String name
    ; "reason", `String (reason_word reason)
    ; "detail", `String (reason_detail reason)
    ]

let string_member key = function
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some (`String value) -> Ok value
     | Some other ->
       Error
         (Printf.sprintf "unread keeper %s is not a string: %s" key
            (Yojson.Safe.to_string other))
     | None -> Error (Printf.sprintf "unread keeper has no %s" key))
  | other ->
    Error
      (Printf.sprintf "unread keeper is not an object: %s"
         (Yojson.Safe.to_string other))

let of_json json =
  let ( let* ) = Result.bind in
  let* name = string_member "name" json in
  let* word = string_member "reason" json in
  let* detail = string_member "detail" json in
  let* reason =
    match word with
    | "meta_read_failed" -> Ok (Meta_read_failed detail)
    | "row_raised" -> Ok (Row_raised detail)
    | other -> Error (Printf.sprintf "unread keeper %s has unknown reason %S" name other)
  in
  Ok { name; reason }

let list_of_json = function
  | `List items ->
    List.fold_right
      (fun item acc ->
         match acc, of_json item with
         | Error _, _ -> acc
         | Ok _, Error e -> Error e
         | Ok rest, Ok row -> Ok (row :: rest))
      items
      (Ok [])
  | other ->
    Error
      (Printf.sprintf "unread keepers is not a list: %s" (Yojson.Safe.to_string other))

let section_field = "unread"

let of_section = function
  | `Assoc fields ->
    (match List.assoc_opt section_field fields with
     | Some value -> list_of_json value
     | None -> Error "keepers section has no unread list")
  | other ->
    Error
      (Printf.sprintf "keepers section is not an object: %s" (Yojson.Safe.to_string other))

let of_snapshot = function
  | `Assoc fields ->
    (match List.assoc_opt "keepers" fields with
     | None -> Ok []
     | Some section -> of_section section)
  | `Null -> Ok []
  | other ->
    Error
      (Printf.sprintf "operator snapshot is not an object: %s" (Yojson.Safe.to_string other))

type listing =
  | Not_listed
  | Listed
  | Unreadable of string

let listing_field = "listing"

let listing_to_json = function
  | Not_listed -> `Assoc [ "state", `String "not_listed" ]
  | Listed -> `Assoc [ "state", `String "listed" ]
  | Unreadable detail ->
    `Assoc [ "state", `String "unreadable"; "detail", `String detail ]

let listing_member key = function
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some (`String value) -> Ok value
     | Some other ->
       Error
         (Printf.sprintf "keeper listing %s is not a string: %s" key
            (Yojson.Safe.to_string other))
     | None -> Error (Printf.sprintf "keeper listing has no %s" key))
  | other ->
    Error
      (Printf.sprintf "keeper listing is not an object: %s"
         (Yojson.Safe.to_string other))

let listing_of_json json =
  match listing_member "state" json with
  | Error detail -> Error detail
  | Ok "not_listed" -> Ok Not_listed
  | Ok "listed" -> Ok Listed
  | Ok "unreadable" ->
    Result.map (fun detail -> Unreadable detail) (listing_member "detail" json)
  | Ok other -> Error (Printf.sprintf "keeper listing has unknown state %S" other)

let listing_of_snapshot = function
  | `Assoc fields ->
    (match List.assoc_opt "keepers" fields with
     | None -> Ok Not_listed
     | Some (`Assoc section) ->
       (match List.assoc_opt listing_field section with
        | Some value -> listing_of_json value
        | None -> Error "keepers section has no listing")
     | Some other ->
       Error
         (Printf.sprintf "keepers section is not an object: %s"
            (Yojson.Safe.to_string other)))
  | `Null -> Ok Not_listed
  | other ->
    Error
      (Printf.sprintf "operator snapshot is not an object: %s" (Yojson.Safe.to_string other))
