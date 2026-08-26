(* A Keeper's durable work is discovered by scanning .masc/keepers for
   directories that hold a queue snapshot or WAL. Any directory qualifies, so a
   name the Keeper store never knew about is discovered exactly like a real
   Keeper. What separates them is the metadata lookup, and until this test the
   sweep folded "the store did not answer" and "the store answered and holds no
   such Keeper" into one error. The second is an orphan directory whose work can
   never run; one of them logged 913 errors in a single day while reading as a
   transient lookup failure. *)

open Alcotest
open Masc

module Maintenance = Server_bootstrap_maintenance
module Persistence = Keeper_event_queue_persistence
module Queue = Keeper_event_queue

let temp_base_path () =
  let path = Filename.temp_file "durable-demand-owner-" "" in
  Unix.unlink path;
  Unix.mkdir path 0o755;
  path
;;

let cleanup path =
  let rec remove target =
    if Sys.file_exists target
    then
      if Sys.is_directory target
      then (
        Sys.readdir target
        |> Array.iter (fun name -> remove (Filename.concat target name));
        Unix.rmdir target)
      else Unix.unlink target
  in
  try remove path with _ -> ()
;;

let pending_stimulus () : Queue.stimulus =
  { post_id = "schedule-due:orphan-probe"
  ; urgency = Queue.Immediate
  ; arrived_at = 1234.5
  ; payload =
      Queue.Schedule_due
        { occurrence_id = "schedule-due:orphan-probe"
        ; schedule_instance_id = "instance-orphan-probe"
        ; schedule_id = "orphan-probe"
        ; due_at = 1200.0
        ; payload_digest = "payload-digest"
        ; title = Some "Wake"
        ; message = "Scheduled lane wake"
        ; result_delivery = None
        }
  }
;;

(* The classification runs its filesystem reads through the shared executor
   pool, so a bare test would only ever observe [Executor_unavailable]. *)
let with_base_path fn =
  let base_path = temp_base_path () in
  Fun.protect ~finally:(fun () -> cleanup base_path) (fun () ->
    Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
        let pool = Domain_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env) in
        Executor_pool_ref.For_testing.with_pool (Domain_pool.executor_pool pool)
        @@ fun () -> fn base_path)))
;;

let seed_durable_demand ~base_path ~keeper_name =
  match
    Persistence.enqueue_stimulus_if_absent_result
      ~base_path
      ~keeper_name
      (pending_stimulus ())
  with
  | Ok _ -> ()
  | Error error -> failf "could not seed durable demand: %s" error
;;

let classify ~base_path ~keeper_name =
  Maintenance.Recovery_for_testing.load_durable_demand_meta
    ~base_path
    ~config:(Workspace.default_config base_path)
    ~keeper_name
;;

let test_durable_work_under_an_unknown_name_is_absent_not_unknown () =
  with_base_path (fun base_path ->
    let keeper_name = "keeper-orphan-agent" in
    seed_durable_demand ~base_path ~keeper_name;
    match classify ~base_path ~keeper_name with
    | Error Maintenance.Owner_absent -> ()
    | Error (Maintenance.Owner_unknown detail) ->
      failf
        "an orphan queue directory was reported as an unanswered lookup: %s"
        detail
    | Error (Maintenance.Demand_unknown detail) ->
      failf "seeded durable demand was not readable back: %s" detail
    | Error (Maintenance.Executor_unavailable _)
    | Error (Maintenance.Demand_execution_failed _) ->
      fail "the classification could not run"
    | Ok None -> fail "seeded durable demand was reported as no demand"
    | Ok (Some _) -> fail "a Keeper the store never knew about resolved to metadata")
;;

let test_a_name_with_no_durable_work_carries_no_demand () =
  with_base_path (fun base_path ->
    match classify ~base_path ~keeper_name:"keeper-quiet-agent" with
    | Ok None -> ()
    | Ok (Some _) -> fail "an empty base path resolved to Keeper metadata"
    | Error Maintenance.Owner_absent ->
      fail
        "a name with no durable work was reported as an orphan; only durable \
         work under an unowned name is one"
    | Error (Maintenance.Demand_unknown detail) ->
      failf "an absent queue was reported as an unreadable one: %s" detail
    | Error (Maintenance.Owner_unknown _)
    | Error (Maintenance.Executor_unavailable _)
    | Error (Maintenance.Demand_execution_failed _) ->
      fail "the classification could not run")
;;

let () =
  run
    "server_bootstrap_durable_demand_owner"
    [ ( "owner_classification"
      , [ test_case "durable work under an unknown name is absent, not unknown" `Quick
            test_durable_work_under_an_unknown_name_is_absent_not_unknown
        ; test_case "a name with no durable work carries no demand" `Quick
            test_a_name_with_no_durable_work_carries_no_demand
        ] )
    ]
;;
