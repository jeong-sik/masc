(* The host end of a microVM guest agent connection; see
   keeper_guest_socket.mli. *)

module Relay = Exec_ssh_protocol.Relay

type expected =
  { uid : int
  ; gid : int
  }

type refusal =
  | Other_source of
      { server : Source_identity.t option
      ; agent : Source_identity.t option
      ; agent_relay : int
      }
  | Root_writable
  | Other_owner of
      { uid : int
      ; gid : int
      }
  | New_privileges_allowed

(* RFC host-and-shim-share-one-build-identity: the source identity comes
   first and stands for the relay version, because one source speaks one
   relay. Neither side knowing its identity is a refusal too: nothing says the
   two are the same build. *)
let refusal ~(expected : expected) (hello : Relay.hello) =
  let other_source () =
    Some
      (Other_source
         { server = Source_identity.current
         ; agent = hello.Relay.source_identity
         ; agent_relay = hello.Relay.relay_version
         })
  in
  match Source_identity.current, hello.Relay.source_identity with
  | None, (Some _ | None) | Some _, None -> other_source ()
  | Some server, Some agent ->
    if not (Source_identity.equal server agent)
    then other_source ()
    else if not hello.Relay.root_read_only
    then Some Root_writable
    else if hello.Relay.uid <> expected.uid || hello.Relay.gid <> expected.gid
    then Some (Other_owner { uid = hello.Relay.uid; gid = hello.Relay.gid })
    else if not hello.Relay.no_new_privs
    then Some New_privileges_allowed
    else None
;;

let identity_to_string = function
  | Some identity -> Source_identity.to_string identity
  | None -> "no source identity"
;;

let refusal_to_string = function
  | Other_source { server; agent; agent_relay } ->
    Printf.sprintf
      "microvm_shim_other_source: the agent was built from %s (relay version %d) \
       and this server from %s (relay version %d)"
      (identity_to_string agent) agent_relay (identity_to_string server) Relay.version
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
   milliseconds (measured 2026-11-03). Without a pause the loop would ask the
   VM runtime for a new guest connection every few milliseconds while the VM
   boots. *)
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
  | Stream_ended
  | Stream_failed of string
  | Undecodable of Relay.decode_error

(* The next chunk, reading more as needed. Only a read moves the undecoded
   rest, so a stream of small chunks costs one copy per read rather than one
   per chunk. *)
let rec next_chunk flow buffer inbox =
  match Relay.decode inbox.bytes ~pos:inbox.pos with
  | Error error -> Error (Undecodable error)
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
     | exception End_of_file -> Error Stream_ended
     | exception (Eio.Io _ as exn) -> Error (Stream_failed (Printexc.to_string exn)))
;;

