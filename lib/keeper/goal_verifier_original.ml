module A = Verification_authority_tools
module Evidence = Workspace_verification_store

open Result.Syntax
let schema = "goal_verifier_original/v1"

type t = {
  subject : A.goal_subject;
  base_path : string;
  attempt : int;
  submitted_evidence : Evidence.submitted_evidence_item list;
  lookup_binding : string;
  lookup_schemas : string list;
  root_layout : string list;
  prompt : string;
  system_instructions : string;
  output_contract : string;
}

let output_contract_text () =
  Printf.sprintf "Call the report_review_verdict tool exactly once with verdict one of: %s."
    (String.concat ", " Task.Anti_rationalization.valid_verdict_strings)

let render_prompt ~subject ~measurement ~lookup_schemas ~root_layout ~submitted_evidence =
  let* root_lines = match root_layout with
    | [] -> Result.map (fun text -> "  " ^ String.trim text)
        (Prompt_registry.render_prompt_template Prompt_names.verification_lookup_root_layout_empty [])
    | entries -> Ok (String.concat "\n" (List.map (fun entry -> "  " ^ entry) entries)) in
  let submitted_sources = Yojson.Safe.to_string (`List (List.map
    Evidence.submitted_evidence_item_metadata_to_yojson submitted_evidence)) in
  let* lookup_section = Prompt_registry.render_prompt_template Prompt_names.goal_verification_lookup
    ["lookup_tools", String.concat ", " lookup_schemas;
     "lookup_root_layout", root_lines; "submitted_sources", submitted_sources] in
  let Goal_store.Criterion {title; metric; target_value; revision=_} = subject.A.criterion in
  let declared = function
    | Some text when String.trim text <> "" -> text
    | Some _ | None -> "(not declared)" in
  Prompt_registry.render_prompt_template Prompt_names.goal_verification_proof
    ["goal_title", title; "metric", declared metric;
     "target_value", declared target_value;
     "reported_measurement", (Goal_measurement.observation_to_yojson measurement
       |> Yojson.Safe.to_string);
     "lookup_section", lookup_section]

let prepare ~attempt ~authority =
  if attempt < 0 then Error "Goal verifier attempt must be non-negative"
  else
    let subject = A.goal_review_subject authority in
    let measurement = A.goal_review_measurement authority in
    let base_path = A.goal_review_base_path authority in
    let submitted_evidence = A.goal_review_evidence authority in
    let lookup_binding = A.goal_review_binding authority in
    let root_layout = A.goal_review_root_layout authority in
    let lookup = A.goal_review_lookup authority in
    let lookup_schemas = List.map (fun (tool : Types_core.tool_schema) -> tool.name) lookup.schemas in
    let* prompt = render_prompt ~subject ~measurement ~lookup_schemas ~root_layout ~submitted_evidence in
    let* system_instructions = Prompt_registry.render_prompt_template Prompt_names.verification_system [] in
    Ok {subject; base_path; attempt; submitted_evidence; lookup_binding; lookup_schemas; root_layout;
      prompt; system_instructions; output_contract=output_contract_text ()}

let subject t = t.subject
let base_path t = t.base_path
let attempt t = t.attempt
let submitted_evidence t = t.submitted_evidence
let lookup_binding t = t.lookup_binding
let lookup_schemas t = t.lookup_schemas
let root_layout t = t.root_layout
let prompt t = t.prompt
let system_instructions t = t.system_instructions
let output_contract t = t.output_contract

let matches_authority t authority =
  let other = A.goal_review_subject authority in
  String.equal t.subject.goal_id other.goal_id
  && String.equal t.subject.request_id other.request_id
  && Goal_store.criterion_equal t.subject.criterion other.criterion
  && String.equal t.lookup_binding (A.goal_review_binding authority)
  && String.equal t.base_path (A.goal_review_base_path authority)
  && t.lookup_schemas = List.map (fun (tool : Types_core.tool_schema) -> tool.name)
       (A.goal_review_lookup authority).schemas
  && Yojson.Safe.equal
       (`List (List.map Evidence.submitted_evidence_item_to_yojson t.submitted_evidence))
       (`List (List.map Evidence.submitted_evidence_item_to_yojson (A.goal_review_evidence authority)))

let to_json t =
  `Assoc ["schema", `String schema;
    "base_path", `String t.base_path;
    "subject", `Assoc ["goal_id", `String t.subject.goal_id;
      "request_id", `String t.subject.request_id;
      "criterion", Goal_store.criterion_to_yojson t.subject.criterion];
    "attempt", `Int t.attempt;
    "submitted_evidence", `List (List.map Evidence.submitted_evidence_item_to_yojson t.submitted_evidence);
    "lookup_binding", `String t.lookup_binding;
    "lookup_schemas", Json_util.json_string_list t.lookup_schemas;
    "root_layout", Json_util.json_string_list t.root_layout;
    "prompt", `String t.prompt;
    "system_instructions", `String t.system_instructions;
    "output_contract", `String t.output_contract]

let of_json json =
  let surface = "Goal verifier original" in
  let field fields key = match List.assoc_opt key fields with
    | Some value -> Ok value | None -> Error (surface ^ "." ^ key ^ " is required") in
  let* fields = match json with `Assoc fields -> Ok fields | _ -> Error (surface ^ " must be an object") in
  let* () = Json_util.reject_unknown_fields ~surface ~allowed:["schema"; "subject"; "base_path"; "attempt";
    "submitted_evidence"; "lookup_binding"; "lookup_schemas"; "root_layout"; "prompt";
    "system_instructions"; "output_contract"] fields in
  let text key = Json_util.require_field_string ~surface key fields in
  let* version = text "schema" in
  let* () = if String.equal version schema then Ok () else Error "Unknown Goal verifier original schema" in
  let* base_path = text "base_path" in
  let* subject_json = field fields "subject" in
  let* subject_fields = match subject_json with
    | `Assoc fields -> Ok fields | _ -> Error "Goal proof subject must be an object" in
  let* () = Json_util.reject_unknown_fields ~surface:"Goal proof subject"
    ~allowed:["goal_id"; "request_id"; "criterion"] subject_fields in
  let* goal_id = Json_util.require_field_string ~surface "goal_id" subject_fields in
  let* request_id = Json_util.require_field_string ~surface "request_id" subject_fields in
  let* criterion_json = field subject_fields "criterion" in
  let* criterion = Goal_store.criterion_of_yojson criterion_json in
  let subject : A.goal_subject = {goal_id; request_id; criterion} in
  let* attempt_json = field fields "attempt" in
  let* attempt = match attempt_json with
    | `Int n when n >= 0 -> Ok n | _ -> Error "Goal verifier attempt must be non-negative" in
  let* evidence_json = field fields "submitted_evidence" in
  let* evidence_list = match evidence_json with
    | `List values -> Ok values | _ -> Error "Goal verifier evidence must be a list" in
  let* submitted_evidence = List.fold_right (fun json rest ->
    let* item = Evidence.submitted_evidence_item_of_yojson json in
    let* rest = rest in Ok (item::rest)) evidence_list (Ok []) in
  let* lookup_binding = text "lookup_binding" in
  let* () = if String_util.is_lowercase_sha256_hex lookup_binding then Ok ()
    else Error "Goal verifier authority digest is invalid" in
  let* lookup_schemas = Json_util.require_field_string_list ~surface "lookup_schemas" fields in
  let* root_layout = Json_util.require_field_string_list ~surface "root_layout" fields in
  let* prompt = text "prompt" in
  let* system_instructions = text "system_instructions" in
  let* output_contract = text "output_contract" in
  let original = {subject; base_path; attempt; submitted_evidence; lookup_binding; lookup_schemas;
    root_layout; prompt; system_instructions; output_contract} in
  (* Existing criterion/evidence codecs own their domain validation. Require
     exact semantic round-trip here as well, so no nested extra field or
     normalized value can disappear silently from an immutable original. *)
  if Yojson.Safe.equal (to_json original) json then Ok original
  else Error "Goal verifier original does not round-trip exactly"

let digest t =
  let* canonical = Lane_addon_action.canonical (to_json t) in
  Ok (Lane_addon_store.digest (Yojson.Safe.to_string canonical))

let successor t =
  if t.attempt = Int.max_int then Error "Goal verifier attempt identity exhausted"
  else Ok {t with attempt=t.attempt+1}
