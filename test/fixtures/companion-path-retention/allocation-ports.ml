#load "unix.cma";;
type cleanup = Paths_retained of string
module B = struct
 type completion = Abandoned
 type shutdown_error = Listener_close_unconfirmed
 type t = {stopped:(unit,shutdown_error) result; mutable revoked:bool}
 let revoke t = t.revoked <- true
 let await_stopped t = assert t.revoked; t.stopped
end
module Eio = struct
 module Lazy = struct
  let from_fun ~cancel:_ f = lazy (f ())
  let force = Lazy.force
 end
 module Promise = struct
  let try_resolve p x = match !p with None -> p:=Some x;true | Some _ -> false
  let await p = p ()
 end
 module Fiber = struct module List = List end
end
module Log = struct module Misc = struct let warn format = Printf.ksprintf ignore format end end
module Eio_unix = struct let run_in_systhread f = f () end
module Unix = struct
 include Unix
 let unlink _ = failwith "cleanup attempted pathname unlink"
 let rmdir _ = failwith "cleanup attempted pathname rmdir"
end
type settlement = {notify:B.completion option ref; settled:unit -> (unit,string) result}
