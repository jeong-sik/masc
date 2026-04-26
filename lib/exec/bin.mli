(** Bin — opaque classified executable name.

    The only entry point is {!of_string}.  Callers cannot mint a [t]
    from raw data, which forces every argv-like shape through one
    classification site.  [`Unknown] becomes [Privileged] so the
    approval policy treats unseen binaries as Ask by default. *)

type t
type unknown = [ `Unknown of string ]

type risk_class =
  [ `Safe (** e.g. [ls], [cat], [pwd], [echo], [grep], [rg], [head], [tail] *)
  | `Audited (** e.g. [git], [docker], [curl], [ssh], [tar], [rsync], [make], [gh] *)
  | `Privileged
    (** e.g. [sudo], [su], [chmod], [chown], [rm], [dd], [mkfs]; also
        the fallback for names that the registry does not know. *)
  ]

val of_string : string -> (t, unknown) result
val risk_class : t -> risk_class

(** Intended only for the exec gate's final spawn path and for error
    messages.  Policy code must stay on the typed value. *)
val to_string : t -> string

val pp : Format.formatter -> t -> unit
