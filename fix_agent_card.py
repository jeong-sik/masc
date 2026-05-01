import re
import os

def process(filepath, sub_ops):
    if not os.path.exists(filepath): return
    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()
    for search, repl in sub_ops:
        content = re.sub(search, repl, content, flags=re.MULTILINE | re.DOTALL)
    with open(filepath, 'w', encoding='utf-8') as f:
        f.write(content)

process("lib/tool_name.ml", [
    (r'\s*\| Agent_card', ''),
    (r'\s*\| Agent_card -> "masc_agent_card"', ''),
    (r'\s*\| "masc_agent_card" -> Some Agent_card', ''),
])

process("lib/tool_name.mli", [
    (r'\s*\| Agent_card', ''),
])

process("lib/tool_catalog.ml", [
    (r'\s*\| TN\.Masc TM\.Agent_card\n', '\n'),
    (r'\| TM\.Agent_card ', ''),
    (r'\("masc_agent_card", readonly_tool\);', ''),
])

process("lib/tool_agent.ml", [
    (r'type agent_card_action =.*?\n\n', ''),
    (r'let agent_card_action_to_string =.*?\n\n', ''),
    (r'let agent_card_action_of_string_opt.*?\n\n', ''),
    (r'let all_agent_card_actions =.*?\n', ''),
    (r'let valid_agent_card_action_strings =.*?\n\n', ''),
    (r'\(\*\* Handle masc_agent_card \*\).*?handle_agent_card.*?\n\s*\| "masc_agent_card" -> Some \(handle_agent_card ctx args\)\n', ''),
    (r'let handle_agent_card.*?let json = Agent_card\.to_json card in\n\s*\(true, Yojson\.Safe\.to_string json\)\n', ''),
    (r'\s*\| "masc_agent_card" -> Some \(handle_agent_card ctx args\)', ''),
    (r'\s*"masc_agent_card";?', ''),
    (r'\| "masc_agent_card" ', ''),
])

process("lib/tool_agent.mli", [
    (r'type agent_card_action = Get \| Refresh\n', ''),
    (r'val agent_card_action_to_string : agent_card_action -> string\n', ''),
    (r'val agent_card_action_of_string_opt : string -> agent_card_action option\n', ''),
    (r'val all_agent_card_actions : agent_card_action list\n', ''),
    (r'val valid_agent_card_action_strings : string list\n', ''),
    (r'val handle_agent_card : context -> Yojson\.Safe\.t -> bool \* string\n', ''),
])

process("lib/mcp_server_eio_protocol.ml", [
    (r'\s*Agent_card\.invalidate_cache \(\);', ''),
])

process("lib/transport_bridge.ml", [
    (r'let agent_card_transports_json.*?\n\s*`List \[\]\n', ''),
])

process("lib/transport_bridge.mli", [
    (r'val agent_card_transports_json : host:string -> port:int -> Yojson\.Safe\.t\n', ''),
])

process("lib/server/server_auth.ml", [
    (r'let serve_agent_card ~host ~port request reqd =\n.*?Httpun\.Reqd\.respond_with_string reqd response body\n', ''),
])

process("lib/server/server_auth.mli", [
    (r'val serve_agent_card :\n\s*host:string ->\n\s*port:int ->\n\s*Httpun\.Request\.t -> Httpun\.Reqd\.t -> unit\n', ''),
])

process("lib/server/server_routes_http_routes_frontend.ml", [
    (r'\s*\|> Http\.Router\.get "/\.well-known/agent\.json" \(serve_agent_card ~host ~port\)', ''),
    (r'\s*\|> Http\.Router\.get "/\.well-known/agent-card\.json" \(serve_agent_card ~host ~port\)', ''),
])

process("lib/server/server_bootstrap_loops.ml", [
    (r'\s*let hb_reaped = A2a_tools\.cleanup_stale_heartbeats ~active_agents \(\) in', ''),
    (r'\s*let buf_reaped = A2a_tools\.cleanup_orphan_buffers \(\) in', ''),
    (r'\s*let sub_expired = A2a_tools\.cleanup_stale_subscriptions \(\) in', ''),
    (r'\s*A2a_tools\.init ~masc_dir;', ''),
])

process("lib/shutdown_hooks.ml", [
    (r'\s*\(try A2a_tools\.clear_transient_state \(\).*?with\n\s*\| _ -> Log\.Server\.warn "\[Shutdown\] a2a_tools clear failed"\);', ''),
])

process("lib/tool_schemas/tool_schemas_agent.ml", [
    (r'let agent_card_action_enum_strings = \[ "get"; "refresh" \]\n', ''),
    (r'\s*\{\n\s*name = "masc_agent_card";.*?\n\s*\};\n', '\n'),
])

process("lib/tool_schemas/tool_schemas_agent.mli", [
    (r'val agent_card_action_enum_strings : string list\n', ''),
    (r'\[masc_agent_card\],', ''),
])

process("lib/keeper/keeper_agent_tool_surface.ml", [
    (r'\s*; "masc_agent_card", ".*?"', ''),
])

process("lib/tool_catalog_surfaces.ml", [
    (r'\s*"masc_agent_card";', ''),
])

process("lib/tool_prefilter.ml", [
    (r'\s*\("masc_agent_card",\s*\[\]\);\n', ''),
])

process("lib/tool_permission_map.ml", [
    (r'\s*\("masc_agent_card", CanReadState\);\n', ''),
])

print("done")
