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

let yojson_field j k =
  match j with
  | `Assoc l -> List.assoc_opt k l
  | _ -> None
;;

let yojson_str j k =
  match yojson_field j k with
  | Some (`String s) -> s
  | _ -> Printf.ksprintf failwith "missing string field %s" k
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

(* Phase 4: the shared status vocabulary used by the dashboard route + SSE +
   keeper tool. "failed" (ok=false) must never collapse into "completed". *)
let test_status_label () =
  check string "running label" "running" (R.status_label R.Running);
  check string "completed label" "completed" (R.status_label (R.Completed { ok = true }));
  check string "failed label" "failed" (R.status_label (R.Completed { ok = false }))
;;

(* Phase 4: run_to_yojson is the one per-run serializer for every fusion-run
   surface — the field set and the status label are asserted here so a drift
   between the HTTP list, the SSE delta, and the tool is caught at the source. *)
let test_run_to_yojson_shape () =
  let t = R.create () in
  R.register_running t ~run_id:"r-ser" ~keeper:"kx" ~preset:"deep" ~started_at:42.0;
  R.mark_completed t ~run_id:"r-ser" ~ok:false;
  match R.get t ~run_id:"r-ser" with
  | None -> fail "run must be present"
  | Some run ->
    let j = R.run_to_yojson run in
    check string "run_id" "r-ser" (yojson_str j "run_id");
    check string "keeper" "kx" (yojson_str j "keeper");
    check string "preset" "deep" (yojson_str j "preset");
    check string "status label (ok=false -> failed)" "failed" (yojson_str j "status");
    (match yojson_field j "started_at" with
     | Some (`Float f) -> check (float 0.001) "started_at" 42.0 f
     | _ -> fail "started_at must serialize as a float field")
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
    ; ( "rfc-0266-phase4"
      , [ test_case "status_label vocabulary" `Quick test_status_label
        ; test_case "run_to_yojson shape + label" `Quick test_run_to_yojson_shape
        ] )
    ]
;;
