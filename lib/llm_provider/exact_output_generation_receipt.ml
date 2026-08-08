module Exec = Exact_output_execution
module Trace = Exact_output_provider_trace

type call_id = Call_id of string
type provider_trace = Trace.t

type terminal_state =
  { status : int
  ; provider_trace : provider_trace option
  }

(* A response-received receipt carries a provider trace for the same reason a
   terminal one does: the trace is evidence about the response that arrived, and an
   error can be raised after the response without the attempt reaching Terminal.
   test_exact_output_single_surface's "response-received error evidence" case pins
   that shape — status Some 200, a typed cause, and a present trace — and it could
   not hold while this state had nowhere to put one. *)
type response_received_state =
  { status : int option
  ; provider_trace : provider_trace option
  }

type state =
  | Not_started_state
  | Before_dispatch_state
  | Dispatch_started_state
  | Response_received_state of response_received_state
  | Terminal_state of terminal_state

type effect_phase =
  | Not_started
  | Before_dispatch
  | Dispatch_started
  | Response_received
  | Terminal

type t =
  { state : state Atomic.t
  ; call_id : call_id
  ; plan_fingerprint : string
  ; request_body_sha256 : string
  ; catalog_generation : Exact_output_resolver.catalog_generation
  ; catalog_evidence : Exact_output_resolver.catalog_evidence
  ; target_identity : Exact_output_resolver.target_identity
  }

type snapshot =
  { phase : effect_phase
  ; dispatch_count : int
  ; http_status : int option
  ; provider_trace : provider_trace option
  ; call_id : call_id
  ; plan_fingerprint : string
  ; request_body_sha256 : string
  ; catalog_generation : Exact_output_resolver.catalog_generation
  ; catalog_evidence : Exact_output_resolver.catalog_evidence
  ; target_identity : Exact_output_resolver.target_identity
  }

let create
      ~call_id
      ~plan_fingerprint
      ~request_body_sha256
      ~catalog_generation
      ~catalog_evidence
      ~target_identity
  =
  { state = Atomic.make Not_started_state
  ; call_id
  ; plan_fingerprint
  ; request_body_sha256
  ; catalog_generation
  ; catalog_evidence
  ; target_identity
  }
;;

let try_start receipt =
  Atomic.compare_and_set receipt.state Not_started_state Before_dispatch_state
;;

let call_id (receipt : t) = receipt.call_id

let phase receipt =
  match Atomic.get receipt.state with
  | Not_started_state -> Not_started
  | Before_dispatch_state -> Before_dispatch
  | Dispatch_started_state -> Dispatch_started
  | Response_received_state _ -> Response_received
  | Terminal_state _ -> Terminal
;;

let dispatch_count receipt =
  match Atomic.get receipt.state with
  | Not_started_state | Before_dispatch_state -> 0
  | Dispatch_started_state | Response_received_state _ | Terminal_state _ -> 1
;;

let generation_dispatched receipt = dispatch_count receipt = 1

let http_status receipt =
  match Atomic.get receipt.state with
  | Response_received_state received -> received.status
  | Terminal_state terminal -> Some terminal.status
  | Not_started_state | Before_dispatch_state | Dispatch_started_state -> None
;;

let provider_trace receipt =
  match Atomic.get receipt.state with
  | Terminal_state terminal -> terminal.provider_trace
  | Response_received_state received -> received.provider_trace
  | Not_started_state | Before_dispatch_state | Dispatch_started_state -> None
;;

let plan_fingerprint (receipt : t) = receipt.plan_fingerprint
let request_body_sha256 (receipt : t) = receipt.request_body_sha256
let catalog_generation (receipt : t) = receipt.catalog_generation
let catalog_evidence (receipt : t) = receipt.catalog_evidence
let target_identity (receipt : t) = receipt.target_identity

let state_rank = function
  | Not_started_state -> 0
  | Before_dispatch_state -> 1
  | Dispatch_started_state -> 2
  | Response_received_state _ -> 3
  | Terminal_state _ -> 4
;;

type response_evidence_field =
  | Http_status_field
  | Provider_trace_field

exception Conflicting_response_evidence of response_evidence_field

