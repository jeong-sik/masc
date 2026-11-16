(* Native macOS regression: only disposable keychains and dummy credentials.
   The agy-shaped fixture is written by security(1) with security(1) as its
   only trusted application, exactly as go-keyring writes agy's login. The
   native-only fixture trusts this test executable alone, so security(1)
   could read it only through a dialog and must never be run on it. *)
external interaction_allowed : unit -> bool = "masc_test_keychain_interaction_allowed"
external set_interaction : bool -> unit = "masc_test_keychain_set_interaction"
external add_trusting_this_executable : string -> unit =
  "masc_test_keychain_add_trusting_this_executable"
external observed_access : string -> int = "masc_test_observed_security_access"
external observed_counts : unit -> int * int = "masc_test_observed_keychain_counts"

(* Codes of masc_antigravity_keychain_security_access. *)
let readable = 0
let inaccessible = 3

let credential = "dummy-antigravity-credential"

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

let add_through_security ~home ?(value = ["-w"; credential]) ~trust path =
  security ~home (["add-generic-password"; "-s"; "gemini"; "-a"; "antigravity"]
    @ value @ trust @ [path])

let check_restored label f =
  let before = interaction_allowed () in
  let result = f () in
  require (label ^ ": restored interaction") (interaction_allowed () = before);
  result

let run home =
  let original = interaction_allowed () in
  Fun.protect ~finally:(fun () -> set_interaction original) (fun () ->
    set_interaction true;
    with_keychain ~home "agy" @@ fun agy ->
    with_keychain ~home "any" @@ fun any ->
    with_keychain ~home "native-only" @@ fun native_only ->
    with_keychain ~home "unprintable" @@ fun unprintable ->
    with_keychain ~home "empty" @@ fun empty ->
    add_through_security ~home ~trust:["-T"; "/usr/bin/security"] agy;
    add_through_security ~home ~trust:["-A"] any;
    add_trusting_this_executable native_only;
    (* 0x01 0x41: security -w prints lowercase hex for a non-printable byte. *)
    add_through_security ~home ~value:["-X"; "0141"] ~trust:["-T"; "/usr/bin/security"]
      unprintable;
    require "observed agy item is readable through security(1)"
      (check_restored "observed agy" (fun () -> observed_access agy) = readable);
    require "observed native-only item is not handed to security(1)"
      (check_restored "observed native-only" (fun () -> observed_access native_only) = inaccessible);
    let access_checks, violations = observed_counts () in
    require "observed real query API" (access_checks > 0);
    require "interaction disabled during the native check" (violations = 0);
    let read path = Apple_keychain.read ~path in
    require "agy-shaped item" (check_restored "agy" (fun () -> read agy)
      = Apple_keychain.Found credential);
    require "any-application item" (check_restored "any" (fun () -> read any)
      = Apple_keychain.Found credential);
    require "non-printable value arrives as security -w prints it"
      (check_restored "unprintable" (fun () -> read unprintable) = Apple_keychain.Found "0141");
    require "item security(1) cannot decrypt is unavailable, not missing"
      (check_restored "native-only" (fun () -> read native_only) = Apple_keychain.Unavailable);
    require "empty selected keychain never searches another keychain"
      (check_restored "missing" (fun () -> read empty) = Apple_keychain.Missing);
    require "missing clear succeeds"
      (check_restored "clear missing" (fun () -> Apple_keychain.clear ~path:empty) = Ok ());
    require "native-only clear refuses"
      (check_restored "clear native-only" (fun () -> Apple_keychain.clear ~path:native_only)
        = Error ());
    security ~home ["lock-keychain"; agy];
    require "locked keychain is not handed to security(1)"
      (check_restored "observed locked" (fun () -> observed_access agy) = inaccessible);
    require "locked read is unavailable"
      (check_restored "locked" (fun () -> read agy) = Apple_keychain.Unavailable);
    require "locked clear refuses"
      (check_restored "clear locked" (fun () -> Apple_keychain.clear ~path:agy) = Error ());
    security ~home ["unlock-keychain"; "-p"; "fixture-password"; agy];
    set_interaction false;
    require "agy item with UI already disabled"
      (check_restored "already disabled" (fun () -> read agy) = Apple_keychain.Found credential);
    require "native-only with UI already disabled"
      (check_restored "already disabled native-only" (fun () -> read native_only)
        = Apple_keychain.Unavailable);
    set_interaction true;
    (* More than one domain is essential: restoring a process-wide setting
       without serializing the entire query can re-enable another call's UI. *)
    let workers = List.init 4 (fun _ -> Domain.spawn (fun () ->
      for _ = 1 to 10 do
        require "concurrent agy" (read agy = Apple_keychain.Found credential);
        require "concurrent native-only" (read native_only = Apple_keychain.Unavailable)
      done)) in
    List.iter Domain.join workers;
    require "concurrent calls restore enabled UI" (interaction_allowed ());
    (* The native check only reads, so a keychain this user cannot rewrite
       passes it; security(1)'s delete then fails and must not read as done.
       The keychain is replaced through its directory, so both are locked. *)
    let fixed_dir = Filename.concat home "read-only" in
    Unix.mkdir fixed_dir 0o700;
    with_keychain ~home:fixed_dir "agy" (fun fixed ->
      add_through_security ~home:fixed_dir ~trust:["-T"; "/usr/bin/security"] fixed;
      Unix.chmod fixed 0o400;
      Unix.chmod fixed_dir 0o500;
      let refused = Fun.protect
        ~finally:(fun () -> Unix.chmod fixed_dir 0o700; Unix.chmod fixed 0o600)
        (fun () -> check_restored "clear read-only" (fun () -> Apple_keychain.clear ~path:fixed)) in
      require "failed security(1) delete is a refusal" (refused = Error ());
      require "refused clear left the item" (read fixed = Apple_keychain.Found credential));
    require "clear agy-shaped item"
      (check_restored "clear" (fun () -> Apple_keychain.clear ~path:agy) = Ok ());
    require "only selected item cleared" (read agy = Apple_keychain.Missing);
    require "other keychain still protected" (read native_only = Apple_keychain.Unavailable);
    require "any-application item untouched" (read any = Apple_keychain.Found credential);
    Printf.printf "PASS: security(1) read/clear of agy-shaped and any-application items, hex value, native-only refusal, locked, missing, restoration, concurrent domains; UI disabled at %d native checks\n%!"
      access_checks )

let () =
  let home = Filename.temp_file "masc-keychain-fixture-" "" in
  Unix.unlink home;
  Unix.mkdir home 0o700;
  Fun.protect ~finally:(fun () -> remove_tree home) (fun () -> run home)
