module type S = sig
  val id : string
  val init_state : config:Yojson.Safe.t -> Yojson.Safe.t
  val apply_event : state:Yojson.Safe.t -> event:Engine_event.t -> Yojson.Safe.t
  val derive_state : state:Yojson.Safe.t -> Yojson.Safe.t
end
