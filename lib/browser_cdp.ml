type session_id = string
type target_kind = Page | Service_worker | Other_kind of string

type event =
  | Binding_called of { session : session_id option; name : string; payload : string }
  | Target_created of { target_id : string; kind : target_kind; url : string }
  | Target_detached of { session : session_id }
  | Target_destroyed of { target_id : string }
  | Malformed_event of { method_ : string; detail : string }
  | Unobserved of { method_ : string }

type failure =
  | Command_rejected of { code : int; message : string }
  | Connection_lost of string

type envelope =
  | Reply of { id : int; result : (Yojson.Safe.t, int * string) result }
  | Event of { method_ : string; session : session_id option; params : Yojson.Safe.t }

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
       (* CDP omits [params] for an event that has none. *)
       let params = Option.value ~default:(`Assoc []) (field "params" json) in
       Ok (Event { method_; session; params })
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

let event_of ~method_ ~session params =
  let decoded =
    match method_ with
    | "Runtime.bindingCalled" ->
      let* name = string_field "name" params in
      let* payload = string_field "payload" params in
      Ok (Binding_called { session; name; payload })
    | "Target.targetCreated" ->
      let* info = Option.to_result ~none:"targetInfo is missing" (field "targetInfo" params) in
      let* target_id = string_field "targetId" info in
      let* kind = string_field "type" info in
      let* url = string_field "url" info in
      Ok (Target_created { target_id; kind = target_kind_of kind; url })
    | "Target.detachedFromTarget" ->
      let* detached = string_field "sessionId" params in
      Ok (Target_detached { session = detached })
    | "Target.targetDestroyed" ->
      let* target_id = string_field "targetId" params in
      Ok (Target_destroyed { target_id })
    | _ -> Ok (Unobserved { method_ })
  in
  match decoded with
  | Ok event -> event
  | Error detail -> Malformed_event { method_; detail }
;;

type t =
  { send : string -> unit
  ; sleep : float -> unit
  ; command_deadline_s : float
  ; on_event : event -> unit
  ; pending : (int, (Yojson.Safe.t, failure) result Eio.Promise.u) Hashtbl.t
  ; mutable next_id : int
  ; mutable lost : string option
  }

let create ~send ~clock ~command_deadline_s ~on_event =
  { send
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
    List.iter (fun resolver -> Eio.Promise.resolve resolver (Error (Connection_lost reason))) waiting
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
    (* A reply that arrived as the deadline passed is the reply. Without one,
       the connection ends rather than write the next command behind a
       command whose outcome is unknown. *)
    Watched_work.run
      ~watcher:(fun () ->
        t.sleep t.command_deadline_s;
        lost t deadline_exceeded;
        Error (Connection_lost deadline_exceeded))
      (fun () -> Eio.Promise.await reply)
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

let connect ~sw ~net ~clock ~url ~max_message ~command_deadline_s ~on_event =
  let* host, port, resource = endpoint_of url in
  Crypto_rng.ensure_default ();
  let* addr =
    match Eio.Net.getaddrinfo_stream net host ~service:(string_of_int port) with
    | first :: _ -> Ok first
    | [] -> Error "CDP loopback address unavailable"
  in
  let wsd = ref None in
  let send frame = Option.iter (fun wsd -> Endpoint.Wsd.send_text wsd frame) !wsd in
  let t = create ~send ~clock ~command_deadline_s ~on_event in
  Eio.Switch.on_release sw (fun () -> lost t "CDP connection owner released");
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
  let authority = (if host = "::1" then "[::1]" else host) ^ ":" ^ string_of_int port in
  (* ws-direct reports a refused upgrade, or a head that did not arrive in its
     window, as [Failure]; a refused TCP connect is [Eio.Io]. Both are this
     connection's error. *)
  match
    (let flow = Eio.Net.connect ~sw net addr in
     Ws_direct_eio.Client.connect ~sw ~clock ~host:authority ~resource ~max_message flow builder)
  with
  | opened ->
    wsd := Some opened;
    Ok t
  | exception Failure detail -> Error ("CDP connection: " ^ detail)
  | exception (Eio.Io _ as exn) -> Error ("CDP connection: " ^ Printexc.to_string exn)
;;
