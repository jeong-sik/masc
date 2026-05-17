type transport = SSE | WS | GRPC | WebRTC

type evict_reason =
  | Cap_exceeded
  | Idle_timeout
  | Backpressure
  | Policy_revoked

type close_reason =
  | Client_disconnected
  | Server_shutdown
  | Server_error of string
  | Evicted of evict_reason

type t =
  | Open of {
      transport : transport ;
      session_id : string ;
      origin : string ;
    }
  | Upgrade of {
      transport_from : transport ;
      transport_to : transport ;
      session_id : string ;
    }
  | Resume of {
      transport : transport ;
      session_id : string ;
      last_event_id : string option ;
      replayed : int ;
    }
  | Evict of {
      transport : transport ;
      session_id : string ;
      reason : evict_reason ;
    }
  | Close of {
      transport : transport ;
      session_id : string ;
      reason : close_reason ;
    }

let bus_topic = "session_lifecycle"

let transport_to_string = function
  | SSE -> "sse"
  | WS -> "ws"
  | GRPC -> "grpc"
  | WebRTC -> "webrtc"

let transport_of_string = function
  | "sse" -> Some SSE
  | "ws" -> Some WS
  | "grpc" -> Some GRPC
  | "webrtc" -> Some WebRTC
  | _ -> None

let evict_reason_to_string = function
  | Cap_exceeded -> "cap_exceeded"
  | Idle_timeout -> "idle_timeout"
  | Backpressure -> "backpressure"
  | Policy_revoked -> "policy_revoked"

let evict_reason_of_string = function
  | "cap_exceeded" -> Some Cap_exceeded
  | "idle_timeout" -> Some Idle_timeout
  | "backpressure" -> Some Backpressure
  | "policy_revoked" -> Some Policy_revoked
  | _ -> None

let close_reason_kind = function
  | Client_disconnected -> "client_disconnected"
  | Server_shutdown -> "server_shutdown"
  | Server_error _ -> "server_error"
  | Evicted _ -> "evicted"

let close_reason_to_yojson = function
  | Client_disconnected ->
      `Assoc [ ("kind", `String "client_disconnected") ]
  | Server_shutdown -> `Assoc [ ("kind", `String "server_shutdown") ]
  | Server_error detail ->
      `Assoc
        [ ("kind", `String "server_error") ; ("detail", `String detail) ]
  | Evicted r ->
      `Assoc
        [
          ("kind", `String "evicted") ;
          ("evict_reason", `String (evict_reason_to_string r)) ;
        ]

let close_reason_of_yojson (j : Yojson.Safe.t) :
    (close_reason, string) result =
  let open Yojson.Safe.Util in
  try
    match j |> member "kind" |> to_string with
    | "client_disconnected" -> Ok Client_disconnected
    | "server_shutdown" -> Ok Server_shutdown
    | "server_error" ->
        let detail = j |> member "detail" |> to_string in
        Ok (Server_error detail)
    | "evicted" -> (
        let r = j |> member "evict_reason" |> to_string in
        match evict_reason_of_string r with
        | Some er -> Ok (Evicted er)
        | None -> Error (Printf.sprintf "unknown evict_reason: %s" r))
    | other -> Error (Printf.sprintf "unknown close_reason kind: %s" other)
  with Type_error (msg, _) -> Error msg

let to_yojson = function
  | Open { transport ; session_id ; origin } ->
      `Assoc
        [
          ("kind", `String "open") ;
          ("transport", `String (transport_to_string transport)) ;
          ("session_id", `String session_id) ;
          ("origin", `String origin) ;
        ]
  | Upgrade { transport_from ; transport_to ; session_id } ->
      `Assoc
        [
          ("kind", `String "upgrade") ;
          ("transport_from", `String (transport_to_string transport_from)) ;
          ("transport_to", `String (transport_to_string transport_to)) ;
          ("session_id", `String session_id) ;
        ]
  | Resume { transport ; session_id ; last_event_id ; replayed } ->
      `Assoc
        [
          ("kind", `String "resume") ;
          ("transport", `String (transport_to_string transport)) ;
          ("session_id", `String session_id) ;
          ( "last_event_id",
            match last_event_id with
            | Some id -> `String id
            | None -> `Null ) ;
          ("replayed", `Int replayed) ;
        ]
  | Evict { transport ; session_id ; reason } ->
      `Assoc
        [
          ("kind", `String "evict") ;
          ("transport", `String (transport_to_string transport)) ;
          ("session_id", `String session_id) ;
          ("reason", `String (evict_reason_to_string reason)) ;
        ]
  | Close { transport ; session_id ; reason } ->
      `Assoc
        [
          ("kind", `String "close") ;
          ("transport", `String (transport_to_string transport)) ;
          ("session_id", `String session_id) ;
          ("reason", close_reason_to_yojson reason) ;
        ]

