module Capture = Keeper_librarian_admission_capture
module Owner = Lane_addon_tool_request_owner
module Progress = Lane_addon_request_progress
module Exact = Lane_addon_exact
module Gate = Keeper_librarian_absorb_gate
module Queue = Keeper_memory_admission_queue
let ( let* ) = Result.bind

let canonical = Lane_addon_action.canonical
let same left right =
  let* left = canonical left in
  let* right = canonical right in
  Ok (Yojson.Safe.equal left right)
let require condition detail = if condition then Ok () else Error detail
let equal left right detail = let* matches = same left right in require matches detail
let digest json = let* json = canonical json in
  Ok Digestif.SHA256.(digest_string (Yojson.Safe.to_string json) |> to_hex)
let rec ordered = function
  | `Assoc fields -> `Assoc (List.sort (fun (left,_) (right,_) -> String.compare left right)
      (List.map (fun (key,value) -> key,ordered value) fields))
  | `List values -> `List (List.map ordered values)
  | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _) as value -> value
let scope owner =
  (* [owner_to_json] is constructed by the host's opaque physical owner. *)
  "keeper-librarian-admission-gate/" ^
  Digestif.SHA256.(digest_string (Yojson.Safe.to_string (ordered (Capture.owner_to_json owner))) |> to_hex)
let fields expected = function
  | `Assoc fields when List.sort String.compare (List.map fst fields) = List.sort String.compare expected -> Ok fields
  | _ -> Error "Original gate record has unknown, duplicate or missing fields"
let value name fields = List.assoc name fields
let text = function
  | `String text when String.trim text <> "" -> Ok text
  | _ -> Error "Original gate identity must be nonblank"
let optional_text = function `Null -> Ok None | json -> let* text = text json in Ok (Some text)
let owned value = Result.map_error Owner.error_to_string value
let parent_execution_id (record : Owner.retained) =
  let* members = fields ["version";"kind";"request_id";"owner";"execution_id";"execution_digest";
    "capture";"proposal";"authority";"predecessor"] record.request in
  let* () = require (value "version" members=`Int 1 && value "kind" members=`String "librarian-admission-gate"
    && value "request_id" members=`String record.request_id) "Invalid gate original header" in
  text (value "execution_id" members)

type inputs = {
  observations : Yojson.Safe.t list;
  facts : Keeper_memory_os_types.fact list;
  new_claims : Keeper_memory_os_types.fact list;
  superseding : string list;
  absorbed : Keeper_memory_os_types.absorbed_statement list;
}
let inputs capture proposal =
  let* accepted = Capture.validate_proposal capture proposal in
  match accepted with
  | Keeper_librarian_runtime.Deferred -> Error "Deferred admission cannot start absorption"
  | Accepted accepted ->
    let input = Capture.input capture in
    let selected = accepted.selection in
    let observations = Keeper_librarian.observations_for_absorption input @
      (Queue.candidates (Capture.batch capture)
       |> List.filter (fun (row : Queue.candidate) -> List.mem row.request_id accepted.admission_support)
       |> List.map (fun (row : Queue.candidate) ->
         `Assoc ["observation_kind", `String "pending_explicit_memory_candidate";
           "request_id", `String row.request_id; "sequence", `Int row.sequence;
           "proposal", Keeper_memory_os_types.fact_to_json row.fact])) in
    Ok {observations;facts=(match input.current with None -> [] | Some current -> current.facts);
      new_claims=selected.new_claims;
      superseding=List.map (fun (revision : Keeper_librarian.revision) -> revision.superseded_by) selected.revisions;
      absorbed=selected.absorbed}

let parent_judgment (parent : Owner.retained) = match Progress.phase parent.progress with
  | Progress.Judged judgment -> Ok judgment
  | Committing commit | Commit_unknown (commit, _) | Finished commit | Conflicted (commit, _) -> Ok commit.judgment
  | Captured | Admission_wait _ | Dispatch_pending _ | Rejected _ | Subdividing _ | Subdivided _ ->
    Error "Original gate parent has no answered judgment"
