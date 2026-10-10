module L = Masc.Keeper_skill_activation_ledger
let forge (activation : L.activation) = { activation with runtime_id = "forged" }
