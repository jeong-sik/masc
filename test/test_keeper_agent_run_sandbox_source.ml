(** Structural guard for keeper provider-CLI sandbox cwd.

    Keeper-internal tools are sandbox-aware, but provider-native CLI tools
    such as Shell/ReadFile inherit the CLI transport cwd. If that cwd falls
    back to the server process cwd, Docker-profile keepers can dirty the repo
    root instead of their playground. This pins the handoff point into OAS. *)

open Alcotest

let target_file = "lib/keeper/keeper_agent_run.ml"

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

let test_execution_receipt_reports_same_sandbox_root () =
  let src = load_source target_file in
  check
    bool
    "receipt reports keeper sandbox root"
    true
    (contains ~needle:"sandbox_root = Some keeper_sandbox_root" src)
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
            "receipt reports same sandbox root"
            `Quick
            test_execution_receipt_reports_same_sandbox_root
        ] )
    ]
;;
