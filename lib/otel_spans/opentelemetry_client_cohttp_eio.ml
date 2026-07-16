open Eio.Std
module OT = Opentelemetry

module Config = struct
  include Opentelemetry_client.Config
  module Env = Opentelemetry_client.Config.Env ()

  let make = Env.make (fun common () -> common)
end

module Signal = Opentelemetry_client.Signal
module Batch = Opentelemetry_client.Batch
open Opentelemetry

let ( let@ ) = ( @@ )
let spf = Printf.sprintf
let set_headers = Config.Env.set_headers
let get_headers = Config.Env.get_headers
(* Library [Opentelemetry.GC_metrics] sampling was removed here: it emitted
   process.runtime.ocaml.gc.* series that duplicated the richer masc_gc_*
   gauges exported through Otel_metric_store (and consumed by the Grafana
   OCaml Heap / GC panels).  One signal, one name. *)

type error =
  [ `Status of int * Opentelemetry.Proto.Status.status
  | `Failure of string
  | `Sysbreak
  ]

let n_errors = Atomic.make 0
let n_dropped = Atomic.make 0

let report_err_ = function
  | `Sysbreak -> Log.Telemetry.warn "opentelemetry: ctrl-c captured, stopping"
  | `Failure msg -> Log.Telemetry.warn "opentelemetry: export failed: %s" msg
  | `Status (code, { Opentelemetry.Proto.Status.code = scode; message; details }) ->
    let details_str =
      List.map (fun s -> Bytes.unsafe_to_string s) details
      |> String.concat "; "
    in
    Log.Telemetry.warn
      "opentelemetry: export failed with http code=%d status={code=%ld; message=%S; \
       details=[%s]}"
      code
      scode
      (Bytes.unsafe_to_string message)
      details_str
;;

module Httpc : sig
  type t

  val create : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t -> t

  val send
    :  t
    -> url:string
    -> decode:[ `Dec of Pbrt.Decoder.t -> 'a | `Ret of 'a ]
    -> string
    -> ('a, error) result
end = struct
  open Opentelemetry.Proto
  module Httpc = Cohttp_eio.Client

  type https_connector =
    Uri.t
    -> [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] r
    -> [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] r

  type t =
    { net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
    ; https : https_connector option
    }

  let authenticator () =
    match Ca_certs.authenticator () with
    | Ok x -> x
    | Error (`Msg m) ->
      invalid_arg
        (Printf.sprintf "opentelemetry_client: failed to create X509 authenticator: %s" m)
  ;;

  let https ~authenticator =
    let tls_config =
      match Tls.Config.client ~authenticator () with
      | Error (`Msg msg) ->
        invalid_arg ("opentelemetry_client: tls configuration problem: " ^ msg)
      | Ok tls_config -> tls_config
    in
    fun uri raw ->
      let host =
        Uri.host uri |> Option.map (fun x -> Domain_name.(host_exn (of_string_exn x)))
      in
      Tls_eio.client_of_flow ?host tls_config raw
  ;;

  let create net =
    let authenticator = authenticator () in
    let https uri raw =
      (https ~authenticator uri raw
        :> [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] r)
    in
    { net :> [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t; https = Some https }
  ;;

  let read_body body =
    let buf = Buffer.create 4096 in
    Eio.Flow.copy body (Eio.Flow.buffer_sink buf);
    Buffer.contents buf
  ;;

  let decode_response ~url ~decode ~code body =
    (* HTTP error if status >= 400 (Cohttp.Code.is_error equivalent). *)
    if code < 400
    then (
      match decode with
      | `Ret x -> Ok x
      | `Dec f ->
        let dec = Pbrt.Decoder.of_string body in
        let r =
          try Ok (f dec) with
          | e ->
            let bt = Printexc.get_backtrace () in
            Error
              (`Failure (spf "decoding failed with:\n%s\n%s" (Printexc.to_string e) bt))
        in
        r)
    else (
      let dec = Pbrt.Decoder.of_string body in
      let r =
        try
          let status = Status.decode_pb_status dec in
          Error (`Status (code, status))
        with
        | e ->
          let bt = Printexc.get_backtrace () in
          Error
            (`Failure
                (spf
                   "httpc: decoding of status (url=%S, code=%d) failed with:\n\
                    %s\n\
                    status: %S\n\
                    %s"
                   url
                   code
                   (Printexc.to_string e)
                   body
                   bt))
      in
      r)
  ;;

  let send (client : t) ~url ~decode (body : string) : ('a, error) result =
    let headers =
      ("Content-Type", "application/x-protobuf") :: Config.Env.get_headers ()
    in
    try
      Eio.Switch.run (fun sw ->
        let http_client = Httpc.make ~https:client.https client.net in
        let response, response_body =
          Httpc.post
            http_client
            ~sw
            ~headers:(Cohttp.Header.of_list headers)
            ~body:(Cohttp_eio.Body.of_string body)
            (Uri.of_string url)
        in
        let code = Cohttp.Code.code_of_status (Cohttp.Response.status response) in
        let body = read_body response_body in
        decode_response ~url ~decode ~code body)
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | Sys.Break -> Error `Sysbreak
    | exn ->
      let bt = Printexc.get_backtrace () in
      Error
        (`Failure
           (spf
              "sending signals via http POST to %S\nfailed with:\n%s"
              url
              (Printexc.to_string exn ^ "\n" ^ bt)))
  ;;
end

module type EMITTER = sig
  open Opentelemetry.Proto

  val push_trace : Trace.resource_spans list -> unit
  val push_metrics : Metrics.resource_metrics list -> unit
  val push_logs : Logs.resource_logs list -> unit
  val set_on_tick_callbacks : (unit -> unit) AList.t -> unit
  val tick : unit -> unit
  val cleanup : on_done:(unit -> unit) -> unit -> unit
end

let mk_emitter ~stop ~clock ~net (config : Config.t) : (module EMITTER) =
  let open struct
    let client =
      Crypto_rng.ensure_default ();
      Httpc.create net
    ;;

    let send_http ~url data : unit =
      let r = Httpc.send client ~url ~decode:(`Ret ()) data in
      match r with
      | Ok () -> ()
      | Error `Sysbreak ->
        Log.Telemetry.warn "opentelemetry: ctrl-c captured, stopping";
        Atomic.set stop true
      | Error err ->
        Atomic.incr n_errors;
        report_err_ err;
        Eio.Time.sleep clock 3.
    ;;

    let timeout =
      if config.batch_timeout_ms > 0
      then Some Mtime.Span.(config.batch_timeout_ms * ms)
      else None
    ;;

    let batch_traces : Proto.Trace.resource_spans Batch.t =
      Batch.make ?batch:config.batch_traces ?timeout ()
    ;;

    let batch_metrics : Proto.Metrics.resource_metrics Batch.t =
      Batch.make ?batch:config.batch_metrics ?timeout ()
    ;;

    let batch_logs : Proto.Logs.resource_logs Batch.t =
      Batch.make ?batch:config.batch_logs ?timeout ()
    ;;

    let push_to_batch b e =
      match Batch.push b e with
      | `Ok -> ()
      | `Dropped -> Atomic.incr n_errors
    ;;

    let[@inline] guard_exn_ where f =
      try f () with
      | e ->
        let bt = Printexc.get_backtrace () in
        Log.Telemetry.warn
          "opentelemetry-eio: uncaught exception in %s: %s\n%s"
          where
          (Printexc.to_string e)
          bt
    ;;

    let push_traces x =
      let@ () = guard_exn_ "push trace" in
      push_to_batch batch_traces x
    ;;

    let push_metrics x =
      let@ () = guard_exn_ "push metrics" in
      push_to_batch batch_metrics x
    ;;

    let push_logs x =
      let@ () = guard_exn_ "push logs" in
      push_to_batch batch_logs x
    ;;

    let maybe_emit (batch : 'a Batch.t) url (f : 'a list -> string) ~now ~force () : unit =
      Batch.pop_if_ready ~force ~now batch
      |> Option.iter (fun signals -> f signals |> send_http ~url)
    ;;

    let emit_traces_maybe = maybe_emit batch_traces config.url_traces Signal.Encode.traces

    let emit_metrics_maybe = maybe_emit batch_metrics config.url_metrics Signal.Encode.metrics

    let emit_logs_maybe = maybe_emit batch_logs config.url_logs Signal.Encode.logs

    let emit_all ~force : unit =
      (* Sequential emit: avoids Eio.Cancel propagation through Switch.run
         that can race Eio.Mutex.use_rw ~protect:true cleanup.
         Each emit is independent HTTP POST; parallelism is unnecessary here.
         See Eio.Cancel.protect docs: cancellation can bypass protect-style
         cleanup in concurrent fiber forks. *)
      let now = Mtime_clock.now () in
      emit_logs_maybe ~now ~force ();
      emit_metrics_maybe ~now ~force ();
      emit_traces_maybe ~now ~force ()
    ;;

    let on_tick_cbs_ = Atomic.make (AList.make ())

    let run_tick_callbacks () =
      List.iter
        (fun f ->
           try f () with
           | e -> Log.Telemetry.warn "opentelemetry: on tick callback raised: %s" (Printexc.to_string e))
        (AList.get @@ Atomic.get on_tick_cbs_)
    ;;
  end in
  let module M = struct
    let set_on_tick_callbacks = Atomic.set on_tick_cbs_
    let push_trace e = push_traces e
    let push_metrics e = push_metrics e
    let push_logs e = push_logs e

    let tick () =
      if Config.Env.get_debug ()
      then Log.Telemetry.debug "opentelemetry: tick (from domain %d)" (Domain.self () :> int);
      (try run_tick_callbacks () with
       | exn ->
         Log.Telemetry.warn "opentelemetry: run_tick_callbacks failed: %s" (Printexc.to_string exn));
      try emit_all ~force:false with
      | exn ->
        Log.Telemetry.warn "opentelemetry: emit_all failed: %s" (Printexc.to_string exn)
    ;;

    let cleanup ~on_done () =
      if Config.Env.get_debug () then Log.Telemetry.debug "opentelemetry: exiting...";
      Atomic.set stop true;
      run_tick_callbacks ();
      emit_all ~force:true;
      on_done ()
    ;;
  end
  in
  (module M : EMITTER)
;;

module Backend (Emitter : EMITTER) : Opentelemetry.Collector.BACKEND = struct
  open Opentelemetry.Proto
  open Opentelemetry.Collector
  open Emitter

  let send_trace : Trace.resource_spans list sender =
    { send =
        (fun l ~ret ->
          (if Config.Env.get_debug ()
           then
             let@ () = Lock.with_lock in
             Log.Telemetry.debug "opentelemetry: send spans %s"
               (Format.asprintf "%a"
                  (Format.pp_print_list Trace.pp_resource_spans) l));
          push_trace l;
          ret ())
    }
  ;;

  let last_sent_metrics = Atomic.make (Mtime_clock.now ())
  let timeout_sent_metrics = Mtime.Span.(5 * s)

  (* Required by Opentelemetry.Collector.BACKEND.  No-op: library GC
     sampling was removed (process.runtime.ocaml.gc.* duplicated the
     masc_gc_* gauges already exported via Otel_metric_store). *)
  let signal_emit_gc_metrics () = ()

  let additional_metrics () : Metrics.resource_metrics list =
    let last_emit = Atomic.get last_sent_metrics in
    let now = Mtime_clock.now () in
    let add_own_metrics =
      let elapsed = Mtime.span last_emit now in
      Mtime.Span.compare elapsed timeout_sent_metrics > 0
    in
    if add_own_metrics
    then (
      Atomic.set last_sent_metrics now;
      let open OT.Metrics in
      [ make_resource_metrics
          [ sum
              ~name:"otel.export.dropped"
              ~is_monotonic:true
              [ int
                  ~start_time_unix_nano:(Mtime.to_uint64_ns last_emit)
                  ~now:(Mtime.to_uint64_ns now)
                  (Atomic.get n_dropped)
              ]
          ; sum
              ~name:"otel.export.errors"
              ~is_monotonic:true
              [ int
                  ~start_time_unix_nano:(Mtime.to_uint64_ns last_emit)
                  ~now:(Mtime.to_uint64_ns now)
                  (Atomic.get n_errors)
              ]
          ]
      ])
    else []
  ;;

  let send_metrics : Metrics.resource_metrics list sender =
    { send =
        (fun m ~ret ->
          (if Config.Env.get_debug ()
           then
             let@ () = Lock.with_lock in
             Log.Telemetry.debug "opentelemetry: send metrics %s"
               (Format.asprintf "%a"
                  (Format.pp_print_list Metrics.pp_resource_metrics) m));
          let m = List.rev_append (additional_metrics ()) m in
          push_metrics m;
          ret ())
    }
  ;;

  let send_logs : Logs.resource_logs list sender =
    { send =
        (fun m ~ret ->
          (if Config.Env.get_debug ()
           then
             let@ () = Lock.with_lock in
             Log.Telemetry.debug "opentelemetry: send logs %s"
               (Format.asprintf "%a"
                  (Format.pp_print_list Logs.pp_resource_logs) m));
          push_logs m;
          ret ())
    }
  ;;

  let tick = Emitter.tick
  let cleanup = Emitter.cleanup
  let set_on_tick_callbacks = Emitter.set_on_tick_callbacks
end

let tick_degraded_state = Atomic.make false
let last_tick_poisoned_error_state : string option Atomic.t = Atomic.make None

let tick_degraded () = Atomic.get tick_degraded_state
let last_tick_poisoned_error () = Atomic.get last_tick_poisoned_error_state

let reset_tick_health () =
  Atomic.set tick_degraded_state false;
  Atomic.set last_tick_poisoned_error_state None
;;

let stop_tick_after_poisoned_mutex ~stop cause =
  Atomic.set stop true;
  Atomic.set tick_degraded_state true;
  Atomic.set last_tick_poisoned_error_state (Some (Printexc.to_string cause));
  Log.Telemetry.error
    "otel tick failed with Eio.Mutex.Poisoned; stopping tick fiber; OTEL metrics \
     export degraded until backend restart; underlying cause: %s"
    (Printexc.to_string cause)
;;

let create_backend ~sw ?(stop = Atomic.make false) ?(config = Config.make ()) env
  : (module OT.Collector.BACKEND)
  =
  let module E = (val mk_emitter ~stop ~clock:env#clock ~net:env#net config) in
  let module B = Backend (E) in
  Eio.Fiber.fork ~sw (fun () ->
    let consecutive_errors = Atomic.make 0 in
    while not @@ Atomic.get stop do
      Eio.Time.sleep env#clock 0.5;
      if not (Atomic.get stop)
      then
        try
          B.tick ();
          Atomic.set consecutive_errors 0
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | Eio.Mutex.Poisoned cause -> stop_tick_after_poisoned_mutex ~stop cause
        | exn ->
          (* Keep the fiber alive so export can resume once the underlying
             condition clears. HTTP errors are handled inside [send_http]; an
             exception here means something unexpected bubbled up from a
             callback, GC metrics sampling, or [Switch.run]. Back off to
             prevent log spam. *)
          let n = Atomic.fetch_and_add consecutive_errors 1 + 1 in
          Atomic.set tick_degraded_state true;
          Log.Telemetry.error
            "otel tick failed (%d consecutive): %s"
            n
            (Printexc.to_string exn);
          let backoff =
            Float.min (0.5 *. Float.of_int (1 lsl min n 6)) 30.0
          in
          Eio.Time.sleep env#clock backoff
    done);
  (module B)
;;

let setup_ ~sw ?stop ?config env : unit =
  reset_tick_health ();
  let backend = create_backend ?stop ?config ~sw env in
  OT.Collector.set_backend backend
;;

let setup ?stop ?config ?(enable = true) ~sw env =
  if enable then setup_ ~sw ?stop ?config env
;;

let remove_backend () =
  reset_tick_health ();
  OT.Collector.remove_backend ~on_done:ignore ()
;;

let with_setup ?stop ?config ?(enable = true) f env =
  if enable
  then
    Switch.run
    @@ fun sw ->
    snd
    @@ Fiber.pair
         (fun () -> setup_ ~sw ?stop ?config env)
         (fun () -> Eio_guard.protect ~finally:(fun () -> remove_backend ()) f)
  else f ()
;;
