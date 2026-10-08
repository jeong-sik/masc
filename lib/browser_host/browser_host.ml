(** Firefox native messaging host. stdout belongs exclusively to the framed
    protocol; operational diagnostics must never include tokens or page data. *)

let ( let* ) = Result.bind

(* Mozilla limits host-to-browser messages to 1 MiB. Browser-to-host frames
   have a separate 8 MiB resource bound: this admits a 5 MiB Vision PNG after
   base64 encoding plus its JSON envelope, without admitting a 4 GiB frame.
   https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/Native_messaging#app_side *)
let command_frame_limit = 1024 * 1024
let reply_frame_limit = 8 * 1024 * 1024

(* The server's long-poll window is 25 seconds. These transport deadlines
   leave it room to finish and bound a dead extension or HTTP connection. *)
let http_timeout_sec = 55.
let extension_timeout_sec = 20.
let reconnect_delay_sec = 5.
(* How long a host that is leaving waits on the server for a request already
   in flight: its disconnect, and a result the server is acknowledging. *)
let leaving_window_sec = 0.25

type verb = Masc.Browser_bidi_peer.verb =
  | Browser_info | Tabs_list | Page_read | Page_elements | Page_capture | Page_scene | Page_interact
type command = { id : string; verb : verb; args : Yojson.Safe.t }
type poll = Empty | Forward of command | Reject of string
type exchange_phase = Writing_frame | Awaiting_reply
type exchange = Replied of Yojson.Safe.t | Write_timed_out

let object_fields = function
  | `Assoc fields -> Ok fields
  | _ -> Error "expected a JSON object"

let required_string fields key =
  match List.assoc_opt key fields with
  | Some (`String value) when String.trim value <> "" -> Ok value
  | _ -> Error ("missing or invalid " ^ key)

let parse_json raw =
  try Ok (Yojson.Safe.from_string raw)
  with Yojson.Json_error _ -> Error "invalid JSON"

