module AR = Task.Anti_rationalization
open Result.Syntax

type original = { prompt : string; system_prompt : string; lookup_binding : string }
type receipt = {
  original : original;
  result : AR.review_result;
  tools : Verification_run_registry.tool_observation list;
}
type phase =
  | Pending of string option
  | Dispatching of original
  | Judged of receipt
  | Reviewed of receipt
  | Deferred of receipt
  | Execution_unknown of { original : original; detail : string;
      tools : Verification_run_registry.tool_observation list }
  | Superseded of receipt
type record = {
  goal_id : string; request_id : string; criterion : Goal_store.criterion;
  requested_by : string; requested_at : string; supersedes : string option;
  phase : phase;
}
type error = Store_unavailable of string | Goal_unavailable of Goal_store.write_error
  | Conflict of string
let error_to_string = function
  | Store_unavailable detail | Conflict detail -> detail
  | Goal_unavailable error -> Goal_store.write_error_to_string error
let authority = Masc_domain.System_llm_agent {agent_run_id="verifier_exact"}
let authority_json = `Assoc ["kind", `String (Masc_domain.completion_authority_kind authority);
  "actor", `String (Masc_domain.completion_authority_actor authority)]
let path config = Filename.concat (Workspace_utils.masc_dir config) "goal_criterion_reviews.json"

let fields allowed = function
  | `Assoc fields ->
    let* () = Json_util.reject_unknown_fields ~surface:"Goal criterion review" ~allowed fields in
    Ok fields
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
    Error "Goal criterion review must be an object"
let text key fields = Json_util.require_field_string ~surface:"Goal criterion review" key fields
let field key fields = match List.assoc_opt key fields with
  | Some value -> Ok value | None -> Error ("Goal criterion review is missing " ^ key)
let decode parse value = Result.bind value parse
let decode_list decode values =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | first :: rest -> let* first = decode first in loop (first :: acc) rest in
  loop [] values
