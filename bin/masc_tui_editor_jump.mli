(** Open a file at a line in the operator's editor.

    Two ways in, and which one applies is a fact about the environment rather
    than a preference. When this surface runs inside a Neovim terminal, Neovim
    exports its own RPC address and the file can be sent there: the operator
    keeps the buffers, the marks and the undo history already open, and this
    surface keeps drawing. Otherwise there is no editor to send to, and the
    only way to open one is to hand it the terminal — which is what
    {!Masc_tui_editor} already does for the settings round-trip. *)

type target = {
  path : string;
      (** Absolute. A remote Neovim has its own working directory and it is
          not this process's, so a relative path would open a different file
          or none. *)
  line : int;  (** 1-based. Values below 1 are read as 1. *)
}

type route =
  | Remote_neovim of { server : string }
      (** [$NVIM] names a running Neovim's RPC address. It is set by
          [:terminal] and [jobstart()], so it is present exactly when this
          surface is a child of the editor the operator is looking at. *)
  | Terminal_handoff of { editor : string }
      (** No parent Neovim. [$EDITOR] (then [$VISUAL]) has to be given this
          terminal for as long as it runs. *)
  | No_editor
      (** Neither a parent Neovim nor a configured editor. Named rather than
          silently doing nothing, so a caller can say why the key did
          nothing. *)

val route : unit -> route
(** Read the environment. [$NVIM] wins when both are available: sending to
    the editor already on screen costs the operator nothing, and taking the
    terminal costs them this surface. *)

val remote_expression : target -> string
(** The Neovim expression that opens [target].

    Exposed because it is the part worth testing: it embeds a path inside a
    Vim string literal, and a path may contain the quote that ends one.
    Doubling is Vim's escape for that, and [fnameescape] then covers the
    characters [:edit] itself would read as syntax. *)

val send_to_neovim : server:string -> target -> (unit, string) result
(** Run [nvim --server <server> --remote-expr <expression>] and wait for it.

    The argument vector is passed to [execvp] rather than a shell, so the
    expression's own quoting is the only quoting in play. A non-zero exit or
    a signal is an error carrying what the child said. *)
