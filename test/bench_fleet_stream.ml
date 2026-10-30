(* Not a test. Prints how long the fleet stream (RFC-0477) takes from a change
   in the hub to the reader's view, over loopback, for several fleet sizes and
   subscriber counts, on two transports.

   - SSE: the real accept loop and the route's [serve] (everything but the
     authorization) on the server; the terminal's HTTP client and
     Masc_tui_fleet_stream on the reader.
   - gRPC: a [Subscribe]-style server-streaming method on grpc-direct. Each
     message is a protobuf message whose field 1 holds the same JSON the SSE
     frame holds, as [payload_json] does in proto/masc_workspace.proto. The
     reader strips that envelope and decodes with the same strict codec. There
     is no generated code, no authentication and none of the pump's bound or
     keepalive, so this is the cheapest gRPC path: it can only flatter gRPC.

   Server, subscribers and the driver run in one process on one domain, so a
   subscriber's parsing competes with the server's writing. The numbers say
   what this path costs on this machine, not what a separate process sees. *)

module F = Masc.Fleet_stream
module Hub = Masc.Fleet_stream_hub
module Client = Masc_tui_fleet_stream
module Route = Server_routes_http_routes_fleet_stream

let queue_bound = 64
let ping_interval_s = 30.0

(* No run of the bench stalls a reader for this long. *)
let stalled_after_s = 600.0
let client_idle_timeout_s = 120.0
let wait_poll_s = 0.0002

(* A burst publishes this many changes back to back, below the queue bound. *)
let burst_size = 16

(* Enough changes to fill the kernel buffers behind a client that stopped
   reading, at 300 keepers. *)
let stalled_events = 2000
let events = 200

let fleet ~keepers ~running : F.fleet =
  let names =
    F.Names.of_list (List.init keepers (fun index -> Printf.sprintf "keeper-%04d" index))
  in
  { F.fs_status = Masc.Keeper_fleet_grade.Fleet_ok
  ; fs_blocker = None
  ; fs_operator_action_required = false
  ; fs_bootable_count = keepers
  ; fs_running_count = running
  ; fs_executable_count = keepers
  ; fs_failing_count = 0
  ; fs_recovering_count = 0
  ; fs_turn_configuration_error_count = 0
  ; fs_official_client_recovery_required_count = 0
  ; fs_paused_count = 0
  ; fs_target_reaction_capacity = keepers
  ; fs_reaction_capacity_shortfall = 0
  ; fs_bootable_names = names
  ; fs_running_names = names
  ; fs_executable_names = names
  ; fs_turn_configuration_error_names = F.Names.empty
  ; fs_official_client_recovery_required_names = F.Names.empty
  ; fs_active_task_owner_without_fiber_count = 0
  ; fs_completion_authority_pending_count = 0
  ; fs_active_task_owner_scan_error_count = 0
  }
;;

let percentile sorted fraction =
  let count = Array.length sorted in
  if count = 0
  then Float.nan
  else sorted.(min (count - 1) (int_of_float (fraction *. float_of_int count)))
;;

(* What a scenario needs from a transport: a server for [hub] on some port, a
   reader that reports each revision it applies and each message's size, and
   (when the transport has one) a reader that takes its first message and then
   stops reading. *)
type transport =
  { name : string
  ; serve : sw:Eio.Switch.t -> env:Eio_unix.Stdenv.base -> hub:Hub.t -> int
  ; read :
      sw:Eio.Switch.t
      -> env:Eio_unix.Stdenv.base
      -> port:int
      -> on_revision:(int -> unit)
      -> on_bytes:(int -> unit)
      -> unit
  ; read_then_stall :
      (sw:Eio.Switch.t -> env:Eio_unix.Stdenv.base -> port:int -> stalled:int ref -> unit) option
  }

