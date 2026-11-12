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
    operator owns the account of a person, so an operator call is refused.
    Each request is judged on one snapshot that the zone could be trusted for
    ({!Authz_zone.read}); a zone whose files stopped or disagree refuses every
    request ({!Zone_uncertain}). *)

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
    owner, and Vibe reads the configuration of the host user. An API provider
    of the runtime table sends with the credential its operator declared, and
    so do the requests outside the table that {!host_client} names. A
    multi-account process shares no account of its host (plans D3b and D4),
    so only a single-user process starts them. *)

(** A client that starts on an account of the host. *)
type host_client =
  | Antigravity
  | Vibe
  | Api_provider
      (** An Agent_core Runtime of the runtime table: see {!api_sealed}. *)
  | Model_list
      (** A model-list or serving-window request of a setup connection, which
          sends with the credential its operator declared (plan D4b). *)
  | Files_api
      (** The provider Files API of the [masc_file_*] tools, called with
          [DEEPSEEK_API_KEY] (plan D4b). *)
  | Replacement_catalog
      (** The exact-output targets of the full replacement catalog
          [AGENT_CORE_MODEL_CATALOG] names, which carries its own providers
          and their credentials (plan D4b). *)
  | Web_search
      (** A provider of [masc_web_search] that needs a key: Brave, Tavily,
          Exa, Bing, Ollama or Z.AI (plan D4d). SearXNG needs none. *)
  | Systemone_cloud
      (** The cloud backend of the SystemOne tool, called with
          [OLLAMA_CLOUD_API_KEY] (plan D4d). The local backend needs none. *)
  | Voice_endpoint
      (** A voice endpoint whose adapter names a key variable, such as
          ElevenLabs (plan D4d). An endpoint that names none needs no key. *)

(** A start of a host client that the published access allows. Only
    {!authorize_host} makes one. *)
type host_account

