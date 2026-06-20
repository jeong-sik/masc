(* RFC-0266 Phase 2 — fusion run registry (in-progress + recent visibility).
   Pure in-memory state; tested on isolated [create ()] instances. *)

open Alcotest
module R = Fusion_run_registry

let status_running = function
  | R.Running -> true
  | R.Completed _ -> false
;;

let status_completed_ok = function
  | R.Completed { ok } -> Some ok
  | R.Running -> None
;;

let test_register_then_query () =
  let t = R.create () in
  R.register_running t ~run_id:"r1" ~keeper:"k" ~preset:"balanced" ~started_at:10.0;
  (match R.get t ~run_id:"r1" with
   | Some run ->
     check string "keeper" "k" run.R.keeper;
     check string "preset" "balanced" run.R.preset;
     check bool "is running" true (status_running run.R.status)
   | None -> fail "registered run must be retrievable");
  check int "one run tracked" 1 (List.length (R.list_runs t))
;;

let test_mark_completed () =
  let t = R.create () in
  R.register_running t ~run_id:"r1" ~keeper:"k" ~preset:"deep" ~started_at:1.0;
  R.mark_completed t ~run_id:"r1" ~ok:true;
  (match R.get t ~run_id:"r1" with
   | Some run -> check (option bool) "completed ok=true" (Some true) (status_completed_ok run.R.status)
   | None -> fail "run should still be tracked after completion");
  (* a failed completion records ok=false, not a drop *)
  R.register_running t ~run_id:"r2" ~keeper:"k" ~preset:"deep" ~started_at:2.0;
  R.mark_completed t ~run_id:"r2" ~ok:false;
  match R.get t ~run_id:"r2" with
  | Some run -> check (option bool) "completed ok=false" (Some false) (status_completed_ok run.R.status)
  | None -> fail "failed run must remain visible as Completed{ok=false}"
;;

let test_mark_unknown_is_noop () =
  let t = R.create () in
  R.mark_completed t ~run_id:"ghost" ~ok:true;
  check int "unknown run_id does not create an entry" 0 (List.length (R.list_runs t))
;;

let test_list_newest_first () =
  let t = R.create () in
  R.register_running t ~run_id:"old" ~keeper:"k" ~preset:"p" ~started_at:1.0;
  R.register_running t ~run_id:"new" ~keeper:"k" ~preset:"p" ~started_at:9.0;
  match R.list_runs t with
  | first :: _ -> check string "newest started_at first" "new" first.R.run_id
  | [] -> fail "expected runs"
;;

(* prune invariant: Running survives a flood of completed; oldest completed are
   evicted while the newest are kept (newest-first retention). *)
let test_prune_keeps_running_and_recent () =
  let t = R.create () in
  R.register_running t ~run_id:"active" ~keeper:"k" ~preset:"p" ~started_at:1000.0;
  for i = 0 to 99 do
    let id = Printf.sprintf "c%d" i in
    R.register_running t ~run_id:id ~keeper:"k" ~preset:"p" ~started_at:(float_of_int i);
    R.mark_completed t ~run_id:id ~ok:true
  done;
  (* the Running run is never evicted *)
  (match R.get t ~run_id:"active" with
   | Some run -> check bool "Running survived the flood" true (status_running run.R.status)
   | None -> fail "Running run must never be pruned");
  (* the most recent completed is retained, the oldest is evicted *)
  check bool "newest completed retained" true (Option.is_some (R.get t ~run_id:"c99"));
  check bool "oldest completed evicted" true (Option.is_none (R.get t ~run_id:"c0"));
  (* total is bounded (retention cap + the one Running) *)
  check bool "registry is bounded under flood" true (List.length (R.list_runs t) <= 65)
;;

let () =
  run
    "fusion_run_registry"
    [ ( "rfc-0266-phase2"
      , [ test_case "register then query" `Quick test_register_then_query
        ; test_case "mark completed (ok true/false)" `Quick test_mark_completed
        ; test_case "mark unknown run_id is a no-op" `Quick test_mark_unknown_is_noop
        ; test_case "list_runs is newest-first" `Quick test_list_newest_first
        ; test_case "prune keeps Running + recent completed" `Quick test_prune_keeps_running_and_recent
        ] )
    ]
;;
