(** The immutable original of one verifier review attempt. *)

module AR = Task.Anti_rationalization

let ( let* ) = Result.bind

let schema = "verifier_review_original/v1"

(* The output contract is a single sentence naming the verdict tool and the
   exact verdict vocabulary the review accepts, so a worker that reads the
   contract from this module and one that reads it from the prompt see the
   same thing. The vocabulary is the review protocol's own
   {!AR.valid_verdict_strings}, not a copy, so the two cannot drift apart. *)
let canonical_output_contract () =
  Printf.sprintf
    "Call the report_review_verdict tool exactly once with verdict one of: %s."
    (String.concat ", " AR.valid_verdict_strings)

(* The review's system prompt is the rendered [Prompt_names.verification]
   template. [AR.build_prompt] needs a [lookup_surface] to name the tools in
   the lookup section; that section reads only the tool names from
   [lookup.schemas], never the dispatch, so a surface whose dispatch always
   refuses renders the identical prompt without authorising a single read.
   The caller passes the schemas the lane actually handed the reviewer. *)
let system_prompt ~lookup_schemas ~question ~lookup_root req =
  let lookup : AR.lookup_surface =
    { schemas =
        List.map
          (fun name -> Types_core.{ name; description = ""; input_schema = `Assoc [] })
          lookup_schemas
    ; dispatch =
        (fun ~name:_ ~args:_ -> Tool_result.refused "lookup is not available in original preparation")
    }
  in
  AR.build_prompt ~question ~lookup ~lookup_root req
;;

type t =
  { verification_id : string
  ; attempt : int
  ; review_request : AR.review_request
  ; question : AR.verdict_question
  ; lookup_root : AR.lookup_root
  ; lookup_schemas : string list
  ; system_prompt : string
  ; output_contract : string
  }

let prepare ~verification_id ~attempt ~question ~lookup_root ~lookup_schemas req =
  if String.trim verification_id = ""
  then Error "verifier review original requires a non-blank verification_id"
  else if attempt < 0
  then Error "verifier review original attempt must be a non-negative integer"
  else if lookup_schemas = []
  then Error "verifier review original requires the reviewer's lookup tool names"
  else (
    let* system_prompt =
      system_prompt ~lookup_schemas ~question ~lookup_root req
      |> Result.map_error (fun detail -> "verifier review prompt unavailable: " ^ detail)
    in
    Ok
      { verification_id
      ; attempt
      ; review_request = req
      ; question
      ; lookup_root
      ; lookup_schemas
      ; system_prompt
      ; output_contract = canonical_output_contract ()
      })
;;

let verification_id t = t.verification_id
let attempt t = t.attempt
let review_request t = t.review_request
let question t = t.question
let lookup_root t = t.lookup_root
let lookup_schemas t = t.lookup_schemas
let system_prompt_text t = t.system_prompt
let output_contract t = t.output_contract

(* Serialisation. The subject, question and lookup grants are the parts a
   worker must not flatten away, so they are encoded as their own fields and
   round-tripped field by field; an original that does not survive the round
   trip exactly is an error, not a best effort. *)

let evidence_image_to_json (image : AR.evidence_image) : Yojson.Safe.t =
  `Assoc
    [ "image_reference", `String image.image_reference
    ; "image_sha256", `String image.image_sha256
    ; "image_bytes", `Int image.image_bytes
    ; "image_media_type", `String image.image_media_type
    ; "image_body_base64", `String image.image_body_base64
    ]
;;

let evidence_image_of_json (json : Yojson.Safe.t) : (AR.evidence_image, string) result =
  let text key fields =
    match List.assoc key fields with
    | `String value when String.trim value <> "" -> Ok value
    | _ -> Error (Printf.sprintf "evidence_image %s must be non-blank text" key)
  in
  let int key fields =
    match List.assoc key fields with
    | `Int value when value >= 0 -> Ok value
    | _ -> Error (Printf.sprintf "evidence_image %s must be a non-negative integer" key)
  in
  match json with
  | `Assoc fields ->
    let* image_reference = text "image_reference" fields in
    let* image_sha256 = text "image_sha256" fields in
    let* image_bytes = int "image_bytes" fields in
    let* image_media_type = text "image_media_type" fields in
    let* image_body_base64 = text "image_body_base64" fields in
    Ok AR.{ image_reference; image_sha256; image_bytes; image_media_type; image_body_base64 }
  | _ -> Error "evidence_image must be an object"
;;

let review_request_to_json (req : AR.review_request) : Yojson.Safe.t =
  `Assoc
    [ "task_title", `String req.task_title
    ; "task_description", `String req.task_description
    ; "completion_notes", `String req.completion_notes
    ; "agent_name", `String req.agent_name
    ; "task_id", `String req.task_id
    ; "evidence_refs", `List (List.map (fun r -> `String r) req.evidence_refs)
    ; "evidence_images", `List (List.map evidence_image_to_json req.evidence_images)
    ]
;;

let review_request_of_json (json : Yojson.Safe.t) : (AR.review_request, string) result =
  let text key fields =
    match List.assoc key fields with
    | `String value when String.trim value <> "" -> Ok value
    | _ -> Error (Printf.sprintf "review_request %s must be non-blank text" key)
  in
  let string_list key fields =
    match List.assoc key fields with
    | `List values ->
      let rec go acc = function
        | [] -> Ok (List.rev acc)
        | `String s :: rest -> go (s :: acc) rest
        | _ -> Error (Printf.sprintf "review_request %s must be a list of strings" key)
      in
      go [] values
    | _ -> Error (Printf.sprintf "review_request %s must be a list" key)
  in
  let image_list key fields =
    match List.assoc key fields with
    | `List values ->
      let rec go acc = function
        | [] -> Ok (List.rev acc)
        | value :: rest ->
          (match evidence_image_of_json value with
           | Ok image -> go (image :: acc) rest
           | Error detail -> Error detail)
      in
      go [] values
    | _ -> Error (Printf.sprintf "review_request %s must be a list" key)
  in
  match json with
  | `Assoc fields ->
    let* task_title = text "task_title" fields in
    let* task_description = text "task_description" fields in
    let* completion_notes = text "completion_notes" fields in
    let* agent_name = text "agent_name" fields in
    let* task_id = text "task_id" fields in
    let* evidence_refs = string_list "evidence_refs" fields in
    let* evidence_images = image_list "evidence_images" fields in
    Ok AR.{ task_title; task_description; completion_notes; agent_name; task_id; evidence_refs; evidence_images }
  | _ -> Error "review_request must be an object"
;;

let evidence_posture_to_json (posture : AR.evidence_posture) : Yojson.Safe.t =
  match posture with
  | AR.Note_only -> `String "note_only"
  | AR.Usable_artifacts count -> `Assoc [ "usable_artifacts", `Int count ]
;;

let evidence_posture_of_json (json : Yojson.Safe.t) : (AR.evidence_posture, string) result =
  match json with
  | `String "note_only" -> Ok AR.Note_only
  | `Assoc [ ("usable_artifacts", `Int count) ] when count >= 0 -> Ok (AR.Usable_artifacts count)
  | _ -> Error "evidence_posture must be note_only or usable_artifacts with a non-negative count"
;;

let verdict_question_to_json (question : AR.verdict_question) : Yojson.Safe.t =
  let completion_contract =
    match question.completion_contract with
    | None -> `Null
    | Some lines -> `List (List.map (fun line -> `String line) lines)
  in
  `Assoc
    [ "completion_contract", completion_contract
    ; "required_evidence", `List (List.map (fun line -> `String line) question.required_evidence)
    ; "evidence_posture", evidence_posture_to_json question.evidence_posture
    ; "few_shot_block", `String question.few_shot_block
    ]
;;

let verdict_question_of_json (json : Yojson.Safe.t) : (AR.verdict_question, string) result =
  let string_list key fields =
    match List.assoc key fields with
    | `List values ->
      let rec go acc = function
        | [] -> Ok (List.rev acc)
        | `String s :: rest -> go (s :: acc) rest
        | _ -> Error (Printf.sprintf "verdict_question %s must be a list of strings" key)
      in
      go [] values
    | _ -> Error (Printf.sprintf "verdict_question %s must be a list" key)
  in
  match json with
  | `Assoc fields ->
    let* completion_contract =
      match List.assoc "completion_contract" fields with
      | `Null -> Ok None
      | `List _ as json ->
        string_list "completion_contract" [ ("completion_contract", json) ]
        |> Result.map (fun lines -> Some lines)
      | _ -> Error "verdict_question completion_contract must be null or a list of strings"
    in
    let* required_evidence = string_list "required_evidence" fields in
    let* evidence_posture =
      match List.assoc "evidence_posture" fields with
      | json -> evidence_posture_of_json json
      | exception Not_found -> Error "verdict_question evidence_posture is required"
    in
    let* few_shot_block =
      match List.assoc "few_shot_block" fields with
      | `String value -> Ok value
      | _ -> Error "verdict_question few_shot_block must be text"
    in
    Ok AR.{ completion_contract; required_evidence; evidence_posture; few_shot_block }
  | _ -> Error "verdict_question must be an object"
;;

let lookup_root_to_json (root : AR.lookup_root) : Yojson.Safe.t =
  match root with
  | AR.Producer_tree paths -> `Assoc [ "producer_tree", `List (List.map (fun p -> `String p) paths) ]
  | AR.Producer_root_absent { root } -> `Assoc [ "producer_root_absent", `String root ]
