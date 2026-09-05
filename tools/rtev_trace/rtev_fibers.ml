(* rtev_fibers DIR PID SECONDS: attach to a running Eio program's runtime-events
   ring and report, per domain, how long each fiber ran without giving the
   scheduler back, what it resumed from and what it suspended on, and how much
   of each long run was GC. Eio emits fiber switch / suspend events through
   Runtime_events whenever the ring is on; masc turns it on at boot. *)
module RE = Runtime_events
module EE = Eio_runtime_events

let ns_of = RE.Timestamp.to_int64
let ms ns = Int64.to_float ns /. 1e6

type run = {
  domain : int;
  fiber : int;
  start_ns : int64;
  end_ns : int64;
  resumed_from : string;
  ended_by : string;
  turn_depth : int;
}

type dstate = {
  mutable cur : (int * int64 * string) option;
  mutable turn_depth : int;
  mutable long_runs : run list; (* runs of at least [keep_ns] *)
  mutable run_count : int;
  mutable run_total_ns : int64;
  mutable run_max_ns : int64;
  mutable over_10 : int;
  mutable over_50 : int;
  mutable over_100 : int;
  mutable gc : (int64 * int64) list;
  gc_open : (RE.runtime_phase, int64) Hashtbl.t;
}

let keep_ns = 1_000_000L

let counted_gc_phase name =
  match name with
  | "empty_minor" | "stw_handler" | "major" | "major_finish_sweeping"
  | "major_finish_marking" | "stw_api_barrier" | "minor" ->
    true
  | _ -> false

let union_ms intervals a b =
  let clipped =
    List.filter_map
      (fun (x, y) ->
        let x = max x a and y = min y b in
        if Int64.compare y x > 0 then Some (x, y) else None)
      intervals
  in
  let sorted = List.sort compare clipped in
  let rec go acc cur = function
    | [] -> (match cur with None -> acc | Some (x, y) -> Int64.add acc (Int64.sub y x))
    | (x, y) :: rest -> (
      match cur with
      | None -> go acc (Some (x, y)) rest
      | Some (cx, cy) ->
        if Int64.compare x cy <= 0 then go acc (Some (cx, max cy y)) rest
        else go (Int64.add acc (Int64.sub cy cx)) (Some (x, y)) rest)
  in
  ms (go 0L None sorted)

