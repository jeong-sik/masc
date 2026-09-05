(* What bare `masc` does.

   The risk this pins is not "does the TUI open" but "does a server that used to
   start still start". A unit file, a container CMD, a CI step and a deploy
   script all invoke `masc` with no subcommand, so every case below that ends in
   [Serve] is a launch path that must not change. *)

open Alcotest

let installed_layout = function
  | "/opt/masc/bin/masc-tui" -> true
  | _ -> false

let nothing_is_executable _ = false

let decide
      ?(interactive = true)
      ?(host = "127.0.0.1")
      ?(deployment_flags_present = false)
      ?(port = 8935)
      ?(base_path = Some "/srv/project")
      ?(executable_name = "/opt/masc/bin/masc")
      ?(path_env = None)
      ?(is_executable = installed_layout)
      ()
  =
  Masc_front_door.decide ~interactive ~host ~default_host:"127.0.0.1"
    ~deployment_flags_present ~port ~base_path ~executable_name ~path_env
    ~is_executable

let is_serve = function
  | Masc_front_door.Serve -> true
  | Masc_front_door.Open_tui _ -> false

let test_terminal_opens_the_tui () =
  match decide () with
  | Masc_front_door.Serve -> fail "a terminal should reach the TUI"
  | Masc_front_door.Open_tui { binary; argv } ->
    check string "sibling TUI" "/opt/masc/bin/masc-tui" binary;
    check (list string) "argv carries port and base path"
      [ "/opt/masc/bin/masc-tui"; "--port"; "8935"; "--base-path"; "/srv/project" ]
      argv

let test_no_terminal_serves () =
  check bool "pipe, unit file, CI step" true (is_serve (decide ~interactive:false ()))

(* The TUI takes no --host, so a bound address other than the default cannot be
   handed over; it is also what a deployment looks like. *)
let test_non_default_host_serves () =
  check bool "0.0.0.0" true (is_serve (decide ~host:"0.0.0.0" ()))

let test_deployment_flags_serve () =
  check bool "provenance or store-quarantine" true
    (is_serve (decide ~deployment_flags_present:true ()))

(* A source checkout builds masc_tui.exe and the container image ships no TUI:
   both find nothing under the installed name and keep the server. *)
let test_absent_tui_serves () =
  check bool "no masc-tui anywhere" true
    (is_serve (decide ~is_executable:nothing_is_executable ()))

let test_path_lookup_when_not_a_sibling () =
  let on_path = function
    | "/usr/local/bin/masc-tui" -> true
    | _ -> false
  in
  match
    decide ~executable_name:"/tmp/masc" ~is_executable:on_path
      ~path_env:(Some "/nowhere:/usr/local/bin") ()
  with
  | Masc_front_door.Serve -> fail "PATH lookup should find the TUI"
  | Masc_front_door.Open_tui { binary; _ } ->
    check string "found on PATH" "/usr/local/bin/masc-tui" binary

(* An empty PATH entry means the current directory to the shell. Probing it here
   would let a masc-tui dropped in a working directory capture the front door. *)
let test_empty_path_entry_is_not_the_cwd () =
  let cwd_tui = function
    | "masc-tui" | "./masc-tui" -> true
    | _ -> false
  in
  check bool "empty entry skipped" true
    (is_serve
       (decide ~executable_name:"/tmp/masc" ~is_executable:cwd_tui
          ~path_env:(Some ":") ()))

let test_argv_without_base_path () =
  check (list string) "no --base-path when none was given"
    [ "/opt/masc/bin/masc-tui"; "--port"; "9000" ]
    (Masc_front_door.tui_argv ~binary:"/opt/masc/bin/masc-tui" ~port:9000
       ~base_path:None)

let () =
  run "Front door"
    [ ( "decide"
      , [ test_case "a terminal opens the TUI" `Quick test_terminal_opens_the_tui
        ; test_case "no terminal serves" `Quick test_no_terminal_serves
        ; test_case "non-default host serves" `Quick test_non_default_host_serves
        ; test_case "deployment flags serve" `Quick test_deployment_flags_serve
        ; test_case "absent TUI serves" `Quick test_absent_tui_serves
        ; test_case "PATH lookup when not a sibling" `Quick
            test_path_lookup_when_not_a_sibling
        ; test_case "empty PATH entry is not the cwd" `Quick
            test_empty_path_entry_is_not_the_cwd
        ] )
    ; ( "tui_argv"
      , [ test_case "omits an absent base path" `Quick test_argv_without_base_path ] )
    ]
