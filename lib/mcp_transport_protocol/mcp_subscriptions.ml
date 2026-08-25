(** Live [subscriptions/listen] streams (MCP 2026-07-28).

    One entry per open stream, keyed by the JSON-RPC id of the request that
    opened it — the revision removed sessions, so the request is the only
    identity a subscription has.

    The transport hands in a [send] closure rather than this module reaching
    for a writer: masc_server depends on masc, and inverting that to let the
    registry write to a socket would point the notification vocabulary at the
    transport. *)

type entry =
  { filter : Mcp_transport_protocol.subscription_filter
  ; subscription_id : Yojson.Safe.t
  ; send : Yojson.Safe.t -> bool
  }

type token = int

let mutex = Eio.Mutex.create ()
let with_lock f = Eio_guard.with_mutex mutex f
let entries : (token, entry) Hashtbl.t = Hashtbl.create 16
let next_token = ref 0

let register ~subscription_id ~filter ~send =
  with_lock (fun () ->
    let token = !next_token in
    incr next_token;
    Hashtbl.replace entries token { filter; subscription_id; send };
    token)
;;

let unregister token = with_lock (fun () -> Hashtbl.remove entries token)
let count () = with_lock (fun () -> Hashtbl.length entries)

(* A send that fails means the peer is gone. Dropping the entry here keeps a
   closed stream from being retried on every later notification; the transport
   also unregisters on close, and [Hashtbl.remove] on an absent key is a no-op,
   so the two paths do not fight. *)
let deliver ~wants notification =
  let dead =
    with_lock (fun () ->
      Hashtbl.fold
        (fun token entry dead ->
           if not (wants entry.filter)
           then dead
           else (
             let tagged =
               Mcp_transport_protocol.tag_notification_with_subscription
                 ~subscription_id:entry.subscription_id
                 notification
             in
             if entry.send tagged then dead else token :: dead))
        entries
        [])
  in
  List.iter unregister dead
;;

let notify_tools_list_changed notification =
  deliver
    ~wants:(fun (f : Mcp_transport_protocol.subscription_filter) ->
      f.tools_list_changed)
    notification
;;

let notify_resource_updated ~uri notification =
  deliver
    ~wants:(fun (f : Mcp_transport_protocol.subscription_filter) ->
      List.exists (String.equal uri) f.resource_subscriptions)
    notification
;;

(* The union of every open stream's [resourceSubscriptions]. The emitter, not
   this module, decides which URIs a tool call touched -- it owns
   [resource_is_dynamic] and the id mapping -- so it asks which URIs anyone
   named and applies its own rules, the same shape the session table uses. *)
let subscribed_resource_uris () =
  with_lock (fun () ->
    Hashtbl.fold
      (fun _ entry acc ->
         List.rev_append entry.filter.Mcp_transport_protocol.resource_subscriptions acc)
      entries
      [])
  |> List.sort_uniq String.compare

(* Both transports build these. Keeping them here is the difference between
   one contract and two that agree today: HTTP/1 and h2c already drifted on the
   header-mismatch body until it moved to one place. *)

(* masc emits neither prompts/list_changed nor resources/list_changed -- its
   capabilities declare listChanged false for both -- and the acknowledgement
   reports "the subset the server agreed to honor", with unsupported types
   omitted rather than refused. *)
let honoured_filter (filter : Mcp_transport_protocol.subscription_filter) =
  { filter with
    Mcp_transport_protocol.prompts_list_changed = false
  ; resources_list_changed = false
  }
;;

(* MUST be the first message on the subscription, with no notification before
   it, so a caller sends this before registering. *)
let acknowledgement ~subscription_id filter =
  Mcp_transport_protocol.tag_notification_with_subscription
    ~subscription_id
    (Mcp_transport_protocol.jsonrpc_notification
       "notifications/subscriptions/acknowledged"
       ~params:
         (`Assoc
           [ ( "notifications"
             , Mcp_transport_protocol.subscription_filter_to_json filter )
           ]))
;;

(* The JSON-RPC response to the long-lived request. A client that receives it
   knows the subscription closed cleanly; a transport that drops without one
   is an unexpected disconnect. *)
let graceful_closure ~subscription_id =
  Mcp_transport_protocol.make_response
    ~id:subscription_id
    (`Assoc
      [ ( "_meta"
        , `Assoc
            [ (Mcp_transport_protocol.subscription_id_meta_key, subscription_id)
            ] )
      ])
;;

let reset_for_test () = with_lock (fun () -> Hashtbl.reset entries)
