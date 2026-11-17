val refusal_sentence : string -> string option
(** The sentence for the body of a refused MSX answer, read with {!Msx_wire}:
    the code says what the operator may do next and the server's message says
    why. [None] for a body that is not an MSX refusal, so the caller keeps its
    own wording. *)
