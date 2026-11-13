(** Immutable request facts and canonical Board result observations. *)

type board_upload_kind =
  | Uk_image
  | Uk_audio
  | Uk_score
  | Uk_midi
  | Uk_file

let board_upload_kind_to_wire = function
  | Uk_image -> "image"
  | Uk_audio -> "audio"
  | Uk_score -> "score"
  | Uk_midi -> "midi"
  | Uk_file -> "file"
;;

(* Case-insensitive -- tab editors and macOS saves routinely write uppercase
   extensions, and the kind describes the file, not the case of its name. A
   bare dotfile (".gp5") or a trailing dot ("notes.") is not an extension. *)
let extension_of_path path =
  let base = Filename.basename path in
  match String.rindex_opt base '.' with
  | Some dot when dot > 0 && dot < String.length base - 1 ->
      Some
        (String.lowercase_ascii
           (String.sub base (dot + 1) (String.length base - dot - 1)))
  | Some _ | None -> None
;;

(* The file's name decides its kind: the store keeps no media type per file,
   so the name is the only signal a client has. A name that says nothing is
   a plain file. *)
let upload_kind_of_path path =
  match extension_of_path path with
  | None -> Uk_file
  | Some extension -> (
      match extension with
      | "gp" | "gp3" | "gp4" | "gp5" | "gpx" | "cap" | "capx" | "atex"
      | "musicxml" | "mxl" ->
          Uk_score
      | "mid" | "midi" -> Uk_midi
      | "png" | "jpg" | "jpeg" | "gif" | "webp" | "svg" | "bmp" -> Uk_image
      | "mp3" | "wav" | "ogg" | "flac" | "m4a" | "aac" -> Uk_audio
      | _ -> Uk_file)
;;

(** A local file the operator staged in board compose. [sa_path] is read at
    send time, so a file replaced on disk since staging posts its current
    bytes. *)
