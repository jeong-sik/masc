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

let is_unresolved_template value =
  let v = String.trim value in
  (String.length v >= 2 && v.[0] = '{' && v.[1] = '{')
  || (String.length v >= 5 && String.sub v 0 5 = "op://")

let supabase_pooler_host_and_port url =
  let uri = Uri.of_string url in
  match Uri.host uri, Uri.port uri with
  | Some host, Some port when String.ends_with ~suffix:".pooler.supabase.com" host ->
      Some (host, port)
  | _ -> None

let maybe_prefer_supabase_transaction_pooler ~primary ~fallbacks =
  match supabase_pooler_host_and_port primary with
  | Some (host, 5432) ->
      (match
         List.find_opt
           (fun candidate ->
             match supabase_pooler_host_and_port candidate with
             | Some (candidate_host, 6543) -> String.equal host candidate_host
             | _ -> false)
           fallbacks
       with
       | Some companion -> companion
       | None -> primary)
  | _ -> primary

let preferred_url_from_env () =
  let env_url name =
    match Sys.getenv_opt name with
    | Some v when String.trim v <> "" && not (is_unresolved_template v) ->
        Some (String.trim v)
    | _ -> None
  in
  let candidates =
    [
      env_url "MASC_POSTGRES_URL";
      env_url "DATABASE_URL";
      env_url "SUPABASE_DB_URL";
      env_url "SB_PG_URL";
    ]
  in
  let rec choose = function
    | [] -> None
    | Some primary :: rest ->
        let fallbacks = List.filter_map Fun.id rest in
        Some (maybe_prefer_supabase_transaction_pooler ~primary ~fallbacks)
    | None :: rest -> choose rest
  in
  choose candidates

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
