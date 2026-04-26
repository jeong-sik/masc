(** P20: Command Risk Classifier

    Classifies a shell command into a risk category based on the
    command prefix and argument patterns.  Pure function — no I/O.

    Risk categories drive policy decisions:
    - [Read]: cacheable (P19), no budget penalty (P17), no approval
    - [Write]: invalidate cache (P19), counts toward budget (P17)
    - [Network]: egress policy check (P12), extended timeout (P18)
    - [Destructive]: requires explicit approval, never cached *)

type risk_class =
  | Read (** Filesystem read, process query: ls, cat, rg, find, ps *)
  | Write (** Filesystem write, version control: git commit, cp, mv *)
  | Network (** Network access: curl, wget, ssh, rsync *)
  | Destructive (** Irreversible: rm -rf, sudo, chmod -R, mkfs *)

(** Classify a command string by its prefix and argument patterns.
    Normalizes simple shell whitespace, then uses prefix matching and
    flag inspection for escalation (e.g. [ls -rf] → Destructive). *)
val classify : string -> risk_class

val risk_class_to_string : risk_class -> string
val risk_class_to_json : risk_class -> Yojson.Safe.t

(** [Read] commands are cacheable; all others are not. *)
val is_cacheable : risk_class -> bool

(** [Destructive] commands require explicit approval. *)
val requires_approval : risk_class -> bool

(** Suggested timeout by risk class:
    Read=30_000, Write=60_000, Network=120_000, Destructive=120_000 *)
val default_timeout_ms : risk_class -> int
