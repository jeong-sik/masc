(** Host-authorized reasons for releasing a machine controller. The worker
    does not inspect Keeper registries or credential stores. *)
type holder_departure =
  | Keeper_stopped
  | Credential_expired
  | No_credential
  | Participant_departed

type admission = {
  observed_holder : string option;
  release : holder_departure option;
  handoff_target : string option;
}
(** Issued by the owning host under its credential transaction. The worker
    compares [observed_holder] before applying [release]. For handoff calls,
    [handoff_target] must equal the parsed recipient (including [None]). *)
val snapshot_tool : string
val release_tool : string
val admission_to_json : admission -> Yojson.Safe.t
val admission_of_json : Yojson.Safe.t -> (admission, string) result
val admission_schema : Yojson.Safe.t
