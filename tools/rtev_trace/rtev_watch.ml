(* rtev_watch DIR PID SECONDS: attach to a running OCaml 5 program's
   runtime-events ring buffer and summarise GC phases, runtime counters and
   lifecycle events per domain over a window that starts after the ring's
   backlog is drained. Stdlib only. *)
module RE = Runtime_events

let ns_of ts = RE.Timestamp.to_int64 ts

type acc = {
  mutable count : int;
  mutable total_ns : int64;
  mutable max_ns : int64;
  mutable samples : int64 array;
  mutable n : int;
}

let new_acc () =
  { count = 0; total_ns = 0L; max_ns = 0L; samples = Array.make 1024 0L; n = 0 }

let push acc d =
  acc.count <- acc.count + 1;
  acc.total_ns <- Int64.add acc.total_ns d;
  if Int64.compare d acc.max_ns > 0 then acc.max_ns <- d;
  if acc.n = Array.length acc.samples then begin
    let bigger = Array.make (2 * acc.n) 0L in
    Array.blit acc.samples 0 bigger 0 acc.n;
    acc.samples <- bigger
  end;
  acc.samples.(acc.n) <- d;
  acc.n <- acc.n + 1

let percentile acc p =
  if acc.n = 0 then 0L
  else begin
    let a = Array.sub acc.samples 0 acc.n in
    Array.sort Int64.compare a;
    a.(min (acc.n - 1) (int_of_float (float_of_int acc.n *. p)))
  end

let find_or_add tbl key mk =
  match Hashtbl.find_opt tbl key with
  | Some v -> v
  | None -> let v = mk () in Hashtbl.replace tbl key v; v

let us ns = Int64.to_float ns /. 1e3
let ms ns = Int64.to_float ns /. 1e6

