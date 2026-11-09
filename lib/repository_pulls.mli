(** The server's latest reading of the open pull requests of the registered
    GitHub repositories, as plain data (RFC-0465 §2-§4; RFC
    keeper-world-state-shows-open-work S1).

    The reader that fills it stays in [masc_server]
    ([Server_repository_pulls]: GraphQL, the reader Keeper's token, one refresh
    every 60 seconds). The data types, the JSON projection and the current
    value live here so that code in [masc], such as a Keeper tool, reads the
    same snapshot the HTTP route shows. Nothing here is persisted: GitHub is
    the source of these facts, so a restart starts at {!initial} and the next
    refresh replaces it. *)

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

type actor =
  | Actor_user of string  (** A GitHub user's login. *)
  | Actor_bot of string  (** A bot account's login. *)
  | Actor_other of
      { typename : string option
      ; login : string option
      }
      (** An actor type this reader does not name (an organization, a
          mannequin), with GitHub's [__typename] and login as sent.
          [typename] is [None] when the answer carried none. *)
  | Actor_absent  (** GitHub gave [null]: the account was deleted. *)

type review_verdict =
  | Verdict_approved
  | Verdict_changes_requested
  | Verdict_commented
  | Verdict_dismissed
  | Verdict_pending
  | Verdict_unrecognized of string
      (** A review state GitHub sent that this build does not know, as sent.
          It is shown, never branched on. *)

type latest_review =
  { reviewer : actor
  ; verdict : review_verdict
  ; commit_oid : string option
      (** The commit the review was submitted against; [None] when GitHub
          reports no commit for it. *)
  }
(** The last review one account left on a pull request (GitHub's
    [latestReviews]). *)

type latest_reviews =
  | Reviews_not_read
      (** The answer carried no readable review list. This is not "no
          reviews". *)
  | Reviews_read of
      { reviews : latest_review list
      ; truncated : bool
          (** GitHub holds more accounts than the page read
              ([pageInfo.hasNextPage]). *)
      }

type pull_request =
  { repo_slug : string  (** [owner/repo] *)
  ; number : int
  ; draft : bool
  ; checks : check_state
  ; review : review_state
  ; mergeable : mergeable
  ; author : string option
      (** The git author name of the newest commit with one parent among
          the pull request's latest commits (RFC-0465 §2.1): a merge commit
          is skipped because its author brought the base in. [None] when
          that window holds no such commit, or GitHub gives its author or
          name as [null]. *)
  ; title : string option  (** [None] when the answer carried no title. *)
  ; head_oid : string option
      (** The head commit's object id ([headRefOid]); [None] when the answer
          carried none. *)
  ; reviews : latest_reviews
  }

type head_review =
  | Reviewed_on_head
      (** The last review of some account is on the current head commit. *)
  | Not_reviewed_on_head
      (** The review list was read in full and none of it is on the head commit. *)
  | Review_history_incomplete
      (** The list was cut ([truncated]) and the part read has none on the head
          commit, so the part not read may. *)
  | Head_review_unknown  (** The head commit or the review list was not read. *)

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
      (** The remote is not one of the three spellings for the configured
          host that [Server_repository_pulls.github_slug_of_remote] reads; not read. *)

(** {1 Reader} *)

type reader =
  | Reader_not_declared
      (** runtime.toml declares no [\[repositories\] pr_reader]. *)
  | Reader_declaration_invalid of string
      (** runtime.toml is unreadable, [pr_reader] is not a Keeper name,
          [github_host] is not a bare hostname, [graphql_url] is not an
          [https://] URL, or a non-default [github_host] has no
          [graphql_url]. *)
  | Reader_keeper_missing of { keeper : string }
      (** No [keepers/<keeper>.toml] declares the named Keeper. *)
  | Reader_token_unavailable of
      { keeper : string
      ; reason : string
      }
      (** The Keeper exists but no token for the configured host can be
          read for it on this host: its GitHub CLI holds none, its meta could
          not be read, or it is a Remote_ssh Keeper whose login lives on its
          endpoint ({!Keeper_github_login_lane.stored_token}). *)
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
  ; slug : string option  (** [owner/repo] when the remote is on the configured host. *)
  ; pulls : repository_pulls
  }

type rejected_token =
  { token_digest : string  (** BLAKE256 hex of the token, never the token itself. *)
  ; graphql_url : string  (** The endpoint that refused it. *)
  }
(** The token GitHub last refused and where. The same token posted to another
    [graphql_url] has not been refused yet. *)

type snapshot =
  { reader : reader
  ; repositories_error : string option
      (** The rows are from an earlier refresh, and why: the registered
          repository list could not be read, or the refresh raised. A
          sentence for the operator, not a code to match on. [None] after
          any refresh that read the list. *)
  ; repositories : repository_entry list
  ; keepers : keeper_names
  ; rejected_token : rejected_token option
      (** The token GitHub last refused, and the endpoint that refused it.
          Not part of the JSON. *)
  }

val initial : snapshot
(** Before the first refresh: no reader resolved, no repository read. *)

val keeper_of_author : keepers:string list -> pull_request -> string option
(** [Some author] when the pull request's [author] (its newest single-parent
    commit's author name) is exactly one of [keepers] (case counts); [None]
    otherwise. A Keeper leaves the branch after opening a pull request, so the
    join is by who wrote the last commit, not by which checkout has the
    branch. The result is for display
    only and is not an identity for authority: any committer can set the
    author name. *)

val head_review_of : pull_request -> head_review
(** Whether some account's last review sits on the head commit. Only the
    review's commit and the head's object id are compared: who wrote the
    review, what it said and the pull request's comments do not count, and
    a review of an older commit does not either. *)

val failure_to_yojson : failure -> Yojson.Safe.t
(** [{"kind": ...}] plus the fields of that failure. The HTTP route and the
    Lane Add-on GitHub read report a failure this way. *)

val reader_to_yojson : reader -> Yojson.Safe.t
(** [{"state": ...}] plus the fields of that state. *)

val snapshot_to_yojson : snapshot -> Yojson.Safe.t
(** Each pull carries ["author"] and ["keeper"] (string or [null]) and
    ["mergeable"] ([mergeable] | [conflicting] | [unknown]). ["keeper"] is
    [null] unless the snapshot's ["keepers"] state is [listed]. *)

(** {1 Projection} *)

val publish : snapshot -> unit
(** Stores the snapshot a refresh ended with. Readers see it from their next
    {!current}. *)

val current : unit -> snapshot
(** The latest published snapshot, or {!initial} before the first one. *)
