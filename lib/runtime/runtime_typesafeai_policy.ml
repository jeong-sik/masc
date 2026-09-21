(* The [typesafeai] table of the loaded runtime.toml, for readers outside
   {!Runtime}: {!Runtime.set_loaded} publishes it, and before any load it is
   the default. One [Atomic.t] so a reader never sees a torn refresh. It is
   its own module, not a field readers take from [Runtime], because the
   readers ([Typesafeai_config], and through it the keeper gates) sit below
   [Runtime] in the dependency order. *)

let current_ref = Atomic.make Runtime_schema.default_typesafeai
let current () = Atomic.get current_ref
let publish (policy : Runtime_schema.typesafeai) = Atomic.set current_ref policy
