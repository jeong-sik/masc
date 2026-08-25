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
        ] )
    ; ( "custom"
      , [ test_case "recording tracer" `Quick test_custom_tracer
        ; test_case "trace context headers" `Quick test_trace_context_headers
        ] )
    ; "coverage", [ test_case "all span_kind variants" `Quick test_span_kind_coverage ]
    ]
;;
