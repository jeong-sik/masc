type t =
  | Memory_and_judgment
  | Browser
  | External_communications
  | Voice_and_media
  | Execution_environment
  | Analysis

let to_string = function
  | Memory_and_judgment -> "memory_judgment"
  | Browser -> "browser"
  | External_communications -> "external_communications"
  | Voice_and_media -> "voice_media"
  | Execution_environment -> "execution_environment"
  | Analysis -> "analysis"

let of_string = function
  | "memory_judgment" -> Ok Memory_and_judgment
  | "browser" -> Ok Browser
  | "external_communications" -> Ok External_communications
  | "voice_media" -> Ok Voice_and_media
  | "execution_environment" -> Ok Execution_environment
  | "analysis" -> Ok Analysis
  | _ -> Error "unknown Add-on UI category"

let to_json category = `String (to_string category)
let of_json = function
  | `String category -> of_string category
  | _ -> Error "Add-on UI category must be a supported string"
