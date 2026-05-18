(** Output JSON and command parsers used by keeper OAS hook metrics. *)

val json_int_opt : string -> Yojson.Safe.t -> int option
val first_some : 'a option -> 'a option -> 'a option

val output_json_opt :
  ?observe_failure:bool -> surface:string -> string -> Yojson.Safe.t option

val route_via_of_json : Yojson.Safe.t -> string option
val pr_url_of_json : Yojson.Safe.t -> string option
val pr_create_ref_of_input : Yojson.Safe.t -> string option

val command_candidates_of_tool_io :
  tool_name:string ->
  input:Yojson.Safe.t ->
  output_json:Yojson.Safe.t option ->
  string list

val gh_argv_of_segment : string -> string list option
val gh_pr_review_action_of_command : string -> (string * int option) option
val assoc_json_opt : string -> Yojson.Safe.t -> Yojson.Safe.t option
val output_success : transport_success:bool -> Yojson.Safe.t option -> bool
