(** OpenTelemetry-compatible tracer for Agent SDK.
    Implements Tracing.TRACER and exports spans as OTLP JSON.

    Self-contained: no external opentelemetry dependency.
    Generates W3C trace/span IDs, maps to GenAI semantic conventions,
    and serializes completed spans to OTLP JSON for HTTP export.

    v0.43.0: Instance-based state — each [create] call returns an
    independent tracer with its own span stack. The global functions
    ([start_span], [flush], etc.) delegate to a shared global instance
    for backward compatibility.

    v0.44.0: Fiber-safe Eio instances.  Per-instance [Eio.Fiber.key]
    stores a [span list ref] so parallel fibers (e.g. tool batches)
    each have their own active-span stack.  Parent lookups and
    current-spans mutations are lock-free inside a fiber;
    [completed_spans] remains mutex-protected because many fibers
    may finish spans concurrently. *)

(* -- OTel span kind --------------------------------------------------- *)

type otel_span_kind =
  | Internal
  | Client
  | Server
  | Producer
  | Consumer

let otel_span_kind_to_int = function
  | Internal -> 1
  | Client -> 3
  | Server -> 2
  | Producer -> 4
  | Consumer -> 5
;;

(* -- Event / Span types ----------------------------------------------- *)

type otel_event =
  { event_name : string
  ; timestamp_ns : Int64.t
  ; attributes : (string * string) list
  }

type otel_link =
  { trace_id : string
  ; span_id : string
  }

type span =
  { trace_id : string
  ; span_id : string
  ; parent_span_id : string option
  ; name : string
  ; kind : otel_span_kind
  ; start_time_ns : Int64.t
  ; end_time_ns : Int64.t option
  ; status : bool option
  ; attributes : (string * string) list
  ; events : otel_event list
  ; mutable links : otel_link list
  }

(* -- Config ----------------------------------------------------------- *)

type config =
  { service_name : string
  ; endpoint : string option
  }

let default_service_name = "agent-sdk"
let otel_endpoint_env_var = "OTEL_EXPORTER_OTLP_ENDPOINT"
let default_config = { service_name = default_service_name; endpoint = None }

let default_config_from_env
      ?(getenv = fun name -> Llm_provider.Cli_common_env.get name)
      ()
  =
  { default_config with endpoint = getenv otel_endpoint_env_var }
;;

(* -- Metric types ----------------------------------------------------- *)

type metric_type =
  | Counter
  | Gauge
  | Histogram

type metric_entry =
  { m_name : string
  ; m_value : float
  ; m_type : metric_type
  }

(* -- Instance type ---------------------------------------------------- *)

type mutex_impl =
  | Stdlib_mu of Mutex.t
  | Eio_mu of Eio.Mutex.t

type instance =
  { config : config
  ; mu : mutex_impl
  ; fiber_key : span list ref Eio.Fiber.key option
  ; mutable current_spans : span list
  ; mutable completed_spans : span list
  ; mutable metrics : metric_entry list
  }

(* -- Random hex ID generation ----------------------------------------- *)

exception Entropy_unavailable of string

let otel_id_of_sample ~kind = function
  | Error detail -> raise (Entropy_unavailable (kind ^ " ID: " ^ detail))
  | Ok value when String.for_all (Char.equal '0') value ->
    (* W3C trace-context forbids the all-zero trace-id and parent-id values.
       Retrying here would turn a broken entropy source into an unbounded
       observability loop, so reject the invalid sample explicitly. *)
    raise (Entropy_unavailable (kind ^ " ID: entropy source yielded all-zero"))
  | Ok value -> value
;;

let otel_id ~kind ~bytes = Llm_provider.Random_id.hex ~bytes |> otel_id_of_sample ~kind
let gen_trace_id () = otel_id ~kind:"trace" ~bytes:16
let gen_span_id () = otel_id ~kind:"span" ~bytes:8

