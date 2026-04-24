(** Unit tests for [Env_git_noninteractive] — RFC-0007 rev.3 PR-1.

    Asserts the exact pairs and docker argv flattening. Any change to the
    constants breaks these tests and forces a deliberate review (there is
    no reason to change them outside of a separate RFC). *)

module Env_git_noninteractive = Masc_mcp.Env_git_noninteractive

let test_env_pairs_are_exact () =
  Alcotest.(check (list (pair string string)))
    "env list matches the canonical two pairs"
    [ ("GIT_ASKPASS", ""); ("GIT_TERMINAL_PROMPT", "0") ]
    Env_git_noninteractive.env

let test_docker_env_args_flatten () =
  Alcotest.(check (list string))
    "docker_env_args is -e K=V for each pair, in order"
    [ "-e"; "GIT_ASKPASS="; "-e"; "GIT_TERMINAL_PROMPT=0" ]
    Env_git_noninteractive.docker_env_args

let test_docker_env_args_even_length () =
  (* Structural: each docker [-e KEY=VALUE] is exactly two argv tokens.
     Breaking this invariant breaks [keeper_shell_docker]'s inline argv. *)
  Alcotest.(check int)
    "docker_env_args length is 2x the env pair count"
    (2 * List.length Env_git_noninteractive.env)
    (List.length Env_git_noninteractive.docker_env_args)

let () =
  Alcotest.run "env_git_noninteractive"
    [
      ( "constants",
        [
          Alcotest.test_case "env pairs exact" `Quick test_env_pairs_are_exact;
          Alcotest.test_case "docker argv flatten" `Quick test_docker_env_args_flatten;
          Alcotest.test_case "docker argv length invariant" `Quick test_docker_env_args_even_length;
        ] );
    ]