(** The access of a process. *)
type t =
  | Single_user of Authz_boot_mode_read.single_user
      (** The boot judged the base path a single-user boot. After the accounts
          were turned off ({!Authz_boot_mode_read.turned_off}), their records
          stay read-only: {!authorize} refuses a run on their Keepers, their
          Runtimes and the homes of their persons. *)
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
      { owner : Authz_types.User_id.t
            (** Whose Keeper it is: the person the request was authenticated
                as. A Keeper is named by its owner and its id
                ({!Authz_keeper_state}). *)
      ; keeper_id : Authz_types.Keeper_id.t
      ; channel : Authz_types.Channel.t  (** What started the turn. *)
      ; pat : Authz_types.Pat_binding.t
            (** The personal access token that authenticated the request the
                turn answers: its scope narrows the turn
                ({!Authz_keeper_turn.decide}). [Not_pat] for a session and
                for a turn the server starts itself. *)
      ; runtime_id : string  (** The Runtime of the runtime table that runs the turn. *)
      }
      (** A turn of a person's Keeper, which the log records. *)
  | Operator_keeper_turn of
      { keeper_name : string  (** The name of its TOML. *)
      ; runtime_id : string  (** The Runtime of the runtime table that runs the turn. *)
      }
      (** A turn of a Keeper of the operator, which a TOML of the
          installation names and a lane of the server runs. It is no Keeper
          of the log, whatever its name (issue #51073): a single user runs
          it, after the accounts were turned off too unless its Runtime or
          its home is a person's, and a multi-account process runs none. *)
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
  | No_operator_keeper of string
      (** A turn of a Keeper of the operator, by its name, in a multi-account
          process. *)
  | Zone_uncertain of Authz_zone.uncertain
      (** A file of the authorization zone is stopped, or the files disagree
          ({!Authz_zone.read}): nothing is decided on its state, so no client
          starts for a person or for a turn. The text says which file it is
          and names no path ({!Authz_zone.uncertain_to_string}). *)
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
  | Off_keeper of Authz_types.Keeper_id.t
      (** A turn of a person's Keeper, after the accounts were turned off. *)
  | Off_runtime of Authz_types.Runtime_id.t
      (** A turn on a Runtime of the log, after the accounts were turned off. *)
  | Off_person_home
      (** A start on a home under the runtime roots of the persons
          ({!Runtime_account_home_layout.under_persons}), after the accounts
          were turned off. *)
  | Off_own_account of Authz_types.User_id.t
      (** A person's own account, after the accounts were turned off. *)

val refusal_to_string : refusal -> string

(** Authorizes [sealed] for [request] by the access the process published. *)
val authorize : request -> 'client sealed -> ('client authorized, refusal) result

(** Authorizes a Muse account for [request] by the access the process
    published, by the rule of {!authorize}. *)
val authorize_muse : request -> 'where muse_account -> ('where muse_authorized, refusal) result

(** Why the accounts of the host are not allowed. *)
type host_refusal =
  | Host_unpublished  (** The process has not published its access. *)
  | Host_not_shared  (** A multi-account process shares no account of its host. *)

(** Allows the accounts of the host in a single-user process. The decision
    does not depend on who asks or for which client: phase 1 shares them with
    nobody in a multi-account process. *)
val host_access : unit -> (host_account, host_refusal) result

(** {!host_access} for a start of [client]: a refusal is {!Not_published} or
    {!Host_account} naming [client]. *)
val authorize_host : host_client -> (host_account, refusal) result

(** {1 API providers}

    An Agent_core Runtime sends with the credential that the operator declared
    for its provider: in the declaration, an environment variable, the setup
    registry or a file of the host (plan D4). *)

(** The provider configuration of an Agent_core Runtime, its credential
    included. The runtime table holds this, so a reader of the table cannot
    send with the credential. *)
type api_sealed

val seal_api : Llm_provider.Provider_config.t -> api_sealed

(** The configuration without its credential: [api_key] and [headers] are
    empty. A reader takes the capabilities, the shape of a request and the
    endpoint from it. *)
val api_declaration : api_sealed -> Llm_provider.Provider_config.t

(** The configuration to send with, by {!authorize_host} [Api_provider]. *)
val authorize_api : api_sealed -> (Llm_provider.Provider_config.t, refusal) result

(** The binding identity of the configuration. It names the credential by a
    digest. *)
val api_binding_identity : api_sealed -> (Agent_core.Binding_identity.t, string) result

(** {!Llm_provider.Provider_admission.allowances_of_configs} of the
    configurations, with the endpoint identity a send of each one has. *)
val api_admission_allowances
  :  (string * api_sealed) list
  -> ( Llm_provider.Provider_admission.published_allowances
     , Llm_provider.Provider_admission.allowance_disagreement list )
     result

(** {!Llm_provider.Provider_admission.snapshot_for} the configuration. *)
val api_admission_snapshot : api_sealed -> Llm_provider.Slot_scheduler.snapshot option

(** {1 Native tools}

    An official CLI runs as the user of the server process, and its own tools
    (Claude Code's Read, Codex's read-only sandbox, Muse's built-in tools)
    reach what that user can read. In a multi-account process that includes
    the account homes of other people, with their login credentials. No
    measurement has shown yet that a native posture stays inside the turn's
    own files, so a multi-account process runs a model turn only without
    native tools (plan D3c). Codex and Muse cannot drop their native tools,
    so their model turns are refused there until a measurement opens a
    posture. A single-user process whose workspace keeps runtime roots of
    persons is in the same place for those roots (plan F3a-3). Calls that run
    no model turn (a login check, a usage read, a model list) take no native
    tools and are not judged here. *)

type native_refusal =
  | Native_unpublished  (** The process has not published its access. *)
  | Native_tools_reach_other_homes of Runtime_native_tools.posture
      (** A model turn with native tools in a multi-account process. *)
  | Native_tools_reach_person_homes of Runtime_native_tools.posture
      (** A model turn with native tools in a single-user process whose
          workspace keeps runtime roots of persons
          ({!Runtime_account_home_layout.persons_remain}). *)
  | Person_homes_unread of
      { posture : Runtime_native_tools.posture
      ; unread : Unix.error
      }
      (** A single-user process could not read whether such roots remain. *)

val native_refusal_to_string : native_refusal -> string

(** Whether a model turn may run with the native tools of [posture].
    {!Runtime_native_tools.Native_none} runs in either mode. The other
    postures run only in a single-user process whose workspace keeps no
    runtime root of a person: after the accounts were turned off, or after
    their log was removed, the logins of the persons stay under
    [.masc/accounts] until the operator removes that directory, and the
    native tools of a CLI could read them (plan F3a-3). Whether it is there is
    read at each call, and the client starts after the answer: a directory
    that appears between the two is seen by the next turn, not by this
    one. *)
val authorize_native : Runtime_native_tools.posture -> (unit, native_refusal) result

(** What the operator of a single-user workspace is told before any turn
    runs, from the answer of {!Runtime_account_home_layout.persons_remain}:
    [None] when no runtime root of a person remains, and otherwise that
    {!authorize_native} refuses the model turns with native tools, and what
    opens them again. [masc doctor] and the boot of the single-user server
    say it, so the state is known before a Keeper turn is refused. It reads
    nothing and judges no turn. *)
val person_homes_notice : (bool, Unix.error) result -> string option
