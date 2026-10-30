type snapshot = unit
type stream_state = unit

let snapshot ~base_path:_ ~keeper_name:_ = ()
let redact_text () text = text
let create_stream_state () = ()
let redact_stream_chunk () text = text
let redact_stream_finish () = ""
