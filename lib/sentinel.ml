(** Sentinel — MASC default resident agent.

    Ensures at least one agent is always alive when the server runs.
    Integrates Guardian's zombie/gc consumers and adds:
    - Self-heartbeat (room presence)
    - Board patrol (stale post detection, daily status)
    - Task hygiene (orphaned/stuck task warnings)
    - Keeper health monitoring

    Opt-out via MASC_SENTINEL_ENABLED=false. *)

open Printf

let agent_name = "sentinel"

let log msg =
  eprintf "[sentinel] %s\n%!" msg

(** Parse ISO 8601 timestamp to float; returns epoch (0.0) on failure
    so that unparseable timestamps are treated as maximally stale. *)
let parse_iso_or_epoch s =
  Resilience.Time.parse_iso8601_opt s |> Option.value ~default:0.0

(* ── Sentinel-specific Pulse Consumers ─────────────────────── *)

(** Heartbeat consumer: keeps sentinel visible in the room. *)
let make_heartbeat_consumer config : (module Pulse.Consumer) =
  (module struct
    let name = "sentinel-heartbeat"
    let should_act _beat = true
    let on_beat _beat =
      try
        let _msg = Room.heartbeat config ~agent_name in
        Ok ()
      with exn ->
        let msg = sprintf "heartbeat failed: %s" (Printexc.to_string exn) in
        log msg;
        Error msg
  end)

(** Board patrol consumer: posts a daily status summary. *)
let make_board_patrol_consumer config : (module Pulse.Consumer) =
  let last_daily_post = ref 0 in (* day-of-year of last post *)
  (module struct
    let name = "sentinel-board-patrol"
    let should_act _beat = true
    let on_beat _beat =
      try
        let state = Room.read_state config in
        let backlog = Room.read_backlog config in
        let agent_count = List.length state.active_agents in
        let task_count = List.length backlog.tasks in
        let pending = List.filter (fun (t : Types.task) ->
          match t.task_status with Types.Todo -> true | _ -> false
        ) backlog.tasks |> List.length in
        let in_progress = List.filter (fun (t : Types.task) ->
          match t.task_status with Types.InProgress _ -> true | _ -> false
        ) backlog.tasks |> List.length in

        (* Post daily status once per calendar day *)
        let tm = Unix.localtime (Time_compat.now ()) in
        let today = tm.Unix.tm_yday in
        if today <> !last_daily_post then begin
          last_daily_post := today;
          let content = sprintf
            "[Sentinel Daily] agents=%d tasks=%d (pending=%d in_progress=%d) paused=%b"
            agent_count task_count pending in_progress state.paused
          in
          (match Board_dispatch.create_post
                   ~author:agent_name ~content
                   ~visibility:Board.Internal
                   ~hearth:"sentinel" () with
           | Ok _post -> log "daily status posted"
           | Error e -> log (sprintf "daily post failed: %s" (Board.show_board_error e)));
        end;
        Ok ()
      with exn ->
        let msg = sprintf "board patrol failed: %s" (Printexc.to_string exn) in
        log msg;
        Error msg
  end)

(** Task hygiene consumer: detects orphaned/stuck tasks and broadcasts warnings. *)
let make_task_hygiene_consumer config : (module Pulse.Consumer) =
  (module struct
    let name = "sentinel-task-hygiene"
    let should_act _beat = true
    let on_beat _beat =
      try
        let backlog = Room.read_backlog config in
        let now_f = Time_compat.now () in
        let stuck_threshold = Env_config.Sentinel.task_stuck_threshold_sec in
        let stale_threshold = Env_config.Sentinel.task_stale_threshold_sec in

        let warnings = ref [] in
        List.iter (fun (t : Types.task) ->
          match t.task_status with
          | Types.Claimed { assignee; claimed_at } ->
              (* Check if the claiming agent still exists *)
              let is_alive = Room.is_agent_joined config ~agent_name:assignee in
              let age = now_f -. (parse_iso_or_epoch claimed_at) in
              if (not is_alive) || age > stuck_threshold then
                warnings := sprintf "task %s may be stuck (claimed by %s, %.0fs ago, agent_alive=%b)"
                  t.id assignee age is_alive :: !warnings
          | Types.InProgress { assignee; started_at } ->
              let age = now_f -. (parse_iso_or_epoch started_at) in
              if age > stale_threshold then
                warnings := sprintf "task %s may be stale (in_progress by %s, %.0fs ago)"
                  t.id assignee age :: !warnings
          | _ -> ()
        ) backlog.tasks;

        if !warnings <> [] then begin
          let msg = sprintf "[sentinel] %d task warning(s): %s"
            (List.length !warnings) (String.concat "; " !warnings) in
          log msg;
          Sse.broadcast (`Assoc [
            ("type", `String "sentinel_warning");
            ("source", `String agent_name);
            ("warnings", `List (List.map (fun w -> `String w) !warnings));
            ("ts", `String (Types.now_iso ()));
          ])
        end;
        Ok ()
      with exn ->
        let msg = sprintf "task hygiene failed: %s" (Printexc.to_string exn) in
        log msg;
        Error msg
  end)

