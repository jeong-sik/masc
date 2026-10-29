module Runtime = Keeper_librarian_runtime
module Exact = Lane_addon_exact
let ( let* ) = Result.bind
let ( let+ ) result f = Result.map f result
let require condition detail = if condition then Ok () else Error detail
let fields expected = function
  | `Assoc fields when List.sort String.compare (List.map fst fields)=List.sort String.compare expected -> Ok fields
  | _ -> Error "Original history request has unknown, duplicate or missing fields"
let value name fields = List.assoc name fields
let text = function `String value -> Ok value | _ -> Error "Original history request expects text"
let integer = function `Int value -> Ok value | _ -> Error "Original history request expects an integer"
let boolean = function `Bool value -> Ok value | _ -> Error "Original history request expects a boolean"
let optional encode = Option.fold ~none:`Null ~some:encode
let option decode = function `Null -> Ok None | json -> let+ value=decode json in Some value
let hash text = Agent_core_sha256.(to_hex (digest_string text))
let prompt_json (p:Prompt_registry.prompt_resolution) = `Assoc [
  "effective",`String p.effective;"source",`String (Prompt_registry.prompt_source_to_string p.source);
  "file_value",optional (fun text -> `String text) p.file_value;
  "override_value",optional (fun text -> `String text) p.override_value;
  "file_path",optional (fun text -> `String text) p.file_path;
  "file_exists",`Bool p.file_exists;"has_override",`Bool p.has_override]
let prompt_of_json json =
  let* f=fields ["effective";"source";"file_value";"override_value";"file_path";"file_exists";"has_override"] json in
  let* effective=text (value "effective" f) in
  let* source=text (value "source" f) in
  let* source=match source with "file" -> Ok Prompt_registry.File | "override" -> Ok Prompt_registry.Override
    | "missing" -> Ok Prompt_registry.Missing | _ -> Error "Unknown original history prompt source" in
  let* file_value=option text (value "file_value" f) in
  let* override_value=option text (value "override_value" f) in
  let* file_path=option text (value "file_path" f) in
  let* file_exists=boolean (value "file_exists" f) in
  let+ has_override=boolean (value "has_override" f) in
  {Prompt_registry.effective;source;file_value;override_value;file_path;file_exists;has_override}
type frozen = {parsing_now:float;policy:Runtime.durable_policy;rule_prompt:Prompt_registry.prompt_resolution;
  prompt:Prompt_registry.prompt_resolution;rendered_prompt_sha256:string;output_schema:Yojson.Safe.t}
(* The substitutions and the rendered prompt repeat the input, so they are
   rendered again on restore; the digest names the prompt the host was sent. *)
let to_json (p:Runtime.durable_preparation) = `Assoc [
  "parsing_now",`Float p.parsing_now;
  "policy",`Assoc ["facts_max_bytes",`Int p.policy.facts_max_bytes;"category_cap",`Int p.policy.category_cap;
    "facts_per_category_cap",`Int p.policy.facts_per_category_cap];
  "rule_prompt",prompt_json p.rule_prompt;"prompt",prompt_json p.prompt;
  "rendered_prompt_sha256",`String (hash p.rendered_prompt);"output_schema",p.output_schema]
let of_json json =
  let* f=fields ["parsing_now";"policy";"rule_prompt";"prompt";"rendered_prompt_sha256";"output_schema"] json in
  let* parsing_now=match value "parsing_now" f with
    | `Float time when Float.is_finite time -> Ok time | `Int time -> Ok (float_of_int time)
    | _ -> Error "Original history parse time is not finite" in
  let* limits=fields ["facts_max_bytes";"category_cap";"facts_per_category_cap"] (value "policy" f) in
  let* facts_max_bytes=integer (value "facts_max_bytes" limits) in
  let* category_cap=integer (value "category_cap" limits) in
  let* facts_per_category_cap=integer (value "facts_per_category_cap" limits) in
  let policy : Runtime.durable_policy = {facts_max_bytes;category_cap;facts_per_category_cap} in
  let* rule_prompt=prompt_of_json (value "rule_prompt" f) in
  let* prompt=prompt_of_json (value "prompt" f) in
  let+ rendered_prompt_sha256=text (value "rendered_prompt_sha256" f) in
  {parsing_now;policy;rule_prompt;prompt;rendered_prompt_sha256;output_schema=value "output_schema" f}
let rendered_matches frozen (p:Runtime.durable_preparation) =
  require (String.equal (hash p.rendered_prompt) frozen.rendered_prompt_sha256)
    "Original history prompt differs from the one its host request named"
let request ~request_id (p:Runtime.durable_preparation) = Exact.request_of_json (`Assoc ["kind",`String "exact_output";
  "request_id",`String request_id;"output",`String "durable";
  "messages",`List [`Assoc ["role",`String "user";"text",`String p.rendered_prompt]];
  "schema",p.output_schema])
