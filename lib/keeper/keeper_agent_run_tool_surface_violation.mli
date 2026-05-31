val to_sdk_error
  :  keeper_name:string
  -> runtime_id:string
  -> requested_tool_names_seen:string list
  -> unexpected_tool_names:string list
  -> Agent_sdk.Error.sdk_error
