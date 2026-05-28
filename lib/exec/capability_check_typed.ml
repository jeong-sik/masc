(** Capability_check_typed — GADT-based capability derivation.

    Each arm reconstructs the [Shell_ir.arg list] that the untyped walker
    would have produced, then wraps it in [Capability.Exec_program].  This
    keeps the capability model unchanged while making the walker indexed
    by the GADT.

    Env / redirect handling: typed constructors do not carry [env] or
    [redirects], so [Shell_ir_typed.of_simple] forces the [Generic]
    fallback whenever the source [simple] has either set.  That keeps
    redirect-derived [Read_path] / [Write_path] and [Env_set]
    capabilities flowing through [Capability_check.of_simple] for the
    [Generic] arm below — without this any redirect outside the
    worktree would be invisible to [Approval_policy.find_write_escape]
    on a parsed command. *)

let arg s = Shell_ir.Lit (s, Shell_ir.default_meta)

let args_of_flags flags =
  List.map
    (function
      | `Long -> arg "-l"
      | `All -> arg "-a"
      | `Human -> arg "-h")
    flags
;;

let of_command = function
  | Shell_ir_typed.W (Ls { path; flags }) ->
    let args =
      args_of_flags flags
      @
      match path with
      | None -> []
      | Some p -> [ arg p ]
    in
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Ls, args) ]
  | Shell_ir_typed.W (Cat { path }) ->
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Cat, [ arg path ]) ]
  | Shell_ir_typed.W (Rg { pattern; path; case_sensitive }) ->
    let args =
      (if case_sensitive then [] else [ arg "-i" ])
      @ [ arg pattern ]
      @
      match path with
      | None -> []
      | Some p -> [ arg p ]
    in
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Rg, args) ]
  | Shell_ir_typed.W (Git_status { short }) ->
    let args = arg "status" :: (if short then [ arg "-s" ] else []) in
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Git, args) ]
  | Shell_ir_typed.W (Git_clone { repo; branch; depth }) ->
    let args =
      (arg "clone"
       :: (match depth with
          | Some d -> [ arg "--depth"; arg (string_of_int d) ]
          | None -> []))
      @ (match branch with
         | None -> []
         | Some b -> [ arg "-b"; arg b ])
      @ [ arg repo ]
    in
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Git, args) ]
  | Shell_ir_typed.W (Curl { url; method_; headers; body }) ->
    let method_args =
      match method_ with
      | `GET -> []
      | `POST -> [ arg "-X"; arg "POST" ]
      | `PUT -> [ arg "-X"; arg "PUT" ]
      | `DELETE -> [ arg "-X"; arg "DELETE" ]
    in
    let header_args =
      match headers with
      | None -> []
      | Some hs -> List.concat_map (fun (k, v) -> [ arg "-H"; arg (k ^ ": " ^ v) ]) hs
    in
    let body_args =
      match body with
      | None -> []
      | Some d -> [ arg "-d"; arg d ]
    in
    let args = method_args @ header_args @ body_args @ [ arg url ] in
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Curl, args) ]
  | Shell_ir_typed.W (Rm { paths; recursive; force }) ->
    let flag_args =
      (if recursive then [ arg "-r" ] else []) @ if force then [ arg "-f" ] else []
    in
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Rm, flag_args @ List.map arg paths) ]
  | Shell_ir_typed.W (Sudo { target_argv }) ->
    let args = List.map arg target_argv in
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Sudo, args) ]
  | Shell_ir_typed.W (Find { path; name; type_ }) ->
    let args =
      arg path
      :: (match name with None -> [] | Some n -> [ arg "-name"; arg n ])
      @ (match type_ with
         | None -> []
         | Some `File -> [ arg "-type"; arg "f" ]
         | Some `Dir -> [ arg "-type"; arg "d" ])
    in
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Find, args) ]
  | Shell_ir_typed.W (Head { path; lines }) ->
    let args = [ arg "-n"; arg (string_of_int lines); arg path ] in
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Head, args) ]
  | Shell_ir_typed.W (Tail { path; lines }) ->
    let args = [ arg "-n"; arg (string_of_int lines); arg path ] in
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Tail, args) ]
  | Shell_ir_typed.W (Grep { pattern; path; recursive; case_sensitive }) ->
    let args =
      (if recursive then [ arg "-r" ] else [])
      @ (if case_sensitive then [] else [ arg "-i" ])
      @ arg pattern
        :: (match path with None -> [] | Some p -> [ arg p ])
    in
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Grep, args) ]
  | Shell_ir_typed.W (Mkdir { path; parents }) ->
    let args = (if parents then [ arg "-p" ] else []) @ [ arg path ] in
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Mkdir, args) ]
  | Shell_ir_typed.W (Wc { path; mode }) ->
    let flag_args =
      match mode with
      | Some `Lines -> [ arg "-l" ]
      | Some `Words -> [ arg "-w" ]
      | Some `Chars -> [ arg "-c" ]
      | None -> []
    in
    let args = flag_args @ [ arg path ] in
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Wc, args) ]
  | Shell_ir_typed.W (Git_diff { stat; cached; paths }) ->
    let flag_args =
      (if stat then [ arg "--stat" ] else [])
      @ (if cached then [ arg "--cached" ] else [])
    in
    [ Capability.Exec_program
        (Exec_program.of_known Exec_program.Git, arg "diff" :: flag_args @ List.map arg paths)
    ]
  | Shell_ir_typed.W (Git_log { oneline; max_count }) ->
    let flag_args =
      (if oneline then [ arg "--oneline" ] else [])
      @ (match max_count with None -> [] | Some n -> [ arg "-n"; arg (string_of_int n) ])
    in
    [ Capability.Exec_program
        (Exec_program.of_known Exec_program.Git, arg "log" :: flag_args)
    ]
  | Shell_ir_typed.W (Git_commit { message; amend }) ->
    let flag_args =
      (if amend then [ arg "--amend" ] else [])
      @ [ arg "-m"; arg message ]
    in
    [ Capability.Exec_program
        (Exec_program.of_known Exec_program.Git, arg "commit" :: flag_args)
    ]
  | Shell_ir_typed.W (Git_push { force; force_with_lease; set_upstream; remote; branch }) ->
    let flag_args =
      (if force then [ arg "--force" ] else [])
      @ (if force_with_lease then [ arg "--force-with-lease" ] else [])
      @ (if set_upstream then [ arg "-u" ] else [])
    in
    let positional =
      (match remote with None -> [] | Some r -> [ arg r ])
      @ (match branch with None -> [] | Some b -> [ arg b ])
    in
    [ Capability.Exec_program
        (Exec_program.of_known Exec_program.Git, arg "push" :: flag_args @ positional)
    ]
  | Shell_ir_typed.W (Git_pull { rebase; remote; branch }) ->
    let flag_args = if rebase then [ arg "--rebase" ] else [] in
    let positional =
      (match remote with None -> [] | Some r -> [ arg r ])
      @ (match branch with None -> [] | Some b -> [ arg b ])
    in
    [ Capability.Exec_program
        (Exec_program.of_known Exec_program.Git, arg "pull" :: flag_args @ positional)
    ]
  | Shell_ir_typed.W (Pwd ()) ->
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Pwd, []) ]
  | Shell_ir_typed.W (Echo { args = echo_args }) ->
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Echo, List.map arg echo_args) ]
  | Shell_ir_typed.W (Which { names }) ->
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Which, List.map arg names) ]
  | Shell_ir_typed.W (Sort { reverse; numeric; unique; key; file }) ->
    let flag_args =
      (if reverse then [ arg "-r" ] else [])
      @ (if numeric then [ arg "-n" ] else [])
      @ (if unique then [ arg "-u" ] else [])
      @ (match key with None -> [] | Some k -> [ arg "-k"; arg (string_of_int k) ])
    in
    let file_args = match file with None -> [] | Some f -> [ arg f ] in
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Sort, flag_args @ file_args) ]
  | Shell_ir_typed.W (Cut { delimiter; fields; file }) ->
    let flag_args =
      (match delimiter with None -> [] | Some d -> [ arg "-d"; arg d ])
      @ [ arg "-f"; arg fields ]
    in
    let file_args = match file with None -> [] | Some f -> [ arg f ] in
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Cut, flag_args @ file_args) ]
  | Shell_ir_typed.W (Tr { set1; set2; delete; squeeze }) ->
    let flag_args =
      (if delete then [ arg "-d" ] else [])
      @ (if squeeze then [ arg "-s" ] else [])
    in
    let set_args = match set2 with None -> [ arg set1 ] | Some s -> [ arg set1; arg s ] in
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Tr, flag_args @ set_args) ]
  | Shell_ir_typed.W (Date { format; utc }) ->
    let flag_args = if utc then [ arg "-u" ] else [] in
    let format_args = match format with None -> [] | Some f -> [ arg f ] in
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Date, flag_args @ format_args) ]
  | Shell_ir_typed.W (Env ()) ->
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Env, []) ]
  | Shell_ir_typed.W (Printenv { name }) ->
    let args = match name with None -> [] | Some n -> [ arg n ] in
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Printenv, args) ]
  | Shell_ir_typed.W (Uniq { count; duplicates; unique; file }) ->
    let flag_args =
      (if count then [ arg "-c" ] else [])
      @ (if duplicates then [ arg "-d" ] else [])
      @ (if unique then [ arg "-u" ] else [])
    in
    let file_args = match file with None -> [] | Some f -> [ arg f ] in
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Uniq, flag_args @ file_args) ]
  | Shell_ir_typed.W (Basename { path; suffix }) ->
    let args =
      arg path :: (match suffix with None -> [] | Some s -> [ arg s ])
    in
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Basename, args) ]
  | Shell_ir_typed.W (Dirname { path }) ->
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Dirname, [ arg path ]) ]
  | Shell_ir_typed.W (Test { expression }) ->
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Test, List.map arg expression) ]
  | Shell_ir_typed.W (Stat { format; path }) ->
    let args =
      (match format with None -> [] | Some f -> [ arg "-f"; arg f ])
      @ [ arg path ]
    in
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Stat, args) ]
  | Shell_ir_typed.W (Hostname { short }) ->
    let args = if short then [ arg "-s" ] else [] in
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Hostname, args) ]
  | Shell_ir_typed.W (Whoami ()) ->
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Whoami, []) ]
  | Shell_ir_typed.W (Du { path; human_readable; summary; max_depth }) ->
    let flag_args =
      (if human_readable then [ arg "-h" ] else [])
      @ (if summary then [ arg "-s" ] else [])
      @ (match max_depth with
         | None -> []
         | Some d -> [ arg ("--max-depth=" ^ string_of_int d) ])
    in
    let path_args = match path with None -> [] | Some p -> [ arg p ] in
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Du, flag_args @ path_args) ]
  | Shell_ir_typed.W (Df { path; human_readable; filesystem_type }) ->
    let flag_args =
      (if human_readable then [ arg "-h" ] else [])
      @ (match filesystem_type with
         | None -> []
         | Some t -> [ arg "-t"; arg t ])
    in
    let path_args = match path with None -> [] | Some p -> [ arg p ] in
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Df, flag_args @ path_args) ]
  | Shell_ir_typed.W (File { path; mime; brief }) ->
    let flag_args =
      (if brief then [ arg "-b" ] else [])
      @ (if mime then [ arg "-i" ] else [])
    in
    [ Capability.Exec_program (Exec_program.of_known Exec_program.File, flag_args @ [ arg path ]) ]
  | Shell_ir_typed.W (Printf { format; args = fmt_args }) ->
    [ Capability.Exec_program
        (Exec_program.of_known Exec_program.Printf, arg format :: List.map arg fmt_args)
    ]
  | Shell_ir_typed.W (Uname { all; kernel_name; release; machine }) ->
    let args =
      (if all then [ arg "-a" ] else [])
      @ (if kernel_name then [ arg "-s" ] else [])
      @ (if release then [ arg "-r" ] else [])
      @ (if machine then [ arg "-m" ] else [])
    in
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Uname, args) ]
  | Shell_ir_typed.W (Ps { all; full; user }) ->
    let flag_args =
      (if all then [ arg "-e" ] else [])
      @ (if full then [ arg "-f" ] else [])
      @ (match user with None -> [] | Some u -> [ arg "-u"; arg u ])
    in
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Ps, flag_args) ]
  | Shell_ir_typed.W (Tty ()) ->
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Tty, []) ]
  | Shell_ir_typed.W (Wget { url; output }) ->
    let flag_args = match output with None -> [] | Some o -> [ arg "-O"; arg o ] in
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Wget, flag_args @ [ arg url ]) ]
  | Shell_ir_typed.W (Ssh { host; user; command; port }) ->
    let target =
      match user with None -> host | Some u -> u ^ "@" ^ host
    in
    let port_args = match port with Some p -> [ arg "-p"; arg (string_of_int p) ] | None -> [] in
    let cmd_args = match command with None -> [] | Some c -> [ arg c ] in
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Ssh, port_args @ [ arg target ] @ cmd_args) ]
  | Shell_ir_typed.W (Scp { source; dest; recursive; port }) ->
    let port_args = match port with Some p -> [ arg "-P"; arg (string_of_int p) ] | None -> [] in
    let flag_args = port_args @ (if recursive then [ arg "-r" ] else []) in
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Scp, flag_args @ [ arg source; arg dest ]) ]
  | Shell_ir_typed.W (Tar { action; archive; paths; compression }) ->
    let action_flag =
      match action with `Create -> "-c" | `Extract -> "-x" | `List -> "-t"
    in
    let compression_flags =
      match compression with
      | `None -> []
      | `Gzip -> [ arg "-z" ]
      | `Bzip2 -> [ arg "-j" ]
      | `Xz -> [ arg "-J" ]
      | `Zstd -> [ arg "--zstd" ]
    in
    let flag_args =
      arg action_flag :: compression_flags @ [ arg "-f"; arg archive ]
    in
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Tar, flag_args @ List.map arg paths) ]
  | Shell_ir_typed.W (Make { target; jobs }) ->
    let flag_args = match jobs with None -> [] | Some j -> [ arg "-j"; arg (string_of_int j) ] in
    let target_args = match target with None -> [] | Some t -> [ arg t ] in
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Make, flag_args @ target_args) ]
  | Shell_ir_typed.W (Diff { file1; file2; unified }) ->
    let flag_args = if unified then [ arg "-u" ] else [] in
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Diff, flag_args @ [ arg file1; arg file2 ]) ]
  | Shell_ir_typed.W (Sed { expression; file; in_place }) ->
    let flag_args = if in_place then [ arg "-i" ] else [] in
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Sed, flag_args @ [ arg "-e"; arg expression; arg file ]) ]
  | Shell_ir_typed.W (Rsync { source; dest; flags }) ->
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Rsync, List.map arg flags @ [ arg source; arg dest ]) ]
  | Shell_ir_typed.W (Node { script; args; inline }) ->
    let entry = match inline with Some code -> [ arg "-e"; arg code ] | None -> [ arg script ] in
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Node, entry @ List.map arg args) ]
  | Shell_ir_typed.W (Python { script; args; inline }) ->
    let entry = match inline with Some code -> [ arg "-c"; arg code ] | None -> [ arg script ] in
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Python, entry @ List.map arg args) ]
  | Shell_ir_typed.W (Python3 { script; args; inline }) ->
    let entry = match inline with Some code -> [ arg "-c"; arg code ] | None -> [ arg script ] in
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Python3, entry @ List.map arg args) ]
  | Shell_ir_typed.W (Pip { subcommand; packages }) ->
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Pip, arg subcommand :: List.map arg packages) ]
  | Shell_ir_typed.W (Patch { file; patchfile; strip; reverse }) ->
    let flag_args =
      (if reverse then [ arg "-R" ] else [])
      @ (match patchfile with None -> [] | Some p -> [ arg "-i"; arg p ])
      @ [ arg "-p"; arg (string_of_int strip) ]
    in
    let file_args = match file with None -> [] | Some f -> [ arg f ] in
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Patch, flag_args @ file_args) ]
  | Shell_ir_typed.W (Npm { subcommand; args }) ->
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Npm, arg subcommand :: List.map arg args) ]
  | Shell_ir_typed.W (Cargo { subcommand; args }) ->
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Cargo, arg subcommand :: List.map arg args) ]
  | Shell_ir_typed.W (Go { subcommand; args }) ->
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Go, arg subcommand :: List.map arg args) ]
  | Shell_ir_typed.W (Gh { subcommand; args }) ->
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Gh, arg subcommand :: List.map arg args) ]
  | Shell_ir_typed.W (Chmod { mode; path; recursive }) ->
    let flag_args = if recursive then [ arg "-R" ] else [] in
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Chmod, flag_args @ [ arg mode; arg path ]) ]
  | Shell_ir_typed.W (Chown { owner; path; recursive }) ->
    let flag_args = if recursive then [ arg "-R" ] else [] in
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Chown, flag_args @ [ arg owner; arg path ]) ]
  | Shell_ir_typed.W (Docker { subcommand; args }) ->
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Docker, arg subcommand :: List.map arg args) ]
  | Shell_ir_typed.W (Opam { subcommand; args }) ->
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Opam, arg subcommand :: List.map arg args) ]
  | Shell_ir_typed.W (Npx { subcommand; args }) ->
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Npx, arg subcommand :: List.map arg args) ]
  | Shell_ir_typed.W (Yarn { subcommand; args }) ->
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Yarn, arg subcommand :: List.map arg args) ]
  | Shell_ir_typed.W (Pnpm { subcommand; args }) ->
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Pnpm, arg subcommand :: List.map arg args) ]
  | Shell_ir_typed.W (Uv { subcommand; args }) ->
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Uv, arg subcommand :: List.map arg args) ]
  | Shell_ir_typed.W (Glab { subcommand; args }) ->
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Glab, arg subcommand :: List.map arg args) ]
  | Shell_ir_typed.W (Pytest { subcommand; args }) ->
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Pytest, arg subcommand :: List.map arg args) ]
  | Shell_ir_typed.W (Terminal_notifier { title; message }) ->
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Terminal_notifier, [ arg title; arg message ]) ]
  | Shell_ir_typed.W (Ruff { subcommand; args }) ->
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Ruff, arg subcommand :: List.map arg args) ]
  | Shell_ir_typed.W (Pyright { subcommand; args }) ->
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Pyright, arg subcommand :: List.map arg args) ]
  | Shell_ir_typed.W (Tsc { subcommand; args }) ->
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Tsc, arg subcommand :: List.map arg args) ]
  | Shell_ir_typed.W (Ocamlfind { subcommand; args }) ->
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Ocamlfind, arg subcommand :: List.map arg args) ]
  | Shell_ir_typed.W (Rustc { subcommand; args }) ->
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Rustc, arg subcommand :: List.map arg args) ]
  | Shell_ir_typed.W (Gofmt { subcommand; args }) ->
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Gofmt, arg subcommand :: List.map arg args) ]
  | Shell_ir_typed.W (Gradle { subcommand; args }) ->
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Gradle, arg subcommand :: List.map arg args) ]
  | Shell_ir_typed.W (Ninja { subcommand; args }) ->
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Ninja, arg subcommand :: List.map arg args) ]
  | Shell_ir_typed.W (Java { subcommand; args }) ->
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Java, arg subcommand :: List.map arg args) ]
  | Shell_ir_typed.W (Javac { subcommand; args }) ->
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Javac, arg subcommand :: List.map arg args) ]
  | Shell_ir_typed.W (Mvn { subcommand; args }) ->
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Mvn, arg subcommand :: List.map arg args) ]
  | Shell_ir_typed.W (Cmake { subcommand; args }) ->
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Cmake, arg subcommand :: List.map arg args) ]
  | Shell_ir_typed.W (Dune_local_sh { subcommand; args }) ->
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Dune_local_sh, arg subcommand :: List.map arg args) ]
  | Shell_ir_typed.W (Osascript { subcommand; args }) ->
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Osascript, arg subcommand :: List.map arg args) ]
  | Shell_ir_typed.W (Play { subcommand; args }) ->
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Play, arg subcommand :: List.map arg args) ]
  | Shell_ir_typed.W (Rec { subcommand; args }) ->
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Rec, arg subcommand :: List.map arg args) ]
  | Shell_ir_typed.W (Ffplay { subcommand; args }) ->
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Ffplay, arg subcommand :: List.map arg args) ]
  | Shell_ir_typed.W (Mpg123 { subcommand; args }) ->
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Mpg123, arg subcommand :: List.map arg args) ]
  | Shell_ir_typed.W (Open { subcommand; args }) ->
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Open, arg subcommand :: List.map arg args) ]
  | Shell_ir_typed.W (Su { subcommand; args }) ->
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Su, arg subcommand :: List.map arg args) ]
  | Shell_ir_typed.W (Dd { subcommand; args }) ->
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Dd, arg subcommand :: List.map arg args) ]
  | Shell_ir_typed.W (Mkfs { subcommand; args }) ->
    [ Capability.Exec_program (Exec_program.of_known Exec_program.Mkfs, arg subcommand :: List.map arg args) ]
  | Shell_ir_typed.W (Generic s) -> Capability_check.of_simple s
;;
