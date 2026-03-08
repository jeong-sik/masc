open Printf

type latency_stats = {
  count: int;
  avg_ms: float;
  p50_ms: float;
  p95_ms: float;
  p99_ms: float;
  min_ms: float;
  max_ms: float;
}

type spawn_info = {
  label: string;
  started_at: float;
}

type snapshot = {
  inflight: int;
  total: int;
  failed: int;
  max_inflight: int;
  oldest_inflight_sec: float option;
  latency: latency_stats;
  last_error: string option;
  updated_at: float;
}

let state_mutex = Eio.Mutex.create ()
let with_lock f = Eio.Mutex.use_rw ~protect:true state_mutex f

let parse_int value =
  try Some (int_of_string value) with _ -> None

let env_int ~name ~default =
  match Sys.getenv_opt name with
  | Some v -> (match parse_int v with Some n -> n | None -> default)
  | None -> default

let max_inflight = env_int ~name:"LLM_MCP_SPAWN_MAX_INFLIGHT" ~default:16
let max_age_sec = env_int ~name:"LLM_MCP_SPAWN_MAX_AGE_SEC" ~default:900

let next_id = ref 0
let active : (int, spawn_info) Hashtbl.t = Hashtbl.create 64
let total = ref 0
let failed = ref 0
let max_inflight_seen = ref 0
let last_error = ref None

let latency_size = 256
let latency_values = Array.make latency_size 0.0
let latency_idx = ref 0
let latency_filled = ref false

let record_latency ms =
  latency_values.(!latency_idx) <- ms;
  latency_idx := (!latency_idx + 1) mod latency_size;
  if !latency_idx = 0 then latency_filled := true

let latency_snapshot () =
  let count = if !latency_filled then latency_size else !latency_idx in
  if count = 0 then
    {
      count = 0;
      avg_ms = 0.0;
      p50_ms = 0.0;
      p95_ms = 0.0;
      p99_ms = 0.0;
      min_ms = 0.0;
      max_ms = 0.0;
    }
  else
    let arr = Array.sub latency_values 0 count in
    Array.sort compare arr;
    let sum = ref 0.0 in
    for i = 0 to count - 1 do
      sum := !sum +. arr.(i)
    done;
    let pick p =
      let idx = int_of_float (p *. float_of_int (count - 1)) in
      arr.(idx)
    in
    {
      count;
      avg_ms = !sum /. float_of_int count;
      p50_ms = pick 0.50;
      p95_ms = pick 0.95;
      p99_ms = pick 0.99;
      min_ms = arr.(0);
      max_ms = arr.(count - 1);
    }

let cleanup_stale now_sec =
  if max_age_sec <= 0 then 0
  else
    let to_remove = ref [] in
    Hashtbl.iter (fun id info ->
      if (now_sec -. info.started_at) > float_of_int max_age_sec then
        to_remove := id :: !to_remove
    ) active;
    List.iter (Hashtbl.remove active) !to_remove;
    List.length !to_remove

let try_start ~label =
  let now_sec = Time_compat.now () in
  with_lock (fun () ->
    let removed = cleanup_stale now_sec in
    if removed > 0 then begin
      failed := !failed + removed;
      last_error := Some "spawn_timeout"
    end;
    let inflight = Hashtbl.length active in
    if max_inflight > 0 && inflight >= max_inflight then begin
      last_error := Some "spawn_inflight_limit";
      Error (sprintf "spawn inflight limit reached (%d)" max_inflight)
    end else begin
      incr next_id;
      let id = !next_id in
      Hashtbl.add active id { label; started_at = now_sec };
      total := !total + 1;
      let inflight' = inflight + 1 in
      if inflight' > !max_inflight_seen then
        max_inflight_seen := inflight';
      Ok id
    end
  )

