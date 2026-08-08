let env_key entry =
  match String.index_opt entry '=' with
  | Some index -> String.sub entry 0 index
  | None -> entry
;;

let is_metered_api_credential = function
  | "OPENAI_API_KEY"
  | "CODEX_API_KEY"
  | "GEMINI_API_KEY"
  | "GOOGLE_API_KEY"
  | "ANTHROPIC_API_KEY" -> true
  | _ -> false
;;

let environment () =
  Unix.environment ()
  |> Array.to_list
  |> List.filter (fun entry -> not (is_metered_api_credential (env_key entry)))
  |> Array.of_list
;;
