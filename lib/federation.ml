(** Federation — multi-org federation protocol with trust and delegation. *)

open Types [@@warning "-33"]
include Federation_types

let state : federation_state = {
  fed_config = None;
  pending_handshakes = [];
  pending_delegations = [];
  event_log = [];
}

(** Federation directory path - with path validation *)
let federation_dir (config : config) : (string, string) result =
  let dir = Filename.concat config.base_path "federation" in
  validate_path config.base_path dir

(** Federation config file path - with path validation *)
let config_file (config : config) : (string, string) result =
  match federation_dir config with
  | Error e -> Error e
  | Ok dir ->
    let path = Filename.concat dir "federation.json" in
    validate_path config.base_path path

(** Events log file path - with path validation *)
let events_file (config : config) : (string, string) result =
  match federation_dir config with
  | Error e -> Error e
  | Ok dir ->
    let path = Filename.concat dir "events.jsonl" in
    validate_path config.base_path path

(** Members file path - with path validation *)
let members_file (config : config) : (string, string) result =
  match federation_dir config with
  | Error e -> Error e
  | Ok dir ->
    let path = Filename.concat dir "members.json" in
    validate_path config.base_path path

(** Get current ISO8601 timestamp *)
let now_iso8601 () : string =
  let t = Time_compat.now () in
  let tm = Unix.gmtime t in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1)
    tm.Unix.tm_mday
    tm.Unix.tm_hour
    tm.Unix.tm_min
    tm.Unix.tm_sec

(** Generate random nonce for handshake *)
let generate_nonce () : string =
  let bytes = Mirage_crypto_rng.generate 32 in
  let buf = Buffer.create 64 in
  for i = 0 to String.length bytes - 1 do
    Buffer.add_string buf (Printf.sprintf "%02x" (Char.code (String.get bytes i)))
  done;
  Buffer.contents buf

(** Generate unique ID *)
let generate_id () : string =
  let bytes = Mirage_crypto_rng.generate 16 in
  let buf = Buffer.create 32 in
  for i = 0 to String.length bytes - 1 do
    Buffer.add_string buf (Printf.sprintf "%02x" (Char.code (String.get bytes i)))
  done;
  let hex = Buffer.contents buf in
  Printf.sprintf "%s-%s-%s-%s-%s"
    (String.sub hex 0 8)
    (String.sub hex 8 4)
    (String.sub hex 12 4)
    (String.sub hex 16 4)
    (String.sub hex 20 12)

(** Ensure federation directory exists - returns Result *)
let ensure_federation_dir (config : config) : (unit, string) result =
  match federation_dir config with
  | Error e -> Error e
  | Ok dir ->
    try
      Fs_compat.mkdir_p dir;
      Ok ()
    with
    | Unix.Unix_error (err, _, _) -> Error (Printf.sprintf "Failed to create directory: %s" (Unix.error_message err))

(** Log a federation event - best effort, ignores errors *)
let log_event (config : config) (event : federation_event) : unit =
  match ensure_federation_dir config with
  | Error e ->
    Log.Misc.error "federation: ensure_dir failed: %s" e
  | Ok () ->
    state.event_log <- event :: state.event_log;
    match events_file config with
    | Error e ->
      Log.Misc.error "federation: events_file path error: %s" e
    | Ok path ->
      (match safe_append_file path (Yojson.Safe.to_string (federation_event_to_yojson event) ^ "\n") with
       | Ok () -> ()
       | Error e -> Log.Misc.error "federation: event write failed: %s" e)

(** Helper: Save config to disk - thread-safe *)
let save_config (config : config) (fed_config : federation_config) : (unit, string) result =
  match config_file config with
  | Error e -> Error e
  | Ok path ->
    let json = federation_config_to_yojson fed_config in
    safe_write_file path (Yojson.Safe.pretty_to_string json)

