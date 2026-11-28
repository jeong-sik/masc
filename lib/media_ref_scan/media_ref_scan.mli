(** Pure shared Markdown/HTML workspace media & Obsidian embed scanner.

    Leaf library shared by {!Wiki_link}, {!Published_artifact} and attachment
    GC ([Tool_blob_sweep]) so Markdown fence/code-span blanking, Obsidian embed
    splitting, and canonical [/api/v1/attachments/att_<64-hex>] (plus legacy
    [/api/v1/media/<64-hex>]) scanning have one single source of truth with
    zero module dependency cycles. *)

val obsidian_media_scheme : string
(** The scheme of an Obsidian media embed: ["media"] in [![[media:<token>]]]. *)

val is_valid_media_token : string -> bool
(** [true] iff [token] is a valid 64-char lowercase hex SHA-256 digest. *)

val parse_media_token : string -> string option
(** Parse either canonical [att_<64-hex>] or bare [<64-hex>] into the
    normalized 64-char lowercase hex SHA-256 digest. *)

val parse_attachment_id_token : string -> string option
(** Parse strictly canonical [att_<64-hex>] into the normalized 64-char
    lowercase hex SHA-256 digest. *)

val strip_url_query : string -> string
(** Return the substring before the first ['?'], or the full string if absent. *)

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
(** Scan [text] for boundary-delimited [/api/v1/attachments/att_<64-hex>]
    (with optional query params) and legacy [/api/v1/media/<64-hex>] (or
    [att_<64-hex>]) tokens, prepending normalized 64-hex digests onto [acc]. *)

val extract_obsidian_media_refs : string -> string list -> string list
(** Scan an unquoted Markdown line for [![[media:att_<64-hex>]]] or legacy
    [![[media:<64-hex>]]] embeds (with trimmed scheme/target) and prepend
    normalized 64-hex digests onto [acc]. *)

val blank_html_comments_and_scripts : string -> string
(** Blank HTML comments ([<!-- ... -->]) and [<script>...</script>] blocks with
    spaces while preserving [<style>] blocks so CSS
    [url(/api/v1/attachments/att_<sha256>)] and [url(/api/v1/media/<sha256>)]
    references are discovered and commented [<script>] tags do not swallow
    subsequent HTML. *)

val extract_markdown_media_refs : string -> string list
(** Extract sorted, deduplicated 64-hex workspace media digests from Markdown
    outside fenced code blocks and inline code spans (covering Obsidian media
    embeds, Markdown image URLs, and inline HTML media URLs). *)

val extract_html_media_refs : string -> string list
(** Extract sorted, deduplicated 64-hex workspace media digests from HTML
    outside HTML comments and [<script>] blocks (including [<style>] CSS
    [url(...)] references). *)

val extract_bare_media_digests : string -> string list
(** Every 64-hex digest [text] names through a bare (no [att_]) media form,
    anywhere in [text]: right after [/api/v1/media/], or after
    {!obsidian_media_scheme}, a colon and optional spaces. The digest must not
    run on into another hex digit. Nothing else around it is checked: no
    [![[]/[]]] pair, URL boundary, code span or fence. Code spans and the JSON
    escapes of tab, carriage return and form feed count as spaces, as the
    reader's code-span blanking and the JSON decoder make them. So a reference a reader
    resolves on decoded Markdown is also found on the raw bytes of the
    Markdown, HTML, JSON or JSONL file that stores it, and attachment GC keeps
    its blob. Canonical [att_<64-hex>] ids are left to
    [Attachment_store.referenced_sha256_of_json_text]. Sorted, deduplicated. *)
