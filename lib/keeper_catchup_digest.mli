(** Keeper_catchup_digest — deterministic "since last seen" activity digest.

    Aggregates what happened to one keeper since an operator's per-keeper
    last-seen cursor, reading only existing durable stores with a
    [ts > since] filter. No LLM summarisation and no heuristics — the digest
    is pure since-windowed counts over the chat / turn / task / board /
    lifecycle stores. Design SSOT: [docs/design/keeper-catchup-digest.md].

    Fail-visible reads: every store-read failure that is not a missing
    directory (a missing store is zero activity, not an error) surfaces in
    [read_errors] rather than being silently dropped. [items] arrays are
    capped at {!digest_items_cap}, newest-first; the count fields are the
    full counts, independent of the cap. All timestamps in the output are
    unix seconds — the sources mix ISO and unix stamps and the digest
    normalises to unix. *)

val digest_items_cap : int
(** Upper bound on each [items] array ([tasks], [lifecycle]). The sibling
    count fields stay full counts, independent of this cap. *)

type task_item =
  { task_id : string
  ; transition : string
  ; ts : float
  }

type lifecycle_item =
  { kind : string
  ; ts : float
  }

type chat =
  { new_messages : int
  ; first_new_ts : float option
  ; transport_failures : int
  }

type turns =
  { completed : int
  ; failed : int
  ; crashes : int
  }

type tasks =
  { claimed : int
  ; done_ : int
  ; released : int
  ; cancelled : int
  ; items : task_item list
  }

type board =
  { posted : int
  ; commented : int
  ; voted : int
  }

type lifecycle =
  { paused_now : bool
  ; pause_events : int
  ; resume_events : int
  ; items : lifecycle_item list
  }

type t =
  { keeper : string
  ; since_unix : float
  ; generated_at_unix : float
  ; chat : chat
  ; turns : turns
  ; tasks : tasks
  ; board : board
  ; lifecycle : lifecycle
  ; read_errors : string list
  }

val to_json : t -> Yojson.Safe.t
(** Wire encoding matching the design contract v1.  [chat.first_new_ts]
    renders as [null] when there is no new message. *)

val build :
  base_path:string ->
  keeper_name:string ->
  since_unix:float ->
  now_unix:float ->
  t
(** [build ~base_path ~keeper_name ~since_unix ~now_unix] aggregates the
    since-windowed digest for [keeper_name] from the stores rooted under
    [base_path] (default-cluster layout: [<base_path>/.masc/...]).

    Sources (all filtered to activity strictly after [since_unix]):
    - [chat]: [Keeper_chat_store] paged backward from the tail; utterances
      count as [new_messages], [Row_kind.Transport_failure] rows as
      [transport_failures].
    - [turns.completed]: keeper-local [turn-records] day-files.
    - [turns.failed]: activity-events [keeper.turn_failed] for the keeper.
    - [turns.crashes]: [Keeper_crash_persistence] recent crash events.
    - [tasks]: [Audit_log] task-transition entries whose [agent_id] resolves
      to the keeper via {!Tool_agent_timeline.identity_matches}.
    - [board]: activity-events [board.posted]/[board.commented]/[board.voted]
      whose actor resolves to the keeper.
    - [lifecycle]: durable transition-audit [operator_pause]/[operator_resume]
      records, plus [paused_now] from the keeper meta.

    Look-back is clamped to the JSONL retention window; beyond it the counts
    are a lower bound and the echoed [since_unix] lets the client detect it.
    Failures and bounded scans that stop before [since_unix] append to
    [read_errors]; a missing store is zero, not a failure. *)
