(** Pure Antigravity CLI permission-pattern syntax, canonical path containment,
    and declarative ACP [settings.json] policy helpers.

    This leaf module has no dependency on {!Runtime_account_access} or
    {!Runtime_acp_client}, keeping the [lib/runtime] module graph acyclic when
    shared by {!Runtime_acp_client} and {!Runtime_antigravity_home}. *)

type error =
  { path : string
  ; detail : string
  }

val error_to_string : error -> string

val has_permission_pattern_syntax : string -> bool
(** True when [path] contains Antigravity permission-rule pattern
    metacharacters (asterisk, question mark, square brackets, or parentheses). *)

val path_is_within : root:string -> string -> bool
(** Whole-component canonical path containment: [true] when [path] lies at or
    below [root] ([/a/b] does not contain [/a/bc]). *)

val acp_settings_json
  :  ?mcp_server_name:string
  -> gemini_dir:string
  -> unit
  -> (Yojson.Safe.t, error) result
(** Build declarative Antigravity [settings.json] permissions for a managed
    ACP [--gemini-dir]: always denies reading [<gemini_dir>/config],
    [<gemini_dir>/antigravity-cli/antigravity-oauth-token], and wildcard
    native URL tools ([read_url] and [execute_url]). When [mcp_server_name] is
    provided, grants MCP tool calls on that server and recursive schema reads
    under [<gemini_dir>/antigravity-cli/mcp/<server>]. Rejects relative,
    NUL-bearing, or pattern-syntax paths and unsafe server names. *)
