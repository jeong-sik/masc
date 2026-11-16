(** Tests for tracing.ml -- TRACER module type and built-in implementations *)

open Alcotest
open Agent_core

let test_null_tracer_no_op () =
  let open Tracing.Null_tracer in
  let span =
    start_span
      { kind = Agent_run
      ; name = "test"
      ; agent_name = "a"
      ; turn = 0
      ; extra = []
      ; links = []
      }
  in
  add_event span "msg";
  add_attrs span [ "k", "v" ];
  end_span span ~ok:true;
  check pass "null_tracer completes without error" () ()
;;

let test_null_tracer_false_ok () =
  let open Tracing.Null_tracer in
  let span =
    start_span
      { kind = Api_call
      ; name = "call"
      ; agent_name = "a"
      ; turn = 1
      ; extra = []
      ; links = []
      }
  in
  end_span span ~ok:false;
  check pass "null_tracer end_span ok:false succeeds" () ()
;;

let test_fmt_tracer_outputs () =
  let buf = Buffer.create 256 in
  (* Save original err_formatter output functions *)
  let orig_out, orig_flush =
    Format.pp_get_formatter_output_functions Format.err_formatter ()
  in
  (* Redirect err_formatter to buffer *)
  Format.pp_set_formatter_output_functions
    Format.err_formatter
    (fun s ofs len -> Buffer.add_substring buf s ofs len)
    (fun () -> ());
  let module T = (val Tracing.fmt : Tracing.TRACER) in
  let span =
    T.start_span
      { kind = Tool_exec
      ; name = "grep"
      ; agent_name = "searcher"
      ; turn = 2
      ; extra = []
      ; links = []
      }
  in
  T.add_event span "found 3 results";
  T.add_attrs span [ "count", "3" ];
  T.end_span span ~ok:true;
  (* Restore original err_formatter *)
  Format.pp_set_formatter_output_functions Format.err_formatter orig_out orig_flush;
  let output = Buffer.contents buf in
  check
    bool
    "output contains [TRACE]"
    true
    (String.length output > 0
     &&
     try
       let _ = Str.search_forward (Str.regexp_string "[TRACE]") output 0 in
       true
     with
     | Not_found -> false)
;;

let test_with_span_success () =
  let result =
    Tracing.with_span
      Tracing.null
      { kind = Agent_run
      ; name = "run"
      ; agent_name = "a"
      ; turn = 0
      ; extra = []
      ; links = []
      }
      (fun _tracer -> 42)
  in
  check int "with_span returns function result" 42 result
;;

let test_with_span_exception () =
  let raised = ref false in
  (try
     let _ =
       Tracing.with_span
         Tracing.null
         { kind = Agent_run
         ; name = "fail"
         ; agent_name = "a"
         ; turn = 0
         ; extra = []
         ; links = []
         }
         (fun _tracer -> failwith "boom")
     in
     ()
   with
   | Failure msg ->
     raised := true;
     check string "exception message preserved" "boom" msg);
  check bool "exception was re-raised" true !raised
;;

(** Custom recording tracer to verify the module type contract. *)
module Recording_tracer : sig
  include Tracing.TRACER

  val events : unit -> string list
  val reset : unit -> unit
end = struct
  type span = { span_name : string }

  let log : string list ref = ref []

  let start_span (attrs : Tracing.span_attrs) =
    log := Printf.sprintf "start:%s" attrs.name :: !log;
    { span_name = attrs.name }
  ;;

  let end_span span ~ok = log := Printf.sprintf "end:%s:ok=%b" span.span_name ok :: !log
  let add_event span msg = log := Printf.sprintf "event:%s:%s" span.span_name msg :: !log

  let add_attrs span kvs =
    List.iter
      (fun (k, v) -> log := Printf.sprintf "attr:%s:%s=%s" span.span_name k v :: !log)
      kvs
  ;;

  let add_link span ~trace_id ~span_id =
    log := Printf.sprintf "link:%s:%s:%s" span.span_name trace_id span_id :: !log
  ;;

  let trace_id _span = None
  let span_id _span = None
  let trace_context_headers () = [ "traceparent", "00-test-test-01" ]

  let with_span attrs f =
    let span = start_span attrs in
    match f () with
    | result ->
      end_span span ~ok:true;
      result
    | exception exn ->
      end_span span ~ok:false;
      raise exn
  ;;

  let events () = List.rev !log
  let reset () = log := []
