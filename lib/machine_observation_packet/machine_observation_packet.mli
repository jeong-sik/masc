(** Retain full machine-live payloads as packet artifacts, leaving only digest
    references in model-visible row fields. No filesystem or host dependency. *)
val encode : Yojson.Safe.t -> (Yojson.Safe.t, string) result
