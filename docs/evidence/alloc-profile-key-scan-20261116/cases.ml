type capture = { label : string; raw : Printexc.raw_backtrace }

let assertions = ref 0
let require label condition = incr assertions; if not condition then failwith label

let[@inline never] leaf max_frames () = Printexc.get_callstack max_frames, 0
let[@inline never] rec own_frames depth capture =
  if depth = 0 then capture ()
  else let raw, sum = own_frames (depth - 1) capture in raw, sum + depth

let[@inline always] inline_leaf () = Printexc.get_callstack 384
let[@inline always] inline_middle () = inline_leaf ()
let[@inline never] inline_outer () = inline_middle ()

let capture_allocations label max_frames work =
  let captured = ref [] and count = ref 0 in
  let observe (allocation : Gc.Memprof.allocation) =
    if !count < 128 then (
      incr count;
      captured := {label; raw = allocation.callstack} :: !captured);
    None
  in
  let tracker : (unit, unit) Gc.Memprof.tracker =
    { Gc.Memprof.null_tracker with alloc_minor = observe; alloc_major = observe } in
  let profile = Gc.Memprof.start ~sampling_rate:0.01 ~callstack_size:max_frames tracker in
  Fun.protect ~finally:(fun () -> Gc.Memprof.stop (); Gc.Memprof.discard profile)
    (fun () -> work (); Gc.minor ());
  List.rev !captured

let stats capture =
  let entries = Printexc.raw_backtrace_entries capture.raw in
  let limit = min Shared.callstack_frames (Array.length entries) in
  let kept = ref 0 and scanned = ref limit and six_reached = ref false in
  let unknown = ref 0 and expanded = ref 0 and stdlib = ref 0 and yojson = ref 0 in
  for index = 0 to limit - 1 do
    let entry = entries.(index) in
    if not (Shared.entry_is_skipped entry) then (
      incr kept;
      if !kept = Shared.frames_per_key && not !six_reached then (
        scanned := index + 1; six_reached := true));
    (match Printexc.backtrace_slots_of_raw_entry entry with
     | None -> incr unknown
     | Some slots ->
       if Array.length slots > 1 then incr expanded;
       Array.iter (fun slot ->
         match Printexc.Slot.name slot with
         | None -> incr unknown
         | Some name ->
           if String.starts_with ~prefix:"Stdlib" name then incr stdlib;
           if String.starts_with ~prefix:"Yojson" name then incr yojson) slots)
  done;
  Array.length entries, limit, !kept, !scanned, !unknown, !expanded, !stdlib, !yojson

