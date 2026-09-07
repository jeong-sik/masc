module Endpoint = Ws_direct_core.Endpoint
module Message = Ws_direct_core.Connection.Message
let ( let* ) = Result.bind
exception Stop
let field key = function `Assoc fields -> List.assoc_opt key fields | _ -> None
let string key json = match field key json with
  | Some (`String value) when value <> "" -> Ok value
  | _ -> Error ("BiDi missing string: " ^ key)

let verify_file ~root path =
  try
    let root = Unix.realpath root in
    let stat = Unix.lstat path in
    let canonical = Unix.realpath path in
    if stat.Unix.st_kind <> Unix.S_REG then Error "download is not a regular file"
    else if not (String.starts_with ~prefix:(root ^ Filename.dir_sep) canonical)
    then Error "download path is outside session staging"
    else Ok (canonical, stat.Unix.st_size)
  with
  | Unix.Unix_error (code, _, _) -> Error (Unix.error_message code)
  | Sys_error detail -> Error detail

let endpoint url =
  let uri = Uri.of_string url in
  match Uri.scheme uri, Uri.host uri, Uri.port uri, Uri.userinfo uri, Uri.fragment uri with
  | Some "ws", Some ("127.0.0.1" | "localhost" | "::1" as host), Some port, None, None
    when port > 0 && port <= 65535 ->
    let resource = Uri.path_and_query uri in
    if resource = "" || resource.[0] <> '/' then Error "invalid BiDi WebSocket path"
    else Ok (host, port, resource)
  | _ -> Error "Firefox must return a loopback ws URL with an explicit port"

(* Network deadlines bound individual protocol requests, never download
   lifetime. A pending download survives caller polling and becomes interrupted
   only when its evidence stream closes. *)
