type format = Markdown | Html
type update = Create | Revise of { id : string; expected_revision : int }
type link_update = Unspecified | Clear | Set of string
type request =
  { update : update; title : string; summary : string; format : format
  ; content : string; task_id : link_update; goal_id : link_update }
type revision =
  { revision : int; title : string; summary : string; format : format
  ; author : string; created_at : string; body : Tool_output.artifact_ref
  ; task_id : string option; goal_id : string option }
type t = { id : string; revisions : revision list }

open Result.Syntax
let format_name = function Markdown -> "markdown" | Html -> "html"
let media_type = function Markdown -> "text/markdown" | Html -> "text/html"
let format_of_json = function
  | `String "markdown" -> Ok Markdown
  | `String "html" -> Ok Html
  | _ -> Error "format must be markdown or html"

let valid_id id =
  String.length id = 41 && String.starts_with ~prefix:"artifact-" id
  && String.for_all (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
       (String.sub id 9 32)

let url ?revision id =
  "/dashboard/#/workspace?section=artifacts&artifact=" ^ id
  ^ Option.fold ~none:"" ~some:(fun n -> "&revision=" ^ string_of_int n) revision

let fields allowed = function
  | `Assoc fields ->
    let names = List.map fst fields in
    if List.length names <> List.length (List.sort_uniq String.compare names)
    then Error "duplicate fields"
    else if List.exists (fun name -> not (List.mem name allowed)) names
    then Error "unknown field"
    else Ok fields
  | _ -> Error "expected an object"

let required name fields =
  match List.assoc_opt name fields with
  | Some (`String value) when String.trim value <> "" && String.is_valid_utf_8 value -> Ok value
  | _ -> Error (name ^ " must be a nonblank UTF-8 string")

let optional name fields =
  match List.assoc_opt name fields with
  | None | Some `Null -> Ok None
  | Some (`String value) when String.trim value <> "" && String.is_valid_utf_8 value -> Ok (Some value)
  | Some _ -> Error (name ^ " must be a nonblank UTF-8 string when supplied")

let link_update name fields =
  match List.assoc_opt name fields with
  | None -> Ok Unspecified
  | Some `Null -> Ok Clear
  | Some (`String value) when String.trim value <> "" && String.is_valid_utf_8 value -> Ok (Set value)
  | Some _ -> Error (name ^ " must be null or a nonblank UTF-8 string when supplied")

let positive name fields =
  match List.assoc_opt name fields with
  | Some (`Int n) when n > 0 -> Ok n
  | _ -> Error (name ^ " must be a positive integer")

let request_of_json json =
  let* fields = fields
    ["id"; "expected_revision"; "title"; "summary"; "format"; "content";
     "task_id"; "goal_id"] json in
  let* title = required "title" fields in
  let* summary = required "summary" fields in
  let* content = required "content" fields in
  let* format = format_of_json (Option.value ~default:`Null (List.assoc_opt "format" fields)) in
  let* task_id = link_update "task_id" fields in
  let* goal_id = link_update "goal_id" fields in
  let* update = match List.assoc_opt "id" fields, List.assoc_opt "expected_revision" fields with
    | None, None -> Ok Create
    | Some (`String id), Some _ when valid_id id ->
      let* expected_revision = positive "expected_revision" fields in
      Ok (Revise { id; expected_revision })
    | _ -> Error "updates require a valid id and expected_revision together" in
  Ok { update; title; summary; format; content; task_id; goal_id }

let option_json = function None -> `Null | Some text -> `String text
let revision_fields (r : revision) =
    [ "revision", `Int r.revision; "title", `String r.title
    ; "summary", `String r.summary; "format", `String (format_name r.format)
    ; "author", `String r.author; "created_at", `String r.created_at
    ; "body", Tool_output.normalized_artifact_ref_to_json r.body
    ; "task_id", option_json r.task_id; "goal_id", option_json r.goal_id ]

let revision_to_json r = `Assoc (revision_fields r)

let summary_to_json ~id r =
  `Assoc (("id", `String id) :: ("url", `String (url id)) :: revision_fields r)

let publication_to_json ~id r =
  `Assoc ["schema", `String "masc.published_artifact.v1";
          "artifact", summary_to_json ~id r;
          "revision_url", `String (url ~revision:r.revision id)]

let to_json t =
  `Assoc ["id", `String t.id; "revisions", `List (List.map revision_to_json t.revisions)]

let revision_of_json json =
  let* fields = fields
    ["revision"; "title"; "summary"; "format"; "author"; "created_at";
     "body"; "task_id"; "goal_id"] json in
  let* revision = positive "revision" fields in
  let* title = required "title" fields in
  let* summary = required "summary" fields in
  let* author = required "author" fields in
  let* created_at = required "created_at" fields in
  let* format = format_of_json (Option.value ~default:`Null (List.assoc_opt "format" fields)) in
  let* task_id = optional "task_id" fields in
  let* goal_id = optional "goal_id" fields in
  let* body = match List.assoc_opt "body" fields with
    | Some json ->
      (match Tool_output.normalized_artifact_ref_of_json json with
       | Tool_output.Decoded_normalized_artifact_ref body -> Ok body
       | Tool_output.Not_normalized_artifact_ref
       | Tool_output.Invalid_normalized_artifact_ref _ -> Error "invalid body reference")
    | None -> Error "missing body reference" in
  if not (String.equal body.mime (media_type format)) then Error "body format mismatch"
  else if not (String.is_valid_utf_8 body.preview) then Error "body preview must be valid UTF-8"
  else Ok { revision; title; summary; format; author; created_at; body; task_id; goal_id }

let of_json json =
  let* fields = fields ["id"; "revisions"] json in
  let* id = required "id" fields in
  if not (valid_id id) then Error "invalid artifact id"
  else
    let* revisions = match List.assoc_opt "revisions" fields with
      | Some (`List (_ :: _ as items)) ->
        List.fold_right (fun json rest ->
          let* r = revision_of_json json in
          let* rest = rest in Ok (r :: rest)) items (Ok [])
      | _ -> Error "revisions must be nonempty" in
    let rec contiguous expected = function
      | [] -> expected = 0
      | (r : revision) :: rest -> r.revision = expected && contiguous (expected - 1) rest in
    if contiguous (List.length revisions) revisions then Ok { id; revisions }
    else Error "revision history must be contiguous and newest first"
