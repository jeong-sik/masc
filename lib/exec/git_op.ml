type t =
  | Read of
      [ `Status | `Log | `Diff | `Show | `Branch_list
      | `Remote_list | `Rev_parse | `Ls_files | `Blame ]
  | Mutating of
      [ `Commit | `Merge | `Rebase | `Pull | `Fetch
      | `Push | `Tag | `Stash_push | `Checkout_branch ]
  | Destructive of
      (* Trust-independent catastrophic floor (RFC-0255 §4.5).  This includes
         irreversible operations plus raw commands whose recovery preconditions
         are stateful and unproven at the syntax classifier. *)
      [ `Push_force | `Push_delete | `Push_mirror | `Clean_force
      | `Stash_drop | `Worktree_remove | `Reset_hard | `Branch_delete ]

let has_flag args flag = List.mem flag args

let has_long_flag args flag =
  List.exists
    (fun arg -> String.equal arg flag || String.starts_with ~prefix:(flag ^ "=") arg)
    args

(* git short flags bundle: [git clean -fd] carries [-f] inside the [-fd]
   cluster, and [git push -fv] carries [-f] inside [-fv]. [has_short_flag]
   matches a single-letter flag whether standalone ([-f]) or bundled with
   other short flags ([-fd], [-df], [-xfd]), but never inside a long flag
   ([--force-with-lease] is matched explicitly as a long force flag). Without
   this, [git clean -fd] — the common force form — bypasses the destructive
   classifier. *)
let has_short_flag args ch =
  List.exists
    (fun arg ->
      String.length arg >= 2 && arg.[0] = '-' && arg.[1] <> '-' && String.contains arg ch)
    args

(* A [git push] refspec carries its danger in a POSITIONAL (non-flag) token, not
   a flag: [:dst] (empty source) deletes the remote ref, and [+src[:dst]] (or a
   bare [+ref]) force-overwrites it. The flag checks ([--delete]/[--force]/[-f])
   never see these, so [git push origin :refs/heads/main] and
   [git push origin +refs/heads/main] would grade as an ordinary [Mutating Push]
   and auto-run. A leading '+' or ':' appears only on a refspec in push args (a
   remote name or a flag never starts with them), so a leading-char scan is
   exact. Same class as the leading-flag (#23390) and action-flag (find -delete)
   bypasses: danger in a non-flag token. *)
let has_leading_char_token ch args =
  List.exists (fun arg -> String.length arg > 0 && arg.[0] = ch) args

let rec strip_global_options = function
  | "-C" :: _path :: rest -> strip_global_options rest
  | "-c" :: _binding :: rest -> strip_global_options rest
  | "--git-dir" :: _dir :: rest -> strip_global_options rest
  | "--work-tree" :: _dir :: rest -> strip_global_options rest
  | "--namespace" :: _ns :: rest -> strip_global_options rest
  | "--no-pager" :: rest -> strip_global_options rest
  | "--literal-pathspecs" :: rest -> strip_global_options rest
  | args -> args

let of_argv = function
  | "git" :: raw_args ->
      let normalized = strip_global_options raw_args in
      (match normalized with
       | [] -> Error (`Unknown_subcmd "<missing git subcmd>")
       | sub :: rest ->
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
           if has_flag rest "--force"
              || has_long_flag rest "--force-with-lease"
              || has_short_flag rest 'f'
              (* [+src[:dst]] / [+ref] force-overwrites the remote ref *)
              || has_leading_char_token '+' rest
           then
             Ok (Destructive `Push_force)
           else if has_flag rest "--mirror" then
             Ok (Destructive `Push_mirror)
           else if
             has_flag rest "--delete" || has_short_flag rest 'd'
             (* [:dst] (empty source) deletes the remote ref *)
             || has_leading_char_token ':' rest
           then
             Ok (Destructive `Push_delete)
           else Ok (Mutating `Push)
       | "reset" when has_flag rest "--hard" ->
           Ok (Destructive `Reset_hard)
       | "clean" when has_short_flag rest 'f' || has_flag rest "--force" ->
           Ok (Destructive `Clean_force)
       | "worktree" ->
           (match rest with
            | "remove" :: _ -> Ok (Destructive `Worktree_remove)
            | _ -> Error (`Unknown_subcmd ("worktree " ^ String.concat " " rest)))
       | other -> Error (`Unknown_subcmd other)))
  | _ -> Error (`Unknown_subcmd "<non-git argv>")

let pp fmt = function
  | Read _ -> Format.fprintf fmt "git:read"
  | Mutating _ -> Format.fprintf fmt "git:mutating"
  | Destructive _ -> Format.fprintf fmt "git:destructive"