let decode_poll json =
  let* fields = object_fields json in
  match List.assoc_opt "id" fields with
  | None ->
      (match List.assoc_opt "ok" fields, List.assoc_opt "empty" fields with
       | Some (`Bool true), Some (`Bool true) -> Ok Empty
       | _ -> Error "invalid empty poll response")
  | Some _ ->
      let* id = required_string fields "id" in
      let* name = required_string fields "verb" in
      let* args =
        match List.assoc_opt "args" fields with
        | Some (`Assoc _ as args) -> Ok args
        | _ -> Error "command args must be an object"
      in
      match name with
      | "tabs.list" -> Ok (Forward { id; verb = Tabs_list; args })
      | "page.read" -> Ok (Forward { id; verb = Page_read; args })
      | "page.scene" -> Ok (Forward { id; verb = Page_scene; args })
      | "page.elements" -> Ok (Forward { id; verb = Page_elements; args })
      | "page.capture" -> Ok (Forward { id; verb = Page_capture; args })
      | "page.interact" -> Ok (Forward { id; verb = Page_interact; args })
      | _ -> Ok (Reject id)

let command_json ~deadline_ms command =
  `Assoc
    [ "id", `String command.id
    ; "verb", `String
        (match command.verb with
         | Browser_info -> "browser.info"
         | Tabs_list -> "tabs.list"
         | Page_read -> "page.read"
         | Page_scene -> "page.scene"
         | Page_elements -> "page.elements"
         | Page_capture -> "page.capture"
         | Page_interact -> "page.interact")
    ; "deadlineMs", `Float deadline_ms
    ; "args", command.args
    ]

let failure id error =
  `Assoc [ "id", `String id; "ok", `Bool false; "error", `String error ]

let decode_reply json =
  let* fields = object_fields json in
  let* id = required_string fields "id" in
  match List.assoc_opt "ok" fields with
  | Some (`Bool true) ->
      (match List.assoc_opt "data" fields with
       | Some data -> Ok (id, `Assoc [ "id", `String id; "ok", `Bool true; "data", data ])
       | None -> Error "successful reply has no data")
  | Some (`Bool false) ->
      let* error = required_string fields "error" in
      let phase = match List.assoc_opt "effectPhase" fields with
        | Some (`String "not_started") -> ["effectPhase", `String "not_started"]
        | _ -> [] in
      Ok (id, `Assoc (["id", `String id; "ok", `Bool false; "error", `String error] @ phase))
  | _ -> Error "reply ok must be a boolean"

let read_frame reader =
  if Eio.Buf_read.at_end_of_input reader then Ok None
  else
    try
      let header = Eio.Buf_read.take 4 reader |> Bytes.of_string in
      let length =
        Int64.logand (Int64.of_int32 (Bytes.get_int32_le header 0)) 0xffff_ffffL
      in
      if length = 0L || length > Int64.of_int reply_frame_limit then
        Error "native frame length is outside the 8 MiB reply limit"
      else
        let* json = parse_json (Eio.Buf_read.take (Int64.to_int length) reader) in
        Ok (Some json)
    with
    | End_of_file -> Error "truncated native frame"
    | Eio.Buf_read.Buffer_limit_exceeded -> Error "native frame exceeds buffer limit"

let write_frame stdout json =
  let payload = Yojson.Safe.to_string json in
  let length = String.length payload in
  if length > command_frame_limit then Error "command exceeds native frame limit"
  else (
    let header = Bytes.create 4 in
    Bytes.set_int32_le header 0 (Int32.of_int length);
    Eio.Flow.copy_string (Bytes.to_string header) stdout;
    Eio.Flow.copy_string payload stdout;
    Ok ())

(* Where polls go. An explicit --server, MASC_HTTP_BASE_URL or MASC_HTTP_PORT
   is a fixed choice. Otherwise the workspace connection.toml names the port.
   That file is the desired endpoint, which the server and other commands
   write, not proof that a server answers there, so the host moves to the
   port it names only once that address answers the lane. *)
type destination = Fixed | Workspace of string
type config = { destination : destination; server : Uri.t; token_file : string; client_id : string }
type browser_info = { browser : string; version : string; engine_version : string;
  transport : Browser_lane.live_transport }
let browser_info json =
  let* envelope = object_fields json in
  if List.assoc_opt "ok" envelope <> Some (`Bool true) then Error "browser metadata unavailable"
  else
    let* fields = match List.assoc_opt "data" envelope with
      | Some data -> object_fields data | None -> Error "browser metadata missing" in
    let version fields key =
      let* value = required_string fields key in
      if String.length value <= 64 && String.for_all (fun c -> Char.code c >= 33 && Char.code c <= 126) value
      then Ok value else Error "invalid browser version" in
    let* engine_version = version fields "version" in
    match List.assoc_opt "zen" fields with
    | Some (`Assoc zen) ->
      let* version = version zen "version" in
      Ok {browser="zen"; version; engine_version; transport=Browser_lane.Web_extension}
    | None when List.assoc_opt "name" fields = Some (`String "Firefox") ->
      Ok {browser="firefox"; version=engine_version; engine_version; transport=Browser_lane.Web_extension}
    | Some _ | None -> Error "unsupported browser metadata"

let loopback_origin raw =
  let server = Uri.of_string raw in
  let loopback = Masc_network_defaults.is_loopback_host_opt (Uri.host server) in
  let valid_port =
    match Uri.port server with None -> true | Some port -> port > 0 && port <= 65535
  in
  if Uri.scheme server <> Some "http" || not loopback || not valid_port
     || Uri.userinfo server <> None || Uri.query server <> []
     || Uri.fragment server <> None
     || (Uri.path server <> "" && Uri.path server <> "/") then
    Error "--server must be a loopback http origin without credentials, path, query or fragment"
  else Ok server

(* A port that fails to resolve is reported, never silently replaced by a
   default the server may not be listening on. *)
let workspace_server ~environment base =
  try
    match Workspace_connection.resolve ~base_path:(Some base)
            ~cli:None ~environment with
    | Error error -> Error (Workspace_connection.error_message error)
    | Ok port ->
        Uri.make ~scheme:"http"
          ~host:(Masc_network_defaults.normalize_advertised_host (Env_config_core.masc_host ()))
          ~port:(Workspace_connection.to_int port) ()
        |> Uri.to_string |> loopback_origin
  with
  | Env_config_core.Config_error message -> Error message
  | Invalid_argument _ -> Error "invalid workspace server origin"

let resolve_config ~base_path ~server ~token_file =
  try
    let base =
      match base_path with
      | Some path -> Env_config_core.normalize_masc_base_path_input path
      | None -> Env_config_core.base_path ()
    in
    (* Workspace_connection reads the connection file through an ownership
       chain that rejects a relative root. The browser spawns this host with
       the launcher's absolute base; a manually invoked relative base keeps
       working by anchoring it to the working directory. *)
    let base =
      if Filename.is_relative base then
        match Sys.getcwd () with
        | directory -> Filename.concat directory base
        | exception Sys_error _ -> base
      else base
    in
    let* destination, server =
      match server, Env_config_core.masc_http_base_url_opt (), Env_config_core.masc_http_port_opt () with
      | Some url, _, _ | None, Some url, _ -> Result.map (fun server -> Fixed, server) (loopback_origin url)
      | None, None, (Some _ as environment) ->
          Result.map (fun server -> Fixed, server) (workspace_server ~environment base)
      | None, None, None ->
          Result.map (fun server -> Workspace base, server) (workspace_server ~environment:None base)
    in
    let token_file =
      match token_file with
      | Some path ->
          if Filename.is_relative path then Filename.concat base path else path
      | None -> Filename.concat (Filename.concat base Common.masc_dirname) "browser-lane/token"
    in
    Ok { destination; server; token_file; client_id = Random_id.uuid_v7 () }
  with
  | Env_config_core.Config_error message -> Error message
  | Invalid_argument _ -> Error "invalid server origin or base path"

let read_token path =
  try
    let token = In_channel.with_open_bin path In_channel.input_all |> String.trim in
    if String.length token < 16
       || not (String.for_all (fun c -> Char.code c >= 33 && Char.code c <= 126) token)
    then Error "lane token file is empty or invalid"
    else Ok token
  with Sys_error _ -> Error "cannot read lane token file"

let endpoint server path =
  Uri.with_path server
    (Env_config_core.strip_trailing_slashes (Uri.path server) ^ "/browser-lane/" ^ path)

type http_error = Http_status of int | Transport_failed | No_response | Response_invalid | Response_too_large | Request_timed_out
type poll_error = Invalid_client | Poll_unanswered of http_error | Poll_failed of string
type destination_change = Unchanged | Moved
(* Whether an address answers this workspace's lane: a ping that holds the
   lane token and registers no client. *)
type lane_answer = Answers | Silent

(* Whether a failed request reached the server. [Reached] is an answer the
   server gave: a status, or a body this host could not accept. [Unreached]
   is a request the server may never have received: no connection, an
   exchange broken before an answer, a connection that closed without a
   response, or no answer within the window. *)
type reach = Reached | Unreached

let reach = function
  | Http_status _ | Response_invalid | Response_too_large -> Reached
  | Transport_failed | No_response | Request_timed_out -> Unreached

(* Why a result stayed undelivered. Each is recorded once; none is sent
   again. *)
type result_undelivered =
  | Refused_by_server of http_error
  | Not_acknowledged
  | Issuer_moved
  | Token_unreadable of string
  | Refused_on_resend of http_error
  | Unacknowledged_as_host_ended of http_error
  | Browser_left_first
  | Stopped_first

let http_error_message = function
  | Http_status status -> Printf.sprintf "HTTP %d" status
  | Transport_failed -> "HTTP transport failed"
  | No_response -> "the connection gave no HTTP response"
  | Response_invalid -> "invalid HTTP response"
  | Response_too_large -> "HTTP response exceeds 1 MiB"
  | Request_timed_out -> "HTTP request timed out"

let result_undelivered_message = function
  | Refused_by_server error ->
      "the server received the result and did not accept it (" ^ http_error_message error ^ ")"
  | Not_acknowledged -> "the server answered the result without an acknowledgement"
  | Issuer_moved -> "the server that issued the request stopped answering and another answers"
  | Token_unreadable detail -> detail
  | Refused_on_resend error ->
      "the server answered the re-sent result with " ^ http_error_message error
      ^ "; it may have taken an earlier attempt"
  | Unacknowledged_as_host_ended error ->
      "the host was ending and its one attempt was not acknowledged (" ^ http_error_message error ^ ")"
  | Browser_left_first -> "the browser connection ended before the server acknowledged the result"
  | Stopped_first -> "the host was stopped before the server acknowledged the result"

(* A transport step under its deadline. The step's outcome stands when the
   step finished, even as the deadline passed; [None] only when it had not.
   The extension aborts a command at the very [deadlineMs] the host sends
   it, so its reply and the host's own timer land together by design. *)
let within ~clock seconds step =
  Watched_work.run
    ~watcher:(fun () ->
      Eio.Time.sleep clock seconds;
      None)
    (fun () -> Some (step ()))

let post ~clock ~client ~server ~config ~info ~token path json =
  match
    within ~clock http_timeout_sec (fun () ->
      try
        Eio.Switch.run (fun sw ->
          match
            Cohttp_eio.Client.post client ~sw
              ~headers:(Cohttp.Header.of_list
                [ "Content-Type", "application/json"; "x-lane", Browser_lane.Lane_name.(to_wire Live); "x-lane-token", token;
                  "x-browser-client-id", config.client_id; "x-browser-name", info.browser;
                  "x-browser-version", info.version; "x-browser-engine-version", info.engine_version;
                  "x-browser-transport", Browser_lane.live_transport_to_string info.transport ])
              ~body:(Cohttp_eio.Body.of_string (Yojson.Safe.to_string json))
              (endpoint server path)
          with
          (* cohttp-eio reports as [Failure] a peer that closed the connection
             before a response head, one that sent something that is not a
             head, and a host name it could not resolve. In each there is no
             answer from the server, which a status or a body would be. *)
          | exception Failure _ -> Error No_response
          | response, body ->
            let status = Cohttp.Response.status response |> Cohttp.Code.code_of_status in
            if status <> 200 then Error (Http_status status)
            else
              let body = Eio.Buf_read.of_flow body ~max_size:(command_frame_limit + 1) in
              parse_json (Eio.Buf_read.take_all body)
              |> Result.map_error (fun _ -> Response_invalid))
      with
      | Eio.Io _ | End_of_file -> Error Transport_failed
      | Eio.Buf_read.Buffer_limit_exceeded -> Error Response_too_large
      | Failure _ | Invalid_argument _ -> Error Response_invalid)
  with
  | Some outcome -> outcome
  | None -> Error Request_timed_out

(* Single Eio domain; reading/writing this cell has no suspension point.
   One pending command is the ownership contract of the serial live host. *)
type pending = (string * Yojson.Safe.t Eio.Promise.u) option ref

let no_pending () : pending = ref None

let settle (pending : pending) json =
  let* id, payload = decode_reply json in
  (match !pending with
   | Some (expected, resolver) when String.equal id expected ->
       pending := None;
       Eio.Promise.resolve resolver payload
   | Some _ | None -> ());
  Ok ()

let forward ~clock ~stdout (pending : pending) command =
  let promise, resolver = Eio.Promise.create () in
  pending := Some (command.id, resolver);
  let phase = ref Writing_frame in
  (* The deadline the extension is handed and the window the host arms
     below are read off one clock; the extension compares it with its own
     wall clock, which is what this clock is in the host process. *)
  let deadline_ms = ceil ((Eio.Time.now clock +. extension_timeout_sec) *. 1000.) in
  let answer =
    Watched_work.run
      ~watcher:(fun () ->
        Eio.Time.sleep clock extension_timeout_sec;
        match !phase with
        | Awaiting_reply -> Replied (failure command.id "extension reply timed out")
        | Writing_frame -> Write_timed_out)
      (fun () ->
        match write_frame stdout (command_json ~deadline_ms command) with
        | Error detail -> Replied (failure command.id detail)
        | Ok () ->
            phase := Awaiting_reply;
            Replied (Eio.Promise.await promise))
  in
  pending := None;
  answer

(* The server side of a live host: who it polls as, and where. Only the fiber
   that polls reads and replaces [server]. Its requests suspend, but no other
   fiber writes [server] in between, and the disconnect at the end reads it
   after that fiber has finished. *)
type link =
  { clock : float Eio.Time.clock_ty Eio.Resource.t
  ; client : Cohttp_eio.Client.t
  ; config : config
  ; info : browser_info
  ; mutable server : Uri.t
  }

let ask link ~server ~token path json =
  post ~clock:link.clock ~client:link.client ~server ~config:link.config ~info:link.info ~token path json

let ask_lane link origin =
  match read_token link.config.token_file with
  | Error _ -> Silent
  | Ok token ->
      (match ask link ~server:origin ~token "ping" (`Assoc []) with
       | Ok (`Assoc fields) when List.assoc_opt "ok" fields = Some (`Bool true) -> Answers
       | Ok _ | Error _ -> Silent)

