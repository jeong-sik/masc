(** The host-key prompt has to answer a closed stdin, not raise on it.

    [confirm_host_key] returns [(unit, string) result] and answers its other
    two cases with a string. [read_line ()] raises [End_of_file] instead, so a
    script, a CI job or an agent calling the bootstrap with no terminal
    attached got an OCaml backtrace where the tool should have said which
    terminal it needs (#34678).

    The rule is the absence: nothing in this binary may reach [read_line],
    which has no way to report EOF. [In_channel.input_line] answers [None] and
    the caller turns that into
    [remote_ssh_host_key_confirmation_needs_a_terminal]. *)

open Alcotest

let source_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root when Sys.file_exists root -> root
  | _ -> Sys.getcwd ()
;;

let bootstrap = "bin/masc_exec_ssh_bootstrap.ml"

let bootstrap_path () = Filename.concat (source_root ()) bootstrap

let read_bootstrap () =
  let path = bootstrap_path () in
  if not (Sys.file_exists path) then failf "%s does not exist under %s" bootstrap (source_root ());
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))
;;

(* An empty read would satisfy every claim below, so it fails first. *)
let test_the_source_is_readable () =
  check bool "the bootstrap source has content" true (String.length (read_bootstrap ()) > 0)
;;

let test_the_prompt_does_not_reach_read_line () =
  check
    int
    "calls to read_line in the bootstrap"
    0
    (Ast_grep.count_calls ~module_path:(bootstrap_path ()) ~callee:"read_line")
;;

let test_the_terminal_refusal_is_named () =
  let source = read_bootstrap () in
  check
    bool
    "remote_ssh_host_key_confirmation_needs_a_terminal is the answer to a closed stdin"
    true
    (String_util.contains_substring source "remote_ssh_host_key_confirmation_needs_a_terminal")
;;

let () =
  run
    "exec_ssh_bootstrap"
    [ ( "host key prompt"
      , [ test_case "the source is readable" `Quick test_the_source_is_readable
        ; test_case "the prompt does not reach read_line" `Quick
            test_the_prompt_does_not_reach_read_line
        ; test_case "the terminal refusal is named" `Quick
            test_the_terminal_refusal_is_named
        ] )
    ]
;;