let list decode = function
  | `List values -> decode_list decode values
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ ->
    Error "Goal criterion review expects a list"
let original_to_json (original : original) = `Assoc [
  "prompt", `String original.prompt; "system_prompt", `String original.system_prompt;
  "lookup_binding", `String original.lookup_binding]
let original_of_json json =
  let* fields = fields ["prompt"; "system_prompt"; "lookup_binding"] json in
  let* prompt = text "prompt" fields in
  let* system_prompt = text "system_prompt" fields in
  let* lookup_binding = text "lookup_binding" fields in
  if String.trim prompt = "" || String.trim system_prompt = ""
    || not (String_util.is_lowercase_sha256_hex lookup_binding)
  then Error "Goal criterion review original is incomplete"
  else Ok {prompt; system_prompt; lookup_binding}
let tools_to_json tools = `List (List.map Verification_run_registry.tool_observation_to_yojson tools)
let receipt_to_json (receipt : receipt) = `Assoc [
  "original", original_to_json receipt.original;
  "authority", authority_json;
  "result", Verifier_review_owner.result_to_json receipt.result;
  "tools", tools_to_json receipt.tools]
let receipt_of_json json =
  let* fields = fields ["original"; "authority"; "result"; "tools"] json in
  let* encoded_authority = field "authority" fields in
  let* () = if Yojson.Safe.equal encoded_authority authority_json then Ok ()
    else Error "Criterion judgment does not name the application verifier authority" in
  let* original = field "original" fields |> decode original_of_json in
  let* result = field "result" fields |> decode Verifier_review_owner.result_of_json in
  let* tools = field "tools" fields |> decode (list Verification_run_registry.tool_observation_of_yojson) in
  Ok {original; result; tools}
let has_reason (result : AR.review_result) = match result.verdict with
  | Some (AR.Approve reason | AR.Reject reason) -> String.trim reason <> ""
  | None -> false
let phase_to_json = function
  | Pending detail -> `Assoc ["state", `String "pending";
      "detail", (match detail with None -> `Null | Some detail -> `String detail)]
  | Dispatching original -> `Assoc ["state", `String "dispatching"; "original", original_to_json original]
  | Judged receipt -> `Assoc ["state", `String "judged"; "receipt", receipt_to_json receipt]
  | Reviewed receipt -> `Assoc ["state", `String "reviewed"; "receipt", receipt_to_json receipt]
  | Deferred receipt -> `Assoc ["state", `String "deferred"; "receipt", receipt_to_json receipt]
  | Superseded receipt -> `Assoc ["state", `String "superseded"; "receipt", receipt_to_json receipt]
  | Execution_unknown {original; detail; tools} -> `Assoc ["state", `String "execution_unknown";
      "original", original_to_json original; "detail", `String detail; "tools", tools_to_json tools]
let phase_of_json json =
  let* all = match json with `Assoc all -> Ok all
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> Error "Invalid review phase" in
  let* state = text "state" all in
  match state with
  | "pending" ->
    let* fields = fields ["state"; "detail"] json in
    (match List.assoc_opt "detail" fields with
     | Some `Null -> Ok (Pending None)
     | Some (`String detail) -> Ok (Pending (Some detail))
     | None | Some _ -> Error "Invalid preparation observation")
  | "dispatching" ->
    let* fields = fields ["state"; "original"] json in
    let* original = field "original" fields |> decode original_of_json in Ok (Dispatching original)
  | "execution_unknown" ->
    let* fields = fields ["state"; "original"; "detail"; "tools"] json in
    let* original = field "original" fields |> decode original_of_json in
    let* detail = text "detail" fields in
    let* tools = field "tools" fields |> decode (list Verification_run_registry.tool_observation_of_yojson) in
    Ok (Execution_unknown {original; detail; tools})
  | "judged" | "reviewed" | "deferred" | "superseded" ->
    let* fields = fields ["state"; "receipt"] json in
    let* receipt = field "receipt" fields |> decode receipt_of_json in
    (match state with
     | "judged" -> Ok (Judged receipt)
     | "reviewed" when has_reason receipt.result -> Ok (Reviewed receipt)
     | "deferred" when not (has_reason receipt.result) -> Ok (Deferred receipt)
     | "superseded" -> Ok (Superseded receipt)
     | _ -> Error "Review phase disagrees with its structured verdict")
  | _ -> Error "Unknown Goal criterion review phase"
let record_to_json (record : record) = `Assoc [
  "goal_id", `String record.goal_id; "request_id", `String record.request_id;
  "criterion", Goal_store.criterion_to_yojson record.criterion;
  "requested_by", `String record.requested_by; "requested_at", `String record.requested_at;
  "supersedes", (match record.supersedes with None -> `Null | Some id -> `String id);
  "phase", phase_to_json record.phase]
let record_of_json json =
  let* fields = fields ["goal_id"; "request_id"; "criterion"; "requested_by";
    "requested_at"; "supersedes"; "phase"] json in
  let* goal_id = text "goal_id" fields in
  let* () = Goal_store.validate_goal_id goal_id |> Result.map_error Goal_store.goal_id_error_to_string in
  let* request_id = text "request_id" fields in
  let* criterion = field "criterion" fields |> decode Goal_store.criterion_of_yojson in
  let* requested_by = text "requested_by" fields in
  let* requested_at = text "requested_at" fields in
  let* supersedes = match List.assoc_opt "supersedes" fields with
    | Some `Null -> Ok None | Some (`String id) when String.trim id <> "" -> Ok (Some id)
    | None | Some _ -> Error "Invalid criterion review predecessor" in
  let* phase = field "phase" fields |> decode phase_of_json in
  if String.trim request_id = "" || String.trim requested_by = "" || String.trim requested_at = ""
  then Error "Criterion review identity is blank"
  else Ok {goal_id; request_id; criterion; requested_by; requested_at; supersedes; phase}
module Ids = Set.Make (String)
module Criteria = Map.Make (struct type t = string * string let compare = Stdlib.compare end)
let records_of_json json =
  let* fields = fields ["version"; "records"] json in
  let* () = match List.assoc_opt "version" fields with
    | Some (`Int 1) -> Ok () | None | Some _ -> Error "Unknown criterion review ledger version" in
  let* records = field "records" fields |> decode (list record_of_json) in
  let* _ = List.fold_left (fun state (record : record) ->
    let* ids, heads = state in
    if Ids.mem record.request_id ids then Error "Duplicate criterion review request" else
    let Goal_store.Criterion {revision; _} = record.criterion in
    let key = record.goal_id, revision in
    let* () = match record.supersedes, Criteria.find_opt key heads with
      | None, None -> Ok ()
      | Some parent, Some previous when String.equal parent previous.request_id
          && Goal_store.criterion_equal record.criterion previous.criterion ->
        (match previous.phase with
         | Deferred _ -> Ok ()
         | Pending _ | Dispatching _ | Judged _ | Reviewed _ | Execution_unknown _ | Superseded _ ->
           Error "Criterion retry replaces an unsettled or judged original")
      | None, Some _ | Some _, None | Some _, Some _ ->
        Error "Criterion review retry lineage does not match its exact settled predecessor" in
    Ok (Ids.add record.request_id ids, Criteria.add key record heads))
    (Ok (Ids.empty, Criteria.empty)) records in
  Ok records
let entry_kind file = Eio_guard.run_in_systhread ~label:"goal-criterion-presence" (fun () ->
  try Ok (Some (Unix.lstat file).Unix.st_kind) with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
  | Unix.Unix_error (error, _, _) -> Error (Store_unavailable (Unix.error_message error)))
let load config =
  let unavailable detail = Error (Store_unavailable detail) in
  let* backend_root = match config.Workspace_utils.backend with
    | Workspace_utils.Memory _ -> unavailable "Criterion reviews require filesystem durability"
    | FileSystem backend -> Backend.FileSystem.physical_root backend
      |> Result.map_error (fun error -> Store_unavailable (Backend_types.show_error error)) in
  let* () = Eio_guard.run_in_systhread ~label:"goal-criterion-root" (fun () ->
    try
      if String.equal backend_root (Unix.realpath (Workspace_utils.masc_dir config)) then Ok ()
      else unavailable "Criterion review backend and workspace roots differ"
    with Unix.Unix_error (error, _, _) -> unavailable (Unix.error_message error)) in
  let* primary = entry_kind (path config) in
  match primary with
  | None ->
    let* mirror = entry_kind (path config ^ ".last-good") in
    (match mirror with None -> Ok []
     | Some _ -> unavailable "Criterion review primary is missing while its recovery mirror exists")
  | Some Unix.S_REG ->
    let* json = Workspace_utils.read_json_local_result (path config)
      |> Result.map_error (fun detail -> Store_unavailable detail) in
    records_of_json json |> Result.map_error (fun detail -> Store_unavailable detail)
  | Some (Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK) ->
    unavailable "Criterion review primary is not a regular file"
let transaction config change =
  match Workspace_utils.with_file_lock_r config (path config) (fun () ->
    let* records = load config in
    let* next, value = change records in
    let* () = if next = records then Ok () else
      let json = `Assoc ["version", `Int 1; "records", `List (List.map record_to_json next)] in
      let* () = Workspace_utils.write_json_local (path config) json
        |> Result.map_error (fun detail -> Store_unavailable detail) in
      Goal_store.projection_source_changed config;
      let mirror = path config ^ ".last-good" in
      let mirror_write =
        let* kind = entry_kind mirror in
        match kind with
        | None | Some Unix.S_REG -> Workspace_utils.write_json_local mirror json
            |> Result.map_error (fun detail -> Store_unavailable detail)
        | Some (Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK) ->
          Error (Store_unavailable "Criterion review mirror is not a regular file") in
      (match mirror_write with
       | Ok () -> ()
       | Error error -> Log.Misc.warn "Criterion review primary committed; mirror failed: %s" (error_to_string error));
      Ok () in
    Ok value) with
  | Ok result -> result
  | Error error -> Error (Store_unavailable (Masc_domain.masc_error_to_string error))
let with_goal config ~goal_id work =
  match Goal_store.transact_goal config ~goal_id (fun goal -> Ok (goal, work goal)) with
  | Ok (_, result) -> result
  | Error error -> Error (Goal_unavailable error)
let recover_interrupted config =
  transaction config (fun records ->
    let records = List.map (fun (record : record) -> match record.phase with
      | Dispatching original -> {record with phase=Execution_unknown {original;
          detail="Application restarted without a retained criterion reviewer reply; original execution is unknown";
          tools=[]}}
      | Pending _ | Judged _ | Reviewed _ | Deferred _ | Execution_unknown _ | Superseded _ -> record) records in
    Ok (records, ()))
let current_for_goal records (goal : Goal_store.goal) =
  let criterion = Goal_store.criterion_of_goal goal in
  List.fold_left (fun found (record : record) ->
    if String.equal record.goal_id goal.id && Goal_store.criterion_equal record.criterion criterion
    then Some record else found) None records
let current_lookup records =
  let indexed = List.fold_left (fun indexed (record : record) ->
    let Goal_store.Criterion {revision; _} = record.criterion in
    Criteria.add (record.goal_id, revision) record indexed) Criteria.empty records in
  fun (goal : Goal_store.goal) ->
    match Criteria.find_opt (goal.id, goal.criterion_revision) indexed with
    | Some record when Goal_store.criterion_equal record.criterion (Goal_store.criterion_of_goal goal) -> Some record
    | None | Some _ -> None
let request ?expected_criterion ?expected_request_id config ~goal_id ~actor ~retry =
  if String.trim actor = "" then Error (Conflict "Criterion review actor is required") else
  with_goal config ~goal_id (fun goal ->
    match expected_criterion with
    | Some expected when not (Goal_store.criterion_equal expected (Goal_store.criterion_of_goal goal)) ->
      Error (Conflict "Criterion changed before its review request committed")
    | None | Some _ -> transaction config (fun records ->
    let previous = current_for_goal records goal in
    let* () = match expected_request_id, previous with
      | None, _ -> Ok ()
      | Some expected, Some record when String.equal expected record.request_id -> Ok ()
      | Some _, (None | Some _) -> Error (Conflict "Criterion review request changed before retry") in
    let create = match previous with
      | None -> true
      | Some {phase=Deferred _; _} -> retry
      | Some {phase=(Pending _ | Dispatching _ | Judged _ | Reviewed _ | Execution_unknown _ | Superseded _); _} -> false in
    if not create then match previous with
      | Some record -> Ok (records, record)
      | None -> Error (Conflict "Criterion review request disappeared")
    else
      let record = {goal_id; request_id=Random_id.hex ~bytes:16;
        criterion=Goal_store.criterion_of_goal goal; requested_by=actor;
        requested_at=Masc_domain.now_iso (); supersedes=Option.map (fun record -> record.request_id) previous;
        phase=Pending None} in
      Ok (records @ [record], record)))
let update config (expected : record) change = transaction config (fun records ->
  match List.find_opt (fun (record : record) -> record.request_id = expected.request_id) records with
  | None -> Error (Conflict "Criterion review request is missing")
  | Some current when current.goal_id <> expected.goal_id
      || not (Goal_store.criterion_equal current.criterion expected.criterion) ->
    Error (Conflict "Criterion review identity changed")
  | Some current ->
    let* phase = change current.phase in
    let updated = {current with phase} in
    Ok (List.map (fun (record : record) -> if record.request_id = current.request_id then updated else record) records, updated))
let begin_dispatch config record original =
  let* _ = original_of_json (original_to_json original) |> Result.map_error (fun detail -> Conflict detail) in
  with_goal config ~goal_id:record.goal_id (fun goal ->
  if not (Goal_store.criterion_equal record.criterion (Goal_store.criterion_of_goal goal))
  then Error (Conflict "Criterion changed before reviewer dispatch") else
  match goal.phase with
  | Goal_phase.Executing | Verifying -> update config record (function
      | Pending _ -> Ok (Dispatching original)
      | Dispatching _ | Judged _ | Reviewed _ | Deferred _ | Execution_unknown _ | Superseded _ ->
        Error (Conflict "Criterion review already has an execution frontier"))
  | Awaiting_confirmation | Completed | Dropped | Paused _ | Blocked _ ->
    Error (Conflict "Goal does not admit a new criterion review"))
let retain_reply config record receipt = update config record (function
  | Dispatching original when original = receipt.original -> Ok (Judged receipt)
  | (Judged saved | Reviewed saved | Deferred saved | Superseded saved) as phase when saved = receipt -> Ok phase
  | Pending _ | Dispatching _ | Judged _ | Reviewed _ | Deferred _ | Execution_unknown _ | Superseded _ ->
    Error (Conflict "Reply does not match its retained criterion review original"))
let publish config record = with_goal config ~goal_id:record.goal_id (fun goal ->
  update config record (function
    | Judged receipt ->
      if not (Goal_store.criterion_equal record.criterion (Goal_store.criterion_of_goal goal))
      then Ok (Superseded receipt)
      else if has_reason receipt.result then Ok (Reviewed receipt) else Ok (Deferred receipt)
    | Reviewed receipt -> Ok (Reviewed receipt)
    | Deferred receipt -> Ok (Deferred receipt)
    | Superseded receipt -> Ok (Superseded receipt)
    | Pending _ | Dispatching _ | Execution_unknown _ -> Error (Conflict "No retained criterion judgment to publish")))
let retain_unknown config record original ~detail ~tools =
  update config record (function
    | Dispatching saved when saved = original -> Ok (Execution_unknown {original; detail; tools})
    | Judged receipt -> Ok (Judged receipt)
    | Reviewed receipt -> Ok (Reviewed receipt)
    | Deferred receipt -> Ok (Deferred receipt)
    | Superseded receipt -> Ok (Superseded receipt)
    | Execution_unknown saved -> Ok (Execution_unknown saved)
    | Pending _ | Dispatching _ -> Error (Conflict "Unknown execution does not match its retained original"))
  |> Result.map (fun _ -> ())
let defer_preparation config record ~detail = update config record (function
  | Pending _ -> Ok (Pending (Some detail))
  | Dispatching _ | Judged _ | Reviewed _ | Deferred _ | Execution_unknown _ | Superseded _ ->
    Error (Conflict "Preparation observation cannot replace an execution"))
  |> Result.map (fun _ -> ())
(* A goal's review as the verdict a reader acts on, and the reviewer's evidence
   (its structured result and the tool calls it made) behind a thunk, so a
   projection that leaves the evidence out never builds it. *)
let project_fields current records goal = match records with
  | Error error -> ["state", `String "unavailable"; "detail", `String (error_to_string error)], (fun () -> [])
  | Ok _ -> match current goal with
    | None -> ["state", `String "unchecked"], (fun () -> [])
    | Some record ->
      let state, detail, receipt = match record.phase with
        | Pending detail -> "pending", detail, None
        | Dispatching _ -> "execution_pending", None, None
        | Execution_unknown {detail; _} -> "execution_unknown", Some detail, None
        | Judged receipt -> "judgment_pending", None, Some receipt
        | Deferred receipt -> "deferred", receipt.result.fallback_reason, Some receipt
        | Superseded receipt -> "superseded", None, Some receipt
        | Reviewed receipt -> (match receipt.result.verdict with
            | Some (AR.Approve reason) -> "viable", Some reason, Some receipt
            | Some (AR.Reject reason) -> "needs_revision", Some reason, Some receipt
            | None -> "deferred", receipt.result.fallback_reason, Some receipt) in
      let Goal_store.Criterion {revision; _} = record.criterion in
      ["state", `String state; "request_id", `String record.request_id;
        "criterion_revision", `String revision;
        "reason", (match record.phase with
          | Reviewed receipt -> (match receipt.result.verdict with
              | Some (AR.Approve reason | AR.Reject reason) -> `String reason
              | None -> `Null)
          | Pending _ | Dispatching _ | Judged _ | Deferred _ | Execution_unknown _ | Superseded _ -> `Null);
        "detail", (match detail with None -> `Null | Some detail -> `String detail)]
        @ (match receipt with None -> [] | Some _ -> ["authority", authority_json]),
      (fun () ->
        (match receipt with None -> [] | Some receipt -> [
          "review", Verifier_review_owner.result_to_json receipt.result;
          "tools", tools_to_json receipt.tools])
        @ (match record.phase with
          | Execution_unknown {tools; _} -> ["tools", tools_to_json tools]
          | Pending _ | Dispatching _ | Judged _ | Reviewed _ | Deferred _ | Superseded _ -> []))
let current_of records = match records with Ok rows -> current_lookup rows | Error _ -> (fun _ -> None)
let projector records =
  let current = current_of records in
  fun goal -> let verdict, evidence = project_fields current records goal in `Assoc (verdict @ evidence ())
let summary_projector records =
  let current = current_of records in
  fun goal -> `Assoc (fst (project_fields current records goal))
let projection records goal = projector records goal
