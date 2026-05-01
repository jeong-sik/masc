import os
import re

def process(filepath, sub_ops):
    if not os.path.exists(filepath): return
    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()
    for search, repl in sub_ops:
        content = re.sub(search, repl, content, flags=re.MULTILINE | re.DOTALL)
    with open(filepath, 'w', encoding='utf-8') as f:
        f.write(content)

process("dashboard/src/components/keeper-config-panel.test.ts", [
    (r'\s*shared_memory_scope:.*?,', ''),
    (r'\s*expect\(draft\.shared_memory_scope\).*?\n', '\n'),
    (r'\s*expect\(payload\.shared_memory_scope\).*?\n', '\n'),
    (r'\s*it\(\'emits shared_memory_scope.*?\n\s*\}\)\n', '\n'),
    (r'\s*const sharedMemory = container\.querySelector.*?HTMLSelectElement \| null\n', ''),
    (r'\s*expect\(sharedMemory\?.value\).*?\n', ''),
])

process("dashboard/src/components/keeper-config-panel.ts", [
    (r', shared_memory_scope', ''),
    (r'<ConfigSelect\s*label="shared_memory_scope"\s*value=\$\{rd\.shared_memory_scope\}\s*options=\$\{SHARED_MEMORY_OPTIONS\}\s*onChange=\$\{\(value: string\) => updateRuntimeDraft\(\'shared_memory_scope\', value as SharedMemoryScope\)\}\s*/>', ''),
    (r'<\$\{ConfigRow\}\s*label="shared_memory_scope"\s*value=\$\{c\.shared_memory_scope \?\? \'disabled\'\}\s*/>', ''),
    (r'const SHARED_MEMORY_OPTIONS =.*?\]\n\n', ''),
])

process("dashboard/src/types/governance.ts", [
    (r'\s*shared_memory_scope\?: string \| null', ''),
])

print("done")
