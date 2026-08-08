(** Agent Event Bus — typed publish/subscribe for agent lifecycle events.

    Each subscriber gets its own explicitly configured bounded FIFO; [publish]
    copies each event to every matching subscriber under that subscription's
    overflow policy.
    Filters are data, not caller callbacks, so a faulty subscriber cannot raise
    or yield inside another producer's publish.

    All state is internal to [t] — no globals.  GC collects everything
    when the bus goes out of scope. *)

open Types

(* ── Envelope ─────────────────────────────────────────────────────── *)

type envelope =
  { correlation_id : string
  ; run_id : string
  ; ts : float
  ; caused_by : string option
  }

type envelope_v2 = Event_envelope.t

(* ── Payload type ─────────────────────────────────────────────────── *)

type payload =
  | AgentStarted of
      { agent_name : string
      ; task_id : string
      }
  | AgentCompleted of
      { agent_name : string
      ; task_id : string
      ; result : (api_response, Error.sdk_error) result
      ; elapsed : float
      }
  | AgentFailed of
      { agent_name : string
      ; task_id : string
      ; error : Error.sdk_error
      ; elapsed : float
      }
  | ToolCalled of
      { invocation : Tool_contract.Invocation.t
      ; agent_name : string
      ; tool_name : string
      ; input : Yojson.Safe.t
      }
  | ToolCompleted of
      { invocation : Tool_contract.Invocation.t
      ; agent_name : string
      ; tool_name : string
      ; output : Types.tool_result
      }
  | TurnStarted of
      { agent_name : string
      ; turn : int
      }
  | TurnReady of
      { agent_name : string
      ; turn : int
      ; tool_names : string list
      }
  | TurnCompleted of
      { agent_name : string
      ; turn : int
      }
  | HandoffRequested of
      { from_agent : string
      ; to_agent : string
      ; reason : string
      }
  | HandoffCompleted of
      { from_agent : string
      ; to_agent : string
      ; elapsed : float
      }
  | ElicitationCompleted of
      { agent_name : string
      ; question : string
      ; response : Hooks.elicitation_response
      }
  | ToolApprovalCompleted of
      { agent_name : string
      ; invocation : Tool_contract.Invocation.t
      ; tool_name : string
      ; approval : Hooks.tool_approval
      }
  | InferenceTelemetry of
      { agent_name : string
      ; turn : int
      ; provider : string
      ; model : string
      ; prompt_tokens : int option
      ; completion_tokens : int option
      ; prompt_ms : float option
      ; decode_ms : float option
      ; decode_tok_s : float option
      }
  | Custom of string * Yojson.Safe.t

(* ── Event type ───────────────────────────────────────────────────── *)

type event =
  { meta : envelope
  ; payload : payload
  }

(* ── Payload introspection ────────────────────────────────────────── *)

(* Stable snake_case event-type label.  Co-located with the [payload]
   variant: adding a new constructor in [payload] forces an update
   here in the same patch under OAS's [warn-error +8] flag set, so
   downstream consumers can rely on the label being defined for every
   reachable variant.  Subscribers may persist or compare the
   returned strings — treat them as part of the public API. *)
let payload_kind = function
  | AgentStarted _ -> "agent_started"
  | AgentCompleted _ -> "agent_completed"
  | AgentFailed _ -> "agent_failed"
  | ToolCalled _ -> "tool_called"
  | ToolCompleted _ -> "tool_completed"
  | TurnStarted _ -> "turn_started"
  | TurnReady _ -> "turn_ready"
  | TurnCompleted _ -> "turn_completed"
  | HandoffRequested _ -> "handoff_requested"
  | HandoffCompleted _ -> "handoff_completed"
  | ElicitationCompleted _ -> "elicitation_completed"
  | ToolApprovalCompleted _ -> "tool_approval_completed"
  | InferenceTelemetry _ -> "inference_telemetry"
  | Custom (name, _) -> Printf.sprintf "custom:%s" name
;;

(* ── ID generation ────────────────────────────────────────────────── *)

let fresh_id = Event_envelope.fresh_id

let mk_envelope ?correlation_id ?run_id ?caused_by () =
  let correlation_id =
    match correlation_id with
    | Some id -> id
    | None -> fresh_id ()
  in
  let run_id =
    match run_id with
    | Some id -> id
    | None -> fresh_id ()
  in
  { correlation_id; run_id; ts = Unix.gettimeofday (); caused_by }
;;

let mk_envelope_v2 = Event_envelope.make

