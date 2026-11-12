module Exact = Agent_core.Exact_output
module Responses = Agent_core.Llm_provider.Backend_openai_responses
module Responses_status = Agent_core.Llm_provider.Responses_stop_reason
module Failure = Keeper_exact_walk_failure
open Result.Syntax

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
type http_v1 = { flow_id:string option; declared:binding list; visited:int;
  admissions:visit list; attempts:attempt list; measurements:string list;
  advances:advance list; semantic:semantic list; terminal:terminal; generation_sent:bool }
[@@deriving yojson]
type response_family = Responses_codec | Other_codec [@@deriving yojson]
type observed_status = Queued | In_progress | Completed | Failed | Incomplete | Cancelled
  | Other_digest of string [@@deriving yojson]
type lifecycle = Observed_status of observed_status | Ambiguous_envelope | Unreadable_json
[@@deriving yojson]
type response_observation = { visit:visit; call_id:string; family:response_family;
  http_status:int option; body_sha256:string option; lifecycle:lifecycle option }
[@@deriving yojson]
type response_observations = response_observation list [@@deriving yojson]
type http = { legacy:http_v1; response_observations:response_observations }
type cli_result = Not_reached | Prompt_unavailable | Answered of string | Exhausted
  | Stopped_before_dispatch of string [@@deriving yojson]
type cli = { visited:string list; dispatched:string list; failures:Failure.cli_observation list; result:cli_result }
[@@deriving yojson]
type walk = { version:int; declared_http:string list; excluded_http:string list;
  declared_cli:string list; http:http_v1; cli:cli } [@@deriving yojson]
type t = { walk:walk; observations:response_observations option }
let response_observations receipt = receipt.observations

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
let response_family = function
  | Exact.Openai_responses_codec -> Responses_codec | Other_http_codec -> Other_codec
let lifecycle = function
  | Responses.Ambiguous_envelope -> Ambiguous_envelope
  | Responses.Unreadable_json -> Unreadable_json
  | Responses.Observed_status status ->
    Observed_status (match status with
      | Responses_status.Queued -> Queued | In_progress -> In_progress | Completed -> Completed
      | Failed -> Failed | Incomplete -> Incomplete | Cancelled -> Cancelled
      | Other value -> Other_digest Agent_core_sha256.(to_hex (digest_string value)))
let capture evidence ~semantic ~terminal =
  let walk={flow_id=Some (Exact.flow_id_to_string evidence.Exact.flow_id);
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
   semantic;terminal;generation_sent=(Exact.flow_evidence_generation_dispatch evidence=Exact.Generation_dispatch_started)} in
  let observations=List.map (fun (a : Exact.flow_attempt_snapshot) ->
    {visit=visit a.visit;call_id=Exact.call_id_to_string (Exact.generation_receipt_snapshot_call_id a.receipt);
     family=response_family (Exact.generation_receipt_snapshot_response_family a.receipt);
     http_status=Exact.generation_receipt_snapshot_http_status a.receipt;
     body_sha256=Exact.generation_receipt_snapshot_response_body_sha256 a.receipt;
     lifecycle=Option.map lifecycle (Exact.generation_receipt_snapshot_responses_lifecycle a.receipt)}) evidence.attempts in
  {legacy=walk;response_observations=observations}
let http_not_started ~detail =
  {legacy={flow_id=None;declared=[];visited=0;admissions=[];attempts=[];measurements=[];
   advances=[];semantic=[];terminal=Not_started detail;generation_sent=false};response_observations=[]}
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
  let receipt=receipt.walk in
  let prior = List.fold_left (fun acc (advance : advance) -> Failure.combine acc (failure advance.failed))
    Failure.empty receipt.http.advances in
  let prior = Option.fold ~none:prior ~some:(fun last -> Failure.combine prior (failure last))
    (terminal_failure receipt.http.terminal) in
  let prior = if receipt.http.semantic=[] then prior else Failure.with_invalid_output prior in
  let prior = match receipt.cli.result with
    | Not_reached -> prior
    | Prompt_unavailable | Answered _ | Exhausted | Stopped_before_dispatch _ ->
      Failure.without_measured_cli_capacity prior in
  List.fold_left (fun acc observed -> Failure.combine acc (Failure.of_cli_observation observed)) prior receipt.cli.failures
