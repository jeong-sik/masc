
(* ---- throughput probe: one large response over TCP loopback ----
   Appended to test/test_h2_request_fibers.ml, whose helpers it uses (run7
   in this bundle's README).
   The server runs on this domain. The client is hand-written HTTP/2 on a
   domain of its own, so its reads do not wait for this domain's scheduler,
   and it decides when to return flow-control credit:
     frame  WINDOW_UPDATE for every DATA frame (ocaml-h2's own client,
            client_connection.ml [done_reading])
     go     x/net/http2 [inflow.add]: when 4 KiB are owed, or when what is
            owed is at least what the server may still send
     half   when half the window is owed (nghttp2
            [nghttp2_should_send_window_update]; Chromium also returns it
            after a time, which this does not model)
   TP_SCENES lists scenes "mib:stream_window:conn_window:policy:busy_us:rounds"
   separated by ';'. [busy_us] is the CPU time another fiber of the server's
   domain takes on every scheduler turn. *)
let tp_out line =
  match Sys.getenv_opt "TP_OUT" with
  | None -> print_endline line
  | Some file ->
    Out_channel.with_open_gen [ Open_append; Open_creat ] 0o644 file (fun oc ->
      output_string oc (line ^ "\n"))

let tp_spin_us us =
  let until = Unix.gettimeofday () +. (float_of_int us /. 1e6) in
  while Unix.gettimeofday () < until do () done

(* The listener sets TCP_NODELAY on what it accepts
   (server_bootstrap_http.ml [disable_nagle]); so do the clients measured
   against. Without it Nagle and the delayed ACK hold every window round. *)
let tp_nodelay flow =
  Eio_unix.Fd.use_exn "TCP_NODELAY" (Eio_unix.Net.fd flow) (fun fd ->
    Unix.setsockopt fd Unix.TCP_NODELAY true)

let tp_u32 n =
  let b = Bytes.create 4 in
  Bytes.set_int32_be b 0 (Int32.of_int n);
  Bytes.to_string b

let tp_frame ~kind ~flags ~stream payload =
  let n = String.length payload in
  let b = Bytes.create (9 + n) in
  Bytes.set_uint8 b 0 ((n lsr 16) land 0xff);
  Bytes.set_uint8 b 1 ((n lsr 8) land 0xff);
  Bytes.set_uint8 b 2 (n land 0xff);
  Bytes.set_uint8 b 3 kind;
  Bytes.set_uint8 b 4 flags;
  Bytes.set_int32_be b 5 (Int32.of_int stream);
  Bytes.blit_string payload 0 b 9 n;
  Bytes.to_string b

let tp_window_update ~stream n = tp_frame ~kind:8 ~flags:0 ~stream (tp_u32 n)

type tp_policy = Per_frame | Go_like | Half_window

let tp_policy_of_string = function
  | "frame" -> Per_frame
  | "go" -> Go_like
  | "half" -> Half_window
  | other -> failf "throughput probe: unknown policy %s" other

(* One window of receive credit. [avail] is what the server may still send,
   [owed] what the client took and has not returned. *)
type tp_credit = { window : int; mutable avail : int; mutable owed : int }

let tp_credit window = { window; avail = window; owed = 0 }

(* Takes [n] received bytes, all read at once, and returns the credit to
   send back now. *)
let tp_take policy credit n =
  credit.avail <- credit.avail - n;
  credit.owed <- credit.owed + n;
  let due =
    match policy with
    | Per_frame -> true
    | Go_like -> not (credit.owed < 4096 && credit.owed < credit.avail)
    | Half_window -> credit.owed >= credit.window / 2
  in
  if due
  then (
    let grant = credit.owed in
    credit.avail <- credit.avail + grant;
    credit.owed <- 0;
    grant)
  else 0

type tp_run =
  { seconds : float
  ; bytes : int
  ; frames : int      (* DATA frames with a payload *)
  ; small : int       (* of those, under 1 KiB *)
  ; smallest : int
  ; whole : bool
  }

let tp_client ~net ~addr ~stream_window ~conn_window ~policy () =
  Eio.Switch.run (fun sw ->
    let flow = Eio.Net.connect ~sw net addr in
    tp_nodelay flow;
    let lit index text =
      Printf.sprintf "%c%c%s" (Char.chr index) (Char.chr (String.length text)) text in
    let settings = tp_frame ~kind:4 ~flags:0 ~stream:0 ("\x00\x04" ^ tp_u32 stream_window) in
    let open_connection =
      if conn_window > 65535 then tp_window_update ~stream:0 (conn_window - 65535) else "" in
    (* HPACK: static 2 = :method GET, 6 = :scheme http; literals named by
       static 4 (:path) and 1 (:authority). END_HEADERS and END_STREAM. *)
    let headers = tp_frame ~kind:1 ~flags:0x5 ~stream:1
      ("\x82\x86" ^ lit 4 "/big" ^ lit 1 "localhost") in
    let started = Unix.gettimeofday () in
    Eio.Flow.copy_string
      ("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" ^ settings ^ open_connection ^ headers) flow;
    let reader = Eio.Buf_read.of_flow flow ~initial_size:65536 ~max_size:(1 lsl 20) in
    let conn = tp_credit conn_window and stream = tp_credit stream_window in
    let bytes = ref 0 and frames = ref 0 and small = ref 0 and smallest = ref max_int in
    let skip len =
      Eio.Buf_read.ensure reader len;
      Eio.Buf_read.consume reader len in
    let rec loop () =
      let header = Eio.Buf_read.take 9 reader in
      let len = (Char.code header.[0] lsl 16) lor (Char.code header.[1] lsl 8)
                lor Char.code header.[2] in
      let kind = Char.code header.[3] and flags = Char.code header.[4] in
      skip len;
      match kind with
      | 0 ->
        if len > 0 then (
          incr frames;
          bytes := !bytes + len;
          if len < 1024 then incr small;
          if len < !smallest then smallest := len);
        let ended = flags land 1 <> 0 in
        let conn_grant = tp_take policy conn len in
        let stream_grant = if ended then 0 else tp_take policy stream len in
        let updates =
          (if conn_grant > 0 then tp_window_update ~stream:0 conn_grant else "")
          ^ (if stream_grant > 0 then tp_window_update ~stream:1 stream_grant else "") in
        if updates <> "" then Eio.Flow.copy_string updates flow;
        if ended then true else loop ()
      | 1 -> if flags land 1 <> 0 then true else loop ()
      | 4 ->
        if flags land 1 = 0
        then Eio.Flow.copy_string (tp_frame ~kind:4 ~flags:1 ~stream:0 "") flow;
        loop ()
      | 3 | 7 -> false
      | _ -> loop ()
    in
    let whole = try loop () with End_of_file -> false in
    let seconds = Unix.gettimeofday () -. started in
    Eio.Flow.shutdown flow `All;
    { seconds; bytes = !bytes; frames = !frames; small = !small
    ; smallest = (if !frames = 0 then 0 else !smallest); whole })

let tp_once ~env ~body ~stream_window ~conn_window ~policy ~busy_us =
  let handler ~stream_end _ h2_reqd =
    Masc.Http_reqd.respond_with_string (reqd_of_h2 ~stream_end h2_reqd)
      (Httpun.Response.create `OK) body in
  Eio.Switch.run (fun sw ->
    let net = Eio.Stdenv.net env in
    let clock = Eio.Stdenv.clock env in
    let listening = Eio.Net.listen ~sw ~backlog:1 ~reuse_addr:true net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0)) in
    let addr = Eio.Net.listening_addr listening in
    Eio.Fiber.fork_daemon ~sw (fun () ->
      Eio.Switch.run (fun conn_sw ->
        let flow, client_addr = Eio.Net.accept ~sw:conn_sw listening in
        tp_nodelay flow;
        Server_bootstrap_http.serve_h2_connection ~clock ~resources:(stalled_ledger ())
          ~sw:conn_sw ~h2_request_handler:handler
          ~h2_error_handler:(Server_h2_gateway.make_error_handler ()) client_addr flow);
      `Stop_daemon);
    if busy_us > 0
    then
      Eio.Fiber.fork_daemon ~sw (fun () ->
        while true do
          tp_spin_us busy_us;
          Eio.Fiber.yield ()
        done;
        `Stop_daemon);
    let run =
      Eio.Domain_manager.run (Eio.Stdenv.domain_mgr env)
        (tp_client ~net ~addr ~stream_window ~conn_window ~policy) in
    if not (run.whole && run.bytes = String.length body)
    then failf "throughput probe: got %d of %d bytes" run.bytes (String.length body);
    run)

