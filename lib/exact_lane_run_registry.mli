(** Admin-only durable observations of exact-output work, including original
    domain work executed through an Addon. Input/output values are exact.
    A logical lane identity does not select or enable a current executor. *)

(** A run's lane. Verifier reviews have separate Task and Goal registries;
    Browser Stagehand requests do not yet create retained run records. Both
    are excluded here, including on replay. *)
type lane =
  | Librarian
  | Hitl_auto_judge
  | Board_attention
  | Workspace_curator
  | Candle_appraiser

val run_lane : lane -> Lane_run_identity.t
(** Logical identity of the original observation, independent of its current
    executor or model configuration. *)

val lane_id : lane -> string
(** Wire/storage key of {!run_lane}. *)

val lane_of_standalone : Standalone_lane.t -> lane option
(** [None] for [Standalone_lane.Verifier] and
    [Standalone_lane.Browser_stagehand], whose runs this registry does not
    record. *)

val lane_of_run_lane : Lane_run_identity.t -> lane option
(** [None] for Verifier and Browser Stagehand. This registry's replay uses
    the observation vocabulary, not the set of currently configurable routes. *)

type outcome =
  | Succeeded
  | Cancelled
  | Failed of
      { code : string
      ; detail : string
      }

val server_restarted_code : string
(** The [Failed] code of a run the server found still running when it
    restarted and closed on replay. Replay does not know which slot the run
    had reached, so such a run names none. *)

type persistence_state =
  | Not_persisted
  | Durability_unknown

type persistence_failure =
  { detail : string
  ; state : persistence_state
  }

(** Token usage of one run's answering provider attempt, as the provider's
    own response parser reported it. [input_tokens] is the inclusive prompt
    total (it already counts the cache components); [cost_usd] is a
    provider-reported charge, [None] when the wire carried none. [None] on
    the status field means the run's transport reported no usage at all
    (CLI slot, vendor-system-one judging, or a body without a usage report). *)
type usage =
  { input_tokens : int
  ; output_tokens : int
  ; cache_creation_input_tokens : int
  ; cache_read_input_tokens : int
  ; cost_usd : float option
  }

val usage_of_api_usage : Agent_core.Types.api_usage -> usage

type completion_origin = Producer | Restart_replay
(** [Restart_replay] describes only the observation fiber lost at restart,
    never the original durable domain request or a producer terminal. *)

type run_status =
  | Running
  | Completed of
      { outcome : outcome
      ; origin : completion_origin
      ; elapsed_s : float option
          (** [None] means the original duration was not measured. *)
      ; output : Yojson.Safe.t
      ; selected_slot : string option
      ; usage : usage option
      }
  | Completion_persistence_failed of
      { intended_outcome : outcome
      ; elapsed_s : float option
          (** [None] means the original duration was not measured. *)
      ; output : Yojson.Safe.t
      ; selected_slot : string option
      ; usage : usage option
      ; failure : persistence_failure
      }

type run_input = Exact_input of Yojson.Safe.t

type payload_read_error =
  | Source_unavailable of string
  | Missing_registration
  | Missing_completion
  | Invalid_payload of string
      (** The run's payload file is not the size or SHA-256 its row recorded,
          or is not JSON. *)
  | Snapshot_changed

type payload_availability =
  | Available
  | Not_loaded
  | Unavailable of payload_read_error

val payload_read_error_to_string : payload_read_error -> string
val availability_to_yojson : payload_availability -> Yojson.Safe.t
val availability_of_yojson : Yojson.Safe.t -> (payload_availability, string) result
(** Availability is independent of payload content: JSON [null] is an available
    value. [Not_loaded] belongs to list projections, not a detail read. *)

type run =
  { run_id : string
  ; lane : lane
  ; actor : string
  ; started_at : float
  ; input : run_input
  ; status : run_status
  ; input_availability : payload_availability
  ; output_availability : payload_availability option
      (** [None] only while [Running]. Every terminal status states whether
          its output could be read, without changing the recorded outcome. *)
  }

type t

type completion_error =
  | Unknown_run
  | Invalid_selected_slot
  | Invalid_elapsed_duration
  | Persistence_failed of persistence_failure

val completion_error_to_string : completion_error -> string

(** Current-only durable registry with the closed [run_input] contract. The log
    row records a run's identity and outcome and the size and SHA-256 of its
    input and output; the values are in [<log dir>/<payload_dirname>/<run_id>/]
    [input-<sha256>.json] and [output-<sha256>.json]. *)
val storage_filename : string

val payload_dirname : string
(** Payload ownership is scoped to the same storage generation as the log.
    Replay cleanup never traverses a different generation's payload root. *)

val max_completed_retained : int
(** How many completed runs survive a replay, PER LANE. Running entries are
    kept regardless, so this bounds finished work only; the bound is applied
    within each lane so the busiest lane (librarian) cannot evict the
    quietest lane's history (compaction fires only on a capacity refusal —
    lane audit W8).

    Derived from the page size of the surface that reads this store rather than
    copied from the sibling registries, which retain 64 and have no paging UI.
    A test pins that relation. *)

val cut_replay_log : execute:bool -> string -> Run_registry_core.cut_report
(** Deployment-time store cut for {!storage_filename}. See
    {!Run_registry_core.Make.cut_replay_log}. *)

