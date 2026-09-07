(** [masc_web_search] and [masc_web_fetch], read from
    [config/tools/masc_web_*.toml] (RFC
    prompts-and-tool-definitions-outside-ocaml §2.2).

    Decoded once at module initialization; a missing or undecodable file
    refuses the boot rather than advertising a partial web surface.
    [Keeper_tool_descriptor] names each value directly rather than reaching
    them through a list. *)

let schema_of_name name : Masc_domain.tool_schema =
  let rel = "tools/" ^ name ^ ".toml" in
  match Embedded_config.read rel with
  | None -> failwith (Printf.sprintf "embedded tool definition missing: %s" rel)
  | Some contents ->
    (match Tool_definition_toml.load ~name ~contents with
     | Ok { Tool_definition_toml.schema; _ } -> schema
     | Error message -> failwith message)
;;

let web_search = schema_of_name "masc_web_search"
let web_fetch = schema_of_name "masc_web_fetch"
let browser_tabs = schema_of_name "masc_browser_tabs"
let browser_read = schema_of_name "masc_browser_read"
let browser_session = schema_of_name "masc_browser_session"
let browser_goto = schema_of_name "masc_browser_goto"
let browser_interact = schema_of_name "masc_browser_interact"
let slack_read = schema_of_name "masc_slack_read"
let msx_load = schema_of_name "masc_msx_load"
let msx_eject = schema_of_name "masc_msx_eject"
let msx_screen = schema_of_name "masc_msx_screen"
let msx_press = schema_of_name "masc_msx_press"
let msx_step = schema_of_name "masc_msx_step"
