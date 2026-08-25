(** Agent-core metrics collection — counters and histograms.

    Instance-based: each agent can maintain independent metrics.
    Follows OpenTelemetry semantic conventions for gen_ai metrics.

    Usage:
    {[
      let m = Metrics.create ()
      let tok = Metrics.counter m ~name:"gen_ai.client.token.usage" ~unit_:"token"
      Metrics.incr tok ~labels:[("gen_ai.token.type", "input")] 150
      Metrics.to_otlp_json m  (* export all collected metrics

    @stability Evolving
    @since 0.93.1 *)
    ]} *)

(** {1 Types} *)

(** Metrics instance. *)
type t

(** Monotonically increasing integer counter. *)
type counter

(** Distribution of float observations. *)
type histogram

(** {1 Construction} *)

val create : unit -> t

(** Register or retrieve a counter by name. *)
val counter : t -> name:string -> unit_:string -> counter

(** Register or retrieve a histogram by name. *)
val histogram : t -> name:string -> buckets:float list -> histogram

(** {1 Recording} *)

(** Increment a counter. *)
val incr : counter -> ?labels:(string * string) list -> int -> unit

(** Record an observation in a histogram. *)
val observe : histogram -> ?labels:(string * string) list -> float -> unit

(** {1 Export} *)

(** Export all metrics in OTLP JSON format. *)
val to_otlp_json : t -> Yojson.Safe.t

(** Export all metrics in Prometheus text exposition format.

    OTel-style metric and label names such as [gen_ai.client.token.usage]
    are normalized to Prometheus identifiers such as
    [gen_ai_client_token_usage]. *)
val to_prometheus_text : t -> string

(** {1 Inspection} *)

(** Read current counter value for given labels. *)
val counter_value : counter -> ?labels:(string * string) list -> unit -> int

(** Number of observations recorded.

    When [labels] is omitted, returns the total across all label series. *)
val histogram_count : ?labels:(string * string) list -> histogram -> int

(** Clear all recorded data. *)
val reset : t -> unit
