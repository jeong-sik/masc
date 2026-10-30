(** Exact-message occurrence state for [Keeper_registry.record_error].

    Free-form diagnostics are never classified here. Typed producers own error
    categories; this leaf only counts identical [(keeper, error)] pairs for
    observability. Every occurrence remains logged by the caller. *)

type record_outcome =
  [ `First
  | `Repeated of int
  ]

(** Record an exact [(keeper, error)] occurrence. Different Keepers or
    different diagnostic strings are independent. *)
val record : keeper:string -> error:string -> record_outcome

(** Reset internal state for isolated tests. *)
val reset_for_test : unit -> unit

(** Number of distinct exact [(keeper, error)] fingerprints. *)
val cardinality : unit -> int
