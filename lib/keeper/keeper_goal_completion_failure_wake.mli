(** Durable owner-lane wake for a failed semantic Goal-completion review.

    Ownership is resolved only from current Keeper metadata:
    [active_goal_ids] containing the Goal id. The producer durably enqueues a
    typed event before issuing a best-effort live wake hint. Unregistered,
    offline, or paused owners therefore retain the event for restart/resume.

    Metadata and queue-storage failures are returned explicitly. They are not
    collapsed into "unowned", because doing so would silently lose a possible
    owner. *)

type projection =
  { owner_names : string list
  ; enqueued_owner_names : string list
  ; already_present_owner_names : string list
  ; observed_owner_names : string list
  ; signaled_owner_names : string list
  ; deferred_owner_names : string list
  }

type failure =
  | Invalid_goal_state of string
  | Owner_discovery_failed of (string * string) list
  | Delivery_failed of (string * string) list
  | Owner_discovery_and_delivery_failed of
      { metadata_errors : (string * string) list
      ; delivery_errors : (string * string) list
      }

type outcome =
  | Projected of projection
  | Unowned
  | Incomplete of
      { projection : projection
      ; failure : failure
      }

val goal_review_fingerprint : Goal_store.goal -> string
(** SHA-256 of the exact typed durable review outcome. Used only as durable
    occurrence identity; never for policy or routing. *)

val project :
  config:Workspace.config ->
  goal:Goal_store.goal ->
  failure:Goal_store.completion_review_failure ->
  outcome

val failure_to_string : failure -> string

type reconciliation_report =
  { examined : int
  ; projected : int
  ; unowned : string list
  ; incomplete : (string * failure) list
  }

val reconcile_all : config:Workspace.config -> reconciliation_report
(** Re-project every durable nonterminal completion-review failure. Exact
    terminal reaction-ledger evidence prevents a settled occurrence from being
    re-delivered; pending/leased occurrences deduplicate in the event queue. *)
