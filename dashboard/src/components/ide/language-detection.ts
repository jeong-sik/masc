const EXTENSION_MAP: Readonly<Record<string, string>> = {
  '.ml': 'ocaml', '.mli': 'ocaml',
  '.ts': 'typescript', '.tsx': 'typescript',
  '.js': 'javascript', '.jsx': 'javascript',
  '.py': 'python', '.rs': 'rust',
  '.md': 'markdown', '.json': 'json',
  '.toml': 'toml', '.yaml': 'yaml', '.yml': 'yaml',
  '.css': 'css', '.html': 'html', '.xml': 'xml',
  '.sh': 'bash', '.bash': 'bash', '.zsh': 'bash',
  '.sql': 'sql', '.go': 'go',
  '.java': 'java', '.kt': 'kotlin', '.scala': 'scala',
  '.rb': 'ruby', '.php': 'php',
  '.c': 'c', '.cpp': 'cpp', '.h': 'c', '.hpp': 'cpp',
  '.cs': 'csharp', '.swift': 'swift',
  '.lua': 'lua', '.r': 'r',
  '.ex': 'elixir', '.exs': 'elixir',
  '.erl': 'erlang', '.hrl': 'erlang',
  '.clj': 'clojure', '.hs': 'haskell',
}

export function languageFromPath(path: string): string {
  const filename = path.split('/').pop() ?? ''
  if (filename === 'dune' || filename === 'dune-project') return 'dune'
  const dot = filename.lastIndexOf('.')
  if (dot < 0) return 'text'
  return EXTENSION_MAP[filename.slice(dot)] ?? 'text'
}
