(** A chat message is refused before it is stored when the keeper is down.

    Whether a keeper can take a turn lives in [Keeper_registry], which is
    process-local. [ensure_keeper_exists] reads disk meta, which a stopped
    keeper still has, so it passed. The user row was committed first and the
    turn then failed resolving its resources, and the raw
    [keeper_turn_resources_unavailable] payload was what the person saw in
    their own chat — stored durably beside the two characters they typed
    (#25529, live 2026-07-21).

    [process_single_turn] asks the registry before anything is written. These
    check that the ask is still there and still ahead of the write. *)

let check_bool = Alcotest.(check bool)
let module_path = "lib/server/server_routes_http_keeper_stream.ml"
let binding = "process_single_turn"

let test_the_send_path_asks_the_registry () =
  let n =
    Ast_grep.count_calls_in_value_binding ~module_path ~binding_name:binding
      ~callee:"Keeper_registry.is_registered"
  in
  if n < 1 then
    Alcotest.failf
      "%s must ask the registry whether the keeper is running; \
       Keeper_registry.is_registered is called %d time(s)"
      binding n
;;

(* The ask is worth nothing after the row is on disk. The gate reaches the
   append through Result.bind, so the append must not also be called from
   anywhere else in this binding. *)
let test_the_write_happens_once_behind_the_gate () =
  let appends =
    Ast_grep.count_calls_in_value_binding ~module_path ~binding_name:binding
      ~callee:"append_queued_user_row_once"
  in
  check_bool
    (Printf.sprintf
       "the user row is appended from exactly one place (found %d)" appends)
    true (appends = 1)
;;

let () =
  Alcotest.run "chat_send_checks_the_registry"
    [ ( "send gate"
      , [ Alcotest.test_case "the send path asks the registry" `Quick
            test_the_send_path_asks_the_registry
        ; Alcotest.test_case "the write happens once behind the gate" `Quick
            test_the_write_happens_once_behind_the_gate
        ] )
    ]
