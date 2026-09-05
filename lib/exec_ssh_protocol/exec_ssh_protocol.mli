(** Protocol codec for the Phase 1 SSH remote execution lane.

    Single source of truth (SSOT) shared by the keeper-side SSH runner
    (encodes requests, parses trailers/probes) and the remote
    [masc-exec-shim] binary (parses requests, emits trailers/probes).
    Pure OCaml, no I/O — the module only transforms strings, so both
    sides can never drift on the wire format.

    Normative spec:
    docs/superpowers/specs/2026-08-27-openssh-microvm-exec-design.md §4.2
    ("Remote shim"). *)

(** {1 Error codes}

    Every [Error] string returned by this module starts with one of
    these snake_case codes, followed by [": "] and a human-readable
    detail.  Callers (Tasks 5/6) match on the code prefix:

    - ["remote_ssh_transport_error"] — malformed framing, unterminated
      JSON, base64 failure, length-prefix mismatch, [stdin_len]
      mismatch, absent or malformed trailer, trailer invariant
      violation.  A transport error means the peer's bytes could not be
      trusted; the caller MUST surface it as a transport failure and
      MUST NOT fabricate an exit code (never "exit 0").

    - ["remote_ssh_version_error"] — a request frame or trailer whose
      [v] field is no {!major} this build speaks, or a v2 frame that carries
      a [mode]. *)

(** {1 Protocol major}

    The shim and the server are deployed separately, so one release apart
    they still have to talk. Every major this build reads and writes is a
    constructor here: v2 is v3 without [mode] and means [Effect]. The newer
    side reads the other's probe ({!major_of_probe}) and frames requests in
    that major; a trailer echoes its request's. Closed: an integer that is
    no constructor is a version error, never a guess. Retiring v2 is
    deleting [V2]; the compiler then points at every arm that spoke it. *)
type major =
  | V2
  | V3

val newest : major
(** [V3]: what this build speaks when nothing has told it otherwise. *)

val majors : major list
(** [[V2; V3]], every constructor, for prose that lists them. *)

val int_of_major : major -> int
(** The [v] on the wire: [V2] → [2], [V3] → [3]. *)

val major_of_int : int -> major option
(** [None] for an integer this build does not speak. *)

val protocol_version : int
(** [int_of_major newest = 3]: the shim's own version major and the number
    the operator-facing skew messages name. v3 added [mode]. *)

(** {1 Execution mode (RFC-0422)}

    How the shim boxes the payload. [Effect] is unrestricted. [Observe]
    denies every filesystem write outside the shim's per-run scratch
    directory (Landlock) and every [socket(2)] (seccomp), so a payload that
    exits 0 has provably landed nothing anywhere. [Guest_local] denies only
    sockets: writes stay inside the box the payload runs in. Both boxes are
    applied by the shim to itself before exec, unprivileged under
    no_new_privs; a shim on a kernel without Landlock refuses them with
    [shim_error = "observe_unsupported: ..."] rather than running unboxed.
    The closed set on the wire is ["effect" | "observe" | "guest_local"]. *)
type mode =
  | Effect
  | Observe
  | Guest_local

val mode_to_string : mode -> string
val mode_of_string : string -> mode option

val observe_capability : string
(** The probe capability a shim advertises when it can run [Observe] and
    [Guest_local] here: ["observe"]. *)

val default_scratch_root : string
(** [/tmp]: where a shim makes a boxed request's scratch when its config
    names no [scratch_root]. Shared with the microvm boot, which mounts the
    guest's in-memory filesystem here, so the host never has to write the
    key into a config a shim one release behind would refuse as unknown. *)

(** {1 Request frame} *)