end

let test_custom_tracer () =
  Recording_tracer.reset ();
  let span =
    Recording_tracer.start_span
      { kind = Hook_invoke
      ; name = "custom"
      ; agent_name = "x"
      ; turn = 0
      ; extra = []
      ; links = []
      }
  in
  Recording_tracer.add_event span "hi";
  Recording_tracer.add_attrs span [ "a", "1" ];
  Recording_tracer.end_span span ~ok:true;
  let evts = Recording_tracer.events () in
  check int "4 events recorded" 4 (List.length evts);
  check string "first is start" "start:custom" (List.nth evts 0);
  check string "second is event" "event:custom:hi" (List.nth evts 1);
  check string "third is attr" "attr:custom:a=1" (List.nth evts 2);
  check string "fourth is end" "end:custom:ok=true" (List.nth evts 3)
;;

let test_trace_context_headers () =
  check
    (list (pair string string))
    "null has no trace headers"
    []
    (Tracing.trace_context_headers Tracing.null);
  check
    (list (pair string string))
    "custom headers"
    [ "traceparent", "00-test-test-01" ]
    (Tracing.trace_context_headers (module Recording_tracer))
;;

let test_span_kind_coverage () =
  let kinds = Tracing.[ Agent_run; Api_call; Tool_exec; Hook_invoke ] in
  List.iteri
    (fun i kind ->
       let result =
         Tracing.with_span
           Tracing.null
           { kind
           ; name = Printf.sprintf "kind_%d" i
           ; agent_name = "a"
           ; turn = 0
           ; extra = []
           ; links = []
           }
           (fun _tracer -> i)
       in
       check int (Printf.sprintf "kind %d returns correctly" i) i result)
    kinds
;;

let test_with_span_exception_ends_span () =
  Recording_tracer.reset ();
  let tracer : Tracing.t = (module Recording_tracer) in
  (try
     let _ =
       Tracing.with_span
         tracer
         { kind = Api_call
         ; name = "err"
         ; agent_name = "a"
         ; turn = 0
         ; extra = []
         ; links = []
         }
         (fun _tracer -> failwith "oops")
     in
     ()
   with
   | Failure _ -> ());
  let evts = Recording_tracer.events () in
  check int "2 events (start + end)" 2 (List.length evts);
  check string "start recorded" "start:err" (List.nth evts 0);
  check string "end with ok=false" "end:err:ok=false" (List.nth evts 1)
;;

let observer_failure_attrs : Tracing.span_attrs =
  { kind = Tool_exec
  ; name = "observer-failure"
  ; agent_name = "tracing-test"
  ; turn = 0
  ; extra = []
  ; links = []
  }
;;

(* Close only this test's descriptor. The real Fmt tracer still writes through
   Format.err_formatter, whose previous output functions are always restored. *)
let with_private_fmt_channel f =
  let saved = Format.pp_get_formatter_out_functions Format.err_formatter () in
  let channel = Unix.out_channel_of_descr (Unix.dup Unix.stderr) in
  Format.pp_set_formatter_out_channel Format.err_formatter channel;
  Fun.protect
    ~finally:(fun () ->
      Format.pp_set_formatter_out_functions Format.err_formatter saved;
      close_out_noerr channel)
    (fun () -> f (fun () -> close_out_noerr channel))
;;

let test_fmt_start_failure_runs_body_once () =
  with_private_fmt_channel (fun close_output ->
    close_output ();
    let effects = ref 0 in
    let result =
      Tracing.with_span Tracing.fmt observer_failure_attrs (fun _ ->
        incr effects;
        42)
    in
    check int "operation survives failed span start" 42 result;
    check int "operation executed once" 1 !effects)
