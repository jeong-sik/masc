(** Immutable Memory-maintenance execution boundary.

    The maintenance pass ({!Keeper_memory_cleanup}) renders the whole current
    Memory OS snapshot with the original [librarian] prompt. This module holds
    the complete immutable boundary of that maintenance request: the retained
    owner observation, the Addon destination, the original
    [durable_preparation] and the complete raw model answer, plus the strict
    decoder that recombines them and the pure JSON envelope for durable host
    retention.

    Retention and restoration supply data only. Nothing here reads mutable
    stores, and nothing here grants source-lock, physical-owner, Memory
    incarnation, provider, gate, disposition or acknowledgement authority.
    A restored boundary is matched against a freshly observed owner through
    {!matches_owner_json}; it never rebuilds an owner from its own JSON.
    These boundaries follow the completed-history port
    (Keeper_librarian_durable_capture / _request) and do not declare any of
    the original 54 work items complete. *)

type error =
  | Request_invalid of string
  | Preparation_invalid of string
  | Proposal_invalid of Keeper_librarian.parse_error

val error_to_string : error -> string

type owner = Keeper_librarian_durable_request.owner
type destination = Keeper_librarian_durable_request.destination

val observe_owner
  :  base_path:string -> keepers_dir:string -> keeper_id:string
  -> (owner, string) result
val discovery_scope
  :  base_path:string -> keepers_dir:string -> keeper_id:string
  -> (string, string) result
val owner_matches_json : owner -> Yojson.Safe.t -> (unit, string) result
val fresh_request_id : owner -> string

val destination_json : destination -> Yojson.Safe.t
val destination_of_json : Yojson.Safe.t -> (destination, string) result
(** Field-exact destination envelope. Requires this feature's configured
    package/tool; a relabeled package is not a maintenance destination. *)

type t

val create
  :  request_id:string
  -> owner:owner
  -> destination:destination
  -> preparation:Keeper_librarian_runtime.durable_preparation
  -> answer_text:string
  -> captured_at:float
  -> (t, error) result
(** Checks the boundary's internal agreement (canonical owner Keeper, nonempty
    answer, destination package/tool) and takes the answer digest from the
    exact answer bytes. Reads no store and grants no authority. *)

val request_id : t -> string
val owner_json : t -> Yojson.Safe.t
val destination : t -> destination
val preparation : t -> Keeper_librarian_runtime.durable_preparation
val answer_text : t -> string
val answer_digest : t -> string
val captured_at : t -> float
val matches_owner_json : t -> owner -> (unit, string) result
(** Compares the retained owner observation against a freshly observed one.
    The retained JSON never becomes an owner by itself. *)

val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, error) result
(** Field-exact envelope with typed structured children. The complete Librarian
    input and its current snapshot, the original preparation and the raw answer
    bytes are retained verbatim; the answer digest must match the retained
    bytes. Restoration performs no store effect. *)

val validate_proposal
  :  t -> Yojson.Safe.t
  -> (Keeper_librarian_runtime.durable_proposal, error) result
(** Recombines the retained preparation with a raw Memory answer and runs the
    existing strict durable decoder against the original input and time. No
    gate judgment, locked disposition or ACK is performed. *)