val create : ?path:string -> unit -> t
val replay : string -> t

val register_running
  :  t
  -> run_id:string
  -> lane:lane
  -> actor:string
  -> started_at:float
  -> input:run_input
  -> unit
(** Raises [Invalid_argument] when [run_id] is not one path segment. *)

val mark_completed
  :  t
  -> run_id:string
  -> outcome:outcome
  -> elapsed_s:float
  -> selected_slot:string option
  -> ?usage:usage
  -> output:Yojson.Safe.t
  -> unit
  -> (unit, completion_error) result
(** Record an observation-plane completion without taking ownership of the
    caller's primary lifecycle. Persistence failures are returned rather than
    raised. The durable core entry remains [Running], while [get]/[list_runs]
    expose [Completion_persistence_failed] with an explicit durability state;
    callers never silently present a terminal run as still executing. The
    completion has [origin=Producer] and [elapsed_s=Some elapsed_s]. A replay
    interruption has [origin=Restart_replay] and no measured duration. Unknown
    duration is never zero and must not enter latency or finish-time statistics.
    The labelled [selected_slot] argument forces every producer to state its lane
    attribution. It names the last bound HTTP attempt, or the successful CLI
    slot after HTTP exhaustion. Vendor System One runs before either and leaves
    it [None]; its provenance remains in [output]. Blank slot identities are
    rejected.

    [usage] is the answering attempt's provider-reported token counts; omit it
    when the run's transport produced none (CLI slot, vendor judging, missing
    wire report). Non-finite or negative measured duration is rejected. *)

val mark_completed_unmeasured
  :  t
  -> run_id:string
  -> outcome:outcome
  -> selected_slot:string option
  -> ?usage:usage
  -> output:Yojson.Safe.t
  -> unit
  -> (unit, completion_error) result
(** Record the actual producer terminal when its original duration was not
    measured, including a retained terminal recovered after restart. Records
    [Producer] and [elapsed_s=None]; observer/retry wall clocks cannot supply
    the missing duration. Persistence and slot validation match [mark_completed].
    This is an unconditional observation write, not durable reconciliation. *)

val list_runs : t -> run list

type original_completion = {
  outcome : outcome;
  elapsed_s : float option;
  output : Yojson.Safe.t;
  selected_slot : string option;
  usage : usage option;
}
type reconciliation_error =
  | Invalid_original of string
  | Original_registration_conflict
  | Original_completion_conflict
  | Failed_completion_conflict
  | Reconciliation_unavailable of string
  | Reconciliation_persistence_failed of persistence_failure
val reconciliation_error_to_string : reconciliation_error -> string
val reconcile_original :
  t -> run_id:string -> lane:lane -> actor:string -> started_at:float ->
  input:run_input -> completion:original_completion option ->
  (unit, reconciliation_error) result
(** Validate the complete original intent before publication. Strict current
    log observation, full owned payload verification and durability settlement,
    equality and conditional publication share the observation/core/file locks.
    Equal registrations and genuine producer terminals are confirmed without
    appending; conflicts and unavailable payloads never overwrite them. Only a
    typed [Restart_replay] completion may be corrected by the original producer
    terminal. Its former row remains in raw history until ordinary compaction;
    this API does not promise permanent superseded-restart audit retention.
    JSON null is a real payload, distinct from unavailable bytes. Conflicting
    diagnostic overlays remain visible and refuse confirmation. Matching overlays
    are cleared only after durable confirmation. Volatile/uninitialized or
    incomplete histories cannot confirm. A pending original may be republished
    at the same ID after genuine absence; already ACKed history must not call
    this API merely because it was later evicted. Success proves historical
    publication, including immediate ordinary retention eviction, not domain
    completion, execution permission or permanent list membership. No callback,
    worker, provider or domain operation runs here. *)

(** A page of retained runs, newest first. [total] counts every retained run so
    a caller can report "50 of 5,908" without asking for the rest. *)
type run_page =
  { runs : run list
  ; total : int
  ; has_more : bool
  }

(** At most [limit] runs strictly older than [before] in the (started_at
    descending, run_id descending) order. [before] is the caller's own
    (started_at, run_id) from the previous page, never server state: the server
    remembers nothing between calls, and the run_id tie-break means two runs
    recorded in the same float second cannot straddle a page boundary.

    Listing everything was what made this surface unusable — 5,908 runs
    serialized to 246 MB on every load, and again on every refresh event. *)
val recent_runs : t -> limit:int -> before:(float * string) option -> run_page
val get : t -> run_id:string -> run option
val status_label : run_status -> string
(** Identity and outcome without either exact payload. A lane run embeds the
    captured template and actual input material needed to reconstruct its
    rendered prompt, so a list that carried payloads shipped hundreds of
    megabytes to draw a table of timestamps. *)
val run_summary_to_yojson : run -> Yojson.Safe.t

(** The whole record, exact payloads included. For one run at a time. *)
val run_to_yojson : run -> Yojson.Safe.t

(** Called after a registry mutation is durable/in-memory-visible. The server
    installs a WS invalidation broadcaster; tests and library-only users keep
    the no-op default. *)
val change_observer_fn : (unit -> unit) Atomic.t

type global_install_error = Already_installed

val global : unit -> t
val install_global : t -> (unit, global_install_error) result
