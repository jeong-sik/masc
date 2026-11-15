(** A queued Keeper chat stream over the route the TUI posts to (#38949).

    A queued operation writes no journal event until its Keeper gets the
    slot. During that silence the stream's keepalive comment is the only
    thing that keeps the TUI's per-stream idle bound from ending a healthy
    queue. This suite posts [/api/v1/keepers/chat/stream] through the
    dashboard router over an httpun connection, with an Owner that has no
    operation runner so the operation stays [Queued], and moves a mock clock.
    It reads the bytes the client gets: a keepalive before the TUI would give
    up, without an [id] the client would resume from, and the end of the
    response once the operation settles without a wire terminal. *)

open Alcotest
open Masc

module Http = Http_server_eio

let () = Mirage_crypto_rng_unix.use_default ()

let keeper_name = "keepalive-http"
let request_id = "req-keepalive-http"

let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
;;

let require_ok to_string = function Ok value -> value | Error error -> fail (to_string error)

(* How long a wait for the stream may take in wall time. It only ends a test
   that has already failed (a frame or the close that never comes); a passing
   run never waits on it, because every step it guards is woken by the bytes
   or the sleep it waits for. *)
let failure_guard_s = 10.0

(* The stream's clock: the mock clock, counting the sleeps started on it.
   A response's frame starts its stall wait before its bytes can reach the
   socket, and the pump starts its keepalive wait only after the send
   returned. So a sleep started after a frame's bytes were written is the
   pump waiting again, and the test moves the time only then. *)
module Counted_clock = struct
  type t =
    { mock : Eio_mock.Clock.t
    ; mutable sleeps : int
    ; changed : Eio.Condition.t
    }

  type time = float

  let now t = Eio.Time.now t.mock

  let sleep_until t time =
    t.sleeps <- t.sleeps + 1;
    Eio.Condition.broadcast t.changed;
    Eio.Time.sleep_until t.mock time
end

(* What the client has read off the connection. [sleeps_at_last_write] is the
   clock's count when the last bytes were handed over: the frame being written
   started its stall wait already, and the pump cannot start its next wait
   before this write is reported. *)
type wire =
  { bytes : Buffer.t
  ; mutable ended : bool
  ; mutable sleeps_at_last_write : int
  }

let read_writes clock connection wire =
  let rec loop () =
    match Httpun.Server_connection.next_write_operation connection with
    | `Write iovecs ->
      let written =
        List.fold_left
          (fun total (iov : Bigstringaf.t Httpun.IOVec.t) ->
             Buffer.add_string wire.bytes
               (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len);
             total + iov.len)
          0 iovecs
      in
      wire.sleeps_at_last_write <- clock.Counted_clock.sleeps;
      Httpun.Server_connection.report_write_result connection (`Ok written);
      Eio.Condition.broadcast clock.changed;
      loop ()
    | `Yield ->
      let more, wake = Eio.Promise.create () in
      Httpun.Server_connection.yield_writer connection (Eio.Promise.resolve wake);
      Eio.Promise.await more;
      loop ()
    | `Close _ ->
      wire.ended <- true;
      Eio.Condition.broadcast clock.changed
  in
  loop ()
;;

(* The complete SSE frames of the response body, in order, each as its
   lines. *)
let frames wire =
  let raw = Buffer.contents wire.bytes in
  let rec find_from pattern index =
    if index + String.length pattern > String.length raw then None
    else if String.sub raw index (String.length pattern) = pattern then Some index
    else find_from pattern (index + 1)
  in
  match find_from "\r\n\r\n" 0 with
  | None -> []
  | Some head_end ->
    let rec split start acc =
      match find_from "\n\n" start with
      | None -> List.rev acc
      | Some stop ->
        split (stop + 2) (String.split_on_char '\n' (String.sub raw start (stop - start)) :: acc)
    in
    split (head_end + 4) []
;;

(* The SSE field names a frame carries. A line that starts with ':' is a
   comment and names no field. *)
