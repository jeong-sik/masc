(* Not a test. Prints how many SSE frames per second one connection carries
   over loopback (RFC-0493 §1.4 asks for 2,616 in a second for Keeper chat).
   Every run queues all its frames before the first is written, as a burst
   does. Four ways:

   - pump: Server_sse_pump takes the frames and writes the ones already
     queued in one Server_sse_response.send, which waits for the socket.
   - send: one Server_sse_response.send per frame, each waiting for the
     socket under the response's stall bound.
   - flush: one write per frame, waiting only for its flush.
   - fire: one write per frame, dropping the flush result, as the Keeper chat
     stream wrote before RFC-0493. Nothing waits and nothing bounds what the
     writer holds.

   The server, the reader and the driver run in one process on one domain, so
   the reader's work competes with the server's writes. The numbers say what
   this path costs on this machine, not what a separate process sees. *)

module Pump = Server_sse_pump
module Sse = Server_sse_response

let frames_per_run = 20_000
let runs = 3
let frame_sizes = [ 256; 4096 ]
let stalled_after_s = 600.0
let ping_interval_s = 30.0
let last_frame = "data: end\n\n"

exception Server_stopped

let frame_of_size size = "data: " ^ String.make (size - 8) 'x' ^ "\n\n"

let serve_once ~sw env ~on_response =
  let clock = Eio.Stdenv.clock env in
  let listening, resolve_listening = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    match
      Eio.Switch.run (fun server_sw ->
        let socket =
          Eio.Net.listen ~reuse_addr:true ~backlog:4 ~sw:server_sw (Eio.Stdenv.net env)
            (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
        in
        let port =
          match Eio.Net.listening_addr socket with
          | `Tcp (_, port) -> port
          | `Unix _ -> failwith "the bench listens on TCP"
        in
        Eio.Promise.resolve resolve_listening (port, fun () -> Eio.Switch.fail server_sw Server_stopped);
        Server_bootstrap_http.serve ~sw:server_sw ~clock ~socket ~addr_label:"sse pump bench"
          ~request_handler:(fun _addr (gluten_reqd : Httpun.Reqd.t Gluten.Reqd.t) ->
            Eio.Fiber.fork ~sw:server_sw (fun () -> on_response gluten_reqd.Gluten.Reqd.reqd)))
    with
    | () -> ()
    | exception Server_stopped -> ());
  Eio.Promise.await listening
;;

let headers = Httpun.Headers.of_list [ "content-type", "text/event-stream"; "connection", "close" ]

let waits ~clock frame reqd =
  let response = Sse.respond ~clock ~stalled_after_s reqd (Httpun.Response.create ~headers `OK) in
  let queue = Pump.Queue.create ~max_queued_events:(frames_per_run + 1) in
  for _ = 1 to frames_per_run do
    Pump.Queue.push queue `Frame
  done;
  Pump.Queue.push queue `Last;
  (match
     Pump.run ~queue
       ~step:(function `Frame -> Pump.Send frame | `Last -> Pump.Send_last last_frame)
       ~idle:(fun () -> Pump.Finish)
       ~clock ~ping_interval_s ~send:(Sse.send response)
   with
   | Pump.Finished -> ()
   | Client_gone | Fell_behind | Stalled -> failwith "the waiting run did not finish");
  Sse.close response
;;

let flush_only frame reqd =
  let writer = Httpun.Reqd.respond_with_streaming reqd (Httpun.Response.create ~headers `OK) in
  for _ = 1 to frames_per_run do
    Httpun.Body.Writer.write_string writer frame;
    let p, r = Eio.Promise.create () in
    Httpun.Body.Writer.flush writer (fun _ -> Eio.Promise.resolve r ());
    Eio.Promise.await p
  done;
  Httpun.Body.Writer.write_string writer last_frame;
  Httpun.Body.Writer.close writer
;;

let send_only ~clock frame reqd =
  let response = Sse.respond ~clock ~stalled_after_s reqd (Httpun.Response.create ~headers `OK) in
  for _ = 1 to frames_per_run do
    ignore (Sse.send response frame : Sse.outcome)
  done;
  ignore (Sse.send response last_frame : Sse.outcome);
  Sse.close response
;;

let fire_and_forget frame reqd =
  let writer = Httpun.Reqd.respond_with_streaming reqd (Httpun.Response.create ~headers `OK) in
  for _ = 1 to frames_per_run do
    Httpun.Body.Writer.write_string writer frame;
    Httpun.Body.Writer.flush writer (fun _ -> ())
  done;
  Httpun.Body.Writer.write_string writer last_frame;
  Httpun.Body.Writer.close writer
;;

let ends_with_last buf =
  let n = Buffer.length buf and m = String.length last_frame in
  n >= m && Buffer.sub buf (n - m) m = last_frame
;;

(* Reads the whole response and returns the seconds from the request to the
   last frame. *)
let measure env ~on_response =
  Eio.Switch.run (fun sw ->
    let port, stop = serve_once ~sw env ~on_response in
    let flow = Eio.Net.connect ~sw (Eio.Stdenv.net env) (`Tcp (Eio.Net.Ipaddr.V4.loopback, port)) in
    let started = Unix.gettimeofday () in
    Eio.Flow.copy_string "GET /events HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n" flow;
    let buf = Cstruct.create 65536 and seen = Buffer.create (1 lsl 20) in
    while not (ends_with_last seen) do
      let n = Eio.Flow.single_read flow buf in
      Buffer.add_string seen (Cstruct.to_string ~len:n buf)
    done;
    let elapsed = Unix.gettimeofday () -. started in
    Eio.Flow.close flow;
    stop ();
    elapsed)
;;

let median values =
  let sorted = List.sort compare values in
  List.nth sorted (List.length sorted / 2)
;;

type way =
  | Pump
  | Send
  | Flush
  | Fire

let ways = [ Pump; Send; Flush; Fire ]

let on_response ~clock frame = function
  | Pump -> waits ~clock frame
  | Send -> send_only ~clock frame
  | Flush -> flush_only frame
  | Fire -> fire_and_forget frame
;;

(* Run [run] takes the ways starting at the [run]th, so the way that runs
   first, right after the process starts or after the other frame size,
   changes from run to run. *)
let rotated run =
  let count = List.length ways in
  List.init count (fun index -> List.nth ways ((run + index) mod count))
;;

(* The seconds of every run, per way. [List.init] evaluates the runs left to
   right and [List.fold_left] takes the ways in list order. *)
let seconds_per_way env ~clock frame =
  let runs =
    List.init runs (fun run ->
      List.fold_left
        (fun measured way -> (way, measure env ~on_response:(on_response ~clock frame way)) :: measured)
        [] (rotated run))
  in
  fun way -> List.concat_map (List.filter_map (fun (w, s) -> if w = way then Some s else None)) runs
;;

let () =
  Eio_main.run (fun env ->
    let clock = Eio.Stdenv.clock env in
    Printf.printf "%d frames per run, median of %d runs, each run in a rotated order\n" frames_per_run
      runs;
    List.iter
      (fun size ->
         let seconds = seconds_per_way env ~clock (frame_of_size size) in
         let rate way = float_of_int frames_per_run /. median (seconds way) in
         let pump = rate Pump in
         let send = rate Send in
         let flush = rate Flush in
         let fire = rate Fire in
         Printf.printf "%5d B  pump %9.0f  send %9.0f  flush %9.0f  fire %9.0f frames/s\n%!" size pump
           send flush fire)
      frame_sizes)
;;
