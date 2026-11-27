const __vite__mapDeps=(i,m=__vite__mapDeps,d=(m.f||(m.f=["assets/wiki-tab.js","assets/vendor.js","assets/markdown-renderer.js","assets/index.js","assets/markdown.js","assets/core.js","assets/type-guards.js","assets/master-detail.js","assets/refresh-button.js","assets/virtual-list.js","assets/table.js","assets/useSelector.js","assets/wire-decode.js","assets/lazy-component.js","assets/attachment-gallery.js","assets/copyable-code.js","assets/toast.js","assets/index6.css","assets/markdown-renderer.css","assets/artifacts-tab.js","assets/memory-tab.js","assets/inline-spinner.js","assets/data-table.js","assets/uplot-chart.js"])))=>i.map(i=>d[i]);
import{U as ie,V as ee,a as Q,O as ht,$ as Vt,z as Ie,A as he,K as kn,C as $n,M as yn,L as _n,Y as oe,D as Cn,Q as ge,B as re,o as ot,ae as _t,am as An}from"./index.js";import{T as ae,d as S,A as U,y as me,q as Fe,m as i,P as Sn}from"./vendor.js";import{c as Ct}from"./lazy-component.js";import{r as ve,A as qt,h as rt,a as at,b as zt,c as Jt}from"./attachment-gallery.js";import{d as wn,a as Rn,M as gt}from"./markdown-renderer.js";import{K as vt}from"./core.js";import{M as Pn}from"./master-detail.js";import{R as Mn}from"./refresh-button.js";import{V as In}from"./virtual-list.js";import"./copyable-code.js";import"./toast.js";import"./markdown.js";import"./type-guards.js";import"./table.js";import"./useSelector.js";function Zt(e){const n=e.trim().toLowerCase();return n==="wiki"||n==="artifacts"||n==="memory"||n==="board"?n:"board"}function f(e){return typeof e=="object"&&e!==null&&!Array.isArray(e)}function b(e){if(typeof e!="string")return null;const n=e.trim();return n.length>0?n:null}function w(e,n=""){return typeof e=="string"?e:n}function te(e){return typeof e=="number"&&Number.isFinite(e)?e:null}function l(e){return typeof e=="number"&&Number.isSafeInteger(e)?e:null}function Te(e){return Array.isArray(e)?e.filter(n=>typeof n=="string"&&n.trim().length>0):[]}const Tn=512,it=new Map;function On(e){const n=it.get(e);if(n!==void 0)return n;const r=Date.parse(e);return it.size>=Tn&&it.clear(),it.set(e,r),r}function ct(e,n=Date.now()){if(e==null||e==="")return"없음";let r;if(typeof e=="number"){if(!Number.isFinite(e))return"없음";r=e<1e12?e*1e3:e}else{const p=On(e);if(Number.isNaN(p))return e;r=p}const a=Math.round((n-r)/1e3);return a<45?"방금 전":a<3600?`${Math.floor(a/60)}분 전`:a<86400?`${Math.floor(a/3600)}시간 전`:`${Math.floor(a/86400)}일 전`}function ss(e){return e==null||!Number.isFinite(e)?"없음":e<1024?`${Math.trunc(e)} B`:e<1024*1024?`${(e/1024).toFixed(1)} KB`:`${(e/(1024*1024)).toFixed(2)} MB`}const xn=["👍","🔥","👀","🎉","❤️","🤔"];function En(e){if(typeof e.serverIsSignal=="boolean")return e.serverIsSignal;if(e.postKind==="system"||e.hearth?.toLowerCase()==="verification")return!1;const n=e.title.trim();return!(n.startsWith("Verify:")||n.startsWith("[verify]")||n.startsWith("Approved task")||n.startsWith("Rejected task"))}function Ln(e,n){const r=new Map;for(const s of e)r.set(s.emoji,s);const a=[],p=[],k=new Set;for(const s of e)k.add(s.emoji),s.count>0?a.push(s):p.push(s.emoji);const u=n.length>0?n:xn;for(const s of u){if(k.has(s))continue;k.add(s);const h=r.get(s);(!h||h.count<=0)&&p.push(s)}return{active:a,collapsedZero:p}}function Gt(e){const n=new Map;for(let s=0;s<e.length;s++){const h=e[s];n.set(h.id,h)}const r=new Map,a=s=>{const h=r.get(s);if(h!==void 0)return h;const I=n.get(s)?.closed?.successorId;if(!I||!n.has(I)||I===s)return r.set(s,s),s;const V=new Set([s]),m=[s];let y=I,O=!1;for(;;){const d=r.get(y);if(d!==void 0){y=d;break}V.add(y),m.push(y);const A=n.get(y)?.closed?.successorId;if(!A||!n.has(A))break;if(V.has(A)){O=!0;break}y=A}if(!O)for(let d=0;d<m.length;d++)r.set(m[d],y);return y},p=new Map,k=new Set;for(let s=0;s<e.length;s++){const h=e[s],R=a(h.id);if(R!==h.id){k.add(h.id);let I=p.get(R);I||(I=[],p.set(R,I)),I.push(h)}}const u=[];for(let s=0;s<e.length;s++){const h=e[s];k.has(h.id)||u.push({head:h,predecessors:p.get(h.id)??[]})}return u}function en(e){if(!f(e))return null;const n=b(e.kind)?.toLowerCase();return n==="targets"?{kind:"targets",targets:Te(e.targets)}:n==="broadcast"?{kind:"broadcast"}:n==="thread_participants"?{kind:"thread_participants"}:n==="discoverable"?{kind:"discoverable"}:null}function Qt(e){if(typeof e=="string")return e;if(typeof e=="number"&&Number.isFinite(e)){const n=e<1e12?e*1e3:e;return new Date(n).toISOString()}return""}function Dn(e){const n=e.indexOf(`
`),r=(n===-1?e:e.slice(0,n)).trim();return r.length>0?r.slice(0,80):"제목 없음"}function tn(e){const n=Array.isArray(e.attachments)?e.attachments:Array.isArray(e.attachment_refs)?e.attachment_refs:[],r=[];for(const a of n){const p=wn(a);p&&r.push(p)}return Rn(r)}function kt(e){if(!f(e))return null;const n=b(e.id),r=b(e.author);if(!n||!r)return null;const a=w(e.body,w(e.content,"")),p=b(e.title)??Dn(a),k=w(e.post_kind,"").toLowerCase(),u=k==="human"||k==="direct"?"direct":k==="automation"?"automation":k==="system"?"system":null,s=b(e.hearth),h=te(e.votes_up)??0,R=te(e.votes_down)??0,I=te(e.votes)??h-R,V=e.current_vote==="up"||e.current_vote==="down"?e.current_vote:null,m=[];if(Array.isArray(e.reactions))for(let D=0;D<e.reactions.length;D++){const A=e.reactions[D];if(!f(A))continue;const ke=b(A.emoji);ke&&m.push({emoji:ke,count:te(A.count)??0,reacted:A.reacted===!0})}let y=null;f(e.closed)&&b(e.closed.closed_by)&&(y={closedBy:w(e.closed.closed_by,""),closedAt:String(e.closed.closed_at??""),successorId:b(e.closed.successor_id),summary:b(e.closed.summary)});const O=e.created_at_iso??e.created_at,d=e.updated_at_iso??e.updated_at??O;return{id:n,title:p,body:a,author:r,hearth:s,postKind:u,visibility:b(e.visibility),audience:en(e.audience),pinned:e.pinned===!0,votes:I,currentVote:V,commentCount:te(e.comment_count)??te(e.reply_count)??0,createdAt:Qt(O),updatedAt:Qt(d),tags:Te(e.tags),reactions:m,supportedReactionEmojis:Te(e.supported_reaction_emojis),attachments:tn(e),closed:y,isSignal:En({postKind:u,hearth:s,title:p,serverIsSignal:typeof e.is_signal=="boolean"?e.is_signal:void 0})}}function lt(e){if(!f(e))return null;const n=b(e.id),r=b(e.author);if(!n||!r)return null;const a=te(e.votes_up)??0,p=te(e.votes_down)??0,k=te(e.votes)??te(e.score)??a-p,u=[];if(Array.isArray(e.reactions))for(const R of e.reactions){if(!f(R))continue;const I=b(R.emoji);I&&u.push({emoji:I,count:te(R.count)??0,reacted:R.reacted===!0})}const s=e.created_at,h=typeof s=="string"?s:typeof s=="number"&&Number.isFinite(s)?new Date(s<1e12?s*1e3:s).toISOString():"";return{id:n,postId:w(e.post_id,""),parentId:b(e.parent_id),author:r,content:w(e.content,w(e.body,"")),createdAt:h,votes:k,currentVote:e.current_vote==="up"||e.current_vote==="down"?e.current_vote:null,reactions:u,attachments:tn(e),audience:en(e.audience)}}const os=["direct_experience","research","experiment","observation"],rs=["page","own_file","external","invalid_name","unsupported:anchor","unsupported:scheme","unsupported:path","unsupported:not_markdown","unsupported:wikilink"];function as(e){if(!f(e))return null;const n=b(e.id),r=b(e.title);if(!n||!r)return null;const a=e.format==="html"?"html":"markdown",p=f(e.body)?e.body:null,k=p&&f(p._blob)?p._blob:p,u=(k?b(k.sha256):null)??w(e.sha256,""),s=l(k?k.bytes:e.bytes);return{id:n,revision:l(e.revision)??1,title:r,summary:w(e.summary,""),format:a,author:w(e.author,"unknown"),createdAt:w(e.created_at,""),sha256:u,bytes:s,taskId:b(e.task_id),goalId:b(e.goal_id)}}function is(e){if(!f(e))return ie("World Memory 응답이 JSON 객체가 아닙니다.");const n=e.ledger_state==="missing"?"missing":e.ledger_state==="available"?"available":null;if(!n)return ie(`알 수 없는 World Memory ledger_state: ${String(e.ledger_state)}`);const r=e.source==="world_memory_db"?"world_memory_db":"legacy_ledger",a=f(e.inventory)?e.inventory:{};let p=null;if(f(e.world_mvcc)){const m=e.world_mvcc;p={digestRevision:l(m.digest_revision),digestSha256:b(m.digest_sha256),edgesCount:l(m.edges_count)??0,indexCount:l(m.index_count)??0,canonicalCount:l(m.canonical_count)??0,wikiCount:l(m.wiki_count)??0,artifactCount:l(m.artifact_count)??0,resourceCount:l(m.resource_count)??0}}const k=[];if(Array.isArray(e.claims))for(const m of e.claims){if(!f(m))continue;const y=b(m.claim_id);y&&k.push({claimId:y,claim:w(m.claim,""),stage:w(m.stage,"unknown"),supportingKeepers:Te(m.supporting_keepers),supportCount:l(m.support_count)??0,hasSourceBound:m.has_source_bound===!0,category:b(m.category),scope:b(m.scope),facets:Te(m.facets),revision:l(m.revision)})}const u=[];if(Array.isArray(e.active_conflicts))for(const m of e.active_conflicts){if(!f(m))continue;const y=b(m.conflict_id);if(!y)continue;const O=[];if(Array.isArray(m.competing_claims))for(const d of m.competing_claims)f(d)&&O.push({storeKind:w(d.store_kind,"ordinary"),keeperId:w(d.keeper_id,"unknown"),path:b(d.path),claimSha256:w(d.claim_sha256,""),resolved:d.resolved===!0,claim:b(d.claim),category:b(d.category),origin:b(d.origin)});u.push({conflictId:y,description:w(m.description,""),memberCount:l(m.member_count)??O.length,competingClaims:O})}const s=f(e.briefing)?e.briefing:{},h=f(s.building_pass)?s.building_pass:null,R=f(e.librarian_writers)?e.librarian_writers:{},I=R.writers==="running"?"running":"none_in_process",V=[];if(I==="running"&&Array.isArray(R.keepers))for(const m of R.keepers){if(!f(m))continue;const y=b(m.keeper),O=f(m.row)?m.row:m;if(!y)continue;const d=f(O.snapshot_file)?O.snapshot_file:null;V.push({keeper:y,state:w(O.state,"unknown"),stopReason:b(O.stop)??b(O.stop_reason)??b(O.stopped),availableActs:Te(O.available_acts),snapshotSha:d?b(d.sha):null,snapshotBytes:d?l(d.bytes):null,snapshotFault:d?b(d.fault):null})}return ee({sourceKind:r,ledgerState:n,ledgerSha256:b(a.ledger_sha256),claimsCount:l(a.claims_count)??k.length,factsCount:l(a.facts_count)??0,classifiedCount:l(a.classified_count),conflictsCount:l(a.conflicts_count)??u.length,excludedCount:l(a.excluded_count)??0,worldMvcc:p,claims:k,activeConflicts:u,briefing:{status:w(s.status,"missing"),text:b(s.text),sourceIdsCount:l(s.source_ids_count)??0,error:b(s.error),buildingTarget:h?l(h.target):null,buildingRemaining:h?l(h.remaining):null},writersMode:I,writersErrorCount:l(R.error)??0,writersWarnCount:l(R.warn)??0,writers:V})}function cs(e){if(!f(e))return ie("workspace-memory-inventory 응답이 객체가 아닙니다.");const n=e.status==="available"?"available":e.status==="missing"?"missing":null;if(!n)return ie(`알 수 없는 workspace-memory-inventory status: ${String(e.status)}`);const r=f(e.ordinary_absence)?e.ordinary_absence:{},a=f(e.briefing)?e.briefing:{},p=f(a.building)?a.building:null;return ee({sourceKind:"workspace_inventory_fallback",ledgerState:n,ledgerSha256:b(e.ledger_sha256),claimsCount:l(e.claim_count)??0,factsCount:l(r.facts)??0,classifiedCount:null,conflictsCount:l(e.conflict_count)??0,excludedCount:l(e.excluded_count)??0,worldMvcc:null,claims:[],activeConflicts:[],briefing:{status:w(a.status,"missing"),text:null,sourceIdsCount:l(e.claim_count)??0,error:null,buildingTarget:p?l(p.target):null,buildingRemaining:p?l(p.remaining):null},writersMode:"none_in_process",writersErrorCount:0,writersWarnCount:0,writers:[]})}function ls(e){return`/api/v1/memory/diff?${new URLSearchParams({scope:"world",window:e}).toString()}`}function ds(e){if(!f(e))return ie("World Diff 응답이 JSON 객체가 아닙니다.");const n=f(e.range)?e.range:{},r=f(e.counts)?e.counts:{},a=f(e.retrieval_heat)?e.retrieval_heat:{},p=Array.isArray(e.revisions)?e.revisions:[],k=[];for(const u of p)f(u)&&k.push({rev:l(u.rev)??0,batchId:w(u.batch_id,""),factId:w(u.fact_id,""),recordedAt:w(u.recorded_at,""),op:w(u.op,"")});return ee({window:b(n.window),counts:{totalClaimsNow:l(r.total_claims_now)??0,added:l(r.added)??0,updated:l(r.updated)??0,retracted:l(r.retracted)??0,incompleteBatches:l(r.incomplete_batches)??0,abortedBatches:l(r.aborted_batches)??0},retrievalHeat:{hot:l(a.hot)??0,warm:l(a.warm)??0,cold:l(a.cold)??0,neverRetrieved:l(a.never_retrieved)??0,totalEvents:l(a.total_events)??0},revisions:k,added:Array.isArray(e.added)?e.added:[],updated:Array.isArray(e.updated)?e.updated:[],retracted:Array.isArray(e.retracted)?e.retracted:[]})}function us(e){if(e.revisions.length===0)return{timestamps:[],added:[],retracted:[],netTotal:[]};const n=e.revisions.map(d=>({ts:Math.floor((Date.parse(d.recordedAt)||0)/1e3),op:d.op.toLowerCase(),rev:d.rev})).filter(d=>d.ts>0).sort((d,D)=>d.ts-D.ts||d.rev-D.rev);if(n.length===0)return{timestamps:[],added:[],retracted:[],netTotal:[]};const r=n[n.length-1].ts-n[0].ts,a=r>3*86400?21600:r>=7200?3600:60,p=new Set(["retracted","retract","removed","remove","deleted","delete"]),k=new Set(["added","add","created","create","inserted","insert"]),u=new Map;for(const d of n){const D=Math.floor(d.ts/a)*a,A=u.get(D)??{added:0,retracted:0};p.has(d.op)?A.retracted+=1:k.has(d.op)&&(A.added+=1),u.set(D,A)}const s=[...u.keys()].sort((d,D)=>d-D),h=[],R=[],I=[],V=[];let m=0;for(const d of s){const D=u.get(d);h.push(d),R.push(D.added),I.push(D.retracted===0?0:-D.retracted),m+=D.added-D.retracted,V.push(m)}const y=Math.max(0,e.counts.totalClaimsNow-m),O=V.map(d=>Math.max(0,y+d));return{timestamps:h,added:R,retracted:I,netTotal:O}}function ms(e){switch(e.action){case"resume":return ee({action:"resume"});case"adopt":{const n=e.observed?.trim()??"";return n?ee({action:"adopt",observed:n}):ie("adopt 실행에는 snapshot SHA-256(observed) 값이 필요합니다.")}case"restart_reading":{const n=e.observed?.trim()??"";return n?ee({action:"restart_reading",observed:n}):ie("restart_reading 실행에는 turn log ID(observed)가 필요합니다.")}case"skip_item":{const n=e.turnLog?.trim()??"",r=e.line;if(!n||r===void 0||!Number.isSafeInteger(r)||r<0)return ie("skip_item 실행에는 turn_log와 0 이상의 line 오프셋이 필요합니다.");const a=e.store?.trim()??"";return a&&e.at!==void 0&&Number.isSafeInteger(e.at)&&e.at>=0?ee({action:"skip_item",target:{kind:"head_item",turn_log:n,line:r,store:a,at:e.at}}):ee({action:"skip_item",target:{kind:"unreadable_unit",turn_log:n,line:r}})}case"skip_line":{const n=e.offset;return n===void 0||!Number.isSafeInteger(n)||n<0?ie("skip_line 실행에는 0 이상의 바이트 offset이 필요합니다."):ee({action:"skip_line",offset:n})}}}function Bn(e,n){if(!f(e)||e.ok!==!0||typeof e.message!="string")return null;try{const r=JSON.parse(e.message);return f(r)&&r.post_id===n?b(r.id):null}catch{return null}}function $t(e){if(!f(e))return null;const n=l(e.offset),r=l(e.returned),a=l(e.total);return n===null||r===null||a===null?null:{offset:n,returned:r,total:a,nextOffset:l(e.next_offset)}}function yt(e,n=!1){return e?e.kind==="targets"&&e.targets.length>0?n&&e.targets.length>1?i`
        <span
          class="kn-badge kn-badge--info"
          title=${e.targets.map(r=>`@${r}`).join(", ")}
        >
          @${e.targets[0]} +${e.targets.length-1}
        </span>
      `:i`
      ${e.targets.map(r=>i`
        <span key=${r} class="kn-badge kn-badge--info">@${r}</span>
      `)}
    `:e.kind==="broadcast"?i`<span class="kn-badge kn-badge--info">@broadcast</span>`:null:null}function Kn(e){const n=new Map;for(const r of e)r.hearth&&n.set(r.hearth,(n.get(r.hearth)??0)+1);return[...n.entries()].sort((r,a)=>a[1]-r[1]||r[0].localeCompare(a[0])).map(([r,a])=>({name:r,count:a}))}function Xt(e){const[n,r]=S(!1),a=U(null),{active:p,collapsedZero:k}=ae(()=>Ln(e.reactions,e.supportedEmojis),[e.reactions,e.supportedEmojis]);return me(()=>{if(!n)return;const u=h=>{a.current&&!a.current.contains(h.target)&&r(!1)},s=h=>{if(!(h.defaultPrevented||h.isComposing||h.keyCode===229)&&h.key==="Escape"){if(typeof document<"u"&&document.querySelector('[role="dialog"][aria-modal="true"]'))return;h.preventDefault(),h.stopPropagation(),r(!1),a.current?.querySelector('button[aria-label="반응 추가"]')?.focus()}};return document.addEventListener("mousedown",u),document.addEventListener("keydown",s),()=>{document.removeEventListener("mousedown",u),document.removeEventListener("keydown",s)}},[n]),i`
    <div ref=${a} class="kn-reactions">
      ${p.map(u=>i`
        <button
          key=${u.emoji}
          type="button"
          class="kn-react-pill"
          aria-pressed=${u.reacted}
          disabled=${e.disabled}
          onClick=${()=>e.onToggle(u.emoji)}
        >
          <span>${u.emoji}</span>
          <span class="tnum">${u.count}</span>
        </button>
      `)}
      ${k.length>0&&i`
        <button
          type="button"
          class="kn-react-pill"
          aria-expanded=${n}
          aria-label="반응 추가"
          disabled=${e.disabled}
          onClick=${()=>r(u=>!u)}
        >
          +☺
        </button>
      `}
      ${n&&k.length>0&&i`
        <div class="kn-react-picker" role="group" aria-label="이모지 선택">
          ${k.map(u=>i`
            <button
              key=${u}
              type="button"
              class="kn-react-pill"
              disabled=${e.disabled}
              onClick=${()=>{r(!1),e.onToggle(u)}}
            >
              ${u}
            </button>
          `)}
        </div>
      `}
    </div>
  `}const Nn={posts:[],hearths:[],subBoards:[],hasMore:!1,filteredOutCount:0,signalScanTruncated:!1};function Yt(e,n,r,a){const p=new URLSearchParams({sort_by:n,limit:"200"});return r&&(p.set("signal_only","true"),p.set("exclude_system","true")),a&&p.set("hearth",a),{params:p,cacheKey:`kn:board:${e?"ma":"local"}:${p.toString()}`}}function Wn(e){const n=Q.value,r=n.kind==="single_user_local",a=!r,p=r&&!ht("admin",n),k=Vt(n),u=ae(()=>{const{cacheKey:t}=Yt(a,"recent",!0,""),o=Ie.peek(t);return o?.kind==="value"?o.data:null},[]),[s,h]=S(()=>u??Nn),[R,I]=S(()=>u===null),[V,m]=S(null),[y,O]=S(!0),[d,D]=S("recent"),[A,ke]=S(""),[He,rn]=S(""),[B,Oe]=S(()=>e.entityId??u?.posts[0]?.id??null),[$e,fe]=S(null),[At,Ue]=S(!1),[an,Ve]=S(!1),[qe,ze]=S(!1),[dt,X]=S(null),[St,cn]=S({}),[ye,_e]=S(0),ne=U(null),Ce=U(null),se=U(0),xe=U(!1),wt=U(null),Y=U(!0);me(()=>(Y.current=!0,()=>{Y.current=!1}),[]),wt.current=$e;const Rt=U(0),G=U(B);G.current=B;const Ee=40,ce=40,[Je,Ge]=S(!1),[Le,Pt]=S(""),[De,Mt]=S(""),[Qe,ln]=S(""),[Ae,Xe]=S([]),[Be,ut]=S(""),[Ye,Ze]=S(null),[Ke,mt]=S([]),[W,q]=S(!1),le=U(Ae);le.current=Ae;const pe=U(Ke);pe.current=Ke,me(()=>()=>{ve(le.current),ve(pe.current)},[]);const[It,E]=S(null),ft=U(null),Tt=U(null),Ot=U(null),Se=U(null),Z=Fe(async(t="mount")=>{const o=++Rt.current;t!=="sse"&&I(!0),m(null);const c=Q.peek().kind==="multi_account_signed_in",{params:g,cacheKey:$}=Yt(c,d,y,A),P=await Ie.fetch($,async L=>{if(c){const T=await he(`/api/v1/dashboard/board?${g.toString()}`,{signal:L});if(!T.ok)return T;const K=f(T.value)?T.value:null,F=[];if(K&&Array.isArray(K.posts))for(const de of K.posts){const tt=kt(de);tt&&F.push(tt)}return ee({posts:F,hearths:Kn(F),subBoards:[],hasMore:K?.has_more===!0,filteredOutCount:l(K?.filtered_out_count)??0,signalScanTruncated:K?.signal_scan_truncated===!0})}const[x,N,z]=await Promise.all([he(`/api/v1/board?${g.toString()}`,{signal:L}),he("/api/v1/board/hearths",{signal:L}),he("/api/v1/board/sub-boards",{signal:L})]);if(!x.ok)return x;const C=f(x.value)?x.value:null,j=[];if(C&&Array.isArray(C.posts))for(const T of C.posts){const K=kt(T);K&&j.push(K)}const M=[];if(N.ok&&f(N.value)&&Array.isArray(N.value.hearths))for(const T of N.value.hearths){if(!f(T))continue;const K=b(T.name);K&&M.push({name:K,count:l(T.count)??0})}const J=[];if(z.ok&&f(z.value)&&Array.isArray(z.value.sub_boards))for(const T of z.value.sub_boards){if(!f(T))continue;const K=b(T.id),F=b(T.slug);if(!K||!F)continue;const de=T.access==="members_only"||T.access==="owner_only"?T.access:"open";J.push({id:K,slug:F,name:w(T.name,F),description:w(T.description,""),access:de,postCount:l(T.post_count)??0})}return ee({posts:j,hearths:M,subBoards:J,hasMore:C?.has_more===!0,filteredOutCount:l(C?.filtered_out_count)??0,signalScanTruncated:C?.signal_scan_truncated===!0})},{ttlMs:1e4,topics:["board","board_post","board_comment"],reason:t});o===Rt.current&&(I(!1),P.kind==="value"?(h(P.data),kn(),Oe(L=>L&&(L===e.entityId||P.data.posts.some(x=>x.id===L))?L:P.data.posts[0]?.id??null)):P.kind==="failed"&&m(P.error.message))},[d,y,A,e.entityId,a]);me(()=>{e.entityId&&Oe(e.entityId)},[e.entityId]),me(()=>{Z("mount")},[Z]);const we=Fe(async(t,o,c)=>{const g=c?.preserveOnError??!1,$=c?.resetWindow??!0,P=++se.current;if(Ce.current?.abort(),ze(!1),Q.peek().kind==="multi_account_signed_in"){xe.current=!1,Ve(!1),fe(null),Ue(!1),X(null);return}const L=wt.current,x=L!==null&&L.post.id===t,N=x&&!$?Math.max(Ee,L.comments.length):Ee;xe.current=!0,Ve(!0),g||Ue(!0),X(null);try{const z=Se.current,C=z?.postId===t?z.commentId:null,j=new URLSearchParams({format:"flat",comment_limit:String(Ee),comment_offset:"0"});C&&j.set("comment_focus",C);const M=await he(`/api/v1/board/${encodeURIComponent(t)}?${j}`,{signal:o});if(o?.aborted||P!==se.current)return;if(Ue(!1),!M.ok){if(M.error.kind==="aborted"||M.error.kind==="epoch_stale")return;g||fe(null),X(`게시글 상세/댓글 조회 실패: ${M.error.message}`);return}if(!f(M.value)){g||fe(null),X("게시글 상세 응답 형식이 올바르지 않습니다.");return}const J=f(M.value.post)?M.value.post:M.value,T=kt(J);if(!T){g||fe(null),X("게시글 상세 파싱에 실패했습니다.");return}const K=Array.isArray(M.value.comments)?M.value.comments:Array.isArray(M.value.comment_context)?M.value.comment_context:[],F=[],de=new Set;for(const H of K){const Pe=lt(H);Pe&&!de.has(Pe.id)&&(de.add(Pe.id),F.push(Pe))}const tt=C&&Array.isArray(M.value.comment_context)?M.value.comment_context.find(H=>f(H)&&H.id===C&&H.post_id===t):null;let bt=C?F.find(H=>H.id===C&&H.postId===t)??lt(tt):null,Re=$t(M.value.comment_page),Ht=0;for(;x&&!$&&F.length<N&&Re!==null&&Re.nextOffset!==null&&Re.nextOffset>Ht;){const H=Re.nextOffset,Pe=new URLSearchParams({format:"flat",comment_limit:String(Ee),comment_offset:String(H)}),ue=await he(`/api/v1/board/${encodeURIComponent(t)}?${Pe}`,{signal:o});if(o?.aborted||P!==se.current)return;if(!ue.ok){if(ue.error.kind==="aborted"||ue.error.kind==="epoch_stale")return;X(`게시글 상세/댓글 조회 실패: ${ue.error.message}`);return}if(!f(ue.value)){X("게시글 댓글 페이지 응답 형식이 올바르지 않아 기존 목록을 유지합니다.");return}const Me=$t(ue.value.comment_page);if(Me!==null&&Me.offset!==H){X("게시글 댓글 페이지 순서가 어긋나 기존 목록을 유지합니다.");return}const vn=Array.isArray(ue.value.comments)?ue.value.comments:[];let Ut=0;for(const nt of vn){const st=lt(nt);st&&!de.has(st.id)&&(de.add(st.id),F.push(st),Ut+=1)}if(Re=Me,Ht=H,C&&!bt&&(bt=F.find(nt=>nt.id===C&&nt.postId===t)??null),Ut===0||Me===null||Me.nextOffset===null||Me.nextOffset<=H)break}if(o?.aborted||P!==se.current)return;_e($?0:H=>Math.min(H,Math.max(0,F.length-ce))),fe({post:T,comments:F,commentPage:Re,focusedComment:bt})}finally{P===se.current&&(xe.current=!1,Ve(!1))}},[]);me(()=>{const t=new Set(["board","board_post","board_comment","board_changed","notifications/board"]);let o=null,c=!1;const g=$n(x=>{const N=Cn(x);if(!N.some(j=>t.has(j)))return;const z=f(x.data)?b(x.data.post_id)??(f(x.data.payload)?b(x.data.payload.post_id):null):null,C=G.current;N.includes("board_comment")&&(!z||C!==null&&z===C)&&(c=!0),!o&&(o=setTimeout(()=>{o=null;const j=c;c=!1,Z("sse");const M=G.current;if(j&&M&&Q.peek().kind!=="multi_account_signed_in"){ne.current?.abort();const J=new AbortController;ne.current=J,we(M,J.signal,{preserveOnError:!0,resetWindow:!1})}},450))}),$=()=>{o&&(clearTimeout(o),o=null),c=!1,Z("sse");const x=G.current;if(x&&Q.peek().kind!=="multi_account_signed_in"){ne.current?.abort();const N=new AbortController;ne.current=N,we(x,N.signal,{preserveOnError:!0,resetWindow:!1})}},P=yn($),L=_n($);return()=>{g(),P(),L(),o&&clearTimeout(o)}},[Z,we]);const _=$e&&$e.post.id===B?$e:null,Ne=_?.focusedComment,dn=ae(()=>{const t=_?.comments.slice(ye,ye+ce)??[];return Ne&&!_?.comments.some(o=>o.id===Ne.id)?[...t,Ne]:t},[_,ye,Ne]);me(()=>{const t=Se.current;if(!t?.scroll||t.postId!==_?.post.id)return;const o=t.commentId===null?Tt.current:_.focusedComment?.id===t.commentId?Ot.current:null;o&&(t.scroll=!1,o.scrollIntoView?.({block:"nearest",behavior:"smooth"}))},[_]);const un=Fe(async()=>{if(!_||_.commentPage?.nextOffset==null||qe||xe.current)return;Ce.current?.abort();const t=new AbortController;Ce.current=t;const o=_.post.id,c=se.current,g=_.commentPage.nextOffset;ze(!0),X(null);try{const $=await he(`/api/v1/board/${encodeURIComponent(o)}?format=flat&comment_limit=${Ee}&comment_offset=${g}`,{signal:t.signal});if(t.signal.aborted||G.current!==o||c!==se.current)return;if(!$.ok){if($.error.kind==="aborted"||$.error.kind==="epoch_stale")return;X(`추가 댓글 조회 실패: ${$.error.message}`);return}if(!f($.value))return;const P=Array.isArray($.value.comments)?$.value.comments:[],L=[];for(const C of P){const j=lt(C);j&&L.push(j)}const x=$t($.value.comment_page);if(x!==null&&x.offset!==g)return;let N=0,z=!1;fe(C=>{if(!C||C.post.id!==o||c!==se.current||C.commentPage?.nextOffset!==g)return C;const j=new Set(C.comments.map(J=>J.id)),M=[...C.comments];for(const J of L)j.has(J.id)||(j.add(J.id),M.push(J));return N=M.length,z=!0,{...C,comments:M,commentPage:x}}),z&&N>ce&&_e(Math.max(0,N-ce))}finally{Ce.current===t&&ze(!1)}},[_,qe]);me(()=>{if(se.current+=1,ne.current?.abort(),Ce.current?.abort(),xe.current=!1,Ve(!1),ze(!1),_e(0),Ze(null),ut(""),ve(pe.current),mt([]),!B){fe(null),Ue(!1),X(null);return}const t=new AbortController;return Se.current={postId:B,commentId:null,scroll:!1},ne.current=t,we(B,t.signal,{preserveOnError:!1,resetWindow:!0}),()=>{Se.current=null,t.abort(),ne.current?.abort(),Ce.current?.abort()}},[B,a,we]);const We=ae(()=>{const t=He.trim().toLowerCase();if(!y&&!A&&t.length===0)return Gt(s.posts);const o=s.posts.filter(c=>!(y&&!c.isSignal||A&&c.hearth!==A||t&&!c.title.toLowerCase().includes(t)&&!c.body.toLowerCase().includes(t)&&!c.author.toLowerCase().includes(t)));return Gt(o)},[s.posts,y,A,He]),mn=ae(()=>s.posts.find(t=>t.id===B)??null,[s.posts,B]),v=$e?.post.id===B?$e.post:mn,et=ae(()=>We.find(t=>t.head.id===B)??null,[We,B]),je=async t=>{ne.current?.abort();const o=new AbortController;ne.current=o,await we(t,o.signal,{preserveOnError:!0,resetWindow:!1})},fn=()=>{if(Je){const t=le.current.filter(o=>o.status==="uploading");t.length>0&&(ve(t),Xe(o=>o.filter(c=>c.status!=="uploading"))),Ge(!1)}else Ge(!0)},xt=async t=>{if(t.preventDefault(),Q.peek().kind!=="single_user_local")return;if(rt(le.current)){E({kind:"err",message:"첨부 파일 업로드가 완료된 뒤 게시하세요."});return}if(at(le.current)){E({kind:"err",message:"업로드에 실패한 첨부 파일을 재시도하거나 제거한 뒤 게시하세요."});return}const o=Jt(le.current);if(!Le.trim()||!De.trim()){E({kind:"err",message:"제목과 본문을 입력하세요."});return}const c=oe();q(!0),E(null);const g={title:Le.trim(),content:De.trim(),author:"operator"};Qe.trim()&&(g.hearth=Qe.trim()),o.length>0&&(g.attachment_ids=o.map(P=>P.attachment_id||P.id));const $=await ge("POST","/api/v1/tools/masc_board_post",g);if(!(!Y.current||!re(c))){if(q(!1),!$.ok){E({kind:"err",message:`게시글 작성 실패: ${$.error.message}`});return}Pt(""),Mt(""),ve(le.current),Xe([]),Ge(!1),E(null),ot("게시글을 작성했습니다.","success"),Ie.invalidateTopic("board"),await Z("manual")}},Et=async t=>{if(t.preventDefault(),Q.peek().kind!=="single_user_local")return;const o=Se.current;if(rt(pe.current)){E({kind:"err",message:"첨부 파일 업로드가 완료된 뒤 등록하세요."});return}if(at(pe.current)){E({kind:"err",message:"업로드에 실패한 첨부 파일을 재시도하거나 제거한 뒤 등록하세요."});return}if(!v||o?.postId!==v.id)return;if(!Be.trim()){E({kind:"err",message:"댓글 본문을 입력하세요."});return}const c=Jt(pe.current),g=oe();q(!0),E(null);const $={post_id:v.id,author:"operator",content:Be.trim()};Ye&&($.parent_id=Ye),c.length>0&&($.attachment_ids=c.map(L=>L.attachment_id||L.id));const P=await ge("POST","/api/v1/tools/masc_board_comment",$);if(!(!Y.current||!re(g))&&(q(!1),!(o!==Se.current||G.current!==v.id))){if(!P.ok){E({kind:"err",message:`댓글 작성 실패: ${P.error.message}`});return}ut(""),Ze(null),ve(pe.current),mt([]),E(null),ot("댓글이 등록되었습니다.","success"),o.commentId=Bn(P.value,v.id),o.scroll=!0,await je(v.id)}},Lt=async(t,o)=>{if(Q.peek().kind!=="single_user_local")return;const c=oe();q(!0);const g=await ge("POST","/api/v1/tools/masc_board_vote",{post_id:t,direction:o,voter:"operator"});if(!(!Y.current||!re(c))){if(q(!1),!g.ok){E({kind:"err",message:`투표 실패: ${g.error.message}`});return}Ie.invalidateTopic("board"),await Z("manual"),!(!Y.current||!re(c))&&G.current===t&&await je(t)}},Dt=async(t,o)=>{if(Q.peek().kind!=="single_user_local")return;const c=oe(),g=G.current;q(!0);const $=await ge("POST","/api/v1/tools/masc_board_comment_vote",{comment_id:t,direction:o,voter:"operator"});if(!(!Y.current||!re(c))){if(q(!1),!$.ok){E({kind:"err",message:`댓글 투표 실패: ${$.error.message}`});return}g&&G.current===g&&await je(g)}},Bt=async(t,o,c)=>{if(!Vt(Q.peek()))return;const g=oe(),$=G.current;q(!0);const P=await ge("POST","/api/v1/board/reactions",{target_type:t,target_id:o,emoji:c});if(!(!Y.current||!re(g))){if(q(!1),!P.ok){E({kind:"err",message:`반응 변경 실패: ${P.error.message}`});return}$&&G.current===$&&await je($)}},pn=async t=>{const o=Q.peek();if(o.kind!=="single_user_local"||ht("admin",o))return;const c=oe();q(!0);const g=await ge("POST","/api/v1/dashboard/board/pin",{post_id:t.id,pinned:!t.pinned});if(!(!Y.current||!re(c))){if(q(!1),!g.ok){E({kind:"err",message:`고정 변경 실패: ${g.error.message}`});return}E(null),ot(t.pinned?"고정이 해제되었습니다.":"게시글이 고정되었습니다.","success"),Ie.invalidateTopic("board"),await Z("manual"),!(!Y.current||!re(c))&&G.current===t.id&&await je(t.id)}},bn=async t=>{const o=Q.peek();if(o.kind!=="single_user_local"||ht("admin",o))return;const c=oe();q(!0);const g=await ge("POST","/api/v1/dashboard/board/delete",{post_id:t});if(!(!Y.current||!re(c))){if(q(!1),!g.ok){E({kind:"err",message:`게시글 삭제 실패: ${g.error.message}`});return}E(null),ot(`게시글 ${t} 삭제 완료`,"success"),Oe($=>$===t?null:$),Ie.invalidateTopic("board"),await Z("manual")}},Kt=6,be=ae(()=>{const t=[...s.hearths].sort((c,g)=>g.count-c.count||c.name.localeCompare(g.name)).map(c=>({key:`h:${c.name}`,value:c.name,label:`#${c.name}`,count:c.count,title:c.name})),o=s.subBoards.map(c=>({key:`sb:${c.id}`,value:c.slug,label:`/${c.slug}`,count:c.postCount,title:c.description||c.name}));return[...t,...o]},[s.hearths,s.subBoards]),Nt=ae(()=>{const t=be.slice(0,Kt);if(A&&!t.some(o=>o.value===A)){const o=be.find(c=>c.value===A);if(o)return[...t,o]}return t},[be,A]),pt=Math.max(0,be.length-Kt),Wt=Math.floor(Date.now()/15e3)*15e3,jt=Fe(t=>t.head.id,[]),Ft=Fe(t=>{const o=t.head;return i`
      <button
        type="button"
        class="kn-row-btn kn-board-row"
        data-selected=${B===o.id?"true":"false"}
        onClick=${()=>Oe(o.id)}
      >
        <div class="kn-row-top">
          <span class="kn-row-title">
            ${o.pinned?"📌 ":""}${o.title}
          </span>
          ${o.hearth&&i`<span class="kn-badge">#${o.hearth}</span>`}
        </div>
        <div class="kn-row-meta">
          <${vt} id=${o.author} size="sm" />
          <span class="tnum">▲ ${o.votes}</span>
          <span class="tnum">💬 ${o.commentCount}</span>
          ${o.attachments.length>0&&i`<span class="tnum" aria-label=${`첨부 ${o.attachments.length}개`}>📎 ${o.attachments.length}</span>`}
          <span>${ct(o.updatedAt||o.createdAt,Wt)}</span>
          ${yt(o.audience,!0)}
          ${t.predecessors.length>0&&i`
            <span class="kn-badge kn-badge--info">계승 체인 +${t.predecessors.length}</span>
          `}
        </div>
      </button>
    `},[B,Wt]),hn=ae(()=>i`
    <div class="kn-pane-col">
      <div class="kn-pane-head">
        <h2 class="kn-pane-title">Board <span class="kn-chip-count">(${We.length})</span></h2>
        <div class="kn-actions">
          ${!a&&i`
            <button type="button" class="btn-primary" onClick=${fn}>
              ${Je?"닫기":"+ 새 글"}
            </button>
          `}
          <${Mn} onRefresh=${()=>Z("manual")} />
        </div>
      </div>

      <div class="kn-filter-bar">
        <div class="kn-toolbar">
          <div class="kn-chips" role="group" aria-label="피드 신호 필터">
            <button
              type="button"
              class="kn-chip"
              aria-pressed=${y}
              onClick=${()=>O(!0)}
            >
              Signal Only
            </button>
            <button
              type="button"
              class="kn-chip"
              aria-pressed=${!y}
              onClick=${()=>O(!1)}
            >
              All Posts
            </button>
          </div>
          <select
            class="kn-select"
            value=${d}
            onChange=${t=>D(t.target.value)}
            aria-label="정렬 기준"
          >
            <option value="recent">최신순</option>
            <option value="hot">인기순</option>
            <option value="trending">트렌딩</option>
            <option value="discussed">댓글순</option>
          </select>
        </div>

        <input
          type="search"
          class="kn-input"
          placeholder="제목, 본문, 작성자 검색…"
          value=${He}
          onInput=${t=>rn(t.target.value)}
          aria-label="게시판 검색"
        />

        ${be.length>0&&i`
          <div class="kn-hearth-bar">
            <div class="kn-hearth-strip" role="group" aria-label="Hearth 및 Sub-board 필터">
              <button
                type="button"
                class="kn-chip"
                aria-pressed=${A===""}
                onClick=${()=>ke("")}
              >
                전체 Hearth
              </button>
              ${Nt.map(t=>i`
                <button
                  key=${t.key}
                  type="button"
                  class="kn-chip"
                  aria-pressed=${A===t.value}
                  onClick=${()=>ke(t.value)}
                  title=${t.title}
                >
                  ${t.label} <span class="kn-chip-count">${t.count}</span>
                </button>
              `)}
            </div>
            ${pt>0&&i`
              <select
                class="kn-select kn-hearth-select"
                aria-label="전체 Hearth 선택"
                value=${A}
                onChange=${t=>ke(t.target.value)}
              >
                <option value="">더보기 (+${pt})</option>
                ${be.map(t=>i`
                  <option key=${t.key} value=${t.value}>
                    ${t.label} (${t.count})
                  </option>
                `)}
              </select>
            `}
          </div>
        `}
      </div>

      ${Je&&!a&&i`
        <form class="kn-section kn-inset" onSubmit=${xt}>
          <h3 class="kn-section-title">새 게시글 작성</h3>
          <input
            type="text"
            class="kn-input"
            required
            placeholder="제목"
            value=${Le}
            onInput=${t=>Pt(t.target.value)}
          />
          <input
            type="text"
            class="kn-input"
            placeholder="Hearth / Sub-board (선택, 예: engineering)"
            value=${Qe}
            onInput=${t=>ln(t.target.value)}
          />
          <${qt}
            items=${Ae}
            onChange=${Xe}
            disabled=${W}
            triggerLabel="이미지 · 파일 첨부"
            onError=${t=>E({kind:"err",message:t})}
          >
            <textarea
              class="kn-textarea"
              required
              placeholder="Markdown 본문 (필수 · 이미지 붙여넣기/드롭 지원 · ⌘↵ 게시)"
              value=${De}
              onInput=${t=>Mt(t.target.value)}
              onKeyDown=${t=>{t.isComposing||t.keyCode===229||(t.metaKey||t.ctrlKey)&&t.key==="Enter"&&!W&&(t.preventDefault(),xt(t))}}
            />
          <//>
          <div class="kn-actions">
            <button
              type="submit"
              class="btn-primary"
              disabled=${W||!Le.trim()||!De.trim()||rt(Ae)||at(Ae)}
            >
              게시
            </button>
            <button
              type="button"
              class="btn-ghost"
              onClick=${()=>{ve(le.current),Xe([]),Ge(!1)}}
            >
              취소
            </button>
          </div>
        </form>
      `}

      ${V&&i`<div class="kn-notice kn-notice--err kn-inset" role="alert">${V}</div>`}

      ${(s.signalScanTruncated||s.hasMore||s.filteredOutCount>0)&&i`
        <div class="kn-notice kn-notice--info kn-inset" role="note">
          ${s.signalScanTruncated?"신호 스캔 상한에 도달하여 일부 오래된 글이 생략되었을 수 있습니다.":s.hasMore?"피드에 추가 게시글이 더 있습니다 (최대 200건 표시).":""}
          ${s.filteredOutCount>0?`${s.signalScanTruncated||s.hasMore?" · ":""}시스템/비신호 글 ${s.filteredOutCount}건 숨김`:""}
        </div>
      `}

      ${R&&s.posts.length===0?i`<div class="kn-detail-pad"><span class="dtable-absent">게시글 불러오는 중…</span></div>`:i`
            <${In}
              items=${We}
              estimateSize=${84}
              height="100%"
              ariaLabel="게시판 목록"
              getItemKey=${jt}
              empty=${i`<div class="kn-detail-pad"><span class="dtable-absent">표시할 게시글이 없습니다.</span></div>`}
              renderItem=${Ft}
            />
          `}
    </div>
  `,[We,a,Je,Z,y,d,He,be,A,Nt,pt,Le,Qe,De,Ae,W,V,s.signalScanTruncated,s.hasMore,s.filteredOutCount,s.posts.length,R,jt,Ft]),gn=v?i`
        <div class="kn-detail-pad">
          ${It&&i`<div class="kn-notice kn-notice--err" role="alert">${It.message}</div>`}
          ${dt&&i`<div class="kn-notice kn-notice--err" role="alert">${dt}</div>`}
          ${a&&i`
            <div class="kn-notice kn-notice--info" role="note">
              멀티-계정 대시보드 세션: <code>/api/v1/dashboard/board</code> 읽기 전용 피드를 표시합니다. 댓글·반응·편집은 단일-사용자 로컬 세션에서 지원됩니다.
            </div>
          `}
          <div class="kn-section-head">
            <div class="kn-min-w-0">
              <div class="kn-row-meta">
                <${vt} id=${v.author} size="sm" />
                ${v.hearth&&i`<span class="kn-badge">#${v.hearth}</span>`}
                ${yt(v.audience)}
                ${v.pinned&&i`<span class="kn-badge kn-badge--info">Pinned</span>`}
                <span>${ct(v.createdAt)}</span>
                ${v.updatedAt&&v.updatedAt!==v.createdAt&&i`
                  <span>· 수정 ${ct(v.updatedAt)}</span>
                `}
              </div>
              <h2 class="kn-heading">${v.title}</h2>
            </div>
            ${!a&&i`
              <div class="kn-actions">
                <button
                  type="button"
                  class="btn-ghost"
                  disabled=${W}
                  onClick=${()=>{Lt(v.id,"up")}}
                >
                  ▲ ${v.votes}
                </button>
                <button
                  type="button"
                  class="btn-ghost"
                  disabled=${W}
                  onClick=${()=>{Lt(v.id,"down")}}
                  aria-label="비추천"
                >
                  ▼
                </button>
                ${p&&i`
                  <button
                    type="button"
                    class="btn-ghost"
                    disabled=${W}
                    onClick=${()=>{pn(v)}}
                  >
                    ${v.pinned?"고정 해제":"고정"}
                  </button>
                  <button
                    type="button"
                    class="kn-btn-danger"
                    disabled=${W}
                    onClick=${()=>{bn(v.id)}}
                  >
                    삭제
                  </button>
                `}
              </div>
            `}
          </div>

          ${et&&et.predecessors.length>0&&i`
            <section class="kn-section" aria-label="접힌 계승 체인">
              <div class="kn-section-head">
                <span class="kn-section-title">Succession Chain (${et.predecessors.length}개 이전 글 접힘)</span>
                <button
                  type="button"
                  class="btn-ghost"
                  onClick=${()=>cn(t=>({...t,[v.id]:!t[v.id]}))}
                >
                  ${St[v.id]?"접기":"이전 체인 펼치기"}
                </button>
              </div>
              ${St[v.id]&&i`
                <div class="kn-stack-1">
                  ${et.predecessors.map(t=>i`
                    <div key=${t.id} class="kn-card-row">
                      <button type="button" class="kn-row-btn" onClick=${()=>Oe(t.id)}>
                        <span class="kn-row-top">
                          <span class="kn-row-title">${t.title}</span>
                          <span class="kn-badge kn-badge--idle">Superseded</span>
                        </span>
                        <span class="kn-row-meta mono">${t.id}</span>
                      </button>
                      ${t.closed?.summary&&i`<${gt} class="kn-body-sm" text=${t.closed.summary} />`}
                    </div>
                  `)}
                </div>
              `}
            </section>
          `}

          <article>
            <${gt} text=${v.body} document />
            ${v.attachments.length>0&&i`
              <${zt} attachments=${v.attachments} workspaceEpoch=${oe()} />
            `}
          </article>

          <${Xt}
            reactions=${v.reactions}
            supportedEmojis=${v.supportedReactionEmojis}
            disabled=${W||!k}
            onToggle=${t=>{Bt("post",v.id,t)}}
          />

          ${!a&&i`
            <section class="kn-section" aria-label="댓글 스레드">
              <h3 class="kn-section-title">
                Comments (${_?`${_.comments.length}${_.commentPage&&_.commentPage.total>_.comments.length?` / ${_.commentPage.total}`:""}`:v.commentCount})
              </h3>
              ${At&&!_&&i`<span class="dtable-absent">댓글 불러오는 중…</span>`}
              ${_&&_.comments.length===0&&i`<span class="dtable-absent">아직 댓글이 없습니다.</span>`}
              ${_&&ye>0&&i`
                <div class="kn-actions">
                  <button
                    type="button"
                    class="btn-ghost"
                    onClick=${()=>_e(t=>Math.max(0,t-ce))}
                  >
                    이전 댓글 보기 (${ye}건 접힘)
                  </button>
                </div>
              `}
              ${dn.map(t=>i`
                <div key=${t.id} ref=${t.id===Ne?.id?Ot:void 0} class=${`kn-comment ${t.parentId?"kn-comment--nested":""}`.trim()}>
                  <div class="kn-row-top">
                    <div class="kn-row-meta">
                      <${vt} id=${t.author} size="sm" />
                      ${yt(t.audience)}
                      <span>${ct(t.createdAt)}</span>
                    </div>
                    <div class="kn-actions">
                      <button type="button" class="btn-ghost kn-btn-compact" disabled=${W} onClick=${()=>{Dt(t.id,"up")}}>
                        ▲ ${t.votes}
                      </button>
                      <button type="button" class="btn-ghost kn-btn-compact" disabled=${W} onClick=${()=>{Dt(t.id,"down")}} aria-label="댓글 비추천">
                        ▼
                      </button>
                      <button
                        type="button"
                        class="btn-ghost kn-btn-compact"
                        onClick=${()=>{Ze(t.id),queueMicrotask(()=>{ft.current?.focus(),ft.current?.scrollIntoView?.({block:"nearest",behavior:"smooth"})})}}
                      >
                        답글
                      </button>
                    </div>
                  </div>
                  <${gt} class="kn-body-md" text=${t.content} document />
                  ${t.attachments.length>0&&i`
                    <${zt} attachments=${t.attachments} workspaceEpoch=${oe()} compact=${!0} />
                  `}
                  <${Xt}
                    reactions=${t.reactions}
                    supportedEmojis=${v.supportedReactionEmojis}
                    disabled=${W||!k}
                    onToggle=${o=>{Bt("comment",t.id,o)}}
                  />
                </div>
              `)}
              ${_&&ye+ce<_.comments.length&&i`
                <div class="kn-actions">
                  <button
                    type="button"
                    class="btn-ghost"
                    onClick=${()=>_e(t=>Math.min(_.comments.length-ce,t+ce))}
                  >
                    다음 로드된 댓글 보기
                  </button>
                </div>
              `}
              ${_&&_.commentPage&&_.commentPage.nextOffset!==null&&i`
                <div class="kn-actions">
                  <button
                    type="button"
                    class="btn-ghost"
                    disabled=${qe||an}
                    onClick=${()=>{un()}}
                  >
                    ${qe?"댓글 불러오는 중…":`댓글 더 불러오기 (${_.comments.length} / ${_.commentPage.total})`}
                  </button>
                </div>
              `}

              <div ref=${Tt} />

              <form class="kn-reply-form" onSubmit=${Et}>
                ${Ye&&i`
                  <div class="kn-notice kn-notice--info">
                    댓글 <span class="mono">${Ye}</span>에 답글 작성 중
                    <button type="button" class="btn-ghost kn-btn-ml" onClick=${()=>Ze(null)}>
                      취소
                    </button>
                  </div>
                `}
                <${qt}
                  items=${Ke}
                  onChange=${mt}
                  disabled=${W}
                  triggerLabel="댓글 파일 첨부"
                  onError=${t=>E({kind:"err",message:t})}
                >
                  <textarea
                    ref=${ft}
                    class="kn-textarea kn-textarea--reply"
                    required
                    placeholder="댓글 내용을 입력하세요 (필수 · Markdown · 이미지 붙여넣기/드롭 · ⌘↵ 등록)…"
                    value=${Be}
                    onInput=${t=>ut(t.target.value)}
                    onKeyDown=${t=>{t.isComposing||t.keyCode===229||(t.metaKey||t.ctrlKey)&&t.key==="Enter"&&!W&&Be.trim()&&(t.preventDefault(),Et(t))}}
                  />
                <//>
                <div class="kn-actions">
                  <button
                    type="submit"
                    class="btn-primary"
                    disabled=${W||!Be.trim()||rt(Ke)||at(Ke)}
                  >
                    댓글 등록
                  </button>
                </div>
              </form>
            </section>
          `}
        </div>
      `:i`
        <div class="kn-detail-pad">
          ${At||R?i`<span class="dtable-absent">게시글 불러오는 중…</span>`:i`<div class="kn-notice kn-notice--err" role="alert">${dt??`게시글 ${B}을 확인할 수 없습니다.`}</div>`}
        </div>
      `;return i`
    <${Pn}
      master=${hn}
      detail=${gn}
      hasSelection=${B!==null}
      selectionKey=${B}
      linkedKey=${e.entityId??null}
      masterLabel="게시글 목록"
      detailLabel="게시글 상세"
      emptyDetail=${i`<div class="kn-detail-pad"><span class="dtable-absent">게시글을 선택하세요.</span></div>`}
    />
  `}const nn=Ct(async()=>(await _t(async()=>{const{WikiTab:e}=await import("./wiki-tab.js");return{WikiTab:e}},__vite__mapDeps([0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18]))).WikiTab),sn=Ct(async()=>(await _t(async()=>{const{ArtifactsTab:e}=await import("./artifacts-tab.js");return{ArtifactsTab:e}},__vite__mapDeps([19,1,15,16,2,3,4,5,6,7,8,9,10,11,13,14,17,18]))).ArtifactsTab),on=Ct(async()=>(await _t(async()=>{const{MemoryTab:e}=await import("./memory-tab.js");return{MemoryTab:e}},__vite__mapDeps([20,1,2,3,4,21,5,6,22,10,11,9,8,23,13,14,15,16,7,17,18]))).MemoryTab);function jn(e){switch(Zt(e)){case"wiki":return nn.preload();case"artifacts":return sn.preload();case"memory":return on.preload();default:return Promise.resolve()}}An("knowledge",e=>{jn(e).catch(()=>{})});function fs(e){const n=Zt(e.subroute);return i`
    <section class="kn-root" aria-label="Knowledge workspace">
      <div class="kn-body">
        ${n==="board"&&i`<${Wn} ...${e} />`}
        ${n!=="board"&&i`
          <${Sn} fallback=${null}>
            ${n==="wiki"&&i`<${nn.Component} ...${e} />`}
            ${n==="artifacts"&&i`<${sn.Component} ...${e} />`}
            ${n==="memory"&&i`<${on.Component} ...${e} />`}
          <//>
        `}
      </div>
    </section>
  `}export{Wn as BoardTab,xn as DEFAULT_REACTION_EMOJIS,fs as KnowledgeWorkspace,rs as WIKI_LINK_KINDS,os as WIKI_SOURCES,te as asFiniteNumber,b as asNonEmptyString,l as asSafeInt,w as asString,Te as asStringArray,us as buildMemoryFlowSeries,ms as buildMemoryRecoveryPayload,ls as buildWorldMemoryDiffUrl,en as decodeBoardAudience,lt as decodeBoardComment,kt as decodeBoardPost,as as decodePublishedArtifactItem,cs as decodeWorkspaceInventoryFallback,ds as decodeWorldDiff,is as decodeWorldMemory,Gt as foldSuccessionChains,ss as formatBytes,ct as formatRelativeTime,f as isRecord,En as isSignalBoardPost,Zt as normalizeKnowledgeSubroute,Ln as partitionReactions,jn as preloadKnowledgeSubroute};
