module Server_runtime = struct end

(* Parenthesized coordinator alias — should be flagged as a violation. *)
module Alias = (Server_runtime)
