val to_sdk_error
  :  keeper_name:string
  -> cascade_name:string
  -> requested_tool_names_seen:string list
  -> unexpected_tool_names:string list
  -> Agent_sdk.Error.sdk_error
