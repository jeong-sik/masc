(** Keeper_memory_recall_exn_class — closed sum for the [exception_class]
    label on [metric_keeper_memory_bank_load_history_swallowed_exceptions].

    Bounds the Prometheus label cardinality of the swallowed-exception
    counter emitted from [Keeper_memory_recall.load_history_user_messages].

    The previous implementation (PR #15781) passed [Printexc.to_string exn]
    directly as the label value. That string carries exception-specific
    detail (byte offsets, file paths, payload fragments from
    [Yojson.Json_error]; per-syscall context from [Unix.Unix_error]; raw
    [Failure] messages) so each distinct exception instance created a new
    Prometheus time-series. Codex P1 flagged this as unbounded label
    cardinality / balloonable in-process metric memory.

    [classify] is a *constructor-level* pattern match on the OCaml [exn]
    type, not a substring scan on [Printexc.to_string] output, so adding
    a new mapping is type-checked, not text-heuristic. The full error
    string is still emitted to the log line; only the *label* is bounded.
*)

type t =
  | Yojson_parse_error
      (** Matches [Yojson.Json_error _] — malformed JSON syntax in a
          history.jsonl line. *)
  | Io_error
      (** Matches [Sys_error _] and [Unix.Unix_error _] — filesystem
          / OS-level read failures. *)
  | Type_error
      (** Matches [Failure _] (raised by [to_string_option] / similar
          conversion helpers) and [Yojson.Safe.Util.Type_error _]
          (raised by [member]/[to_string] when the JSON shape is
          wrong). *)
  | Other
      (** Terminal bucket — any exception not covered by the above
          variants. Bounded by construction (single value). *)

val classify : exn -> t
(** Map an OCaml exception to its closed classification. The match
    discriminates on the [exn] constructor; no string sniffing. *)

val to_label : t -> string
(** Render the classification as the wire label value used by
    Prometheus. Returns one of the lowercase strings
    {[ "yojson_parse_error" ]}, {[ "io_error" ]}, {[ "type_error" ]},
    {[ "other" ]}. *)
