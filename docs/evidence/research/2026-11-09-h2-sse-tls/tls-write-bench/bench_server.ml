(* One TLS 1.3 listener on 127.0.0.1:<port>. Each connection reads "<n>\n",
   writes <n> payloads of <payload> bytes through the TLS flow in
   single_write calls of <write> bytes, sends close_notify and prints one JSON
   line. The sink decides what tls-eio copies its ciphertext into:
   "stock" is the accepted socket itself (Eio's 4096-byte copy fallback),
   "copy:<bytes>" wraps the socket so each copy reaches it in writes of up to
   <bytes>, through one buffer kept for the connection. "pieces" is the
   policy of RFC-0518 D8: every copy call makes its own buffer of one TLS 1.3
   record (16,384 + 22 bytes) and, when the first read fills it, goes on with
   one of 256 KiB. *)

module Chunked = struct
  type tag = [ `Generic ]

  type t =
    { socket : [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t
    ; buf : Cstruct.t
    }

  let read_methods = []
  let single_read t dst = Eio.Flow.single_read t.socket dst
  let single_write t bufs = Eio.Flow.single_write t.socket bufs

  let copy t ~src =
    try
      while true do
        let got = Eio.Flow.single_read src t.buf in
        Eio.Flow.write t.socket [ Cstruct.sub t.buf 0 got ]
      done
    with
    | End_of_file -> ()

  let shutdown t cmd = Eio.Flow.shutdown t.socket cmd
  let close t = Eio.Resource.close t.socket
end

let chunked_handler = Eio.Net.Pi.stream_socket (module Chunked)

module Pieces = struct
  type tag = [ `Generic ]
  type t = [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t

  let record_bytes = 16_384 + 22
  let piece_bytes = 256 * 1024
  let read_methods = []
  let single_read t dst = Eio.Flow.single_read t dst
  let single_write t bufs = Eio.Flow.single_write t bufs

  let copy t ~src =
    let rec go buf =
      match Eio.Flow.single_read src buf with
      | exception End_of_file -> ()
      | got ->
        Eio.Flow.write t [ Cstruct.sub buf 0 got ];
        if got = Cstruct.length buf && got < piece_bytes
        then go (Cstruct.create_unsafe piece_bytes)
        else go buf
    in
    go (Cstruct.create_unsafe record_bytes)

  let shutdown t cmd = Eio.Flow.shutdown t cmd
  let close t = Eio.Resource.close t
end

let pieces_handler = Eio.Net.Pi.stream_socket (module Pieces)

let cpu () =
  let t = Unix.times () in
  t.Unix.tms_utime +. t.Unix.tms_stime

let read_file name = In_channel.with_open_bin name In_channel.input_all

let () =
  match Sys.argv with
  | [| _; port; cert; key; sink; cipher; payload; write |] ->
    Mirage_crypto_rng_unix.use_default ();
    let certs =
      match X509.Certificate.decode_pem_multiple (read_file cert) with
      | Ok c -> c
      | Error (`Msg m) -> failwith ("cert: " ^ m)
    in
    let key =
      match X509.Private_key.decode_pem (read_file key) with
      | Ok k -> k
      | Error (`Msg m) -> failwith ("key: " ^ m)
    in
    let ciphers =
      match cipher with
      | "aes128" -> [ `AES_128_GCM_SHA256 ]
      | "aes256" -> [ `AES_256_GCM_SHA384 ]
      | "chacha" -> [ `CHACHA20_POLY1305_SHA256 ]
      | other -> failwith ("cipher: " ^ other)
    in
    let config =
      match
        Tls.Config.server
          ~certificates:(`Single (certs, key))
          ~version:(`TLS_1_3, `TLS_1_3)
          (* tls 2.1.5 refuses an EC certificate without a suite that names EC
             keys, and the TLS 1.3 suites name none. The listener speaks 1.3
             only, so the 1.2 suite is never chosen. *)
          ~ciphers:(ciphers @ [ `ECDHE_ECDSA_WITH_AES_128_GCM_SHA256 ])
          ()
      with
      | Ok c -> c
      | Error (`Msg m) -> failwith ("config: " ^ m)
    in
    let payload = String.make (int_of_string payload) 'x' in
    let write = int_of_string write in
    let sink =
      match String.split_on_char ':' sink with
      | [ "stock" ] -> `Stock
      | [ "copy"; bytes ] -> `Copy (int_of_string bytes)
      | [ "pieces" ] -> `Pieces
      | _ -> failwith ("sink: " ^ sink)
    in
    Eio_main.run
    @@ fun env ->
    Eio.Switch.run
    @@ fun sw ->
    let listening =
      Eio.Net.listen
        ~sw
        ~backlog:64
        ~reuse_addr:true
        (Eio.Stdenv.net env)
        (`Tcp (Eio.Net.Ipaddr.V4.loopback, int_of_string port))
    in
    Printf.printf "{\"ready\":true}\n%!";
    let rec accept () =
      let socket, _ = Eio.Net.accept ~sw listening in
      Eio_unix.Fd.use_exn "nodelay" (Eio_unix.Net.fd socket) (fun fd ->
        Unix.setsockopt fd Unix.TCP_NODELAY true);
      Eio.Fiber.fork ~sw (fun () ->
        Eio.Switch.run (fun conn_sw ->
          Eio.Switch.on_release conn_sw (fun () -> Eio.Resource.close socket);
          let flow =
            match sink with
            | `Stock -> (socket :> [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t)
            | `Pieces ->
              (Eio.Resource.T ((socket :> [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t), pieces_handler) :> [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t)
            | `Copy bytes ->
              (Eio.Resource.T ({ Chunked.socket = (socket :> [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t); buf = Cstruct.create bytes }, chunked_handler) :> [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t)
          in
          let tls = Tls_eio.server_of_flow config flow in
          let n = int_of_string Eio.Buf_read.(line (of_flow ~max_size:64 tls)) in
          let cpu0 = cpu () in
          let t0 = Unix.gettimeofday () in
          let whole = Cstruct.of_string payload in
          let size = String.length payload in
          for _ = 1 to n do
            let rec go off =
              if off < size
              then (
                let len = min write (size - off) in
                ignore (Eio.Flow.single_write tls [ Cstruct.sub whole off len ] : int);
                go (off + len))
            in
            go 0
          done;
          Eio.Flow.shutdown tls `Send;
          let cpu1 = cpu () in
          Printf.printf
            "{\"bytes\":%d,\"cpu_start\":%.4f,\"cpu_end\":%.4f,\"wall_start\":%.4f,\"wall_end\":%.4f}\n%!"
            (n * size) cpu0 cpu1 t0 (Unix.gettimeofday ())));
      accept ()
    in
    accept ()
  | _ ->
    prerr_endline
      "usage: bench_server <port> <cert.pem> <key.pem> <stock|copy:BYTES|pieces> <aes128|aes256|chacha> <payload> <write>";
    exit 2