(** Initialize federation with local organization

    @param config Room configuration
    @param org_id Organization identifier
    @param org_name Human-readable organization name
    @return Initialized federation configuration or error
*)
let initialize (config : config) ~org_id ~org_name : (federation_config, string) result =
  (* Validate inputs *)
  match validate_id org_id "org_id" with
  | Error e -> Error e
  | Ok validated_org_id ->
    match validate_id org_name "org_name" with
    | Error e -> Error e
    | Ok validated_org_name ->
      (* Ensure directory exists *)
      match ensure_federation_dir config with
      | Error e -> Error e
      | Ok () ->
        let now = now_iso8601 () in
        let local_org = make_local_org ~id:validated_org_id ~name:validated_org_name () in
        let fed_config : federation_config = {
          id = generate_id ();
          name = validated_org_name ^ " Federation";
          local_org;
          members = [];
          shared_state = [];
          created_at = now;
          protocol_version = "1.0";
        } in
        (* Thread-safe state update *)
        with_lock (fun () ->
          state.fed_config <- Some fed_config
        );
        (* Save to disk *)
        match save_config config fed_config with
        | Error e -> Error e
        | Ok () -> Ok fed_config

(** Load federation config from disk *)
let load (config : config) : (federation_config option, string) result =
  match config_file config with
  | Error e -> Error e
  | Ok path ->
    match safe_read_file path with
    | Error _ -> Ok None  (* File not found is OK *)
    | Ok content ->
      match Yojson.Safe.from_string content |> federation_config_of_yojson with
      | Ok fed_config ->
        with_lock (fun () ->
          state.fed_config <- Some fed_config
        );
        Ok (Some fed_config)
      | Error msg -> Error (Printf.sprintf "Failed to parse config: %s" msg)

(** Get current federation config *)
let get_config () : federation_config option =
  state.fed_config

(** Create handshake challenge for incoming organization

    @param from_org Organization requesting to join
    @return Handshake challenge to send back
*)
let create_challenge (from_org : organization) : handshake_challenge =
  let now = Time_compat.now () in
  let timeout = 3600.0 in  (* 1 hour timeout *)
  let challenge : handshake_challenge = {
    challenge_id = generate_id ();
    from_org;
    nonce = generate_nonce ();
    created_at = string_of_float now;
    expires_at = string_of_float (now +. timeout);
  } in
  (* Thread-safe state update *)
  with_lock (fun () ->
    state.pending_handshakes <- challenge :: state.pending_handshakes
  );
  challenge

(** Verify handshake response

    In production, this would:
    1. Check signature against public key
    2. Verify nonce matches challenge
    3. Check expiry

    For now, accept all responses (trust-on-first-use)
*)
let verify_response (config : config) (response : handshake_response) : (federation_member, federation_error) result =
  (* Thread-safe challenge lookup and removal *)
  let challenge_opt = with_lock (fun () ->
    match List.find_opt (fun (c : handshake_challenge) -> c.challenge_id = response.challenge_id) state.pending_handshakes with
    | None -> None
    | Some challenge ->
      state.pending_handshakes <- List.filter (fun (c : handshake_challenge) -> c.challenge_id <> response.challenge_id) state.pending_handshakes;
      Some challenge
  ) in
  match challenge_opt with
  | None -> Error (HandshakeError "Challenge not found or expired")
  | Some challenge ->
    (* Create member *)
    let now = now_iso8601 () in
    let member = make_federation_member ~org:challenge.from_org ~now in
    let member = { member with status = Active } in
    (* Log event *)
    log_event config (HandshakeSuccess { org_id = challenge.from_org.id; timestamp = now });
    Ok member

(** Add organization to federation

    @param config Room configuration
    @param org Organization to add
    @return Updated member or error
*)
let add_member (config : config) (org : organization) : (federation_member, federation_error) result =
  (* Validate org_id *)
  match validate_id org.id "org_id" with
  | Error e -> Error (HandshakeError e)
  | Ok _ ->
    (* Thread-safe state update *)
    let result = with_lock (fun () ->
      match state.fed_config with
      | None -> Error FederationNotInitialized
      | Some fed_config ->
        if List.exists (fun m -> m.organization.id = org.id) fed_config.members then
          Error (HandshakeError "Organization already a member")
        else begin
          let now = now_iso8601 () in
          let member = make_federation_member ~org ~now in
          let member = { member with status = Active } in
          let updated = { fed_config with members = member :: fed_config.members } in
          state.fed_config <- Some updated;
          Ok (updated, member, now)
        end
    ) in
    match result with
    | Error e -> Error e
    | Ok (updated, member, now) ->
      (* Save outside lock *)
      begin match save_config config updated with
      | Error e -> Error (HandshakeError e)
      | Ok () ->
        log_event config (OrgJoined { org_id = org.id; timestamp = now });
        Ok member
      end

