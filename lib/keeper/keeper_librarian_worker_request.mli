(** Commands prepared by the host that already restored the original Librarian
    capture. The configured worker's declared reply frame is authoritative:
    a request larger than that frame cannot fit any pending-request listing. *)
val prepare : max_reply_bytes:int -> request_id:string -> tool:string ->
  arguments:Yojson.Safe.t -> (Yojson.Safe.t, string) result
(** Preserve reads and fitting submissions. Replace an oversized submission
    with an operator-only [refuse_body] command carrying the same request ID,
    the worker's sorted-canonical request digest and its UTF-8 byte count.
    The worker retains the ordinary body-free [Request_body_refused] terminal;
    this function does not retain a result, run a provider or advance Memory.
    The input must be exactly a read or submission for this original and tool.
    Requests at the frame boundary still reach the worker's envelope check.
    Librarian's generated schemas contain integer bounds. An oversized input
    with remaining non-integral schema numbers is refused locally: OCaml and
    Python float serializers do not always give the same digest bytes. *)
