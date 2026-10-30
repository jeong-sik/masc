# Candle scope reference inputs and operator anchor

These 20 inputs were proposed by the assistant and remain synthetic. The frozen400-call Grade scope survey retained 20 trials per input, without any human grades in model inputs. Its results are in [the evidence bundle](../../evidence/2026-09-30-candle-grade-scope-survey/README.md).

On 2026-09-30 the operator explicitly assigned case 19 **Epic**, because it changes a common product foundation across Goal, Task, Board and Keeper domains. The choice was made after the survey distribution Medium12/Large6/Epic2 was shown. It establishes a scope policy anchor and is not a blinded validation label. [human-grades.csv](human-grades.csv) records only that supplied grade; the other 19 rows remain blank. Assistant rubric proposals do not fill those rows.

The model receives only title, metric and target from [cases.json](cases.json). It receives no human_grade, reviewer or notes. The case inputs and their SHA256 remain unchanged. Model stability thresholds and the RFC's 20-Goal human agreement criterion remain unadopted and incomplete.

The rule clarified by case 19 is general: an explicitly promised common foundation covering several product domains can be an Epic even if the implementation is one subsystem. A technology swap alone or multiple interfaces for a bounded function do not establish that scope. Further measurements must use a new frozen plan and output directory, retain every attempt and failure, and preserve the earlier surveys.
