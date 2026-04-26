(** WebRTC DataChannel Transport for MASC MCP.

    Enables P2P agent-to-agent communication via WebRTC DataChannels,
    bypassing the central server for event streaming after initial
    signaling.

    Architecture:
    1. Signaling: HTTP POST /webrtc/offer and /webrtc/answer exchange
       SDP-like payloads (ICE candidates, DTLS fingerprints) via the
       MASC HTTP server.
    2. DataChannel: Once ICE+DTLS completes, a "masc-events" DataChannel
       carries JSON-RPC messages directly between peers.

    This module manages the signaling state, peer registry, and live
    WebRTC connections via ocaml-webrtc (Webrtc.Webrtc_eio).

    Enabled by default. Opt-out via MASC_WEBRTC_ENABLED=0. *)

(** Whether WebRTC transport is enabled (default: true). *)
let is_enabled () = Env_config.Transport.webrtc_enabled ()

let trim_nonempty value =
  let trimmed = String.trim value in
  if trimmed = "" then None else Some trimmed
;;

let getenv_nonempty name =
  match Sys.getenv_opt name with
  | Some value -> trim_nonempty value
  | None -> None
;;

let split_csv value = String.split_on_char ',' value |> List.filter_map trim_nonempty
let ice_server_urls (server : Webrtc.Ice.ice_server) = server.Webrtc.Ice.urls

