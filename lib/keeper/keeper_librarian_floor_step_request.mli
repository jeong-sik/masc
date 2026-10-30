(** Original host request for one question of the durable message floor
    (RFC librarian-durable-message-floor). The floor reads a turn that exceeded
    the worker frame one message at a time; each question is one original of its
    own, retained before dispatch, in a scope of its own, so completed-history
    discovery never sees it as a history original.

    A step carries its own input: the one message it asks about, the facts
    staged by the steps before it and what the host observed that no accepted
    step has taken yet, together with the working state and unread messages the
    question carries in. It restores from its record alone, so the host can
    validate a model's answer to it and a wake can name its Keeper without the
    chain. A step names the range original it reads and the step before it by
    request ID and digest. Whether those records exist, agree and make the next
    question the floor asks is the chain's check, made with {!matches_question}.
    Retention and restore perform no provider, Gate, Memory, source or cursor
    effect. Blocking filesystem operations must be offloaded as a whole from
    Eio callers. *)
type link = {request_id:string;request_digest:string}
(** An original named by the ID and digest of its record. *)

val scope : Keeper_librarian_durable_request.owner -> string
(** The store scope of this owner's steps. It differs from the owner's history
    scope. *)
val fresh_request_id : Keeper_librarian_durable_request.owner -> string
val scope_of_request_id : string -> (string, string) result
(** A history request ID is not a step ID, and a step ID is not a history ID. *)
val minted_on : string -> (string, string) result
(** The UTC day a step ID was minted, which is the day its records settle under. *)

type t
val create : request_id:string -> owner:Keeper_librarian_durable_request.owner ->
  destination:Keeper_librarian_durable_request.destination -> transaction_id:string -> range:link ->
  previous:link option ->
  question:Keeper_librarian_message_floor.Machine.question ->
  step:Keeper_librarian_runtime.durable_step_preparation -> unit -> (t, string) result
(** [range] is a history request of the owner and [previous] a step of the
    owner other than this one. Only the first question has no [previous].
    [transaction_id] names the chain's one Memory program; every step of a chain
    carries the same value, and a restarted chain takes it from its first step
    rather than naming a new one. The step must be the preparation of
    [question]. The request restores from its own encoding before it is
    returned. *)
val restore : owner:Keeper_librarian_durable_request.owner -> Lane_addon_tool_request_owner.retained ->
  (t, string) result
(** Decode the record's request, render its prompt again from the retained
    resolutions and its own input, and check that the prompt is the one the
    host was sent. The record must be this owner's step scope with the host
    binding the request names. *)
val matches_question : Keeper_librarian_message_floor.Machine.question -> t -> (unit, string) result
(** The step is the question the floor asks now: the same position and sources,
    the same carried working state and unread messages, and the same input. *)
type header = {request_id:string;destination:Keeper_librarian_durable_request.destination;
  transaction_id:string;range:link;previous:link option;position:int;
  sources:Keeper_librarian_unread.source list}
val header : owner:Keeper_librarian_durable_request.owner -> Lane_addon_tool_request_owner.retained ->
  (header, string) result
(** What a record of this owner's step scope says about its place in a chain,
    without decoding its input or rendering its prompt: the checks of its
    identity, owner, links and position that {!restore} makes, but not of its
    preparation. It grants no authority to run, answer or settle the step. *)
val observe_record_owner : base_path:string -> keepers_dir:string -> Lane_addon_tool_request_owner.retained ->
  (Keeper_librarian_durable_request.owner, string) result
(** The live owner a retained step names: its recorded physical roots and Memory
    epoch must still be the live ones. The host asks this before it restores a
    step it did not create. *)
val confirm_record : t -> Lane_addon_tool_request_owner.retained -> (unit, string) result
(** The record is this step's: same scope, ID and host binding, and the digest
    of this request. *)
val to_json : t -> Yojson.Safe.t
val request_id : t -> string
val physical_owner : t -> Keeper_librarian_durable_request.owner
val destination : t -> Keeper_librarian_durable_request.destination
val transaction_id : t -> string
val range : t -> link
val previous : t -> link option
val position : t -> int
val sources : t -> Keeper_librarian_unread.source list
val step : t -> Keeper_librarian_runtime.durable_step_preparation
val request : t -> (Lane_addon_exact.request, string) result
val confirm_owner : t -> (unit, string) result
val confirm_final : store:Lane_addon_store.t -> t -> Lane_addon_exact.final ->
  (unit, string) result
(** Reobserve the full physical owner and epoch, then the host proof of
    {!Keeper_librarian_original_final.confirm_final}. *)
val refusal_evidence : store:Lane_addon_store.t -> t -> Lane_addon_exact.final ->
  (Keeper_exact_walk_failure.t, string) result
(** What a refused step shows about reading less, by the rules of
    {!Keeper_librarian_original_final.refusal_evidence}. *)
val validate_proposal : t -> Yojson.Safe.t ->
  (Keeper_librarian_runtime.durable_step_proposal, string) result
(** Parse the step's raw answer against its input and require a nonblank
    working state. *)
