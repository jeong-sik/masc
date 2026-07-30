(** Slack_mrkdwn_converter — Converts standard markdown text to Slack mrkdwn format safely. *)

(* Static pre-compiled regular expressions for high performance *)
let re_code_block = Re.Pcre.regexp "```[\\s\\S]*?```|`[^`\\n]+`"
let re_link = Re.Pcre.regexp "\\[([^\\]]+)\\]\\((https?://[^\\s)]+)\\)?"
let re_bold = Re.Pcre.regexp "\\*\\*([^*]+)\\*\\*"
let re_header = Re.Pcre.regexp "^#{1,6}\\s+(.+)$"
let re_bullet = Re.Pcre.regexp "^(\\s*)[-*+]\\s+(.+)$"

(** Escape raw Slack special characters outside formed tags *)
let escape_slack_raw text =
  let buf = Buffer.create (String.length text) in
  String.iter
    (function
      | '&' -> Buffer.add_string buf "&amp;"
      | '<' -> Buffer.add_string buf "&lt;"
      | '>' -> Buffer.add_string buf "&gt;"
      | c -> Buffer.add_char buf c)
    text;
  Buffer.contents buf

(** Preserve code blocks from being corrupted during markdown conversion *)
let preserve_code_blocks text =
  let blocks = ref [] in
  let counter = ref 0 in
  let protected_text =
    Re.Pcre.substitute ~rex:re_code_block ~subst:(fun matched ->
      let placeholder = Printf.sprintf "\x00SLACK_CODE_%d\x00" !counter in
      incr counter;
      blocks := (placeholder, matched) :: !blocks;
      placeholder
    ) text
  in
  (protected_text, List.rev !blocks)

let restore_code_blocks text blocks =
  List.fold_left (fun acc (placeholder, original_code) ->
    let re_place = Re.Pcre.regexp (Re.Pcre.quote placeholder) in
    Re.Pcre.substitute ~rex:re_place ~subst:(fun _ -> original_code) acc
  ) text blocks

let convert_markdown_links text =
  Re.Pcre.substitute ~rex:re_link ~subst:(fun matched ->
    try
      let groups = Re.Pcre.exec ~rex:re_link matched in
      let label = Re.Pcre.get_substring groups 1 in
      let url = Re.Pcre.get_substring groups 2 in
      Printf.sprintf "<%s|%s>" url (escape_slack_raw label)
    with _ -> matched
  ) text

let convert_bold text =
  Re.Pcre.substitute ~rex:re_bold ~subst:(fun matched ->
    try
      let groups = Re.Pcre.exec ~rex:re_bold matched in
      let inner = Re.Pcre.get_substring groups 1 in
      Printf.sprintf "*%s*" inner
    with _ -> matched
  ) text

let convert_headers line =
  if Re.Pcre.pmatch ~rex:re_header line then
    try
      let groups = Re.Pcre.exec ~rex:re_header line in
      let content = Re.Pcre.get_substring groups 1 in
      Printf.sprintf "*%s*" content
    with _ -> line
  else
    line

let convert_bullets line =
  if Re.Pcre.pmatch ~rex:re_bullet line then
    try
      let groups = Re.Pcre.exec ~rex:re_bullet line in
      let indent = Re.Pcre.get_substring groups 1 in
      let content = Re.Pcre.get_substring groups 2 in
      Printf.sprintf "%s• %s" indent content
    with _ -> line
  else
    line

let to_slack_mrkdwn input =
  let protected_text, code_blocks = preserve_code_blocks input in
  let lines = String.split_on_char '\n' protected_text in
  let converted_lines =
    List.map (fun line ->
      let l1 = convert_headers line in
      let l2 = convert_bullets l1 in
      let l3 = convert_markdown_links l2 in
      let l4 = convert_bold l3 in
      l4
    ) lines
  in
  let formatted = String.concat "\n" converted_lines in
  restore_code_blocks formatted code_blocks