let envelope_v2_of_envelope ?event_id ?observed_at ?seq ?parent_event_id (env : envelope) =
  Event_envelope.make
    ?event_id
    ~correlation_id:env.correlation_id
    ~run_id:env.run_id
    ~event_time:env.ts
    ?observed_at
    ?seq
    ?parent_event_id
    ?caused_by:env.caused_by
    ~source_clock:Event_envelope.Wall
    ()
;;

let mk_event ?correlation_id ?run_id ?caused_by payload =
  { meta = mk_envelope ?correlation_id ?run_id ?caused_by (); payload }
;;

(* ── Subscription ─────────────────────────────────────────────────── *)

type filter =
  | Accept_all
  | Agent of string
  | Tools_only
  | Topic of string
  | Correlation of string
  | Run of string
  | Any of filter list
  | All of filter list

type overflow =
  | Drop_oldest
  | Drop_newest

type subscription_config_error = Non_positive_capacity of int

type subscription_config =
  { capacity : int
  ; overflow : overflow
  }

let subscription_config ~capacity ~overflow =
  if capacity <= 0
  then Error (Non_positive_capacity capacity)
  else Ok { capacity; overflow }
;;

type subscription =
  { id : int
  ; stream : event Eio.Stream.t
  ; filter : filter
  ; purpose : string option
  ; capacity : int
  ; overflow : overflow
  ; published_total : int Atomic.t
  ; drained_total : int Atomic.t
  ; dropped_total : int Atomic.t
  ; deliver_mu : Eio.Mutex.t
  ; cancelled : bool Atomic.t
  }

(* ── Bus ──────────────────────────────────────────────────────────── *)

type t =
  { mutable subscribers : subscription list
  ; mutable next_id : int
  ; mu : Eio.Mutex.t
  ; (* Cached subscriber count for O(1) queries. Publish still snapshots the
     subscriber list under [mu] to avoid racing concurrent subscribers. *)
    subscriber_count : int Atomic.t
  }

let create () =
  { subscribers = []
  ; next_id = 0
  ; mu = Eio.Mutex.create ()
  ; subscriber_count = Atomic.make 0
  }
;;

(* ── Filters ──────────────────────────────────────────────────────── *)

let accept_all = Accept_all
let filter_agent name = Agent name
let filter_tools_only = Tools_only
let filter_topic topic = Topic topic
let filter_correlation id = Correlation id
let filter_run id = Run id
let filter_any filters = Any filters
let filter_all filters = All filters

let rec matches filter event =
  match filter with
  | Accept_all -> true
  | Agent name ->
    (match event.payload with
     | AgentStarted r -> r.agent_name = name
     | AgentCompleted r -> r.agent_name = name
     | AgentFailed r -> r.agent_name = name
     | ToolCalled r -> r.agent_name = name
     | ToolCompleted r -> r.agent_name = name
     | TurnStarted r -> r.agent_name = name
     | TurnReady r -> r.agent_name = name
     | TurnCompleted r -> r.agent_name = name
     | HandoffRequested r -> r.from_agent = name || r.to_agent = name
     | HandoffCompleted r -> r.from_agent = name || r.to_agent = name
     | ElicitationCompleted r -> r.agent_name = name
     | ToolApprovalCompleted r -> r.agent_name = name
     | InferenceTelemetry r -> r.agent_name = name
     | Custom _ -> true)
  | Tools_only ->
    (match event.payload with
     | ToolCalled _ | ToolCompleted _ -> true
     | AgentStarted _
     | AgentCompleted _
     | AgentFailed _
     | TurnStarted _
     | TurnReady _
     | TurnCompleted _
     | HandoffRequested _
     | HandoffCompleted _
     | ElicitationCompleted _
     | ToolApprovalCompleted _
     | InferenceTelemetry _
     | Custom _ -> false)
  | Topic topic ->
    (match event.payload with
     | Custom (actual, _) -> String.equal actual topic
     | AgentStarted _
     | AgentCompleted _
     | AgentFailed _
     | ToolCalled _
     | ToolCompleted _
     | TurnStarted _
     | TurnReady _
     | TurnCompleted _
     | HandoffRequested _
     | HandoffCompleted _
     | ElicitationCompleted _
     | ToolApprovalCompleted _
     | InferenceTelemetry _ -> false)
  | Correlation id -> String.equal event.meta.correlation_id id
  | Run id -> String.equal event.meta.run_id id
  | Any filters -> List.exists (fun filter -> matches filter event) filters
  | All filters -> List.for_all (fun filter -> matches filter event) filters
;;

(* ── Subscribe / unsubscribe ──────────────────────────────────────── *)

