(** [masc_keeper_delegate_targets]: the chat queue and live turn of the Keepers
    a caller may choose between before it calls [masc_keeper_delegate].

    A queued operation starts after the target's current turn ends and after
    the operations queued ahead of it. The submit result reports both only
    after the work is queued; this reads them for several named Keepers first.
    Every field is a fact at the instant of the read. Which Keeper takes the
    work stays with the caller. *)

(** Why a Keeper has no row of facts. *)
type unavailable =
  | Unknown_keeper
  (** The owner inventory holds no Keeper by this name. *)
  | Owner_unavailable
  (** The owner exists or is expected but is not serving reads: still
      initializing, failed to initialize, or the inventory is stopping. *)
  | Store_unavailable
  (** The owner answered, and its operation store could not be read. *)

(** What the Keeper registry says about the Keeper's turn. *)
type presence =
  | Not_registered
  (** The registry holds no entry, so no turn starts until it does. *)
  | Between_turns
  | In_turn of { age_s : int }
  (** Whole seconds the live turn has run. *)

type queue =
  { queued_count : int
  (** Operations waiting. The running turn is not counted. *)
  ; oldest_queued_age_s : int option
  (** Whole seconds the longest-waiting operation has waited; [None] while
      nothing is queued. *)
  }

type row =
  | Available of { name : string; presence : presence; queue : queue }
  | Unavailable of { name : string; reason : unavailable }

(** Whole seconds from [since] to [now], never negative: a clock behind the
    start reads as zero. *)
val age_seconds : now:float -> since:float -> int

(** [presence ~now ~base_path name] reads the registry entry and its live turn.
    The delegate submit result takes its [target_turn_age_s] from it. *)
val presence : now:float -> base_path:string -> string -> presence

(** [observe ~now ~base_path ~keeper_name] reads the owner's operation
    inventory, which is lock-free, and the registry. *)
val observe : now:float -> base_path:string -> keeper_name:string -> row

val row_to_json : row -> Yojson.Safe.t

(** The tool body: [{"names": [...]}] in, [{"targets": [row, ...]}] out, in the
    order asked. A name outside the Keeper name grammar is a rejected input,
    not an unknown Keeper. *)
val body : config:Workspace.config -> Yojson.Safe.t -> Keeper_types_profile.tool_result