let%test "all-zero trace identifier fails explicitly" =
  match otel_id_of_sample ~kind:"trace" (Ok (String.make 32 '0')) with
  | exception Entropy_unavailable detail ->
    String.equal detail "trace ID: entropy source yielded all-zero"
  | _ -> false
;;

(* -- Timestamp -------------------------------------------------------- *)

let now_ns () =
  let t = Unix.gettimeofday () in
  Int64.of_float (t *. 1_000_000_000.0)
;;

(* -- Span kind mapping ------------------------------------------------ *)

let map_span_kind = function
  | Tracing.Agent_run -> Internal
  | Tracing.Api_call -> Client
  | Tracing.Tool_exec -> Internal
  | Tracing.Hook_invoke -> Internal
;;

(* -- Semantic convention attributes ----------------------------------- *)

let semantic_attrs (attrs : Tracing.span_attrs) =
  [ "gen_ai.agent.name", attrs.agent_name
  ; "gen_ai.turn", string_of_int attrs.turn
  ; "gen_ai.operation.name", attrs.name
  ]
  @ attrs.extra
;;

(* -- Span name -------------------------------------------------------- *)

let span_kind_to_string = function
  | Tracing.Agent_run -> "agent_run"
  | Tracing.Api_call -> "api_call"
  | Tracing.Tool_exec -> "tool_exec"
  | Tracing.Hook_invoke -> "hook_invoke"
;;

let make_span_name (attrs : Tracing.span_attrs) =
  Printf.sprintf "%s/%s" (span_kind_to_string attrs.kind) attrs.name
;;

(* -- Instance operations ---------------------------------------------- *)

let inst_with_lock inst f =
  match inst.mu with
  | Eio_mu mu -> Eio.Mutex.use_rw ~protect:true mu f
  | Stdlib_mu mu ->
    Mutex.lock mu;
    Fun.protect f ~finally:(fun () -> Mutex.unlock mu)
;;

