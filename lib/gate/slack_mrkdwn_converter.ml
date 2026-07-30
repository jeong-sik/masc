(** Slack_mrkdwn_converter — Converts standard markdown text to Slack mrkdwn format. *)

let convert_markdown_links text =
  let re = Re.Pcre.regexp "\\[([^\\]]+)\\]\\(([^\\)]+)\\)" in
  Re.Pcre.substitute ~rex:re ~subst:(fun matched ->
    try
      let groups = Re.Pcre.exec ~rex:re matched in
      let label = Re.Pcre.get_substring groups 1 in
      let url = Re.Pcre.get_substring groups 2 in
      Printf.sprintf "<%s|%s>" url label
    with _ -> matched
  ) text

let convert_bold text =
  let re = Re.Pcre.regexp "\\*\\*([^*]+)\\*\\*" in
  Re.Pcre.substitute ~rex:re ~subst:(fun matched ->
    try
      let groups = Re.Pcre.exec ~rex:re matched in
      let inner = Re.Pcre.get_substring groups 1 in
      Printf.sprintf "*%s*" inner
    with _ -> matched
  ) text

let convert_headers line =
  let re = Re.Pcre.regexp "^#{1,6}\\s+(.+)$" in
  if Re.Pcre.pmatch ~rex:re line then
    try
      let groups = Re.Pcre.exec ~rex:re line in
      let content = Re.Pcre.get_substring groups 1 in
      Printf.sprintf "*%s*" content
    with _ -> line
  else
    line

let convert_bullets line =
  let re = Re.Pcre.regexp "^(\\s*)[-*+]\\s+(.+)$" in
  if Re.Pcre.pmatch ~rex:re line then
    try
      let groups = Re.Pcre.exec ~rex:re line in
      let indent = Re.Pcre.get_substring groups 1 in
      let content = Re.Pcre.get_substring groups 2 in
      Printf.sprintf "%s• %s" indent content
    with _ -> line
  else
    line

let to_slack_mrkdwn input =
  let lines = String.split_on_char '\n' input in
  let converted_lines =
    List.map (fun line ->
      let l1 = convert_headers line in
      let l2 = convert_bullets l1 in
      let l3 = convert_markdown_links l2 in
      let l4 = convert_bold l3 in
      l4
    ) lines
  in
  String.concat "\n" converted_lines
