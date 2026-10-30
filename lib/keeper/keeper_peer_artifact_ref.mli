type t = private { blob : Tool_output.artifact_ref; filename : string; purpose : string }
val make : blob:Tool_output.artifact_ref -> filename:string -> purpose:string -> (t, string) result
val of_json : Yojson.Safe.t -> (t, string) result
val to_json : t -> Yojson.Safe.t
