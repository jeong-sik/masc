type risk_class =
  [ `Safe
  | `Audited
  | `Privileged
  ]

let risk_class_max a b =
  match a, b with
  | `Privileged, _ | _, `Privileged -> `Privileged
  | `Audited, _ | _, `Audited -> `Audited
  | `Safe, `Safe -> `Safe
;;

type kind =
  [ `Git
  | `Docker
  | `Curl
  | `Ssh
  | `Other_audited
  | `Safe_program
  | `Privileged_program
  ]

(** Closed variant of every binary the exec gate knows about.

    Each constructor maps to exactly one string name via {!name_of_known}.
    Adding a new binary requires adding a constructor here AND updating
    {!name_of_known} — the compiler enforces completeness. *)
type known =
  (* Safe *)
  | Ls
  | Cat
  | Pwd
  | Echo
  | Head
  | Tail
  | Rg
  | Grep
  | Find
  | Which
  | Test
  | Basename
  | Dirname
  | Stat
  | Du
  | Df
  | Sort
  | Uniq
  | Wc
  | Cut
  | Tr
  | File
  | Printf
  | Date
  | Env
  | Printenv
  | Hostname
  | Whoami
  | Uname
  | Ps
  | Tty
  | Cp
  | Mv
  | Ln
  | Touch
  | Tee
  | Awk
  | Xargs
  (* Audited *)
  | Git
  | Docker
  | Curl
  | Wget
  | Ssh
  | Scp
  | Tar
  | Rsync
  | Make
  | Cmake
  | Dune_local_sh
  | Diff
  | Patch
  | Mkdir
  | Npm
  | Node
  | Npx
  | Yarn
  | Pnpm
  | Pip
  | Python
  | Python3
  | Pytest
  | Pyright
  | Ruff
  | Opam
  | Ocamlfind
  | Tsc
  | Cargo
  | Rustc
  | Go
  | Gofmt
  | Gradle
  | Java
  | Javac
  | Mvn
  | Ninja
  | Sed
  | Uv
  | Gh
  | Glab
  | Terminal_notifier
  | Osascript
  | Play
  | Rec
  | Ffplay
  | Mpg123
  | Open
  (* Database CLIs: network clients.  Destructiveness lives in the SQL verb
     ([Db_op]), floored by [Approval_policy.find_destructive_db], not in the
     binary identity — so these are [`Audited], not [`Privileged]. *)
  | Psql
  | Mysql
  | Mariadb
  (* Privileged *)
  | Sudo
  | Su
  | Chmod
  | Chown
  | Rm
  | Dd
  | Mkfs
  (* System-power control: catastrophic-by-identity, path-independent. A keeper
     has no legitimate argument form for halting/rebooting the host, so these
     are floored beside [Mkfs] (see [Approval_policy.find_catastrophic_program]),
     not merely classified [`Privileged]. *)
  | Shutdown
  | Reboot
  | Halt
  | Poweroff

type known_metadata =
  { name : string
  ; risk : risk_class
  ; kind : kind
  }

