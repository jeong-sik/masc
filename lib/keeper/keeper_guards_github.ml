(* Keeper GitHub write/credential hard gates - task-1819
   From 2026-07-05 audit: all GitHub write operations must be gated
   by explicit credential check and write-permission flag.
*)

let is_github_write_operation (argv : string list) : bool =
  match argv with
  | "gh" :: _ -> true
  | "git" :: "push" :: _ -> true
  | _ -> false

let check_github_credential () : bool =
  Sys.getenv_opt "GITHUB_TOKEN" <> None || Sys.getenv_opt "GH_TOKEN" <> None

let enforce_github_write_gate (argv : string list) : unit =
  if is_github_write_operation argv then (
    if not (check_github_credential ()) then
      failwith "SECURITY: GitHub write operation requires GITHUB_TOKEN or GH_TOKEN"
  )