(** Remove organization from federation *)
let remove_member (config : config) ~org_id ~reason : (unit, federation_error) result =
  (* Validate org_id *)
  match validate_id org_id "org_id" with
  | Error e -> Error (HandshakeError e)
  | Ok _ ->
    (* Thread-safe state update *)
    let result = with_lock (fun () ->
      match state.fed_config with
      | None -> Error FederationNotInitialized
      | Some fed_config ->
        if not (List.exists (fun m -> m.organization.id = org_id) fed_config.members) then
          Error (OrgNotFound org_id)
        else begin
          let updated = { fed_config with
            members = List.filter (fun m -> m.organization.id <> org_id) fed_config.members
          } in
          state.fed_config <- Some updated;
          Ok updated
        end
    ) in
    match result with
    | Error e -> Error e
    | Ok updated ->
      (* Save outside lock *)
      begin match save_config config updated with
      | Error e -> Error (HandshakeError e)
      | Ok () ->
        let now = now_iso8601 () in
        log_event config (OrgLeft { org_id; reason; timestamp = now });
        Ok ()
      end

(** Find member by organization ID *)
let find_member ~org_id : federation_member option =
  match state.fed_config with
  | None -> None
  | Some fed_config ->
    List.find_opt (fun m -> m.organization.id = org_id) fed_config.members

(** Convert trust level to integer for comparison (higher = more trusted) *)
let trust_level_to_int = function
  | Trusted -> 4
  | Verified -> 3
  | Pending -> 2
  | Untrusted -> 1

(** Check if member meets minimum trust level for delegation *)
let can_delegate_to ~(member : federation_member) ~min_trust : bool =
  member.active &&
  member.status = Active &&
  trust_level_to_int member.trust_level >= trust_level_to_int min_trust

(** Convert integer back to trust level *)
let int_to_trust_level = function
  | n when n >= 4 -> Trusted
  | 3 -> Verified
  | 2 -> Pending
  | _ -> Untrusted

(** Update trust level based on success/failure of delegation *)
let update_trust ~(member : federation_member) ~success : federation_member =
  let current = trust_level_to_int member.trust_level in
  let delta = if success then 1 else -1 in
  let new_level = int_to_trust_level (max 1 (min 4 (current + delta))) in
  { member with trust_level = new_level }

(** Check if delegation is allowed to target organization *)
let can_delegate ~to_org_id ?(min_trust = default_trust_threshold) () : bool =
  match find_member ~org_id:to_org_id with
  | None -> false
  | Some member -> can_delegate_to ~member ~min_trust

(** Create delegation request

    @param config Room configuration
    @param to_org Target organization ID
    @param task Task to delegate
    @param priority 1-5 (1 = highest)
    @param timeout_seconds Maximum time for task completion
    @return Delegation request or error
*)
let create_delegation (config : config) ~to_org ~(task : task) ~priority ~timeout_seconds
    : (delegation_request, federation_error) result =
  (* Validate to_org *)
  match validate_id to_org "to_org" with
  | Error e -> Error (HandshakeError e)
  | Ok _ ->
    (* Thread-safe read and update *)
    let result = with_lock (fun () ->
      match state.fed_config with
      | None -> Error FederationNotInitialized
      | Some fed_config ->
        match find_member ~org_id:to_org with
        | None -> Error (OrgNotFound to_org)
        | Some member ->
          if not (can_delegate_to ~member ~min_trust:default_trust_threshold) then
            Error (TrustTooLow {
              org_id = to_org;
              required = default_trust_threshold;
              actual = member.trust_level
            })
          else begin
            let now = now_iso8601 () in
            let request : delegation_request = {
              id = generate_id ();
              from_org = fed_config.local_org.id;
              to_org;
              task;
              priority;
              timeout_seconds;
              created_at = now;
              status = "pending";
              result = None;
            } in
            state.pending_delegations <- request :: state.pending_delegations;
            Ok (request, now)
          end
    ) in
    match result with
    | Error e -> Error e
    | Ok (request, now) ->
      log_event config (TaskDelegated {
        task_id = request.id;
        from_org = request.from_org;
        to_org = request.to_org;
        task = task.id;
        timestamp = now
      });
      Ok request

