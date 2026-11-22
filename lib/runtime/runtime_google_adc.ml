type runner = string list -> (string, unit) result

let default_ttl_s = 2700.0
let ns_per_s = 1_000_000_000.0

let default_now () =
  Mtime.Span.to_float_ns (Mtime_clock.elapsed ()) /. ns_per_s
;;

type cached_entry =
  { token : Llm_provider.Secret.t
  ; expires_at_s : float
  }

type cache =
  { state_mu : Stdlib.Mutex.t
  ; refresh_mu : Cross_context_mutex.t
  ; ttl_s : float
  ; now : unit -> float
  ; mutable entry : cached_entry option
  ; mutable generation : int
  }

let create_cache ?(ttl_s = default_ttl_s) ?(now = default_now) () =
  if (not (Float.is_finite ttl_s)) || Float.compare ttl_s 0.0 <= 0
  then
    invalid_arg
      (Printf.sprintf
         "Runtime_google_adc.create_cache: ttl_s must be finite and > 0, got %.17g"
         ttl_s);
  { state_mu = Stdlib.Mutex.create ()
  ; refresh_mu = Cross_context_mutex.create ()
  ; ttl_s
  ; now
  ; entry = None
  ; generation = 0
  }
;;

let default_cache = create_cache ()

let invalidate_cache (cache : cache) =
  Stdlib.Mutex.protect cache.state_mu (fun () ->
    cache.entry <- None;
    cache.generation <- cache.generation + 1)
;;

let invalidate () = invalidate_cache default_cache

let lookup_live (cache : cache) =
  let now_s = cache.now () in
  Stdlib.Mutex.protect cache.state_mu (fun () ->
    match cache.entry with
    | Some entry when Float.compare now_s entry.expires_at_s < 0 -> Some entry.token
    | Some _ ->
      cache.entry <- None;
      None
    | None -> None)
;;

let refresh_with ~run () =
  match run [ "gcloud"; "auth"; "application-default"; "print-access-token"; "--quiet" ] with
  | Error () -> Error Llm_provider.Provider_config.Credential_unavailable
  | Ok output ->
    let token = String.trim output in
    if token = "" || String.exists (function '\000' .. '\032' | '\127' -> true | _ -> false) token then
      Error Llm_provider.Provider_config.Invalid_credential_response
    else Ok (Llm_provider.Secret.of_string token)
;;

let get_token_with ?(cache = default_cache) ~run () =
  match lookup_live cache with
  | Some token -> Ok token
  | None ->
    Cross_context_mutex.with_lock cache.refresh_mu (fun () ->
      (* Re-check inside single-flight lock in case another caller refreshed
         while we waited. *)
      match lookup_live cache with
      | Some token -> Ok token
      | None ->
        let gen_before =
          Stdlib.Mutex.protect cache.state_mu (fun () -> cache.generation)
        in
        (match refresh_with ~run () with
         | Error _ as err -> err
         | Ok token ->
           let expires_at_s = cache.now () +. cache.ttl_s in
           Stdlib.Mutex.protect cache.state_mu (fun () ->
             (* Only populate cache if no concurrent [invalidate_cache] occurred
                while this refresh was in flight. *)
             if cache.generation = gen_before
             then cache.entry <- Some { token; expires_at_s });
           Ok token))
;;

let run argv =
  match Process_eio.run_argv_with_status_split_or_refusal
    ~timeout_sec:(Env_config_sandbox.Shell_timeout.timeout_sec ~bucket:Env_config_sandbox.Shell_timeout.Read ()) argv with
  | Ok (Unix.WEXITED 0, stdout, _) -> Ok stdout
  | Ok ((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _), _, _) | Error _ -> Error ()
;;

let credential_source_with ?(cache = default_cache) ~run () =
  Llm_provider.Provider_config.make_refreshable_credential
    ~invalidate:(fun () -> invalidate_cache cache)
    (fun () -> get_token_with ~cache ~run ())
;;

let default_credential_source =
  credential_source_with ~cache:default_cache ~run ()
;;

let credential_source () = default_credential_source
