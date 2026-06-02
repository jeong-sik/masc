#use "topfind";;
#require "masc_mcp";;
let () =
  match Masc_mcp.Keeper_identity.canonical_keeper_name_from_agent_name "keeper-direct-agent" with
  | Some name -> Printf.printf "Result: %s\n" name
  | None -> Printf.printf "Result: None\n"
