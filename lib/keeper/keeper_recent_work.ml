type t =
  { conversation : (Keeper_turn_fragments.observed_message list, string) result
  ; autonomous_reply : (Keeper_turn_fragments.observed_message list, string) result
  }

let empty = { conversation = Ok []; autonomous_reply = Ok [] }

let collect ~(config : Workspace.config) ~(meta : Keeper_meta_contract.keeper_meta) =
  let session_dir = Keeper_types_support.keeper_session_dir config
      (Keeper_id.Trace_id.to_string meta.runtime.trace_id) in
  (* Same eight-message conversation window as direct-turn context, but tools
     cannot displace conversation and the messages retain their provenance.
     The latest autonomous conclusion is separate: it may contain the next
     step taken after the direct exchange. Neither is inferred open work. *)
  let conversation = Keeper_turn_fragments.read_recent_messages
      ~session_dir ~roles:[Agent_core.Types.User; Assistant] ~limit:8 Main in
  let autonomous_reply = Keeper_turn_fragments.read_recent_messages
      ~session_dir ~roles:[Agent_core.Types.Assistant] ~limit:1 Internal in
  { conversation; autonomous_reply }