(** Update delegation status *)
let update_delegation ~request_id ~status ~result : (delegation_request, federation_error) result =
  (* Thread-safe update *)
  with_lock (fun () ->
    match List.find_opt (fun (r : delegation_request) -> r.id = request_id) state.pending_delegations with
    | None -> Error (DelegationFailed { task_id = request_id; reason = "Delegation not found" })
    | Some request ->
      let updated = { request with status; result } in
      state.pending_delegations <- List.map (fun (r : delegation_request) ->
        if r.id = request_id then updated else r
      ) state.pending_delegations;
      Ok updated
  )

(** Update trust based on delegation outcome *)
let update_member_trust (config : config) ~org_id ~success : (federation_member, federation_error) result =
  (* Validate org_id *)
  match validate_id org_id "org_id" with
  | Error e -> Error (HandshakeError e)
  | Ok _ ->
    (* Thread-safe state update *)
    let result = with_lock (fun () ->
      match state.fed_config with
      | None -> Error FederationNotInitialized
      | Some fed_config ->
        match find_member ~org_id with
        | None -> Error (OrgNotFound org_id)
        | Some member ->
          let old_level = member.trust_level in
          let updated_member = update_trust ~member ~success in
          let updated_config = { fed_config with
            members = List.map (fun m ->
              if m.organization.id = org_id then updated_member else m
            ) fed_config.members
          } in
          state.fed_config <- Some updated_config;
          Ok (updated_config, old_level, updated_member)
    ) in
    match result with
    | Error e -> Error e
    | Ok (updated_config, old_level, updated_member) ->
      (* Save outside lock *)
      begin match save_config config updated_config with
      | Error e -> Error (HandshakeError e)
      | Ok () ->
        let now = now_iso8601 () in
        log_event config (TrustUpdated {
          org_id;
          old_level;
          new_level = updated_member.trust_level;
          timestamp = now
        });
        Ok updated_member
      end

(** Get shared state entry *)
let get_shared_state ~key : shared_state_entry option =
  with_lock (fun () ->
    match state.fed_config with
    | None -> None
    | Some fed_config ->
      List.find_opt (fun e -> e.key = key) fed_config.shared_state
  )

(** Set shared state entry (optimistic concurrency) *)
let set_shared_state (config : config) ~key ~value ~expected_version
    : (shared_state_entry, federation_error) result =
  (* Validate key *)
  match validate_id key "key" with
  | Error e -> Error (HandshakeError e)
  | Ok _ ->
    (* Thread-safe optimistic concurrency *)
    let result = with_lock (fun () ->
      match state.fed_config with
      | None -> Error FederationNotInitialized
      | Some fed_config ->
        let existing = List.find_opt (fun e -> e.key = key) fed_config.shared_state in
        let current_version = match existing with
          | Some e -> e.version
          | None -> 0
        in
        if expected_version <> current_version then
          Error (DelegationFailed {
            task_id = key;
            reason = Printf.sprintf "Version mismatch: expected %d, got %d" expected_version current_version
          })
        else begin
          let now = now_iso8601 () in
          let entry : shared_state_entry = {
            key;
            value;
            version = current_version + 1;
            updated_by = fed_config.local_org.id;
            updated_at = now;
          } in
          let updated = { fed_config with
            shared_state = entry :: List.filter (fun e -> e.key <> key) fed_config.shared_state
          } in
          state.fed_config <- Some updated;
          Ok (updated, entry)
        end
    ) in
    match result with
    | Error e -> Error e
    | Ok (updated, entry) ->
      (* Save outside lock *)
      begin match save_config config updated with
      | Error e -> Error (HandshakeError e)
      | Ok () -> Ok entry
      end

(** List all members with their status *)
let list_members () : federation_member list =
  match state.fed_config with
  | None -> []
  | Some fed_config -> fed_config.members

