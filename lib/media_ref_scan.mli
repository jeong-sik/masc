(** Pure shared Markdown/HTML workspace media & Obsidian embed scanner.

    Leaf module shared by {!Wiki_link} and {!Published_artifact} so Markdown
    fence/code-span blanking, Obsidian embed splitting, and
    [/api/v1/media/<sha256>] scanning have one single source of truth with zero
    module dependency cycles. *)

val is_valid_media_token : string -> bool
(** [true] iff [token] is a valid 64-char lowercase hex SHA-256 digest. *)

val blank_code_spans : string -> string
(** Replace backtick-delimited inline code spans on a single line with spaces
    so links and embeds inside code spans are ignored. *)

val fence_of_line : string -> (char * int * string) option
(** Detect a CommonMark fenced code block delimiter (at most 3 leading spaces
    followed by 3+ backticks or tildes). Returns [(mark, count, trimmed_info)]. *)

val fold_unquoted_lines :
  (line_no:int -> string -> 'a list -> 'a list) -> string -> 'a list
(** Fold [scan] over every line outside fenced code blocks with inline code
    spans blanked, returning accumulated items in reading order. *)

val split_obsidian_inner : string -> string * string option
(** Split the body inside [![[...]]] on the first ['|'], trimming both the
    target and the optional label. Empty trimmed labels become [None]. *)

val split_obsidian_scheme_payload :
  string -> [ `Bare of string | `Qualified of string * string ]
(** Split a trimmed Obsidian target on the first [':'], trimming both scheme
    and payload to stay in lockstep with Dashboard [parseObsidianEmbed]. *)

val extract_url_media_refs : string -> string list -> string list
(** Scan [text] for boundary-delimited [/api/v1/media/<64-hex>] tokens and
    prepend valid tokens onto [acc]. *)

val extract_obsidian_media_refs : string -> string list -> string list
(** Scan an unquoted Markdown line for [![[media:<64-hex>]]] embeds (with
    trimmed scheme/target) and prepend valid tokens onto [acc]. *)

val blank_html_comments_and_scripts : string -> string
(** Blank HTML comments ([<!-- ... -->]) and [<script>...</script>] blocks with
    spaces while preserving [<style>] blocks so CSS
    [url(/api/v1/media/<sha256>)] references are discovered and commented
    [<script>] tags do not swallow subsequent HTML. *)

val extract_markdown_media_refs : string -> string list
(** Extract sorted, deduplicated 64-hex workspace media tokens from Markdown
    outside fenced code blocks and inline code spans (covering Obsidian media
    embeds, Markdown image URLs, and inline HTML media URLs). *)

val extract_html_media_refs : string -> string list
(** Extract sorted, deduplicated 64-hex workspace media tokens from HTML
    outside HTML comments and [<script>] blocks (including [<style>] CSS
    [url(/api/v1/media/...)] references). *)
