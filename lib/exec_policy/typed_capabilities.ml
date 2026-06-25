(** GADT Capability and Verified Shell IR definitions.

    Risk classification is the single source of truth for shell safety.
    [Safe_IR] wrapping happens after static R0 verification; no redundant
    capability or mutation checks are performed here. *)

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
  | Git | Gh | Glab | Curl | Wget | Ssh | Scp | Rsync
  | Psql | Mysql | Mariadb | Cockroach ->
      { read_fs = true; write_fs = true; network = true; spawn = false }

  (* Write + Network + Spawn operations (highest capability required) *)
  | Sudo | Su | Chmod | Chown | Rm | Dd | Mkfs
  | Shutdown | Reboot | Halt | Poweroff
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

let shell_ir : type phase. phase verified_ir -> Masc_exec.Shell_ir.t = function
  | Safe_IR ir -> ir
  | Unsafe_IR ir -> ir
