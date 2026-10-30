(** Concurrency tests for {!Context} under Eio fibers.

    Verifies that the default Eio-backed context survives parallel access from
    multiple fibers without deadlock or crash. *)

open Agent_core

let test_concurrent_context_access () =
  Eio_main.run
  @@ fun _env ->
  Eio.Switch.run
  @@ fun sw ->
  let ctx = Context.create () in
  let f n =
    Eio.Fiber.fork ~sw (fun () ->
      for i = 1 to 100 do
        Context.set ctx ("key" ^ string_of_int n) (`Int i)
      done)
  in
  List.iter f [ 1; 2; 3 ];
  (* If we get here without deadlock or exception, the test passes. *)
  ()
;;

let test_sync_context_at_eio_agent_boundary () =
  let ctx = Context.create_sync () in
  Eio_main.run (fun env ->
    let agent = Agent.create ~media_store:(Agent_core.History.Memory_store.create ()) ~net:env#net
      ~config:(Types.default_config ~model:"context-boundary") ~context:ctx () in
    let shared = Agent.context agent in
    Alcotest.(check bool) "constructor preserves shared context identity" true (shared == ctx);
    Alcotest.(check bool) "sync backend actually reaches Eio" true
      (Context.concurrency_backend shared = Context.Stdlib_mutex);
    let readbacks_match = Atomic.make true in
    let write prefix i =
      let key = Printf.sprintf "%s:%d" prefix i in
      Context.set shared key (`Int i);
      if Context.get shared key <> Some (`Int i)
      then Atomic.set readbacks_match false;
      ignore (Context.snapshot shared : (string * Yojson.Safe.t) list)
    in
    Eio.Fiber.both
      (fun () -> Eio.Domain_manager.run_raw env#domain_mgr (fun () ->
        for i = 1 to 200 do write "domain" i done))
      (fun () -> Eio.Fiber.List.iter (fun prefix ->
        for i = 1 to 200 do
          write prefix i;
          Eio.Fiber.yield ()
        done) ["fiber-a"; "fiber-b"]);
    Alcotest.(check bool) "all published values were readable" true
      (Atomic.get readbacks_match);
    Alcotest.(check int) "both fibers and the other domain retain all writes"
      600 (List.length (Context.keys shared));
    let child = Context.create_scope ~parent:shared
      ~propagate_down:["domain:1"] ~propagate_up:["reply"] in
    Context.set child.local "reply" (`String "merged");
    Context.merge_back child;
    Alcotest.(check bool) "scope result reaches original shared owner" true
      (Context.get ctx "reply" = Some (`String "merged"));
    let independent = Context.copy ~eio:true shared in
    Context.delete independent "reply";
    Alcotest.(check bool) "explicit Eio copy stays independent" true
      (Context.get ctx "reply" = Some (`String "merged")))
;;

let () =
  Alcotest.run
    "Context_concurrency"
    [ ( "fiber safety"
      , [ Alcotest.test_case
            "concurrent set under Eio"
            `Quick
            test_concurrent_context_access
        ; Alcotest.test_case "sync context at actual Eio Agent boundary"
            `Quick test_sync_context_at_eio_agent_boundary
        ] )
    ]
;;
