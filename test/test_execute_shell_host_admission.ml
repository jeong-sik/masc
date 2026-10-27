open Alcotest

(* The gate, the path check, the lowering and the costume classification stat
   and realpath a command's paths, so they run on a host system thread
   (#46410), which is outside Eio. Each case answers once outside Eio, where
   [Systhread_host.run] calls the work directly, and once inside Eio with the
   host started, and requires the same answer. An Eio effect added to any of
   them raises [Effect.Unhandled] in the outside-Eio answer (checked by adding
   [Eio.Fiber.yield] to [Path_scope.classify]); the inside answer shows the
   work answers the same when the host runs it for a fiber.

   The host is process-wide and cannot be stopped, so every case starts it;
   the outside-Eio answers do not depend on it. *)

module Adapter = Keeper_tooling.Execute_shell_ir
module Typed = Masc.Keeper_tool_execute_typed_input

let with_eio f =
  Eio_main.run
  @@ fun env ->
  Process_eio.init
    ~cwd_default:(Eio.Stdenv.cwd env)
    ~proc_mgr:(Eio.Stdenv.process_mgr env)
    ~clock:(Eio.Stdenv.clock env);
  f ()
;;

let host () = Masc_exec.Sandbox_target.host ()

let echo ?cwd text =
  let open Masc_exec.Shell_ir in
  Simple
    { bin = Masc_exec.Exec_program.of_string "echo" |> Result.get_ok
    ; args = [ Lit (text, default_meta) ]
    ; env = []
    ; cwd
    ; redirects = []
    ; sandbox = host ()
    }
;;

let refusal_tag = function
  | Adapter.Too_complex reason -> "too_complex:" ^ Adapter.too_complex_reason_tag reason
  | Adapter.Cannot_parse reason -> "cannot_parse:" ^ Adapter.parse_reason_tag reason
  | Adapter.Gate_reject diagnostic -> "gate_reject:" ^ diagnostic
  | Adapter.Path_reject diagnostic -> "path_reject:" ^ diagnostic
;;

let refusal ir =
  match Adapter.dispatch ~workdir:"/tmp" ~sandbox:(host ()) ir with
  | Ok _ -> "dispatched"
  | Error error -> refusal_tag error
;;

let test_allowed_command_runs () =
  Systhread_host.start ();
  with_eio (fun () ->
    match Adapter.dispatch ~workdir:"/tmp" ~sandbox:(host ()) (echo "admitted") with
    | Ok result ->
      check bool "exits zero" true (result.status = Unix.WEXITED 0);
      check string "the command ran" "admitted" (String.trim result.stdout)
    | Error error -> fail ("an allowed command was refused: " ^ refusal_tag error))
;;

(* The cwd cases reach the realpath in [Path_scope.classify] and the
   ancestor walk in [Exec_policy_paths.resolve_path]; the nested pipeline is
   refused by the gate before any path is read. *)
let refused_cases () =
  let scope raw = Masc_exec.Path_scope.classify ~raw ~cwd:raw in
  let open Masc_exec.Shell_ir in
  [ "a cwd outside the workspace", echo ~cwd:(scope "/etc") "x"
  ; "a cwd that does not exist", echo ~cwd:(scope "/masc_46410_absent/a/b") "x"
  ; "a nested pipeline", Pipeline [ Pipeline [ echo "a"; echo "b" ]; echo "c" ]
  ]
;;

let test_refusals_match_outside_eio () =
  Systhread_host.start ();
  let outside = List.map (fun (name, ir) -> name, refusal ir) (refused_cases ()) in
  List.iter
    (fun (name, answer) ->
       check bool (name ^ " is refused") true (answer <> "dispatched"))
    outside;
  let inside =
    with_eio (fun () -> List.map (fun (name, ir) -> name, refusal ir) (refused_cases ()))
  in
  check (list (pair string string)) "the same refusals on the host thread" outside inside
;;

let lowered input =
  match Typed.to_shell_ir ~sandbox:(host ()) input with
  | Ok ir -> Format.asprintf "%a" Masc_exec.Shell_ir.pp ir
  | Error error -> Format.asprintf "error:%a" Typed.pp_validation_error error
;;

let findings input =
  Typed.hidden_script_findings ~sandbox:(host ()) input
  |> List.map (fun (shell, finding) ->
    shell ^ ":" ^ Keeper_tooling.Shell_costume.finding_tag finding)
;;

let inputs () =
  List.map
    (fun json -> Typed.of_json json |> Result.get_ok)
    [ `Assoc [ "command", `String "echo hi > out.txt"; "cwd", `String "/tmp" ]
    ; `Assoc [ "argv", `List [ `String "bash"; `String "-c"; `String "cat < in.txt" ]
             ; "cwd", `String "/masc_46410_absent/dir" ]
    ; `Assoc [ "argv", `List [ `String "ls"; `String "-la" ] ]
    ]
;;

let test_lowering_matches_outside_eio () =
  Systhread_host.start ();
  let answer input = lowered input, findings input in
  let outside = List.map answer (inputs ()) in
  let inside =
    with_eio (fun () ->
      List.map
        (fun input ->
           ( Systhread_host.run (fun () -> lowered input)
           , Systhread_host.run (fun () -> findings input) ))
        (inputs ()))
  in
  check
    (list (pair string (list string)))
    "the same lowering and findings on the host thread"
    outside
    inside
;;

let () =
  run
    "execute_shell_host_admission"
    [ ( "host thread"
      , [ test_case "an allowed command runs" `Quick test_allowed_command_runs
        ; test_case "refusals match outside Eio" `Quick test_refusals_match_outside_eio
        ; test_case "lowering matches outside Eio" `Quick test_lowering_matches_outside_eio
        ] )
    ]
;;
