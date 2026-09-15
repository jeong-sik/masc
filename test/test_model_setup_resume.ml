let check = Alcotest.check
let test_deferred_owner_activation () =
  let previous = Runtime_startup_state.get () in
  Fun.protect ~finally:(fun () -> Runtime_startup_state.set previous) (fun () ->
    Eio_main.run (fun _ -> Eio.Switch.run (fun sw ->
      Runtime_startup_state.set (Setup_required Config_missing);
      let configured = ref false and starts = ref 0 and attempts = ref 0 in
      Server_model_setup_resume.install ~sw ~base_path:"/fixture-owner"
        ~resume:(fun () ->
          incr attempts;
          if not !configured then Error (Configuration_unavailable { detail = "fixture model settings are not saved" })
          else (Runtime_startup_state.set Available; Ok false));
      Eio.Fiber.fork ~sw (fun () ->
        Runtime_startup_state.await_available ();
        incr starts);
      Eio.Fiber.yield ();
      check Alcotest.int "model-less owner does not boot keeper services" 0 !starts;
      (match Server_model_setup_resume.request ~base_path:"/other-owner" with
       | Error Workspace_mismatch -> () | _ -> Alcotest.fail "cross-workspace resume accepted");
      check Alcotest.int "wrong owner never invokes activation" 0 !attempts;
      (match Server_model_setup_resume.request ~base_path:"/fixture-owner" with
       | Error (Configuration_unavailable _) -> () | _ -> Alcotest.fail "invalid config activated services");
      Runtime_startup_state.note_runtime_loaded ();
      Eio.Fiber.yield ();
      check Alcotest.int "config save alone cannot activate skipped services" 0 !starts;
      configured := true;
      (match Server_model_setup_resume.request ~base_path:"/fixture-owner" with
       | Ok false -> () | _ -> Alcotest.fail "conversation needs no exact-output authority");
      Eio.Fiber.yield ();
      check Alcotest.int "same owner resumes deferred services" 1 !starts;
      ignore (Server_model_setup_resume.request ~base_path:"/fixture-owner");
      Eio.Fiber.yield ();
      check Alcotest.int "repeat resume never forks duplicate service" 1 !starts)));
  match Server_model_setup_resume.request ~base_path:"/fixture-owner" with
  | Error Owner_not_ready -> () | _ -> Alcotest.fail "closed owner retained activation authority"

let test_stale_authority_is_withdrawn () =
  let module Exact = Agent_core.Exact_output in
  let snapshot = match Exact.load_resolver_snapshot
    ~io:{getenv=(fun _ -> Ok None)}
    ~target_binding_policy:Exact.Exclude_unbound_targets
    ~catalog:Exact.Embedded_default () with
    | Ok snapshot -> snapshot | Error _ -> Alcotest.fail "embedded resolver unavailable" in
  ignore (Runtime_exact_output_registry.publish ~lanes:[] snapshot |> Result.get_ok);
  check Alcotest.bool "prior authority published" true
    (Result.is_ok (Runtime_exact_output_registry.current ()));
  ignore (Runtime_exact_output_registry.unpublish () |> Result.get_ok);
  (match Runtime_exact_output_registry.current () with
   | Error Registry_not_published -> () | _ -> Alcotest.fail "old authority remained usable");
  ignore (Runtime_exact_output_registry.unpublish () |> Result.get_ok)

let contains ~needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec from i = i + n <= h && (String.sub haystack i n = needle || from (i + 1)) in
  from 0

(* Boot and resume used to replace every load or validation diagnostic with a
   fixed sentence, so an operator saw "no valid initialized runtime" and no
   binding name. The diagnostic below is the shape Runtime reports for a
   binding with no resolvable context window. *)
let test_setup_reason_names_its_cause () =
  let previous = Runtime_startup_state.get () in
  Fun.protect ~finally:(fun () -> Runtime_startup_state.set previous) (fun () ->
    Eio_main.run (fun _ ->
      let detail = "Keeper runtime \"openrouter.vendor-new\" resolves no max-context" in
      Runtime_startup_state.set (Setup_required (Config_invalid { detail }));
      (match Runtime_startup_state.to_json () with
       | `Assoc fields ->
         check Alcotest.bool "reason stays config_invalid" true
           (List.assoc_opt "reason" fields = Some (`String "config_invalid"));
         (match List.assoc_opt "message" fields with
          | Some (`String message) ->
            check Alcotest.bool "health message names the binding" true
              (contains ~needle:detail message)
          | _ -> Alcotest.fail "setup_required must render a message")
       | _ -> Alcotest.fail "model setup JSON must be an object");
      check Alcotest.bool "unreadable reason carries its read error" true
        (contains ~needle:"permission denied"
           (Runtime_startup_state.message (Config_unreadable { detail = "permission denied" })));
      check Alcotest.bool "resume error carries its cause" true
        (contains ~needle:detail
           (Server_model_setup_resume.error_message (Configuration_unavailable { detail })))))

let () = Alcotest.run "model setup resume"
  ["owner lifecycle",[Alcotest.test_case "save, retry and exactly-once activation" `Quick test_deferred_owner_activation;
    Alcotest.test_case "changed config revokes stale authority" `Quick test_stale_authority_is_withdrawn;
    Alcotest.test_case "setup reason names its cause" `Quick test_setup_reason_names_its_cause]]
