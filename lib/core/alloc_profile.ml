(* See alloc_profile.mli for the estimator and the domain rules. *)

let default_sampling_rate = 1e-5

(* Frames beyond this add cost per sample without telling the reader more
   than which subsystem allocated; the top frames name the site. *)
let callstack_frames = 16

type site =
  { site_key : string
  ; mutable allocated_samples : int
  ; mutable promoted_samples : int
  ; mutable live_samples : int
  }

type block =
  { site : site
  ; n_samples : int
  }

(* One table for every domain and thread sampling this profile. The
   callbacks may run in parallel, so every access takes the mutex. *)
let sites : (string, site) Hashtbl.t = Hashtbl.create 1024
let sites_mutex = Stdlib.Mutex.create ()
let rate = Atomic.make 0.0
let profile : Gc.Memprof.t option Atomic.t = Atomic.make None

let site_for key =
  match Hashtbl.find_opt sites key with
  | Some site -> site
  | None ->
    let site =
      { site_key = key; allocated_samples = 0; promoted_samples = 0; live_samples = 0 }
    in
    Hashtbl.add sites key site;
    site
;;

let observe_alloc ~key ~n_samples =
  Stdlib.Mutex.protect sites_mutex (fun () ->
    let site = site_for key in
    site.allocated_samples <- site.allocated_samples + n_samples;
    site.live_samples <- site.live_samples + n_samples;
    { site; n_samples })
;;

let observe_promote block =
  Stdlib.Mutex.protect sites_mutex (fun () ->
    block.site.promoted_samples <- block.site.promoted_samples + block.n_samples)
;;

let observe_dealloc block =
  Stdlib.Mutex.protect sites_mutex (fun () ->
    block.site.live_samples <- block.site.live_samples - block.n_samples)
;;

let key_of_callstack callstack =
  let entries = Printexc.raw_backtrace_entries callstack in
  let buffer = Buffer.create 256 in
  Array.iteri
    (fun index entry ->
       if index < callstack_frames
       then begin
         match Printexc.backtrace_slots_of_raw_entry entry with
         | None -> Buffer.add_string buffer "<unknown>\n"
         | Some slots ->
           Array.iteri
             (fun slot_index slot ->
                match Printexc.Slot.format slot_index slot with
                | Some text ->
                  Buffer.add_string buffer text;
                  Buffer.add_char buffer '\n'
                | None -> ())
             slots
       end)
    entries;
  Buffer.contents buffer
;;

let tracker : (block, block) Gc.Memprof.tracker =
  { alloc_minor =
      (fun (allocation : Gc.Memprof.allocation) ->
        Some
          (observe_alloc
             ~key:(key_of_callstack allocation.callstack)
             ~n_samples:allocation.n_samples))
  ; alloc_major =
      (fun (allocation : Gc.Memprof.allocation) ->
        let block =
          observe_alloc
            ~key:(key_of_callstack allocation.callstack)
            ~n_samples:allocation.n_samples
        in
        observe_promote block;
        Some block)
  ; promote =
      (fun block ->
        observe_promote block;
        Some block)
  ; dealloc_minor = observe_dealloc
  ; dealloc_major = observe_dealloc
  }
;;

let start ~sampling_rate =
  Atomic.set rate sampling_rate;
  Atomic.set
    profile
    (Some
       (Gc.Memprof.start
          ~sampling_rate
          ~callstack_size:callstack_frames
          tracker))
;;

let is_sampling () = Gc.Memprof.is_sampling ()

type site_totals =
  { key : string
  ; samples : int
  ; words : int
  }

type report =
  { sampling_rate : float
  ; sampling : bool
  ; live : site_totals list
  ; promoted : site_totals list
  ; allocated : site_totals list
  ; live_samples : int
  ; live_words : int
  ; allocated_samples : int
  ; allocated_words : int
  ; promoted_words : int
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
  let snapshot =
    Stdlib.Mutex.protect sites_mutex (fun () ->
      Hashtbl.fold
        (fun _ site acc ->
           { site_key = site.site_key
           ; allocated_samples = site.allocated_samples
           ; promoted_samples = site.promoted_samples
           ; live_samples = site.live_samples
           }
           :: acc)
        sites
        [])
  in
  let sum measure = List.fold_left (fun acc site -> acc + measure site) 0 snapshot in
  let live_samples = sum (fun site -> site.live_samples) in
  let allocated_samples = sum (fun site -> site.allocated_samples) in
  let promoted_samples = sum (fun site -> site.promoted_samples) in
  { sampling_rate
  ; sampling = is_sampling ()
  ; live = top_sites ~top ~sampling_rate (fun site -> site.live_samples) snapshot
  ; promoted = top_sites ~top ~sampling_rate (fun site -> site.promoted_samples) snapshot
  ; allocated = top_sites ~top ~sampling_rate (fun site -> site.allocated_samples) snapshot
  ; live_samples
  ; live_words = estimate_words ~sampling_rate live_samples
  ; allocated_samples
  ; allocated_words = estimate_words ~sampling_rate allocated_samples
  ; promoted_words = estimate_words ~sampling_rate promoted_samples
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
    ; "promoted_bytes", `Int (Heap_roots.words_to_bytes report.promoted_words)
    ; "live", table report.live
    ; "promoted", table report.promoted
    ; "allocated", table report.allocated
    ]
;;

module For_testing = struct
  type nonrec block = block

  let observe_alloc = observe_alloc
  let observe_promote = observe_promote
  let observe_dealloc = observe_dealloc
  let set_sampling_rate sampling_rate = Atomic.set rate sampling_rate

  let reset () =
    Stdlib.Mutex.protect sites_mutex (fun () -> Hashtbl.reset sites);
    Atomic.set rate 0.0
  ;;
end