let known_metadata : known -> known_metadata = function
  | Ls -> { name = "ls"; risk = `Safe; kind = `Safe_program }
  | Cat -> { name = "cat"; risk = `Safe; kind = `Safe_program }
  | Pwd -> { name = "pwd"; risk = `Safe; kind = `Safe_program }
  | Echo -> { name = "echo"; risk = `Safe; kind = `Safe_program }
  | Head -> { name = "head"; risk = `Safe; kind = `Safe_program }
  | Tail -> { name = "tail"; risk = `Safe; kind = `Safe_program }
  | Rg -> { name = "rg"; risk = `Safe; kind = `Safe_program }
  | Grep -> { name = "grep"; risk = `Safe; kind = `Safe_program }
  | Find -> { name = "find"; risk = `Safe; kind = `Safe_program }
  | Which -> { name = "which"; risk = `Safe; kind = `Safe_program }
  | Test -> { name = "test"; risk = `Safe; kind = `Safe_program }
  | Basename -> { name = "basename"; risk = `Safe; kind = `Safe_program }
  | Dirname -> { name = "dirname"; risk = `Safe; kind = `Safe_program }
  | Stat -> { name = "stat"; risk = `Safe; kind = `Safe_program }
  | Du -> { name = "du"; risk = `Safe; kind = `Safe_program }
  | Df -> { name = "df"; risk = `Safe; kind = `Safe_program }
  | Sort -> { name = "sort"; risk = `Safe; kind = `Safe_program }
  | Uniq -> { name = "uniq"; risk = `Safe; kind = `Safe_program }
  | Wc -> { name = "wc"; risk = `Safe; kind = `Safe_program }
  | Cut -> { name = "cut"; risk = `Safe; kind = `Safe_program }
  | Tr -> { name = "tr"; risk = `Safe; kind = `Safe_program }
  | File -> { name = "file"; risk = `Safe; kind = `Safe_program }
  | Printf -> { name = "printf"; risk = `Safe; kind = `Safe_program }
  | Date -> { name = "date"; risk = `Safe; kind = `Safe_program }
  | Env -> { name = "env"; risk = `Safe; kind = `Safe_program }
  | Printenv -> { name = "printenv"; risk = `Safe; kind = `Safe_program }
  | Hostname -> { name = "hostname"; risk = `Safe; kind = `Safe_program }
  | Whoami -> { name = "whoami"; risk = `Safe; kind = `Safe_program }
  | Uname -> { name = "uname"; risk = `Safe; kind = `Safe_program }
  | Ps -> { name = "ps"; risk = `Safe; kind = `Safe_program }
  | Tty -> { name = "tty"; risk = `Safe; kind = `Safe_program }
  | Cp -> { name = "cp"; risk = `Safe; kind = `Safe_program }
  | Mv -> { name = "mv"; risk = `Safe; kind = `Safe_program }
  | Ln -> { name = "ln"; risk = `Safe; kind = `Safe_program }
  | Touch -> { name = "touch"; risk = `Safe; kind = `Safe_program }
  | Tee -> { name = "tee"; risk = `Safe; kind = `Safe_program }
  | Awk -> { name = "awk"; risk = `Safe; kind = `Safe_program }
  | Xargs -> { name = "xargs"; risk = `Safe; kind = `Safe_program }
  | Git -> { name = "git"; risk = `Audited; kind = `Git }
  | Docker -> { name = "docker"; risk = `Audited; kind = `Docker }
  | Curl -> { name = "curl"; risk = `Audited; kind = `Curl }
  | Wget -> { name = "wget"; risk = `Audited; kind = `Other_audited }
  | Ssh -> { name = "ssh"; risk = `Audited; kind = `Ssh }
  | Scp -> { name = "scp"; risk = `Audited; kind = `Other_audited }
  | Tar -> { name = "tar"; risk = `Audited; kind = `Other_audited }
  | Rsync -> { name = "rsync"; risk = `Audited; kind = `Other_audited }
  | Make -> { name = "make"; risk = `Audited; kind = `Other_audited }
  | Cmake -> { name = "cmake"; risk = `Audited; kind = `Other_audited }
  | Dune_local_sh ->
    { name = "dune-local.sh"; risk = `Audited; kind = `Other_audited }
  | Diff -> { name = "diff"; risk = `Audited; kind = `Other_audited }
  | Patch -> { name = "patch"; risk = `Audited; kind = `Other_audited }
  | Mkdir -> { name = "mkdir"; risk = `Audited; kind = `Other_audited }
  | Npm -> { name = "npm"; risk = `Audited; kind = `Other_audited }
  | Node -> { name = "node"; risk = `Audited; kind = `Other_audited }
  | Npx -> { name = "npx"; risk = `Audited; kind = `Other_audited }
  | Yarn -> { name = "yarn"; risk = `Audited; kind = `Other_audited }
  | Pnpm -> { name = "pnpm"; risk = `Audited; kind = `Other_audited }
  | Pip -> { name = "pip"; risk = `Audited; kind = `Other_audited }
  | Python -> { name = "python"; risk = `Audited; kind = `Other_audited }
  | Python3 -> { name = "python3"; risk = `Audited; kind = `Other_audited }
  | Pytest -> { name = "pytest"; risk = `Audited; kind = `Other_audited }
  | Pyright -> { name = "pyright"; risk = `Audited; kind = `Other_audited }
  | Ruff -> { name = "ruff"; risk = `Audited; kind = `Other_audited }
  | Opam -> { name = "opam"; risk = `Audited; kind = `Other_audited }
  | Ocamlfind -> { name = "ocamlfind"; risk = `Audited; kind = `Other_audited }
  | Tsc -> { name = "tsc"; risk = `Audited; kind = `Other_audited }
  | Cargo -> { name = "cargo"; risk = `Audited; kind = `Other_audited }
  | Rustc -> { name = "rustc"; risk = `Audited; kind = `Other_audited }
  | Go -> { name = "go"; risk = `Audited; kind = `Other_audited }
  | Gofmt -> { name = "gofmt"; risk = `Audited; kind = `Other_audited }
  | Gradle -> { name = "gradle"; risk = `Audited; kind = `Other_audited }
  | Java -> { name = "java"; risk = `Audited; kind = `Other_audited }
  | Javac -> { name = "javac"; risk = `Audited; kind = `Other_audited }
  | Mvn -> { name = "mvn"; risk = `Audited; kind = `Other_audited }
  | Ninja -> { name = "ninja"; risk = `Audited; kind = `Other_audited }
  | Sed -> { name = "sed"; risk = `Audited; kind = `Other_audited }
  | Uv -> { name = "uv"; risk = `Audited; kind = `Other_audited }
  | Gh -> { name = "gh"; risk = `Audited; kind = `Other_audited }
  | Glab -> { name = "glab"; risk = `Audited; kind = `Other_audited }
  | Terminal_notifier ->
    { name = "terminal-notifier"; risk = `Audited; kind = `Other_audited }
  | Osascript -> { name = "osascript"; risk = `Audited; kind = `Other_audited }
  | Play -> { name = "play"; risk = `Audited; kind = `Other_audited }
  | Rec -> { name = "rec"; risk = `Audited; kind = `Other_audited }
  | Ffplay -> { name = "ffplay"; risk = `Audited; kind = `Other_audited }
  | Mpg123 -> { name = "mpg123"; risk = `Audited; kind = `Other_audited }
  | Open -> { name = "open"; risk = `Audited; kind = `Other_audited }
  | Psql -> { name = "psql"; risk = `Audited; kind = `Other_audited }
  | Mysql -> { name = "mysql"; risk = `Audited; kind = `Other_audited }
  | Mariadb -> { name = "mariadb"; risk = `Audited; kind = `Other_audited }
  | Sudo -> { name = "sudo"; risk = `Privileged; kind = `Privileged_program }
  | Su -> { name = "su"; risk = `Privileged; kind = `Privileged_program }
  | Chmod -> { name = "chmod"; risk = `Privileged; kind = `Privileged_program }
  | Chown -> { name = "chown"; risk = `Privileged; kind = `Privileged_program }
  | Rm -> { name = "rm"; risk = `Privileged; kind = `Privileged_program }
  | Dd -> { name = "dd"; risk = `Privileged; kind = `Privileged_program }
  | Mkfs -> { name = "mkfs"; risk = `Privileged; kind = `Privileged_program }
  | Shutdown -> { name = "shutdown"; risk = `Privileged; kind = `Privileged_program }
  | Reboot -> { name = "reboot"; risk = `Privileged; kind = `Privileged_program }
  | Halt -> { name = "halt"; risk = `Privileged; kind = `Privileged_program }
  | Poweroff -> { name = "poweroff"; risk = `Privileged; kind = `Privileged_program }
