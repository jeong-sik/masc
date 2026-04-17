(** Git_op — typed classification of the first positional after [git].

    Three severity tiers, each a polymorphic variant.  Unknown
    subcommands return an error so the caller decides: in practice the
    approval policy maps them to [Ask]. *)

type t =
  | Read of
      [ `Status | `Log | `Diff | `Show | `Branch_list
      | `Remote_list | `Rev_parse | `Ls_files | `Blame ]
  | Mutating of
      [ `Commit | `Merge | `Rebase | `Pull | `Fetch
      | `Push | `Tag | `Stash_push | `Checkout_branch ]
  | Destructive of
      [ `Reset_hard | `Push_force | `Branch_delete
      | `Clean_force | `Stash_drop | `Worktree_remove ]

val of_argv : string list -> (t, [ `Unknown_subcmd of string ]) result
(** [of_argv argv] expects [argv] to start with the [git] token.  The
    classifier is syntactic only — it does not execute git. *)

val pp : Format.formatter -> t -> unit
