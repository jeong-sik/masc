let oracle entries wanted =
  let rec loop index total = function
    | _ when total >= wanted -> index, total
    | [] -> index,total
    | n :: rest -> loop (index+1) (total+n) rest
  in loop 0 0 (List.rev entries)
let checksum = ref 0
let checks = ref 0
let check entries requests =
  let before=Before.row_counts_for entries ~inner_width:80 ~origin:Before.Origin_row in
  let after=After.row_counts_for entries ~inner_width:80 ~origin:After.Origin_row in
  List.iter (fun wanted ->
    let expected=oracle entries wanted in
    let old=Before.count_rows_until before ~wanted () in
    let proposed=After.count_rows_until after ~wanted () in
    if old<>expected || proposed<>expected then failwith "prefix admission decision differs";
    let visited,total=proposed in
    List.iter (fun from_bottom ->
      let first=After.first_row_count_at_least after ~wanted:(from_bottom+1) in
      let rec linear i sum =
        if i>=visited then visited else
        let sum=sum+List.nth (List.rev entries) i in
        if sum>from_bottom then i else linear (i+1) sum
      in
      if min visited first <> linear 0 0 then failwith "first selected entry differs";
      incr checks) [0;total/2;max 0 (total-1);total];
    incr checks) requests
let now ()=Mtime_clock.elapsed_ns ()
let cpu ()=let t=Unix.times () in t.Unix.tms_utime+.t.Unix.tms_stime
let () =
 let rng=Random.State.make [|20261030;39|] in
 List.iter (fun entries -> check entries [-5;0;1;2;9;30;300;100000])
   [[];[0];[1];[3;0;0;0];[0;0;3];List.init 300 (fun _->0)];
 for trial=0 to 599 do
   let entries=List.init (Random.State.int rng 301) (fun _->Random.State.int rng 11) in
   let total=List.fold_left (+) 0 entries in
   check entries (List.init 24 (fun _ -> Random.State.int rng (max 1 (total+100))-5))
 done;
 let records=ref [] in
 List.iter (fun size ->
  let entries=List.init size (fun i -> if i mod 11=0 then 0 else 1+i mod 5) in
  let total=List.fold_left (+) 0 entries in
  let wanted=max 1 (total*9/10) in
  let expected=oracle entries wanted in
  List.iter (fun mode ->
   for batch=0 to 7 do
    let order=if batch mod 2=0 then ["before";"after"] else ["after";"before"] in
    List.iter (fun version ->
      let calls=if mode="hot" then 10000 else 20 in
      let old=Before.row_counts_for entries ~inner_width:80 ~origin:Before.Origin_row in
      let proposed=After.row_counts_for entries ~inner_width:80 ~origin:After.Origin_row in
      ignore (Before.count_rows_until old ~wanted ());ignore (After.count_rows_until proposed ~wanted ());
      Gc.full_major ();
      let allocated=Gc.allocated_bytes () and c=cpu () and t=now () in
      for _=1 to calls do
        let answer=if version="before" then (
          let held=if mode="hot" then old else (Before.row_counts_memo:=None;Before.row_counts_for entries ~inner_width:80 ~origin:Before.Origin_row) in
          Before.count_rows_until held ~wanted ())
        else (
          let held=if mode="hot" then proposed else (After.row_counts_memo:=None;After.row_counts_for entries ~inner_width:80 ~origin:After.Origin_row) in
          After.count_rows_until held ~wanted ()) in
        if answer<>expected then failwith "measured navigation decision differs";
        checksum := !checksum lxor fst answer lxor snd answer
      done;
      let wall=Int64.to_float (Int64.sub (now ()) t)/.1000. and used_cpu=(cpu()-.c)*.1e6 in
      let bytes=Gc.allocated_bytes ()-.allocated in
      records := `Assoc ["entries",`Int size;"mode",`String mode;"version",`String version;
        "batch",`Int batch;"calls",`Int calls;"wall_us",`Float wall;"cpu_us",`Float used_cpu;
        "allocated_bytes",`Float bytes] :: !records) order
   done) ["hot";"cold"]) [30;300;3000;30000];
 Yojson.Safe.to_channel stdout (`Assoc ["scope",`String "Extracted count/index navigation decisions with integer row-count adapter. Not formatting, full TUI rendering, requests or physical display latency. Hot counts prefilled; cold includes new cache arrays and simulated per-entry rows. Per-call answer checking is included equally. Eight AB/BA batches; default runtime, shared host.";"checks",`Int !checks;"checksum",`Int !checksum;"records",`List (List.rev !records)]);
 print_newline ()
