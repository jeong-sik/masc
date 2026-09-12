open World_constitution_types

(* Wire vocabulary. Encoder and decoder share these so a rename cannot move
   only one side. *)
let field_id = "id"
let field_text = "text"
let field_author = "author"
let field_at = "at"
let field_evidence = "evidence"
let field_uri = "uri"
let field_sha256 = "sha256"
let field_kind = "kind"
let field_article = "article"
let field_by = "by"
let kind_added = "added"
let kind_removed = "removed"

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
  | Unknown_entry of string
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
  | Unknown_entry name -> Printf.sprintf "unknown entry kind %S" name
  | Invalid_id detail -> detail
  | Invalid_article invalid -> invalid_to_string invalid

let decode_error_to_string { path; reason } =
  let rendered = String.concat "" (List.map decode_step_to_string path) in
  Printf.sprintf "entry%s: %s" rendered (decode_reason_to_string reason)

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

(* Absent and null both mean "no digest". The encoder omits the field, but a
   line written by hand or by a future producer may spell it either way, and
   the type this decodes into calls it optional. *)
let optional_string_field ~path ~field fields =
  match assoc_opt field fields with
  | None -> Ok None
  | Some `Null -> Ok None
  | Some (`String s) -> Ok (Some s)
  | Some _ ->
    Error { path = path @ [ Field field ]; reason = Expected_string }

let article_id_field ~path ~field fields =
  let* raw = string_field ~path ~field fields in
  match Article_id.of_string raw with
  | Ok id -> Ok id
  | Error detail ->
    Error { path = path @ [ Field field ]; reason = Invalid_id detail }

let evidence_item_to_json { uri; sha256 } =
  `Assoc
    (( field_uri, `String uri )
     :: (match sha256 with
         | None -> []
         | Some digest -> [ field_sha256, `String digest ]))

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
    decode 0 [] items
  | _ -> Error { path; reason = Expected_array }

let article_to_json article =
  `Assoc
    [ field_id, `String (Article_id.to_string article.id)
    ; field_text, `String article.text
    ; field_author, `String article.author
    ; field_at, `Float article.at
    ; ( field_evidence
      , `List (List.map evidence_item_to_json article.evidence) )
    ]

let article_of_json ~path json =
  let* fields = object_fields ~path json in
  let* () =
    reject_unknown ~path
      ~allowed:
        [ field_id; field_text; field_author; field_at; field_evidence ]
      fields
  in
  let* id = article_id_field ~path ~field:field_id fields in
  let* text = string_field ~path ~field:field_text fields in
  let* author = string_field ~path ~field:field_author fields in
  let* at = number_field ~path ~field:field_at fields in
  let* raw_evidence = required ~path ~field:field_evidence fields in
  let* evidence =
    evidence_of_json ~path:(path @ [ Field field_evidence ]) raw_evidence
  in
  match make ~id ~text ~author ~at ~evidence with
  | Ok article -> Ok article
  | Error invalid -> Error { path; reason = Invalid_article invalid }

let entry_to_json = function
  | Added article ->
    `Assoc
      [ field_kind, `String kind_added
      ; field_article, article_to_json article
      ]
  | Removed { id; by; at } ->
    `Assoc
      [ field_kind, `String kind_removed
      ; field_id, `String (Article_id.to_string id)
      ; field_by, `String by
      ; field_at, `Float at
      ]

let entry_of_json json =
  let path = [] in
  let* fields = object_fields ~path json in
  let* kind = string_field ~path ~field:field_kind fields in
  if String.equal kind kind_added then (
    let* () =
      reject_unknown ~path ~allowed:[ field_kind; field_article ] fields
    in
    let* raw = required ~path ~field:field_article fields in
    let* article = article_of_json ~path:(path @ [ Field field_article ]) raw in
    Ok (Added article))
  else if String.equal kind kind_removed then (
    let* () =
      reject_unknown ~path
        ~allowed:[ field_kind; field_id; field_by; field_at ]
        fields
    in
    let* id = article_id_field ~path ~field:field_id fields in
    let* by = string_field ~path ~field:field_by fields in
    let* at = number_field ~path ~field:field_at fields in
    Ok (Removed { id; by; at }))
  else Error { path; reason = Unknown_entry kind }
