# Shared structured verdict reader. Caller supplies GH and repo; read-only.
# Newest structured verdict for this head; malformed evidence never grants PASS.
verdict_for() { # pr head
  local lines
  lines=$( { "$GH" api --paginate "repos/$repo/issues/$1/comments" --jq '.[] | [(.updated_at // .created_at), .body, (.author_association // "UNKNOWN")] | @tsv' &&
             "$GH" api --paginate "repos/$repo/pulls/$1/reviews" --jq '.[] | [.submitted_at, .body, (.author_association // "UNKNOWN")] | @tsv'; } ) || return 1
  printf '%s\n' "$lines" | awk -F'\t' -v head="$2" '
    { body=$2; sub(/\\n.*/, "", body); sub(/\\r$/, "", body)
      n=split(body, w, " ")
      names_head=0; head_fields=0
      for (i=3; i<n; i++) if (w[i]=="head:") {
        head_fields++; if (w[i+1]==head) names_head=1
      }
      if (w[1]=="verdict:" && names_head) {
        state=w[2]; run="-"; by="-"
        if (state=="PASS" || state=="FAIL") {
          if (body ~ /^verdict: (PASS|FAIL) head: [0-9a-f]+ run: [1-9][0-9]* by: [A-Za-z0-9._-]+$/ &&
              n==8 && head_fields==1 && w[3]=="head:" && w[4]==head &&
              w[5]=="run:" && w[6] ~ /^[1-9][0-9]*$/ &&
              w[7]=="by:" && w[8] ~ /^[A-Za-z0-9._-]+$/) { run=w[6]; by=w[8] }
          else state="INVALID"
        } else if (state!="HOLD" && state!="COMMENT") state="UNKNOWN"
        # Positive authority belongs to repository participants. Unknown or
        # outsider PASS never clears a trusted refusal; refusals stay conservative.
        if (state=="PASS" && $3!="OWNER" && $3!="MEMBER" && $3!="COLLABORATOR") state="UNTRUSTED"
        # Conflicting decisions in the same API timestamp cannot grant PASS.
        if ($1 > t || ($1==t && state!="PASS")) {
          t=$1; v=state" "run" "by
        }
      } }
    END { print v }'
}