let stat_json capture =
  let raw, window, kept, scanned, unknown, expanded, stdlib, yojson = stats capture in
  `Assoc ["label", `String capture.label; "raw_entries", `Int raw;
          "window_entries", `Int window; "kept_in_window", `Int kept;
          "candidate_classifications", `Int scanned;
          "unknown_entries_or_slots", `Int unknown; "inline_expanded_entries", `Int expanded;
          "stdlib_named_slots", `Int stdlib; "yojson_named_slots", `Int yojson;
          "output_bytes", `Int (String.length (Original.key_of_callstack capture.raw))]

let measure iterations key capture =
  Gc.full_major ();
  let before_bytes = Gc.allocated_bytes () and before_cpu = Sys.time () in
  let checksum = ref 0 in
  for _ = 1 to iterations do
    let text = Sys.opaque_identity (key capture.raw) in
    checksum := !checksum + String.length text
  done;
  let cpu = Sys.time () -. before_cpu and bytes = Gc.allocated_bytes () -. before_bytes in
  `Assoc ["cpu_seconds", `Float cpu; "allocated_bytes", `Float bytes; "checksum", `Int !checksum]

let run () =
  Printexc.record_backtrace true;
  let direct = List.map (fun depth ->
    let raw, _ = own_frames depth (leaf 384) in
    {label = Printf.sprintf "direct-depth-%d" depth; raw}) [0; 3; 6; 12; 48; 128; 191; 192; 256] in
  let prefixed = List.map (fun (depth, limit) ->
    let raw, _ = Stdlib__Key_scan_fixture.capture depth limit in
    {label = Printf.sprintf "synthetic-skip-prefix-depth-%d-limit-%d" depth limit; raw})
    [0, 384; 3, 384; 189, 192; 190, 192; 191, 192; 256, 192; 256, 384] in
  let empty = {label = "empty"; raw = Printexc.get_callstack 0} in
  let unknown = {label = "no-debug-native-module"; raw = No_debug_capture.capture 384} in
  let inline = {label = "inline-requested-native"; raw = inline_outer ()} in
  let chunk = String.make 2048 'x' in
  let buffer () =
    let b = Buffer.create 1 in
    for _ = 1 to 4000 do Buffer.add_string b chunk done;
    ignore (Sys.opaque_identity (Buffer.contents b)) in
  let rec json depth = if depth = 0 then `String chunk else `List [json (depth - 1); `String chunk] in
  let document = json 240 in
  let encode () = for _ = 1 to 3 do ignore (Sys.opaque_identity (Yojson.Safe.to_string document)) done in
  let sampled_stdlib = capture_allocations "actual-stdlib-buffer-allocation" 384 buffer in
  let sampled_yojson = capture_allocations "actual-yojson-encode-allocation" 384 encode in
  let short_stdlib = capture_allocations "actual-stdlib-short-window" 1 buffer in
  require "fixture sampling stopped before oracle and measurements" (not (Gc.Memprof.is_sampling ()));
  require "actual allocation callstacks captured" (sampled_stdlib <> [] && sampled_yojson <> [] && short_stdlib <> []);
  let captures = empty :: unknown :: inline :: (direct @ prefixed @ sampled_stdlib @ sampled_yojson @ short_stdlib) in
  List.iter (fun capture ->
    require ("byte equality: " ^ capture.label)
      (String.equal (Original.key_of_callstack capture.raw) (Candidate.key_of_callstack capture.raw))) captures;
  let all_skipped capture = let _, window, kept, _, _, _, _, _ = stats capture in window > 0 && kept = 0 in
  let early capture = let _, window, _, scanned, _, _, _, _ = stats capture in scanned < window in
  let unknown_frame capture = let _, _, _, _, unknown, _, _, _ = stats capture in unknown > 0 in
  let inline_frame capture = let _, _, _, _, _, expanded, _, _ = stats capture in expanded > 0 in
  let actual_yojson capture = let _, _, _, _, _, _, _, yojson = stats capture in yojson > 0 in
  require "early-stop corpus case exists" (List.exists early captures);
  require "all-skipped nonempty corpus case exists" (List.exists all_skipped captures);
  require "real unknown-debug corpus case exists" (List.exists unknown_frame captures);
  require "raw arrays beyond source window exist" (List.exists (fun capture -> let raw,_,_,_,_,_,_,_ = stats capture in raw > Shared.callstack_frames) captures);
  let pick predicate values = List.find_opt predicate values in
  let groups =
    [Some ("shallow-attributed", List.hd direct);
     Some ("deep-early-stop", List.nth direct 5);
     Option.map (fun c -> "all-skipped-full-window", c)
       (pick (fun c -> let _,window,kept,_,_,_,_,_ = stats c in window=Shared.callstack_frames && kept=0) prefixed);
     Option.map (fun c -> "actual-stdlib", c) (pick (fun _ -> true) sampled_stdlib);
     Option.map (fun c -> "actual-yojson", c) (pick actual_yojson sampled_yojson);
     Some ("unknown-debug", unknown)] |> List.filter_map Fun.id in
  let iterations = 2000 in
  let results = List.map (fun (name, capture) ->
    for _ = 1 to 100 do
      ignore (Sys.opaque_identity (Original.key_of_callstack capture.raw));
      ignore (Sys.opaque_identity (Candidate.key_of_callstack capture.raw))
    done;
    let rounds = List.init 5 (fun round ->
      let original, candidate =
        if round mod 2 = 0 then
          let original = measure iterations Original.key_of_callstack capture in
          original, measure iterations Candidate.key_of_callstack capture
        else
          let candidate = measure iterations Candidate.key_of_callstack capture in
          measure iterations Original.key_of_callstack capture, candidate in
      `Assoc ["round", `Int round; "original", original; "candidate", candidate]) in
    `Assoc ["group", `String name; "capture", stat_json capture;
            "iterations_per_variant_per_round", `Int iterations; "rounds", `List rounds]) groups in
  `Assoc ["assertions", `Int !assertions; "oracle_raw_captures", `Int (List.length captures);
          "sampled_stdlib_captures", `Int (List.length sampled_stdlib);
          "sampled_yojson_captures", `Int (List.length sampled_yojson);
          "inline_expansion_observed", `Bool (List.exists inline_frame captures);
          "actual_yojson_named_slots_observed", `Bool (List.exists actual_yojson captures);
          "sampling_during_measurement", `Bool (Gc.Memprof.is_sampling ());
          "capture_stats", `List (List.map stat_json captures); "benchmarks", `List results]

let () = print_endline (Yojson.Safe.pretty_to_string (run ()))
