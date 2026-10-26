(** Read an original immutable terminal observation after its live supervisor
    or endpoint boot is gone. Protected receipts prove historical physical/tree
    settlement and complete output. Physical observations leave payload effects
    uncertain; proven non-starts retain separate gate evidence. Neither restores
    kernel handles nor establishes payload or Task/Goal success. *)
module P = Endpoint_job_protocol
module R = Endpoint_job_registry
module O = Endpoint_job_output
module G = Endpoint_process_gate
type t
val leaf : string
type error =
  | Registry_error of R.error
  | Output_error of { stream : P.stream; cause : O.error }
  | Codec_error of P.codec_error
  | Invalid_receipt
  | Storage_unavailable
  | Sync_failed of Fs_compat.owned_regular_file_read_error
val error_to_string : error -> string
type input_delivery = Accepted of int64 | Incomplete of { confirmed_prefix : int64 }
(** Accepted bytes entered the original pipe, never proof of consumption. *)
type preparation = Pending | Ready | Rejected of { diagnostic : string }
type control = Open | Ended | Failed of { diagnostic : string }
type gate = { preparation : preparation; decision : G.decision; control : control }
(** Failed is a broken private gate channel; its other gate fields may be cut
    short. Rejection and failure diagnostics are display evidence only; never parse them to infer
    exec, non-start, retry, signalling or cleanup permission. *)
val encode :
  status:P.response -> physical_exit:P.exit_status -> launch_id:P.Id.t -> input:input_delivery -> gate:gate ->
  (string,error) result
(** Pure structural encoding of a pending sealed physical or proven non-start observation with a
    domain-separated payload checksum. This grants no provenance, publication
    or readiness authority; the trusted producer must supply actual evidence. *)
val load :
  sw:Eio.Switch.t -> storage:R.storage -> expected_sha256:P.Sha256.t option -> (t,error) result
(** Strictly decode the private original terminal receipt, match its admission,
    known launch, source progress and input prefix, verify both complete sealed
    streams by hashing their actual bytes, and sync the exact receipt file and
    parent before reporting readiness. Original root/receipt/output attachment
    is revalidated at the final observation. Missing/corrupt/changed authority
    remains an error; it never becomes an empty result or new Start. A known
    host result digest must be supplied as [Some digest]; mismatch never adopts
    a replacement. [None] permits initial discovery only under original private
    storage authority and the receipt payload checksum, which is corruption
    detection rather than authentication.

    [sw] owns reader descriptors through durable host consumption; do not use
    the global registry lifetime. Cancelling this reader preserves the original
    files and operation. Old-boot reads are permitted without process adoption.
    No publication, removal, host ACK or Release authority is granted. *)
val sha256 : t -> P.Sha256.t
val input_delivery : t -> input_delivery
val gate : t -> gate
val physical_exit : t -> P.exit_status
(** Raw original OS status, including bootstrap exits for proven non-starts. *)
val inspect : t -> (P.response,error) result
(** Revalidate retained original receipt and output attachments, refresh only
    legitimate original source progress, then return Result_ready for the exact
    receipt digest. This is a current observation, not Task/Goal verification. *)
val read_output :
  t -> stream:P.stream -> offset:int64 -> max_bytes:int -> (O.chunk,error) result
(** Read only the verified original sealed stream, revalidating original
    receipt/source/output attachment before and after the bounded range. *)
module For_testing : sig
  val load :
    after_receipt_read:(unit -> unit) -> before_ready:(unit -> unit) ->
    sw:Eio.Switch.t -> storage:R.storage -> expected_sha256:P.Sha256.t option -> (t,error) result
  (** Interleave after reading the actual receipt bytes, or after complete
      output verification/sync and before final readiness validation. *)
end
