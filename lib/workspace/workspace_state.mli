(** Workspace state — backlog, workspace state, and recovery helpers. *)


val normalized_string_list : string list -> string list

(** Why [state.json] is there and yet gave no state. *)
type state_read_fault =
  | State_document_fault of Workspace_utils_ops.json_doc_error
      (** Blank, unparsable, or not readable from the store. *)
  | State_schema_fault of
      { reason : string
      ; document : Yojson.Safe.t
      }
      (** Parsed as JSON but not as a workspace state. *)

val state_read_fault_to_string : state_read_fault -> string

(** What one read of [state.json] found. *)
type state_observation =
  | State_absent of Masc_domain.workspace_state
      (** No document. Carries the declared default, which is not stored. *)
  | State_decoded of Masc_domain.workspace_state
  | State_recovered of
      { state : Masc_domain.workspace_state
      ; fault : state_read_fault
      }
      (** The document did not decode. [state] is what could be kept from it
          over the declared default; the stored document is unchanged. *)

val state_of_observation : state_observation -> Masc_domain.workspace_state

val state_observation_to_yojson : state_observation -> Yojson.Safe.t
(** [{"outcome": "absent" | "decoded" | "recovered"}], with ["fault"] beside
    ["recovered"]. *)

val observe_state_doc :
  defaults:(unit -> Masc_domain.workspace_state) ->
  (Yojson.Safe.t option, Workspace_utils_ops.json_doc_error) result ->
  state_observation
(** Classify one read of the document. Takes no store, so it cannot write. *)

val observe_state : Workspace_utils_backend_setup.config -> state_observation
(** Read [state.json] and classify it. Never writes: an undecodable document
    stays as it is, so this is safe where the store's write lock is not, such
    as a system thread. {!update_state} is what replaces such a document. *)

val read_state : Workspace_utils_backend_setup.config -> Masc_domain.workspace_state
(** {!observe_state} without the fault, which is logged. Never writes. *)

val write_state :
  Workspace_utils_backend_setup.config -> Masc_domain.workspace_state -> unit

val update_state :
  Workspace_utils_backend_setup.config ->
  (Masc_domain.workspace_state -> Masc_domain.workspace_state) ->
  Masc_domain.workspace_state
(** Under the state lock, apply the function and write the result. An
    undecodable document is replaced: the function sees its recovered value.
    Call from a fiber. *)

val next_seq : Workspace_utils_backend_setup.config -> int

val take : int -> 'a list -> 'a list
