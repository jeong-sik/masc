module R = Librarian_continuity_report
module S = Librarian_continuity_snapshot
module B = Keeper_turn_boundaries

type case =
  { id : string; trace_id : string; absolute_turn : int
  ; prefix : Agent_core.Types.message list; suffix : Agent_core.Types.message list
  ; facts : R.fact list; question : string }
type dataset = { provenance : R.provenance; cases : case list }
type work = Work_not_started | Work_failed of R.failed_generation | Work_ready of R.generation
type snapshot = Snapshot_not_started | Snapshot_failed of string | Snapshot_ready of S.t
type progress =
  { work : work; snapshot : snapshot; baseline : R.progress; restored : R.progress }

let ( let* ) = Result.bind
let initial_progress =
  { work = Work_not_started; snapshot = Snapshot_not_started
  ; baseline = R.Not_started; restored = R.Not_started }
let messages_json messages = `List (List.map Agent_core.Checkpoint.message_to_json messages)
let case_to_yojson (case : case) =
  `Assoc ["id", `String case.id; "trace_id", `String case.trace_id;
    "absolute_turn", `Int case.absolute_turn; "prefix", messages_json case.prefix;
    "suffix", messages_json case.suffix; "facts", `List (List.map R.fact_to_yojson case.facts);
    "question", `String case.question]
let progress_to_yojson progress =
  let work = match progress.work with
    | Work_not_started -> `Assoc ["status", `String "not_started"]
    | Work_failed failure -> `Assoc ["status", `String "failed"; "failure", R.failed_generation_to_yojson failure]
    | Work_ready value -> `Assoc ["status", `String "ready"; "generation", R.generation_to_yojson value] in
  let snapshot = match progress.snapshot with
    | Snapshot_not_started -> `Assoc ["status", `String "not_started"]
    | Snapshot_failed error -> `Assoc ["status", `String "failed"; "error", `String error]
    | Snapshot_ready value -> `Assoc ["status", `String "ready"; "artifact", S.to_json value] in
  `Assoc ["work", work; "snapshot", snapshot;
    "boundary_provenance", `String "synthetic_fresh_history";
    "baseline", R.progress_to_yojson progress.baseline; "restored", R.progress_to_yojson progress.restored]

let exact_fields keys = function
  | `Assoc fields when List.sort String.compare (List.map fst fields) = List.sort String.compare keys -> Ok fields
  | _ -> Error "unexpected, duplicate, missing fields or non-object"
let string fields key = match List.assoc key fields with
  | `String value when String.trim value <> "" -> Ok value
  | _ -> Error ("expected nonblank " ^ key)
let rec parse_list parse = function
  | [] -> Ok []
  | item :: rest -> let* item = parse item in let* rest = parse_list parse rest in Ok (item :: rest)
let array parse = function
  | `List values -> parse_list parse values
  | _ -> Error "expected array"
let parse_message json =
  Agent_core.Checkpoint.message_of_json json |> Result.map_error Agent_core.Error.to_string
let parse_case json =
  let* fields = exact_fields ["id"; "trace_id"; "absolute_turn"; "prefix"; "suffix"; "facts"; "question"] json in
  let* id = string fields "id" in
  let* trace_id = string fields "trace_id" in
  let* question = string fields "question" in
  let* absolute_turn = match List.assoc "absolute_turn" fields with
    | `Int value when value > 0 -> Ok value | _ -> Error "absolute_turn must be positive" in
  let* prefix = array parse_message (List.assoc "prefix" fields) in
  let* suffix = array parse_message (List.assoc "suffix" fields) in
  let* facts = array R.fact_of_yojson (List.assoc "facts" fields) in
  let* () = if prefix = [] then Error "prefix must be nonempty" else Ok () in
  let ids = List.map (fun (fact : R.fact) -> fact.id) facts in
  let* () = if List.exists (fun (fact : R.fact) -> String.trim fact.id = "" || String.trim fact.claim = "") facts
    || List.length ids <> List.length (List.sort_uniq String.compare ids)
    then Error "fact identities and claims must be nonblank and unique" else Ok () in
  Ok {id; trace_id; absolute_turn; prefix; suffix; facts; question}
let parse_dataset json =
  let* fields = exact_fields ["provenance"; "cases"] json in
  let* provenance = R.provenance_of_yojson (List.assoc "provenance" fields) in
  let* cases = array parse_case (List.assoc "cases" fields) in
  let ids = List.map (fun (case : case) -> case.id) cases in
  if cases = [] || List.length ids <> List.length (List.sort_uniq String.compare ids)
  then Error "cases must be nonempty with unique identities"
  else Ok {provenance; cases}

let working_prompt (case : case) : R.prompt =
  { system = "Organize the provided conversation into working state for a later turn. Preserve current tasks, constraints, decisions, evidence, and unresolved questions. Do not invent facts. Return only the working state."
  ; user = Yojson.Safe.to_string (`Assoc ["prefix", messages_json case.prefix]) }
let answer_prompt ~question ~facts ~working_state messages : R.prompt =
  { system = "Answer the question using only the provided context. If context does not establish an answer, state what is missing."
  ; user = Yojson.Safe.to_string (`Assoc ["working_state", (match working_state with None -> `Null | Some value -> `String value);
      "messages", messages_json messages; "facts", `List (List.map R.fact_to_yojson facts);
      "question", `String question]) }

let evaluate_case ~generate ~judge ~judge_endpoint ~judge_model ~snapshot_path ~save (case : case) =
  let persist progress = let* () = save progress in Ok progress in
  let* progress = match generate (working_prompt case) with
    | Error failure -> persist {initial_progress with work = Work_failed failure}
    | Ok generation -> persist {initial_progress with work = Work_ready generation} in
  let restored_input = match progress.work with
    | Work_not_started | Work_failed _ -> None
    | Work_ready generation ->
      Some (let* position = B.position_of_messages case.prefix in
        let lines = [1, Ok { B.recorded_at = 0.; event = B.Turn_ended
          { turn_ref = Ids.Turn_ref.make ~trace_id:case.trace_id ~absolute_turn:case.absolute_turn;
            history_at_start = B.Fresh_history; position } }] in
        let* snapshot = S.capture ~trace_id:case.trace_id ~lines ~messages:case.prefix
          ~working_state:generation.response.text |> Result.map_error S.error_to_string in
        let* () = S.save ~path:snapshot_path snapshot |> Result.map_error S.error_to_string in
        let* loaded = S.load ~path:snapshot_path |> Result.map_error S.error_to_string in
        let* restored = S.restore ~trace_id:case.trace_id ~lines
          ~messages:(case.prefix @ case.suffix) loaded |> Result.map_error S.error_to_string in
        Ok (loaded, restored)) in
  let* progress = match restored_input with
    | None -> Ok progress
    | Some (Error detail) -> persist {progress with snapshot = Snapshot_failed detail}
    | Some (Ok (snapshot, _)) -> persist {progress with snapshot = Snapshot_ready snapshot} in
  let reference = Yojson.Safe.to_string (`Assoc
    ["prefix", messages_json case.prefix; "suffix", messages_json case.suffix;
     "facts", `List (List.map R.fact_to_yojson case.facts)]) in
  let run_arm progress update prompt =
    let question = R.Provided case.question in
    match generate prompt with
    | Error failure -> persist (update progress (R.Answer_failed (question, failure)))
    | Ok answer ->
      let* progress = persist (update progress (R.Answer_ready {question; answer})) in
      let request = R.judge_request_for ~endpoint:judge_endpoint ~model:judge_model
        ~question_id:case.id ~reference ~question:case.question ~answer:answer.response.text in
      let outcome = match judge request with
        | Ok judgment -> R.Scored {question; answer; judgment}
        | Error error -> R.Judge_failed {question; answer; failure = {request; error}} in
      persist (update progress outcome) in
  let* progress = run_arm progress (fun p baseline -> {p with baseline})
    (answer_prompt ~question:case.question ~facts:case.facts ~working_state:None (case.prefix @ case.suffix)) in
  match restored_input with
  | None | Some (Error _) -> Ok progress
  | Some (Ok (_, restored)) ->
    run_arm progress (fun p restored -> {p with restored})
      (answer_prompt ~question:case.question ~facts:case.facts ~working_state:(Some restored.working_state) restored.messages)
