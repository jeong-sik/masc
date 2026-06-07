type tool_event =
  { base_path : string
  ; tool_name : string
  ; keeper_id : string
  ; turn_id : string
  ; outcome : string
  ; typed_outcome : string
  ; duration_ms : float
  ; output_text : string
  ; input : Yojson.Safe.t
  }

type pr_event =
  { base_path : string
  ; keeper_id : string
  ; turn_id : string
  ; output_text : string
  ; tool_name : string
  ; success : bool
  }

type turn_event =
  { base_path : string
  ; turn_id : string
  ; keeper_id : string
  ; phase : string
  ; model_used : string option
  ; tools_used : string list
  ; stop_reason : string option
  ; duration_ms : int option
  ; timestamp_ms : int64
  }

type tool_event_sink = tool_event -> unit
type pr_event_sink = pr_event -> unit
type turn_event_sink = turn_event -> unit

let noop_tool_event_sink (_ : tool_event) = ()
let noop_pr_event_sink (_ : pr_event) = ()
let noop_turn_event_sink (_ : turn_event) = ()

let tool_event_sink = Atomic.make noop_tool_event_sink
let pr_event_sink = Atomic.make noop_pr_event_sink
let turn_event_sink = Atomic.make noop_turn_event_sink

let register_tool_event_sink sink = Atomic.set tool_event_sink sink
let register_pr_event_sink sink = Atomic.set pr_event_sink sink
let register_turn_event_sink sink = Atomic.set turn_event_sink sink

let emit_tool_event event = Atomic.get tool_event_sink event
let emit_pr_event event = Atomic.get pr_event_sink event
let emit_turn_event event = Atomic.get turn_event_sink event

let reset_for_testing () =
  Atomic.set tool_event_sink noop_tool_event_sink;
  Atomic.set pr_event_sink noop_pr_event_sink;
  Atomic.set turn_event_sink noop_turn_event_sink
;;
