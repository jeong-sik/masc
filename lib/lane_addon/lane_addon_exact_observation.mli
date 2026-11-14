(** Passive per-attempt companion to the unchanged original execution proof.
    The owner supplies its already validated proof; its full canonical digest,
    physical store root and declaration/request/ordinal identify the record.
    Missing or invalid observations never replace or authorize execution. *)
val retain : store:Lane_addon_store.t -> declaration_id:string -> request_id:string ->
  attempt_ordinal:int -> proof:Yojson.Safe.t -> Exact_lane_slot_observation.t list ->
  (unit,string) result
val read : store:Lane_addon_store.t -> declaration_id:string -> request_id:string ->
  attempt_ordinal:int -> proof:Yojson.Safe.t ->
  (Exact_lane_slot_observation.t list option,string) result
val directory : declaration_id:string -> string
val store_root : Yojson.Safe.t -> string option
(** The store root an observation file names, when it names one, read without
    decoding the file. *)
val request_id : store:Lane_addon_store.t -> declaration_id:string -> file_name:string ->
  Yojson.Safe.t -> (string,string) result
(** Original request identity of this exact companion file, for the existing
    original-owner sweep. Checks its envelope/path, grants no execution. *)
