(* HIGH-RISK-UNREVIEWED: this module decides whether a CLI may start on an
   official account. A wrong answer starts a CLI on the subscription of
   another person. Read it against plan D2. *)

(** Whether a CLI may start on an official account (multi-account plan D2).

    A captured account ({!Runtime_official_account.t}) holds the environment
    its CLI starts with, and that environment can hold a credential. A CLI
    starts only on an {!authorized} account, and only {!authorize} makes one:
    from a {!sealed} account and the {!request} it serves, by the access the
    process {!publish}ed.

    {b Published once.} A process publishes its access once. The owner state
    of a server and of the stdio server publishes {!Single_user} after the
    judgment of the account mode, a host tool publishes it after
    {!Authz_boot_mode_read.tool}, and the multi-account preview publishes
    {!Multi_account} with the zone it opened. Until then every request is
    refused.

    {b Single user.} The one person of a single-user process owns every
    account of it, so every request is allowed.

    {b Multi-account.} A CLI starts only on a home of the person the request
    is for, as {!Runtime_account_home_layout} spells it under the namespace of
    their membership, and only on a home that was declared: an inherited home
    carries the credentials of the process environment. For a Keeper turn
    that person is the owner of the Keeper, and the log decides the turn
    ({!Authz_keeper_turn.decide}) and names the Runtime and the account. No
    operator owns the account of a person, so an operator call is refused. *)

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
  | Multi_account of
      { zone : Authz_zone.t  (** The authorization zone of [base_path]. *)
      ; base_path : string
      ; now : unit -> float  (** Seconds since the epoch, for the decision of a turn. *)
      }

type publish_error = Already_published  (** The process published its access before. *)

val publish_error_to_string : publish_error -> string

(** Publishes the access of this process. The first call wins. A later call
    is refused and changes nothing. *)
val publish : t -> (unit, publish_error) result

(** Publishes the access of a host tool: {!Single_user} when
    {!Authz_boot_mode_read.tool} judges [base_path] a single user, with
    [config_dir] as the boot reads it. The judgment opens no file a server may
    be writing. The error is the reasons of the judgment, or a second
    publication. *)
val publish_host_tool
  :  base_path:string
  -> config_dir:string option
  -> (unit, string * string list) result

(** What a CLI starts for. *)
type request =
  | Keeper_turn of
      { keeper_name : string  (** The name of the Keeper, which is the name of its TOML. *)
      ; channel : Authz_types.Channel.t  (** What started the turn. *)
      ; runtime_id : string  (** The Runtime of the runtime table that runs the turn. *)
      }
  | Own_account of
      { user_id : Authz_types.User_id.t  (** The person who asked, as their session names them. *)
      ; provider_account_id : Authz_types.Provider_account_id.t
      }
      (** A person's own account: the check that follows their login and the
          verification they ask for. The log need not link the account yet,
          because the login checks the account before it links it. *)
  | Operator_call
      (** A call on the authority of the person who runs the process, not of
          the owner of a Keeper: a probe, a verification run of the operator,
          a one-shot output of the librarian, a summary, the vision tool or
          Fusion. *)

type refusal =
  | Not_published  (** The process has not published its access. *)
  | No_operator  (** An operator call in a multi-account process. *)
  | Not_a_keeper_id of string  (** The name of the Keeper is not an id of the log. *)
  | Turn_refused of Authz_keeper_turn.refusal
  | Not_the_assigned_runtime of
      { requested : string
      ; assigned : Authz_types.Runtime_id.t
      }  (** The turn runs on another Runtime than the one its owner gave the Keeper. *)
  | Not_active of Authz_types.User_id.t  (** The log has no active principal of this id. *)
  | No_membership of Authz_types.User_id.t
  | Home_unresolved of string  (** The home of the account could not be spelled. *)
  | Not_a_declared_home  (** The account was captured from an inherited home. *)
  | Not_the_account_home of Authz_types.Provider_account_id.t
      (** The account was captured from another home than the one of this
          account of the person. *)

val refusal_to_string : refusal -> string

(** Authorizes [sealed] for [request] by the access the process published. *)
val authorize : request -> 'client sealed -> ('client authorized, refusal) result
