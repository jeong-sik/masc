(** GADT Capability and Verified Shell IR definitions. *)

type yes = Yes
type no = No

type safe = Safe_tag
type unsafe = Unsafe_tag

type _ verified_ir =
  | Safe_IR : Masc_exec.Shell_ir.t -> safe verified_ir
  | Unsafe_IR : Masc_exec.Shell_ir.t -> unsafe verified_ir

type cap_flags = {
  read_fs : bool;
  write_fs : bool;
  network : bool;
  spawn : bool;
}

type promotion_error =
  | Unsafe_capability of string
  | Mutation_not_allowed of string

(** Deduce capability flags for a known binary. *)
let classify_flags : Masc_exec.Exec_program.known -> cap_flags = function
  (* Read-only filesystem operations *)
  | Ls | Cat | Pwd | Echo | Head | Tail | Rg | Grep | Find | Which
  | Test | Basename | Dirname | Stat | Du | Df | Sort | Uniq | Wc
  | Cut | Tr | File | Printf | Date | Env | Printenv | Hostname
  | Whoami | Uname | Ps | Tty ->
      { read_fs = true; write_fs = false; network = false; spawn = false }

  (* Write filesystem operations (no network, no spawn) *)
  | Cp | Mv | Ln | Touch | Tee | Sed | Mkdir | Tar | Diff | Patch | Awk ->
      { read_fs = true; write_fs = true; network = false; spawn = false }

  (* Write + Network operations (no spawn) *)
  | Git | Gh | Glab | Curl | Wget | Ssh | Scp | Rsync ->
      { read_fs = true; write_fs = true; network = true; spawn = false }

  (* Write + Network + Spawn operations (highest capability required) *)
  | Sudo | Su | Chmod | Chown | Rm | Dd | Mkfs
  | Docker | Npm | Node | Npx | Yarn | Pnpm | Pip | Python | Python3
  | Pytest | Pyright | Ruff | Opam | Ocamlfind | Tsc | Cargo | Rustc
  | Go | Gofmt | Gradle | Java | Javac | Mvn | Ninja | Uv | Make | Cmake
  | Dune_local_sh | Terminal_notifier | Osascript | Play | Rec | Ffplay
  | Mpg123 | Open | Xargs ->
      { read_fs = true; write_fs = true; network = true; spawn = true }

(** Deduce capability flags for any [Exec_program.t]. *)
let classify_program_flags (p : Masc_exec.Exec_program.t) : cap_flags =
  match Masc_exec.Exec_program.known p with
  | Some k -> classify_flags k
  | None ->
      (* Fail-closed: classify unknown binaries as needing full capabilities *)
      { read_fs = true; write_fs = true; network = true; spawn = true }

let validate_safe_capabilities ir =
  let validate_simple (simple : Masc_exec.Shell_ir.simple) =
    let bin = simple.Masc_exec.Shell_ir.bin in
    let bin_name = Masc_exec.Exec_program.to_string bin in
    let flags = classify_program_flags bin in
    if String.equal bin_name "env"
    then Error (Unsafe_capability bin_name)
    else if flags.write_fs || flags.network || flags.spawn
    then Error (Unsafe_capability bin_name)
    else Ok ()
  in
  let rec loop = function
    | Masc_exec.Shell_ir.Simple simple -> validate_simple simple
    | Masc_exec.Shell_ir.Pipeline stages ->
      let rec loop_stages = function
        | [] -> Ok ()
        | stage :: rest ->
          (match loop stage with
           | Ok () -> loop_stages rest
           | Error _ as error -> error)
      in
      loop_stages stages
  in
  loop ir
;;

let validate_safe_risk ir =
  let decided =
    Masc_exec.Shell_ir_risk.(classify (undecided ir))
  in
  match Masc_exec.Shell_ir_risk.risk_class decided with
  | R0_Read -> Ok ()
  | risk ->
    Error
      (Mutation_not_allowed (Masc_exec.Shell_ir_risk.string_of_risk_class risk))
;;

let promote ir =
  match validate_safe_capabilities ir with
  | Error _ as error -> error
  | Ok () ->
    (match validate_safe_risk ir with
     | Error _ as error -> error
     | Ok () -> Ok (Safe_IR ir))
;;

let shell_ir : type phase. phase verified_ir -> Masc_exec.Shell_ir.t = function
  | Safe_IR ir -> ir
  | Unsafe_IR ir -> ir
;;