;;

let lookup_root_of_json (json : Yojson.Safe.t) : (AR.lookup_root, string) result =
  let string_list key fields =
    match List.assoc key fields with
    | `List values ->
      let rec go acc = function
        | [] -> Ok (List.rev acc)
        | `String s :: rest -> go (s :: acc) rest
        | _ -> Error (Printf.sprintf "lookup_root %s must be a list of strings" key)
      in
      go [] values
    | _ -> Error (Printf.sprintf "lookup_root %s must be a list" key)
  in
  match json with
  | `Assoc fields ->
    (match List.assoc_opt "producer_tree" fields with
     | Some json ->
       string_list "producer_tree" [ ("producer_tree", json) ]
       |> Result.map (fun paths -> AR.Producer_tree paths)
     | None ->
       (match List.assoc_opt "producer_root_absent" fields with
        | Some (`String root) when String.trim root <> "" -> Ok (AR.Producer_root_absent { root })
        | Some _ -> Error "lookup_root producer_root_absent must be non-blank text"
        | None -> Error "lookup_root must be producer_tree or producer_root_absent"))
  | _ -> Error "lookup_root must be an object"
;;

let lookup_schemas_to_json (schemas : string list) : Yojson.Safe.t =
  `List (List.map (fun name -> `String name) schemas)
