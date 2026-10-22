module Exact = Agent_core.Exact_output
module Failure = Keeper_exact_walk_failure
let ( let* ) = Result.bind

type binding = { candidate_id:string; catalog_generation:string; catalog_evidence:string; target:string }
[@@deriving yojson]
type visit = { ordinal:int; candidate_id:string } [@@deriving yojson]
type generation_phase = Fresh | Before_wire | Wire_started | Response_received | Terminal
[@@deriving yojson]
type attempt = { visit:visit; call_id:string; phase:generation_phase; dispatch_count:int;
  generation_sent:bool; plan:string; body:string }
[@@deriving yojson]
type failed =
  | Rejected of { visit:visit; disposition:Failure.local_rejection; detail:string }
  | Execution_failed of { visit:visit; cause:Failure.api_observation; raw_sha:string option }
[@@deriving yojson]
type advance = { failed:failed; next:visit } [@@deriving yojson]
type semantic = { visit:visit; raw_sha:string; detail:string } [@@deriving yojson]
type local_stop = Already_started | Attempt_start | Measurement_start | Before_measurement
  | Measurement_terminal | Before_dispatch | Before_advance of failed
[@@deriving yojson]
type terminal = Not_started of string | Accepted of visit | Execution_exhausted of failed
  | Candidates_exhausted of failed | Execution_stopped of failed | Semantic_exhausted | Locally_stopped of local_stop
[@@deriving yojson]
type http = { flow_id:string option; declared:binding list; visited:int;
  admissions:visit list; attempts:attempt list; measurements:string list;
  advances:advance list; semantic:semantic list; terminal:terminal; generation_sent:bool }
[@@deriving yojson]
type cli_result = Not_reached | Prompt_unavailable | Answered of string | Exhausted [@@deriving yojson]
type cli = { visited:string list; dispatched:string list; failures:Failure.cli_observation list; result:cli_result }
[@@deriving yojson]
type t = { version:int; declared_http:string list; excluded_http:string list;
  declared_cli:string list; http:http; cli:cli } [@@deriving yojson]

let cli ~visited ~dispatched ~failures ~result =
  {visited;dispatched;failures=List.map Failure.cli_observation failures;result}
let visit (v : Exact.flow_candidate_visit) =
  {ordinal=Exact.flow_visit_ordinal_to_int v.ordinal;candidate_id=v.identity.candidate_id}
let binding (identity : Exact.flow_candidate_identity) =
  {candidate_id=identity.candidate_id;
   catalog_generation=Exact.catalog_generation_fingerprint identity.catalog_generation;
   catalog_evidence=Exact.catalog_evidence_sha256 identity.catalog_evidence;
   target=Exact.target_identity_fingerprint identity.target_identity}
let phase = function
  | Exact.Not_started -> Fresh | Before_dispatch -> Before_wire
  | Dispatch_started -> Wire_started | Response_received -> Response_received | Terminal -> Terminal
let rejected receipt = Rejected {visit=visit (Exact.candidate_rejection_visit receipt);
  disposition=Failure.local_rejection (Exact.candidate_rejection_disposition receipt);
  detail=Exact.candidate_rejection_reason receipt}
let execution (candidate : Exact.flow_attempt_receipt) (error : Exact.execution_error) =
  Execution_failed {visit=visit candidate.visit;cause=Failure.api_observation error.cause;
    raw_sha=Option.map (fun (raw : Exact.raw_response) -> raw.body_sha256) error.raw_response}
let failed_snapshot = function
  | Exact.Flow_advance_candidate_rejected receipt -> rejected receipt
  | Flow_advance_execution_failed {candidate;cause;raw_response_sha256} ->
    Execution_failed {visit=visit candidate.visit;cause=Failure.api_observation cause;raw_sha=raw_response_sha256}
let failed_candidate = function
  | Exact.Flow_candidate_rejected receipt -> rejected receipt
  | Flow_candidate_execution_failed {candidate;cause} -> execution candidate cause