(* Called only after a request to [link.server] failed: that failure is the
   event that the server may have moved. A fixed destination never moves.
   The connection file is only the desired port, so a failure alone moves
   nothing: the host stays while its server still answers the lane, and
   moves only to an address that answers it. *)
let follow_workspace link =
  match link.config.destination with
  | Fixed -> Unchanged
  | Workspace base ->
      (match workspace_server ~environment:None base with
       | Error detail ->
           Log.Transport.warn "browser-host: workspace connection unreadable after a failed request: %s" detail;
           Unchanged
       | Ok resolved when Uri.equal resolved link.server -> Unchanged
       | Ok resolved ->
           (match ask_lane link link.server with
            | Answers ->
                Log.Transport.info "browser-host: %s still answers; staying while the connection names %s"
                  (Uri.to_string link.server) (Uri.to_string resolved);
                Unchanged
            | Silent ->
                (match ask_lane link resolved with
                 | Silent ->
                     Log.Transport.info "browser-host: the connection names %s, which does not answer yet"
                       (Uri.to_string resolved);
                     Unchanged
                 | Answers ->
                     Log.Transport.info "browser-host: moving to %s, which answers the lane"
                       (Uri.to_string resolved);
                     link.server <- resolved;
                     Moved)))

(* One attempt to hand a result to the server. *)
type delivery = Delivered | Undelivered of result_undelivered | Unreached of http_error

