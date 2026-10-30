module Types = Typesafeai_types

type candidate = { id : string; summary : string }
type use = For_current_decision | For_comparison

type evaluation_error = Capacity_refused of string | Unavailable of string

type deferred =
  | Evaluation_failed of string
  | Capacity_unresolved of string
  | Invalid_answer of string
  | Source_unavailable of string
  | Applicability_unresolved

type outcome =
  | Selected of { candidate : candidate; use : use; source_detail : Yojson.Safe.t }
  | Not_needed of candidate
  | Deferred of { candidate : candidate; reason : deferred }

type evaluate =
  state:Yojson.Safe.t -> questions:(string * Types.question) list ->
  (Types.eval_response, evaluation_error) result

type decision = Include of use | Inspect_source | Omit

let label = function
  | Include For_current_decision -> "current_decision"
  | Include For_comparison -> "comparison"
  | Inspect_source -> "inspect_source"
  | Omit -> "not_needed"

let choices = Types.choice_set
  ~options:[Include For_current_decision; Include For_comparison; Inspect_source; Omit]
  ~label ~describe:(function
    | Include For_current_decision -> Some
        "A constraint, causal observation, state or uncertainty directly informs the current decision within its stated scope. This is not independent verification."
    | Include For_comparison -> Some
        "A specific contrast, analogy or counterexample helps answer the stated question, distinguish its alternatives or correct a stated assumption, while belonging to another event, environment or scope. Identify that contribution from the supplied purpose and evidence; shared topic or different scope alone is insufficient. It remains comparison, not evidence of the current event's state."
    | Inspect_source -> Some
        "Applicability or useful scope cannot be established without resolving missing or conflicting source information."
    | Omit -> Some
        "No useful contribution to this purpose is established. Shared topic or general Keeper interest alone is insufficient; this does not retire the memory.")

let instruction_error detail = Evaluation_failed ("memory selection prompt: " ^ detail)

let load_instructions () =
  Prompt_registry.render_prompt_template Prompt_names.keeper_memory_selection []
  |> Result.map String.trim
  |> Result.map_error instruction_error

let load_batch_instructions () =
  let open Result.Syntax in
  let* instructions = load_instructions () in
  let+ scope_prompt, _ =
    Prompt_registry.resolve_and_render_prompt_template
      Prompt_names.keeper_memory_selection_candidate ["question_id", "prompt-validation"]
    |> Result.map_error instruction_error
  in
  instructions, scope_prompt

