
let sensitive_flags =
  [ "--token"; "--password"; "--passwd"; "--auth-token"; "--api-key"
  ; "--secret"; "--apikey"; "--client-secret"
  ]
;;

(* Every entry of [sensitive_flags] must have its equals-form covered here:
   [flat_stage_words] hands [--secret=abc] over as one literal word, and the
   whole-word flag check never sees it. [secret=] covers [--secret=] and
   [--client-secret=]; [token=] already covers [--token=] and [--auth-token=].
   [access_key=] covers AWS_SECRET_ACCESS_KEY and AWS_ACCESS_KEY assignments;
   [access_key_id=] covers AWS_ACCESS_KEY_ID, including opaque values
   that do not carry a recognizable credential prefix. *)
let sensitive_assignment_markers =
  [ ":_authtoken="; "_authtoken="; "token="; "password="; "passwd="; "api-key="
  ; "secret="; "apikey="; "api_key="; "access_key="; "access_key_id="
  ; "bearer_token_bedrock="
  ]
;;

let redact_inline_secret_assignment token =
  (* Markers are lowercase; the match runs against a lowercased copy so
     [TOKEN=] and [Password=] redact like [token=], while the kept prefix
     is spliced from the token as it came. The copy is rebuilt per marker
     because an earlier marker may already have shortened the token. *)
  let redact_after token marker =
    match String_util.find_substring (String.lowercase_ascii token) marker with
    | Some idx -> String.sub token 0 (idx + String.length marker) ^ "[REDACTED]"
    | None -> token
  in
  List.fold_left redact_after token sensitive_assignment_markers
;;

let command_has_sensitive_marker cmd =
  let lower = String.lowercase_ascii cmd in
  List.exists (fun flag -> String_util.contains_substring lower flag) sensitive_flags
  || List.exists
       (fun marker -> String_util.contains_substring lower (String.lowercase_ascii marker))
       sensitive_assignment_markers
;;

let sanitize_parts parts =
  let rec redact prev_sensitive acc = function
    | [] -> String.concat " " (List.rev acc)
    | part :: rest ->
      let part =
        if prev_sensitive && part <> ""
        then "[REDACTED]"
        else part |> Url_userinfo.redact_text |> redact_inline_secret_assignment
      in
      let next_sensitive = List.mem (String.lowercase_ascii part) sensitive_flags in
      redact next_sensitive (part :: acc) rest
  in
  redact false [] parts
;;

let sanitize_command_for_log cmd =
  let trimmed = String.trim cmd in
  if trimmed = ""
  then "[EMPTY]"
  else if command_has_sensitive_marker cmd
  then "[REDACTED]"
  else cmd |> Url_userinfo.redact_text |> redact_inline_secret_assignment
;;

let sanitize_command_for_log_of_ir ~fallback_cmd ir =
  match Exec_policy_literal_words.flat_stage_words ir with
  | [] -> sanitize_command_for_log fallback_cmd
  | parts -> sanitize_parts parts
;;

let truncate_for_log ?(max_len = 240) s =
  String_util.utf8_safe ~max_bytes:(max_len + 3) ~suffix:"..." s |> String_util.to_string
;;
