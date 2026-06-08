(** Exec_effect — Effect axis types for Shell IR execution.

    P1 of the Shell IR Effect Proof Design (RFC-0208 extension).
    Fine-grained per-constructor decomposition on top of P0.

    Note: [effect] is a reserved keyword in OCaml 5, so the primary
    type is named [t] and the collection is [set]. *)

(* --------------------------------------------------------------------------- *)
(** {1 Effect types} *)

type effect_kind =
  | Fs_read
  | Fs_write
  | Fs_delete
  | Process_spawn
  | Shell_interpreter
  | Net_egress
  | Credential_use
  | External_mutation

let string_of_effect_kind = function
  | Fs_read -> "Fs_read"
  | Fs_write -> "Fs_write"
  | Fs_delete -> "Fs_delete"
  | Process_spawn -> "Process_spawn"
  | Shell_interpreter -> "Shell_interpreter"
  | Net_egress -> "Net_egress"
  | Credential_use -> "Credential_use"
  | External_mutation -> "External_mutation"
;;

let pp_effect_kind fmt k = Format.pp_print_string fmt (string_of_effect_kind k)

let compare_effect_kind a b =
  String.compare (string_of_effect_kind a) (string_of_effect_kind b)
;;

type t =
  { kind : effect_kind
  ; scope : string list
  ; source : string
  }

type set = t list

let pp fmt e =
  Format.fprintf
    fmt
    "{ kind = %a; scope = [%a]; source = %S }"
    pp_effect_kind
    e.kind
    (Format.pp_print_list
       ~pp_sep:(fun fmt () -> Format.fprintf fmt "; ")
       Format.pp_print_string)
    e.scope
    e.source
;;

let pp_set fmt es =
  Format.fprintf
    fmt
    "[%a]"
    (Format.pp_print_list ~pp_sep:(fun fmt () -> Format.fprintf fmt ";@ ") pp)
    es
;;

(* --------------------------------------------------------------------------- *)
(** {1 Effect-level risk mapping} *)

let effect_kind_floor = function
  | Fs_read -> Shell_ir_risk.R0_Read
  | Fs_write -> Shell_ir_risk.R1_Reversible_mutation
  | Fs_delete -> Shell_ir_risk.R2_Irreversible
  | Process_spawn -> Shell_ir_risk.R1_Reversible_mutation
  | Shell_interpreter -> Shell_ir_risk.Destructive_protected
  | Net_egress -> Shell_ir_risk.R1_Reversible_mutation
  | Credential_use -> Shell_ir_risk.R1_Reversible_mutation
  | External_mutation -> Shell_ir_risk.R1_Reversible_mutation
;;

(* --------------------------------------------------------------------------- *)
(** {1 Projection (legacy compatibility)} *)

let project_risk (effects : set) : Shell_ir_risk.risk_class =
  let max_risk a b =
    let rank = function
      | Shell_ir_risk.R0_Read -> 0
      | Shell_ir_risk.R1_Reversible_mutation -> 1
      | Shell_ir_risk.R2_Irreversible -> 2
      | Shell_ir_risk.Destructive_protected -> 3
    in
    if rank a >= rank b then a else b
  in
  List.fold_left
    (fun acc e -> max_risk acc (effect_kind_floor e.kind))
    Shell_ir_risk.R0_Read
    effects
;;

(* --------------------------------------------------------------------------- *)
(** {1 P1 helpers — word-list decomposition} *)

let words_of_simple (s : Shell_ir.simple) : string list option =
  let rec collect acc = function
    | [] -> Some (List.rev acc)
    | Shell_ir.Lit (a, _) :: rest -> collect (a :: acc) rest
    | Shell_ir.Concat _ :: _ | Shell_ir.Var _ :: _ -> None
  in
  match collect [] s.args with
  | None -> None
  | Some args -> Some (Exec_program.to_string s.bin :: args)
;;

let is_protected_branch_target arg =
  let target = String.lowercase_ascii arg in
  List.mem
    target
    [ "main"
    ; "master"
    ; "origin/main"
    ; "origin/master"
    ; "refs/heads/main"
    ; "refs/heads/master"
    ]
  || List.exists
       (fun suffix -> String.ends_with ~suffix target)
       [ ":main"
       ; ":master"
       ; ":origin/main"
       ; ":origin/master"
       ; ":refs/heads/main"
       ; ":refs/heads/master"
       ]
;;

let has_flag flags args =
  List.exists (fun f -> List.exists (String.equal f) args) flags
;;

(** Word-list effect extraction.
    Uses [Shell_ir_risk.classify_words] as the safety floor, then maps
    common command families to their intuitive effect kinds so the
    decomposition is more informative than a single generic R1/R2 tag. *)
