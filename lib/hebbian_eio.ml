(** MASC Hebbian Learning - Collaboration Pattern Learning (Eio Native)

    "Agents that fire together, wire together"

    Pure synchronous operations (direct-style).
    Compatible with Eio direct-style concurrency.

    Tracks successful collaboration patterns:
    - Strengthen connections on successful tasks
    - Weaken connections on failures
    - Consolidate (decay) old connections

    Storage: .masc/synapses/graph.json
*)

(** Config type alias *)
type config = Coord_utils.config

(** Synapse between two agents *)
type synapse = {
  from_agent: string;
  to_agent: string;
  weight: float;        (* 0.0-1.0, higher = stronger connection *)
  success_count: int;   (* Number of successful collaborations *)
  failure_count: int;   (* Number of failed collaborations *)
  last_updated: float;  (* Unix timestamp *)
  created_at: float;
  weight_history: (float * float) list;
    (* (ts, weight) newest first, capped at [history_cap]. Enables
       sparkline visualization of learning direction (strengthening
       vs weakening over time). *)
}

(** Cap for [weight_history]. Newer entries evict older ones.

    30 is arbitrary — not derived from any learning-theory argument. It
    roughly matches the dashboard sparkline pixel budget (80 px wide,
    ~2.7 px per point) so the polyline renders with legible segments,
    but the number was picked first and the rationale came after. Raise
    it if you want longer trajectories; the JSON payload grows linearly. *)
let history_cap = 30

(** Prepend [(ts, w)] to [history] and trim to [history_cap].
    Back-to-back writes at the same fractional tick produce separate
    entries — this preserves trajectory resolution and keeps the
    append deterministic (no dependence on clock granularity). *)
let append_history ~ts ~w history =
  let rec take n xs = match n, xs with
    | 0, _ | _, [] -> []
    | n, x :: rest -> x :: take (n - 1) rest
  in
  take history_cap ((ts, w) :: history)

(** Synapse graph *)
type synapse_graph = {
  synapses: synapse list;
  last_consolidation: float;
}

(** Learning parameters *)
type learning_params = {
  strengthen_rate: float;  (* How much to increase on success, default 0.1 *)
  weaken_rate: float;      (* How much to decrease on failure, default 0.05 *)
  decay_rate: float;       (* Daily decay rate for consolidation, default 0.01 *)
  min_weight: float;       (* Minimum weight before pruning, default 0.05 *)
  max_weight: float;       (* Maximum weight, default 1.0 *)
}

let default_params () = {
  strengthen_rate = Level2_config.Hebbian.learning_rate ();
  weaken_rate = Level2_config.Hebbian.learning_rate ();  (* Symmetric *)
  decay_rate = Level2_config.Hebbian.decay_rate ();
  min_weight = Level2_config.Hebbian.min_weight ();
  max_weight = Level2_config.Hebbian.max_weight ();
}

(** Get synapses file path *)
let synapses_file (config : config) =
  Filename.concat config.Coord_utils.base_path ".masc/synapses/graph.json"

(** Get lock file path *)
let synapses_lock_file (config : config) =
  synapses_file config ^ ".lock"

(** Ensure synapses directory exists *)
let ensure_synapses_dir config =
  let synapses_dir = Filename.concat (Common.masc_dir_from_base_path ~base_path:config.Coord_utils.base_path) "synapses" in
  Fs_compat.mkdir_p synapses_dir

(** Lock contention metrics *)
let lock_acquisitions = Atomic.make 0
let lock_total_wait_ms = Atomic.make 0.0
let lock_max_wait_ms = Atomic.make 0.0

let rec cas_float atomic f =
  let old = Atomic.get atomic in
  if not (Atomic.compare_and_set atomic old (f old)) then cas_float atomic f

(** Get lock statistics *)
let get_lock_stats () =
  let avg_wait = if (Atomic.get lock_acquisitions) = 0 then 0.0
    else Atomic.get lock_total_wait_ms /. float_of_int (Atomic.get lock_acquisitions) in
  ((Atomic.get lock_acquisitions), avg_wait, Atomic.get lock_max_wait_ms)

(** Reset lock statistics *)
let reset_lock_stats () =
  Atomic.set lock_acquisitions 0;
  Atomic.set lock_total_wait_ms 0.0;
  Atomic.set lock_max_wait_ms 0.0

