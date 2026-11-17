(* See alloc_profile.mli for the estimator, the callback rule, and the bounds. *)

let default_sampling_rate = 1e-5
let max_pending_events = 1_000_000
let max_sites = 50_000
let overflow_site_key = "<sites past the table bound>"

(* Deep enough that a masc frame is inside the window. With 16, the
   2026-09-05 steady-state reading left 24 GB of a 203 GB window with no masc
   caller at all: Buffer.resize under Yojson writers, Format.make_formatter
   under output_acc, and Eio's scheduler loop each spend more than 16 frames
   in library code before the masc caller appears, and [key_of_callstack]
   skips those frames without seeing past them (RFC
   main-domain-scheduler-latency §8.6). Cost is per sample at rate 1e-5. *)
let callstack_frames = 192

(* What a key says when the window held no masc frame. Without it the key
   falls back to the top library frames, and those aggregate into a row that
   reads like a site -- a 2026-09-06 steady-state reading put 1.94 GB under
   [Buffer.resize] with no caller, which names how the bytes were built and
   not who asked for them. A profile that cannot answer should say so rather
   than point somewhere plausible. *)
let unattributed_marker = "<no masc frame in the sampled window>\n" 

type block =
  { site_key : string
  ; n_samples : int
  ; on_starting_domain : bool
  }

(* What a callback records. Callbacks push; only the reader pops. *)
type event =
  | Allocated of block
  | Allocated_in_major of block
  | Promoted of block
  | Freed of block

(* A Treiber stack: push is one CAS, drain is one exchange. No lock is ever
   taken on this path, which is the whole point (see the mli). *)
let pending : event list Atomic.t = Atomic.make []
let pending_count = Atomic.make 0
let dropped_samples = Atomic.make 0
let rate = Atomic.make 0.0
let profile : Gc.Memprof.t option Atomic.t = Atomic.make None

(* The domain that called [start]: the server's main domain. An allocation
   callback runs on the thread that allocated, so [Domain.self] there is the
   allocating domain. No domain has this id before [start]. *)
let no_domain = -1
let starting_domain = Atomic.make no_domain

(* Readers take this before [sites_mutex]; callbacks take neither. Memprof
   lifecycle operations never run while the site registry is locked. *)
let lifecycle_mutex = Stdlib.Mutex.create ()
let profile_epoch = ref 0

let push event =
  let rec attempt () =
    let current = Atomic.get pending in
    if not (Atomic.compare_and_set pending current (event :: current)) then attempt ()
  in
  attempt ();
  Atomic.incr pending_count
;;

(* Admission for new blocks only. A block that is already tracked always
   gets its later events pushed, so the live table cannot inflate. *)
let admit event block =
  if Atomic.get pending_count >= max_pending_events
  then begin
    (* See mli: the count before the add is not needed, only the running total. *)
    ignore (Atomic.fetch_and_add dropped_samples block.n_samples : int);
    None
  end
  else begin
    push (event block);
    Some block
  end
;;

(* Frames of these libraries are skipped when a key is built: they say how
   a value was built (a lexer recursion, a Bytes copy, a fiber resumed by the
   scheduler), not who asked for it, and they multiply distinct stacks past
   any table bound. Every other frame counts, so the skip list is closed and
   small. Eio was added after the 2026-09-05 reading in which
   [Eio__Executor_pool.run_worker] and [Eio_posix__Sched.with_sched] headed
   14.5 GB and 4.8 GB with no masc frame inside the six the key keeps (RFC
   main-domain-scheduler-latency §8.6). The prefixes name Eio's own
   libraries; masc modules that start with [Eio_] (Eio_guard, Eio_context)
   keep counting. *)
let skipped_frame_name_prefixes =
  [ "Stdlib__"
  ; "Stdlib."
  ; "Yojson__"
  ; "CamlinternalFormat"
  ; "Eio__"
  ; "Eio_posix__"
  ; "Eio_unix__"
  ; "Eio_linux__"
  ; "Eio_main."
  ]
;;

(* How many kept frames name a site. Deeper than this the paths converge on
   the same keeper loop and add nothing. *)
let frames_per_key = 6

let frame_lines entry =
  match Printexc.backtrace_slots_of_raw_entry entry with
  | None -> [ "<unknown>" ]
  | Some slots ->
    Array.to_list slots
    |> List.mapi (fun slot_index slot -> Printexc.Slot.format slot_index slot)
    |> List.filter_map Fun.id
;;

let is_skipped_slot slot =
  match Printexc.Slot.name slot with
  | None -> false
  | Some name ->
    List.exists (fun prefix -> String.starts_with ~prefix name) skipped_frame_name_prefixes
;;

let entry_is_skipped entry =
  match Printexc.backtrace_slots_of_raw_entry entry with
  | None -> false
  | Some slots -> Array.for_all is_skipped_slot slots
