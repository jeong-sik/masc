(** Fiber-safety tests for Otel_tracer.

    Runs inside [Eio_main.run] so [Eio.Fiber.List.map] is available.
    Verifies that parallel tool-batch fibers each get their own
    active-span stack and that parent/child relationships are correct. *)

let check = Alcotest.(check (option string))

let test_parallel_spans_have_correct_parents () =
  Eio_main.run (fun _env ->
    let inst = Agent_core.Otel_tracer.create_instance_eio () in
    let module T = (val Agent_core.Otel_tracer.tracer_of_instance inst) in
    let parent_attrs =
      { Agent_core.Tracing.kind = Agent_run
      ; name = "parent"
      ; agent_name = "test"
      ; turn = 1
      ; extra = []
      ; links = []
      }
    in
    T.with_span parent_attrs (fun () ->
      let parent_span = Option.get (Agent_core.Otel_tracer.inst_current_span inst) in
      let parent_id = parent_span.Agent_core.Otel_tracer.span_id in
      let child_results =
        Eio.Fiber.List.map
          (fun i ->
             let child_attrs =
               { Agent_core.Tracing.kind = Tool_exec
               ; name = Printf.sprintf "child_%d" i
               ; agent_name = "test"
               ; turn = 1
               ; extra = []
               ; links = []
               }
             in
             T.with_span child_attrs (fun () ->
               let child_span =
                 Option.get (Agent_core.Otel_tracer.inst_current_span inst)
               in
               child_span.Agent_core.Otel_tracer.parent_span_id))
          [ 0; 1; 2 ]
      in
      List.iteri
        (fun i ppid ->
           check (Printf.sprintf "child_%d has correct parent" i) (Some parent_id) ppid)
        child_results))
;;

let test_parallel_spans_do_not_cross_contaminate () =
  Eio_main.run (fun _env ->
    let inst = Agent_core.Otel_tracer.create_instance_eio () in
    let module T = (val Agent_core.Otel_tracer.tracer_of_instance inst) in
    let root_attrs =
      { Agent_core.Tracing.kind = Agent_run
      ; name = "root"
      ; agent_name = "test"
      ; turn = 1
      ; extra = []
      ; links = []
      }
    in
    T.with_span root_attrs (fun () ->
      (* Spawn 3 fibers, each starting its own sibling span.
         Without fiber-local stacks they would race and one
         would become the parent of another. *)
      let _sibling_spans =
        Eio.Fiber.List.map
          (fun i ->
             let sibling_attrs =
               { Agent_core.Tracing.kind = Tool_exec
               ; name = Printf.sprintf "sibling_%d" i
               ; agent_name = "test"
               ; turn = 1
               ; extra = []
               ; links = []
               }
             in
             T.with_span sibling_attrs (fun () ->
               let span = Option.get (Agent_core.Otel_tracer.inst_current_span inst) in
               span.Agent_core.Otel_tracer.name, span.Agent_core.Otel_tracer.parent_span_id))
          [ 0; 1; 2 ]
      in
      (* All three siblings must have the SAME parent: the root span. *)
      let parent_ids =
        List.filter_map snd _sibling_spans |> List.sort_uniq String.compare
      in
      Alcotest.(check int "all siblings share one parent" 1) (List.length parent_ids);
      (* After all siblings finish, the active span must be the root again. *)
      let active = Option.get (Agent_core.Otel_tracer.inst_current_span inst) in
      Alcotest.(check string "active span is root after siblings" "agent_run/root")
        active.Agent_core.Otel_tracer.name))
;;

let test_global_with_span_is_fiber_safe () =
  Eio_main.run (fun _env ->
    (* Ensure the global tracer is initialized inside the Eio runtime. *)
    let (_ : Agent_core.Otel_tracer.span) =
      Agent_core.Otel_tracer.start_span
        { Agent_core.Tracing.kind = Agent_run
        ; name = "warmup"
        ; agent_name = "test"
        ; turn = 1
        ; extra = []
        ; links = []
        }
    in
    Agent_core.Otel_tracer.reset ();
    let root_attrs =
      { Agent_core.Tracing.kind = Agent_run
      ; name = "global_root"
      ; agent_name = "test"
      ; turn = 1
      ; extra = []
      ; links = []
      }
    in
    Agent_core.Otel_tracer.with_span root_attrs (fun () ->
      let parent_span = Option.get (Agent_core.Otel_tracer.current_span ()) in
      let parent_id = parent_span.Agent_core.Otel_tracer.span_id in
      let child_ids =
        Eio.Fiber.List.map
          (fun i ->
             let child_attrs =
               { Agent_core.Tracing.kind = Tool_exec
               ; name = Printf.sprintf "global_child_%d" i
               ; agent_name = "test"
               ; turn = 1
               ; extra = []
               ; links = []
               }
             in
             Agent_core.Otel_tracer.with_span child_attrs (fun () ->
               let child = Option.get (Agent_core.Otel_tracer.current_span ()) in
               child.Agent_core.Otel_tracer.parent_span_id))
          [ 0; 1; 2 ]
      in
      List.iteri
        (fun i ppid ->
           check
             (Printf.sprintf "global_child_%d has correct parent" i)
             (Some parent_id)
             ppid)
        child_ids))
;;

(* Unlike a callback that returns immediately, yielding keeps sibling spans
   alive together. A fiber-local binding must not share a mutable stack cell
   inherited from its parent. *)
