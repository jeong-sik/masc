let git_global_option_takes_value = function
  | "-c"
  | "-C"
  | "--exec-path"
  | "--git-dir"
  | "--work-tree"
  | "--namespace"
  | "--super-prefix"
  | "--config-env" -> true
  | _ -> false
;;

let git_global_option_has_inline_value token =
  List.exists
    (fun prefix -> String.starts_with ~prefix token)
    [ "--exec-path="; "--git-dir="; "--work-tree="; "--namespace="; "--config-env=" ]
;;

let rec first_git_subcommand = function
  | [] -> None
  | token :: rest when git_global_option_takes_value token ->
    (match rest with
     | _value :: tail -> first_git_subcommand tail
     | [] -> None)
  | token :: rest when git_global_option_has_inline_value token ->
    first_git_subcommand rest
  | token :: rest when String.starts_with ~prefix:"-" token -> first_git_subcommand rest
  | token :: _rest -> Some token
;;

let readonly_shell_token_match tokens =
  match tokens with
  | [] -> None
  | "git" :: rest ->
    (match first_git_subcommand rest with
     | Some "push" -> Some ("git push", "git_write")
     | Some "reset" -> Some ("git reset", "git_write")
     | Some "checkout" -> Some ("git checkout", "git_write")
     | Some "rebase" -> Some ("git rebase", "git_write")
     | _ -> None)
  | "pip" :: "install" :: _ -> Some ("pip install", "package_install")
  | "npm" :: "install" :: _ -> Some ("npm install", "package_install")
  | "opam" :: "install" :: _ -> Some ("opam install", "package_install")
  | "rm" :: _ -> Some ("rm ", "destructive")
  | "rmdir" :: _ -> Some ("rmdir", "destructive")
  | "mv" :: _ -> Some ("mv ", "destructive")
  | "cp" :: _ -> Some ("cp ", "destructive")
  | "chmod" :: _ -> Some ("chmod", "destructive")
  | "chown" :: _ -> Some ("chown", "destructive")
  | "kill" :: _ -> Some ("kill", "destructive")
  | "pkill" :: _ -> Some ("pkill", "destructive")
  | "dd" :: _ -> Some ("dd ", "destructive")
  | "mkfs" :: _ -> Some ("mkfs", "destructive")
  | "wget" :: _ -> Some ("wget ", "destructive")
  | "curl" :: rest when List.exists (String.equal "-o") rest ->
    Some ("curl -o", "destructive")
  | "curl" :: rest when List.exists (String.equal "--output") rest ->
    Some ("curl --output", "destructive")
  | _ -> None
;;

let readonly_hint_of_category = function
  | "chaining" ->
    "`&&`, `||`, and `;` chaining are blocked in readonly shell. \
     Issue one command per Bash call, or use visible read/search \
     aliases such as Read and Grep. \
     Good: Bash executable='git' argv=['status']. \
     Bad: raw shell text 'git status && git log -1'."
  | "redirect" ->
    "Redirects (`>`, `>>`, `| tee`) are blocked in readonly shell. \
     Use Write/Edit when a file must change, or Bash only when the \
     active policy exposes a write-capable Bash surface. \
     Good: Write file_path='notes.md' content='...'. \
     Bad: raw shell text 'echo hi > notes.md'."
  | "git_write" ->
    "Use Bash only when the active policy exposes write-capable command \
     execution for git writes. \
     Good: Bash executable='git' argv=['add','lib/foo.ml']. \
     Bad: raw shell text 'git commit -m x' without write access \
     does not accept git write commands)."
  | "package_install" ->
    "Package installation requires a write-capable Bash surface. \
     Good: Bash executable='opam' argv=['install','-y','eio']. \
     Bad: raw shell text 'opam install eio' without write access \
     does not accept package installs)."
  | "destructive" ->
    "Use Bash only when the active policy exposes write-capable command \
     execution, not readonly shell. \
     Good: Bash executable='rm' argv=['.tmp/scratch.log']. \
     Bad: raw shell text 'rm -rf .tmp/' (readonly shell does \
     not accept destructive commands)."
  | _ -> "This operation is not allowed in readonly shell."
;;

