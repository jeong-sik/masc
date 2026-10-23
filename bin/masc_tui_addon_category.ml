module Category = Masc.Lane_addon_category
let label = function
  | Category.Memory_and_judgment -> "Memory & judgment"
  | Category.Browser -> "Browser"
  | Category.External_communications -> "External communications"
  | Category.Voice_and_media -> "Voice & media"
  | Category.Execution_environment -> "Execution environment"
  | Category.Analysis -> "Analysis"
let order = [Category.Memory_and_judgment; Category.Browser; Category.External_communications;
  Category.Voice_and_media; Category.Execution_environment; Category.Analysis]
let unclassified = "Unclassified"
