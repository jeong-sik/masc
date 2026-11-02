module Context = Keeper_librarian_context
module Jev = Typesafeai_types

type verdict = Faithful | Needs_revision | Insufficient_evidence
let label = function
  | Faithful -> "faithful"
  | Needs_revision -> "needs_revision"
  | Insufficient_evidence -> "insufficient_evidence"
let choices ~describe = Jev.choice_set
  ~options:[Faithful; Needs_revision; Insufficient_evidence] ~label
  ~describe
let question_id = "meaning_preservation"
let question () =
  let open Result.Syntax in
  let* faithful = Prompt_registry.render_prompt_template Prompt_names.librarian_context_review_faithful [] in
  let* needs_revision = Prompt_registry.render_prompt_template Prompt_names.librarian_context_review_needs_revision [] in
  let* insufficient_evidence = Prompt_registry.render_prompt_template Prompt_names.librarian_context_review_insufficient_evidence [] in
  let* choices = choices ~describe:(function
    | Faithful -> Some faithful
    | Needs_revision -> Some needs_revision
    | Insufficient_evidence -> Some insufficient_evidence) in
  let* instructions =
    Prompt_registry.render_prompt_template Prompt_names.librarian_context_review []
  in
  Ok (choices, Jev.choice_of_set ~instructions choices)

type request = { destinations : Typesafeai_client.destination_id list; state : Yojson.Safe.t; question : Jev.question }
type result =
  | Judged of { receipt : Typesafeai_client.evaluated; verdict : verdict }
  | Invalid_answer of { receipt : Typesafeai_client.evaluated; detail : string }
  | Failed of Typesafeai_client.failure
type skip_reason = No_contexts | Unavailable of Typesafeai_config.unavailable_reason
  | Invalid_question of string
type observation =
  | Skipped of skip_reason
  | Checking of request
  | Complete of { request : request; result : result; elapsed_s : float }

let source_json (s : Context.source) =
  `Assoc ["reference", `String s.reference; "content", s.content]
let strings xs = `List (List.map (fun s -> `String s) xs)
let optional_string = function None -> `Null | Some s -> `String s
let state (input : Context.input) (proposed : Context.pocket list) =
  let selected = List.concat_map (fun (p : Context.pocket) -> p.sources) proposed in
  let targets = List.concat_map (fun (p : Context.pocket) -> p.merge_contexts) proposed in
  let previous = match input.previous with
    | None -> []
    | Some previous -> List.filter_map (fun (p : Context.pocket) ->
        if not (List.mem p.id targets) then None else
        Some (`Assoc ["id", `String p.id; "context", `String p.context;
          "next_steps", strings p.next_steps;
          "completeness", `String (match p.completeness with
            | Context.Current -> "current" | Needs_reconsideration -> "needs_reconsideration");
          "sources", `List (List.filter_map (fun (s : Context.source) ->
            if List.mem s.reference p.sources then Some (source_json s) else None) previous.sources)])) previous.pockets
  in
  `Assoc ["proposed_contexts", Context.pockets_to_json proposed;
    "selected_sources", `List (List.filter_map (fun (s : Context.source) ->
      if List.mem s.reference selected then Some (source_json s) else None) input.sources);
    "merged_previous", `List previous;
    "observed_references", strings (List.map (fun (s : Context.source) -> s.reference) input.sources);
    "unavailable", strings input.unavailable;
    "execution_basis", `Assoc [
      "previous", optional_string (Option.bind input.previous (fun s -> s.Context.execution_basis));
      "current", optional_string input.execution_basis]]

let receipt_json (r : Typesafeai_client.evaluated) =
  `Assoc ["model", `String r.response.model;
    "destination_uri", `String r.destination.destination_uri;
    "requested_model", `String r.destination.model;
    "passed_over", `List (List.map Typesafeai_client.attempt_to_yojson r.passed_over);
    "request_body_sha256", `String r.request_body_sha256;
    "answers", `Assoc (List.map (fun (id, answer) -> id, Jev.answer_to_yojson answer) r.response.answers);
    "usage", (match r.response.usage with None -> `Null | Some u ->
      `Assoc ["input_tokens", `Int u.input_tokens; "output_tokens", `Int u.output_tokens])]
let request_json request = `Assoc [
  "destinations", `List (List.map Typesafeai_client.destination_id_to_yojson request.destinations);
  "state", request.state;
  "questions", `Assoc [question_id, Jev.question_to_yojson request.question]]
let observation_to_yojson = function
  | Skipped reason -> `Assoc ["status", `String "skipped"; "reason", `String (match reason with
      | No_contexts -> "no_contexts"
      | Unavailable r -> Typesafeai_config.unavailable_reason_to_string r
      | Invalid_question detail -> detail)]
  | Checking request -> `Assoc ["status", `String "incomplete"; "request", request_json request]
  | Complete {request; result; elapsed_s} ->
    let fields = match result with
      | Judged {receipt; verdict} -> ["status", `String "judged"; "verdict", `String (label verdict); "response", receipt_json receipt]
      | Invalid_answer {receipt; detail} -> ["status", `String "invalid_answer"; "detail", `String detail; "response", receipt_json receipt]
      | Failed failure -> ["status", `String "failed"; "failure", Typesafeai_client.failure_to_yojson failure]
    in `Assoc (fields @ ["elapsed_s", `Float elapsed_s; "request", request_json request])

let permits_publication = function
  | Complete {result = Judged {verdict = Needs_revision; _}; _} -> false
  | Skipped _ | Checking _
  | Complete
      { result =
          ( Judged { verdict = Faithful | Insufficient_evidence; _ }
          | Invalid_answer _ | Failed _ )
      ; _
      } -> true

let run ?(observe = fun _ -> ()) ?clock ~keeper_id ~input ~proposed () =
  let finish observation = observe observation; observation in
  if proposed = [] then finish (Skipped No_contexts) else
  match Typesafeai_config.context_review_destinations ~keeper_id with
  | Error reason -> finish (Skipped (Unavailable reason))
  | Ok ((first, rest) as armed) ->
    match question () with
    | Error detail -> finish (Skipped (Invalid_question detail))
    | Ok (choices, question) ->
    let request = { destinations = List.map Typesafeai_client.identify (first :: rest);
      state = state input proposed; question } in
    observe (Checking request);
    let now () = match clock with Some clock -> Eio.Time.now clock | None -> Time_compat.now () in
    let started = now () in
    let result = match Typesafeai_client.evaluate ?clock ~destinations:armed
        ~state:request.state ~questions:[question_id, request.question] () with
      | Error failure -> Failed failure
      | Ok receipt ->
        let decoded = match receipt.response.answers with
          | [id, answer] when String.equal id question_id -> Jev.decode_choice choices answer
          | _ -> Error "context review requires exactly one meaning_preservation answer" in
        match decoded with
        | Ok answer -> Judged {receipt; verdict = answer.choice}
        | Error detail -> Invalid_answer {receipt; detail}
    in finish (Complete {request; result; elapsed_s = now () -. started})
