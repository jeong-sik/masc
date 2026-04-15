
include Swarm_status_types
include Swarm_status_json
include Swarm_status_parse
include Swarm_status_classify
include Swarm_status_inputs
include Swarm_status_lanes
include Swarm_status_build

let build_json_from_snapshot ?(timeline_limit_override = timeline_limit)
    (config : Coord_utils.config) snapshot =
  build_json_from_inputs
    ~timeline_limit_override
    ~now:(Time_compat.now ())
    ~operations:(operation_infos_of_snapshot snapshot)
    ~detachments:(detachment_infos_of_snapshot snapshot)
    ~alerts:(alert_infos_of_snapshot snapshot)
    ~decisions:(decision_infos_of_snapshot snapshot)
    ~traces:(trace_infos_of_snapshot snapshot)
    ~sessions:(read_session_infos config)

let build_json ?(timeline_limit_override = timeline_limit)
    (config : Coord_utils.config) =
  build_json_from_inputs
    ~timeline_limit_override
    ~now:(Time_compat.now ())
    ~operations:(read_operation_infos config)
    ~detachments:(read_detachment_infos config)
    ~alerts:(read_alert_infos config)
    ~decisions:(read_decision_infos config)
    ~traces:(read_trace_infos ~limit:timeline_limit_override config)
    ~sessions:(read_session_infos config)
