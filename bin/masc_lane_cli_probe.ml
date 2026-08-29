(** Measure a declared [cli_slots] runtime against a lane's real requirement.

    The CLI transport is the one an operator cannot probe with curl: masc
    admits a subscription, spawns the client, carries the lane schema as
    prompt text ([Agent_core.Exact_output.schema_instruction_text]) and parses
    the reply strictly, with no fence stripping. That last part is why a probe
    matters — the shape most exposed to a model wrapping its answer in
    markdown is exactly the one with no provider-side enforcement to fall back
    on, and the four exact lanes currently declare a single CLI slot between
    them.

    This runs [Masc.Keeper_lane_cli_oneshot.run] itself rather than reimplementing
    the invocation, so what it reports is what the lane would get.

    Usage: masc-lane-cli-probe --lane <name> --runtime <id> [--trials N] *)

(* verifier_exact is absent on purpose: its channel is a report_review_verdict
   tool call, and this transport has no tool channel to offer. A CLI slot on
   that lane would be answering a different question than the lane asks. *)
let usage = "masc-lane-cli-probe --lane <librarian|hitl> --runtime <id> [--trials N]"

type lane_case =
  { requirement : Agent_core.Exact_output.output_requirement
  ; system_prompt : string
  ; prompt : string
  }

(* Each case carries the lane's own schema, not a stand-in: a model that keeps
   one lane's shape may not keep another's, which is the whole reason these are
   measured per lane. *)
let librarian_case () =
  { requirement =
      Agent_core.Exact_output.make_output_requirement
        ~schema:Masc.Keeper_structured_output_schema.librarian_current_output_schema
        ~minimum_guarantee:Agent_core.Exact_output.Json_syntax
  ; system_prompt =
      "You are a structured JSON librarian. Output ONLY valid JSON matching the \
       requested schema."
  ; prompt =
      "Exact current memory:\n\
       m1 [fact] The lane advances off a 429 but stops on a 403.\n\
       m2 [lesson] A fenced answer is Invalid_json_output on this transport.\n\n\
       Conversation history:\n\
       user: 두 번째 슬롯이 주간 쿼터로 막혔어요.\n\
       assistant: 다른 provider 는 살아 있습니다.\n\
       user: 정리해줘.\n"
  }
;;

let hitl_case () =
  { requirement =
      Agent_core.Exact_output.make_output_requirement
        ~schema:Masc.Keeper_structured_output_schema.hitl_context_summary_schema
        ~minimum_guarantee:Agent_core.Exact_output.Json_syntax
  ; system_prompt = "You judge one requested external effect. Answer with JSON only."
  ; prompt =
      "Keeper: taskmaster\n\
       Requested effect: github_push_files\n\
       Arguments: repo=jeong-sik/masc branch=taskmaster/evidence files=[docs/e.md]\n\
       Recent context: 운영자가 근거 문서를 저장소에 남기라고 지시했습니다.\n"
  }
;;

let cases = [ "librarian", librarian_case; "hitl", hitl_case ]

let () =
  let lane = ref "" and runtime = ref "" and trials = ref 3 in
  let rec parse = function
    | "--lane" :: value :: rest -> lane := value; parse rest
    | "--runtime" :: value :: rest -> runtime := value; parse rest
    | "--trials" :: value :: rest -> trials := int_of_string value; parse rest
    | [] -> ()
    | other :: _ -> prerr_endline (usage ^ "\nunexpected: " ^ other); exit 2
  in
  parse (List.tl (Array.to_list Sys.argv));
  if String.equal !lane "" || String.equal !runtime "" then (
    prerr_endline usage;
    exit 2);
  let case =
    match List.assoc_opt !lane cases with
    | Some build -> build ()
    | None ->
      prerr_endline (Printf.sprintf "unknown lane %S; expected one of %s" !lane
                       (String.concat ", " (List.map fst cases)));
      exit 2
  in
  (* The lane resolves this from the approval entry it is serving; a probe has
     no entry, so it takes the install root the same way the server is started
     with it. *)
  let base_dir =
    match Sys.getenv_opt "MASC_BASE_PATH" with
    | Some path when String.trim path <> "" -> String.trim path
    | Some _ | None ->
      Filename.concat (Option.value (Sys.getenv_opt "HOME") ~default:".") "me"
  in
  let config_path = Masc.Fusion_config_loader.runtime_toml_path ~base_path:base_dir in
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun _sw ->
  (* An official-client panelist spawns a subprocess and times it, so it needs
     the env and clock published the way the server publishes them. Without
     this the slot answers "requires Eio_context env and clock". *)
  Eio_context.set_env env;
  Eio_context.set_clock (Eio.Stdenv.clock env);
  (* The server installs the deployment capability overlay at boot and a CLI
     does not; keeper_capability_probe_cli carries the same call for the same
     reason. *)
  ignore
    (Server_runtime_bootstrap.configure_agent_core_model_catalog_overlay
       ~config_root:(Filename.dirname config_path)
       ()
     : string option);
  (match Runtime.init_default ~config_path with
   | Error detail ->
     Printf.eprintf "runtime init failed (%s): %s
" config_path detail;
     exit 2
   | Ok () -> ());
  let outcomes = Hashtbl.create 8 in
  let bump key = Hashtbl.replace outcomes key (1 + Option.value ~default:0 (Hashtbl.find_opt outcomes key)) in
  for trial = 1 to !trials do
    let started = Unix.gettimeofday () in
    let result =
      Masc.Keeper_lane_cli_oneshot.run
        ~base_dir
        ~runtime_id:!runtime
        ~system_prompt:case.system_prompt
        ~requirement:case.requirement
        ~prompt:case.prompt
        ()
    in
    let elapsed = Unix.gettimeofday () -. started in
    match result with
    | Ok value ->
      bump "ok";
      Printf.printf
        "%s %s trial=%d ok %.1fs bytes=%d\n%!"
        !lane
        !runtime
        trial
        elapsed
        (String.length (Yojson.Safe.to_string value))
    | Error failure ->
      let detail = Masc.Keeper_lane_cli_oneshot.failure_to_string failure in
      bump
        (match failure with
         | Masc.Keeper_lane_cli_oneshot.Not_an_official_client _ -> "not_an_official_client"
         | Masc.Keeper_lane_cli_oneshot.Execution_failed _ -> "execution_failed"
         | Masc.Keeper_lane_cli_oneshot.Invalid_json_output _ -> "invalid_json_output");
      Printf.printf "%s %s trial=%d FAIL %.1fs %s\n%!" !lane !runtime trial elapsed detail
  done;
  let summary =
    Hashtbl.fold (fun key count acc -> Printf.sprintf "%s=%d" key count :: acc) outcomes []
  in
  Printf.printf
    "SUMMARY lane=%s runtime=%s trials=%d %s\n%!"
    !lane
    !runtime
    !trials
    (String.concat " " (List.sort compare summary))
;;
