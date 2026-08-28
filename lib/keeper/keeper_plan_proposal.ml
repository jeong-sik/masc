module Surface = Keeper_capability_surface
module Plan = Keeper_tool_plan
module Request = Keeper_tool_plan_request

module Proposal_id = struct
  type t = string

  type error = Not_lowercase_sha256

  let of_string value =
    if String_util.is_lowercase_sha256_hex value
    then Ok value
    else Error Not_lowercase_sha256
  ;;

  let to_string value = value
  let equal = String.equal
end

type execution =
  | Inline
  | Async

type invalid_payload =
  | Payload_not_object
  | Json_not_canonicalizable of string
  | Unknown_field of string
  | Missing_field of string
  | Invalid_field_type of
      { field : string
      ; expected : string
      ; found : string
      }
  | Blank_field of string
  | Invalid_json_syntax of string

type digest_field =
  | Capability_surface_sha256
  | Proposal_digest

type reference_error =
  | Reference_parse_failed of
      { index : int
      ; error : Surface.ordinary_tool_reference_parse_error
      }
  | Duplicate_reference of Surface.ordinary_tool_reference
  | Unknown_descriptor_reference of Surface.ordinary_tool_reference
  | Mismatched_capability_reference of
      { reference : Surface.ordinary_tool_reference
      ; expected_capability_id : string
      }
  | Missing_plan_reference of
      { descriptor_id : string
      ; capability_id : string
      }

type error =
  | Invalid_payload of invalid_payload
  | Unsupported_version of int
  | Invalid_reference of reference_error
  | Invalid_digest of
      { field : digest_field
      ; value : string
      }
  | Plan_rejected of Request.error
  | Async_tool_not_statically_read_only of
      { descriptor_id : string
      ; capability_id : string
      }
  | Tampered_payload of
      { stored_digest : string
      ; computed_digest : string
      }
  | Filename_digest_mismatch of
      { filename_digest : string
      ; content_digest : string
      }

type t =
  { schema_version : int
  ; id : Proposal_id.t
  ; digest : string
  ; objective : string
  ; execution : execution
  ; capability_surface_sha256 : string
  ; ordinary_tool_references : Surface.ordinary_tool_reference list
  ; plan : Plan.t
  ; plan_json : Yojson.Safe.t
  ; canonical_bytes : string
  }

let current_schema_version = 1
let ( let* ) = Result.bind

let sha256 bytes = Digestif.SHA256.(digest_string bytes |> to_hex)

let canonicalize json =
  match Keeper_chat_operation.canonical_json_string json with
  | Error detail -> Error (Invalid_payload (Json_not_canonicalizable detail))
  | Ok bytes ->
    (try Ok (Yojson.Safe.from_string bytes, bytes) with
     | Yojson.Json_error detail ->
       Error (Invalid_payload (Invalid_json_syntax detail)))
;;

let execution_to_string = function
  | Inline -> "inline"
  | Async -> "async"
;;

let execution_of_string = function
  | "inline" -> Ok Inline
  | "async" -> Ok Async
  | value ->
    Error
      (Invalid_payload
         (Invalid_field_type
            { field = "execution"; expected = "inline or async"; found = value }))
;;

let reference_equal left right =
  String.equal left.Surface.descriptor_id right.Surface.descriptor_id
  && String.equal left.capability_id right.capability_id
;;

let descriptor_for_reference descriptors reference =
  match
    List.find_opt
      (fun (descriptor : Keeper_tool_descriptor.t) ->
         String.equal descriptor.id reference.Surface.descriptor_id)
      descriptors
  with
  | None -> Error (Invalid_reference (Unknown_descriptor_reference reference))
  | Some descriptor ->
    if String.equal descriptor.capability_id reference.capability_id
    then Ok descriptor
    else
      Error
        (Invalid_reference
           (Mismatched_capability_reference
              { reference; expected_capability_id = descriptor.capability_id }))
;;

