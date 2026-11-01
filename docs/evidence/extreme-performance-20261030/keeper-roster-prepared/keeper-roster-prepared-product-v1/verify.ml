module F=Fixture_types
module D=F.Decode
module B=Actual_control_baseline
module C=Actual_control_candidate

let require yes message = if not yes then failwith message
let name i = Printf.sprintf "keeper-%05d" i
let source_rows n = List.init n (fun i ->
    {D.kr_name=name i;runtime_identity=i;kr_keepalive_running=i mod 2=0})

let check_source rows before after =
  let original = function
    | B.Roster_unobserved -> None,0,false
    | B.Roster_complete observed -> Some observed,List.length observed,true
    | B.Roster_partial {observed;total} -> Some observed,total,false
    | B.Roster_invalid {observed;errors;complete} -> Some observed,List.length errors,complete in
  let current = match C.roster_view after with
    | C.Roster_unobserved -> None,0,false
    | C.Roster_complete observed -> Some observed,List.length observed,true
    | C.Roster_partial {observed;total} -> Some observed,total,false
    | C.Roster_invalid {observed;errors;complete} -> Some observed,List.length errors,complete in
  let _,old_total,old_complete=original before in
  let actual,now_total,now_complete=current in
  require (old_total=now_total && old_complete=now_complete) "view metadata changed";
  match actual with
  | None -> ()
  | Some observed -> require (observed==rows) "original source list replaced"

let check_name before after key =
  let left=B.liveness_of_roster before key and right=C.liveness_of_roster after key in
  require (left=right) "reading decision changed";
  (match left,right with
   | F.Control.Present a,F.Control.Present b -> require (a==b) "runtime identity changed"
   | (F.Control.Unobserved | Invalid _ | Absent),_
   | F.Control.Present _,(F.Control.Unobserved | Invalid _ | Absent) -> ());
  List.iter (fun paused ->
      let a={F.Control.name=key;paused;liveness=left} in
      let b={F.Control.name=key;paused;liveness=right} in
      require (B.runs a=C.runs b) "running authority changed";
      require (B.available a=C.available b) "lifecycle choices changed") [false;true]

let () =
  let checks=List.fold_left (fun count size ->
      let rows=source_rows size in
      List.fold_left (fun count duplicates ->
          let rows=match rows with [] -> [] | first::_ when duplicates ->
              rows @ [{first with D.runtime_identity=100_000;kr_keepalive_running=false}]
            | _ -> rows in
          List.fold_left (fun count errors ->
              List.fold_left (fun count truncated ->
                  List.fold_left (fun count total ->
                      let before=B.roster_of_reading ~rows ~errors ~truncated ~total in
                      let after=C.roster_of_reading ~rows ~errors ~truncated ~total in
                      check_source rows before after;
                      List.iter (check_name before after)
                        [name 0;name 1;name 29;name 299;"error-only";"unknown";"Keeper-00001"];
                      count+7) count [0;size;size+List.length errors+1]) count [false;true]) count
            [[];[name 0,"first";name 0,"second"];
             ["error-only","unobserved-error";name 0,"configuration-error"]]) count [false;true])
      0 [0;1;2;30;300] in
  List.iter (check_name B.Roster_unobserved C.unobserved_roster)
    [name 0;"unknown"];
  Printf.printf "{\"reading_comparisons\":%d,\"lifecycle_choice_pairs\":%d,\"scope\":\"Exact product factory/getter/decision fragments with reduced typed runtime records; no complete module, UI ordering, native execution or latency proof.\"}\n"
    (checks+2) (2*(checks+2))
