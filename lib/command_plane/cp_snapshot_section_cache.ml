include Cp_unit

type section_cache = {
  mutable base_path : string option;
  mutable topo_units_mtime : float;
  mutable topo_agents_mtime : float;
  mutable agents : Types.agent list;
  mutable managed_units : unit_record list;
  mutable units : unit_record list;
  mutable source : string;
  mutable intents_mtime : float;
  mutable intents : intent_record list;
  mutable ops_topo_units_mtime : float;
  mutable ops_topo_agents_mtime : float;
  mutable ops_mtime : float;
  mutable operations : operation_record list;
  mutable det_mtime : float;
  mutable det_ops_mtime : float;
  mutable detachments : detachment_record list;
  mutable decisions_mtime : float;
  mutable decisions_operator_mtime : float;
  mutable decisions : policy_decision_record list;
}

let create () =
  {
    base_path = None;
    topo_units_mtime = 0.0;
    topo_agents_mtime = 0.0;
    agents = [];
    managed_units = [];
    units = [];
    source = "auto";
    intents_mtime = 0.0;
    intents = [];
    ops_topo_units_mtime = 0.0;
    ops_topo_agents_mtime = 0.0;
    ops_mtime = 0.0;
    operations = [];
    det_mtime = 0.0;
    det_ops_mtime = 0.0;
    detachments = [];
    decisions_mtime = 0.0;
    decisions_operator_mtime = 0.0;
    decisions = [];
  }

let shared_cache : section_cache option ref = ref None