let parse_ice_servers_json raw =
  let open Yojson.Safe.Util in
  let parse_server json =
    let urls =
      match member "urls" json with
      | `String value -> split_csv value
      | `List values ->
        values
        |> List.filter_map (fun value ->
          try value |> to_string |> trim_nonempty with
          | Type_error _ -> None)
      | _ -> []
    in
    if urls = []
    then None
    else (
      let opt name =
        match member name json |> to_string_option with
        | Some value -> trim_nonempty value
        | None -> None
      in
      Some
        { Webrtc.Ice.urls
        ; username = opt "username"
        ; credential = opt "credential"
        ; tls_ca = opt "tls_ca"
        })
  in
  try
    match Yojson.Safe.from_string raw with
    | `List servers -> List.filter_map parse_server servers
    | json -> List.filter_map parse_server [ json ]
  with
  | Yojson.Json_error _ -> []
;;

let configured_ice_servers () =
  match getenv_nonempty "MASC_WEBRTC_ICE_SERVERS_JSON" with
  | Some raw ->
    (match parse_ice_servers_json raw with
     | [] -> Webrtc.Webrtc_eio.default_ice_config.Webrtc.Ice.ice_servers
     | servers -> servers)
  | None ->
    (match getenv_nonempty "MASC_WEBRTC_ICE_URLS" with
     | Some raw ->
       let urls = split_csv raw in
       if urls = []
       then Webrtc.Webrtc_eio.default_ice_config.Webrtc.Ice.ice_servers
       else
         [ { Webrtc.Ice.urls
           ; username = getenv_nonempty "MASC_WEBRTC_ICE_USERNAME"
           ; credential = getenv_nonempty "MASC_WEBRTC_ICE_CREDENTIAL"
           ; tls_ca = getenv_nonempty "MASC_WEBRTC_ICE_TLS_CA"
           }
         ]
     | None -> Webrtc.Webrtc_eio.default_ice_config.Webrtc.Ice.ice_servers)
;;

let configured_ice_server_urls () =
  configured_ice_servers () |> List.concat_map ice_server_urls
;;

let configured_ice_config ~role =
  { Webrtc.Webrtc_eio.default_ice_config with
    Webrtc.Ice.role
  ; ice_servers = configured_ice_servers ()
  }
;;

(** {1 Signaling State} *)

(** Pending offer waiting for an answer. *)
type pending_offer =
  { offer_id : string
  ; from_agent : string
  ; ice_candidates : string list
  ; dtls_fingerprint : string
  ; created_at : float
  }

(** Active DataChannel peer connection (post-signaling). *)
type peer_conn =
  { peer_id : string
  ; remote_agent : string
  ; channel_label : string
  ; mutable connected : bool
  ; mutable last_activity : float
  }

(** {1 Registries} *)

(** Signaling exchange registry. *)
let pending_offers : (string, pending_offer) Hashtbl.t = Hashtbl.create 8

let active_peers : (string, peer_conn) Hashtbl.t = Hashtbl.create 8

(** Live WebRTC connections keyed by peer_id. *)
let peer_webrtc_map : (string, Webrtc.Webrtc_eio.t) Hashtbl.t = Hashtbl.create 8

(** DataChannel references keyed by peer_id (for sending responses). *)
let peer_channel_map : (string, Webrtc.Webrtc_eio.datachannel) Hashtbl.t =
  Hashtbl.create 8
;;

let registry_mutex = Eio.Mutex.create ()
let with_registry f = Eio_guard.with_mutex registry_mutex f

(** Generate a unique offer/peer ID. *)
let next_id =
  let counter = Atomic.make 0 in
  fun prefix ->
    let n = Atomic.fetch_and_add counter 1 in
    Printf.sprintf "%s-%d-%d" prefix (int_of_float (Unix.gettimeofday () *. 1000.0)) n
;;

(** {1 Message Handler} *)

(** Callback invoked when a DataChannel message arrives.
    Signature: peer_id -> message_body -> unit.
    Set by [set_message_handler] from the server bootstrap. *)
let message_handler : (string -> string -> unit) ref =
  ref (fun _peer_id _body ->
    Log.Server.warn "WebRTC message received but no handler registered")
;;

(** Register the MCP dispatch handler for incoming DataChannel messages. *)
let set_message_handler f = message_handler := f

(** Callback to start a WebRTC connection for a given peer_id.
    Set by [set_connection_starter] from the server bootstrap,
    which captures ~sw and ~env in its closure. *)
let connection_starter : (string -> unit) ref =
  ref (fun _peer_id ->
    Log.Server.warn "WebRTC connection_starter not set; cannot start peer")
;;

(** Register the connection starter (called from bootstrap where sw/env
    are in scope). *)
let set_connection_starter f = connection_starter := f

let normalize_candidate_string candidate_str =
  let trimmed = String.trim candidate_str in
  if String.starts_with ~prefix:"a=candidate:" trimmed
  then String.sub trimmed 12 (String.length trimmed - 12)
  else if String.starts_with ~prefix:"candidate:" trimmed
  then String.sub trimmed 10 (String.length trimmed - 10)
  else trimmed
;;

let add_remote_ice_candidate webrtc candidate_str =
  let normalized = normalize_candidate_string candidate_str in
  let should_warn = String.contains normalized ' ' || String.contains normalized ':' in
  if normalized = "" || normalized = "end-of-candidates"
  then ()
  else (
    match Webrtc.Ice.parse_candidate normalized with
    | Ok candidate -> Webrtc.Webrtc_eio.add_ice_candidate webrtc candidate
    | Error _ ->
      if String.contains normalized ':' && not (String.contains normalized ' ')
      then (
        match String.split_on_char ':' normalized with
        | [ addr; port_s ] ->
          (match int_of_string_opt port_s with
           | Some port ->
             let candidate : Webrtc.Ice.candidate =
               { foundation = "webrtc"
               ; component = 1
               ; transport = Webrtc.Ice.UDP
               ; priority = 100
               ; address = addr
               ; port
               ; cand_type = Webrtc.Ice.Host
               ; base_address = None
               ; base_port = None
               ; related_address = None
               ; related_port = None
               ; extensions = []
               }
             in
             Webrtc.Webrtc_eio.add_ice_candidate webrtc candidate
           | None when should_warn ->
             Log.Server.warn "Ignoring invalid WebRTC ICE candidate: %s" candidate_str
           | None -> ())
        | ([] | [ _ ] | _ :: _ :: _ :: _) when should_warn ->
          Log.Server.warn "Ignoring invalid WebRTC ICE candidate: %s" candidate_str
        | [] | [ _ ] | _ :: _ :: _ :: _ -> ())
      else if should_warn
      then Log.Server.warn "Ignoring invalid WebRTC ICE candidate: %s" candidate_str)
;;

(** {1 Signaling API} *)

(** Create a signaling offer.
    Returns the offer_id for the answerer to reference. *)
let create_offer ~from_agent ~ice_candidates ~dtls_fingerprint =
  let offer_id = next_id "offer" in
  let offer =
    { offer_id
    ; from_agent
    ; ice_candidates
    ; dtls_fingerprint
    ; created_at = Unix.gettimeofday ()
    }
  in
  with_registry (fun () -> Hashtbl.replace pending_offers offer_id offer);
  Log.Server.info
    "WebRTC offer %s from %s (%d ICE candidates)"
    offer_id
    from_agent
    (List.length ice_candidates);
  offer_id
;;

(** Retrieve a pending offer (for the answerer). *)
let get_offer offer_id =
  with_registry (fun () -> Hashtbl.find_opt pending_offers offer_id)
;;

(** Complete signaling by accepting an offer.
    Creates a Webrtc.Webrtc_eio.t server-side peer and stores it in peer_webrtc_map.
    The offer's ICE candidates and credentials are fed into the WebRTC peer.
    Returns a peer_conn for both sides. *)
let accept_offer ~offer_id ~answerer_agent =
  with_registry (fun () ->
    match Hashtbl.find_opt pending_offers offer_id with
    | None -> Error "Offer not found or expired"
    | Some offer ->
      Hashtbl.remove pending_offers offer_id;
      let peer_id = next_id "peer" in
      let conn =
        { peer_id
        ; remote_agent = offer.from_agent
        ; channel_label = "masc-events"
        ; connected = false
        ; last_activity = Unix.gettimeofday ()
        }
      in
      Hashtbl.replace active_peers peer_id conn;
      (* Create server-side WebRTC peer *)
      let ice_config = configured_ice_config ~role:Webrtc.Ice.Controlled in
      let webrtc =
        Webrtc.Webrtc_eio.create ~ice_config ~role:Webrtc.Webrtc_eio.Server ()
      in
      (* Feed remote ICE candidates from the offer *)
      List.iter (add_remote_ice_candidate webrtc) offer.ice_candidates;
      Hashtbl.replace peer_webrtc_map peer_id webrtc;
      Log.Server.info
        "WebRTC peer %s established: %s <-> %s"
        peer_id
        offer.from_agent
        answerer_agent;
      Ok conn)
;;

(** Mark a peer as connected (DataChannel open). *)
let mark_connected peer_id =
  with_registry (fun () ->
    match Hashtbl.find_opt active_peers peer_id with
    | None -> ()
    | Some conn ->
      conn.connected <- true;
      conn.last_activity <- Unix.gettimeofday ())
;;

(** Remove a peer connection and close the WebRTC stack. *)
let remove_peer peer_id =
  with_registry (fun () ->
    Hashtbl.remove active_peers peer_id;
    (match Hashtbl.find_opt peer_webrtc_map peer_id with
     | Some webrtc ->
       Webrtc.Webrtc_eio.close webrtc;
       Hashtbl.remove peer_webrtc_map peer_id
     | None -> ());
    Hashtbl.remove peer_channel_map peer_id);
  Log.Server.info "WebRTC peer %s removed" peer_id
;;

(** {1 WebRTC Connection Lifecycle} *)

(** Start a WebRTC connection for an accepted peer.
    Spawns a daemon fiber that runs the ICE+DTLS+SCTP stack.
    Wires on_state_change and on_datachannel callbacks. *)
let start_webrtc_connection ~sw ~env peer_id =
  let webrtc = with_registry (fun () -> Hashtbl.find_opt peer_webrtc_map peer_id) in
  match webrtc with
  | None -> Log.Server.warn "WebRTC start_connection: peer %s not found" peer_id
  | Some wrtc ->
    (* Wire state change callback *)
    Webrtc.Webrtc_eio.on_state_change wrtc (fun state ->
      let state_str = Webrtc.Webrtc_eio.show_connection_state state in
      Log.Server.info "WebRTC peer %s state: %s" peer_id state_str;
      match state with
      | Webrtc.Webrtc_eio.Connected -> mark_connected peer_id
      | Webrtc.Webrtc_eio.Disconnected
      | Webrtc.Webrtc_eio.Failed
      | Webrtc.Webrtc_eio.Closed -> remove_peer peer_id
      | Webrtc.Webrtc_eio.New | Webrtc.Webrtc_eio.Connecting -> ());
    (* Wire datachannel callback — receives the "masc-events" channel *)
    Webrtc.Webrtc_eio.on_datachannel wrtc (fun dc ->
      Log.Server.info
        "WebRTC peer %s datachannel opened: %s (id=%d)"
        peer_id
        dc.Webrtc.Webrtc_eio.label
        dc.Webrtc.Webrtc_eio.id;
      with_registry (fun () -> Hashtbl.replace peer_channel_map peer_id dc);
      (* Wire message handler on the datachannel *)
      dc.Webrtc.Webrtc_eio.on_message
      <- Some
           (fun data ->
             let msg = Bytes.to_string data in
             with_registry (fun () ->
               match Hashtbl.find_opt active_peers peer_id with
               | Some conn -> conn.last_activity <- Unix.gettimeofday ()
               | None -> ());
             !message_handler peer_id msg);
      dc.Webrtc.Webrtc_eio.on_close
      <- Some
           (fun () ->
             Log.Server.info "WebRTC peer %s datachannel closed" peer_id;
             remove_peer peer_id));
    (* Spawn daemon fiber to run the WebRTC stack *)
    let net = Eio.Stdenv.net env in
    let clock = Eio.Stdenv.clock env in
    Eio.Fiber.fork_daemon ~sw (fun () ->
      (try Webrtc.Webrtc_eio.run wrtc ~sw ~net ~clock with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
         Log.Server.warn "WebRTC peer %s run failed: %s" peer_id (Printexc.to_string exn);
         remove_peer peer_id);
      `Stop_daemon)
