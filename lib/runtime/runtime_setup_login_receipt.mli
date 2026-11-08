(** Private recovery receipts contain no CLI output, input, credentials or paths.
    Scope is a digest of the canonical workspace and authenticated actor. *)
type status = Running | Complete of Runtime_setup_login_client.observation
  | Failed | Cancelled | Interrupted
(** Where the account of a login is. A complete receipt has a [Published] or
    a [Linked] one, and only a complete receipt has a [Linked] one. *)
type account =
  | Unselected  (** No account was selected or made yet. *)
  | Published of Runtime_setup_accounts.reference
      (** A single-user login: the setup registry holds the account, and setup
          selects it by this reference ([account_ref] in the JSON). *)
  | Linked
      (** A multi-account login of a person: the authorization log links the
          account, whose id is the login id, to the person, and the setup
          registry does not hold it (plan D1-4; [account] is [linked] in the
          JSON). *)
type t = {
  login_id : string;
  integration_id : string;
  account : account;
  status : status;
}
type error = Not_found | Unavailable
val save : workspace:string -> actor:string -> t -> (unit, error) result
val load : workspace:string -> actor:string -> login_id:string -> (t, error) result
val to_json : t -> Yojson.Safe.t
(** A running receipt with no process registry entry is projected as Interrupted
    by the caller. A reference alone is never authentication evidence. *)
