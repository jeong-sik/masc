#load "unix.cma";;
type shutdown_error = Listener_close_unconfirmed
module Real_unix = Unix
let fail_close = ref false
module Unix = struct
 include Real_unix
 let close fd = if !fail_close then raise (Unix_error (EIO,"close","PRIVATE_MARKER")) else Real_unix.close fd
end
let hooks = ref []
module Eio = struct
 module Cancel = struct let protect f = f () end
 module Switch = struct let on_release () f = hooks := f :: !hooks end
end
module Eio_unix = struct
 let run_in_systhread f = f ()
 module Net = struct let import_socket_listening ~sw:_ ~close_unix:_ fd = fd end
end
