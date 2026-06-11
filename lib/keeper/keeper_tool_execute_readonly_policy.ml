let readonly_hint_of_category = function
  | "chaining" ->
    "`&&`, `||`, and `;` chaining are blocked in readonly shell. \
     Issue one command per Execute call, or use visible read/search \
     aliases such as Read and Grep. \
     Good: Execute executable='git' argv=['status']. \
     Bad: raw shell text 'git status && git log -1'."
  | "redirect" ->
    "Redirects (`>`, `>>`, `| tee`) are blocked in readonly shell. \
     Use Write/Edit when a file must change, or Execute only when the \
     active runtime schema exposes a write-capable Execute surface. \
     Good: Write file_path='notes.md' content='...'. \
     Bad: raw shell text 'echo hi > notes.md'."
  | "git_write" ->
    "Use Execute only when the active runtime schema exposes write-capable command \
     execution for git writes. \
     Good: Execute executable='git' argv=['add','lib/foo.ml']. \
     Bad: raw shell text 'git commit -m x' without write access \
     does not accept git write commands)."
  | "package_install" ->
    "Package installation requires a write-capable Execute surface. \
     Good: Execute executable='opam' argv=['install','-y','eio']. \
     Bad: raw shell text 'opam install eio' without write access \
     does not accept package installs)."
  | "destructive" ->
    "Use Execute only when the active runtime schema exposes write-capable command \
     execution, not readonly shell. \
     Good: Execute executable='rm' argv=['.tmp/scratch.log']. \
     Bad: raw shell text 'rm -rf .tmp/' (readonly shell does \
     not accept destructive commands)."
  | _ -> "This operation is not allowed in readonly shell."
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
            "Split into two Execute calls, or use visible Read/Grep \
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
             the second Execute call."
      ; tool_suggestion = None
      }
  | Exec_policy.Direct_dune_invocation ->
    Some
      { Exec_core.rule_id = "direct_dune_blocked"
      ; explanation =
          "Bare dune bypasses scripts/dune-local.sh and can create \
           concurrent local builds that exhaust host file descriptors."
      ; rewrite = Some "Run scripts/dune-local.sh build <target> from the repo root."
      ; tool_suggestion = Some "Execute"
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
             argument in a second Execute call."
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
  | Exec_policy.Empty_command ->
    Some
      { Exec_core.rule_id = "command_empty"
      ; explanation = "The command string is empty."
      ; rewrite = Some "Provide typed argv: Execute executable='ls' argv=['-la','lib/']."
      ; tool_suggestion = None
      }
;;