type 'a connection_result =
  | Retry of string
  | Finished of ('a, not_sent) result

type ending =
  | Exit_code of int
  | Broke of string

let finite_and_positive seconds = Float.is_finite seconds && seconds > 0.

(* Each attempt owns its socket. Only a connection or hello failure can
   retry; [exchange] runs once after an accepted hello and is never replayed.
   Both connection and hello waits spend the original connect deadline. *)
let with_accepted_connection ~net ~clock ~accept ~socket ~connect_deadline ~attempts exchange =
  let connection ~remaining =
    incr attempts;
    Eio.Switch.run @@ fun sw ->
    let connect () =
      match Eio.Net.connect ~sw net (`Unix socket) with
      | flow -> Ok (Ok flow)
      | exception (Eio.Io _ as exn) -> Ok (Error (Printexc.to_string exn))
      | exception (Unix.Unix_error _ as exn) -> Ok (Error (Printexc.to_string exn))
    in
    match Eio.Time.with_timeout clock remaining connect with
    | Error `Timeout -> Retry "the connection wait exhausted the connect budget"
    | Ok (Error detail) -> Retry detail
    | Ok (Ok flow) ->
      let buffer = Cstruct.create read_size in
      let inbox = { bytes = ""; pos = 0 } in
      let wait = Float.min hello_wait_sec (connect_deadline -. Eio.Time.now clock) in
      if wait <= 0. then Retry "the connect budget ran out before the hello"
      else
        match Eio.Time.with_timeout clock wait (fun () -> Ok (next_chunk flow buffer inbox)) with
        | Error `Timeout -> Retry (Printf.sprintf "no hello within %.1fs" wait)
        | Ok (Error Stream_ended) -> Retry "the connection ended"
        | Ok (Error (Stream_failed detail)) -> Retry detail
        | Ok (Error (Undecodable error)) ->
          Finished (Error (Incompatible ("the agent's first chunk: " ^ decode_error_to_string error)))
        | Ok (Ok (Relay.Stdout _ | Relay.Stderr _ | Relay.Exit _)) ->
          Finished (Error (Incompatible "the agent's first chunk was not a hello"))
        | Ok (Ok (Relay.Hello hello)) ->
          match accept hello with
          | Some refusal -> Finished (Error (Refused refusal))
          | None -> Finished (Ok (exchange flow buffer inbox ~attempts:!attempts))
  in
  let rec attempt last =
    let remaining = connect_deadline -. Eio.Time.now clock in
    if remaining <= 0. then Error (Unreachable { attempts = !attempts; last })
    else
      match connection ~remaining with
      | Finished result -> result
      | Retry reason ->
        Eio.Time.sleep clock
          (Float.min reconnect_pause_sec
             (Float.max 0. (connect_deadline -. Eio.Time.now clock)));
        attempt reason
  in
  attempt "no connection was tried"
;;

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
          | Error Stream_ended -> Broke "the stream ended before the exit chunk"
          | Error (Stream_failed reason) ->
            Broke ("the stream ended before the exit chunk: " ^ reason)
          | Error (Undecodable error) ->
            Broke ("an undecodable chunk: " ^ decode_error_to_string error)
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
    match with_accepted_connection ~net ~clock ~accept ~socket ~connect_deadline
        ~attempts:(ref 0) exchange with
    | Ok outcome -> outcome
    | Error error -> Not_sent error)

;;

type stdio_error =
  | Invalid_request of string
  | Not_connected of not_sent
  | Ended_before_exit
  | Invalid_chunk of Relay.decode_error
  | Unexpected_hello
  | Read_failed of string
  | Write_failed of string
  | Shutdown_failed of string
  | Budget_spent

let stdio_error_to_string = function
  | Invalid_request detail -> "invalid interactive request: " ^ detail
  | Not_connected (Unreachable { attempts; last }) ->
    Printf.sprintf "no accepted hello over %d connections: %s" attempts last
  | Not_connected (Refused reason) -> refusal_to_string reason
  | Not_connected (Incompatible detail) -> "incompatible guest relay: " ^ detail
  | Not_connected (Bad_budget { connect_budget_sec; budget_sec }) ->
    Printf.sprintf "invalid budgets (connect %g, whole %g)" connect_budget_sec budget_sec
  | Ended_before_exit -> "the connection ended before the exit chunk"
  | Invalid_chunk error -> "invalid guest chunk: " ^ decode_error_to_string error
  | Unexpected_hello -> "the guest sent a second hello"
  | Read_failed detail -> "reading the guest: " ^ detail
  | Write_failed detail -> "writing the guest: " ^ detail
  | Shutdown_failed detail -> "closing the guest input: " ^ detail
  | Budget_spent -> "the interactive guest call exhausted its whole-call budget"
;;

type 'e stdio_failure =
  | Dispatch_declined of 'e
  | Transport_failed of stdio_error

(* Only failures created at this transport's own I/O boundaries use this
   exception. A user's Eio.Io exception is never classified as a socket error. *)
exception Stdio_transport_error of stdio_error

type stdout_piece = Bytes of string | End

module Stdio_source = struct
  type t =
    { pieces : stdout_piece Eio.Stream.t
    ; mutable current : string
    ; mutable offset : int
    ; mutable ended : bool
    }

  let read_methods = []

  let rec single_read t buffer =
    let remaining = String.length t.current - t.offset in
    if remaining > 0 then (
      let count = min remaining (Cstruct.length buffer) in
      Cstruct.blit_from_string t.current t.offset buffer 0 count;
      t.offset <- t.offset + count;
      count)
    else if t.ended then raise End_of_file
    else (
      match Eio.Stream.take t.pieces with
      | End -> t.ended <- true; raise End_of_file
      | Bytes bytes ->
        t.current <- bytes;
        t.offset <- 0;
        single_read t buffer)
end

let validate_interactive_frame frame =
  match Exec_ssh_protocol.decode_request frame with
  | Error detail -> Error (Invalid_request detail)
  | Ok (request, initial) ->
    match request.v, request.stdin with
    | Exec_ssh_protocol.V3, Exec_ssh_protocol.Interactive when initial = "" -> Ok ()
    | Exec_ssh_protocol.V3, Exec_ssh_protocol.Interactive ->
      Error (Invalid_request "interactive requests cannot carry an initial payload")
    | Exec_ssh_protocol.V2, (Exec_ssh_protocol.Framed _ | Exec_ssh_protocol.Interactive)
    | Exec_ssh_protocol.V3, Exec_ssh_protocol.Framed _ ->
      Error (Invalid_request "the guest stdio port requires a V3 Interactive request")
;;

let with_stdio ~net ~clock ~expected ~socket ~connect_budget_sec ~budget_sec ~frame
    ~on_dispatch ~on_request_write ~on_stderr_chunk ~on_stdout_tail callback =
  match validate_interactive_frame frame with
  | Error error -> Error (Transport_failed error)
  | Ok () when not (finite_and_positive connect_budget_sec && finite_and_positive budget_sec) ->
    Error (Transport_failed (Not_connected (Bad_budget { connect_budget_sec; budget_sec })))
  | Ok () ->
    let primary = ref None in
    let transport_failure = ref None in
    let fail_transport error =
      transport_failure := Some error;
      raise (Stdio_transport_error error)
    in
    let invoke f =
      match f () with
      | value -> value
      | exception (Stdio_transport_error _ as exn) -> raise exn
      | exception (Eio.Cancel.Cancelled _ as exn) when Option.is_some !transport_failure ->
        raise exn
      | exception exn ->
        let backtrace = Printexc.get_raw_backtrace () in
        if Option.is_none !primary then primary := Some (exn, backtrace);
        Printexc.raise_with_backtrace exn backtrace
    in
    let write_started = ref false in
    let attempts = ref 0 in
    let started = Eio.Time.now clock in
    let deadline = started +. budget_sec in
    let connect_deadline = Float.min deadline (started +. connect_budget_sec) in
    let exchange flow buffer inbox ~attempts =
      match invoke on_dispatch with
      | Error error -> Error (Dispatch_declined error)
      | Ok () ->
        (* A rendezvous queue adds no independent retention budget. The
           decoder holds at most one protocol chunk while the source holds
           the remainder of the chunk currently borrowed by its reader. *)
        let pieces = Eio.Stream.create 0 in
        let source_state : Stdio_source.t =
          { pieces; current = ""; offset = 0; ended = false }
        in
        let input = Eio.Resource.T (source_state, Eio.Flow.Pi.source (module Stdio_source)) in
        let module Output = struct
          type t = unit
          let single_write () buffers =
            match Eio.Flow.single_write flow buffers with
            | count -> count
            | exception (Eio.Io _ as exn) -> fail_transport (Write_failed (Printexc.to_string exn))
          let copy () ~src = Eio.Flow.Pi.simple_copy ~single_write () ~src
        end in
        let output = Eio.Resource.T ((), Eio.Flow.Pi.sink (module Output)) in
        let terminal, resolve_terminal = Eio.Promise.create () in
        let returned, resolve_returned = Eio.Promise.create () in
        let rec decode () =
          match next_chunk flow buffer inbox with
          | Error Stream_ended -> fail_transport Ended_before_exit
          | Error (Stream_failed detail) -> fail_transport (Read_failed detail)
          | Error (Undecodable error) -> fail_transport (Invalid_chunk error)
          | Ok (Relay.Hello _) -> fail_transport Unexpected_hello
          | Ok (Relay.Stdout bytes) ->
            if bytes <> "" then Eio.Stream.add pieces (Bytes bytes);
            decode ()
          | Ok (Relay.Stderr bytes) -> invoke (fun () -> on_stderr_chunk bytes); decode ()
          | Ok (Relay.Exit status) ->
            Eio.Promise.resolve resolve_terminal status;
            Eio.Stream.add pieces End
        in
        let drain_tail () =
          let chunk = Cstruct.create Relay.max_payload_bytes in
          let rec drain () =
            match Eio.Flow.single_read input chunk with
            | count ->
              invoke (fun () -> on_stdout_tail (Cstruct.to_string ~len:count chunk));
              drain ()
            | exception End_of_file -> ()
          in
          drain ()
        in
        let use () =
          let remaining = deadline -. Eio.Time.now clock in
          if remaining <= 0. then
            fail_transport (Not_connected (Unreachable
              { attempts; last = "the budget ran out before request writing" }));
          write_started := true;
          invoke on_request_write;
          Eio.Flow.copy_string
            (String.make 1 (Relay.request_kind_byte Relay.Interactive_run) ^ frame) output;
          let value = invoke (fun () -> callback ~input ~output) in
          (match Eio.Promise.peek terminal with
           | Some _ -> ()
           | None ->
             match Eio.Flow.shutdown flow `Send with
             | () -> ()
             | exception (Eio.Io _ as exn) ->
               fail_transport (Shutdown_failed (Printexc.to_string exn)));
          drain_tail ();
          Eio.Promise.resolve resolve_returned value
        in
        (* Either failure cancels its sibling. In particular, a reader must
           not remain blocked on the rendezvous after the callback fails. *)
        Eio.Fiber.both use decode;
        Ok (Eio.Promise.await returned, Eio.Promise.await terminal)
    in
    let run () =
      let exchange () =
        Ok (with_accepted_connection ~net ~clock ~accept:(refusal ~expected)
          ~socket ~connect_deadline ~attempts exchange)
      in
      match Eio.Time.with_timeout clock budget_sec exchange with
      | Ok (Ok result) -> result
      | Ok (Error error) -> Error (Transport_failed (Not_connected error))
      | Error `Timeout ->
        let error =
          if !write_started then Budget_spent
          else Not_connected (Unreachable
            { attempts = !attempts; last = "the whole-call budget ran out before request writing" })
        in
        Error (Transport_failed error)
    in
    match run () with
    | result ->
      (match !primary with
       | None | Some (Eio.Cancel.Cancelled _, _) -> result
       | Some (primary, backtrace) -> Printexc.raise_with_backtrace primary backtrace)
    | exception exn ->
      let backtrace = Printexc.get_raw_backtrace () in
      match !primary, !transport_failure with
      | Some (primary, primary_backtrace), (None | Some _) ->
        if exn != primary then
          (match Log.Misc.warn "[guest stdio] secondary transport or cleanup failure: %s"
              (Printexc.to_string exn) with
           | () -> () | exception _reporter_failure -> ());
        Printexc.raise_with_backtrace primary primary_backtrace
      | None, Some error -> Error (Transport_failed error)
      | None, None -> Printexc.raise_with_backtrace exn backtrace
;;