let merge_optional ~field ~equal current incoming =
  match current, incoming with
  | None, None -> None
  | Some value, None | None, Some value -> Some value
  | Some current, Some incoming ->
    if equal current incoming
    then Some current
    else raise (Conflicting_response_evidence field)
;;

let merge_response_fields (current_status, current_trace) (incoming_status, incoming_trace)
  =
  ( merge_optional ~field:Http_status_field ~equal:Int.equal current_status incoming_status
  , merge_optional
      ~field:Provider_trace_field
      ~equal:Trace.equal
      current_trace
      incoming_trace )
;;

let state_equal left right =
  match left, right with
  | Not_started_state, Not_started_state
  | Before_dispatch_state, Before_dispatch_state
  | Dispatch_started_state, Dispatch_started_state -> true
  | Response_received_state left, Response_received_state right ->
    Option.equal Int.equal left.status right.status
    && Option.equal Trace.equal left.provider_trace right.provider_trace
  | Terminal_state left, Terminal_state right ->
    Int.equal left.status right.status
    && Option.equal Trace.equal left.provider_trace right.provider_trace
  | _ -> false
;;

(* The state shape comes from the higher rank, while response knowledge is an
   immutable join. This keeps a trace observed before status, a status observed
   before trace, and both fields when Response_received is promoted to Terminal. *)
let merge_state current desired =
  match current, desired with
  | Response_received_state current, Response_received_state desired ->
    let status, provider_trace =
      merge_response_fields
        (current.status, current.provider_trace)
        (desired.status, desired.provider_trace)
    in
    Response_received_state { status; provider_trace }
  | Response_received_state current, Terminal_state desired ->
    let status, provider_trace =
      merge_response_fields
        (current.status, current.provider_trace)
        (Some desired.status, desired.provider_trace)
    in
    Terminal_state { status = Option.get status; provider_trace }
  | Terminal_state current, Terminal_state desired ->
    let status, provider_trace =
      merge_response_fields
        (Some current.status, current.provider_trace)
        (Some desired.status, desired.provider_trace)
    in
    Terminal_state { status = Option.get status; provider_trace }
  | _ -> desired
;;

let rec advance_atomic
          ?(before_compare_and_set = fun () -> ())
          ~rank
          ~merge
          ~equal
          state
          desired
  =
  let current = Atomic.get state in
  if rank desired >= rank current
  then (
    let merged = merge current desired in
    if not (equal current merged)
    then (
      before_compare_and_set ();
      if not (Atomic.compare_and_set state current merged)
      then advance_atomic ~before_compare_and_set ~rank ~merge ~equal state desired))
;;

let advance receipt desired =
  advance_atomic
    ~rank:state_rank
    ~merge:merge_state
    ~equal:state_equal
    receipt.state
    desired
;;

let%test "conflicting same-attempt response evidence fails closed" =
  match
    try
      ignore (merge_response_fields (Some 200, None) (Some 503, None));
      None
    with
    | Conflicting_response_evidence field -> Some field
  with
  | Some Http_status_field -> true
  | Some Provider_trace_field | None -> false
;;

let%test "same-rank receipt evidence joins in either order" =
  let empty = Response_received_state { status = None; provider_trace = None } in
  let status = Response_received_state { status = Some 200; provider_trace = None } in
  let converge desired =
    let state = Atomic.make empty in
    List.iter
      (advance_atomic ~rank:state_rank ~merge:merge_state ~equal:state_equal state)
      desired;
    Atomic.get state
  in
  state_equal (converge [ empty; status ]) status
  && state_equal (converge [ status; empty ]) status
;;

let%test "receipt CAS retry converges after competing rank promotion" =
  let state = Atomic.make Dispatch_started_state in
  let competed = ref false in
  let before_compare_and_set () =
    if not !competed
    then (
      competed := true;
      advance_atomic
        ~rank:state_rank
        ~merge:merge_state
        ~equal:state_equal
        state
        (Response_received_state { status = Some 200; provider_trace = None }))
  in
  advance_atomic
    ~before_compare_and_set
    ~rank:state_rank
    ~merge:merge_state
    ~equal:state_equal
    state
    (Terminal_state { status = 200; provider_trace = None });
  !competed
  &&
  match Atomic.get state with
  | Terminal_state { status = 200; provider_trace = None } -> true
  | Not_started_state
  | Before_dispatch_state
  | Dispatch_started_state
  | Response_received_state _
  | Terminal_state _ -> false
