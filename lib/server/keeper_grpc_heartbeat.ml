open Keeper_types
open Keeper_meta_contract
open Keeper_keepalive

let grpc_client_ref : Masc_grpc_client.t option Atomic.t = Atomic.make None
let grpc_env_ref : Eio_unix.Stdenv.base option Atomic.t = Atomic.make None

let set_grpc_client ?(env : Eio_unix.Stdenv.base option) c =
  Atomic.set grpc_client_ref (Some c);
  Atomic.set grpc_env_ref env
;;

let make_grpc_heartbeat_ping ~config ~agent_name ~session_id ~auth_token =
  Masc_grpc_types.HeartbeatPing.
    { agent_name
    ; session_id
    ; timestamp_ms = Int64.of_float (Time_compat.now () *. 1000.0)
    ; current_task_id = Keeper_keepalive.current_task_id_for_agent ~config agent_name
    ; auth_token
    }
;;

let handle_grpc_heartbeat_ack ~agent_name (ack : Masc_grpc_types.HeartbeatAck.t) =
  Log.Keeper.debug
    "gRPC bidi heartbeat: agent=%s agents=%d tasks=%d"
    agent_name
    ack.active_agent_count
    ack.pending_task_count
;;

exception Grpc_heartbeat_stream_error of string
exception Grpc_heartbeat_stop

let run_grpc_heartbeat_stream
      ~stop
      ~close_ref
      ~clock
      ~interval_sec
      ~config
      ~agent_name
      ~session_id
      ~auth_token
      ~on_ack
      send
      recv
  =
  let rec tick () =
    if Atomic.get stop || Atomic.get close_ref
    then ()
    else (
      (try
         send (make_grpc_heartbeat_ping ~config ~agent_name ~session_id ~auth_token);
         match recv () with
         | Ok ack ->
           on_ack ();
           handle_grpc_heartbeat_ack ~agent_name ack
         | Error err ->
           Otel_metric_store.inc_counter
             Keeper_metrics.(to_string HeartbeatFailures)
             ~labels:[ "keeper", agent_name; "site", "grpc_recv" ]
             ();
           raise (Grpc_heartbeat_stream_error err)
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | End_of_file -> raise End_of_file
       | Grpc_heartbeat_stream_error _ as exn -> raise exn
       | exn ->
         Otel_metric_store.inc_counter
           Keeper_metrics.(to_string HeartbeatFailures)
           ~labels:[ "keeper", agent_name; "site", "grpc_tick" ]
           ();
         Log.Keeper.error "gRPC heartbeat tick error: %s" (Printexc.to_string exn);
         raise exn);
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
      "gRPC heartbeat stream closed for %s (consecutive reconnect %d)"
      agent_name
      (attempts + 1)
  | `Error message ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string HeartbeatFailures)
      ~labels:[ "keeper", agent_name; "site", "grpc_stream" ]
      ();
    Log.Keeper.warn
      "gRPC heartbeat stream error for %s: %s (consecutive reconnect %d)"
      agent_name
      message
      (attempts + 1)
;;

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
    let active_cancel_ref : (unit -> unit) option Atomic.t = Atomic.make None in
    Eio.Fiber.fork ~sw (fun () ->
      let rec connect_loop attempts =
        if Atomic.get stop || Atomic.get close_ref
        then ()
        else (
          let received_ack = ref false in
          let outcome =
            match
              Auth.ensure_keeper_credential config.base_path ~agent_name
            with
            | Error err ->
              let message = Masc_domain.masc_error_to_string err in
              Otel_metric_store.inc_counter
                Keeper_metrics.(to_string HeartbeatFailures)
                ~labels:[ "keeper", agent_name; "site", "grpc_credential" ]
                ();
              `Error message
            | Ok (auth_token, _credential) ->
              Fun.protect
                ~finally:(fun () -> Atomic.set active_cancel_ref None)
                (fun () ->
                  try
                    Eio.Switch.run ~name:("grpc-heartbeat:" ^ agent_name) (fun stream_sw ->
                      let cancel () =
                        try Eio.Switch.fail stream_sw Grpc_heartbeat_stop with
                        | Invalid_argument _ -> ()
                      in
                      Atomic.set active_cancel_ref (Some cancel);
                      if Atomic.get stop || Atomic.get close_ref
                      then (
                        cancel ();
                        Eio.Switch.check stream_sw);
                      let send, recv, close_stream =
                        Masc_grpc_client.heartbeat_stream
                          grpc_client
                          ~sw:stream_sw
                          ~env
                      in
                      Fun.protect
                        ~finally:close_stream
                        (fun () ->
                          run_grpc_heartbeat_stream
                            ~stop
                            ~close_ref
                            ~clock
                            ~interval_sec
                            ~config
                            ~agent_name
                            ~session_id
                            ~auth_token
                            ~on_ack:(fun () -> received_ack := true)
                            send
                            recv;
                          raise Grpc_heartbeat_stop));
                    `Stopped
                  with
                  | Grpc_heartbeat_stop -> `Stopped
                  | End_of_file -> `Closed
                  | Grpc_heartbeat_stream_error message -> `Error message
                  | Eio.Cancel.Cancelled _ as exn -> raise exn
                  | exn -> `Error (Printexc.to_string exn))
          in
          match outcome with
          | `Stopped -> ()
          | (`Closed | `Error _) as failure ->
            log_grpc_heartbeat_stream_failure ~agent_name ~attempts failure;
            if not (Atomic.get stop || Atomic.get close_ref)
            then (
              ignore
                (Keeper_keepalive_signal.interruptible_sleep
                   ~clock
                   ~stop
                   ~wakeup:close_ref
                   reconnect_backoff_sec
                 : Keeper_keepalive_signal.sleep_outcome);
              let next_attempts = if !received_ack then 0 else attempts + 1 in
              connect_loop next_attempts))
      in
      connect_loop 0);
    Some
      (fun () ->
         Atomic.set close_ref true;
         Option.iter (fun cancel -> cancel ()) (Atomic.get active_cancel_ref))
;;

let start_keeper_grpc_heartbeat
      ~(ctx : _ Keeper_types_profile.context)
      ~(m : keeper_meta)
      ~(stop : bool Atomic.t)
  : (unit -> unit) option
  =
  match Masc_grpc_transport.from_env (), Atomic.get grpc_client_ref with
  | Masc_grpc_transport.Grpc, Some client ->
    (match Auth.ensure_keeper_credential ctx.config.base_path ~agent_name:m.agent_name with
     | Error err ->
       Otel_metric_store.inc_counter
         Keeper_metrics.(to_string HeartbeatFailures)
         ~labels:[ "keeper", m.name; "site", "grpc_credential" ]
         ();
       Log.Keeper.error
         "keeper %s: cannot start gRPC heartbeat without an owning credential: %s"
         m.name
         (Masc_domain.masc_error_to_string err);
       None
     | Ok _ ->
       Log.Keeper.info
         "keeper %s: starting credential-bound gRPC heartbeat fiber"
         m.name;
       let interval =
         float_of_int (Keeper_heartbeat_snapshot.keepalive_interval_sec ())
       in
       let session_id =
         Random_id.prefixed ~prefix:("keeper-" ^ m.name ^ "-") ~bytes:16
       in
       let sw =
         Option.value (Keeper_supervisor.get_global_switch ()) ~default:ctx.sw
       in
       run_grpc_heartbeat_fiber
         ~sw
         ~stop
         ~grpc_client:client
         ~config:ctx.config
         ~agent_name:m.agent_name
         ~session_id
         ~interval_sec:interval
         ~clock:ctx.clock)
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
