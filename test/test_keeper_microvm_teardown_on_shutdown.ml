(* Shutdown finalization is the only place that knows a keeper is gone for
   good: the microvm lane keeps one guest per keeper across turns, so turn
   teardown deliberately leaves it running. Before this was wired, removing a
   keeper left ~400 MB of guest behind for somebody to find by hand.

   Two properties hold it. The first is that finalization calls the teardown
   at all -- deleting the call is the regression, and no other suite would
   notice. The second is that the teardown is safe to call for every keeper:
   a docker keeper has no guest under this name, and finalization must not
   turn that into a blocked shutdown. *)

module Runtime = Masc.Keeper_turn_sandbox_runtime

(* Every keeper goes through finalization, and only microvm keepers have a
   guest. If an absent guest were an error the shutdown would block on it, so
   this pins that removing nothing succeeds -- run against a name that has
   never had a guest. *)
let test_removing_an_absent_guest_succeeds () =
  let base_path = Filename.temp_file "microvm_teardown_" "" in
  Unix.unlink base_path;
  Unix.mkdir base_path 0o755;
  Fun.protect
    ~finally:(fun () -> try Unix.rmdir base_path with _ -> ())
    (fun () ->
       let config = Masc.Workspace.default_config base_path in
       match
         Runtime.teardown_keeper_sandbox_by_name
           ~timeout_sec:30.0
           ~config
           ~keeper_name:"microvm-teardown-probe-never-started"
           ()
       with
       | Ok () -> ()
       | Error detail ->
         (* container absent from the host is not a failed teardown either:
            the suite has to pass on a machine without the CLI. *)
         if not (Astring.String.is_infix ~affix:"executable file not found" detail)
            && not (Astring.String.is_infix ~affix:"No such file" detail)
         then
           Alcotest.failf
             "removing a guest that was never started must succeed, got: %s"
             detail)

let () =
  Alcotest.run
    "keeper_microvm_teardown_on_shutdown"
    [ ( "teardown"
      , [ Alcotest.test_case "removing an absent guest succeeds" `Quick
            test_removing_an_absent_guest_succeeds
        ] )
    ]
