open Fixture_types
module D = Tui_decode
module C = Control
module A = Masc.Tui_decode_asks

let require condition message = if not condition then failwith message
let name i = Printf.sprintf "keeper-%05d" i
let task_id i = Printf.sprintf "task-%05d" i

let make ~keepers ~side ~dense ~declared ~duplicates =
  let keepers = List.init keepers (fun i ->
      { D.k_name = name i; k_paused = i mod 2 = 0;
        k_origin = if declared then D.Declared_keeper "fixture"
                   else if i mod 2 = 0 then D.Persisted_keeper else D.Remote_keeper;
        k_activity = if dense then Some {D.k_current_task_id = Some (task_id i)} else None;
        source_identity = i }) in
  let keepers = match keepers with
    | first :: _ when duplicates -> keepers @ [{first with D.source_identity = 100_000}]
    | _ -> keepers in
  let observed = List.init side (fun i -> {D.kr_name = name i; runtime_identity = i}) in
  let observed = match observed with
    | first :: _ when duplicates -> observed @ [{first with D.runtime_identity = 100_001}]
    | _ -> observed in
  let turns = if dense then List.init side (fun i -> {D.ktr_keeper_name = name i; ktr_state = D.Turn i}) else [] in
  let turns = match turns with
    | first :: _ when duplicates -> turns @ [{first with D.ktr_state = D.Turn 100_002}]
    | _ -> turns in
  let waiting = if dense then List.init side (fun i -> {D.kwr_keeper_name = name i; waiting_identity = i}) else [] in
  let approvals = if dense then List.init side (fun i -> {D.kta_keeper = name i; approval_identity = i}) else [] in
  let tasks = if dense then List.init side (fun i ->
      {D.id = task_id i; status = if i mod 3 = 0 then Masc_domain.AwaitingVerification {assignee = name i}
                                 else if i mod 3 = 1 then Masc_domain.InProgress () else Masc_domain.Done ();
       task_identity = i}) else [] in
  let tasks = match tasks with
    | first :: _ when duplicates -> tasks @ [{first with D.status = Masc_domain.AwaitingVerification {assignee=name 1}; task_identity=100_003}]
    | _ -> tasks in
  let asks = if dense then List.init (side * 2) (fun i -> {A.ar_asker = A.Ask_keeper (name (i mod (max 1 side)))})
                @ [{A.ar_asker = A.Ask_installation "unrelated"}] else [] in
  let requests = if dense then List.init (side * 3) (fun i -> {D.ar_keeper_name = name (i mod (max 1 side)); async_identity = i}) else [] in
  { keepers; keeper_roster=C.Roster_complete observed; keeper_turns=turns;
    keeper_waiting=waiting; keeper_waiting_failure=None; keeper_tool_approvals=approvals;
    tasks; asks_snapshot=Some {A.asn_rows=asks}; tools_async_observation=Some (D.Async_ready {requests});
    keeper_list_layout=(); keeper_list_sort=() }

let canonical_metadata rows =
  (* Key by the original fixture identity, deliberately ignoring UI row order. *)
  List.sort (fun (left : Model.row) right ->
      Int.compare left.keeper.source_identity right.keeper.source_identity) rows

let check state =
  let before = Projection_baseline.keeper_list_rows state in
  let after = Projection_candidate.keeper_list_rows state in
  require (canonical_metadata before = canonical_metadata after) "metadata/decision mismatch";
  List.iter (fun (row : Model.row) ->
      require (List.exists (fun keeper -> keeper == row.keeper) state.keepers)
        "projection lost original keeper object") after

let validate () =
  let cases = List.concat_map (fun keepers -> List.concat_map (fun side ->
      List.concat_map (fun declared -> List.map (fun duplicates ->
          make ~keepers ~side ~dense:true ~declared ~duplicates) [false;true]) [false;true])
      [0;1;2;7]) [0;1;2;8] in
  List.iter (fun state ->
      let observed = match state.keeper_roster with C.Roster_complete rows -> rows
        | C.Roster_unobserved | C.Roster_partial _ | C.Roster_invalid _ -> [] in
      let errors = [name 0,"first-error"; name 0,"second-error"; "missing","unobserved-error"] in
      let rosters = [C.Roster_unobserved; C.Roster_complete observed;
        C.Roster_partial {observed;total=99}; C.Roster_invalid {observed;errors;complete=false};
        C.Roster_invalid {observed;errors;complete=true}] in
      List.iter (fun roster ->
          let prepared = Control_candidate.liveness_reader roster in
          List.iter (fun key ->
              require (Control_baseline.liveness_of_roster roster key = prepared key)
                "lifecycle reading differs") [name 0;name 1;name 7;"missing";"unseen"];
          List.iter (fun waiting_failure ->
              let state = {state with keeper_roster=roster; keeper_waiting_failure=waiting_failure} in
              check state;
              check {state with tools_async_observation=Some (D.Async_unavailable "fixture")};
              check {state with asks_snapshot=None;tools_async_observation=None}) [None;Some "unread"])
        rosters) cases;
  List.length cases * 5 * 2 * 3

let run label state iterations variant fn round =
  ignore (Sys.opaque_identity (fn state));
  Gc.full_major ();
  let allocation_before = Gc.allocated_bytes () in
  let cpu_before = Sys.time () in
  let before = Mtime_clock.elapsed_ns () in
  for _ = 1 to iterations do ignore (Sys.opaque_identity (fn state)) done;
  let elapsed = Int64.sub (Mtime_clock.elapsed_ns ()) before in
  let cpu = Sys.time () -. cpu_before in
  let allocation = Gc.allocated_bytes () -. allocation_before in
  Printf.printf "{\"case\":%S,\"round\":%d,\"variant\":%S,\"iterations\":%d,\"keepers\":%d,\"wall_ns\":%Ld,\"cpu_s\":%.9f,\"allocated_bytes\":%.0f}\n%!"
    label round variant iterations (List.length state.keepers) elapsed cpu allocation

let () =
  let checked = validate () in
  Printf.printf "{\"metadata_decision_cases\":%d,\"scope\":\"Reduced typed records; no rendered UI text, layout or row-order assertion; identical no-op activity and sorting stubs.\"}\n%!" checked;
  let cases = [
    "empty",0,300,true,false,2000;
    "one-dense",1,1,true,false,5000;
    "two-dense",2,2,true,false,5000;
    "thirty-dense",30,30,true,false,500;
    "threehundred-dense",300,300,true,false,50;
    "threethousand-dense",3000,3000,true,false,1;
    "threehundred-sparse",300,300,false,false,100;
    "two-large-sides",2,3000,true,false,10;
    "threehundred-declared",300,300,true,true,50
  ] in
  List.iter (fun (label,keepers,side,dense,declared,iterations) ->
      let state = make ~keepers ~side ~dense ~declared ~duplicates:false in
      for round = 1 to 5 do
        if round mod 2 = 1 then (
          run label state iterations "baseline" Projection_baseline.keeper_list_rows round;
          run label state iterations "candidate" Projection_candidate.keeper_list_rows round)
        else (
          run label state iterations "candidate" Projection_candidate.keeper_list_rows round;
          run label state iterations "baseline" Projection_baseline.keeper_list_rows round)
      done) cases