;;

let key_of_callstack callstack =
  let entries = Printexc.raw_backtrace_entries callstack in
  let limit = min callstack_frames (Array.length entries) in
  let rec choose index count kept =
    if index = limit || count = frames_per_key then List.rev kept
    else
      let entry = entries.(index) in
      if entry_is_skipped entry then choose (index + 1) count kept
      else choose (index + 1) (count + 1) (entry :: kept)
  in
  let attributed, chosen =
    match choose 0 0 [] with
    | [] -> false, List.init (min frames_per_key limit) (Array.get entries)
    | _ :: _ as chosen -> true, chosen
  in
  let body = String.concat "\n" (List.concat_map frame_lines chosen) ^ "\n" in
  if attributed then body else unattributed_marker ^ body
;;

let block_of (allocation : Gc.Memprof.allocation) =
  { site_key = key_of_callstack allocation.callstack
  ; n_samples = allocation.n_samples
  ; on_starting_domain = (Domain.self () :> int) = Atomic.get starting_domain
  }
;;

let tracker : (block, block) Gc.Memprof.tracker =
  { alloc_minor = (fun allocation -> admit (fun block -> Allocated block) (block_of allocation))
  ; alloc_major =
      (fun allocation ->
        admit (fun block -> Allocated_in_major block) (block_of allocation))
  ; promote =
      (fun block ->
        push (Promoted block);
        Some block)
  ; dealloc_minor = (fun block -> push (Freed block))
  ; dealloc_major = (fun block -> push (Freed block))
  }
;;

let start ~sampling_rate =
  Stdlib.Mutex.protect lifecycle_mutex (fun () ->
    let previous_domain = Atomic.get starting_domain in
    Atomic.set starting_domain (Domain.self () :> int);
    match Gc.Memprof.start ~sampling_rate ~callstack_size:callstack_frames tracker with
    | started ->
      Atomic.set rate sampling_rate;
      Atomic.set profile (Some started);
      incr profile_epoch
    | exception exn ->
      let bt = Printexc.get_raw_backtrace () in
      Atomic.set starting_domain previous_domain;
      Printexc.raise_with_backtrace exn bt)
;;

let is_sampling () = Gc.Memprof.is_sampling ()

let stop () =
  Stdlib.Mutex.protect lifecycle_mutex (fun () ->
    match Atomic.exchange profile None with
    | None -> ()
    | Some started ->
      incr profile_epoch;
      if is_sampling () then Gc.Memprof.stop ();
      Gc.Memprof.discard started)
;;

(* The site table. Only the reader touches it, under [sites_mutex], which no
   callback ever takes. *)
type site =
  { site_id : int
  ; site_key : string
  ; mutable allocated_samples : int
  ; mutable starting_domain_samples : int
  ; mutable major_samples : int
  ; mutable direct_major_samples : int
  ; mutable live_samples : int
  }

let sites : (string, site) Hashtbl.t = Hashtbl.create 1024
let sites_mutex = Stdlib.Mutex.create ()
let next_site_id = ref 0

let new_site site_key =
  incr next_site_id;
  { site_id = !next_site_id
  ; site_key
  ; allocated_samples = 0
  ; starting_domain_samples = 0
  ; major_samples = 0
  ; direct_major_samples = 0
  ; live_samples = 0
  }
;;

let site_for key =
  match Hashtbl.find_opt sites key with
  | Some site -> site
  | None ->
    let key = if Hashtbl.length sites >= max_sites then overflow_site_key else key in
    (match Hashtbl.find_opt sites key with
     | Some site -> site
     | None ->
       let site = new_site key in
       Hashtbl.add sites key site;
       site)
;;

let count_allocation site block =
  site.allocated_samples <- site.allocated_samples + block.n_samples;
  if block.on_starting_domain
  then site.starting_domain_samples <- site.starting_domain_samples + block.n_samples
;;

let apply = function
  | Allocated block ->
    let site = site_for block.site_key in
    count_allocation site block;
    site.live_samples <- site.live_samples + block.n_samples
  | Allocated_in_major block ->
    let site = site_for block.site_key in
    count_allocation site block;
    site.live_samples <- site.live_samples + block.n_samples;
    site.major_samples <- site.major_samples + block.n_samples;
    site.direct_major_samples <- site.direct_major_samples + block.n_samples
  | Promoted block ->
    let site = site_for block.site_key in
    site.major_samples <- site.major_samples + block.n_samples
  | Freed block ->
    let site = site_for block.site_key in
    site.live_samples <- site.live_samples - block.n_samples
;;

(* Pushes are newest first; apply oldest first so a block's Allocated
   precedes its Freed. *)
