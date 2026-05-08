(** Capability_check_typed — GADT-based capability derivation.

    Each arm reconstructs the [Shell_ir.arg list] that the untyped walker
    would have produced, then wraps it in [Capability.Exec_bin].  This
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

let arg s = Shell_ir.Lit s

let args_of_flags flags =
  List.map (function
    | `Long -> arg "-l"
    | `All -> arg "-a"
    | `Human -> arg "-h") flags

let of_command = function
  | Shell_ir_typed.W (Ls { path; flags }) ->
    let args = args_of_flags flags @ (match path with None -> [] | Some p -> [arg p]) in
    [ Capability.Exec_bin (Bin.of_known Bin.Ls, args) ]
  | Shell_ir_typed.W (Cat { path }) ->
    [ Capability.Exec_bin (Bin.of_known Bin.Cat, [ arg path ]) ]
  | Shell_ir_typed.W (Rg { pattern; path; case_sensitive }) ->
    let args =
      (if case_sensitive then [] else [ arg "-i" ])
      @ [ arg pattern ]
      @
      match path with
      | None -> []
      | Some p -> [ arg p ]
    in
    [ Capability.Exec_bin (Bin.of_known Bin.Rg, args) ]
  | Shell_ir_typed.W (Git_status { short }) ->
    let args = arg "status" :: (if short then [ arg "-s" ] else []) in
    [ Capability.Exec_bin (Bin.of_known Bin.Git, args) ]
  | Shell_ir_typed.W (Git_clone { repo; branch; depth }) ->
    let args =
      (arg "clone"
       :: (if depth <> 1 then [ arg "--depth"; arg (string_of_int depth) ] else []))
      @ (match branch with
         | None -> []
         | Some b -> [ arg "-b"; arg b ])
      @ [ arg repo ]
    in
    [ Capability.Exec_bin (Bin.of_known Bin.Git, args) ]
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
    [ Capability.Exec_bin (Bin.of_known Bin.Curl, args) ]
  | Shell_ir_typed.W (Rm { paths; recursive; force }) ->
    let flag_args =
      (if recursive then [ arg "-r" ] else []) @ if force then [ arg "-f" ] else []
    in
    [ Capability.Exec_bin (Bin.of_known Bin.Rm, flag_args @ List.map arg paths) ]
  | Shell_ir_typed.W (Sudo { target_argv }) ->
    let args = List.map arg target_argv in
    [ Capability.Exec_bin (Bin.of_known Bin.Sudo, args) ]
  | Shell_ir_typed.W (Generic s) -> Capability_check.of_simple s
