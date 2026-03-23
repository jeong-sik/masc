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

    This module manages the signaling state and peer registry.
    The actual WebRTC stack is provided by ocaml-webrtc (Webrtc_eio).

    Opt-in via MASC_WEBRTC_ENABLED=1. *)

(** Whether WebRTC transport is enabled. *)
let is_enabled () =
  match Sys.getenv_opt "MASC_WEBRTC_ENABLED" with
  | Some "1" | Some "true" -> true
  | _ -> false

(** {1 Signaling State} *)

(** Pending offer waiting for an answer. *)
type pending_offer = {
  offer_id: string;
  from_agent: string;
  ice_candidates: string list;
  dtls_fingerprint: string;
  created_at: float;
}

(** Active DataChannel peer connection (post-signaling). *)
type peer_conn = {
  peer_id: string;
  remote_agent: string;
  channel_label: string;
  mutable connected: bool;
  mutable last_activity: float;
}

(** Signaling exchange registry. *)
let pending_offers : (string, pending_offer) Hashtbl.t = Hashtbl.create 8
let active_peers : (string, peer_conn) Hashtbl.t = Hashtbl.create 8
let registry_mutex = Eio.Mutex.create ()

let with_registry f =
  try Eio.Mutex.use_rw ~protect:true registry_mutex f
  with Effect.Unhandled _ | Eio.Mutex.Poisoned _ -> f ()

(** Generate a unique offer/peer ID. *)
let next_id =
  let counter = Atomic.make 0 in
  fun prefix ->
    let n = Atomic.fetch_and_add counter 1 in
    Printf.sprintf "%s-%d-%d" prefix
      (int_of_float (Unix.gettimeofday () *. 1000.0)) n

(** {1 Signaling API} *)

(** Create a signaling offer.
    Returns the offer_id for the answerer to reference. *)
let create_offer ~from_agent ~ice_candidates ~dtls_fingerprint =
  let offer_id = next_id "offer" in
  let offer = {
    offer_id;
    from_agent;
    ice_candidates;
    dtls_fingerprint;
    created_at = Unix.gettimeofday ();
  } in
  with_registry (fun () ->
    Hashtbl.replace pending_offers offer_id offer);
  Log.Server.info "WebRTC offer %s from %s (%d ICE candidates)"
    offer_id from_agent (List.length ice_candidates);
  offer_id

(** Retrieve a pending offer (for the answerer). *)
let get_offer offer_id =
  with_registry (fun () ->
    Hashtbl.find_opt pending_offers offer_id)

(** Complete signaling by accepting an offer.
    Returns a peer_conn for both sides. *)
let accept_offer ~offer_id ~answerer_agent =
  with_registry (fun () ->
    match Hashtbl.find_opt pending_offers offer_id with
    | None -> Error "Offer not found or expired"
    | Some offer ->
      Hashtbl.remove pending_offers offer_id;
      let peer_id = next_id "peer" in
      let conn = {
        peer_id;
        remote_agent = offer.from_agent;
        channel_label = "masc-events";
        connected = false;
        last_activity = Unix.gettimeofday ();
      } in
      Hashtbl.replace active_peers peer_id conn;
      Log.Server.info "WebRTC peer %s established: %s <-> %s"
        peer_id offer.from_agent answerer_agent;
      Ok conn)

(** Mark a peer as connected (DataChannel open). *)
let mark_connected peer_id =
  with_registry (fun () ->
    match Hashtbl.find_opt active_peers peer_id with
    | None -> ()
    | Some conn ->
      conn.connected <- true;
      conn.last_activity <- Unix.gettimeofday ())

(** Remove a peer connection. *)
let remove_peer peer_id =
  with_registry (fun () ->
    Hashtbl.remove active_peers peer_id);
  Log.Server.info "WebRTC peer %s removed" peer_id

(** {1 HTTP Signaling Handlers} *)

(** Handle POST /webrtc/offer — create a new offer. *)
let handle_offer_request body =
  try
    let json = Yojson.Safe.from_string body in
    let from_agent =
      Yojson.Safe.Util.(member "agent_name" json |> to_string) in
    let ice_candidates =
      Yojson.Safe.Util.(member "ice_candidates" json |> to_list
        |> List.map to_string) in
    let dtls_fingerprint =
      Yojson.Safe.Util.(member "dtls_fingerprint" json |> to_string_option)
      |> Option.value ~default:"" in
    let offer_id = create_offer ~from_agent ~ice_candidates ~dtls_fingerprint in
    Ok (Printf.sprintf {|{"offer_id":"%s","status":"pending"}|} offer_id)
  with exn ->
    Error (Printf.sprintf "Invalid offer: %s" (Printexc.to_string exn))

(** Handle POST /webrtc/answer — accept an existing offer. *)
let handle_answer_request body =
  try
    let json = Yojson.Safe.from_string body in
    let offer_id =
      Yojson.Safe.Util.(member "offer_id" json |> to_string) in
    let answerer =
      Yojson.Safe.Util.(member "agent_name" json |> to_string) in
    match accept_offer ~offer_id ~answerer_agent:answerer with
    | Ok conn ->
      Ok (Printf.sprintf
        {|{"peer_id":"%s","remote_agent":"%s","channel":"%s","status":"accepted"}|}
        conn.peer_id conn.remote_agent conn.channel_label)
    | Error msg ->
      Error msg
  with exn ->
    Error (Printf.sprintf "Invalid answer: %s" (Printexc.to_string exn))

(** {1 Diagnostics} *)

(** Number of pending offers. *)
let pending_offer_count () =
  with_registry (fun () ->
    Hashtbl.length pending_offers)

(** Number of active peer connections. *)
let active_peer_count () =
  with_registry (fun () ->
    Hashtbl.length active_peers)

(** Clean up expired offers (older than max_age_s, default 60s). *)
let cleanup_expired_offers ?(max_age_s = 60.0) () =
  let now = Unix.gettimeofday () in
  let expired =
    with_registry (fun () ->
      Hashtbl.fold (fun id offer acc ->
        if now -. offer.created_at > max_age_s then id :: acc else acc
      ) pending_offers [])
  in
  List.iter (fun id ->
    with_registry (fun () -> Hashtbl.remove pending_offers id)
  ) expired;
  List.length expired
