type component =
  | Ready_notification
  | Scheduler_probe
  | Full_health_refresh
  | Heap_roots
  | Owner_lanes
  | Discord_gateway
  | Slack_gateway
  | Slack_poll
  | Imessage_gateway
  | Telegram_gateway
  | Startup_banner
  | Grpc_listener
  | Grpc_client
  | Websocket_handler
  | Transport_providers
  | Execution_refresh
  | Transport_health_refresh
  | Execution_trust_refresh
  | Mission_refresh
  | Operator_snapshot_refresh
  | Operator_digest_refresh
  | Shell_prewarm

type starts =
  { ready_notification : unit -> unit
  ; scheduler_probe : unit -> unit
  ; full_health_refresh : unit -> unit
  ; heap_roots : unit -> unit
  ; owner_lanes : unit -> unit
  ; discord_gateway : unit -> unit
  ; slack_gateway : unit -> unit
  ; slack_poll : unit -> unit
  ; imessage_gateway : unit -> unit
  ; telegram_gateway : unit -> unit
  ; startup_banner : unit -> unit
  ; grpc_listener : unit -> unit
  ; grpc_client : unit -> unit
  ; websocket_handler : unit -> unit
  ; transport_providers : unit -> unit
  ; execution_refresh : unit -> unit
  ; transport_health_refresh : unit -> unit
  ; execution_trust_refresh : unit -> unit
  ; mission_refresh : unit -> unit
  ; operator_snapshot_refresh : unit -> unit
  ; operator_digest_refresh : unit -> unit
  ; shell_prewarm : unit -> unit
  }

type failure =
  { cause : exn
  ; backtrace : Printexc.raw_backtrace
  }

type attempt = Not_attempted | Starting | Returned | Failed of failure | Cancelled

module Components = Map.Make (struct
  type t = component
  let compare = Stdlib.compare
end)

type t = { state : attempt Components.t Atomic.t }
let create () = { state = Atomic.make Components.empty }
let global = create ()

let component_name = function
  | Ready_notification -> "ready_notification"
  | Scheduler_probe -> "scheduler_probe"
  | Full_health_refresh -> "full_health_refresh"
  | Heap_roots -> "heap_roots"
  | Owner_lanes -> "owner_lanes"
  | Discord_gateway -> "discord_gateway"
  | Slack_gateway -> "slack_gateway"
  | Slack_poll -> "slack_poll"
  | Imessage_gateway -> "imessage_gateway"
  | Telegram_gateway -> "telegram_gateway"
  | Startup_banner -> "startup_banner"
  | Grpc_listener -> "grpc_listener"
  | Grpc_client -> "grpc_client"
  | Websocket_handler -> "websocket_handler"
  | Transport_providers -> "transport_providers"
  | Execution_refresh -> "execution_refresh"
  | Transport_health_refresh -> "transport_health_refresh"
  | Execution_trust_refresh -> "execution_trust_refresh"
  | Mission_refresh -> "mission_refresh"
  | Operator_snapshot_refresh -> "operator_snapshot_refresh"
  | Operator_digest_refresh -> "operator_digest_refresh"
  | Shell_prewarm -> "shell_prewarm"

let bindings starts =
  [ Ready_notification, starts.ready_notification
  ; Scheduler_probe, starts.scheduler_probe
  ; Full_health_refresh, starts.full_health_refresh
  ; Heap_roots, starts.heap_roots
  ; Owner_lanes, starts.owner_lanes
  ; Discord_gateway, starts.discord_gateway
  ; Slack_gateway, starts.slack_gateway
  ; Slack_poll, starts.slack_poll
  ; Imessage_gateway, starts.imessage_gateway
  ; Telegram_gateway, starts.telegram_gateway
  ; Startup_banner, starts.startup_banner
  ; Grpc_listener, starts.grpc_listener
  ; Grpc_client, starts.grpc_client
  ; Websocket_handler, starts.websocket_handler
  ; Transport_providers, starts.transport_providers
  ; Execution_refresh, starts.execution_refresh
  ; Transport_health_refresh, starts.transport_health_refresh
  ; Execution_trust_refresh, starts.execution_trust_refresh
  ; Mission_refresh, starts.mission_refresh
  ; Operator_snapshot_refresh, starts.operator_snapshot_refresh
  ; Operator_digest_refresh, starts.operator_digest_refresh
  ; Shell_prewarm, starts.shell_prewarm
  ]

let components starts = List.map fst (bindings starts)
let snapshot t = Components.bindings (Atomic.get t.state)

let set t component attempt =
  Atomic_util.update t.state (Components.add component attempt)

let check_cancellation () =
  match Eio_guard.execution_context () with
  | Eio_fiber -> Eio.Fiber.check ()
  | Non_eio -> ()

let run_all t starts =
  let ordered = bindings starts in
  Atomic.set t.state
    (List.fold_left
       (fun state (component, _) -> Components.add component Not_attempted state)
       Components.empty ordered);
  let rec run failures = function
    | [] ->
        check_cancellation ();
        List.rev failures
    | (component, start) :: rest ->
        check_cancellation ();
        set t component Starting;
        match start () with
        | () ->
            set t component Returned;
            run failures rest
        | exception cause ->
            let backtrace = Printexc.get_raw_backtrace () in
            (match cause with
             | Eio.Cancel.Cancelled _ ->
                 set t component Cancelled;
                 Printexc.raise_with_backtrace cause backtrace
             | _ ->
                 let failure = { cause; backtrace } in
                 set t component (Failed failure);
                 run ((component, failure) :: failures) rest)
  in
  run [] ordered

let phase = function
  | Not_attempted -> "not_attempted"
  | Starting -> "starting"
  | Returned -> "returned"
  | Failed _ -> "failed"
  | Cancelled -> "cancelled"

let to_yojson t =
  let observed = snapshot t in
  let failed, incomplete =
    List.fold_left
      (fun (failed, incomplete) (component, attempt) ->
        match attempt with
        | Failed _ -> (component :: failed, incomplete)
        | Not_attempted | Starting | Cancelled -> (failed, true)
        | Returned -> (failed, incomplete))
      ([], observed = []) observed
  in
  let failed = List.rev failed in
  let status =
    match failed, incomplete with
    | _ :: _, _ -> "degraded"
    | [], true -> "warming"
    | [], false -> "ok"
  in
  let reasons =
    List.map (fun component -> `String (component_name component ^ ":start_failed")) failed
  in
  `Assoc
    [ "status", `String status
    ; "status_reasons", `List reasons
    ; "operator_action_required", `Bool (failed <> [])
    ; "operator_action_reasons", `List reasons
    ; "components", `List
        (List.map
           (fun (component, attempt) ->
             `Assoc
               [ "component", `String (component_name component)
               ; "phase", `String (phase attempt)
               ])
           observed)
    ]
