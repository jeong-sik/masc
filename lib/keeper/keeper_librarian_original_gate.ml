type inputs = Keeper_librarian_runtime.durable_absorption
module type Capture = sig
  type owner
  type t
  val gate_scope : owner -> string
  val gate_kind : string
  (** Host constants/addressing for this purpose; never worker-supplied aliases.
      Stable addressing must not hide old records after a missing/replaced epoch. *)
  val scope : owner -> string
  val keeper_id : owner -> string
  val base_path : owner -> string
  val keepers_dir : owner -> string
  val observe_owner : base_path:string -> keepers_dir:string -> keeper_id:string -> (owner, string) result
  val owner_to_json : owner -> Yojson.Safe.t
  val owner_matches_json : owner -> Yojson.Safe.t -> (unit, string) result
  val request_id : t -> string
  val to_json : t -> Yojson.Safe.t
  val decode_final : store:Lane_addon_store.t -> t -> Yojson.Safe.t -> (Lane_addon_exact.final, string) result
  val confirm_final : store:Lane_addon_store.t -> t -> Lane_addon_exact.final -> (unit, string) result
  val gate_inputs : t -> Yojson.Safe.t -> (inputs, string) result
  (** Revalidate the complete original domain proposal and derive its original
      absorption inputs. No current-source substitution or provider fallback. *)
end


module Make (Capture : Capture) = struct
module Owner = Lane_addon_tool_request_owner
module Progress = Lane_addon_request_progress
module Exact = Lane_addon_exact
module Gate = Keeper_librarian_absorb_gate
open Result.Syntax

let canonical = Lane_addon_action.canonical
let same left right =
  let* left = canonical left in
  let* right = canonical right in
  Ok (Yojson.Safe.equal left right)
let require condition detail = if condition then Ok () else Error detail
let equal left right detail = let* matches = same left right in require matches detail
let digest json = let* json = canonical json in
  Ok Agent_core_sha256.(digest_string (Yojson.Safe.to_string json) |> to_hex)
