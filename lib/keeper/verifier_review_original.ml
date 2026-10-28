(** The immutable original of one verifier review attempt. *)

module AR = Task.Anti_rationalization

open Result.Syntax

let schema = "verifier_review_original/v3"

(* Strict JSON decoding helpers. A decoder that reads a required key with a
   bare [List.assoc] leaks [Not_found] out of the [result] on a missing key,
   and one that ignores unknown or duplicate fields is not the strict inverse
   the interface documents. [require_fields] rejects both; [field] then reads a
   key that is known to be present exactly once. *)

let require_fields ~what ~expected fields =
  let seen = List.map fst fields in
  let has_dup = List.length seen <> List.length (List.sort_uniq String.compare seen) in
  if has_dup
  then Error (Printf.sprintf "%s has duplicate fields" what)
  else (
    let seen_sorted = List.sort String.compare seen in
    let expected_sorted = List.sort String.compare expected in
    if seen_sorted <> expected_sorted
    then
      Error
        (Printf.sprintf "%s has an unexpected field set (want [%s])" what
           (String.concat "; " expected_sorted))
    else Ok ())

let field key fields : (Yojson.Safe.t, string) result =
  match List.assoc_opt key fields with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "missing field %s" key)

(* A string field that may legitimately be blank. [build_prompt] renders
   [review_request.task_description] and [review_request.completion_notes]
   with no non-blank check, so decode accepts the same blank strings prepare
   accepts and a stored original always reads back. *)
let field_string key fields : (string, string) result =
  let* value = field key fields in
  match value with
  | `String value -> Ok value
  | _ -> Error (Printf.sprintf "field %s must be a string" key)

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
        (fun ~name:_ ~args:_ ->
          Tool_result.error
            ~failure_class:Tool_result.Policy_rejection
            ~tool_name:"verifier_review_original.lookup"
            ~start_time:(Tool_timing.start ())
            "lookup is not available in original preparation")
    }
  in
  AR.build_prompt ~question ~lookup ~lookup_root req
;;

type t =
  { verification_id : string
  ; attempt : int
  ; review_request : AR.review_request
  ; generator_runtime : string option
  ; question : AR.verdict_question
  ; lookup_root : AR.lookup_root
  ; lookup_schemas : string list
  ; lookup_binding : string
  ; system_prompt : string
  ; system_instructions : string
  ; output_contract : string
  }

let prepare ~generator_runtime ~verification_id ~attempt ~question ~lookup_root ~lookup_schemas ~lookup_binding req =
  if Option.fold ~none:false ~some:(fun runtime -> String.trim runtime = "") generator_runtime
  then Error "verifier review original generator_runtime must be non-blank when present"
  else if String.trim verification_id = ""
  then Error "verifier review original requires a non-blank verification_id"
  else if attempt < 0
  then Error "verifier review original attempt must be a non-negative integer"
  else if not (String_util.is_lowercase_sha256_hex lookup_binding)
  then Error "verifier review original requires a canonical authority digest"
  else if lookup_schemas = []
  then Error "verifier review original requires the reviewer's lookup tool names"
  else (
    let* system_prompt =
      system_prompt ~lookup_schemas ~question ~lookup_root req
      |> Result.map_error (fun detail -> "verifier review prompt unavailable: " ^ detail)
    in
    let* system_instructions=Prompt_registry.render_prompt_template Prompt_names.verification_system [] in
    Ok
      { verification_id
      ; attempt
      ; review_request = req
      ; generator_runtime
      ; question
      ; lookup_root
      ; lookup_schemas
      ; lookup_binding
      ; system_prompt
      ; system_instructions
      ; output_contract = canonical_output_contract ()
      })
;;

let verification_id t = t.verification_id
let attempt t = t.attempt
let review_request t = t.review_request
let generator_runtime t = t.generator_runtime
let question t = t.question
let lookup_root t = t.lookup_root
let lookup_schemas t = t.lookup_schemas
let lookup_binding t = t.lookup_binding
let system_prompt_text t = t.system_prompt
let system_instructions t = t.system_instructions
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
    let* value = field key fields in
    match value with
    | `String value when String.trim value <> "" -> Ok value
    | _ -> Error (Printf.sprintf "evidence_image %s must be non-blank text" key)
  in
  let int key fields =
    let* value = field key fields in
    match value with
    | `Int value when value >= 0 -> Ok value
    | _ -> Error (Printf.sprintf "evidence_image %s must be a non-negative integer" key)
  in
  match json with
  | `Assoc fields ->
    let* () =
      require_fields ~what:"evidence_image"
        ~expected:[ "image_reference"; "image_sha256"; "image_bytes"; "image_media_type"; "image_body_base64" ]
        fields
    in
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
    let* value = field key fields in
    match value with
    | `String value when String.trim value <> "" -> Ok value
    | _ -> Error (Printf.sprintf "review_request %s must be non-blank text" key)
  in
  let string_list key fields =
    let* value = field key fields in
    match value with
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
    let* value = field key fields in
    match value with
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
    let* () =
      require_fields ~what:"review_request"
        ~expected:[ "task_title"; "task_description"; "completion_notes"; "agent_name"; "task_id"; "evidence_refs"; "evidence_images" ]
        fields
    in
    (* [build_prompt] renders task_description and completion_notes without
       any non-blank check, and the runtime can legitimately carry an empty
       completion_notes; decode accepts the same blank strings prepare accepts
       so a stored original always reads back. Only the identity fields
       (task_title, agent_name, task_id) require non-blank. *)
    let* task_title = text "task_title" fields in
    let* task_description = field_string "task_description" fields in
    let* completion_notes = field_string "completion_notes" fields in
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
    let* value = field key fields in
    match value with
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
    let* () =
      require_fields ~what:"verdict_question"
        ~expected:[ "completion_contract"; "required_evidence"; "evidence_posture"; "few_shot_block" ]
        fields
    in
    let* completion_contract =
      let* value = field "completion_contract" fields in
      match value with
      | `Null -> Ok None
      | `List _ -> string_list "completion_contract" [ ("completion_contract", value) ] |> Result.map Option.some
      | _ -> Error "verdict_question completion_contract must be null or a list of strings"
    in
    let* required_evidence = string_list "required_evidence" fields in
    let* evidence_posture =
      let* value = field "evidence_posture" fields in
      evidence_posture_of_json value
    in
    let* few_shot_block =
      let* value = field "few_shot_block" fields in
      match value with
      | `String value -> Ok value
      | _ -> Error "verdict_question few_shot_block must be text"
    in
    Ok AR.{ completion_contract; required_evidence; evidence_posture; few_shot_block }
  | _ -> Error "verdict_question must be an object"
