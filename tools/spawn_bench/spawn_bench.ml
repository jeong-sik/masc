(* Spawn latency with a large live heap: eio_posix (fork) vs posix_spawn. *)
let live_mb = try int_of_string Sys.argv.(1) with _ -> 1500
let rounds = try int_of_string Sys.argv.(2) with _ -> 20

let () =
  Eio_main.run @@ fun env ->
  (* Keep [live_mb] of small heap blocks alive so the major heap resembles the server's. *)
  let chunk = 4096 in
  let keep = Array.init (live_mb * 1024 * 1024 / chunk) (fun i -> Bytes.make chunk (Char.chr (i land 255))) in
  Gc.full_major ();
  let stat = Gc.quick_stat () in
  Printf.printf "live heap ~%d MB (heap_words=%d)\n%!" (stat.Gc.heap_words * 8 / 1024 / 1024) stat.Gc.heap_words;
  let time mgr label =
    let samples =
      List.init rounds (fun _ ->
        let t0 = Unix.gettimeofday () in
        (* ignore: the sample measures spawn latency only; /usr/bin/true emits nothing worth consuming *)
        ignore (Eio.Process.parse_out mgr Eio.Buf_read.take_all [ "/usr/bin/true" ]);
        (Unix.gettimeofday () -. t0) *. 1000.0)
      |> List.sort compare
    in
    let nth p = List.nth samples (min (rounds - 1) (p * rounds / 100)) in
    Printf.printf "%-12s p50=%.1fms p90=%.1fms max=%.1fms\n%!" label (nth 50) (nth 90) (List.nth samples (rounds - 1))
  in
  time (Eio.Stdenv.process_mgr env) "fork";
  time Posix_spawn_process_mgr.mgr "posix_spawn";
  time (Eio.Stdenv.process_mgr env) "fork";
  time Posix_spawn_process_mgr.mgr "posix_spawn";
  (* ignore: keeps [keep] reachable so the live heap survives to the end of the benchmark *)
  ignore (Sys.opaque_identity keep)