let load_parent ~store ~owner ~capture ~proposal =
  let* parent = owned (Owner.load ~store ~scope:(Capture.scope owner) ~request_id:(Capture.request_id capture)) in
  let* parent = Option.to_result ~none:"Original gate execution parent is absent" parent in
  let* () = equal parent.request (Capture.to_json capture) "Gate parent capture differs" in
  let* judgment = parent_judgment parent in
  let* exact = Capture.request capture in
  let* schema = Option.to_result ~none:"Original admission request has no schema" exact.schema in
  let* final = Exact.final_of_json ~schema judgment in
  let* () = match final with
    | Exact.Call_final (Answered {output;_}) ->
      equal (Exact.checked_json output) proposal "Gate proposal differs from the original answered judgment"
    | Call_final (Invalid_output _ | Input_refused _ | Output_limit_reached _)
    | Outcome_unknown | Not_allowed _ | Request_id_reused -> Error "Gate requires the original answered proposal" in
  Ok parent

type transcript = {evaluations : Gate.retained_evaluation list; aborted : Yojson.Safe.t option}
let empty = {evaluations=[];aborted=None}
let transcript_json transcript =
  `Assoc ["version", `Int 1; "evaluations", `List (List.map (fun (evaluation : Gate.retained_evaluation) ->
    `Assoc ["request", evaluation.request; "returned", Option.value evaluation.returned ~default:`Null]) transcript.evaluations);
    "aborted", Option.value transcript.aborted ~default:`Null]
let transcript_of_json json =
  let* members = fields ["version";"evaluations";"aborted"] json in
  let* () = require (value "version" members = `Int 1) "Unknown gate transcript version" in
  let* evaluations = match value "evaluations" members with
    | `List values -> List.fold_right (fun json tail ->
      let* members = fields ["request";"returned"] json in
      let* tail = tail in
      let returned = match value "returned" members with `Null -> None | json -> Some json in
      Ok ({Gate.request=value "request" members;returned} :: tail)) values (Ok [])
    | _ -> Error "Gate transcript requires original evaluations" in
  let* aborted = match value "aborted" members with
    | `Null -> Ok None
    | json ->
      let* members = fields ["kind";"detail"] json in
      (match value "kind" members, value "detail" members with
       | `String "cancelled", `Null | `String "failed", `String _ -> Ok (Some json)
       | _ -> Error "Invalid gate aborted observation") in
  let* () = equal json (transcript_json {evaluations;aborted}) "Noncanonical gate transcript" in
  let rec complete_prefix = function
    | [] | [{Gate.returned=None;_}] -> true
    | {Gate.returned=Some _;_} :: tail -> complete_prefix tail
    | {Gate.returned=None;_} :: _ :: _ -> false in
  let* () = require (complete_prefix evaluations) "Gate has a pending request before a later evaluation" in
  let* () = require (match aborted, List.rev evaluations with
    | None, _ -> true | Some _, {Gate.returned=None;_} :: _ -> true
    | Some _, ([] | {Gate.returned=Some _;_} :: _) -> false) "Gate abort has no pending original request" in
  Ok {evaluations;aborted}

let restore_result authority input evaluations =
  Gate.restore ~authority ~new_observations:input.observations ~facts:input.facts
    ~new_claims:input.new_claims ~superseding:input.superseding ~absorbed:input.absorbed ~evaluations
let valid_prefix authority input transcript =
  match restore_result authority input transcript.evaluations with
  | Ok result -> Ok (Some result)
  | Error (Gate.Missing_evaluation index) when index = List.length transcript.evaluations -> Ok None
  | Error (Gate.Incomplete_evaluation index) when index + 1 = List.length transcript.evaluations -> Ok None
  | Error error -> Error (Gate.replay_error_to_string error)
let transcript_step previous next =
  let* () = require (Option.is_none previous.aborted) "An aborted gate cannot continue" in
  let rec transition left right = match left, right with
    | [], [{Gate.returned=None;_}] -> Ok ()
    | [{Gate.request;returned=None}], [{Gate.request=next;returned=Some _}] ->
      equal request next "Returned gate request differs from its original intent"
    | [{Gate.request;returned=None}], [{Gate.request=next_request;returned=None}] when Option.is_some next.aborted ->
      equal request next_request "Aborted gate request differs from its original intent"
    | ({Gate.returned=Some _;_} as first) :: left, second :: right ->
      let encode (x : Gate.retained_evaluation) = `Assoc ["request",x.request;"returned",Option.value x.returned ~default:`Null] in
      let* () = equal (encode first) (encode second) "Gate completed prefix changed" in
      transition left right
    | ([] | _::_), ([] | _::_) -> Error "Gate transcript did not append or complete exactly one original request" in
  transition previous.evaluations next.evaluations

type restored = {proposal:Yojson.Safe.t;authority:Gate.replay_authority;
  input:inputs;transcript:transcript;complete:Gate.run_result option}
let gate_request ~owner ~capture ~parent ~proposal ~request_id ~authority ~predecessor =
  `Assoc ["version",`Int 1;"kind",`String "librarian-admission-gate";"request_id",`String request_id;
    "owner",Capture.owner_to_json owner;"execution_id",`String (Capture.request_id capture);
    "execution_digest",`String parent.Owner.request_digest;"capture",Capture.to_json capture;
    "proposal",proposal;"authority",Gate.replay_authority_to_yojson authority;
    "predecessor",Option.fold ~none:`Null ~some:(fun id -> `String id) predecessor]
