(** RFC-0019 PR-B §4.4 — credential materialiser.

    Decides the on-disk lifecycle status of a credential record:

    | gh_config_dir input | action | resulting state |
    |---------------------|--------|-----------------|
    | None / empty | none | [Unmaterialized] |
    | non-empty dir, missing on disk | none | [Unmaterialized] |
    | exists + [gh auth status] = 0 | record verify timestamp | [Materialized {last_verified_at}] |
    | exists + [gh auth status] != 0 | record reason | [Stale {reason}] |

    PR-B Slice 1 ships this **verify-only** path.  The two [oauth_method]
    materialisation flows (web device-flow, with-token) are layered on
    top by Slice 2 in [Server_routes_http_routes_credentials].  The trait
    surface stays minimal so PR-C can wire [Credential_provider.finalize]
    against it without introducing new public types. *)

open Repo_manager_types

let now_unix_ms () =
  Int64.of_float (Unix.gettimeofday () *. 1000.0)

(** Run [gh auth status] against the supplied [GH_CONFIG_DIR] and
    return whether it succeeded.  The implementation runs synchronously
    via [Unix.system] for now; PR-C will move it to [Process_eio.run_argv]
    once the lifecycle hooks land in the keeper-side path. *)
let gh_auth_status_ok ~gh_config_dir =
  let cmd =
    Printf.sprintf
      "GH_CONFIG_DIR=%s gh auth status >/dev/null 2>&1"
      (Filename.quote gh_config_dir)
  in
  match Unix.system cmd with Unix.WEXITED 0 -> true | _ -> false

(** Compute the new state for [gh_config_dir] without writing anywhere.
    Pure with respect to credential records; reads filesystem + invokes
    [gh] subprocess. *)
let verify_state ~gh_config_dir : credential_state =
  if String.equal (String.trim gh_config_dir) "" then Unmaterialized
  else if not (Sys.file_exists gh_config_dir) then Unmaterialized
  else if not (Sys.is_directory gh_config_dir) then
    Stale { reason = "gh_config_dir is not a directory" }
  else if gh_auth_status_ok ~gh_config_dir then
    Materialized { last_verified_at = now_unix_ms () }
  else
    Stale { reason = "gh auth status returned non-zero exit code" }

(** Re-compute and update the [state] field of [cred] without touching
    other fields.  Idempotent.  Called by [Credential_store.add] /
    [Credential_store.update] (PR-B Slice 2) so newly-registered
    credentials carry an accurate state without requiring an explicit
    second call. *)
let ensure (cred : credential) : credential =
  let new_state =
    match cred.gh_config_dir with
    | None -> Unmaterialized
    | Some dir -> verify_state ~gh_config_dir:dir
  in
  { cred with state = new_state }
