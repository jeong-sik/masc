let checks=ref 0
let flatten entries =
 List.concat (List.mapi (fun entry_index count ->
  let body=ref 0 in
  List.init count (fun offset ->
   let is_body=offset mod 7<>0 && offset mod 11<>0 in
   let ordinal= !body in if is_body then incr body;
   entry_index,ordinal,is_body)) entries)
let expected entries height requested =
 let all=flatten entries in
 let total=List.length all in
 let scroll=min requested (max 0 (total-max 1 height)) in
 let bottom=max 0 (total-scroll) in
 let first=max 0 (bottom-max 0 height) in
 let positions=List.filter_map (fun (at,(entry,body,is_body)) ->
   if at>=first && at<bottom && is_body then Some (entry,body,bottom-at-1) else None)
   (List.mapi (fun i x->i,x) all) in
 scroll,positions
let expected_anchor entries entry body =
 let all=flatten entries in
 let rec find at = function
 | [] -> None
 | (e,b,is_body)::rest -> if e=entry && b=body && is_body then Some(List.length all-at-1) else find(at+1) rest
 in if body<0 then None else find 0 all
let check entries requested height =
 let want=expected entries height requested in
 let old=Before.clamped_scrolled_rows ~inner_width:80 ~height ~requested entries in
 let proposed=After.clamped_scrolled_rows ~inner_width:80 ~height ~requested entries in
 let before=old.Before.scroll,List.map (fun (p:Before.body_row_position)->p.entry_index,p.body_row,p.rows_below) old.body_positions in
 let after=proposed.After.scroll,List.map (fun (p:After.body_row_position)->p.entry_index,p.body_row,p.rows_below) proposed.body_positions in
 if before<>want || after<>want then failwith "viewport input-anchor decision differs";
 incr checks;
 List.iter (fun entry -> List.iter (fun body ->
   let target=expected_anchor entries entry body in
   let before=Before.scroll_for_body_row ~inner_width:80 ~entry_index:entry ~body_row:body entries in
   let after=After.scroll_for_body_row ~inner_width:80 ~entry_index:entry ~body_row:body entries in
   if before<>target || after<>target then failwith "anchor-to-scroll decision differs";
   incr checks) [-1;0;1;4;30]) [-1;0;List.length entries/2;List.length entries-1;List.length entries]
let now()=Mtime_clock.elapsed_ns()
let cpu()=let t=Unix.times() in t.Unix.tms_utime+.t.Unix.tms_stime
let checksum=ref 0
let () =
 let random=Random.State.make [|20261030;41|] in
 List.iter (fun entries->List.iter (fun requested->List.iter (check entries requested) [-2;0;1;9;45]) [1;2;30;300;100000])
  [[];[0];[1];[2;0;0];[0;0;3];List.init 120(fun _->0)];
 for _=1 to 350 do
  let entries=List.init (Random.State.int random 121) (fun _->Random.State.int random 14) in
  for _=1 to 12 do check entries (1+Random.State.int random 1800) (Random.State.int random 60-2) done
 done;
 let records=ref [] in
 List.iter (fun size->
  let entries=List.init size (fun i->if i mod 11=0 then 0 else 1+i mod 5) in
  let total=List.fold_left (+) 0 entries in
  let requested=max 1 (total*9/10) in
  List.iter (fun mode->for batch=0 to 7 do
   let order=if batch mod 2=0 then ["before";"after"] else ["after";"before"] in
   List.iter (fun version->
    let calls=if mode="hot" then (if size>=30000 then 2000 else 10000) else 20 in
    ignore(Before.clamped_scrolled_rows ~inner_width:80 ~height:40 ~requested entries);
    ignore(After.clamped_scrolled_rows ~inner_width:80 ~height:40 ~requested entries);
    Gc.full_major();let allocated=Gc.allocated_bytes() and c=cpu() and t=now() in
    for _=1 to calls do
     let answer=if version="before" then (
       if mode="cold" then Before.row_counts_memo:=None;
       let w=Before.clamped_scrolled_rows ~inner_width:80 ~height:40 ~requested entries in w.Before.scroll,List.length w.body_positions)
     else (
       if mode="cold" then After.row_counts_memo:=None;
       let w=After.clamped_scrolled_rows ~inner_width:80 ~height:40 ~requested entries in w.After.scroll,List.length w.body_positions) in
     checksum := !checksum lxor fst answer lxor snd answer
    done;
    let wall=Int64.to_float(Int64.sub(now())t)/.1000. and used_cpu=(cpu()-.c)*.1e6 in
    let bytes=Gc.allocated_bytes()-.allocated in
    records:=`Assoc["entries",`Int size;"mode",`String mode;"version",`String version;"batch",`Int batch;
      "calls",`Int calls;"wall_us",`Float wall;"cpu_us",`Float used_cpu;"allocated_bytes",`Float bytes]::!records) order
  done) ["hot";"cold"]) [30;300;3000;30000];
 Yojson.Safe.to_channel stdout (`Assoc["scope",`String "Extracted actual viewport/anchor algorithms with synthetic metadata/body rows; state and input-anchor decisions only. Not full formatting, TUI Build/Present or display latency. Eight AB/BA batches, shared host and default runtime.";
   "decision_checks",`Int !checks;"checksum",`Int !checksum;"records",`List(List.rev !records)]);print_newline()