let field_names frame =
  List.filter_map
    (fun line ->
       if line = "" || line.[0] = ':' then None
       else
         match String.index_opt line ':' with
         | Some colon -> Some (String.sub line 0 colon)
         | None -> Some line)
    frame
;;

let data_json frame =
  List.find_map
    (fun line ->
       let prefix = "data: " in
       let length = String.length prefix in
       if String.length line > length && String.sub line 0 length = prefix
       then Some (Yojson.Safe.from_string (String.sub line length (String.length line - length)))
       else None)
    frame
;;

(* The acceptance's operation state when [frame] is the acceptance. *)
let accepted_state frame =
  let open Yojson.Safe.Util in
  match data_json frame with
  | Some json when member "name" json = `String "KEEPER_CHAT_OPERATION_ACCEPTED" ->
    Some (json |> member "value" |> member "state" |> to_string)
  | Some _ | None -> None
;;

let loopback_request_authority () =
  match Server_request_authority.of_host_port ~host:"127.0.0.1" ~port:8935 with
  | Ok authority -> authority
  | Error `Malformed -> fail "failed to construct loopback request authority"
;;

let with_server f =
  let base_path = Filename.temp_dir "keeper-chat-keepalive-http" "" in
  let previous_state = Server_auth.For_testing.snapshot_server_state () in
  Fun.protect
    ~finally:(fun () ->
      Server_auth.For_testing.restore_server_state previous_state;
      Fs_compat.clear_fs ();
      remove_tree base_path)
    (fun () -> Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Eio.Switch.run @@ fun sw ->
      let state = Mcp_server.For_testing.create_state ~base_path in
      let config = Mcp_server.workspace_config state in
      ignore (Workspace.init config ~agent_name:None);
      let meta = require_ok Fun.id (Masc_test_deps.meta_of_json_fixture
        (`Assoc [ "name", `String keeper_name; "trace_id", `String "keepalive-http-trace" ])) in
      require_ok Fun.id (Keeper_meta_store.replace_snapshot config meta);
      (* No operation runner: the Owner accepts the operation and nothing
         ever claims it, so it stays queued until it is cancelled. *)
      ignore (require_ok Keeper_owner_registry.install_error_to_string
        (Keeper_owner_registry.install_from_store ~sw ~operation_runner:None
          ~on_turn_slot_released:None config));
      Server_auth.For_testing.restore_server_state (Some state);
      Auth.save_auth_config base_path
        { Masc_domain.default_auth_config with enabled = true; require_token = true };
      let token = fst (require_ok Masc_domain.masc_error_to_string
        (Auth.create_token base_path ~agent_name:"keepalive-operator" ~role:Masc_domain.Admin)) in
      let clock =
        { Counted_clock.mock = Eio_mock.Clock.make (); sleeps = 0
        ; changed = Eio.Condition.create () }
      in
      let stream_clock : float Eio.Time.clock_ty Eio.Resource.t =
        Eio.Resource.T (clock, Eio.Time.Pi.clock (module Counted_clock))
      in
      let router =
        Server_routes_http_routes_dashboard.add_routes ~sw ~clock:stream_clock
          (Http.Router.create ())
      in
      f ~real_clock:(Eio.Stdenv.clock env) ~sw ~base_path ~clock ~router ~token)
;;

let test_a_queued_stream_keeps_alive_and_ends_when_the_operation_settles () =
  with_server (fun ~real_clock ~sw ~base_path ~clock ~router ~token ->
    let await what ready =
      match
        Eio.Time.with_timeout real_clock failure_guard_s (fun () ->
          let rec loop () =
            if ready () then Ok () else (Eio.Condition.await_no_mutex clock.changed; loop ())
          in
          loop ())
      with
      | Ok () -> ()
      | Error `Timeout -> failf "%s did not happen" what
    in
    let wire = { bytes = Buffer.create 1024; ended = false; sleeps_at_last_write = 0 } in
    (* Waits until the pump, after the last frame went out, waits again. *)
    let await_stream_waiting () =
      let written = wire.sleeps_at_last_write in
      await "the stream's next wait" (fun () -> clock.sleeps > written)
    in
    let connection =
      Httpun.Server_connection.create (fun reqd ->
        Http.Router.dispatch router (Httpun.Reqd.request reqd) (Http_reqd.of_httpun reqd))
    in
    Eio.Fiber.fork ~sw (fun () -> read_writes clock connection wire);
    let body =
      Yojson.Safe.to_string
        (`Assoc [ "request_id", `String request_id; "name", `String keeper_name
                ; "message", `String "hello" ])
    in
    let raw_request =
      Printf.sprintf
        "POST /api/v1/keepers/chat/stream HTTP/1.1\r\n\
         Host: 127.0.0.1:8935\r\n\
         Authorization: Bearer %s\r\n\
         Accept: text/event-stream\r\n\
         Content-Type: application/json\r\n\
         Content-Length: %d\r\n\
         \r\n\
         %s"
        token (String.length body) body
    in
    let input = Bigstringaf.of_string ~off:0 ~len:(String.length raw_request) raw_request in
    Server_request_authority.with_current (loopback_request_authority ()) (fun () ->
      ignore (Httpun.Server_connection.read connection input ~off:0 ~len:(Bigstringaf.length input)
              : int));
    let accepted () = List.find_map accepted_state (frames wire) in
    await "the acceptance" (fun () -> Option.is_some (accepted ()));
    check (option string) "the operation is accepted queued" (Some "Queued") (accepted ());
    await_stream_waiting ();
    let before_keepalive = List.length (frames wire) in
    (* The TUI ends a keeper chat stream that stays silent for
       [keeper_chat_timeout_sec]. Just short of that silence the queued
       stream must have written. The time moves once, so only the wait the
       pump started at the acceptance comes due. *)
    Eio_mock.Clock.set_time clock.mock (Float.pred Masc_tui_http.keeper_chat_timeout_sec);
    await "a frame within the TUI's idle bound" (fun () ->
      List.length (frames wire) > before_keepalive);
    let keepalive =
      match List.filteri (fun index _ -> index >= before_keepalive) (frames wire) with
      | [ keepalive ] -> keepalive
      | written -> failf "one frame for the silence, got %d" (List.length written)
    in
    (* A frame with an id moves the cursor the TUI resumes from (since_seq),
       and a data frame is an event the projection reads. The keepalive is
       neither: a comment. *)
    check bool "the keepalive is a comment" true
      (List.exists (fun line -> line <> "" && line.[0] = ':') keepalive);
    check (list string) "the keepalive carries no field, so no id" [] (field_names keepalive);
    check bool "the stream is still open" false wire.ended;
    await_stream_waiting ();
    let operation_id =
      require_ok Fun.id (Keeper_owner.Chat_operation.Operation_id.of_string request_id)
    in
    let cancelled =
      require_ok Keeper_owner_registry.command_error_to_string
        (Keeper_owner_registry.cancel_queued_operation ~base_path ~keeper_name operation_id)
    in
    check bool "the operation settled" true
      (Keeper_owner.Chat_operation.is_terminal cancelled.Keeper_chat_operation.state);
    let before_close = List.length (frames wire) in
    (* A cancel publishes no wire terminal. The stream reads the settled
       record at its next quiet interval and ends, so the TUI settles the
       request from the record before its own idle bound would. *)
    Eio_mock.Clock.set_time clock.mock
      (Eio.Time.now clock.mock +. Float.pred Masc_tui_http.keeper_chat_timeout_sec);
    await "the end of the response" (fun () -> wire.ended);
    check int "nothing written after the operation settled" before_close
      (List.length (frames wire)))
;;

let () =
  run "keeper chat stream keepalive HTTP"
    [ ( "actual router"
      , [ test_case "a queued stream keeps alive and ends when the operation settles" `Quick
            test_a_queued_stream_keeps_alive_and_ends_when_the_operation_settles
        ] )
    ]
;;