(** Run a blocking op in systhread when Eio context is available *)
let run_blocking_op f = Eio_guard.run_in_systhread f

(** Transactional lock for graph operations.
    Uses F_TLOCK (non-blocking) from a systhread so the Eio scheduler stays
    free.  The body [f] runs in the main Eio context (not in the systhread)
    so it can use Eio.Path / Fs_compat safely. *)
let with_graph_lock config f =
  ensure_synapses_dir config;
  let lock_file = synapses_lock_file config in
  let start_time = Time_compat.now () in
  (* Acquire lock in systhread (non-blocking F_TLOCK + retry) *)
  let fd = run_blocking_op (fun () ->
    File_lock_eio.acquire_flock_retry ~lock_path:lock_file
      ~mode:[Unix.O_WRONLY; Unix.O_CREAT] ~perm:0o600
      ~caller:"hebbian_eio" ()
  ) in
  (* Record lock metrics *)
  let wait_ms = (Time_compat.now () -. start_time) *. 1000.0 in
  Atomic.incr lock_acquisitions;
  cas_float lock_total_wait_ms (fun v -> v +. wait_ms);
  cas_float lock_max_wait_ms (fun v -> Float.max v wait_ms);
  let warn_threshold = Level2_config.Lock.warn_threshold_ms () in
  if wait_ms > warn_threshold then
    Log.Misc.warn "Lock contention detected: %.1fms wait (threshold: %.0fms)" wait_ms warn_threshold;
  (* Run body in Eio context, release lock in systhread *)
  Common.protect ~module_name:"hebbian_eio" ~finally_label:"finalizer"
    ~finally:(fun () ->
      run_blocking_op (fun () ->
        (try Unix.lockf fd Unix.F_ULOCK 0 with Unix.Unix_error _ -> ());
        Unix.close fd))
    f

(** Synapse to JSON *)
let synapse_to_json (s : synapse) : Yojson.Safe.t =
  let history_json =
    `List (List.map (fun (ts, w) -> `List [`Float ts; `Float w]) s.weight_history)
  in
  `Assoc [
    ("from_agent", `String s.from_agent);
    ("to_agent", `String s.to_agent);
    ("weight", `Float s.weight);
    ("success_count", `Int s.success_count);
    ("failure_count", `Int s.failure_count);
    ("last_updated", `Float s.last_updated);
    ("created_at", `Float s.created_at);
    ("weight_history", history_json);
  ]

(** Parse [weight_history] from JSON, tolerating missing field (backward
    compat with graph.json files written before this field existed). *)
let weight_history_of_json json =
  let open Yojson.Safe.Util in
  match member "weight_history" json with
  | `Null -> []
  | `List items ->
    List.filter_map (fun item ->
      match item with
      | `List [`Float ts; `Float w] -> Some (ts, w)
      | `List [`Int ts; `Float w] -> Some (float_of_int ts, w)
      | _ -> None
    ) items
  | _ -> []

(** Synapse from JSON. [weight_history] defaults to [] for files written
    before the field was introduced. *)
let synapse_of_json json : synapse option =
  let open Yojson.Safe.Util in
  try
    Some {
      from_agent = json |> member "from_agent" |> to_string;
      to_agent = json |> member "to_agent" |> to_string;
      weight = json |> member "weight" |> to_float;
      success_count = json |> member "success_count" |> to_int;
      failure_count = json |> member "failure_count" |> to_int;
      last_updated = json |> member "last_updated" |> to_float;
      created_at = json |> member "created_at" |> to_float;
      weight_history = weight_history_of_json json;
    }
  with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
    Log.Misc.error "Failed to parse synapse: %s" (Printexc.to_string exn);
    None

