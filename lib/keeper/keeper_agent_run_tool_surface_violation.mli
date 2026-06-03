val to_sdk_error
  :  keeper_name:string
  -> runtime_id:string
  -> visible_tool_names:string list
  -> unexpected_tool_names:string list
  -> Agent_sdk.Error.sdk_error