let generation_dispatch receipt =
  let receipt=receipt.walk in
  if receipt.http.generation_sent then Exact.Generation_dispatch_started else Exact.No_generation_dispatch
let answered_slot receipt = let receipt=receipt.walk in match receipt.cli.result,receipt.http.terminal with
  | Answered slot,_ -> Some slot
  | (Not_reached | Prompt_unavailable | Exhausted | Stopped_before_dispatch _),Accepted visit ->
    Some visit.candidate_id
  | (Not_reached | Prompt_unavailable | Exhausted | Stopped_before_dispatch _),(Not_started _ | Execution_exhausted _
      | Candidates_exhausted _ | Execution_stopped _ | Semantic_exhausted | Locally_stopped _) -> None
let dispatched_failure = function
  | Rejected _ -> false
  | Execution_failed {cause;_} -> Failure.dispatched_valid_output_failure cause
let exhausted_input_refusals receipt =
  let evidence=failure_evidence receipt in
  let receipt=receipt.walk in
  match receipt.http.terminal,evidence.provider_input_refusals with
  | Execution_exhausted last,(_::_ as causes)
    when receipt.declared_cli=[] && receipt.excluded_http=[] && receipt.http.semantic=[]
      && not evidence.invalid_output && receipt.http.visited=List.length receipt.http.declared
      && dispatched_failure last && List.for_all (fun (a : advance) -> dispatched_failure a.failed) receipt.http.advances -> Some causes
  | (Not_started _ | Accepted _ | Execution_exhausted _ | Candidates_exhausted _
      | Execution_stopped _ | Semantic_exhausted | Locally_stopped _),([] | _::_) -> None

type http_slot = { slot_id:string; target_fingerprint:string }
type http_slot_answer = Input_size_refused | Other_answer
let http_slot_answers receipt =
  let h=receipt.walk.http in
  let bound (visit : visit) = List.find_map (fun (b : binding) ->
    if String.equal b.candidate_id visit.candidate_id
    then Some {slot_id=b.candidate_id;target_fingerprint=b.target} else None) h.declared in
  let answered visit = Option.map (fun slot -> slot,Other_answer) (bound visit) in
  let failed = function
    | Rejected _ -> None
    | Execution_failed {visit;cause;_} ->
      (match (Failure.of_api_observation cause).Failure.provider_input_refusals with
       | _::_ -> Option.map (fun slot -> slot,Input_size_refused) (bound visit)
       | [] -> if Failure.api_generation_dispatched cause then answered visit else None) in
  let terminal = match h.terminal with
    | Accepted visit -> Option.to_list (answered visit)
    | Execution_exhausted f | Candidates_exhausted f | Execution_stopped f
    | Locally_stopped (Before_advance f) -> Option.to_list (failed f)
    | Not_started _ | Semantic_exhausted
    | Locally_stopped (Already_started | Attempt_start | Measurement_start | Before_measurement
                      | Measurement_terminal | Before_dispatch) -> [] in
  List.filter_map (fun (a : advance) -> failed a.failed) h.advances
  @ List.filter_map (fun (s : semantic) -> answered s.visit) h.semantic
  @ terminal