let deliver link payload =
  match read_token link.config.token_file with
  | Error detail -> Undelivered (Token_unreadable detail)
  | Ok token ->
      (match ask link ~server:link.server ~token "result" payload with
       | Ok (`Assoc fields) when List.assoc_opt "ok" fields = Some (`Bool true) -> Delivered
       | Ok _ -> Undelivered Not_acknowledged
       | Error error ->
           (match reach error with
            (* The server received these bytes and answered: a 400 for a
               request it no longer owns, a 413 for a body over its limit, a
               5xx for a failure it already met. The same bytes ask the same
               question again, so the host records the answer and polls. *)
            | Reached -> Undelivered (Refused_by_server error)
            | Unreached -> Unreached error))

(* A result that may not have reached the server is sent again until it is
   delivered or the server answers it. The server takes a result once: when
   an earlier attempt did arrive and only its answer was lost, the attempt
   after it is refused, and the host cannot tell that from a request the
   server gave up on. A restarted server has no memory of the request, so
   there the result is lost whichever attempt arrives. *)
let rec publish ?(resent = false) link payload =
  match deliver link payload with
  | Delivered -> Ok ()
  | Undelivered (Refused_by_server error) when resent -> Error (Refused_on_resend error)
  | Undelivered why -> Error why
  | Unreached error ->
      Log.Transport.warn "browser-host: result delivery failed: %s" (http_error_message error);
      Eio.Time.sleep link.clock reconnect_delay_sec;
      (match follow_workspace link with
       | Unchanged -> publish ~resent:true link payload
       (* The server that issued the request no longer answers and another
          does; polling there registers the lane again. *)
       | Moved -> Error Issuer_moved)

