open Alcotest

let load_source relative_path =
  let root = Option.value (Sys.getenv_opt "DUNE_SOURCEROOT") ~default:(Sys.getcwd ()) in
  let path = Filename.concat root relative_path in
  In_channel.with_open_bin path In_channel.input_all
;;

let count_occurrences ~needle source =
  let needle_length = String.length needle in
  let rec loop offset count =
    if offset + needle_length > String.length source
    then count
    else if String.sub source offset needle_length = needle
    then loop (offset + needle_length) (count + 1)
    else loop (offset + 1) count
  in
  if needle_length = 0 then 0 else loop 0 0
;;

let check_absent ~source label needle =
  check int label 0 (count_occurrences ~needle source)
;;

let test_tool_dispatch_has_no_fleet_start_authority () =
  let source = load_source "lib/keeper/keeper_tool_surface.ml" in
  check_absent
    ~source
    "Keeper tools do not start keepalives"
    "Keeper_keepalive.start_keepalive";
  check_absent
    ~source
    "Keeper tools do not start the supervisor"
    "start_supervisor_sweep"
;;

let test_runtime_has_no_fleet_start_authority () =
  let source = load_source "lib/keeper/keeper_runtime.ml" in
  check_absent
    ~source
    "Keeper runtime does not start keepalives"
    "Keeper_supervisor.supervise_keepalive"
;;

let test_server_subsystem_owns_boot_and_supervisor_once () =
  let source = load_source "lib/server/server_bootstrap_loops.ml" in
  check int
    "one Keeper autoboot subsystem"
    1
    (count_occurrences ~needle:"fork_subsystem \"keeper_autoboot\"" source);
  check int
    "one direct keepalive start site"
    1
    (count_occurrences ~needle:"Keeper_keepalive.start_keepalive\n" source);
  check int
    "one supervisor start site"
    1
    (count_occurrences ~needle:"Keeper_runtime.start_supervisor_sweep" source)
;;

let () =
  run
    "keeper autoboot single owner"
    [ ( "ownership"
      , [ test_case
            "tool dispatch has no fleet-start authority"
            `Quick
            test_tool_dispatch_has_no_fleet_start_authority
        ; test_case
            "runtime has no fleet-start authority"
            `Quick
            test_runtime_has_no_fleet_start_authority
        ; test_case
            "server subsystem owns boot and supervisor once"
            `Quick
            test_server_subsystem_owns_boot_and_supervisor_once
        ] )
    ]
;;
