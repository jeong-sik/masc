(** Private recovery receipts contain no CLI output, input, credentials or paths.
    Scope is a digest of the canonical workspace and authenticated actor. *)
type status = Running | Complete of Runtime_setup_login_client.observation
  | Failed | Cancelled | Interrupted
type t = {
  login_id : string;
  integration_id : string;
  account_ref : Runtime_setup_accounts.reference option;
  status : status;
}
type error = Not_found | Unavailable
val save : workspace:string -> actor:string -> t -> (unit, error) result
val load : workspace:string -> actor:string -> login_id:string -> (t, error) result
val to_json : t -> Yojson.Safe.t
(** A running receipt with no process registry entry is projected as Interrupted
    by the caller. A reference alone is never authentication evidence. *)
