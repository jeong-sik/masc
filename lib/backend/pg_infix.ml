(** Pg_infix — Caqti_request.Infix wrapper for Transaction Pooler compatibility.

    Supabase Transaction Pooler (port 6543) does not support prepared statements
    because connections are shared across sessions. When Transaction Pooler is
    detected, all requests use [~oneshot:true] (Direct policy) to avoid
    prepared statement errors.

    Session Pooler (port 5432) and direct connections work normally with
    the default Static prepared statement policy.

    NOTE: [Room_utils.normalize_postgres_url] rewrites Supabase `:6543` to
    `:5432` at connection time. This module mirrors that normalization so
    the oneshot policy matches the actual port the driver connects to. *)

(* Apply the same port normalization as Room_utils.normalize_postgres_url.
   Supabase Transaction Pooler URLs on pooler.supabase.com:6543 are rewritten
   to Session Pooler port 5432 at connection time, so the driver never actually
   talks to port 6543. *)
let normalize_pg_port url =
  let uri = Uri.of_string url in
  match Uri.host uri, Uri.port uri with
  | Some host, Some 6543 when String.ends_with ~suffix:".pooler.supabase.com" host ->
      Uri.with_port uri (Some 5432) |> Uri.to_string
  | _ -> url

let use_oneshot =
  let env_url name =
    match Sys.getenv_opt name with
    | Some v when String.trim v <> "" -> Some (String.trim v)
    | _ -> None
  in
  let url =
    match env_url "MASC_POSTGRES_URL" with
    | Some _ as u -> u
    | None -> None
  in
  match url with
  | None -> false
  | Some raw_url ->
      let url = normalize_pg_port raw_url in
      (match Uri.port (Uri.of_string url) with
      | Some 6543 -> true
      | _ -> false)

let oneshot () = use_oneshot

let ( ->. ) a b ?(oneshot = oneshot ()) s =
  Caqti_request.Infix.( ->. ) a b ~oneshot s

let ( ->? ) a b ?(oneshot = oneshot ()) s =
  Caqti_request.Infix.( ->? ) a b ~oneshot s

let ( ->* ) a b ?(oneshot = oneshot ()) s =
  Caqti_request.Infix.( ->* ) a b ~oneshot s

let ( ->! ) a b ?(oneshot = oneshot ()) s =
  Caqti_request.Infix.( ->! ) a b ~oneshot s