(** Get federation status summary *)
let status () : Yojson.Safe.t =
  match state.fed_config with
  | None ->
    `Assoc [
      ("initialized", `Bool false);
      ("message", `String "Federation not initialized. Use initialize() first.");
    ]
  | Some fed_config ->
    let active_members = List.filter (fun (m : federation_member) -> m.status = Active) fed_config.members in
    let suspended_members = List.filter (fun (m : federation_member) -> m.status = Suspended) fed_config.members in
    `Assoc [
      ("initialized", `Bool true);
      ("federation_id", `String fed_config.id);
      ("federation_name", `String fed_config.name);
      ("local_org", `Assoc [
        ("id", `String fed_config.local_org.id);
        ("name", `String fed_config.local_org.name);
      ]);
      ("protocol_version", `String fed_config.protocol_version);
      ("created_at", `String fed_config.created_at);
      ("members", `Assoc [
        ("total", `Int (List.length fed_config.members));
        ("active", `Int (List.length active_members));
        ("suspended", `Int (List.length suspended_members));
      ]);
      ("pending_handshakes", `Int (List.length state.pending_handshakes));
      ("pending_delegations", `Int (List.length state.pending_delegations));
      ("event_log_size", `Int (List.length state.event_log));
      ("shared_state_keys", `Int (List.length fed_config.shared_state));
    ]

