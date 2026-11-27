import{d as _,g as aa,A as Me,y as ve,m as a,T as ce,a as sa}from"./vendor.js";import{a as be,s as tt,R as Wt,c as mn,z as N,C as At,M as Kt,L as Ot,Y as xe,A as $e,B as Z,K as Lt,aK as ra,D as Et,Q as Pe,o as qe,_ as vn,O as ot,F as rt,P as ia,an as En,$ as gn,aL as zn,aM as Dn,X as Ze,ao as jt,aq as Vt,ap as et,W as $n,l as oa,V as Nt,U as Qt,J as Mn,N as an}from"./index.js";import{V as Pn}from"./virtual-list.js";import{M as la}from"./master-detail.js";import"./command-search.js";import{R as wt}from"./refresh-button.js";import{M as ln}from"./markdown-renderer.js";import{e as Ct,a as ft,d as da}from"./wire-decode.js";import{U as It}from"./uplot-chart.js";import{D as Ut}from"./data-table.js";import{K as Xt}from"./core.js";import{c as ca,e as ua,f as bn,s as pa,a as va,b as fa,d as ma}from"./keeper-oauth-flow.js";import{c as ga}from"./copyable-code.js";import{i as $a}from"./quota-window.js";import{r as ba,a as ha,c as ya,b as ka,S as xa,d as Wn,p as _a,l as Fn,e as Nn,f as wa,g as Sa,h as Ca,i as Ia,m as Ra,j as dn,q as Ta,w as Aa,k as Oa,n as Un,s as Kn,t as Ft,o as Rt,u as Pt,v as hn,x as Zt,y as Bn,z as yn,A as cn,B as La,C as Ea,D as qn,E as kn,F as sn,G as za,H as Da,I as Ma,J as Pa,K as Wa,L as Fa}from"./setup-inventory-read.js";import{R as Rr}from"./setup-inventory-read.js";import{e as jn,c as Na}from"./format-time.js";import{i as nn}from"./type-guards.js";import{I as Jt}from"./inline-spinner.js";import{c as Ua}from"./markdown.js";import"./table.js";import"./useSelector.js";import"./sse-reader.js";import"./toast.js";import"./format-string.js";function Ka(e){const t="GET /api/v1/lane-addons",n=Ct(e,t);return{...n,instances:ft(n,"instances",t),rows:ft(n,"rows",t),coverage:ft(n,"coverage",t)}}function Ba(e){const t="GET /api/v1/lane-addons/asks",n=Ct(e,t),l=da(n,"asks",t).map((d,c)=>{const v=Ct(d,`${t} asks[${c}]`),h=ft(v,"questions",`${t} asks[${c}]`);return{...v,questions:h}});return{...n,asks:l}}function qa(e){const t="GET /api/v1/lane-addons/package-catalog",n=Ct(e,t);return{...n,entries:ft(n,"entries",t)}}function ja(e){const t="GET /api/v1/dashboard/browser-lane/clients",n=Ct(e,t);return{...n,clients:ft(n,"clients",t),inventoryIssues:ft(n,"inventoryIssues",t)}}function Va(e){const t="POST /api/v1/dashboard/browser-lane/read",n=Ct(e,t);if(n.ok===!1||n.status==="deferred"){const r=typeof n.error=="string"&&n.error.trim().length>0?n.error.trim():typeof n.message=="string"&&n.message.trim().length>0?n.message.trim():typeof n.status=="string"&&n.status.trim().length>0?`요청 보류됨 (${n.status.trim()})`:"브라우저 탭 읽기가 완료되지 않았습니다.";throw new Error(r)}if("data"in n&&n.data!==void 0){const r=Ct(n.data,`${t} data`);return ft(r,"tabs",t)}return ft(n,"tabs",t)}function Ha(e){const t=be.value,n=tt.value,r=Wt(t),l=r&&mn(t),d=N.observe("runtime:lane-addons").value,c=N.observe("runtime:lane-addons-asks").value,[v,h]=_(null),[m,k]=_(null),[q,z]=_(null),[T,ue]=_("default"),[W,oe]=_("{}"),fe=aa(),[U,ae]=_({}),[Ae,O]=_(null),[te,Ee]=_({kind:"loading"}),[je,ze]=_({}),[Ke,pe]=_(null),G=Me(!0),Ie=Me(null),J=Me(null),K=Me(null),_e=()=>Wt(be.peek()),L=()=>{const g=be.peek();return Wt(g)&&mn(g)},F=(g="mount")=>{if(!_e())return Promise.resolve();const C=xe();return Promise.all([N.fetch("runtime:lane-addons",x=>$e("/api/v1/lane-addons",{signal:x,decode:Ka}),{ttlMs:15e3,topics:["lane_addon","lane_addon_exports_changed"],reason:g}),N.fetch("runtime:lane-addons-asks",x=>$e("/api/v1/lane-addons/asks",{signal:x,decode:Ba}),{ttlMs:15e3,topics:["lane_addon","lane_addon_asks_changed"],reason:g})]).then(()=>{G.current&&Z(C)&&Lt()})},ge=async()=>{if(!_e())return;Ie.current?.abort();const g=new AbortController;Ie.current=g;const C=xe();Ee({kind:"loading"});const x=await ra({method:"GET",path:"/api/v1/dashboard/browser-lane/clients",envelope:"ok_data",decode:ja,signal:g.signal});if(!(!G.current||!Z(C)||g.signal.aborted)){if(!x.ok){if(x.error.kind==="aborted"||x.error.kind==="epoch_stale")return;x.error.status===503?Ee({kind:"unattached_503",reason:x.error.message||"브라우저 레인 애드온이 아직 연결되지 않았습니다."}):Ee({kind:"failed",message:x.error.message});return}Ee({kind:"ready",data:x.value})}},j=async g=>{if(!_e())return;J.current?.abort();const C=new AbortController;J.current=C;const x=xe(),u=g?`?directory=${encodeURIComponent(g)}`:"",R=await $e(`/api/v1/lane-addons/package-catalog${u}`,{signal:C.signal,decode:qa});!G.current||!Z(x)||C.signal.aborted||(R.ok?k(R.value):R.error.kind!=="aborted"&&R.error.kind!=="epoch_stale"&&O({kind:"err",text:`패키지 카탈로그 조회 실패: ${R.error.message}`}))};ve(()=>{if(G.current=!0,h(null),k(null),z(null),ze({}),ae({}),O(null),pe(null),Ee({kind:"loading"}),!r)return Ie.current?.abort(),J.current?.abort(),K.current?.abort(),()=>{G.current=!1};F("mount"),ge();const g=new Set(["lane_addon","lane_addon_asks","lane_addon_asks_changed","lane_addon_exports_changed","dataset_invalidation"]);let C=null;const x=()=>{C!==null&&clearTimeout(C),C=setTimeout(()=>{C=null,!(!G.current||!Z(n))&&(F("sse"),ge())},350)},u=At(Q=>{Et(Q).some(V=>g.has(V))&&x()}),R=()=>{!G.current||!Z(n)||(N.invalidateTopic("lane_addon"),F("sse"),ge())},I=Kt(R),w=Ot(R);return()=>{G.current=!1,C!==null&&clearTimeout(C),u(),I(),w(),Ie.current?.abort(),J.current?.abort(),K.current?.abort()}},[n,r]);const Oe=d.kind==="value"&&Array.isArray(d.data?.instances)?d.data.instances:[],E=Oe.find(g=>g.instance_id===v)??Oe[0]??null,re=async g=>{if(!_e())return;K.current?.abort();const C=new AbortController;K.current=C;const x=xe(),u=await $e(`/api/v1/lane-addons/package-preview?manifest_path=${encodeURIComponent(g)}`,{signal:C.signal});!G.current||!Z(x)||C.signal.aborted||(u.ok?z(u.value):u.error.kind!=="aborted"&&u.error.kind!=="epoch_stale"&&O({kind:"err",text:`미리보기 실패: ${u.error.message}`}))},ye=async g=>{if(!_e())return;const C=xe(),x=await Pe("POST","/api/v1/lane-addons/attach",{manifest_path:g,run_id:T.trim()||"default",binding:{}});if(!(!G.current||!Z(C))){if(!x.ok){O({kind:"err",text:`애드온 Attach 실패: ${x.error.message}`});return}O(null),qe(`애드온 연결됨 (${g}).`,"success"),z(null),F("manual"),ge()}},Y=async g=>{if(!_e())return;const C=xe(),x=await Pe("POST","/api/v1/lane-addons/detach",{instance_id:g});if(!(!G.current||!Z(C))){if(!x.ok){O({kind:"err",text:`Detach 실패: ${x.error.message}`});return}O(null),qe(`${g} 연결 해제 요청 완료.`,"success"),F("manual")}},Re=async g=>{if(!_e())return;const C=xe(),x=await Pe("POST","/api/v1/lane-addons/observe",{instance_id:g});if(!(!G.current||!Z(C))){if(!x.ok){O({kind:"err",text:`관측 트리거 실패: ${x.error.message}`});return}F("manual")}},ie=async g=>{if(!_e())return;let C;try{const I=JSON.parse(W);if(!I||typeof I!="object"||Array.isArray(I))throw new Error("JSON 객체가 필요합니다.");C=I}catch(I){O({kind:"err",text:`액션 JSON 오류: ${I instanceof Error?I.message:String(I)}`});return}const x=xe(),u=`req-${Date.now()}`,R=await Pe("POST","/api/v1/lane-addons/actions",{instance_id:g.instance_id,expected_incarnation:g.incarnation,request_id:u,action:C});if(!(!G.current||!Z(x))){if(!R.ok){O({kind:"err",text:`액션 호출 실패: ${R.error.message}`});return}O(null),qe(`액션 요청 접수됨 (${u}).`,"success"),e.onInspect({title:`Addon Action Receipt · ${g.title}`,subtitle:u,kind:"addon_action_receipt",data:R.value,render:()=>a`
        <pre class="mono" style=${{margin:0,fontSize:"var(--fs-11)",overflowX:"auto",whiteSpace:"pre-wrap"}}>
          ${JSON.stringify(R.value,null,2)}
        </pre>
      `})}},he=async g=>{if(!L())return;const C=(g.questions??[]).map((R,I)=>{const w=R.id??R.question_id??`q-${I}`,Q=`${g.ask_id}:${w}`,V=(U[Q]??"").trim();return{question_id:w,response:V.length>0?{kind:"wrote",text:V}:{kind:"skipped"}}});if(C.length===0){O({kind:"err",text:"응답할 질문 항목이 없습니다."});return}const x=xe(),u=await Pe("POST","/api/v1/lane-addons/ask-answer",{declaration_id:g.declaration_id,ask_id:g.ask_id,answers:C});if(!(!G.current||!Z(x))){if(!u.ok){O({kind:"err",text:`애드온 질문 응답 실패: ${u.error.message}`});return}O(null),qe(`애드온 질문 ${g.ask_id} 응답이 기록되었습니다.`,"success"),F("manual")}},Ge=async g=>{if(!_e())return;const C=xe();pe(g.clientId);const x=await Pe("POST","/api/v1/dashboard/browser-lane/read",{lane:"live",clientId:g.clientId},{decode:Va});if(!G.current||!Z(C))return;if(pe(R=>R===g.clientId?null:R),!x.ok){O({kind:"err",text:`탭 읽기 실패 (${g.clientId}): ${x.error.message}`});return}const u=x.value;ze(R=>({...R,[g.clientId]:u})),e.onInspect({title:`Browser Tabs · ${g.clientId}`,subtitle:`${u.length}개 열린 탭`,kind:"browser_tabs",data:u,render:()=>a`
        <div style=${{display:"flex",flexDirection:"column",gap:"var(--sp-2)"}}>
          ${u.length===0?a`<div class="dtable-absent">열린 탭 없음</div>`:u.map(R=>a`
                <div key=${R.id} class="wka-card" style=${{fontSize:"var(--fs-12)"}}>
                  <div style=${{fontWeight:600}}>${R.active?"● ":""}${R.title||"(제목 없음)"}</div>
                  <div class="mono" style=${{fontSize:"var(--fs-11)",color:"var(--info-fg)",wordBreak:"break-all"}}>${R.url}</div>
                </div>
              `)}
        </div>
      `})},Ce=a`
    <div style=${{padding:"var(--sp-3)",display:"flex",flexDirection:"column",gap:"var(--sp-3)",minWidth:0}}>
      <div class="wka-h">
        <h3>Lane-Addons 인스턴스 (${Oe.length})</h3>
        <div style=${{display:"flex",gap:"var(--sp-1)"}}>
          <button type="button" class="btn-ghost" onClick=${()=>{j()}}>패키지 탐색</button>
          <${wt} onRefresh=${()=>F("manual")} />
        </div>
      </div>

      ${d.kind==="failed"?a`<div class="ap-error" role="alert">Lane-Addons 조회 실패: ${d.error.message}</div>`:Oe.length===0?a`<div class="dtable-absent">${d.kind==="loading"?"불러오는 중…":"연결된 Lane-Addon 인스턴스가 없습니다."}</div>`:a`
            <${Pn}
              items=${Oe}
              estimateSize=${64}
              height=${Math.min(260,Math.max(120,Oe.length*68))}
              ariaLabel="Lane-Addon 인스턴스 목록"
              renderItem=${g=>{const C=E?.instance_id===g.instance_id;return a`
                  <button
                    type="button"
                    onClick=${()=>h(g.instance_id)}
                    style=${{width:"100%",marginBottom:"var(--sp-2)",textAlign:"left",padding:"var(--sp-2)",background:C?"var(--bg-4)":"var(--bg-2)",border:"1px solid var(--line-1)",borderRadius:"var(--radius-sm)",cursor:"pointer",display:"flex",justifyContent:"space-between",alignItems:"center",gap:"var(--sp-2)"}}
                  >
                    <div style=${{minWidth:0}}>
                      <div style=${{fontWeight:600,fontSize:"var(--fs-13)"}}>${g.title}</div>
                      <div class="mono" style=${{fontSize:"var(--fs-11)",color:"var(--fg-3)"}}>
                        ${g.instance_id} · seq ${g.observation_seq} · ${g.rows_count}행
                      </div>
                    </div>
                    <span class="mono" style=${{fontSize:"var(--fs-11)",color:g.runtime_presence==="live"?"var(--ok-fg)":"var(--fg-3)"}}>
                      ${g.runtime_presence??"retained"} / ${g.phase?.kind??"unknown"}
                    </span>
                  </button>
                `}}
            />
          `}

      ${E&&a`
        <div class="wka-card" style=${{display:"flex",flexDirection:"column",gap:"var(--sp-2)",background:"var(--bg-2)"}}>
          <div class="wka-h">
            <h3>${E.title} 제어</h3>
            <div style=${{display:"flex",gap:"var(--sp-1)"}}>
              <button type="button" class="btn-ghost" onClick=${()=>{Re(E.instance_id)}}>관측</button>
              <button type="button" class="btn-ghost" style=${{color:"var(--err-fg)"}} onClick=${()=>{Y(E.instance_id)}}>Detach</button>
            </div>
          </div>
          <label style=${{display:"flex",flexDirection:"column",gap:"var(--sp-1)",fontSize:"var(--fs-12)"}}>
            <span>액션 호출 (JSON)</span>
            <textarea
              rows=${3}
              class="mono"
              value=${W}
              onInput=${g=>oe(g.target.value)}
              style=${{padding:"var(--sp-2)",fontSize:"var(--fs-11)",background:"var(--bg-0)",border:"1px solid var(--line-1)",borderRadius:"var(--radius-sm)"}}
            />
          </label>
          <button type="button" class="btn-primary" style=${{alignSelf:"flex-start"}} onClick=${()=>{ie(E)}}>
            액션 실행
          </button>

          ${(E.host_requests?.waiting?.length??0)>0&&a`
            <div style=${{borderTop:"1px solid var(--line-1)",paddingTop:"var(--sp-2)"}}>
              <div style=${{fontSize:"var(--fs-12)",fontWeight:600,color:"var(--warn-fg)",marginBottom:"var(--sp-1)"}}>
                대기 중인 호스트 요청 (${E.host_requests.waiting.length})
              </div>
              ${E.host_requests.waiting.map(g=>a`
                <div key=${g.request_id} class="mono" style=${{fontSize:"var(--fs-11)",color:"var(--fg-2)"}}>
                  ${g.request_id} · ${String(g.reason?.reason??"waiting")}
                </div>
              `)}
            </div>
          `}
        </div>
      `}

      ${c.kind==="failed"&&a`
        <div class="ap-error" role="alert">Lane-Addon 질문 조회 실패: ${c.error.message}</div>
      `}

      ${c.kind==="value"&&(c.data.asks?.length??0)>0&&a`
        <div class="wka-card" data-testid="lane-addon-asks-panel" style=${{display:"flex",flexDirection:"column",gap:"var(--sp-2)",borderColor:"var(--warn-border)"}}>
          <div class="wka-h">
            <h3>열린 Lane-Addon 질문 (${c.data.asks.length})</h3>
          </div>
          ${c.data.asks.map((g,C)=>a`
            <div key=${g.ask_id} style=${{display:"flex",flexDirection:"column",gap:"var(--sp-2)",padding:"var(--sp-2)",background:"var(--bg-2)",borderRadius:"var(--radius-sm)"}}>
              <div style=${{fontWeight:600,fontSize:"var(--fs-12)"}}>${g.title}</div>
              <div class="mono" style=${{fontSize:"var(--fs-11)",color:"var(--fg-3)"}}>
                declaration=${g.declaration_id} · ask=${g.ask_id}
              </div>
              ${(g.questions??[]).map((x,u)=>{const R=x.id??x.question_id??`q-${u}`,I=`${g.ask_id}:${R}`,w=`${fe}-${C}-${u}`;return a`
                  <div key=${I} style=${{display:"flex",flexDirection:"column",gap:"var(--sp-1)",fontSize:"var(--fs-12)"}}>
                    <div id=${w}>
                      <${ln} text=${x.prompt??x.text??x.label??R} />
                    </div>
                    ${l&&a`
                      <input
                        type="text"
                        aria-labelledby=${w}
                        placeholder="응답 입력 (비우면 skipped)"
                        value=${U[I]??""}
                        onInput=${Q=>ae(V=>({...V,[I]:Q.target.value}))}
                        style=${{padding:"var(--sp-1) var(--sp-2)",background:"var(--input-bg)",border:"1px solid var(--input-border)",borderRadius:"var(--radius-sm)"}}
                      />
                    `}
                  </div>
                `})}
              ${l?a`
                    <button
                      type="button"
                      class="btn-primary"
                      style=${{alignSelf:"flex-start"}}
                      onClick=${()=>{he(g)}}
                    >
                      질문 응답 제출
                    </button>
                  `:a`
                    <div class="dtable-absent" data-testid="addon-ask-admin-locked" role="status">
                      애드온 질문 응답 제출은 관리자 전용입니다.
                    </div>
                  `}
            </div>
          `)}
        </div>
      `}

      ${m&&a`
        <div class="wka-card" style=${{display:"flex",flexDirection:"column",gap:"var(--sp-2)"}}>
          <div class="wka-h">
            <h3>패키지 카탈로그 (${m.directory})</h3>
            ${m.parent&&a`
              <button type="button" class="btn-ghost" onClick=${()=>{j(m.parent)}}>↑ 상위</button>
            `}
          </div>
          <div style=${{display:"flex",flexDirection:"column",gap:"var(--sp-1)"}}>
            ${(m.entries??[]).map((g,C)=>g.kind==="folder"?a`
                  <button key=${`f-${C}`} type="button" class="btn-ghost" style=${{justifyContent:"flex-start"}} onClick=${()=>{j(g.path)}}>
                    📁 ${g.path}
                  </button>
                `:g.kind==="issue"?a`<div key=${`i-${C}`} style=${{fontSize:"var(--fs-11)",color:"var(--err-fg)"}}>⚠ ${g.path}: ${g.message}</div>`:a`
                <div key=${g.manifest_path} style=${{display:"flex",justifyContent:"space-between",alignItems:"center",gap:"var(--sp-2)",padding:"var(--sp-1) var(--sp-2)",background:"var(--bg-2)",borderRadius:"var(--radius-sm)"}}>
                  <span style=${{fontSize:"var(--fs-12)"}}>${g.title}</span>
                  <button type="button" class="btn-ghost" style=${{padding:"var(--sp-0) var(--sp-1)",fontSize:"var(--fs-11)"}} onClick=${()=>{re(g.manifest_path)}}>
                    미리보기
                  </button>
                </div>
              `)}
          </div>
          ${q&&a`
            <div style=${{borderTop:"1px solid var(--line-1)",paddingTop:"var(--sp-2)",display:"flex",flexDirection:"column",gap:"var(--sp-2)"}}>
              <div style=${{fontSize:"var(--fs-12)",fontWeight:600}}>${q.package.title} (${q.execution.kind})</div>
              <div style=${{display:"flex",gap:"var(--sp-2)"}}>
                <input
                  type="text"
                  value=${T}
                  onInput=${g=>ue(g.target.value)}
                  placeholder="run_id"
                  style=${{flex:1,minWidth:0,padding:"var(--sp-1) var(--sp-2)",background:"var(--input-bg)",border:"1px solid var(--input-border)",borderRadius:"var(--radius-sm)"}}
                />
                <button type="button" class="btn-primary" onClick=${()=>{ye(q.manifest_path)}}>Attach</button>
              </div>
            </div>
          `}
        </div>
      `}
    </div>
  `,me=a`
    <div style=${{padding:"var(--sp-3)",display:"flex",flexDirection:"column",gap:"var(--sp-3)",minWidth:0}}>
      <div class="wka-h">
        <h3>Browser Lane 클라이언트 & 온디맨드 탭</h3>
        <${wt} onRefresh=${()=>ge()} />
      </div>

      ${te.kind==="loading"&&a`<div class="dtable-absent">Browser Lane 상태 확인 중…</div>`}

      ${te.kind==="unattached_503"&&a`
        <div
          class="wka-card"
          data-testid="browser-lane-503"
          role="status"
          style=${{borderColor:"var(--warn-border)",background:"var(--warn-soft)",display:"flex",flexDirection:"column",gap:"var(--sp-2)"}}
        >
          <div style=${{fontWeight:600,color:"var(--warn-fg)"}}>
            ⚠ Browser Lane 미연결 (HTTP 503)
          </div>
          <div style=${{fontSize:"var(--fs-12)",color:"var(--fg-2)"}}>
            ${te.reason}
          </div>
          <div style=${{display:"flex",gap:"var(--sp-2)"}}>
            <button type="button" class="btn-ghost" onClick=${()=>{j()}}>왼쪽 카탈로그에서 애드온 Attach</button>
            <${wt} label="다시 확인" onRefresh=${()=>ge()} />
          </div>
        </div>
      `}

      ${te.kind==="failed"&&a`
        <div class="ap-error" role="alert">Browser Lane 조회 실패: ${te.message}</div>
      `}

      ${te.kind==="ready"&&(()=>{const g=te.data.clients,C=te.data.inventoryIssues;return a`
        <div style=${{display:"flex",flexDirection:"column",gap:"var(--sp-2)"}}>
          <div class="mono tnum" style=${{fontSize:"var(--fs-11)",color:"var(--fg-3)"}}>
            클라이언트 ${g.length}개 · 인벤토리 ${te.data.inventoryComplete?"완전":"불완전"}
          </div>

          ${C.length>0&&a`
            <div class="ap-error sev-warn" role="alert">
              ${C.map((x,u)=>a`
                <div key=${u} class="mono" style=${{fontSize:"var(--fs-11)"}}>
                  [${x.kind}] ${x.message??x.instanceId??""}
                </div>
              `)}
            </div>
          `}

          ${g.length===0?a`<div class="dtable-absent">연결된 브라우저 클라이언트가 없습니다.</div>`:g.map(x=>{const u=je[x.clientId];return a`
                  <article key=${x.clientId} class="wka-card" style=${{display:"flex",flexDirection:"column",gap:"var(--sp-2)",background:"var(--bg-2)"}}>
                    <div style=${{display:"flex",justifyContent:"space-between",alignItems:"center",gap:"var(--sp-2)",flexWrap:"wrap"}}>
                      <div>
                        <div style=${{fontWeight:600,fontSize:"var(--fs-13)"}}>${x.browser} (${x.version})</div>
                        <div class="mono" style=${{fontSize:"var(--fs-11)",color:"var(--fg-3)"}}>
                          ${x.clientId} · ${x.transport} ${x.space?`· space:${x.space.name}`:""}
                        </div>
                      </div>
                      <button
                        type="button"
                        class="btn-primary"
                        style=${{minWidth:"116px"}}
                        disabled=${Ke===x.clientId}
                        onClick=${()=>{Ge(x)}}
                      >
                        ${Ke===x.clientId?"읽는 중…":"Open Tabs 읽기"}
                      </button>
                    </div>
                    ${u&&a`
                      <div style=${{display:"flex",flexDirection:"column",gap:"var(--sp-1)",borderTop:"1px solid var(--line-1)",paddingTop:"var(--sp-1)"}}>
                        ${u.length===0?a`<span class="dtable-absent" style=${{fontSize:"var(--fs-11)"}}>열린 탭 없음</span>`:u.slice(0,8).map(R=>a`
                              <div key=${R.id} style=${{fontSize:"var(--fs-11)",display:"flex",gap:"var(--sp-1)",minWidth:0}}>
                                <span style=${{color:R.active?"var(--ok-fg)":"var(--fg-3)"}}>${R.active?"●":"○"}</span>
                                <span style=${{overflow:"hidden",textOverflow:"ellipsis",whiteSpace:"nowrap"}}>${R.title||R.url}</span>
                              </div>
                            `)}
                      </div>
                    `}
                  </article>
                `})}
        </div>
      `})()}
    </div>
  `;return a`
    <div class="ov ov--split" data-testid="runtime-addons-tab">
      <header class="ov-head" style=${{flexShrink:0}}>
        <div>
          <span class="ov-eyebrow">5 RUNTIME · LANE-ADDONS & BROWSER</span>
          <h1>Lane-Addons 인스턴스 & Browser Lane 클라이언트</h1>
        </div>
      </header>

      ${Ae&&a`
        <div
          role="alert"
          class="ap-error"
          style=${{flexShrink:0}}
        >
          ${Ae.text}
        </div>
      `}

      ${r?a`
            <div style=${{flex:"1 1 0%",minHeight:0}}>
              <${la}
                masterLabel="Lane-Addons 인스턴스"
                detailLabel="Browser Lane 클라이언트"
                master=${Ce}
                detail=${me}
              />
            </div>
          `:a`
            <div class="wka-card" data-testid="addons-mode-notice" role="status" style=${{fontSize:"var(--fs-13)",color:"var(--fg-2)"}}>
              ${t.kind==="single_user_local"?"Lane-Addons 및 Browser Lane 제어는 워크스페이스 접근 권한이 있는 세션에서만 사용할 수 있습니다.":"Lane-Addons 및 Browser Lane(/api/v1/lane-addons, /api/v1/dashboard/browser-lane)은 single_user 모드 전용입니다."}
            </div>
          `}
    </div>
  `}const xn=["payment_refused","provider_quota_refused","usage_read"];function _n(e){const t=xn.indexOf(e);return t===-1?xn.length:t}function Dt(e){const t=e.trim();switch(t){case"provider_quota_refused":return{label:"한도 초과",shortLabel:"한도 초과",tone:"warn"};case"payment_refused":return{label:"결제·크레딧 거절",shortLabel:"결제 거절",tone:"bad"};case"usage_read":return{label:"사용량 100% 도달",shortLabel:"사용량 100%",tone:"warn"};default:{const n=t.length>0?`일시 중지 (${t})`:"일시 중지";return{label:n,shortLabel:n,tone:"warn"}}}}function Tt(e){return e==="bad"?{background:"var(--err-soft)",border:"1px solid var(--err-border)",color:"var(--err-fg)"}:{background:"var(--warn-soft)",border:"1px solid var(--warn-border)",color:"var(--warn-fg)"}}function Ht(e){return String(e).padStart(2,"0")}function mt(e){return typeof e=="number"&&Number.isFinite(e)&&e>0}function Vn(e,t=Date.now()/1e3){if(!mt(e))return null;const n=mt(t)?t:Date.now()/1e3,r=new Date(e*1e3),l=new Date(n*1e3),d=`${Ht(r.getHours())}:${Ht(r.getMinutes())}`,c=new Date(l.getFullYear(),l.getMonth(),l.getDate()),v=new Date(r.getFullYear(),r.getMonth(),r.getDate()),h=Math.round((v.getTime()-c.getTime())/864e5);return h===0?`오늘 ${d}`:h===1?`내일 ${d}`:`${Ht(r.getMonth()+1)}/${Ht(r.getDate())} ${d}`}function Yt(e,t,n=Date.now()/1e3){const r=!t;if(!mt(e))return{countdown:"미정",localTime:null,isSoon:!1,isEstimated:r,hasPassed:!1};const l=mt(n)?n:Date.now()/1e3,d=e-l,c=Vn(e,l);if(d<=0)return{countdown:"해제됨",localTime:c,isSoon:!1,isEstimated:r,hasPassed:!0};const v=d>0&&d<=1800;let h;if(d<60)h=`${Math.max(1,Math.round(d))}초 후`;else if(d<3600)h=`${Math.max(1,Math.floor(d/60))}분 후`;else if(d<86400){const m=Math.floor(d/3600),k=Math.floor(d%3600/60);h=k>0?`${m}시간 ${k}분 후`:`${m}시간 후`}else{const m=Math.floor(d/86400),k=Math.floor(d%86400/3600);h=k>0?`${m}일 ${k}시간 후`:`${m}일 후`}return{countdown:h,localTime:c,isSoon:v,isEstimated:r,hasPassed:!1}}function wn(e){return`${e.hasPassed?"가장 빠른 해제 시각 지남":`가장 빠른 해제 ${e.countdown}`}${e.localTime?` (${e.localTime})`:""}${e.isEstimated?" · 예상":""}`}const Ga=3e4,Ja=1e3;function Ya(e,t){if(e.length===0)return null;let n=Ga;for(const r of e){const l=r*1e3+Ja-t;l>0&&l<n&&(n=l)}return n}function Qa(e,t){return e.some(n=>n*1e3<=t)}const Xa=new Set([":","/",".","-","_"]);function Za(e,t){if(!t||!e.startsWith(t))return e;const n=e.slice(t.length);return n.length>1&&Xa.has(n[0])?n.slice(1):e}function Sn(e,t){if(e)return e instanceof Map?e.get(t):e[t]}function Hn(e){if(e===void 0)return null;if(typeof e=="string"){const t=e.trim();return t.length>0?t:null}return e.state==="not_read"?`계정 미확인 (${e.cause})`:[e.email,...e.plan??[]].join(" · ")}function un(e,t){const n=mt(e),r=mt(t);return n&&r?e-t:n?-1:r?1:0}function es(e,t){const n=mt(e.quota_rest.until)?e.quota_rest.until:null,r=mt(t.quota_rest.until)?t.quota_rest.until:null;return un(n,r)||e.id.localeCompare(t.id)}function Cn(e){let t=null,n=!1;for(const r of e){const l=r.quota_rest.until;mt(l)&&(t===null||l<t?(t=l,n=r.quota_rest.reset_stated):l===t&&r.quota_rest.reset_stated&&(n=!0))}return{until:t,resetStated:n}}function ts(e){return e.quota_rest!==null}function In(e,t){const n=e.length,r=new Map,l=new Map,d=[],c={};for(const U of e){if(r.set(U.provider,(r.get(U.provider)??0)+1),!ts(U))continue;d.push(U);const ae=U.quota_rest.cause;c[ae]=(c[ae]??0)+1;const Ae=l.get(U.provider);Ae?Ae.push(U):l.set(U.provider,[U])}const v=d.length,h=t.nowUnix??Date.now()/1e3;let m=0,k=0,q=0;for(const U of e){const ae=ba(U,h);ae?.kind==="credential_refused"?k+=1:ae?.kind==="rate_limited"&&U.quota_rest===null&&(q+=1),ha(U,h)&&(m+=1)}const z=n-m,T=l.size,ue=Cn(d),W=(c.payment_refused??0)>0,oe=k>0,fe=[];for(const[U,ae]of l.entries()){const Ae=t.causeFilter==="all"?ae:ae.filter(J=>J.quota_rest.cause===t.causeFilter);if(Ae.length===0)continue;const O=[...Ae].sort(es),te=new Set;for(const J of O)te.add(J.quota_rest.cause);const Ee=[...te].sort((J,K)=>_n(J)-_n(K)||J.localeCompare(K)),je=Ee[0],ze=Cn(O),Ke=O.some(J=>!J.quota_rest.reset_stated),pe=Sn(t.providerDisplayNames,U),G=pe&&pe.trim().length>0?pe.trim():U,Ie=Hn(Sn(t.accountEmails,U));fe.push({provider:U,displayName:G,accountLineText:Ie,totalInProvider:r.get(U)??O.length,restingCount:O.length,runtimes:O,causes:Ee,primaryCause:je,soonestUntil:ze.until,soonestResetStated:ze.resetStated,hasEstimatedReset:Ke})}return fe.sort((U,ae)=>{switch(t.sortBy){case"count":return ae.restingCount-U.restingCount||un(U.soonestUntil,ae.soonestUntil)||U.provider.localeCompare(ae.provider);case"name":return U.displayName.localeCompare(ae.displayName)||U.provider.localeCompare(ae.provider);default:return un(U.soonestUntil,ae.soonestUntil)||ae.restingCount-U.restingCount||U.provider.localeCompare(ae.provider)}}),{summary:{totalRegistered:n,restingCount:v,blockedCount:z,availableCount:m,credentialRefusedCount:k,rateLimitedCount:q,groupCount:T,soonestUntil:ue.until,soonestResetStated:ue.resetStated,causeCounts:c,hasPaymentRefused:W,hasCredentialRefused:oe},groups:fe}}const ns={padding:"var(--sp-0) var(--sp-2)",borderRadius:"var(--radius-pill)",fontWeight:600,whiteSpace:"nowrap"};function as(e,t){switch(e.kind){case"credential_refused":{const n=Vn(e.since,t);return{label:"인증 거부",tone:"bad",when:`${jn(t-e.since)}부터${n?` (${n})`:""}`}}case"rate_limited":{if(e.resetsAt===null)return{label:"속도 제한 (429)",tone:"warn",when:"해제 시각 없음 · 응답이 오면 해제"};const n=Yt(e.resetsAt,!0,t);return{label:"속도 제한 (429)",tone:"warn",when:`${n.countdown}${n.localTime?` (${n.localTime})`:""}`}}}}function ss({row:e,nowUnix:t}){const{runtime:n,block:r,failedAttempt:l}=e,d=r===null?null:as(r,t);return a`
    <div
      data-testid=${`runtime-liveness-${n.id}`}
      style=${{display:"flex",alignItems:"center",justifyContent:"space-between",gap:"var(--sp-2)",flexWrap:"wrap",padding:"var(--sp-1) var(--sp-2)",borderRadius:"var(--radius-sm)",background:"var(--bg-1)",border:"1px solid var(--line-1)"}}
    >
      <span style=${{display:"inline-flex",alignItems:"center",gap:"var(--sp-2)",flexWrap:"wrap",minWidth:0}}>
        <span style=${{fontWeight:600,fontSize:"var(--fs-12)"}}>${n.model||n.id}</span>
        <span class="mono" style=${{fontSize:"var(--fs-11)",color:"var(--fg-3)"}}>${n.id}</span>
      </span>
      <span class="mono tnum" style=${{display:"inline-flex",alignItems:"center",gap:"var(--sp-2)",flexWrap:"wrap",fontSize:"var(--fs-11)"}}>
        ${d&&a`
          <span style=${{...Tt(d.tone),...ns}}>${d.label}</span>
          <span style=${{color:"var(--fg-2)"}}>${d.when}</span>
        `}
        ${l&&a`
          <span style=${{color:"var(--warn-fg)"}}>
            마지막 실패 ${ka(l.failure)} · ${l.recorded_by} · ${jn(t-l.noted_at)}
          </span>
        `}
      </span>
    </div>
  `}function rs({runtimes:e,nowUnix:t=Date.now()/1e3}){const n=ya(e,t);if(n.length===0)return null;const r=n.some(l=>l.block?.kind==="credential_refused");return a`
    <section
      class="wka-card"
      data-testid="runtime-liveness-panel"
      aria-label="호출이 막히거나 실패한 런타임"
      style=${{display:"flex",flexDirection:"column",gap:"var(--sp-2)",borderColor:r?"var(--err-border)":"var(--warn-border)",background:r?"var(--err-soft)":"var(--warn-soft)"}}
    >
      <span style=${{fontSize:"var(--fs-13)",fontWeight:600}}>호출이 막히거나 실패한 런타임 (${n.length})</span>
      <p style=${{margin:0,fontSize:"var(--fs-12)",color:"var(--fg-2)"}}>
        인증 거부와 속도 제한 중인 런타임은 가용에서 뺍니다. 마지막 실패는 그 런타임이 다시 응답하면 사라집니다.
      </p>
      <div style=${{display:"flex",flexDirection:"column",gap:"var(--sp-1)"}}>
        ${n.map(l=>a`<${ss} key=${l.runtime.id} row=${l} nowUnix=${t} />`)}
      </div>
    </section>
  `}const is=[{label:"평균 사용률 (%)",colorToken:"--info-fg",width:2,fillAlpha:.14,unit:"%"},{label:"최대 피크 사용률 (%)",colorToken:"--warn-fg",width:1.75,unit:"%"},{label:"일시 중지·소진 수",colorToken:"--err-fg",width:1.75,dash:[4,3]}];function Gn(e){if(e.length===0)return[[],[],[],[]];const t=new Map;for(const c of e){const v=Math.floor(c.observed_at/3600)*3600;let h=null;const m=c.utilization,k=$a(m)===!0;switch(m.unit){case"fraction":h=Math.min(100,Math.max(0,m.value*100));break;case"percent":h=Math.min(100,Math.max(0,m.value));break;case"usd":m.limit!==null&&m.limit>0&&(h=Math.min(100,Math.max(0,m.value/m.limit*100)));break;case"credit_balance":m.total!==null&&m.total>0&&(h=Math.min(100,Math.max(0,(m.total-m.remaining)/m.total*100)));break}const q=t.get(v)??{sumPct:0,count:0,maxPct:0,cooldownCount:0};h!==null&&(q.sumPct+=h,q.count+=1,h>q.maxPct&&(q.maxPct=h)),k&&(q.cooldownCount+=1),t.set(v,q)}const n=[...t.keys()].sort((c,v)=>c-v),r=[],l=[],d=[];for(const c of n){const v=t.get(c);r.push(v.count>0?Number((v.sumPct/v.count).toFixed(1)):null),l.push(v.count>0?Number(v.maxPct.toFixed(1)):null),d.push(v.cooldownCount)}return[n,r,l,d]}function os(e){return e.providers.length>0?e.providers.map(t=>t.display_name||t.id).join(" · "):e.scope_id||e.scope}function rn(e){return Hn(e)}function ls(e){return e.providers[0]?.id??e.scope_id??e.scope}function ds(e){switch(e){case"exhausted_zero":return{background:"var(--err-soft)",border:"1px solid var(--err-border)",color:"var(--err-fg)"};case"subscription_zero":return{background:"var(--ok-soft)",border:"1px solid var(--ok-border)",color:"var(--ok-fg)"};case"amount":return{background:"var(--info-soft)",border:"1px solid var(--info-border)",color:"var(--info-fg)"};case"unreported":return{background:"var(--idle-soft)",border:"1px solid var(--idle-border)",color:"var(--fg-3)"}}}const cs=["payment_refused","provider_quota_refused","usage_read"];function us(e){const t=vn.value,n=En(t),r=be.value,l=tt.value,d=r.kind==="multi_account_signed_in",c=r.kind==="single_user_local",v=ot("admin",r),h=d||c&&!v,m=N.observe("runtime:resolved").value,k=`runtime:provider-usage-history:${n}`,q=N.observe(k).value,z=d?"runtime:auth-provider-accounts":xa,T=N.observe(z).value,ue=N.observe("runtime:auth-integrations").value,[W,oe]=_(!1),[fe,U]=_(null),[ae,Ae]=_(!1),[O,te]=_("release"),[Ee,je]=_("all"),[ze,Ke]=_(()=>new Set),[pe,G]=_(()=>Date.now()/1e3),[Ie,J]=_(null),[K,_e]=_(""),[L,F]=_(null),[ge,j]=_(null),[Oe,E]=_(null),[re,ye]=_(""),Y=Me(!0),Re=Me(null);ve(()=>{Y.current=!0;const o=window.setInterval(()=>{G(Date.now()/1e3)},3e4);return()=>{Y.current=!1,window.clearInterval(o),Re.current?.abort()}},[]);const ie=(o="mount")=>{const S=be.peek(),y=S.kind==="multi_account_signed_in",X=S.kind==="single_user_local";if(!y&&!X)return Re.current?.abort(),Promise.resolve();const M=xe(),ee=[N.fetch("runtime:resolved",Fn,{ttlMs:15e3,topics:["runtime","runtime_resolved","provider_usage","config"],reason:o})];if(X&&ee.push(N.fetch(k,A=>Nn(n,A),{ttlMs:3e4,topics:["provider_usage"],reason:o})),y)Re.current?.abort(),ee.push(N.fetch("runtime:auth-provider-accounts",A=>$e("/api/v1/auth/provider-accounts",{signal:A,decode:wa}),{ttlMs:2e4,topics:["provider_accounts"],reason:o}),N.fetch("runtime:auth-integrations",A=>$e("/api/v1/auth/integrations",{signal:A,decode:Sa}),{ttlMs:3e4,topics:["provider_accounts","config"],reason:o}));else if(X&&!ot("admin",S)){ee.push(Ca(o)),Re.current?.abort();const A=new AbortController;Re.current=A,$e("/api/v1/runtime/config/raw",{signal:A.signal}).then(i=>{!Y.current||!Z(M)||A.signal.aborted||i.ok&&typeof i.value.source_revision=="string"&&i.value.source_revision.trim().length>0&&ye(i.value.source_revision.trim())})}else Re.current?.abort();return Promise.all(ee).then(()=>{Y.current&&Z(M)&&Lt()})};ve(()=>{ye(""),J(null),F(null),E(null)},[l]),ve(()=>{ie("mount")},[n,r.kind,l,v]),ve(()=>{const o=new Set(["runtime","runtime_resolved","provider_usage","provider_standing","quota","config","provider_accounts","setup_inventory","dataset_invalidation"]);let S=null;const y=()=>{S!==null&&clearTimeout(S),S=setTimeout(()=>{S=null,!(!Y.current||!Z(l))&&ie("sse")},450)},X=At(i=>{Et(i).some(p=>o.has(p))&&y()}),M=()=>{!Y.current||!Z(l)||ie("sse")},ee=Kt(M),A=Ot(M);return()=>{S!==null&&clearTimeout(S),X(),ee(),A()}},[n,r.kind,l,v]);const he=m.kind==="value"?m.data:null;ve(()=>{he&&G(Date.now()/1e3)},[he]);const Ge=ce(()=>(he?.runtimes??[]).flatMap(o=>o.quota_rest!==null?[o.quota_rest.until]:[]),[he]),[Ce,me]=_(0);ve(()=>{const o=Ya(Ge,Date.now());if(o===null)return;const S=window.setTimeout(()=>{G(Date.now()/1e3),Qa(Ge,Date.now())&&ie("manual"),me(y=>y+1)},o);return()=>window.clearTimeout(S)},[Ge,Ce,n,r.kind,l,v]);const g=ce(()=>Wn(he?.runtimes??[],pe),[he,pe]),C=ce(()=>_a(he?.provider_usage_windows??[],g,pe),[he,g,pe]),x=ce(()=>new Map(T.kind==="value"&&"account_emails"in T.data&&Array.isArray(T.data.account_emails)?T.data.account_emails.map(o=>[o.integration_id,o]):[]),[T]),u=ce(()=>T.kind==="value"&&"integrations"in T.data&&Array.isArray(T.data.integrations)?T.data.integrations:[],[T]),R=ce(()=>T.kind==="value"?"provider_accounts"in T.data&&Array.isArray(T.data.provider_accounts)?T.data.provider_accounts:"accounts"in T.data&&Array.isArray(T.data.accounts)?T.data.accounts:[]:[],[T]),I=ce(()=>{if(q.kind==="loading")return{kind:"loading"};if(q.kind==="failed")return{kind:"failed",message:q.error.message};if(q.kind!=="value")return{kind:"unavailable",reason:"히스토리 데이터 없음"};const o=q.data;return o.state==="unavailable"?{kind:"unavailable",reason:o.reason}:{kind:"ready",data:Gn(o.points),pointsCount:o.points.length,unreadable:o.unreadable_reports,undecodable:o.undecodable_points,days:o.days}},[q]),w=ce(()=>ue.kind==="value"&&Array.isArray(ue.data.integrations)?ue.data.integrations:[],[ue]),Q=ce(()=>{const o=new Map;for(const S of R){const y=S.integration_id??S.provider,X=S.display_name??S.label;y&&X&&!o.has(y)&&o.set(y,X)}for(const S of w)S.integration_id&&S.display_name&&o.set(S.integration_id,S.display_name);for(const S of u)S.id&&S.display_name&&o.set(S.id,S.display_name);for(const S of he?.provider_usage_windows??[])for(const y of S.providers)y.id&&y.display_name&&o.set(y.id,y.display_name);return o},[he,u,w,R]),V=ce(()=>In(he?.runtimes??[],{providerDisplayNames:Q,accountEmails:x,sortBy:O,causeFilter:"all",nowUnix:pe}),[he,Q,x,O,pe]),We=Ee!=="all"&&(V.summary.causeCounts[Ee]??0)>0?Ee:"all",Ve=ce(()=>We==="all"?V:In(he?.runtimes??[],{providerDisplayNames:Q,accountEmails:x,sortBy:O,causeFilter:We,nowUnix:pe}),[V,We,he,Q,x,O,pe]),ct=o=>{Ke(S=>{const y=new Set(S);return y.has(o)?y.delete(o):y.add(o),y})},Ye=o=>{const S=K.trim();if(S)return S;const y=w.find(M=>M.integration_id===o);return y&&y.models?.[0]?y.models[0]:(he?.runtimes??[]).find(M=>M.provider===o&&M.model)?.model??""},nt=o=>o.kind==="multi_account_signed_in"||o.kind==="single_user_local"&&!ot("admin",o),pt=async o=>{o.preventDefault();const S=be.peek(),y=S.kind==="multi_account_signed_in";if(!nt(S)||!Ie||!Ie.providerId.trim()||!Ie.secret.trim())return;const X=xe(),M=Ie.providerId.trim(),ee=Ie.secret.trim();if(j("save-cred"),E(null),y){const p=await Pe("POST","/api/v1/setup/accounts/key",{integration_id:M,key:ee});if(!Y.current||!Z(X))return;if(j(null),!p.ok){E({kind:"err",text:`키 저장 실패: ${p.error.message}`});return}E(null),qe(`${M} 개인 API 키가 등록되었습니다.`,"success"),J(null),ie("manual");return}let A=re.trim();if(!A){const p=await $e("/api/v1/runtime/config/raw");if(!Y.current||!Z(X))return;p.ok&&typeof p.value.source_revision=="string"&&(A=p.value.source_revision.trim(),A&&ye(A))}if(!A){j(null),E({kind:"err",text:"runtime.toml의 source_revision을 확인할 수 없어 자격 증명을 저장할 수 없습니다. 새로고침 후 다시 시도하세요."});return}const i=await Pe("POST","/api/v1/setup/credential",{provider_id:M,secret:ee,source_revision:A});if(!(!Y.current||!Z(X))){if(j(null),!i.ok){E({kind:"err",text:`키 저장 실패: ${i.error.message}`});return}E(null),qe(`${M} 자격 증명이 저장되었습니다.`,"success"),J(null),ie("manual")}},De=Me(null),we=Me(null),[ke,at]=_(""),[Be,He]=_(!1);ve(()=>()=>{De.current?.abort("unmount")},[]),ve(()=>{De.current?.abort("session_changed"),De.current=null,Re.current?.abort("session_changed"),Re.current=null,we.current=null,F(null),J(null),at(""),He(!1),ye(""),j(null)},[l,r.kind,h]);const Se=async o=>{const S=be.peek(),y=S.kind==="multi_account_signed_in";if(!nt(S))return;const X=xe();De.current?.abort("superseded");const M=new AbortController;De.current=M,we.current=null,at(""),He(!1),j(`login:${o}`),E(null);const ee=()=>Y.current&&Z(X)&&!M.signal.aborted&&De.current===M;F({loginId:"",integrationId:o,status:"starting",accountRef:null,authentication:null,authUrl:null,deviceCode:null,inputReady:!1,outputTail:"",streaming:!0,popupBlocked:!1}),await ca({integrationId:o,signal:M.signal,callbacks:{onStarted:A=>{ee()&&F(i=>({...i??{loginId:A.loginId,integrationId:o},loginId:A.loginId||i?.loginId||"",integrationId:A.integrationId||o,status:A.status,accountRef:A.accountRef??i?.accountRef??null,authentication:A.authentication??i?.authentication??null,streaming:!0}))},onOutput:(A,i)=>{ee()&&F(p=>p&&{...p,outputTail:`${p.outputTail??""}${i}`.slice(-2e3)})},onScreen:A=>{ee()&&F(i=>i&&{...i,outputTail:A.slice(-2e3)})},onAuthUrl:A=>{if(!ee())return;let i=!1;if(we.current!==A&&(we.current=A,typeof window<"u"&&typeof window.open=="function"))try{i=window.open(A,"_blank","noopener,noreferrer")===null}catch{i=!0}F(p=>p&&{...p,authUrl:A,popupBlocked:i})},onDeviceCode:A=>{ee()&&F(i=>i&&{...i,deviceCode:A})},onInputReady:()=>{ee()&&F(A=>A&&{...A,inputReady:!0})},onComplete:A=>{if(!ee())return;F(p=>({...p??{loginId:A.loginId,integrationId:o},loginId:A.loginId||p?.loginId||"",integrationId:A.integrationId||o,status:"complete",accountRef:A.accountRef??p?.accountRef??null,authentication:A.authentication??p?.authentication??null,inputReady:!1,streaming:!1})),E(null),qe(`${o} CLI OAuth 로그인이 완료되었습니다.`,"success"),ie("manual");const i=A.accountRef;y&&i&&Ye(o)&&de(o,i)},onError:(A,i)=>{ee()&&(F(p=>p?{...p,loginId:i?.loginId||p.loginId,status:i?.status||"failed",accountRef:i?.accountRef??p.accountRef,message:A,inputReady:!1,streaming:!1}:null),E({kind:"err",text:`CLI OAuth 로그인 실패: ${A}`}))}}}),ee()&&(j(A=>A===`login:${o}`?null:A),F(A=>A&&{...A,streaming:!1}))},vt=async o=>{if(o.preventDefault(),!nt(be.peek())||!L?.loginId||!ke.trim())return;const S=xe(),y=ke.trim();j("login-input");const X=await bn(L.loginId,{kind:"text",text:y});if(!(!Y.current||!Z(S))){if(j(null),!X.ok){E({kind:"err",text:`CLI 입력 전송 실패: ${X.error.message}`});return}at(""),F(M=>M&&{...M,inputReady:!1})}},it=async()=>{if(!nt(be.peek())||!L?.loginId)return;const o=xe();j("login-input");const S=await bn(L.loginId,{kind:"key",key:"enter"});if(!(!Y.current||!Z(o))){if(j(null),!S.ok){E({kind:"err",text:`Enter 키 전송 실패: ${S.error.message}`});return}F(y=>y&&{...y,inputReady:!1})}},Fe=async()=>{if(!nt(be.peek()))return;const o=xe(),S=De.current;L?.loginId&&await ua(L.loginId),!(!Y.current||!Z(o)||De.current!==S)&&(S?.abort("cancelled"),F(y=>y&&{...y,status:"cancelled",streaming:!1,inputReady:!1}))},ut=async()=>{if(!nt(be.peek()))return;const o=L?.loginId?.trim();if(!o)return;const S=xe();j("receipt");const y=await $e(`/api/v1/setup/accounts/login/${encodeURIComponent(o)}`);if(!Y.current||!Z(S))return;if(j(M=>M==="receipt"?null:M),!y.ok){E({kind:"err",text:`로그인 영수증 조회 실패: ${y.error.message}`});return}const X=y.value;F(M=>!M||M.loginId!==o?M:{...M,status:typeof X.status=="string"?X.status:M.status,accountRef:typeof X.account_ref=="string"?X.account_ref:M.accountRef,authentication:typeof X.authentication=="string"?X.authentication:M.authentication})},de=async(o,S)=>{if(be.peek().kind!=="multi_account_signed_in"){E({kind:"err",text:"계정 검증(/api/v1/setup/accounts/verify)은 multi_account 모드에서만 지원됩니다."});return}const y=(S??"").trim(),X=Ye(o);if(!y||!X){E({kind:"err",text:`계정 검증 실패 (${o}): provider_account_id와 검증할 모델명이 필요합니다.`});return}const M=xe();j(`verify:${y}`),E(null);const ee=await Pe("POST","/api/v1/setup/accounts/verify",{provider_account_id:y,model:X});if(!(!Y.current||!Z(M))){if(j(null),!ee.ok){E({kind:"err",text:`검증 실패 (${y}): ${ee.error.message}`});return}E(null),qe(`${y} (${X}) 계정 검증 완료.`,"success"),ie("manual")}},lt=async o=>{if(be.peek().kind!=="multi_account_signed_in")return;const S=xe();j(`remove:${o}`),E(null);const y=await Pe("DELETE",`/api/v1/setup/accounts/key/${encodeURIComponent(o)}`);if(!(!Y.current||!Z(S))){if(j(null),!y.ok){E({kind:"err",text:`삭제 실패 (${o}): ${y.error.message}`});return}E(null),qe(`${o} 자격 증명을 제거했습니다.`,"success"),ie("manual")}},dt=(o,S)=>{const y=Ia(o,pe),X=Ra(o,pe),M=ls(o),ee=os(o),A=o.providers.map(le=>rn(x.get(le.id))).filter(le=>le!==null),i=new Set(o.providers.map(le=>le.id));let p=!1,b=!1;for(const le of he?.runtimes??[]){if(!i.has(le.provider_id))continue;const s=dn(le);s.visionInput&&(p=!0),s.imageOutput&&(b=!0)}const B=ds(y.kind),ne=Ta(o,he?.runtimes??[]),se=ne!==null&&ne.until*1e3>Date.now()?Dt(ne.cause):null;return a`
      <article
        key=${`${o.scope}-${S}`}
        class="wka-card"
        style=${{display:"flex",flexDirection:"column",gap:"var(--sp-2)",minWidth:0}}
      >
        <div style=${{display:"flex",alignItems:"center",justifyContent:"space-between",gap:"var(--sp-2)",flexWrap:"wrap"}}>
          <div style=${{minWidth:0}}>
            <div style=${{display:"flex",alignItems:"center",gap:"var(--sp-1)",flexWrap:"wrap",fontWeight:600,fontSize:"var(--fs-13)",color:"var(--fg-1)"}}>
              <span>${ee}</span>
              ${p&&a`<span class="mono rt-cap-chip" data-testid=${`scope-${M}-cap-vision`}>Vision</span>`}
              ${b&&a`<span class="mono rt-cap-chip rt-cap-chip--gen" data-testid=${`scope-${M}-cap-image-gen`}>Image Gen</span>`}
            </div>
            <div class="mono" style=${{fontSize:"var(--fs-11)",color:"var(--fg-3)"}}>${o.scope}</div>
            ${A.map(le=>a`<div class="mono" style=${{fontSize:"var(--fs-11)",color:"var(--fg-2)"}}>${le}</div>`)}
            ${se!==null&&a`
              <div data-testid="quota-card-rest" style=${{fontSize:"var(--fs-11)",color:Tt(se.tone).color}}>
                일시 중지 · ${se.shortLabel}
              </div>
            `}
          </div>
          <span
            class="mono tnum"
            style=${{...B,padding:"var(--sp-0) var(--sp-2)",borderRadius:"var(--radius-pill)",fontSize:"var(--fs-11)",fontWeight:600,whiteSpace:"nowrap"}}
          >
            ${y.badge}
          </span>
        </div>

        ${o.windows.length>0?a`
              <div style=${{display:"flex",flexDirection:"column",gap:"var(--sp-1)"}}>
                ${o.windows.map((le,s)=>{const f=le.utilization;let $=0,D="미보고";f.unit==="fraction"?($=Math.min(100,Math.max(0,f.value*100)),D=`${$.toFixed(1)}%`):f.unit==="percent"?($=Math.min(100,Math.max(0,f.value)),D=`${$.toFixed(0)}%`):f.unit==="credit_balance"?(D=`${f.remaining.toFixed(2)} ${f.currency}`,$=f.total&&f.total>0?Math.min(100,(f.total-f.remaining)/f.total*100):0):f.unit==="usd"?(D=f.limit!==null?`$${f.value.toFixed(2)} / $${f.limit.toFixed(2)}`:`$${f.value.toFixed(2)}`,$=f.limit&&f.limit>0?Math.min(100,f.value/f.limit*100):0):f.unit==="credit_unlimited"&&(D="무제한 구독");const H=$>=95?"var(--err)":$>=75?"var(--warn)":"var(--ok)";return a`
                    <div key=${`${s}-${le.limit_id??"w"}`} style=${{display:"flex",flexDirection:"column",gap:"var(--sp-0)"}}>
                      <div style=${{display:"flex",justifyContent:"space-between",fontSize:"var(--fs-11)",color:"var(--fg-2)"}}>
                        <span class="mono">${Aa(le.window)} ${le.limit_id?`(${le.limit_id})`:""}</span>
                        <span class="mono tnum">
                          ${D} · 리셋 ${Oa(le.resets_at,pe)}
                        </span>
                      </div>
                      <div style=${{height:"6px",borderRadius:"var(--radius-pill)",background:"var(--bg-3)",overflow:"hidden"}}>
                        <div style=${{width:`${$}%`,height:"100%",background:H}} />
                      </div>
                    </div>
                  `})}
              </div>
            `:a`
              <div style=${{fontSize:"var(--fs-12)",color:"var(--fg-3)"}}>
                ${o.state==="reported_no_windows"?"창 정보 없음 (제공자 미제공)":"서버 시작 이후 미보고"}
              </div>
            `}

        <div style=${{display:"flex",alignItems:"center",justifyContent:"space-between",gap:"var(--sp-2)",paddingTop:"var(--sp-1)",borderTop:"1px solid var(--line-1)",flexWrap:"wrap"}}>
          <span class="mono tnum" style=${{fontSize:"var(--fs-11)",color:"var(--fg-3)"}}>
            최대 사용률: ${X!==null?`${X.toFixed(1)}%`:"미보고"}
          </span>
          <div style=${{display:"flex",gap:"var(--sp-1)"}}>
            ${h&&a`
              <button
                type="button"
                class="btn-ghost"
                onClick=${()=>J({providerId:M,secret:"",mode:"api_key"})}
              >
                Re-auth
              </button>
            `}
            ${h&&!v&&a`
              <button
                type="button"
                class="btn-ghost"
                onClick=${()=>e.onNavigate(`/settings?key=providers.${encodeURIComponent(M)}`)}
              >
                Open Config Key
              </button>
            `}
          </div>
        </div>
      </article>
    `},ht=(he?.provider_usage_windows??[]).length,P=Ve.summary,gt=Ve.groups,yt=cs.filter(o=>(P.causeCounts[o]??0)>0),Qe=gt.length>0&&gt.every(o=>ze.has(o.provider)),Je=fe??P.hasPaymentRefused,st=P.soonestUntil!==null?Yt(P.soonestUntil,P.soonestResetStated,pe):null,kt=P.hasPaymentRefused||P.hasCredentialRefused?"bad":P.availableCount<P.totalRegistered?"warn":"ok",zt=u.filter(o=>o.enabled!==!1).length,xt=We!=="all"?` · ${Dt(We).shortLabel}`:O!=="release"?` · ${{release:"해제 임박순",count:"런타임 많은순",name:"이름순"}[O]}`:"",_t=[{id:"sort-release",label:"정렬: 해제 임박순",active:O==="release",testId:"paused-sort-release",onSelect:()=>te("release")},{id:"sort-count",label:"정렬: 런타임 많은순",active:O==="count",testId:"paused-sort-count",onSelect:()=>te("count")},{id:"sort-name",label:"정렬: 이름순",active:O==="name",testId:"paused-sort-name",onSelect:()=>te("name")},...yt.length>=2?[{id:"filter-all",label:`사유: 전체 (${P.restingCount})`,active:We==="all",testId:"paused-filter-all",separatorBefore:!0,onSelect:()=>je("all")},...yt.map(o=>{const S=Dt(o),y=P.causeCounts[o]??0;return{id:`filter-${o}`,label:`사유: ${S.shortLabel} (${y})`,active:We===o,testId:`paused-filter-${o}`,onSelect:()=>je(o)}})]:[],{id:"toggle-expand-all",label:Qe?"모두 접기":"모두 펼치기",testId:"paused-expand-all-toggle",separatorBefore:!0,onSelect:()=>{Ke(Qe?new Set:new Set(gt.map(o=>o.provider)))}}];return a`
    <div class="ov" data-testid="runtime-quotas-tab">
      <header class="ov-head">
        <div>
          <span class="ov-eyebrow">5 RUNTIME · QUOTAS & RATE LIMITS</span>
          <h1>제공자 할당량 · 일시 중지 · 자격 증명</h1>
          <p class="ov-sub">
            $0 Sub / $0 Exhausted / ? Unreported 정직 분류 · 조회 창 ${t} (Provider History ${n}d)
          </p>
        </div>
        <div style=${{display:"flex",gap:"var(--sp-2)",flexWrap:"wrap"}}>
          ${h&&a`
            <button
              type="button"
              class="btn-primary"
              onClick=${()=>J({providerId:w[0]?.integration_id??u[0]?.id??"openai",secret:"",mode:"api_key"})}
            >
              + API 키 등록
            </button>
          `}
          <${wt} onRefresh=${()=>ie("manual")} />
        </div>
      </header>

      ${Oe&&a`
        <div role="alert" class="ap-error">
          ${Oe.text}
        </div>
      `}

      ${m.kind==="failed"&&a`
        <div class="ap-error" role="alert">할당량 요약 조회 실패: ${m.error.message}</div>
      `}

      <section class="ov-kpis" aria-label="할당량 요약">
        <div class="ov-kpi">
          <div class="ov-kpi-k">Tier 1 소진 / 크레딧 / 429</div>
          <div class=${`ov-kpi-v ${m.kind==="failed"?"bad":m.kind==="value"?C.tier1ExhaustedOrCredits.length>0?"bad":"ok":""}`}>
            ${m.kind==="value"?C.tier1ExhaustedOrCredits.length:rt(m)}
          </div>
        </div>
        <div class="ov-kpi">
          <div class="ov-kpi-k">Tier 2 활성 구독 ($0 Sub)</div>
          <div class=${`ov-kpi-v ${m.kind==="failed"?"bad":m.kind==="value"?"ok":""}`}>
            ${m.kind==="value"?C.tier2ActiveSubscriptions.length:rt(m)}
          </div>
        </div>
        <div class="ov-kpi">
          <div class="ov-kpi-k">Tier 3 미보고 (? Unreported)</div>
          <div class=${`ov-kpi-v ${m.kind==="failed"?"bad":""}`}>
            ${m.kind==="value"?C.tier3Unreported.length:rt(m)}
          </div>
        </div>
        <div class="ov-kpi" data-testid="kpi-paused-runtimes">
          <div class="ov-kpi-k">
            ${P.blockedCount>P.restingCount?"일시 중지 런타임 · 차단":"일시 중지 런타임"}
          </div>
          <div class=${`ov-kpi-v ${m.kind==="failed"?"bad":m.kind==="value"?kt:""}`}>
            ${m.kind!=="value"?rt(m):P.totalRegistered>0?`${P.blockedCount} / ${P.totalRegistered}`:String(P.blockedCount)}
          </div>
          ${m.kind==="value"&&P.totalRegistered>0&&a`
            <div class="mono tnum" style=${{fontSize:"var(--fs-11)",color:"var(--fg-3)",marginTop:"var(--sp-0)"}}>
              전체 ${P.totalRegistered} · 가용 ${P.availableCount}${P.credentialRefusedCount>0?` · 인증 거부 ${P.credentialRefusedCount}`:""}${P.rateLimitedCount>0?` · 속도 제한 ${P.rateLimitedCount}`:""}
            </div>
          `}
        </div>
      </section>

      ${P.restingCount>0&&a`
        <section
          class="wka-card"
          data-testid="paused-runtimes-panel"
          aria-label="일시 중지 런타임"
          style=${{display:"flex",flexDirection:"column",gap:"var(--sp-2)",borderColor:P.hasPaymentRefused?"var(--err-border)":"var(--warn-border)",background:P.hasPaymentRefused?"var(--err-soft)":"var(--warn-soft)"}}
        >
          <div style=${{display:"flex",alignItems:"center",justifyContent:"space-between",gap:"var(--sp-2)",flexWrap:"wrap"}}>
            <button
              type="button"
              class="ap-disclosure-trigger"
              data-testid="paused-panel-toggle"
              aria-expanded=${Je}
              onClick=${()=>U(!Je)}
              style=${{flex:"1 1 240px",padding:"var(--sp-1) var(--sp-2)",color:"var(--fg-1)"}}
            >
              <span style=${{display:"inline-flex",alignItems:"center",gap:"var(--sp-2)",flexWrap:"wrap",fontSize:"var(--fs-13)",fontWeight:600}}>
                <span aria-hidden="true">${Je?"▾":"▸"}</span>
                ${Je?a`
                      <span>일시 중지 런타임 (${P.restingCount}/${P.totalRegistered})</span>
                      <span class="mono tnum" style=${{fontSize:"var(--fs-11)",fontWeight:500,color:"var(--fg-2)"}}>
                        ${P.groupCount}개 계정 · 가용 ${P.availableCount}
                      </span>
                    `:a`
                      <span class="mono tnum" style=${{fontSize:"var(--fs-12)"}}>
                        일시 중지 ${P.restingCount}/${P.totalRegistered} (${P.groupCount}개 계정) · 가용 ${P.availableCount}${st?` · ${wn(st)}`:""}
                      </span>
                    `}
              </span>
            </button>

            ${Je&&a`
              <div style=${{display:"inline-flex",alignItems:"center",gap:"var(--sp-2)",flexWrap:"wrap",flexShrink:0}}>
                ${st&&a`
                  <span class="mono tnum" style=${{fontSize:"var(--fs-11)",color:st.isSoon?"var(--ok-fg)":"var(--fg-2)"}}>
                    ${wn(st)}
                  </span>
                `}
                <${ia}
                  triggerLabel=${`정렬·필터${xt} ▾`}
                  triggerTestId="paused-controls-trigger"
                  popoverTestId="paused-controls-menu"
                  align="right"
                  ariaLabel="일시 중지 런타임 정렬 및 사유 필터"
                  items=${_t}
                />
              </div>
            `}
          </div>

          ${Je&&a`
            <p style=${{margin:0,fontSize:"var(--fs-12)",color:"var(--fg-2)"}}>
              할당량 소진·결제 거절로 자동 우회 중인 런타임입니다. 해제 시각이 지나면 자동으로 다시 호출됩니다.
            </p>

            <div style=${{display:"flex",flexDirection:"column",gap:"var(--sp-1)"}}>
              ${gt.map(o=>{const S=ze.has(o.provider),y=Yt(o.soonestUntil,o.soonestResetStated,pe),X=o.causes.includes("payment_refused"),M=y.isEstimated;return a`
                  <div
                    key=${o.provider}
                    data-testid=${`paused-group-${o.provider}`}
                    style=${{border:`1px solid ${X?"var(--err-border)":"var(--line-1)"}`,borderRadius:"var(--radius-sm)",background:"var(--bg-1)"}}
                  >
                    <button
                      type="button"
                      class="ap-disclosure-trigger"
                      aria-expanded=${S}
                      onClick=${()=>ct(o.provider)}
                      style=${{flexWrap:"wrap",padding:"var(--sp-2) var(--sp-3)",borderRadius:"var(--radius-sm)",color:"var(--fg-1)"}}
                    >
                      <span style=${{display:"inline-flex",alignItems:"center",gap:"var(--sp-2)",flexWrap:"wrap",minWidth:0}}>
                        <span aria-hidden="true" style=${{color:"var(--fg-3)"}}>${S?"▾":"▸"}</span>
                        <span style=${{fontWeight:600,fontSize:"var(--fs-13)"}}>${o.displayName}</span>
                        ${o.displayName!==o.provider&&a`
                          <span class="mono" style=${{fontSize:"var(--fs-11)",color:"var(--fg-3)"}}>${o.provider}</span>
                        `}
                        ${o.accountLineText&&a`
                          <span class="mono" style=${{fontSize:"var(--fs-11)",color:"var(--fg-2)"}}>${o.accountLineText}</span>
                        `}
                        ${o.causes.map(ee=>{const A=Dt(ee);return a`
                            <span
                              key=${ee}
                              style=${{...Tt(A.tone),padding:"var(--sp-0) var(--sp-2)",borderRadius:"var(--radius-pill)",fontSize:"var(--fs-11)",fontWeight:600,whiteSpace:"nowrap"}}
                            >
                              ${A.label}
                            </span>
                          `})}
                      </span>

                      <span class="mono tnum" style=${{display:"inline-flex",alignItems:"center",gap:"var(--sp-2)",flexWrap:"wrap",fontSize:"var(--fs-12)"}}>
                        <span style=${{color:"var(--fg-2)",fontWeight:600}}>
                          ${o.restingCount}/${o.totalInProvider} 중지
                        </span>
                        <span style=${{color:y.isSoon?"var(--ok-fg)":"var(--fg-2)"}}>
                          ${y.isSoon?`곧 해제 · ${y.countdown}`:y.countdown}${y.localTime?` (${y.localTime})`:""}
                        </span>
                        ${M&&a`
                          <span
                            title="제공자가 정확한 리셋 시각을 명시하지 않아 서버 재시도 예정 시각을 표시합니다."
                            style=${{padding:"var(--sp-0) var(--sp-1)",borderRadius:"var(--radius-sm)",border:"1px solid var(--line-2)",background:"var(--bg-2)",color:"var(--fg-3)",fontSize:"var(--fs-11)"}}
                          >
                            예상
                          </span>
                        `}
                      </span>
                    </button>

                    ${S&&a`
                      <div
                        data-testid=${`paused-group-body-${o.provider}`}
                        style=${{display:"flex",flexDirection:"column",gap:"var(--sp-1)",padding:"var(--sp-2) var(--sp-3)",borderTop:"1px solid var(--line-1)",borderBottomLeftRadius:"var(--radius-sm)",borderBottomRightRadius:"var(--radius-sm)",background:"var(--bg-2)"}}
                      >
                        ${o.runtimes.map(ee=>{const A=Dt(ee.quota_rest.cause),i=Yt(ee.quota_rest.until,ee.quota_rest.reset_stated,pe),p=Za(ee.id,o.provider);return a`
                            <div
                              key=${ee.id}
                              style=${{display:"flex",alignItems:"center",justifyContent:"space-between",gap:"var(--sp-2)",flexWrap:"wrap",padding:"var(--sp-1) var(--sp-2)",borderRadius:"var(--radius-sm)",background:"var(--bg-1)",border:"1px solid var(--line-1)"}}
                            >
                              <span style=${{display:"inline-flex",alignItems:"center",gap:"var(--sp-2)",flexWrap:"wrap",minWidth:0}}>
                                <span style=${{fontWeight:600,fontSize:"var(--fs-12)"}}>${ee.model||p}</span>
                                <span class="mono" title=${ee.id} style=${{fontSize:"var(--fs-11)",color:"var(--fg-3)"}}>
                                  ${p}
                                </span>
                                ${ee.is_default&&a`
                                  <span style=${{padding:"var(--sp-0) var(--sp-1)",borderRadius:"var(--radius-pill)",background:"var(--info-soft)",border:"1px solid var(--info-border)",color:"var(--info-fg)",fontSize:"var(--fs-11)",fontWeight:600}}>
                                    기본
                                  </span>
                                `}
                              </span>
                              <span class="mono tnum" style=${{display:"inline-flex",alignItems:"center",gap:"var(--sp-2)",flexWrap:"wrap",fontSize:"var(--fs-11)"}}>
                                <span style=${{...Tt(A.tone),padding:"var(--sp-0) var(--sp-2)",borderRadius:"var(--radius-pill)",fontWeight:600}}>
                                  ${A.shortLabel}
                                </span>
                                <span style=${{color:i.isSoon?"var(--ok-fg)":"var(--fg-2)"}}>
                                  ${i.countdown}${i.localTime?` (${i.localTime})`:""}
                                </span>
                                ${i.isEstimated&&a`
                                  <span style=${{padding:"var(--sp-0) var(--sp-1)",borderRadius:"var(--radius-sm)",border:"1px solid var(--line-2)",background:"var(--bg-2)",color:"var(--fg-3)"}}>
                                    예상
                                  </span>
                                `}
                              </span>
                            </div>
                          `})}

                        <div style=${{display:"flex",justifyContent:"flex-end",gap:"var(--sp-2)",paddingTop:"var(--sp-1)",flexWrap:"wrap"}}>
                          ${h&&!v&&a`
                            <button
                              type="button"
                              class="btn-ghost"
                              style=${{padding:"var(--sp-0) var(--sp-2)",fontSize:"var(--fs-11)"}}
                              onClick=${()=>e.onNavigate(`/settings?key=providers.${encodeURIComponent(o.provider)}`)}
                            >
                              설정 열기
                            </button>
                          `}
                          ${h&&X&&a`
                            <button
                              type="button"
                              class="btn-primary"
                              style=${{padding:"var(--sp-0) var(--sp-2)",fontSize:"var(--fs-11)"}}
                              onClick=${()=>J({providerId:o.provider,secret:"",mode:"api_key"})}
                            >
                              API 키 등록
                            </button>
                          `}
                        </div>
                      </div>
                    `}
                  </div>
                `})}
            </div>
          `}
        </section>
      `}

      <${rs} runtimes=${he?.runtimes??[]} nowUnix=${pe} />

      <!-- Provider Usage History UPlotChart (Strictly days=1|7|14 & HTTP 200 unavailable honesty) -->
      <section aria-label="제공자 사용량 이력">
        ${!c&&a`
          <div class="wka-card dtable-absent" data-testid="provider-usage-mode-notice" role="status">
            제공자 사용량 이력 시계열은 single_user 모드에서 제공됩니다.
          </div>
        `}
        ${c&&I.kind==="loading"&&a`
          <div class="wka-card dtable-absent">사용량 이력 불러오는 중… (${n}d)</div>
        `}
        ${c&&I.kind==="failed"&&a`
          <div class="ap-error" role="alert">사용량 이력 조회 실패: ${I.message}</div>
        `}
        ${c&&I.kind==="unavailable"&&a`
          <div
            class="wka-card"
            data-testid="provider-usage-unavailable"
            role="status"
            style=${{borderColor:"var(--warn-border)",background:"var(--warn-soft)"}}
          >
            <div style=${{fontWeight:600,color:"var(--warn-fg)",marginBottom:"var(--sp-1)"}}>
              ⚠ 제공자 사용량 이력 사용 불가 (state: unavailable)
            </div>
            <div style=${{fontSize:"var(--fs-12)",color:"var(--fg-2)"}}>
              사유: <span class="mono">${I.reason}</span>
            </div>
          </div>
        `}
        ${c&&I.kind==="ready"&&a`
          <${It}
            id="runtime-quotas-history"
            title=${`제공자 사용량 이력 & 일시 중지 추이 (${I.days}일 · ${I.pointsCount}포인트)`}
            subtitle=${I.unreadable>0||I.undecodable>0?a`<span class="mono" style=${{fontSize:"var(--fs-11)",color:"var(--warn-fg)"}}>${[I.unreadable>0?`판독 불가 보고서 ${I.unreadable}건`:null,I.undecodable>0?`읽지 못한 포인트 ${I.undecodable}건 (차트에서 빠짐)`:null].filter(o=>o!==null).join(" · ")}</span>`:a`<span class="mono" style=${{fontSize:"var(--fs-11)",color:"var(--fg-3)"}}>days=${n}</span>`}
            data=${I.data}
            series=${is}
            height=${210}
            emptyLabel="선택한 기간에 기록된 제공자 사용량 이력이 없습니다."
          />
        `}
      </section>

      <!-- 3-Tier Quota Partition -->
      <section style=${{display:"flex",flexDirection:"column",gap:"var(--sp-3)"}} aria-label="3계층 할당량 파티션">
        ${m.kind==="loading"&&a`
          <div class="wka-card dtable-absent">런타임 할당량 불러오는 중…</div>
        `}
        ${m.kind==="failed"&&a`
          <div class="ap-error" role="alert">런타임 할당량 조회 오류: ${m.error.message}</div>
        `}

        ${m.kind==="value"&&ht===0&&a`
          <div class="wka-card dtable-absent">보고된 제공자 할당량 스코프가 없습니다.</div>
        `}

        ${C.tier1ExhaustedOrCredits.length>0&&a`
          <div data-testid="quota-tier-1">
            <h2 style=${{margin:"0 0 var(--sp-2)",fontSize:"var(--fs-13)",color:"var(--err-fg)"}}>
              Tier 1 · 소진 / 크레딧 잔액 / 고사용률 (${C.tier1ExhaustedOrCredits.length})
            </h2>
            <div style=${{display:"grid",gridTemplateColumns:"repeat(auto-fill, minmax(280px, 1fr))",gap:"var(--sp-3)"}}>
              ${C.tier1ExhaustedOrCredits.map(dt)}
            </div>
          </div>
        `}

        ${C.tier2ActiveSubscriptions.length>0&&a`
          <div data-testid="quota-tier-2">
            <h2 style=${{margin:"0 0 var(--sp-2)",fontSize:"var(--fs-13)",color:"var(--ok-fg)"}}>
              Tier 2 · 활성 구독 ($0 Sub · ${C.tier2ActiveSubscriptions.length})
            </h2>
            <div style=${{display:"grid",gridTemplateColumns:"repeat(auto-fill, minmax(280px, 1fr))",gap:"var(--sp-3)"}}>
              ${C.tier2ActiveSubscriptions.map(dt)}
            </div>
          </div>
        `}

        ${C.tier3Unreported.length>0&&a`
          <div data-testid="quota-tier-3">
            <div style=${{display:"flex",alignItems:"center",justifyContent:"space-between",marginBottom:"var(--sp-2)"}}>
              <h2 style=${{margin:0,fontSize:"var(--fs-13)",color:"var(--fg-3)"}}>
                Tier 3 · 미보고 (? Unreported · ${C.tier3Unreported.length})
              </h2>
              <button
                type="button"
                class="btn-ghost"
                aria-expanded=${W}
                onClick=${()=>oe(o=>!o)}
              >
                ${W?"미보고 접기":`미보고 ${C.tier3Unreported.length}개 펼치기`}
              </button>
            </div>
            ${W&&a`
              <div style=${{display:"grid",gridTemplateColumns:"repeat(auto-fill, minmax(280px, 1fr))",gap:"var(--sp-3)"}}>
                ${C.tier3Unreported.map(dt)}
              </div>
            `}
          </div>
        `}
      </section>

      <!-- Inline Credential Form & CLI OAuth Receipt -->
      ${h&&Ie&&a`
        <form class="wka-card" onSubmit=${pt} style=${{display:"flex",flexDirection:"column",gap:"var(--sp-3)",borderColor:"var(--line-2)"}}>
          <div class="wka-h">
            <h3>제공자 API 키 등록 / 갱신 (${d?"개인 계정":"워크스페이스"})</h3>
            <button type="button" class="btn-ghost" onClick=${()=>J(null)}>닫기</button>
          </div>
          <div style=${{display:"grid",gridTemplateColumns:"repeat(auto-fit, minmax(200px, 1fr))",gap:"var(--sp-2)"}}>
            <label style=${{display:"flex",flexDirection:"column",gap:"var(--sp-1)",fontSize:"var(--fs-12)"}}>
              <span>제공자 ID</span>
              <input
                type="text"
                value=${Ie.providerId}
                onInput=${o=>{const S=o.target.value;J(y=>y&&{...y,providerId:S})}}
                style=${{padding:"var(--sp-1) var(--sp-2)",background:"var(--input-bg)",border:"1px solid var(--input-border)",borderRadius:"var(--radius-sm)"}}
                required
              />
            </label>
            <label style=${{display:"flex",flexDirection:"column",gap:"var(--sp-1)",fontSize:"var(--fs-12)"}}>
              <span>API 키 / 시크릿</span>
              <input
                type="password"
                autocomplete="off"
                placeholder="sk-..."
                value=${Ie.secret}
                onInput=${o=>{const S=o.target.value;J(y=>y&&{...y,secret:S})}}
                style=${{padding:"var(--sp-1) var(--sp-2)",background:"var(--input-bg)",border:"1px solid var(--input-border)",borderRadius:"var(--radius-sm)"}}
                required
              />
            </label>
          </div>
          <div style=${{display:"flex",gap:"var(--sp-2)"}}>
            <button type="submit" class="btn-primary" disabled=${ge==="save-cred"}>
              ${ge==="save-cred"?"저장 중…":"저장"}
            </button>
            <button
              type="button"
              class="btn-ghost"
              onClick=${()=>{Se(Ie.providerId)}}
              disabled=${ge!==null}
            >
              CLI OAuth 로그인 시작
            </button>
          </div>
        </form>
      `}

      ${h&&L&&a`
        <section
          class="wka-card"
          data-testid="setup-login-panel"
          style=${{borderColor:"var(--info-border)",background:"var(--info-soft)",display:"flex",flexDirection:"column",gap:"var(--sp-2)"}}
        >
          <div class="wka-h">
            <h3>CLI OAuth 로그인 스트림 · ${L.integrationId}</h3>
            <div style=${{display:"flex",gap:"var(--sp-2)"}}>
              ${L.streaming&&a`
                <button type="button" class="btn-ghost" style=${{color:"var(--err-fg)"}} onClick=${()=>{Fe()}}>
                  로그인 취소
                </button>
              `}
              <button
                type="button"
                class="btn-ghost"
                onClick=${()=>{De.current?.abort("dismissed"),F(null)}}
              >
                닫기
              </button>
            </div>
          </div>

          <div class="mono" style=${{fontSize:"var(--fs-12)",display:"flex",flexWrap:"wrap",gap:"var(--sp-3)"}}>
            <span>login_id: ${L.loginId||"연결 중…"}</span>
            <span>상태: ${L.status}${L.streaming?" (SSE 실시간)":""}</span>
            ${L.authentication&&a`<span>인증: ${L.authentication}</span>`}
            ${L.accountRef&&a`<span>ref: ${L.accountRef.slice(0,12)}…</span>`}
          </div>

          ${(L.authUrl||L.deviceCode)&&a`
            <div style=${{display:"flex",alignItems:"center",gap:"var(--sp-2)",flexWrap:"wrap",padding:"var(--sp-2)",borderRadius:"var(--radius-sm)",background:"var(--bg-1)",border:"1px solid var(--line-2)"}}>
              ${L.authUrl&&a`
                <a
                  href=${L.authUrl}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="btn-primary"
                  data-testid="setup-login-auth-url"
                >
                  OAuth 인증 페이지 열기 ↗
                </a>
              `}
              ${L.deviceCode&&a`
                <span class="mono" data-testid="setup-login-device-code" style=${{padding:"var(--sp-1) var(--sp-2)",borderRadius:"var(--radius-sm)",background:"var(--brass-soft)",color:"var(--brass-1)",fontWeight:700,fontSize:"var(--fs-13)"}}>
                  ${L.deviceCode}
                </span>
                <button
                  type="button"
                  class="btn-ghost"
                  onClick=${()=>{const o=L.deviceCode??"";ga(o).then(S=>{Y.current&&(S?He(!0):E({kind:"err",text:"클립보드 복사에 실패했습니다. 코드를 직접 선택해 복사하세요."}))})}}
                >
                  ${Be?"복사됨 ✓":"코드 복사"}
                </button>
              `}
              ${L.popupBlocked&&a`
                <span style=${{fontSize:"var(--fs-11)",color:"var(--warn-fg)"}}>
                  브라우저 팝업이 차단되었습니다 — 위 버튼을 직접 클릭하세요.
                </span>
              `}
            </div>
          `}

          ${L.inputReady&&L.loginId&&a`
            <form
              data-testid="setup-login-input-form"
              onSubmit=${vt}
              style=${{display:"flex",gap:"var(--sp-2)",flexWrap:"wrap",alignItems:"center"}}
            >
              <input
                type="text"
                aria-label="CLI 로그인 응답 입력"
                placeholder="인증 코드 또는 응답을 입력하세요…"
                value=${ke}
                onInput=${o=>at(o.target.value)}
                class="mono"
                style=${{flex:"1 1 220px",minWidth:0,padding:"var(--sp-1) var(--sp-2)",background:"var(--input-bg)",border:"1px solid var(--input-border)",borderRadius:"var(--radius-sm)"}}
              />
              <button type="submit" class="btn-primary" disabled=${ge==="login-input"||!ke.trim()}>
                응답 전송
              </button>
              <button type="button" class="btn-ghost" disabled=${ge==="login-input"} onClick=${()=>{it()}}>
                Enter 전송
              </button>
            </form>
          `}

          ${L.outputTail&&a`
            <details>
              <summary style=${{cursor:"pointer",fontSize:"var(--fs-11)",color:"var(--fg-2)"}}>CLI 로그인 출력 로그</summary>
              <pre class="mono" style=${{margin:"var(--sp-1) 0 0",padding:"var(--sp-2)",background:"var(--bg-0)",border:"1px solid var(--line-1)",borderRadius:"var(--radius-sm)",fontSize:"var(--fs-11)",maxHeight:"180px",overflow:"auto",whiteSpace:"pre-wrap"}}>
                ${L.outputTail}
              </pre>
            </details>
          `}

          <div style=${{display:"flex",gap:"var(--sp-2)"}}>
            ${L.loginId&&a`
              <${wt} label="영수증 상태 새로고침" onRefresh=${ut} />
            `}
            ${d&&L.accountRef&&a`
              <button
                type="button"
                class="btn-primary"
                onClick=${()=>{de(L.integrationId,L.accountRef??void 0)}}
              >
                계정 검증
              </button>
            `}
          </div>
        </section>
      `}

      <!-- Provider Credentials & OAuth Inventory (default-collapsed via .ap-disclosure) -->
      <section class="ap-disclosure" data-testid="provider-inventory-disclosure" aria-label="제공자 자격 증명 목록">
        <button
          type="button"
          class="ap-disclosure-trigger"
          data-testid="provider-inventory-toggle"
          aria-expanded=${ae}
          onClick=${()=>Ae(o=>!o)}
        >
          <span>
            ${d?`내 제공자 계정 (${R.length}개 계정)`:`제공자 연동 & 자격 증명 (${u.length}개 제공자 · 활성 ${zt})`}
          </span>
          <span aria-hidden="true">${ae?"▾":"▸"}</span>
        </button>

        ${ae&&a`
          <div class="ap-disclosure-body" data-testid="provider-inventory-body">
            ${T.kind==="failed"&&a`
              <div class="ap-error" role="alert">제공자 자격 증명 조회 실패: ${T.error.message}</div>
            `}
            ${d&&ue.kind==="failed"&&a`
              <div class="ap-error" role="alert">제공자 연동 목록 조회 실패: ${ue.error.message}</div>
            `}
            ${d&&a`
              <div style=${{display:"flex",alignItems:"center",gap:"var(--sp-2)",flexWrap:"wrap"}}>
                <label style=${{fontSize:"var(--fs-12)",color:"var(--fg-2)"}}>검증용 모델 (선택 시 우선 적용):</label>
                <input
                  type="text"
                  aria-label="검증할 모델 ID"
                  placeholder="예: gpt-5-codex (비우면 통합 기본 모델)"
                  value=${K}
                  onInput=${o=>_e(o.target.value)}
                  class="mono"
                  style=${{flex:"1 1 200px",minWidth:0,minHeight:"var(--btn-h, 32px)",padding:"var(--sp-1) var(--sp-2)",background:"var(--input-bg)",border:"1px solid var(--input-border)",borderRadius:"var(--radius-sm)",fontSize:"var(--fs-12)"}}
                />
              </div>
            `}

            ${d?R.length===0?T.kind==="failed"?null:a`<div class="dtable-absent">${T.kind==="loading"?"불러오는 중…":"연결된 개인 제공자 계정이 없습니다."}</div>`:a`
                    <div style=${{display:"flex",flexDirection:"column",gap:"var(--sp-2)"}}>
                      ${R.map((o,S)=>{const y=o.integration_id??o.provider??o.provider_account_id??o.id??`acct-${S}`,X=o.provider_account_id??o.account_ref??o.id??y,M=o.removal?`removal:${o.removal}`:o.replacement?`replacement:${o.replacement}`:o.key?`${o.kind??"key"} (${o.key})`:o.status??(o.kind==="login"?"login":o.verified?"verified":"active");return a`
                          <div key=${X} style=${{display:"flex",alignItems:"center",justifyContent:"space-between",gap:"var(--sp-2)",padding:"var(--sp-2)",border:"1px solid var(--line-1)",borderRadius:"var(--radius-sm)",flexWrap:"wrap"}}>
                            <div>
                              <div style=${{fontWeight:600,fontSize:"var(--fs-13)"}}>${o.display_name??o.label??y}</div>
                              <div class="mono" style=${{fontSize:"var(--fs-11)",color:"var(--fg-3)"}}>
                                ${X} · ${M}
                              </div>
                            </div>
                            <div style=${{display:"flex",gap:"var(--sp-1)",flexWrap:"wrap"}}>
                              <button type="button" class="btn-ghost" onClick=${()=>{de(y,o.provider_account_id??o.account_ref)}}>검증</button>
                              <button type="button" class="btn-ghost" onClick=${()=>{Se(y)}}>Re-auth</button>
                              ${o.kind!=="login"&&a`
                                <button type="button" class="btn-ghost" onClick=${()=>{lt(X)}} style=${{color:"var(--err-fg)"}}>제거</button>
                              `}
                            </div>
                          </div>
                        `})}
                    </div>
                  `:c?v?a`<div class="dtable-absent" data-testid="provider-inventory-admin-locked" role="status">워크스페이스 제공자 자격 증명 관리는 관리자 전용입니다.</div>`:u.length===0?T.kind==="failed"?null:a`<div class="dtable-absent">${T.kind==="loading"?"불러오는 중…":"등록된 제공자 인벤토리가 없습니다."}</div>`:a`
                      <div style=${{display:"grid",gridTemplateColumns:"repeat(auto-fill, minmax(290px, 1fr))",gap:"var(--sp-2)"}}>
                        ${u.map(o=>a`
                          <div key=${o.id} style=${{display:"flex",flexDirection:"column",gap:"var(--sp-2)",padding:"var(--sp-2)",border:"1px solid var(--line-1)",borderRadius:"var(--radius-sm)",background:"var(--bg-2)"}}>
                            <div style=${{display:"flex",justifyContent:"space-between",gap:"var(--sp-2)"}}>
                              <div>
                                <div style=${{fontWeight:600,fontSize:"var(--fs-13)"}}>${o.display_name}</div>
                                <div class="mono" style=${{fontSize:"var(--fs-11)",color:"var(--fg-3)"}}>
                                  ${o.id} · ${o.credential_kind??o.protocol??"없음"}
                                </div>
                                ${rn(x.get(o.id))!==null&&a`
                                  <div data-testid="provider-account-line" class="mono" style=${{fontSize:"var(--fs-11)",color:"var(--fg-2)"}}>
                                    ${rn(x.get(o.id))}
                                  </div>
                                `}
                              </div>
                              <span class="mono" style=${{fontSize:"var(--fs-11)",color:o.enabled===!1?"var(--fg-4)":"var(--ok-fg)"}}>
                                ${o.enabled===!1?"비활성":"활성"}
                              </span>
                            </div>
                            <div style=${{display:"flex",gap:"var(--sp-1)",flexWrap:"wrap"}}>
                              <button type="button" class="btn-ghost" onClick=${()=>J({providerId:o.id,secret:"",mode:"api_key"})}>
                                API 키
                              </button>
                              <button type="button" class="btn-ghost" onClick=${()=>{Se(o.id)}}>
                                CLI OAuth
                              </button>
                              ${!v&&a`
                                <button type="button" class="btn-ghost" onClick=${()=>e.onNavigate(`/settings?key=providers.${encodeURIComponent(o.id)}`)}>
                                  Open Config Key
                                </button>
                              `}
                            </div>
                          </div>
                        `)}
                      </div>
                    `:a`<div class="dtable-absent">로그인된 세션에서만 제공자 자격 증명을 관리할 수 있습니다.</div>`}
          </div>
        `}
      </section>
    </div>
  `}function ps(e){if(e.status==="running")return"running";switch(e.runKind){case"exact_output":return e.status==="succeeded"?"passed":"not_passed";case"task_verification":return e.status==="approved"?"passed":"not_passed";case"goal_verification":return e.status==="committed"?"passed":"not_passed"}}function Rn(e){if(e.runKind!=="exact_output")return null;const{persistenceState:t,persistenceError:n,intendedStatus:r}=e;return t===void 0||n===void 0||r===void 0?null:{persistenceState:t,persistenceError:n,intendedStatus:r,intendedCode:e.intendedCode??null,intendedDetail:e.intendedDetail??null}}function vs(e){switch(e){case"not_persisted":return"완료 기록을 저장하지 못함";case"durability_unknown":return"완료 기록이 저장됐는지 모름"}}function fs(e){switch(e){case"24h":return{windowMinutes:1440,bucketMinutes:60,sinceHours:24,bucket:"hour"};case"7d":return{windowMinutes:10080,bucketMinutes:360,sinceHours:168,bucket:"day"};case"30d":return{windowMinutes:10080,bucketMinutes:720,sinceHours:720,bucket:"day"}}}const ms=[{label:"프롬프트 캐시 적중률 (%)",colorToken:"--ok-fg",width:2,fillAlpha:.16,unit:"%"}],gs=[{label:"처리량 (요청/버킷)",colorToken:"--info-fg",width:2,fillAlpha:.12},{label:"보고 비용 ($ × 100 센트)",colorToken:"--brass-1",width:2,unit:"¢"}],$s=[{label:"피크 할당량 사용률 (%)",colorToken:"--warn-fg",width:2,fillAlpha:.14,unit:"%"},{label:"429 / 소진 카운트",colorToken:"--err-fg",width:1.75,dash:[4,3]}],bs=[{label:"도구 오류율 (%)",colorToken:"--err-fg",width:2,fillAlpha:.12,unit:"%"},{label:"도구 호출량 (÷10)",colorToken:"--info-fg",width:1.5,dash:[3,3]}];function hs(e){if(!e)return[];const t=new Map;for(const n of e.models)for(const r of n.buckets){const l=t.get(r.ts_start)??{entries:0,cost:0,costReports:0,costUnknown:0,modelBuckets:0,pairedInputTokens:0,pairedCacheReadTokens:0,pairedSamples:0,expectedSamples:0,legacyCacheRatios:[]};l.modelBuckets+=1,l.entries+=r.entry_count,l.expectedSamples+=Math.max(0,r.success_count??r.entry_count),typeof r.total_cost_usd=="number"&&Number.isFinite(r.total_cost_usd)?(l.cost+=r.total_cost_usd,l.costReports+=1):l.costUnknown+=1,r.cached_input?(l.pairedInputTokens+=r.cached_input.input_tokens,l.pairedCacheReadTokens+=r.cached_input.cache_read_tokens,l.pairedSamples+=r.cached_input.sample_count):typeof r.cache_hit_ratio=="number"&&Number.isFinite(r.cache_hit_ratio)&&l.legacyCacheRatios.push(Math.min(1,Math.max(0,r.cache_hit_ratio))*100),t.set(r.ts_start,l)}return[...t.entries()].sort((n,r)=>n[0]-r[0]).map(([n,r])=>({ts:n,entries:r.entries,costUsd:r.costReports>0&&r.costUnknown===0?r.cost:null,costCoverage:r.costReports===0?"unreported":r.costUnknown>0?"partial":"reported",cacheHitPct:r.pairedInputTokens>0?Number((r.pairedCacheReadTokens*100/r.pairedInputTokens).toFixed(1)):r.modelBuckets===1&&r.legacyCacheRatios.length===1?Number(r.legacyCacheRatios[0].toFixed(1)):null,cacheReportedSamples:r.pairedInputTokens>0?r.pairedSamples:null,cacheExpectedSamples:r.pairedInputTokens>0?r.expectedSamples:null,cacheSource:r.pairedInputTokens>0?"paired":r.modelBuckets===1&&r.legacyCacheRatios.length===1?"legacy_single_model":"unreported"}))}function ys(e){let t=0,n=0,r=0,l=0;for(const d of e){l+=Math.max(0,d.success_count??d.entry_count);const c=d.cached_input;c&&(t+=c.input_tokens,n+=c.cache_read_tokens,r+=c.sample_count)}return{hitPct:t>0?Math.min(100,n/t*100):null,reportedSamples:r,expectedSamples:l}}function ks(e){let t=0,n=0,r=0,l=0;for(const d of e){const c=d.success_count;if(typeof c!="number"||!Number.isSafeInteger(c)||c<0){l+=1;continue}c!==0&&(r+=1,!(typeof d.total_cost_usd!="number"||!Number.isFinite(d.total_cost_usd))&&(t+=d.total_cost_usd,n+=1))}return{reportedUsd:t,reportedSuccessModels:n,successModels:r,unknownSuccessModels:l,hasReported:n>0}}function xs(e){const t=e.filter(r=>r.cacheSource==="paired"),n=e.filter(r=>r.cacheSource==="legacy_single_model").length;if(t.length>0){const r=t.reduce((d,c)=>d+(c.cacheReportedSamples??0),0),l=t.reduce((d,c)=>d+(c.cacheExpectedSamples??0),0);return`paired 보고가 있는 구간 내 ${r}/${l} 샘플${n>0?` · 구형 단일 모델 버킷 ${n}개`:""}`}return n>0?`구형 단일 모델 비율 ${n}개 · 표본 커버리지 미확인`:"paired 입력 없음 · 복수 모델의 구형 비율은 합산하지 않음"}function _s(e){const t=vn.value,n=be.value,r=Wt(n),l=n.kind==="multi_account_signed_in",d=ot("admin",n),c=gn(n),v=r?zn.value:null,h=tt.value,m=fs(t),k=En(t),[q,z]=_(null),[T,ue]=_(!1),[W,oe]=_(null),[fe,U]=_(null),ae=Me(null),Ae=Un(),O=`runtime:models-metrics:${t}`,te="runtime:cache-stats",Ee=`runtime:provider-usage-history:${k}`,je=`runtime:tool-series-snap:${t}`,ze="runtime:exact-runs-snap",Ke="runtime:keeper-costs:24h",pe="runtime:keeper-efficiency",G=N.observe(O).value,Ie=N.observe(te).value,J=N.observe(Ee).value,K=N.observe(je).value,_e=N.observe(ze).value,L=N.observe(Ke).value,F=N.observe(pe).value,ge=(u="mount")=>{const R=be.peek();if(!oa(R))return Promise.resolve();const I=Wt(R),w=h,Q=[N.fetch(te,V=>$e("/api/v1/dashboard/cache-stats",{signal:V}),{ttlMs:15e3,topics:["cache_stats","model_metrics","telemetry"],reason:u})];return ot("admin",R)||Q.push(N.fetch(ze,V=>Bn({limit:50},V),{ttlMs:2e4,topics:["exact_lane_runs","verification_requests"],reason:u})),I&&(Q.push(N.fetch(O,V=>$e(`/api/v1/models/metrics?window=${m.windowMinutes}&bucket_min=${m.bucketMinutes}`,{signal:V,decode:yn}),{ttlMs:2e4,topics:["model_metrics","telemetry"],reason:u}),N.fetch(Ee,V=>Nn(k,V),{ttlMs:3e4,topics:["provider_usage","runtime_resolved"],reason:u}),N.fetch(je,V=>$e(`/api/v1/tool-metrics/series?since_hours=${m.sinceHours}&bucket=${m.bucket}&utc_offset_min=${Ae}`,{signal:V,decode:cn}),{ttlMs:2e4,topics:["tool_metrics","telemetry"],reason:u}),N.fetch(Ke,V=>$e("/api/v1/dashboard/keeper-costs?window=1440",{signal:V,decode:La}),{ttlMs:2e4,topics:["keeper_costs","model_metrics","keeper_turn_complete","cost"],reason:u})),gn(R)&&Q.push(N.fetch(pe,V=>$e("/api/v1/keeper-efficiency",{signal:V,decode:Ea}),{ttlMs:6e4,topics:["keeper_efficiency","model_metrics","keeper_turn_complete","cost"],reason:u}))),Promise.all(Q).then(()=>{Z(w)&&Lt()})};ve(()=>{z(null),oe(null),ge("mount")},[t,h,n.kind,r,d,c]),ve(()=>{if(U(null),t!=="24h"||!v){ue(!1);return}const u=Dn("runtime-efficiency",R=>{qn("/api/v1/models/metrics/stream?window=1440&bucket_min=60",R,I=>{if(I.data&&typeof I.data=="object"){const w=I.data;if(typeof w.error=="string"&&w.error.trim().length>0){ue(!1),oe(w.error.trim());return}if("models"in w)try{const Q=yn(I.data);z(Q),oe(null),U(null),ue(!0)}catch(Q){U(Q instanceof Error?Q.message:String(Q))}}},(I,w)=>{ue(I==="open"),I==="error"&&w&&oe(w)})});return()=>{u.release()}},[t,v,h]),ve(()=>{const u=new Set(["provider_usage","tool_metrics","exact_lane_runs","model_metrics","telemetry","runtime_resolved","keeper_turn_complete","keeper_turns","dataset_invalidation"]),R=At(V=>{Et(V).some(We=>u.has(We))&&(ae.current!==null&&clearTimeout(ae.current),ae.current=setTimeout(()=>{ge("sse")},600))}),I=()=>{Z(h)&&ge("sse")},w=Kt(I),Q=Ot(I);return()=>{R(),w(),Q(),ae.current!==null&&clearTimeout(ae.current)}},[t,h,n.kind,r,d,c]);const j=r?t==="24h"&&v&&q?q:G.kind==="value"?G.data:null:null,Oe=r&&t==="24h"&&v!==null&&T,E=r?W??(j?null:Kn(G)):null,re=t==="30d"?"7d 상한":t,ye=r?Oe?"● LIVE SSE (models/metrics/stream)":W?`○ STREAM ERROR (${W})`:E?"○ UNAVAILABLE":G.kind==="loading"&&!j?"◐ LOADING":`○ SNAPSHOT (${re})`:"○ SINGLE-USER ONLY",Y=ce(()=>hs(j),[j]),Re=ce(()=>xs(Y),[Y]),ie=ce(()=>Y.length===0?[[],[]]:[Y.map(u=>u.ts),Y.map(u=>u.cacheHitPct)],[Y]),he=ce(()=>Y.length===0?[[],[],[]]:[Y.map(u=>u.ts),Y.map(u=>u.entries),Y.map(u=>u.costUsd===null?null:Number((u.costUsd*100).toFixed(2)))],[Y]),Ge=ce(()=>{if(J.kind!=="value"||J.data.state==="unavailable")return[[],[],[]];const u=Gn(J.data.points);return[u[0],u[2]??[],u[3]??[]]},[J]),Ce=ce(()=>{if(K.kind!=="value")return[[],[],[]];const u=[],R=[],I=[];for(const w of K.data.buckets??[]){u.push(w.start);const Q=Math.max(0,w.call_count-(w.deferred_count??0)),V=Q>0?Number((w.failure_count/Q*100).toFixed(1)):null;R.push(V),I.push(Number((w.call_count/10).toFixed(1)))}return[u,R,I]},[K]),me=ce(()=>{const u=ys(j?.models??[]),R=ks(j?.models??[]),I=u.hitPct!==null?Ze(u.hitPct):!j&&G.kind==="failed"?jt(G.error):!j&&G.kind==="loading"?Vt():et(),w=R.hasReported?Ze(R.reportedUsd):!j&&G.kind==="failed"?jt(G.error):!j&&G.kind==="loading"?Vt():et(),We=(!d&&_e.kind==="value"?_e.data.runs??[]:[]).map(ps).filter(De=>De!=="running"),Ve=We.filter(De=>De==="passed"),ct=We.length>0?Ze(Ve.length/We.length*100):!d&&_e.kind==="failed"?jt(_e.error):!d&&_e.kind==="loading"?Vt():$n(),Ye=K.kind==="value"?K.data.total:null,nt=Ye?Math.max(0,Ye.call_count-(Ye.deferred_count??0)):0,pt=Ye&&nt>0?Ze(Ye.failure_count/nt*100):K.kind==="failed"?jt(K.error):K.kind==="loading"?Vt():Ye?et():$n();return{cacheHitObs:I,spendObs:w,exactPassObs:ct,toolErrObs:pt,cacheCoverage:u,costCoverage:R}},[j,G,_e,K,d]),g=ce(()=>{const u=new Map,R=new Map;if(F.kind==="value")for(const w of F.data.keepers??[])R.set(w.keeper,w);const I=w=>w?typeof w.cache_hit_pct=="number"&&Number.isFinite(w.cache_hit_pct)?Ze(Math.min(100,Math.max(0,w.cache_hit_pct))):w.cache_hit_pct===null?et():typeof w.cache_read_tokens=="number"&&w.input_tokens>0?Ze(Math.min(100,w.cache_read_tokens/w.input_tokens*100)):et():et();if(L.kind==="value")for(const w of L.data.keepers??[]){const Q=R.get(w.keeper_name);u.set(w.keeper_name,{keeper:w.keeper_name,turns:Q?Ze(Q.turns):et(),totalTokens:w.tokens_reported_samples>0&&w.total_tokens!==null?Ze(w.total_tokens):et(),cacheHitPct:I(Q),spendUsd:w.cost_reported_samples>0&&w.total_cost_usd!==null?Ze(w.total_cost_usd):et(),toolCalls:Q?Ze(Q.calls):et(),toolErrors:Q?Ze(Q.failed):et(),p95LatencyMs:Ft(w.p95_latency_ms,!0)})}if(F.kind==="value")for(const w of F.data.keepers??[])u.has(w.keeper)||u.set(w.keeper,{keeper:w.keeper,turns:Ze(w.turns),totalTokens:et(),cacheHitPct:I(w),spendUsd:et(),toolCalls:Ze(w.calls),toolErrors:Ze(w.failed),p95LatencyMs:et()});return[...u.values()]},[L,F]),C=ce(()=>[{id:"keeper",header:"Keeper",width:"20.5rem",sortable:!0,sortValue:u=>u.keeper,cell:u=>a`<${Xt} id=${u.keeper} size="sm" />`},{id:"turns",header:"월간 턴",width:"4.5rem",numeric:!0,sortable:!0,observed:u=>u.turns,formatValue:u=>Rt(Number(u))},{id:"tokens",header:"토큰 (24h)",width:"6rem",numeric:!0,sortable:!0,observed:u=>u.totalTokens,formatValue:u=>Rt(Number(u))},{id:"cacheHit",header:"월간 캐시 %",width:"6rem",numeric:!0,sortable:!0,observed:u=>u.cacheHitPct,formatValue:u=>Pt(Number(u))},{id:"spend",header:"비용 (24h USD)",width:"7.75rem",numeric:!0,sortable:!0,observed:u=>u.spendUsd,formatValue:u=>hn(Number(u))},{id:"tools",header:"월간 도구 호출",width:"6.75rem",numeric:!0,sortable:!0,observed:u=>u.toolCalls,formatValue:u=>Rt(Number(u))},{id:"errors",header:"월간 도구 실패",width:"6.75rem",numeric:!0,sortable:!0,observed:u=>u.toolErrors,formatValue:u=>Rt(Number(u))},{id:"p95",header:"p95 지연 (24h)",width:"7.75rem",numeric:!0,sortable:!0,observed:u=>u.p95LatencyMs,formatValue:u=>Zt(Number(u))}],[]),x=Ie.kind==="value"?Ie.data:null;return a`
    <div class="ov" data-testid="runtime-efficiency-tab">
      <header class="ov-head">
        <div>
          <span class="ov-eyebrow">5 RUNTIME · EFFICIENCY & CACHE</span>
          <h1>프롬프트 캐시 · 토큰 속도 · 4패널 상관 피드백 루프</h1>
          <p class="ov-sub">
            공유 크로스헤어 (<span class="mono">masc-telemetry</span>) · 2+1 SSE 규율 준수
          </p>
        </div>
        <div style=${{display:"flex",alignItems:"center",gap:"var(--sp-2)",flexWrap:"wrap"}}>
          <${wt} onRefresh=${()=>ge("manual")} />
        </div>
      </header>

      ${l&&a`
        <div class="wka-card" data-testid="efficiency-mode-notice" role="status" style=${{fontSize:"var(--fs-12)",color:"var(--fg-2)"}}>
          멀티 계정 모드에서는 API 캐시 통계와 Exact-Output 지표(관리자 전용)만 브리지됩니다. 모델·도구·Keeper 비용 시계열은 single_user 모드에서 제공됩니다.
        </div>
      `}

      ${fe&&a`
        <div class="ap-error" role="alert">실시간 모델 지표 디코드 오류: ${fe}</div>
      `}

      <section class="ov-kpis" aria-label="효율성 핵심 지표">
        <div class="ov-kpi">
          <div class="ov-kpi-k">프롬프트 캐시 적중률 (paired 입력)</div>
          <div class="ov-kpi-v ok">${rt(me.cacheHitObs,u=>Pt(u))}</div>
          ${me.cacheCoverage.expectedSamples>0&&a`<div class="ov-sub" data-testid="efficiency-cache-coverage">캐시 telemetry ${me.cacheCoverage.reportedSamples}/${me.cacheCoverage.expectedSamples} 샘플</div>`}
        </div>
        <div class="ov-kpi">
          <div class="ov-kpi-k">보고된 비용 합계 (${re})</div>
          <div class="ov-kpi-v volt">${rt(me.spendObs,u=>hn(u))}</div>
          ${me.costCoverage.successModels+me.costCoverage.unknownSuccessModels>0&&a`<div class="ov-sub" data-testid="efficiency-cost-coverage">성공 기록 기준 · 비용 보고 ${me.costCoverage.reportedSuccessModels}/${me.costCoverage.successModels} 성공 모델${me.costCoverage.unknownSuccessModels>0?` · 성공 수 미확인 ${me.costCoverage.unknownSuccessModels}개 모델`:""} · 전체 여부 미확인</div>`}
        </div>
        <div class="ov-kpi">
          <div class="ov-kpi-k">도구 오류율</div>
          <div class=${`ov-kpi-v ${me.toolErrObs.kind==="value"&&me.toolErrObs.data>5?"bad":""}`}>
            ${rt(me.toolErrObs,u=>Pt(u))}
          </div>
        </div>
        <div class="ov-kpi">
          <div class="ov-kpi-k">Exact-Output 통과율</div>
          <div class=${`ov-kpi-v ${d?"":"ok"}`} data-testid="efficiency-exact-pass-kpi">
            ${d?"관리자 전용":rt(me.exactPassObs,u=>Pt(u))}
          </div>
        </div>
      </section>

      <!-- 4-Panel Synchronized uPlot Suite (balanced 2x2 on >=1024px) -->
      <section
        class="uplot-grid-2x2"
        aria-label="4패널 동기화 텔레메트리 차트"
      >
        <!-- Panel 1: Prompt Cache Hit % & Savings -->
        <${It}
          id="eff-panel-1-cache"
          title="1. Prompt Cache Hit % & 대시보드 캐시"
          subtitle=${x?a`<span class="mono tnum" style=${{fontSize:"var(--fs-11)",color:"var(--fg-3)"}}>
                ${Re} · API 캐시 적중 ${(x.hit_ratio*100).toFixed(1)}% · 항목 ${x.entries}/${x.max_entries} (신선 ${x.fresh})
              </span>`:a`<span class="mono" style=${{fontSize:"var(--fs-11)",color:"var(--fg-3)"}}>${Re} · 스냅샷</span>`}
          data=${ie}
          series=${ms}
          height=${190}
          syncCrosshair=${!0}
          emptyLabel=${E?`모델 지표 조회 실패: ${E}`:G.kind==="loading"?"모델 지표 불러오는 중…":"캐시 적중률 버킷 없음"}
        />

        <!-- Panel 2: Token Velocity vs Spend -->
        <${It}
          id="eff-panel-2-velocity"
          title="2. Token Velocity vs Spend"
          subtitle=${a`<span
            class="mono"
            data-testid="efficiency-stream-badge"
            style=${{fontSize:"var(--fs-11)",color:Oe?"var(--ok-fg)":"var(--fg-3)"}}
          >${ye}</span><span class="mono" style=${{fontSize:"var(--fs-11)",color:"var(--fg-3)"}}>
            · 구간 기록 기준 보고 비용 · 전체 여부 미확인 (미보고 버킷은 공백)
          </span>`}
          data=${he}
          series=${gs}
          height=${190}
          syncCrosshair=${!0}
          emptyLabel=${E?`모델 지표 조회 실패: ${E}`:G.kind==="loading"?"모델 지표 불러오는 중…":"토큰 속도/비용 버킷 없음"}
        />

        <!-- Panel 3: 429 / Quota Cooldown Pressure -->
        <${It}
          id="eff-panel-3-cooldown"
          title="3. 429 / Quota Cooldown Pressure"
          subtitle=${a`<button type="button" class="btn-ghost" style=${{padding:"var(--sp-0) var(--sp-1)",fontSize:"var(--fs-11)"}} onClick=${()=>e.onNavigate("/runtime/quotas")}>
            Quotas →
          </button>`}
          data=${Ge}
          series=${$s}
          height=${190}
          syncCrosshair=${!0}
          emptyLabel=${J.kind==="failed"?`사용량 이력 조회 실패: ${J.error.message}`:J.kind==="loading"?"사용량 이력 불러오는 중…":J.kind==="value"&&J.data.state==="unavailable"?`사용량 이력 불가: ${J.data.reason}`:"일시 중지 이력 없음"}
        />

        <!-- Panel 4: Tool Error Rate & Call Volume -->
        <${It}
          id="eff-panel-4-tools-exact"
          title="4. Tool Error Rate & Call Volume"
          subtitle=${a`
            <div style=${{display:"flex",gap:"var(--sp-1)"}}>
              <button type="button" class="btn-ghost" style=${{padding:"var(--sp-0) var(--sp-1)",fontSize:"var(--fs-11)"}} onClick=${()=>e.onNavigate("/runtime/tools")}>
                Tools →
              </button>
              <button type="button" class="btn-ghost" style=${{padding:"var(--sp-0) var(--sp-1)",fontSize:"var(--fs-11)"}} onClick=${()=>e.onNavigate("/runtime/lanes")}>
                Lanes →
              </button>
            </div>
          `}
          data=${Ce}
          series=${bs}
          height=${190}
          syncCrosshair=${!0}
          emptyLabel=${K.kind==="failed"?`도구 시계열 조회 실패: ${K.error.message}`:"도구 오류 시계열 없음"}
        />
      </section>

      <!-- Virtualized Keeper Spend & Prompt Cache Outcomes Table -->
      <section style=${{display:"flex",flexDirection:"column",gap:"var(--sp-2)",minWidth:0}}>
        <div class="wka-h">
          <h3>Keeper별 24h 비용 · 월간 프롬프트 캐시 성과 (${g.length})</h3>
          <span class="mono" style=${{fontSize:"var(--fs-11)",color:"var(--fg-3)"}}>
            비용은 24h 상한 창 · 미보고 구독 비용은 0이 아닌 "미보고"로 표기
          </span>
        </div>
        ${(L.kind==="failed"||F.kind==="failed")&&a`
          <div class="ap-error" role="alert">
            ${L.kind==="failed"?`Keeper 비용 조회 실패: ${L.error.message}`:""}
            ${L.kind==="failed"&&F.kind==="failed"?" · ":""}
            ${F.kind==="failed"?`Keeper 효율 조회 실패: ${F.error.message}`:""}
          </div>
        `}
        <${Ut}
          data=${g}
          columns=${C}
          getRowId=${u=>u.keeper}
          virtualizeThreshold=${30}
          maxHeight=${420}
          caption="Keeper 비용 및 프롬프트 캐시 효율"
          emptyLabel=${L.kind==="loading"?"불러오는 중…":"기록된 Keeper 비용 데이터가 없습니다."}
        />
      </section>
    </div>
  `}sa(0);const ws=["simple","refine","conditional","judge_of_judges","staged_judge_of_judges"];function St(e,t,n=!1){if(typeof e!="number"||!Number.isFinite(e)||e<0||n&&!Number.isInteger(e))throw new Error(`Invalid Fusion ${t}`);return e}function Ss(e){if(!nn(e))throw new Error("Invalid Fusion replay observation");switch(e.status){case"not_replayed":case"absent":return{status:e.status};case"complete":case"incomplete":return{status:e.status,linesRead:St(e.lines_read,"replay.lines_read",!0),malformedLines:St(e.malformed_lines,"replay.malformed_lines",!0),droppedRunning:St(e.dropped_running,"replay.dropped_running",!0)};default:throw new Error("Unknown Fusion replay status")}}function Cs(e){if(!Array.isArray(e))throw new Error("Invalid Fusion historical evidence list");return e.map(t=>{if(!nn(t)||typeof t.run_id!="string"||!t.run_id.trim()||typeof t.post_id!="string"||!t.post_id.trim()||typeof t.title!="string")throw new Error("Fusion historical evidence requires exact run and Board post identities");return{runId:t.run_id,postId:t.post_id,title:t.title,createdAt:St(t.created_at,"historical publication time")}})}function bt(e,t){if(typeof e!="string")throw new Error(`Invalid Fusion ${t}: expected a string`);return e}function Is(e,t){const n=`runs[${t}]`;if(!nn(e))throw new Error(`Invalid Fusion ${n}: expected an object`);const r=bt(e.run_id,`${n}.run_id`);if(!r.trim())throw new Error(`Invalid Fusion ${n}.run_id: empty identity`);const l=bt(e.keeper,`${n}.keeper`),d=bt(e.preset,`${n}.preset`),c=bt(e.topology,`${n}.topology`);if(!ws.includes(c))throw new Error(`Unknown Fusion ${n}.topology: ${c}`);const v=St(e.started_at,`${n}.started_at`),h=e.finished_at==null?void 0:St(e.finished_at,`${n}.finished_at`),m=e.stage===void 0?void 0:bt(e.stage,`${n}.stage`),k=e.status;if(k!=="running"&&k!=="completed"&&k!=="failed")throw new Error(`Unknown Fusion ${n}.status: ${String(k)}`);const q=k==="failed"?bt(e.error,`${n}.error`):void 0,z=k==="failed"?bt(e.failure_code,`${n}.failure_code`):void 0;if(k!=="failed"&&(e.error!=null||e.failure_code!=null))throw new Error(`Invalid Fusion ${n}: only failed runs may carry failure attribution`);return{runId:r,keeper:l,preset:d,topology:c,startedAt:v,finishedAt:h,stage:m,status:k,error:q,failureCode:z}}function Rs(e){if(!nn(e))throw new Error("Invalid Fusion response: expected an object");if(!Array.isArray(e.runs))throw new Error("Invalid Fusion runs: expected an array");const t=e.runs.map(Is),n=St(e.count,"count",!0);if(n!==t.length)throw new Error(`Invalid Fusion count: ${n} does not match ${t.length} rows`);if(new Set(t.map(r=>r.runId)).size!==t.length)throw new Error("Invalid Fusion runs: duplicate run_id");return{runs:t,count:n,generatedAt:bt(e.generated_at,"generated_at"),replay:Ss(e.replay),historicalEvidence:Cs(e.historical_evidence)}}const Ts=/^[A-Za-z0-9][A-Za-z0-9._-]*$/,As=/^[A-Za-z0-9_-]+$/;function Tn(e){const t=e.trim();return t.startsWith('"')&&t.endsWith('"')||t.startsWith("'")&&t.endsWith("'")?t.slice(1,-1):t}function Os(e){return As.test(e)?e:JSON.stringify(e)}function Jn(e){return e==="failover"?"runtime.lanes.":"runtime.exact_output_lanes."}function Ls(e,t){return`[${Jn(e)}${Os(t)}]`}function Bt(e){let t="none";for(let n=0;n<e.length;n++){const r=e[n];if(t==="none"){if(r==="#")return e.slice(0,n);r==='"'?t="double":r==="'"&&(t="single")}else t==="double"?r==="\\"?n+=1:r==='"'&&(t="none"):r==="'"&&(t="none")}return e}function Yn(e){let t="";for(let n=0;n<e.length;n++){const r=e[n];if(r==="\\"&&n+1<e.length){const l=e[n+1];n+=1,l==='"'||l==="\\"?t+=l:l==="n"?t+=`
`:l==="t"?t+="	":l==="r"?t+="\r":t+=l}else t+=r}return t}function Es(e){const t=Bt(e).trim();if(!t.startsWith("[")||t.startsWith("[[")||!t.endsWith("]"))return null;const n=t.slice(1,-1).trim();if(n.startsWith("runtime.lanes.")){const r=n.slice(14).trim();return!r||r.includes(".")&&!r.startsWith('"')&&!r.startsWith("'")?null:{kind:"failover",id:Tn(r)}}if(n.startsWith("runtime.exact_output_lanes.")){const r=n.slice(27).trim();return!r||r.includes(".")&&!r.startsWith('"')&&!r.startsWith("'")?null:{kind:"exact_output",id:Tn(r)}}return null}function Qn(e){const t=Bt(e).trim();return t.startsWith("[")&&t.endsWith("]")}function en(e){let t="none",n=0;for(let r=0;r<e.length;r++){const l=e[r];if(t==="none"){if(l==="#")break;l==='"'?t="double":l==="'"?t="single":l==="["?n+=1:l==="]"&&(n-=1)}else t==="double"?l==="\\"?r+=1:l==='"'&&(t="none"):l==="'"&&(t="none")}return n}function fn(e){const t=[];let n=0;for(;n<e.length;){const r=Es(e[n]);if(!r){n+=1;continue}let l=n+1,d=0;for(;l<e.length;){const c=e[l];if(d===0&&Qn(c))break;d=Math.max(0,d+en(c)),l+=1}t.push({kind:r.kind,id:r.id,startLine:n,endLine:l}),n=l}return t}function Xn(e,t){const n=new RegExp(`^\\s*${t}\\s*=`);let r=0;for(let l=0;l<e.length;l++){const d=e[l];if(r>0){r=Math.max(0,r+en(d));continue}const c=n.exec(d);if(!c){r=Math.max(0,r+en(d));continue}const v=c[0].length;let h=0,m=!1;const k=[];for(let q=l;q<e.length;q++){const z=e[q];let T=q===l?v:0;for(;T<z.length;){const ue=z[T];if(ue==="#")break;if(!m){ue==="["&&(m=!0,h=1),T+=1;continue}if(ue==="["){h+=1,T+=1;continue}if(ue==="]"){if(h-=1,T+=1,h===0)return{startLine:l,endLine:q,items:k};continue}if(ue==='"'){let W="";for(T+=1;T<z.length;){const oe=z[T];if(oe==="\\"&&T+1<z.length){W+=oe+z[T+1],T+=2;continue}if(oe==='"'){T+=1;break}W+=oe,T+=1}if(h===1){const oe=Yn(W).trim();oe&&k.push(oe)}continue}if(ue==="'"){let W="";for(T+=1;T<z.length&&z[T]!=="'";)W+=z[T],T+=1;if(T<z.length&&z[T]==="'"&&(T+=1),h===1){const oe=W.trim();oe&&k.push(oe)}continue}T+=1}if(!m)return{startLine:l,endLine:l,items:[]}}return{startLine:l,endLine:e.length-1,items:k}}return null}function zs(e,t){return Xn(e,t)?.items??[]}function Ds(e,t){const r=new RegExp(`^\\s*${t}\\s*=\\s*([+]?[0-9_]+)\\b`,"m").exec(e);if(!r)return;const l=Number.parseInt(r[1].replace(/_/g,""),10);return Number.isSafeInteger(l)?l:void 0}function Ms(e,t){const r=new RegExp(`^\\s*${t}\\s*=\\s*(true|false)\\b`,"m").exec(e);if(r)return r[1]==="true"}function Ps(e){const t=e.split(/\r?\n/);return fn(t).map(r=>{const l=t.slice(r.startLine+1,r.endLine),d=l.join(`
`),c=r.kind==="failover"?"candidates":"slots",v=zs(l,c);return r.kind==="exact_output"?{kind:"exact_output",id:r.id,candidates:v,maxOutputTokens:Ds(d,"max_output_tokens"),enabled:Ms(d,"enabled")}:{kind:"failover",id:r.id,candidates:v}})}function Ws(e){const t=e.trim();return t?Ts.test(t)?Nt(t):Qt("레인 ID는 영문/숫자로 시작하며 영문, 숫자, ., _, - 만 사용할 수 있습니다."):Qt("레인 ID를 입력하세요.")}function An(e,t,n){const r=n==="up"?t-1:t+1;if(t<0||t>=e.length||r<0||r>=e.length)return e;const l=[...e],d=l[t];return l[t]=l[r],l[r]=d,l}function Zn(e,t){return t.length<=2?[`${e} = [${t.map(n=>JSON.stringify(n)).join(", ")}]`]:[`${e} = [`,...t.map(n=>`  ${JSON.stringify(n)},`),"]"]}function Fs(e,t,n){const r=Zn(t,n),l=Xn(e,t);return l?[...e.slice(0,l.startLine),...r,...e.slice(l.endLine+1)]:[...r,...e]}function tn(e,t,n){const r=new RegExp(`^\\s*${t}\\s*=`),l=e.findIndex(c=>r.test(c));if(l>=0)return n===null?[...e.slice(0,l),...e.slice(l+1)]:[...e.slice(0,l),n,...e.slice(l+1)];if(n===null)return[...e];let d=e.length;for(;d>0&&e[d-1].trim()==="";)d-=1;return[...e.slice(0,d),n,...e.slice(d)]}function Ns(e,t){const n=Ws(t.id);if(!n.ok)return n;const r=n.value,l=[],d=new Set;for(const z of t.candidates){const T=z.trim();!T||d.has(T)||(d.add(T),l.push(T))}if(l.length===0)return Qt("최소 1개 이상의 후보 Runtime ID를 추가하세요.");const c=e.endsWith(`
`),v=e.split(/\r?\n/);c&&v[v.length-1]===""&&v.pop();const m=fn(v).find(z=>z.kind===t.kind&&z.id===r),k=t.kind==="failover"?"candidates":"slots";let q;if(m){let z=v.slice(m.startLine+1,m.endLine);z=Fs(z,k,l),t.kind==="exact_output"&&(t.maxOutputTokens!==void 0&&(z=tn(z,"max_output_tokens",t.maxOutputTokens!==null&&t.maxOutputTokens>0?`max_output_tokens = ${Math.trunc(t.maxOutputTokens)}`:null)),t.enabled!==void 0&&(z=tn(z,"enabled",`enabled = ${t.enabled?"true":"false"}`))),q=[...v.slice(0,m.startLine+1),...z,...v.slice(m.endLine)]}else{const z=[Ls(t.kind,r),...Zn(k,l)];t.kind==="exact_output"&&(t.maxOutputTokens&&t.maxOutputTokens>0&&z.push(`max_output_tokens = ${Math.trunc(t.maxOutputTokens)}`),t.enabled===!1&&z.push("enabled = false")),q=[...v.length>0&&v[v.length-1].trim()!==""?[...v,""]:[...v],...z]}return Nt(`${q.join(`
`)}
`)}function Us(e,t,n){const r=n.trim(),l=e.endsWith(`
`),d=e.split(/\r?\n/);l&&d[d.length-1]===""&&d.pop();const v=fn(d).find(k=>k.kind===t&&k.id===r);if(!v)return Qt(`runtime.toml에서 [${Jn(t)}${r}] 섹션을 찾지 못했습니다.`);let h=v.startLine;h>0&&d[h-1].trim()===""&&(v.endLine>=d.length||d[v.endLine].trim()==="")&&(h-=1);const m=[...d.slice(0,h),...d.slice(v.endLine)];return Nt(m.length>0?`${m.join(`
`)}
`:"")}function ea(e,t){for(let n=0;n<e.length;n+=1){if(Bt(e[n]).trim()!==`[${t}]`)continue;let l=n+1,d=0;for(;l<e.length;){const c=e[l];if(d===0&&Qn(c))break;d=Math.max(0,d+en(c)),l+=1}return{startLine:n,endLine:l}}return null}function On(e,t){const n=new RegExp(`^\\s*${t}\\s*=\\s*(.+)$`);for(const r of e){const l=Bt(r).trim(),d=n.exec(l);if(!d)continue;const c=d[1].trim();return c.startsWith('"')&&c.endsWith('"')&&c.length>=2?Yn(c.slice(1,-1)).trim()||null:c.startsWith("'")&&c.endsWith("'")&&c.length>=2?c.slice(1,-1).trim()||null:c||null}return null}function Ks(e){const t=e.split(/\r?\n/),n=ea(t,"runtime.media");if(!n)return{visionReader:null,imageGenerator:null};const r=t.slice(n.startLine+1,n.endLine);return{visionReader:On(r,"vision_reader"),imageGenerator:On(r,"image_generator")}}function Bs(e,t){const n=t.visionReader?.trim()||null,r=t.imageGenerator?.trim()||null,l=e.endsWith(`
`),d=e.split(/\r?\n/);l&&d[d.length-1]===""&&d.pop();const c=ea(d,"runtime.media");let v;if(c){let h=d.slice(c.startLine+1,c.endLine);if(h=tn(h,"vision_reader",n?`vision_reader = ${JSON.stringify(n)}`:null),h=tn(h,"image_generator",r?`image_generator = ${JSON.stringify(r)}`:null),h.some(k=>Bt(k).trim()!==""))v=[...d.slice(0,c.startLine+1),...h,...d.slice(c.endLine)];else{let k=c.startLine;k>0&&d[k-1].trim()===""&&(c.endLine>=d.length||d[c.endLine].trim()==="")&&(k-=1),v=[...d.slice(0,k),...d.slice(c.endLine)]}}else{if(!n&&!r)return Nt(e);const h=["[runtime.media]"];n&&h.push(`vision_reader = ${JSON.stringify(n)}`),r&&h.push(`image_generator = ${JSON.stringify(r)}`),v=[...d.length>0&&d[d.length-1].trim()!==""?[...d,""]:[...d],...h]}return Nt(v.length>0?`${v.join(`
`)}
`:"")}function qs(e,t,n="runtime.toml"){return Ua(`a/${n}`,`b/${n}`,e,t,"current","proposed",{context:3})}const pn="runtime:fusion-runs",ta="fusion_run_status",js={running:"진행 중",completed:"완료",failed:"실패"},Vs=new Map([["panel","패널 응답 수집"],["judge","판정 중"],["computed","판정 결과 수신"],["recording_evidence","증거 기록 중"]]);function Mt(e){if(be.peek().kind==="single_user_local")return N.fetch(pn,t=>$e("/api/v1/dashboard/fusion-runs",{signal:t,decode:Rs}),{ttlMs:15e3,topics:[ta],reason:e})}function Hs({row:e,epoch:t}){const n=tt.value===t&&be.value.kind==="single_user_local",[r,l]=_(null);return ve(()=>{if(!n)return;const d=new AbortController;return $e(`/api/v1/dashboard/fusion-runs/${encodeURIComponent(e.runId)}`,{signal:d.signal}).then(c=>{!d.signal.aborted&&Z(t)&&l(c)}),()=>d.abort()},[e.runId,t,n]),n?r===null?a`<p role="status" class="inline-flex items-center gap-2"><${Jt} size="xs" />실행 상세 불러오는 중…</p>`:a`
    ${r.ok?a`<p class="ap-muted">상세를 열 때 읽은 스냅샷입니다.</p>`:a`<div class="ap-error" role="alert">실행 상세 조회 실패. 아래는 목록에서 마지막으로 읽은 값입니다. ${r.error.message}</div>`}
    <pre class="ap-inspect-json mono">${JSON.stringify(r.ok?r.value:e,null,2)}</pre>
  `:null}function Gt(e){return!e.signal.aborted&&Z(e.epoch)}function Gs(e,t){const n=new Set;if(e){e.default_runtime&&n.add(e.default_runtime.id);for(const d of e.lanes??[])for(const c of d.runtime_ids??[])n.add(c)}const r=[],l=[];for(const d of t?.probe?.providers??[]){const c=n.has(d.runtime_id)?"active_lane":"outside_lane",v={...d,scopeBand:c};c==="active_lane"?r.push(v):l.push(v)}return{active:r,outside:l,all:[...r,...l]}}function Js(e){const t=(e??"").trim().toLowerCase();if(t==="exact"||t==="fusion")return t;const n=Mn.peek().query.mode?.toLowerCase();if(n==="exact"||n==="fusion")return n;if(typeof window<"u"){const r=new URLSearchParams(window.location.search).get("mode")?.toLowerCase();if(r==="exact"||r==="fusion")return r}return"failover"}function on(e){const t=e.toLowerCase();return t==="reachable"||t==="succeeded"||t==="completed"||t==="approved"||t==="committed"?{background:"var(--ok-soft)",border:"1px solid var(--ok-border)",color:"var(--ok-fg)"}:t==="running"||t==="skipped_cli"||t==="skipped_native_auth"||t==="warming_up"?{background:"var(--info-soft)",border:"1px solid var(--info-border)",color:"var(--info-fg)"}:t==="cancelled"||t==="superseded"||t==="deferred"?{background:"var(--warn-soft)",border:"1px solid var(--warn-border)",color:"var(--warn-fg)"}:{background:"var(--err-soft)",border:"1px solid var(--err-border)",color:"var(--err-fg)"}}function Ys(e){const t=be.value,n=t.kind==="single_user_local",r=ot("admin",t),l=n&&!r,d=n&&t.role!=="player",[c,v]=_(()=>Js(e.entityTab)),[h,m]=_("all"),[k,q]=_(!1),[z,T]=_(()=>Date.now()/1e3),[ue,W]=_(null),[oe,fe]=_(null),[U,ae]=_(""),[Ae,O]=_(""),[te,Ee]=_(""),[je,ze]=_(""),[Ke,pe]=_(""),G=Me(!1),[Ie,J]=_(null),[K,_e]=_(null),L=Me(null),F=Me(null),ge=Me(null),j=Me(!0);ve(()=>(j.current=!0,()=>{j.current=!1}),[]);const Oe=tt.value,E=Mn.value.query.mode?.toLowerCase();ve(()=>{(E==="failover"||E==="exact"||E==="fusion")&&v(E)},[E]);const[re,ye]=_(null),[Y,Re]=_(null),[ie,he]=_(null),[Ge,Ce]=_(null),[me,g]=_("all"),[C,x]=_([]),u=C[C.length-1]??null,[R,I]=_(!1),[w,Q]=_(""),[V,We]=_(""),[Ve,ct]=_(""),[Ye,nt]=_("simple"),[pt,De]=_(!1),we=N.observe("runtime:resolved").value,ke=N.observe("runtime:probe").value,at=`runtime:exact-runs:${me}:${u?`${u.startedAt}:${u.runId}`:"head"}`,Be=N.observe(at).value,He=N.observe(pn).value,Se=()=>{F.current?.abort(),he(null),fe(s=>s==="lane-preview"?null:s)},vt=()=>{const s=be.peek();return s.kind==="single_user_local"&&!ot("admin",s)},it=Me(!1);it.current=ie!==null||re!==null||Y!==null||oe==="lane-apply";const Fe=(s=!1,f="mount")=>{const $=be.peek(),D=$.kind==="single_user_local",H=$.kind==="multi_account_signed_in";if(f!=="sse"&&(L.current?.abort(),Se(),_e(null),fe(Te=>Te==="lane-apply"?null:Te)),!D&&!H){W(Te=>Te?.kind==="lane-source-error"?null:Te);return}const Xe=xe(),Le=[N.fetch("runtime:resolved",Fn,{ttlMs:15e3,topics:["runtime","runtime_resolved","config"],reason:f})];if(D&&Le.push(N.fetch("runtime:probe",Te=>$e(`/api/v1/dashboard/runtime-probe${s?"?force=true":""}`,{signal:Te,decode:Ma}),{ttlMs:2e4,topics:["runtime_probe"],reason:s?"manual":f})),Promise.all(Le).then(()=>{Z(Xe)&&Lt()}),!D||ot("admin",$)){W(Te=>Te?.kind==="lane-source-error"?null:Te);return}if(f==="sse"&&it.current)return;L.current?.abort();const Ne=new AbortController;L.current=Ne;const Ue=xe();$e("/api/v1/runtime/config/raw",{signal:Ne.signal}).then(Te=>{if(!(Ne.signal.aborted||!Z(Ue))){if(!Te.ok){W({kind:"lane-source-error",text:`runtime.toml 원본 조회 실패: ${Te.error.message}`});return}if(typeof Te.value.source_revision=="string"&&(J(Te.value.source_revision),typeof Te.value.source_text=="string"&&typeof Te.value.path=="string")){_e({sourceText:Te.value.source_text,sourceRevision:Te.value.source_revision,sourcePath:Te.value.path,epoch:Ue,signal:Ne.signal}),W(qt=>qt?.kind==="lane-source-error"?null:qt);return}W({kind:"lane-source-error",text:"runtime.toml 원본의 경로, 리비전 또는 내용을 받지 못했습니다."})}})},ut=(s="mount")=>{if(ot("admin",be.peek()))return;const f=xe(),$={limit:50,runKind:me==="all"?void 0:me,before:u??void 0};N.fetch(at,D=>Bn($,D),{ttlMs:15e3,topics:["exact_lane_runs"],reason:s}).then(()=>{Z(f)&&Lt()})};ve(()=>(fe(null),Se(),_e(null),J(null),ye(null),Re(null),Ce(null),()=>{L.current?.abort(),F.current?.abort(),ge.current?.abort()}),[Oe]),ve(()=>{l||(L.current?.abort(),F.current?.abort(),Se(),_e(null),J(null),ye(null),Re(null),Ce(null))},[l]),ve(()=>{r&&ge.current?.abort()},[r]),ve(()=>{d||I(!1)},[d]),ve(()=>{c==="failover"?Fe(!1,"mount"):c==="exact"&&ut("mount")},[c,me,u,Oe,t.kind,r]),ve(()=>{if(c==="fusion")return;let s=!1,f=null;const $=c==="failover"?new Set(["runtime","runtime_resolved","runtime_probe","config","dataset_invalidation"]):new Set(["exact_lane_runs","goal_projection_changed","verification_requests","dataset_invalidation"]),D=()=>{s||!Z(Oe)||(c==="failover"?Fe(!1,"sse"):ut("sse"))},H=()=>{f!==null&&clearTimeout(f),f=setTimeout(()=>{f=null,D()},400)},Xe=At(Ue=>{Et(Ue).some(Te=>$.has(Te))&&H()}),Le=Kt(D),Ne=Ot(D);return()=>{s=!0,f!==null&&clearTimeout(f),Xe(),Le(),Ne()}},[c,me,u,Oe,t.kind,r]),ve(()=>{if(c!=="fusion"||!n)return;let s=!1;const f=At(Le=>{Et(Le).includes(ta)&&Mt("sse")}),$=()=>{N.invalidateKey(pn),queueMicrotask(()=>{!s&&Z(Oe)&&Mt("sse")})};let D=an.peek();const H=an.subscribe(Le=>{Le&&!D&&$(),D=Le}),Xe=Ot($);return Mt("mount"),()=>{s=!0,f(),H(),Xe()}},[c,Oe,n]);const de=we.kind==="value"?we.data:null,lt=ke.kind==="value"?ke.data:null;ve(()=>{const s=window.setInterval(()=>{T(Date.now()/1e3)},3e4);return()=>window.clearInterval(s)},[]),ve(()=>{de&&(T(Date.now()/1e3),!U&&de.default_route&&ae(de.default_route),!Ae&&de.assignments?.[0]&&O(de.assignments[0].keeper),!w&&de.assignments?.[0]&&Q(de.assignments[0].keeper))},[de]);const dt=ce(()=>{const s=new Map;for(const f of de?.runtimes??[])s.set(f.id,f);return s},[de]),ht=ce(()=>Wn(de?.runtimes??[],z),[de,z]),P=ce(()=>Gs(de,lt),[de,lt]),gt=ce(()=>h==="active_lane"?P.active:h==="outside_lane"?P.outside:P.all,[P,h]),yt=ce(()=>P.active.filter(s=>s.reachable===!1).length,[P.active]),Qe=ce(()=>P.outside.filter(s=>s.reachable===!1).length,[P.outside]),Je=ce(()=>[{id:"run_id",header:"Run ID",cell:s=>a`<span class="mono" style=${{fontSize:"var(--fs-11)"}}>${s.runId.slice(0,14)}</span>`},{id:"kind",header:"종류",sortable:!0,sortValue:s=>s.runKind,cell:s=>a`<span class="mono" style=${{fontSize:"var(--fs-11)",color:"var(--info-fg)"}}>${s.runKind}</span>`},{id:"lane",header:"레인",sortable:!0,sortValue:s=>s.lane,cell:s=>a`<span class="mono" style=${{fontSize:"var(--fs-12)"}}>${s.lane}</span>`},{id:"actor",header:"Actor",cell:s=>a`<${Xt} id=${s.actor} size="sm" />`},{id:"status",header:"상태",sortable:!0,sortValue:s=>s.status,cell:s=>{const f=Rn(s);return a`
          <span class="mono" style=${{...on(s.status),padding:"var(--sp-0) var(--sp-2)",borderRadius:"var(--radius-pill)",fontSize:"var(--fs-11)"}}>
            ${s.status}
          </span>
          ${f&&a`<span class="mono" style=${{marginLeft:"var(--sp-1)",fontSize:"var(--fs-11)",color:"var(--fg-2)"}}>실제 결과 ${f.intendedStatus}</span>`}
        `}},{id:"elapsed",header:"소요(s)",numeric:!0,observed:s=>Ft(s.elapsedSeconds,!0),formatValue:s=>`${Number(s).toFixed(2)}s`},{id:"started",header:"시작 시각",numeric:!0,sortable:!0,sortValue:s=>s.startedAt,cell:s=>a`<span class="mono tnum" style=${{fontSize:"var(--fs-11)",color:"var(--fg-3)"}}>${kn(s.startedAt)}</span>`}],[]),st=He.kind==="value"&&He.stale,kt=an.value&&!st,zt=ce(()=>[{id:"run_id",header:"Run ID",cell:s=>a`<span class="mono" style=${{fontSize:"var(--fs-11)"}}>${s.runId.slice(0,14)}</span>`},{id:"keeper",header:"Keeper",cell:s=>a`<${Xt} id=${s.keeper} size="sm" />`},{id:"preset",header:"프리셋",sortable:!0,accessor:s=>s.preset},{id:"topology",header:"토폴로지",sortable:!0,sortValue:s=>s.topology,cell:s=>a`<span class="mono" style=${{fontSize:"var(--fs-11)",color:"var(--brass-1)"}}>${s.topology}</span>`},{id:"status",header:"상태",sortable:!0,sortValue:s=>s.status,cell:s=>{const f=s.stage&&(Vs.get(s.stage)??s.stage),$=s.status==="running"&&s.stage==="accepted";return a`
          <span class="inline-flex items-center gap-1" style=${{...on(s.status),padding:"var(--sp-0) var(--sp-2)",borderRadius:"var(--radius-pill)",fontSize:"var(--fs-12)",fontWeight:600}}>
            ${s.status==="running"&&!$&&kt&&a`<${Jt} size="xs" />`}
            ${$?"접수됨":js[s.status]}
          </span>
          ${s.status==="running"&&!$&&f&&a`<span class="ml-2">${f}</span>`}
          ${s.status==="failed"&&s.error&&a`<div style=${{color:"var(--err-fg)"}}>${s.error}</div>`}
        `}},{id:"started",header:"시작 시각",numeric:!0,sortable:!0,sortValue:s=>s.startedAt,cell:s=>a`<span class="mono tnum" style=${{fontSize:"var(--fs-11)",color:"var(--fg-3)"}}>${kn(s.startedAt)}</span>`},{id:"duration",header:"소요 시간",numeric:!0,cell:s=>s.status!=="running"&&s.finishedAt!==void 0?Na(s.finishedAt-s.startedAt):"—"}],[kt]);ve(()=>{if(!G.current)if(K){const s=Ks(K.sourceText);ze(s.visionReader??""),pe(s.imageGenerator??"")}else de?.media&&(ze(de.media.vision_reader??""),pe(de.media.image_generator??""))},[K,de]);const $t=ce(()=>K?Ps(K.sourceText):de?(de.lanes??[]).map(s=>({kind:"failover",id:s.id,candidates:s.runtime_ids??[]})):[],[K,de]),xt=ce(()=>{const s=new Set;for(const f of de?.runtimes??[])f.id&&s.add(f.id);for(const f of lt?.probe?.providers??[])f.runtime_id&&s.add(f.runtime_id);return[...s]},[de,lt]),_t=async(s,f)=>{if(!vt())return;const $=K;if(!$||!Gt($)){W({kind:"err",text:"runtime.toml 원본을 불러오지 못해 미리보기를 실행할 수 없습니다."});return}Se();const D=new AbortController;F.current=D,fe("lane-preview"),W(null),Ce(null);const H=await Pe("POST","/api/v1/runtime/config/raw/preview",{source_text:s},{signal:D.signal});if(D.signal.aborted||!Gt($))return;if(fe(null),!H.ok){W({kind:"err",text:`레인 검증 미리보기 실패: ${H.error.message}`});return}const Le=(Array.isArray(H.value.validation?.issues)?H.value.validation.issues:[]).map(Ue=>{const Te=typeof Ue.severity=="string"&&Ue.severity.trim()?`[${Ue.severity.trim()}] `:"",qt=typeof Ue.key=="string"&&Ue.key.trim()?`${Ue.key.trim()}: `:"",na=typeof Ue.detail=="string"&&Ue.detail.trim()?Ue.detail.trim():typeof Ue.message=="string"&&Ue.message.trim()?Ue.message.trim():"";return`${Te}${qt}${na}`.trim()}).filter(Boolean),Ne=qs($.sourceText,s,$.sourcePath);he({source:$,nextToml:s,diff:Ne,canSave:H.value.can_save===!0,runtimeValidation:typeof H.value.runtime_validation=="string"&&H.value.runtime_validation.trim()?H.value.runtime_validation.trim():null,validationIssues:Le,label:f})},o=async s=>{if(s.preventDefault(),!re||!K)return;const f=re.kind==="exact_output"&&(re.mode==="create"||re.maxOutputTokensEdited),$=re.maxOutputTokens.trim(),D=f&&$?Number.parseInt($,10):null;if(f&&$&&(!Number.isSafeInteger(D)||(D??0)<=0)){W({kind:"err",text:"max_output_tokens는 양의 정수를 입력하세요."});return}const H=Ns(K.sourceText,{kind:re.kind,id:re.id,candidates:re.candidates,maxOutputTokens:f?D:void 0});if(!H.ok){W({kind:"err",text:H.error});return}await _t(H.value,`${re.mode==="create"?"생성":"수정"}: ${re.id.trim()} (${re.kind})`)},S=async(s,f)=>{if(!K)return;const $=Us(K.sourceText,s,f);if(!$.ok){W({kind:"err",text:$.error});return}await _t($.value,`삭제: ${f} (${s})`)},y=async s=>{if(s.preventDefault(),!K)return;const f=Bs(K.sourceText,{visionReader:je.trim()||null,imageGenerator:Ke.trim()||null});if(!f.ok){W({kind:"err",text:f.error});return}await _t(f.value,"[runtime.media] 오버라이드")},X=async()=>{if(!vt()||!ie?.canSave||!Gt(ie.source))return;fe("lane-apply"),W(null),Ce(null);const s=await Pe("POST","/api/v1/runtime/config/raw",{source_text:ie.nextToml,expected_source_revision:ie.source.sourceRevision,expected_source_path:ie.source.sourcePath});if(Gt(ie.source)){if(fe(null),!s.ok){s.error.kind==="conflict_cas"?Ce(s.error.message||"runtime.toml이 외부에서 변경되었습니다 (409 revision_conflict)."):W({kind:"err",text:`runtime.toml 저장 실패: ${s.error.message}`});return}W(null),qe(`레인 변경(${ie.label})이 runtime.toml에 CAS 저장되었습니다.`,"success"),Se(),ye(null),Re(null),G.current=!1,Fe(!1,"manual")}},M=async s=>{if(s.preventDefault(),!vt()||!U.trim())return;const f=xe(),$=U.trim();fe("routing"),W(null);const D=await Pe("POST","/api/v1/runtime/config/routing",{lane:"default",runtime_id:$});if(!(!j.current||!Z(f))){if(fe(null),!D.ok){W({kind:"err",text:`기본 라우트 변경 실패: ${D.error.message}`});return}W(null),qe(`기본 라우트가 ${$} 로 갱신되었습니다.`,"success"),Fe(!1,"manual")}},ee=async s=>{if(s.preventDefault(),!vt()||!Ae.trim())return;const f=xe(),$=Ae.trim(),D=te.trim();fe("assignment"),W(null);const H=de?.assignments?.find(Ue=>Ue.keeper===$),Xe=H&&H.assignment_source==="explicit"?H.resolved.id:null,Ne=await Pe("POST","/api/v1/runtime/config/assignment",{keeper_name:$,runtime_id:D||null,expected_assignment_revision:Ie?{state:"runtime_config_present",source_revision:Ie,assignment:Xe?{state:"assigned",runtime_id:Xe}:{state:"missing"}}:{state:"runtime_config_missing"}});if(!(!j.current||!Z(f))){if(fe(null),!Ne.ok){W({kind:"err",text:`Keeper 할당 실패: ${Ne.error.message}`});return}W(null),qe(`${$} 런타임 할당이 반영되었습니다.`,"success"),Fe(!1,"manual")}},A=async s=>{if(r)return;ge.current?.abort();const f=new AbortController;ge.current=f,e.onInspect({title:`Exact Run · ${s.lane}`,subtitle:`${s.runId} (${s.status})`,kind:"exact_lane_run",data:s,render:()=>a`<div class="dtable-absent">상세 페이로드 불러오는 중…</div>`});const $=await Pa(s.runId,f.signal);if(f.signal.aborted||ot("admin",be.peek()))return;const D=$.ok?$.value:null,H=D??s,Xe=$.ok?null:$.error.message,Le=Rn(H),Ne=H.runKind==="exact_output"?H:null;e.onInspect({title:`Exact Run · ${H.lane}`,subtitle:`${H.runId} · ${H.runKind} · ${H.status}`,kind:"exact_lane_run",data:H,render:()=>a`
        <div style=${{display:"flex",flexDirection:"column",gap:"var(--sp-3)",minWidth:0}}>
          ${Xe&&a`<div class="ap-error">상세 API 조회 오류: ${Xe}</div>`}
          <div class="wka-card" style=${{display:"grid",gridTemplateColumns:"repeat(2, minmax(0, 1fr))",gap:"var(--sp-2)",fontSize:"var(--fs-12)"}}>
            <div><span style=${{color:"var(--fg-3)"}}>Status:</span> <span class="mono">${H.status}</span></div>
            <div><span style=${{color:"var(--fg-3)"}}>Slot:</span> <span class="mono">${H.selectedSlot??"없음"}</span></div>
            ${Ne&&a`<div><span style=${{color:"var(--fg-3)"}}>Origin:</span> <span class="mono">${Ne.completionOrigin??"없음"}</span></div>`}
            <div><span style=${{color:"var(--fg-3)"}}>Subject:</span> <span class="mono">${H.subjectId??"없음"}</span></div>
          </div>

          ${Le&&a`
            <div class="wka-card" role="alert" style=${{borderColor:"var(--err-border)"}}>
              <h4 style=${{margin:"0 0 var(--sp-1)",fontSize:"var(--fs-12)",color:"var(--err-fg)"}}>${vs(Le.persistenceState)}</h4>
              <div style=${{fontSize:"var(--fs-12)"}}>
                <span style=${{color:"var(--fg-3)"}}>실제 결과:</span> <span class="mono">${Le.intendedStatus}</span>
                ${Le.intendedCode!==null&&a` · <span class="mono">${Le.intendedCode}</span>: ${Le.intendedDetail??""}`}
              </div>
              <div style=${{marginTop:"var(--sp-1)",fontSize:"var(--fs-12)"}}>
                <span style=${{color:"var(--fg-3)"}}>저장 실패 이유:</span> <span class="mono">${Le.persistenceError}</span>
              </div>
            </div>
          `}

          <div class="wka-card">
            <h4 style=${{margin:"0 0 var(--sp-1)",fontSize:"var(--fs-12)"}}>스키마 / 페이로드 가용성</h4>
            <div class="mono" style=${{fontSize:"var(--fs-11)",color:"var(--fg-2)"}}>
              Input: ${D?.payloadAvailability.input.state??"unobserved"} ·
              Output: ${D===null?"unobserved":D.payloadAvailability.output?.state??"running (null)"}
            </div>
            ${Ne?.code&&a`
              <div style=${{marginTop:"var(--sp-1)",color:"var(--err-fg)",fontSize:"var(--fs-12)"}}>
                ${Ne.code}: ${Ne.detail??""}
              </div>
            `}
          </div>

          ${Ne&&a`
            <div class="wka-card">
              <h4 style=${{margin:"0 0 var(--sp-1)",fontSize:"var(--fs-12)"}}>슬롯 관측 (Slot Observations)</h4>
              <pre class="mono" style=${{margin:0,fontSize:"var(--fs-11)",overflowX:"auto",whiteSpace:"pre-wrap",background:"var(--bg-0)",padding:"var(--sp-2)",borderRadius:"var(--radius-sm)"}}>
                ${JSON.stringify(Ne.slotObservations??{state:"unobserved"},null,2)}
              </pre>
            </div>
          `}

          <div class="wka-card">
            <h4 style=${{margin:"0 0 var(--sp-1)",fontSize:"var(--fs-12)"}}>Raw Output Payload</h4>
            <pre class="mono" style=${{margin:0,fontSize:"var(--fs-11)",overflowX:"auto",whiteSpace:"pre-wrap",background:"var(--bg-0)",padding:"var(--sp-2)",borderRadius:"var(--radius-sm)"}}>
              ${D?.output!==void 0?JSON.stringify(D.output,null,2):"없음"}
            </pre>
          </div>
        </div>
      `})},i=s=>{be.peek().kind==="single_user_local"&&(ge.current?.abort(),e.onInspect({title:`Fusion · ${s.preset}`,subtitle:`${s.runId} · ${s.topology}`,kind:"fusion_run",render:()=>a`<${Hs} key=${s.runId} row=${s} epoch=${Oe} />`}))},p=async s=>{s.preventDefault();const f=be.peek();if(f.kind!=="single_user_local"||f.role==="player"||!w.trim()||!V.trim())return;const $=xe(),D=w.trim(),H=Ye;fe("fusion"),W(null);const Xe={prompt:V.trim(),topology:H,web_tools:pt,...Ve.trim()?{preset:Ve.trim()}:{}},Le=await Pe("POST",`/api/v1/keepers/${encodeURIComponent(D)}/fusion`,Xe);if(!(!j.current||!Z($))){if(fe(null),!Le.ok){W({kind:"err",text:`Fusion 실행 실패: ${Le.error.message}`});return}W(null),qe(`${D} Fusion (${H}) 실행을 요청했습니다.`,"success"),I(!1),We(""),Mt("manual")}},b=!r&&Be.kind==="value"?Be.data:null,B=He.kind==="value"?He.data:null,ne=k||re!==null||Y!==null||ie!==null||Ge!==null,se=(s,f)=>!s.visionInput&&!s.imageOutput?null:a`
      ${s.visionInput&&a`
        <span
          class="mono rt-cap-chip"
          data-testid=${`${f}-cap-vision`}
          title="이 런타임/레인은 이미지 입력(Vision)을 기본 지원합니다"
        >
          Vision
        </span>
      `}
      ${s.imageOutput&&a`
        <span
          class="mono rt-cap-chip rt-cap-chip--gen"
          data-testid=${`${f}-cap-image-gen`}
          title="이 런타임/레인은 이미지 생성(Image Gen)을 기본 지원합니다"
        >
          Image Gen
        </span>
      `}
    `,le=(s,f)=>{const $=dt.get(s),D=$?sn($,z):null;return D?a`
      <span
        data-testid=${f}
        data-liveness-kind=${D.kind}
        class="mono"
        style=${{...Tt(D.tone),padding:"var(--sp-0) var(--sp-1)",borderRadius:"var(--radius-pill)",fontSize:"var(--fs-10)",fontWeight:600,whiteSpace:"nowrap"}}
      >
        ${D.label}
      </span>
    `:null};return a`
    <div class="ov" data-testid="runtime-lanes-tab">
      <header class="ov-head">
        <div>
          <span class="ov-eyebrow">5 RUNTIME · LANES & EXACT OUTPUT</span>
          <h1>페일오버 레인 · Exact Output · Fusion 패널</h1>
        </div>
        <div style=${{display:"flex",alignItems:"center",gap:"var(--sp-2)",flexWrap:"wrap"}}>
          <div class="ap-viewseg" role="tablist" aria-label="레인 모드 선택">
            <button
              type="button"
              role="tab"
              aria-selected=${c==="failover"}
              class=${`ap-viewbtn ${c==="failover"?"on":""}`}
              onClick=${()=>v("failover")}
            >
              Failover
            </button>
            <button
              type="button"
              role="tab"
              aria-selected=${c==="exact"}
              class=${`ap-viewbtn ${c==="exact"?"on":""}`}
              onClick=${()=>v("exact")}
            >
              Exact Output
            </button>
            <button
              type="button"
              role="tab"
              aria-selected=${c==="fusion"}
              class=${`ap-viewbtn ${c==="fusion"?"on":""}`}
              onClick=${()=>v("fusion")}
            >
              Fusion
            </button>
          </div>
          ${c==="failover"&&n&&a`
            <button type="button" class="btn-ghost" onClick=${()=>Fe(!0,"manual")}>
              강제 프로브
            </button>
          `}
          ${c==="fusion"&&d&&a`
            <button type="button" class="btn-primary" onClick=${()=>I(s=>!s)}>
              + Fusion 실행
            </button>
          `}
        </div>
      </header>

      ${ue&&a`
        <div role="alert" class="ap-error">
          ${ue.text}
        </div>
      `}

      ${c==="failover"&&a`
        <div style=${{display:"flex",flexDirection:"column",gap:"var(--sp-4)",minWidth:0}}>
          ${(we.kind==="failed"||n&&ke.kind==="failed")&&a`
            <div class="ap-error" role="alert">
              ${we.kind==="failed"?`런타임 레인 조회 실패: ${we.error.message}`:""}
              ${we.kind==="failed"&&n&&ke.kind==="failed"?" · ":""}
              ${n&&ke.kind==="failed"?`런타임 프로브 조회 실패: ${ke.error.message}`:""}
            </div>
          `}
          <section class="ov-kpis" aria-label="레인 프로브 요약">
            <div class="ov-kpi">
              <div class="ov-kpi-k">기본 라우트</div>
              <div class="ov-kpi-v" style=${{fontSize:"var(--fs-14)"}}>
                ${we.kind==="value"?de?.default_route??"없음":rt(we)}
              </div>
            </div>
            <div class="ov-kpi">
              <div class="ov-kpi-k">활성 레인 프로브 (실패)</div>
              <div class=${`ov-kpi-v ${ke.kind==="failed"||we.kind==="failed"?"bad":ke.kind==="value"?yt>0?"bad":"ok":""}`}>
                ${ke.kind==="value"?`${P.active.length} (${yt})`:n?rt(ke):"—"}
              </div>
            </div>
            <div class="ov-kpi">
              <div class="ov-kpi-k">외부 레인 프로브 (격리)</div>
              <div class=${`ov-kpi-v ${ke.kind==="failed"?"bad":ke.kind==="value"&&Qe>0?"warn":""}`}>
                ${ke.kind==="value"?`${P.outside.length} (${Qe})`:n?rt(ke):"—"}
              </div>
            </div>
            <div class="ov-kpi">
              <div class="ov-kpi-k">선언된 페일오버 레인</div>
              <div class=${`ov-kpi-v ${we.kind==="failed"?"bad":""}`}>
                ${we.kind==="value"?de?.lanes?.length??0:rt(we)}
              </div>
            </div>
          </section>

          <!-- Default-Collapsed Routing & Lane CRUD Configuration (keeps Virtualized Probes above the fold) -->
          <section class="ap-disclosure" data-testid="lane-config-disclosure" aria-label="라우팅 및 레인 설정">
            <button
              type="button"
              class="ap-disclosure-trigger"
              data-testid="lane-config-toggle"
              aria-expanded=${ne}
              onClick=${()=>q(!ne)}
            >
              <span style=${{display:"inline-flex",alignItems:"center",gap:"var(--sp-2)",flexWrap:"wrap"}}>
                <span>라우팅 · 레인 설정 (기본: ${de?.default_route??"없음"} · 레인 ${$t.length}개)</span>
                ${l&&Ge&&a`
                  <span class="mono" style=${{fontSize:"var(--fs-11)",color:"var(--err-fg)"}}>CAS 충돌</span>
                `}
              </span>
              <span aria-hidden="true">${ne?"▾":"▸"}</span>
            </button>

            ${ne&&!l&&a`
              <div class="ap-disclosure-body" data-testid="lane-config-body">
                <div class="dtable-absent" data-testid="lane-config-admin-locked" role="status">
                  ${n?"라우팅 및 레인 설정 편집은 관리자 전용입니다.":"라우팅 및 runtime.toml 편집은 single_user 모드 전용입니다."}
                </div>
              </div>
            `}

            ${ne&&l&&a`
              <div class="ap-disclosure-body" data-testid="lane-config-body">
                <datalist id="lane-runtime-candidates">
                  ${xt.map(s=>{const f=dt.get(s),$=f?sn(f,z):null;return a`<option key=${s} value=${s} label=${$?`${s} (${$.label})`:void 0} />`})}
                </datalist>

                <!-- Inline Default Route & Keeper Assignment Controls -->
                <section style=${{display:"grid",gridTemplateColumns:"repeat(auto-fit, minmax(300px, 1fr))",gap:"var(--sp-3)",minWidth:0}}>
                  <form class="wka-card" onSubmit=${M} style=${{display:"flex",flexDirection:"column",gap:"var(--sp-2)"}}>
                    <div style=${{display:"flex",alignItems:"center",justifyContent:"space-between",gap:"var(--sp-2)",flexWrap:"wrap"}}>
                      <h3 style=${{margin:0,fontSize:"var(--fs-13)"}}>기본 라우트 설정 (/runtime/config/routing)</h3>
                      ${le(U.trim(),"default-route-liveness-badge")}
                    </div>
                    <div style=${{display:"flex",gap:"var(--sp-2)"}}>
                      <input
                        type="text"
                        list="lane-runtime-candidates"
                        aria-label="기본 라우트 ID"
                        value=${U}
                        onInput=${s=>ae(s.target.value)}
                        placeholder="lane 또는 runtime ID"
                        style=${{flex:1,minWidth:0,minHeight:"var(--btn-h, 32px)",padding:"var(--sp-1) var(--sp-2)",background:"var(--input-bg)",border:"1px solid var(--input-border)",borderRadius:"var(--radius-sm)"}}
                      />
                      <button type="submit" class="btn-primary" disabled=${oe==="routing"}>적용</button>
                    </div>
                  </form>

                  <form class="wka-card" onSubmit=${ee} style=${{display:"flex",flexDirection:"column",gap:"var(--sp-2)"}}>
                    <div style=${{display:"flex",alignItems:"center",justifyContent:"space-between",gap:"var(--sp-2)",flexWrap:"wrap"}}>
                      <h3 style=${{margin:0,fontSize:"var(--fs-13)"}}>Keeper 런타임 할당 (/runtime/config/assignment)</h3>
                      ${le(te.trim(),"assign-runtime-liveness-badge")}
                    </div>
                    <div style=${{display:"flex",gap:"var(--sp-2)",flexWrap:"wrap"}}>
                      <input
                        type="text"
                        aria-label="Keeper 이름"
                        value=${Ae}
                        onInput=${s=>O(s.target.value)}
                        placeholder="keeper"
                        style=${{flex:"1 1 120px",minWidth:0,minHeight:"var(--btn-h, 32px)",padding:"var(--sp-1) var(--sp-2)",background:"var(--input-bg)",border:"1px solid var(--input-border)",borderRadius:"var(--radius-sm)"}}
                      />
                      <input
                        type="text"
                        list="lane-runtime-candidates"
                        aria-label="할당할 Runtime ID"
                        value=${te}
                        onInput=${s=>Ee(s.target.value)}
                        placeholder="runtime_id (비우면 기본값)"
                        style=${{flex:"1 1 140px",minWidth:0,minHeight:"var(--btn-h, 32px)",padding:"var(--sp-1) var(--sp-2)",background:"var(--input-bg)",border:"1px solid var(--input-border)",borderRadius:"var(--radius-sm)"}}
                      />
                      <button type="submit" class="btn-primary" disabled=${oe==="assignment"}>할당</button>
                    </div>
                  </form>

                  <form
                    class="wka-card"
                    data-testid="runtime-media-overrides-form"
                    onSubmit=${y}
                    style=${{display:"flex",flexDirection:"column",gap:"var(--sp-2)"}}
                  >
                    <div style=${{display:"flex",alignItems:"center",justifyContent:"space-between",gap:"var(--sp-2)",flexWrap:"wrap"}}>
                      <h3 style=${{margin:0,fontSize:"var(--fs-13)"}}>미디어 라우팅 오버라이드 ([runtime.media], 선택)</h3>
                    </div>
                    <p style=${{margin:0,fontSize:"var(--fs-11)",color:"var(--fg-3)"}}>
                      비워 두면 각 Keeper 활성 런타임의 기본 Vision · Image Gen 역량을 자동 사용합니다.
                    </p>
                    <div style=${{display:"flex",gap:"var(--sp-2)",flexWrap:"wrap"}}>
                      <input
                        type="text"
                        list="lane-runtime-candidates"
                        aria-label="Vision Reader 오버라이드"
                        value=${je}
                        onInput=${s=>{G.current=!0,ze(s.target.value)}}
                        placeholder="vision_reader (비우면 자동)"
                        class="mono"
                        style=${{flex:"1 1 160px",minWidth:0,minHeight:"var(--btn-h, 32px)",padding:"var(--sp-1) var(--sp-2)",background:"var(--input-bg)",border:"1px solid var(--input-border)",borderRadius:"var(--radius-sm)",fontSize:"var(--fs-12)"}}
                      />
                      <input
                        type="text"
                        list="lane-runtime-candidates"
                        aria-label="Image Generator 오버라이드"
                        value=${Ke}
                        onInput=${s=>{G.current=!0,pe(s.target.value)}}
                        placeholder="image_generator (비우면 자동)"
                        class="mono"
                        style=${{flex:"1 1 160px",minWidth:0,minHeight:"var(--btn-h, 32px)",padding:"var(--sp-1) var(--sp-2)",background:"var(--input-bg)",border:"1px solid var(--input-border)",borderRadius:"var(--radius-sm)",fontSize:"var(--fs-12)"}}
                      />
                      <button type="submit" class="btn-ghost" disabled=${!K||oe==="lane-preview"}>
                        미디어 미리보기
                      </button>
                    </div>
                  </form>
                </section>

                <!-- Visual Runtime Lane CRUD (/api/v1/runtime/config/raw + /raw/preview, zero $EDITOR) -->
                <section class="wka-card" data-testid="visual-lane-crud" style=${{display:"flex",flexDirection:"column",gap:"var(--sp-3)",minWidth:0}}>
                  <div class="wka-h" style=${{marginBottom:0}}>
                    <div>
                      <h3 style=${{margin:0,fontSize:"var(--fs-13)"}}>선언된 레인 CRUD (Failover · Exact Output · CAS Diff)</h3>
                      <span class="mono" style=${{fontSize:"var(--fs-11)",color:"var(--fg-3)"}}>
                        ${K?`runtime.toml rev ${K.sourceRevision.slice(0,12)} · ${$t.length}개 레인`:`${$t.length}개 레인 (raw 스냅샷 대기 중)`}
                      </span>
                    </div>
                    <button
                      type="button"
                      class="btn-primary"
                      disabled=${!K}
                      onClick=${()=>{Re(null),Se(),ye({mode:"create",kind:"failover",id:"",candidates:xt[0]?[xt[0]]:[],newCandidate:"",maxOutputTokens:"8192",maxOutputTokensEdited:!1})}}
                    >
                      + 새 레인
                    </button>
                  </div>

                  ${Ge&&a`
                    <div class="ap-error" role="alert" data-testid="lane-cas-conflict" style=${{display:"flex",justifyContent:"space-between",alignItems:"center",gap:"var(--sp-2)",flexWrap:"wrap"}}>
                      <span>⚠ 409 CAS 충돌: ${Ge}</span>
                      <button
                        type="button"
                        class="btn-primary"
                        onClick=${()=>{Ce(null),Se(),Fe(!1,"manual")}}
                      >
                        최신 runtime.toml 다시 불러오기
                      </button>
                    </div>
                  `}

                  ${$t.length===0?a`<div class="dtable-absent">선언된 레인이 없습니다. "+ 새 레인"을 눌러 첫 레인을 만드세요.</div>`:a`
                        <div style=${{display:"flex",flexDirection:"column",gap:"var(--sp-2)"}}>
                          ${$t.map(s=>a`
                            <div
                              key=${`${s.kind}:${s.id}`}
                              data-lane-row=${`${s.kind}:${s.id}`}
                              style=${{display:"flex",justifyContent:"space-between",alignItems:"center",gap:"var(--sp-2)",padding:"var(--sp-2) var(--sp-3)",borderRadius:"var(--radius-sm)",border:"1px solid var(--line-1)",background:"var(--bg-2)",flexWrap:"wrap"}}
                            >
                              <div style=${{display:"flex",flexDirection:"column",gap:"var(--sp-1)",minWidth:0}}>
                                <div style=${{display:"flex",alignItems:"center",gap:"var(--sp-2)",flexWrap:"wrap"}}>
                                  <span class="mono" style=${{fontWeight:600,fontSize:"var(--fs-13)",color:"var(--fg-1)"}}>${s.id}</span>
                                  <span class="mono" style=${{fontSize:"var(--fs-10)",padding:"var(--sp-0) var(--sp-1)",borderRadius:"var(--radius-pill)",background:s.kind==="failover"?"var(--brass-soft)":"var(--info-soft)",color:s.kind==="failover"?"var(--brass-1)":"var(--info-fg)"}}>
                                    ${s.kind}
                                  </span>
                                  ${se(za(s.candidates,dt),`lane-${s.id}`)}
                                  ${s.maxOutputTokens!==void 0&&a`
                                    <span class="mono tnum" style=${{fontSize:"var(--fs-11)",color:"var(--fg-3)"}}>max_tokens=${s.maxOutputTokens}</span>
                                  `}
                                </div>
                                <div class="mono" style=${{display:"flex",alignItems:"center",gap:"var(--sp-1)",flexWrap:"wrap",fontSize:"var(--fs-11)",color:"var(--fg-2)",overflowWrap:"anywhere"}}>
                                  ${s.candidates.length===0?"(후보 없음)":s.candidates.map((f,$)=>a`
                                        <span key=${`${f}-${$}`} style=${{display:"inline-flex",alignItems:"center",gap:"var(--sp-1)"}}>
                                          ${$>0&&a`<span aria-hidden="true" style=${{color:"var(--fg-4)"}}>→</span>`}
                                          <span>${f}</span>
                                          ${se(dn(dt.get(f)),`cand-${f}`)}
                                          ${le(f)}
                                        </span>
                                      `)}
                                </div>
                              </div>
                              <div style=${{display:"flex",gap:"var(--sp-1)",flexShrink:0}}>
                                <button
                                  type="button"
                                  class="btn-ghost"
                                  disabled=${!K}
                                  onClick=${()=>{Re(null),Se(),ye({mode:"edit",kind:s.kind,id:s.id,candidates:[...s.candidates],newCandidate:"",maxOutputTokens:s.maxOutputTokens?String(s.maxOutputTokens):"",maxOutputTokensEdited:!1})}}
                                >
                                  편집
                                </button>
                                <button
                                  type="button"
                                  class="btn-ghost"
                                  disabled=${!K}
                                  style=${{color:"var(--err-fg)"}}
                                  onClick=${()=>{ye(null),Se(),Re({kind:s.kind,id:s.id})}}
                                >
                                  삭제
                                </button>
                              </div>
                            </div>
                          `)}
                        </div>
                      `}

                  ${re&&a`
                    <form
                      data-testid="lane-editor-form"
                      onSubmit=${o}
                      style=${{display:"flex",flexDirection:"column",gap:"var(--sp-2)",padding:"var(--sp-3)",borderRadius:"var(--radius-sm)",border:"1px solid var(--brass-border)",background:"var(--bg-1)"}}
                    >
                      <div class="wka-h" style=${{marginBottom:0}}>
                        <strong style=${{fontSize:"var(--fs-13)"}}>
                          ${re.mode==="create"?"새 레인 생성":`레인 편집 · ${re.id}`}
                        </strong>
                        <button type="button" class="btn-ghost" onClick=${()=>{ye(null),Se()}}>닫기</button>
                      </div>

                      <div style=${{display:"grid",gridTemplateColumns:"repeat(auto-fit, minmax(180px, 1fr))",gap:"var(--sp-2)"}}>
                        <label style=${{display:"flex",flexDirection:"column",gap:"var(--sp-1)",fontSize:"var(--fs-12)"}}>
                          <span>레인 종류</span>
                          <select
                            aria-label="레인 종류"
                            disabled=${re.mode==="edit"}
                            value=${re.kind}
                            onChange=${s=>{const f=s.target.value;ye($=>$?{...$,kind:f}:null),Se()}}
                            style=${{minHeight:"var(--btn-h, 32px)",padding:"var(--sp-1) var(--sp-2)",background:"var(--input-bg)",border:"1px solid var(--input-border)",borderRadius:"var(--radius-sm)"}}
                          >
                            <option value="failover">Failover Lane ([runtime.lanes.*])</option>
                            <option value="exact_output">Exact Output Lane ([runtime.exact_output_lanes.*])</option>
                          </select>
                        </label>

                        <label style=${{display:"flex",flexDirection:"column",gap:"var(--sp-1)",fontSize:"var(--fs-12)"}}>
                          <span>레인 ID</span>
                          <input
                            type="text"
                            aria-label="레인 ID"
                            required
                            disabled=${re.mode==="edit"}
                            placeholder="예: coding-fast"
                            value=${re.id}
                            onInput=${s=>{const f=s.target.value;ye($=>$?{...$,id:f}:null),Se()}}
                            class="mono"
                            style=${{minHeight:"var(--btn-h, 32px)",padding:"var(--sp-1) var(--sp-2)",background:"var(--input-bg)",border:"1px solid var(--input-border)",borderRadius:"var(--radius-sm)"}}
                          />
                        </label>

                        ${re.kind==="exact_output"&&a`
                          <label style=${{display:"flex",flexDirection:"column",gap:"var(--sp-1)",fontSize:"var(--fs-12)"}}>
                            <span>max_output_tokens (선택)</span>
                            <input
                              type="number"
                              aria-label="max_output_tokens"
                              value=${re.maxOutputTokens}
                              onInput=${s=>{const f=s.target.value;ye($=>$?{...$,maxOutputTokens:f,maxOutputTokensEdited:!0}:null),Se()}}
                              class="mono tnum"
                              style=${{minHeight:"var(--btn-h, 32px)",padding:"var(--sp-1) var(--sp-2)",background:"var(--input-bg)",border:"1px solid var(--input-border)",borderRadius:"var(--radius-sm)"}}
                            />
                          </label>
                        `}
                      </div>

                      <div style=${{display:"flex",flexDirection:"column",gap:"var(--sp-1)"}}>
                        <span style=${{fontSize:"var(--fs-12)",color:"var(--fg-2)"}}>
                          후보 Runtime 순서 (${re.candidates.length}개 · 위에서 아래로 우선순위)
                        </span>
                        ${re.candidates.map((s,f)=>a`
                          <div key=${`${s}-${f}`} data-lane-candidate=${s} style=${{display:"flex",alignItems:"center",justifyContent:"space-between",gap:"var(--sp-2)",padding:"var(--sp-1) var(--sp-2)",borderRadius:"var(--radius-sm)",border:"1px solid var(--line-1)",background:"var(--bg-2)"}}>
                            <span class="mono" style=${{display:"inline-flex",alignItems:"center",gap:"var(--sp-2)",flexWrap:"wrap",fontSize:"var(--fs-12)"}}>
                              <span>${f+1}. ${s}</span>
                              ${le(s)}
                            </span>
                            <div style=${{display:"flex",gap:"var(--sp-1)"}}>
                              <button
                                type="button"
                                class="btn-ghost"
                                aria-label=${`${s} 위로 이동`}
                                disabled=${f===0}
                                onClick=${()=>{ye($=>$?{...$,candidates:An($.candidates,f,"up")}:null),Se()}}
                              >
                                ↑
                              </button>
                              <button
                                type="button"
                                class="btn-ghost"
                                aria-label=${`${s} 아래로 이동`}
                                disabled=${f===re.candidates.length-1}
                                onClick=${()=>{ye($=>$?{...$,candidates:An($.candidates,f,"down")}:null),Se()}}
                              >
                                ↓
                              </button>
                              <button
                                type="button"
                                class="btn-ghost"
                                aria-label=${`${s} 후보 제거`}
                                style=${{color:"var(--err-fg)"}}
                                onClick=${()=>{ye($=>$?{...$,candidates:$.candidates.filter((D,H)=>H!==f)}:null),Se()}}
                              >
                                ×
                              </button>
                            </div>
                          </div>
                        `)}

                        <div style=${{display:"flex",gap:"var(--sp-2)",flexWrap:"wrap",alignItems:"center"}}>
                          <input
                            type="text"
                            list="lane-runtime-candidates"
                            aria-label="추가할 후보 Runtime ID"
                            placeholder="provider.model-id"
                            value=${re.newCandidate}
                            onInput=${s=>{const f=s.target.value;ye($=>$?{...$,newCandidate:f}:null)}}
                            onKeyDown=${s=>{if(!(s.isComposing||s.keyCode===229)&&s.key==="Enter"){s.preventDefault();const f=re.newCandidate.trim();if(!f)return;ye($=>$?$.candidates.includes(f)?{...$,newCandidate:""}:{...$,candidates:[...$.candidates,f],newCandidate:""}:null),Se()}}}
                            class="mono"
                            style=${{flex:"1 1 200px",minWidth:0,minHeight:"var(--btn-h, 32px)",padding:"var(--sp-1) var(--sp-2)",background:"var(--input-bg)",border:"1px solid var(--input-border)",borderRadius:"var(--radius-sm)"}}
                          />
                          ${le(re.newCandidate.trim())}
                          <button
                            type="button"
                            class="btn-ghost"
                            onClick=${()=>{const s=re.newCandidate.trim();s&&(ye(f=>f?f.candidates.includes(s)?{...f,newCandidate:""}:{...f,candidates:[...f.candidates,s],newCandidate:""}:null),Se())}}
                          >
                            + 후보 추가
                          </button>
                        </div>
                      </div>

                      <div style=${{display:"flex",gap:"var(--sp-2)",justifyContent:"flex-end"}}>
                        <button type="submit" class="btn-primary" disabled=${oe==="lane-preview"}>
                          ${oe==="lane-preview"?"검증 중…":"Diff 미리보기 (Preview)"}
                        </button>
                      </div>
                    </form>
                  `}

                  ${Y&&a`
                    <div
                      data-testid="lane-delete-confirm"
                      role="alert"
                      style=${{display:"flex",alignItems:"center",justifyContent:"space-between",gap:"var(--sp-2)",flexWrap:"wrap",padding:"var(--sp-2) var(--sp-3)",borderRadius:"var(--radius-sm)",border:"1px solid var(--err-border)",background:"var(--err-soft)"}}
                    >
                      <span style=${{fontSize:"var(--fs-12)",color:"var(--err-fg)"}}>
                        <strong>${Y.id}</strong> (${Y.kind}) 레인을 <code>runtime.toml</code>에서 삭제할까요?
                      </span>
                      <div style=${{display:"flex",gap:"var(--sp-2)"}}>
                        <button type="button" class="btn-ghost" onClick=${()=>Re(null)}>취소</button>
                        <button
                          type="button"
                          class="btn-primary"
                          disabled=${oe==="lane-preview"}
                          onClick=${()=>{S(Y.kind,Y.id)}}
                        >
                          삭제 Diff 미리보기
                        </button>
                      </div>
                    </div>
                  `}

                  ${ie&&a`
                    <div
                      data-testid="lane-diff-preview"
                      style=${{display:"flex",flexDirection:"column",gap:"var(--sp-2)",padding:"var(--sp-3)",borderRadius:"var(--radius-sm)",border:"1px solid var(--info-border)",background:"var(--bg-1)"}}
                    >
                      <div class="wka-h" style=${{marginBottom:0}}>
                        <strong style=${{fontSize:"var(--fs-12)"}}>Unified Diff 미리보기 · ${ie.label}</strong>
                        <div style=${{display:"flex",gap:"var(--sp-2)"}}>
                          <button type="button" class="btn-ghost" onClick=${()=>Se()}>취소</button>
                          <button
                            type="button"
                            class="btn-primary"
                            disabled=${!ie.canSave||oe==="lane-apply"}
                            onClick=${()=>{X()}}
                          >
                            ${oe==="lane-apply"?"저장 중…":"변경 적용 (CAS Save)"}
                          </button>
                        </div>
                      </div>
                      ${ie.runtimeValidation&&a`
                        <div class="ap-error" role="alert">런타임 검증 오류: ${ie.runtimeValidation}</div>
                      `}
                      ${ie.validationIssues.length>0&&a`
                        <div class="ap-error" role="alert" data-testid="lane-validation-issues">
                          ${ie.validationIssues.map((s,f)=>a`
                            <div key=${f}>스키마 검증 오류: ${s}</div>
                          `)}
                        </div>
                      `}
                      ${!ie.canSave&&!ie.runtimeValidation&&ie.validationIssues.length===0&&a`
                        <div class="ap-error" role="alert">서버 미리보기 검증(can_save=false)을 통과하지 못해 저장할 수 없습니다.</div>
                      `}
                      <pre
                        class="mono"
                        style=${{margin:0,padding:"var(--sp-2)",background:"var(--bg-0)",border:"1px solid var(--line-1)",borderRadius:"var(--radius-sm)",fontSize:"var(--fs-11)",overflowX:"auto",lineHeight:1.45}}
                      >
                        ${ie.diff}
                      </pre>
                    </div>
                  `}
                </section>
              </div>
            `}
          </section>

          <!-- Virtualized Probes DataTable (<1,000 DOM even with 200+ probes!) -->
          <section style=${{display:"flex",flexDirection:"column",gap:"var(--sp-2)",minWidth:0}}>
            <div style=${{display:"flex",alignItems:"center",justifyContent:"space-between",gap:"var(--sp-2)",flexWrap:"wrap"}}>
              <div class="ap-viewseg" role="group" aria-label="프로브 범위 필터">
                <button type="button" class=${`ap-viewbtn ${h==="all"?"on":""}`} onClick=${()=>m("all")}>
                  전체 (${P.all.length})
                </button>
                <button type="button" class=${`ap-viewbtn ${h==="active_lane"?"on":""}`} onClick=${()=>m("active_lane")}>
                  활성 레인 (${P.active.length})
                </button>
                <button type="button" class=${`ap-viewbtn ${h==="outside_lane"?"on":""}`} onClick=${()=>m("outside_lane")}>
                  외부 레인 (${P.outside.length})
                </button>
              </div>
              <span class="mono" style=${{fontSize:"var(--fs-11)",color:"var(--fg-3)"}}>
                ${lt?`상태: ${lt.refresh_state} · 캐시 ${lt.cache_hit?"HIT":"MISS"}`:"대기 중"}
              </span>
            </div>

            <!-- The track below keeps a 640px minimum, so narrow screens scroll it
                 sideways. A focusable named region lets keyboard users scroll
                 to the right-hand columns; its rows hold no focusable controls. -->
            <div
              class="wka-card v2-failover-probes-scroll"
              data-testid="failover-probes-list"
              tabIndex=${0}
              role="region"
              aria-label="런타임 프로브 표"
              style=${{padding:0,overflowX:"auto",minWidth:0}}
            >
              <div class="v2-failover-probes-track">
              <div
                class="mono"
                aria-hidden="true"
                style=${{display:"grid",gridTemplateColumns:"78px minmax(0, 1.2fr) minmax(0, 1.2fr) minmax(170px, 1fr) 64px 76px",gap:"var(--sp-2)",padding:"var(--sp-2) var(--sp-3)",background:"var(--bg-2)",borderBottom:"1px solid var(--line-1)",fontSize:"var(--fs-11)",color:"var(--fg-3)",fontWeight:600}}
              >
                <span>대역</span>
                <span>RUNTIME ID</span>
                <span>제공자 / 모델</span>
                <span>프로브 · 상태</span>
                <span style=${{textAlign:"right"}}>HTTP</span>
                <span style=${{textAlign:"right"}}>지연</span>
              </div>
              <${Pn}
                items=${gt}
                estimateSize=${44}
                height=${400}
                ariaLabel="런타임 프로브 목록"
                getItemKey=${s=>`${s.scopeBand}:${s.runtime_id}`}
                empty=${a`
                  ${n?ke.kind==="failed"?a`<div class="ap-error" role="alert" style=${{margin:"var(--sp-3)"}}>런타임 프로브 조회 실패: ${ke.error.message}</div>`:a`
                        <div class="dtable-absent" style=${{padding:"var(--sp-4)"}}>
                          ${ke.kind==="loading"?"프로브 불러오는 중…":"표시할 런타임 프로브가 없습니다."}
                        </div>
                      `:a`<div class="dtable-absent" data-testid="failover-probes-mode-notice" style=${{padding:"var(--sp-4)"}}>런타임 프로브(/api/v1/dashboard/runtime-probe)는 single_user 모드에서 제공됩니다.</div>`}
                `}
                renderItem=${s=>{const f=dt.get(s.runtime_id),$=f?sn(f,z):null,D=ht.has(s.provider_id),H=$?.tone==="bad"?"var(--err)":$!==null||D?"var(--warn)":null;return a`
                    <div
                      data-probe-runtime=${s.runtime_id}
                      data-provider-attention=${D?"true":void 0}
                      style=${{display:"grid",gridTemplateColumns:"78px minmax(0, 1.2fr) minmax(0, 1.2fr) minmax(170px, 1fr) 64px 76px",gap:"var(--sp-2)",alignItems:"center",height:"44px",padding:"0 var(--sp-3)",borderBottom:"1px solid var(--line-1)",borderLeft:H?`3px solid ${H}`:void 0,fontSize:"var(--fs-12)",minWidth:0}}
                    >
                      <span
                        class="mono"
                        style=${{fontSize:"var(--fs-10)",padding:"var(--sp-0) var(--sp-1)",borderRadius:"var(--radius-pill)",background:s.scopeBand==="active_lane"?"var(--brass-soft)":"var(--idle-soft)",color:s.scopeBand==="active_lane"?"var(--brass-1)":"var(--fg-3)",textAlign:"center"}}
                      >
                        ${s.scopeBand==="active_lane"?"ACTIVE":"OUTSIDE"}
                      </span>
                      <span class="mono" style=${{display:"inline-flex",alignItems:"center",gap:"var(--sp-1)",overflow:"hidden",minWidth:0}}>
                        <span style=${{overflow:"hidden",textOverflow:"ellipsis",whiteSpace:"nowrap"}}>${s.runtime_id}</span>
                        ${se(dn(f),`probe-${s.runtime_id}`)}
                      </span>
                      <span style=${{overflow:"hidden",textOverflow:"ellipsis",whiteSpace:"nowrap",color:D?"var(--warn-fg)":"var(--fg-2)"}}>
                        ${s.provider_display_name} · <span class="mono" style=${{fontSize:"var(--fs-11)",color:"var(--fg-3)"}}>${s.model_id}</span>
                      </span>
                      <span style=${{display:"inline-flex",alignItems:"center",gap:"var(--sp-1)",minWidth:0,overflow:"hidden"}}>
                        <span class="mono" style=${{...on(s.status),padding:"var(--sp-0) var(--sp-2)",borderRadius:"var(--radius-pill)",fontSize:"var(--fs-11)",whiteSpace:"nowrap"}}>
                          ${s.status}
                        </span>
                        ${$&&a`
                          <span
                            data-testid=${`probe-liveness-${s.runtime_id}`}
                            data-liveness-kind=${$.kind}
                            class="mono"
                            style=${{...Tt($.tone),padding:"var(--sp-0) var(--sp-1)",borderRadius:"var(--radius-pill)",fontSize:"var(--fs-10)",fontWeight:600,whiteSpace:"nowrap"}}
                          >
                            ${$.label}
                          </span>
                        `}
                      </span>
                      <span class="mono tnum" style=${{textAlign:"right",color:s.http_status===null?"var(--fg-4)":"var(--fg-1)"}}>
                        ${s.http_status===null?"미보고":s.http_status}
                      </span>
                      <span class="mono tnum" style=${{textAlign:"right",color:s.latency_ms===null?"var(--fg-4)":"var(--fg-1)"}}>
                        ${s.latency_ms===null?"미보고":Zt(s.latency_ms)}
                      </span>
                    </div>
                  `}}
              />
              </div>
            </div>
          </section>
        </div>
      `}

      ${c==="exact"&&a`
        <div style=${{display:"flex",flexDirection:"column",gap:"var(--sp-3)",minWidth:0}}>
          ${r?a`
                <div class="wka-card" data-testid="exact-runs-admin-locked" role="status" style=${{fontSize:"var(--fs-13)",color:"var(--fg-2)"}}>
                  Exact Output 실행 이력(<span class="mono">/api/v1/dashboard/exact-lane-runs</span>)은 관리자 전용입니다.
                </div>
              `:a`
                <div style=${{display:"flex",alignItems:"center",justifyContent:"space-between",gap:"var(--sp-2)",flexWrap:"wrap"}}>
                  <div class="ap-viewseg" role="group" aria-label="Exact 실행 종류 필터">
                    ${["all","exact_output","task_verification","goal_verification"].map(s=>a`
                      <button
                        key=${s}
                        type="button"
                        class=${`ap-viewbtn ${me===s?"on":""}`}
                        onClick=${()=>{g(s),x([])}}
                      >
                        ${s==="all"?"전체":s}
                      </button>
                    `)}
                  </div>
                  <div style=${{display:"flex",alignItems:"center",gap:"var(--sp-2)"}}>
                    <span class="mono tnum" style=${{fontSize:"var(--fs-11)",color:"var(--fg-3)"}}>
                      총 ${rt(Be,s=>`${s.total}건`)} · 행 클릭으로 [⤢] 상세 열기
                    </span>
                    <button
                      type="button"
                      class="btn-ghost"
                      disabled=${C.length===0}
                      onClick=${()=>x(s=>s.slice(0,-1))}
                    >
                      ← 이전
                    </button>
                    <button
                      type="button"
                      class="btn-ghost"
                      disabled=${!b?.hasMore||!b.runs.length}
                      onClick=${()=>{const s=b?.runs[b.runs.length-1];s&&x(f=>[...f,{startedAt:s.startedAt,runId:s.runId}])}}
                    >
                      다음 →
                    </button>
                  </div>
                </div>

                ${Be.kind==="failed"&&a`
                  <div class="ap-error" role="alert">Exact Output 실행 이력 조회 실패. ${Be.error.message}</div>
                  <button type="button" class="btn-ghost self-start" onClick=${()=>ut("manual")}>다시 조회</button>
                `}
                ${Be.kind==="loading"&&a`
                  <p role="status" class="inline-flex items-center gap-2"><${Jt} size="xs" />Exact Output 실행 이력 불러오는 중…</p>
                `}
                ${(Be.kind==="absent"||Be.kind==="unreported")&&a`
                  <p role="status">서버에서 Exact Output 실행 이력을 확인할 수 없습니다.</p>
                `}
                ${b&&a`<${Ut}
                  data=${b.runs}
                  columns=${Je}
                  getRowId=${s=>s.runId}
                  onRowClick=${s=>{A(s)}}
                  virtualizeThreshold=${25}
                  maxHeight=${460}
                  caption="Exact Output 실행 이력"
                  emptyLabel="Exact Output 실행 기록이 없습니다."
                />`}
              `}
        </div>
      `}

      ${c==="fusion"&&!n&&a`
        <div class="wka-card" data-testid="fusion-mode-notice" role="status" style=${{fontSize:"var(--fs-13)",color:"var(--fg-2)"}}>
          Fusion 실행 이력 및 실행 요청(<span class="mono">/api/v1/dashboard/fusion-runs</span>)은 single_user 모드 전용입니다.
        </div>
      `}

      ${c==="fusion"&&n&&a`
        <div style=${{display:"flex",flexDirection:"column",gap:"var(--sp-3)",minWidth:0}}>
          ${d&&R&&a`
            <form
              class="wka-card"
              data-testid="fusion-launch-form"
              onSubmit=${p}
              style=${{display:"flex",flexDirection:"column",gap:"var(--sp-3)",borderColor:"var(--brass-border)"}}
            >
              <div class="wka-h">
                <h3>Fusion 패널 Fan-Out 실행 (POST /api/v1/keepers/:k/fusion)</h3>
                <button type="button" class="btn-ghost" onClick=${()=>I(!1)}>닫기</button>
              </div>
              <div style=${{display:"grid",gridTemplateColumns:"repeat(auto-fit, minmax(180px, 1fr))",gap:"var(--sp-2)"}}>
                <label style=${{display:"flex",flexDirection:"column",gap:"var(--sp-1)",fontSize:"var(--fs-12)"}}>
                  <span>Keeper</span>
                  <input
                    type="text"
                    required
                    value=${w}
                    onInput=${s=>Q(s.target.value)}
                    style=${{padding:"var(--sp-1) var(--sp-2)",background:"var(--input-bg)",border:"1px solid var(--input-border)",borderRadius:"var(--radius-sm)"}}
                  />
                </label>
                <label style=${{display:"flex",flexDirection:"column",gap:"var(--sp-1)",fontSize:"var(--fs-12)"}}>
                  <span>토폴로지 (닫힌 합타입)</span>
                  <select
                    value=${Ye}
                    onChange=${s=>nt(s.target.value)}
                    style=${{padding:"var(--sp-1) var(--sp-2)",background:"var(--input-bg)",border:"1px solid var(--input-border)",borderRadius:"var(--radius-sm)"}}
                  >
                    ${Da.map(s=>a`<option key=${s.value} value=${s.value}>${s.label}</option>`)}
                  </select>
                </label>
                <label style=${{display:"flex",flexDirection:"column",gap:"var(--sp-1)",fontSize:"var(--fs-12)"}}>
                  <span>프리셋 (선택)</span>
                  <input
                    type="text"
                    placeholder="기본 프리셋"
                    value=${Ve}
                    onInput=${s=>ct(s.target.value)}
                    style=${{padding:"var(--sp-1) var(--sp-2)",background:"var(--input-bg)",border:"1px solid var(--input-border)",borderRadius:"var(--radius-sm)"}}
                  />
                </label>
              </div>
              <label style=${{display:"flex",flexDirection:"column",gap:"var(--sp-1)",fontSize:"var(--fs-12)"}}>
                <span>패널 질문 (Free Text)</span>
                <textarea
                  rows=${3}
                  required
                  value=${V}
                  onInput=${s=>We(s.target.value)}
                  style=${{padding:"var(--sp-2)",background:"var(--input-bg)",border:"1px solid var(--input-border)",borderRadius:"var(--radius-sm)",resize:"vertical"}}
                />
              </label>
              <div style=${{display:"flex",alignItems:"center",justifyContent:"space-between",flexWrap:"wrap",gap:"var(--sp-2)"}}>
                <label style=${{display:"inline-flex",alignItems:"center",gap:"var(--sp-1)",fontSize:"var(--fs-12)"}}>
                  <input
                    type="checkbox"
                    checked=${pt}
                    onChange=${s=>De(s.target.checked)}
                  />
                  <span>web_tools 허용</span>
                </label>
                <button type="submit" class="btn-primary" disabled=${oe==="fusion"}>
                  ${oe==="fusion"?"실행 중…":"Fusion 실행"}
                </button>
              </div>
            </form>
          `}

          <div class="v2-sync-toolbar">
            <button
              type="button"
              class="btn-ghost"
              disabled=${He.kind==="loading"}
              onClick=${()=>{Mt("manual")}}
            >
              Fusion 이력 새로고침
            </button>
            <div class="v2-sync-slot">
              ${He.kind==="loading"&&a`
                <span class="v2-sync-pill v2-sync-pill--info" role="status" title="Fusion 실행 이력 불러오는 중…">
                  <${Jt} size="xs" />
                  <span class="v2-sync-pill-text">Fusion 실행 이력 불러오는 중…</span>
                </span>
              `}
              ${st&&a`
                <span
                  class="v2-sync-pill v2-sync-pill--warn"
                  role="status"
                  title="Fusion 실행 이력을 새로고침하고 있습니다. 목록은 마지막 관측입니다."
                >
                  <span class="v2-sync-pill-text">새로고침 중 · 마지막 관측</span>
                </span>
              `}
              ${B&&!kt&&!st&&a`
                <span
                  class="v2-sync-pill"
                  role="status"
                  title="실시간 연결을 기다리는 중입니다. 목록은 마지막 관측입니다."
                >
                  <span class="v2-sync-pill-text">실시간 연결 대기 · 마지막 관측</span>
                </span>
              `}
            </div>
          </div>
          ${He.kind==="failed"&&a`
            <div class="ap-error" role="alert">Fusion 실행 이력 조회 실패. ${He.error.message}</div>
          `}
          ${(He.kind==="absent"||He.kind==="unreported")&&a`
            <p role="status">서버에서 Fusion 실행 이력을 확인할 수 없습니다.</p>
          `}
          ${B&&a`<${Ut}
            data=${B.runs}
            columns=${zt}
            getRowId=${s=>s.runId}
            onRowClick=${i}
            virtualizeThreshold=${25}
            maxHeight=${440}
            caption="Fusion 실행 목록"
            emptyLabel=${st?"마지막으로 확인한 실행은 없습니다.":"Fusion 실행 이력이 없습니다."}
          />`}
        </div>
      `}
    </div>
  `}const Qs=[{label:"도구 호출 수",colorToken:"--info-fg",width:2,fillAlpha:.14},{label:"실패 수",colorToken:"--err-fg",width:2,fillAlpha:.1}];function Ln(e,t,n){const r=typeof n.call_count=="number"&&Number.isFinite(n.call_count)?n.call_count:typeof n.calls=="number"&&Number.isFinite(n.calls)?n.calls:0,l=typeof n.success_count=="number"&&Number.isFinite(n.success_count),d=l?n.success_count:0,c=typeof n.failure_count=="number"&&Number.isFinite(n.failure_count)?n.failure_count:0,v=typeof n.deferred_count=="number"&&Number.isFinite(n.deferred_count),h=v?n.deferred_count:0,m=typeof n.p95_ms=="number"&&Number.isFinite(n.p95_ms)&&r>0?n.p95_ms:null,k=e.get(t);k?(k.calls+=r,k.successCount+=d,k.hasSuccessCount=k.hasSuccessCount&&l,k.failureCount+=c,k.deferredCount+=h,k.hasDeferredCount=k.hasDeferredCount&&v,m!==null&&(k.p95Ms=k.p95Ms===null?m:Math.max(k.p95Ms,m))):e.set(t,{calls:r,successCount:d,hasSuccessCount:l,failureCount:c,deferredCount:h,hasDeferredCount:v,p95Ms:m})}function Xs(e){const t=new Map;if(!e||typeof e!="object"||Array.isArray(e))return t;const n=e,r=Array.isArray(n.by_tool)?n.by_tool:Array.isArray(n.top_20)?n.top_20:[];for(const l of r){if(!l||typeof l!="object"||Array.isArray(l))continue;const d=l,c=typeof d.name=="string"&&d.name.trim()?d.name.trim():null;if(c&&Ln(t,c,d),Array.isArray(d.public_names))for(const v of d.public_names)typeof v=="string"&&v.trim()&&v.trim()!==c&&Ln(t,v.trim(),d)}return t}function Zs(e){if(!e||typeof e!="object")return{rows:[],isWarming:!1};const t=e,n=t.is_warming===!0,r=t.tool_inventory&&typeof t.tool_inventory=="object"&&!Array.isArray(t.tool_inventory)?t.tool_inventory:null,l=r&&Array.isArray(r.tools)?r.tools:Array.isArray(t.tools)?t.tools:Array.isArray(t.entries)?t.entries:Array.isArray(e)?e:[],d=Xs(t.tool_usage);return{rows:l.filter(v=>typeof v=="object"&&v!==null).map(v=>{const h=typeof v.name=="string"?v.name:String(v.tool??"unknown"),m=d.get(h),k=typeof v.calls=="number"?v.calls:typeof v.call_count=="number"?v.call_count:null,q=k??(m?m.calls:null),z=typeof v.failure_count=="number"?v.failure_count:m?m.failureCount:0,T=typeof v.deferred_count=="number"&&Number.isFinite(v.deferred_count),ue=T?v.deferred_count:m?m.deferredCount:0,W=typeof v.success_count=="number"&&Number.isFinite(v.success_count),oe=W?v.success_count:m?m.successCount:0,fe=T||!!m?.hasDeferredCount,U=W||!!m?.hasSuccessCount,ae=typeof v.failure_rate=="number"?v.failure_rate:typeof v.failure_rate_pct=="number"?v.failure_rate_pct:null,Ae=fe&&q!==null?Math.max(0,q-ue):U?oe+z:q!==null?Math.max(0,q-ue):0,O=ae??((m||k!==null)&&Ae>0?z/Ae*100:null),te=typeof v.p95_ms=="number"?v.p95_ms:m?m.p95Ms:null;return{name:h,description:typeof v.description=="string"?v.description:null,calls:q,failure_count:z,deferred_count:ue,failure_rate:O,p95_ms:te,domain:typeof v.domain=="string"?v.domain:void 0,family:typeof v.family=="string"?v.family:typeof v.category=="string"?v.category:void 0}}),isWarming:n}}function er({onInspect:e}){const t=vn.value,n=be.value,r=n.kind==="single_user_local",l=n.kind==="multi_account_signed_in",d=ot("admin",n),c=r&&!d,v=r&&n.role!=="player",h=r?zn.value:null,m=tt.value,[k,q]=_("catalog"),[z,T]=_(""),[ue,W]=_(null),[oe,fe]=_(!1),[U,ae]=_(null),[Ae,O]=_(null),[te,Ee]=_(null),[je,ze]=_(""),[Ke,pe]=_(!0),[G,Ie]=_("read_only"),[J,K]=_(null),[_e,L]=_(!1),[F,ge]=_(null),[j,Oe]=_([]),[E,re]=_(""),[ye,Y]=_([]),[Re,ie]=_(null),[he,Ge]=_(!1),[Ce,me]=_(null),[g,C]=_(null),[x,u]=_(!1),R=Me(null),I=Me(null),w=Me(null),Q=Me(null),V=Me(!0),We=Me("");ve(()=>(V.current=!0,()=>{V.current=!1,Q.current?.abort()}),[]);const Ve=i=>i!==null&&i===I.current&&i.epoch===tt.peek(),ct=i=>{const p=i.trim(),b=I.current;(!b||b.keeper!==p||b.epoch!==m)&&(I.current={keeper:p,epoch:m},R.current?.cancel(),w.current?.abort(),me(null),C(null),u(!1),Y([]),ie(null),Ge(!1),O(null)),re(i)};ve(()=>(ct(""),Oe([]),()=>{I.current=null,R.current?.cancel(),w.current?.abort()}),[m]),ve(()=>{c||(Q.current?.abort(),R.current?.cancel(),Ee(null),ze(""),K(null),L(!1),me(null),C(null),u(!1))},[c]),ve(()=>{v||ge(null)},[v]);const Ye=t==="24h"?24:t==="7d"?168:720,nt=t==="24h"?"hour":"day",pt=`runtime:tools-series:${t}`,De=N.observe(pt).value,we=N.observe("runtime:dashboard-tools").value,ke=N.observe("runtime:skills").value,at=N.observe("runtime:gate-connectors").value,Be=N.observe("runtime:mcp-clients").value,He=Un(),Se=(i="mount")=>be.peek().kind!=="single_user_local"?Promise.resolve(null):N.fetch(pt,p=>$e(`/api/v1/tool-metrics/series?since_hours=${Ye}&bucket=${nt}&utc_offset_min=${He}`,{signal:p,decode:cn}),{ttlMs:15e3,topics:["tool_metrics","tools"],reason:i}),vt=(i,p="mount")=>{const b=be.peek(),B=b.kind==="single_user_local",ne=b.kind==="multi_account_signed_in";return i==="catalog"?!B&&!ne?Promise.resolve(null):N.fetch("runtime:dashboard-tools",se=>$e("/api/v1/dashboard/tools",{signal:se}),{ttlMs:2e4,topics:["tools","tool_metrics","skills","async_requests"],reason:p}):B?i==="skills"?N.fetch("runtime:skills",se=>$e("/api/v1/skills",{signal:se}),{ttlMs:2e4,topics:["skills","skill_usage","skill_activations"],reason:p}):i==="connectors"?N.fetch("runtime:gate-connectors",se=>$e("/api/v1/gate/connectors",{signal:se}),{ttlMs:15e3,topics:["connectors","gate","gate_connector_changed"],reason:p}):i==="clients"?N.fetch("runtime:mcp-clients",se=>$e("/api/v1/dashboard/clients",{signal:se}),{ttlMs:15e3,topics:["clients","ide_presence"],reason:p}):Promise.resolve(null):Promise.resolve(null)};ve(()=>{W(null),r&&Se("mount")},[t,m,r]),ve(()=>{if(ae(null),t!=="24h"||!h){fe(!1);return}const i=Dn("runtime-tools",p=>{qn(`/api/v1/tool-metrics/series/stream?since_hours=24&bucket=hour&utc_offset_min=${He}`,p,b=>{if(b.data&&typeof b.data=="object"){const B=b.data;if(typeof B.error=="string"&&B.error.trim().length>0){fe(!1),O({kind:"err",text:`도구 지표 스트림 오류: ${B.error}`});return}if("buckets"in B)try{const ne=cn(b.data);W(ne),ae(null),fe(!0)}catch(ne){ae(ne instanceof Error?ne.message:String(ne))}}},b=>{fe(b==="open")})});return()=>{i.release()}},[t,h,m]),ve(()=>{const i=new Set(["tools","tool_metrics","skills","async_requests","skill_usage","skill_activations","gate_connector_changed","gate","connectors","ide_presence","clients","dataset_invalidation"]);let p=null;const b=()=>{!V.current||!Z(m)||Promise.all([Se("sse"),vt(k,"sse")]).then(()=>{V.current&&Z(m)&&Lt()})},B=At(le=>{Et(le).some(s=>i.has(s))&&(p!==null&&clearTimeout(p),p=setTimeout(()=>{p=null,b()},400))}),ne=Kt(b),se=Ot(b);return()=>{p!==null&&clearTimeout(p),B(),ne(),se()}},[k,t,m]),ve(()=>{if(k!=="oauth")vt(k,"mount");else if(k==="oauth"){if(!r)return;let i=!1;return(async()=>{let p=I.current?.keeper??"";if(j.length===0||!p){const b=new Set,B=[],ne=se=>{if(typeof se!="string")return;const le=se.trim();le&&!b.has(le)&&(b.add(le),B.push(le))};if(v){const se=await $e("/api/v1/gate/keepers");if(i)return;if(se.ok&&Array.isArray(se.value.keepers))for(const le of se.value.keepers)ne(le?.name)}if(B.length===0){const se=await $e("/api/v1/dashboard/shell");if(i)return;if(se.ok){if(Array.isArray(se.value.groups)){for(const le of se.value.groups)if(Array.isArray(le?.keepers))for(const s of le.keepers)ne(s)}if(Array.isArray(se.value.keepers))for(const le of se.value.keepers)ne(le?.name)}}p=I.current?.keeper??"",B.length>0&&(Oe(B),(!p||!B.includes(p))&&(p=B[0],ct(p)))}!i&&p&&it(p)})(),()=>{i=!0}}},[k,m,r,l,v]);const it=async i=>{if(be.peek().kind!=="single_user_local")return;const p=I.current;if(!p?.keeper||p.keeper!==i.trim()||!Ve(p))return;w.current?.abort();const b=new AbortController;w.current=b,Ge(!0);const B=await $e(`/api/v1/keepers/oauth/attached-tools?keeper=${encodeURIComponent(p.keeper)}`,{signal:b.signal});b.signal.aborted||!Ve(p)||(Ge(!1),B.ok?(Y(B.value.providers??[]),ie(typeof B.value.callback?.url=="string"?B.value.callback.url:null)):(Y([]),O({kind:"err",text:`OAuth 도구 조회 실패: ${B.error.message}`})))},Fe=r?t==="24h"&&h&&ue?ue:De.kind==="value"?De.data:null:null,ut=r&&t==="24h"&&h!==null&&oe,de=r&&!Fe?Kn(De):null,lt=r?ut?"● LIVE SSE (tool-metrics)":de?"○ UNAVAILABLE":De.kind==="loading"&&!Fe?"◐ LOADING":`○ SNAPSHOT (${t})`:"○ SINGLE-USER ONLY",dt=ce(()=>{if(!Fe)return[[],[],[]];const i=Fe.buckets??[];return[i.map(p=>p.start),i.map(p=>p.call_count),i.map(p=>p.failure_count)]},[Fe]),ht=ce(()=>we.kind==="value"?Zs(we.data):{rows:[],isWarming:!1},[we]),P=ce(()=>{const i=ht.rows,p=z.trim().toLowerCase();return p?i.filter(b=>b.name.toLowerCase().includes(p)||(b.description??"").toLowerCase().includes(p)):i},[ht,z]),gt=ce(()=>[{id:"name",header:"도구 이름",sortable:!0,sortValue:i=>i.name,cell:i=>a`<span class="mono" style=${{fontSize:"var(--fs-12)"}}>${i.name}</span>`},{id:"desc",header:"설명",cell:i=>{const p=i.description;return p?a`
          <button type="button" class="btn-ghost btn-compact" aria-label=${`${i.name} 설명 읽기`} onClick=${()=>e({title:i.name,kind:"tool-description",render:()=>a`<${ln} text=${p} />`})}>설명 읽기</button>
        `:"없음"}},{id:"calls",header:"호출 수",numeric:!0,sortable:!0,observed:i=>Ft(i.calls,!0),formatValue:i=>Rt(Number(i))},{id:"failRate",header:"실패율",numeric:!0,sortable:!0,observed:i=>Ft(i.failure_rate,!0),formatValue:i=>Pt(Number(i))},{id:"p95",header:"p95",numeric:!0,sortable:!0,observed:i=>Ft(i.p95_ms,!0),formatValue:i=>Zt(Number(i))}],[e]),yt=ce(()=>[{id:"name",header:"클라이언트",sortable:!0,accessor:i=>i.name},{id:"keeper",header:"바인딩 Keeper",cell:i=>i.keeper_name?a`<${Xt} id=${i.keeper_name} size="sm" />`:a`<span class="dtable-absent">없음</span>`},{id:"status",header:"상태",accessor:i=>i.status},{id:"lastSeen",header:"최근 관측",numeric:!0,cell:i=>a`<span class="mono tnum" style=${{fontSize:"var(--fs-11)",color:"var(--fg-3)"}}>${Wa(i.last_seen)}</span>`}],[]),Qe=i=>i?`${i.identity.source_id}:${i.identity.package_id}:${i.identity.name}`:"";We.current=Qe(te);const Je=()=>{const i=be.peek();return i.kind==="single_user_local"&&!ot("admin",i)},st=()=>{const i=be.peek();return i.kind==="single_user_local"&&i.role!=="player"},kt=async i=>{if(!Je())return;Q.current?.abort();const p=new AbortController;Q.current=p;const b=tt.peek(),B=Qe(i);Ee(i),pe(!0),ze(""),K(null),L(!0);const ne=await Pe("POST","/api/v1/skills/editor/read",{reference:{identity:i.identity,content_revision:i.content_revision}},{signal:p.signal});if(!(!V.current||p.signal.aborted||tt.peek()!==b||We.current!==B)){if(L(!1),!ne.ok){O({kind:"err",text:`SKILL.md 읽기 실패: ${ne.error.message}`}),ze("");return}ze(ne.value.source_text??""),Ie(ne.value.access??"read_only")}},zt=async()=>{if(!Je()||!te)return;const i=tt.peek(),p=Qe(te);L(!0);const b=await Pe("POST","/api/v1/skills/editor/preview",{reference:{identity:te.identity,content_revision:te.content_revision},source_text:je});if(!V.current||tt.peek()!==i||We.current!==p)return;if(L(!1),!b.ok){K(`검증 오류: ${b.error.message}`);return}const B=b.value.preview?.diagnostics??[];K(B.length===0?"검증 통과 (경고 0건)":`진단: ${B.join(" · ")}`)},$t=async()=>{if(!Je()||!te)return;const i=tt.peek(),p=Qe(te);L(!0);const b=await Pe("POST","/api/v1/skills/editor/save",{reference:{identity:te.identity,content_revision:te.content_revision},source_text:je});if(!V.current||tt.peek()!==i)return;if(L(!1),!b.ok){O({kind:"err",text:b.error.kind==="conflict_cas"?"스킬 리비전 충돌 (409) — 스킬 목록을 새로고침 후 다시 편집하세요.":`스킬 저장 실패: ${b.error.message}`});return}O(null),qe(`SKILL.md 저장 완료 (${b.value.status??"saved"}).`,"success");const B=await N.fetch("runtime:skills",ne=>$e("/api/v1/skills",{signal:ne}),{reason:"manual"});if(!(!V.current||tt.peek()!==i)&&B.kind==="value"){const ne=B.data.snapshot?.skills?.find(se=>Qe(se)===p);ne&&Ee(se=>Qe(se)===p?ne:se)}},xt=async i=>{if(i.preventDefault(),!st()||!F||!F.channelId.trim()||!F.keeperName.trim())return;const p=xe(),b=F,B=await Pe("POST",`/api/v1/gate/connector/bind?name=${encodeURIComponent(b.connectorId)}`,{channel_id:b.channelId.trim(),keeper_name:b.keeperName.trim()});if(!(!V.current||!Z(p))){if(!B.ok){O({kind:"err",text:`커넥터 바인딩 실패: ${B.error.message}`});return}O(null),qe(`${b.connectorId} 바인딩 완료.`,"success"),ge(null),N.fetch("runtime:gate-connectors",ne=>$e("/api/v1/gate/connectors",{signal:ne}),{reason:"manual"})}},_t=async(i,p)=>{if(!st())return;const b=xe(),B=await Pe("POST",`/api/v1/gate/connector/unbind?name=${encodeURIComponent(i)}`,{channel_id:p});if(!(!V.current||!Z(b))){if(!B.ok){O({kind:"err",text:`바인딩 해제 실패: ${B.error.message}`});return}O(null),qe(`${i} 채널 ${p} 해제됨.`,"success"),N.fetch("runtime:gate-connectors",ne=>$e("/api/v1/gate/connectors",{signal:ne}),{reason:"manual"})}},o=i=>{if(!Je())return;const p=E.trim();if(!p){O({kind:"err",text:"먼저 대상 Keeper를 선택하세요."});return}const b=I.current;if(!b||b.keeper!==p||!Ve(b))return;R.current?.cancel(),O(null);const B=i.provider_label??i.provider,ne={keeper:p,providerLabel:B,onUpdate:se=>{Ve(b)&&me(se)},onSettled:se=>{se&&Ve(b)&&it(p)}};R.current=i.provider==="github"?va(ne):fa({...ne,provider:i.provider})},S=async i=>{if(i.preventDefault(),!Je()||!g||!g.clientId.trim())return;const p=I.current;u(!0);const b=await pa({provider:g.provider,clientId:g.clientId,clientSecret:g.clientSecret,scopes:g.scopes});if(Ve(p)){if(u(!1),!b.ok){O({kind:"err",text:`OAuth 앱 등록 실패: ${b.error.message}`});return}O(null),qe(`${g.providerLabel} OAuth 앱이 등록되었습니다. 이제 바로 연결할 수 있습니다.`,"success"),C(null),E.trim()&&it(E)}},y=async(i,p)=>{if(!Je())return;const b=I.current,B=await Pe("POST",`/api/v1/keepers/${encodeURIComponent(E)}/identity-switch`,{provider:i,enabled:p});if(Ve(b)){if(!B.ok){O({kind:"err",text:`스위치 전환 실패: ${B.error.message}`});return}it(E)}},X=async i=>{if(!Je())return;const p=I.current,b=await ma(E,i);if(Ve(p)){if(!b.ok){O({kind:"err",text:`OAuth 연결 해제 실패: ${b.error.message}`});return}O(null),qe(`${E} · ${i} 연결이 해제되었습니다.`,"success"),it(E)}},M=ke.kind==="value"?ke.data.snapshot?.skills??[]:[],ee=at.kind==="value"?at.data.connectors??[]:[],A=Be.kind==="value"?Be.data.clients??[]:[];return a`
    <div class="ov" data-testid="runtime-tools-tab">
      <header class="ov-head">
        <div>
          <span class="ov-eyebrow">5 RUNTIME · TOOLS, SKILLS & PLUG-INS</span>
          <h1>도구 시계열 · 스킬(SKILL.md) · 커넥터 · OAuth · MCP</h1>
        </div>
        <span
          class="mono"
          data-testid="tools-stream-badge"
          style=${{padding:"var(--sp-0) var(--sp-2)",borderRadius:"var(--radius-pill)",fontSize:"var(--fs-11)",border:`1px solid ${ut?"var(--ok-border)":"var(--line-2)"}`,background:ut?"var(--ok-soft)":"var(--bg-2)",color:ut?"var(--ok-fg)":"var(--fg-2)"}}
        >
          ${lt}
        </span>
      </header>

      ${Ae&&a`
        <div role="alert" class="ap-error">
          ${Ae.text}
        </div>
      `}
      ${U&&a`
        <div role="alert" class="ap-error">
          실시간 도구 시계열 디코드 오류: ${U}
        </div>
      `}

      <!-- 24h Tool Call & Failure Rate Chart -->
      <${It}
        id="runtime-tools-series"
        title="도구 호출 & 실패 시계열"
        subtitle=${Fe?.total?a`<span class="mono tnum" style=${{fontSize:"var(--fs-11)",color:"var(--fg-3)"}}>
              총 ${Rt(Fe.total.call_count)}회 · 실패 ${Fe.total.failure_count} · p95 ${Fe.total.p95_ms!==null?Zt(Fe.total.p95_ms):"미보고"}
            </span>`:void 0}
        data=${dt}
        series=${Qs}
        height=${185}
        syncCrosshair=${!0}
        emptyLabel=${r?de?`도구 호출 시계열 조회 실패: ${de}`:De.kind==="loading"?"도구 호출 시계열 불러오는 중…":"도구 호출 시계열 데이터 없음":"도구 호출 시계열은 single_user 모드에서 제공됩니다."}
      />

      <!-- Plug-in Surface Switcher -->
      <div class="ap-viewseg" role="tablist" aria-label="플러그인 서피스 선택" style=${{alignSelf:"flex-start",flexWrap:"wrap"}}>
        ${[["catalog","Tools 카탈로그"],["skills","Skills (SKILL.md)"],["connectors","Gate 커넥터"],["oauth","Keeper OAuth"],["clients","MCP 클라이언트"]].map(([i,p])=>a`
          <button
            key=${i}
            type="button"
            role="tab"
            aria-selected=${k===i}
            class=${`ap-viewbtn ${k===i?"on":""}`}
            onClick=${()=>q(i)}
          >
            ${p}
          </button>
        `)}
      </div>

      ${k==="catalog"&&a`
        <div style=${{display:"flex",flexDirection:"column",gap:"var(--sp-2)",minWidth:0}}>
          <input
            type="search"
            aria-label="도구 검색"
            placeholder="도구 이름 / 설명 검색…"
            value=${z}
            onInput=${i=>T(i.target.value)}
            style=${{maxWidth:"320px",padding:"var(--sp-1) var(--sp-2)",background:"var(--input-bg)",border:"1px solid var(--input-border)",borderRadius:"var(--radius-sm)"}}
          />
          ${we.kind==="failed"&&a`
            <div class="ap-error" role="alert">도구 카탈로그 조회 실패: ${we.error.message}</div>
          `}
          <${Ut}
            data=${P}
            columns=${gt}
            getRowId=${i=>i.name}
            virtualizeThreshold=${30}
            maxHeight=${400}
            caption="도구 카탈로그"
            emptyLabel=${we.kind==="failed"?`도구 카탈로그 조회 실패: ${we.error.message}`:we.kind==="loading"?"도구 불러오는 중…":ht.isWarming?"도구 카탈로그 준비 중…":"등록된 도구가 없습니다."}
          />
        </div>
      `}

      ${k!=="catalog"&&!r&&a`
        <div class="wka-card" data-testid="tools-section-mode-notice" role="status" style=${{fontSize:"var(--fs-13)",color:"var(--fg-2)"}}>
          선택한 플러그인 탭(Skills · Gate 커넥터 · Keeper OAuth · MCP 클라이언트)은 single_user 모드 전용입니다.
        </div>
      `}

      ${k==="skills"&&r&&a`
        <div style=${{display:"grid",gridTemplateColumns:"repeat(auto-fit, minmax(260px, 1fr))",gap:"var(--sp-3)",minWidth:0}}>
          <div class="wka-card" style=${{display:"flex",flexDirection:"column",gap:"var(--sp-2)"}}>
            <div class="wka-h">
              <h3>스킬 목록 (${M.length})</h3>
              <${wt}
                onRefresh=${()=>N.fetch("runtime:skills",i=>$e("/api/v1/skills",{signal:i}),{reason:"manual"})}
              />
            </div>
            ${ke.kind==="failed"?a`<div class="ap-error" role="alert">스킬 목록 조회 실패: ${ke.error.message}</div>`:M.length===0?a`<div class="dtable-absent">${ke.kind==="loading"?"스킬 불러오는 중…":"발행된 스킬이 없습니다."}</div>`:M.map(i=>a`
                  <button
                    key=${`${i.identity.source_id}:${i.identity.package_id}:${i.identity.name}`}
                    type="button"
                    class="btn-ghost"
                    disabled=${!c}
                    style=${{justifyContent:"space-between",textAlign:"left",background:Qe(te)===Qe(i)?"var(--bg-4)":void 0}}
                    onClick=${()=>{kt(i)}}
                  >
                    <span class="mono">${i.identity.name}</span>
                    <span class="mono tnum" style=${{fontSize:"var(--fs-11)",color:"var(--fg-3)"}}>${i.body_bytes}B</span>
                  </button>
                `)}
          </div>

          <div class="wka-card" style=${{display:"flex",flexDirection:"column",gap:"var(--sp-2)",minWidth:0}}>
            <div class="wka-h">
              <h3>${te?`SKILL.md · ${te.identity.name}`:"SKILL.md 뷰어 / 편집기"}</h3>
              ${c&&te&&a`
                <div style=${{display:"flex",gap:"var(--sp-1)"}}>
                  <button type="button" class="btn-ghost" aria-pressed=${!Ke} onClick=${()=>pe(i=>!i)}>
                    ${Ke?"원문":"읽기"}
                  </button>
                  <button type="button" class="btn-ghost" disabled=${_e} onClick=${zt}>미리보기 검증</button>
                  <button type="button" class="btn-primary" disabled=${_e||G!=="read_write"} onClick=${$t}>저장</button>
                </div>
              `}
            </div>
            ${c?a`
                  ${J&&a`<div class="mono" style=${{fontSize:"var(--fs-11)",color:"var(--info-fg)"}}>${J}</div>`}
                  ${te?Ke?a`<${ln} text=${je} document />`:a`
                        <textarea
                          rows=${14}
                          readOnly=${G!=="read_write"}
                          value=${je}
                          onInput=${i=>ze(i.target.value)}
                          class="mono"
                          style=${{width:"100%",padding:"var(--sp-2)",fontSize:"var(--fs-12)",background:"var(--bg-0)",border:"1px solid var(--line-1)",borderRadius:"var(--radius-sm)"}}
                        />
                      `:a`<div class="dtable-absent">왼쪽에서 스킬을 선택하면 SKILL.md 본문을 불러옵니다.</div>`}
                `:a`<div class="dtable-absent" data-testid="tools-skills-admin-locked" role="status">SKILL.md 본문 조회 및 편집은 관리자 전용입니다.</div>`}
          </div>
        </div>
      `}

      ${k==="connectors"&&r&&a`
        <div style=${{display:"flex",flexDirection:"column",gap:"var(--sp-3)"}}>
          ${v&&F&&a`
            <form class="wka-card" onSubmit=${xt} style=${{display:"flex",gap:"var(--sp-2)",flexWrap:"wrap",alignItems:"flex-end"}}>
              <strong style=${{fontSize:"var(--fs-12)"}}>${F.connectorId} 바인딩:</strong>
              <input
                type="text"
                placeholder="channel_id"
                value=${F.channelId}
                onInput=${i=>{const p=i.target.value;ge(b=>b&&{...b,channelId:p})}}
                style=${{padding:"var(--sp-1) var(--sp-2)",background:"var(--input-bg)",border:"1px solid var(--input-border)",borderRadius:"var(--radius-sm)"}}
                required
              />
              <input
                type="text"
                placeholder="keeper_name"
                value=${F.keeperName}
                onInput=${i=>{const p=i.target.value;ge(b=>b&&{...b,keeperName:p})}}
                style=${{padding:"var(--sp-1) var(--sp-2)",background:"var(--input-bg)",border:"1px solid var(--input-border)",borderRadius:"var(--radius-sm)"}}
                required
              />
              <button type="submit" class="btn-primary">바인딩</button>
              <button type="button" class="btn-ghost" onClick=${()=>ge(null)}>취소</button>
            </form>
          `}

          ${at.kind==="failed"?a`<div class="ap-error" role="alert">Gate 커넥터 조회 실패: ${at.error.message}</div>`:ee.length===0?a`<div class="wka-card dtable-absent">${at.kind==="loading"?"커넥터 불러오는 중…":"등록된 Gate 커넥터가 없습니다."}</div>`:a`
                <div style=${{display:"grid",gridTemplateColumns:"repeat(auto-fill, minmax(300px, 1fr))",gap:"var(--sp-3)"}}>
                  ${ee.map(i=>a`
                    <article key=${i.connector_id} class="wka-card" style=${{display:"flex",flexDirection:"column",gap:"var(--sp-2)"}}>
                      <div class="wka-h">
                        <h3>${i.display_name} (${i.channel})</h3>
                        <span class="mono" style=${{fontSize:"var(--fs-11)",color:i.connected?"var(--ok-fg)":"var(--warn-fg)"}}>
                          ${i.connected?"connected":i.status||"offline"}
                        </span>
                      </div>
                      ${i.error&&a`<div style=${{fontSize:"var(--fs-11)",color:"var(--err-fg)"}}>${i.error}</div>`}
                      <div style=${{display:"flex",flexDirection:"column",gap:"var(--sp-1)"}}>
                        ${(i.configured_bindings??[]).length===0?a`<span class="dtable-absent" style=${{fontSize:"var(--fs-12)"}}>바인딩 없음</span>`:(i.configured_bindings??[]).map(p=>a`
                              <div key=${`${p.channel_id}:${p.keeper_name}`} style=${{display:"flex",justifyContent:"space-between",alignItems:"center",fontSize:"var(--fs-12)"}}>
                                <span class="mono">${p.channel_id} → ${p.keeper_name}</span>
                                ${v&&a`
                                  <button type="button" class="btn-ghost" style=${{padding:"var(--sp-0) var(--sp-1)",fontSize:"var(--fs-11)"}} onClick=${()=>{_t(i.connector_id,p.channel_id)}}>
                                    Unbind
                                  </button>
                                `}
                              </div>
                            `)}
                      </div>
                      ${v&&a`
                        <button
                          type="button"
                          class="btn-ghost"
                          style=${{alignSelf:"flex-start"}}
                          onClick=${()=>ge({connectorId:i.connector_id,channelId:"",keeperName:""})}
                        >
                          + 채널 바인딩
                        </button>
                      `}
                    </article>
                  `)}
                </div>
              `}
        </div>
      `}

      ${k==="oauth"&&r&&a`
        <div class="wka-card" style=${{display:"flex",flexDirection:"column",gap:"var(--sp-3)"}}>
          ${!c&&a`
            <div class="dtable-absent" data-testid="tools-oauth-admin-locked" role="status">
              OAuth 앱 설정·연결·스위치·해제는 관리자 전용입니다. 현재 연결 상태만 조회할 수 있습니다.
            </div>
          `}
          <form
            onSubmit=${i=>{i.preventDefault(),it(E)}}
            style=${{display:"flex",gap:"var(--sp-2)",alignItems:"center",flexWrap:"wrap"}}
          >
            <label style=${{fontSize:"var(--fs-12)"}}>Keeper:</label>
            ${j.length>0?a`
                  <select
                    aria-label="OAuth 대상 Keeper"
                    value=${E}
                    onChange=${i=>{const p=i.target.value;ct(p),it(p)}}
                    style=${{padding:"var(--sp-1) var(--sp-2)",background:"var(--input-bg)",border:"1px solid var(--input-border)",borderRadius:"var(--radius-sm)"}}
                  >
                    ${j.map(i=>a`<option key=${i} value=${i}>${i}</option>`)}
                  </select>
                `:a`
                  <input
                    type="text"
                    aria-label="OAuth 대상 Keeper"
                    placeholder="Keeper 이름 입력…"
                    value=${E}
                    onInput=${i=>ct(i.target.value)}
                    style=${{padding:"var(--sp-1) var(--sp-2)",background:"var(--input-bg)",border:"1px solid var(--input-border)",borderRadius:"var(--radius-sm)"}}
                  />
                `}
            <button type="submit" class="btn-primary" disabled=${he||!E.trim()}>조회</button>
          </form>

          ${Ce&&a`
            <div
              data-testid="tools-oauth-active-flow"
              role="status"
              style=${{display:"flex",flexDirection:"column",gap:"var(--sp-2)",padding:"var(--sp-3)",borderRadius:"var(--radius-sm)",border:`1px solid ${Ce.phase==="failed"?"var(--err-border)":Ce.phase==="completed"?"var(--ok-border)":"var(--info-border)"}`,background:Ce.phase==="failed"?"var(--err-soft)":Ce.phase==="completed"?"var(--ok-soft)":"var(--info-soft)"}}
            >
              <div style=${{display:"flex",justifyContent:"space-between",alignItems:"center",gap:"var(--sp-2)"}}>
                <strong style=${{fontSize:"var(--fs-12)"}}>
                  ${Ce.providerLabel} · ${Ce.phase}
                </strong>
                <button
                  type="button"
                  class="btn-ghost"
                  onClick=${()=>{R.current?.cancel(),me(null)}}
                >
                  닫기
                </button>
              </div>
              <div style=${{fontSize:"var(--fs-12)"}}>${Ce.message}</div>
              <div style=${{display:"flex",alignItems:"center",gap:"var(--sp-2)",flexWrap:"wrap"}}>
                ${Ce.authorizeUrl&&a`
                  <a
                    href=${Ce.authorizeUrl}
                    target="_blank"
                    rel="noopener noreferrer"
                    class="btn-primary"
                    data-testid="tools-oauth-authorize-link"
                  >
                    OAuth 인증 페이지 열기 ↗
                  </a>
                `}
                ${Ce.deviceCode&&a`
                  <span class="mono" data-testid="tools-oauth-device-code" style=${{padding:"var(--sp-1) var(--sp-2)",borderRadius:"var(--radius-sm)",background:"var(--brass-soft)",color:"var(--brass-1)",fontWeight:700}}>
                    ${Ce.deviceCode}
                  </span>
                `}
              </div>
            </div>
          `}

          ${g&&a`
            <form
              data-testid="tools-oauth-client-form"
              onSubmit=${S}
              style=${{display:"flex",flexDirection:"column",gap:"var(--sp-2)",padding:"var(--sp-3)",borderRadius:"var(--radius-sm)",border:"1px solid var(--brass-border)",background:"var(--bg-1)"}}
            >
              <div class="wka-h">
                <strong style=${{fontSize:"var(--fs-12)"}}>내 OAuth 앱 등록 · ${g.providerLabel}</strong>
                <button type="button" class="btn-ghost" onClick=${()=>C(null)}>닫기</button>
              </div>
              ${Re&&a`
                <div class="mono" style=${{fontSize:"var(--fs-11)",color:"var(--fg-2)",padding:"var(--sp-1) var(--sp-2)",background:"var(--bg-2)",borderRadius:"var(--radius-sm)",overflowWrap:"anywhere"}}>
                  Callback URL: ${Re}
                </div>
              `}
              <input
                type="text"
                aria-label="OAuth Client ID"
                placeholder="Client ID (필수)"
                required
                value=${g.clientId}
                onInput=${i=>{const p=i.target.value;C(b=>b?{...b,clientId:p}:null)}}
                class="mono"
                style=${{padding:"var(--sp-1) var(--sp-2)",background:"var(--input-bg)",border:"1px solid var(--input-border)",borderRadius:"var(--radius-sm)"}}
              />
              <input
                type="password"
                aria-label="OAuth Client Secret"
                placeholder="Client Secret (공개 PKCE 앱이면 비워두세요)"
                value=${g.clientSecret}
                onInput=${i=>{const p=i.target.value;C(b=>b?{...b,clientSecret:p}:null)}}
                class="mono"
                style=${{padding:"var(--sp-1) var(--sp-2)",background:"var(--input-bg)",border:"1px solid var(--input-border)",borderRadius:"var(--radius-sm)"}}
              />
              <input
                type="text"
                aria-label="OAuth Scopes"
                placeholder="Scopes (선택, 공백 구분)"
                value=${g.scopes}
                onInput=${i=>{const p=i.target.value;C(b=>b?{...b,scopes:p}:null)}}
                class="mono"
                style=${{padding:"var(--sp-1) var(--sp-2)",background:"var(--input-bg)",border:"1px solid var(--input-border)",borderRadius:"var(--radius-sm)"}}
              />
              <div style=${{display:"flex",gap:"var(--sp-2)"}}>
                <button type="submit" class="btn-primary" disabled=${x}>
                  ${x?"저장 중…":"OAuth 앱 저장"}
                </button>
              </div>
            </form>
          `}

          ${ye.length===0?a`<div class="dtable-absent">${he?"불러오는 중…":"연결 가능한 OAuth 제공자가 없습니다."}</div>`:ye.map(i=>a`
                <div key=${i.provider} style=${{display:"flex",justifyContent:"space-between",alignItems:"center",gap:"var(--sp-2)",padding:"var(--sp-2)",border:"1px solid var(--line-1)",borderRadius:"var(--radius-sm)",flexWrap:"wrap"}}>
                  <div>
                    <div style=${{fontWeight:600,fontSize:"var(--fs-13)"}}>${i.provider_label??i.provider}</div>
                    <div class="mono" style=${{fontSize:"var(--fs-11)",color:"var(--fg-3)"}}>
                      ${i.problem?`오류: ${i.problem}`:i.attached?`연결됨 · 도구 ${i.tools?.length??0}개 · ${i.switch_problem?`스위치 오류: ${i.switch_problem}`:i.enabled===!1?"꺼짐":"켜짐"}`:"미연결"}
                    </div>
                  </div>
                  ${c&&a`
                    <div style=${{display:"flex",gap:"var(--sp-1)",flexWrap:"wrap"}}>
                      ${i.provider!=="github"&&a`
                        <button
                          type="button"
                          class="btn-ghost"
                          onClick=${()=>C({provider:i.provider,providerLabel:i.provider_label??i.provider,clientId:"",clientSecret:"",scopes:""})}
                        >
                          앱 설정
                        </button>
                      `}
                      ${!i.problem&&(i.attached?a`
                            <button type="button" class="btn-ghost" onClick=${()=>{y(i.provider,i.enabled===!1)}}>
                              ${i.enabled===!1?"켜기":"끄기"}
                            </button>
                            <button type="button" class="btn-ghost" style=${{color:"var(--err-fg)"}} onClick=${()=>{X(i.provider)}}>
                              연결 해제
                            </button>
                          `:a`<button type="button" class="btn-primary" onClick=${()=>o(i)}>OAuth 연결</button>`)}
                    </div>
                  `}
                </div>
              `)}
        </div>
      `}

      ${k==="clients"&&r&&a`
        <div style=${{display:"flex",flexDirection:"column",gap:"var(--sp-2)",minWidth:0}}>
          ${Be.kind==="failed"&&a`
            <div class="ap-error" role="alert">MCP 클라이언트 조회 실패: ${Be.error.message}</div>
          `}
          <${Ut}
            data=${A}
            columns=${yt}
            getRowId=${(i,p)=>`${i.name}-${p}`}
            virtualizeThreshold=${30}
            maxHeight=${400}
            caption="MCP 클라이언트 목록"
            emptyLabel=${Be.kind==="failed"?`MCP 클라이언트 조회 실패: ${Be.error.message}`:Be.kind==="loading"?"불러오는 중…":"연결된 MCP 클라이언트가 없습니다."}
          />
        </div>
      `}
    </div>
  `}function Sr(e){switch(Fa(e.subroute)){case"quotas":return a`<${us} ...${e} />`;case"efficiency":return a`<${_s} ...${e} />`;case"lanes":return a`<${Ys} ...${e} />`;case"tools":return a`<${er} ...${e} />`;case"addons":return a`<${Ha} ...${e} />`}}export{Rr as RUNTIME_TABS,Sr as RuntimeWorkspace,Sr as default,Fa as normalizeRuntimeSubroute};
