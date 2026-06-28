(** RFC-0284: push the goal-loop OODA status to dashboard clients over SSE
    when its content changes, instead of leaving the panel on HTTP pull.

    The goal-loop worker is an out-of-process Python OODA loop
    ([scripts/goal_loop_scheduler.py] and friends) that only writes
    [<masc_dir>/goal-loop/status.json]; it cannot call the in-process
    [Sse.broadcast]. So the broadcast trigger lives here on the server: a
    periodic tick reads the (5 s TTL cached) status via
    [Dashboard_goal_loop.status_json], fingerprints the meaningful content,
    and broadcasts a [goal_loop_status] event only when it changed since the
    last broadcast.

    The [goal_loop_status] event bridges to the existing dashboard "goals"
    WS slice via [Server_mcp_transport_ws.dashboard_slice_for_sse_type], so
    no new dashboard WS slice is introduced. RFC-0284 §3.1 originally
    proposed reusing the "goals" snapshot with no new event type at all, but
    the live-update path runs through the SSE -> dashboard/delta bridge,
    which keys deltas by event_type; the "goals" slice only paints on the
    initial dashboard/snapshot burst. A dedicated [goal_loop_status] event
    type is therefore required for live deltas. See RFC-0284 §3 (amended).

    The change-detection / fingerprint pattern mirrors
    [Server_dashboard_http_namespace_truth.should_broadcast_namespace_truth_snapshot]. *)

let goal_loop_broadcast_event_type = "goal_loop_status"

(* Default tick interval. Matches the goal-loop status read model's own 5 s
   TTL cache ([Dashboard_goal_loop.goal_loop_cache_ttl_s]); a shorter tick
   would only re-read the same cached value. *)
let goal_loop_broadcast_interval_s = 5.0
let goal_loop_broadcast_timeout_s = goal_loop_broadcast_interval_s *. 0.8

(* Per-write volatiles excluded from the change fingerprint. The Python
   writer stamps a fresh [generated_at] on every write (and the OCaml read
   model attaches a read-time [dashboard_source]), even when the OODA content
   is unchanged. Hashing those would broadcast on every no-op rewrite.
   [loop_iteration] / [overall_status] / [phases] / [next_action] /
   [system_health_signals] / [known_blockers] remain in the fingerprint, so a
   real OODA-cycle change still triggers a broadcast. *)
let goal_loop_fingerprint_volatile_keys = [ "generated_at"; "dashboard_source" ]

let goal_loop_fingerprint (status : Yojson.Safe.t) : Digestif.SHA256.t =
  let stable =
    match status with
    | `Assoc kvs ->
        `Assoc
          (List.filter
             (fun (k, _) -> not (List.mem k goal_loop_fingerprint_volatile_keys))
             kvs)
    | other -> other
  in
  Digestif.SHA256.digest_string (Yojson.Safe.to_string stable)

let last_goal_loop_snapshot_hash : Digestif.SHA256.t option ref = ref None
let goal_loop_snapshot_hash_mu = Eio.Mutex.create ()

(* Returns [true] exactly once per distinct fingerprint: the first time a
   given content is seen, and again only after the content changes. Updates
   the stored fingerprint as a side effect. *)
let should_broadcast_goal_loop_snapshot (status : Yojson.Safe.t) : bool =
  let hash = goal_loop_fingerprint status in
  Eio.Mutex.use_rw ~protect:true goal_loop_snapshot_hash_mu (fun () ->
      match !last_goal_loop_snapshot_hash with
      | Some prev when Digestif.SHA256.equal prev hash -> false
      | _ ->
          last_goal_loop_snapshot_hash := Some hash;
          true)

let goal_loop_snapshot_event (status : Yojson.Safe.t) : Yojson.Safe.t =
  `Assoc
    [ "type", `String goal_loop_broadcast_event_type
    ; "payload", status
    ; "ts_unix", `Float (Time_compat.now ())
    ]

(* RFC-0284 §3.2: broadcast a [goal_loop_status] event carrying [status], but
   only when its fingerprint changed since the last broadcast. Returns [true]
   when an event was emitted (exposed for tests). *)
let broadcast_goal_loop_status (status : Yojson.Safe.t) : bool =
  if should_broadcast_goal_loop_snapshot status then begin
    Sse.broadcast_to Observers (goal_loop_snapshot_event status);
    Log.Dashboard.routine "goal-loop status pushed via SSE";
    true
  end
  else begin
    Log.Dashboard.routine "goal-loop status unchanged, skipping SSE broadcast";
    false
  end

let goal_loop_status_for_state (state : Mcp_server.server_state) : Yojson.Safe.t =
  Dashboard_goal_loop.status_json
    ~base_path:(Mcp_server.workspace_config state).base_path ()

let start_goal_loop_refresh_loop ~state ~sw ~clock =
  Proactive_refresh.start
    ~sw
    ~clock
	~config:
	  { (Proactive_refresh.default_config
	       ~label:"goal_loop_status"
	       ~interval_s:goal_loop_broadcast_interval_s) with
	    timeout_s = goal_loop_broadcast_timeout_s
	  }
    ~compute:(fun () -> goal_loop_status_for_state state)
    ~on_result:(fun status -> ignore (broadcast_goal_loop_status status))
