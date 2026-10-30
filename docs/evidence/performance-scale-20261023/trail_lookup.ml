type live_tool_call = {local_id : int; result : int}
type transcript = {reversed_tool_calls : live_tool_call list}
let before t ids =
  let call_of local_id =
    List.find_opt
      (fun (call : live_tool_call) -> call.local_id = local_id)
      t.reversed_tool_calls
  in
 List.map call_of ids
;;
let after t ids =
  (* Resolve each trail node against this projection's current call records.
     Searching the complete list for every node made a long turn quadratic.
     The index is local: late results and superseded attempts are read anew
     on the next projection, with no second mutable store to keep in sync. *)
  let calls = Hashtbl.create (List.length t.reversed_tool_calls) in
  List.iter
    (fun (call : live_tool_call) -> Hashtbl.add calls call.local_id call)
    t.reversed_tool_calls;
  let call_of local_id = Hashtbl.find_opt calls local_id in
 List.map call_of ids
;;

let measure f t ids =
  Gc.full_major ();
  let allocated = Gc.allocated_bytes () in
  let started = Unix.gettimeofday () in
  let value = f t ids in
  let elapsed = (Unix.gettimeofday () -. started) *. 1000. in
  let bytes = Gc.allocated_bytes () -. allocated in
  ignore (Sys.opaque_identity value);
  elapsed, bytes
;;
let () =
  List.iter (fun n ->
    let calls = List.init n (fun i -> { local_id = i; result = i * 3 }) in
    let t = { reversed_tool_calls = List.rev calls } in
    let ids = List.init n Fun.id in
    assert (before t ids = after t ids);
    assert (after t [-1; n] = [None; None]);
    let late = { reversed_tool_calls = List.map (fun call ->
      if call.local_id = 0 then {call with result = -42} else call) t.reversed_tool_calls } in
    assert (before late ids = after late ids);
    for round = 1 to 9 do
      let run label f =
        let ms, bytes = measure f t ids in
        Printf.printf "%d,%d,%s,%.6f,%.0f\n%!" n round label ms bytes in
      if round mod 2 = 0 then (run "after" after; run "before" before)
      else (run "before" before; run "after" after)
    done) [35;350;3500;10000]
;;