let extract_words (s : Shell_ir.simple) : set =
  match words_of_simple s with
  | None -> []
  | Some words ->
    let risk = Shell_ir_risk.classify_words words in
    if risk = Shell_ir_risk.R0_Read
    then []
    else
      let kind =
        match words with
        | "curl" :: _ | "wget" :: _ | "ssh" :: _ | "scp" :: _ | "rsync" :: _ ->
          Net_egress
        | "gh" :: _ -> Credential_use
        | ("sh" | "bash" | "zsh" | "fish" | "ksh" | "dash" | "csh" | "tcsh" | "ash")
          :: _ -> Shell_interpreter
        | ("node" | "npx" | "pip" | "python" | "python3") :: _ ->
          Shell_interpreter
        | "rm" :: rest | "rmdir" :: rest ->
          let opts =
            List.filter (fun a -> String.length a > 0 && a.[0] = '-') rest
          in
          let recursive = has_flag [ "-r"; "-R"; "--recursive" ] opts in
          let force = has_flag [ "-f"; "--force" ] opts in
          if recursive && force then Shell_interpreter else Fs_delete
        | "git" :: "push" :: rest ->
          let forced =
            has_flag [ "--force"; "-f" ] rest
            || List.exists (String.starts_with ~prefix:"--force-with-lease") rest
          in
          let protected = List.exists is_protected_branch_target rest in
          if forced && protected then Shell_interpreter else Fs_write
        | "git" :: "reset" :: _ -> Fs_delete
        | "git" :: "clean" :: rest ->
          let dry_run = has_flag [ "-n"; "--dry-run" ] rest in
          if dry_run then Fs_read else Fs_delete
        | _ ->
          (match risk with
           | Shell_ir_risk.R1_Reversible_mutation -> Fs_write
           | Shell_ir_risk.R2_Irreversible -> Fs_delete
           | Shell_ir_risk.Destructive_protected -> Shell_interpreter
           | Shell_ir_risk.R0_Read -> Fs_read)
      in
      [ { kind; scope = []; source = "word_list" } ]
;;

(* --------------------------------------------------------------------------- *)
(** {1 P1 helpers — redirect decomposition} *)

let extract_redirects (redirects : Redirect_scope.t list) : set =
  List.filter_map
    (function
      | Redirect_scope.File { mode = Redirect_scope.Write; target; _ } ->
        Some
          { kind = Fs_write
          ; scope = [ Path_scope.raw target ]
          ; source = "redirect:write"
          }
      | Redirect_scope.File { mode = Redirect_scope.Append; target; _ } ->
        Some
          { kind = Fs_write
          ; scope = [ Path_scope.raw target ]
          ; source = "redirect:append"
          }
      | Redirect_scope.File { mode = Redirect_scope.Read; _ } -> None
      | Redirect_scope.Fd_to_fd _ -> None)
    redirects
;;

(* --------------------------------------------------------------------------- *)
(** {1 P1 helpers — typed GADT decomposition} *)

let npm_write_subcommands =
  [ "add"
  ; "install"
  ; "link"
  ; "prune"
  ; "publish"
  ; "remove"
  ; "unlink"
  ; "update"
  ; "up"
  ]
;;