let free_port env =
  Eio.Switch.run (fun sw ->
    let socket =
      Eio.Net.listen ~reuse_addr:true ~backlog:1 ~sw (Eio.Stdenv.net env)
        (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
    in
    match Eio.Net.listening_addr socket with
    | `Tcp (_, port) -> port
    | `Unix _ -> failwith "the bench listens on TCP")
;;

(* A reader that cannot read the stream stops the bench instead of leaving it
   waiting for a snapshot that will not come. *)
let sse =
  let url port = Printf.sprintf "http://127.0.0.1:%d%s" port F.stream_path in
  let headers = [ "Accept", "text/event-stream" ] in
  let get ~sw ~env ~port ~on_chunk =
    Eio.Fiber.fork_daemon ~sw (fun () ->
      (match
         Masc_http_client.get_stream
           ~clock:(Eio.Stdenv.clock env)
           ~idle_timeout_sec:client_idle_timeout_s
           ~url:(url port)
           ~headers
           ~on_chunk
           ()
       with
       | Ok (Masc_http_client.Pool.Streamed _) -> ()
       | Ok (Masc_http_client.Pool.Buffered { status; body; _ }) ->
         failwith (Printf.sprintf "the server refused the reader with %d: %s" status body)
       | Error detail -> failwith ("the reader could not connect: " ^ detail));
      `Stop_daemon)
  in
  { name = "sse"
  ; serve =
      (fun ~sw ~env ~hub ->
         let clock = Eio.Stdenv.clock env in
         let socket =
           Eio.Net.listen ~reuse_addr:true ~backlog:128 ~sw (Eio.Stdenv.net env)
             (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
         in
         let port =
           match Eio.Net.listening_addr socket with
           | `Tcp (_, port) -> port
           | `Unix _ -> failwith "the bench listens on TCP"
         in
         Eio.Fiber.fork_daemon ~sw (fun () ->
           Server_bootstrap_http.serve
             ~sw
             ~clock
             ~socket
             ~addr_label:"bench"
             ~request_handler:(fun _addr (gluten_reqd : Httpun.Reqd.t Gluten.Reqd.t) ->
               Route.serve
                 ~sw
                 ~clock
                 ~subscribe:(Hub.subscribe hub)
                 ~ping_interval_s
                 ~stalled_after_s
                 ~max_queued_events:queue_bound
                 gluten_reqd.Gluten.Reqd.reqd);
           `Stop_daemon);
         port)
  ; read =
      (fun ~sw ~env ~port ~on_revision ~on_bytes ->
         let reader = Client.create () in
         Client.started reader;
         get ~sw ~env ~port ~on_chunk:(fun chunk ->
           on_bytes (String.length chunk);
           match Client.feed reader chunk with
           | Client.Reconnect -> failwith "the bench reader was asked to reconnect"
           | Client.Keep_reading ->
             (match Client.view reader with
              | Client.Reading { reading; _ } ->
                on_revision (F.Revision.to_int reading.Client.revision)
              | Client.Awaiting_first_reading | Client.Unreachable _ | Client.Unavailable _
              | Client.Cannot_read _ -> ())))
  ; read_then_stall =
      Some
        (fun ~sw ~env ~port ~stalled ->
           get ~sw ~env ~port ~on_chunk:(fun _ ->
             incr stalled;
             Eio.Time.sleep (Eio.Stdenv.clock env) 3600.0))
  }
;;

(* gRPC messages are protobuf: field 1, length-delimited, holding the JSON. *)
let proto_field_1 = '\x0a'

let add_varint buffer length =
  let rec go n =
    if n < 0x80
    then Buffer.add_char buffer (Char.chr n)
    else (
      Buffer.add_char buffer (Char.chr (n land 0x7f lor 0x80));
      go (n lsr 7))
  in
  go length
;;

let wrap json_text =
  let buffer = Buffer.create (String.length json_text + 8) in
  Buffer.add_char buffer proto_field_1;
  add_varint buffer (String.length json_text);
  Buffer.add_string buffer json_text;
  Buffer.contents buffer
;;

let unwrap message =
  if message.[0] <> proto_field_1 then failwith "a gRPC message without field 1";
  let rec varint position shift acc =
    let byte = Char.code message.[position] in
    let acc = acc lor ((byte land 0x7f) lsl shift) in
    if byte < 0x80 then acc, position + 1 else varint (position + 1) (shift + 7) acc
  in
  let length, start = varint 1 0 0 in
  String.sub message start length