let assess ~instructions ~evaluate ~purpose ~candidate ~source_detail =
  match choices with
  | Error detail -> Error (Invalid_answer detail)
  | Ok choices ->
    let state = `Assoc
      ["current_purpose", purpose;
       "candidate", `Assoc ["id", `String candidate.id; "summary", `String candidate.summary];
       "source_detail", (match source_detail with None -> `Null | Some detail -> detail)] in
    let questions = ["selection", Types.choice_of_set choices ~instructions] in
    match evaluate ~state ~questions with
    | Error (Unavailable detail) -> Error (Evaluation_failed detail)
    | Error (Capacity_refused detail) -> Error (Capacity_unresolved detail)
    | Ok response ->
      match response.Types.answers with
      | ["selection", answer] ->
        Types.decode_choice choices answer
        |> Result.map (fun (judgment : decision Types.decoded_choice) -> judgment.choice)
        |> Result.map_error (fun detail -> Invalid_answer detail)
      | _ -> Error (Invalid_answer "memory selection requires exactly one selection answer")

let select ~evaluate ~resolve ~purpose candidate =
  let deferred reason = Deferred {candidate; reason} in
  match load_instructions () with
  | Error reason -> deferred reason
  | Ok instructions ->
  match assess ~instructions ~evaluate ~purpose ~candidate ~source_detail:None with
  | Error reason -> deferred reason
  | Ok Omit -> Not_needed candidate
  | Ok (Include _ | Inspect_source) ->
    match resolve ~id:candidate.id with
    | Error detail -> deferred (Source_unavailable detail)
    | Ok source_detail ->
      match assess ~instructions ~evaluate ~purpose ~candidate ~source_detail:(Some source_detail) with
      | Error reason -> deferred reason
      | Ok Omit -> Not_needed candidate
      | Ok Inspect_source -> deferred Applicability_unresolved
      | Ok (Include use) -> Selected {candidate; use; source_detail}

let rec assess_batch ~instructions ~scope_prompt ~evaluate ~purpose rows =
  match rows, choices with
  | [], _ -> []
  | _, Error detail -> List.map (fun _ -> Error (Invalid_answer detail)) rows
  | _, Ok _ when List.length (List.sort_uniq String.compare
      (List.map (fun (candidate,_) -> candidate.id) rows)) <> List.length rows ->
    List.map (fun _ -> Error (Invalid_answer "duplicate candidate IDs in selection batch")) rows
  | _, Ok choices ->
    let questions = List.fold_right (fun (candidate,_) prepared ->
      let open Result.Syntax in
      let* prepared = prepared in
      let id = candidate.id in
      let+ scope = Prompt_registry.render_resolved_prompt_template
        Prompt_names.keeper_memory_selection_candidate scope_prompt ["question_id", id]
        |> Result.map_error instruction_error in
      (id, Types.choice_of_set choices
        ~instructions:(instructions ^ " " ^ String.trim scope)) :: prepared) rows (Ok []) in
    match questions with
    | Error reason -> List.map (fun _ -> Error reason) rows
    | Ok questions ->
    let state = `Assoc
      ["current_purpose",purpose;
       "candidates",`List (List.map (fun (candidate,source_detail) -> `Assoc
         ["question_id",`String candidate.id;
          "candidate",`Assoc ["id",`String candidate.id;"summary",`String candidate.summary];
          "source_detail",(match source_detail with None -> `Null | Some detail -> detail)]) rows)] in
    match evaluate ~state ~questions with
    | Error (Unavailable detail) -> List.map (fun _ -> Error (Evaluation_failed detail)) rows
    | Error (Capacity_refused detail) ->
      (match rows with
       | [] | [_] -> List.map (fun _ -> Error (Capacity_unresolved detail)) rows
       | _ :: _ :: _ ->
         let half = List.length rows / 2 in
         let left = assess_batch ~instructions ~scope_prompt ~evaluate ~purpose (List.take half rows) in
         let right = assess_batch ~instructions ~scope_prompt ~evaluate ~purpose (List.drop half rows) in
         left @ right)
    | Ok response ->
      let answer_ids = List.map fst response.Types.answers in
      if List.length (List.sort_uniq String.compare answer_ids) <> List.length answer_ids
         || List.exists (fun id -> not (List.mem_assoc id questions)) answer_ids then
        List.map (fun _ -> Error (Invalid_answer "batch response has duplicate or unknown answer IDs")) rows
      else List.map (fun (id,_) ->
        match List.assoc_opt id response.answers with
        | None -> Error (Invalid_answer ("missing batch answer: " ^ id))
        | Some answer -> Types.decode_choice choices answer
          |> Result.map (fun (judgment : decision Types.decoded_choice) -> judgment.choice)
          |> Result.map_error (fun detail -> Invalid_answer detail)) questions

let select_many ~evaluate ~resolve ~purpose candidates =
  if candidates = [] then [] else
  match load_batch_instructions () with
  | Error reason -> List.map (fun candidate -> Deferred {candidate; reason}) candidates
  | Ok (instructions, scope_prompt) ->
  let initial = assess_batch ~instructions ~scope_prompt ~evaluate ~purpose
      (List.map (fun candidate -> candidate,None) candidates) in
  let staged = List.map2 (fun candidate decision ->
    let defer reason = Deferred {candidate;reason} in
    match decision with
    | Error reason -> Either.Left (defer reason)
    | Ok Omit -> Either.Left (Not_needed candidate)
    | Ok (Include _ | Inspect_source) ->
      match resolve ~id:candidate.id with
      | Error detail -> Either.Left (defer (Source_unavailable detail))
      | Ok detail -> Either.Right (candidate,detail)) candidates initial in
  let sources = List.filter_map (function Either.Left _ -> None | Right row -> Some row) staged in
  let answers = assess_batch ~instructions ~scope_prompt ~evaluate ~purpose
      (List.map (fun (candidate,detail) -> candidate,Some detail) sources) in
  let rec finish staged answers = match staged,answers with
    | [], [] -> []
    | Either.Left outcome :: rest, _ -> outcome :: finish rest answers
    | Either.Right (candidate,source_detail) :: rest, answer :: tail ->
      let outcome = match answer with
        | Error reason -> Deferred {candidate;reason}
        | Ok Omit -> Not_needed candidate
        | Ok Inspect_source -> Deferred {candidate;reason=Applicability_unresolved}
        | Ok (Include use) -> Selected {candidate;use;source_detail} in
      outcome :: finish rest tail
    | [], _ :: _ | Either.Right _ :: _, [] ->
      (* assess_batch returns one result per submitted row. *)
      invalid_arg "memory selection batch result cardinality" in
  finish staged answers

let select_resolved_many ~evaluate ~purpose rows =
  if rows = [] then [] else
  match load_batch_instructions () with
  | Error reason -> List.map (fun (candidate,_) -> Deferred {candidate; reason}) rows
  | Ok (instructions, scope_prompt) ->
  let answers = assess_batch ~instructions ~scope_prompt ~evaluate ~purpose
      (List.map (fun (candidate,detail) -> candidate,Some detail) rows) in
  List.map2 (fun (candidate,source_detail) answer ->
    match answer with
    | Error reason -> Deferred {candidate;reason}
    | Ok Omit -> Not_needed candidate
    | Ok Inspect_source -> Deferred {candidate;reason=Applicability_unresolved}
    | Ok (Include use) -> Selected {candidate;use;source_detail}) rows answers
