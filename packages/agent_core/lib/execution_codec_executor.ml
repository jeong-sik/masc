module Event = Execution_event

type operation =
  | Encode_events
  | Decode_canonical_event
  | Compare_canonical_payload
[@@deriving show]

type captured_exception =
  { exception_ : exn
  ; backtrace : Printexc.raw_backtrace option
  }

type cause =
  { primary : captured_exception
  ; observation_failure : captured_exception option
  }

type failure =
  | Executor_unavailable of
      { operation : operation
      ; cause : cause
      }
  | Codec_raised of
      { operation : operation
      ; cause : cause
      }

type decode_failure =
  | Invalid_event of { detail : string }
  | Noncanonical_event

type operation_stats =
  { requested : int
  ; started : int
  ; completed : int
  ; job_failed : int
  ; worker_cancelled : int
  ; executor_failed : int
  ; caller_cancelled : int
  ; last_caller_domain : Domain.id option
  ; last_worker_domain : Domain.id option
  }

type observation = operation_stats Atomic.t

type t =
  { runtime : Execution_runtime.t
  ; encode_events : observation
  ; decode_canonical_event : observation
  ; compare_canonical_payload : observation
  }

type stats =
  { encode_events : operation_stats
  ; decode_canonical_event : operation_stats
  ; compare_canonical_payload : operation_stats
  }

type _ request =
  | Encode_events_request : Event.t list -> string list request
  | Decode_canonical_event_request : string -> (Event.t, decode_failure) result request
  | Compare_canonical_payload_request :
      { expected : string
      ; actual : string
      }
      -> bool request

type 'a job_outcome =
  | Job_completed of 'a
  | Job_raised of cause
  | Job_cancelled of cause

let empty_stats =
  { requested = 0
  ; started = 0
  ; completed = 0
  ; job_failed = 0
  ; worker_cancelled = 0
  ; executor_failed = 0
  ; caller_cancelled = 0
  ; last_caller_domain = None
  ; last_worker_domain = None
  }
;;

let of_runtime runtime =
  { runtime
  ; encode_events = Atomic.make empty_stats
  ; decode_canonical_event = Atomic.make empty_stats
  ; compare_canonical_payload = Atomic.make empty_stats
  }
;;

let operation : type result. result request -> operation = function
  | Encode_events_request _ -> Encode_events
  | Decode_canonical_event_request _ -> Decode_canonical_event
  | Compare_canonical_payload_request _ -> Compare_canonical_payload
;;

let observation (t : t) = function
  | Encode_events -> t.encode_events
  | Decode_canonical_event -> t.decode_canonical_event
  | Compare_canonical_payload -> t.compare_canonical_payload
;;

let rec update observation f =
  let current = Atomic.get observation in
  let next = f current in
  if not (Atomic.compare_and_set observation current next) then update observation f
;;

let check_worker_cancellation t = Execution_runtime.Private.check_cancellation t.runtime

let encode_events t events =
  let rec loop encoded_rev = function
    | [] ->
      check_worker_cancellation t;
      List.rev encoded_rev
    | event :: rest ->
      check_worker_cancellation t;
      let payload = Event.to_json_string event in
      loop (payload :: encoded_rev) rest
  in
  loop [] events
;;

let decode_canonical_event t payload =
  check_worker_cancellation t;
  match Event.of_json_string payload with
  | Error detail -> Error (Invalid_event { detail })
  | Ok event ->
    check_worker_cancellation t;
    if String.equal payload (Event.to_json_string event)
    then Ok event
    else Error Noncanonical_event
;;

let compare_canonical_payload t ~expected ~actual =
  check_worker_cancellation t;
  let identical = String.equal expected actual in
  check_worker_cancellation t;
  identical
;;

let execute : type result. t -> result request -> result =
  fun t -> function
  | Encode_events_request events -> encode_events t events
  | Decode_canonical_event_request payload -> decode_canonical_event t payload
  | Compare_canonical_payload_request { expected; actual } ->
    compare_canonical_payload t ~expected ~actual
;;

let captured_exception ?backtrace exception_ = { exception_; backtrace }

let cause ?backtrace exception_ =
  { primary = captured_exception ?backtrace exception_; observation_failure = None }
;;

let reraise_captured_fatal { exception_; backtrace } =
  let backtrace = Option.value ~default:(Printexc.get_raw_backtrace ()) backtrace in
  match exception_ with
  | Out_of_memory | Stack_overflow | Sys.Break ->
    Printexc.raise_with_backtrace exception_ backtrace
  | _ -> ()
;;

let reraise_fatal cause =
  reraise_captured_fatal cause.primary;
  Option.iter reraise_captured_fatal cause.observation_failure
;;

let cause_of_runtime_failure
      ({ exception_; backtrace } : Execution_runtime.Private.run_failure)
  =
  cause ?backtrace exception_
;;

let record_terminal observation update_stats primary =
  match update observation update_stats with
  | () -> { primary; observation_failure = None }
  | exception exn ->
    let backtrace = Printexc.get_raw_backtrace () in
    { primary; observation_failure = Some (captured_exception ~backtrace exn) }
;;

let record_job_failure observation primary =
  record_terminal
    observation
    (fun stats -> { stats with job_failed = stats.job_failed + 1 })
    primary
;;

let record_worker_cancellation observation primary =
  record_terminal
    observation
    (fun stats -> { stats with worker_cancelled = stats.worker_cancelled + 1 })
    primary
