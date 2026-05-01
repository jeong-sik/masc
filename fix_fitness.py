import re
with open("lib/tool_agent.ml", "r") as f: content = f.read()

# Fix type
content = re.sub(r'w_handoff : float;\n\s*w_collaboration : float;', 'w_handoff : float;', content)

# Fix defaults
content = re.sub(r'w_completion = 0\.35;', 'w_completion = 0.40;', content)
content = re.sub(r'w_reliability = 0\.25;', 'w_reliability = 0.30;', content)
content = re.sub(r'w_collaboration = 0\.10;', '', content)

# Fix score_for
content = re.sub(r'let score_for \?\(weights = default_fitness_weights\) ~min_avg ~max_collabs metrics =', 
                 'let score_for ?(weights = default_fitness_weights) ~min_avg metrics =', content)
content = re.sub(r'let collaboration =.*?in\n', '', content, flags=re.DOTALL)
content = re.sub(r'\+\. \(weights.w_collaboration \*\. collaboration\)', '', content)
content = re.sub(r'\(score, completion, reliability, speed, handoff, collaboration\)', '(score, completion, reliability, speed, handoff)', content)

# Fix handle_agent_fitness
content = re.sub(r'let max_col = max_collabs metrics_list in', '', content)
content = re.sub(r'let \(score, completion, reliability, speed, handoff, collaboration\) = score_for ~min_avg ~max_collabs:max_col metrics in', 
                 'let (score, completion, reliability, speed, handoff) = score_for ~min_avg metrics in', content)
content = re.sub(r'\("collaboration", `Float collaboration\);', '', content)

with open("lib/tool_agent.ml", "w") as f: f.write(content)
print("done")
