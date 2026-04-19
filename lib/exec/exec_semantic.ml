type t =
  [ `Ok
  | `Fail of int
  | `Timeout of float
  | `Signaled of int
  | `Git_not_a_repo
  | `Oom_killed
  | `Policy_denied of string
  | `Tool_missing of string
  | `Permission_denied of string ]

let is_git_argv = function
  | "git" :: _ -> true
  | bin :: _ when Filename.basename bin = "git" -> true
  | _ -> false

let stderr_hints_oom stderr =
  let lower = String.lowercase_ascii stderr in
  let contains s sub =
    let ls = String.length s and lb = String.length sub in
    if lb = 0 || lb > ls then false
    else
      let rec loop i =
        if i + lb > ls then false
        else if String.sub s i lb = sub then true
        else loop (i + 1)
      in
      loop 0
  in
  contains lower "out of memory"
  || contains lower "oom-killer"
  || contains lower "killed (oom)"
  || contains lower "cannot allocate memory"

let interpret ~argv ~status ~stdout:_ ~stderr =
  match status with
  | Unix.WEXITED 0 -> `Ok
  | Unix.WEXITED 127 ->
      let tool = match argv with
        | x :: _ -> Filename.basename x
        | [] -> ""
      in
      `Tool_missing tool
  | Unix.WEXITED 126 ->
      let path = match argv with
        | x :: _ -> x
        | [] -> ""
      in
      `Permission_denied path
  | Unix.WEXITED 128 when is_git_argv argv -> `Git_not_a_repo
  | Unix.WEXITED code -> `Fail code
  | Unix.WSIGNALED n when n = Sys.sigkill && stderr_hints_oom stderr ->
      `Oom_killed
  | Unix.WSIGNALED n -> `Signaled n
  | Unix.WSTOPPED n -> `Signaled n

let to_hint = function
  | `Ok -> None
  | `Fail n -> Some (Printf.sprintf "command exited with code %d" n)
  | `Timeout s -> Some (Printf.sprintf "timed out after %.1fs" s)
  | `Signaled n -> Some (Printf.sprintf "process terminated by signal %d" n)
  | `Git_not_a_repo ->
      Some "git exit 128 — cwd is not inside a git repository"
  | `Oom_killed ->
      Some "process was OOM-killed — try a smaller input or higher mem limit"
  | `Policy_denied rule ->
      Some (Printf.sprintf "policy denied: %s" rule)
  | `Tool_missing tool ->
      Some (Printf.sprintf "tool not found on PATH: %s" tool)
  | `Permission_denied path ->
      Some (Printf.sprintf "EACCES: cannot execute %s" path)

type payload_value =
  [ `String of string
  | `Int of int
  | `Float of float ]

let to_kind = function
  | `Ok -> "ok"
  | `Fail _ -> "fail"
  | `Timeout _ -> "timeout"
  | `Signaled _ -> "signaled"
  | `Git_not_a_repo -> "git_not_a_repo"
  | `Oom_killed -> "oom_killed"
  | `Policy_denied _ -> "policy_denied"
  | `Tool_missing _ -> "tool_missing"
  | `Permission_denied _ -> "permission_denied"

let to_payload : t -> (string * payload_value) list = function
  | `Ok -> []
  | `Fail n -> [ "exit_code", `Int n ]
  | `Timeout s -> [ "seconds", `Float s ]
  | `Signaled n -> [ "signal", `Int n ]
  | `Git_not_a_repo -> []
  | `Oom_killed -> []
  | `Policy_denied rule -> [ "rule", `String rule ]
  | `Tool_missing tool -> [ "tool", `String tool ]
  | `Permission_denied path -> [ "path", `String path ]

let enabled () =
  match Sys.getenv_opt "MASC_BASH_SEMANTIC_EXIT" with
  | Some ("1" | "true" | "TRUE") -> true
  | _ -> false
