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
       :: (if depth <> 1 then [ arg "--depth"; arg (string_of_int depth) ] else []))
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
    let flag =
      arg (match mode with `Lines -> "-l" | `Words -> "-w" | `Chars -> "-c")
    in
    let args = [ flag; arg path ] in
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
  | Shell_ir_typed.W (Generic s) -> Capability_check.of_simple s
;;
