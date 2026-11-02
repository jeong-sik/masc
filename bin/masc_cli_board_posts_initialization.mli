type action = Inspect | Bootstrap of { expected_intent_sha256 : string }
  | Adopt of { expected_intent_sha256 : string }
type request = { base_path : string; action : action }
val cmd : base_path:string Cmdliner.Term.t -> run:(request -> 'a) -> 'a Cmdliner.Cmd.t
val run : ?out:out_channel -> request -> int
(** Attempt JSON output and flush, then always finish the actual response.
    Retained operation failure takes precedence over a reporting failure. *)
