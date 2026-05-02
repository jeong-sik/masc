(** P12 — Network egress policy for Docker sandbox execution.

    Pure module: domain allowlist loading, matching, and structured
    error generation.  No I/O beyond file reading; no knowledge of
    Docker or keeper internals.

    Policy source: [egress.json] in the keeper's config directory.
    Empty, missing, unreadable, or invalid policy = fail closed for
    commands with extracted outbound domains.
    Wildcard suffix: ["*.github.com"] matches ["api.github.com"]. *)

type t = {
  allowed : string list;
  source : string;
}

let empty = { allowed = []; source = "(no egress policy)" }

let of_allowed ~source domains =
  let normalized =
    List.map (fun d ->
      String.trim (String.lowercase_ascii d)
    ) domains
  in
  { allowed = normalized; source }

(** Domain matching rules:
    - Exact match after lowercasing
    - Wildcard prefix ["*.x.com"] matches ["sub.x.com"] and ["x.com"] *)
let domain_allowed policy domain =
  let d = String.trim (String.lowercase_ascii domain) in
  let suffix_match ~suffix target =
    target = suffix
    || (String.length target > String.length suffix + 1
        && String.sub target (String.length target - String.length suffix - 1)
             (String.length suffix + 1)
           = "." ^ suffix)
  in
  List.exists (fun pattern ->
    if String.length pattern > 2 &&
       Base.String.is_prefix pattern ~prefix:"*." then begin
      let suffix = String.sub pattern 2 (String.length pattern - 2) in
      suffix_match ~suffix d
    end else
      d = pattern
  ) policy.allowed

(** Extract domains from a command string.

    Looks for patterns like:
    - [curl https://example.com/...]
    - [wget http://example.com/...]
    - [git clone https://github.com/...]

    Returns the host portion only (lowercased). *)
let extract_domains_from_command cmd =
  let re =
    let open Re in
    let url_prefix =
      alt [ str "https://"; str "http://"; str "git://" ]
    in
    let host = group (rep1 (compl [ set "/ \t\n\r\"'"; ])) in
    compile (seq [ url_prefix; host ])
  in
  let matches = Re.all re cmd in
  List.filter_map (fun m ->
    match Re.Group.get m 1 with
    | host ->
        (* Strip port *)
        match String.index_opt host ':' with
        | None -> Some (String.lowercase_ascii host)
        | Some i -> Some (String.lowercase_ascii (String.sub host 0 i))
    | exception Not_found -> None
  ) matches

type check_result =
  | Allowed
  | Blocked of { attempted : string; allowed : string list }

(** Check a command against the policy.

    If the policy has no allowed domains, commands with extracted outbound
    domains are blocked. Commands without extracted domains are allowed.

    If the policy has allowed domains, any URL in the command must
    match at least one allowed domain. *)
let check_command policy cmd =
  let domains = extract_domains_from_command cmd in
  match List.find_opt (fun d -> not (domain_allowed policy d)) domains with
  | None -> Allowed
  | Some blocked_domain ->
      Blocked { attempted = blocked_domain; allowed = policy.allowed }

(** Format a blocked result as a structured JSON string.

    [expected_policy_path] is the on-disk path the caller resolved for
    this keeper's [egress.json].  When supplied, the JSON includes
    [expected_policy_path] plus a humanish [reason] aimed at the LLM
    consumer — empty allowlist points operator at "seed this file",
    non-empty-but-unmatched allowlist points at "extend this file".

    Without [expected_policy_path], the legacy schema is preserved so
    callers that have no path context (tests, generic utilities) keep
    working unchanged. *)
let blocked_to_json ?expected_policy_path (blocked : check_result) =
  let json : Yojson.Safe.t =
    match blocked with
    | Allowed -> `Assoc [ ("ok", `Bool true) ]
    | Blocked { attempted; allowed } ->
        let base =
          [
            ("ok", `Bool false);
            ("error", `String "egress_blocked");
            ("attempted", `String attempted);
            ("allowed", `List (List.map (fun d -> `String d) allowed));
          ]
        in
        let extras =
          match expected_policy_path with
          | None -> []
          | Some path ->
              let reason =
                if allowed = [] then
                  Printf.sprintf
                    "egress allowlist empty or unreadable for this keeper; \
                     operator should seed %s with the required domains \
                     (e.g. \"*.github.com\", \"*.npmjs.org\") and retry"
                    path
                else
                  Printf.sprintf
                    "domain %s not in egress allowlist at %s; operator must \
                     add it before this command can succeed"
                    attempted path
              in
              [
                ("expected_policy_path", `String path);
                ("reason", `String reason);
              ]
        in
        `Assoc (base @ extras)
  in
  Yojson.Safe.to_string json

(** Load policy from a JSON string.

    Expected format: ["github.com", "*.npmjs.org"]

    Returns [empty] on parse failure (fail-closed: no domains allowed). *)
let of_json_string ~source json_str =
  match Yojson.Safe.from_string json_str with
  | `List items ->
      let domains = List.filter_map (function
        | `String s -> Some (String.trim s)
        | _ -> None
      ) items in
      of_allowed ~source domains
  | _ -> empty
  | exception Yojson.Json_error _ -> empty

(** Load policy from a file path.

    Returns [empty] if the file does not exist or is unreadable.
    [empty] is fail-closed for commands with extracted outbound domains. *)
let of_file path =
  match Stdlib.In_channel.with_open_bin path Stdlib.In_channel.input_all with
  | json_str ->
      of_json_string ~source:path json_str
  | exception Sys_error _ -> empty

let to_allowed_domains t = t.allowed
