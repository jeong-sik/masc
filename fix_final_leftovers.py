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

process("lib/operator/operator_control_snapshot.ml", [
    (r'\s*in\s*\|\s*Some task, Some result.*?\n\s*let agent_card = `Null in', '\n  let agent_card = `Null in'),
])

process("lib/server/server_auth.ml", [
    (r'\s*let card =.*?Agent_card\.get_cached.*?in', '\n      let card = `Null in'),
])

print("done")
