type t =
  | Ok_0
  | Policy_blocked
  | Type_mismatch
  | Auth_failed
  | Network
  | Unknown

let to_string = function
  | Ok_0 -> "Ok_0"
  | Policy_blocked -> "Policy_blocked"
  | Type_mismatch -> "Type_mismatch"
  | Auth_failed -> "Auth_failed"
  | Network -> "Network"
  | Unknown -> "Unknown"
;;

type rule =
  { exit_code : int
  ; stderr_contains : string option
  ; class_ : t
  }

(* Empty needle preserves the legacy "matches all" semantic; non-empty
   matching delegates to [String_util.contains_substring_ci], which
   scans byte-wise with inline [Char.lowercase_ascii] and avoids the
   two [String.lowercase_ascii] allocations plus per-position
   [String.sub]. *)
let contains_ci ~haystack ~needle =
  String.length needle = 0 || String_util.contains_substring_ci haystack needle
;;

(* Default rule table. Ordered: most-specific first.

   Sources:
   - [gh] man page exit conventions (0 ok, 1 error, 2 argparse, 4 auth).
     `gh help` / `gh auth status` empirical; `gh-cli` is not contractually
     stable so [Unknown] is the fail-safe.
   - masc-mcp internal: `Keeper_exec_shell` reserves exit codes 200..201
     for R1/R2 destructive-mutation blocks. See `gh_command_validation`
     [classify_gh_reversibility].
   - Network keywords from curl(1) error messages and [gh api] wrappings
     observed in production stderr. *)
let default_rules : rule list =
  [ { exit_code = 0; stderr_contains = None; class_ = Ok_0 }
  ; (* masc-mcp R1/R2 block codes. Kept first so policy signals are
     never mistaken for a gh CLI failure. *)
    { exit_code = 200; stderr_contains = None; class_ = Policy_blocked }
  ; { exit_code = 201; stderr_contains = None; class_ = Policy_blocked }
  ; (* Auth surface. exit 4 is the documented `gh auth` error code. *)
    { exit_code = 4; stderr_contains = None; class_ = Auth_failed }
  ; { exit_code = 1; stderr_contains = Some "authentication"; class_ = Auth_failed }
  ; { exit_code = 1; stderr_contains = Some "Bad credentials"; class_ = Auth_failed }
  ; { exit_code = 1; stderr_contains = Some "401 Unauthorized"; class_ = Auth_failed }
  ; { exit_code = 1; stderr_contains = Some "403 Forbidden"; class_ = Auth_failed }
  ; { exit_code = 1; stderr_contains = Some "gh auth login"; class_ = Auth_failed }
  ; (* Network surface. *)
    { exit_code = 1; stderr_contains = Some "Could not resolve host"; class_ = Network }
  ; { exit_code = 1
    ; stderr_contains = Some "connect: network is unreachable"
    ; class_ = Network
    }
  ; { exit_code = 1; stderr_contains = Some "dial tcp"; class_ = Network }
  ; { exit_code = 1; stderr_contains = Some "tls: handshake failure"; class_ = Network }
  ; { exit_code = 1; stderr_contains = Some "i/o timeout"; class_ = Network }
  ; (* Argparse / schema failure shape. exit 2 is the conventional
     Go/cobra argparse code. *)
    { exit_code = 2; stderr_contains = None; class_ = Type_mismatch }
  ; { exit_code = 1; stderr_contains = Some "unknown flag"; class_ = Type_mismatch }
  ; { exit_code = 1; stderr_contains = Some "unknown command"; class_ = Type_mismatch }
  ; { exit_code = 1; stderr_contains = Some "required flag"; class_ = Type_mismatch }
  ; { exit_code = 1; stderr_contains = Some "accepts "; class_ = Type_mismatch }
  ]
;;

let overrides : rule list ref = ref []
let install_overrides rules = overrides := rules @ !overrides
let active_rules () = !overrides @ default_rules

let rule_matches rule ~exit_code ~stderr =
  rule.exit_code = exit_code
  &&
  match rule.stderr_contains with
  | None -> true
  | Some needle -> contains_ci ~haystack:stderr ~needle
;;

let classify ~exit_code ~stderr =
  let rec walk = function
    | [] -> Unknown
    | r :: rest -> if rule_matches r ~exit_code ~stderr then r.class_ else walk rest
  in
  walk (active_rules ())
;;

let interpretation_of = function
  | Ok_0 -> None
  | Policy_blocked ->
    Some
      "masc-mcp policy guard blocked this mutation (R1/R2). Not retryable without an \
       operator override."
  | Type_mismatch ->
    Some
      "gh CLI argparse failure. Fix the argv shape (flag name, required field, \
       subcommand) and retry."
  | Auth_failed ->
    Some
      "gh authentication failed. Check GH_TOKEN / keeper identity bundle; do not retry \
       with the same credentials."
  | Network -> Some "Network transient failure. Safe to retry after backoff."
  | Unknown -> None
;;

type gh_result =
  { stdout : string
  ; stderr : string
  ; exit_code : int
  ; class_ : t
  ; interpretation : string option
  }

let make ~stdout ~stderr ~exit_code =
  let class_ = classify ~exit_code ~stderr in
  { stdout; stderr; exit_code; class_; interpretation = interpretation_of class_ }
;;

let to_legacy_result r =
  match r.class_ with
  | Ok_0 -> Ok r.stdout
  | _ ->
    let summary =
      match r.interpretation with
      | Some s -> Printf.sprintf "[%s] %s" (to_string r.class_) s
      | None -> Printf.sprintf "[%s] exit=%d" (to_string r.class_) r.exit_code
    in
    let body =
      if r.stderr = ""
      then summary
      else Printf.sprintf "%s\n%s" summary (String.trim r.stderr)
    in
    Error body
;;