let drain () =
  let events = Atomic.exchange pending [] in
  let count = List.length events in
  (* See mli: the stack is already taken above; the old count is not needed. *)
  ignore (Atomic.fetch_and_add pending_count (-count) : int);
  List.iter apply (List.rev events)
;;

type site_totals =
  { key : string
  ; samples : int
  ; words : int
  }

type report =
  { sampling_rate : float
  ; sampling : bool
  ; live : site_totals list
  ; major : site_totals list
  ; allocated : site_totals list
  ; starting_domain_allocated : site_totals list
  ; live_samples : int
  ; live_words : int
  ; allocated_samples : int
  ; allocated_words : int
  ; starting_domain_allocated_samples : int
  ; starting_domain_allocated_words : int
  ; major_samples : int
  ; major_words : int
  ; direct_major_samples : int
  ; dropped_samples : int
  ; pending_events : int
  ; sites : int
  }

let estimate_words ~sampling_rate samples =
  if sampling_rate <= 0.0 then 0 else int_of_float (Float.of_int samples /. sampling_rate)
;;

let top_sites ~top ~sampling_rate measure snapshot =
  snapshot
  |> List.filter_map (fun site ->
    let samples = measure site in
    if samples <= 0
    then None
    else Some { key = site.site_key; samples; words = estimate_words ~sampling_rate samples })
  |> List.sort (fun a b -> Int.compare b.samples a.samples)
  |> List.filteri (fun index _ -> index < top)
;;

let report ~top =
  let sampling_rate = Atomic.get rate in
  let snapshot, site_count =
    Stdlib.Mutex.protect sites_mutex (fun () ->
      drain ();
      ( Hashtbl.fold
          (fun _ site acc ->
             { site_id = site.site_id
             ; site_key = site.site_key
             ; allocated_samples = site.allocated_samples
             ; starting_domain_samples = site.starting_domain_samples
             ; major_samples = site.major_samples
             ; direct_major_samples = site.direct_major_samples
             ; live_samples = site.live_samples
             }
             :: acc)
          sites
          []
      , Hashtbl.length sites ))
  in
  let sum measure = List.fold_left (fun acc site -> acc + measure site) 0 snapshot in
  let live_samples = sum (fun site -> site.live_samples) in
  let allocated_samples = sum (fun site -> site.allocated_samples) in
  let major_samples = sum (fun site -> site.major_samples) in
  let starting_domain_allocated_samples = sum (fun site -> site.starting_domain_samples) in
  { sampling_rate
  ; sampling = is_sampling ()
  ; live = top_sites ~top ~sampling_rate (fun site -> site.live_samples) snapshot
  ; major = top_sites ~top ~sampling_rate (fun site -> site.major_samples) snapshot
  ; allocated = top_sites ~top ~sampling_rate (fun site -> site.allocated_samples) snapshot
  ; starting_domain_allocated =
      top_sites ~top ~sampling_rate (fun site -> site.starting_domain_samples) snapshot
  ; live_samples
  ; live_words = estimate_words ~sampling_rate live_samples
  ; allocated_samples
  ; allocated_words = estimate_words ~sampling_rate allocated_samples
  ; starting_domain_allocated_samples
  ; starting_domain_allocated_words =
      estimate_words ~sampling_rate starting_domain_allocated_samples
  ; major_samples
  ; major_words = estimate_words ~sampling_rate major_samples
  ; direct_major_samples = sum (fun site -> site.direct_major_samples)
  ; dropped_samples = Atomic.get dropped_samples
  ; pending_events = Atomic.get pending_count
  ; sites = site_count
  }
;;

