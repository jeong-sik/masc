(* Legendary Bash bg_tasks route — JSON shape tests.

   Exercises [Server_routes_http_routes_legendary_bash.bg_tasks_response]
   directly as a pure function.  The live HTTP handler path and
   extract_path_param wiring are covered by the route pipeline
   integration suite; this file locks the serialisation contract that
   dashboards will consume so it can't silently drift (field names,
   empty-list encoding, keeper echo). *)

open Masc_mcp

let test_empty_keeper_shape () =
  (* Quiet / unknown keeper legitimately returns count=0 and tasks=[].
     The endpoint does not gate on keeper existence — mirrors the
     shadow_counters "zero-cost public read" posture. *)
  let json =
    Server_routes_http_routes_legendary_bash.bg_tasks_response ~keeper:"analyst"
  in
  let s = Yojson.Safe.to_string json in
  Alcotest.(check bool)
    "keeper echoed"
    true
    (Astring.String.is_infix ~affix:"\"keeper\":\"analyst\"" s);
  Alcotest.(check bool)
    "count=0 when no tasks"
    true
    (Astring.String.is_infix ~affix:"\"count\":0" s);
  Alcotest.(check bool)
    "tasks=[] when no tasks"
    true
    (Astring.String.is_infix ~affix:"\"tasks\":[]" s);
  Alcotest.(check bool)
    "task_details=[] when no tasks"
    true
    (Astring.String.is_infix ~affix:"\"task_details\":[]" s)
;;

let test_keeper_with_unusual_name () =
  (* Names can contain hyphens, underscores, digits — the endpoint
     must echo the raw keeper string as-is without normalising. *)
  let json =
    Server_routes_http_routes_legendary_bash.bg_tasks_response ~keeper:"my-keeper_01"
  in
  let s = Yojson.Safe.to_string json in
  Alcotest.(check bool)
    "unusual keeper name echoed"
    true
    (Astring.String.is_infix ~affix:"\"keeper\":\"my-keeper_01\"" s)
;;

let test_field_ordering_stable () =
  (* Dashboards depend on a stable JSON object key order ("keeper"
     first, then "count", then "tasks") so that a human-readable curl
     response mirrors the runbook's documented shape.  Yojson preserves
     [`Assoc] order on serialisation. *)
  let json = Server_routes_http_routes_legendary_bash.bg_tasks_response ~keeper:"x" in
  let s = Yojson.Safe.to_string json in
  (* Locate positions of each key; keeper < count < tasks. *)
  let find_key k =
    match Astring.String.find_sub ~sub:("\"" ^ k ^ "\":") s with
    | Some i -> i
    | None -> -1
  in
  let i_keeper = find_key "keeper" in
  let i_count = find_key "count" in
  let i_tasks = find_key "tasks" in
  let i_details = find_key "task_details" in
  Alcotest.(check bool) "keeper present" true (i_keeper >= 0);
  Alcotest.(check bool) "count present" true (i_count > i_keeper);
  Alcotest.(check bool) "tasks after count" true (i_tasks > i_count);
  Alcotest.(check bool) "task_details after tasks" true (i_details > i_tasks)
;;

let test_task_details_shape_on_empty () =
  (* Even with no live tasks the empty task_details array must parse as
     a JSON array of objects — dashboards that [].map over it without
     a null guard would crash if it were serialised as null / missing. *)
  let json = Server_routes_http_routes_legendary_bash.bg_tasks_response ~keeper:"x" in
  match json with
  | `Assoc fields ->
    (match List.assoc_opt "task_details" fields with
     | Some (`List []) -> ()
     | Some other ->
       Alcotest.failf "expected `List [], got %s" (Yojson.Safe.to_string other)
     | None -> Alcotest.fail "task_details field missing")
  | _ -> Alcotest.fail "response is not a JSON object"
;;

let () =
  Alcotest.run
    "legendary_bash_bg_tasks_route"
    [ ( "shape"
      , [ Alcotest.test_case "empty keeper" `Quick test_empty_keeper_shape
        ; Alcotest.test_case "unusual keeper name" `Quick test_keeper_with_unusual_name
        ; Alcotest.test_case "field ordering stable" `Quick test_field_ordering_stable
        ; Alcotest.test_case
            "task_details empty shape"
            `Quick
            test_task_details_shape_on_empty
        ] )
    ]
;;
