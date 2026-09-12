(** JSON wire form for constitution articles (RFC-0442).

    The schema is closed: an unknown or duplicated field is a rejection, not a
    field to ignore. A decoder that answers [None] tells its caller only that
    something is wrong, so every rejection names its path and reason. *)

open World_constitution_types

(* Wire vocabulary. Encoder and decoder share these so a rename cannot move
   only one side. *)
let field_id = "id"
let field_text = "text"
let field_evidence = "evidence"
let field_proposer = "proposer"
let field_state = "state"
let field_last_cited_at = "last_cited_at"
let field_uri = "uri"
let field_sha256 = "sha256"
let field_kind = "kind"
let field_post_id = "post_id"
let field_at = "at"
let field_ratifiers = "ratifiers"
let field_by = "by"
let kind_proposed = "proposed"
let kind_ratified = "ratified"
let kind_superseded = "superseded"
let kind_repealed = "repealed"

type decode_step =
  | Field of string
  | Index of int

type decode_reason =
  | Expected_object
  | Expected_array
  | Expected_string
  | Expected_number
  | Missing_field of string
  | Unknown_field of string
  | Duplicate_field of string
  | Unknown_state of string
  | Empty_list
  | Invalid_id of string
  | Invalid_article of invalid

type decode_error = {
  path : decode_step list;
  reason : decode_reason;
}

let decode_step_to_string = function
  | Field name -> "." ^ name
  | Index index -> Printf.sprintf "[%d]" index

let decode_reason_to_string = function
  | Expected_object -> "expected an object"
  | Expected_array -> "expected an array"
  | Expected_string -> "expected a string"
  | Expected_number -> "expected a number"
  | Missing_field name -> Printf.sprintf "missing field %S" name
  | Unknown_field name -> Printf.sprintf "unknown field %S" name
  | Duplicate_field name -> Printf.sprintf "duplicate field %S" name
  | Unknown_state name -> Printf.sprintf "unknown state %S" name
  | Empty_list -> "expected at least one element"
  | Invalid_id detail -> detail
  | Invalid_article invalid -> invalid_to_string invalid

let decode_error_to_string { path; reason } =
  let rendered = String.concat "" (List.map decode_step_to_string path) in
  Printf.sprintf "article%s: %s" rendered (decode_reason_to_string reason)

let ( let* ) = Result.bind

let assoc_opt key fields =
  Option.map snd (List.find_opt (fun (k, _) -> String.equal k key) fields)

let object_fields ~path json =
  match json with
  | `Assoc fields ->
    let rec check seen = function
      | [] -> Ok fields
      | (key, _) :: rest ->
        if List.exists (String.equal key) seen then
          Error { path; reason = Duplicate_field key }
        else check (key :: seen) rest
    in
    check [] fields
  | _ -> Error { path; reason = Expected_object }

let reject_unknown ~path ~allowed fields =
  match
    List.find_opt
      (fun (key, _) -> not (List.exists (String.equal key) allowed))
      fields
  with
  | Some (key, _) -> Error { path; reason = Unknown_field key }
  | None -> Ok ()

let required ~path ~field fields =
  match assoc_opt field fields with
  | Some value -> Ok value
  | None -> Error { path; reason = Missing_field field }

let string_field ~path ~field fields =
  let* value = required ~path ~field fields in
  match value with
  | `String s -> Ok s
  | _ -> Error { path = path @ [ Field field ]; reason = Expected_string }

let number_field ~path ~field fields =
  let* value = required ~path ~field fields in
  match value with
  | `Float f -> Ok f
  | `Int i -> Ok (float_of_int i)
  | _ -> Error { path = path @ [ Field field ]; reason = Expected_number }

let optional_string_field ~path ~field fields =
  let* value = required ~path ~field fields in
  match value with
  | `Null -> Ok None
  | `String s -> Ok (Some s)
  | _ -> Error { path = path @ [ Field field ]; reason = Expected_string }

let optional_number_field ~path ~field fields =
  let* value = required ~path ~field fields in
  match value with
  | `Null -> Ok None
  | `Float f -> Ok (Some f)
  | `Int i -> Ok (Some (float_of_int i))
  | _ -> Error { path = path @ [ Field field ]; reason = Expected_number }

let article_id_field ~path ~field fields =
  let* raw = string_field ~path ~field fields in
  match Article_id.of_string raw with
  | Ok id -> Ok id
  | Error detail ->
    Error { path = path @ [ Field field ]; reason = Invalid_id detail }

let non_empty ~path items =
  match Non_empty.of_list items with
  | Ok value -> Ok value
  | Error `Empty -> Error { path; reason = Empty_list }

let evidence_item_to_json { uri; sha256 } =
  `Assoc
    [ field_uri, `String uri
    ; ( field_sha256
      , match sha256 with None -> `Null | Some digest -> `String digest )
    ]

