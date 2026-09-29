(** Removing an account through the setup API that [/login] uses: a preview
    that names what the removal changes, and the removal that commits exactly
    that.

    The preview reads runtime.toml as it is and answers with its
    [source_revision]. The removal takes that revision back and removes the
    account only while the file still is that revision, checked inside the
    config write lock. One revision is one text, and
    {!Runtime_account_removal.remove} reads nothing but the text, so what is
    committed is what the preview listed. The commit is
    {!Runtime.edit_config_text}'s, with the raw save's validation. *)

type error =
  | Invalid_request  (** The body is not the fields this call takes. *)
  | Configuration_unavailable of string
  | Configuration_changed
      (** runtime.toml is no longer the revision the preview answered with. *)
  | Refused of Runtime_account_removal.error
  | Save_rejected of string  (** The commit refused the text without the account. *)

val error_message : error -> string

val preview : runtime_config_path:string -> Yojson.Safe.t -> (Yojson.Safe.t, error) result
(** Body [{"integration_id": id}], the provider id [/login] lists. The answer
    carries [integration_id] and [revision], and then either
    [{"state": "removable", "changes": [...], "login_store": path or null}] or
    [{"state": "refused", "reason": text}]. A change is one of
    [{"kind": "table", "path"}], [{"kind": "lane_candidate", "lane",
    "runtime"}], [{"kind": "exact_lane_slot", "lane", "runtime"}],
    [{"kind": "vision_runtime", "runtime"}] and [{"kind": "assignment",
    "keeper", "runtime"}]. *)

val remove :
  runtime_config_path:string -> Yojson.Safe.t -> (Runtime.config_commit_receipt, error) result
(** Body [{"integration_id": id, "revision": revision}], the revision taken
    from the preview. *)