;;

let record_caller_cancelled observation =
  update observation (fun stats ->
    { stats with caller_cancelled = stats.caller_cancelled + 1 })
;;

let propagate_caller_cancellation observation exn backtrace =
  record_caller_cancelled observation;
  Printexc.raise_with_backtrace exn backtrace
;;

let check_caller_cancellation observation =
  match Eio.Fiber.check () with
  | () -> ()
  | exception (Eio.Cancel.Cancelled _ as exn) ->
    let backtrace = Printexc.get_raw_backtrace () in
    propagate_caller_cancellation observation exn backtrace
;;

let submit : type value. t -> value request -> (value, failure) Stdlib.result =
  fun t request ->
  let operation = operation request in
  let observation = observation t operation in
  update observation (fun stats ->
    { stats with
      requested = stats.requested + 1
    ; last_caller_domain = Some (Domain.self ())
    });
  match
    Execution_runtime.Private.run_cpu t.runtime (fun () ->
      try
        update observation (fun stats ->
          { stats with
            started = stats.started + 1
          ; last_worker_domain = Some (Domain.self ())
          });
        let value = execute t request in
        check_worker_cancellation t;
        update observation (fun stats -> { stats with completed = stats.completed + 1 });
        Job_completed value
      with
      | Execution_runtime.Private.Caller_cancelled as exn ->
        let backtrace = Printexc.get_raw_backtrace () in
        let primary = captured_exception ~backtrace exn in
        let cause = record_worker_cancellation observation primary in
        reraise_fatal cause;
        Printexc.raise_with_backtrace exn backtrace
      | Execution_runtime.Private.Runtime_released as exn ->
        let backtrace = Printexc.get_raw_backtrace () in
        let primary = captured_exception ~backtrace exn in
        Job_cancelled (record_worker_cancellation observation primary)
      | Eio.Cancel.Cancelled _ as exn ->
        let backtrace = Printexc.get_raw_backtrace () in
        let primary = captured_exception ~backtrace exn in
        Job_cancelled (record_worker_cancellation observation primary)
      | exn ->
        let backtrace = Printexc.get_raw_backtrace () in
        let primary = captured_exception ~backtrace exn in
        Job_raised (record_job_failure observation primary))
  with
  | Ok (Job_completed value) ->
    check_caller_cancellation observation;
    Ok value
  | Ok (Job_raised cause) ->
    reraise_fatal cause;
    check_caller_cancellation observation;
    Error (Codec_raised { operation; cause })
  | Ok (Job_cancelled cause) ->
    reraise_fatal cause;
    check_caller_cancellation observation;
    update observation (fun stats ->
      { stats with executor_failed = stats.executor_failed + 1 });
    Error (Executor_unavailable { operation; cause })
  | Error failure ->
    let cause = cause_of_runtime_failure failure in
    reraise_fatal cause;
    check_caller_cancellation observation;
    update observation (fun stats ->
      { stats with executor_failed = stats.executor_failed + 1 });
    Error (Executor_unavailable { operation; cause })
  | exception (Execution_runtime.Private.Caller_cancelled as exn) ->
    let backtrace = Printexc.get_raw_backtrace () in
    Printexc.raise_with_backtrace exn backtrace
  | exception (Eio.Cancel.Cancelled _ as exn) ->
    let backtrace = Printexc.get_raw_backtrace () in
    propagate_caller_cancellation observation exn backtrace
  | exception exn ->
    let backtrace = Printexc.get_raw_backtrace () in
    Llm_provider.Reserved_exn.reraise_if_reserved exn;
    update observation (fun stats ->
      { stats with executor_failed = stats.executor_failed + 1 });
    Error (Executor_unavailable { operation; cause = cause ~backtrace exn })
;;

let encode_events t events = submit t (Encode_events_request events)
let decode_canonical_event t payload = submit t (Decode_canonical_event_request payload)

let compare_canonical_payload t ~expected ~actual =
  submit t (Compare_canonical_payload_request { expected; actual })
;;

let captured_exception_to_string { exception_; backtrace } =
  match backtrace with
  | None -> Printexc.to_string exception_
  | Some backtrace ->
    let rendered = Printexc.raw_backtrace_to_string backtrace in
    if String.equal rendered ""
    then Printexc.to_string exception_
    else Printexc.to_string exception_ ^ "\n" ^ rendered
;;

let cause_to_string cause =
  match cause.observation_failure with
  | None -> captured_exception_to_string cause.primary
  | Some observation_failure ->
    captured_exception_to_string cause.primary
    ^ "\nobservation failure: "
    ^ captured_exception_to_string observation_failure
;;

let failure_to_string = function
  | Executor_unavailable { operation; cause } ->
    Printf.sprintf
      "execution codec executor unavailable for %s: %s"
      (show_operation operation)
      (cause_to_string cause)
  | Codec_raised { operation; cause } ->
    Printf.sprintf
      "execution codec %s raised: %s"
      (show_operation operation)
      (cause_to_string cause)
;;

let pp_failure formatter failure =
  Format.pp_print_string formatter (failure_to_string failure)
;;

let show_failure failure = failure_to_string failure

let stats (t : t) =
  { encode_events = Atomic.get t.encode_events
  ; decode_canonical_event = Atomic.get t.decode_canonical_event
  ; compare_canonical_payload = Atomic.get t.compare_canonical_payload
  }
;;
