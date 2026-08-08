(** Unit tests for Trajectory — construction, serialization, metrics.

    Targets 53 uncovered points in lib/trajectory.ml. *)

open Agent_sdk

let () = Printexc.record_backtrace true
let tc name f = Alcotest.test_case name `Quick f

(* ── Tool call helpers ───────────────────────────────────────── *)

let mk_tool_call
      ?(id = "tc-1")
      ?(name = "bash")
      ?(is_error = false)
      ?(started = 1.0)
      ?finished
      ?(result = None)
      ()
  : Trajectory.tool_call
  =
  { tool_use_id = id
  ; tool_name = name
  ; tool_input = `Assoc [ "cmd", `String "ls" ]
  ; tool_result = result
  ; is_error
  ; started_at = started
  ; finished_at = finished
  }
;;

let mk_trajectory ?(steps = []) ?(success = true) ?finished ?error ()
  : Trajectory.trajectory
  =
  { agent_name = "test-agent"
  ; model = "test-model"
  ; prompt = "do stuff"
  ; steps
  ; started_at = 100.0
  ; finished_at = finished
  ; success
  ; metrics = None
  ; error
  }
;;

(* ── show / pp ───────────────────────────────────────────────── *)

let test_show_tool_call () =
  let tc = mk_tool_call ~id:"abc" ~name:"read" ~started:2.5 ~is_error:true () in
  let s = Trajectory.show_tool_call tc in
  Alcotest.(check bool) "contains id" true (String.length s > 0);
  Alcotest.(check bool)
    "contains name"
    true
    (try
       ignore (Str.search_forward (Str.regexp_string "read") s 0);
       true
     with
     | Not_found -> false)
;;

let test_pp_tool_call () =
  let tc = mk_tool_call () in
  let buf = Buffer.create 64 in
  let fmt = Format.formatter_of_buffer buf in
  Trajectory.pp_tool_call fmt tc;
  Format.pp_print_flush fmt ();
  Alcotest.(check bool) "pp produces output" true (Buffer.length buf > 0)
;;

(* ── Step show/pp ────────────────────────────────────────────── *)

let test_show_step_think () =
  let s = Trajectory.show_step (Think { content = "reasoning"; ts = 1.0 }) in
  Alcotest.(check bool) "Think" true (String.length s > 0)
;;

let test_show_step_act () =
  let tc = mk_tool_call () in
  let s = Trajectory.show_step (Act { tool_call = tc; ts = 1.0 }) in
  Alcotest.(check bool) "Act" true (String.length s > 0)
;;

let test_show_step_observe () =
  let s = Trajectory.show_step (Observe { content = "result"; ts = 1.0 }) in
  Alcotest.(check bool) "Observe" true (String.length s > 0)
;;

let test_show_step_respond () =
  let s = Trajectory.show_step (Respond { content = "answer"; ts = 1.0 }) in
  Alcotest.(check bool) "Respond" true (String.length s > 0)
;;

let test_pp_step () =
  let buf = Buffer.create 64 in
  let fmt = Format.formatter_of_buffer buf in
  Trajectory.pp_step fmt (Think { content = "x"; ts = 1.0 });
  Format.pp_print_flush fmt ();
  Alcotest.(check bool) "pp_step" true (Buffer.length buf > 0)
;;

(* ── step_ts ─────────────────────────────────────────────────── *)

let test_step_ts_think () =
  let ts = Trajectory.step_ts (Think { content = ""; ts = 42.0 }) in
  Alcotest.(check (float 0.001)) "Think ts" 42.0 ts
;;

let test_step_ts_act () =
  let tc = mk_tool_call ~started:55.0 () in
  let ts = Trajectory.step_ts (Act { tool_call = tc; ts = 55.0 }) in
  Alcotest.(check (float 0.001)) "Act ts" 55.0 ts
;;

let test_step_ts_observe () =
  let ts = Trajectory.step_ts (Observe { content = ""; ts = 99.0 }) in
  Alcotest.(check (float 0.001)) "Observe ts" 99.0 ts
;;

let test_step_ts_respond () =
  let ts = Trajectory.step_ts (Respond { content = ""; ts = 7.0 }) in
  Alcotest.(check (float 0.001)) "Respond ts" 7.0 ts
;;

(* ── Trajectory show/pp ──────────────────────────────────────── *)

let test_show_trajectory () =
  let t =
    mk_trajectory
      ~steps:
        [ Think { content = "a"; ts = 1.0 }
        ; Act { tool_call = mk_tool_call (); ts = 2.0 }
        ; Observe { content = "b"; ts = 3.0 }
        ; Respond { content = "c"; ts = 4.0 }
        ]
      ()
  in
  let s = Trajectory.show_trajectory t in
  Alcotest.(check bool)
    "has agent name"
    true
    (try
       ignore (Str.search_forward (Str.regexp_string "test-agent") s 0);
       true
     with
     | Not_found -> false)
;;

let test_pp_trajectory () =
  let t = mk_trajectory () in
  let buf = Buffer.create 64 in
  let fmt = Format.formatter_of_buffer buf in
  Trajectory.pp_trajectory fmt t;
  Format.pp_print_flush fmt ();
  Alcotest.(check bool) "pp_trajectory" true (Buffer.length buf > 0)
;;

(* ── count_steps ─────────────────────────────────────────────── *)

let test_count_steps_empty () =
  let t = mk_trajectory () in
  let th, ac, ob, re = Trajectory.count_steps t in
  Alcotest.(check int) "think" 0 th;
  Alcotest.(check int) "act" 0 ac;
  Alcotest.(check int) "observe" 0 ob;
  Alcotest.(check int) "respond" 0 re
;;

let test_count_steps_mixed () =
  let t =
    mk_trajectory
      ~steps:
        [ Think { content = "a"; ts = 1.0 }
        ; Think { content = "b"; ts = 2.0 }
        ; Act { tool_call = mk_tool_call (); ts = 3.0 }
        ; Observe { content = "c"; ts = 4.0 }
        ; Respond { content = "d"; ts = 5.0 }
        ; Respond { content = "e"; ts = 6.0 }
        ]
      ()
  in
  let th, ac, ob, re = Trajectory.count_steps t in
  Alcotest.(check int) "think" 2 th;
  Alcotest.(check int) "act" 1 ac;
  Alcotest.(check int) "observe" 1 ob;
  Alcotest.(check int) "respond" 2 re
;;

(* ── total_tool_calls / tool_error_count ─────────────────────── *)

let test_total_tool_calls () =
  let t =
    mk_trajectory
      ~steps:
        [ Act { tool_call = mk_tool_call ~id:"1" (); ts = 1.0 }
        ; Think { content = "x"; ts = 2.0 }
        ; Act { tool_call = mk_tool_call ~id:"2" (); ts = 3.0 }
        ]
      ()
  in
  Alcotest.(check int) "total tool calls" 2 (Trajectory.total_tool_calls t)
;;

let test_tool_error_count () =
  let t =
    mk_trajectory
      ~steps:
        [ Act { tool_call = mk_tool_call ~id:"1" ~is_error:true (); ts = 1.0 }
        ; Act { tool_call = mk_tool_call ~id:"2" ~is_error:false (); ts = 2.0 }
        ; Act { tool_call = mk_tool_call ~id:"3" ~is_error:true (); ts = 3.0 }
        ]
      ()
  in
  Alcotest.(check int) "error count" 2 (Trajectory.tool_error_count t)
;;

(* ── elapsed_s ───────────────────────────────────────────────── *)

let test_elapsed_finished () =
  let t = mk_trajectory ~finished:110.0 () in
  Alcotest.(check (option (float 0.001))) "elapsed" (Some 10.0) (Trajectory.elapsed_s t)
;;

let test_elapsed_not_finished () =
  let t = mk_trajectory () in
  Alcotest.(check (option (float 0.001))) "not finished" None (Trajectory.elapsed_s t)
;;

(* ── JSON round-trip: tool_call ──────────────────────────────── *)

let test_tool_call_json_roundtrip () =
  let tc =
    mk_tool_call
      ~id:"rt-1"
      ~name:"write"
      ~is_error:false
      ~started:10.0
      ~finished:12.0
      ~result:(Some "ok")
      ()
  in
  let json = Trajectory.tool_call_to_json tc in
  match Trajectory.tool_call_of_json json with
  | Error e -> Alcotest.fail ("roundtrip failed: " ^ e)
  | Ok tc2 ->
    Alcotest.(check string) "id" tc.tool_use_id tc2.tool_use_id;
    Alcotest.(check string) "name" tc.tool_name tc2.tool_name;
    Alcotest.(check bool) "is_error" tc.is_error tc2.is_error;
    Alcotest.(check (float 0.001)) "started" tc.started_at tc2.started_at;
    Alcotest.(check (option (float 0.001))) "finished" tc.finished_at tc2.finished_at;
    Alcotest.(check (option string)) "result" tc.tool_result tc2.tool_result
;;

let test_tool_call_json_null_finished () =
  let tc = mk_tool_call ~finished:12.0 () in
  let json = Trajectory.tool_call_to_json { tc with finished_at = None } in
  match Trajectory.tool_call_of_json json with
  | Error e -> Alcotest.fail ("roundtrip failed: " ^ e)
  | Ok tc2 ->
    Alcotest.(check (option (float 0.001))) "finished is None" None tc2.finished_at
;;

let test_tool_call_of_json_error () =
  let bad_json = `Assoc [ "tool_use_id", `Int 123 ] in
  match Trajectory.tool_call_of_json bad_json with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected error"
;;

(* ── JSON round-trip: step ───────────────────────────────────── *)

let test_step_json_think () =
  let s : Trajectory.step = Think { content = "hmm"; ts = 1.5 } in
  let json = Trajectory.step_to_json s in
  match Trajectory.step_of_json json with
  | Error e -> Alcotest.fail ("think roundtrip: " ^ e)
  | Ok s2 ->
    let ts = Trajectory.step_ts s2 in
    Alcotest.(check (float 0.001)) "ts" 1.5 ts
;;

let test_step_json_act () =
  let tc = mk_tool_call ~id:"a1" ~started:2.0 () in
  let s : Trajectory.step = Act { tool_call = tc; ts = 2.0 } in
  let json = Trajectory.step_to_json s in
  match Trajectory.step_of_json json with
  | Error e -> Alcotest.fail ("act roundtrip: " ^ e)
  | Ok (Act { tool_call = tc2; _ }) -> Alcotest.(check string) "id" "a1" tc2.tool_use_id
  | Ok _ -> Alcotest.fail "expected Act"
;;

let test_step_json_observe () =
  let s : Trajectory.step = Observe { content = "data"; ts = 3.0 } in
  let json = Trajectory.step_to_json s in
  match Trajectory.step_of_json json with
  | Error e -> Alcotest.fail ("observe roundtrip: " ^ e)
  | Ok (Observe { content; _ }) -> Alcotest.(check string) "content" "data" content
  | Ok _ -> Alcotest.fail "expected Observe"
;;

let test_step_json_respond () =
  let s : Trajectory.step = Respond { content = "done"; ts = 4.0 } in
  let json = Trajectory.step_to_json s in
  match Trajectory.step_of_json json with
  | Error e -> Alcotest.fail ("respond roundtrip: " ^ e)
  | Ok (Respond { content; _ }) -> Alcotest.(check string) "content" "done" content
  | Ok _ -> Alcotest.fail "expected Respond"
;;

let test_step_json_unknown_type () =
  let json = `Assoc [ "type", `String "mystery"; "ts", `Float 1.0 ] in
  match Trajectory.step_of_json json with
  | Error msg ->
    Alcotest.(check bool)
      "mentions unknown"
      true
      (try
         ignore (Str.search_forward (Str.regexp_string "unknown") msg 0);
         true
       with
       | Not_found -> false)
  | Ok _ -> Alcotest.fail "expected error"
;;

let test_step_json_bad_type () =
  let json = `Assoc [ "type", `Int 42 ] in
  match Trajectory.step_of_json json with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected error for bad type"
;;

(* ── JSON round-trip: trajectory ─────────────────────────────── *)

let test_trajectory_json_roundtrip () =
  let t =
    mk_trajectory
      ~steps:
        [ Think { content = "think"; ts = 100.0 }
        ; Act
            { tool_call =
                mk_tool_call
                  ~id:"t1"
                  ~started:101.0
                  ~finished:102.0
                  ~result:(Some "ok")
                  ()
            ; ts = 101.0
            }
        ; Observe { content = "obs"; ts = 102.0 }
        ; Respond { content = "done"; ts = 103.0 }
        ]
      ~finished:103.0
      ~error:"test error"
      ~success:false
      ()
  in
  let json = Trajectory.to_json t in
  match Trajectory.of_json json with
  | Error e -> Alcotest.fail ("trajectory roundtrip: " ^ e)
  | Ok t2 ->
    Alcotest.(check string) "agent" t.agent_name t2.agent_name;
    Alcotest.(check string) "model" t.model t2.model;
    Alcotest.(check string) "prompt" t.prompt t2.prompt;
    Alcotest.(check int) "steps" (List.length t.steps) (List.length t2.steps);
    Alcotest.(check (float 0.001)) "started" t.started_at t2.started_at;
    Alcotest.(check (option (float 0.001))) "finished" t.finished_at t2.finished_at;
    Alcotest.(check bool) "success" t.success t2.success;
    Alcotest.(check (option string)) "error" t.error t2.error
;;

let test_trajectory_json_minimal () =
  let t = mk_trajectory () in
  let json = Trajectory.to_json t in
  match Trajectory.of_json json with
  | Error e -> Alcotest.fail ("minimal roundtrip: " ^ e)
  | Ok t2 ->
    Alcotest.(check int) "no steps" 0 (List.length t2.steps);
    Alcotest.(check (option (float 0.001))) "no finished" None t2.finished_at
;;

let test_trajectory_of_json_bad_step () =
  let json =
    `Assoc
      [ "agent_name", `String "a"
      ; "model", `String "m"
      ; "prompt", `String "p"
      ; "steps", `List [ `Assoc [ "type", `String "invalid_step"; "ts", `Float 1.0 ] ]
      ; "started_at", `Float 1.0
      ; "finished_at", `Null
      ; "success", `Bool true
      ; "metrics", `Null
      ; "error", `Null
      ]
  in
  match Trajectory.of_json json with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected error for bad step"
;;

let test_trajectory_of_json_bad_type () =
  let json = `String "not an object" in
  match Trajectory.of_json json with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected error"
