(** eval_grounding_dry_run — RFC-0259 P2 standalone dry-run runner.

    Runs the observe-only grounding reconciler's logic as a one-shot CLI so an
    operator can SEE what P3 retraction would face — without merging the fiber or
    restarting the server. Reads the LIVE keeper fact stores (read-only),
    re-checks each volatile (external_ref) fact past the grounding horizon against
    GitHub using the token in [MASC_GROUNDING_GITHUB_TOKEN], and prints the
    provisional verdicts plus a summary. Performs NO writes.

    Usage:
      MASC_GROUNDING_GITHUB_TOKEN=<repo-read PAT> \
        dune exec test/eval_grounding_dry_run.exe -- [--owner O] [--repo R] [--horizon-seconds N]

    With no token every verdict is Indeterminate (the run still lists which facts
    WOULD be checked). The token is read from the environment by this process; it
    is never written or logged. *)

module Grounding = Masc.Keeper_memory_os_grounding
module Io = Masc.Keeper_memory_os_io
module Types = Masc.Keeper_memory_os_types

let () =
  let owner = ref Grounding.default_owner in
  let repo = ref Grounding.default_repo in
  let horizon = ref Grounding.default_grounding_horizon_seconds in
  Arg.parse
    [ "--owner", Arg.Set_string owner, " GitHub owner (default jeong-sik)"
    ; "--repo", Arg.Set_string repo, " GitHub repo (default masc)"
    ; "--horizon-seconds", Arg.Set_float horizon, " re-grounding horizon in seconds"
    ]
    (fun _ -> ())
    "eval_grounding_dry_run [--owner O] [--repo R] [--horizon-seconds N]";
  let token = Sys.getenv_opt "MASC_GROUNDING_GITHUB_TOKEN" in
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      (* Masc_http_client resolves its per-domain pool via Eio_context. *)
      Eio_context.set_switch sw;
      Eio_context.set_env env;
      let clock = Eio.Stdenv.clock env in
      let verify_external =
        match token with
        | Some t when String.trim t <> "" ->
          Grounding.github_verify ~token:t ~clock ~timeout_sec:10.0 ~owner:!owner ~repo:!repo
        | Some _ | None ->
          prerr_endline
            "[dry-run] no MASC_GROUNDING_GITHUB_TOKEN set; every verdict is Indeterminate";
          Grounding.no_token_verify
      in
      let now = Eio.Time.now clock in
      let keepers =
        List.filter
          (fun id -> not (String.equal id Types.shared_store_id))
          (Io.list_fact_store_keeper_ids ())
      in
      let counts = Hashtbl.create 4 in
      let bump key =
        Hashtbl.replace counts key (1 + Option.value (Hashtbl.find_opt counts key) ~default:0)
      in
      List.iter
        (fun keeper_id ->
          let facts = try Io.read_facts_all ~keeper_id with _ -> [] in
          let observations =
            Grounding.grounding_pass
              ~verify_external
              ~now
              ~grounding_horizon:!horizon
              ~keeper_id
              facts
          in
          List.iter
            (fun (o : Grounding.observation) ->
              bump (Grounding.provisional_verdict_to_string o.verdict);
              print_endline (Grounding.observation_log_line o))
            observations)
        keepers;
      Printf.printf "\n--- dry-run summary (keepers=%d, horizon=%.0fs) ---\n" (List.length keepers) !horizon;
      List.iter
        (fun key ->
          Printf.printf "%s: %d\n" key (Option.value (Hashtbl.find_opt counts key) ~default:0))
        [ "confirmed"; "contradicted_candidate"; "indeterminate" ]))
;;