let () =
  let dir = Sys.argv.(1) in
  let pid = int_of_string Sys.argv.(2) in
  let seconds = float_of_string Sys.argv.(3) in
  let states : (int, dstate) Hashtbl.t = Hashtbl.create 16 in
  let state d =
    match Hashtbl.find_opt states d with
    | Some s -> s
    | None ->
      let s =
        { cur = None; turn_depth = 0; long_runs = []; run_count = 0; run_total_ns = 0L;
          run_max_ns = 0L; over_10 = 0; over_50 = 0; over_100 = 0; gc = [];
          gc_open = Hashtbl.create 8 }
      in
      Hashtbl.replace states d s;
      s
  in
  let last_reason : (int, string) Hashtbl.t = Hashtbl.create 4096 in
  let names : (int, string) Hashtbl.t = Hashtbl.create 256 in
  let parent : (int, int) Hashtbl.t = Hashtbl.create 4096 in
  (* Who was running when an object was created: [Create] is emitted on the
     creating fiber's domain, so the fiber current there is the creator. *)
  let created_by : (int, int) Hashtbl.t = Hashtbl.create 4096 in
  let cc_kind : (int, string) Hashtbl.t = Hashtbl.create 4096 in
  let lost = ref 0 in
  let close d ts ended_by =
    let s = state d in
    match s.cur with
    | None -> ()
    | Some (fiber, start_ns, resumed_from) ->
      s.cur <- None;
      let dur = Int64.sub ts start_ns in
      s.run_count <- s.run_count + 1;
      s.run_total_ns <- Int64.add s.run_total_ns dur;
      if Int64.compare dur s.run_max_ns > 0 then s.run_max_ns <- dur;
      if Int64.compare dur 10_000_000L >= 0 then s.over_10 <- s.over_10 + 1;
      if Int64.compare dur 50_000_000L >= 0 then s.over_50 <- s.over_50 + 1;
      if Int64.compare dur 100_000_000L >= 0 then s.over_100 <- s.over_100 + 1;
      if Int64.compare dur keep_ns >= 0 then
        s.long_runs <-
          { domain = d; fiber; start_ns; end_ns = ts; resumed_from; ended_by;
            turn_depth = s.turn_depth }
          :: s.long_runs
  in
  let eio d ts (ev : EE.event) =
    let ts = ns_of ts in
    match ev with
    | `Fiber id ->
      close d ts "switch";
      let resumed_from =
        Option.value ~default:"(first run)" (Hashtbl.find_opt last_reason id)
      in
      (state d).cur <- Some (id, ts, resumed_from)
    | `Suspend_fiber reason ->
      (match (state d).cur with
       | Some (id, _, _) -> Hashtbl.replace last_reason id reason
       | None -> ());
      close d ts reason
    | `Suspend_domain RE.Type.Begin -> close d ts "domain idle"
    | `Exit_fiber _ -> close d ts "exit"
    | `Create (id, `Fiber_in cc) ->
      Hashtbl.replace parent id cc;
      (match (state d).cur with
       | Some (creator, _, _) -> Hashtbl.replace created_by id creator
       | None -> ())
    | `Create (id, `Cc ty) ->
      Hashtbl.replace cc_kind id (EE.cc_ty_to_string ty);
      (match (state d).cur with
       | Some (creator, _, _) -> Hashtbl.replace created_by id creator
       | None -> ())
    | `Name (id, n) -> Hashtbl.replace names id n
    | _ -> ()
  in
  let runtime_begin d ts phase =
    if counted_gc_phase (RE.runtime_phase_name phase) then
      Hashtbl.replace (state d).gc_open phase (ns_of ts)
  in
  let runtime_end d ts phase =
    let s = state d in
    match Hashtbl.find_opt s.gc_open phase with
    | None -> ()
    | Some b ->
      Hashtbl.remove s.gc_open phase;
      s.gc <- (b, ns_of ts) :: s.gc
  in
  let user_span d _ts ev v =
    if String.equal (RE.User.name ev) "masc.turn" then begin
      let s = state d in
      match v with
      | RE.Type.Begin -> s.turn_depth <- s.turn_depth + 1
      | RE.Type.End -> s.turn_depth <- max 0 (s.turn_depth - 1)
    end
  in
  let lost_events _d n = lost := !lost + n in
  let callbacks =
    RE.Callbacks.create ~runtime_begin ~runtime_end ~lost_events ()
    |> EE.add_callbacks eio
    |> RE.Callbacks.add_user_event RE.Type.span user_span
  in
  let cursor = RE.create_cursor (Some (dir, pid)) in
  let drain = RE.Callbacks.create () in
  let rec drain_all () = if RE.read_poll cursor drain None > 0 then drain_all () in
  drain_all ();
  let t_start = Unix.gettimeofday () in
  let events = ref 0 in
  while Unix.gettimeofday () -. t_start < seconds do
    events := !events + RE.read_poll cursor callbacks None;
    Unix.sleepf 0.02
  done;
  let window = Unix.gettimeofday () -. t_start in
  Printf.printf "pid=%d window_s=%.1f events=%d lost=%d\n\n" pid window !events !lost;
  let domains = List.sort compare (Hashtbl.fold (fun d _ l -> d :: l) states []) in
  Printf.printf "%-7s %9s %10s %8s %8s %8s %8s %9s\n" "domain" "runs" "run_ms" "busy%" ">=10ms" ">=50ms" ">=100ms" "max_ms";
  List.iter
    (fun d ->
      let s = state d in
      Printf.printf "%-7d %9d %10.1f %7.1f%% %8d %8d %8d %9.1f\n" d s.run_count
        (ms s.run_total_ns)
        (100.0 *. ms s.run_total_ns /. (window *. 1000.0))
        s.over_10 s.over_50 s.over_100 (ms s.run_max_ns))
    domains;
  let label_of fiber =
    match Hashtbl.find_opt names fiber with
    | Some n -> n
    | None -> (
      match Hashtbl.find_opt parent fiber with
      | Some cc -> (
        match Hashtbl.find_opt names cc with
        | Some n -> "cc:" ^ n
        | None -> Printf.sprintf "cc#%d" cc)
      | None -> "-")
  in
  (* fiber <- its cc (kind, name) <- the fiber that created it <- ... *)
  let ancestry fiber =
    let buf = Buffer.create 128 in
    let rec go fiber depth =
      if depth < 6 then begin
        match Hashtbl.find_opt parent fiber with
        | None -> ()
        | Some cc ->
          let kind = Option.value ~default:"?" (Hashtbl.find_opt cc_kind cc) in
          let name = Option.value ~default:"" (Hashtbl.find_opt names cc) in
          Buffer.add_string buf
            (Printf.sprintf " <- cc#%d(%s%s)" cc kind (if name = "" then "" else ":" ^ name));
          (match Hashtbl.find_opt created_by cc with
           | None -> ()
           | Some creator ->
             Buffer.add_string buf (Printf.sprintf " <- fiber %d" creator);
             (match Hashtbl.find_opt names creator with
              | Some n -> Buffer.add_string buf (Printf.sprintf "(%s)" n)
              | None -> ());
             go creator (depth + 1))
      end
    in
    go fiber 0;
    Buffer.contents buf
  in
  let all_runs = List.concat_map (fun d -> (state d).long_runs) domains in
  let by_len =
    List.sort
      (fun a b -> Int64.compare (Int64.sub b.end_ns b.start_ns) (Int64.sub a.end_ns a.start_ns))
      all_runs
  in
  Printf.printf "\nlongest uninterrupted fiber runs (domain fiber ms gc_ms turn resumed_from -> ended_by [label])\n";
  List.iteri
    (fun i r ->
      if i < 40 then begin
        let dur = Int64.sub r.end_ns r.start_ns in
        let gc = union_ms (state r.domain).gc r.start_ns r.end_ns in
        Printf.printf "%-3d %-7d %8.1f %6.1f %4d %-34s -> %-34s [%s]%s\n" r.domain r.fiber (ms dur) gc
          r.turn_depth r.resumed_from r.ended_by (label_of r.fiber) (ancestry r.fiber)
      end)
    by_len;
  Printf.printf "\ndomain 0 runs >= 10ms grouped by (resumed_from -> ended_by): count total_ms max_ms\n";
  let groups : (string * string, int * int64 * int64) Hashtbl.t = Hashtbl.create 64 in
  List.iter
    (fun r ->
      if r.domain = 0 then begin
        let dur = Int64.sub r.end_ns r.start_ns in
        if Int64.compare dur 10_000_000L >= 0 then begin
          let c, t, m =
            Option.value ~default:(0, 0L, 0L) (Hashtbl.find_opt groups (r.resumed_from, r.ended_by))
          in
          Hashtbl.replace groups (r.resumed_from, r.ended_by) (c + 1, Int64.add t dur, max m dur)
        end
      end)
    all_runs;
  let grows = Hashtbl.fold (fun k v l -> (k, v) :: l) groups [] in
  List.iter
    (fun ((a, b), (c, t, m)) -> Printf.printf "%5d %9.1f %8.1f  %s -> %s\n" c (ms t) (ms m) a b)
    (List.sort (fun (_, (_, t1, _)) (_, (_, t2, _)) -> Int64.compare t2 t1) grows);
  RE.free_cursor cursor
