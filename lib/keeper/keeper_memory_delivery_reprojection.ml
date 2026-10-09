type reduction = Unchanged | Reprojected
type t = refusal:Agent_core.Error.t -> (reduction, string) result
