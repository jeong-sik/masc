(** Host-known source of one admitted direct operation. This observation names
    the original operation and its input source; it grants no
    permission and does not change the request body, message role, attribution
    metadata or checkpoint history. *)
type t

val of_admitted_input :
  operation_id:Keeper_chat_operation.Operation_id.t ->
  speaker:Keeper_input_speaker.t ->
  t
(** Keeper identity was already matched against the registry by the producer.
    Owner becomes [local_request], never an authenticated operator claim.
    External retains its host-known channel and speaker fields; Host retains
    only its cue kind. The caller retains this original operation source when
    a host-authored cue resumes the operation. No registry I/O occurs. *)

val render : t -> string
(** Render only the original operation id and typed input source through
    [keeper_context_direct_input_source]. Template failure remains visible as
    the prompt key and its diagnostic. *)