;;

(** {1 Send API} *)

(** Send a message to a connected peer via its DataChannel.
    Returns Ok bytes_sent or Error reason. *)
let send_to_peer peer_id msg =
  let result =
    with_registry (fun () ->
      match
        ( Hashtbl.find_opt peer_webrtc_map peer_id
        , Hashtbl.find_opt peer_channel_map peer_id )
      with
      | Some webrtc, Some dc -> Some (webrtc, dc)
      | _ -> None)
  in
  match result with
  | None -> Error (Printf.sprintf "Peer %s not connected or no datachannel" peer_id)
  | Some (webrtc, dc) -> Webrtc.Webrtc_eio.send_channel webrtc dc (Bytes.of_string msg)
;;

(** {1 HTTP Signaling Handlers} *)

(** Handle POST /webrtc/offer — create a new offer. *)
let handle_offer_request body =
  try
    let json = Yojson.Safe.from_string body in
    let from_agent = Yojson.Safe.Util.(member "agent_name" json |> to_string) in
    let ice_candidates =
      Yojson.Safe.Util.(member "ice_candidates" json |> to_list |> List.map to_string)
    in
    let dtls_fingerprint =
      Yojson.Safe.Util.(member "dtls_fingerprint" json |> to_string_option)
      |> Option.value ~default:""
    in
    let offer_id = create_offer ~from_agent ~ice_candidates ~dtls_fingerprint in
    Ok (Printf.sprintf {|{"offer_id":"%s","status":"pending"}|} offer_id)
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> Error (Printf.sprintf "Invalid offer: %s" (Printexc.to_string exn))
;;

