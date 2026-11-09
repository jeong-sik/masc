(** The index of the delivery provenance in a transcript.

    A row may carry [delivery_provenance], the address of the delivery that
    wrote it. [provenance_of_line] reads one line into a [scanned_provenance]:
    no provenance, a valid one with its row id, or a delivery key that the row
    poisons because its role or its execution id does not fit its transcript
    slot. [provenance_index_of_existing] reads a whole transcript into a
    [provenance_index]: the rows by provenance, by tool ordinal and by
    execution id, and the poisoned delivery keys. A provenance, a tool ordinal
    or an execution id that appears twice poisons its delivery key, and a line
    that cannot be read at all is an [Error].
    [find_indexed_provenance] answers from an index that is built:
    [Ok (Some row_id)] when the delivery already has its row and [Ok None] when
    it has none. It is an [Error] when the delivery cannot be answered safely:
    its key is poisoned, its rows are duplicated, or its tool ordinal or
    execution id belongs to another delivery. [find_provenance] builds the
    index first. [transcript_provenance_readable] asks only whether the index
    can be built.
    [Keeper_chat_store] includes this module. *)

module Provenance_key :
  sig
    type t = Keeper_chat_delivery_identity.delivery_provenance
    val equal : t -> t -> bool
    val hash : 'a -> int
  end

