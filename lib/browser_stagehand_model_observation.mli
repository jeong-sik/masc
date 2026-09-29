(** Shareable diagnostics projected only from closed typed failure facts.
    No provider bodies/messages, schema paths, slot identities, credentials or
    opaque subtypes are copied. Lists are bounded by the visited lane slots. *)
val refusal_json : Browser_stagehand_model.refusal -> Yojson.Safe.t