let diagnosis_of_readonly_category category =
  match category with
  | "chaining" ->
    Some
      { Exec_core.rule_id = "readonly_chaining_blocked"
      ; explanation =
          "&&, ||, and ; chain multiple commands; the readonly shell \
           validates one command per call."
      ; rewrite =
          Some
            "Split into two typed argv calls: Bash executable='git' \
             argv=['status'] then Bash executable='git' argv=['log','-1']."
      ; tool_suggestion = None
      }
  | "redirect" ->
    Some
      { Exec_core.rule_id = "readonly_redirect_blocked"
      ; explanation = "> and >> modify the filesystem; readonly shell forbids writes."
      ; rewrite = None
      ; tool_suggestion = Some "Write"
      }
  | "git_write" ->
    Some
      { Exec_core.rule_id = "readonly_git_write_blocked"
      ; explanation =
          "git commit/push/checkout modify state; readonly shell only \
           allows read-only git subcommands (log, diff, status, show)."
      ; rewrite =
          Some
            "Use a write-capable Bash surface: Bash executable='git' \
             argv=['add','lib/foo.ml']. Commit in a second Bash call."
      ; tool_suggestion = None
      }
  | "package_install" ->
    Some
      { Exec_core.rule_id = "readonly_package_install_blocked"
      ; explanation =
          "opam install / npm install mutate the global environment; \
           readonly shell forbids package mutations."
      ; rewrite =
          Some
            "Use a write-capable Bash surface: Bash executable='opam' \
             argv=['install','-y','eio']."
      ; tool_suggestion = None
      }
  | "destructive" ->
    Some
      { Exec_core.rule_id = "readonly_destructive_blocked"
      ; explanation =
          "rm, curl -o, and similar destructive commands modify or \
           delete state; readonly shell forbids them."
      ; rewrite =
          Some
            "Use a write-capable Bash surface: Bash executable='rm' \
             argv=['.tmp/scratch.log']."
      ; tool_suggestion = None
      }
  | _ -> None
;;

let diagnosis_of_block_reason reason =
  match reason with
  | Exec_policy.Chain_or_redirect ->
    Some
      { Exec_core.rule_id = "command_chaining_blocked"
      ; explanation =
          "Pipe | and chain && or ; combine multiple commands; the \
           keeper validates one command per call."
      ; rewrite =
          Some
            "Split into two Bash calls, or use visible Read/Grep \
             tools for file inspection and search."
      ; tool_suggestion = None
      }
  | Exec_policy.Pipes_not_allowed ->
    Some
      { Exec_core.rule_id = "command_pipe_blocked"
      ; explanation =
          "Pipes (|) connect two processes; each needs separate \
           validation in the keeper security model."
      ; rewrite =
          Some
            "Run the first command, then pipe the output into \
             the second Bash call."
      ; tool_suggestion = None
      }
  | Exec_policy.Direct_dune_invocation ->
    Some
      { Exec_core.rule_id = "direct_dune_blocked"
      ; explanation =
          "Bare dune bypasses scripts/dune-local.sh and can create \
           concurrent local builds that exhaust host file descriptors."
      ; rewrite = Some "Run scripts/dune-local.sh build <target> from the repo root."
      ; tool_suggestion = Some "Bash"
      }
  | Exec_policy.Unsafe_redirect ->
    Some
      { Exec_core.rule_id = "command_redirect_blocked"
      ; explanation =
          "Redirect syntax changes process I/O outside the typed command \
           contract."
      ; rewrite = None
      ; tool_suggestion = Some "Write"
      }
  | Exec_policy.Injection ->
    Some
      { Exec_core.rule_id = "command_injection_blocked"
      ; explanation =
          "Shell metacharacters ($(), ``, eval) can inject arbitrary \
           commands; they are blocked for safety."
      ; rewrite =
          Some
            "Compute the value first, then pass it as a literal \
             argument in a second Bash call."
      ; tool_suggestion = None
      }
  | Exec_policy.Process_substitution ->
    Some
      { Exec_core.rule_id = "command_process_subst_blocked"
      ; explanation =
          "<() and >() process substitutions create sub-processes; \
           they are blocked for safety."
      ; rewrite =
          Some
            "Write the intermediate result to a temp file, then \
             reference it in the second command."
      ; tool_suggestion = None
      }
  | Exec_policy.Command_not_allowed name ->
    Some
      { Exec_core.rule_id = "command_not_allowed"
      ; explanation =
          Printf.sprintf "'%s' is not on the allowed command list for this preset." name
      ; rewrite = None
      ; tool_suggestion = None
      }
  | Exec_policy.Empty_command ->
    Some
      { Exec_core.rule_id = "command_empty"
      ; explanation = "The command string is empty."
      ; rewrite = Some "Provide typed argv: Bash executable='ls' argv=['-la','lib/']."
      ; tool_suggestion = None
      }
;;