module Provenance_index :
  sig
    type key = Provenance_key.t
    type 'a t = 'a Hashtbl.Make(Provenance_key).t
    val create : int -> 'a t
    val clear : 'a t -> unit
    val reset : 'a t -> unit
    val copy : 'a t -> 'a t
    val add : 'a t -> key -> 'a -> unit
    val remove : 'a t -> key -> unit
    val find_and_remove : 'a t -> key -> 'a option
    val find : 'a t -> key -> 'a
    val find_opt : 'a t -> key -> 'a option
    val find_all : 'a t -> key -> 'a list
    val replace : 'a t -> key -> 'a -> unit
    val find_and_replace : 'a t -> key -> 'a -> 'a option
    val mem : 'a t -> key -> bool
    val iter : (key -> 'a -> unit) -> 'a t -> unit
    val filter_map_inplace : (key -> 'a -> 'a option) -> 'a t -> unit
    val fold : (key -> 'a -> 'acc -> 'acc) -> 'a t -> 'acc -> 'acc
    val length : 'a t -> int
    val stats : 'a t -> Hashtbl.statistics
    val to_seq : 'a t -> (key * 'a) Seq.t
    val to_seq_keys : 'a t -> key Seq.t
    val to_seq_values : 'a t -> 'a Seq.t
    val add_seq : 'a t -> (key * 'a) Seq.t -> unit
    val replace_seq : 'a t -> (key * 'a) Seq.t -> unit
    val of_seq : (key * 'a) Seq.t -> 'a t
  end

module Delivery_key :
  sig
    type t = Keeper_chat_delivery_identity.delivery_key
    val equal : t -> t -> bool
    val hash : 'a -> int
  end

module Poisoned_delivery_keys :
  sig
    type key = Delivery_key.t
    type 'a t = 'a Hashtbl.Make(Delivery_key).t
    val create : int -> 'a t
    val clear : 'a t -> unit
    val reset : 'a t -> unit
    val copy : 'a t -> 'a t
    val add : 'a t -> key -> 'a -> unit
    val remove : 'a t -> key -> unit
    val find_and_remove : 'a t -> key -> 'a option
    val find : 'a t -> key -> 'a
    val find_opt : 'a t -> key -> 'a option
    val find_all : 'a t -> key -> 'a list
    val replace : 'a t -> key -> 'a -> unit
    val find_and_replace : 'a t -> key -> 'a -> 'a option
    val mem : 'a t -> key -> bool
    val iter : (key -> 'a -> unit) -> 'a t -> unit
    val filter_map_inplace : (key -> 'a -> 'a option) -> 'a t -> unit
    val fold : (key -> 'a -> 'acc -> 'acc) -> 'a t -> 'acc -> 'acc
    val length : 'a t -> int
    val stats : 'a t -> Hashtbl.statistics
    val to_seq : 'a t -> (key * 'a) Seq.t
    val to_seq_keys : 'a t -> key Seq.t
    val to_seq_values : 'a t -> 'a Seq.t
    val add_seq : 'a t -> (key * 'a) Seq.t -> unit
    val replace_seq : 'a t -> (key * 'a) Seq.t -> unit
    val of_seq : (key * 'a) Seq.t -> 'a t
  end

module Tool_ordinal :
  sig
    type t = Poisoned_delivery_keys.key * int
    val equal :
      Poisoned_delivery_keys.key * int ->
      Poisoned_delivery_keys.key * int -> bool
    val hash : 'a -> int
  end

module Tool_ordinal_index :
  sig
    type key = Tool_ordinal.t
    type 'a t = 'a Hashtbl.Make(Tool_ordinal).t
    val create : int -> 'a t
    val clear : 'a t -> unit
    val reset : 'a t -> unit
    val copy : 'a t -> 'a t
    val add : 'a t -> key -> 'a -> unit
    val remove : 'a t -> key -> unit
    val find_and_remove : 'a t -> key -> 'a option
    val find : 'a t -> key -> 'a
    val find_opt : 'a t -> key -> 'a option
    val find_all : 'a t -> key -> 'a list
    val replace : 'a t -> key -> 'a -> unit
    val find_and_replace : 'a t -> key -> 'a -> 'a option
    val mem : 'a t -> key -> bool
    val iter : (key -> 'a -> unit) -> 'a t -> unit
    val filter_map_inplace : (key -> 'a -> 'a option) -> 'a t -> unit
    val fold : (key -> 'a -> 'acc -> 'acc) -> 'a t -> 'acc -> 'acc
    val length : 'a t -> int
    val stats : 'a t -> Hashtbl.statistics
    val to_seq : 'a t -> (key * 'a) Seq.t
    val to_seq_keys : 'a t -> key Seq.t
    val to_seq_values : 'a t -> 'a Seq.t
    val add_seq : 'a t -> (key * 'a) Seq.t -> unit
    val replace_seq : 'a t -> (key * 'a) Seq.t -> unit
    val of_seq : (key * 'a) Seq.t -> 'a t
  end

module Execution_id_key :
  sig
    type t = Ids.Execution_id.t
    val equal : t -> t -> bool
    val hash : 'a -> int
  end

module Execution_index :
  sig
    type key = Execution_id_key.t
    type 'a t = 'a Hashtbl.Make(Execution_id_key).t
    val create : int -> 'a t
    val clear : 'a t -> unit
    val reset : 'a t -> unit
    val copy : 'a t -> 'a t
    val add : 'a t -> key -> 'a -> unit
    val remove : 'a t -> key -> unit
    val find_and_remove : 'a t -> key -> 'a option
    val find : 'a t -> key -> 'a
    val find_opt : 'a t -> key -> 'a option
    val find_all : 'a t -> key -> 'a list
    val replace : 'a t -> key -> 'a -> unit
    val find_and_replace : 'a t -> key -> 'a -> 'a option
    val mem : 'a t -> key -> bool
    val iter : (key -> 'a -> unit) -> 'a t -> unit
    val filter_map_inplace : (key -> 'a -> 'a option) -> 'a t -> unit
    val fold : (key -> 'a -> 'acc -> 'acc) -> 'a t -> 'acc -> 'acc
    val length : 'a t -> int
    val stats : 'a t -> Hashtbl.statistics
    val to_seq : 'a t -> (key * 'a) Seq.t
    val to_seq_keys : 'a t -> key Seq.t
    val to_seq_values : 'a t -> 'a Seq.t
    val add_seq : 'a t -> (key * 'a) Seq.t -> unit
    val replace_seq : 'a t -> (key * 'a) Seq.t -> unit
    val of_seq : (key * 'a) Seq.t -> 'a t
  end

type indexed_provenance =
  | Unique_provenance of string
  | Duplicate_provenance

type indexed_tool_ordinal =
  | Unique_tool_ordinal of
      Keeper_chat_delivery_identity.transcript_slot * string
  | Duplicate_tool_ordinal

type execution_owner =
  { delivery_key : Keeper_chat_delivery_identity.delivery_key
  ; ordinal : int
  }

type indexed_execution =
  | Unique_execution of execution_owner
  | Reused_execution

type autonomous_input_index

type provenance_index =
  { valid : indexed_provenance Provenance_index.t
  ; poisoned_delivery_keys : string Poisoned_delivery_keys.t
  ; tool_ordinals : indexed_tool_ordinal Tool_ordinal_index.t
  ; executions : indexed_execution Execution_index.t
  ; autonomous_inputs : autonomous_input_index
  }

val provenance_index_of_existing :
  string -> (provenance_index, string) result

val transcript_provenance_readable : string -> (unit, string) result

val validate_indexed_autonomous_inputs :
  provenance_index ->
  delivery_key:Keeper_chat_delivery_identity.delivery_key ->
  Keeper_chat_delivery_identity.approval_input_binding list ->
  (unit, string) result
(** Before any append, require the existing turn's exact ordered binding.
    An unseen turn can be bound once. Missing binding behind existing tools,
    duplicate bindings or another vector are conflicts, never repair inputs. *)

val find_indexed_provenance :
  provenance_index ->
  provenance:Provenance_index.key -> (string option, string) result

val find_provenance :
  string -> provenance:Provenance_index.key -> (string option, string) result
