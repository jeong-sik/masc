open Alcotest
module Codec = Masc.Keeper_official_client_context_codec

let message role value : Agent_core.Types.message =
  { origin = Llm_provider.Types.Conversation
  ; role
  ; content = [ Agent_core.Types.Text value ]
  ; name = None
  ; tool_call_id = None
  ; metadata = []
  }
;;

let system_prompt = "You keep the lane."

let messages =
  [ message Agent_core.Types.User "first \"quoted\"\nline"
  ; message Agent_core.Types.Assistant "second"
  ]
;;

let rest = [ "model", `Null; "workspace_root", `String "/workspace" ]

(* The text the two runtimes hashed before the function existed. A stored
   session carries this digest, so the function must keep producing it. *)
let spelled_out ~rest =
  `Assoc
    (("system_prompt", `String system_prompt)
     :: ("messages", `List (List.map Codec.to_json messages))
     :: rest)
  |> Yojson.Safe.to_string
  |> Agent_core_sha256.digest_string
  |> Agent_core_sha256.to_hex
;;

let test_the_digest_is_of_the_text_the_runtimes_wrote () =
  check string "with trailing fields" (spelled_out ~rest)
    (Codec.canonical_source_sha256 ~system_prompt ~messages ~rest);
  check string "with none" (spelled_out ~rest:[])
    (Codec.canonical_source_sha256 ~system_prompt ~messages ~rest:[]);
  check bool "the trailing fields are part of it" false
    (String.equal (spelled_out ~rest) (spelled_out ~rest:[]))
;;

let busy_worker_polls = 50
let busy_worker_poll_interval_s = 0.01

(* On a fiber of a process with a domain pool the digest is a job of that
   pool: while the pool's one worker is busy the fiber waits for it, and the
   value is the one computed with no pool. *)
let test_a_fiber_with_a_domain_pool_digests_on_the_pool () =
  let expected = Codec.canonical_source_sha256 ~system_prompt ~messages ~rest in
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let pool = Domain_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env) in
  let previous_pool = Domain_pool_ref.get () in
  Fun.protect
    ~finally:(fun () ->
      match previous_pool with
      | None -> Domain_pool_ref.clear_for_tests ()
      | Some previous -> Domain_pool_ref.set previous)
  @@ fun () ->
  Domain_pool_ref.set pool;
  let occupied, occupied_u = Eio.Promise.create () in
  let release, release_u = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ (fun () ->
      Eio.Promise.resolve occupied_u ();
      Eio.Promise.await release));
  Eio.Promise.await occupied;
  let digest = ref None in
  let clock = Eio.Stdenv.clock env in
  Eio.Fiber.both
    (fun () -> digest := Some (Codec.canonical_source_sha256 ~system_prompt ~messages ~rest))
    (fun () ->
      let rec wait polls =
        if polls > 0 && Option.is_none !digest
        then (
          Eio.Time.sleep clock busy_worker_poll_interval_s;
          wait (polls - 1))
      in
      wait busy_worker_polls;
      check bool "the digest waits for the busy worker" true (Option.is_none !digest);
      Eio.Promise.resolve release_u ());
  check (option string) "and is the same value" (Some expected) !digest
;;

let () =
  run
    "official client canonical source digest"
    [ ( "digest"
      , [ test_case "the digest is of the text the runtimes wrote" `Quick
            test_the_digest_is_of_the_text_the_runtimes_wrote
        ; test_case "a fiber with a domain pool digests on the pool" `Quick
            test_a_fiber_with_a_domain_pool_digests_on_the_pool
        ] )
    ]
;;
