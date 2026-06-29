(** RFC-0284 §6 server verification: the goal-loop status broadcast is
    change-gated.

    A status whose meaningful content changed (loop_iteration / overall_status
    / phases) broadcasts exactly one [goal_loop_status] event; an unchanged
    status — or one differing only in the volatile [generated_at] — broadcasts
    nothing. The gate is exercised through the public [broadcast_goal_loop_status]
    (bool result + the per-session SSE stream), so the [generated_at]-exclusion
    is asserted by behavior rather than by inspecting the fingerprint. *)

module Sse = Masc.Sse
module Session = Masc.Session
module Broadcast = Server_dashboard_http_goal_loop_broadcast

let status ~iter ~generated_at =
  `Assoc
    [ ("schema_version", `Int 1)
    ; ("generated_at", `String generated_at)
    ; ("loop_iteration", `String (string_of_int iter))
    ; ("overall_status", `String "ok")
    ; ("phases", `Assoc [ ("observe", `Assoc [ ("status", `String "ok") ]) ])
    ]

let event_type_of = function
  | `Assoc fields -> (
      match List.assoc_opt "type" fields with
      | Some (`String s) -> Some s
      | _ -> None)
  | _ -> None

let test_event_shape () =
  let ev = Broadcast.goal_loop_snapshot_event (status ~iter:1 ~generated_at:"t1") in
  Alcotest.(check (option string))
    "event type is goal_loop_status" (Some "goal_loop_status") (event_type_of ev);
  match ev with
  | `Assoc fields ->
      Alcotest.(check bool)
        "event carries payload" true (List.mem_assoc "payload" fields)
  | _ -> Alcotest.fail "event must be a JSON object"

let test_refresh_timeout_below_interval () =
  Alcotest.(check bool)
    "timeout stays below interval to avoid Proactive_refresh clamp"
    true
    (Broadcast.goal_loop_broadcast_timeout_s
     < Broadcast.goal_loop_broadcast_interval_s)

let drain session_id =
  let rec loop n =
    match Sse.try_pop session_id with Some _ -> loop (n + 1) | None -> n
  in
  loop 0

let register_exn ~auth ?kind session_id ~last_event_id =
  (* Pre-create the MCP session so registration validates an existing
     session rather than auto-bootstrapping one (security/sse-auth-validation). *)
  let (_ : Session.McpSessionStore.mcp_session) =
    Session.McpSessionStore.get_or_create ~id:session_id ()
  in
  match Sse.register ?kind ~auth session_id ~last_event_id with
  | Ok result -> result
  | Error e ->
      Alcotest.fail
        (Printf.sprintf "Sse.register failed: %s"
           (Sse.registration_error_to_string e))

let test_change_gated_broadcast () =
  Eio_main.run @@ fun _env ->
  let workspace = Masc_test_deps.setup_test_workspace () in
  let auth = Masc_test_deps.make_sse_auth workspace "goal-loop-agent" in
  Fun.protect
    ~finally:(fun () -> Masc_test_deps.cleanup_test_workspace workspace)
    (fun () ->
      let session_id = Printf.sprintf "goal_loop_test_%d" (Random.int 1_000_000) in
      let _ = register_exn ~auth ~kind:Sse.Observer session_id ~last_event_id:0 in
      let (_ : int) = drain session_id in
      let s1 = status ~iter:1 ~generated_at:"2026-06-23T00:00:00Z" in
      Alcotest.(check bool)
        "first status broadcasts" true (Broadcast.broadcast_goal_loop_status s1);
      Alcotest.(check int) "first status emits one event" 1 (drain session_id);
      (* identical content -> no rebroadcast *)
      Alcotest.(check bool)
        "unchanged status is skipped" false
        (Broadcast.broadcast_goal_loop_status
           (status ~iter:1 ~generated_at:"2026-06-23T00:00:00Z"));
      Alcotest.(check int) "unchanged status emits nothing" 0 (drain session_id);
      (* only generated_at differs -> still skipped (volatile key excluded) *)
      Alcotest.(check bool)
        "generated_at-only change is skipped" false
        (Broadcast.broadcast_goal_loop_status
           (status ~iter:1 ~generated_at:"2026-06-23T11:11:11Z"));
      Alcotest.(check int)
        "generated_at-only change emits nothing" 0 (drain session_id);
      (* real OODA change (loop_iteration) -> broadcast *)
      Alcotest.(check bool)
        "changed status broadcasts" true
        (Broadcast.broadcast_goal_loop_status
           (status ~iter:2 ~generated_at:"2026-06-23T11:11:11Z"));
      Alcotest.(check int) "changed status emits one event" 1 (drain session_id);
      Sse.unregister session_id)

let () =
  Alcotest.run "goal_loop_broadcast"
    [ ( "event"
      , [ Alcotest.test_case "shape" `Quick test_event_shape
        ; Alcotest.test_case "refresh timeout below interval" `Quick
            test_refresh_timeout_below_interval
        ] )
    ; ( "change_gate"
      , [ Alcotest.test_case "broadcast" `Quick test_change_gated_broadcast ] )
    ]