(** Discover remote organizations by fetching their agent card.

    Tries the canonical A2A discovery path first and keeps the legacy
    agent-card alias for backward compatibility.
*)
let discover_remote ~endpoint : Yojson.Safe.t =
  match A2a_tools.fetch_remote_agent_card endpoint with
  | Ok (card_json, discovered_url) ->
      `Assoc
        [
          ("success", `Bool true);
          ("type", `String "remote_discovery");
          ("endpoint", `String endpoint);
          ("discovered_url", `String discovered_url);
          ("agent_card", card_json);
        ]
  | Error err -> `Assoc [ ("success", `Bool false); ("error", `String err) ]

(* ============================================ *)
(* Cross-Room Communication                     *)
(* ============================================ *)

(** List rooms in a federated organization

    Returns room information for the specified organization.
    For local org, reads from disk. For remote orgs, fetches
    from the remote endpoint via curl.
*)
let list_org_rooms ~org_id : Yojson.Safe.t =
  match state.fed_config with
  | None ->
    `Assoc [
      ("success", `Bool false);
      ("error", `String "Federation not initialized");
    ]
  | Some fed_config ->
    if fed_config.local_org.id = org_id then
      (* Local org - return actual room info *)
      `Assoc [
        ("success", `Bool true);
        ("org_id", `String org_id);
        ("rooms", `List (List.map (fun r -> `String r) fed_config.local_org.rooms));
        ("source", `String "local");
      ]
    else
      match find_member ~org_id with
      | None ->
        `Assoc [
          ("success", `Bool false);
          ("error", `String (Printf.sprintf "Organization %s not found in federation" org_id));
        ]
      | Some member ->
        let endpoint = Option.value member.organization.endpoint ~default:"unknown" in
        let rooms_url = endpoint ^ "/api/rooms" in
        let argv = ["curl"; "-s"; "--max-time"; "10"; "--proto"; "=https,http";
                    "-H"; "Accept: application/json"; rooms_url] in
        (try
          let (status, body) = Process_eio.run_argv_with_status ~timeout_sec:15.0 argv in
          match status with
          | Unix.WEXITED 0 when String.length body > 0 ->
            (try
              let rooms_json = Yojson.Safe.from_string body in
              `Assoc [
                ("success", `Bool true);
                ("org_id", `String org_id);
                ("rooms", rooms_json);
                ("source", `String "remote");
                ("endpoint", `String endpoint);
              ]
            with Yojson.Json_error msg ->
              `Assoc [
                ("success", `Bool false);
                ("error", `String (Printf.sprintf "Invalid JSON from %s: %s" rooms_url msg));
              ])
          | Unix.WEXITED 0 ->
            `Assoc [
              ("success", `Bool false);
              ("error", `String (Printf.sprintf "Empty response from %s" rooms_url));
            ]
          | Unix.WEXITED code ->
            `Assoc [
              ("success", `Bool false);
              ("error", `String (Printf.sprintf "HTTP fetch failed (exit %d): %s" code rooms_url));
            ]
          | Unix.WSIGNALED sig_num ->
            `Assoc [
              ("success", `Bool false);
              ("error", `String (Printf.sprintf "Fetch killed by signal %d: %s" sig_num rooms_url));
            ]
          | Unix.WSTOPPED _ ->
            `Assoc [
              ("success", `Bool false);
              ("error", `String (Printf.sprintf "Fetch stopped: %s" rooms_url));
            ]
        with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
          Log.Misc.error "federation: remote room list error: %s" (Printexc.to_string exn);
          `Assoc [
            ("success", `Bool false);
            ("error", `String "Remote room list error (internal error)");
          ])

(** Cross-room message type *)
type cross_room_message = {
  id: string;
  from_org: string;
  from_room: string;
  to_org: string;
  to_room: string;
  content: string;
  message_type: string;  (* "request" | "response" | "broadcast" *)
  created_at: string;
  metadata: (string * string) list;
}

(** Send message to a room in another organization

    For remote orgs, returns routing info for HTTP client.
    Trust level is checked before allowing cross-room messaging.
*)
let send_cross_room_message (config : config)
    ~from_room ~to_org ~to_room ~content ~message_type
    : (Yojson.Safe.t, federation_error) result =
  match state.fed_config with
  | None -> Error FederationNotInitialized
  | Some fed_config ->
    match find_member ~org_id:to_org with
    | None -> Error (OrgNotFound to_org)
    | Some member ->
      if not (can_delegate_to ~member ~min_trust:default_trust_threshold) then
        Error (TrustTooLow {
          org_id = to_org;
          required = default_trust_threshold;
          actual = member.trust_level
        })
      else begin
        let now = now_iso8601 () in
        let msg : cross_room_message = {
          id = generate_id ();
          from_org = fed_config.local_org.id;
          from_room;
          to_org;
          to_room;
          content;
          message_type;
          created_at = now;
          metadata = [];
        } in
        (* Log the event *)
        log_event config (TaskDelegated {
          task_id = msg.id;
          from_org = msg.from_org;
          to_org = msg.to_org;
          task = "cross_room_message";
          timestamp = now;
        });
        let endpoint = Option.value member.organization.endpoint ~default:"unknown" in
        Ok (`Assoc [
          ("success", `Bool true);
          ("message_id", `String msg.id);
          ("from_org", `String msg.from_org);
          ("from_room", `String msg.from_room);
          ("to_org", `String msg.to_org);
          ("to_room", `String msg.to_room);
          ("type", `String "cross_room_message");
          ("endpoint", `String endpoint);
          ("delivery_url", `String (endpoint ^ "/api/rooms/" ^ to_room ^ "/messages"));
          ("note", `String "Use HTTP client to POST message to delivery_url");
        ])
      end

(** Subscribe to events from a remote room

    Returns subscription info for SSE client setup.
*)
let subscribe_remote_room ~org_id ~room_id : (Yojson.Safe.t, federation_error) result =
  match state.fed_config with
  | None -> Error FederationNotInitialized
  | Some _fed_config ->
    match find_member ~org_id with
    | None -> Error (OrgNotFound org_id)
    | Some member ->
      if not (can_delegate_to ~member ~min_trust:default_trust_threshold) then
        Error (TrustTooLow {
          org_id;
          required = default_trust_threshold;
          actual = member.trust_level
        })
      else begin
        let endpoint = Option.value member.organization.endpoint ~default:"unknown" in
        Ok (`Assoc [
          ("success", `Bool true);
          ("subscription_type", `String "remote_room_events");
          ("org_id", `String org_id);
          ("room_id", `String room_id);
          ("endpoint", `String endpoint);
          ("sse_url", `String (endpoint ^ "/api/rooms/" ^ room_id ^ "/events"));
          ("note", `String "Connect SSE client to sse_url to receive events");
          ("event_types", `List [
            `String "task_created";
            `String "task_claimed";
            `String "task_completed";
            `String "message_broadcast";
            `String "agent_joined";
            `String "agent_left";
          ]);
        ])
      end