let validate_references ~descriptors ~plan references =
  let rec reject_duplicates seen = function
    | reference :: _
      when List.exists (reference_equal reference) seen ->
      Error (Invalid_reference (Duplicate_reference reference))
    | reference :: rest -> reject_duplicates (reference :: seen) rest
    | [] -> Ok ()
  in
  let* () = reject_duplicates [] references in
  let* () =
    List.fold_left
      (fun result reference ->
         let* () = result in
         let* _ = descriptor_for_reference descriptors reference in
         Ok ())
      (Ok ())
      references
  in
  let plan_descriptors =
    Plan.nodes plan
    |> List.filter_map (fun node -> Plan.descriptor plan node.Plan.id)
  in
  let* () =
    List.fold_left
      (fun result (descriptor : Keeper_tool_descriptor.t) ->
         let* () = result in
         if
           List.exists
             (fun reference ->
                String.equal reference.Surface.descriptor_id descriptor.id
                && String.equal reference.capability_id descriptor.capability_id)
             references
         then Ok ()
         else
           Error
             (Invalid_reference
                (Missing_plan_reference
                   { descriptor_id = descriptor.id
                   ; capability_id = descriptor.capability_id
                   })))
      (Ok ())
      plan_descriptors
  in
  Ok references
;;

let validate_execution ~execution ~plan =
  match execution with
  | Inline -> Ok ()
  | Async ->
    Plan.nodes plan
    |> List.find_map (fun node ->
      match Plan.descriptor plan node.Plan.id with
      | Some descriptor
        when Keeper_tool_descriptor.readonly_static_hint descriptor <> Some true ->
        Some
          (Error
             (Async_tool_not_statically_read_only
                { descriptor_id = descriptor.id
                ; capability_id = descriptor.capability_id
                }))
      | Some _ | None -> None)
    |> Option.value ~default:(Ok ())
;;

let digest_payload
      ~objective
      ~execution
      ~capability_surface_sha256
      ~ordinary_tool_references
      ~plan_json
  =
  `Assoc
    [ "schema_version", `Int current_schema_version
    ; "objective", `String objective
    ; "execution", `String (execution_to_string execution)
    ; ( "source"
      , `Assoc
          [ "capability_surface_sha256", `String capability_surface_sha256 ] )
    ; ( "ordinary_tool_references"
      , `List
          (List.map Surface.ordinary_tool_reference_to_yojson ordinary_tool_references) )
    ; "plan", plan_json
    ]
;;

let create
      ~descriptors
      ~objective
      ~execution
      ~capability_surface_sha256
      ~ordinary_tool_references
      ~plan_json
  =
  if String.equal (String.trim objective) ""
  then Error (Invalid_payload (Blank_field "objective"))
  else if not (String_util.is_lowercase_sha256_hex capability_surface_sha256)
  then
    Error
      (Invalid_digest
         { field = Capability_surface_sha256; value = capability_surface_sha256 })
  else
    let* plan_json, _ = canonicalize plan_json in
    let* plan =
      Request.plan_of_json ~descriptors plan_json
      |> Result.map_error (fun error -> Plan_rejected error)
    in
    let* ordinary_tool_references =
      validate_references ~descriptors ~plan ordinary_tool_references
    in
    let* () = validate_execution ~execution ~plan in
    let payload =
      digest_payload
        ~objective
        ~execution
        ~capability_surface_sha256
        ~ordinary_tool_references
        ~plan_json
    in
    let* _, payload_bytes = canonicalize payload in
    let digest = sha256 payload_bytes in
    let* id =
      Proposal_id.of_string digest
      |> Result.map_error (fun Proposal_id.Not_lowercase_sha256 ->
        Invalid_digest { field = Proposal_digest; value = digest })
    in
    let stored_json =
      match payload with
      | `Assoc fields -> `Assoc (("proposal_digest", `String digest) :: fields)
      | _ -> payload
    in
    let* _, canonical_bytes = canonicalize stored_json in
    Ok
      { schema_version = current_schema_version
      ; id
      ; digest
      ; objective
      ; execution
      ; capability_surface_sha256
      ; ordinary_tool_references
      ; plan
      ; plan_json
      ; canonical_bytes
      }