(** Handle POST /webrtc/answer — accept an existing offer.
    Also returns server-side ICE credentials for the client to complete
    the signaling handshake. *)
let handle_answer_request body =
  try
    let json = Yojson.Safe.from_string body in
    let offer_id = Yojson.Safe.Util.(member "offer_id" json |> to_string) in
    let answerer = Yojson.Safe.Util.(member "agent_name" json |> to_string) in
    (* Also accept optional answerer ICE candidates *)
    let answer_ice =
      match Yojson.Safe.Util.member "ice_candidates" json with
      | `Null -> []
      | candidates -> Yojson.Safe.Util.(to_list candidates |> List.map to_string)
    in
    ignore answer_ice;
    match accept_offer ~offer_id ~answerer_agent:answerer with
    | Ok conn ->
      (* Retrieve server-side ICE credentials to return in the answer *)
      let ice_ufrag, ice_pwd =
        with_registry (fun () ->
          match Hashtbl.find_opt peer_webrtc_map conn.peer_id with
          | Some webrtc -> Webrtc.Webrtc_eio.get_local_credentials webrtc
          | None -> "", "")
      in
      (* Trigger the WebRTC connection fiber via the registered starter *)
      !connection_starter conn.peer_id;
      Ok
        (Printf.sprintf
           {|{"peer_id":"%s","remote_agent":"%s","channel":"%s","status":"accepted","ice_ufrag":"%s","ice_pwd":"%s"}|}
           conn.peer_id
           conn.remote_agent
           conn.channel_label
           ice_ufrag
           ice_pwd)
    | Error msg -> Error msg
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> Error (Printf.sprintf "Invalid answer: %s" (Printexc.to_string exn))
;;

(** {1 Diagnostics} *)

(** Number of pending offers. *)
let pending_offer_count () = with_registry (fun () -> Hashtbl.length pending_offers)

(** Number of active peer connections. *)
let active_peer_count () = with_registry (fun () -> Hashtbl.length active_peers)

(** Number of live WebRTC connections (subset of active_peers that have
    a Webrtc.Webrtc_eio.t running). *)
let live_webrtc_count () = with_registry (fun () -> Hashtbl.length peer_webrtc_map)

(** Number of peers with an open DataChannel ready for messaging. *)
let connected_channel_count () = with_registry (fun () -> Hashtbl.length peer_channel_map)

(** Clean up expired offers (older than max_age_s, default 60s). *)
let cleanup_expired_offers ?(max_age_s = 60.0) () =
  let now = Unix.gettimeofday () in
  let expired =
    with_registry (fun () ->
      Hashtbl.fold
        (fun id offer acc ->
           if now -. offer.created_at > max_age_s then id :: acc else acc)
        pending_offers
        [])
  in
  List.iter (fun id -> with_registry (fun () -> Hashtbl.remove pending_offers id)) expired;
  List.length expired
;;
