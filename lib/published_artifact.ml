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

let is_valid_media_token token = Result.is_ok (Tool_output.validate_sha256 token)

let is_url_start_boundary = function
  | '(' | '<' | '"' | '\'' | '=' | ' ' | '\t' | '\n' | '\r' -> true
  | _ -> false

let is_url_end_boundary = function
  | ')' | '>' | '"' | '\'' | ']' | '|' | ' ' | '\t' | '\n' | '\r' | ',' | ';' -> true
  | _ -> false

let extract_url_media_refs text acc =
  let prefix = Masc_network_defaults.media_path_prefix in
  let prefix_len = String.length prefix in
  let token_len = 64 in
  let len = String.length text in
  let rec scan pos acc =
    if pos >= len then acc
    else
      match String_util.find_substring ~pos text prefix with
      | None -> acc
      | Some idx ->
        let start_ok = idx = 0 || is_url_start_boundary text.[idx - 1] in
        let token_start = idx + prefix_len in
        let token_end = token_start + token_len in
        let acc =
          if start_ok && token_end <= len
             && (token_end = len || is_url_end_boundary text.[token_end])
          then
            let token = String.sub text token_start token_len in
            if is_valid_media_token token then token :: acc else acc
          else acc
        in
        scan (idx + prefix_len) acc
  in
  scan 0 acc

let blank_code_spans line =
  let length = String.length line in
  let bytes = Bytes.of_string line in
  let run_end from =
    let stop = ref from in
    while !stop < length && Char.equal line.[!stop] '`' do
      incr stop
    done;
    !stop
  in
  let rec closing ~run from =
    if from >= length then None
    else if Char.equal line.[from] '`' then
      let stop = run_end from in
      if stop - from = run then Some stop else closing ~run stop
    else closing ~run (from + 1)
  in
  let rec scan index =
    if index < length then
      if Char.equal line.[index] '`' then
        let stop = run_end index in
        match closing ~run:(stop - index) stop with
        | Some close ->
          Bytes.fill bytes index (close - index) ' ';
          scan close
        | None -> scan stop
      else scan (index + 1)
  in
  scan 0;
  Bytes.to_string bytes

let fence_of_line line =
  let length = String.length line in
  let rec indent index =
    if index < length && index < 3 && Char.equal line.[index] ' '
    then indent (index + 1)
    else index
  in
  let start = indent 0 in
  if start >= length then None
  else
    let mark = line.[start] in
    if not (Char.equal mark '`' || Char.equal mark '~') then None
    else
      let stop = ref start in
      while !stop < length && Char.equal line.[!stop] mark do
        incr stop
      done;
      let count = !stop - start in
      if count >= 3
      then Some (mark, count, String.trim (String.sub line !stop (length - !stop)))
      else None

let extract_obsidian_media_refs line acc =
  let open_tok = "![[media:" in
  let open_len = String.length open_tok in
  let len = String.length line in
  let rec scan pos acc =
    if pos >= len then acc
    else
      match String_util.find_substring ~pos line open_tok with
      | None -> acc
      | Some idx ->
        let payload_start = idx + open_len in
        (match String_util.find_substring ~pos:payload_start line "]]" with
         | None -> acc
         | Some stop ->
           let inner = String.sub line payload_start (stop - payload_start) in
           let raw_token =
             match String.index_opt inner '|' with
             | None -> inner
             | Some bar -> String.sub inner 0 bar
           in
           let acc = if is_valid_media_token raw_token then raw_token :: acc else acc in
           scan (stop + 2) acc)
  in
  scan 0 acc

let extract_media_refs format content =
  let raw =
    match format with
    | Html -> extract_url_media_refs content []
    | Markdown ->
      let strip_cr line =
        let length = String.length line in
        if length > 0 && Char.equal line.[length - 1] '\r'
        then String.sub line 0 (length - 1)
        else line
      in
      let _, acc =
        List.fold_left
          (fun (fence, acc) raw_line ->
             let line = strip_cr raw_line in
             match fence, fence_of_line line with
             | None, Some (mark, count, _info) -> Some (mark, count), acc
             | None, None ->
               let unquoted = blank_code_spans line in
               let acc = extract_url_media_refs unquoted acc in
               let acc = extract_obsidian_media_refs unquoted acc in
               None, acc
             | Some (mark, count), Some (closing_mark, closing_count, rest)
               when Char.equal mark closing_mark
                    && closing_count >= count
                    && String.equal rest "" -> None, acc
             | Some open_fence, (Some _ | None) -> Some open_fence, acc)
          (None, [])
          (String.split_on_char '\n' content)
      in
      acc
  in
  List.sort_uniq String.compare raw

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

let publication_to_json ?(media_refs = []) ?(missing_media_refs = []) ~id r =
  let missing_fields =
    match missing_media_refs with
    | [] -> []
    | missing ->
      [ "missing_media_refs", `List (List.map (fun s -> `String s) missing)
      ; ( "warnings"
        , `List
            [ `String
                (Printf.sprintf
                   "referenced workspace media not found in store: %s"
                   (String.concat ", " missing))
            ] )
      ]
  in
  `Assoc
    ([ "schema", `String "masc.published_artifact.v1"
     ; "artifact", summary_to_json ~id r
     ; "revision_url", `String (url ~revision:r.revision id)
     ; "media_refs", `List (List.map (fun s -> `String s) media_refs)
     ]
     @ missing_fields)

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
        let rec loop acc = function
          | [] -> Ok (List.rev acc)
          | json :: rest ->
            let* r = revision_of_json json in
            loop (r :: acc) rest
        in
        loop [] items
      | _ -> Error "revisions must be nonempty" in
    let rec contiguous expected = function
      | [] -> expected = 0
      | (r : revision) :: rest -> r.revision = expected && contiguous (expected - 1) rest in
    if contiguous (List.length revisions) revisions then Ok { id; revisions }
    else Error "revision history must be contiguous and newest first"
