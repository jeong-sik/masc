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

type mergeable =
  | Mergeable
  | Conflicting
  | Mergeable_unknown
      (** GitHub has not computed mergeability yet (its [UNKNOWN]). *)

type pull_request =
  { repo_slug : string  (** [owner/repo] *)
  ; number : int
  ; title : string
  ; head_branch : string
  ; draft : bool
  ; checks : check_state
  ; review : review_state
  ; mergeable : mergeable
  ; author : string option
      (** The git author name of the most recent commit with one parent
          (RFC-0465 §2.1). A merge commit does not say who wrote the pull
          request, so it is skipped. [None] when the window holds no such
          commit, the pull request reports no commit, or GitHub gives the
          author or its name as [null]. *)
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
      (** GitHub's rate limit. With [Some t], GitHub's own time to wait
          until ([retry-after] from the moment of the answer, else
          [x-ratelimit-reset]), no
          request is sent before [t] and this failure stands until then. With
          [None] (GitHub sent no reset header, or curl older than 7.84 could
          not read it) there is no time to wait for that would be GitHub's
          rather than a number of ours, so the next refresh asks again at the
          normal 60 s pace. *)
  | Forbidden of { status : int }
      (** 403 with neither an exhausted rate limit nor [retry-after], e.g.
          organisation policy. *)
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
      (** The Keeper exists but no github.com token can be read for it on
          this host: its GitHub CLI holds none, its meta could not be read, or
          it is a Remote_ssh Keeper whose login lives on its endpoint
          ({!Keeper_github_login_lane.stored_token}). *)
  | Reader_ready of { keeper : string }

(** {1 Snapshot} *)

type keeper_names =
  | Keepers_not_listed  (** Before the first refresh. *)
  | Keepers_listed of string list
      (** The persisted Keeper names ({!Keeper_meta_store.keeper_names_result}),
          read once per refresh. *)
  | Keepers_list_failed of string
      (** The Keeper list could not be read, or reading it raised (the
          exception text). No pull request is then said to be a Keeper's or
          not, and the GitHub reads of the same refresh still publish. *)

type repository_entry =
  { repository_id : string
  ; url : string
  ; slug : string option  (** [owner/repo] when the remote is on github.com. *)
  ; pulls : repository_pulls
  }

type snapshot =
  { reader : reader
  ; repositories_error : string option
      (** The rows are from an earlier refresh, and why: the registered
          repository list could not be read, or the refresh raised. A
          sentence for the operator, not a code to match on. [None] after
          any refresh that read the list. *)
  ; repositories : repository_entry list
  ; keepers : keeper_names
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
  ; retry_after_s : int option
      (** GitHub's [retry-after] header in seconds. A 403 or 429 carrying it
          is a rate limit even while [x-ratelimit-remaining] is above 0
          (GitHub's secondary rate limit), and its wait is taken before
          [x-ratelimit-reset]. *)
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
  now:(unit -> float) -> http_post:http_post -> config:Workspace.config -> previous:snapshot -> snapshot
(** One full read: resolve the reader, load the registered repositories and
    read each GitHub one. The persisted Keeper names are listed once, first. A repository whose previous answer was
    [Token_rejected] for the same token, or [Rate_limited] with a reset time
    still ahead of [now], keeps that answer and is not fetched. When the
    reader is not ready, nothing is fetched and
    every GitHub repository reads [Pulls_not_read]: an earlier read is not
    shown as current. [previous] only stands in when the repository list
    itself cannot be read. *)

val keeper_of_author : keepers:string list -> pull_request -> string option
(** [Some author] when the author name read from the most recent single-parent
    commit is exactly one of [keepers] (case counts); [None] otherwise. A
    Keeper leaves the branch after opening a pull request, so the join is by
    who wrote the last commit, not by which checkout has the branch. The
    result is for display only and is not an identity for authority: any
    committer can set the author name. *)

val snapshot_to_yojson : snapshot -> Yojson.Safe.t
(** Each pull carries ["author"] and ["keeper"] (string or [null]) and
    ["mergeable"] ([mergeable] | [conflicting] | [unknown]). ["keeper"] is
    [null] unless the snapshot's ["keepers"] state is [listed]. *)

(** {1 Projection} *)

val current : unit -> snapshot
(** The latest refresh, or {!initial} before the first one ends. *)

val refresh_raised : previous:snapshot -> exn -> snapshot
(** What {!start} publishes when {!refresh} raises: [previous] with
    [repositories_error] saying so. *)

val start : sw:Eio.Switch.t -> clock:_ Eio.Time.clock -> config:Workspace.config -> unit
(** Forks the refresh loop under [sw]: one {!refresh} immediately, then one
    every 60 seconds. A refresh that raises publishes {!refresh_raised}.
    Cancelled with [sw]. *)