(** Return the fiber-local span-stack ref cell, if we are running inside
    an Eio fiber that has the instance's [fiber_key] bound. *)
let get_fiber_stack inst : span list ref option =
  match inst.fiber_key with
  | None -> None
  | Some key ->
    (try
       match Eio.Fiber.get key with
       | Some ref -> Some ref
       | None -> None
     with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | _ -> None)
;;

let inst_start_span inst (attrs : Tracing.span_attrs) : span =
  let new_trace_id = gen_trace_id () in
  let span_id = gen_span_id () in
  match get_fiber_stack inst with
  | Some stack_ref ->
    let parent =
      match !stack_ref with
      | p :: _ -> Some p
      | [] -> None
    in
    let trace_id =
      match parent with
      | Some p -> p.trace_id
      | None -> new_trace_id
    in
    let parent_span_id =
      match parent with
      | Some p -> Some p.span_id
      | None -> None
    in
    let s =
      { trace_id
      ; span_id
      ; parent_span_id
      ; name = make_span_name attrs
      ; kind = map_span_kind attrs.kind
      ; start_time_ns = now_ns ()
      ; end_time_ns = None
      ; status = None
      ; attributes = semantic_attrs attrs
      ; events = []
      ; links = List.map (fun (trace_id, span_id) -> { trace_id; span_id }) attrs.links
      }
    in
    stack_ref := s :: !stack_ref;
    s
  | None ->
    inst_with_lock inst
    @@ fun () ->
    let parent =
      match inst.current_spans with
      | p :: _ -> Some p
      | [] -> None
    in
    let trace_id =
      match parent with
      | Some p -> p.trace_id
      | None -> new_trace_id
    in
    let parent_span_id =
      match parent with
      | Some p -> Some p.span_id
      | None -> None
    in
    let s =
      { trace_id
      ; span_id
      ; parent_span_id
      ; name = make_span_name attrs
      ; kind = map_span_kind attrs.kind
      ; start_time_ns = now_ns ()
      ; end_time_ns = None
      ; status = None
      ; attributes = semantic_attrs attrs
      ; events = []
      ; links = List.map (fun (trace_id, span_id) -> { trace_id; span_id }) attrs.links
      }
    in
    inst.current_spans <- s :: inst.current_spans;
    s
;;

let inst_end_span inst (s : span) ~ok =
  let target_opt =
    match get_fiber_stack inst with
    | Some stack_ref ->
      let target = ref None in
      stack_ref
      := List.filter_map
           (fun sp ->
              if sp.span_id = s.span_id
              then (
                let updated =
                  { sp with end_time_ns = Some (now_ns ()); status = Some ok }
                in
                target := Some updated;
                None)
              else Some sp)
           !stack_ref;
      !target
    | None ->
      inst_with_lock inst
      @@ fun () ->
      let target = ref None in
      inst.current_spans
      <- List.filter_map
           (fun sp ->
              if sp.span_id = s.span_id
              then (
                let updated =
                  { sp with end_time_ns = Some (now_ns ()); status = Some ok }
                in
                target := Some updated;
                None)
              else Some sp)
           inst.current_spans;
      !target
  in
  match target_opt with
  | Some completed ->
    inst_with_lock inst (fun () ->
      inst.completed_spans <- completed :: inst.completed_spans)
  | None -> ()
;;

let inst_add_event inst (s : span) (msg : string) =
  let update_spans spans =
    let evt = { event_name = msg; timestamp_ns = now_ns (); attributes = [] } in
    List.map
      (fun sp ->
         if sp.span_id = s.span_id
         then { sp with events = Util.snoc sp.events evt }
         else sp)
      spans
  in
  match get_fiber_stack inst with
  | Some stack_ref -> stack_ref := update_spans !stack_ref
  | None ->
    inst_with_lock inst @@ fun () -> inst.current_spans <- update_spans inst.current_spans
;;

let inst_add_attrs inst (s : span) (attrs : (string * string) list) =
  let update_spans spans =
    List.map
      (fun sp ->
         if sp.span_id = s.span_id
         then { sp with attributes = Util.snoc_list sp.attributes attrs }
         else sp)
      spans
  in
  match get_fiber_stack inst with
  | Some stack_ref -> stack_ref := update_spans !stack_ref
  | None ->
    inst_with_lock inst @@ fun () -> inst.current_spans <- update_spans inst.current_spans
;;

let inst_add_link inst (s : span) ~trace_id ~span_id =
  let link = { trace_id; span_id } in
  let update_spans spans =
    List.map
      (fun sp ->
         if sp.span_id = s.span_id
         then (
           sp.links <- link :: sp.links;
           sp)
         else sp)
      spans
  in
  match get_fiber_stack inst with
  | Some stack_ref -> stack_ref := update_spans !stack_ref
  | None ->
    inst_with_lock inst @@ fun () -> inst.current_spans <- update_spans inst.current_spans
;;

let inst_flush inst =
  inst_with_lock inst
  @@ fun () ->
  let spans = List.rev inst.completed_spans in
  inst.completed_spans <- [];
  spans
;;

let inst_reset inst =
  (match get_fiber_stack inst with
   | Some stack_ref -> stack_ref := []
   | None -> ());
  inst_with_lock inst
  @@ fun () ->
  inst.current_spans <- [];
  inst.completed_spans <- []
;;

let inst_completed_count inst =
  inst_with_lock inst @@ fun () -> List.length inst.completed_spans
;;

let inst_active_count inst =
  match get_fiber_stack inst with
  | Some stack_ref -> List.length !stack_ref
  | None -> inst_with_lock inst @@ fun () -> List.length inst.current_spans
;;

let inst_current_span inst =
  match get_fiber_stack inst with
  | Some stack_ref ->
    (match !stack_ref with
     | current :: _ -> Some current
     | [] -> None)
  | None ->
    inst_with_lock inst
    @@ fun () ->
    (match inst.current_spans with
     | current :: _ -> Some current
     | [] -> None)
;;

let traceparent_of_span ?(sampled = true) (span : span) =
  let flags = if sampled then "01" else "00" in
  Printf.sprintf "00-%s-%s-%s" span.trace_id span.span_id flags
;;

let trace_context_headers_of_span ?(sampled = true) ?tracestate span =
  let headers = [ "traceparent", traceparent_of_span ~sampled span ] in
  match tracestate with
  | Some state when String.trim state <> "" -> headers @ [ "tracestate", state ]
  | Some _ | None -> headers
;;

let inst_trace_context_headers ?sampled ?tracestate inst =
  match inst_current_span inst with
  | Some span -> trace_context_headers_of_span ?sampled ?tracestate span
  | None -> []
;;

(* -- Instance metric operations --------------------------------------- *)

let inst_record_metric inst ~name ~value ~metric_type =
  inst_with_lock inst
  @@ fun () ->
  inst.metrics <- { m_name = name; m_value = value; m_type = metric_type } :: inst.metrics
;;

let entropy_failure_metric = "otel.id_entropy_failures"

let run_span_scope ~start_span ~end_span ~on_entropy_unavailable f =
  match start_span () with
  | span ->
    (match f () with
     | result ->
       end_span span ~ok:true;
       result
     | exception exn ->
       end_span span ~ok:false;
       raise exn)
  | exception Entropy_unavailable detail ->
    on_entropy_unavailable detail;
    f ()
;;

let%test "entropy failure degrades only the observation span" =
  let degraded = ref None in
  let body_ran = ref false in
  let result =
    run_span_scope
      ~start_span:(fun () -> raise (Entropy_unavailable "trace ID: unavailable"))
      ~end_span:(fun (_ : unit) ~ok:_ -> ())
      ~on_entropy_unavailable:(fun detail -> degraded := Some detail)
      (fun () ->
         body_ran := true;
         42)
  in
  result = 42 && !body_ran && !degraded = Some "trace ID: unavailable"
;;

let inst_get_metrics inst =
  inst_with_lock inst
  @@ fun () -> List.map (fun m -> m.m_name, m.m_value, m.m_type) (List.rev inst.metrics)
;;

let inst_drain_metrics inst =
  inst_with_lock inst
  @@ fun () ->
  let metrics = List.rev inst.metrics in
  inst.metrics <- [];
  metrics
;;

let inst_clear_metrics inst = inst_with_lock inst @@ fun () -> inst.metrics <- []

let metric_type_to_string = function
  | Counter -> "counter"
  | Gauge -> "gauge"
  | Histogram -> "histogram"
;;

(* -- Global instance (backward compat) -------------------------------- *)

(* The global tracer is initialized on first use so that environment-sensitive
   configuration is not captured at module load, and so the fiber-local key is
   only allocated when needed. First-use creation is protected by a stdlib
   mutex because the global API can be reached by non-Eio callers. Using a
   fiber-local key makes the global API safe for concurrent Eio fibers: each
   fiber gets its own span stack instead of sharing the instance-wide
   [current_spans].

   NOTE: the endpoint is resolved once from [otel_endpoint_env_var] when the
   global instance is created. Later env changes do not affect the
   already-created shared instance; create a fresh instance with
   [create_instance] for per-call env resolution. *)
let make_global_instance () : instance =
  { config = default_config_from_env ()
  ; mu = Stdlib_mu (Mutex.create ())
  ; fiber_key = Some (Eio.Fiber.create_key ())
  ; current_spans = []
  ; completed_spans = []
  ; metrics = []
  }
;;

let global_instance_mu = Mutex.create ()
let global_instance_ref : instance option ref = ref None

let global_instance () =
  Mutex.lock global_instance_mu;
  Fun.protect
    (fun () ->
       match !global_instance_ref with
       | Some inst -> inst
       | None ->
         let inst = make_global_instance () in
         global_instance_ref := Some inst;
         inst)
    ~finally:(fun () -> Mutex.unlock global_instance_mu)
;;

let start_span attrs = inst_start_span (global_instance ()) attrs
let end_span s ~ok = inst_end_span (global_instance ()) s ~ok
let add_event s msg = inst_add_event (global_instance ()) s msg
let add_attrs s attrs = inst_add_attrs (global_instance ()) s attrs

let add_link s ~trace_id ~span_id =
  inst_add_link (global_instance ()) s ~trace_id ~span_id
;;

let flush () = inst_flush (global_instance ())
let reset () = inst_reset (global_instance ())
let completed_count () = inst_completed_count (global_instance ())
let active_count () = inst_active_count (global_instance ())

let record_metric ~name ~value ~metric_type =
  inst_record_metric (global_instance ()) ~name ~value ~metric_type
;;

let get_metrics () = inst_get_metrics (global_instance ())
let clear_metrics () = inst_clear_metrics (global_instance ())
let current_span () = inst_current_span (global_instance ())

(* -- JSON export ------------------------------------------------------ *)

let attrs_to_json (attrs : (string * string) list) : Yojson.Safe.t =
  `List
    (List.map
       (fun (k, v) ->
          `Assoc [ "key", `String k; "value", `Assoc [ "stringValue", `String v ] ])
       attrs)
;;

let event_to_json (evt : otel_event) : Yojson.Safe.t =
  `Assoc
    [ "timeUnixNano", `String (Int64.to_string evt.timestamp_ns)
    ; "name", `String evt.event_name
    ; "attributes", attrs_to_json evt.attributes
    ]
;;

let status_to_json (s : span) : Yojson.Safe.t =
  match s.status with
  | None -> `Assoc [ "code", `Int 0 ] (* UNSET *)
  | Some true -> `Assoc [ "code", `Int 1 ] (* OK *)
  | Some false -> `Assoc [ "code", `Int 2; "message", `String "error" ]
;;

(* ERROR *)

let link_to_json (link : otel_link) : Yojson.Safe.t =
  `Assoc
    [ "traceId", `String link.trace_id
    ; "spanId", `String link.span_id
    ; "attributes", `List []
    ; "droppedAttributesCount", `Int 0
    ]
;;

let span_to_json (s : span) : Yojson.Safe.t =
  let end_ns =
    match s.end_time_ns with
    | Some ns -> ns
    | None -> s.start_time_ns
  in
  let base =
    [ "traceId", `String s.trace_id
    ; "spanId", `String s.span_id
    ; "name", `String s.name
    ; "kind", `Int (otel_span_kind_to_int s.kind)
    ; "startTimeUnixNano", `String (Int64.to_string s.start_time_ns)
    ; "endTimeUnixNano", `String (Int64.to_string end_ns)
    ; "status", status_to_json s
    ; "attributes", attrs_to_json s.attributes
    ; "events", `List (List.map event_to_json s.events)
    ; "links", `List (List.map link_to_json s.links)
    ]
  in
  let with_parent =
    match s.parent_span_id with
    | Some pid -> ("parentSpanId", `String pid) :: base
    | None -> base
  in
  `Assoc with_parent
;;

let metric_entry_to_json (m : metric_entry) : Yojson.Safe.t =
  let ts = now_ns () in
  let data_point =
    `Assoc [ "asDouble", `Float m.m_value; "timeUnixNano", `String (Int64.to_string ts) ]
  in
  let metric_body =
    match m.m_type with
    | Counter ->
      [ ( "sum"
        , `Assoc
            [ "dataPoints", `List [ data_point ]
            ; "isMonotonic", `Bool true
            ; "aggregationTemporality", `Int 2
            ] )
      ]
    | Gauge -> [ "gauge", `Assoc [ "dataPoints", `List [ data_point ] ] ]
    | Histogram ->
      [ ( "histogram"
        , `Assoc [ "dataPoints", `List [ data_point ]; "aggregationTemporality", `Int 2 ]
        )
      ]
  in
  `Assoc (("name", `String m.m_name) :: metric_body)
