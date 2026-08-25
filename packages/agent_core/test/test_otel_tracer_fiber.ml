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
        ] )
    ]
;;