let tp_scenes () =
  Option.value (Sys.getenv_opt "TP_SCENES") ~default:"1:65535:65535:frame:0:1"
  |> String.split_on_char ';'
  |> List.filter (fun scene -> scene <> "")

let tp_probe () =
  let label = Option.value (Sys.getenv_opt "TP_LABEL") ~default:"?" in
  Eio_main.run (fun env ->
    List.iter (fun scene ->
      match String.split_on_char ':' scene with
      | [ mib; stream_window; conn_window; policy; busy_us; rounds ] ->
        let rounds = int_of_string rounds in
        let body = String.make (int_of_string mib * 1024 * 1024) 'b' in
        let once () =
          tp_once ~env ~body ~stream_window:(int_of_string stream_window)
            ~conn_window:(int_of_string conn_window)
            ~policy:(tp_policy_of_string policy) ~busy_us:(int_of_string busy_us) in
        let runs = List.sort (fun a b -> Float.compare a.seconds b.seconds)
          (List.init rounds (fun _ -> once ())) in
        let median = List.nth runs (rounds / 2) in
        tp_out (Printf.sprintf
          "%s %s ms_min=%.1f ms_median=%.1f ms_max=%.1f mib_per_s=%.1f data_frames=%d under_1k=%d smallest=%d"
          label scene
          (1000. *. (List.hd runs).seconds) (1000. *. median.seconds)
          (1000. *. (List.nth runs (rounds - 1)).seconds)
          (float_of_string mib /. median.seconds)
          median.frames median.small median.smallest)
      | _ -> failf "throughput probe: bad scene %s" scene)
      (tp_scenes ()))

let tp_cases = [ test_case "large response over TCP loopback" `Quick tp_probe ]