;;

let test_fmt_finish_failure_preserves_result () =
  with_private_fmt_channel (fun close_output ->
    let effects = ref 0 in
    let result =
      Tracing.with_span Tracing.fmt observer_failure_attrs (fun _ ->
        incr effects;
        close_output ();
        42)
    in
    check int "operation result survives failed span finish" 42 result;
    check int "completed effect is not replayed" 1 !effects)
;;

let first_backtrace_location backtrace =
  check bool "body backtrace is available" true
    (Printexc.raw_backtrace_length backtrace > 0);
  let slot = Printexc.get_raw_backtrace_slot backtrace 0 in
  match Printexc.Slot.location (Printexc.convert_raw_backtrace_slot slot) with
  | Some location -> location
  | None -> fail "body raise location was not recorded"
;;

let test_fmt_finish_failure_preserves_body_exception () =
  let was_recording = Printexc.backtrace_status () in
  Printexc.record_backtrace true;
  Fun.protect
    ~finally:(fun () -> Printexc.record_backtrace was_recording)
    (fun () ->
      with_private_fmt_channel (fun close_output ->
        let effects = ref 0 in
        let original = Failure "body-failure" in
        let origin = ref None in
        match
          Tracing.with_span Tracing.fmt observer_failure_attrs (fun _ ->
            incr effects;
            close_output ();
            try raise original with
            | exn ->
              let backtrace = Printexc.get_raw_backtrace () in
              origin := Some (first_backtrace_location backtrace);
              Printexc.raise_with_backtrace exn backtrace)
        with
        | _ -> fail "body exception was swallowed"
        | exception observed ->
          let backtrace = Printexc.get_raw_backtrace () in
          check bool "original exception object survives failed finish" true
            (observed == original);
          check int "failed effect is not replayed" 1 !effects;
          check bool "original raise location survives failed finish" true
            (Some (first_backtrace_location backtrace) = !origin)))
;;

let test_trace_context_failure_is_optional () =
  let module Failing_context = struct
    include Tracing.Null_tracer
    let trace_context_headers () = raise (Sys_error "trace context unavailable")
  end
  in
  check (list (pair string string)) "failed observation adds no trace headers" []
    (Tracing.trace_context_headers (module Failing_context))
;;

let test_tracer_control_exceptions_propagate () =
  let effects = ref 0 in
  let module Interrupted_start = struct
    include Tracing.Null_tracer
    let with_span _attrs _f = raise Sys.Break
  end
  in
  check_raises "reserved start failure does not enter the body" Sys.Break
    (fun () ->
      ignore (Tracing.with_span (module Interrupted_start) observer_failure_attrs
        (fun _ -> incr effects)));
  check int "interrupted start executed no effect" 0 !effects;
  let module Interrupted_finish = struct
    include Tracing.Null_tracer
    let with_span _attrs f =
      ignore (f ());
      raise Sys.Break
  end
  in
  check_raises "reserved finish failure still propagates" Sys.Break
    (fun () ->
      ignore (Tracing.with_span (module Interrupted_finish) observer_failure_attrs
        (fun _ -> incr effects)));
  check int "interrupted finish does not replay the effect" 1 !effects;
  let module Interrupted_context = struct
    include Tracing.Null_tracer
    let trace_context_headers () = raise Sys.Break
  end
  in
  check_raises "reserved context failure is not converted to missing context" Sys.Break
    (fun () -> ignore (Tracing.trace_context_headers (module Interrupted_context)))
;;

let cleanup_failure_tracer ~before_body failure : Tracing.t =
  let module Failing_cleanup = struct
    include Tracing.Null_tracer
    let with_span _attrs f =
      if before_body then raise failure
      else Fun.protect ~finally:(fun () -> raise failure) f
    let trace_context_headers () = raise failure
  end
  in
  (module Failing_cleanup)
;;

