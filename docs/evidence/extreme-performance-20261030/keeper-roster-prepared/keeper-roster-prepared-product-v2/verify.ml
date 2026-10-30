module F=Fixture_types
module D=F.Decode
module B=Actual_control_baseline
module C=Actual_control_candidate

let require yes message = if not yes then failwith message
let name i = Printf.sprintf "keeper-%05d" i
let source_rows n = List.init n (fun i ->
    {D.kr_name=name i;runtime_identity=i;kr_keepalive_running=i mod 2=0})

type source_view =
  | Not_observed
  | Complete of D.keeper_runtime list
  | Partial of D.keeper_runtime list * int
  | Invalid_source of D.keeper_runtime list * (string * string) list * bool

let check_source before after =
  let original = match before with
    | B.Roster_unobserved -> Not_observed
    | B.Roster_complete observed -> Complete observed
    | B.Roster_partial {observed;total} -> Partial (observed,total)
    | B.Roster_invalid {observed;errors;complete} -> Invalid_source (observed,errors,complete) in
  let current = match C.roster_view after with
    | C.Roster_unobserved -> Not_observed
    | C.Roster_complete observed -> Complete observed
    | C.Roster_partial {observed;total} -> Partial (observed,total)
    | C.Roster_invalid {observed;errors;complete} -> Invalid_source (observed,errors,complete) in
  require (original=current) "source view contents or constructor changed"

let check_name before after key =
  let left=B.liveness_of_roster before key and right=C.liveness_of_roster after key in
  require (left=right) "reading decision changed";
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
                      check_source before after;
                      List.iter (check_name before after)
                        [name 0;name 1;name 29;name 299;"error-only";"unknown";"Keeper-00001"];
                      count+7) count [0;size;size+List.length errors+1]) count [false;true]) count
            [[];[name 0,"first";name 0,"second"];
             ["error-only","unobserved-error";name 0,"configuration-error"]]) count [false;true])
      0 [0;1;2;30;300] in
  List.iter (check_name B.Roster_unobserved C.unobserved_roster)
    [name 0;"unknown"];
  Printf.printf "{\"reading_comparisons\":%d,\"lifecycle_choice_pairs\":%d,\"scope\":\"Exact product factory/getter/decision fragments with reduced typed runtime records; no complete product-module or TUI native execution, UI ordering or latency proof.\"}\n"
    (checks+2) (2*(checks+2))
