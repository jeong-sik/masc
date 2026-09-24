type session_id = string
type target_kind = Page | Service_worker | Other_kind of string

type target_info = { target_id : string; kind : target_kind; url : string }

type event =
  | Binding_called of { session : session_id option; name : string; payload : string }
  | Target_created of target_info
  | Target_detached of { session : session_id }
  | Target_destroyed of { target_id : string }
  | Malformed_event of { method_ : string; detail : string }
  | Unobserved of { method_ : string }
  | Connection_ended of { reason : string }

type failure =
  | Command_rejected of { code : int; message : string }
  | Connection_lost of string

type envelope =
  | Reply of { id : int; result : (Yojson.Safe.t, int * string) result }
  | Event of { method_ : string; session : session_id option; params : Yojson.Safe.t option }

let ( let* ) = Result.bind
let field key = function `Assoc fields -> List.assoc_opt key fields | _ -> None

let string_field key json =
  match field key json with
  | Some (`String value) -> Ok value
  | Some _ | None -> Error (key ^ " is not a string")
;;

let decode frame =
  match Yojson.Safe.from_string frame with
  | exception Yojson.Json_error detail -> Error ("invalid CDP JSON: " ^ detail)
  | json ->
    (match field "id" json, field "method" json with
     | Some (`Int id), None ->
       (match field "result" json, field "error" json with
        | Some result, None -> Ok (Reply { id; result = Ok result })
        | None, Some error ->
          (match field "code" error, field "message" error with
           | Some (`Int code), Some (`String message) -> Ok (Reply { id; result = Error (code, message) })
           | _ -> Error "CDP error reply without an integer code and a message")
        | Some _, Some _ | None, None -> Error "CDP reply without exactly one of result and error")
     | None, Some (`String method_) ->
       let session = match field "sessionId" json with Some (`String id) -> Some id | _ -> None in
       Ok (Event { method_; session; params = field "params" json })
     | _ -> Error "CDP frame is neither a reply nor an event")
;;

let encode_command ~id ?session method_ params =
  let session = match session with None -> [] | Some id -> [ "sessionId", `String id ] in
  Yojson.Safe.to_string (`Assoc ([ "id", `Int id; "method", `String method_; "params", params ] @ session))
;;

let target_kind_of = function
  | "page" -> Page
  | "service_worker" -> Service_worker
  | other -> Other_kind other
;;

let target_info_of_json info =
  let* target_id = string_field "targetId" info in
  let* kind = string_field "type" info in
  let* url = string_field "url" info in
  Ok { target_id; kind = target_kind_of kind; url }
;;

let event_of ~method_ ~session params =
  let with_params read =
    match params with
    | Some params -> read params
    | None -> Error "params are missing"
  in
  let decoded =
    match method_ with
    | "Runtime.bindingCalled" ->
      with_params (fun params ->
        let* name = string_field "name" params in
        let* payload = string_field "payload" params in
        Ok (Binding_called { session; name; payload }))
    | "Target.targetCreated" ->
      with_params (fun params ->
        let* info = Option.to_result ~none:"targetInfo is missing" (field "targetInfo" params) in
        let* target = target_info_of_json info in
        Ok (Target_created target))
    | "Target.detachedFromTarget" ->
      with_params (fun params ->
        let* detached = string_field "sessionId" params in
        Ok (Target_detached { session = detached }))
    | "Target.targetDestroyed" ->
      with_params (fun params ->
        let* target_id = string_field "targetId" params in
        Ok (Target_destroyed { target_id }))
    | _ -> Ok (Unobserved { method_ })
  in
  match decoded with
  | Ok event -> event
  | Error detail -> Malformed_event { method_; detail }
;;

type t =
  { send : string -> unit
  ; close : unit -> unit
  ; sleep : float -> unit
  ; command_deadline_s : float
  ; on_event : event -> unit
  ; pending : (int, (Yojson.Safe.t, failure) result Eio.Promise.u) Hashtbl.t
  ; mutable next_id : int
  ; mutable lost : string option
  }

let create ~send ~close ~clock ~command_deadline_s ~on_event =
  { send
  ; close
  ; sleep = Eio.Time.sleep clock
  ; command_deadline_s
  ; on_event
  ; pending = Hashtbl.create 8
  ; next_id = 0
  ; lost = None
  }
;;

let lost_reason t = t.lost

let lost t reason =
  match t.lost with
  | Some _ -> ()
  | None ->
    t.lost <- Some reason;
    let waiting = Hashtbl.fold (fun _ resolver acc -> resolver :: acc) t.pending [] in
    Hashtbl.reset t.pending;
    List.iter (fun resolver -> Eio.Promise.resolve resolver (Error (Connection_lost reason))) waiting;
    t.close ();
    t.on_event (Connection_ended { reason })
;;

let receive t frame =
  match t.lost with
  | Some _ -> ()
  | None ->
    (match decode frame with
     | Error detail -> lost t detail
     | Ok (Reply { id; result }) ->
       (match Hashtbl.find_opt t.pending id with
        | None -> lost t (Printf.sprintf "CDP reply for unknown command %d" id)
        | Some resolver ->
          Hashtbl.remove t.pending id;
          Eio.Promise.resolve resolver
            (Result.map_error (fun (code, message) -> Command_rejected { code; message }) result))
     | Ok (Event { method_; session; params }) -> t.on_event (event_of ~method_ ~session params))
;;

let deadline_exceeded = "CDP command deadline exceeded"

let command t ?session method_ params =
  match t.lost with
  | Some reason -> Error (Connection_lost reason)
  | None ->
    t.next_id <- t.next_id + 1;
    let id = t.next_id in
    let reply, resolver = Eio.Promise.create () in
    Hashtbl.replace t.pending id resolver;
    t.send (encode_command ~id ?session method_ params);
    (* The deadline ends the connection only for a command still waiting: a
       reply that arrived as the deadline passed is the reply, and the
       connection stays. Without one, the connection ends rather than write
       the next command behind a command whose outcome is unknown. *)
    (match
       Watched_work.run
         ~watcher:(fun () ->
           t.sleep t.command_deadline_s;
           if Hashtbl.mem t.pending id then lost t deadline_exceeded;
           Eio.Promise.await reply)
         (fun () -> Eio.Promise.await reply)
     with
     | result -> result
     | exception (Eio.Cancel.Cancelled _ as exn) ->
       (* A caller that leaves with its command out leaves its outcome unknown. *)
       if Hashtbl.mem t.pending id then lost t "a command's caller was cancelled";
       raise exn)
;;

module Endpoint = Ws_direct_core.Endpoint
module Message = Ws_direct_core.Connection.Message

let endpoint_of url =
  let uri = Uri.of_string url in
  match Uri.scheme uri, Uri.host uri, Uri.port uri, Uri.userinfo uri, Uri.fragment uri with
  | Some "ws", Some host, Some port, None, None
    when Masc_network_defaults.is_loopback_host host && port > 0 && port <= 65535 ->
    let resource = Uri.path_and_query uri in
    if resource = "" || resource.[0] <> '/' then Error "invalid CDP websocket path" else Ok (host, port, resource)
  | _ -> Error "CDP websocket must be a loopback ws URL with an explicit port"
;;

exception Released

let connect ~sw ~net ~clock ~url ~max_message ~command_deadline_s ~on_event =
  let* host, port, resource = endpoint_of url in
  Crypto_rng.ensure_default ();
  let authority = (if host = "::1" then "[::1]" else host) ^ ":" ^ string_of_int port in
  (* Opens the socket and ws-direct's driver fibers on [inner]. Failures are
     this connection's error: ws-direct reports a refused upgrade or a late
     head as [Failure], a peer that closes during the upgrade as
     [End_of_file], and a refused lookup or connect is [Eio.Io]. *)
  let open_on inner =
    match Eio.Net.getaddrinfo_stream net host ~service:(string_of_int port) with
    | exception (Eio.Io _ as exn) -> Error ("CDP address lookup: " ^ Printexc.to_string exn)
    | [] -> Error "CDP loopback address unavailable"
    | addr :: _ ->
      let wsd = ref None in
      let released, release = Eio.Promise.create () in
      let t =
        create
          ~send:(fun frame -> Option.iter (fun wsd -> Endpoint.Wsd.send_text wsd frame) !wsd)
          ~close:(fun () -> Eio.Promise.resolve release ())
          ~clock ~command_deadline_s ~on_event
      in
      let on_message (message : Message.t) =
        match message.kind with
        | Message.Text -> receive t (Bigstringaf.to_string message.payload)
        | Message.Binary -> lost t "unexpected binary CDP frame"
      in
      let builder _ =
        Endpoint.handlers ~on_message
          ~on_close:(fun ~code:_ ~reason:_ -> lost t "CDP websocket closed")
          ~on_error:(fun detail -> lost t ("CDP websocket error: " ^ detail))
          ~on_eof:(fun () -> lost t "CDP websocket EOF")
          ()
      in
      (match Eio.Net.connect ~sw:inner net addr with
       | exception (Eio.Io _ as exn) -> Error ("CDP connection: " ^ Printexc.to_string exn)
       | flow ->
         (match Ws_direct_eio.Client.connect ~sw:inner ~clock ~host:authority ~resource ~max_message flow builder with
          | opened ->
            wsd := Some opened;
            Ok (t, released)
          | exception Failure detail -> Error ("CDP connection: " ^ detail)
          | exception End_of_file -> Error "CDP connection: closed during the upgrade"
          | exception (Eio.Io _ as exn) -> Error ("CDP connection: " ^ Printexc.to_string exn)))
  in
  let opened, open_ = Eio.Promise.create () in
  (* The socket lives on a switch of its own under a daemon of the owner's.
     [lost] ends that switch, and so does the owner's main work finishing, so
     neither waits for Chrome to close its end. A failed open ends it at
     once, closing the socket. *)
  Eio.Fiber.fork_daemon ~sw (fun () ->
    (try
       Eio.Switch.run (fun inner ->
         match open_on inner with
         | Error detail -> Eio.Promise.resolve open_ (Error detail)
         | Ok (t, released) ->
           Eio.Promise.resolve open_ (Ok t);
           Eio.Promise.await released;
           Eio.Switch.fail inner Released)
     with
     | Released -> ());
    `Stop_daemon);
  let* t = Eio.Promise.await opened in
  Eio.Switch.on_release sw (fun () -> lost t "CDP connection owner released");
  Ok t
;;