;;

let lookup_root_to_json (root : AR.lookup_root) : Yojson.Safe.t =
  match root with
  | AR.Producer_namespace { root } -> `Assoc [ "producer_namespace", `String root ]
  | AR.Producer_tree paths -> `Assoc [ "producer_tree", `List (List.map (fun p -> `String p) paths) ]
  | AR.Producer_root_absent { root } -> `Assoc [ "producer_root_absent", `String root ]
;;

let lookup_root_of_json (json : Yojson.Safe.t) : (AR.lookup_root, string) result =
  let string_list key fields =
    let* value = field key fields in
    match value with
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
    (match fields with
    | [ "producer_tree", _ ] ->
        let* paths = string_list "producer_tree" fields in
        Ok (AR.Producer_tree paths)
    | [ "producer_namespace", `String root ] when String.trim root <> "" ->
        Ok (AR.Producer_namespace { root })
    | [ "producer_root_absent", `String root ] when String.trim root <> "" ->
        Ok (AR.Producer_root_absent { root })
    | _ -> Error "lookup_root must contain exactly one valid producer root variant")
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
  ; "generator_runtime"
  ; "lookup_binding"
  ; "lookup_root"
  ; "lookup_schemas"
  ; "output_contract"
  ; "question"
  ; "review_request"
  ; "schema"
  ; "system_instructions"
  ; "system_prompt"
  ; "verification_id"
  ]
;;

let to_json t =
  `Assoc
    [ "schema", `String schema
    ; "verification_id", `String t.verification_id
    ; "attempt", `Int t.attempt
    ; "generator_runtime", Json_util.string_opt_to_json t.generator_runtime
    ; "review_request", review_request_to_json t.review_request
    ; "question", verdict_question_to_json t.question
    ; "lookup_root", lookup_root_to_json t.lookup_root
    ; "lookup_schemas", lookup_schemas_to_json t.lookup_schemas
    ; "lookup_binding", `String t.lookup_binding
    ; "system_instructions", `String t.system_instructions
    ; "system_prompt", `String t.system_prompt
    ; "output_contract", `String t.output_contract
    ]
;;

let of_json json =
  match json with
  | `Assoc fields ->
    let names = List.map fst fields in
    let has_dup = List.length names <> List.length (List.sort_uniq String.compare names) in
    let names_sorted = List.sort String.compare names in
    if has_dup
    then Error "verifier review original has duplicate fields"
    else if names_sorted <> field_names
    then Error "verifier review original has an unexpected field set"
    else (
      let text key =
        let* value = field key fields in
        match value with
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
      let* lookup_binding = text "lookup_binding" in
      let* () =
        if String_util.is_lowercase_sha256_hex lookup_binding then Ok ()
        else Error "verifier review original authority digest is invalid" in
      let* system_prompt = text "system_prompt" in
      let* system_instructions = text "system_instructions" in
      let* output_contract = text "output_contract" in
      let* attempt =
        let* value = field "attempt" fields in
        match value with
        | `Int value when value >= 0 -> Ok value
        | _ -> Error "verifier review original attempt must be a non-negative integer"
      in
      let* generator_runtime =
        let* value = field "generator_runtime" fields in
        match value with
        | `Null -> Ok None
        | `String runtime when String.trim runtime <> "" -> Ok (Some runtime)
        | _ -> Error "verifier review original generator_runtime must be null or non-blank text"
      in
      let* review_request_json = field "review_request" fields in
      let* question_json = field "question" fields in
      let* lookup_root_json = field "lookup_root" fields in
      let* lookup_schemas_json = field "lookup_schemas" fields in
      let* review_request = review_request_of_json review_request_json in
      let* question = verdict_question_of_json question_json in
      let* lookup_root = lookup_root_of_json lookup_root_json in
      let* lookup_schemas = lookup_schemas_of_json lookup_schemas_json in
      if lookup_schemas = []
      then Error "verifier review original lookup_schemas must not be empty"
      else
        Ok
          { verification_id
          ; attempt
          ; review_request
          ; generator_runtime
          ; question
          ; lookup_root
          ; lookup_schemas
          ; lookup_binding
          ; system_prompt
          ; system_instructions
          ; output_contract
          })
  | _ -> Error "verifier review original must be an object"
;;

let digest t =
  let* canonical = Lane_addon_action.canonical (to_json t) in
  Ok (Lane_addon_store.digest (Yojson.Safe.to_string canonical))
;;

let successor original =
  if original.attempt = Int.max_int then Error "verifier attempt identity exhausted"
  else Ok {original with attempt=original.attempt + 1}
