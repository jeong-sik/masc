(** The [keeper_code_query] tool: ask the language server about a name.

    RFC a-language-server-the-keeper-can-ask. [Lsp_workspace_pool] holds the
    servers and [Lsp_questions] asks them; this is the surface a Keeper reaches
    them through, and it is where the Keeper's sandbox bounds the question.

    Three questions. [textDocument/references] answers only the opened file's
    own occurrences when the project's reference index is missing — one where
    the truth was three, measured — so it is checked for before the question is
    asked, and its absence is an answer naming the command that fixes it
    (#30504).

    Positions are 1-based in and out, the way [Grep] and [Read] report them.
    LSP counts from 0; that conversion happens here rather than in the Keeper's
    head. *)

val dispatch
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> name:string
  -> args:Yojson.Safe.t
  -> Tool_result.result option
(** [None] for a name this module does not own, which is how a tag dispatch
    asks whether a call is this one. *)
