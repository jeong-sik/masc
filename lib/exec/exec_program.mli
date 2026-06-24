(** Exec_program — opaque classified executable name.

    The only entry point is {!of_string}.  Callers cannot mint a [t]
    from raw data, which forces every argv-like shape through one
    classification site.  [`Unknown] becomes [Privileged] so the
    approval policy treats unseen binaries as Ask by default. *)

type t
type unknown = [ `Unknown of string ]

type risk_class =
  [ `Safe (** e.g. [ls], [cat], [pwd], [echo], [rg], [head], [tail] *)
  | `Audited (** e.g. [git], [docker], [curl], [ssh], [tar], [rsync], [make], [gh] *)
  | `Privileged
    (** e.g. [sudo], [su], [chmod], [chown], [rm], [dd], [mkfs]; also
        the fallback for names that the registry does not know. *)
  ]

val risk_class_max : risk_class -> risk_class -> risk_class
(** [risk_class_max a b] returns the stricter of the two risk classes.
    Order: [`Privileged] > [`Audited] > [`Safe]. *)

(** Finer-grained classification for typed dispatch.  Callers that
    used to switch on [Exec_program.to_string bin = "git"] should switch on
    [Exec_program.kind bin] instead so a new audited bin forces a compile
    error in every dispatch site.

    The shape mirrors {!risk_class} 1:1 — [`Safe_program] for [`Safe],
    [`Privileged_program] for [`Privileged], and the audited names fan
    out into [`Git | `Docker | `Curl | `Ssh | `Other_audited]. *)
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

    Each constructor maps to exactly one metadata entry in the implementation.
    Adding a new binary requires adding a constructor here AND updating the
    metadata function there; the compiler enforces completeness so no known
    binary can silently miss name/risk/kind classification. *)
type known =
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
  (* Database CLIs (network clients); destructiveness lives in the SQL verb. *)
  | Psql
  | Mysql
  | Mariadb
  | Sudo
  | Su
  | Chmod
  | Chown
  | Rm
  | Dd
  | Mkfs
  (* System-power control: catastrophic-by-identity, path-independent —
     floored beside [Mkfs] in [Approval_policy.find_catastrophic_program]. *)
  | Shutdown
  | Reboot
  | Halt
  | Poweroff

(** Closed registry used for reverse lookup and golden checks. *)
val all_known : known list

val name_of_known : known -> string
val risk_of_known : known -> risk_class
val kind_of_known : known -> kind
val of_string : string -> (t, unknown) result
val risk_class : t -> risk_class
val kind : t -> kind

(** Intended only for the exec gate's final spawn path and for error
    messages.  Policy code must stay on the typed value. *)
val to_string : t -> string

(** Construct a [t] directly from a [known] variant — no string parsing. *)
val of_known : known -> t

(** [Some k] for binaries in the closed registry, [None] for unknowns
    that were classified as [Privileged] by default. *)
val known : t -> known option

val pp : Format.formatter -> t -> unit
val equal : t -> t -> bool
val to_yojson : t -> [> `String of string ]