;;

let to_otlp_json (cfg : config) : Yojson.Safe.t =
  let global = global_instance () in
  let spans, metrics =
    inst_with_lock global (fun () ->
      List.rev global.completed_spans, List.rev global.metrics)
  in
  let resource =
    `Assoc [ "attributes", attrs_to_json [ "service.name", cfg.service_name ] ]
  in
  let resource_spans =
    `Assoc
      [ "resource", resource
      ; ( "scopeSpans"
        , `List
            [ `Assoc
                [ ( "scope"
                  , `Assoc
                      [ "name", `String "agent_sdk.otel_tracer"
                      ; "version", `String Sdk_version.version
                      ] )
                ; "spans", `List (List.map span_to_json spans)
                ]
            ] )
      ]
  in
  let base = [ "resourceSpans", `List [ resource_spans ] ] in
  let with_metrics =
    if metrics = []
    then base
    else (
      let resource_metrics =
        `Assoc
          [ "resource", resource
          ; ( "scopeMetrics"
            , `List
                [ `Assoc
                    [ ( "scope"
                      , `Assoc
                          [ "name", `String "agent_sdk.otel_tracer"
                          ; "version", `String Sdk_version.version
                          ] )
                    ; "metrics", `List (List.map metric_entry_to_json metrics)
                    ]
                ] )
          ]
      in
      base @ [ "resourceMetrics", `List [ resource_metrics ] ])
  in
  `Assoc with_metrics
;;

(* -- Instance creation ------------------------------------------------ *)

let create_instance ?config ?getenv () : instance =
  let config =
    match config with
    | Some config -> config
    | None -> default_config_from_env ?getenv ()
  in
  { config
  ; mu = Stdlib_mu (Mutex.create ())
  ; fiber_key = None
  ; current_spans = []
  ; completed_spans = []
  ; metrics = []
  }
;;

let create_instance_eio ?config ?getenv () : instance =
  let config =
    match config with
    | Some config -> config
    | None -> default_config_from_env ?getenv ()
  in
  { config
  ; mu = Eio_mu (Eio.Mutex.create ())
  ; fiber_key = Some (Eio.Fiber.create_key ())
  ; current_spans = []
  ; completed_spans = []
  ; metrics = []
  }
;;

let tracer_of_instance inst : Tracing.t =
  (module struct
    type nonrec span = span

    let start_span = inst_start_span inst
    let end_span = inst_end_span inst
    let add_event = inst_add_event inst
    let add_attrs = inst_add_attrs inst
    let add_link s ~trace_id ~span_id = inst_add_link inst s ~trace_id ~span_id
    let trace_id s = Some s.trace_id
    let span_id s = Some s.span_id
    let trace_context_headers () = inst_trace_context_headers inst

    let with_span attrs f =
      let run () =
        run_span_scope
          ~start_span:(fun () -> inst_start_span inst attrs)
          ~end_span:(inst_end_span inst)
          ~on_entropy_unavailable:(fun _detail ->
            inst_record_metric
              inst
              ~name:entropy_failure_metric
              ~value:1.0
              ~metric_type:Counter)
          f
      in
      match inst.fiber_key with
      | Some key ->
        let stack_ref =
          match Eio.Fiber.get key with
          | Some ref -> ref
          | None -> ref []
        in
        Eio.Fiber.with_binding key stack_ref run
      | None -> run ()
    ;;
  end)
;;

let with_span attrs f =
  let module T = (val tracer_of_instance (global_instance ())) in
  T.with_span attrs f
;;

(* -- First-class module constructors ---------------------------------- *)

let create ?config ?getenv () : Tracing.t =
  tracer_of_instance (create_instance ?config ?getenv ())
;;

let create_eio ?config ?getenv () : Tracing.t =
  tracer_of_instance (create_instance_eio ?config ?getenv ())
;;
