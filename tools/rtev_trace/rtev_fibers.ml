(* rtev_fibers DIR PID SECONDS: attach to a running Eio program's runtime-events
   ring and report, per domain, how long each fiber ran without giving the
   scheduler back, what it resumed from and what it suspended on, and how much
   of each long run was GC. Eio emits fiber switch / suspend events through
   Runtime_events whenever the ring is on; masc turns it on at boot. *)
module RE = Runtime_events
module EE = Eio_runtime_events
type collection_end = Stop_requested | Observation_deadline

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

(* One traced section; see {!Rtev_span}. [run_ns] and [waits] sum, over the
   section's fibers, the time they ran, waited on something, and waited for
   the domain. They split the wall time only when one fiber runs at a time. *)
type span = Rtev_span.span = {
  span_name : string;
  span_domain : int;
  enter_ns : int64;
  mutable exit_ns : int64 option;
  mutable run_ns : int64;
  waits : (string, int64) Hashtbl.t;
  parent : span option;
}

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
  let control = Sys.getenv_opt "MASC_RTEV_CONTROL_DIR" in
  let mark name stamp = match control with
    | None -> ()
    | Some dir -> Out_channel.with_open_text (Filename.concat dir name)
        (fun out -> Printf.fprintf out "%.9f\n" stamp) in
  let stopping () = match control with
    | None -> false
    | Some dir -> Sys.file_exists (Filename.concat dir "stop") in
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
  (* The name of the newest named switch each fiber opened. Eio names only
     cancellation contexts ([Switch.run ~name]), never fibers, so a fiber
     that opens a named switch at the top of its body is labelled by it. *)
  let opened : (int, string) Hashtbl.t = Hashtbl.create 4096 in
  (* The first named switch each fiber opened: masc names its long-lived
     fibers at the top of their body, and Eio names its own internal
     switches ([both], [with_open_in], [Buf_write.with_flow]) later, so the
     first name is the code and the newest is what the fiber was doing. *)
  let opened_first : (int, string) Hashtbl.t = Hashtbl.create 4096 in
  let book = Rtev_span.create () in
  let suspended_at : (int, string * int64) Hashtbl.t = Hashtbl.create 4096 in
  let finished_spans = ref [] in
  (* Locks: [Try_get] then [Get] when a fiber waits for one, [Get] alone when
     it takes one free, [Put] when it lets go. Mutexes are created at module
     initialisation, before this attaches, so they are known only by id. *)
  let wanted : (int, int) Hashtbl.t = Hashtbl.create 1024 in
  let held : (int, int * int64 * string) Hashtbl.t = Hashtbl.create 1024 in
  (* What each lock holder suspended on while it held the lock: a holder that
     waits on a file or another job keeps every waiter behind that wait. *)
  let held_waits : (int, (string * int64) list) Hashtbl.t = Hashtbl.create 1024 in
  let long_holds = ref [] in
  (* The locks each fiber holds now, so a suspend looks only at its own. *)
  let holding : (int, int list) Hashtbl.t = Hashtbl.create 1024 in
  (* For each lock: what its holder last suspended on before taking it and
     first suspended on after letting go, so a lock without a name is placed
     by the file work around its critical section. *)
  let taken_after : (int, string) Hashtbl.t = Hashtbl.create 1024 in
  let released_before : (int, int * string * int64) Hashtbl.t = Hashtbl.create 1024 in
  let brackets : (int * string * string, int * int64) Hashtbl.t = Hashtbl.create 256 in
  (* Objects created while tracing, by kind. A promise or stream also reports
     [Get]; only mutexes, semaphores and objects older than the trace (the
     module-level mutexes) are treated as locks. *)
  let obj_kind : (int, string) Hashtbl.t = Hashtbl.create 4096 in
  let lock_like id =
    match Hashtbl.find_opt obj_kind id with
    | None -> true
    | Some kind -> String.equal kind "mutex" || String.equal kind "semaphore"
  in
  let lock_waits : (int * string, int * int64 * int64) Hashtbl.t = Hashtbl.create 256 in
  let lock_holds : (int * string, int * int64 * int64) Hashtbl.t = Hashtbl.create 256 in
  let bump table key dur =
    let c, t, m = Option.value ~default:(0, 0L, 0L) (Hashtbl.find_opt table key) in
    Hashtbl.replace table key (c + 1, Int64.add t dur, max m dur)
  in
  let span_label fiber =
    match Rtev_span.active book fiber with Some sp -> sp.span_name | None -> "(no job)"
  in
  let lost = ref 0 in
  let close d ts ended_by =
    let s = state d in
    match s.cur with
    | None -> ()
    | Some (fiber, start_ns, resumed_from) ->
      s.cur <- None;
      let dur = Int64.sub ts start_ns in
      Rtev_span.ran book ~fiber ~dur;
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
      (match Hashtbl.find_opt suspended_at id, Hashtbl.find_opt wanted id with
       | Some (_, since), Some lock ->
         bump lock_waits (lock, span_label id) (Int64.sub ts since)
       | (Some _ | None), _ -> ());
      Hashtbl.remove wanted id;
      (match Hashtbl.find_opt suspended_at id with
       | Some (reason, since) ->
         Hashtbl.remove suspended_at id;
         Rtev_span.waited book ~fiber:id ~reason ~dur:(Int64.sub ts since)
       | None -> ());
      let resumed_from =
        Option.value ~default:"(first run)" (Hashtbl.find_opt last_reason id)
      in
      (state d).cur <- Some (id, ts, resumed_from)
    | `Suspend_fiber reason ->
      (match (state d).cur with
       | Some (id, _, _) ->
         Hashtbl.replace last_reason id reason;
         Hashtbl.replace suspended_at id (reason, ts);
         (match Hashtbl.find_opt released_before id with
          | Some (lock, before, dur) ->
            Hashtbl.remove released_before id;
            let c, t = Option.value ~default:(0, 0L) (Hashtbl.find_opt brackets (lock, before, reason)) in
            Hashtbl.replace brackets (lock, before, reason) (c + 1, Int64.add t dur)
          | None -> ());
         List.iter
           (fun lock ->
              let prior = Option.value ~default:[] (Hashtbl.find_opt held_waits lock) in
              Hashtbl.replace held_waits lock ((reason, ts) :: prior))
           (Option.value ~default:[] (Hashtbl.find_opt holding id))
       | None -> ());
      close d ts reason
    | `Suspend_domain RE.Type.Begin -> close d ts "domain idle"
    | `Exit_fiber _ -> close d ts "exit"
    | `Create (id, `Fiber_in cc) ->
      Hashtbl.replace parent id cc;
      (match (state d).cur with
       | Some (creator, _, _) ->
         Hashtbl.replace created_by id creator;
         Rtev_span.inherit_from book ~creator ~child:id
       | None -> ())
    | `Enter_span name ->
      (match (state d).cur with
       | Some (fiber, start_ns, _) ->
         Rtev_span.enter book ~fiber ~domain:d ~name ~ts ~segment_start:start_ns
       | None -> ())
    | `Exit_span ->
      (match (state d).cur with
       | Some (fiber, start_ns, _) ->
         (match Rtev_span.leave book ~fiber ~ts ~segment_start:start_ns with
          | Some sp -> finished_spans := sp :: !finished_spans
          | None -> ())
       | None -> ())
    | `Create (id, `Cc ty) ->
      Hashtbl.replace cc_kind id (EE.cc_ty_to_string ty);
      (match (state d).cur with
       | Some (creator, _, _) -> Hashtbl.replace created_by id creator
       | None -> ())
    | `Name (id, n) ->
      Hashtbl.replace names id n;
      (match Hashtbl.find_opt created_by id with
       | Some creator ->
         Hashtbl.replace opened creator n;
         if not (Hashtbl.mem opened_first creator) then Hashtbl.replace opened_first creator n
       | None -> ())
    | `Try_get lock ->
      (match (state d).cur with
       | Some (fiber, _, _) -> Hashtbl.replace wanted fiber lock
       | None -> ())
    | `Get lock when lock_like lock ->
      (match (state d).cur with
       | Some (fiber, _, _) ->
         Hashtbl.replace held lock (fiber, ts, span_label fiber);
         Hashtbl.replace taken_after lock
           (Option.value ~default:"(first run)" (Hashtbl.find_opt last_reason fiber));
         Hashtbl.replace holding fiber
           (lock :: Option.value ~default:[] (Hashtbl.find_opt holding fiber))
       | None -> ())
    | `Get _ -> ()
    | `Put lock ->
      (match Hashtbl.find_opt held lock with
       | Some (holder, since, label) ->
         Hashtbl.remove held lock;
         (match Hashtbl.find_opt holding holder with
          | Some locks ->
            (match List.filter (fun other -> other <> lock) locks with
             | [] -> Hashtbl.remove holding holder
             | rest -> Hashtbl.replace holding holder rest)
          | None -> ());
         let dur = Int64.sub ts since in
         bump lock_holds (lock, label) dur;
         let reasons =
           Option.value ~default:[] (Hashtbl.find_opt held_waits lock)
           |> List.rev_map fst
         in
         Hashtbl.remove held_waits lock;
         let before = Option.value ~default:"?" (Hashtbl.find_opt taken_after lock) in
         Hashtbl.replace released_before holder (lock, before, dur);
         if Int64.compare dur 100_000_000L >= 0 then
           long_holds := (lock, holder, dur, label, reasons) :: !long_holds
       | None -> ())
    | `Create (id, `Obj kind) ->
      Hashtbl.replace obj_kind id (String.lowercase_ascii (EE.obj_ty_to_string kind))
    | `Suspend_domain (End) | `Error _
    | `Log _ | `Domain_spawn _ | `Exit_cc -> ()
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
  mark "ready" t_start;
  Printf.printf "ready pid=%d started_at_unix=%.6f\n%!" pid t_start;
  let events = ref 0 in
  let rec collect () =
    if stopping () then Stop_requested
    else if not (Unix.gettimeofday () -. t_start < seconds) then Observation_deadline
    else (
      events := !events + RE.read_poll cursor callbacks None;
      Unix.sleepf 0.02;
      collect ())
  in
  let collection_end = collect () in
  events := !events + RE.read_poll cursor callbacks None;
  let t_end = Unix.gettimeofday () in
  (match collection_end with
   | Stop_requested -> mark "stop-ack" t_end
   | Observation_deadline -> ());
  mark "ended" t_end;
  let window = t_end -. t_start in
  Printf.printf "window started_at_unix=%.6f ended_at_unix=%.6f\n" t_start t_end;
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
    match Hashtbl.find_opt opened_first fiber, Hashtbl.find_opt opened fiber with
    | Some first, Some last when not (String.equal first last) -> first ^ " > " ^ last
    | Some first, _ -> first
    | None, Some last -> last
    | None, None -> (
      match Hashtbl.find_opt names fiber with
      | Some n -> n
      | None -> (
      match Hashtbl.find_opt parent fiber with
      | Some cc -> (
        match Hashtbl.find_opt names cc with
        | Some n -> "cc:" ^ n
        | None -> Printf.sprintf "cc#%d" cc)
      | None -> "-"))
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
             (match Hashtbl.find_opt opened_first creator with
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
  Printf.printf "\nlongest uninterrupted runs on domain 0 (fiber ms gc_ms turn resumed_from -> ended_by [label])\n";
  List.iteri
    (fun i r ->
      if i < 15 then begin
        let dur = Int64.sub r.end_ns r.start_ns in
        let gc = union_ms (state 0).gc r.start_ns r.end_ns in
        Printf.printf "%-7d %8.1f %6.1f %4d %-34s -> %-34s [%s]%s\n" r.fiber (ms dur) gc
          r.turn_depth r.resumed_from r.ended_by (label_of r.fiber) (ancestry r.fiber)
      end)
    (List.filter (fun r -> r.domain = 0) by_len);
  Printf.printf "\ndomain 0 runs >= 10ms grouped by label: count total_ms max_ms\n";
  let by_label : (string, int * int64 * int64) Hashtbl.t = Hashtbl.create 64 in
  List.iter
    (fun r ->
      if r.domain = 0 then begin
        let dur = Int64.sub r.end_ns r.start_ns in
        if Int64.compare dur 10_000_000L >= 0 then begin
          let key = Printf.sprintf "%s (turn %d)" (label_of r.fiber) r.turn_depth in
          let c, t, m = Option.value ~default:(0, 0L, 0L) (Hashtbl.find_opt by_label key) in
          Hashtbl.replace by_label key (c + 1, Int64.add t dur, max m dur)
        end
      end)
    all_runs;
  List.iter
    (fun (k, (c, t, m)) -> Printf.printf "%5d %9.1f %8.1f  %s\n" c (ms t) (ms m) k)
    (List.sort
       (fun (_, (_, t1, _)) (_, (_, t2, _)) -> Int64.compare t2 t1)
       (Hashtbl.fold (fun k v l -> (k, v) :: l) by_label []));
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
  let spans = !finished_spans in
  let wall sp = match sp.exit_ns with Some x -> Int64.sub x sp.enter_ns | None -> 0L in
  let top_waits table k =
    Hashtbl.fold (fun reason ns acc -> (reason, ns) :: acc) table []
    |> List.sort (fun (_, a) (_, b) -> Int64.compare b a)
    |> List.filteri (fun i _ -> i < k)
    |> List.map (fun (reason, ns) -> Printf.sprintf "%s %.0f" reason (ms ns))
    |> String.concat ", "
  in
  Printf.printf "\ntraced sections (pool jobs) by name: count wall_sum_ms wall_max_ms run_sum_ms run_sum/wall%% top waits_ms (sums over fibers; concurrent fibers can pass wall)\n";
  let by_name : (string, int * int64 * int64 * int64 * (string, int64) Hashtbl.t) Hashtbl.t =
    Hashtbl.create 64
  in
  List.iter
    (fun sp ->
      let c, w, m, r, waits =
        Option.value ~default:(0, 0L, 0L, 0L, Hashtbl.create 4) (Hashtbl.find_opt by_name sp.span_name)
      in
      Hashtbl.iter
        (fun reason ns ->
          let prior = Option.value ~default:0L (Hashtbl.find_opt waits reason) in
          Hashtbl.replace waits reason (Int64.add prior ns))
        sp.waits;
      Hashtbl.replace by_name sp.span_name
        (c + 1, Int64.add w (wall sp), max m (wall sp), Int64.add r sp.run_ns, waits))
    spans;
  List.iteri
    (fun i (name, (c, w, m, r, waits)) ->
      if i < 30 then
        Printf.printf "%6d %10.1f %9.1f %10.1f %5.0f%%  %s  [%s]\n" c (ms w) (ms m) (ms r)
          (if Int64.compare w 0L > 0 then 100.0 *. ms r /. ms w else 0.0)
          name (top_waits waits 3))
    (List.sort
       (fun (_, (_, w1, _, _, _)) (_, (_, w2, _, _, _)) -> Int64.compare w2 w1)
       (Hashtbl.fold (fun k v l -> (k, v) :: l) by_name []));
  Printf.printf "\nlongest traced sections (domain wall_ms run_ms name [top waits_ms])\n";
  List.iteri
    (fun i sp ->
      if i < 25 then
        Printf.printf "%-3d %9.1f %9.1f  %s  [%s]\n" sp.span_domain (ms (wall sp)) (ms sp.run_ns)
          sp.span_name (top_waits sp.waits 4))
    (List.sort (fun a b -> Int64.compare (wall b) (wall a)) spans);
  (* Locks some job waited on at least 100 ms in total, longest wait first;
     under each, who waited and who held it. Promise and stream ids are
     included only when a fiber waited on them as a lock would be. *)
  let total_wait lock =
    Hashtbl.fold (fun (l, _) (_, t, _) acc -> if l = lock then Int64.add acc t else acc) lock_waits 0L
  in
  let locks =
    Hashtbl.fold (fun (l, _) _ acc -> if List.mem l acc then acc else l :: acc) lock_waits []
    |> List.filter (fun l -> Int64.compare (total_wait l) 100_000_000L >= 0)
    |> List.sort (fun a b -> Int64.compare (total_wait b) (total_wait a))
  in
  Printf.printf "\nlocks waited on (id total_wait_ms; waiters count total max; holders count total max)\n";
  let rows table lock =
    Hashtbl.fold (fun (l, label) v acc -> if l = lock then (label, v) :: acc else acc) table []
    |> List.sort (fun (_, (_, t1, _)) (_, (_, t2, _)) -> Int64.compare t2 t1)
  in
  List.iteri
    (fun i lock ->
      if i < 12 then begin
        Printf.printf "lock#%d %.1f\n" lock (ms (total_wait lock));
        List.iteri
          (fun j (label, (c, t, m)) ->
            if j < 6 then Printf.printf "   wait %6d %10.1f %9.1f  %s\n" c (ms t) (ms m) label)
          (rows lock_waits lock);
        List.iteri
          (fun j (label, (c, t, m)) ->
            if j < 6 then Printf.printf "   hold %6d %10.1f %9.1f  %s\n" c (ms t) (ms m) label)
          (rows lock_holds lock)
      end)
    locks;
  let print_hold (lock, holder, dur, label, reasons) =
    Printf.printf "lock#%d %d %9.1f %s [%s]%s  {%s}\n" lock holder (ms dur) label (label_of holder)
      (ancestry holder)
      (String.concat ", " (List.filteri (fun j _ -> j < 8) reasons))
  in
  Printf.printf "\nwhat holders of the three most waited-on locks did around them (count hold_ms before -> after)\n";
  List.iteri
    (fun i lock ->
      if i < 3 then
        Hashtbl.fold (fun (l, b, a) v acc -> if l = lock then (b, a, v) :: acc else acc) brackets []
        |> List.sort (fun (_, _, (_, t1)) (_, _, (_, t2)) -> Int64.compare t2 t1)
        |> List.iteri (fun j (b, a, (c, t)) ->
             if j < 12 then Printf.printf "lock#%d %6d %9.1f  %s -> %s\n" lock c (ms t) b a))
    locks;
  Printf.printf "\nlongest holds of the three most waited-on locks\n";
  List.iteri
    (fun i lock ->
      if i < 3 then
        List.filter (fun (l, _, _, _, _) -> l = lock) !long_holds
        |> List.sort (fun (_, _, a, _, _) (_, _, b, _, _) -> Int64.compare b a)
        |> List.iteri (fun j hold -> if j < 8 then print_hold hold))
    locks;
  Printf.printf "\nlongest lock holds (lock holder_fiber hold_ms job [holder label] suspended_on_while_holding)\n";
  List.iteri
    (fun i (lock, holder, dur, label, reasons) ->
      if i < 20 then
        Printf.printf "lock#%d %d %9.1f %s [%s]%s  {%s}\n" lock holder (ms dur) label (label_of holder)
          (ancestry holder)
          (String.concat ", " (List.filteri (fun j _ -> j < 6) reasons)))
    (List.sort (fun (_, _, a, _, _) (_, _, b, _, _) -> Int64.compare b a) !long_holds);
  RE.free_cursor cursor;
  flush stdout;
  mark "report-complete" (Unix.gettimeofday ())
