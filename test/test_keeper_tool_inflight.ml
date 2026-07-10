(** Tests for Keeper_tool_inflight (RFC-0336 Phase A). The registry is the
    authoritative "running now" source; these cover the CRUD contract, the
    honest-ETA rule, and the keeper filter/sort. *)

open Masc.Keeper_tool_inflight

let test_register_and_list () =
  clear ();
  let e = register ~keeper_name:"k1" ~tool_name:"t1" ~job_id:"j1" () in
  Alcotest.(check string) "register returns the job_id" "j1" e.job_id;
  Alcotest.(check string) "register keeps tool_name" "t1" e.tool_name;
  Alcotest.(check bool) "no deadline_ms -> deadline_at None"
    true (Option.is_none e.deadline_at);
  Alcotest.(check int) "list k1 has 1" 1 (List.length (list ~keeper_name:"k1"));
  Alcotest.(check int) "list k2 has 0" 0 (List.length (list ~keeper_name:"k2"))
;;

let test_deadline_only_when_supplied () =
  clear ();
  let e = register ~keeper_name:"k1" ~tool_name:"t1" ~deadline_ms:5000 ~job_id:"j1" () in
  (match e.deadline_at with
   | None -> Alcotest.fail "deadline_at should be Some when deadline_ms given"
   | Some d ->
     Alcotest.(check bool) "deadline_at after started_at" true (d > e.started_at);
     Alcotest.(check bool) "deadline_at ~= started + 5s" true
       (Float.abs (d -. (e.started_at +. 5.0)) < 0.001));
  let e' = register ~keeper_name:"k1" ~tool_name:"t2" ~job_id:"j2" () in
  Alcotest.(check bool) "no deadline_ms -> None" true (Option.is_none e'.deadline_at)
;;

let test_unregister_and_absent_noop () =
  clear ();
  let _ = register ~keeper_name:"k1" ~tool_name:"t1" ~job_id:"j1" () in
  unregister ~job_id:"j1";
  Alcotest.(check int) "unregister removes entry" 0
    (List.length (list ~keeper_name:"k1"));
  (* unregister of an absent id must be a no-op, not raise *)
  unregister ~job_id:"absent";
  Alcotest.(check int) "unregister absent is no-op" 0
    (List.length (list ~keeper_name:"k1"))
;;

let test_filter_sort_list_all () =
  clear ();
  let _ = register ~keeper_name:"k1" ~tool_name:"t1" ~job_id:"j1" () in
  let _ = register ~keeper_name:"k2" ~tool_name:"t2" ~job_id:"j2" () in
  let _ = register ~keeper_name:"k1" ~tool_name:"t3" ~job_id:"j3" () in
  Alcotest.(check int) "list k1 filters to 2" 2 (List.length (list ~keeper_name:"k1"));
  Alcotest.(check int) "list k2 filters to 1" 1 (List.length (list ~keeper_name:"k2"));
  Alcotest.(check int) "list_all has 3" 3 (List.length (list_all ()));
  (* re-register same job_id replaces, does not duplicate *)
  let _ = register ~keeper_name:"k1" ~tool_name:"t1-replaced" ~job_id:"j1" () in
  Alcotest.(check int) "re-register replaces (no dup)" 2
    (List.length (list ~keeper_name:"k1"))
;;

let () =
  Alcotest.run
    "keeper_tool_inflight"
    [ "register/list", [ "register + list + no-deadline", `Quick, test_register_and_list ]
    ; "deadline", [ "deadline_at only when deadline_ms supplied", `Quick, test_deadline_only_when_supplied ]
    ; "unregister", [ "unregister + absent no-op", `Quick, test_unregister_and_absent_noop ]
    ; "list", [ "filter / sort / list_all / replace", `Quick, test_filter_sort_list_all ]
    ]
;;
