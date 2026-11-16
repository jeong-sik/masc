(* Execute_script_paths — the closed destination vocabulary for the exec
   lane, and the one operand pass that carries it to the judge.

   Goal task-634 / issue #26289 (operator decision, ask938aaf519a5c543e):
   destination paths reached the process while the approval layer judged
   only the shell's own cwd field and redirects.  The operator picked:
   - read_superset — the READ authority widens to include the same
     objective roots the exec policy judges (implemented on the read
     side, Keeper_alerting_path); the write authority does not move;
   - amend_closed_keys — argv operands of a closed program-key table are
     judged by the same authority (this module's argv pass);
   - cd_promote — the script lane's cd targets are judged too (this
     module's script pass).  open-then-verify was NOT picked: referent
     verification (A3 symlink escape) stays out of scope and recorded.

   Every source converges on one Shell IR at the gate, so
   Exec_policy.validate_shell_ir_paths runs this pass on plain argv
   children, shell-costumed children and the script child alike: argv
   operands come from the closed table, script destinations from
   re-opening the [sh -c] / [bash -c] subscript with the repo's subset
   parser.

   Naming is intentionally partial and fails OPEN, not closed: an
   operand this table cannot cleanly name (a shell variable, a glob, a
   substitution, an unparseable subscript) is left to the box's
   existing authority exactly as it was before this module existed —
   this module only ever narrows what was previously never judged at
   all, it does not newly reject commands the gate already ran. Every
   destination it DOES name is judged by the caller's own whitelist
   function — the same one that already judges cwd and redirects — so
   there is exactly one judge and one set of error messages, never a
   second containment rule invented here. *)

let name = "Execute_script_paths"

type destination = { raw : string; is_cd : bool }
(* [is_cd]: a cd target must already exist as a directory (the same
   Cwd_not_directory parity a plain argv [cd] gets); write operands may
   name not-yet-existing destinations (mkdir). *)

type named =
  | Destinations of destination list
  | Outside_vocabulary  (* the box keeps judging this text *)

let bin_name (bin : Masc_exec.Exec_program.t) : string =
  Masc_exec.Exec_program.to_string bin
;;

let bin_base (bin : Masc_exec.Exec_program.t) : string =
  Filename.basename (bin_name bin)
;;

let is_cd_stage (stage : Masc_exec.Shell_ir.simple) : bool =
  String.equal (bin_base stage.bin) "cd"
;;

let rec cd_operands = function
  | [] -> Ok []
  | arg :: rest ->
    (match classify_arg arg with
     | `Lit "--" -> Ok rest
     | `Lit opt
       when String.length opt >= 2
            && opt.[0] = '-'
            && opt.[1] <> '-'
            && String.for_all (function '-' | 'L' | 'P' -> true | _ -> false) opt ->
       cd_operands rest
     | `Lit opt when looks_like_option opt -> Error ()
     | `Lit _ | `Glob_or_dynamic -> Ok (arg :: rest))
;;

let looks_like_option (s : string) : bool =
  String.length s >= 2 && String.unsafe_get s 0 = '-'
;;

let classify_arg = function
  | Masc_exec.Shell_ir.Lit (s, meta) ->
    if meta.glob then `Glob_or_dynamic else `Lit s
  | Masc_exec.Shell_ir.Var _
  | Masc_exec.Shell_ir.Concat _
  | Masc_exec.Shell_ir.Subst _ -> `Glob_or_dynamic
;;

let value_after_eq ~prefix (s : string) : string option =
  if String.starts_with ~prefix s
  then (
    let plen = String.length prefix in
    Some (String.sub s plen (String.length s - plen)))
  else None
;;

(* ------------------------------------------------------------------ *)
(* Closed program-key table (operator: amend_closed_keys).             *)
(* ------------------------------------------------------------------ *)

let git_standalone_globals =
  [ "--no-pager"
  ; "-p"
  ; "-P"
  ; "--paginate"
  ; "--no-replace-objects"
  ; "--bare"
  ; "--no-optional-locks"
  ; "--literal-pathspecs"
  ; "--glob-pathspecs"
  ; "--noglob-pathspecs"
  ; "--icase-pathspecs"
  ; "--no-lazy-fetch"
  ; "--no-advice"
  ]
;;

let git_value_globals_non_path =
  [ "-c"; "--config-env"; "--namespace"; "--exec-path"; "--super-prefix" ]
;;

let git_attached_globals_non_path =
  [ "--config-env="; "--namespace="; "--exec-path="; "--super-prefix=" ]
;;

let git_worktree_subcommand_destinations ~is_add (args : Masc_exec.Shell_ir.arg list)
    (acc : destination list)
  : named
  =
  let rec scan ~after_double_dash = function
    | [] -> Destinations (List.rev acc)
    | arg :: tail ->
      (match classify_arg arg with
       | `Glob_or_dynamic -> Outside_vocabulary
       | `Lit "--" when not after_double_dash -> scan ~after_double_dash:true tail
       | `Lit s when (not after_double_dash) && looks_like_option s ->
         if is_add
            && (String.equal s "-b"
                || String.equal s "-B"
                || String.equal s "--reason")
         then (
           match tail with
           | [] -> Outside_vocabulary
           | _branch_or_reason :: rest -> scan ~after_double_dash rest)
         else scan ~after_double_dash tail
       | `Lit target ->
         (* [git worktree add <path> <commit-ish>] and [git worktree remove <path>]
            each name one filesystem path; any trailing positional argument on
            [add] is a commit-ish ref, not a destination. *)
         Destinations (List.rev ({ raw = target; is_cd = false } :: acc)))
  in
  scan ~after_double_dash:false args
;;

let git_stage_destinations (args : Masc_exec.Shell_ir.arg list) : named =
  let rec scan_globals acc = function
    | [] -> Destinations (List.rev acc)
    | hd :: tl ->
      (match classify_arg hd with
       | `Glob_or_dynamic -> Outside_vocabulary
       | `Lit "--" -> inspect_subcommand acc tl
       | `Lit flag when String.equal flag "-C"
                     || String.equal flag "--git-dir"
                     || String.equal flag "--work-tree" ->
         (match tl with
          | [] -> Destinations (List.rev acc)
          | next :: rest ->
            (match classify_arg next with
             | `Glob_or_dynamic -> Outside_vocabulary
             | `Lit target ->
               if looks_like_option target
               then Outside_vocabulary
               else scan_globals ({ raw = target; is_cd = false } :: acc) rest))
       | `Lit flag when String.starts_with ~prefix:"-C" flag && String.length flag > 2 ->
         let target = String.sub flag 2 (String.length flag - 2) in
         scan_globals ({ raw = target; is_cd = false } :: acc) tl
       | `Lit flag ->
         (match
            match value_after_eq ~prefix:"--git-dir=" flag with
            | Some _ as hit -> hit
            | None -> value_after_eq ~prefix:"--work-tree=" flag
          with
          | Some target ->
            if String.equal target ""
            then Outside_vocabulary
            else scan_globals ({ raw = target; is_cd = false } :: acc) tl
          | None ->
            if List.mem flag git_value_globals_non_path
            then (
              match tl with
              | [] -> Destinations (List.rev acc)
              | _val :: rest -> scan_globals acc rest)
            else if
              List.exists
                (fun prefix -> String.starts_with ~prefix flag)
                git_attached_globals_non_path
              || List.mem flag git_standalone_globals
            then scan_globals acc tl
            else if looks_like_option flag
            then Outside_vocabulary
            else inspect_subcommand acc (hd :: tl)))
  and inspect_subcommand acc = function
    | sub1 :: sub2 :: rest ->
      (match classify_arg sub1, classify_arg sub2 with
       | `Lit "worktree", `Lit "add" ->
         git_worktree_subcommand_destinations ~is_add:true rest acc
       | `Lit "worktree", `Lit "remove" ->
         git_worktree_subcommand_destinations ~is_add:false rest acc
       | `Lit "worktree", `Glob_or_dynamic -> Outside_vocabulary
       | (`Lit _ | `Glob_or_dynamic), (`Lit _ | `Glob_or_dynamic) ->
         Destinations (List.rev acc))
    | [] | [ _ ] -> Destinations (List.rev acc)
  in
  scan_globals [] args
;;

let file_cmd_destinations ~is_mkdir ~allow_short_t
    (args : Masc_exec.Shell_ir.arg list)
  : named
  =
  let rec collect ~after_double_dash acc = function
    | [] -> Destinations (List.rev acc)
    | arg :: tail ->
      (match classify_arg arg with
       | `Glob_or_dynamic -> Outside_vocabulary
       | `Lit "--" when not after_double_dash -> collect ~after_double_dash:true acc tail
       | `Lit s when (not after_double_dash) && looks_like_option s ->
         (match
            match value_after_eq ~prefix:"--target-directory=" s with
            | Some _ as hit -> hit
            | None -> value_after_eq ~prefix:"--output=" s
          with
          | Some target ->
            if String.equal target ""
            then Outside_vocabulary
            else collect ~after_double_dash ({ raw = target; is_cd = false } :: acc) tail
          | None ->
            if String.equal s "--target-directory"
               || String.equal s "--output"
               || (allow_short_t && String.equal s "-t")
            then (
              match tail with
              | [] -> Outside_vocabulary
              | next :: rest ->
                (match classify_arg next with
                 | `Glob_or_dynamic -> Outside_vocabulary
                 | `Lit target ->
                   collect ~after_double_dash ({ raw = target; is_cd = false } :: acc) rest))
            else if allow_short_t && String.starts_with ~prefix:"-t" s && String.length s > 2
            then (
              let target = String.sub s 2 (String.length s - 2) in
              collect ~after_double_dash ({ raw = target; is_cd = false } :: acc) tail)
            else if is_mkdir && (String.equal s "-m" || String.equal s "--mode")
            then (
              match tail with
              | [] -> Outside_vocabulary
              | next :: rest ->
                (match classify_arg next with
                 | `Glob_or_dynamic -> Outside_vocabulary
                 | `Lit _mode -> collect ~after_double_dash acc rest))
            else collect ~after_double_dash acc tail)
       | `Lit s -> collect ~after_double_dash ({ raw = s; is_cd = false } :: acc) tail)
  in
  collect ~after_double_dash:false [] args
;;

let stage_extra_destinations (stage : Masc_exec.Shell_ir.simple) : destination list =
  let cwd_dest =
    match stage.cwd with
    | None -> []
    | Some scope -> [ { raw = Masc_exec.Path_scope.raw scope; is_cd = true } ]
  in
  let redirect_dests =
    List.filter_map
      (function
        | Masc_exec.Redirect_scope.File { target; _ } ->
          let scope = Masc_exec.Redirect_scope.target_as_written target in
          let raw = Masc_exec.Path_scope.raw scope in
          if Masc_exec.Path_scope.is_discard_sink scope || String.equal raw "/dev/null"
          then None
          else Some { raw; is_cd = false }
        | Masc_exec.Redirect_scope.Fd_to_fd _ | Masc_exec.Redirect_scope.Literal _ -> None)
      stage.redirects
  in
  cwd_dest @ redirect_dests
;;

(* One stage's argv destinations under the closed table.  Non-literal
   operands and glob operands leave the destination set incomplete —
   refused for judging, never partially named. *)
let argv_stage_destinations (stage : Masc_exec.Shell_ir.simple) : named =
  if is_cd_stage stage then
    match cd_operands stage.args with
    | Ok [ arg ] ->
      (match classify_arg arg with
       | `Lit dest ->
         if looks_like_option dest then Outside_vocabulary
         else Destinations [ { raw = dest; is_cd = true } ]
       | `Glob_or_dynamic -> Outside_vocabulary)
    | Ok ([] | _ :: _ :: _) | Error () -> Outside_vocabulary
  else (
    match bin_base stage.bin with
    | "git" -> git_stage_destinations stage.args
    | "mkdir" -> file_cmd_destinations ~is_mkdir:true ~allow_short_t:false stage.args
    | "rm" -> file_cmd_destinations ~is_mkdir:false ~allow_short_t:false stage.args
    | "cp" | "mv" -> file_cmd_destinations ~is_mkdir:false ~allow_short_t:true stage.args
    | _ -> Destinations [])
;;

let literal_file_cmd_destinations ~is_mkdir ~allow_short_t
    (args : Masc_exec.Shell_ir.arg list)
  : destination list
  =
  let rec collect ~after_double_dash acc = function
    | [] -> List.rev acc
    | arg :: tail ->
      (match classify_arg arg with
       | `Glob_or_dynamic -> collect ~after_double_dash acc tail
       | `Lit "--" when not after_double_dash -> collect ~after_double_dash:true acc tail
       | `Lit s when (not after_double_dash) && looks_like_option s ->
         (match
            match value_after_eq ~prefix:"--target-directory=" s with
            | Some _ as hit -> hit
            | None -> value_after_eq ~prefix:"--output=" s
          with
          | Some target when not (String.equal target "") ->
            collect ~after_double_dash ({ raw = target; is_cd = false } :: acc) tail
          | Some _ -> collect ~after_double_dash acc tail
          | None ->
            if String.equal s "--target-directory"
               || String.equal s "--output"
               || (allow_short_t && String.equal s "-t")
            then (
              match tail with
              | [] -> List.rev acc
              | next :: rest ->
                (match classify_arg next with
                 | `Lit target when not (looks_like_option target) ->
                   collect ~after_double_dash ({ raw = target; is_cd = false } :: acc) rest
                 | `Lit _ | `Glob_or_dynamic -> collect ~after_double_dash acc rest))
            else if allow_short_t && String.starts_with ~prefix:"-t" s && String.length s > 2
            then
              collect
                ~after_double_dash
                ({ raw = String.sub s 2 (String.length s - 2); is_cd = false } :: acc)
                tail
            else if is_mkdir && (String.equal s "-m" || String.equal s "--mode")
            then (
              match tail with
              | [] -> List.rev acc
              | _ :: rest -> collect ~after_double_dash acc rest)
            else collect ~after_double_dash acc tail)
       | `Lit s -> collect ~after_double_dash ({ raw = s; is_cd = false } :: acc) tail)
  in
  collect ~after_double_dash:false [] args
;;

let literal_git_destinations (args : Masc_exec.Shell_ir.arg list) : destination list =
  let rec scan acc = function
    | [] -> List.rev acc
    | hd :: tl ->
      (match classify_arg hd with
       | `Glob_or_dynamic -> scan acc tl
       | `Lit flag
         when String.equal flag "-C"
              || String.equal flag "--git-dir"
              || String.equal flag "--work-tree" ->
         (match tl with
          | [] -> List.rev acc
          | next :: rest ->
            (match classify_arg next with
             | `Lit target when not (looks_like_option target) ->
               scan ({ raw = target; is_cd = false } :: acc) rest
             | `Lit _ | `Glob_or_dynamic -> scan acc rest))
       | `Lit flag when String.starts_with ~prefix:"-C" flag && String.length flag > 2 ->
         scan ({ raw = String.sub flag 2 (String.length flag - 2); is_cd = false } :: acc) tl
       | `Lit flag ->
         (match
            match value_after_eq ~prefix:"--git-dir=" flag with
            | Some _ as hit -> hit
            | None -> value_after_eq ~prefix:"--work-tree=" flag
          with
          | Some target when not (String.equal target "") ->
            scan ({ raw = target; is_cd = false } :: acc) tl
          | Some _ | None ->
            if List.mem flag git_value_globals_non_path
            then (
              match tl with
              | [] -> List.rev acc
              | _ :: rest -> scan acc rest)
            else scan acc tl))
  in
  scan [] args
;;

let literal_stage_destinations (stage : Masc_exec.Shell_ir.simple) : destination list =
  if is_cd_stage stage
  then (
    match cd_operands stage.args with
    | Ok args ->
      List.filter_map
        (fun arg ->
           match classify_arg arg with
           | `Lit dest when not (looks_like_option dest) ->
             Some { raw = dest; is_cd = true }
           | `Lit _ | `Glob_or_dynamic -> None)
        args
    | Error () -> [])
  else (
    match bin_base stage.bin with
    | "git" -> literal_git_destinations stage.args
    | "mkdir" -> literal_file_cmd_destinations ~is_mkdir:true ~allow_short_t:false stage.args
    | "rm" | "chmod" | "touch" | "truncate" ->
      literal_file_cmd_destinations ~is_mkdir:false ~allow_short_t:false stage.args
    | "cp" | "mv" | "ln" ->
      literal_file_cmd_destinations ~is_mkdir:false ~allow_short_t:true stage.args
    | _ -> [])
;;

(* ------------------------------------------------------------------ *)
(* Script pass (operator: cd_promote): re-open the [sh -c] subscript.  *)
(* ------------------------------------------------------------------ *)

let is_sh_short_cluster (s : string) : bool =
  String.length s >= 2
  && (s.[0] = '-' || s.[0] = '+')
  && s.[1] <> s.[0]
  && String.for_all
       (function
         | '-' | '+' | 'c' | 'e' | 'u' | 'x' | 'l' | 'i' | 's' | 'f' | 'v' | 'a' | 'o' -> true
         | _ -> false)
       s
;;

let sh_cluster_has ch (s : string) : bool =
  let n = String.length s in
  let rec loop i = i < n && (s.[i] = ch || loop (i + 1)) in
  loop 1
;;

let is_shell_long_standalone_flag = function
  | "--login" | "--norc" | "--noprofile" | "--posix" -> true
  | _ -> false
;;

let sh_script_of_stage (stage : Masc_exec.Shell_ir.simple) : string option =
  match bin_base stage.bin with
  | "sh" | "bash" | "dash" | "zsh" ->
    let rec scan = function
      | [] -> None
      | flag_arg :: rest ->
        (match classify_arg flag_arg with
         | `Glob_or_dynamic -> None
         | `Lit "--" -> None
         | `Lit flag when is_sh_short_cluster flag && sh_cluster_has 'c' flag ->
           let after_o =
             if sh_cluster_has 'o' flag
             then (match rest with _opt :: tail -> tail | [] -> [])
             else rest
           in
           (match after_o with
            | script_arg :: _ ->
              (match classify_arg script_arg with
               | `Lit script -> Some script
               | `Glob_or_dynamic -> None)
            | [] -> None)
         | `Lit flag when is_sh_short_cluster flag && sh_cluster_has 'o' flag ->
           (match rest with
            | _opt :: tail -> scan tail
            | [] -> None)
         | `Lit flag when is_sh_short_cluster flag || is_shell_long_standalone_flag flag ->
           scan rest
         | `Lit _ -> None)
    in
    scan stage.args
  | _ -> None
;;

let max_nested_script_depth = 8

let script_destinations ~(limit : int) (script : string) : named =
  let rec parse_at_depth depth text =
    if depth > max_nested_script_depth
    then Outside_vocabulary
    else (
      match Masc_exec_bash_parser.Bash.parse_string text with
      | Masc_exec.Parsed.Parsed ir ->
        if Masc_exec.Shell_ir.has_variable_expansion ir
        then Outside_vocabulary
        else (
          let count_cd =
            let one s n = if is_cd_stage s then n + 1 else n in
            let rec go n = function
              | Masc_exec.Shell_ir.Simple s -> one s n
              | Masc_exec.Shell_ir.Pipeline stages -> List.fold_left go n stages
              | Masc_exec.Shell_ir.Sequence { head; tail } ->
                List.fold_left (fun acc (_, t) -> go acc t) (go n head) tail
            in
            go 0 ir
          in
          if count_cd > 1
          then Outside_vocabulary
          else (
            let combine a b =
              match a, b with
              | Outside_vocabulary, _ | _, Outside_vocabulary -> Outside_vocabulary
              | Destinations d1, Destinations d2 -> Destinations (d1 @ d2)
            in
            let rec ir_destinations (node : Masc_exec.Shell_ir.t) : named =
              match node with
              | Masc_exec.Shell_ir.Simple s ->
                let extras = Destinations (stage_extra_destinations s) in
                let subst_children =
                  List.concat_map
                    Masc_exec.Shell_ir.subst_children_of_arg
                    (s.Masc_exec.Shell_ir.args @ List.map snd s.Masc_exec.Shell_ir.env)
                in
                let subst_named = list_destinations subst_children in
                let stage_named =
                  match sh_script_of_stage s with
                  | Some nested -> parse_at_depth (depth + 1) nested
                  | None -> argv_stage_destinations s
                in
                combine extras (combine subst_named stage_named)
              | Masc_exec.Shell_ir.Pipeline stages -> list_destinations stages
              | Masc_exec.Shell_ir.Sequence { head; tail } ->
                combine (ir_destinations head) (list_destinations (List.map snd tail))
            and list_destinations = function
              | [] -> Destinations []
              | s :: rest -> combine (ir_destinations s) (list_destinations rest)
            in
            match ir_destinations ir with
            | Destinations ds when List.length ds <= limit -> Destinations ds
            | Destinations _ -> Outside_vocabulary
            | Outside_vocabulary -> Outside_vocabulary))
      | Masc_exec.Parsed.Too_complex _
      | Masc_exec.Parsed.Parse_error _
      | Masc_exec.Parsed.Parse_aborted _ -> Outside_vocabulary)
  in
  parse_at_depth 0 script
;;

(* ------------------------------------------------------------------ *)
(* The operand pass: one walk over the IR the gate already holds.      *)
(* The caller supplies the judge, so this module never invents a       *)
(* second whitelist, existence check or error message — it only names  *)
(* destinations for [Exec_policy.validate_shell_ir_paths]'s own        *)
(* [validate_path_value] to judge, the same function that already      *)
(* judges cwd and redirect targets.                                    *)
(* ------------------------------------------------------------------ *)

let judge_destinations
    ~(judge : requires_existing_dir:bool -> string -> (unit, string) result)
    (destinations : destination list)
  : (unit, string) result
  =
  let rec go = function
    | [] -> Ok ()
    | d :: rest -> (
      match judge ~requires_existing_dir:d.is_cd d.raw with
      | Ok () -> go rest
      | Error _ as err -> err)
  in
  go destinations
;;

(* Unnameable operands (a variable, a glob, a substitution, an
   unparseable subscript) fall through as [Ok ()]: the box already ran
   these unjudged before this module existed, and this pass only
   narrows that gap for what it CAN name — it does not newly reject a
   class of commands the gate has always allowed through. *)
let judge_named
    ~(judge : requires_existing_dir:bool -> string -> (unit, string) result)
    (named : named)
  : (unit, string) result
  =
  match named with
  | Outside_vocabulary -> Ok ()
  | Destinations destinations -> judge_destinations ~judge destinations
;;

let judge_operands
    ~(judge : requires_existing_dir:bool -> string -> (unit, string) result)
    ~limit:_
    (ir : Masc_exec.Shell_ir.t)
  : (unit, string) result
  =
  let resolve_against_cwd cwd_opt raw =
    match cwd_opt with
    | Some prev when Filename.is_relative raw -> Filename.concat prev raw
    | Some _ | None -> raw
  in
  let map_destinations ~effective_cwd ~mkdir_seen ds =
    List.map
      (fun d ->
        { raw = resolve_against_cwd !effective_cwd d.raw
        ; is_cd = d.is_cd && not !mkdir_seen
        })
      ds
  in
  let rec walk ~depth ~(effective_cwd : string option ref) ~(mkdir_seen : bool ref)
      (node : Masc_exec.Shell_ir.t)
    : (unit, string) result
    =
    match node with
    | Masc_exec.Shell_ir.Simple stage ->
      let stage_cwd =
        match stage.cwd with
        | Some scope ->
          ref (Some (resolve_against_cwd !effective_cwd (Masc_exec.Path_scope.raw scope)))
        | None -> effective_cwd
      in
      let extras =
        stage_extra_destinations stage
        |> map_destinations ~effective_cwd ~mkdir_seen
      in
      (match judge_destinations ~judge extras with
       | Error _ as err -> err
       | Ok () ->
         let subst_children =
           List.concat_map
             Masc_exec.Shell_ir.subst_children_of_arg
             (stage.Masc_exec.Shell_ir.args @ List.map snd stage.Masc_exec.Shell_ir.env)
         in
         (match
            walk_subshells ~depth ~parent_cwd:!stage_cwd ~parent_mkdir:!mkdir_seen
              subst_children
          with
          | Error _ as err -> err
          | Ok () ->
            (match sh_script_of_stage stage with
             | Some script ->
               if depth >= max_nested_script_depth
               then Ok ()
               else (
                 match Masc_exec_bash_parser.Bash.parse_string script with
                 | Masc_exec.Parsed.Parsed sub_ir ->
                   walk
                     ~depth:(depth + 1)
                     ~effective_cwd:(ref !stage_cwd)
                     ~mkdir_seen:(ref !mkdir_seen)
                     sub_ir
                 | Masc_exec.Parsed.Too_complex _
                 | Masc_exec.Parsed.Parse_error _
                 | Masc_exec.Parsed.Parse_aborted _ -> Ok ())
             | None ->
               let raw_named = argv_stage_destinations stage in
               let named, check_named =
                 match raw_named with
                 | Outside_vocabulary ->
                   ( Outside_vocabulary
                   , Destinations
                       (map_destinations
                          ~effective_cwd:stage_cwd
                          ~mkdir_seen
                          (literal_stage_destinations stage)) )
                 | Destinations ds ->
                   let mapped =
                     Destinations
                       (map_destinations ~effective_cwd:stage_cwd ~mkdir_seen ds)
                   in
                   mapped, mapped
               in
               (match judge_named ~judge check_named with
                | Error _ as err -> err
                | Ok () ->
                  if String.equal (bin_base stage.bin) "mkdir"
                  then mkdir_seen := true;
                  (if is_cd_stage stage then
                     match named with
                     | Destinations [ d ] -> effective_cwd := Some d.raw
                     | Destinations _ | Outside_vocabulary -> effective_cwd := None);
                  Ok ()))))
    | Masc_exec.Shell_ir.Pipeline stages ->
      walk_subshells ~depth ~parent_cwd:!effective_cwd ~parent_mkdir:!mkdir_seen stages
    | Masc_exec.Shell_ir.Sequence { head; tail } ->
      (match walk ~depth ~effective_cwd ~mkdir_seen head with
       | Error _ as err -> err
       | Ok () -> walk_sequence ~depth ~effective_cwd ~mkdir_seen (List.map snd tail))
  and walk_sequence ~depth ~effective_cwd ~mkdir_seen = function
    | [] -> Ok ()
    | part :: rest ->
      (match walk ~depth ~effective_cwd ~mkdir_seen part with
       | Ok () -> walk_sequence ~depth ~effective_cwd ~mkdir_seen rest
       | Error _ as err -> err)
  and walk_subshells ~depth ~parent_cwd ~parent_mkdir = function
    | [] -> Ok ()
    | stage :: rest ->
      (match
         walk
           ~depth
           ~effective_cwd:(ref parent_cwd)
           ~mkdir_seen:(ref parent_mkdir)
           stage
       with
       | Ok () -> walk_subshells ~depth ~parent_cwd ~parent_mkdir rest
       | Error _ as err -> err)
  in
  walk ~depth:0 ~effective_cwd:(ref None) ~mkdir_seen:(ref false) ir
;;