;;

(* ── Test suite ──────────────────────────────────────────────── *)

let () =
  Alcotest.run
    "Trajectory unit"
    [ ( "show_pp"
      , [ tc "show_tool_call" test_show_tool_call
        ; tc "pp_tool_call" test_pp_tool_call
        ; tc "show_step think" test_show_step_think
        ; tc "show_step act" test_show_step_act
        ; tc "show_step observe" test_show_step_observe
        ; tc "show_step respond" test_show_step_respond
        ; tc "pp_step" test_pp_step
        ; tc "show_trajectory" test_show_trajectory
        ; tc "pp_trajectory" test_pp_trajectory
        ] )
    ; ( "step_ts"
      , [ tc "think" test_step_ts_think
        ; tc "act" test_step_ts_act
        ; tc "observe" test_step_ts_observe
        ; tc "respond" test_step_ts_respond
        ] )
    ; ( "count_steps"
      , [ tc "empty" test_count_steps_empty; tc "mixed" test_count_steps_mixed ] )
    ; ( "derived_metrics"
      , [ tc "total_tool_calls" test_total_tool_calls
        ; tc "tool_error_count" test_tool_error_count
        ; tc "elapsed finished" test_elapsed_finished
        ; tc "elapsed not finished" test_elapsed_not_finished
        ] )
    ; ( "tool_call_json"
      , [ tc "roundtrip" test_tool_call_json_roundtrip
        ; tc "null finished" test_tool_call_json_null_finished
        ; tc "parse error" test_tool_call_of_json_error
        ] )
    ; ( "step_json"
      , [ tc "think" test_step_json_think
        ; tc "act" test_step_json_act
        ; tc "observe" test_step_json_observe
        ; tc "respond" test_step_json_respond
        ; tc "unknown type" test_step_json_unknown_type
        ; tc "bad type" test_step_json_bad_type
        ] )
    ; ( "trajectory_json"
      , [ tc "roundtrip" test_trajectory_json_roundtrip
        ; tc "minimal" test_trajectory_json_minimal
        ; tc "bad step" test_trajectory_of_json_bad_step
        ; tc "bad type" test_trajectory_of_json_bad_type
        ] )
    ]
;;
