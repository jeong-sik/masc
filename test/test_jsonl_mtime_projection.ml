(** Tests for [Jsonl_mtime_projection] — the shared mtime+size-gated projection
    cache used by dashboard read paths. A [build] counter proves the cache
    actually avoids recomputation (not just that it returns correct values) and
    that each invalidation signal (mtime change, size-only change, any of
    several sources) forces exactly one rebuild. *)

open Alcotest
module P = Masc.Jsonl_mtime_projection

let with_temp_dir f =
  let dir = Filename.temp_file "jsonl_proj_test" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () ->
      (try Sys.readdir dir with _ -> [||])
      |> Array.iter (fun n -> try Sys.remove (Filename.concat dir n) with _ -> ());
      try Unix.rmdir dir with _ -> ())
    (fun () -> f dir)

let write path content ~mtime =
  let oc = open_out path in
  output_string oc content;
  close_out oc;
  Unix.utimes path mtime mtime

let test_caches_until_change () =
  with_temp_dir (fun dir ->
      let p = Filename.concat dir "a.jsonl" in
      write p "one" ~mtime:1000.0;
      let cache = P.create () in
      let builds = ref 0 in
      let run () =
        P.get cache ~key:"k" ~sources:[ p ] ~build:(fun () ->
            incr builds;
            !builds)
      in
      let v1 = run () in
      let v2 = run () in
      check int "build ran once" 1 !builds;
      check int "second call served from cache" v1 v2;
      (* mtime advance invalidates *)
      write p "two" ~mtime:2000.0;
      let _ = run () in
      check int "rebuilt after mtime change" 2 !builds)

let test_size_gate_same_mtime () =
  with_temp_dir (fun dir ->
      let p = Filename.concat dir "a.jsonl" in
      write p "one" ~mtime:1000.0;
      let cache = P.create () in
      let builds = ref 0 in
      let run () =
        P.get cache ~key:"k" ~sources:[ p ] ~build:(fun () -> incr builds)
      in
      run ();
      (* same mtime, larger file — an append a coarse clock would miss *)
      write p "one-two" ~mtime:1000.0;
      run ();
      check int "size change forces rebuild despite equal mtime" 2 !builds)

let test_distinct_keys_independent () =
  with_temp_dir (fun dir ->
      let p = Filename.concat dir "a.jsonl" in
      write p "one" ~mtime:1000.0;
      let cache = P.create () in
      let builds = ref 0 in
      let run key =
        P.get cache ~key ~sources:[ p ] ~build:(fun () -> incr builds)
      in
      run "k1";
      run "k2";
      run "k1";
      check int "each key builds once; k1 reuse is a hit" 2 !builds)

let test_multi_source_any_change () =
  with_temp_dir (fun dir ->
      let a = Filename.concat dir "a.jsonl" in
      let b = Filename.concat dir "b.jsonl" in
      write a "a" ~mtime:1000.0;
      write b "b" ~mtime:1000.0;
      let cache = P.create () in
      let builds = ref 0 in
      let run () =
        P.get cache ~key:"k" ~sources:[ a; b ] ~build:(fun () -> incr builds)
      in
      run ();
      run ();
      check int "stable: one build" 1 !builds;
      write b "b2" ~mtime:2000.0;
      run ();
      check int "change in any source rebuilds" 2 !builds)

let () =
  run "jsonl_mtime_projection"
    [
      ( "gate",
        [
          test_case "caches until a source changes" `Quick test_caches_until_change;
          test_case "size gate catches same-mtime append" `Quick
            test_size_gate_same_mtime;
          test_case "distinct keys are independent" `Quick
            test_distinct_keys_independent;
          test_case "any source change invalidates" `Quick
            test_multi_source_any_change;
        ] );
    ]
