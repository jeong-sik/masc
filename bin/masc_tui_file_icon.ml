(* A file's type mark for the Code tree, chosen by extension. The kind is a
   closed set so the renderer's colour match stays exhaustive -- add a kind and
   the compiler names every colour that has not answered for it. The glyph is
   plain unicode (Geometric Shapes / Latin-1), never a Nerd Font private-use
   codepoint, so it draws in any monospace terminal. Colour is the renderer's
   to pick; this module carries the mapping and the glyph only. *)

type kind =
  | Code
  | Data
  | Prose
  | Script
  | Web
  | Media
  | Plain

let extension name =
  match String.rindex_opt name '.' with
  | Some dot when dot > 0 ->
      String.lowercase_ascii (String.sub name dot (String.length name - dot))
  | _ -> ""

let kind_of_name name =
  match extension name with
  | ".ml" | ".mli" | ".re" | ".rei" | ".ts" | ".tsx" | ".js" | ".jsx" | ".mjs"
  | ".cjs" | ".py" | ".rs" | ".go" | ".c" | ".h" | ".cpp" | ".cc" | ".hpp"
  | ".java" | ".rb" | ".php" | ".lua" | ".ex" | ".exs" | ".hs" | ".scala"
  | ".kt" | ".swift" | ".dart" | ".sql" ->
      Code
  | ".json" | ".toml" | ".yaml" | ".yml" | ".xml" | ".csv" | ".ini" | ".conf"
  | ".lock" | ".env" ->
      Data
  | ".md" | ".markdown" | ".txt" | ".rst" | ".org" | ".adoc" -> Prose
  | ".sh" | ".bash" | ".zsh" | ".fish" | ".ps1" | ".bat" -> Script
  | ".html" | ".htm" | ".css" | ".scss" | ".sass" | ".less" | ".vue"
  | ".svelte" ->
      Web
  | ".png" | ".jpg" | ".jpeg" | ".gif" | ".svg" | ".webp" | ".ico" | ".pdf"
  | ".mp4" | ".mp3" | ".wav" ->
      Media
  | _ -> Plain

let glyph = function
  | Code -> "\xe2\x97\x86" (* U+25C6 BLACK DIAMOND *)
  | Data -> "\xe2\x96\xa4" (* U+25A4 SQUARE WITH HORIZONTAL FILL *)
  | Prose -> "\xe2\x89\xa1" (* U+2261 IDENTICAL TO -- stacked lines like text *)
  | Script -> "\xc2\xbb" (* U+00BB RIGHT-POINTING DOUBLE ANGLE QUOTATION *)
  | Web -> "\xe2\x97\x88" (* U+25C8 WHITE DIAMOND CONTAINING BLACK DIAMOND *)
  | Media -> "\xe2\x96\xa8" (* U+25A8 SQUARE WITH UPPER RIGHT TO LOWER LEFT FILL *)
  | Plain -> "\xc2\xb7" (* U+00B7 MIDDLE DOT *)
