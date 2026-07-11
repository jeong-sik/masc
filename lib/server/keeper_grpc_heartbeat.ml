open Keeper_types
open Keeper_meta_contract
open Keeper_keepalive

let grpc_client_ref : Masc_grpc_client.t option Atomic.t = Atomic.make None
let grpc_env_ref : Eio_unix.Stdenv.base option Atomic.t = Atomic.make None

let set_grpc_client ?(env : Eio_unix.Stdenv.base option) c =
  Atomic.set grpc_client_ref (Some c);
  Atomic.set grpc_env_ref env
;;

let make_grpc_heartbeat_ping ~config ~agent_name ~session_id =
  Masc_grpc_types.HeartbeatPing.
    { agent_name
    ; session_id
    ; timestamp_ms = Int64.of_float (Time_compat.now () *. 1000.0)
    ; current_task_id = Keeper_keepalive.current_task_id_for_agent ~config agent_name
    }
;;

let handle_grpc_heartbeat_ack ~agent_name (ack : Masc_grpc_types.HeartbeatAck.t) =
  Log.Keeper.debug
    "gRPC bidi heartbeat: agent=%s agents=%d tasks=%d directives=%d"
    agent_name
    ack.active_agent_count
    ack.pending_task_count
    (List.length ack.directives);
  List.iter (Keeper_keepalive.process_directive ~agent_name) ack.directives
;;

let run_grpc_heartbeat_stream
      ~stop
      ~close_ref
      ~clock
      ~interval_sec
      ~config
      ~agent_name
      ~session_id
      send
      recv
  =
  let rec tick () =
    if Atomic.get stop || Atomic.get close_ref
    then ()
    else (
      (try
         send (make_grpc_heartbeat_ping ~config ~agent_name ~session_id);
         match recv () with
         | Ok ack -> handle_grpc_heartbeat_ack ~agent_name ack
         | Error err ->
           Otel_metric_store.inc_counter
             Keeper_metrics.(to_string HeartbeatFailures)
             ~labels:[ "keeper", agent_name; "site", "grpc_recv" ]
             ();
           Log.Keeper.warn "gRPC heartbeat recv: %s" err
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | End_of_file -> raise End_of_file
       | exn ->
         Otel_metric_store.inc_counter
           Keeper_metrics.(to_string HeartbeatFailures)
           ~labels:[ "keeper", agent_name; "site", "grpc_tick" ]
           ();
         Log.Keeper.error "gRPC heartbeat tick error: %s" (Printexc.to_string exn));
      if not (Atomic.get stop || Atomic.get close_ref)
      then (
        let no_wakeup = Atomic.make false in
        ignore
          (Keeper_keepalive_signal.interruptible_sleep ~clock ~stop ~wakeup:no_wakeup interval_sec
           : Keeper_keepalive_signal.sleep_outcome);
        tick ()))
  in
  tick ()
;;

let log_grpc_heartbeat_stream_failure ~agent_name ~attempts = function
  | `Closed ->
    Log.Keeper.warn
      "gRPC heartbeat stream closed for %s (attempt %d/%d)"
      agent_name
      (attempts + 1)
      Env_config.KeeperGrpc.max_reconnect_attempts
  | `Error exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string HeartbeatFailures)
      ~labels:[ "keeper", agent_name; "site", "grpc_stream" ]
      ();
    Log.Keeper.warn
      "gRPC heartbeat stream error for %s: %s (attempt %d/%d)"
      agent_name
      (Printexc.to_string exn)
      (attempts + 1)
      Env_config.KeeperGrpc.max_reconnect_attempts
;;

let max_reconnect_attempts = Env_config.KeeperGrpc.max_reconnect_attempts
let reconnect_backoff_sec = Env_config.KeeperGrpc.reconnect_backoff_sec

let run_grpc_heartbeat_fiber
      ~sw
      ~stop
      ~(grpc_client : Masc_grpc_client.t)
      ~(config : Workspace.config)
      ~(agent_name : string)
      ~(session_id : string)
      ~(interval_sec : float)
      ~(clock : _ Eio.Time.clock)
  =
  match Atomic.get grpc_env_ref with
  | None ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string HeartbeatFailures)
      ~labels:[ "keeper", agent_name; "site", "grpc_no_env" ]
      ();
    Log.Keeper.warn "gRPC heartbeat: Eio env not available";
    None
  | Some env ->
    let close_ref = Atomic.make false in
    Eio.Fiber.fork ~sw (fun () ->
      let rec connect_loop attempts =
        if Atomic.get stop || Atomic.get close_ref
        then ()
        else if attempts >= max_reconnect_attempts
        then (
          Otel_metric_store.inc_counter
            Keeper_metrics.(to_string HeartbeatFailures)
            ~labels:[ "keeper", agent_name; "site", "grpc_reconnect_exhausted" ]
            ();
          Log.Keeper.error
            "gRPC heartbeat: exceeded %d reconnect attempts for %s, stopping"
            max_reconnect_attempts
            agent_name)
        else (
          let send, recv, close_stream =
            Masc_grpc_client.heartbeat_stream grpc_client ~sw ~env
          in
          (try
             run_grpc_heartbeat_stream
               ~stop
               ~close_ref
               ~clock
               ~interval_sec
               ~config
               ~agent_name
               ~session_id
               send
               recv
           with
           | Eio.Cancel.Cancelled _ as e ->
             close_stream ();
             raise e
           | End_of_file ->
             log_grpc_heartbeat_stream_failure ~agent_name ~attempts `Closed;
             close_stream ()
           | exn ->
             log_grpc_heartbeat_stream_failure ~agent_name ~attempts (`Error exn);
             close_stream ());
          if not (Atomic.get stop || Atomic.get close_ref)
          then (
            Eio.Time.sleep clock reconnect_backoff_sec;
            connect_loop (attempts + 1)))
      in
      connect_loop 0);
    Some (fun () -> Atomic.set close_ref true)
;;

let start_keeper_grpc_heartbeat
      ~(ctx : _ Keeper_types_profile.context)
      ~(m : keeper_meta)
      ~(stop : bool Atomic.t)
  : (unit -> unit) option
  =
  match Masc_grpc_transport.from_env (), Atomic.get grpc_client_ref with
  | Masc_grpc_transport.Grpc, Some client ->
    Log.Keeper.info "keeper %s: starting gRPC heartbeat fiber" m.name;
    let interval = float_of_int (Keeper_heartbeat_snapshot.keepalive_interval_sec ()) in
    let session_id =
      Printf.sprintf
        "keeper-%s-%Ld"
        m.name
        (Int64.of_float (Time_compat.now () *. 1000.0))
    in
    run_grpc_heartbeat_fiber
      ~sw:ctx.sw
      ~stop
      ~grpc_client:client
      ~config:ctx.config
      ~agent_name:m.agent_name
      ~session_id
      ~interval_sec:interval
      ~clock:ctx.clock
  | Masc_grpc_transport.Grpc, None ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string HeartbeatFailures)
      ~labels:[ "keeper", m.name; "site", "grpc_no_client" ]
      ();
    Log.Keeper.warn "keeper %s: gRPC transport requested but no client configured" m.name;
    None
  | _ -> None
;;

let () =
  Keeper_keepalive_signal.register_grpc_heartbeat_starter { Keeper_keepalive_signal.f = start_keeper_grpc_heartbeat }
;;
