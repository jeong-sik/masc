type t =
  | PR_merged of { repo : string; pr_number : int }
  | CI_pass of { repo : string; pr_number : int }
  | Tests_pass of { command : string; expected_exit : int }
  | Artifact_exists of { path : string; min_bytes : int option }
  | File_changed of { path : string; min_bytes : int option }
  | Custom_check of { id : string; payload : Yojson.Safe.t }
[@@deriving show, eq, yojson]

let to_human_string = function
  | PR_merged { repo; pr_number } ->
      Printf.sprintf "pr_merged(%s#%d)" repo pr_number
  | CI_pass { repo; pr_number } ->
      Printf.sprintf "ci_pass(%s#%d)" repo pr_number
  | Tests_pass { command; expected_exit } ->
      Printf.sprintf "tests_pass(%s, exit=%d)" command expected_exit
  | Artifact_exists { path; min_bytes } ->
      let suffix =
        match min_bytes with Some n -> Printf.sprintf ", >=%dB" n | None -> ""
      in
      Printf.sprintf "artifact_exists(%s%s)" path suffix
  | File_changed { path; min_bytes } ->
      let suffix =
        match min_bytes with Some n -> Printf.sprintf ", >=%dB" n | None -> ""
      in
      Printf.sprintf "file_changed(%s%s)" path suffix
  | Custom_check { id; _ } -> Printf.sprintf "custom_check(%s)" id