let evidence_item_of_json ~path json =
  let* fields = object_fields ~path json in
  let* () = reject_unknown ~path ~allowed:[ field_uri; field_sha256 ] fields in
  let* uri = string_field ~path ~field:field_uri fields in
  let* sha256 = optional_string_field ~path ~field:field_sha256 fields in
  Ok { uri; sha256 }

let evidence_of_json ~path json =
  match json with
  | `List items ->
    let rec decode index acc = function
      | [] -> Ok (List.rev acc)
      | item :: rest ->
        let* decoded =
          evidence_item_of_json ~path:(path @ [ Index index ]) item
        in
        decode (index + 1) (decoded :: acc) rest
    in
    let* items = decode 0 [] items in
    non_empty ~path items
  | _ -> Error { path; reason = Expected_array }

let ratifiers_of_json ~path json =
  match json with
  | `List items ->
    let rec decode index acc = function
      | [] -> Ok (List.rev acc)
      | `String value :: rest -> decode (index + 1) (value :: acc) rest
      | _ :: _ ->
        Error { path = path @ [ Index index ]; reason = Expected_string }
    in
    let* items = decode 0 [] items in
    non_empty ~path items
  | _ -> Error { path; reason = Expected_array }

let state_to_json = function
  | Proposed { post_id } ->
    `Assoc [ field_kind, `String kind_proposed; field_post_id, `String post_id ]
  | Ratified { at; ratifiers } ->
    `Assoc
      [ field_kind, `String kind_ratified
      ; field_at, `Float at
      ; ( field_ratifiers
        , `List
            (List.map
               (fun name -> `String name)
               (Non_empty.to_list ratifiers)) )
      ]
  | Superseded { by; at } ->
    `Assoc
      [ field_kind, `String kind_superseded
      ; field_by, `String (Article_id.to_string by)
      ; field_at, `Float at
      ]
  | Repealed { at; post_id } ->
    `Assoc
      [ field_kind, `String kind_repealed
      ; field_at, `Float at
      ; field_post_id, `String post_id
      ]

let state_of_json ~path json =
  let* fields = object_fields ~path json in
  let* kind = string_field ~path ~field:field_kind fields in
  if String.equal kind kind_proposed then (
    let* () =
      reject_unknown ~path ~allowed:[ field_kind; field_post_id ] fields
    in
    let* post_id = string_field ~path ~field:field_post_id fields in
    Ok (Proposed { post_id }))
  else if String.equal kind kind_ratified then (
    let* () =
      reject_unknown ~path
        ~allowed:[ field_kind; field_at; field_ratifiers ]
        fields
    in
    let* at = number_field ~path ~field:field_at fields in
    let* raw = required ~path ~field:field_ratifiers fields in
    let* ratifiers =
      ratifiers_of_json ~path:(path @ [ Field field_ratifiers ]) raw
    in
    Ok (Ratified { at; ratifiers }))
  else if String.equal kind kind_superseded then (
    let* () =
      reject_unknown ~path ~allowed:[ field_kind; field_by; field_at ] fields
    in
    let* by = article_id_field ~path ~field:field_by fields in
    let* at = number_field ~path ~field:field_at fields in
    Ok (Superseded { by; at }))
  else if String.equal kind kind_repealed then (
    let* () =
      reject_unknown ~path
        ~allowed:[ field_kind; field_at; field_post_id ]
        fields
    in
    let* at = number_field ~path ~field:field_at fields in
    let* post_id = string_field ~path ~field:field_post_id fields in
    Ok (Repealed { at; post_id }))
  else Error { path; reason = Unknown_state kind }

let to_json article =
  `Assoc
    [ field_id, `String (Article_id.to_string article.id)
    ; field_text, `String article.text
    ; ( field_evidence
      , `List
          (List.map evidence_item_to_json (Non_empty.to_list article.evidence))
      )
    ; field_proposer, `String article.proposer
    ; field_state, state_to_json article.state
    ; ( field_last_cited_at
      , match article.last_cited_at with
        | None -> `Null
        | Some at -> `Float at )
    ]

let of_json json =
  let path = [] in
  let* fields = object_fields ~path json in
  let* () =
    reject_unknown ~path
      ~allowed:
        [ field_id
        ; field_text
        ; field_evidence
        ; field_proposer
        ; field_state
        ; field_last_cited_at
        ]
      fields
  in
  let* id = article_id_field ~path ~field:field_id fields in
  let* text = string_field ~path ~field:field_text fields in
  let* raw_evidence = required ~path ~field:field_evidence fields in
  let* evidence =
    evidence_of_json ~path:(path @ [ Field field_evidence ]) raw_evidence
  in
  let* proposer = string_field ~path ~field:field_proposer fields in
  let* raw_state = required ~path ~field:field_state fields in
  let* state = state_of_json ~path:(path @ [ Field field_state ]) raw_state in
  let* last_cited_at =
    optional_number_field ~path ~field:field_last_cited_at fields
  in
  match make ~id ~text ~evidence ~proposer ~state ~last_cited_at with
  | Ok article -> Ok article
  | Error invalid -> Error { path; reason = Invalid_article invalid }