;;

let strict_fields ~allowed = function
  | `Assoc fields ->
    (match List.find_opt (fun (field, _) -> not (List.mem field allowed)) fields with
     | Some (field, _) -> Error (Invalid_payload (Unknown_field field))
     | None -> Ok fields)
  | _ -> Error (Invalid_payload Payload_not_object)
;;

let required fields field =
  match List.assoc_opt field fields with
  | Some value -> Ok value
  | None -> Error (Invalid_payload (Missing_field field))
;;

let required_string fields field =
  let* value = required fields field in
  match value with
  | `String value when String.equal (String.trim value) "" ->
    Error (Invalid_payload (Blank_field field))
  | `String value -> Ok value
  | value ->
    Error
      (Invalid_payload
         (Invalid_field_type
            { field; expected = "string"; found = Json_util.kind_name value }))
;;

let references_of_json = function
  | `List values ->
    List.fold_left
      (fun result (index, value) ->
         let* references = result in
         match Surface.ordinary_tool_reference_of_yojson value with
         | Ok reference -> Ok (reference :: references)
         | Error error ->
           Error (Invalid_reference (Reference_parse_failed { index; error })))
      (Ok [])
      (List.mapi (fun index value -> index, value) values)
    |> Result.map List.rev
  | value ->
    Error
      (Invalid_payload
         (Invalid_field_type
            { field = "ordinary_tool_references"
            ; expected = "array"
            ; found = Json_util.kind_name value
            }))
;;

let of_stored_yojson ~descriptors ~expected_id json =
  let* json, _ = canonicalize json in
  let* fields =
    strict_fields
      ~allowed:
        [ "schema_version"
        ; "proposal_digest"
        ; "objective"
        ; "execution"
        ; "source"
        ; "ordinary_tool_references"
        ; "plan"
        ]
      json
  in
  let* version_json = required fields "schema_version" in
  let* () =
    match version_json with
    | `Int version when version = current_schema_version -> Ok ()
    | `Int version -> Error (Unsupported_version version)
    | value ->
      Error
        (Invalid_payload
           (Invalid_field_type
              { field = "schema_version"
              ; expected = "integer"
              ; found = Json_util.kind_name value
              }))
  in
  let* stored_digest = required_string fields "proposal_digest" in
  let* () =
    if String_util.is_lowercase_sha256_hex stored_digest
    then Ok ()
    else Error (Invalid_digest { field = Proposal_digest; value = stored_digest })
  in
  let* objective = required_string fields "objective" in
  let* execution_text = required_string fields "execution" in
  let* execution = execution_of_string execution_text in
  let* source_json = required fields "source" in
  let* source_fields =
    strict_fields ~allowed:[ "capability_surface_sha256" ] source_json
  in
  let* capability_surface_sha256 =
    required_string source_fields "capability_surface_sha256"
  in
  let* references_json = required fields "ordinary_tool_references" in
  let* ordinary_tool_references = references_of_json references_json in
  let* plan_json = required fields "plan" in
  let* proposal =
    create
      ~descriptors
      ~objective
      ~execution
      ~capability_surface_sha256
      ~ordinary_tool_references
      ~plan_json
  in
  if not (String.equal stored_digest proposal.digest)
  then
    Error
      (Tampered_payload
         { stored_digest; computed_digest = proposal.digest })
  else
    let filename_digest = Proposal_id.to_string expected_id in
    if not (String.equal filename_digest proposal.digest)
    then
      Error
        (Filename_digest_mismatch
           { filename_digest; content_digest = proposal.digest })
    else Ok proposal
;;

let schema_version proposal = proposal.schema_version
let id proposal = proposal.id
let digest proposal = proposal.digest
let objective proposal = proposal.objective
let execution proposal = proposal.execution
let capability_surface_sha256 proposal = proposal.capability_surface_sha256
let ordinary_tool_references proposal = proposal.ordinary_tool_references
let plan proposal = proposal.plan
let plan_json proposal = proposal.plan_json
let canonical_bytes proposal = proposal.canonical_bytes
let to_yojson proposal = Yojson.Safe.from_string proposal.canonical_bytes

