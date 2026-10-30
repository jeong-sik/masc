module C = Fixture_types.Control
module D = Fixture_types.Tui_decode
module P = Prepared_roster

let live_words () =
  Gc.full_major ();
  (Gc.stat ()).live_words

let measure count round =
  let observed = List.init count (fun i ->
      {D.kr_name=Printf.sprintf "keeper-%05d" i; runtime_identity=i}) in
  let source=C.Roster_complete observed in
  let before=live_words () in
  let prepared=P.prepare source in
  let after=live_words () in
  ignore (Sys.opaque_identity prepared);
  ignore (Sys.opaque_identity source);
  Printf.printf "{\"roster_rows\":%d,\"round\":%d,\"before_live_words\":%d,\"after_live_words\":%d,\"delta_live_words\":%d,\"word_bits\":%d}\n%!"
    count round before after (after-before) Sys.word_size

let () =
  Printf.printf "{\"scope\":\"Separate-process GC live-word increment while one prepared source stays reachable; original source is already reachable before preparation. Not RSS, allocator capacity, peak memory, stale-result reclamation or real refresh cadence.\",\"ocaml_version\":%S}\n%!" Sys.ocaml_version;
  List.iter (fun count -> for round=1 to 5 do measure count round done)
    [0;1;2;30;300;3000]