let extract_typed (w : Shell_ir_typed.wrapped) : set =
  let paths = Shell_ir_typed.path_args w in
  let scope = paths in
  let open Shell_ir_typed in
  match w with
  (* --- read / inspection: R0_Read ----------------------------------- *)
  | W (Ls _)
  | W (Cat _)
  | W (Rg _)
  | W (Find _)
  | W (Head _)
  | W (Tail _)
  | W (Grep _)
  | W (Wc _)
  | W (Pwd _)
  | W (Echo _)
  | W (Which _)
  | W (Sort _)
  | W (Cut _)
  | W (Tr _)
  | W (Date _)
  | W (Env _)
  | W (Printenv _)
  | W (Uniq _)
  | W (Basename _)
  | W (Dirname _)
  | W (Test _)
  | W (Stat _)
  | W (Hostname _)
  | W (Whoami _)
  | W (Du _)
  | W (Df _)
  | W (File _)
  | W (Printf _)
  | W (Uname _)
  | W (Ps _)
  | W (Tty _)
  | W (Diff _)
  | W (Git_status _)
  | W (Git_diff _)
  | W (Git_log _)
  | W (Git_pull _)
  | W (Git_stash _)
  | W (Git_rebase _)
  | W (Git_merge _)
  | W (Git_branch _)
  | W (Git_fetch _)
  | W (Git_show _)
  | W (Git_blame _)
  | W (Git_add _)
  | W (Tar _)
  | W (Patch _)
  | W (Cargo _)
  | W (Go _)
  | W (Glab _)
  | W (Uv _)
  | W (Pytest _)
  | W (Terminal_notifier _)
  | W (Ruff _)
  | W (Pyright _)
  | W (Tsc _)
  | W (Ocamlfind _)
  | W (Rustc _)
  | W (Gofmt _)
  | W (Gradle _)
  | W (Ninja _)
  | W (Java _)
  | W (Javac _)
  | W (Mvn _)
  | W (Cmake _)
  | W (Dune_local_sh _)
  | W (Osascript _)
  | W (Play _)
  | W (Rec _)
  | W (Ffplay _)
  | W (Mpg123 _)
  | W (Open _)
  | W (Awk _) ->
    [ { kind = Fs_read; scope; source = "typed:read" } ]
  (* --- reversible mutation: R1 -------------------------------------- *)
  | W (Mkdir _)
  | W (Chmod _)
  | W (Chown _)
  | W (Make _)
  | W (Git_clone _)
  | W (Git_commit _)
  | W (Git_checkout _)
  | W (Cp _)
  | W (Mv _)
  | W (Ln _)
  | W (Touch _)
  | W (Tee _) ->
    [ { kind = Fs_write; scope; source = "typed:write" } ]
  | W (Sed { in_place; _ }) ->
    if in_place
    then [ { kind = Fs_write; scope; source = "typed:sed" } ]
    else [ { kind = Fs_read; scope; source = "typed:sed" } ]
  | W (Npm { subcommand; _ }) ->
    if List.mem subcommand npm_write_subcommands
    then [ { kind = Fs_write; scope; source = "typed:npm" } ]
    else [ { kind = Fs_read; scope; source = "typed:npm" } ]
  | W (Yarn { subcommand; _ }) ->
    if List.mem subcommand npm_write_subcommands
    then [ { kind = Fs_write; scope; source = "typed:yarn" } ]
    else [ { kind = Fs_read; scope; source = "typed:yarn" } ]
  | W (Pnpm { subcommand; _ }) ->
    if List.mem subcommand npm_write_subcommands
    then [ { kind = Fs_write; scope; source = "typed:pnpm" } ]
    else [ { kind = Fs_read; scope; source = "typed:pnpm" } ]
  | W (Opam { subcommand; _ }) ->
    if String.equal subcommand "exec"
    then [ { kind = Shell_interpreter; scope; source = "typed:opam" } ]
    else [ { kind = Fs_read; scope; source = "typed:opam" } ]
  | W (Git_push { force; force_with_lease; branch; _ }) ->
    let forced = force || force_with_lease in
    let protected_target =
      match branch with
      | Some b -> is_protected_branch_target b
      | None -> false
    in
    if forced && protected_target
    then [ { kind = Shell_interpreter; scope; source = "typed:git_push_destructive" } ]
    else [ { kind = Fs_write; scope; source = "typed:git_push" } ]
  (* --- irreversible: R2 --------------------------------------------- *)
  | W (Rm { paths = rm_paths; recursive; force }) ->
    if recursive && force
    then [ { kind = Shell_interpreter; scope = rm_paths; source = "typed:rm_destructive" } ]
    else [ { kind = Fs_delete; scope = rm_paths; source = "typed:rm" } ]
  | W (Su _) | W (Dd _) | W (Mkfs _) | W (Xargs _) | W (Git_reset _) ->
    [ { kind = Fs_delete; scope; source = "typed:delete" } ]
  (* --- network ------------------------------------------------------ *)
  | W (Curl _) | W (Wget _) | W (Ssh _) | W (Scp _) | W (Rsync _) ->
    [ { kind = Net_egress; scope; source = "typed:net" } ]
  (* --- interpreters / scripting ------------------------------------- *)
  | W (Node _) | W (Python _) | W (Python3 _) | W (Pip _) | W (Npx _) | W (Sudo _) ->
    [ { kind = Shell_interpreter; scope; source = "typed:interpreter" } ]
  (* --- credential-bearing (risk is word-list floor owned) ----------- *)
  | W (Gh _) -> [ { kind = Fs_read; scope; source = "typed:gh" } ]
  (* --- docker (read-only audit) ------------------------------------- *)
  | W (Docker _) -> [ { kind = Fs_read; scope; source = "typed:docker" } ]
  (* --- escape hatch ------------------------------------------------- *)
  | W (Generic _) -> []
;;

(* --------------------------------------------------------------------------- *)
(** {1 Extraction} *)

let dedup (effects : set) : set =
  let seen = Hashtbl.create 16 in
  List.filter
    (fun e ->
       let key = e.kind, e.scope in
       if Hashtbl.mem seen key then false else (Hashtbl.add seen key true; true))
    effects
;;

let extract_simple (s : Shell_ir.simple) : set =
  let typed = Shell_ir_typed.of_simple s in
  let typed_effects = extract_typed typed in
  let redirect_effects = extract_redirects s.redirects in
  let word_effects = extract_words s in
  dedup (typed_effects @ redirect_effects @ word_effects)
;;

let rec extract (ir : Shell_ir.t) : set =
  match ir with
  | Shell_ir.Simple s -> extract_simple s
  | Shell_ir.Pipeline stages ->
    List.concat_map extract stages |> dedup
;;