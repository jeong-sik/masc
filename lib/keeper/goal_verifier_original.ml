module A = Verification_authority_tools
module Evidence = Workspace_verification_store

open Result.Syntax
let schema = "goal_verifier_original/v2"

type t = {
  subject : A.goal_subject;
  base_path : string;
  attempt : int;
  submitted_evidence : Evidence.submitted_evidence_item list;
  measurement : Goal_measurement.observation;
  question_binding : string;
  authority_binding : string;
  lookup_schemas : string list;
  root_layout : string list;
  prompt : string;
  system_instructions : string;
  output_contract : string;
}

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

let lookup_names authority =
  List.map (fun (tool : Types_core.tool_schema) -> tool.name) (A.goal_review_lookup authority).schemas

(* The question parts come from the caller. The lookup grants, the rendered
   prompt, the instructions and the answer format are built now. *)
let build ~attempt ~subject ~base_path ~submitted_evidence ~measurement ~question_binding authority =
  let authority_binding = A.goal_review_authority_binding authority in
  let root_layout = A.goal_review_root_layout authority in
  let lookup_schemas = lookup_names authority in
  let* prompt = render_prompt ~subject ~measurement ~lookup_schemas ~root_layout ~submitted_evidence in
  let* system_instructions = Prompt_registry.render_prompt_template Prompt_names.verification_system [] in
  Ok {subject; base_path; attempt; submitted_evidence; measurement; question_binding; authority_binding;
    lookup_schemas; root_layout; prompt; system_instructions;
    output_contract = Verifier_review_original.canonical_output_contract ()}

let prepare ~attempt ~authority =
  if attempt < 0 then Error "Goal verifier attempt must be non-negative"
  else
    build ~attempt ~subject:(A.goal_review_subject authority)
      ~base_path:(A.goal_review_base_path authority)
      ~submitted_evidence:(A.goal_review_evidence authority)
      ~measurement:(A.goal_review_measurement authority)
      ~question_binding:(A.goal_review_question_binding authority) authority

let subject t = t.subject
let base_path t = t.base_path
let attempt t = t.attempt
let submitted_evidence t = t.submitted_evidence
let measurement t = t.measurement
let question_binding t = t.question_binding
let authority_binding t = t.authority_binding
let lookup_schemas t = t.lookup_schemas
let root_layout t = t.root_layout
let prompt t = t.prompt
let system_instructions t = t.system_instructions
let output_contract t = t.output_contract

let evidence_json items = `List (List.map Evidence.submitted_evidence_item_to_yojson items)

let question_matches t authority =
  let other = A.goal_review_subject authority in
  String.equal t.subject.goal_id other.goal_id
  && String.equal t.subject.request_id other.request_id
  && Goal_store.criterion_equal t.subject.criterion other.criterion
  && String.equal t.base_path (A.goal_review_base_path authority)
  && Yojson.Safe.equal (evidence_json t.submitted_evidence) (evidence_json (A.goal_review_evidence authority))
  && String.equal t.question_binding (A.goal_review_question_binding authority)

let authority_change t authority =
  Verifier_review_authority_change.between ~retained_authority:t.authority_binding
    ~current_authority:(A.goal_review_authority_binding authority)
    ~retained_format:t.output_contract
    ~current_format:(Verifier_review_original.canonical_output_contract ())

let to_json t =
  `Assoc ["schema", `String schema;
    "base_path", `String t.base_path;
    "subject", `Assoc ["goal_id", `String t.subject.goal_id;
      "request_id", `String t.subject.request_id;
      "criterion", Goal_store.criterion_to_yojson t.subject.criterion];
    "attempt", `Int t.attempt;
    "submitted_evidence", evidence_json t.submitted_evidence;
    "measurement", Goal_measurement.observation_to_yojson t.measurement;
    "question_binding", `String t.question_binding;
    "authority_binding", `String t.authority_binding;
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
    "submitted_evidence"; "measurement"; "question_binding"; "authority_binding"; "lookup_schemas";
    "root_layout"; "prompt"; "system_instructions"; "output_contract"] fields in
  let text key = Json_util.require_field_string ~surface key fields in
  let digest key =
    let* value = text key in
    if String_util.is_lowercase_sha256_hex value then Ok value
    else Error (surface ^ "." ^ key ^ " is not a canonical digest") in
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
  let* submitted_evidence =
    let rec loop acc = function
      | [] -> Ok (List.rev acc)
      | json :: rest ->
        let* item = Evidence.submitted_evidence_item_of_yojson json in
        loop (item :: acc) rest
    in
    loop [] evidence_list
  in
  let* measurement_json = field fields "measurement" in
  let* measurement = Goal_measurement.observation_of_yojson measurement_json in
  let* question_binding = digest "question_binding" in
  let* authority_binding = digest "authority_binding" in
  let* lookup_schemas = Json_util.require_field_string_list ~surface "lookup_schemas" fields in
  let* root_layout = Json_util.require_field_string_list ~surface "root_layout" fields in
  let* prompt = text "prompt" in
  let* system_instructions = text "system_instructions" in
  let* output_contract = text "output_contract" in
  let original = {subject; base_path; attempt; submitted_evidence; measurement; question_binding;
    authority_binding; lookup_schemas; root_layout; prompt; system_instructions; output_contract} in
  (* Existing criterion/evidence/measurement codecs own their domain
     validation. Require exact semantic round-trip here as well, so no nested
     extra field or normalized value can disappear silently from an immutable
     original. *)
  if Yojson.Safe.equal (to_json original) json then Ok original
  else Error "Goal verifier original does not round-trip exactly"

let digest t =
  let* canonical = Lane_addon_action.canonical (to_json t) in
  Ok (Lane_addon_store.digest (Yojson.Safe.to_string canonical))

type successor_error =
  | Question_changed
  | Prompt_unavailable of string
  | Successor_unavailable of string

(* HIGH-RISK-UNREVIEWED: the next attempt takes the reviewer's lookup grants,
   prompt, instructions and answer format from [authority], the authority
   current at that attempt, instead of copying the parent's. Only the question
   travels: subject, workspace, submitted snapshot, reported measurement and
   question digest come from the parent. An [authority] for another question
   is refused, never adopted. *)
let successor ~authority parent =
  if not (question_matches parent authority) then Error Question_changed
  else if parent.attempt = Int.max_int
  then Error (Successor_unavailable "Goal verifier attempt identity exhausted")
  else
    build ~attempt:(parent.attempt + 1) ~subject:parent.subject ~base_path:parent.base_path
      ~submitted_evidence:parent.submitted_evidence ~measurement:parent.measurement
      ~question_binding:parent.question_binding authority
    |> Result.map_error (fun detail -> Prompt_unavailable detail)

let is_successor_of ~parent child =
  child.attempt = parent.attempt + 1
  && String.equal child.subject.goal_id parent.subject.goal_id
  && String.equal child.subject.request_id parent.subject.request_id
  && Goal_store.criterion_equal child.subject.criterion parent.subject.criterion
  && String.equal child.base_path parent.base_path
  && Yojson.Safe.equal (evidence_json child.submitted_evidence) (evidence_json parent.submitted_evidence)
  && Yojson.Safe.equal (Goal_measurement.observation_to_yojson child.measurement)
       (Goal_measurement.observation_to_yojson parent.measurement)
  && String.equal child.question_binding parent.question_binding
