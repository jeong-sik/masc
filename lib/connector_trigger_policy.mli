(** Connector_trigger_policy — runtime.toml > default resolution for a
    connector's trigger policy.

    The Discord and Slack gateways each carried a byte-for-byte copy of this
    walk, differing only in the table name and which module parses the value. The policy type stays with its connector: this
    module is a functor over it and links against neither gateway.

    A functor rather than a polymorphic type because each gateway re-exports
    the outcome constructors under its own name, and OCaml cannot re-export the
    constructors of an instantiated parameterized type. {!load_error} carries no
    parameter and is shared directly. *)

type load_error =
  | Runtime_toml_unreadable of { path : string; detail : string }
  | Runtime_toml_invalid of { path : string; detail : string }
  | Trigger_policy_invalid of { path : string; detail : string }

module type CONNECTOR = sig
  type policy

  val table : string
  (** The runtime.toml table holding [trigger_policy] — ["discord"]. *)

  val parse : string -> (policy, string) result
  (** The connector's own grammar. An unparseable name is an error, never a
      policy: silently answering with a default would run the gateway on a
      stance the operator did not write. *)

  val default : policy
  (** Answers only when both planes are absent. *)
end

module Make (C : CONNECTOR) : sig
  type load =
    | Runtime_toml_missing
    | Trigger_policy_missing
    | Trigger_policy_loaded of C.policy

  val load_from_toml : path:string -> (load, load_error) result
  (** Read [<table>.trigger_policy] from the runtime.toml at [path]. A missing
      file, a missing key and a blank value are three ways of saying "unset"
      and are reported as such, not coerced to a policy. An unreadable file,
      unparseable TOML, a non-string value and an unparseable policy name are
      errors: the caller refuses to start rather than falling back. *)

  val resolve : unit -> (C.policy, load_error) result
  (** The runtime.toml the workspace resolves to, then [C.default]. Which
      inbound messages start a turn is a stance an operator writes down, so it
      is read from the config file and nowhere else. *)
end
