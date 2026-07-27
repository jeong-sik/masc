open Alcotest
open Test_keeper_lifecycle_nonce_support

exception Nested_admission_failure

let test_reentrant_lease_drains_before_admission_release () =
  with_base "masc_lifecycle_permit_scope_" @@ fun base_path ->
  let module Admission =
    Masc.Keeper_lifecycle_admission.Durable_transaction
  in
  let config = Masc.Workspace.default_config base_path in
  Eio.Switch.run @@ fun sw ->
  let child_entered, resolve_child_entered = Eio.Promise.create () in
  let outer_body_returning, resolve_outer_body_returning =
    Eio.Promise.create ()
  in
  let observe_after_close, resolve_observe_after_close =
    Eio.Promise.create ()
  in
  let lease_observed, resolve_lease_observed = Eio.Promise.create () in
  let release_child_body, resolve_release_child_body =
    Eio.Promise.create ()
  in
  let first_reentry_done, resolve_first_reentry_done =
    Eio.Promise.create ()
  in
  let allow_fresh_reentry, resolve_allow_fresh_reentry =
    Eio.Promise.create ()
  in
  let child_result, resolve_child_result = Eio.Promise.create () in
  let outer_result =
    Eio.Fiber.fork_promise ~sw (fun () ->
      Admission.with_durable_lifecycle_admission
        config
        ~keeper_name:"keeper-a"
        (fun permit ->
           let exception_released =
             try
               ignore
                 (Admission.with_permit_lease
                    permit
                    config
                    "keeper-a"
                    (fun () -> raise Nested_admission_failure));
               false
             with Nested_admission_failure -> true
           in
           check bool
             "nested exception leaves its reentrant lease"
             true
             exception_released;
           let cancellation_reason =
             Failure "cancel nested lifecycle admission"
           in
           let cancellation_released =
             try
               Eio.Cancel.sub (fun context ->
                 ignore
                   (Admission.with_permit_lease
                      permit
                      config
                      "keeper-a"
                      (fun () ->
                         Eio.Cancel.cancel
                           context
                           cancellation_reason;
                         Eio.Fiber.check ()));
                 false)
             with
             | Eio.Cancel.Cancelled observed ->
               observed == cancellation_reason
           in
           check bool
             "nested cancellation leaves its reentrant lease"
             true
             cancellation_released;
           Eio.Fiber.fork ~sw (fun () ->
             let first_reentry =
               Admission.with_permit_lease
                 permit
                 config
                 "keeper-a"
                 (fun () ->
                    Eio.Promise.resolve resolve_child_entered ();
                    Eio.Promise.await observe_after_close;
                    Eio.Promise.resolve
                      resolve_lease_observed
                      (Admission.For_testing.permit_matches
                         permit
                         config
                         "keeper-a");
                    Eio.Promise.await release_child_body)
             in
             Eio.Promise.resolve
               resolve_first_reentry_done
               first_reentry;
             Eio.Promise.await allow_fresh_reentry;
             let inherited_permit_is_live =
               Admission.For_testing.permit_matches
                 permit
                 config
                 "keeper-a"
             in
             let reacquired =
               Admission.with_durable_lifecycle_admission
                 config
                 ~keeper_name:"keeper-a"
                 (fun fresh_permit ->
                    ( Admission.For_testing.permit_matches
                        permit
                        config
                        "keeper-a"
                    , Admission.For_testing.permit_matches
                        fresh_permit
                        config
                        "keeper-a" ))
             in
             Eio.Promise.resolve
               resolve_child_result
               (inherited_permit_is_live, reacquired));
           Eio.Promise.await child_entered;
           Eio.Promise.resolve resolve_outer_body_returning ()))
  in
  Eio.Promise.await outer_body_returning;
  Eio.Fiber.yield ();
  Eio.Fiber.yield ();
  check bool
    "outer admission waits for in-flight reentrant body"
    false
    (Option.is_some (Eio.Promise.peek outer_result));
  Eio.Promise.resolve resolve_observe_after_close ();
  check bool
    "in-flight lease remains authorized while outer drains"
    true
    (Eio.Promise.await lease_observed);
  Eio.Promise.resolve resolve_release_child_body ();
  (match Eio.Promise.await first_reentry_done with
   | Admission.Permit_lease_completed () -> ()
   | Admission.Permit_lease_denied ->
     fail "direct permit operation lost its in-flight lease");
  (match Eio.Promise.await_exn outer_result with
   | Admission.Admission_completed () -> ()
   | Admission.Admission_completed_with_attention ((), _) ->
     fail "outer admission completed with unexpected release attention"
   | Admission.Admission_blocked reason ->
     fail
       (Admission.blocked_reason_to_wire reason));
  Eio.Promise.resolve resolve_allow_fresh_reentry ();
  let inherited_permit_is_live, reacquired = Eio.Promise.await child_result in
  check bool
    "inherited permit is revoked after parent scope"
    false
    inherited_permit_is_live;
  match reacquired with
  | Admission.Admission_completed (stale_matches, fresh_matches) ->
    check bool "revoked binding cannot authorize reentry" false stale_matches;
    check bool "reentry acquires a fresh live permit" true fresh_matches
  | Admission.Admission_completed_with_attention _ ->
    fail "fresh admission completed with unexpected release attention"
  | Admission.Admission_blocked reason ->
    fail
      (Admission.blocked_reason_to_wire reason)
;;

let test_permit_scope_is_cluster_scoped () =
  with_base "masc_lifecycle_permit_cluster_scope_" @@ fun base_path ->
  let module Admission =
    Masc.Keeper_lifecycle_admission.Durable_transaction
  in
  let default_config = Masc.Workspace.default_config base_path in
  let cluster_config =
    { default_config with
      backend_config =
        { default_config.backend_config with cluster_name = "cluster-b" }
    }
  in
  match
    Admission.with_durable_lifecycle_admission
      default_config
      ~keeper_name:"keeper-a"
      (fun default_permit ->
         let stale_matches =
           Admission.For_testing.permit_matches
             default_permit
             cluster_config
             "keeper-a"
         in
         let stale_lease =
           Admission.with_permit_lease
             default_permit
             cluster_config
             "keeper-a"
             (fun () -> ())
         in
         let fresh =
           Admission.with_durable_lifecycle_admission
             cluster_config
             ~keeper_name:"keeper-a"
             (fun cluster_permit ->
                Admission.For_testing.permit_matches
                  cluster_permit
                  cluster_config
                  "keeper-a")
         in
         stale_matches, stale_lease, fresh)
  with
  | Admission.Admission_completed
      ( false
      , Admission.Permit_lease_denied
      , Admission.Admission_completed true ) ->
    ()
  | Admission.Admission_completed _ ->
    fail "cluster permit scope reused a foreign durable authority"
  | Admission.Admission_completed_with_attention _ ->
    fail "cluster permit test completed with release attention"
  | Admission.Admission_blocked reason ->
    fail (Admission.blocked_reason_to_wire reason)
;;
