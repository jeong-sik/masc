let path = Sys.getenv_opt "MASC_TUI_ALLOC_PROFILE"

(* One sample per this many allocated words, on average. A held key allocated
   about 60 MB per second on the UI domain, so this keeps a few thousand
   samples a second: enough to rank sites, cheap enough not to move them. *)
let sampling_rate = 1e-4

(* Frames recorded per sample. Deep enough to get past the Stdlib helpers
   (Buffer, Printf, List) to the masc code that called them. *)
let callstack_frames = 24

(* Sites printed per ranking. *)
let report_rows = 40

let by_site : (string, float) Hashtbl.t = Hashtbl.create 1024
let by_stack : (string, float) Hashtbl.t = Hashtbl.create 1024
let sampled_words = ref 0.

let add table key words =
  Hashtbl.replace table key
    (words +. Option.value ~default:0. (Hashtbl.find_opt table key))

let location slot =
  match Printexc.Slot.location slot with
  | None -> None
  | Some { Printexc.filename; line_number; _ } ->
      Some (Printf.sprintf "%s:%d" filename line_number)

(* masc's own sources are the frames under bin/ and lib/; the standard
   library and opam packages record bare or package-relative file names. *)
let is_masc location =
  String.starts_with ~prefix:"bin/" location || String.starts_with ~prefix:"lib/" location

let record (allocation : Gc.Memprof.allocation) =
  let words = float_of_int allocation.n_samples /. sampling_rate in
  sampled_words := !sampled_words +. words;
  let locations =
    match Printexc.backtrace_slots allocation.callstack with
    | None -> []
    | Some slots -> List.filter_map location (Array.to_list slots)
  in
  let site =
    match List.find_opt is_masc locations with
    | Some l -> l
    | None -> "(no masc frame)"
  in
  add by_site site words;
  add by_stack
    (String.concat " < " (List.filteri (fun i _ -> i < 8) locations))
    words;
  None

let tracker =
  { Gc.Memprof.null_tracker with alloc_minor = record; alloc_major = record }

let started = ref false

let start () =
  match path with
  | None -> ()
  | Some _ when !started -> ()
  | Some _ ->
      started := true;
      ignore
        (Gc.Memprof.start ~sampling_rate ~callstack_size:callstack_frames tracker)

let ranked table =
  Hashtbl.fold (fun key words acc -> (key, words) :: acc) table []
  |> List.sort (fun (_, a) (_, b) -> Float.compare b a)
  |> List.filteri (fun i _ -> i < report_rows)

let report () =
  match path with
  | None -> ()
  | Some _ when not !started -> ()
  | Some file -> (
      (try Gc.Memprof.stop () with Failure _ -> ());
      try
        let oc = open_out_gen [ Open_append; Open_creat ] 0o644 file in
        let total = !sampled_words in
        let share words = if total > 0. then 100. *. words /. total else 0. in
        Printf.fprintf oc "alloc estimated_words=%.0f sampling_rate=%g\n" total
          sampling_rate;
        List.iter
          (fun (site, words) ->
            Printf.fprintf oc "  site %5.1f%% %.0f words %s\n" (share words) words site)
          (ranked by_site);
        List.iter
          (fun (stack, words) ->
            Printf.fprintf oc "  stack %5.1f%% %s\n" (share words) stack)
          (ranked by_stack);
        close_out oc
      with Sys_error _ -> ())