let digest_field_to_string = function
  | Capability_surface_sha256 -> "capability_surface_sha256"
  | Proposal_digest -> "proposal_digest"
;;

let invalid_payload_to_yojson = function
  | Payload_not_object -> `Assoc [ "kind", `String "payload_not_object" ]
  | Json_not_canonicalizable detail ->
    `Assoc
      [ "kind", `String "json_not_canonicalizable"; "detail", `String detail ]
  | Unknown_field field ->
    `Assoc [ "kind", `String "unknown_field"; "field", `String field ]
  | Missing_field field ->
    `Assoc [ "kind", `String "missing_field"; "field", `String field ]
  | Invalid_field_type { field; expected; found } ->
    `Assoc
      [ "kind", `String "invalid_field_type"
      ; "field", `String field
      ; "expected", `String expected
      ; "found", `String found
      ]
  | Blank_field field ->
    `Assoc [ "kind", `String "blank_field"; "field", `String field ]
  | Invalid_json_syntax detail ->
    `Assoc [ "kind", `String "invalid_json_syntax"; "detail", `String detail ]
;;

let reference_error_to_yojson = function
  | Reference_parse_failed { index; error } ->
    `Assoc
      [ "kind", `String "reference_parse_failed"
      ; "index", `Int index
      ; "error", Surface.ordinary_tool_reference_parse_error_to_yojson error
      ]
  | Duplicate_reference reference ->
    `Assoc
      [ "kind", `String "duplicate_reference"
      ; "reference", Surface.ordinary_tool_reference_to_yojson reference
      ]
  | Unknown_descriptor_reference reference ->
    `Assoc
      [ "kind", `String "unknown_descriptor_reference"
      ; "reference", Surface.ordinary_tool_reference_to_yojson reference
      ]
  | Mismatched_capability_reference { reference; expected_capability_id } ->
    `Assoc
      [ "kind", `String "mismatched_capability_reference"
      ; "reference", Surface.ordinary_tool_reference_to_yojson reference
      ; "expected_capability_id", `String expected_capability_id
      ]
  | Missing_plan_reference { descriptor_id; capability_id } ->
    `Assoc
      [ "kind", `String "missing_plan_reference"
      ; "descriptor_id", `String descriptor_id
      ; "capability_id", `String capability_id
      ]
;;

let error_to_yojson = function
  | Invalid_payload payload ->
    `Assoc
      [ "kind", `String "invalid_payload"
      ; "error", invalid_payload_to_yojson payload
      ]
  | Unsupported_version version ->
    `Assoc [ "kind", `String "unsupported_version"; "version", `Int version ]
  | Invalid_reference error ->
    `Assoc
      [ "kind", `String "invalid_reference"
      ; "error", reference_error_to_yojson error
      ]
  | Invalid_digest { field; value } ->
    `Assoc
      [ "kind", `String "invalid_digest"
      ; "field", `String (digest_field_to_string field)
      ; "value", `String value
      ]
  | Plan_rejected error ->
    `Assoc
      [ "kind", `String "plan_rejected"; "error", Request.error_to_json error ]
  | Async_tool_not_statically_read_only { descriptor_id; capability_id } ->
    `Assoc
      [ "kind", `String "async_tool_not_statically_read_only"
      ; "descriptor_id", `String descriptor_id
      ; "capability_id", `String capability_id
      ]
  | Tampered_payload { stored_digest; computed_digest } ->
    `Assoc
      [ "kind", `String "tampered_payload"
      ; "stored_digest", `String stored_digest
      ; "computed_digest", `String computed_digest
      ]
  | Filename_digest_mismatch { filename_digest; content_digest } ->
    `Assoc
      [ "kind", `String "filename_digest_mismatch"
      ; "filename_digest", `String filename_digest
      ; "content_digest", `String content_digest
      ]
;;
