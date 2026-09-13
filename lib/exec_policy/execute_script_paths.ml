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

let is_cd_stage (stage : Masc_exec.Shell_ir.simple) : bool =
  String.equal (bin_name stage.bin) "cd"
;;

let looks_like_option (s : string) : bool =
  String.length s >= 2 && String.unsafe_get s 0 = '-'
;;

(* ------------------------------------------------------------------ *)
(* Closed program-key table (operator: amend_closed_keys).             *)
(* ------------------------------------------------------------------ *)

type operand_spec =
  | Flag_operand of string
      (* the literal immediately after this exact flag is the operand *)
  | Subcommand_operands of string list * int option
      (* subcommand words; the remaining non-flag literals are operands,
         up to the given count ([None] = unlimited). [git worktree add
         <path> <commit-ish>] takes exactly one path — its second
         positional argument names a ref, not a destination, and must
         not be handed to the filesystem judge. *)

let operand_specs = function
  | "git" ->
    [ Flag_operand "-C"; Subcommand_operands ([ "worktree"; "add" ], Some 1) ]
  | "mkdir" | "rm" | "cp" | "mv" -> [ Subcommand_operands ([], None) ]
  | _ -> []
;;

(* One stage's argv destinations under the closed table.  Non-literal
   operands and glob operands leave the destination set incomplete —
   refused for judging, never partially named. *)
let argv_stage_destinations (stage : Masc_exec.Shell_ir.simple) : named =
  if is_cd_stage stage then
    match stage.args with
    | [ Masc_exec.Shell_ir.Lit (dest, meta) ] when not meta.glob ->
      if looks_like_option dest then Outside_vocabulary
      else Destinations [ { raw = dest; is_cd = true } ]
    | _ -> Outside_vocabulary
  else (
    match operand_specs (bin_name stage.bin) with
    | [] -> Destinations []
    | specs -> (
      let rec match_specs = function
        | [] -> Destinations []
        | spec :: rest -> (
          match (spec, stage.args) with
          | Flag_operand flag, Masc_exec.Shell_ir.Lit (a, _) :: args_tail
            when String.equal a flag
            -> (
            match args_tail with
            | Masc_exec.Shell_ir.Lit (target, meta) :: _ when not meta.glob ->
              if looks_like_option target then Outside_vocabulary
              else Destinations [ { raw = target; is_cd = false } ]
            | Masc_exec.Shell_ir.Lit _ :: _ -> Outside_vocabulary
            | Masc_exec.Shell_ir.Var _ :: _ | Masc_exec.Shell_ir.Concat _ :: _
            | Masc_exec.Shell_ir.Subst _ :: _ ->
              Outside_vocabulary
            | [] -> Destinations [])
          | Subcommand_operands (words, max_count), args -> (
            let rec drop_words = function
              | w :: ws, Masc_exec.Shell_ir.Lit (a, _) :: rest when String.equal a w ->
                drop_words (ws, rest)
              | [], rest -> Some rest
              | _ -> None
            in
            match drop_words (words, args) with
            | None -> match_specs rest
            | Some rest -> (
              let rec collect acc n = function
                | _rest when (match max_count with Some m -> n >= m | None -> false) ->
                  Destinations (List.rev acc)
                | [] -> Destinations (List.rev acc)
                | Masc_exec.Shell_ir.Lit (s, meta) :: tail ->
                  if meta.glob then Outside_vocabulary
                  else if looks_like_option s then collect acc n tail
                  else collect ({ raw = s; is_cd = false } :: acc) (n + 1) tail
                | Masc_exec.Shell_ir.Var _ :: _
                | Masc_exec.Shell_ir.Concat _ :: _
                | Masc_exec.Shell_ir.Subst _ :: _ ->
                  Outside_vocabulary
              in
              collect [] 0 rest))
          | _ -> match_specs rest)
      in
      match_specs specs))
;;

(* ------------------------------------------------------------------ *)
(* Script pass (operator: cd_promote): re-open the [sh -c] subscript.  *)
(* ------------------------------------------------------------------ *)

let sh_script_of_stage (stage : Masc_exec.Shell_ir.simple) : string option =
  match bin_name stage.bin with
  | "sh" | "bash" -> (
    match stage.args with
    | [ Masc_exec.Shell_ir.Lit (flag, _); Masc_exec.Shell_ir.Lit (script, script_meta) ]
      when String.equal flag "-c" && not script_meta.glob
      -> Some script
    | _ -> None)
  | _ -> None
;;

let script_destinations ~(limit : int) (script : string) : named =
  match Masc_exec_bash_parser.Bash.parse_string script with
  | Masc_exec.Parsed.Parsed ir ->
    if Masc_exec.Shell_ir.has_variable_expansion ir then Outside_vocabulary
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
      if count_cd > 1 then Outside_vocabulary
      else
        let rec ir_destinations (ir : Masc_exec.Shell_ir.t) : named =
          match ir with
          | Masc_exec.Shell_ir.Simple s -> argv_stage_destinations s
          | Masc_exec.Shell_ir.Pipeline stages -> list_destinations stages
          | Masc_exec.Shell_ir.Sequence { head; tail } -> (
            match ir_destinations head with
            | Outside_vocabulary -> Outside_vocabulary
            | Destinations head_ds -> (
              let rec go ds = function
                | [] -> Destinations (List.rev ds)
                | (_, t) :: rest -> (
                  match ir_destinations t with
                  | Outside_vocabulary -> Outside_vocabulary
                  | Destinations ds' -> go (List.rev_append ds' ds) rest)
              in
              go head_ds tail))
        and list_destinations = function
          | [] -> Destinations []
          | s :: rest -> (
            match ir_destinations s with
            | Outside_vocabulary -> Outside_vocabulary
            | Destinations ds -> (
              match list_destinations rest with
              | Outside_vocabulary -> Outside_vocabulary
              | Destinations ds' -> Destinations (ds @ ds')))
        in
        match ir_destinations ir with
        | Destinations ds when List.length ds <= limit -> Destinations ds
        | Destinations _ -> Outside_vocabulary
        | Outside_vocabulary -> Outside_vocabulary)
  | Masc_exec.Parsed.Too_complex _ | Masc_exec.Parsed.Parse_error _
  | Masc_exec.Parsed.Parse_aborted _ ->
    Outside_vocabulary
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
    ~(limit : int)
    (ir : Masc_exec.Shell_ir.t)
  : (unit, string) result
  =
  let rec walk (ir : Masc_exec.Shell_ir.t) : (unit, string) result =
    match ir with
    | Masc_exec.Shell_ir.Simple stage -> (
      match sh_script_of_stage stage with
      | Some script -> judge_named ~judge (script_destinations ~limit script)
      | None -> judge_named ~judge (argv_stage_destinations stage))
    | Masc_exec.Shell_ir.Pipeline stages -> walk_each stages
    | Masc_exec.Shell_ir.Sequence { head; tail } -> (
      match walk head with
      | Error _ as err -> err
      | Ok () -> walk_each (List.map snd tail))
  and walk_each = function
    | [] -> Ok ()
    | part :: rest -> (
      match walk part with
      | Ok () -> walk_each rest
      | Error _ as err -> err)
  in
  walk ir
;;
