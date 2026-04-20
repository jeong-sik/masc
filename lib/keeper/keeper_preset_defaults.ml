let preset_of_defaults_warn ~call_site ~defaults_tool_preset =
  match defaults_tool_preset with
  | None -> None
  | Some raw ->
      (match Keeper_types.tool_preset_of_string raw with
       | Some _ as v -> v
       | None ->
           Log.Keeper.warn
             "%s: unknown tool_preset %S in profile defaults \
              -> falling back to caller default (drift; see #8605)"
             call_site raw;
           None)