let command_timeout = 20.
let start ~sw ~env ~root ~publish:publish_artifact ~session_id ~websocket_url =
  let* host, port, resource = endpoint websocket_url in
  let ready, ready_u = Eio.Promise.create () in
  let stopped, stopped_u = Eio.Promise.create () in
  let model = Browser_downloads.create () in
  let failure = ref None in
  let pending = Hashtbl.create 4 in
  let disconnect reason =
    if !failure = None then (
      failure := Some reason;
      Browser_downloads.interrupt model reason;
      Hashtbl.iter (fun _ resolver -> Eio.Promise.resolve resolver (Error reason)) pending;
      Hashtbl.clear pending);
    if Eio.Promise.peek stopped = None then Eio.Promise.resolve stopped_u () in
  let publish result = if Eio.Promise.peek ready = None then Eio.Promise.resolve ready_u result in
  Eio.Fiber.fork ~sw (fun () ->
    try Eio.Switch.run (fun session_sw ->
      Eio.Switch.on_release session_sw (fun () ->
        disconnect "Firefox BiDi session closed";
        publish (Error "Firefox BiDi setup was interrupted"));
      let setup () =
        Crypto_rng.ensure_default ();
        let net = Eio.Stdenv.net env and clock = Eio.Stdenv.clock env in
        let addr = match Eio.Net.getaddrinfo_stream net host ~service:(string_of_int port) with
          | addr :: _ -> addr | [] -> failwith "BiDi loopback address unavailable" in
        let flow = Eio.Time.with_timeout_exn clock command_timeout (fun () -> Eio.Net.connect ~sw:session_sw net addr) in
        let on_message (message : Message.t) =
          if !failure <> None then () else
          let result = match message.kind with
            | Message.Binary -> Error "BiDi sent a binary message"
            | Message.Text ->
              (match Yojson.Safe.from_string (Bigstringaf.to_string message.payload) with
               | exception Yojson.Json_error detail -> Error ("invalid BiDi JSON: " ^ detail)
               | json ->
                 match field "type" json with
                 | Some (`String "event") ->
                   let* method_ = string "method" json in
                   (match field "params" json with
                    | Some params -> Browser_downloads.event model ~method_ params
                    | None -> Error "BiDi event lacks params")
                 | Some (`String ("success" | "error" as kind)) ->
                   (match field "id" json with
                    | Some (`Int id) ->
                      (match Hashtbl.find_opt pending id with
                       | None -> Ok ()
                       | Some resolver ->
                         Hashtbl.remove pending id;
                         let result = if kind = "success" then
                           (match field "result" json with Some result -> Ok result | None -> Error "BiDi response lacks result")
                         else let* code = string "error" json in
                           let detail = match field "message" json with Some (`String s) -> s | _ -> "" in
                           Error (code ^ ": " ^ detail) in
                         Eio.Promise.resolve resolver result; Ok ())
                    | _ -> Error "BiDi response lacks integer id")
                 | _ -> Error "BiDi response has unknown type") in
          match result with Ok () -> () | Error reason -> disconnect reason in
        let builder _ = Endpoint.handlers ~on_message
          ~on_close:(fun ~code:_ ~reason -> disconnect ("Firefox BiDi closed: " ^ reason))
          ~on_error:disconnect ~on_eof:(fun () -> disconnect "Firefox BiDi EOF") () in
        let authority = (if host = "::1" then "[::1]" else host) ^ ":" ^ string_of_int port in
        let wsd = Ws_direct_eio.Client.connect ~sw:session_sw ~clock
            ~host:authority ~resource ~max_message:(1024 * 1024) flow builder in
        let next = ref 0 in
        let command method_ params =
          match !failure with
          | Some reason -> Error reason
          | None ->
            incr next;
            let id = !next in
            let reply, resolver = Eio.Promise.create () in
            Hashtbl.add pending id resolver;
            Endpoint.Wsd.send_text wsd (Yojson.Safe.to_string
              (`Assoc ["id",`Int id;"method",`String method_;"params",params]));
            (try Eio.Time.with_timeout_exn clock command_timeout (fun () -> Eio.Promise.await reply)
             with Eio.Time.Timeout ->
               disconnect ("BiDi command timed out: " ^ method_); Error ("BiDi command timed out: " ^ method_)) in
        let* _ = command "session.subscribe" (`Assoc ["events",`List (List.map (fun s -> `String s)
          ["browsingContext.contextCreated";"browsingContext.downloadWillBegin";"browsingContext.downloadEnd"])]) in
        let* tree = command "browsingContext.getTree" (`Assoc []) in
        let* () = Browser_downloads.add_tree model tree in
        let directory = Eio_unix.run_in_systhread (fun () ->
          Fs_compat.mkdir_p root;
          (* Session IDs are opaque remote data, never pathname components. *)
          let path = Filename.concat root (Digest.to_hex (Digest.string session_id)) in
          Unix.mkdir path 0o700;
          Unix.realpath path) in
        let* _ = command "browser.setDownloadBehavior" (`Assoc ["downloadBehavior",`Assoc
          ["type",`String "allowed";"destinationFolder",`String directory]]) in
        let check () = match !failure with None -> Ok () | Some reason -> Error reason in
        let artifacts = Hashtbl.create 16 in
        let read ~context =
          let rows = Browser_downloads.for_context model context in
          let records = List.map (fun (row : Browser_downloads.download) ->
            let data = Eio_unix.run_in_systhread (fun () ->
              Browser_downloads.to_json ~verify:(verify_file ~root:directory) row) in
            let artifact = match Hashtbl.find_opt artifacts row.id with
              | Some value -> Some (Ok value)
              | None -> (match field "path" data with
                  | Some (`String path) ->
                    let result = publish_artifact path in
                    Result.iter (fun value -> Hashtbl.replace artifacts row.id value) result;
                    Some result
                  | _ -> None) in
            match data, artifact with
            | `Assoc fields, Some (Ok value) -> `Assoc (("artifact",value) :: fields)
            | `Assoc fields, Some (Error reason) -> `Assoc (("artifactError",`String reason) :: fields)
            | _ -> data) rows in
          let state = !failure in
          Ok (`Assoc ["sessionId",`String session_id;"downloads",`List records;
            "observation",`String (if state = None then "connected" else "interrupted");
            "reason",(match state with None -> `Null | Some reason -> `String reason)]) in
        Ok Browser_downloads.{read;check;close=(fun () -> disconnect "Firefox session closed")} in
      let result =
        try setup () with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | Eio.Io _ as exn -> Error (Printexc.to_string exn)
        | Unix.Unix_error (code, _, _) -> Error (Unix.error_message code)
        | Sys_error detail | Failure detail -> Error detail
        | Eio.Time.Timeout -> Error "BiDi connection timed out" in
      publish result;
      (match result with Ok _ -> Eio.Promise.await stopped | Error _ -> ());
      raise Stop)
    with Stop -> ());
  try Eio.Promise.await ready with
  | Eio.Cancel.Cancelled _ as exn -> disconnect "BiDi setup caller canceled"; raise exn
