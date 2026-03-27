(** Shared PostgreSQL URL selection helpers.

    Runtime URL selection and prepared-statement policy must agree on the same
    effective target. Keep the Supabase companion-selection rule here so the
    backend config path and the Pg_infix oneshot path cannot silently drift. *)

type selection = {
  url : string;
  preferred_supabase_transaction_companion : bool;
  preferred_host : string option;
}

let is_unresolved_template value =
  let v = String.trim value in
  (String.length v >= 2 && v.[0] = '{' && v.[1] = '{')
  || (String.length v >= 5 && String.sub v 0 5 = "op://")

let env_url_opt ?(on_unresolved = fun _ -> ()) name =
  match Sys.getenv_opt name with
  | Some value ->
      let trimmed = String.trim value in
      if trimmed = "" then None
      else if is_unresolved_template trimmed then (
        on_unresolved name;
        None)
      else Some trimmed
  | None -> None

let supabase_pooler_host_and_port url =
  let uri = Uri.of_string url in
  match Uri.host uri, Uri.port uri with
  | Some host, Some port when String.ends_with ~suffix:".pooler.supabase.com" host ->
      Some (host, port)
  | _ -> None

let choose_preferred_url candidates =
  let rec choose = function
    | [] -> None
    | Some primary :: rest ->
        let fallbacks = List.filter_map Fun.id rest in
        let selected =
          match supabase_pooler_host_and_port primary with
          | Some (host, 5432) -> (
              match
                List.find_opt
                  (fun candidate ->
                    match supabase_pooler_host_and_port candidate with
                    | Some (candidate_host, 6543) -> String.equal host candidate_host
                    | _ -> false)
                  fallbacks
              with
              | Some companion ->
                  {
                    url = companion;
                    preferred_supabase_transaction_companion = true;
                    preferred_host = Some host;
                  }
              | None ->
                  {
                    url = primary;
                    preferred_supabase_transaction_companion = false;
                    preferred_host = None;
                  })
          | _ ->
              {
                url = primary;
                preferred_supabase_transaction_companion = false;
                preferred_host = None;
              }
        in
        Some selected
    | None :: rest -> choose rest
  in
  choose candidates