let () =
  let dir = Sys.argv.(1) in
  let pid = int_of_string Sys.argv.(2) in
  let seconds = float_of_string Sys.argv.(3) in
  let opens : (int * RE.runtime_phase, int64) Hashtbl.t = Hashtbl.create 64 in
  let spans : (int * RE.runtime_phase, acc) Hashtbl.t = Hashtbl.create 64 in
  let counters : (int * RE.runtime_counter, int * int) Hashtbl.t = Hashtbl.create 64 in
  let lifecycles : (int * RE.lifecycle, int) Hashtbl.t = Hashtbl.create 16 in
  let lost = ref 0 in
  let handler_begins : (int, int64 list) Hashtbl.t = Hashtbl.create 16 in
  let barriers : (int * int64 * int64) list ref = ref [] in
  let runtime_begin domain ts phase =
    (match RE.runtime_phase_name phase with
     | "stw_handler" ->
       let l = Option.value ~default:[] (Hashtbl.find_opt handler_begins domain) in
       Hashtbl.replace handler_begins domain (ns_of ts :: l)
     | _ -> ());
    Hashtbl.replace opens (domain, phase) (ns_of ts) in
  let runtime_end domain ts phase =
    match Hashtbl.find_opt opens (domain, phase) with
    | None -> ()
    | Some t0 ->
      Hashtbl.remove opens (domain, phase);
      (match RE.runtime_phase_name phase with
       | "stw_api_barrier" -> barriers := (domain, t0, ns_of ts) :: !barriers
       | _ -> ());
      push (find_or_add spans (domain, phase) new_acc) (Int64.sub (ns_of ts) t0)
  in
  let runtime_counter domain _ts counter value =
    let sum, n = Option.value ~default:(0, 0) (Hashtbl.find_opt counters (domain, counter)) in
    Hashtbl.replace counters (domain, counter) (sum + value, n + 1)
  in
  let lifecycle domain _ts event _arg =
    let n = Option.value ~default:0 (Hashtbl.find_opt lifecycles (domain, event)) in
    Hashtbl.replace lifecycles (domain, event) (n + 1)
  in
  let lost_events _domain n = lost := !lost + n in
  let callbacks =
    RE.Callbacks.create ~runtime_begin ~runtime_end ~runtime_counter ~lifecycle ~lost_events ()
  in
  let cursor = RE.create_cursor (Some (dir, pid)) in
  let drain = RE.Callbacks.create () in
  let backlog = ref 0 in
  let rec drain_all () =
    let n = RE.read_poll cursor drain None in
    if n > 0 then (backlog := !backlog + n; drain_all ())
  in
  drain_all ();
  let t_start = Unix.gettimeofday () in
  let events = ref 0 in
  while Unix.gettimeofday () -. t_start < seconds do
    events := !events + RE.read_poll cursor callbacks None;
    Unix.sleepf 0.02
  done;
  let window = Unix.gettimeofday () -. t_start in
  Printf.printf "pid=%d dir=%s window_s=%.1f backlog_drained=%d events=%d lost=%d\n\n"
    pid dir window !backlog !events !lost;
  (* phases aggregated across domains *)
  let by_phase : (RE.runtime_phase, acc) Hashtbl.t = Hashtbl.create 64 in
  let domains = Hashtbl.create 16 in
  Hashtbl.iter
    (fun (domain, phase) acc ->
      Hashtbl.replace domains domain ();
      let merged = find_or_add by_phase phase new_acc in
      for i = 0 to acc.n - 1 do push merged acc.samples.(i) done)
    spans;
  let rows = Hashtbl.fold (fun phase acc l -> (phase, acc) :: l) by_phase [] in
  let rows = List.sort (fun (_, a) (_, b) -> Int64.compare b.total_ns a.total_ns) rows in
  Printf.printf "%-34s %8s %7s %10s %9s %9s %9s %9s\n"
    "phase" "count" "per_s" "total_ms" "mean_us" "p50_us" "p99_us" "max_us";
  List.iter
    (fun (phase, acc) ->
      Printf.printf "%-34s %8d %7.1f %10.1f %9.1f %9.1f %9.1f %9.1f\n"
        (RE.runtime_phase_name phase) acc.count
        (float_of_int acc.count /. window) (ms acc.total_ns)
        (us acc.total_ns /. float_of_int (max 1 acc.count))
        (us (percentile acc 0.5)) (us (percentile acc 0.99)) (us acc.max_ns))
    rows;
  (* per-domain view of the phases that decide stop-the-world cost *)
  let key_phases =
    List.filter_map
      (fun (phase, _) ->
        match RE.runtime_phase_name phase with
        | "minor" | "stw_leader" | "stw_api_barrier" | "stw_handler" | "major_slice"
        | "major" | "major_gc_stw" | "minor_leave_barrier" | "interrupt_remote"
        | "empty_minor" | "domain_condition_wait" ->
          Some phase
        | _ -> None)
      rows
  in
  let domain_list = List.sort compare (Hashtbl.fold (fun d () l -> d :: l) domains []) in
  Printf.printf "\nper-domain count/total_ms/max_ms\n%-8s" "domain";
  List.iter (fun p -> Printf.printf " %22s" (RE.runtime_phase_name p)) key_phases;
  print_newline ();
  List.iter
    (fun d ->
      Printf.printf "%-8d" d;
      List.iter
        (fun p ->
          match Hashtbl.find_opt spans (d, p) with
          | None -> Printf.printf " %22s" "-"
          | Some a -> Printf.printf " %6d/%7.1f/%6.1f" a.count (ms a.total_ns) (ms a.max_ns))
        key_phases;
      print_newline ())
    domain_list;
  (* counters, summed over the window, per domain *)
  Printf.printf "\ncounters (domain counter sum events)\n";
  let crows = Hashtbl.fold (fun (d, c) (sum, n) l -> (d, c, sum, n) :: l) counters [] in
  let crows = List.sort (fun (d1, c1, _, _) (d2, c2, _, _) -> compare (RE.runtime_counter_name c1, d1) (RE.runtime_counter_name c2, d2)) crows in
  List.iter
    (fun (d, c, sum, n) -> Printf.printf "%-8d %-40s %14d %8d\n" d (RE.runtime_counter_name c) sum n)
    crows;
  (* For each stop-the-world the leader waited for (its stw_api_barrier
     span [t0, t1]), the domain whose stw_handler began last inside the span
     is the one every other domain waited on. *)
  let late : (int, acc) Hashtbl.t = Hashtbl.create 16 in
  List.iter
    (fun (leader, t0, t1) ->
      let worst = ref None in
      Hashtbl.iter
        (fun d begins ->
          if d <> leader then
            List.iter
              (fun b ->
                if Int64.compare b t0 >= 0 && Int64.compare b (Int64.add t1 2_000_000L) <= 0 then
                  match !worst with
                  | Some (_, wb) when Int64.compare wb b >= 0 -> ()
                  | _ -> worst := Some (d, b))
              begins)
        handler_begins;
      match !worst with
      | None -> ()
      | Some (d, b) -> push (find_or_add late d new_acc) (Int64.sub b t0))
    !barriers;
  Printf.printf "\nstw late arrivals: domain that reached the barrier last (count total_ms p50_ms max_ms)\n";
  let lrows = Hashtbl.fold (fun d a l -> (d, a) :: l) late [] in
  List.iter
    (fun (d, a) ->
      Printf.printf "%-8d %6d %9.1f %8.2f %8.2f\n" d a.count (ms a.total_ns) (ms (percentile a 0.5)) (ms a.max_ns))
    (List.sort (fun (_, a) (_, b) -> Int64.compare b.total_ns a.total_ns) lrows);
  Printf.printf "\nlifecycle (domain event count)\n";
  Hashtbl.iter
    (fun (d, e) n -> Printf.printf "%-8d %-24s %6d\n" d (RE.lifecycle_name e) n)
    lifecycles;
  RE.free_cursor cursor
