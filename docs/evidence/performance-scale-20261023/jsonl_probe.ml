(* Loaded after the exact baseline/candidate modules by the probe wrapper. *)
let count_before cache path = Jsonl_baseline.read cache ~key:path ~path ~empty:0
  ~add:(fun count _ -> count + 1) ~initial_tail_bytes:1_000_000
let count_after cache path = Jsonl_candidate.read cache ~key:path ~path ~empty:0
  ~add:(fun count _ -> count + 1) ~initial_tail_bytes:1_000_000

let measure f paths =
  Gc.full_major ();
  let allocated = Gc.allocated_bytes () in
  let started = Mtime_clock.counter () in
  let results = List.map f paths in
  let ms = Mtime.Span.to_float_ns (Mtime_clock.count started) /. 1_000_000. in
  let bytes = Gc.allocated_bytes () -. allocated in
  results, ms, bytes

let () =
  List.iter (fun files ->
    let paths = List.init files (fun _ -> Filename.temp_file "masc-jsonl-probe-" ".jsonl") in
    Fun.protect ~finally:(fun () -> List.iter Sys.remove paths) (fun () ->
      let row = "{\"content\":\"" ^ String.make 60 'x' ^ "\"}\n" in
      List.iter (fun path -> Out_channel.with_open_bin path (fun oc ->
        for _ = 1 to 1000 do output_string oc row done)) paths;
      let before_cache = Jsonl_baseline.create () in
      let after_cache = Jsonl_candidate.create () in
      let before = count_before before_cache in
      let after = count_after after_cache in
      assert (List.map before paths = List.map after paths);
      List.iter (fun phase ->
        for round = 1 to 9 do
          if phase = "append" then List.iter (fun path ->
            let oc = open_out_gen [Open_append; Open_binary] 0o600 path in
            Fun.protect ~finally:(fun () -> close_out oc) (fun () -> output_string oc row)) paths;
          let run label f =
            let results, ms, bytes = measure f paths in
            Printf.printf "%d,%s,%d,%s,%.6f,%.0f\n%!" files phase round label ms bytes;
            results in
          let left,right = if round mod 2 = 0 then
            let right = run "after" after in let left = run "before" before in left,right
          else let left = run "before" before in let right = run "after" after in left,right in
          assert (left = right);
          List.iter (fun n -> assert (n = 1000 + if phase = "append" then round else 0)) left
        done) ["idle"; "append"])) [35;350]
