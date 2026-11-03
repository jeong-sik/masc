(* The host end of a microVM guest agent connection; see
   keeper_guest_socket.mli. *)

module Relay = Exec_ssh_protocol.Relay

type expected =
  { uid : int
  ; gid : int
  }

type refusal =
  | Other_relay_version of { agent : int }
  | Root_writable
  | Other_owner of
      { uid : int
      ; gid : int
      }
  | New_privileges_allowed

let refusal ~(expected : expected) (hello : Relay.hello) =
  if hello.Relay.relay_version <> Relay.version
  then Some (Other_relay_version { agent = hello.Relay.relay_version })
  else if not hello.Relay.root_read_only
  then Some Root_writable
  else if hello.Relay.uid <> expected.uid || hello.Relay.gid <> expected.gid
  then Some (Other_owner { uid = hello.Relay.uid; gid = hello.Relay.gid })
  else if not hello.Relay.no_new_privs
  then Some New_privileges_allowed
  else None
;;

let refusal_to_string = function
  | Other_relay_version { agent } ->
    Printf.sprintf "the agent speaks relay version %d and this host speaks %d" agent
      Relay.version
  | Root_writable -> "the agent left the guest root filesystem writable"
  | Other_owner { uid; gid } ->
    Printf.sprintf "the agent runs as %d:%d, not as the Keeper's uid and gid" uid gid
  | New_privileges_allowed -> "the agent did not set no_new_privs"
;;

type request =
  | Run of { frame : string }
  | Probe

type not_sent =
  | Unreachable of
      { attempts : int
      ; last : string
      }
  | Refused of refusal

type outcome =
  | Not_sent of not_sent
  | Exited of
      { code : int
      ; stdout : string
      ; stderr : string
      }
  | Timed_out of
      { stdout : string
      ; stderr : string
      }
  | Broken of
      { reason : string
      ; stdout : string
      ; stderr : string
      }

let hello_wait_sec = 1.0

(* A connection made before the agent listens usually ends within a few
   milliseconds (docs/evidence/2026-11-03-microvm-request-transport,
   agent-boot-results.json). Without a pause the loop would ask the VM runtime
   for a new guest connection every few milliseconds while the VM boots. *)
let reconnect_pause_sec = 0.1

(* One read takes at most a whole chunk: a 5-byte header and the largest
   payload. *)
let read_size = Relay.max_payload_bytes + 5

let decode_error_to_string = function
  | Relay.Unknown_kind kind -> Printf.sprintf "unknown chunk kind %d" kind
  | Relay.Oversized { length } ->
    Printf.sprintf "a chunk of %d bytes is over the limit" length
  | Relay.Malformed_hello detail -> "malformed hello: " ^ detail
  | Relay.Malformed_exit detail -> "malformed exit: " ^ detail
;;

(* The chunk at the front of [pending], reading more as needed, and the bytes
   after it. *)
let rec next_chunk flow buffer pending =
  match Relay.decode pending ~pos:0 with
  | Error error -> Error (decode_error_to_string error)
  | Ok (Relay.Chunk { chunk; consumed }) ->
    Ok (chunk, String.sub pending consumed (String.length pending - consumed))
  | Ok Relay.Need_more ->
    (match Eio.Flow.single_read flow buffer with
     | read -> next_chunk flow buffer (pending ^ Cstruct.to_string (Cstruct.sub buffer 0 read))
     | exception End_of_file -> Error "the connection ended"
     | exception (Eio.Io _ as exn) -> Error (Printexc.to_string exn))
;;

(* A connection whose hello [accept] took, the bytes read after the hello, and
   how many connections it took. *)
