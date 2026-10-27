(** Immutable Memory-maintenance execution boundary. See the .mli. *)
let ( let* ) = Result.bind
let ( >>= ) = Result.bind
let ( let+ ) result fn = Result.map fn result

type error =
  | Request_invalid of string
  | Preparation_invalid of string
  | Proposal_invalid of Keeper_librarian.parse_error

let error_to_string = function
  | Request_invalid detail -> detail
  | Preparation_invalid detail -> detail
  | Proposal_invalid error -> Keeper_librarian.parse_error_to_string error

type owner = Keeper_librarian_durable_request.owner

let observe_owner = Keeper_librarian_durable_request.observe_owner
let discovery_scope = Keeper_librarian_durable_request.discovery_scope
let owner_matches_json = Keeper_librarian_durable_request.owner_matches_json
let fresh_request_id = Keeper_librarian_durable_request.fresh_request_id
let owner_keeper_id = Keeper_librarian_durable_request.keeper_id

type destination = Keeper_librarian_durable_request.destination

let digest_of_string text = Agent_core_sha256.(to_hex (digest_string text))

(* Field-exact JSON object reader: unknown, duplicate or missing fields refuse. *)
let fields_of error expected json =
  match json with
  | `Assoc fields when List.sort String.compare (List.map fst fields)
                      = List.sort String.compare expected ->
    Ok fields
  | _ -> Error (error "unknown, duplicate or missing fields")

let text_of error = function
  | `String value -> Ok value
  | _ -> Error (error "expected text")

let maintenance_schema = "keeper-librarian-maintenance-capture/1"

let destination_json (value : destination) : Yojson.Safe.t =
  `Assoc
    [ "installation_id", `String value.installation_id
    ; "package_id", `String value.package_id
    ; "tool", `String value.tool
    ; "source_revision", `String value.source_revision
    ; "configuration_revision", `String value.configuration_revision ]

let destination_of_json (json : Yojson.Safe.t) : (destination, string) result =
  let error detail = "Maintenance destination " ^ detail in
  let expected =
    [ "installation_id"; "package_id"; "tool"; "source_revision"
    ; "configuration_revision" ] in
  let* fields =
    match json with
    | `Assoc fields when List.sort String.compare (List.map fst fields)
                        = List.sort String.compare expected ->
      Ok fields
    | _ -> Error (error "unknown, duplicate or missing fields") in
  let field name =
    match List.assoc_opt name fields with
    | Some value -> Ok value
    | None -> Error (error ("field absent: " ^ name)) in
  let text name =
    field name
    >>= (function
      | `String value -> Ok value
      | _ -> Error (error ("field is not text: " ^ name)))
    >>= (fun value ->
      if String.trim value = "" then Error (error ("field is blank: " ^ name))
      else Ok value) in
  let* installation_id = text "installation_id" in
  let* package_id = text "package_id" in
  let* tool = text "tool" in
  let* source_revision = text "source_revision" in
  let* configuration_revision = text "configuration_revision" in
  let* () =
    if package_id = Keeper_librarian_durable_request.package_id
       && tool = Keeper_librarian_durable_request.tool
    then Ok ()
    else Error (error "package/tool differs") in
  Ok { Keeper_librarian_durable_request.installation_id
     ; Keeper_librarian_durable_request.package_id
     ; Keeper_librarian_durable_request.tool
     ; Keeper_librarian_durable_request.source_revision
     ; Keeper_librarian_durable_request.configuration_revision }

type t =
  { request_id : string
  ; owner_json : Yojson.Safe.t
  ; destination : destination
  ; preparation : Keeper_librarian_runtime.durable_preparation
  ; answer_text : string
  ; answer_digest : string
  ; captured_at : float }

let request_id t = t.request_id
let owner_json t = t.owner_json
let destination t = t.destination
let preparation t = t.preparation
let answer_text t = t.answer_text
let answer_digest t = t.answer_digest
let captured_at t = t.captured_at

let matches_owner_json t owner = owner_matches_json owner t.owner_json

let create ~request_id ~owner ~destination ~preparation ~answer_text ~captured_at =
  let error detail = Request_invalid detail in
  let* () =
    if String.trim request_id <> ""
       && String.equal request_id (String.trim request_id)
    then Ok ()
    else Error (error "request id is blank or padded") in
  let* () =
    match Keeper_identity.Keeper_id.of_string (owner_keeper_id owner) with
    | Some _ -> Ok ()
    | None -> Error (error "owner requires a canonical Keeper ID") in
  let* () =
    if destination.Keeper_librarian_durable_request.package_id
         = Keeper_librarian_durable_request.package_id
       && destination.Keeper_librarian_durable_request.tool
            = Keeper_librarian_durable_request.tool
    then Ok ()
    else Error (error "destination package/tool differs") in
  let* () =
    if String.length answer_text > 0 then Ok ()
    else Error (error "answer is empty") in
  Ok { request_id; owner_json = Keeper_librarian_durable_request.owner_to_json owner
     ; destination; preparation; answer_text
     ; answer_digest = digest_of_string answer_text; captured_at }