type request =
  { v : major
    (** a request is framed in the receiving shim's major; a trailer echoes
        its request's *)
  ; argv : string list  (** remote argv; each entry base64 on the wire *)
  ; env : (string * string) list
    (** environment overlay; names and values base64 on the wire *)
  ; cwd : string  (** remote working directory; base64 on the wire *)
  ; remote_root : string
    (** the jail this one call runs inside; base64 on the wire.

        The shim's own config states the widest root that host will ever
        allow, and this narrows it for this request. It is carried rather
        than read from the shim's config because one host runs endpoints for
        several Keepers, each with its own root, and a single global value
        makes every root but one read as an escape. Required, not optional:
        an absent jail has no safe reading, and the protocol version is
        matched exactly so there is no older client to keep working. *)
  ; timeout_sec : float
    (** payload wall-clock budget, enforced server-side by the shim *)
  ; stdin_len : int64
    (** declared byte length of the raw stdin payload *)
  ; mode : mode  (** how the shim boxes the payload; ["mode"] on the wire *)
  }

(** Wire layout (§4.2):

    {v
    [0        8              8+json_len            8+json_len+stdin_len]
    [ 8-byte  ][ request JSON ][        raw stdin bytes               ]
    [ BE  L   ]
    v}

    The 8-byte big-endian length L covers BOTH the request JSON and the
    raw stdin bytes: [L = json_len + stdin_len].  (The spec's
    "[len][JSON][stdin_len raw bytes]" layout; this file is the
    contract, and {!decode_request} agrees.)

    The request JSON is a compact object:
    {[
      { "v": 3,
        "argv": ["<base64>", "..."],
        "env": [["<base64 name>", "<base64 value>"]],
        "cwd": "<base64>",
        "remote_root": "<base64>",
        "timeout_sec": 300.0,
        "stdin_len": 0,
        "mode": "effect" }
    ]}

    Binary-suspect fields ([argv] entries, [env] names and values,
    [cwd]) are base64-encoded (RFC 4648, standard alphabet, WITH
    padding) INSIDE the JSON, so invalid UTF-8 and control bytes
    round-trip losslessly.  [stdin] is NOT base64: it travels as raw
    bytes after the JSON, delimited by the length prefix. *)

val encode_request : request -> stdin:string -> (string, string) result
(** [encode_request req ~stdin] renders one complete frame
    (length prefix + JSON + raw stdin).

    Fails with [remote_ssh_transport_error] when:
    - [req.timeout_sec] is not finite ([nan]/[infinity] do not survive
      JSON — caught here instead of raising);
    - [req.stdin_len] differs from the byte length of [stdin] — the
      caller inconsistency is rejected at the source rather than
      producing a frame the peer would reject as a truncated read. *)

val decode_request : string -> (request * string, string) result
(** [decode_request frame] parses exactly one frame: [frame] must be
    precisely [8 + L] bytes (trailing bytes are an error).  Returns the
    decoded {!request} and the raw stdin payload.

    Errors:
    - shorter than the 8-byte prefix, length-prefix mismatch,
      unterminated or invalid JSON, bad base64, missing/mistyped
      fields, negative [stdin_len], or declared [stdin_len] not equal
      to the number of bytes actually present after the JSON →
      [remote_ssh_transport_error];
    - non-finite [timeout_sec] on the wire (e.g. [1e999], [nan]) →
      [remote_ssh_transport_error] — a timer must never receive
      [infinity];
    - a [mode] outside the closed set → [remote_ssh_transport_error];
    - [v <> 3] → [remote_ssh_version_error].

    The [stdin_len] check happens BEFORE the payload is handed back, so
    a truncated frame can never be mistaken for a valid request.

    Duplicate JSON keys are first-wins ([List.assoc_opt]); benign, and
    identical on both peers since both use this module. *)

(** {1 Result trailer}

    The shim appends the result trailer after the payload's stderr,
    delimited by [\x1e] (RS, a control byte that cannot appear in valid
    UTF-8):

    {v
    \x1e{"masc_exec_result":{"v":3,"exit":0,"signal":null,
                             "timed_out":false,"shim_error":null}}\x1e
    v}

    This is how WEXITED vs WSIGNALED vs shim/transport errors stay
    distinct (ssh alone exits 255 for its own errors). *)

type trailer =
  { v : major
    (** a request is framed in the receiving shim's major; a trailer echoes
        its request's *)
  ; exit : int option  (** set iff the payload exited normally *)
  ; signal : int option  (** set iff the payload died on a signal *)
  ; timed_out : bool  (** true iff the shim killed the payload on
                          [timeout_sec] *)
  ; shim_error : string option  (** set iff the shim itself failed
                                    before/without running the payload *)
  }

val render_trailer : trailer -> string
(** [render_trailer t] is the exact [\x1e]-delimited byte string the
    shim appends to stderr.  Control bytes inside [shim_error] are
    JSON-escaped by the renderer, so no literal [\x1e] can appear
    between the delimiters. *)

val parse_trailer : string -> (trailer, string) result
(** [parse_trailer tail] extracts the trailer from the TAIL of a
    captured stderr stream.

    Last-match semantics: the payload may itself have emitted
    [\x1e]-delimited junk earlier in the stream (stderr is not
    guaranteed UTF-8), so ONLY the final [\x1e ... \x1e] pair in [tail]
    is considered; earlier pairs are never inspected, so an earlier
    malformed pair cannot poison a well-formed final trailer.

    Honest limit of that rule: a transport error is produced only when
    the surviving final pair is absent or malformed.  If the real
    trailer was cut by tail truncation and an EARLIER well-formed pair
    survives (e.g. the payload itself printed a forged
    ["masc_exec_result"] blob), that earlier pair is indistinguishable
    from a real trailer by construction and WILL be accepted.  Hence:

    CONTRACT NOTE — {!parse_trailer} output is authoritative ONLY when
    the ssh channel closed cleanly (full EOF on both streams observed).
    On any ssh-level failure (client exit 255, channel reset, dropped
    ControlMaster) the runner MUST classify the outcome as
    [remote_ssh_transport_error] itself, regardless of any trailer it
    managed to parse from the partial tail.

    Errors (all [remote_ssh_transport_error], or
    [remote_ssh_version_error] for [v <> 1]):
    - fewer than two [\x1e] bytes in [tail] (absent trailer);
    - the final pair is not valid JSON, lacks the ["masc_exec_result"]
      wrapper, or has missing/mistyped fields;
    - invariant violation: [exit], [signal] and [shim_error] are
      mutually exclusive (more than one set → malformed), and at least
      one of the three must be set unless [timed_out] is true (a
      trailer with no result information at all → malformed).

    Absent/malformed is NEVER mapped to a fabricated [exit 0]. *)

(** {1 Shim probe}

    [masc-exec-shim --probe] answers a plain JSON object
    [{"name":..., "version":..., "capabilities":[...]}].  The caller reads
    the shim's major with {!major_of_probe}: a spoken major is the version
    every request to that shim is framed in; one this build does not speak
    is the spec-level named error [remote_shim_version_skew] (fabricated by
    the caller — this module only supplies the reading). *)

type probe =
  { name : string  (** e.g. ["masc-exec-shim"] *)
  ; version : string  (** dotted semver, e.g. ["1.4.2"] *)
  ; capabilities : string list
  }

val render_probe : probe -> string
val parse_probe : string -> (probe, string) result
(** [parse_probe] fails with [remote_ssh_transport_error] on invalid
    JSON or missing/mistyped fields. *)

val shim_config_env_var : string
(** [= "MASC_EXEC_SHIM_CONFIG"]. The one environment entry the shim reads for
    itself: where its config file is, when not at the default
    [/etc/masc-exec-shim.conf]. A transport that cannot write [/etc] on the
    endpoint (an Apple [container] guest with a read-only root) sets it on the
    shim's own process; it is never part of the payload environment. *)

val major_of_probe : probe -> (major, string) result
(** The major this build will frame requests to the probed shim in: [Ok V2]
    for ["2.4.1"], [Ok V3] for ["3.0.0"]; [Error] naming both sides for a
    major this build does not speak or a version with no numeric major.
    Never raises. *)
