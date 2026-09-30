(** Runtime configuration failure vocabulary and pure rendering.
    Loader validation constructs these values; transport and operator surfaces
    render them without inspecting message text or depending on loader effects. *)

type drop_reason =
  | Binding_disabled
  | Provider_disabled of string
  | Provider_not_declared of string
  | Model_not_declared of string
  | Execution_unbuildable of string
      (** Why a binding did not become a runtime. Closed so consumers decide per
          case instead of matching the rendered text: the [*_not_declared] pair
          is a dangling reference (an operator typo, fatal at
          {!Runtime.load_list}), while a disabled binding or provider is a choice the
          operator wrote down and [Execution_unbuildable] is an adapter
          capability limit — both non-fatal, per RFC-0206 §2.1. *)

val string_of_drop_reason : drop_reason -> string
(** Operator-facing rendering. Single source for the wording, so a reason read
    from a runtime message and one read from a load error cannot drift. *)

type reference_shape =
  | Scalar
  | List_entry
      (** How a reference names its id. A list entry reads as [field entry "id"]
          and a scalar as [field = "id"]; keeping both apart stops a message
          from telling an operator a list field equals one id. *)

type resolution_failure =
  { unresolved_id : string
  ; declared_drop : drop_reason option
  ; runtime_count : int
  }
(** Why an id did not resolve to a runtime. [reason] is the binding's own drop
    reason when one was declared under that id, [None] when nothing declared
    it. *)

type exact_slot_body_deadline_gap =
  { lane_id : string
  ; slot_id : string
  ; provider_id : string
  }
(** One [\[runtime.exact_output_lanes.<lane>\]] [slots] entry that names an
    HTTP runtime whose provider declares no [exact-body-timeout-s] (rule 3,
    #38779). Not collected under {!Runtime.Replacement_catalog_targets}. *)

type exact_slot_degradation =
  { gaps : exact_slot_body_deadline_gap list
  ; emptied_lane_ids : string list
        (** Lanes whose every slot is a gap and that declare no cli_slots.
            Each is unavailable on its own; the other lanes still publish. *)
  }

val exact_slot_body_deadline_gap_to_string : exact_slot_body_deadline_gap -> string
(** One line naming the lane table, the slot, the provider and the key to add. *)

type exact_lane_cli_slot_unservable_reason =
  | Not_an_official_client
      (** The runtime is dispatched over HTTP ([Agent_core]). *)
  | Client_without_output_schema
      (** An official client that cannot hold an answer to a JSON Schema
          ({!Runtime_schema.api_format_output_schema_channel}). *)

type exact_lane_cli_slot_unservable =
  { lane_id : string
  ; slot_id : string
  ; provider_id : string
  ; reason : exact_lane_cli_slot_unservable_reason
  }
(** One [\[runtime.exact_output_lanes.<lane>\]] [cli_slots] entry that names a
    configured runtime the CLI tail cannot call. Every lane's [cli_slots]
    dispatches through {!Keeper_lane_cli_oneshot.run} alone, which requires
    {!Runtime_execution.Official_client} and hands the client an output
    schema on every call; an id that resolves to nothing instead is
    {!Reference_unresolved}, not this. An official client with no schema
    channel is also refused when its runtime id appears in [slots];
    catalog-only [slots] ids remain catalog-owned. *)

type load_failure =
  | Toml_unparsable of Runtime_toml.parse_error list
  | Undeclared_bindings of (string * drop_reason) list
  | Default_runtime_absent
  | Default_runtime_unresolved of resolution_failure
  | Reference_unresolved of
      { site : string
      ; shape : reference_shape
      ; resolution : resolution_failure
      }
  | Lane_candidate_unresolved of
      { lane_id : string
      ; resolution : resolution_failure
      }
  | Max_context_absent of
      { runtime_id : string
      ; execution_model : string
      ; declared_model : string
      }
  | Exact_slot_body_deadlines_absent of exact_slot_body_deadline_gap list
      (** The exact-output slots a save would add on an HTTP provider that
          declares no [exact-body-timeout-s], compared with the file on disk.
          A gap the file already has does not refuse the save; a load keeps
          every gap as degraded state ({!exact_slot_degradation}) and the
          exact-output registry leaves those slots out. *)
  | Context_marks_exceed_max_context of
      { runtime_id : string
      ; high_water_tokens : int
      ; max_context : int
      }
  | Muse_window_below_host_overhead of
      { runtime_id : string
      ; max_context : int
      }
  | Exact_lane_cli_slot_unservable of exact_lane_cli_slot_unservable
      (** Why {!Runtime.load_list} refused a configuration. Closed, so a consumer
          decides per case instead of matching rendered text — the contract
          {!drop_reason} keeps one level down. [Toml_unparsable] is the one case
          whose text comes from the parser and can quote operator input; the
          rest name ids and config keys this repository authored. *)


val to_diagnostic_text : config_path:string -> load_failure -> string
(** The operator-facing account of a refused configuration, and the wording the
    CLI has always printed. A consumer that shows a failure to a person on a
    surface where parser text is unwelcome should match on the case instead. *)

val to_operator_text : config_path:string -> load_failure -> string
(** The same account with the parser's own text withheld: {!Toml_unparsable}
    renders as a count and a pointer at [masc runtime-probe], every other case
    identically to {!to_diagnostic_text}. *)


val dangling_reference_reason : drop_reason -> string option
(** [None] for disabled bindings/providers and adapter capability limits;
    [Some detail] for a provider or model reference that was never declared. *)

val resolution_of :
  dropped_bindings:(string * drop_reason) list -> runtime_count:int ->
  string -> resolution_failure

val exact_slot_body_deadline_gap_to_yojson :
  exact_slot_body_deadline_gap -> Yojson.Safe.t