let semantic ~rejection_to_string (receipt : 'a Exact.semantic_rejection_receipt) =
  {visit=visit (Exact.flow_success_candidate receipt.transport_success).visit;
   raw_sha=(Exact.flow_success_output receipt.transport_success).raw_response.body_sha256;
   detail=rejection_to_string receipt.rejection}
let capture evidence ~semantic ~terminal =
  {flow_id=Some (Exact.flow_id_to_string evidence.Exact.flow_id);
   declared=List.map binding evidence.declared_candidate_snapshot;
   visited=Exact.candidate_visit_count_to_int evidence.candidate_visit_count;
   admissions=List.map (function
     | Exact.Candidate_admitted admitted -> visit admitted.visit
     | Candidate_rejected receipt -> visit (Exact.candidate_rejection_visit receipt)) evidence.admissions;
   attempts=List.map (fun (a : Exact.flow_attempt_snapshot) ->
     {visit=visit a.visit;call_id=Exact.call_id_to_string (Exact.generation_receipt_snapshot_call_id a.receipt);
      phase=phase (Exact.generation_receipt_snapshot_phase a.receipt);
      dispatch_count=Exact.generation_receipt_snapshot_dispatch_count a.receipt;
      generation_sent=Exact.generation_receipt_snapshot_generation_dispatched a.receipt;
      plan=Exact.generation_receipt_snapshot_plan_fingerprint a.receipt;
      body=Exact.generation_receipt_snapshot_request_body_sha256 a.receipt}) evidence.attempts;
   measurements=List.map Exact.measurement_receipt_snapshot_to_string evidence.measurements;
   advances=List.map (fun (a : Exact.flow_advance_receipt) -> {failed=failed_snapshot a.failed;next=visit a.next}) evidence.advances;
   semantic;terminal;generation_sent=(Exact.flow_evidence_generation_dispatch evidence=Exact.Generation_dispatch_started)}
let http_not_started ~detail =
  {flow_id=None;declared=[];visited=0;admissions=[];attempts=[];measurements=[];
   advances=[];semantic=[];terminal=Not_started detail;generation_sent=false}
let http_success (success : ('a,'b) Exact.validated_flow_success) ~rejection_to_string =
  capture (Exact.flow_success_evidence success.transport_success)
    ~semantic:(List.map (semantic ~rejection_to_string) success.prior_rejections)
    ~terminal:(Accepted (visit (Exact.flow_success_candidate success.transport_success).visit))
let http_failure ~callback_error_to_string ~rejection_to_string = function
  | Exact.Flow_semantic_candidates_exhausted {rejections;evidence} ->
    capture evidence ~semantic:(List.map (semantic ~rejection_to_string) (rejections.first::rejections.rest))
      ~terminal:Semantic_exhausted
  | Exact.Flow_execution_terminal {cause;prior_rejections} ->
    let evidence,terminal = match cause with
      | Exact.Flow_exact_execution_failed {candidate;cause=error;evidence} ->
        evidence,(match Exact.flow_execution_terminal_kind cause with
          | Exact.Advanceable_candidates_exhausted -> Execution_exhausted (execution candidate error)
          | Non_advanceable_terminal -> Execution_stopped (execution candidate error))
      | Flow_candidates_exhausted {rejection;evidence} -> evidence,Candidates_exhausted (rejected rejection)
      | Flow_attempt_already_started evidence -> evidence,Locally_stopped Already_started
      | Flow_attempt_start_failed {evidence;_} -> evidence,Locally_stopped Attempt_start
      | Flow_measurement_start_failed {evidence;_} -> evidence,Locally_stopped Measurement_start
      | Flow_before_measurement_dispatch_callback_failed {evidence;cause;_} ->
        ignore (callback_error_to_string cause); evidence,Locally_stopped Before_measurement
      | Flow_measurement_terminal_callback_failed {evidence;cause;_} ->
        ignore (callback_error_to_string cause); evidence,Locally_stopped Measurement_terminal
      | Flow_before_dispatch_callback_failed {evidence;cause;_} ->
        ignore (callback_error_to_string cause); evidence,Locally_stopped Before_dispatch
      | Flow_before_advance_callback_failed {evidence;cause;failed;_} ->
        ignore (callback_error_to_string cause); evidence,Locally_stopped (Before_advance (failed_candidate failed)) in
    capture evidence ~semantic:(List.map (semantic ~rejection_to_string) prior_rejections) ~terminal

let failed_visit = function Rejected {visit;_} | Execution_failed {visit;_} -> visit
let failure = function
  | Rejected {disposition;_} -> Failure.of_local_rejection disposition
  | Execution_failed {cause;_} -> Failure.of_api_observation cause
let terminal_failure = function
  | Execution_exhausted failed | Candidates_exhausted failed | Execution_stopped failed -> Some failed
  | Not_started _ | Accepted _ | Semantic_exhausted | Locally_stopped _ -> None
let failure_evidence receipt =
  let prior = List.fold_left (fun acc (advance : advance) -> Failure.combine acc (failure advance.failed))
    Failure.empty receipt.http.advances in
  let prior = Option.fold ~none:prior ~some:(fun last -> Failure.combine prior (failure last))
    (terminal_failure receipt.http.terminal) in
  let prior = if receipt.http.semantic=[] then prior else Failure.with_invalid_output prior in
  let prior = match receipt.cli.result with
    | Not_reached -> prior
    | Prompt_unavailable | Answered _ | Exhausted -> Failure.without_measured_cli_capacity prior in
  List.fold_left (fun acc observed -> Failure.combine acc (Failure.of_cli_observation observed)) prior receipt.cli.failures
let generation_dispatch receipt =
  if receipt.http.generation_sent then Exact.Generation_dispatch_started else Exact.No_generation_dispatch
let answered_slot receipt = match receipt.cli.result,receipt.http.terminal with
  | Answered slot,_ -> Some slot
  | (Not_reached | Prompt_unavailable | Exhausted),Accepted visit -> Some visit.candidate_id
  | (Not_reached | Prompt_unavailable | Exhausted),(Not_started _ | Execution_exhausted _
      | Candidates_exhausted _ | Execution_stopped _ | Semantic_exhausted | Locally_stopped _) -> None
let dispatched_failure = function
  | Rejected _ -> false
  | Execution_failed {cause;_} -> Failure.dispatched_valid_output_failure cause
let exhausted_input_refusals receipt =
  let evidence=failure_evidence receipt in
  match receipt.http.terminal,evidence.provider_input_refusals with
  | Execution_exhausted last,(_::_ as causes)
    when receipt.declared_cli=[] && receipt.excluded_http=[] && receipt.http.semantic=[]
      && not evidence.invalid_output && receipt.http.visited=List.length receipt.http.declared
      && dispatched_failure last && List.for_all (fun (a : advance) -> dispatched_failure a.failed) receipt.http.advances -> Some causes
  | (Not_started _ | Accepted _ | Execution_exhausted _ | Candidates_exhausted _
      | Execution_stopped _ | Semantic_exhausted | Locally_stopped _),([] | _::_) -> None

let valid_digest text = String.length text=64 && String.for_all (function '0'..'9'|'a'..'f' -> true | _ -> false) text
let unique values = List.length values=List.length (List.sort_uniq String.compare values)
let valid_names values = unique values && List.for_all (fun value -> String.trim value<>"") values
let check condition detail = if condition then Ok () else Error detail
let validate receipt =
  let h=receipt.http in
  let ids=List.map (fun (b : binding) -> b.candidate_id) h.declared in
  let* ()=check (receipt.version=1 && valid_names receipt.declared_http && valid_names receipt.declared_cli
    && valid_names receipt.excluded_http) "invalid walk version or declarations" in
  let* ()=check (List.for_all (fun id -> List.mem id receipt.declared_http) receipt.excluded_http)
    "excluded HTTP member not declared" in
  let* ()=check (ids=List.filter (fun id -> not (List.mem id receipt.excluded_http)) receipt.declared_http
      || (match h.flow_id,h.terminal with None,Not_started _ -> true | (None|Some _),
        (Accepted _|Execution_exhausted _|Candidates_exhausted _|Execution_stopped _|Semantic_exhausted|Locally_stopped _) | Some _,Not_started _ -> false))
    "HTTP snapshot differs from original declaration" in
  let valid_visit (v : visit) = v.ordinal>0 && v.ordinal<=h.visited && v.ordinal<=List.length ids
    && List.nth_opt ids (v.ordinal-1)=Some v.candidate_id in
  let* ()=check (h.visited>=0 && h.visited<=List.length ids && List.length h.admissions=h.visited
    && List.for_all Fun.id (List.mapi (fun i (v : visit) -> v.ordinal=i+1 && valid_visit v) h.admissions))
    "incomplete or reordered HTTP visits" in
  let* ()=check (List.for_all (fun (b : binding) -> valid_digest b.catalog_generation
    && valid_digest b.catalog_evidence && valid_digest b.target) h.declared) "invalid candidate fingerprints" in
  let valid_generation (a : attempt) = match a.phase with
    | Fresh | Before_wire -> a.dispatch_count=0 && not a.generation_sent
    | Wire_started | Response_received | Terminal -> a.dispatch_count=1 && a.generation_sent in
  let attempt_ids=List.map (fun (a : attempt) -> a.visit.candidate_id) h.attempts in
  let* ()=check (unique attempt_ids && List.for_all (fun (a : attempt) -> valid_visit a.visit
      && String.trim a.call_id<>"" && valid_generation a
      && valid_digest a.plan && valid_digest a.body) h.attempts) "invalid generation attempts" in
  let valid_failed failed = valid_visit (failed_visit failed) && match failed with
    | Rejected _ -> not (List.mem (failed_visit failed).candidate_id attempt_ids)
    | Execution_failed {raw_sha;_} -> List.mem (failed_visit failed).candidate_id attempt_ids
      && Option.fold ~none:true ~some:valid_digest raw_sha
      && (match List.find_opt (fun (a : attempt) -> a.visit=(failed_visit failed)) h.attempts,failed with
        | Some attempt,Execution_failed {cause;_} -> attempt.generation_sent=Failure.api_generation_dispatched cause
        | (Some _|None),Rejected _ | None,Execution_failed _ -> false) in
  let* ()=check (List.for_all (fun (a : advance) -> valid_failed a.failed && valid_visit a.next
      && (failed_visit a.failed).ordinal+1=a.next.ordinal) h.advances)
    "invalid or unbound advance" in
  let visit_was_sent visit = List.exists (fun (a : attempt) -> a.visit=visit && a.generation_sent) h.attempts in
  let* ()=check (List.for_all (fun (s : semantic) -> valid_visit s.visit
      && visit_was_sent s.visit && valid_digest s.raw_sha) h.semantic
      && unique (List.map (fun (s : semantic) -> s.visit.candidate_id) h.semantic)) "invalid semantic visits" in
  let terminal_valid = match h.flow_id,h.terminal with
    | None,Not_started _ -> h.visited=0 && h.declared=[] && h.attempts=[] && h.measurements=[]
      && h.advances=[] && h.semantic=[] && not h.generation_sent
    | Some flow,(Accepted v) -> String.trim flow<>"" && valid_visit v && v.ordinal=h.visited
      && visit_was_sent v
    | Some flow,(Execution_exhausted failed | Candidates_exhausted failed) ->
      String.trim flow<>"" && valid_failed failed && (failed_visit failed).ordinal=h.visited
      && h.visited=List.length h.declared
    | Some flow,Execution_stopped failed -> String.trim flow<>"" && valid_failed failed
    | Some flow,Semantic_exhausted -> String.trim flow<>"" && h.visited=List.length h.declared
      && List.exists (fun (s : semantic) -> s.visit.ordinal=h.visited) h.semantic
    | Some flow,Locally_stopped stop -> String.trim flow<>"" && (match stop with
        | Before_advance failed -> valid_failed failed
        | Already_started | Attempt_start | Measurement_start | Before_measurement
        | Measurement_terminal | Before_dispatch -> true)
    | None,(Accepted _|Execution_exhausted _|Candidates_exhausted _|Execution_stopped _|Semantic_exhausted|Locally_stopped _)
    | Some _,Not_started _ -> false in
  let* ()=check terminal_valid "invalid HTTP terminal" in
  let ordered_unique visits =
    List.map (fun (v : visit) -> v.ordinal) visits
    = List.sort_uniq Int.compare (List.map (fun (v : visit) -> v.ordinal) visits) in
  let* ()=check (ordered_unique (List.map (fun (a : advance) -> failed_visit a.failed) h.advances)
    && ordered_unique (List.map (fun (s : semantic) -> s.visit) h.semantic)
    && ordered_unique (List.map (fun (a : attempt) -> a.visit) h.attempts)) "reordered or duplicate flow evidence" in
  let terminal_visits,complete = match h.terminal with
    | Accepted v -> [v],true
    | Execution_exhausted failed | Candidates_exhausted failed -> [failed_visit failed],true
    | Semantic_exhausted -> [],true
    | Not_started _ | Locally_stopped _ | Execution_stopped _ -> [],false in
  let outcome_visits=List.map (fun (a : advance) -> failed_visit a.failed) h.advances
    @ List.map (fun (s : semantic) -> s.visit) h.semantic @ terminal_visits in
  let* ()=check (not complete || List.sort Int.compare (List.map (fun (v : visit) -> v.ordinal) outcome_visits)
    = List.init h.visited (fun i -> i+1)) "missing or duplicated candidate outcomes" in
  let executed_visits=List.filter_map (fun (a : advance) -> match a.failed with
      | Execution_failed {visit;_} -> Some visit | Rejected _ -> None) h.advances
    @ List.map (fun (s : semantic) -> s.visit) h.semantic
    @ (match h.terminal with Accepted v | Execution_exhausted (Execution_failed {visit=v;_}) -> [v]
       | Execution_exhausted (Rejected _) | Candidates_exhausted _ | Semantic_exhausted
       | Execution_stopped _ | Not_started _ | Locally_stopped _ -> []) in
  let* ()=check (not complete || List.sort Int.compare (List.map (fun (v : visit) -> v.ordinal) executed_visits)
    = List.map (fun (a : attempt) -> a.visit.ordinal) h.attempts) "generation attempts differ from executed outcomes" in
  let sent = List.exists (fun (s : semantic) -> valid_visit s.visit) h.semantic
    || (match h.terminal with Accepted _ -> true | Not_started _ | Execution_exhausted _
        | Candidates_exhausted _ | Execution_stopped _ | Semantic_exhausted | Locally_stopped _ -> false)
    || List.exists (function Execution_failed {cause;_} -> Failure.dispatched_valid_output_failure cause
        | Rejected _ -> false) (List.map (fun (a : advance) -> a.failed) h.advances
          @ Option.to_list (terminal_failure h.terminal)) in
  let* ()=check ((not sent || h.generation_sent)
    && h.generation_sent=List.exists (fun (a : attempt) -> a.generation_sent) h.attempts)
    "generation fact contradicts original attempts" in
  let* ()=List.fold_left (fun result raw -> let* ()=result in
    let* measurement=Exact.measurement_receipt_snapshot_of_string raw
      |> Result.map_error Exact.measurement_receipt_snapshot_decode_error_to_string in
    let v={ordinal=Exact.flow_visit_ordinal_to_int measurement.visit_ordinal;candidate_id=measurement.candidate_id} in
    let binding=List.nth_opt h.declared (v.ordinal-1) in
    check (valid_visit v && h.flow_id=Some (Exact.flow_id_to_string measurement.flow_id)
      && (match binding with None -> false | Some binding ->
        measurement.catalog_generation_fingerprint=binding.catalog_generation
        && measurement.catalog_evidence_sha256=binding.catalog_evidence))
      "measurement belongs to another flow visit or catalog") (Ok ()) h.measurements in
  let failure_ids=List.map Failure.cli_observation_slot receipt.cli.failures in
  let c=receipt.cli in
  let* ()=check (unique c.visited && unique c.dispatched && unique failure_ids
    && List.for_all (fun id -> List.mem id receipt.declared_cli) c.visited)
    "CLI visits differ from the original declaration" in
  let expected_dispatch=List.filter_map (fun failure ->
    if Failure.cli_was_dispatched failure then Some (Failure.cli_observation_slot failure) else None) c.failures
    @ (match c.result with Answered slot -> [slot] | Not_reached|Prompt_unavailable|Exhausted -> []) in
  let* ()=check (c.dispatched=expected_dispatch) "CLI dispatch differs from original ordered outcomes" in
  let* ()=check (match c.result with
    | Not_reached -> c.visited=[] && c.dispatched=[] && c.failures=[]
    | Prompt_unavailable -> receipt.declared_cli<>[] && c.visited=[] && c.dispatched=[] && c.failures=[]
    | Answered slot -> List.mem slot receipt.declared_cli && not (List.mem slot failure_ids)
        && c.visited=failure_ids@[slot]
    | Exhausted -> receipt.declared_cli<>[] && c.visited=failure_ids
        && List.sort String.compare c.visited=List.sort String.compare receipt.declared_cli)
    "incomplete or reordered CLI outcome" in
  check (match h.terminal,receipt.cli.result with
    | Accepted _,Not_reached -> true
    | (Accepted _|Locally_stopped _|Execution_stopped _),(Prompt_unavailable|Answered _|Exhausted) -> false
    | (Locally_stopped _|Execution_stopped _),Not_reached -> true
    | (Not_started _|Execution_exhausted _|Candidates_exhausted _|Semantic_exhausted),
      (Not_reached|Prompt_unavailable|Answered _|Exhausted) -> true) "CLI ran after a stopped HTTP flow"

let make ~declared_http ~excluded_http ~declared_cli ~http ~cli =
  let value={version=1;declared_http;excluded_http;declared_cli;http;cli} in
  let* ()=validate value in Ok value
let to_json = to_yojson
let of_json json =
  let* value=of_yojson json in
  let* original=Lane_addon_action.canonical json in
  let* encoded=Lane_addon_action.canonical (to_json value) in
  let* ()=check (original=encoded) "unknown or noncanonical original walk evidence" in
  let* ()=validate value in Ok value