let policy_json (policy : Keeper_librarian_runtime.durable_policy) =
  `Assoc
    [ "facts_max_bytes", `Int policy.facts_max_bytes
    ; "category_cap", `Int policy.category_cap
    ; "facts_per_category_cap", `Int policy.facts_per_category_cap ]

let policy_of_json json =
  let error detail = "Maintenance policy " ^ detail in
  let expected =
    [ "facts_max_bytes"; "category_cap"; "facts_per_category_cap" ] in
  let* fields =
    match json with
    | `Assoc fields when List.sort String.compare (List.map fst fields)
                        = List.sort String.compare expected ->
      Ok fields
    | _ -> Error (error "unknown, duplicate or missing fields") in
  let integer name =
    match List.assoc_opt name fields with
    | Some (`Int value) -> Ok value
    | _ -> Error (error ("field is absent or not an integer: " ^ name)) in
  let* facts_max_bytes = integer "facts_max_bytes" in
  let* category_cap = integer "category_cap" in
  let+ facts_per_category_cap = integer "facts_per_category_cap" in
  ({ facts_max_bytes; category_cap; facts_per_category_cap }
     : Keeper_librarian_runtime.durable_policy)

let prompt_json (p : Prompt_registry.prompt_resolution) =
  `Assoc
    [ "effective", `String p.effective
    ; "source", `String (Prompt_registry.prompt_source_to_string p.source)
    ; "file_value", Option.fold ~none:`Null ~some:(fun text -> `String text) p.file_value
    ; "override_value", Option.fold ~none:`Null ~some:(fun text -> `String text) p.override_value
    ; "file_path", Option.fold ~none:`Null ~some:(fun text -> `String text) p.file_path
    ; "file_exists", `Bool p.file_exists
    ; "has_override", `Bool p.has_override ]

let prompt_of_json json =
  let error detail = "Maintenance prompt " ^ detail in
  let expected =
    [ "effective"; "source"; "file_value"; "override_value"; "file_path"
    ; "file_exists"; "has_override" ] in
  let* fields =
    match json with
    | `Assoc fields when List.sort String.compare (List.map fst fields)
                        = List.sort String.compare expected ->
      Ok fields
    | _ -> Error (error "unknown, duplicate or missing fields") in
  let field name =
    match List.assoc_opt name fields with
    | Some value -> Ok value
    | None -> Error (error ("field absent: " ^ name)) in
  let* effective = field "effective" >>= text_of error in
  let* source = field "source" >>= text_of error in
  let* source =
    match source with
    | "file" -> Ok Prompt_registry.File
    | "override" -> Ok Prompt_registry.Override
    | "missing" -> Ok Prompt_registry.Missing
    | _ -> Error (error "source is unknown") in
  let optional name =
    match List.assoc_opt name fields with
    | Some `Null -> Ok None
    | Some (`String value) -> Ok (Some value)
    | Some _ -> Error (error ("field is not text: " ^ name))
    | None -> Error (error ("field absent: " ^ name)) in
  let* file_value = optional "file_value" in
  let* override_value = optional "override_value" in
  let* file_path = optional "file_path" in
  let boolean name =
    match List.assoc_opt name fields with
    | Some (`Bool value) -> Ok value
    | _ -> Error (error ("field is absent or not a boolean: " ^ name)) in
  let* file_exists = boolean "file_exists" in
  let+ has_override = boolean "has_override" in
  { Prompt_registry.effective; source; file_value; override_value; file_path
  ; file_exists; has_override }

let preparation_json (p : Keeper_librarian_runtime.durable_preparation) =
  `Assoc
    [ "parsing_now", `Float p.parsing_now
    ; "policy", policy_json p.policy
    ; "rule_prompt", prompt_json p.rule_prompt
    ; "prompt", prompt_json p.prompt
    ; "variables", `List (List.map (fun (name, value) -> `List [ `String name
                                                      ; `String value ])
                          p.variables)
    ; "rendered_prompt", `String p.rendered_prompt
    ; "output_schema", p.output_schema ]

let preparation_of_json ~source_input json =
  let error detail = "Maintenance preparation " ^ detail in
  let expected =
    [ "parsing_now"; "policy"; "rule_prompt"; "prompt"; "variables"
    ; "rendered_prompt"; "output_schema" ] in
  let* fields =
    match json with
    | `Assoc fields when List.sort String.compare (List.map fst fields)
                        = List.sort String.compare expected ->
      Ok fields
    | _ -> Error (error "unknown, duplicate or missing fields") in
  let field name =
    match List.assoc_opt name fields with
    | Some value -> Ok value
    | None -> Error (error ("field absent: " ^ name)) in
  let* parsing_now =
    match List.assoc_opt "parsing_now" fields with
    | Some (`Float time) when Float.is_finite time -> Ok time
    | Some (`Int time) -> Ok (float_of_int time)
    | _ -> Error (error "parsing_now is not a finite time") in
  let* policy =
    field "policy" >>= policy_of_json in
  let* rule_prompt = field "rule_prompt" >>= prompt_of_json in
  let* prompt = field "prompt" >>= prompt_of_json in
  let* variables =
    match List.assoc_opt "variables" fields with
    | Some (`List items) ->
      List.fold_right
        (fun item tail ->
          let* tail = tail in
          match item with
          | `List [ `String name; `String value ] -> Ok ((name, value) :: tail)
          | _ -> Error (error "substitution is not a name/value pair"))
        items (Ok [])
    | _ -> Error (error "variables is not a list") in
  let* rendered_prompt =
    match List.assoc_opt "rendered_prompt" fields with
    | Some (`String value) -> Ok value
    | _ -> Error (error "rendered_prompt is not text") in
  let* output_schema =
    match List.assoc_opt "output_schema" fields with
    | Some value -> Ok value
    | None -> Error (error "output_schema is absent") in
  let preparation : Keeper_librarian_runtime.durable_preparation =
    { source_input; parsing_now; policy; rule_prompt; prompt; variables
    ; rendered_prompt; output_schema } in
  let* () =
    Keeper_librarian_runtime.validate_durable_preparation preparation in
  Ok preparation

let to_json t =
  `Assoc
    [ "schema", `String maintenance_schema
    ; "request_id", `String t.request_id
    ; "owner", t.owner_json
    ; "destination", destination_json t.destination
    ; "captured_at", `Float t.captured_at
    ; "answer_text", `String t.answer_text
    ; "answer_digest", `String t.answer_digest
    ; "preparation", preparation_json t.preparation
    ; "input", Keeper_librarian_input_capture.to_json t.preparation.source_input ]

let of_json json =
  let error detail = Request_invalid ("Maintenance boundary " ^ detail) in
  let expected =
    [ "schema"; "request_id"; "owner"; "destination"; "captured_at"
    ; "answer_text"; "answer_digest"; "preparation"; "input" ] in
  let* fields = fields_of error expected json in
  let field name =
    match List.assoc_opt name fields with
    | Some value -> Ok value
    | None -> Error (error ("field absent: " ^ name)) in
  let* schema = field "schema" >>= text_of error in
  let* () =
    if String.equal schema maintenance_schema then Ok ()
    else Error (error "schema is unknown") in
  let* request_id = field "request_id" >>= text_of error in
  let* () =
    if String.trim request_id <> ""
       && String.equal request_id (String.trim request_id)
    then Ok ()
    else Error (error "request id is blank or padded") in
  let* () =
    match List.assoc_opt "owner" fields with
    | Some (`Assoc _) -> Ok ()
    | _ -> Error (error "owner is not an object") in
  let owner_json =
    match List.assoc_opt "owner" fields with
    | Some value -> value
    | None -> `Null in
  let* destination =
    field "destination"
    >>= (fun json ->
      destination_of_json json
      |> Result.map_error (fun detail ->
             Preparation_invalid ("destination: " ^ detail))) in
  let* captured_at =
    match List.assoc_opt "captured_at" fields with
    | Some (`Float time) when Float.is_finite time -> Ok time
    | Some (`Int time) -> Ok (float_of_int time)
    | _ -> Error (error "captured_at is not a finite time") in
  let* answer_text = field "answer_text" >>= text_of error in
  let* () =
    if String.length answer_text > 0 then Ok ()
    else Error (error "answer is empty") in
  let* answer_digest = field "answer_digest" >>= text_of error in
  let* () =
    if String.equal answer_digest (digest_of_string answer_text) then Ok ()
    else Error (error "answer digest does not match its retained bytes") in
  let* input_json = field "input" in
  let* input =
    Keeper_librarian_input_capture.of_json input_json
    |> Result.map_error (fun detail -> error ("input: " ^ detail)) in
  let* () =
    match input.Keeper_librarian.current with
    | Some _ -> Ok ()
    | None -> Error (error "input lost its current snapshot") in
  let* preparation =
    field "preparation"
    >>= (fun json ->
      preparation_of_json ~source_input:input json
      |> Result.map_error (fun detail ->
             Preparation_invalid ("preparation: " ^ detail))) in
  Ok { request_id; owner_json; destination; preparation; answer_text
     ; answer_digest; captured_at }

let validate_proposal t output =
  match
    Keeper_librarian_runtime.validate_durable_proposal t.preparation output
  with
  | Ok proposal -> Ok proposal
  | Error (Preparation_invalid detail) -> Error (Preparation_invalid detail)
  | Error (Proposal_invalid parse_error) -> Error (Proposal_invalid parse_error)
