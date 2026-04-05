(** Coverage tests for Tool_code_write — git clone org validation.

    Tests extract_github_org, validate_clone_url, and clone dispatch
    error paths. Pure function tests do not require Eio or file I/O.
*)

module Tool_code_write = Masc_mcp.Tool_code_write

let test_counter = ref 0
let pass = ref 0
let fail = ref 0

let check name cond =
  incr test_counter;
  if cond then (
    incr pass;
    Printf.printf "\027[32mPASS\027[0m %s\n" name)
  else (
    incr fail;
    Printf.printf "\027[31mFAIL\027[0m %s\n" name)

(* ── extract_github_org ──────────────────────────────────────────── *)

let () = check "extract_github_org: https URL with .git"
  (Tool_code_write.extract_github_org
     "https://github.com/jeong-sik/masc-mcp.git"
   = Some "jeong-sik")

let () = check "extract_github_org: https URL without .git"
  (Tool_code_write.extract_github_org
     "https://github.com/jeong-sik/masc-mcp"
   = Some "jeong-sik")

let () = check "extract_github_org: ssh URL"
  (Tool_code_write.extract_github_org
     "git@github.com:jeong-sik/oas.git"
   = Some "jeong-sik")

let () = check "extract_github_org: ssh protocol URL"
  (Tool_code_write.extract_github_org
     "ssh://git@github.com/jeong-sik/oas.git"
   = Some "jeong-sik")

let () = check "extract_github_org: non-github URL returns None"
  (Tool_code_write.extract_github_org
     "https://gitlab.com/someone/repo.git"
   = None)

let () = check "extract_github_org: bare string returns None"
  (Tool_code_write.extract_github_org "not-a-url" = None)

let () = check "extract_github_org: different org"
  (Tool_code_write.extract_github_org
     "https://github.com/kidsnote/backend.git"
   = Some "kidsnote")

let () = check "extract_github_org: empty string returns None"
  (Tool_code_write.extract_github_org "" = None)

let () = check "extract_github_org: URL with no path after org"
  (Tool_code_write.extract_github_org
     "https://github.com/jeong-sik"
   = None)

(* ── validate_clone_url ──────────────────────────────────────────── *)

let () =
  (* Inject cache to avoid file I/O *)
  Tool_code_write.clone_allowed_orgs_cache := Some ["jeong-sik"]

let () = check "validate_clone_url: allowed org passes"
  (Tool_code_write.validate_clone_url ~base_path:"/tmp"
     "https://github.com/jeong-sik/masc-mcp.git" = Ok ())

let () = check "validate_clone_url: disallowed org rejected"
  (match Tool_code_write.validate_clone_url ~base_path:"/tmp"
     "https://github.com/other-org/repo.git" with
   | Error _ -> true | Ok () -> false)

let () = check "validate_clone_url: non-github URL rejected"
  (match Tool_code_write.validate_clone_url ~base_path:"/tmp"
     "https://gitlab.com/jeong-sik/repo.git" with
   | Error _ -> true | Ok () -> false)

let () = check "validate_clone_url: ssh allowed org passes"
  (Tool_code_write.validate_clone_url ~base_path:"/tmp"
     "git@github.com:jeong-sik/oas.git" = Ok ())

let () =
  Tool_code_write.clone_allowed_orgs_cache := Some []

let () = check "validate_clone_url: empty allowlist rejected"
  (match Tool_code_write.validate_clone_url ~base_path:"/tmp"
     "https://github.com/jeong-sik/repo.git" with
   | Error msg ->
     let needle = "No allowed orgs" in
     (try ignore (Str.search_forward (Str.regexp_string needle) msg 0); true
      with Not_found -> false)
   | Ok () -> false)

(* ── Security: authority spoofing ─────────────────────────────────── *)

let () = check "extract_github_org: domain spoofing github.com.evil.com rejected"
  (Tool_code_write.extract_github_org
     "https://github.com.evil.com/jeong-sik/repo.git"
   = None)

let () = check "extract_github_org: authority spoofing via @ rejected"
  (Tool_code_write.extract_github_org
     "https://jeong-sik@evil.com/repo"
   = None)

(* ── Security: case-insensitive org matching ─────────────────────── *)

let () =
  Tool_code_write.clone_allowed_orgs_cache := Some ["jeong-sik"]

let () = check "validate_clone_url: mixed-case org passes (case-insensitive)"
  (Tool_code_write.validate_clone_url ~base_path:"/tmp"
     "https://github.com/Jeong-Sik/repo.git" = Ok ())

let () = check "extract_github_org: uppercase normalized to lowercase"
  (Tool_code_write.extract_github_org
     "https://github.com/JEONG-SIK/repo.git"
   = Some "jeong-sik")

(* ── Security: org name validation ───────────────────────────────── *)

let () = check "extract_github_org: percent-encoded org rejected"
  (Tool_code_write.extract_github_org
     "https://github.com/jeong%2Dsik/repo.git"
   = None)

let () = check "extract_github_org: org with dots rejected"
  (Tool_code_write.extract_github_org
     "https://github.com/jeong.sik/repo.git"
   = None)

(* ── Summary ─────────────────────────────────────────────────────── *)

let () =
  Printf.printf "\n%d/%d tests passed\n" !pass !test_counter;
  if !fail > 0 then exit 1