let valid_digest = String_util.is_lowercase_sha256_hex
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
    @ (match c.result with Answered slot -> [slot]
       | Not_reached|Prompt_unavailable|Exhausted|Stopped_before_dispatch _ -> []) in
  let* ()=check (c.dispatched=expected_dispatch) "CLI dispatch differs from original ordered outcomes" in
  let* ()=check (match c.result with
    | Not_reached -> c.visited=[] && c.dispatched=[] && c.failures=[]
    | Prompt_unavailable -> receipt.declared_cli<>[] && c.visited=[] && c.dispatched=[] && c.failures=[]
    | Answered slot -> List.mem slot receipt.declared_cli && not (List.mem slot failure_ids)
        && c.visited=failure_ids@[slot]
    | Exhausted -> receipt.declared_cli<>[] && c.visited=failure_ids
        && List.sort String.compare c.visited=List.sort String.compare receipt.declared_cli
    | Stopped_before_dispatch slot -> List.mem slot receipt.declared_cli
        && not (List.mem slot failure_ids) && c.visited=failure_ids@[slot])
    "incomplete or reordered CLI outcome" in
  check (match h.terminal,receipt.cli.result with
    | Accepted _,Not_reached -> true
    | (Accepted _|Locally_stopped _|Execution_stopped _),
      (Prompt_unavailable|Answered _|Exhausted|Stopped_before_dispatch _) -> false
    | (Locally_stopped _|Execution_stopped _),Not_reached -> true
    | (Not_started _|Execution_exhausted _|Candidates_exhausted _|Semantic_exhausted),
      (Not_reached|Prompt_unavailable|Answered _|Exhausted|Stopped_before_dispatch _) -> true)
    "CLI ran after a stopped HTTP flow"

let validate_observations walk observations =
  let h=walk.http in
  let* ()=check (List.length h.attempts=List.length observations)
    "response observations differ from the original attempts" in
  let* ()=check (unique (List.map (fun (observation : response_observation) -> observation.call_id) observations))
    "response observations repeat an attempt identity" in
  let failures=List.map (fun (advance : advance) -> advance.failed) h.advances
    @ (match h.terminal with
      | Execution_exhausted f | Candidates_exhausted f | Execution_stopped f
      | Locally_stopped (Before_advance f) -> [f]
      | Not_started _ | Accepted _ | Semantic_exhausted
      | Locally_stopped (Already_started | Attempt_start | Measurement_start | Before_measurement
                        | Measurement_terminal | Before_dispatch) -> []) in
  let original_raw = List.filter_map (function
    | Execution_failed {visit;raw_sha=Some raw;_} -> Some (visit,raw)
    | Execution_failed {raw_sha=None;_} | Rejected _ -> None) failures
    @ List.map (fun (semantic : semantic) -> semantic.visit,semantic.raw_sha) h.semantic in
  List.fold_left (fun state ((attempt : attempt),(observation : response_observation)) ->
    let* ()=state in
    let* ()=check (attempt.visit=observation.visit && String.equal attempt.call_id observation.call_id)
      "response observation belongs to another attempt" in
    let has_headers=match attempt.phase with Response_received | Terminal -> true
      | Fresh | Before_wire | Wire_started -> false in
    let* ()=check (has_headers || observation.http_status=None)
      "response status before response observation" in
    let* ()=check (attempt.phase<>Terminal || observation.http_status<>None)
      "terminal response has no observed status" in
    let* ()=check (Option.fold ~none:true ~some:valid_digest observation.body_sha256
      && (observation.body_sha256=None || observation.http_status<>None))
      "invalid response body digest or missing response status" in
    let* ()=check (match observation.lifecycle,observation.family,observation.http_status,observation.body_sha256 with
      | None,_,_,_ -> true
      | Some lifecycle,Responses_codec,Some status,Some _ when status>=200 && status<300 ->
        (match lifecycle with Observed_status (Other_digest digest) -> valid_digest digest
         | Observed_status (Queued | In_progress | Completed | Failed | Incomplete | Cancelled)
         | Ambiguous_envelope | Unreadable_json -> true)
      | Some _,(Responses_codec | Other_codec),_,_ -> false)
      "invalid Responses lifecycle observation" in
    let body_deadline=List.exists (function
      | Execution_failed {visit;cause;_} -> visit=observation.visit && Failure.api_observation_is_body_deadline cause
      | Rejected _ -> false) failures in
    let* ()=check (not body_deadline || (attempt.phase=Response_received && Option.fold ~none:false
      ~some:(fun status -> status>=200 && status<300) observation.http_status
      && observation.body_sha256=None && observation.lifecycle=None))
      "body deadline differs from its response observation" in
    let successful = List.exists (fun (semantic : semantic) -> semantic.visit=observation.visit) h.semantic
      || (match h.terminal with Accepted visit -> visit=observation.visit
          | Not_started _ | Execution_exhausted _ | Candidates_exhausted _ | Execution_stopped _
          | Semantic_exhausted | Locally_stopped _ -> false) in
    let successful_lifecycle=match observation.family,observation.lifecycle with
      | Other_codec,None -> true
      | Responses_codec,Some (Observed_status Completed | Ambiguous_envelope) -> true
      | Other_codec,Some _ | Responses_codec,(None | Some (Unreadable_json
          | Observed_status (Queued | In_progress | Failed | Incomplete | Cancelled | Other_digest _))) -> false in
    let* ()=check (not successful || (attempt.phase=Terminal
      && Option.fold ~none:false ~some:(fun status -> status>=200 && status<300) observation.http_status
      && observation.body_sha256<>None
      && successful_lifecycle))
      "successful visit lacks its complete response observation" in
    check (List.for_all (fun (visit,original) -> visit<>observation.visit
      || observation.body_sha256=Some original) original_raw)
      "response digest differs from the original outcome") (Ok ()) (List.combine h.attempts observations)

