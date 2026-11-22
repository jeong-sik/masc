open Alcotest
open Masc
module Context = Keeper_librarian_context

let source reference text : Context.source = {reference; content = `String text}
let events = List.init 20 (fun i -> source (Printf.sprintf "event:campaign:%d" i) "continue campaign")
let question = source "chat:question:revision1" "Where are we now?"
let pocket sources context next_steps : Context.pocket = {id = "test:" ^ String.concat ":" sources; merge_contexts = []; sources; context; next_steps; completeness = Context.Current}
let input sources previous : Context.input = {sources; previous; unavailable = []; withheld = []; execution_basis = Some "test-progress"}
let ok = function Ok value -> value | Error detail -> fail detail

(* A fake model groups repeated notifications while retaining the direct
   question's separate unresolved answer obligation in the same context. *)
let fake_model sources =
  Context.pockets_to_json
    [pocket (List.mapi (fun i _ -> Printf.sprintf "s%d" (i + 1)) sources)
       "Campaign is in progress; the user is asking for current progress."
       ["Answer the user's progress question"; "Continue the campaign once"]]

let test_queue_wakes_coalesce_without_waiting_for_librarian () =
  Masc_test_deps.ensure_rng_initialized ();
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let keepers_dir = Filename.temp_dir "librarian-flood" "" in
  Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree keepers_dir);
  Eio_context.with_test_env ~sw ~net:env#net ~clock:env#clock ~mono_clock:env#mono_clock @@ fun () ->
  Keeper_memory_lane.init ~sw;
  let started, start = Eio.Promise.create () in
  let release, release_first = Eio.Promise.create () in
  let finished, finish = Eio.Promise.create () in
  let original = ref [List.hd events] in
  let calls = ref 0 in
  let organize () =
    incr calls;
    let sources = !original in
    if !calls = 1 then (Eio.Promise.resolve start (); Eio.Promise.await release);
    let previous = ok (Context.read ~keepers_dir ~keeper_id:"flood") in
    let selected = ok (Context.select (input sources previous) (fake_model sources)) in
    ignore (ok (Context.commit ~keepers_dir ~keeper_id:"flood"
      ~expected_version:(Option.map Context.version previous)
      ~sources selected));
    if !calls = 2 then Eio.Promise.resolve finish ()
  in
  Keeper_working_context_signal.install (fun ~base_path ~keeper_name ->
    ignore (Keeper_memory_lane.submit ~base_path ~keeper_name organize));
  Eio.Switch.on_release sw (fun () -> Keeper_working_context_signal.install
    (fun ~base_path:_ ~keeper_name:_ -> ()));
  let signal () = Keeper_working_context_signal.changed ~base_path:keepers_dir ~keeper_name:"flood" in
  signal ();
  Eio.Promise.await started;
  List.iter (fun event -> original := !original @ [event]; signal ()) (List.tl events @ [question]);
  check int "all input accepted while first model is blocked" 21 (List.length !original);
  Eio.Promise.resolve release_first ();
  Eio.Time.with_timeout_exn env#clock 2.0 (fun () -> Eio.Promise.await finished);
  check int "one active plus one latest pass" 2 !calls;
  let snapshot = ok (Context.read ~keepers_dir ~keeper_id:"flood") |> Option.get in
  check int "latest pass sees entire accumulated input" 21 (List.length snapshot.sources);
  check int "repeated notifications become one context" 1 (List.length snapshot.pockets)

let () =
  Prompt_registry.set_markdown_dir (Masc_test_deps.source_path "config/prompts");
  run "keeper_working_context_signal_flood"
  ["scenarios", [
    test_case "queue wake flood does not wait for librarian" `Quick test_queue_wakes_coalesce_without_waiting_for_librarian]]
