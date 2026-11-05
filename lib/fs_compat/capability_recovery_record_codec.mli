(** JSON encoding and strict decoding of the recovery records defined in
    [Capability_recovery_record].

    A record is one JSON object followed by a newline. A decoder accepts only
    the exact field set of its state and only the current schema name and
    version, and it builds the locator and permissions through their validating
    constructors. Every refusal is a [validation_error] returned as [Error]; a
    decoder does not raise. *)

open Capability_recovery_record

val encode_prepared : prepared -> string
val encode_bound : bound -> string
val encode_forensic : forensic -> string
val decode_prepared : string -> (prepared, validation_error) result
val decode_bound : string -> (bound, validation_error) result
val decode_forensic : string -> (forensic, validation_error) result

(** A mismatch outcome must name the identity [prepared] recorded for that
    directory, and what it observed must differ from that identity. The other
    outcomes need no check. *)
val validate_prepared_recovery_outcome
  :  prepared
  -> prepared_recovery_outcome
  -> (unit, validation_error) result

(** As {!validate_prepared_recovery_outcome}, and a preserved stage must be a
    directory with the identity [bound] recorded for its stage. *)
val validate_bound_recovery_outcome
  :  bound
  -> bound_recovery_outcome
  -> (unit, validation_error) result

(** The owner and operation id inside a record found at a store location must be
    the ones that location names. *)
val validate_record_owner_and_id
  :  owner:owner
  -> operation_id:operation_id
  -> record_owner:owner
  -> record_id:operation_id
  -> (unit, validation_error) result
