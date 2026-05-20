(** gh-pr native-tool routing hints for keeper_bash. *)

type native_tool_hint =
  { rule_id : string
  ; tool_suggestion : string
  ; rewrite : string
  ; hint : string
  ; alternatives : string list
  }

(** Map a raw shell command to the corresponding keeper_pr_* tool
    suggestion when it would otherwise call [gh pr <subcommand>]
    directly. Returns [None] for commands outside the gh-pr surface. *)
val gh_pr_native_tool_hint : string -> native_tool_hint option

(** Wrap a [native_tool_hint] into the [Exec_core] diagnostic record. *)
val native_tool_diagnosis : native_tool_hint -> Exec_core.diagnosis