(** Graph to JSON *)
let graph_to_json (g : synapse_graph) : Yojson.Safe.t =
  `Assoc [
    ("synapses", `List (List.map synapse_to_json g.synapses));
    ("last_consolidation", `Float g.last_consolidation);
  ]

(** Graph from JSON *)
let graph_of_json json : synapse_graph =
  let open Yojson.Safe.Util in
  try
    let synapses = json |> member "synapses" |> to_list
      |> List.filter_map synapse_of_json in
    let last_consolidation = json |> member "last_consolidation" |> to_float in
    { synapses; last_consolidation }
  with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
    Log.Misc.error "Failed to parse graph: %s" (Printexc.to_string exn);
    { synapses = []; last_consolidation = 0.0 }

(** Load synapse graph - synchronous *)
let load_graph config : synapse_graph =
  let file = synapses_file config in
  if not (Sys.file_exists file) then
    { synapses = []; last_consolidation = 0.0 }
  else
    try
      let content = Fs_compat.load_file file in
      let json = Yojson.Safe.from_string content in
      graph_of_json json
    with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
      Log.Misc.error "Failed to load graph from %s: %s" file (Printexc.to_string exn);
      { synapses = []; last_consolidation = 0.0 }

(** Save synapse graph - synchronous *)
let save_graph config (graph : synapse_graph) : unit =
  ensure_synapses_dir config;
  let file = synapses_file config in
  let json = graph_to_json graph in
  let content = Yojson.Safe.pretty_to_string json in
  Fs_compat.save_file file content

(** Find synapse between two agents - pure *)
let find_synapse graph ~from_agent ~to_agent : synapse option =
  List.find_opt (fun s ->
    s.from_agent = from_agent && s.to_agent = to_agent
  ) graph.synapses

(** Create new synapse - pure. Seeds [weight_history] with the initial
    neutral weight so sparklines have a reference point from tick 0. *)
let create_synapse ~from_agent ~to_agent : synapse =
  let now = Time_compat.now () in
  {
    from_agent;
    to_agent;
    weight = 0.5;  (* Start at neutral *)
    success_count = 0;
    failure_count = 0;
    last_updated = now;
    created_at = now;
    weight_history = [(now, 0.5)];
  }

(** Update synapse in graph - pure *)
let update_synapse graph (synapse : synapse) : synapse_graph =
  let updated = synapse :: (List.filter (fun s ->
    not (s.from_agent = synapse.from_agent && s.to_agent = synapse.to_agent)
  ) graph.synapses) in
  { graph with synapses = updated }

(** Strengthen connection - synchronous *)
let strengthen config ?params ~from_agent ~to_agent () : unit =
  let params = Option.value params ~default:(default_params ()) in
  with_graph_lock config (fun () ->
    let graph = load_graph config in
    let synapse = match find_synapse graph ~from_agent ~to_agent with
      | Some s -> s
      | None -> create_synapse ~from_agent ~to_agent
    in
    let new_weight = min params.max_weight (synapse.weight +. params.strengthen_rate) in
    let now = Time_compat.now () in
    let updated = {
      synapse with
      weight = new_weight;
      success_count = synapse.success_count + 1;
      last_updated = now;
      weight_history = append_history ~ts:now ~w:new_weight synapse.weight_history;
    } in
    let new_graph = update_synapse graph updated in
    save_graph config new_graph
  )

(** Weaken connection - synchronous *)
let weaken config ?params ~from_agent ~to_agent () : unit =
  let params = Option.value params ~default:(default_params ()) in
  with_graph_lock config (fun () ->
    let graph = load_graph config in
    match find_synapse graph ~from_agent ~to_agent with
    | None -> ()  (* No synapse to weaken *)
    | Some synapse ->
      let new_weight = max 0.0 (synapse.weight -. params.weaken_rate) in
      let now = Time_compat.now () in
      let updated = {
        synapse with
        weight = new_weight;
        failure_count = synapse.failure_count + 1;
        last_updated = now;
        weight_history = append_history ~ts:now ~w:new_weight synapse.weight_history;
      } in
      let new_graph = update_synapse graph updated in
      save_graph config new_graph
  )

(** Get preferred collaboration partner - synchronous *)
let get_preferred_partner config ~agent_id : string option =
  let graph = load_graph config in
  let outgoing = List.filter (fun s -> s.from_agent = agent_id) graph.synapses in
  match outgoing with
  | [] -> None
  | _ ->
    let sorted = List.sort (fun a b -> compare b.weight a.weight) outgoing in
    match sorted with
    | best :: _ -> Some best.to_agent
    | [] -> None (* unreachable but type-safe *)

(** Consolidate - apply decay to old connections - synchronous.

    Must hold [with_graph_lock] around the read-modify-write cycle: a
    concurrent [strengthen]/[weaken] that observes the same pre-decay
    graph, writes its updated weight under the lock, then has its
    write silently clobbered when consolidate's save lands on the
    stale snapshot. Without the lock, consolidate can roll back any
    strengthen/weaken that races it — an invariant violation for
    hebbian learning. *)
let consolidate config ?params ~decay_after_days () : int =
  let params = Option.value params ~default:(default_params ()) in
  with_graph_lock config (fun () ->
    let graph = load_graph config in
    let now = Time_compat.now () in
    let cutoff = now -. Masc_time_constants.days_to_seconds decay_after_days in

    let (decayed, pruned_count) = List.fold_left (fun (acc, count) synapse ->
      if synapse.last_updated < cutoff then
        (* Apply decay *)
        let days_since = (now -. synapse.last_updated) /. Masc_time_constants.day in
        let decay = params.decay_rate *. days_since in
        let new_weight = max 0.0 (synapse.weight -. decay) in
        if new_weight < params.min_weight then
          (* Prune weak synapse *)
          (acc, count + 1)
        else
          let updated = {
            synapse with
            weight = new_weight;
            last_updated = now;
            weight_history = append_history ~ts:now ~w:new_weight synapse.weight_history;
          } in
          (updated :: acc, count)
      else
        (synapse :: acc, count)
    ) ([], 0) graph.synapses in

    let new_graph = { synapses = decayed; last_consolidation = now } in
    save_graph config new_graph;
    pruned_count
  )

(** Get collaboration graph as visualization data - synchronous *)
let get_graph_data config : (synapse list * string list) =
  let graph = load_graph config in
  let agents = List.sort_uniq String.compare (
    List.concat_map (fun s -> [s.from_agent; s.to_agent]) graph.synapses
  ) in
  (graph.synapses, agents)

(** #9876: consolidation scheduler.

    The evidence in #9876 is that [last_consolidation = 0.0] on a live
    graph with 37 synapses — consolidation had never run, not just
    "not recently". Root cause: {!consolidate} has zero production
    callers. The fiber below closes the loop so decay + pruning
    actually execute on a cadence, and the graph stops being
    write-only.

    Design follows {!Tool_metrics_persist.start_flush_fiber} (the
    canonical periodic-fiber pattern in this codebase): fork on the
    startup switch, loop with [Eio.Time.sleep], catch non-Cancel
    exceptions per-iteration so a transient IO failure cannot kill
    the fiber.

    Metrics (for #9520 telemetry discipline):
    - [masc_hebbian_consolidate_total{outcome=ok\|error}]
    - [masc_hebbian_consolidate_pruned_total] — counts pruned synapses
    - [masc_hebbian_consolidate_duration_seconds] — histogram

    The fiber is cancelable via the passed switch. Shutdown is a
    passive cancellation — we do NOT run a final consolidation on
    shutdown because pruning on an unclean exit is riskier than
    skipping one cycle. *)
let start_consolidation_fiber ~sw ~clock config =
  let interval_s = Level2_config.Hebbian.consolidation_interval_s () in
  let decay_after_days =
    int_of_float (Level2_config.Hebbian.decay_after_days ())
  in
  Log.Coord.info
    "hebbian: consolidation fiber starting (interval=%.0fs decay_after=%dd)"
    interval_s decay_after_days;
  Eio.Fiber.fork ~sw (fun () ->
    let rec loop () =
      Eio.Time.sleep clock interval_s;
      let t0 = Time_compat.now () in
      (try
         let pruned = consolidate config ~decay_after_days () in
         let elapsed = Time_compat.now () -. t0 in
         Prometheus.inc_counter
           "masc_hebbian_consolidate_total"
           ~labels:[("outcome", "ok")] ();
         if pruned > 0 then
           Prometheus.inc_counter
             "masc_hebbian_consolidate_pruned_total"
             ~delta:(Float.of_int pruned) ();
         Prometheus.observe_histogram
           "masc_hebbian_consolidate_duration_seconds" elapsed;
         if pruned > 0 then
           Log.Coord.info
             "hebbian: consolidated graph, pruned=%d duration=%.3fs"
             pruned elapsed
         else
           Log.Coord.debug
             "hebbian: consolidated graph, pruned=0 duration=%.3fs"
             elapsed
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
         Prometheus.inc_counter
           "masc_hebbian_consolidate_total"
           ~labels:[("outcome", "error")] ();
         Log.Coord.error
           "hebbian: consolidation iteration failed: %s"
           (Printexc.to_string exn));
      loop ()
    in
    loop ())