;;

let observe_phase receipt = function
  | Http_client_phase_observer.Dispatch_started -> advance receipt Dispatch_started_state
  | Http_client_phase_observer.Response_received status ->
    advance
      receipt
      (Response_received_state { status = Some status; provider_trace = None })
;;

let synchronize receipt complete_receipt =
  match Exec.receipt_phase complete_receipt with
  | Exec.Before_dispatch -> advance receipt Before_dispatch_state
  | Exec.Dispatch_started -> advance receipt Dispatch_started_state
  | Exec.Response_received ->
    advance
      receipt
      (Response_received_state
         { status = Exec.receipt_http_status complete_receipt; provider_trace = None })
  | Exec.Terminal ->
    (match Exec.receipt_http_status complete_receipt with
     | Some status -> advance receipt (Terminal_state { status; provider_trace = None })
     | None -> invalid_arg "Exact_output: terminal receipt without HTTP status")
;;

let rec record_provider_trace receipt provider_trace =
  let current = Atomic.get receipt.state in
  match current with
  | Terminal_state ({ provider_trace = None; _ } as terminal) ->
    let desired = Terminal_state { terminal with provider_trace = Some provider_trace } in
    if not (Atomic.compare_and_set receipt.state current desired)
    then record_provider_trace receipt provider_trace
  | Terminal_state { provider_trace = Some recorded; _ } ->
    if not (Trace.equal recorded provider_trace)
    then raise (Conflicting_response_evidence Provider_trace_field)
  | Response_received_state ({ provider_trace = None; _ } as received) ->
    let desired =
      Response_received_state { received with provider_trace = Some provider_trace }
    in
    if not (Atomic.compare_and_set receipt.state current desired)
    then record_provider_trace receipt provider_trace
  | Response_received_state { provider_trace = Some recorded; _ } ->
    if not (Trace.equal recorded provider_trace)
    then raise (Conflicting_response_evidence Provider_trace_field)
  | Not_started_state | Before_dispatch_state | Dispatch_started_state ->
    invalid_arg "Exact_output: provider trace before response is received"
;;

let snapshot receipt =
  let state = Atomic.get receipt.state in
  let phase, dispatch_count, http_status, provider_trace =
    match state with
    | Not_started_state -> Not_started, 0, None, None
    | Before_dispatch_state -> Before_dispatch, 0, None, None
    | Dispatch_started_state -> Dispatch_started, 1, None, None
    | Response_received_state received ->
      Response_received, 1, received.status, received.provider_trace
    | Terminal_state terminal ->
      Terminal, 1, Some terminal.status, terminal.provider_trace
  in
  { phase
  ; dispatch_count
  ; http_status
  ; provider_trace
  ; call_id = receipt.call_id
  ; plan_fingerprint = receipt.plan_fingerprint
  ; request_body_sha256 = receipt.request_body_sha256
  ; catalog_generation = receipt.catalog_generation
  ; catalog_evidence = receipt.catalog_evidence
  ; target_identity = receipt.target_identity
  }
;;

let snapshot_phase (snapshot : snapshot) = snapshot.phase
let snapshot_dispatch_count (snapshot : snapshot) = snapshot.dispatch_count
let snapshot_http_status (snapshot : snapshot) = snapshot.http_status
let snapshot_provider_trace (snapshot : snapshot) = snapshot.provider_trace
let snapshot_call_id (snapshot : snapshot) = snapshot.call_id
let snapshot_plan_fingerprint (snapshot : snapshot) = snapshot.plan_fingerprint
let snapshot_request_body_sha256 (snapshot : snapshot) = snapshot.request_body_sha256
let snapshot_catalog_generation (snapshot : snapshot) = snapshot.catalog_generation
let snapshot_catalog_evidence (snapshot : snapshot) = snapshot.catalog_evidence
let snapshot_target_identity (snapshot : snapshot) = snapshot.target_identity
