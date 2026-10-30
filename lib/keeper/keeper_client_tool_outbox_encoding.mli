(** A lossless model-facing representation of already validated receipts. *)
type t =
  | Individual of string
  | Shared of string

val shared_description : string
(** The model-facing explanation required by the shared representation. *)

val encode : Yojson.Safe.t list -> t
(** Use sharing only when common data repeats and the complete representation,
    including its description, is smaller. The shared representation holds
    complete common fields in [shared] and a [receipts] array in snapshot order. Each
    receipt is [shared_index, call_id] for a vendor receipt, or
    [shared_index, call_id, host_invocation_index] for a host receipt. All
    remaining fields, including arguments and response, stay in the selected
    shared object. If no common data repeats or a receipt shape is unexpected,
    use the individual representation.
    No retained file or acknowledgement is changed. *)