let make_internal ~version ~declared_http ~excluded_http ~declared_cli ~(http : http) ~cli =
  let walk={version=1;declared_http;excluded_http;declared_cli;http=http.legacy;cli} in
  let* ()=validate walk in
  let* observations=match version with
    | `V1 -> Ok None
    | `V2 -> let* ()=validate_observations walk http.response_observations in
      Ok (Some http.response_observations) in
  Ok {walk;observations}
let make ~declared_http ~excluded_http ~declared_cli ~http ~cli =
  make_internal ~version:`V1 ~declared_http ~excluded_http ~declared_cli ~http ~cli
let make_v2 ~declared_http ~excluded_http ~declared_cli ~http ~cli =
  make_internal ~version:`V2 ~declared_http ~excluded_http ~declared_cli ~http ~cli
let to_json receipt =
  match walk_to_yojson receipt.walk,receipt.observations with
  | json,None -> json
  | `Assoc fields,Some observations -> `Assoc
      (("response_observations",response_observations_to_yojson observations)
       :: List.map (fun (key,value) -> key,if key="version" then `Int 2 else value) fields)
  | _,Some _ -> invalid_arg "original walk encoding must be an object"
let of_json json =
  let* walk,observations=match json with
    | `Assoc fields -> (match List.assoc_opt "version" fields with
      | Some (`Int 1) -> let* walk=walk_of_yojson json in Ok (walk,None)
      | Some (`Int 2) ->
        let* encoded=Option.to_result ~none:"missing response observations" (List.assoc_opt "response_observations" fields) in
        let* observations=response_observations_of_yojson encoded in
        let v1=`Assoc (List.filter_map (fun (key,value) ->
          if key="response_observations" then None
          else Some (key,if key="version" then `Int 1 else value)) fields) in
        let* walk=walk_of_yojson v1 in Ok (walk,Some observations)
      | Some _ | None -> Error "unknown original walk version")
    | _ -> Error "original walk evidence must be an object" in
  let value={walk;observations} in
  let* original=Lane_addon_action.canonical json in
  let* encoded=Lane_addon_action.canonical (to_json value) in
  let* ()=check (original=encoded) "unknown or noncanonical original walk evidence" in
  let* ()=validate walk in
  let* ()=match observations with None -> Ok () | Some observations -> validate_observations walk observations in
  Ok value
