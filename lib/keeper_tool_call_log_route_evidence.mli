(** Route evidence extraction for keeper tool-call I/O records. *)

val route_evidence_json_of_tool_io
  :  max_output_len:int
  -> tool_name:string
  -> input:Yojson.Safe.t
  -> output_text:string
  -> execution_evidence:Yojson.Safe.t option
  -> Yojson.Safe.t option
(** [execution_evidence] is a completed Execute's audit object (see
    {!Keeper_tool_call_log.execution_evidence_of_metadata}); its [via] and
    [sandbox_profile] are read beside the output's route fields. *)
