module F = Fixture_types
module C = F.Control
module D = F.Tui_decode
module P = Prepared_roster

let require yes message = if not yes then failwith message
let name index = Printf.sprintf "keeper-%05d" index
let rows count = List.init count (fun index -> {D.kr_name=name index; runtime_identity=index})
let reading_value = function
  | C.Unobserved -> -1 | C.Absent -> -2 | C.Invalid detail -> String.length detail
  | C.Present row -> row.D.runtime_identity

let validate () =
  let cases = List.concat_map (fun count ->
      let observed = rows count in
      let observed = match observed with [] -> [] | first :: _ -> observed @ [{first with D.runtime_identity=100_000}] in
      let errors = [name 0,"first"; name 0,"second"; "unknown","unobserved-error"] in
      [C.Roster_unobserved; C.Roster_complete observed;
       C.Roster_partial {observed;total=count+1};
       C.Roster_invalid {observed;errors;complete=true};
       C.Roster_invalid {observed;errors;complete=false}]) [0;1;2;30;300] in
  List.iter (fun source ->
      let prepared = P.prepare source in
      require (P.view prepared == source) "original source identity changed";
      List.iter (fun key ->
          let before = Control_baseline.liveness_of_roster source key in
          let after = P.liveness prepared key in
          require (before=after) "roster reading decision differs";
          match before,after with
          | C.Present a,C.Present b -> require (a==b) "runtime object identity changed"
          | (C.Unobserved | Absent | Invalid _),_
          | C.Present _,(C.Unobserved | Absent | Invalid _) -> ())
        [name 0;name 1;name 29;name 299;"unknown";"missing"]) cases;
  let old_source = C.Roster_complete [{D.kr_name=name 0;runtime_identity=1}] in
  let new_source = C.Roster_invalid {observed=[];errors=[name 0,"new-error"];complete=false} in
  let old = P.prepare old_source and current = P.prepare new_source in
  require (P.liveness current (name 0)=C.Invalid "new-error") "replacement reused old reading";
  require (P.liveness current "missing"=C.Unobserved) "replacement fabricated absence";
  require (P.view old == old_source && P.view current == new_source) "source ownership changed";
  List.length cases * 6

let checksum read keys = List.fold_left (fun total key -> total + reading_value (read key)) 0 keys
let measure label count iterations round fn =
  ignore (Sys.opaque_identity (fn ()));
  Gc.full_major ();
  let alloc_before=Gc.allocated_bytes () in
  let cpu_before=Sys.time () in
  let before=Mtime_clock.elapsed_ns () in
  for _=1 to iterations do ignore (Sys.opaque_identity (fn ())) done;
  let wall=Int64.sub (Mtime_clock.elapsed_ns ()) before in
  let cpu=Sys.time () -. cpu_before in
  let alloc=Gc.allocated_bytes () -. alloc_before in
  Printf.printf "{\"case\":%S,\"roster_rows\":%d,\"iterations\":%d,\"round\":%d,\"wall_ns\":%Ld,\"cpu_s\":%.9f,\"allocated_bytes\":%.0f}\n%!"
    label count iterations round wall cpu alloc

let () =
  Printf.printf "{\"scope\":\"Research prototype with reduced runtime records. No full product compile, TUI frame, real fetch/decode, workspace/caller authority or physical paint claim.\",\"reading_comparisons\":%d,\"ocaml_version\":%S}\n%!" (validate ()) Sys.ocaml_version;
  List.iter (fun count ->
      let observed=rows count in
      let source=C.Roster_complete observed in
      let keys=List.init count name in
      let first_key=name 0 in
      let prepared=P.prepare source in
      let iterations=if count>=3000 then 2 else if count>=300 then 100 else 2000 in
      let operations=[
        "source-construction",(fun () ->
            let constructed=C.roster_of_reading ~errors:[] ~rows:observed ~truncated:false ~total:count in
            ignore (Sys.opaque_identity constructed);0);
        "cold-source-preparation",(fun () ->
            let constructed=C.roster_of_reading ~errors:[] ~rows:observed ~truncated:false ~total:count in
            ignore (Sys.opaque_identity (P.prepare constructed));0);
        "prepare-only",(fun () -> ignore (Sys.opaque_identity (P.prepare source));0);
        "linear-batch",(fun () -> checksum (Control_baseline.liveness_of_roster source) keys);
        "cold-prepared-batch",(fun () -> checksum (P.liveness (P.prepare source)) keys);
        "warm-prepared-batch",(fun () -> checksum (P.liveness prepared) keys);
        "linear-first",(fun () -> reading_value (Control_baseline.liveness_of_roster source first_key));
        "cold-prepared-first",(fun () -> reading_value (P.liveness (P.prepare source) first_key));
        "warm-prepared-first",(fun () -> reading_value (P.liveness prepared first_key));
      ] in
      for round=1 to 5 do
        List.iter (fun (label,fn) -> measure label count iterations round fn)
          (if round mod 2=1 then operations else List.rev operations)
      done) [0;1;2;30;300;3000]
