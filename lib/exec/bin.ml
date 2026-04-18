type risk_class =
  [ `Safe | `Audited | `Privileged ]

type t = {
  name : string;
  risk : risk_class;
}

type unknown = [ `Unknown of string ]

(* A0 seed table.  Expanded in A2 alongside the capability walker. *)
let safe_bins =
  [ "ls"; "cat"; "pwd"; "echo"; "head"; "tail"; "grep"; "rg"; "find";
    "which"; "test"; "basename"; "dirname"; "stat"; "du"; "df";
    "sort"; "uniq"; "wc"; "cut"; "tr"; "date"; "env"; "printenv";
    "hostname"; "whoami"; "uname"; "ps"; "tty" ]

let audited_bins =
  [ "git"; "docker"; "curl"; "wget"; "ssh"; "scp"; "tar"; "rsync";
    "make"; "cmake"; "npm"; "yarn"; "pnpm"; "pip"; "opam"; "cargo";
    "gh"; "glab"; "terminal-notifier"; "osascript"; "play"; "rec";
    "ffplay"; "mpg123"; "open"; "claude"; "gemini"; "codex" ]

let privileged_bins =
  [ "sudo"; "su"; "chmod"; "chown"; "rm"; "dd"; "mkfs" ]

let classify name =
  if List.mem name safe_bins then Some `Safe
  else if List.mem name audited_bins then Some `Audited
  else if List.mem name privileged_bins then Some `Privileged
  else None

let of_string raw =
  if raw = "" then Error (`Unknown raw)
  else
    let name = Filename.basename raw in
    match classify name with
    | Some risk -> Ok { name; risk }
    | None ->
        (* Unknown binary -> Privileged per RFC v5 fail-closed rule. *)
        Ok { name; risk = `Privileged }

let risk_class t = t.risk
let to_string t = t.name

let pp fmt t =
  let tag = match t.risk with
    | `Safe -> "safe"
    | `Audited -> "audited"
    | `Privileged -> "privileged"
  in
  Format.fprintf fmt "%s:%s" tag t.name
