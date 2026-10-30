(* Native macOS regression: only disposable keychains and dummy credentials.
   In particular the denied fixture trusts security(1), exactly as agy-created
   items do, but does not trust this executable. *)
external interaction_allowed : unit -> bool = "masc_test_keychain_interaction_allowed"
external set_interaction : bool -> unit = "masc_test_keychain_set_interaction"
external add_allowed : string -> unit = "masc_test_keychain_add_allowed"
external observed_item : string -> bool -> int * string = "masc_test_observed_keychain_item"
external observed_counts : unit -> int * int * int = "masc_test_observed_keychain_counts"

let require label condition = if not condition then failwith label

let rec remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
    Sys.readdir path |> Array.iter (fun entry -> remove_tree (Filename.concat path entry));
    Unix.rmdir path
  | _ -> Unix.unlink path

let security ~home args =
  let env = Unix.environment () |> Array.to_list |> List.filter (fun entry ->
    not (String.starts_with ~prefix:"HOME=" entry)) in
  let env = Array.of_list (("HOME=" ^ home) :: env) in
  let null = Unix.openfile "/dev/null" [Unix.O_RDWR] 0 in
  Fun.protect ~finally:(fun () -> Unix.close null) (fun () ->
    let pid = Unix.create_process_env "/usr/bin/security"
      (Array.of_list ("/usr/bin/security" :: args)) env null null null in
    match snd (Unix.waitpid [] pid) with
    | Unix.WEXITED 0 -> ()
    | Unix.WEXITED code -> failwith (Printf.sprintf "fixture security exited %d" code)
    | Unix.WSIGNALED signal | Unix.WSTOPPED signal ->
      failwith (Printf.sprintf "fixture security signal %d" signal))

let with_keychain ~home name f =
  let path = Filename.concat home (name ^ ".keychain-db") in
  security ~home ["create-keychain"; "-p"; "fixture-password"; path];
  Fun.protect
    ~finally:(fun () -> security ~home ["delete-keychain"; path])
    (fun () -> f path)

let add_denied ~home path =
  security ~home ["add-generic-password"; "-s"; "gemini"; "-a"; "antigravity";
    "-w"; "dummy-antigravity-credential"; "-T"; "/usr/bin/security"; path]

let check_restored label f =
  let before = interaction_allowed () in
  let result = f () in
  require (label ^ ": restored interaction") (interaction_allowed () = before);
  result

let run home =
  let original = interaction_allowed () in
  Fun.protect ~finally:(fun () -> set_interaction original) (fun () ->
    set_interaction true;
    with_keychain ~home "allowed" @@ fun allowed ->
    with_keychain ~home "denied" @@ fun denied ->
    with_keychain ~home "empty" @@ fun empty ->
    with_keychain ~home "observed" @@ fun observed ->
    add_allowed allowed;
    add_denied ~home denied;
    add_allowed observed;
    require "observed allowed read"
      (check_restored "observed read" (fun () -> observed_item observed false)
        = (0, "dummy-antigravity-credential"));
    require "observed allowed clear"
      (check_restored "observed clear" (fun () -> observed_item observed true) = (0, ""));
    let read_checks, clear_checks, violations = observed_counts () in
    require "observed real read API" (read_checks > 0);
    require "observed real clear API" (clear_checks > 0);
    require "interaction disabled during read and clear" (violations = 0);
    let read path = Apple_keychain.read ~path in
    require "observed clear removed its item" (read observed = Apple_keychain.Missing);
    require "explicit allowed item" (check_restored "allowed" (fun () -> read allowed)
      = Apple_keychain.Found "dummy-antigravity-credential");
    require "ACL denial is unavailable, not missing"
      (check_restored "denied" (fun () -> read denied) = Apple_keychain.Unavailable);
    require "empty selected keychain never searches another keychain"
      (check_restored "missing" (fun () -> read empty) = Apple_keychain.Missing);
    require "missing clear succeeds"
      (check_restored "clear missing" (fun () -> Apple_keychain.clear ~path:empty) = Ok ());
    security ~home ["lock-keychain"; allowed];
    require "locked read is unavailable"
      (check_restored "locked" (fun () -> read allowed) = Apple_keychain.Unavailable);
    require "locked clear refuses"
      (check_restored "clear locked" (fun () -> Apple_keychain.clear ~path:allowed) = Error ());
    security ~home ["unlock-keychain"; "-p"; "fixture-password"; allowed];
    set_interaction false;
    require "allowed with UI already disabled"
      (check_restored "already disabled" (fun () -> read allowed)
        = Apple_keychain.Found "dummy-antigravity-credential");
    require "denied with UI already disabled"
      (check_restored "already disabled denial" (fun () -> read denied) = Apple_keychain.Unavailable);
    set_interaction true;
    (* More than one domain is essential: restoring a process-wide setting
       without serializing the entire query can re-enable another call's UI. *)
    let workers = List.init 4 (fun _ -> Domain.spawn (fun () ->
      for _ = 1 to 20 do
        require "concurrent allowed" (read allowed = Apple_keychain.Found "dummy-antigravity-credential");
        require "concurrent denied" (read denied = Apple_keychain.Unavailable)
      done)) in
    List.iter Domain.join workers;
    require "concurrent calls restore enabled UI" (interaction_allowed ());
    require "clear allowed" (check_restored "clear" (fun () -> Apple_keychain.clear ~path:allowed) = Ok ());
    require "only selected item cleared" (read allowed = Apple_keychain.Missing);
    require "other keychain still protected" (read denied = Apple_keychain.Unavailable);
    Printf.printf "PASS: native keychain read/clear, denied ACL, locked, missing, restoration, concurrent domains; UI disabled at %d read and %d clear API calls\n%!"
      read_checks clear_checks )

let () =
  let home = Filename.temp_file "masc-keychain-fixture-" "" in
  Unix.unlink home;
  Unix.mkdir home 0o700;
  Fun.protect ~finally:(fun () -> remove_tree home) (fun () -> run home)