(* The last result of a host that is ending is offered once: no later poll
   exists for another attempt to come before. *)
let publish_once link payload =
  match deliver link payload with
  | Delivered -> Ok ()
  | Undelivered why -> Error why
  | Unreached error -> Error (Unacknowledged_as_host_ended error)

let record_delivery = function
  | Ok () -> ()
  | Error undelivered ->
      Log.Transport.warn "browser-host: result not delivered: %s"
        (result_undelivered_message undelivered)

(* What the server asks for next. A poll that got no answer, or an answer
   this host cannot read, is asked again after a pause: nothing has been sent
   to the browser, so asking again repeats no effect. Only a registration the
   server refuses is an error. *)
let rec next_command link =
  let asked =
    let* token =
      read_token link.config.token_file |> Result.map_error (fun detail -> Poll_failed detail) in
    let* response =
      ask link ~server:link.server ~token "poll" (`Assoc [])
      |> Result.map_error (function
        | Http_status 400 -> Invalid_client
        | error -> Poll_unanswered error) in
    decode_poll response |> Result.map_error (fun detail -> Poll_failed detail)
  in
  match asked with
  | Ok next -> Ok next
  | Error Invalid_client -> Error "native client registration rejected"
  | Error (Poll_unanswered error) ->
      Log.Transport.warn "browser-host: poll failed: %s" (http_error_message error);
      Eio.Time.sleep link.clock reconnect_delay_sec;
      (match follow_workspace link with Unchanged | Moved -> next_command link)
  | Error (Poll_failed detail) ->
      Log.Transport.warn "browser-host: poll failed: %s" detail;
      Eio.Time.sleep link.clock reconnect_delay_sec;
      next_command link

(* Ending this client at the server. Best effort and bounded: a dead server
   must not keep the host alive, and nobody is left to report a failure to. *)
let disconnect link =
  match read_token link.config.token_file with
  | Error _ -> ()
  | Ok token ->
      Eio.Fiber.first
        (fun () -> ignore (ask link ~server:link.server ~token "disconnect" (`Assoc [])))
        (fun () -> Eio.Time.sleep link.clock leaving_window_sec)