let subscribe ~(config : subscription_config) ?(filter = accept_all) ?purpose bus =
  let stream = Eio.Stream.create config.capacity in
  Eio.Mutex.use_rw ~protect:true bus.mu (fun () ->
    let id = bus.next_id in
    let sub =
      { id
      ; stream
      ; filter
      ; purpose
      ; capacity = config.capacity
      ; overflow = config.overflow
      ; published_total = Atomic.make 0
      ; drained_total = Atomic.make 0
      ; dropped_total = Atomic.make 0
      ; deliver_mu = Eio.Mutex.create ()
      ; cancelled = Atomic.make false
      }
    in
    bus.subscribers <- sub :: bus.subscribers;
    bus.next_id <- id + 1;
    ignore (Atomic.fetch_and_add bus.subscriber_count 1);
    sub)
;;

let remove_subscription bus sub =
  Eio.Mutex.use_rw ~protect:true bus.mu (fun () ->
    let before = List.length bus.subscribers in
    bus.subscribers <- List.filter (fun s -> s.id <> sub.id) bus.subscribers;
    let after = List.length bus.subscribers in
    if after < before then ignore (Atomic.fetch_and_add bus.subscriber_count (-1)) else ())
;;

let drain_locked sub =
  let rec collect acc =
    match Eio.Stream.take_nonblocking sub.stream with
    | Some event ->
      Atomic.incr sub.drained_total;
      collect (event :: acc)
    | None -> List.rev acc
  in
  collect []
;;

let unsubscribe bus sub =
  Atomic.set sub.cancelled true;
  remove_subscription bus sub;
  Eio.Mutex.use_rw ~protect:true sub.deliver_mu (fun () ->
    let rec discard_pending () =
      match Eio.Stream.take_nonblocking sub.stream with
      | Some _ -> discard_pending ()
      | None -> ()
    in
    discard_pending ())
;;

let unsubscribe_and_drain bus sub =
  Atomic.set sub.cancelled true;
  remove_subscription bus sub;
  Eio.Mutex.use_rw ~protect:true sub.deliver_mu (fun () -> drain_locked sub)
;;

(* ── Publish ──────────────────────────────────────────────────────── *)

let unless_cancelled sub f = if Atomic.get sub.cancelled then () else f ()

let deliver_to_sub sub event =
  let add_unless_cancelled () =
    unless_cancelled sub (fun () -> Eio.Stream.add sub.stream event)
  in
  unless_cancelled sub (fun () ->
    Atomic.incr sub.published_total;
    match sub.overflow with
    | Drop_oldest ->
      Eio.Mutex.use_rw ~protect:true sub.deliver_mu (fun () ->
        unless_cancelled sub (fun () ->
          if Eio.Stream.length sub.stream >= sub.capacity
          then (
            match Eio.Stream.take_nonblocking sub.stream with
            | Some _ ->
              Atomic.incr sub.dropped_total;
              add_unless_cancelled ()
            | None -> add_unless_cancelled ())
          else add_unless_cancelled ()))
    | Drop_newest ->
      Eio.Mutex.use_rw ~protect:true sub.deliver_mu (fun () ->
        unless_cancelled sub (fun () ->
          if Eio.Stream.length sub.stream >= sub.capacity
          then Atomic.incr sub.dropped_total
          else add_unless_cancelled ())))
;;

let publish bus event =
  let subs = Eio.Mutex.use_ro bus.mu (fun () -> bus.subscribers) in
  List.iter (fun sub -> if matches sub.filter event then deliver_to_sub sub event) subs
;;

(* ── Drain ────────────────────────────────────────────────────────── *)

let drain sub = Eio.Mutex.use_rw ~protect:true sub.deliver_mu (fun () -> drain_locked sub)

(* ── Queries ──────────────────────────────────────────────────────── *)

let subscriber_count bus = Atomic.get bus.subscriber_count

type subscription_stats =
  { purpose : string option
  ; capacity : int
  ; overflow : overflow
  ; depth : int
  ; published_total : int
  ; drained_total : int
  ; dropped_total : int
  }

type bus_stats =
  { subscriber_count : int
  ; subscriptions : subscription_stats list
  }

let stats bus =
  let subs = Eio.Mutex.use_ro bus.mu (fun () -> bus.subscribers) in
  let subscriptions =
    List.map
      (fun (sub : subscription) ->
         ({ purpose = sub.purpose
          ; capacity = sub.capacity
          ; overflow = sub.overflow
          ; depth = Eio.Stream.length sub.stream
          ; published_total = Atomic.get sub.published_total
          ; drained_total = Atomic.get sub.drained_total
          ; dropped_total = Atomic.get sub.dropped_total
          }
          : subscription_stats))
      subs
  in
  ({ subscriber_count = List.length subs; subscriptions } : bus_stats)
;;