;;

let all_known =
  [ Ls
  ; Cat
  ; Pwd
  ; Echo
  ; Head
  ; Tail
  ; Rg
  ; Grep
  ; Find
  ; Which
  ; Test
  ; Basename
  ; Dirname
  ; Stat
  ; Du
  ; Df
  ; Sort
  ; Uniq
  ; Wc
  ; Cut
  ; Tr
  ; File
  ; Printf
  ; Date
  ; Env
  ; Printenv
  ; Hostname
  ; Whoami
  ; Uname
  ; Ps
  ; Tty
  ; Cp
  ; Mv
  ; Ln
  ; Touch
  ; Tee
  ; Awk
  ; Xargs
  ; Git
  ; Docker
  ; Curl
  ; Wget
  ; Ssh
  ; Scp
  ; Tar
  ; Rsync
  ; Make
  ; Cmake
  ; Dune_local_sh
  ; Diff
  ; Patch
  ; Mkdir
  ; Npm
  ; Node
  ; Npx
  ; Yarn
  ; Pnpm
  ; Pip
  ; Python
  ; Python3
  ; Pytest
  ; Pyright
  ; Ruff
  ; Opam
  ; Ocamlfind
  ; Tsc
  ; Cargo
  ; Rustc
  ; Go
  ; Gofmt
  ; Gradle
  ; Java
  ; Javac
  ; Mvn
  ; Ninja
  ; Sed
  ; Uv
  ; Gh
  ; Glab
  ; Terminal_notifier
  ; Osascript
  ; Play
  ; Rec
  ; Ffplay
  ; Mpg123
  ; Open
  ; Psql
  ; Mysql
  ; Mariadb
  ; Sudo
  ; Su
  ; Chmod
  ; Chown
  ; Rm
  ; Dd
  ; Mkfs
  ; Shutdown
  ; Reboot
  ; Halt
  ; Poweroff
  ]
