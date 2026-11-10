(* HIGH-RISK-UNREVIEWED: this module decides whether a CLI may start on an
   official account. A wrong answer starts a CLI on the subscription of
   another person. Read it against plan D2. *)

(** Whether a CLI may start on an official account (multi-account plan D2,
    and D3 for Muse and the host clients).

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

(** An account captured from a declaration. No CLI starts on it, and it
    gives no environment: the runtime table holds this, so a reader of the
    table cannot take the credentials of an account. *)
type 'client sealed

val seal : 'client Runtime_official_account.t -> 'client sealed

(** The home of a sealed account. It names the account, as its quota window
    does, and carries no credential. *)
val home : 'client sealed -> string

(** Whether two sealed accounts are the same capture, for a reload of the
    table. It renders no credential. *)
val same : 'client sealed -> 'client sealed -> bool

(** An account a CLI may start on. Only {!authorize} makes one. *)
type 'client authorized

(** The account, for the client that starts the CLI. *)
val account : 'client authorized -> 'client Runtime_official_account.t

(** {1 Muse}

    Muse keeps its login in a home of its own, as Codex and Claude Code do,
    and its client builds the environment of the process from that home when
    the process starts. So a Muse account is its home alone, and
    {!authorize_muse} judges it as {!authorize} judges a captured account. *)

(** A declared Muse home. No Muse process starts on it: the runtime table
    holds this. *)
type muse_home

(** Parses a declared home as {!Runtime_account_home.of_string} does. *)
val declare_muse_home : string -> (muse_home, string) result

(** The path of a declared home. It names the account, as its quota window
    does, and carries no credential. *)
val muse_home_path : muse_home -> string

(** Where a Muse account is: a declared home, or the environment of the
    process. *)
type declared
type process_environment

(** What a Muse process starts on. *)
type _ muse_account =
  | Declared_home : muse_home -> declared muse_account
  | Process_environment : process_environment muse_account
      (** The home the environment of the process names, which protocol
          fixtures use. A multi-account process refuses it, as it refuses an
          inherited home of Codex and Claude Code. *)

(** A Muse account a process may start on. Only {!authorize_muse} makes one. *)
type 'where muse_authorized

(** The home the Muse process starts on, for its client: the declared path,
    or [None] for {!Process_environment}. *)
val muse_account_home : _ muse_authorized -> string option

(** The declared home, for a caller that prepares it before the call. *)
val declared_muse_home : declared muse_authorized -> string

(** {1 Host accounts}

    Antigravity and Vibe start on accounts of the host, not of a person. The
    credential of Antigravity is a copy in the setup registry, which has no
    owner, and Vibe reads the configuration of the host user. A
    multi-account process shares no account of its host (plan D3b), so only
    a single-user process starts them. *)

(** A client that starts on an account of the host. *)
type host_client =
  | Antigravity
  | Vibe

(** A start of a host client that the published access allows. Only
    {!authorize_host} makes one. *)
type host_account

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
  | Not_a_declared_home
      (** The account was captured from an inherited home, or a Muse process
          would start on the environment of the process. *)
  | Not_the_account_home of Authz_types.Provider_account_id.t
      (** The account was captured from another home than the one of this
          account of the person. *)
  | Host_account of host_client
      (** A host client in a multi-account process, which shares no account
          of its host. *)

val refusal_to_string : refusal -> string

(** Authorizes [sealed] for [request] by the access the process published. *)
val authorize : request -> 'client sealed -> ('client authorized, refusal) result

(** Authorizes a Muse account for [request] by the access the process
    published, by the rule of {!authorize}. *)
val authorize_muse : request -> 'where muse_account -> ('where muse_authorized, refusal) result

(** Allows a start of a host client in a single-user process, and refuses it
    in a multi-account process with {!Host_account}. *)
val authorize_host : host_client -> (host_account, refusal) result

(** {1 Native tools}

    An official CLI runs as the user of the server process, and its own tools
    (Claude Code's Read, Codex's read-only sandbox, Muse's built-in tools)
    reach what that user can read. In a multi-account process that includes
    the account homes of other people, with their login credentials. No
    measurement has shown yet that a native posture stays inside the turn's
    own files, so a multi-account process runs a model turn only without
    native tools (plan D3c). Codex and Muse cannot drop their native tools,
    so their model turns are refused there until a measurement opens a
    posture. Calls that run no model turn (a login check, a usage read, a
    model list) take no native tools and are not judged here. *)

type native_refusal =
  | Native_unpublished  (** The process has not published its access. *)
  | Native_tools_reach_other_homes of Runtime_native_tools.posture
      (** A model turn with native tools in a multi-account process. *)

val native_refusal_to_string : native_refusal -> string

(** Whether a model turn may run with the native tools of [posture]: every
    posture in a single-user process, and only
    {!Runtime_native_tools.Native_none} in a multi-account process. *)
val authorize_native : Runtime_native_tools.posture -> (unit, native_refusal) result
