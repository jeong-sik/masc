(** Route evidence extraction for keeper tool-call I/O records. *)

val route_evidence_json_of_tool_io
  :  max_output_len:int
  -> tool_name:string
  -> input:Yojson.Safe.t
  -> output_text:string
  -> Yojson.Safe.t option