;;

let grpc_service = "masc.fleet.v1.FleetStream"
let grpc_method = "Subscribe"

let grpc =
  let connect ~sw ~env ~port =
    let client = Grpc_eio.Client.connect ~sw ~env (Printf.sprintf "http://127.0.0.1:%d" port) in
    Grpc_eio.Client.call_server_streaming ~sw ~env client ~service:grpc_service
      ~method_:grpc_method ~request:""
  in
  { name = "grpc"
  ; serve =
      (fun ~sw ~env ~hub ->
         let port = free_port env in
         let handler (_request : string) : string Grpc_eio.Stream.t =
           let out = Grpc_eio.Stream.create queue_bound in
           let queue = Eio.Stream.create max_int in
           let (_ : unit -> unit) =
             Hub.subscribe hub ~on_event:(fun event -> Eio.Stream.add queue event)
           in
           Eio.Fiber.fork_daemon ~sw (fun () ->
             while true do
               let event = Eio.Stream.take queue in
               Grpc_eio.Stream.add out (wrap (Yojson.Safe.to_string (F.encode event)))
             done;
             `Stop_daemon);
           out
         in
         let service =
           Grpc_eio.Service.create grpc_service
           |> Grpc_eio.Service.add_server_streaming grpc_method handler
         in
         let server =
           Grpc_eio.Server.create
             ~config:{ Grpc_eio.Server.default_config with port }
             ()
           |> Grpc_eio.Server.add_service service
         in
         Eio.Fiber.fork_daemon ~sw (fun () ->
           Grpc_eio.Server.serve ~sw ~env server;
           `Stop_daemon);
         (* serve returns nothing to wait on: connect until it accepts. *)
         let rec wait_for_listener attempts =
           match
             Eio.Switch.run (fun probe ->
               Eio.Flow.close
                 (Eio.Net.connect ~sw:probe (Eio.Stdenv.net env)
                    (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))))
           with
           | () -> ()
           | exception (Eio.Io _ as exn) ->
             if attempts = 0 then raise exn;
             Eio.Time.sleep (Eio.Stdenv.clock env) 0.01;
             wait_for_listener (attempts - 1)
         in
         wait_for_listener 200;
         port)
  ; read =
      (fun ~sw ~env ~port ~on_revision ~on_bytes ->
         let messages = connect ~sw ~env ~port in
         Eio.Fiber.fork_daemon ~sw (fun () ->
           let rec loop () =
             match Grpc_eio.Stream.take messages with
             | Ok message ->
               on_bytes (String.length message);
               (match F.decode (Yojson.Safe.from_string (unwrap message)) with
                | Ok event ->
                  on_revision (F.Revision.to_int (F.revision_of_event event));
                  loop ()
                | Error error ->
                  failwith ("a gRPC message did not decode: " ^ F.decode_error_to_string error))
             | Error _status -> ()
             | exception End_of_file -> ()
           in
           loop ();
           `Stop_daemon))
  ; read_then_stall = None
  }
;;

type outcome =
  { latencies_ms : float array
  ; bytes_per_event : float
  ; cpu_ms_per_event : float
  }

exception Scenario_done

(* One scenario: [subscribers] readers, one hub change per event, and
   optionally a reader that stops reading after its first chunk. [burst]
   publishes [burst_size] changes back to back before it waits for the
   readers. *)
let scenario env transport ~keepers ~subscribers ~events ~burst ~stalled =
  let measured = ref None in
  (* The accept loop forks one fiber per connection into [sw], and a reader
     keeps its stream open, so the switch would never end by itself: once the
     numbers are taken it is failed with [Scenario_done] and torn down. *)
  (match
     Eio.Switch.run (fun sw ->
       let clock = Eio.Stdenv.clock env in
       let hub =
         Hub.create ~on_subscriber_error:(fun exn ->
           Printf.eprintf "subscriber raised: %s\n%!" (Printexc.to_string exn))
       in
       let published_at = Array.make (events + 2) 0.0 in
       let applied_at = Array.init subscribers (fun _ -> Array.make (events + 2) 0.0) in
       let latest = Array.make subscribers 0 in
       let received_bytes = ref 0 in
       Hub.observe hub ~measured_at:0.0 (fleet ~keepers ~running:0);
       let port = transport.serve ~sw ~env ~hub in
       for index = 0 to subscribers - 1 do
         transport.read ~sw ~env ~port
           ~on_bytes:(fun size -> received_bytes := !received_bytes + size)
           ~on_revision:(fun revision ->
             let now = Unix.gettimeofday () in
             for seen = latest.(index) + 1 to min revision (events + 1) do
               applied_at.(index).(seen) <- now
             done;
             latest.(index) <- max latest.(index) revision)
       done;
       let all_applied revision = Array.for_all (fun seen -> seen >= revision) latest in
       let wait_for revision =
         while not (all_applied revision) do
           Eio.Time.sleep clock wait_poll_s
         done
       in
       wait_for 1;
       (match stalled, transport.read_then_stall with
        | false, _ -> ()
        | true, Some stall ->
          let stalled_chunks = ref 0 in
          stall ~sw ~env ~port ~stalled:stalled_chunks;
          while !stalled_chunks = 0 do
            Eio.Time.sleep clock wait_poll_s
          done
        | true, None -> failwith (transport.name ^ " has no stalled reader"));
       let cpu_before = Sys.time () in
       let bytes_before = !received_bytes in
       for index = 1 to events do
         published_at.(index + 1) <- Unix.gettimeofday ();
         Hub.observe hub ~measured_at:(float_of_int index) (fleet ~keepers ~running:index);
         if (not burst) || index mod burst_size = 0 then wait_for (index + 1)
       done;
       wait_for (events + 1);
       let cpu_after = Sys.time () in
       let latencies =
         Array.concat
           (List.init subscribers (fun index ->
              Array.init events (fun offset ->
                (applied_at.(index).(offset + 2) -. published_at.(offset + 2)) *. 1000.0)))
       in
       Array.sort Float.compare latencies;
       measured :=
         Some
           { latencies_ms = latencies
           ; bytes_per_event =
               float_of_int (!received_bytes - bytes_before)
               /. float_of_int (events * subscribers)
           ; cpu_ms_per_event = (cpu_after -. cpu_before) *. 1000.0 /. float_of_int events
           };
       Eio.Switch.fail sw Scenario_done)
   with
   | () -> ()
   | exception Scenario_done -> ());
  match !measured with
  | Some outcome -> outcome
  | None -> failwith "the scenario ended without taking its numbers"
;;

let print_row env transport ~keepers ~subscribers ~events ~burst ~stalled =
  let outcome = scenario env transport ~keepers ~subscribers ~events ~burst ~stalled in
  Printf.printf
    "%-5s %7d %5d %6d %-6s %-7s %6.2f %6.2f %7.2f %11.0f %9.2f\n%!"
    transport.name
    keepers
    subscribers
    events
    (if burst then "burst" else "single")
    (if stalled then "stalled" else "-")
    (percentile outcome.latencies_ms 0.50)
    (percentile outcome.latencies_ms 0.99)
    (percentile outcome.latencies_ms 1.0)
    outcome.bytes_per_event
    outcome.cpu_ms_per_event
;;

let () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun root ->
      Masc_http_client.with_scoped_pool ~sw:root ~env (fun () ->
      Printf.printf
        "trans  keepers  subs events mode   reader  p50_ms p99_ms  max_ms bytes/event  cpu_ms/ev\n%!";
      (* Both transports run one after the other for each scenario, so a busy
         machine slows both alike. *)
      List.iter
        (fun (keepers, subscribers, events, burst, stalled) ->
           List.iter
             (fun transport ->
                if (not stalled) || Option.is_some transport.read_then_stall
                then print_row env transport ~keepers ~subscribers ~events ~burst ~stalled)
             [ sse; grpc ])
        [ 40, 1, events, false, false
        ; 40, 5, events, false, false
        ; 300, 1, events, false, false
        ; 300, 5, events, false, false
        ; 300, 5, events, true, false
        ; 300, 5, stalled_events, false, true
        ])))
;;
