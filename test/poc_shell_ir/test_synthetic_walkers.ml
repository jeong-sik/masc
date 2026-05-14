(* RFC-0054 POC — verify codegen-emitted walkers compile and behave
   correctly on the same 4-parameter GADT shape that broke under
   ppxlib (PR-1 / PR-1b).

   If this test passes, the codegen approach is empirically proven on
   exactly the failure case. *)

let test_risk_per_constructor () =
  let ls = Synthetic_command.C_ls { path = Some "/tmp" } in
  let gs = Synthetic_command.C_git_status { short = true } in
  let rm = Synthetic_command.C_rm { path = "/tmp/foo" } in
  assert (Synthetic_walkers.risk ls = `Safe);
  assert (Synthetic_walkers.risk gs = `Audited);
  assert (Synthetic_walkers.risk rm = `Privileged)

let test_sandbox_per_constructor () =
  let ls = Synthetic_command.C_ls { path = Some "/tmp" } in
  let gs = Synthetic_command.C_git_status { short = true } in
  let rm = Synthetic_command.C_rm { path = "/tmp/foo" } in
  assert (Synthetic_walkers.sandbox ls = `Host);
  assert (Synthetic_walkers.sandbox gs = `Host);
  assert (Synthetic_walkers.sandbox rm = `Host)

let test_all_constructor_names () =
  assert (
    Synthetic_walkers.all_constructor_names
    = [ "C_ls"; "C_git_status"; "C_rm" ])

let () =
  test_risk_per_constructor ();
  test_sandbox_per_constructor ();
  test_all_constructor_names ();
  print_endline "RFC-0054 POC: codegen walkers OK"
