(* RFC-0160 S6: Verify Shell IR-based guard token extraction preserves
   the semantics of the old Bash_words-based implementation. *)

open Alcotest

module NRT = Masc_mcp.Keeper_shell_docker_nested_runtime

let guard_words tokens =
  List.filter_map
    (function
      | NRT.Guard_word (w, _) -> Some w
      | NRT.Guard_separator -> None)
    tokens

let has_separator tokens =
  List.exists
    (function NRT.Guard_separator -> true | _ -> false)
    tokens

let test_simple_command () =
  let tokens = NRT.shell_guard_tokens "docker run ubuntu" in
  let words = guard_words tokens in
  check int "3 words" 3 (List.length words);
  check bool "starts with docker" true (List.mem "docker" words);
  check bool "no separator" false (has_separator tokens)

let test_pipeline_produces_separator () =
  let tokens = NRT.shell_guard_tokens "echo hello | docker run ubuntu" in
  let words = guard_words tokens in
  check bool "has docker" true (List.mem "docker" words);
  check bool "has separator" true (has_separator tokens)

let test_quoted_separator_preserved () =
  let tokens = NRT.shell_guard_tokens "echo 'hello;world'" in
  let words = guard_words tokens in
  check bool "has hello;world" true (List.mem "hello;world" words)

let test_unquoted_separator_split () =
  let tokens = NRT.shell_guard_tokens "echo hello; docker ps" in
  check bool "has separator" true (has_separator tokens)

let test_empty_command () =
  let tokens = NRT.shell_guard_tokens "" in
  check int "empty tokens" 0 (List.length tokens)

let test_nested_container_detection () =
  let is_nested = NRT.command_uses_nested_container_runtime "docker build -t myimage ." in
  check bool "docker detected" true is_nested;
  let is_nested2 = NRT.command_uses_nested_container_runtime "podman run alpine" in
  check bool "podman detected" true is_nested2;
  let not_nested = NRT.command_uses_nested_container_runtime "ls -la /tmp" in
  check bool "ls not nested" false not_nested

let test_sudo_docker_chain () =
  let is_nested = NRT.command_uses_nested_container_runtime "sudo docker ps" in
  check bool "sudo docker detected" true is_nested

let test_env_docker_chain () =
  let is_nested = NRT.command_uses_nested_container_runtime "env DOCKER_HOST=xxx docker ps" in
  check bool "env docker detected" true is_nested

let test_socket_reference () =
  let is_nested = NRT.command_uses_nested_container_runtime "curl --unix-socket /var/run/docker.sock http://localhost/info" in
  check bool "socket reference detected" true is_nested

let test_sh_c_docker () =
  let is_nested = NRT.command_uses_nested_container_runtime "sh -c 'docker ps'" in
  check bool "sh -c docker detected" true is_nested

let suite =
  [
    ( "guard_tokens"
    , [
        test_case "simple command" `Quick test_simple_command;
        test_case "pipeline separator" `Quick test_pipeline_produces_separator;
        test_case "quoted separator preserved" `Quick test_quoted_separator_preserved;
        test_case "unquoted separator split" `Quick test_unquoted_separator_split;
        test_case "empty command" `Quick test_empty_command;
      ] );
    ( "nested_container_detection"
    , [
        test_case "docker/podman detection" `Quick test_nested_container_detection;
        test_case "sudo docker chain" `Quick test_sudo_docker_chain;
        test_case "env docker chain" `Quick test_env_docker_chain;
        test_case "socket reference" `Quick test_socket_reference;
        test_case "sh -c docker" `Quick test_sh_c_docker;
      ] );
  ]

let () = Alcotest.run "Keeper_shell_docker_nested_runtime" suite
