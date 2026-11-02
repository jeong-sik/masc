val start :
  sw:Eio.Switch.t -> publish:(base_path:string -> unit) -> (base_path:string -> unit)
(** Return a short, non-yielding workspace enqueue callback. The switch-owned
    worker coalesces pending paths and invokes [publish] outside the caller. *)