let site_totals_to_yojson site : Yojson.Safe.t =
  `Assoc
    [ "samples", `Int site.samples
    ; "words", `Int site.words
    ; "bytes", `Int (Heap_roots.words_to_bytes site.words)
    ; "callstack", `String site.key
    ]
;;

let report_to_yojson report : Yojson.Safe.t =
  let table sites = `List (List.map site_totals_to_yojson sites) in
  `Assoc
    [ "sampling_rate", `Float report.sampling_rate
    ; "sampling", `Bool report.sampling
    ; "live_samples", `Int report.live_samples
    ; "live_bytes", `Int (Heap_roots.words_to_bytes report.live_words)
    ; "allocated_samples", `Int report.allocated_samples
    ; "allocated_bytes", `Int (Heap_roots.words_to_bytes report.allocated_words)
    ; "starting_domain_allocated_samples", `Int report.starting_domain_allocated_samples
    ; ( "starting_domain_allocated_bytes"
      , `Int (Heap_roots.words_to_bytes report.starting_domain_allocated_words) )
    ; "major_samples", `Int report.major_samples
    ; "major_bytes", `Int (Heap_roots.words_to_bytes report.major_words)
    ; "direct_major_samples", `Int report.direct_major_samples
    ; "dropped_samples", `Int report.dropped_samples
    ; "pending_events", `Int report.pending_events
    ; "sites", `Int report.sites
    ; "site_bound", `Int max_sites
    ; "overflow_site_key", `String overflow_site_key
    ; "live", table report.live
    ; "major", table report.major
    ; "allocated", table report.allocated
    ; "starting_domain_allocated", table report.starting_domain_allocated
    ]
;;

type site_id = int
let site_id_of_int id = if id > 0 && id <= max_sites + 1 then Some id else None

type counter_identity = { epoch : int; sampling_rate : float }
type sample_counters =
  { allocated_samples : int
  ; starting_domain_samples : int
  ; major_samples : int
  ; direct_major_samples : int
  ; live_samples : int
  }
type site_counters = { id : site_id; counts : sample_counters }
type counter_snapshot =
  { identity : counter_identity
  ; sampling : bool
  ; counters : site_counters list
  ; totals : sample_counters
  ; dropped_samples : int
  ; pending_events : int
  ; overflow_id : site_id option
  }

let counter_snapshot () =
  Stdlib.Mutex.protect lifecycle_mutex (fun () ->
    Stdlib.Mutex.protect sites_mutex (fun () ->
      drain ();
      let counters = Hashtbl.fold (fun _ (site : site) rows ->
        {id=site.site_id; counts=
          { allocated_samples=site.allocated_samples
          ; starting_domain_samples=site.starting_domain_samples
          ; major_samples=site.major_samples
          ; direct_major_samples=site.direct_major_samples
          ; live_samples=site.live_samples }} :: rows) sites [] in
      let zero = {allocated_samples=0; starting_domain_samples=0; major_samples=0;
                  direct_major_samples=0; live_samples=0} in
      let totals = List.fold_left (fun total {counts; id=_} ->
        { allocated_samples=total.allocated_samples + counts.allocated_samples
        ; starting_domain_samples=total.starting_domain_samples + counts.starting_domain_samples
        ; major_samples=total.major_samples + counts.major_samples
        ; direct_major_samples=total.direct_major_samples + counts.direct_major_samples
        ; live_samples=total.live_samples + counts.live_samples }) zero counters in
      { identity={epoch= !profile_epoch; sampling_rate=Atomic.get rate}
      ; sampling=is_sampling ()
      ; counters; totals
      ; dropped_samples=Atomic.get dropped_samples
      ; pending_events=Atomic.get pending_count
      ; overflow_id=Option.map (fun site -> site.site_id) (Hashtbl.find_opt sites overflow_site_key)
      }))
;;

type stack_lookup_error = Profile_changed | Unknown_site of site_id
module Site_ids = Set.Make (Int)

let callstacks ~(expected : counter_identity) ids =
  Stdlib.Mutex.protect lifecycle_mutex (fun () ->
    if expected.epoch <> !profile_epoch || not (Float.equal expected.sampling_rate (Atomic.get rate))
    then Error Profile_changed
    else Stdlib.Mutex.protect sites_mutex (fun () ->
      let requested = Site_ids.of_list ids in
      let found, missing = Hashtbl.fold (fun _ site ((found, missing) as state) ->
        if Site_ids.mem site.site_id missing then
          ((site.site_id,site.site_key)::found, Site_ids.remove site.site_id missing)
        else state) sites ([],requested) in
      match Site_ids.min_elt_opt missing with
      | Some id -> Error (Unknown_site id)
      | None -> Ok found))
;;

module For_testing = struct
  type nonrec block = block

  let observe_alloc ~key ~n_samples =
    let block = { site_key = key; n_samples; on_starting_domain = false } in
    push (Allocated block);
    block
  ;;

  let observe_alloc_on_starting_domain ~key ~n_samples =
    let block = { site_key = key; n_samples; on_starting_domain = true } in
    push (Allocated block);
    block
  ;;

  let observe_alloc_in_major ~key ~n_samples =
    let block = { site_key = key; n_samples; on_starting_domain = false } in
    push (Allocated_in_major block);
    block
  ;;

  let observe_promote block = push (Promoted block)
  let observe_dealloc block = push (Freed block)
  let set_sampling_rate sampling_rate =
    Stdlib.Mutex.protect lifecycle_mutex (fun () ->
      incr profile_epoch;
      Atomic.set rate sampling_rate)

  let reset () =
    Stdlib.Mutex.protect lifecycle_mutex (fun () ->
    Stdlib.Mutex.protect sites_mutex (fun () ->
      (* See mli: tests discard undrained events on purpose. *)
      ignore (Atomic.exchange pending [] : event list);
      Atomic.set pending_count 0;
      Atomic.set dropped_samples 0;
      Hashtbl.reset sites;
      next_site_id := 0);
    incr profile_epoch;
    Atomic.set starting_domain no_domain;
    Atomic.set rate 0.0)
  ;;
end
