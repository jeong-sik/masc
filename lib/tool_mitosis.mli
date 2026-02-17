(** Mitosis Tool Handlers

    Extracted from mcp_server_eio.ml for testability.
    8 tools: mitosis_status, mitosis_all, mitosis_pool, mitosis_divide,
             mitosis_check, mitosis_record, mitosis_prepare, mitosis_handoff

    Key tool: masc_mitosis_handoff - 2-phase proactive context management
    - 50% threshold: DNA preparation (context summary extracted)
    - 80% threshold: Handoff execution (spawn successor agent)
*)

(** Tool handler context - extensible for future features *)
type any_clock = Clock : _ Eio.Time.clock -> any_clock

type context = {
  config: Room_utils.config;
  logger: (string -> unit) option;  (** Optional logging callback *)
  sw: Eio.Switch.t option;
  proc_mgr: Eio_unix.Process.mgr_ty Eio.Resource.t option;
  clock: any_clock option;
}

(** Create context with just config (backward compatible) *)
val make_context : Room_utils.config -> context

(** Create context with config and logger *)
val make_context_with_logger : Room_utils.config -> (string -> unit) -> context

(** Create context with sw and proc_mgr for non-blocking spawn *)
val make_context_with_eio :
  config:Room_utils.config ->
  sw:Eio.Switch.t ->
  proc_mgr:Eio_unix.Process.mgr_ty Eio.Resource.t option ->
  clock:_ Eio.Time.clock ->
  context

(** Internal logging helper (for testing) *)
val log : context -> string -> unit

(** Last successful handoff timestamp for cooldown enforcement *)
val last_handoff_time : float ref

(** Reset handoff cooldown timer (for testing) *)
val reset_handoff_cooldown : unit -> unit

(** Tool result type *)
type result = bool * string

(** {1 Argument Helpers} *)

val get_string : Yojson.Safe.t -> string -> string -> string
val get_float : Yojson.Safe.t -> string -> float -> float
val get_bool : Yojson.Safe.t -> string -> bool -> bool

(** {1 Individual Handlers} *)

val handle_mitosis_status : context -> Yojson.Safe.t -> result
val handle_mitosis_all : context -> Yojson.Safe.t -> result
val handle_mitosis_pool : context -> Yojson.Safe.t -> result
val handle_mitosis_divide : context -> Yojson.Safe.t -> result
val handle_mitosis_check : context -> Yojson.Safe.t -> result
val handle_mitosis_record : context -> Yojson.Safe.t -> result
val handle_mitosis_prepare : context -> Yojson.Safe.t -> result
val handle_mitosis_handoff : context -> Yojson.Safe.t -> result

(** {1 Dispatcher} *)

(** Dispatch mitosis tool by name. Returns None if not a mitosis tool. *)
val dispatch : context -> name:string -> args:Yojson.Safe.t -> result option
