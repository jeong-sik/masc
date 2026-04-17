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

let has_flag args flag = List.mem flag args

let of_argv = function
  | "git" :: sub :: rest ->
      (match sub with
       | "status" -> Ok (Read `Status)
       | "log" -> Ok (Read `Log)
       | "diff" -> Ok (Read `Diff)
       | "show" -> Ok (Read `Show)
       | "ls-files" -> Ok (Read `Ls_files)
       | "rev-parse" -> Ok (Read `Rev_parse)
       | "blame" -> Ok (Read `Blame)
       | "branch" ->
           if has_flag rest "-D" || has_flag rest "--delete" then
             Ok (Destructive `Branch_delete)
           else Ok (Read `Branch_list)
       | "remote" -> Ok (Read `Remote_list)
       | "commit" -> Ok (Mutating `Commit)
       | "merge" -> Ok (Mutating `Merge)
       | "rebase" -> Ok (Mutating `Rebase)
       | "pull" -> Ok (Mutating `Pull)
       | "fetch" -> Ok (Mutating `Fetch)
       | "tag" -> Ok (Mutating `Tag)
       | "checkout" -> Ok (Mutating `Checkout_branch)
       | "stash" ->
           (match rest with
            | "drop" :: _ -> Ok (Destructive `Stash_drop)
            | _ -> Ok (Mutating `Stash_push))
       | "push" ->
           if has_flag rest "--force" || has_flag rest "-f" then
             Ok (Destructive `Push_force)
           else Ok (Mutating `Push)
       | "reset" when has_flag rest "--hard" ->
           Ok (Destructive `Reset_hard)
       | "clean" when has_flag rest "-f" || has_flag rest "--force" ->
           Ok (Destructive `Clean_force)
       | "worktree" ->
           (match rest with
            | "remove" :: _ -> Ok (Destructive `Worktree_remove)
            | _ -> Error (`Unknown_subcmd ("worktree " ^ String.concat " " rest)))
       | other -> Error (`Unknown_subcmd other))
  | _ -> Error (`Unknown_subcmd "<non-git argv>")

let pp fmt = function
  | Read _ -> Format.fprintf fmt "git:read"
  | Mutating _ -> Format.fprintf fmt "git:mutating"
  | Destructive _ -> Format.fprintf fmt "git:destructive"
