(** The claims on a work volume as the keeper side reads and changes them:
    the marker read back from the volume, the report of the helper guest, the
    containers that reference a keeper, and the add and release of a claim on
    Apple's container.

    [Keeper_sandbox_microvm] includes this module. *)

(* Strict decode of marker content. Empty output means no marker (the read
   helper prints nothing for an absent file); anything else must be a JSON
   array of valid claimants, or it is invalid -- never a default. *)
type volume_claims_read =
  | Marker_absent
  | Claims_read of string list
  | Claims_invalid of string

val volume_claims_of_output : string -> volume_claims_read

(* The release helper's stdout protocol: one outcome word, and for [kept]
   the marker content that remains. Pure, so the mapping is testable
   without a container runtime. *)
type apple_volume_claim_helper_report =
  | Claims_marker_absent
  | Claimant_not_present
  | Released_last_claim
  | Kept_with_claimants of string list
  | Report_unrecognized of string

val volume_claim_helper_report_of_output : string -> apple_volume_claim_helper_report

val apple_keeper_owner_containers :
  run:(timeout_sec:float -> string list -> Unix.process_status * string * string)
  -> timeout_sec:float
  -> keeper_name:string
  -> (string list, string) result

val add_apple_work_volume_claim :
  run:(timeout_sec:float -> string list -> Unix.process_status * string * string)
  -> timeout_sec:float
  -> keeper_name:string
  -> volume_name:string
  -> image:string
  -> claimant:string
  -> (unit, string) result

type apple_volume_claim_release =
  | Kept_for_claimants of string list
  | Kept_for_containers of string list
  | Skipped_unverified of string

val release_apple_work_volume_claim :
  run:(timeout_sec:float -> string list -> Unix.process_status * string * string)
  -> timeout_sec:float
  -> keeper_name:string
  -> volume_name:string
  -> image:string
  -> claimant:string
  -> apple_volume_claim_release
