(** Firefox native messaging host. stdout belongs exclusively to the framed
    protocol; operational diagnostics must never include tokens or page data. *)

let ( let* ) = Result.bind

(* Mozilla permits 1 MiB from host to browser, 4 GiB in the other direction.
   This reader deliberately applies the smaller resource bound both ways:
   browser lane page reads are bounded, and an unbounded tab list must fail
   explicitly rather than allocate a browser-controlled 4 GiB frame.
   https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/Native_messaging#app_side *)
let frame_limit = 1024 * 1024

(* The server's long-poll window is 25 seconds. These transport deadlines
   leave it room to finish and bound a dead extension or HTTP connection. *)
let http_timeout_sec = 55.
let extension_timeout_sec = 20.
let reconnect_delay_sec = 5.

type verb = Tabs_list | Page_read | Page_capture
type command = { id : string; verb : verb; args : Yojson.Safe.t }
type poll = Empty | Forward of command | Reject of string
type exchange_phase = Writing_frame | Awaiting_reply
type exchange = Replied of Yojson.Safe.t | Write_timed_out
type cycle = Continue | Stop of string

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
      | "page.capture" -> Ok (Forward { id; verb = Page_capture; args })
      | _ -> Ok (Reject id)

let command_json command =
  `Assoc
    [ "id", `String command.id
    ; "verb", `String (match command.verb with Tabs_list -> "tabs.list" | Page_read -> "page.read" | Page_capture -> "page.capture")
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
      Ok (id, failure id error)
  | _ -> Error "reply ok must be a boolean"

let read_frame reader =
  if Eio.Buf_read.at_end_of_input reader then Ok None
  else
    try
      let header = Eio.Buf_read.take 4 reader |> Bytes.of_string in
      let length =
        Int64.logand (Int64.of_int32 (Bytes.get_int32_le header 0)) 0xffff_ffffL
      in
      if length = 0L || length > Int64.of_int frame_limit then
        Error "native frame length is outside the 1 MiB limit"
      else
        let* json = parse_json (Eio.Buf_read.take (Int64.to_int length) reader) in
        Ok (Some json)
    with
    | End_of_file -> Error "truncated native frame"
    | Eio.Buf_read.Buffer_limit_exceeded -> Error "native frame exceeds buffer limit"

let write_frame stdout json =
  let payload = Yojson.Safe.to_string json in
  let length = String.length payload in
  if length > frame_limit then Error "command exceeds native frame limit"
  else (
    let header = Bytes.create 4 in
    Bytes.set_int32_le header 0 (Int32.of_int length);
    Eio.Flow.copy_string (Bytes.to_string header) stdout;
    Eio.Flow.copy_string payload stdout;
    Ok ())

type config = { server : Uri.t; token_file : string }

let resolve_config ~base_path ~server ~token_file =
  try
    let base =
      match base_path with
      | Some path -> Env_config_core.normalize_masc_base_path_input path
      | None -> Env_config_core.base_path ()
    in
    let server =
      match server with
      | Some url -> url
      | None ->
          (match Env_config_core.masc_http_base_url_opt () with
           | Some url -> url
           | None ->
               Uri.make ~scheme:"http"
                 ~host:(Masc_network_defaults.normalize_advertised_host (Env_config_core.masc_host ()))
                 ~port:(Env_config_core.masc_http_port_int ()) ()
               |> Uri.to_string)
    in
    let server = Uri.of_string server in
    let loopback =
      match Option.map String.lowercase_ascii (Uri.host server) with
      | Some ("127.0.0.1" | "localhost" | "::1") -> true
      | Some _ | None -> false
    in
    let valid_port =
      match Uri.port server with None -> true | Some port -> port > 0 && port <= 65535
    in
    if Uri.scheme server <> Some "http" || not loopback || not valid_port
       || Uri.userinfo server <> None || Uri.query server <> []
       || Uri.fragment server <> None
       || (Uri.path server <> "" && Uri.path server <> "/") then
      Error "--server must be a loopback http origin without credentials, path, query or fragment"
    else
      let token_file =
        match token_file with
        | Some path ->
            if Filename.is_relative path then Filename.concat base path else path
        | None -> Filename.concat (Filename.concat base Common.masc_dirname) "browser-lane/token"
      in
      Ok { server; token_file }
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

let endpoint config path =
  Uri.with_path config.server
    (Env_config_core.strip_trailing_slashes (Uri.path config.server) ^ "/browser-lane/" ^ path)

type http_error = Http_status of int | Transport_failed | Response_invalid | Response_too_large | Request_timed_out

let http_error_message = function
  | Http_status status -> Printf.sprintf "HTTP %d" status
  | Transport_failed -> "HTTP transport failed"
  | Response_invalid -> "invalid HTTP response"
  | Response_too_large -> "HTTP response exceeds 1 MiB"
  | Request_timed_out -> "HTTP request timed out"

let post ~clock ~client ~config ~token path json =
  Eio.Fiber.first
    (fun () ->
      try
        Eio.Switch.run (fun sw ->
          let response, body =
            Cohttp_eio.Client.post client ~sw
              ~headers:(Cohttp.Header.of_list
                [ "Content-Type", "application/json"; "x-lane", "live"; "x-lane-token", token ])
              ~body:(Cohttp_eio.Body.of_string (Yojson.Safe.to_string json))
              (endpoint config path)
          in
          let status = Cohttp.Response.status response |> Cohttp.Code.code_of_status in
          if status <> 200 then Error (Http_status status)
          else
            let body = Eio.Buf_read.of_flow body ~max_size:(frame_limit + 1) in
            parse_json (Eio.Buf_read.take_all body)
            |> Result.map_error (fun _ -> Response_invalid))
      with
      | Eio.Io _ | End_of_file -> Error Transport_failed
      | Eio.Buf_read.Buffer_limit_exceeded -> Error Response_too_large
      | Failure _ | Invalid_argument _ -> Error Response_invalid)
    (fun () -> Eio.Time.sleep clock http_timeout_sec; Error Request_timed_out)

let run env config =
  let clock = Eio.Stdenv.clock env in
  let client = Cohttp_eio.Client.make ~https:None (Eio.Stdenv.net env) in
  let reader = Eio.Buf_read.of_flow (Eio.Stdenv.stdin env) ~max_size:(frame_limit + 4) in
  (* Single Eio domain; reading/writing this cell has no suspension point.
     One pending command is the ownership contract of the serial live host. *)
  let pending : (string * Yojson.Safe.t Eio.Promise.u) option ref = ref None in
  let rec receive () =
    let* frame = read_frame reader in
    match frame with
    | None -> Ok ()
    | Some json ->
        let* id, payload = decode_reply json in
        (match !pending with
         | Some (expected, resolver) when String.equal id expected ->
             pending := None;
             Eio.Promise.resolve resolver payload
         | Some _ | None -> ());
        receive ()
  in
  let forward command =
    let promise, resolver = Eio.Promise.create () in
    pending := Some (command.id, resolver);
    let phase = ref Writing_frame in
    let answer =
      Eio.Fiber.first
        (fun () ->
          match write_frame (Eio.Stdenv.stdout env) (command_json command) with
          | Error detail -> Replied (failure command.id detail)
          | Ok () ->
              phase := Awaiting_reply;
              Replied (Eio.Promise.await promise))
        (fun () ->
          Eio.Time.sleep clock extension_timeout_sec;
          match !phase with
          | Awaiting_reply -> Replied (failure command.id "extension reply timed out")
          | Writing_frame -> Write_timed_out)
    in
    pending := None;
    answer
  in
  let rec publish payload =
    let* token = read_token config.token_file in
    match post ~clock ~client ~config ~token "result" payload with
    | Ok (`Assoc fields) when List.assoc_opt "ok" fields = Some (`Bool true) -> Ok ()
    | Ok _ -> Error "invalid result acknowledgement"
    | Error (Http_status 400) ->
        (* A restarted server no longer owns this request. Return to polling
           so it can register the lane; retrying the old result would deadlock
           reconnection. Record the lost receipt instead of claiming delivery. *)
        Error "server rejected result; request ownership was lost"
    | Error error ->
        Log.Transport.warn "browser-host: result delivery failed: %s"
          (http_error_message error);
        Eio.Time.sleep clock reconnect_delay_sec;
        publish payload
  in
  let rec poll () =
    (* Reread at each poll so a token rotation does not require restarting Firefox. *)
    let result =
      let* token = read_token config.token_file in
      let* response =
        post ~clock ~client ~config ~token "poll" (`Assoc [])
        |> Result.map_error http_error_message
      in
      let* next = decode_poll response in
      match next with
       | Empty -> Ok Continue
       | Reject id ->
           let* () = publish (failure id "unsupported live browser verb") in
           Ok Continue
       | Forward command ->
           (match forward command with
            | Replied payload -> let* () = publish payload in Ok Continue
            | Write_timed_out ->
                (* A partial frame cannot be followed by another command.
                   Close this stream and let the extension reconnect. *)
                Ok (Stop "native frame write timed out"))
    in
    match result with
    | Ok (Stop detail) -> Error detail
    | Ok Continue -> poll ()
    | Error detail ->
        Log.Transport.warn "browser-host: poll failed: %s" detail;
        Eio.Time.sleep clock reconnect_delay_sec;
        poll ()
  in
  Eio.Fiber.first receive poll

