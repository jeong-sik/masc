Source: bin/main_eio.ml
Commit under test: 23662748a1

Bounded source excerpt (lines 23 and 1200-1221):

    23 module Keeper_github_identity = Masc.Keeper_github_identity

  1200 let keeper_github_cmd =
  1201   let login =
  1202     keeper_github_action_cmd
  1203       "login"
  1204       "Log a Keeper into GitHub CLI."
  1205       Keeper_github_identity.run_cli_login
  1206   in
  1207   let status =
  1208     keeper_github_action_cmd
  1209       "status"
  1210       "Observe stored and effective Keeper GitHub identities."
  1211       Keeper_github_identity.run_cli_status
  1212   in
  1213   let logout =
  1214     keeper_github_action_cmd
  1215       "logout"
  1216       "Remove a Keeper GitHub CLI login."
  1217       Keeper_github_identity.run_cli_logout
  1218   in
  1219   Cmd.group
  1220     (Cmd.info "keeper-github" ~doc:"Manage Keeper-specific GitHub CLI identity.")
  1221     [ login; status; logout ]

The exact CLI/library build exits 0:
dune build --root . --build-dir _build-task237-explicit lib/masc.cmxa bin/main_eio.exe
