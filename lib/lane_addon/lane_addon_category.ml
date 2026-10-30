type t =
  | Memory_and_judgment
  | Browser
  | External_communications
  | Voice_and_media
  | Execution_environment
  | Analysis
[@@deriving enumerate]

let to_string = function
  | Memory_and_judgment -> "memory_judgment"
  | Browser -> "browser"
  | External_communications -> "external_communications"
  | Voice_and_media -> "voice_media"
  | Execution_environment -> "execution_environment"
  | Analysis -> "analysis"

let of_string s =
  match List.find_opt (fun v -> String.equal (to_string v) s) all with
  | Some v -> Ok v
  | None -> Error "unknown Add-on UI category"

let to_json category = `String (to_string category)
let of_json = function
  | `String category -> of_string category
  | _ -> Error "Add-on UI category must be a supported string"