let test_wrapped_control_exceptions_propagate () =
  let backtrace = Printexc.get_callstack 0 in
  let cancellation = Eio.Cancel.Cancelled (Failure "cancelled test scope") in
  let wrapped =
    [ "cleanup interrupt", Fun.Finally_raised Sys.Break
    ; "cleanup cancellation", Fun.Finally_raised cancellation
    ; ( "parallel mixed cancellation"
      , Eio.Exn.Multiple
          [ Failure "other observer error", backtrace
          ; cancellation, backtrace
          ] )
    ]
  in
  List.iter
    (fun (label, failure) ->
      let effects = ref 0 in
      let before = cleanup_failure_tracer ~before_body:true failure in
      check_raises (label ^ " before entry") failure (fun () ->
        ignore (Tracing.with_span before observer_failure_attrs (fun _ -> incr effects)));
      check int "wrapped control did not start the body" 0 !effects;
      let after = cleanup_failure_tracer ~before_body:false failure in
      check_raises (label ^ " after success") (Fun.Finally_raised failure)
        (fun () ->
          ignore (Tracing.with_span after observer_failure_attrs (fun _ -> incr effects)));
      check int "wrapped control did not replay a completed effect" 1 !effects;
      check_raises (label ^ " after a body failure") (Fun.Finally_raised failure)
        (fun () ->
          ignore (Tracing.with_span after observer_failure_attrs (fun _ ->
            incr effects;
            failwith "original body error")));
      check int "wrapped control did not replay a failed effect" 2 !effects;
      check_raises (label ^ " during context observation") failure
        (fun () -> ignore (Tracing.trace_context_headers before)))
    wrapped
;;

let test_ordinary_cleanup_failure_remains_diagnostic () =
  let tracer = cleanup_failure_tracer ~before_body:false
      (Failure "ordinary observer failure") in
  let effects = ref 0 in
  let result = Tracing.with_span tracer observer_failure_attrs (fun _ -> incr effects; 42) in
  check int "ordinary cleanup failure preserves the value" 42 result;
  let original = Failure "body error survives ordinary cleanup failure" in
  (match Tracing.with_span tracer observer_failure_attrs (fun _ -> incr effects; raise original) with
   | _ -> fail "ordinary cleanup failure swallowed the body error"
   | exception observed -> check bool "original body exception" true (observed == original));
  check int "neither effect was replayed" 2 !effects
;;

let () =
  run
    "Tracing"
    [ ( "null_tracer"
      , [ test_case "no-op operations" `Quick test_null_tracer_no_op
        ; test_case "end_span ok:false" `Quick test_null_tracer_false_ok
        ] )
    ; "fmt_tracer", [ test_case "outputs to stderr" `Quick test_fmt_tracer_outputs ]
    ; ( "with_span"
      , [ test_case "success path" `Quick test_with_span_success
        ; test_case "exception path" `Quick test_with_span_exception
        ; test_case "exception ends span" `Quick test_with_span_exception_ends_span
        ; test_case "Fmt start failure runs the operation once" `Quick
            test_fmt_start_failure_runs_body_once
        ; test_case "Fmt finish failure preserves the operation result" `Quick
            test_fmt_finish_failure_preserves_result
        ; test_case "Fmt finish failure preserves the body exception and origin" `Quick
            test_fmt_finish_failure_preserves_body_exception
        ; test_case "tracer control exceptions propagate" `Quick
            test_tracer_control_exceptions_propagate
        ; test_case "wrapped tracer controls propagate through cleanup" `Quick
            test_wrapped_control_exceptions_propagate
        ; test_case "ordinary cleanup failure remains diagnostic" `Quick
            test_ordinary_cleanup_failure_remains_diagnostic
        ] )
    ; ( "custom"
      , [ test_case "recording tracer" `Quick test_custom_tracer
        ; test_case "trace context headers" `Quick test_trace_context_headers
        ; test_case "trace context failure remains optional" `Quick
            test_trace_context_failure_is_optional
        ] )
    ; "coverage", [ test_case "all span_kind variants" `Quick test_span_kind_coverage ]
    ]
;;
