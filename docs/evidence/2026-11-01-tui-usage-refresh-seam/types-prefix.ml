(* State/path adapter. Real identity matcher and request orders follow. *)
module Tui_decode = struct
  module Canonical_path = struct
    type t = string
    let is_empty value = value = ""
    let equal = String.equal
  end
  type server_identity = {sid_base_path:string;sid_masc_root:string;sid_state_ready:bool option}
  let system_log_level_query value = value
end
module Canonical_path = Tui_decode.Canonical_path
