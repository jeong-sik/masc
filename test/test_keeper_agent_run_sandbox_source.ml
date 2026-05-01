(** Structural guard for keeper provider-CLI sandbox cwd.

    Keeper-internal tools are sandbox-aware, but provider-native CLI tools
    such as Shell/ReadFile inherit the CLI transport cwd. If that cwd falls
    back to the server process cwd, Docker-profile keepers can dirty the repo
    root instead of their playground. This pins the handoff point into OAS. *)

open Alcotest

let target_file = "lib/keeper/keeper_agent_run.ml"
let run_tools_file = "lib/keeper/keeper_run_tools.ml"

let load_source rel =
  let source_root =
    match Sys.getenv_opt "DUNE_SOURCEROOT" with
    | Some root -> root
    | None -> Sys.getcwd ()
  in
  let path = Filename.concat source_root rel in
  if not (Sys.file_exists path)
  then failwith (Printf.sprintf "source file not found: %s" path)
  else (
    let ic = open_in path in
    Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () -> In_channel.input_all ic))
;;

let count_occurrences ~needle haystack =
  let nlen = String.length needle in
  if nlen = 0
  then 0
  else (
    let rec loop pos acc =
      if pos + nlen > String.length haystack
      then acc
      else if String.sub haystack pos nlen = needle
      then loop (pos + nlen) (acc + 1)
      else loop (pos + 1) acc
    in
    loop 0 0)
;;

let contains ~needle haystack = count_occurrences ~needle haystack > 0

let test_cli_transport_cwd_is_keeper_sandbox_root () =
  let src = load_source target_file in
  check
    bool
    "keeper_sandbox_root is derived from keeper meta"
    true
    (contains
       ~needle:
         "let keeper_sandbox_root = Keeper_sandbox.host_root_abs_of_meta ~config meta"
       src);
  check
    bool
    "CLI transport cwd uses keeper sandbox root"
    true
    (contains ~needle:"cwd = Some keeper_sandbox_root" src);
  check
    int
    "CLI transport cwd must not fall back to process cwd"
    0
    (count_occurrences ~needle:"cwd = None" src)
;;

let test_execution_receipt_reports_keeper_visible_sandbox_root () =
  let src = load_source target_file in
  check
    bool
    "receipt reports keeper-visible sandbox root"
    true
    (contains ~needle:"sandbox_root = Some keeper_visible_sandbox_root" src)
;;

let test_runtime_contract_sandbox_root_is_keeper_visible () =
  (* Runtime_contract.sandbox_root is consumed by the keeper LLM. Surfacing
     the host abs path there leaks the abstraction that the keeper lives
     entirely inside its sandbox; the LLM then emits host-path commands
     like [cd /Users/.../playground/<keeper>/...] on the next turn, which
     fail with No such file or directory inside the container.
     The fix routes the sandbox_root field through
     [Keeper_sandbox.keeper_visible_root_abs_of_meta] so Docker keepers see
     [container_root] and Local keepers keep the host path. *)
  let src = load_source target_file in
  check
    bool
    "runtime_contract sandbox_root routes through keeper_visible_root_abs_of_meta"
    true
    (contains
       ~needle:"Keeper_sandbox.keeper_visible_root_abs_of_meta ~config meta"
       src);
  check
    int
    "runtime_contract sandbox_root no longer calls host_root_abs_of_meta directly"
    0
    (count_occurrences
       ~needle:"~sandbox_root:(Keeper_sandbox.host_root_abs_of_meta"
       src)
;;

let test_keeper_tool_bundle_cleanup_is_retained_and_invoked () =
  let agent_src = load_source target_file in
  let run_tools_src = load_source run_tools_file in
  check
    bool
    "run setup retains the full keeper tool bundle"
    true
    (contains ~needle:"Keeper_tools_oas.make_tool_bundle" run_tools_src);
  check
    bool
    "run setup exposes the bundle cleanup callback"
    true
    (contains ~needle:"cleanup = keeper_tool_bundle.cleanup" run_tools_src);
  check
    bool
    "agent run reads setup cleanup callback"
    true
    (contains ~needle:"s.Keeper_run_tools.cleanup ()" agent_src);
  check
    int
    "agent run defines cleanup once and references it from both result and exception branches"
    3
    (count_occurrences ~needle:"cleanup_agent_setup" agent_src);
  check
    bool
    "agent run preserves exception propagation after cleanup"
    true
    (contains ~needle:"raise e" agent_src)
;;

let () =
  run
    "keeper_agent_run_sandbox_source"
    [ ( "provider_cli_sandbox"
      , [ test_case
            "CLI transport cwd is keeper sandbox root"
            `Quick
            test_cli_transport_cwd_is_keeper_sandbox_root
        ; test_case
            "receipt reports keeper-visible sandbox root"
            `Quick
            test_execution_receipt_reports_keeper_visible_sandbox_root
        ; test_case
            "runtime_contract sandbox_root is keeper-visible"
            `Quick
            test_runtime_contract_sandbox_root_is_keeper_visible
        ; test_case
            "keeper tool bundle cleanup is retained and invoked"
            `Quick
            test_keeper_tool_bundle_cleanup_is_retained_and_invoked
        ] )
    ]
;;
