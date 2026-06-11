(** Keeper_ops_iteration — in-memory ring buffer tracking
    keeper recovery iterations for the ops dashboard.

    Receives recovery events from {!Keeper_recording_error_state}
    and maintains a bounded cyclic buffer (last N events).
    The dashboard endpoint projects this buffer +
    per-keeper aggregate stats. *)

module T = Masc_dashboard_api_types.Iteration
open T

(** Configuration. *)
let capacity = 1024     (* max events retained in ring buffer *)

(** {1 Ring buffer} *)

type ring = {
  events : recovery_event array;    (* fixed-size array, cyclically indexed *)
  mutable next : int;               (* next write slot *)
  mutable count : int;              (* total events written (for cycle tracking) *)
  mutable wrapped : bool;           (* true after first wrap *)
}

let create_ring () =
  { events = Array.make capacity (Obj.magic ());
    next = 0; count = 0; wrapped = false }

let push_event ring ev =
  ring.events.(ring.next) <- ev;
  ring.next <- (ring.next + 1) mod capacity;
  ring.count <- ring.count + 1;
  if ring.next = 0 then ring.wrapped <- true

(** Fold over events in insertion order (oldest first). *)
let fold_events ring ~init ~f =
  let n = if ring.wrapped then capacity else ring.count in
  let start = if ring.wrapped then ring.next else 0 in
  let acc = ref init in
  for i = 0 to n - 1 do
    let idx = (start + i) mod capacity in
    acc := f !acc ring.events.(idx)
  done;
  !acc

(** {1 Per-keeper stats} *)

type keeper_stats = {
  mutable total : int;
  mutable active : int;
  mutable resolved : int;
  mutable escalated : int;
  mutable duration_sum : int;
  mutable duration_count : int;
  mutable error_counts : (string, int) Hashtbl.t;
  mutable last_recovery : string option;
}

let make_keeper_stats () =
  { total = 0; active = 0; resolved = 0; escalated = 0;
    duration_sum = 0; duration_count = 0;
    error_counts = Hashtbl.create 8;
    last_recovery = None }

(** {1 Global state} *)

type t = {
  ring : ring;
  mutable cycle : int;
  per_keeper : (string, keeper_stats) Hashtbl.t;
}

let create () =
  { ring = create_ring ();
    cycle = 0;
    per_keeper = Hashtbl.create 16 }

let current_cycle t = t.cycle

(** {1 Record a recovery event} *)

let record_recovery t ~keeper_name ~error_message ?tool_name ?phase () =
  let id = Printf.sprintf "rec-%s-%d" keeper_name t.ring.count in
  let phase = Option.value phase ~default:Detecting in
  let now_iso = "" in (* caller should set started_at *)
  let ev = {
    id;
    keeper_name;
    phase;
    error_hint = None;
    error_message;
    tool_name;
    started_at = now_iso;
    resolved_at = None;
    duration_ms = None;
  } in
  push_event t.ring ev;
  (* Update per-keeper stats *)
  let ks = match Hashtbl.find_opt t.per_keeper keeper_name with
    | Some ks -> ks
    | None ->
        let ks = make_keeper_stats () in
        Hashtbl.replace t.per_keeper keeper_name ks;
        ks
  in
  ks.total <- ks.total + 1;
  ks.active <- ks.active + 1;
  (match tool_name with Some _ -> () | None -> ());
  (* Track top error *)
  let err_key = match String.length error_message with
    | n when n > 60 -> String.sub error_message 0 60 ^ "..."
    | _ -> error_message
  in
  let cur = try Hashtbl.find ks.error_counts err_key with Not_found -> 0 in
  Hashtbl.replace ks.error_counts err_key (cur + 1);
  ks.last_recovery <- Some now_iso;
  ()

(** Resolve a recovery event by id. *)
let resolve_event t ~event_id ~duration_ms =
  fold_events t.ring ~init:() ~f:(fun () ev ->
    if ev.id = event_id && ev.phase <> Resolved && ev.phase <> Escalated then begin
      ev.phase <- Resolved;
      ev.resolved_at <- Some "";
      ev.duration_ms <- Some duration_ms;
      (* Update stats *)
      match Hashtbl.find_opt t.per_keeper ev.keeper_name with
      | Some ks ->
          ks.active <- max 0 (ks.active - 1);
          ks.resolved <- ks.resolved + 1;
          ks.duration_sum <- ks.duration_sum + duration_ms;
          ks.duration_count <- ks.duration_count + 1
      | None -> ()
    end
  )

(** Escalate a recovery event (could not auto-resolve). *)
let escalate_event t ~event_id ~duration_ms =
  fold_events t.ring ~init:() ~f:(fun () ev ->
    if ev.id = event_id && ev.phase <> Resolved && ev.phase <> Escalated then begin
      ev.phase <- Escalated;
      ev.resolved_at <- Some "";
      ev.duration_ms <- Some duration_ms;
      match Hashtbl.find_opt t.per_keeper ev.keeper_name with
      | Some ks ->
          ks.active <- max 0 (ks.active - 1);
          ks.escalated <- ks.escalated + 1
      | None -> ()
    end
  )

(** Step to next cycle. *)
let step_cycle t =
  t.cycle <- t.cycle + 1

(** {1 Build response} *)

let build_response t ~workspace =
  let events = fold_events t.ring ~init:[] ~f:(fun acc ev -> ev :: acc)
               |> List.rev in
  (* Per-keeper stats response *)
  let keeper_stats = Hashtbl.fold (fun name ks acc ->
    let top_error =
      let max_entry = Hashtbl.fold (fun err cnt best ->
        match best with
        | None -> Some (err, cnt)
        | Some (_, bc) -> if cnt > bc then Some (err, cnt) else best
      ) ks.error_counts None in
      Option.map fst max_entry
    in
    let avg_dur =
      if ks.duration_count > 0
      then ks.duration_sum / ks.duration_count
      else 0
    in
    { name;
      total_recoveries = ks.total;
      active_recoveries = ks.active;
      resolved_count = ks.resolved;
      escalated_count = ks.escalated;
      avg_duration_ms = avg_dur;
      top_error;
      last_recovery_at = ks.last_recovery;
    } :: acc
  ) t.per_keeper [] |> List.rev in
  (* Summary *)
  let total_events = fold_events t.ring ~init:0 ~f:(fun acc _ -> acc + 1) in
  let resolved_events = List.filter (fun (ev : recovery_event) ->
    ev.phase = Resolved) events |> List.length in
  let escalated_events = List.filter (fun (ev : recovery_event) ->
    ev.phase = Escalated) events |> List.length in
  let active_events = total_events - resolved_events - escalated_events in
  (* Global avg duration *)
  let total_dur = fold_events t.ring ~init:0 ~f:(fun acc ev ->
    acc + Option.value ev.duration_ms ~default:0) in
  let duration_events = fold_events t.ring ~init:0 ~f:(fun acc ev ->
    acc + (if ev.duration_ms <> None then 1 else 0)) in
  let global_avg = if duration_events > 0 then total_dur / duration_events else 0 in
  let now_iso = "" in
  { events = List.rev events;
    keeper_stats;
    summary = { total_events; active_events;
                resolved_events; escalated_events;
                global_avg_duration_ms = global_avg };
    cycle = t.cycle;
    workspace;
    generated_at = now_iso }