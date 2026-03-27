(** Pg_infix — Caqti_request.Infix wrapper for Transaction Pooler compatibility.

    Supabase Transaction Pooler (port 6543) does not support prepared statements
    because connections are shared across sessions. When Transaction Pooler is
    detected, all requests use [~oneshot:true] (Direct policy) to avoid
    prepared statement errors.

    Session Pooler (port 5432) and direct connections work normally with
    the default Static prepared statement policy.

    When a legacy Session Pooler URL is configured via [MASC_POSTGRES_URL]
    but a companion Supabase Transaction Pooler URL is still available in
    lower-priority env vars, this module mirrors the runtime selector and
    enables oneshot mode for the companion `:6543` target. *)

let preferred_url_from_env () =
  let primary = [ Backend_pg_url.env_url_opt "MASC_POSTGRES_URL" ] in
  match Backend_pg_url.choose_preferred_url primary with
  | Some selection -> Some selection.Backend_pg_url.url
  | None ->
      (* Legacy fallback — mirrors room_utils_backend_setup deprecation *)
      let legacy =
        [ Backend_pg_url.env_url_opt "DATABASE_URL";
          Backend_pg_url.env_url_opt "SUPABASE_DB_URL";
          Backend_pg_url.env_url_opt "SB_PG_URL" ]
      in
      Option.map (fun s -> s.Backend_pg_url.url)
        (Backend_pg_url.choose_preferred_url legacy)

let use_oneshot =
  match preferred_url_from_env () with
  | None -> false
  | Some url ->
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