let scope = Capture.gate_scope
let fields expected = function
  | `Assoc fields when List.sort String.compare (List.map fst fields) = List.sort String.compare expected -> Ok fields
  | _ -> Error "Original gate record has unknown, duplicate or missing fields"
let value name fields = List.assoc name fields
(* A gate request names its parent execution by ID and request digest; the
   parent's body is read from the parent record, never copied here
   (RFC-librarian-history-settles-finished-originals 3.4). *)
let request_version = 2
let request_fields = ["version";"kind";"request_id";"owner";"execution_id";"execution_digest";
  "proposal";"authority";"predecessor"]
(* The version is read before the field set, so a request written in another
   shape is refused by name rather than as an unknown field. *)
let request_members json =
  let* () = match json with
    | `Assoc members when List.assoc_opt "version" members <> Some (`Int request_version) ->
      Error (Printf.sprintf "Original gate request is not version %d" request_version)
    | _ -> Ok () in
  fields request_fields json
let text = function
  | `String text when String.trim text <> "" -> Ok text
  | _ -> Error "Original gate identity must be nonblank"
let optional_text = function `Null -> Ok None | json -> let* text = text json in Ok (Some text)
let owned value = Result.map_error Owner.error_to_string value
let parent_execution_id (record : Owner.retained) =
  let* members = request_members record.request in
  let* () = require (value "kind" members=`String Capture.gate_kind
    && value "request_id" members=`String record.request_id) "Invalid gate original header" in
  text (value "execution_id" members)

let inputs = Capture.gate_inputs

let parent_judgment (parent : Owner.retained) = match Progress.phase parent.progress with
  | Progress.Judged judgment -> Ok judgment
  | Committing commit | Commit_unknown (commit, _) | Finished commit | Conflicted (commit, _) -> Ok commit.judgment
  | Captured | Admission_wait _ | Dispatch_pending _ | Rejected _ | Subdividing _ | Subdivided _ ->
    Error "Original gate parent has no answered judgment"
type reading = {
  load : scope:string -> request_id:string -> (Owner.retained option, string) result;
  records : scope:string -> (Owner.retained list, string) result;
  successor : scope:string -> Progress.successor -> (Yojson.Safe.t, string) result;
}
let current_reading store = {
  load=(fun ~scope ~request_id -> owned (Owner.load ~store ~scope ~request_id));
  records=(fun ~scope -> owned (Owner.load_scope ~store ~scope));
  successor=(fun ~scope successor -> owned (Owner.load_successor_request ~store ~scope successor));
}
let load_parent_with ~read ~store ~owner ~capture ~proposal =
  let* parent = read.load ~scope:(Capture.scope owner) ~request_id:(Capture.request_id capture) in
  let* parent = Option.to_result ~none:"Original gate execution parent is absent" parent in
  let* () = equal parent.request (Capture.to_json capture) "Gate parent capture differs" in
  let* judgment = parent_judgment parent in
  let* final = Capture.decode_final ~store capture judgment in
  let* () = Capture.confirm_final ~store capture final in
  let* () = match final with
    | Exact.Call_final (Answered {output;_}) ->
      equal (Exact.checked_json output) proposal "Gate proposal differs from the original answered judgment"
    | Call_final (Invalid_output _ | Input_refused _ | Output_limit_reached _)
    | Outcome_unknown | Not_allowed _ | Request_id_reused -> Error "Gate requires the original answered proposal" in
  Ok parent
let load_parent ~store ~owner ~capture ~proposal =
  load_parent_with ~read:(current_reading store) ~store ~owner ~capture ~proposal

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

let restore_result authority (input : inputs) evaluations =
  Gate.restore ~authority ~new_observations:input.observations ~facts:input.facts
    ~new_claims:input.new_claims ~superseding:input.superseding ~absorbed:input.absorbed ~evaluations
let valid_prefix authority input transcript =
  match restore_result authority input transcript.evaluations with
  | Ok result -> Ok (Some result)
  | Error (Gate.Missing_evaluation index) when index = List.length transcript.evaluations -> Ok None
  | Error (Gate.Incomplete_evaluation index) when index + 1 = List.length transcript.evaluations -> Ok None
  | Error ((Gate.Invalid_evidence _ | Incomplete_evaluation _ | Missing_evaluation _
      | Extra_evaluations _) as error) -> Error (Gate.replay_error_to_string error)
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
  `Assoc ["version",`Int request_version;"kind",`String Capture.gate_kind;"request_id",`String request_id;
    "owner",Capture.owner_to_json owner;"execution_id",`String (Capture.request_id capture);
    "execution_digest",`String parent.Owner.request_digest;
    "proposal",proposal;"authority",Gate.replay_authority_to_yojson authority;
    "predecessor",Option.fold ~none:`Null ~some:(fun id -> `String id) predecessor]
let completed_json transcript result =
  let* sha = digest (transcript_json transcript) in
  Ok (`Assoc ["kind",`String "original-gate-complete";"transcript_sha256",`String sha;
    "result",Gate.run_result_to_yojson result])

let validate_successor_request_with ~read ~store ~owner ~capture ~(prior:Owner.retained) (successor:Progress.successor) =
  let* request = read.successor ~scope:(scope owner) successor in
  let* members = request_members request in
  let* _ = text (`String successor.request_id) in
  let* () = require (successor.request_id<>prior.request_id) "Gate successor cannot name itself" in
  let proposal = value "proposal" members in
  let* prior_members = request_members prior.request in
  let* () = equal proposal (value "proposal" prior_members) "Gate successor changed the original proposal" in
  let* parent = load_parent_with ~read ~store ~owner ~capture ~proposal in
  let* authority = Gate.replay_authority_of_yojson (value "authority" members) in
  equal request (gate_request ~owner ~capture ~parent ~proposal
    ~request_id:successor.request_id ~authority ~predecessor:(Some prior.request_id))
    "Gate successor differs from its complete original request"

let rec restore_record_with ~read ~store ~owner ~capture ~visited (record : Owner.retained) =
  let* () = require (not (List.mem record.request_id visited)) "Cyclic gate retry ancestry" in
  let* members = request_members record.request in
  let* () = Capture.owner_matches_json owner (value "owner" members) in
  let proposal = value "proposal" members in
  let* input = inputs capture proposal in
  let* parent = load_parent_with ~read ~store ~owner ~capture ~proposal in
  let* authority = Gate.replay_authority_of_yojson (value "authority" members) in
  let* predecessor = optional_text (value "predecessor" members) in
  let* () = require (record.scope=scope owner && record.installation_id=parent.installation_id
    && record.package_id=parent.package_id && record.tool=parent.tool) "Gate owner destination differs from its execution" in
  let* () = equal record.request
    (gate_request ~owner ~capture ~parent ~proposal ~request_id:record.request_id ~authority ~predecessor)
    "Gate original execution identity differs" in
  let* () = match predecessor with
    | None ->
      (match Progress.preparation parent.progress with
       | None -> Error "Original gate root has no full parent preparation intent"
       | Some (Preparation_pending original | Preparation_confirmed original) ->
         let* () = require (original.request_id=record.request_id) "Original parent names another gate root" in
         let* () = equal original.request record.request "Original gate root differs from its full parent intent" in
         match Progress.preparation parent.progress with
         | Some (Preparation_pending _) ->
           require (Progress.phase record.progress=Progress.Captured)
             "Unacknowledged original gate root has execution progress"
         | Some (Preparation_confirmed _) -> Ok ()
         | None -> Error "Original gate root preparation disappeared")
    | Some request_id ->
      let* prior = read.load ~scope:(scope owner) ~request_id in
      let* prior = Option.to_result ~none:"Original predecessor gate is absent" prior in
      let* prior = restore_record_with ~read ~store ~owner ~capture ~visited:(record.request_id::visited) prior in
      let* () = equal prior.proposal proposal "Gate retry changed the original proposal" in
      let* () = match prior.complete with
       | Some result when Option.is_some (Gate.failure_detail ~absorbed:prior.input.absorbed result) -> Ok ()
       | Some _ | None -> Error "Only a completed unsuccessful gate can have a new attempt" in
      let* prior_record = read.load ~scope:(scope owner) ~request_id in
      let* prior_record = Option.to_result ~none:"Original predecessor gate disappeared" prior_record in
      (match Progress.phase prior_record.progress with
       | Progress.Subdividing (_,successor) | Subdivided (_,successor) ->
         let* () = require (successor.request_id=record.request_id) "Gate predecessor names another original child" in
         require (successor.request_digest=record.request_digest) "Gate child differs from original successor intent"
       | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
       | Finished _ | Conflicted _ | Rejected _ -> Error "Gate child has no original forward publication intent") in
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
    | Judgment_retained json -> Ok (transcript, Some (json,false))
    | Refused {stage=Progress.Execution;evidence} -> Ok (transcript, Some (evidence,true))
    | Successor_intended successor ->
      let* () = require (Option.is_some terminal) "Gate successor precedes its original terminal" in
      let* () = validate_successor_request_with ~read ~store ~owner ~capture ~prior:record successor in
      Ok (transcript,terminal)
    | Successor_observed _ ->
      let* () = require (Option.is_some terminal) "Gate successor ACK precedes its original terminal" in
      Ok (transcript,terminal)
    | Admission_declined _ | Execution_observed (Absent _) | Commit_intended _ | Commit_uncertain _
    | Commit_retry_observed _ | Commit_observed _ | Commit_conflicted _
    | Preparation_intended _ | Preparation_observed _ | Replacement_intended _ | Replacement_observed _
    | Refused {stage=Progress.Before_dispatch;_} | Observer _ -> Error "Unexpected event in original gate journal")
    (Ok (empty,None)) (Progress.events record.progress) in
  let* derived = valid_prefix authority input transcript in
  let* complete = match terminal, derived with
    | None, _ -> Ok None
    | Some (json,failed), Some result -> let* expected = completed_json transcript result in
      let* () = equal json expected "Gate terminal differs from original replay" in
      let* () = require (failed=Option.is_some (Gate.failure_detail ~absorbed:input.absorbed result))
        "Gate terminal refusal differs from its original complete result" in Ok (Some result)
    | Some _, None -> Error "Gate terminal has incomplete original evaluations" in
  Ok {proposal;authority;input;transcript;complete}

let restore_record ~store ~owner ~capture ~visited record =
  restore_record_with ~read:(current_reading store) ~store ~owner ~capture ~visited record
let validate_successor_request ~store ~owner ~capture ~prior successor =
  validate_successor_request_with ~read:(current_reading store) ~store ~owner ~capture ~prior successor
let validate ~store ~owner ~capture ~record =
  let* _ = restore_record ~store ~owner ~capture ~visited:[] record in Ok ()
let advance ~store record event =
  match Owner.advance ~store ~expected:record ~event with
  | Ok (Owner.Stored record) -> Ok (true,record)
  | Ok (Owner.Already_stored record) -> Ok (false,record)
  | Ok (Owner.Unconfirmed detail) -> Error detail
  | Error error -> Error (Owner.update_error_to_string error)
let read_chain_with ~read ~store ~owner ~capture =
  let* records = read.records ~scope:(scope owner) in
  let* matching = List.fold_left (fun result (record:Owner.retained) ->
    let* matching = result in
    let* execution_id = parent_execution_id record in
    let* () = require (record.scope=scope owner) "Gate inventory scope differs" in
    let* members = request_members record.request in
    let* () = Capture.owner_matches_json owner (value "owner" members) in
    if execution_id<>Capture.request_id capture then Ok matching else
    let* _ = restore_record_with ~read ~store ~owner ~capture ~visited:[] record in
    let* predecessor = optional_text (value "predecessor" members) in
    Ok ((record,predecessor)::matching)) (Ok []) records in
  let* () = List.fold_left (fun result ((record:Owner.retained),_) ->
    let* () = result in
    match Progress.phase record.progress with
    | Progress.Subdividing (_,successor) | Subdivided (_,successor) ->
      let* () = validate_successor_request_with ~read ~store ~owner ~capture ~prior:record successor in
      (match List.find_opt (fun ((child:Owner.retained),_) -> child.request_id=successor.request_id) matching with
       | None -> (match Progress.phase record.progress with
         | Progress.Subdividing _ -> Ok ()
         | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
         | Finished _ | Conflicted _ | Rejected _ | Subdivided _ -> Error "Acknowledged original gate successor is missing")
       | Some (child,predecessor) ->
         let* () = require (predecessor=Some record.request_id) "Gate successor has another predecessor" in
         let* () = require (successor.request_digest=child.request_digest) "Original gate successor input changed" in
         match Progress.phase record.progress with
         | Progress.Subdividing _ ->
           (match Progress.phase child.progress with
            | Progress.Captured -> Ok ()
            | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
            | Finished _ | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ ->
              Error "Unacknowledged original gate child has execution progress")
         | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
         | Finished _ | Conflicted _ | Rejected _ | Subdivided _ -> Ok ())
    | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
    | Finished _ | Conflicted _ | Rejected _ -> Ok ()) (Ok ()) matching in
  match matching with
  | [] -> Ok []
  | _::_ ->
    let predecessors = List.filter_map snd matching in
    let* () = require (List.length predecessors=List.length (List.sort_uniq String.compare predecessors))
      "Original gate retry history branches" in
    let* () = require (List.for_all (fun id -> List.exists
      (fun ((record:Owner.retained),_) -> record.request_id=id) matching) predecessors)
      "Original gate predecessor is outside its execution inventory" in
    let roots = List.filter (fun (_,predecessor) -> Option.is_none predecessor) matching in
    let leaves = List.filter (fun ((record:Owner.retained),_) -> not (List.mem record.request_id predecessors)) matching in
    let* () = require (List.length roots=1 && List.length leaves=1)
      "Original gate history has no unique complete retry frontier" in
    Ok matching
let read_chain ~store ~owner ~capture =
  read_chain_with ~read:(current_reading store) ~store ~owner ~capture
let validate_chain ~store ~owner ~capture =
  let* _ = read_chain ~store ~owner ~capture in Ok ()
let root ~store ~owner ~capture =
  let* matching = read_chain ~store ~owner ~capture in
  match List.filter (fun (_,predecessor) -> Option.is_none predecessor) matching with
  | [] -> Ok None | [(record,_)] -> Ok (Some record)
  | _::_::_ -> Error "Original gate history has multiple roots"
let latest ~store ~owner ~capture =
  let* matching = read_chain ~store ~owner ~capture in
  let* () = require (not (List.exists (fun ((record:Owner.retained),_) ->
    match Progress.phase record.progress with
    | Progress.Subdividing _ -> true
    | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
    | Finished _ | Conflicted _ | Rejected _ | Subdivided _ -> false) matching))
    "Original gate successor publication requires local recovery" in
  let predecessors=List.filter_map snd matching in
  match List.filter (fun ((record:Owner.retained),_) -> not (List.mem record.request_id predecessors)) matching with
  | [] -> Ok None | [(record,_)] -> Ok (Some record)
  | _::_::_ -> Error "Original gate history has multiple latest attempts"
let recover_retries ~store ~owner ~capture =
  let* matching = read_chain ~store ~owner ~capture in
  let* () = List.fold_left (fun result ((record:Owner.retained),_) ->
    let* () = result in
    match Progress.phase record.progress with
    | Progress.Subdividing (_,successor) ->
      let* () = validate_successor_request ~store ~owner ~capture ~prior:record successor in
      let* request = owned (Owner.load_successor_request ~store ~scope:(scope owner) successor) in
      let* () = owned (Owner.retain ~store ~scope:(scope owner) ~request_id:successor.request_id
        ~installation_id:record.installation_id ~package_id:record.package_id ~tool:record.tool
        ~summary:`Null ~request) in
      let* child = owned (Owner.load ~store ~scope:(scope owner) ~request_id:successor.request_id) in
      let* child = Option.to_result ~none:"Original gate child publication is unconfirmed" child in
      let* () = require (child.request_digest=successor.request_digest) "Original gate child publication differs" in
      let* () = validate ~store ~owner ~capture ~record:child in
      let* () = require (Progress.phase child.progress=Progress.Captured)
        "Original gate child progressed before its publication ACK" in
      let* _fresh,_record = advance ~store record (Progress.Successor_observed successor.request_id) in Ok ()
    | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
    | Finished _ | Conflicted _ | Rejected _ | Subdivided _ -> Ok ()) (Ok ()) matching in
  validate_chain ~store ~owner ~capture

let restore_size_evidence ~store ~owner ~parent_execution ~gate_request_id =
  let* record = latest ~store ~owner ~capture:parent_execution in
  let* record = Option.to_result ~none:"Original gate is absent" record in
  let* () = require (record.request_id=gate_request_id)
    "Earlier gate evidence cannot replace the latest original attempt" in
  let* restored = restore_record ~store ~owner ~capture:parent_execution ~visited:[] record in
  Option.to_result ~none:"Original gate has no completed terminal" restored.complete

let prepare_root ~store ~owner ~capture ~(parent:Owner.retained) ~proposal ~request_id ~authority =
  let* () = require (Gate.keeper_of_authority authority=Capture.keeper_id owner)
    "Original gate live authority belongs to another Keeper" in
  let* current = load_parent ~store ~owner ~capture ~proposal in
  let* () = require (parent.request_id=current.request_id && parent.request_digest=current.request_digest)
    "Original gate preparation belongs to another parent" in
  let* () = require (String.trim request_id<>"" && request_id<>current.request_id)
    "Invalid original first gate identity" in
  let* _ = inputs capture proposal in
  Ok {Progress.request_id;request=gate_request ~owner ~capture ~parent:current ~proposal ~request_id
    ~authority:(Gate.replay_authority authority) ~predecessor:None}

let root_preparation_with ~read ~store ~owner ~capture =
  let* actual = Capture.observe_owner ~base_path:(Capture.base_path owner)
    ~keepers_dir:(Capture.keepers_dir owner) ~keeper_id:(Capture.keeper_id owner) in
  let* () = Capture.owner_matches_json actual (Capture.owner_to_json owner) in
  let* parent = read.load ~scope:(Capture.scope owner) ~request_id:(Capture.request_id capture) in
  let* parent = Option.to_result ~none:"Original gate publication parent is absent" parent in
  let* () = equal parent.request (Capture.to_json capture) "Gate publication parent capture differs" in
  let* intended,pending = match Progress.preparation parent.progress with
    | Some (Preparation_pending intent) -> Ok (intent,true)
    | Some (Preparation_confirmed intent) -> Ok (intent,false)
    | None -> Error "Original execution has no gate publication intent" in
  let* members = request_members intended.request in
  let proposal=value "proposal" members in
  let* current=load_parent_with ~read ~store ~owner ~capture ~proposal in
  let* authority=Gate.replay_authority_of_yojson (value "authority" members) in
  let* ()=equal intended.request (gate_request ~owner ~capture ~parent:current ~proposal
    ~request_id:intended.request_id ~authority ~predecessor:None) "Original gate publication intent differs" in
  let* child=read.load ~scope:(scope owner) ~request_id:intended.request_id in
  let* ()=match child,pending with
    | None,true -> Ok ()
    | None,false -> Error "Acknowledged original gate root is absent"
    | Some child,(true|false) ->
      let* ()=equal child.request intended.request "Original gate root publication changed its full request" in
      let* ()=Result.map (fun _ -> ()) (restore_record_with ~read ~store ~owner ~capture ~visited:[] child) in
      if pending then require (Progress.phase child.progress=Progress.Captured)
        "Original gate root executed before its parent publication acknowledgement"
      else Ok () in
  Ok (parent,intended,pending,child)
let root_preparation ~store ~owner ~capture =
  root_preparation_with ~read:(current_reading store) ~store ~owner ~capture
let validate_root_preparation ~store ~owner ~capture =
  let* _=root_preparation ~store ~owner ~capture in Ok ()

module Inventory = struct
  module Records = Map.Make (String)
  type t = {
    store : Lane_addon_store.t;
    owner : Capture.owner;
    by_id : Owner.retained Records.t;
    by_execution : Owner.retained list Records.t;
  }
  type chain = {
    root : Owner.retained option;
    latest : (Owner.retained option, string) result;
    preparation : (unit, string) result;
    completed : (Gate.run_result option, string) result;
  }
  let read ~store ~owner =
    let* actual = Capture.observe_owner ~base_path:(Capture.base_path owner)
      ~keepers_dir:(Capture.keepers_dir owner) ~keeper_id:(Capture.keeper_id owner) in
    let* () = Capture.owner_matches_json actual (Capture.owner_to_json owner) in
    let* records = owned (Owner.load_scope ~store ~scope:(scope owner)) in
    let* by_id,by_execution = List.fold_left (fun result (record : Owner.retained) ->
      let* by_id,by_execution = result in
      let* execution_id = parent_execution_id record in
      let* members = request_members record.request in
      let* () = require (record.scope=scope owner) "Gate inventory scope differs" in
      let* () = Capture.owner_matches_json owner (value "owner" members) in
      let* () = require (not (Records.mem record.request_id by_id)) "Duplicate original gate identity" in
      let siblings=Option.value (Records.find_opt execution_id by_execution) ~default:[] in
      Ok (Records.add record.request_id record by_id,
        Records.add execution_id (record::siblings) by_execution)) (Ok (Records.empty,Records.empty)) records in
    Ok {store;owner;by_id;by_execution=Records.map List.rev by_execution}
  let record_count t = Records.cardinal t.by_id
  let executions t = List.map fst (Records.bindings t.by_execution)
  let execution_records t ~execution_id =
    Option.value (Records.find_opt execution_id t.by_execution) ~default:[]
  let validate t ~capture ~(parent : Owner.retained) =
    let store=t.store and owner=t.owner in
    let* () = require (parent.scope=Capture.scope owner && parent.request_id=Capture.request_id capture)
      "Observed original gate parent belongs to another capture" in
    let* () = equal parent.request (Capture.to_json capture) "Observed gate parent capture differs" in
    let read = {
      load=(fun ~scope:requested ~request_id ->
        if requested=Capture.scope owner then
          if request_id=parent.request_id then Ok (Some parent)
          else Error "Observed original gate execution parent differs"
        else if requested=scope owner then Ok (Records.find_opt request_id t.by_id)
        else Error "Observed original gate scope differs");
      records=(fun ~scope:requested ->
        if requested=scope owner then
          Ok (Option.value (Records.find_opt (Capture.request_id capture) t.by_execution) ~default:[])
        else Error "Observed original gate scope differs");
      successor=(fun ~scope:requested (successor : Progress.successor) ->
        if requested<>scope owner then Error "Observed original gate scope differs" else
        match Records.find_opt successor.request_id t.by_id with
        | Some record ->
          let* () = require (record.request_digest=successor.request_digest)
            "Gate child differs from original successor intent" in
          Ok record.request
        | None ->
          (* An unpublished pending successor still names its durable body.
             Read that exact digest; absence never authorizes a new child. *)
          owned (Owner.load_successor_request ~store ~scope:requested successor));
    } in
    let* matching = read_chain_with ~read ~store ~owner ~capture in
    let* root = match List.filter (fun (_,predecessor) -> Option.is_none predecessor) matching with
      | [] -> Ok None | [(record,_)] -> Ok (Some record)
      | _::_::_ -> Error "Original gate history has multiple roots" in
    let predecessors=List.filter_map snd matching in
    let latest =
      let* () = require (not (List.exists (fun ((record:Owner.retained),_) ->
        match Progress.phase record.progress with
        | Progress.Subdividing _ -> true
        | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
        | Finished _ | Conflicted _ | Rejected _ | Subdivided _ -> false) matching))
        "Original gate successor publication requires local recovery" in
      match List.filter (fun ((record:Owner.retained),_) -> not (List.mem record.request_id predecessors)) matching with
      | [] -> Ok None | [(record,_)] -> Ok (Some record)
      | _::_::_ -> Error "Original gate history has multiple latest attempts" in
    let preparation = match Progress.preparation parent.progress with
      | None -> Ok ()
      | Some (Preparation_pending _ | Preparation_confirmed _) ->
        Result.map (fun _ -> ()) (root_preparation_with ~read ~store ~owner ~capture) in
    let completed =
      let* record = latest in
      let* record = Option.to_result ~none:"Original gate is absent" record in
      let* restored = restore_record_with ~read ~store ~owner ~capture ~visited:[] record in
      Ok restored.complete in
    Ok {root;latest;preparation;completed}
  let root t = t.root
  let latest t = t.latest
  let validate_root_preparation t = t.preparation
  let restore_size_evidence t ~gate_request_id =
    let* record = t.latest in
    let* record = Option.to_result ~none:"Original gate is absent" record in
    let* () = require (record.request_id=gate_request_id)
      "Earlier gate evidence cannot replace the latest original attempt" in
    let* complete = t.completed in
    Option.to_result ~none:"Original gate has no completed terminal" complete
end

let recover_root ~store ~owner ~capture =
  let* parent,intended,pending,child=root_preparation ~store ~owner ~capture in
  if not pending then Ok parent else
  let* ()=match child with
    | None -> owned (Owner.retain ~store ~scope:(scope owner) ~request_id:intended.Progress.request_id
        ~installation_id:parent.installation_id ~package_id:parent.package_id ~tool:parent.tool
        ~summary:`Null ~request:intended.request)
    | Some _ -> Ok () in
  let* child=owned (Owner.load ~store ~scope:(scope owner) ~request_id:intended.request_id) in
  let* child=Option.to_result ~none:"Original gate root publication is unconfirmed" child in
  let* ()=equal child.request intended.request "Original gate root publication changed its full request" in
  let* ()=validate ~store ~owner ~capture ~record:child in
  let* ()=require (Progress.phase child.progress=Progress.Captured)
    "Original gate root executed before its parent publication acknowledgement" in
  let* _fresh,parent=advance ~store parent (Progress.Preparation_observed intended.request_id) in
  Ok parent

let retain ~store ~owner ~capture ~parent ~proposal ~request_id ~authority ~predecessor =
  let* () = require (Gate.keeper_of_authority authority=Capture.keeper_id owner)
    "Original gate live authority belongs to another Keeper" in
  let* current = load_parent ~store ~owner ~capture ~proposal in
  let* () = require (parent.Owner.request_digest=current.request_digest
    && parent.request_id=current.request_id) "Gate parent identity changed before retention" in
  let* _ = inputs capture proposal in
  let request = gate_request ~owner ~capture ~parent:current ~proposal ~request_id
    ~authority:(Gate.replay_authority authority) ~predecessor in
  let* () = match predecessor with
    | None ->
      let* intended,pending = match Progress.preparation current.progress with
        | Some (Preparation_pending intended) -> Ok (intended,true)
        | Some (Preparation_confirmed intended) -> Ok (intended,false)
        | None -> Error "Original first gate requires its full parent preparation intent" in
      let* () = require (intended.request_id=request_id) "First gate does not own its original parent preparation ID" in
      let* () = equal intended.request request "First gate differs from its full original preparation" in
      let* existing = root ~store ~owner ~capture in
      (match existing with
       | None -> require pending "Acknowledged original gate root cannot be recreated"
       | Some original ->
         let* () = require (original.request_id=request_id) "Original execution already has a gate root" in
         equal original.request request "Original gate root ID was reused")
    | Some id ->
      let* prior = latest ~store ~owner ~capture in
      let* prior = Option.to_result ~none:"Original predecessor gate is absent" prior in
      let* () = require (prior.request_id=id && id<>request_id) "Gate retry does not name its latest original predecessor" in
      let* restored = restore_record ~store ~owner ~capture ~visited:[] prior in
      let* () = equal restored.proposal proposal "Gate retry changed the original proposal" in
      let* () = match restored.complete,Progress.phase prior.progress with
        | Some result,Progress.Rejected {stage=Progress.Execution;_}
          when Option.is_some (Gate.failure_detail ~absorbed:restored.input.absorbed result) -> Ok ()
        | (None | Some _),(Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _
          | Commit_unknown _ | Finished _ | Conflicted _
          | Rejected {stage=(Before_dispatch | Execution);_} | Subdividing _ | Subdivided _) ->
          Error "A gate retry requires an original completed unsuccessful refusal" in
      let* successor = owned (Owner.prepare_successor ~store ~scope:(scope owner) ~request_id ~request) in
      let* () = validate_successor_request ~store ~owner ~capture ~prior successor in
      let* fresh,_record = advance ~store prior (Progress.Successor_intended successor) in
      let* () = require fresh "Original gate successor intent was already stored; reload and recover the same child" in
      recover_retries ~store ~owner ~capture in
  let* () = match predecessor with
    | None -> owned (Owner.retain ~store ~scope:(scope owner) ~request_id
        ~installation_id:current.installation_id ~package_id:current.package_id ~tool:current.tool ~summary:`Null ~request)
    | Some _ -> Ok () in
  let* retained = owned (Owner.load ~store ~scope:(scope owner) ~request_id) in
  let* retained = Option.to_result ~none:"Retained original gate disappeared" retained in
  let* () = equal retained.request request "Retained original gate request differs" in
  let* () = validate ~store ~owner ~capture ~record:retained in
  let* latest = latest ~store ~owner ~capture in
  let* latest = Option.to_result ~none:"Retained original gate chain disappeared" latest in
  let* () = require (latest.request_id=request_id) "Retained gate is not the acknowledged original frontier" in
  Ok retained

type result = Pending of Owner.retained | Complete of Gate.run_result * Owner.retained
exception Journal_error of string
let resume ~store ~owner ~capture ~record ~live_authority ~before_dispatch =
  let* restored = Systhread_host.run (fun () ->
    let* parent=owned (Owner.load ~store ~scope:(Capture.scope owner) ~request_id:(Capture.request_id capture)) in
    let* parent=Option.to_result ~none:"Original gate execution parent is absent" parent in
    let* ()=match Progress.preparation parent.progress with
      | Some (Preparation_confirmed _) -> Ok ()
      | None | Some (Preparation_pending _) -> Error "Original gate root publication is not acknowledged" in
    let* current = latest ~store ~owner ~capture in
    let* current = Option.to_result ~none:"Original gate runnable frontier is absent" current in
    let* () = require (current.request_id=record.Owner.request_id && current.request_digest=record.request_digest)
      "A historical or unacknowledged gate cannot execute" in
    let* () = equal (Progress.to_json current.progress) (Progress.to_json record.progress)
      "Original gate progress changed before resume" in
    restore_record ~store ~owner ~capture ~visited:[] current) in
  match restored.complete with
  | Some result -> Ok (Complete (result,record))
  | None ->
    let* proceed, record = match Progress.phase record.Owner.progress with
      | Progress.Captured -> Systhread_host.run (fun () -> advance ~store record Progress.Dispatch_intended)
      | Dispatch_pending _ -> Ok (true,record)
      | Admission_wait _ | Judged _ | Committing _ | Commit_unknown _ | Finished _ | Conflicted _
      | Rejected _ | Subdividing _ | Subdivided _ -> Error "Original gate has an invalid execution phase" in
    if not proceed then Ok (Pending record)
    else
      let current = ref record and transcript = ref restored.transcript in
      let publish event =
        match Systhread_host.run (fun () -> advance ~store !current event) with
        | Ok (true,record) -> current:=record
        | Ok (false,_) -> raise (Journal_error "Gate publication was already stored; reload original work")
        | Error detail -> raise (Journal_error detail) in
      let before_evaluate ~direction ~destinations ~state ~questions =
        (match before_dispatch () with Ok () -> () | Error detail -> raise (Journal_error detail));
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
        | Error ((Gate.Invalid_evidence _ | Extra_evaluations _) as error) ->
          Error (Gate.replay_error_to_string error)
        | Ok result ->
          let* confirmed = match restore_result restored.authority restored.input (!transcript).evaluations with
            | Ok result -> Ok result | Error error -> Error (Gate.replay_error_to_string error) in
          let* () = equal (Gate.run_result_to_yojson result) (Gate.run_result_to_yojson confirmed)
            "Executed gate differs from its original transcript replay" in
          let* terminal = completed_json !transcript confirmed in
          let event = match Gate.failure_detail ~absorbed:restored.input.absorbed confirmed with
            | None -> Progress.Judgment_retained terminal
            | Some _ -> Progress.Refused {stage=Progress.Execution;evidence=terminal} in
          Eio.Cancel.protect (fun () -> publish event);
          Ok (Complete (confirmed,!current))
      with Journal_error detail -> Error detail

end
