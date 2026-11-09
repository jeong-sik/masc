(* HIGH-RISK-UNREVIEWED: this module decides whether a CLI may start on an
   official account. A wrong answer starts a CLI on the subscription of
   another person. Read it against plan D2. *)

(** Whether a CLI may start on an official account (multi-account plan D2-3).

    A captured account ({!Runtime_official_account.t}) holds the environment
    its CLI starts with, and that environment can hold a credential. A CLI
    starts only on an {!authorized} account, and only {!authorize} makes one:
    from a {!sealed} account and the {!request} it serves, by the access the
    process {!publish}ed.

    {b Published once.} A process publishes its access once, after the
    judgment of its account mode: the owner state of a server and of the
    stdio server publishes it, and a host tool publishes it after
    {!Authz_boot_mode_read.tool}. Until then every request is refused.

    {b Single user.} The one person of a single-user process owns every
    account of it, so every request is allowed. A request still names the
    Keeper turn or the call it serves, because a process of more than one
    person decides on it (plan D2-7). *)

(** An account captured from a declaration. No CLI starts on it. *)
type 'client sealed

val seal : 'client Runtime_official_account.t -> 'client sealed

(** An account a CLI may start on. Only {!authorize} makes one. *)
type 'client authorized

(** The account, for the client that starts the CLI. *)
val account : 'client authorized -> 'client Runtime_official_account.t

(** The access of a process. *)
type t =
  | Single_user of Authz_boot_mode_read.single_user
      (** The boot judged the base path a single-user boot. *)

type publish_error = Already_published  (** The process published its access before. *)

val publish_error_to_string : publish_error -> string

(** Publishes the access of this process. The first call wins. A later call
    is refused and changes nothing. *)
val publish : t -> (unit, publish_error) result

(** What a CLI starts for. *)
type request =
  | Keeper_turn of
      { keeper_name : string  (** The name of the Keeper, which is the name of its TOML. *)
      ; channel : Authz_types.Channel.t  (** What started the turn. *)
      ; runtime_id : string  (** The Runtime of the runtime table that runs the turn. *)
      }
  | Operator_call
      (** A call that no Keeper turn makes, for the person who runs the
          process: a probe of a subscription, a list of models, a
          verification run. *)

type refusal = Not_published  (** The process has not published its access. *)

val refusal_to_string : refusal -> string

(** Authorizes [sealed] for [request] by the access the process published. *)
val authorize : request -> 'client sealed -> ('client authorized, refusal) result
