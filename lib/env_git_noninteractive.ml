let env =
  [
    ("GIT_ASKPASS", "");
    ("GIT_TERMINAL_PROMPT", "0");
  ]

let docker_env_args =
  List.concat_map (fun (k, v) -> [ "-e"; k ^ "=" ^ v ]) env