let completed_json transcript result =
  let* sha = digest (transcript_json transcript) in
  Ok (`Assoc ["kind",`String "original-gate-complete";"transcript_sha256",`String sha;
    "result",Gate.run_result_to_yojson result])

let rec restore_record ~store ~owner ~capture ~visited (record : Owner.retained) =
  let* () = require (not (List.mem record.request_id visited)) "Cyclic gate retry ancestry" in
  let* members = fields ["version";"kind";"request_id";"owner";"execution_id";"execution_digest";
    "capture";"proposal";"authority";"predecessor"] record.request in
  let* () = Capture.owner_matches_json owner (value "owner" members) in
  let proposal = value "proposal" members in
  let* input = inputs capture proposal in
  let* parent = load_parent ~store ~owner ~capture ~proposal in
  let* authority = Gate.replay_authority_of_yojson (value "authority" members) in
  let* predecessor = optional_text (value "predecessor" members) in
  let* () = require (record.scope=scope owner && record.installation_id=parent.installation_id
    && record.package_id=parent.package_id && record.tool=parent.tool) "Gate owner destination differs from its execution" in
  let* () = equal record.request
    (gate_request ~owner ~capture ~parent ~proposal ~request_id:record.request_id ~authority ~predecessor)
    "Gate original execution identity differs" in
  let* () = match predecessor with
    | None -> Ok ()
    | Some request_id ->
      let* prior = owned (Owner.load ~store ~scope:(scope owner) ~request_id) in
      let* prior = Option.to_result ~none:"Original predecessor gate is absent" prior in
      let* prior = restore_record ~store ~owner ~capture ~visited:(record.request_id::visited) prior in
      let* () = equal prior.proposal proposal "Gate retry changed the original proposal" in
      (match prior.complete with
       | Some result when Option.is_some (Gate.failure_detail ~absorbed:prior.input.absorbed result) -> Ok ()
       | Some _ | None -> Error "Only a completed unsuccessful gate can have a new attempt") in
  let* transcript, terminal = List.fold_left (fun accumulated event ->
    let* transcript, terminal = accumulated in
    match event with
    | Progress.Dispatch_intended -> Ok (transcript, terminal)
    | Execution_observed (Waiting json | Outcome_unknown json) ->
      let* () = require (Option.is_none terminal) "Gate evidence followed its terminal" in
      let* next = transcript_of_json json in
      let* () = transcript_step transcript next in
      let* _ = valid_prefix authority input next in
      Ok (next, None)
    | Judgment_retained json -> Ok (transcript, Some json)
    | Admission_declined _ | Execution_observed (Absent _) | Commit_intended _ | Commit_uncertain _
    | Commit_retry_observed _ | Commit_observed _ | Commit_conflicted _ | Refused _
    | Successor_intended _ | Successor_observed _ | Observer _ -> Error "Unexpected event in original gate journal")
    (Ok (empty,None)) (Progress.events record.progress) in
  let* derived = valid_prefix authority input transcript in
  let* complete = match terminal, derived with
    | None, _ -> Ok None
    | Some json, Some result -> let* expected = completed_json transcript result in
      let* () = equal json expected "Gate terminal differs from original replay" in Ok (Some result)
    | Some _, None -> Error "Gate terminal has incomplete original evaluations" in
  Ok {proposal;authority;input;transcript;complete}

let validate ~store ~owner ~capture ~record =
  let* _ = restore_record ~store ~owner ~capture ~visited:[] record in Ok ()
let restore_size_evidence ~store ~owner ~parent_execution ~gate_request_id =
  let* record = owned (Owner.load ~store ~scope:(scope owner) ~request_id:gate_request_id) in
  let* record = Option.to_result ~none:"Original gate is absent" record in
  let* restored = restore_record ~store ~owner ~capture:parent_execution ~visited:[] record in
  Option.to_result ~none:"Original gate has no completed terminal" restored.complete

let retain ~store ~owner ~capture ~parent ~proposal ~request_id ~authority ~predecessor =
  let* () = require (Gate.keeper_of_authority authority=Capture.keeper_id owner)
    "Original gate live authority belongs to another Keeper" in
  let* current = load_parent ~store ~owner ~capture ~proposal in
  let* () = require (parent.Owner.request_digest=current.request_digest
    && parent.request_id=current.request_id) "Gate parent identity changed before retention" in
  let* _ = inputs capture proposal in
  let request = gate_request ~owner ~capture ~parent:current ~proposal ~request_id
    ~authority:(Gate.replay_authority authority) ~predecessor in
  (* Validate retries and the full immutable join before any publication. *)
  let* () = match predecessor with
    | None -> Ok ()
    | Some id ->
      let* () = require (id<>request_id) "Gate cannot retry itself" in
      let* prior = owned (Owner.load ~store ~scope:(scope owner) ~request_id:id) in
      let* prior = Option.to_result ~none:"Original predecessor gate is absent" prior in
      let* prior = restore_record ~store ~owner ~capture ~visited:[] prior in
      let* () = equal prior.proposal proposal "Gate retry changed the original proposal" in
      (match prior.complete with
       | Some result when Option.is_some (Gate.failure_detail ~absorbed:prior.input.absorbed result) -> Ok ()
       | Some _ | None -> Error "A gate retry requires a completed unsuccessful predecessor") in
  let* () = owned (Owner.retain ~store ~scope:(scope owner) ~request_id
    ~installation_id:current.installation_id ~package_id:current.package_id ~tool:current.tool ~request) in
  let* retained = owned (Owner.load ~store ~scope:(scope owner) ~request_id) in
  let* retained = Option.to_result ~none:"Retained original gate disappeared" retained in
  let* () = validate ~store ~owner ~capture ~record:retained in Ok retained

type result = Pending of Owner.retained | Complete of Gate.run_result * Owner.retained
exception Journal_error of string
let advance ~store record event =
  match Owner.advance ~store ~expected:record ~event with
  | Ok (Owner.Stored record) -> Ok (true,record)
  | Ok (Owner.Already_stored record) -> Ok (false,record)
  | Ok (Owner.Unconfirmed detail) -> Error detail
  | Error error -> Error (Owner.update_error_to_string error)
let resume ~store ~owner ~capture ~record ~live_authority =
  let* restored = Eio_unix.run_in_systhread (fun () ->
    restore_record ~store ~owner ~capture ~visited:[] record) in
  match restored.complete with
  | Some result -> Ok (Complete (result,record))
  | None ->
    let* proceed, record = match Progress.phase record.Owner.progress with
      | Progress.Captured -> Eio_unix.run_in_systhread (fun () -> advance ~store record Progress.Dispatch_intended)
      | Dispatch_pending _ -> Ok (true,record)
      | Admission_wait _ | Judged _ | Committing _ | Commit_unknown _ | Finished _ | Conflicted _
      | Rejected _ | Subdividing _ | Subdivided _ -> Error "Original gate has an invalid execution phase" in
    if not proceed then Ok (Pending record)
    else
      let current = ref record and transcript = ref restored.transcript in
      let publish event =
        match Eio_unix.run_in_systhread (fun () -> advance ~store !current event) with
        | Ok (true,record) -> current:=record
        | Ok (false,_) -> raise (Journal_error "Gate publication was already stored; reload original work")
        | Error detail -> raise (Journal_error detail) in
      let before_evaluate ~direction ~destinations ~state ~questions =
        let request = Gate.evaluation_request_to_yojson ~direction ~destinations ~state ~questions in
        let next = {!transcript with evaluations=(!transcript).evaluations @ [{Gate.request;returned=None}]} in
        Eio.Cancel.protect (fun () -> publish (Progress.Execution_observed (Waiting (transcript_json next))));
        transcript:=next;
        List.length next.evaluations in
      let after_evaluate ~evaluation_id evaluation =
        if evaluation_id<>List.length (!transcript).evaluations then raise (Journal_error "Gate evaluation token changed");
        let next = {!transcript with evaluations=List.mapi (fun index original ->
          if index+1=evaluation_id then {original with Gate.returned=Some (Gate.evaluation_evidence_to_yojson evaluation)}
          else original) (!transcript).evaluations} in
        publish (Progress.Execution_observed (Waiting (transcript_json next)));
        transcript:=next in
      let on_evaluation_aborted ~evaluation_id disposition =
        if evaluation_id<>List.length (!transcript).evaluations then raise (Journal_error "Gate aborted token changed");
        let aborted = match disposition with
          | `Cancelled -> `Assoc ["kind",`String "cancelled";"detail",`Null]
          | `Failed detail -> `Assoc ["kind",`String "failed";"detail",`String detail] in
        let next = {!transcript with aborted=Some aborted} in
        publish (Progress.Execution_observed (Outcome_unknown (transcript_json next)));
        transcript:=next in
      try
        match Gate.continue_captured ~keeper_id:(Capture.keeper_id owner) ~authority:restored.authority
          ~live_authority ~evaluations:restored.transcript.evaluations
          ~before_evaluate ~after_evaluate ~on_evaluation_aborted
          ~new_observations:restored.input.observations ~facts:restored.input.facts
          ~new_claims:restored.input.new_claims ~superseding:restored.input.superseding
          ~absorbed:restored.input.absorbed () with
        | Error (Gate.Missing_evaluation _ | Incomplete_evaluation _) -> Ok (Pending !current)
        | Error error -> Error (Gate.replay_error_to_string error)
        | Ok result ->
          let* confirmed = match restore_result restored.authority restored.input (!transcript).evaluations with
            | Ok result -> Ok result | Error error -> Error (Gate.replay_error_to_string error) in
          let* () = equal (Gate.run_result_to_yojson result) (Gate.run_result_to_yojson confirmed)
            "Executed gate differs from its original transcript replay" in
          let* terminal = completed_json !transcript confirmed in
          Eio.Cancel.protect (fun () -> publish (Progress.Judgment_retained terminal));
          Ok (Complete (confirmed,!current))
      with Journal_error detail -> Error detail