(** Keeper health consumer: detects stale keepers via bootstrap stats. *)
let make_keeper_health_consumer _config : (module Pulse.Consumer) =
  (module struct
    let name = "sentinel-keeper-health"
    let should_act _beat = true
    let on_beat _beat =
      try
        (* Read keeper meta directory for stale entries *)
        let keepers_dir =
          match Env_config.me_root_opt () with
          | Some root -> Filename.concat root ".masc/keepers"
          | None -> ".masc/keepers"
        in
        if Sys.file_exists keepers_dir && Sys.is_directory keepers_dir then begin
          let now_f = Time_compat.now () in
          let threshold = Env_config.KeeperBootstrap.stale_turn_seconds in
          let stale = ref [] in
          Sys.readdir keepers_dir |> Array.iter (fun name ->
            if Filename.check_suffix name ".json" then begin
              let path = Filename.concat keepers_dir name in
              try
                let json = Yojson.Safe.from_file path in
                (* Extract last_turn_at from keeper meta *)
                (match Yojson.Safe.Util.member "last_turn_at" json with
                 | `String ts ->
                     let last = parse_iso_or_epoch ts in
                     if now_f -. last > threshold then
                       stale := (Filename.chop_suffix name ".json") :: !stale
                 | _ -> ())
              with _ -> ()
            end
          );
          if !stale <> [] then
            log (sprintf "%d stale keeper(s): %s"
              (List.length !stale) (String.concat ", " !stale))
        end;
        Ok ()
      with exn ->
        let msg = sprintf "keeper health failed: %s" (Printexc.to_string exn) in
        log msg;
        Error msg
  end)

(* ── Status ────────────────────────────────────────────────── *)

let started = ref false
let start_ts : float ref = ref 0.0

let status_json () : Yojson.Safe.t =
  `Assoc [
    ("enabled", `Bool Env_config.Sentinel.enabled);
    ("started", `Bool !started);
    ("agent_name", `String agent_name);
    ("uptime_s", `Float (if !started then Time_compat.now () -. !start_ts else 0.0));
    ("consumers", `List [
      `String "sentinel-heartbeat";
      `String "guardian-zombie";
      `String "guardian-gc";
      `String "sentinel-board-patrol";
      `String "sentinel-task-hygiene";
      `String "sentinel-keeper-health";
    ]);
  ]

(* ── Start ─────────────────────────────────────────────────── *)

let start ~sw ~clock ~net config =
  if not Env_config.Sentinel.enabled then
    log "disabled (set MASC_SENTINEL_ENABLED=true)"
  else begin
    (* 1. Join room as sentinel agent *)
    let join_result = Room.join config ~agent_name ~capabilities:["sentinel"; "housekeeping"] () in
    log (sprintf "join: %s" (String.sub join_result 0 (min 80 (String.length join_result))));

    (* 2. Heartbeat pulse (30s) *)
    let p_hb = Pulse.create
      ~clock
      ~rhythm:(Guardian.fixed_rhythm Env_config.Sentinel.heartbeat_interval_sec)
      ~lifecycle:Perpetual
      ~consumers:[make_heartbeat_consumer config]
    in
    Pulse.run ~sw p_hb;

    (* 3. Guardian consumers: zombie + gc (reuse existing factories) *)
    Guardian.start_masc_loops ~sw ~clock config;

    (* 4. Board patrol (10min) *)
    let p_board = Pulse.create
      ~clock
      ~rhythm:(Guardian.fixed_rhythm Env_config.Sentinel.board_patrol_interval_sec)
      ~lifecycle:Perpetual
      ~consumers:[make_board_patrol_consumer config]
    in
    Pulse.run ~sw p_board;

    (* 5. Task hygiene + Keeper health (5min) *)
    let p_ops = Pulse.create
      ~clock
      ~rhythm:(Guardian.fixed_rhythm Env_config.Sentinel.task_hygiene_interval_sec)
      ~lifecycle:Perpetual
      ~consumers:[
        make_task_hygiene_consumer config;
        make_keeper_health_consumer config;
      ]
    in
    Pulse.run ~sw p_ops;

    started := true;
    start_ts := Time_compat.now ();
    ignore net;  (* net reserved for future HTTP-based health checks *)
    log "started (6 consumers: heartbeat, zombie, gc, board-patrol, task-hygiene, keeper-health)"
  end