type board_staged_attachment = {
  sa_path: string;
  sa_name: string;  (** Basename, sent as the entry's [name]. *)
  sa_kind: board_upload_kind;
}

(** One uploaded attachment ready for the post payload. *)
type board_outbound_attachment = {
  oa_kind: board_upload_kind;
  oa_sha256: string;
  oa_name: string;
}

(* The payload field for a post's staged uploads. [None] -- the field absent
   from the payload -- when nothing was staged, so a plain post's payload is
   exactly what it was before attachments existed. *)
let board_outbound_attachments_field attachments =
  match attachments with
  | [] -> None
  | _ ->
      Some
        ( "attachments"
        , `List
            (List.map
               (fun { oa_kind; oa_sha256; oa_name } ->
                  `Assoc
                    [ "kind", `String (board_upload_kind_to_wire oa_kind)
                    ; "sha256", `String oa_sha256
                    ; "name", `String oa_name
                    ])
               attachments) )
;;

type request_id = unit ref

type 'authority request = {
  id : request_id;
  authority : 'authority;
  host : string;
  port : int;
  expected_workspace : Masc.Tui_decode.server_identity option;
  sent_draft : string;
  staged : board_staged_attachment list;
  title : string;
  body : string;
  hearth : string option;
}

let capture ~authority ~host ~port ~expected_workspace ~sent_draft ~staged
    ~title ~body ~hearth () =
  { id = ref (); authority; host; port; expected_workspace; sent_draft;
    staged; title; body; hearth }

let same_request left right = left.id == right.id

type 'authority prepared = { request : 'authority request; body : string }
let bind_body request ~body = { request; body }

type committed = {
  post_id : Board_types.Post_id.t;
  canonical_result : Yojson.Safe.t;
}
type failure = {
  effect_disposition : Failure_effect.t;
  committed_post_id : Board_types.Post_id.t option;
  class_ : Tool_result.tool_failure_class;
  message : string;
  canonical_result : Yojson.Safe.t;
}

type acknowledgement =
  (committed, Yojson.Safe.t, failure) Tool_result.disposition

type response =
  | Answered of acknowledgement
  | Unanswered of { detail : string; raw_response : (int * string) option }

let ( let* ) = Result.bind

let object_fields context = function
  | `Assoc fields -> Ok fields
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
    Error (context ^ " must be an object")

let optional_field name fields =
  match List.filter (fun (key, _) -> String.equal key name) fields with
  | [] -> Ok None
  | [(_, value)] -> Ok (Some value)
  | _ :: _ :: _ -> Error ("duplicate Board result field: " ^ name)

let required_field name fields =
  let* value = optional_field name fields in
  match value with
  | Some value -> Ok value
  | None -> Error ("missing Board result field: " ^ name)

let string_field name fields =
  let* value = required_field name fields in
  match value with
  | `String value -> Ok value
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _ ->
    Error ("Board result field must be a string: " ^ name)

let parsed_post_id field fields =
  let* wire = string_field field fields in
  Board_types.Post_id.of_string wire
  |> Result.map_error Board_types.show_board_error

let failure_effect fields =
  let* wire = string_field "effect_disposition" fields in
  match Tool_result.failure_effect_disposition_of_string wire with
  | Some disposition -> Ok disposition
  | None -> Error "unknown Board failure effect disposition"

let failure_class fields =
  let* wire = string_field "failure_class" fields in
  match Tool_result.tool_failure_class_of_string wire with
  | Some class_ -> Ok class_
  | None -> Error "unknown Board failure class"

let reject_unproven_id = function
  | `Assoc fields ->
    let* id = optional_field "committed_post_id" fields in
    (match id with
     | None -> Ok None
     | Some _ -> Error "an uncommitted Board failure carries a committed ID")
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
    Ok None

let decode_canonical json =
  let* envelope = object_fields "Board response" json in
  let* canonical_result = required_field "result" envelope in
  let* fields = object_fields "canonical Board result" canonical_result in
  let* tool_name = string_field "tool_name" fields in
  let* () =
    match Tool_name.Board_name.of_string tool_name with
    | None -> Error "unknown tool in Board publication response"
    | Some parsed ->
      if parsed = Tool_name.Board_name.Board_post then Ok ()
      else Error "Board publication response belongs to another tool"
  in
  let* wire = string_field "disposition" fields in
  let* disposition = Tool_result.unit_disposition_of_string wire in
  let* data = required_field "data" fields in
  match disposition with
  | Tool_result.Completed () ->
    let* data_fields = object_fields "completed Board post" data in
    let* post_id = parsed_post_id "id" data_fields in
    Ok (Tool_result.Completed { post_id; canonical_result })
  | Tool_result.Deferred () -> Ok (Tool_result.Deferred canonical_result)
  | Tool_result.Failed () ->
    let* effect_disposition = failure_effect fields in
    let* class_ = failure_class fields in
    let* message = string_field "message" fields in
    let* committed_post_id =
      match effect_disposition with
      | Failure_effect.Proven_post_effect ->
        let* data_fields = object_fields "committed Board failure data" data in
        let* post_id = parsed_post_id "committed_post_id" data_fields in
        Ok (Some post_id)
      | Failure_effect.Proven_pre_effect | Failure_effect.Effect_outcome_unknown ->
        reject_unproven_id data
    in
    Ok (Tool_result.Failed
      { effect_disposition; committed_post_id; class_; message; canonical_result })

let decode_response ~status_code ~body =
  let decoded =
    match Yojson.Safe.from_string body with
    | json -> decode_canonical json
    | exception Yojson.Json_error detail -> Error detail
  in
  match decoded with
  | Ok acknowledgement -> Answered acknowledgement
  | Error detail ->
    Unanswered { detail; raw_response = Some (status_code, body) }

let unanswered detail = Unanswered { detail; raw_response = None }

let committed_post_id = function
  | Answered (Tool_result.Completed committed) -> Some committed.post_id
  | Answered (Tool_result.Failed failure) -> failure.committed_post_id
  | Answered (Tool_result.Deferred _) | Unanswered _ -> None

let response_diagnostic ~ko = function
  | Answered (Tool_result.Completed _) -> None
  | Answered (Tool_result.Failed failure) -> Some failure.message
  | Answered (Tool_result.Deferred _) -> Some (if ko then "미뤄짐" else "deferred")
  | Unanswered { detail; raw_response = Some (status, _) } ->
    (* An answer came back and could not be read; [detail] says why. *)
    Some
      (Printf.sprintf
         (if ko then "응답을 읽지 못함 (HTTP %d): %s" else "response could not be read (HTTP %d): %s")
         status detail)
  | Unanswered { detail; raw_response = None } -> Some detail

let outcome_unknown ~ko = if ko then "게시 결과 미확인" else "Board post outcome unknown"

let response_effect = function
  | Answered (Tool_result.Completed _) -> Failure_effect.Proven_post_effect
  | Answered (Tool_result.Failed failure) -> failure.effect_disposition
  | Answered (Tool_result.Deferred _) | Unanswered _ -> Failure_effect.Effect_outcome_unknown

type 'authority outcome =
  | Not_attempted of { request : 'authority request; detail : string }
  | Returned of { prepared : 'authority prepared; response : response }

let not_attempted request ~detail = Not_attempted { request; detail }
let returned prepared response = Returned { prepared; response }
let outcome_request = function
  | Not_attempted { request; _ } -> request
  | Returned { prepared; _ } -> prepared.request

type 'authority entry = Pending of 'authority request | Finished of 'authority outcome
type 'authority history = 'authority entry list
let empty = []

let entry_request = function
  | Pending request -> request
  | Finished outcome -> outcome_request outcome

let register history request =
  if List.exists (fun entry -> same_request (entry_request entry) request) history
  then history
  else Pending request :: history

type 'authority recording =
  | Recorded of 'authority history
  | Already_recorded
  | Not_registered

let record history outcome =
  let request = outcome_request outcome in
  let rec settle prefix = function
    | [] -> Not_registered
    | (Pending original as entry) :: rest ->
      if same_request original request then
        Recorded (List.rev_append prefix (Finished outcome :: rest))
      else settle (entry :: prefix) rest
    | (Finished previous as entry) :: rest ->
      if same_request (outcome_request previous) request then Already_recorded
      else settle (entry :: prefix) rest
  in
  settle [] history

let entries history = List.rev history
