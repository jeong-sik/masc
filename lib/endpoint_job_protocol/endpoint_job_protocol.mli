(** Control messages for endpoint-owned asynchronous workspace processes and
    isolated jobs. This protocol is separate from synchronous exec framing:
    control EOF never supplies cancellation authority. Its codec performs no
    filesystem, process, signalling, network or admission effects.

    A future endpoint service must authenticate its peer, bind these untrusted
    lookup keys to the original protected registry, and run payloads across an
    actual supervisor/control-storage authority boundary. A same-UID private
    directory is insufficient. No shim advertises support merely because this
    library is present. *)

val capability : string
(** Advertise only after the endpoint has a configured, functioning protected
    supervisor and registry implementing this exact protocol. *)

module Id : sig
  type t = private string
  val of_string : string -> (t, string) result
  val to_string : t -> string
end
(** Canonical lowercase UUIDs, not authorization tokens. *)

module Sha256 : sig
  type t = private string
  val of_string : string -> (t, string) result
  val to_string : t -> string
end

type backend = Apple_container | Microsandbox | Nerdctl_kata | Remote_ssh

type route =
  { backend : backend
  ; endpoint_incarnation : Id.t
  ; boot_id : Id.t
  }
(** Freeze the actual endpoint incarnation and boot, never just a mutable
    endpoint name. PID, process-group and host paths are absent from controls. *)

type owner = { workspace_id : Id.t; keeper_name : string }

type isolated_preparation =
  { preparation_id : Id.t
  ; image_sha256 : Sha256.t
  ; input_manifest_sha256 : Sha256.t
  }

type domain = Workspace_process | Isolated_job of isolated_preparation
(** An isolated launch must resolve its original protected preparation and
    verify its immutable image/input manifest plus private mounts, identity,
    credentials and network. The preparation ID and digests are lookup pins,
    never authority to treat the ordinary Keeper workspace as isolated. *)

type spec = private
  { domain : domain
  ; argv : string list
  ; env : (string * string) list
  ; cwd : string
  ; remote_root : string
  ; stdin : string
  ; mode : Exec_ssh_protocol.mode
  ; network_policy_sha256 : Sha256.t option
  }
(** Exact byte strings survive through Base64. [None] means no extra network
    policy identity is carried; it does not grant network access. The service
    must apply the original authorized route/mode/policy and path jail. *)

val spec :
  domain:domain -> argv:string list -> env:(string * string) list ->
  cwd:string -> remote_root:string -> stdin:string ->
  mode:Exec_ssh_protocol.mode -> network_policy_sha256:Sha256.t option ->
  (spec, string) result
(** No empty argv/program, NUL in exec strings, relative cwd/root or duplicate
    environment names. Environment names obey exec's NAME grammar. Values retain non-NUL bytes; stdin retains arbitrary bytes. This is structural validation, not command,
    Gate, sandbox, credential or filesystem authority. *)

val spec_sha256 : spec -> Sha256.t
(** Domain-separated digest of the complete canonical launch specification,
    including environment order, stdin, execution domain and network identity. *)

type binding = private
  { route : route
  ; owner : owner
  ; operation_id : Id.t
  ; invocation_sha256 : Sha256.t
  ; spec_sha256 : Sha256.t
  }

val binding :
  route:route -> owner:owner -> operation_id:Id.t ->
  invocation_sha256:Sha256.t -> spec_sha256:Sha256.t ->
  (binding, string) result
(** [invocation_sha256] binds the originating call/source on the trusted host;
    [spec_sha256] independently binds the complete endpoint payload. Neither
    hash authenticates a peer or grants ownership. No live config retargeting. *)

type stream = Stdout | Stderr

type original = private { binding : binding; admission_id : Id.t }
val original : binding:binding -> admission_id:Id.t -> original
(** A confirmed protected admission coordinate, not a peer credential or launch
    permission. The service still loads/verifies the immutable original record. *)

type request =
  | Start of { binding : binding; spec : spec }
  | Reconcile_admission of binding
  | Activate of original
  | Inspect of original
  | Read_output of { original : original; stream : stream; offset : int64; max_bytes : int }
  | Cancel of original
  | Release of { original : original; result_sha256 : Sha256.t }
(** Start only registers original bytes; it never activates a child. A lost
    registration reply may reconcile that binding before activation intent.
    Admitted must be durably recorded on the host before Activate. Once the
    host has confirmed an admission, every subsequent control carries that
    same admission ID; missing original authority never permits a fresh Start.
    Duplicate Activate reconciles its original launch rendezvous, never mints
    another launch permit. These are controller-internal steps, not user asks.

    Cancel commits intent before signalling and resolves only the confirmed
    original protected process/cgroup handle. An operation ID or PID alone
    never authorizes kill. Release requires durable host result consumption
    and the exact terminal result digest, not a generic deletion request. *)