;;

let lookup_schemas_of_json (json : Yojson.Safe.t) : (string list, string) result =
  match json with
  | `List values ->
    let rec go acc = function
      | [] -> Ok (List.rev acc)
      | `String s :: rest -> go (s :: acc) rest
      | _ -> Error "lookup_schemas must be a list of strings"
    in
    go [] values
  | _ -> Error "lookup_schemas must be a list"
;;

let field_names =
  [ "attempt"
  ; "lookup_root"
  ; "lookup_schemas"
  ; "output_contract"
  ; "question"
  ; "review_request"
  ; "schema"
  ; "system_prompt"
  ; "verification_id"
  ]
;;

let to_json t =
  `Assoc
    [ "schema", `String schema
    ; "verification_id", `String t.verification_id
    ; "attempt", `Int t.attempt
    ; "review_request", review_request_to_json t.review_request
    ; "question", verdict_question_to_json t.question
    ; "lookup_root", lookup_root_to_json t.lookup_root
    ; "lookup_schemas", lookup_schemas_to_json t.lookup_schemas
    ; "system_prompt", `String t.system_prompt
    ; "output_contract", `String t.output_contract
    ]
;;

let of_json json =
  match json with
  | `Assoc fields ->
    let names = List.sort String.compare (List.map fst fields) in
    if names <> field_names
    then Error "verifier review original has an unexpected field set"
    else (
      let text key =
        match List.assoc key fields with
        | `String value when String.trim value <> "" -> Ok value
        | _ -> Error (Printf.sprintf "verifier review original %s must be non-blank text" key)
      in
      let* version = text "schema" in
      let* () =
        if String.equal version schema
        then Ok ()
        else Error "verifier review original has an unknown schema"
      in
      let* verification_id = text "verification_id" in
      let* system_prompt = text "system_prompt" in
      let* output_contract = text "output_contract" in
      let* attempt =
        match List.assoc "attempt" fields with
        | `Int value when value >= 0 -> Ok value
        | _ -> Error "verifier review original attempt must be a non-negative integer"
      in
      let* review_request = review_request_of_json (List.assoc "review_request" fields) in
      let* question = verdict_question_of_json (List.assoc "question" fields) in
      let* lookup_root = lookup_root_of_json (List.assoc "lookup_root" fields) in
      let* lookup_schemas = lookup_schemas_of_json (List.assoc "lookup_schemas" fields) in
      if lookup_schemas = []
      then Error "verifier review original lookup_schemas must not be empty"
      else
        Ok
          { verification_id
          ; attempt
          ; review_request
          ; question
          ; lookup_root
          ; lookup_schemas
          ; system_prompt
          ; output_contract
          })
  | _ -> Error "verifier review original must be an object"
;;

let digest t =
  let* canonical = Lane_addon_action.canonical (to_json t) in
  Ok (Lane_addon_store.digest (Yojson.Safe.to_string canonical))
;;

let ( let* ) = Result.bind
