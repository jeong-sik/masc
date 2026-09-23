(** Open pull requests of the registered GitHub repositories (RFC-0465 §2-§4).

    The server reads every repository registered in
    [.masc/config/repositories.toml] whose remote is on github.com, one
    GraphQL query per repository page, with the token of the Keeper named by
    runtime.toml [\[repositories\] pr_reader]. Nothing here is persisted:
    GitHub is the source of these facts, so a restart starts at
    [Pulls_not_read] and the next read replaces it.

    The reader is resolved again on every refresh. runtime.toml, the Keeper
    declaration and the Keeper's [github-cli/hosts.yml] token are all read at
    that moment and nothing is kept between refreshes, so a Keeper that logs
    in again or out is followed by the next read. When the reader cannot be
    used, no repository is read with any other credential. *)

(** {1 Pull request facts} *)

type check_state =
  | Checks_passing
  | Checks_failing
  | Checks_running
  | Checks_none
      (** The head commit has no status check rollup, or the pull request
          reported no commit. *)

type review_state =
  | Review_approved
  | Review_changes_requested
  | Review_waiting
  | Review_none
      (** GitHub reports no review decision: the base branch requires no
          review. *)

type pull_request =
  { repo_slug : string  (** [owner/repo] *)
  ; number : int
  ; title : string
  ; head_branch : string
  ; cross_repository : bool
      (** GitHub's [isCrossRepository]: the head branch is in a fork. *)
  ; draft : bool
  ; checks : check_state
  ; review : review_state
  ; updated_at : float
  }

type failure =
  | Repository_not_visible
      (** GitHub answered [NOT_FOUND] on the repository: the reader's account cannot see
          this repository (a private repository it has no access to, or a
          remote that no longer exists). *)
  | Token_rejected
      (** 401: the token was refused. hosts.yml is still read on every
          refresh, but GitHub is asked again only once it holds a different
          token; until then this failure stands with its first
          [observed_at]. *)
  | Rate_limited of { reset_at : float option }
      (** GitHub's rate limit. With [Some t], GitHub's own reset time, no
          request is sent before [t] and this failure stands until then. With
          [None] (GitHub sent no reset header, or curl older than 7.84 could
          not read it) there is no time to wait for that would be GitHub's
          rather than a number of ours, so the next refresh asks again at the
          normal 60 s pace. *)
  | Forbidden of { status : int }
      (** 403 without an exhausted rate limit, e.g. organisation policy. *)
  | Http_status of { status : int }
  | Graphql_errors of { messages : string list }
  | Transport_failed of string
  | Response_unreadable of string
      (** The body was not the GraphQL shape this reader asks for. *)

type repository_pulls =
  | Pulls_not_read  (** Not read since this server started. *)
  | Pulls_read of
      { observed_at : float
      ; pulls : pull_request list
      ; undecodable : int
          (** Pull request rows carrying a value this build does not know
              (a new GitHub enum member, a missing field). They are counted,
              never folded into [Checks_none] or [Review_none]. *)
      }
  | Pulls_failed of
      { observed_at : float
      ; failure : failure
      }
  | Pulls_not_github
      (** The remote is not one of the three github.com spellings
          {!github_slug_of_remote} reads; not read. *)

(** {1 Reader} *)

type reader =
  | Reader_not_declared
      (** runtime.toml declares no [\[repositories\] pr_reader]. *)
  | Reader_declaration_invalid of string
      (** runtime.toml is unreadable, or [pr_reader] is not a Keeper name. *)
  | Reader_keeper_missing of { keeper : string }
      (** No [keepers/<keeper>.toml] declares the named Keeper. *)
  | Reader_token_unavailable of
      { keeper : string
      ; reason : string
      }
      (** The Keeper exists but its GitHub CLI holds no github.com token. *)
  | Reader_ready of { keeper : string }

(** {1 Keepers on a pull request's branch (RFC-0465 §0.2)} *)

type keeper_checkouts_read =
  | Checkouts_read of Keeper_sandbox_control.checkout_scan
      (** A [scan_truncated] limit counts the Keeper as unread for every
          repository: checkouts past it were never seen. *)
  | Checkouts_absent
      (** The playground does not exist ([Root_missing]), e.g. a microvm guest
          not booted in this process. No checkout, so no branch and nothing
          unread. *)
  | Checkouts_unread of string
      (** The Keeper's metadata or playground could not be read, or its
          inspection raised: any of its checkouts may be on any branch. *)

type keeper_checkouts =
  { keeper : string
  ; checkouts : keeper_checkouts_read
  }

type fleet_checkouts = (keeper_checkouts list, string) result
(** Every Keeper's checkouts, or why the Keeper list could not be read. *)

type keeper_on_repository =
  { on_keeper : string
  ; branches : string list
      (** Branches of this Keeper's checkouts whose origin names this
          repository. *)
  ; unread : string list
      (** Why a checkout that may be of this repository has no branch: the
          Keeper's playground was not read or its discovery stopped early, a
          checkout's origin or the catalog was not read, or the branch probe
          failed. *)
  }

type repository_keepers =
  | Keepers_not_inspected
      (** The repository has no open pull request read, or no join has run
          since this server started. *)
  | Keepers_unlisted of
      { observed_at : float
      ; error : string  (** The Keeper list could not be read. *)
      }
  | Keepers_listed of
      { observed_at : float
      ; on_repository : keeper_on_repository list
          (** Only Keepers with a branch or an unread reason for this
              repository. *)
      }

type keeper_join =
  | Join_not_inspected
  | Join_keepers_unlisted of string
  | Join_read of
      { keepers : string list
          (** Keepers with a checkout of the repository on the pull
              request's head branch, compared with [String.equal]. Always
              empty for a pull request whose head is in another repository
              (a fork). *)
      ; keepers_unread : int
          (** Keepers not in [keepers] with a checkout that may be of this
              repository but whose branch is unknown. *)
      }

(** {1 Snapshot} *)

type repository_entry =
  { repository_id : string
  ; url : string
  ; slug : string option  (** [owner/repo] when the remote is on github.com. *)
  ; pulls : repository_pulls
  ; keepers : repository_keepers
  }

val pull_keepers : repository_entry -> pull_request -> keeper_join
(** The Keepers whose checkout of the entry's repository is on the pull
    request's head branch. *)

type snapshot =
  { reader : reader
  ; repositories_error : string option
      (** The registered repository list could not be read. *)
  ; repositories : repository_entry list
  ; rejected_token_digest : string option
      (** BLAKE256 hex of the token GitHub last refused, never the token
          itself. Not part of the JSON. *)
  }

val initial : snapshot
(** Before the first refresh: no reader resolved, no repository read. *)

(** {1 Transport} *)

type response =
  { status : int
  ; body : string
  ; rate_limit_remaining : int option
  ; rate_limit_reset : float option
      (** GitHub's [x-ratelimit-remaining] and [x-ratelimit-reset] headers. *)
  }

type http_post =
  url:string -> token:string -> body:Yojson.Safe.t -> (response, string) result
(** Injected transport. Production passes {!default_http_post}; tests pass a
    stub that answers from recorded bodies. *)

val default_http_post : http_post
(** curl through {!Process_eio}. The token goes to curl on stdin
    ([-H \@-]), never on the command line where other local users could read
    it from the process table. *)

(** {1 Reading} *)

val github_slug_of_remote : string -> string option
(** [owner/repo] for the three spellings git accepts for a github.com remote
    ([https://github.com/o/r(.git)], [git\@github.com:o/r(.git)],
    [ssh://git\@github.com/o/r(.git)]); [None] for anything else. *)

val read_repository :
  now:(unit -> float) -> http_post:http_post -> token:string -> string -> repository_pulls
(** [read_repository ~now ~http_post ~token slug] reads every open pull
    request of [slug], following the GraphQL cursor until GitHub reports no
    next page. *)

val refresh :
  now:(unit -> float) -> http_post:http_post -> base_path:string -> previous:snapshot -> snapshot
(** One full read: resolve the reader, load the registered repositories and
    read each GitHub one. A repository whose previous answer was
    [Token_rejected] for the same token, or [Rate_limited] with a reset time
    still ahead of [now], keeps that answer and is not fetched. When the
    reader is not ready, nothing is fetched and
    every GitHub repository reads [Pulls_not_read]: an earlier read is not
    shown as current. [previous] only stands in when the repository list
    itself cannot be read. Each repository keeps its previous [keepers]
    join, with that join's own [observed_at], until {!join_keepers}
    replaces it. *)

type inspect_checkouts =
  catalog:(Repo_manager_types.repository list, string) result -> fleet_checkouts

val join_keepers :
  now:(unit -> float) ->
  inspect_checkouts:inspect_checkouts ->
  base_path:string ->
  snapshot ->
  snapshot
(** Join every repository with open pull requests to the Keepers' checkouts.
    The catalog is loaded once and [inspect_checkouts] runs once, and neither
    runs when no repository has an open pull request read. A repository
    without one reads [Keepers_not_inspected]. *)

val snapshot_to_yojson : snapshot -> Yojson.Safe.t

(** {1 Projection} *)

val current : unit -> snapshot
(** The latest refresh, or {!initial} before the first one ends. *)

val checkouts_of_scan :
  (Keeper_sandbox_control.checkout_scan, Keeper_playground_checkouts.scan_error) result ->
  keeper_checkouts_read
(** [Root_missing] is {!Checkouts_absent}; every other scan error is
    {!Checkouts_unread} with its text. *)

val inspect_fleet_checkouts : config:Workspace.config -> inspect_checkouts
(** {!Keeper_sandbox_control.checkout_scan} for every persisted Keeper,
    against the one [catalog]. A shared-mount Keeper costs up to six git calls
    per checkout (origin, branch, HEAD, status, and for a registered checkout
    the upstream ref and ahead/behind), all within that Keeper's 5 s
    inspection budget; an endpoint-owned Keeper costs one remote probe. *)

val start : sw:Eio.Switch.t -> clock:_ Eio.Time.clock -> config:Workspace.config -> unit
(** Forks the refresh loop under [sw]: every 60 seconds, starting now, one
    {!refresh} is published as soon as GitHub has answered, then
    {!join_keepers} with {!inspect_fleet_checkouts} is published over it. A
    slow or failing fleet inspection never delays or discards the pull
    requests. Cancelled with [sw]. *)