type exit_status = Exited of int | Signaled of int

type non_start = Cancelled_before_activation | Launch_rejected
(** The protected supervisor must prove that the original payload cannot run:
    a confirmed cancellation won before activation and the original gate is
    settled, or preparation/exec was authoritatively rejected. A cancellation
    request, controller EOF, activation request, missing record or bootstrap
    exit code alone is insufficient. Uncertain original authority stays Held. *)

type phase =
  | Queued | Starting | Running
  | Finished of exit_status
  | Not_started of non_start
  | Termination_observed of exit_status
(** Not_started is terminal without inventing a payload exit status. Bootstrap
    exits are not classified as Finished just from their physical exit code.
    Termination_observed records the exact original main reaped and recursive
    tree empty, while leaving payload execution and effects uncertain. Gate
    activation/control EOF cannot establish exec. This is neither success nor
    failure/retry permission, and may retain nonempty original output.
    Its protected terminal receipt must preserve raw gate boundary, original
    admission/launch and cancellation intent before result readiness.
    Not_started carries no payload output; its streams may still await durable
    empty sealing and result-manifest publication. Cancelled_before_activation
    requires the corresponding cancellation intent to remain visible. *)

type extent =
  | Growing of int64
  | Sealed of { byte_length : int64; sha256 : Sha256.t }
(** Sealed means the original stream reached EOF and its complete bytes and
    digest were durably retained, never a bounded stdout/stderr preview. *)

type refusal =
  | Unsupported
  | Unauthenticated
  | Owner_mismatch
  | Request_conflict
  | Endpoint_replaced
  | Admission_refused
  | Release_refused

type hold =
  | Registry_unavailable
  | Supervisor_unavailable
  | Operation_not_found
  | Output_unavailable of stream
(** A hold preserves the caller's last confirmed state and original intent.
    Missing/unavailable authority never means absence, pre-effect refusal,
    completion, cancellation or permission to launch another process. *)

type result_availability = Result_pending | Result_ready of Sha256.t
(** Ready names the protected complete terminal result manifest required by
    Release. It requires a Finished, proven Not_started or Termination_observed
    terminal receipt and both durably sealed streams;
    even that combination may remain pending until manifest publication. *)

type response =
  | Admitted of { original : original; revision : int64 }
  | Status of
      { original : original; revision : int64; phase : phase; cancel_requested : bool; result : result_availability
      ; stdout : extent; stderr : extent }
  | Output of { original : original; revision : int64; stream : stream; offset : int64; data : string; extent : extent }
  | Released of { original : original; revision : int64; result_sha256 : Sha256.t }
  | Refused of { binding : binding; reason : refusal }
  | Held of { binding : binding; reason : hold }
(** Admitted identifies a complete durable original registration, not process
    activation or execution. Positive controls/results carry that same original
    admission. Refused/Held carry no state and cannot advance it.
    Status is observation, not Task/Goal verification or source ACK. A terminal
    operation with Growing streams is not a complete result. Refused/held messages
    contain typed facts, never payload prose interpreted as control. *)

type codec_error =
  | Missing_field of string
  | Duplicate_field of string
  | Unexpected_field of string
  | Invalid_field of string
  | Version_unsupported
  | Tag_unsupported of string
  | Spec_digest_mismatch
  | Binding_mismatch
  | Original_admission_mismatch
  | Response_kind_mismatch
  | Output_range_mismatch
  | Output_digest_mismatch
  | Response_revision_stale

val error_to_string : codec_error -> string
(** Diagnostics identify the schema field, never command/env/stdin bytes. *)

val request_to_json : request -> (Yojson.Safe.t, codec_error) result
val request_of_json : Yojson.Safe.t -> (request, codec_error) result
val response_to_json : response -> (Yojson.Safe.t, codec_error) result
val response_of_json : Yojson.Safe.t -> (response, codec_error) result
(** Closed v1 envelopes; required nullable fields stay required. Unknown,
    duplicate and missing fields at every object level fail, including fields
    from a different operation. Offsets/lengths are canonical decimal strings
    to preserve int64 identity through JSON implementations. No silent defaults. *)

val check_response : minimum_revision:int64 -> request:request -> response -> (unit, codec_error) result
(** Bind a decoded response to the complete original request/route/owner/call
    and, after registration, the exact confirmed admission ID. Start and
    Reconcile_admission accept only Admitted (or a typed refusal/hold);
    Activate/Inspect/Cancel accept only Status for the confirmed admission.
    Output additionally matches the exact stream/offset and requested capacity;
    release matches the original terminal result digest. Revisions never go
    below the host's last accepted protected snapshot; holds/refusals carry no
    state and do not advance it. This is validation of
    a peer's claim; only the authenticated protected supervisor is authority. *)
