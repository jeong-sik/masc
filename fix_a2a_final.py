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

process("lib/agent_identity.ml", [
    (r'\s*\(used by \[Lib\.A2a_tools\] \(.*?\)\)\. \*\)', ''),
])

process("lib/coord/nickname.ml", [
    (r'\s*Same discipline as \[Lib\.A2a_tools\]', ''),
])

process("lib/mention_inbox.ml", [
    (r'\s*Same discipline as \[Lib\.A2a_tools\]', ''),
])

process("lib/operator/operator_control_snapshot.ml", [
    (r'\s*match A2a_tools\.latest_heartbeat_task.*?\n\s*A2a_tools\.latest_heartbeat_result.*?with\n', ''),
])

process("lib/server/server_auth.ml", [
    (r'\s*let a2a_version = A2a_tools\.default_a2a_version in', 'let a2a_version = "v0.3.0" in'),
])

process("lib/shutdown_hooks.ml", [
    (r'\s*\(try A2a_tools\.clear_transient_state.*?\);', ''),
])

process("lib/shutdown_hooks.mli", [
    (r'\s*and clears transient A2A and', 'and clears'),
    (r'\s*5\. Clear \[A2a_tools\] transient state\.', ''),
])

print("done")
