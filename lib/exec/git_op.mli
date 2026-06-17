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
      (* Irreversible — RFC-0255 §4.5 catastrophic floor. *)
      [ `Push_force | `Clean_force | `Stash_drop | `Worktree_remove ]
  | Destructive_recoverable of
      (* Reflog-recoverable — RFC-0255 §4.5, overlay-graded not floored. *)
      [ `Reset_hard | `Branch_delete ]

val of_argv : string list -> (t, [ `Unknown_subcmd of string ]) result
(** [of_argv argv] expects [argv] to start with the [git] token.  The
    classifier is syntactic only — it does not execute git. *)

val pp : Format.formatter -> t -> unit