let connect_until_hello ~sw ~net ~clock ~socket ~accept ~until =
  let buffer = Cstruct.create read_size in
  let rec attempt attempts last =
    let remaining = until -. Eio.Time.now clock in
    if remaining <= 0.
    then Error (Unreachable { attempts; last })
    else (
      let failed reason =
        Eio.Time.sleep clock (Float.min reconnect_pause_sec (Float.max 0. (until -. Eio.Time.now clock)));
        attempt (attempts + 1) reason
      in
      match Eio.Net.connect ~sw net (`Unix socket) with
      | exception (Eio.Io _ as exn) -> failed (Printexc.to_string exn)
      | flow ->
        let wait = Float.min hello_wait_sec remaining in
        (match
           Eio.Time.with_timeout clock wait (fun () -> Ok (next_chunk flow buffer ""))
         with
         | Ok (Ok (Relay.Hello hello, pending)) ->
           (match accept hello with
            | None -> Ok (flow, pending, attempts + 1)
            | Some refusal ->
              Eio.Flow.close flow;
              Error (Refused refusal))
         | Ok (Ok ((Relay.Stdout _ | Relay.Stderr _ | Relay.Exit _), _)) ->
           Eio.Flow.close flow;
           failed "the first chunk was not a hello"
         | Ok (Error reason) ->
           Eio.Flow.close flow;
           failed reason
         | Error `Timeout ->
           Eio.Flow.close flow;
           failed (Printf.sprintf "no hello within %.1fs" wait)))
  in
  attempt 0 "no connection was tried"
;;

type ending =
  | Ended of int
  | Broke of string

let run ~net ~clock ?on_stdout_chunk ?on_stderr_chunk ~accept ~socket ~connect_budget_sec
      ~budget_sec request =
  let stdout = Buffer.create 4096 in
  let stderr = Buffer.create 4096 in
  let emit buffer callback bytes =
    Buffer.add_string buffer bytes;
    Option.iter (fun callback -> callback bytes) callback
  in
  let started = Eio.Time.now clock in
  let deadline = started +. budget_sec in
  Eio.Switch.run
  @@ fun sw ->
  match
    connect_until_hello ~sw ~net ~clock ~socket ~accept
      ~until:(Float.min deadline (started +. connect_budget_sec))
  with
  | Error not_sent -> Not_sent not_sent
  | Ok (flow, pending, attempts) ->
    let remaining = deadline -. Eio.Time.now clock in
    if remaining <= 0.
    then (
      Eio.Flow.close flow;
      Not_sent (Unreachable { attempts; last = "the budget ran out right after the hello" }))
    else (
      let kind, frame =
        match request with
        | Run { frame } -> Relay.Run, frame
        | Probe -> Relay.Probe, ""
      in
      let buffer = Cstruct.create read_size in
      let rec read pending =
        match next_chunk flow buffer pending with
        | Error reason -> Broke ("the stream ended before the exit chunk: " ^ reason)
        | Ok (Relay.Stdout bytes, rest) ->
          emit stdout on_stdout_chunk bytes;
          read rest
        | Ok (Relay.Stderr bytes, rest) ->
          emit stderr on_stderr_chunk bytes;
          read rest
        | Ok (Relay.Exit (Relay.Exited code), _) -> Ended code
        | Ok (Relay.Exit (Relay.Signaled signal), _) ->
          Broke (Printf.sprintf "the shim ended on guest signal %d" signal)
        | Ok (Relay.Hello _, _) -> Broke "a second hello"
      in
      let exchange () =
        match
          Eio.Flow.copy_string (String.make 1 (Relay.request_kind_byte kind) ^ frame) flow
        with
        | () -> Ok (read pending)
        | exception (Eio.Io _ as exn) ->
          Ok (Broke ("writing the request: " ^ Printexc.to_string exn))
      in
      match Eio.Time.with_timeout clock remaining exchange with
      | Ok (Ended code) ->
        Exited { code; stdout = Buffer.contents stdout; stderr = Buffer.contents stderr }
      | Ok (Broke reason) ->
        Broken { reason; stdout = Buffer.contents stdout; stderr = Buffer.contents stderr }
      | Error `Timeout ->
        Timed_out { stdout = Buffer.contents stdout; stderr = Buffer.contents stderr })
;;