;;

let name_of_known known = (known_metadata known).name
let risk_of_known known = (known_metadata known).risk
let kind_of_known known = (known_metadata known).kind

type t =
  { name : string
  ; risk : risk_class
  ; kind : kind
  ; known : known option
  }

type unknown = [ `Unknown of string ]

(** Reverse lookup is derived from [all_known] and [known_metadata] so string
    names cannot drift from risk/kind classification. *)
let known_of_string name =
  List.find_opt (fun known -> String.equal (name_of_known known) name) all_known
;;

let of_string raw =
  if raw = ""
  then Error (`Unknown raw)
  else (
    let name = Filename.basename raw in
    match known_of_string name with
    | Some k ->
      Ok { name; risk = risk_of_known k; kind = kind_of_known k; known = Some k }
    | None when String.starts_with ~prefix:"mkfs." name ->
      (* The [mkfs.<fstype>] family (mkfs.ext4, mkfs.xfs, mkfs.vfat, ...) is the
         util-linux / fs-tools naming convention for filesystem-format helpers.
         Every member is catastrophic-by-identity like bare [mkfs] (RFC-0254
         §5.3 floor), so recognize the family structurally: an enumerated set
         would let a new fstype helper silently bypass the floor. The recorded
         [name] stays the real binary so the deny diagnostic is accurate. *)
      Ok { name; risk = risk_of_known Mkfs; kind = kind_of_known Mkfs; known = Some Mkfs }
    | None ->
      (* Unknown binary -> Privileged per RFC v5 fail-closed rule. *)
      Ok { name; risk = `Privileged; kind = `Privileged_program; known = None })
;;

let risk_class t = t.risk
let kind t = t.kind
let to_string t = t.name

(** Construct a [t] directly from a [known] variant — no string parsing,
    no risk of [Error]. *)
let of_known k =
  { name = name_of_known k
  ; risk = risk_of_known k
  ; kind = kind_of_known k
  ; known = Some k
  }
;;

(** Returns [Some k] when the binary is in the known registry, [None]
    for unknown binaries classified as Privileged by default. *)
let known t = t.known

let pp fmt t =
  let tag =
    match t.risk with
    | `Safe -> "safe"
    | `Audited -> "audited"
    | `Privileged -> "privileged"
  in
  Format.fprintf fmt "%s:%s" tag t.name
;;

let equal a b = String.equal a.name b.name
let to_yojson t = `String t.name