module type Span_scope = sig
  val with_span : Agent_core.Tracing.span_attrs -> (unit -> 'a) -> 'a
end

let check_yielding_siblings (module T : Span_scope) current_span () =
  let attrs name : Agent_core.Tracing.span_attrs =
    { kind = Tool_exec; name; agent_name = "yielding-proof"; turn = 1
    ; extra = []; links = [] }
  in
  T.with_span (attrs "parent") (fun () ->
    let parent = Option.get (current_span ()) in
    let siblings = Eio.Fiber.List.map (fun i ->
      T.with_span (attrs (Printf.sprintf "sibling_%d" i)) (fun () ->
        let before = Option.get (current_span ()) in
        Eio.Fiber.yield ();
        let after = Option.get (current_span ()) in
        Alcotest.(check string) "yield preserves this fiber's span"
          before.Agent_core.Otel_tracer.span_id after.Agent_core.Otel_tracer.span_id;
        before.Agent_core.Otel_tracer.parent_span_id)) [0; 1; 2]
    in
    List.iter (check "every overlapping sibling has original parent"
      (Some parent.Agent_core.Otel_tracer.span_id)) siblings;
    check "parent remains active after siblings"
      (Some parent.Agent_core.Otel_tracer.span_id)
      (Option.map (fun (span : Agent_core.Otel_tracer.span) -> span.span_id)
        (current_span ())))
;;

let test_yielding_instance_siblings () =
  Eio_main.run (fun _ ->
    let inst = Agent_core.Otel_tracer.create_instance_eio () in
    let module T = (val Agent_core.Otel_tracer.tracer_of_instance inst) in
    check_yielding_siblings
      (module T : Span_scope)
      (fun () -> Agent_core.Otel_tracer.inst_current_span inst) ();
    Alcotest.(check int) "four completed spans" 4
      (Agent_core.Otel_tracer.inst_completed_count inst);
    check "instance scope has no leaked active span" None
      (Option.map (fun (span : Agent_core.Otel_tracer.span) -> span.span_id)
        (Agent_core.Otel_tracer.inst_current_span inst)))
;;

let test_yielding_global_siblings () =
  Eio_main.run (fun _ ->
    Agent_core.Otel_tracer.reset ();
    (* The global public scope and current-span API must share the same
       isolation contract as an explicitly created Eio instance. *)
    let tracer : (module Span_scope) =
      (module struct
        let with_span = Agent_core.Otel_tracer.with_span
      end)
    in
    check_yielding_siblings tracer Agent_core.Otel_tracer.current_span ();
    Alcotest.(check int) "four global completed spans" 4
      (Agent_core.Otel_tracer.completed_count ());
    check "global scope has no leaked active span" None
      (Option.map (fun (span : Agent_core.Otel_tracer.span) -> span.span_id)
        (Agent_core.Otel_tracer.current_span ())))
;;

let test_nested_scope_preserves_explicit_parent_updates () =
  Eio_main.run (fun _ ->
    let inst = Agent_core.Otel_tracer.create_instance_eio () in
    let module T = (val Agent_core.Otel_tracer.tracer_of_instance inst) in
    let attrs name : Agent_core.Tracing.span_attrs =
      { kind = Tool_exec; name; agent_name = "parent-updates"; turn = 1
      ; extra = []; links = [] }
    in
    T.with_span (attrs "root") (fun () ->
      let parent = T.start_span (attrs "parent") in
      Eio.Fiber.List.iter (fun i ->
        T.with_span (attrs (string_of_int i)) (fun () ->
          T.add_attrs parent ["child", string_of_int i];
          T.add_event parent ("child-" ^ string_of_int i);
          T.add_link parent ~trace_id:(string_of_int i) ~span_id:(string_of_int i);
          Eio.Fiber.yield ())) [0; 1; 2];
      let updated = Option.get (Agent_core.Otel_tracer.inst_current_span inst) in
      List.iter (fun i ->
        Alcotest.(check bool) "ancestor attributes survive child scope" true
          (List.mem ("child", string_of_int i) updated.attributes);
        Alcotest.(check bool) "ancestor events survive child scope" true
          (List.exists (fun (event : Agent_core.Otel_tracer.otel_event) ->
             event.event_name = "child-" ^ string_of_int i) updated.events);
        Alcotest.(check bool) "ancestor links survive child scope" true
          (List.exists (fun (link : Agent_core.Otel_tracer.otel_link) ->
             link.span_id = string_of_int i) updated.links)) [0; 1; 2];
      T.end_span parent ~ok:true);
    let completed = Agent_core.Otel_tracer.inst_flush inst in
    let parent = List.find (fun (span : Agent_core.Otel_tracer.span) ->
      span.name = "tool_exec/parent") completed in
    Alcotest.(check int) "completed parent retains all child events" 3
      (List.length parent.events))
;;

let () =
  Alcotest.run
    "otel_tracer_fiber"
    [ ( "fiber_safety"
      , [ Alcotest.test_case
            "parallel spans have correct parents"
            `Quick
            test_parallel_spans_have_correct_parents
        ; Alcotest.test_case
            "parallel spans do not cross-contaminate"
            `Quick
            test_parallel_spans_do_not_cross_contaminate
        ; Alcotest.test_case
            "global with_span is fiber-safe"
            `Quick
            test_global_with_span_is_fiber_safe
        ; Alcotest.test_case "yielding instance siblings retain ownership"
            `Quick test_yielding_instance_siblings
        ; Alcotest.test_case "yielding global siblings retain ownership"
            `Quick test_yielding_global_siblings
        ; Alcotest.test_case "nested scopes preserve explicit parent updates"
            `Quick test_nested_scope_preserves_explicit_parent_updates
        ] )
    ]
;;