let of_yojson (j : Yojson.Safe.t) : (t, string) result =
  let open Yojson.Safe.Util in
  try
    let kind = j |> member "kind" |> to_string in
    let transport_field name =
      let s = j |> member name |> to_string in
      match transport_of_string s with
      | Some t -> Ok t
      | None -> Error (Printf.sprintf "unknown transport: %s" s)
    in
    let session_id () = j |> member "session_id" |> to_string in
    match kind with
    | "open" ->
        Result.bind (transport_field "transport") (fun transport ->
            let origin = j |> member "origin" |> to_string in
            Ok (Open { transport ; session_id = session_id () ; origin }))
    | "upgrade" ->
        Result.bind (transport_field "transport_from") (fun transport_from ->
            Result.bind (transport_field "transport_to") (fun transport_to ->
                Ok
                  (Upgrade
                     { transport_from ; transport_to ; session_id = session_id () })))
    | "resume" ->
        Result.bind (transport_field "transport") (fun transport ->
            let last_event_id =
              match j |> member "last_event_id" with
              | `Null -> None
              | `String s -> Some s
              | _ -> None
            in
            let replayed = j |> member "replayed" |> to_int in
            Ok
              (Resume
                 { transport ; session_id = session_id () ; last_event_id ; replayed }))
    | "evict" ->
        Result.bind (transport_field "transport") (fun transport ->
            let reason_str = j |> member "reason" |> to_string in
            match evict_reason_of_string reason_str with
            | Some reason ->
                Ok (Evict { transport ; session_id = session_id () ; reason })
            | None ->
                Error (Printf.sprintf "unknown evict_reason: %s" reason_str))
    | "close" ->
        Result.bind (transport_field "transport") (fun transport ->
            Result.bind
              (close_reason_of_yojson (j |> member "reason"))
              (fun reason ->
                Ok (Close { transport ; session_id = session_id () ; reason })))
    | other -> Error (Printf.sprintf "unknown event kind: %s" other)
  with Type_error (msg, _) -> Error msg

let pp fmt t = Format.pp_print_string fmt (Yojson.Safe.to_string (to_yojson t))

(* PR-3: publisher injection. Default is no-op; embedder installs a
   real publisher at bootstrap. Atomic so swap is observable to
   concurrent callers consistently. *)

let _noop_publisher : t -> unit = fun _ -> ()
let _publisher : (t -> unit) Atomic.t = Atomic.make _noop_publisher
let _installed : bool Atomic.t = Atomic.make false

let publish evt =
  let p = Atomic.get _publisher in
  try p evt
  with exn ->
    (* Swallow + log: a failing observer must not break the eviction
       path. The whole point of PR-3 is that transport teardown
       remains predictable regardless of subscriber state. *)
    Log.Misc.debug "Session_lifecycle_event.publish: %s"
      (Printexc.to_string exn)

let set_publisher p =
  Atomic.set _publisher p ;
  Atomic.set _installed true

let reset_publisher () =
  Atomic.set _publisher _noop_publisher ;
  Atomic.set _installed false

let is_publisher_installed () = Atomic.get _installed
