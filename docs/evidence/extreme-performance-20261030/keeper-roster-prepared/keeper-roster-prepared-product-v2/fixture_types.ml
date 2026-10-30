module Decode = struct
  type keeper_runtime = { kr_name : string; runtime_identity : int;
                          kr_keepalive_running : bool }
end
module Control = struct
  type liveness = Unobserved | Invalid of string | Absent | Present of Decode.keeper_runtime
  type reading = { name : string; paused : bool; liveness : liveness }
type action =
  | Pause
  | Resume
  | Boot
  | Shutdown
  | Wakeup
  | Delete

end
