(** Bin — opaque classified executable name.

    The only entry point is {!of_string}.  Callers cannot mint a [t]
    from raw data, which forces every argv-like shape through one
    classification site.  [`Unknown] becomes [Privileged] so the
    approval policy treats unseen binaries as Ask by default. *)

type t

type unknown = [ `Unknown of string ]

type risk_class =
  [ `Safe
    (** e.g. [ls], [cat], [pwd], [echo], [grep], [rg], [head], [tail] *)
  | `Audited
    (** e.g. [git], [docker], [curl], [ssh], [tar], [rsync], [make], [gh] *)
  | `Privileged
    (** e.g. [sudo], [su], [chmod], [chown], [rm], [dd], [mkfs]; also
        the fallback for names that the registry does not know. *)
  ]

type kind =
  [ `Git
  | `Docker
  | `Curl
  | `Ssh
  | `Other_audited
  | `Safe_bin
  | `Privileged_bin
  ]
(** Finer-grained classification for typed dispatch.  Callers that
    used to switch on [Bin.to_string bin = "git"] should switch on
    [Bin.kind bin] instead so a new audited bin forces a compile
    error in every dispatch site.

    The shape mirrors {!risk_class} 1:1 — [`Safe_bin] for [`Safe],
    [`Privileged_bin] for [`Privileged], and the audited names fan
    out into [`Git | `Docker | `Curl | `Ssh | `Other_audited]. *)

(** Closed variant of every binary the exec gate knows about.

    Each constructor maps to exactly one string name.  Adding a new
    binary requires adding a constructor here AND updating the
    string mapping in the implementation — the compiler enforces
    completeness so no known binary can be silently dropped. *)
type known =
  | Ls | Cat | Pwd | Echo | Head | Tail | Grep | Rg | Find
  | Which | Test | Basename | Dirname | Stat | Du | Df
  | Sort | Uniq | Wc | Cut | Tr | Date | Env | Printenv
  | Hostname | Whoami | Uname | Ps | Tty
  | Git | Docker | Curl | Wget | Ssh | Scp | Tar | Rsync
  | Make | Cmake | Npm | Yarn | Pnpm | Pip | Opam | Cargo
  | Gh | Glab | Terminal_notifier | Osascript
  | Play | Rec | Ffplay | Mpg123 | Open
  | Claude | Gemini | Codex
  | Sudo | Su | Chmod | Chown | Rm | Dd | Mkfs

val name_of_known : known -> string
val risk_of_known : known -> risk_class
val kind_of_known : known -> kind

val of_string : string -> (t, unknown) result
val risk_class : t -> risk_class
val kind : t -> kind
val to_string : t -> string
(** Intended only for the exec gate's final spawn path and for error
    messages.  Policy code must stay on the typed value. *)

val of_known : known -> t
(** Construct a [t] directly from a [known] variant — no string parsing. *)

val known : t -> known option
(** [Some k] for binaries in the closed registry, [None] for unknowns
    that were classified as [Privileged] by default. *)

val pp : Format.formatter -> t -> unit

val equal : t -> t -> bool

val to_yojson : t -> [> `String ]
