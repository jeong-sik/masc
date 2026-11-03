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
  | Incompatible of string
  | Bad_budget of
      { connect_budget_sec : float
      ; budget_sec : float
      }

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

(* The same bound a local process's output gets (Process_eio): the head and
   the tail are kept and the middle is elided with a marker, so the
   acceptance frame at the front of stderr and the trailer at its end both
   survive. The chunk callbacks still see every byte. *)
let capture () =
  Exec_buffer.create
    ~head_cap:Common.max_process_capture_head_bytes
    ~tail_cap:Common.max_process_capture_tail_bytes
;;

let decode_error_to_string = function
  | Relay.Unknown_kind kind -> Printf.sprintf "unknown chunk kind %d" kind
  | Relay.Oversized { length } ->
    Printf.sprintf "a chunk of %d bytes is over the limit" length
  | Relay.Malformed_hello detail -> "malformed hello: " ^ detail
  | Relay.Malformed_exit detail -> "malformed exit: " ^ detail
;;

(* Bytes read from the connection; those before [pos] are decoded. *)
type inbox =
  { mutable bytes : string
  ; mutable pos : int
  }

type read_failure =
  | Stream_ended of string  (* the connection ended or failed *)
  | Undecodable of string  (* the agent sent bytes this host cannot read *)

(* The next chunk, reading more as needed. Only a read moves the undecoded
   rest, so a stream of small chunks costs one copy per read rather than one
   per chunk. *)
let rec next_chunk flow buffer inbox =
  match Relay.decode inbox.bytes ~pos:inbox.pos with
  | Error error -> Error (Undecodable (decode_error_to_string error))
  | Ok (Relay.Chunk { chunk; consumed }) ->
    inbox.pos <- inbox.pos + consumed;
    Ok chunk
  | Ok Relay.Need_more ->
    (match Eio.Flow.single_read flow buffer with
     | read ->
       let rest = String.sub inbox.bytes inbox.pos (String.length inbox.bytes - inbox.pos) in
       inbox.bytes <- rest ^ Cstruct.to_string (Cstruct.sub buffer 0 read);
       inbox.pos <- 0;
       next_chunk flow buffer inbox
     | exception End_of_file -> Error (Stream_ended "the connection ended")
     | exception (Eio.Io _ as exn) -> Error (Stream_ended (Printexc.to_string exn)))
;;

type connection_result =
  | Retry of string
  | Finished of outcome

type ending =
  | Exit_code of int
  | Broke of string

let finite_and_positive seconds = Float.is_finite seconds && seconds > 0.

let run ~net ~clock ?on_stdout_chunk ?on_stderr_chunk ~accept ~socket ~connect_budget_sec
      ~budget_sec request =
  if not (finite_and_positive connect_budget_sec && finite_and_positive budget_sec)
  then Not_sent (Bad_budget { connect_budget_sec; budget_sec })
  else (
    let started = Eio.Time.now clock in
    let deadline = started +. budget_sec in
    let connect_deadline = Float.min deadline (started +. connect_budget_sec) in
    let kind, frame =
      match request with
      | Run { frame } -> Relay.Run, frame
      | Probe -> Relay.Probe, ""
    in
    (* After an accepted hello, inside the switch that owns the connection. *)
    let exchange flow buffer inbox ~attempts =
      let remaining = deadline -. Eio.Time.now clock in
      if remaining <= 0.
      then Not_sent (Unreachable { attempts; last = "the budget ran out right after the hello" })
      else (
        let stdout = capture () in
        let stderr = capture () in
        let emit capture callback bytes =
          Exec_buffer.add_string capture bytes;
          Option.iter (fun callback -> callback bytes) callback
        in
        let rec read () =
          match next_chunk flow buffer inbox with
          | Error (Stream_ended reason) ->
            Broke ("the stream ended before the exit chunk: " ^ reason)
          | Error (Undecodable detail) -> Broke ("an undecodable chunk: " ^ detail)
          | Ok (Relay.Stdout bytes) ->
            emit stdout on_stdout_chunk bytes;
            read ()
          | Ok (Relay.Stderr bytes) ->
            emit stderr on_stderr_chunk bytes;
            read ()
          | Ok (Relay.Exit (Relay.Exited code)) -> Exit_code code
          | Ok (Relay.Exit (Relay.Signaled signal)) ->
            Broke (Printf.sprintf "the shim ended on guest signal %d" signal)
          | Ok (Relay.Hello _) -> Broke "a second hello"
        in
        let send () =
          match
            Eio.Flow.copy_string (String.make 1 (Relay.request_kind_byte kind) ^ frame) flow
          with
          | () -> Ok (read ())
          | exception (Eio.Io _ as exn) ->
            Ok (Broke ("writing the request: " ^ Printexc.to_string exn))
        in
        let rendered_stdout () = Exec_buffer.render stdout in
        let rendered_stderr () = Exec_buffer.render stderr in
        match Eio.Time.with_timeout clock remaining send with
        | Ok (Exit_code code) ->
          Exited { code; stdout = rendered_stdout (); stderr = rendered_stderr () }
        | Ok (Broke reason) ->
          Broken { reason; stdout = rendered_stdout (); stderr = rendered_stderr () }
        | Error `Timeout ->
          Timed_out { stdout = rendered_stdout (); stderr = rendered_stderr () })
    in
    (* One connection, in a switch of its own: whatever it opened is closed
       when it ends, whether it failed, was refused or ran the request. *)
    let connection ~attempts ~remaining =
      Eio.Switch.run
      @@ fun sw ->
      match Eio.Net.connect ~sw net (`Unix socket) with
      | exception (Eio.Io _ as exn) -> Retry (Printexc.to_string exn)
      | exception (Unix.Unix_error _ as exn) ->
        (* socket(2) itself, EMFILE for one, is outside Eio's error wrapping. *)
        Retry (Printexc.to_string exn)
      | flow ->
        let buffer = Cstruct.create read_size in
        let inbox = { bytes = ""; pos = 0 } in
        let wait = Float.min hello_wait_sec remaining in
        (match
           Eio.Time.with_timeout clock wait (fun () -> Ok (next_chunk flow buffer inbox))
         with
         | Error `Timeout -> Retry (Printf.sprintf "no hello within %.1fs" wait)
         | Ok (Error (Stream_ended reason)) -> Retry reason
         | Ok (Error (Undecodable detail)) ->
           Finished (Not_sent (Incompatible ("the agent's first chunk: " ^ detail)))
         | Ok (Ok (Relay.Stdout _ | Relay.Stderr _ | Relay.Exit _)) ->
           Finished (Not_sent (Incompatible "the agent's first chunk was not a hello"))
         | Ok (Ok (Relay.Hello hello)) ->
           (match accept hello with
            | Some refusal -> Finished (Not_sent (Refused refusal))
            | None -> Finished (exchange flow buffer inbox ~attempts:(attempts + 1))))
    in
    let rec attempt attempts last =
      let remaining = connect_deadline -. Eio.Time.now clock in
      if remaining <= 0.
      then Not_sent (Unreachable { attempts; last })
      else (
        match connection ~attempts ~remaining with
        | Finished outcome -> outcome
        | Retry reason ->
          Eio.Time.sleep clock
            (Float.min reconnect_pause_sec
               (Float.max 0. (connect_deadline -. Eio.Time.now clock)));
          attempt (attempts + 1) reason)
    in
    attempt 0 "no connection was tried")
;;
