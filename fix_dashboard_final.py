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

process("dashboard/src/api/dashboard.ts", [
    (r'\s*AgentCollaborator,', ''),
])

process("dashboard/src/api/schemas/agent-relations.ts", [
    (r'const AgentCollaboratorSchema =.*?export type AgentCollaborator = InferOutput<typeof AgentCollaboratorSchema>', ''),
    (r'collaborators: array\(AgentCollaboratorSchema\),', ''),
])

process("dashboard/src/components/agent-profile.ts", [
    (r'const collabs = rel\.collaborators.*?\n\s*let collab_summary =.*?\n', '\n'),
    (r'<\$\{AgentDetailMemory\}.*?collaborators=\$\{collabs\}.*?/>', ''),
])

# Remove doc mentions
process("docs/KEEPER-USER-MANUAL.md", [
    (r'- delivery swarm.*?\n', ''),
    (r'Agent collaboration rooms.*?\n', ''),
])

process("ROADMAP.md", [
    (r'\| v2\.88\.0 \| Reliable Swarm.*?\n', ''),
    (r'\| v2\.89\.0 \| Visible Swarm.*?\n', ''),
    (r'\| v2\.90\.0 \| Recoverable Swarm.*?\n', ''),
    (r'delivery-swarm ergonomics.*?\n', ''),
])

print("done dashboard docs")