let run env config =
  let clock = Eio.Stdenv.clock env in
  let client = Cohttp_eio.Client.make ~https:None (Eio.Stdenv.net env) in
  let reader = Eio.Buf_read.of_flow (Eio.Stdenv.stdin env) ~max_size:(reply_frame_limit + 4) in
  let pending = no_pending () in
  let rec receive () =
    let* frame = read_frame reader in
    match frame with
    | None -> Ok ()
    | Some json ->
        let* () = settle pending json in
        receive ()
  in
  let forward = forward ~clock ~stdout:(Eio.Stdenv.stdout env) pending in
  let registered = ref None in
  let run_poll () =
    match forward {id="browser-info"; verb=Browser_info; args=`Assoc []} with
    | Write_timed_out -> Error "browser metadata frame write timed out"
    | Replied reply ->
      let* info = browser_info reply in
      let link = { clock; client; config; info; server = config.server } in
      registered := Some link;
      let rec serve () =
        let* next = next_command link in
        match next with
        | Empty -> serve ()
        | Reject id ->
          record_delivery (publish link (failure id "unsupported live browser verb"));
          serve ()
        | Forward command ->
          (match forward command with
           | Replied payload -> record_delivery (publish link payload); serve ()
           | Write_timed_out -> Error "native frame write timed out")
      in
      serve () in
  (* Both arms are real endings, and the poll's is the one that says why:
     Firefox closing stdin and the server refusing the lane in the same
     scheduler pass would otherwise end the host with [Ok ()] and no
     word. [Fiber.first] keeps whichever finished first, so the poll's
     outcome is named the work and stands. *)
  let outcome = Watched_work.run ~watcher:receive run_poll in
  (* EOF ends this native-process identity; a failed disconnect must not
     retain Firefox's native child. *)
  Option.iter disconnect !registered;
  outcome

(* Why a BiDi host leaves its wait on the server. *)
type leaving = Browser_gone of string | Stop_asked of string

(* BiDi owns the attached contexts; the operator owns Firefox. This path never
   sends browser.close or browsingContext.close.

   The host stays for as long as both of its sides can be served. A MASC
   server that stops answering is asked again, at the address the workspace
   names, exactly as the extension host does: restarting the server does not
   end this host. It ends when the BiDi connection has ended, also while it
   waits for work, when a command's outcome is unknown, when the server
   refuses its registration, and when [stop] says the operator asked.

   On each of those ways out, and when an exception raised while it serves
   leaves it, it ends the BiDi session it asked for. Firefox keeps a session
   whose socket closed and takes one at a time, so a host that left its
   session behind could only be attached again after restarting that
   Firefox. *)
let run_bidi env config url ~stop =
  let clock = Eio.Stdenv.clock env in
  let client = Cohttp_eio.Client.make ~https:None (Eio.Stdenv.net env) in
  Eio.Switch.run @@ fun stop_sw ->
  let stopping, set_stopping = Eio.Promise.create () in
  Eio.Fiber.fork_daemon ~sw:stop_sw (fun () ->
    Eio.Promise.resolve set_stopping (stop ());
    `Stop_daemon);
  let stopped_unattached asked =
    Log.Transport.info "browser-host: stopped by %s before it was attached" asked;
    Ok ()
  in
  (* Set once the BiDi connection is up and nobody had asked to stop. Until
     then a stop abandons the attempt to connect: no session was asked for.
     From then on the serving fiber sees the stop itself and leaves in
     order. *)
  let attached = ref false in
  let serve_link ~ended peer link =
    Eio.Switch.run (fun sw ->
      Eio.Switch.on_release sw (fun () -> disconnect link);
      let leaving () =
        match Eio.Promise.peek ended, Eio.Promise.peek stopping with
        | Some reason, (Some _ | None) -> Some (Browser_gone reason)
        | None, Some asked -> Some (Stop_asked asked)
        | None, None -> None
      in
      (* A wait on the server lasts only while Firefox is attached and nobody
         asked the host to stop, and [grace_sec] past that. What the server
         handed over as the wait ended stands. *)
      let while_serving ?(grace_sec = 0.) wait =
        match leaving () with
        | Some leaving -> Error leaving
        | None ->
            Watched_work.run
              ~watcher:(fun () ->
                let leaving =
                  Eio.Fiber.first
                    (fun () -> Browser_gone (Eio.Promise.await ended))
                    (fun () -> Stop_asked (Eio.Promise.await stopping))
                in
                Eio.Time.sleep clock grace_sec;
                Error leaving)
              (fun () -> Ok (wait ()))
      in
      let left = function
        | Browser_gone reason -> Error ("BiDi connection ended: " ^ reason)
        | Stop_asked asked ->
            Log.Transport.info "browser-host: stopped by %s" asked;
            Ok ()
      in
      let answer id = function
        | Ok data -> `Assoc [ "id", `String id; "ok", `Bool true; "data", data ]
        | Error (Masc.Browser_bidi_peer.Before_effect message) ->
            `Assoc
              [ "id", `String id; "ok", `Bool false; "error", `String message
              ; "effectPhase", `String "not_started" ]
        | Error (Masc.Browser_bidi_peer.Outcome_unknown message) -> failure id message
      in
      (* A result is sent again for as long as the host is serving. When it
         leaves, an attempt already in flight gets a moment for the server's
         acknowledgement, so a result the server is taking is not reported
         lost; one cut short is recorded like any other undelivered one. *)
      let publish_while_serving payload =
        match while_serving ~grace_sec:leaving_window_sec (fun () -> publish link payload) with
        | Ok delivery -> record_delivery delivery; Ok ()
        | Error leaving ->
            record_delivery
              (Error (match leaving with
                 | Browser_gone _ -> Browser_left_first
                 | Stop_asked _ -> Stopped_first));
            Error leaving
      in
      (* An answer the host owes while it is serving, and its last one when
         it is leaving: that one is offered once, because no later poll could
         carry another attempt. *)
      let publish_answer payload =
        match leaving () with
        | Some leaving -> record_delivery (publish_once link payload); Error leaving
        | None -> publish_while_serving payload
      in
      let rec serve () =
        match while_serving (fun () -> next_command link) with
        | Error leaving -> left leaving
        | Ok (Error refused) -> Error refused
        | Ok (Ok Empty) -> serve ()
        | Ok (Ok (Reject id)) ->
            (match publish_answer (failure id "unsupported BiDi verb") with
             | Ok () -> serve ()
             | Error leaving -> left leaving)
        | Ok (Ok (Forward command)) ->
            let result =
              match
                within ~clock extension_timeout_sec (fun () ->
                  Masc.Browser_bidi_peer.dispatch peer ~verb:command.verb command.args)
              with
              | Some result -> result
              | None -> Error (Masc.Browser_bidi_peer.Outcome_unknown "BiDi command deadline exceeded")
            in
            let payload = answer command.id result in
            (match result with
             (* Any unknown outcome ends this client, preventing pointer
                replay or a next gesture while a previous button may remain
                pressed. *)
             | Error (Masc.Browser_bidi_peer.Outcome_unknown _) ->
                 record_delivery (publish_once link payload);
                 Error "BiDi client stopped after an unknown command outcome"
             | Ok _ | Error (Masc.Browser_bidi_peer.Before_effect _) ->
                 (match publish_answer payload with
                  | Ok () -> serve ()
                  | Error leaving -> left leaving))
      in
      serve ())
  in
  let serving () =
    Masc.Browser_bidi_peer.with_connection ~env ~timeout:extension_timeout_sec ~url (fun ~ended peer ->
      match Eio.Promise.peek stopping with
      | Some asked -> stopped_unattached asked
      | None ->
          attached := true;
          let session_left = ref false in
          let served =
            Eio.Switch.run (fun session_sw ->
              (* Registered before the session is asked for, so every way out
                 of this scope ends it, an exception raised in it included.
                 The server is told first: that hook is the inner one. A
                 cancellation from outside has taken the connection's fibers
                 down by the time this runs; the session is then reported as
                 not ended. *)
              Eio.Switch.on_release session_sw (fun () ->
                match Masc.Browser_bidi_peer.end_session peer with
                | Ok () -> ()
                | Error detail ->
                    session_left := true;
                    Log.Transport.warn
                      "browser-host: the BiDi session was not ended (%s); if that Firefox is still \
                       running, restart it before attaching again" detail);
              let* version =
                match within ~clock extension_timeout_sec (fun () -> Masc.Browser_bidi_peer.metadata peer) with
                | Some version -> version
                | None -> Error "BiDi metadata deadline exceeded" in
              let info =
                { browser = "firefox"; version; engine_version = version
                ; transport = Browser_lane.Webdriver_bidi } in
              serve_link ~ended peer { clock; client; config; info; server = config.server })
          in
          (* [Ok ()] says the host left in order and the same Firefox takes
             the next one. A stop that left its session behind is not that. *)
          (match served, !session_left with
           | Ok (), true -> Error "stopped with its BiDi session left in Firefox"
           | Ok (), false | Error _, (true | false) -> served))
  in
  Eio.Fiber.first serving (fun () ->
    let asked = Eio.Promise.await stopping in
    if !attached then Eio.Fiber.await_cancel () else stopped_unattached asked)

module For_testing = struct
  let within = within
end
