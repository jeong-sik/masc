(** Pg_infix — Caqti_request.Infix wrapper for Transaction Pooler compatibility.

    Supabase Transaction Pooler (port 6543) does not support prepared statements
    because connections are shared across sessions. When Transaction Pooler is
    detected, all requests use [~oneshot:true] (Direct policy) to avoid
    prepared statement errors.

    Session Pooler (port 5432) and direct connections work normally with
    the default Static prepared statement policy. *)

let use_oneshot =
  lazy
    (let env_url name =
       match Sys.getenv_opt name with
       | Some v when String.trim v <> "" -> Some (String.trim v)
       | _ -> None
     in
     let url =
       match env_url "MASC_POSTGRES_URL" with
       | Some _ as u -> u
       | None -> (
           match env_url "DATABASE_URL" with
           | Some _ as u -> u
           | None -> (
               match env_url "SUPABASE_DB_URL" with
               | Some _ as u -> u
               | None -> env_url "SB_PG_URL"))
     in
     match url with
     | None -> false
     | Some url -> (
         match Uri.port (Uri.of_string url) with
         | Some 6543 -> true
         | _ -> false))

let oneshot () = Lazy.force use_oneshot

let ( ->. ) a b ?(oneshot = oneshot ()) s =
  Caqti_request.Infix.( ->. ) a b ~oneshot s

let ( ->? ) a b ?(oneshot = oneshot ()) s =
  Caqti_request.Infix.( ->? ) a b ~oneshot s

let ( ->* ) a b ?(oneshot = oneshot ()) s =
  Caqti_request.Infix.( ->* ) a b ~oneshot s

let ( ->! ) a b ?(oneshot = oneshot ()) s =
  Caqti_request.Infix.( ->! ) a b ~oneshot s