let () =
  Log.init_from_env ();
  let base_path = ref None and server = ref None and token_file = ref None in
  let positional = ref [] in
  let set target value = target := Some value in
  let options =
    [ "--base-path", Arg.String (set base_path), "PATH Workspace containing .masc (or MASC_BASE_PATH)"
    ; "--server", Arg.String (set server), "URL MASC HTTP server (or existing MASC HTTP configuration)"
    ; "--token-file", Arg.String (set token_file), "PATH Lane token (default: <base-path>/.masc/browser-lane/token)"
    ]
  in
  Arg.parse options (fun value -> positional := value :: !positional)
    "masc-browser-host [--base-path PATH] [--server URL] [--token-file PATH]";
  let arguments_valid =
    match List.rev !positional with
    | [] | [ _ ] -> true
    | [ _; "browser-lane@masc.local" ] -> true
    | _ -> false
  in
  let result =
    if not arguments_valid then Error "unexpected native host arguments"
    else if Sys.big_endian then Error "native host requires a little-endian platform"
    else
      let* config = resolve_config ~base_path:!base_path ~server:!server ~token_file:!token_file in
      (* Firefox owns the pipe's reader; this executable owns its writer.
         POSIX readiness does not promise that a whole native frame fits:
         a blocking writev can otherwise stop Eio's timer and stdin fibers
         on macOS. Configure before Eio first queries/caches the FD mode. *)
      let* () = match Unix.set_nonblock Unix.stdout with
        | () -> Ok ()
        | exception Unix.Unix_error _ -> Error "native stdout setup failed" in
      try Eio_main.run (fun env -> run env config)
      with Eio.Io _ -> Error "native messaging connection failed"
  in
  match result with
  | Ok () -> ()
  | Error detail -> Log.Transport.error "browser-host: %s" detail; exit 1