let finish ~id ~ok ~error =
  let now_sec = Time_compat.now () in
  with_lock (fun () ->
    (match Hashtbl.find_opt active id with
     | Some info ->
         Hashtbl.remove active id;
         record_latency ((now_sec -. info.started_at) *. 1000.0)
     | None -> ());
    if not ok then begin
      failed := !failed + 1;
      last_error := (match error with Some e -> Some e | None -> Some "spawn_failed")
    end
  )

let snapshot () =
  let now_sec = Time_compat.now () in
  with_lock (fun () ->
    let removed = cleanup_stale now_sec in
    if removed > 0 then begin
      failed := !failed + removed;
      last_error := Some "spawn_timeout"
    end;
    let oldest =
      Hashtbl.fold (fun _ info acc ->
        let age = now_sec -. info.started_at in
        match acc with
        | None -> Some age
        | Some v -> Some (max v age)
      ) active None
    in
    {
      inflight = Hashtbl.length active;
      total = !total;
      failed = !failed;
      max_inflight = !max_inflight_seen;
      oldest_inflight_sec = oldest;
      latency = latency_snapshot ();
      last_error = !last_error;
      updated_at = now_sec;
    }
  )

let to_json () =
  let s = snapshot () in
  `Assoc [
    ("inflight", `Int s.inflight);
    ("total", `Int s.total);
    ("failed", `Int s.failed);
    ("max_inflight", `Int s.max_inflight);
    ("oldest_inflight_sec",
     match s.oldest_inflight_sec with
     | None -> `Null
     | Some v -> `Float v);
    ("latency_ms", `Assoc [
      ("count", `Int s.latency.count);
      ("avg", `Float s.latency.avg_ms);
      ("p50", `Float s.latency.p50_ms);
      ("p95", `Float s.latency.p95_ms);
      ("p99", `Float s.latency.p99_ms);
      ("min", `Float s.latency.min_ms);
      ("max", `Float s.latency.max_ms);
    ]);
    ("last_error",
     match s.last_error with
     | None -> `Null
     | Some v -> `String v);
    ("updated_at", `Float s.updated_at);
  ]

let prom_metric name value =
  name ^ " " ^ value ^ "\n"

let to_prometheus_text () =
  let s = snapshot () in
  let oldest =
    match s.oldest_inflight_sec with
    | None -> "0"
    | Some v -> sprintf "%.3f" v
  in
  let latency = s.latency in
  String.concat "" [
    "# HELP llm_spawn_inflight Spawn inflight count\n";
    "# TYPE llm_spawn_inflight gauge\n";
    prom_metric "llm_spawn_inflight" (string_of_int s.inflight);
    "# HELP llm_spawn_total Spawn total count\n";
    "# TYPE llm_spawn_total counter\n";
    prom_metric "llm_spawn_total" (string_of_int s.total);
    "# HELP llm_spawn_failed Spawn failed count\n";
    "# TYPE llm_spawn_failed counter\n";
    prom_metric "llm_spawn_failed" (string_of_int s.failed);
    "# HELP llm_spawn_max_inflight Spawn max inflight observed\n";
    "# TYPE llm_spawn_max_inflight gauge\n";
    prom_metric "llm_spawn_max_inflight" (string_of_int s.max_inflight);
    "# HELP llm_spawn_oldest_inflight_seconds Oldest inflight spawn age\n";
    "# TYPE llm_spawn_oldest_inflight_seconds gauge\n";
    prom_metric "llm_spawn_oldest_inflight_seconds" oldest;
    "# HELP llm_spawn_latency_ms Spawn latency summary (ms)\n";
    "# TYPE llm_spawn_latency_ms gauge\n";
    prom_metric "llm_spawn_latency_ms" (sprintf "%.3f" latency.avg_ms);
    prom_metric "llm_spawn_latency_ms_p50" (sprintf "%.3f" latency.p50_ms);
    prom_metric "llm_spawn_latency_ms_p95" (sprintf "%.3f" latency.p95_ms);
    prom_metric "llm_spawn_latency_ms_p99" (sprintf "%.3f" latency.p99_ms);
  ]
