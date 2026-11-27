const __vite__mapDeps=(i,m=__vite__mapDeps,d=(m.f||(m.f=["assets/index6.js","assets/vendor.js","assets/keeper-state.js","assets/type-guards.js","assets/format-string.js","assets/core.js","assets/refresh-button.js","assets/uplot-chart.js","assets/hitl-decoders.js","assets/dashboard-goals.js","assets/turn-context.js","assets/format-time.js","assets/quota-window.js","assets/index3.css","assets/index5.js","assets/lazy-component.js","assets/markdown-renderer.js","assets/markdown.js","assets/copyable-code.js","assets/toast.js","assets/shared-ticker.js","assets/inline-spinner.js","assets/master-detail.js","assets/target-locked-action.js","assets/virtual-list.js","assets/table.js","assets/useSelector.js","assets/types.js","assets/markdown-renderer.css","assets/index.css","assets/index2.js","assets/attachment-gallery.js","assets/index2.css","assets/index3.js","assets/setup-inventory-read.js","assets/sse-reader.js","assets/wire-decode.js","assets/now-signal.js","assets/icons.js","assets/index5.css","assets/index8.js","assets/command-search.js","assets/data-table.js","assets/keeper-oauth-flow.js","assets/index9.js","assets/unified-diff.js","assets/index4.css","assets/index4.js","assets/config-schema.js","assets/index7.js","assets/hitl-parsers.js","assets/verification-coverage.js","assets/fast-approval-strip.js","assets/command-palette.js","assets/drift-error.js","assets/quick-peek-drawer.js","assets/queue-context-overlay.js","assets/incidents-overlay.js"])))=>i.map(i=>d[i]);
import{n as E,a as C,c as Z,z as De,m as b,A as U,y as le,d as ce,g as Ga,S as Fn,P as $e,C as Va,R as Fa}from"./vendor.js";const za=(function(){const t=typeof document<"u"&&document.createElement("link").relList;return t&&t.supports&&t.supports("modulepreload")?"modulepreload":"preload"})(),Ua=function(e){return"/dashboard/"+e},bn={},F=function(t,n,a){let o=Promise.resolve();if(n&&n.length>0){let f=function(l){return Promise.all(l.map(c=>Promise.resolve(c).then(p=>({status:"fulfilled",value:p}),p=>({status:"rejected",reason:p}))))};document.getElementsByTagName("link");const i=document.querySelector("meta[property=csp-nonce]"),r=i?.nonce||i?.getAttribute("nonce");o=f(n.map(l=>{if(l=Ua(l),l in bn)return;bn[l]=!0;const c=l.endsWith(".css"),p=c?'[rel="stylesheet"]':"";if(document.querySelector(`link[href="${l}"]${p}`))return;const u=document.createElement("link");if(u.rel=c?"stylesheet":za,c||(u.as="script"),u.crossOrigin="",u.href=l,r&&u.setAttribute("nonce",r),document.head.appendChild(u),c)return new Promise((_,d)=>{u.addEventListener("load",_),u.addEventListener("error",()=>d(new Error(`Unable to preload CSS for ${l}`)))})}))}function s(i){const r=new Event("vite:preloadError",{cancelable:!0});if(r.payload=i,window.dispatchEvent(r),!r.defaultPrevented)throw i}return o.then(i=>{for(const r of i||[])r.status==="rejected"&&s(r.reason);return t().catch(s)})},ja=/[^A-Za-z0-9._-]+/g,Ya=32,zn="masc_dashboard_agent_name";function Ut(){if(typeof window>"u")return null;try{const e=window.localStorage;return e&&typeof e.getItem=="function"?e:null}catch{return null}}function Pe(e){return typeof e!="string"?null:e.trim().replace(ja,"").slice(0,Ya)||null}function Za(e=Ut()){try{return Pe(e?.getItem(zn))}catch{return null}}function jt(e=typeof window>"u"?"":window.location.search,t=Ut()){const n=new URLSearchParams(e);return Pe(n.get("agent"))||Pe(n.get("agent_name"))||Za(t)}const Ct=new Set;function Qa(e){return Ct.add(e),()=>{Ct.delete(e)}}function Yt(){return jt()??"dashboard"}let It=Yt();function Un(){for(const e of Ct)try{e()}catch(t){console.warn("[dashboard-auth] actor hint listener failed",t)}}function Ja(e){const t=Yt();It=t,e!==t&&Un()}typeof window<"u"&&(window.addEventListener("storage",e=>{const t=Ut();if(e.storageArea!==null&&e.storageArea!==t||e.key!==null&&e.key!==zn||jt(window.location.search,null)!==null)return;const n=Pe(e.oldValue)??"dashboard",a=Pe(e.newValue)??"dashboard";e.key!==null&&n===a||(It=Yt(),Un())}),window.addEventListener("popstate",()=>{Ja(It)}));let we=null;const Zt=C(0),hs=Zt;Qa(()=>{we===null&&Zt.value++});const jn=C(0),ks=jn,gs=C(null),vs=C(null),Xa=C(0);let er=0;const bs=Xa;function _s(){return er}function Yn(e,t){const n=Pe(e)??null,a=n!==we,o=we===null&&n==="dashboard",s=t?.rejected===!0,i=t?.verifiedAfterRefusal===!0,r=a&&!o||s||i;return(a||r||t?.rejected)&&E(()=>{t?.rejected,we=n,a&&Zt.value++,r&&jn.value++}),we}function tr(){return jt()||"dashboard"}function ys(){return we??tr()}const Qt="masc_bearer_token",st="masc_bearer_token_meta",nr=/^[\x21-\x7E]+$/,ar=/^[\x20-\x7E]+$/;function Ve(e){if(e==null)return{ok:!0,token:null};const t=a=>a.startsWith('"')&&a.endsWith('"')&&a.length>=2||a.startsWith("'")&&a.endsWith("'")&&a.length>=2?a.slice(1,-1).trim():a;let n=t(e.trim());return/^bearer\s+/i.test(n)&&(n=t(n.replace(/^bearer\s+/i,"").trim())),n.length===0?{ok:!0,token:null}:nr.test(n)?{ok:!0,token:n}:{ok:!1,error:"유효한 ASCII Bearer 토큰이 아닙니다. 공백·한글·특수문자 없이 토큰 문자열만 붙여넣어 주세요."}}const Pt=new Set;let Zn=0;function Qn(e){Zn+=1;for(const t of Pt)try{t(e)}catch(n){console.warn("[dashboard-auth] token change listener failed",n)}}function ue(){return Zn}function rr(e){return Pt.add(e),()=>{Pt.delete(e)}}function Jn(e){if(typeof e!="object"||e===null||Array.isArray(e))return null;const t=e;return t.source==="manual"?{source:"manual"}:t.source==="url"?{source:"url"}:t.source==="dev"&&t.actor==="dashboard"&&t.role==="admin"?{source:"dev",actor:"dashboard",role:"admin"}:null}function or(e,t){return e===null||t===null?e===t:e.source!==t.source?!1:e.source!=="dev"||t.source!=="dev"?!0:e.actor===t.actor&&e.role===t.role}function sr(){try{if(typeof window>"u"||!window.location)return null;const e=new URLSearchParams(window.location.search);if(!e.has("token"))return null;const t=e.get("token"),n=Ve(t);e.delete("token");const a=e.toString(),o=window.location.pathname+(a?`?${a}`:"")+window.location.hash;return typeof window.history?.replaceState=="function"&&window.history.replaceState(null,"",o),n.ok?n.token:null}catch{return null}}function Xn(e){if(e==null)return{ok:!0,token:null};const t=e.trim();return t.length===0?{ok:!0,token:null}:ar.test(t)?{ok:!0,token:t}:{ok:!1,error:"유효한 ASCII Bearer 토큰이 아닙니다. 공백·한글·특수문자 없이 토큰 문자열만 붙여넣어 주세요."}}function Jt(){try{const e=sessionStorage.getItem(Qt);if(e===null)return{raw:null,token:null,invalid:!1};const t=Xn(e);return t.ok?{raw:e,token:t.token,invalid:!1}:{raw:e,token:null,invalid:!0}}catch{return{raw:null,token:null,invalid:!1}}}function ir(){const{token:e,invalid:t}=Jt();return t?(en(),null):e}function Xt(){try{const e=sessionStorage.getItem(st);return e?Jn(JSON.parse(e)):null}catch{return null}}function lr(e,t={source:"manual"}){const n=Xn(e);if(!n.ok)return;const a=n.token;if(!a){en();return}const{token:o,invalid:s}=Jt(),i=Xt(),r=Jn(t);sessionStorage.setItem(Qt,a),r?sessionStorage.setItem(st,JSON.stringify(r)):sessionStorage.removeItem(st),Yn(null),(s||o!==a||!or(i,r))&&Qn({token:a,meta:r})}function en(){const{raw:e,token:t}=Jt(),n=Xt();try{sessionStorage.removeItem(Qt),sessionStorage.removeItem(st)}catch{}Yn(null),(e!==null||t!==null||n!==null)&&Qn({token:null,meta:null})}const Lt="masc.core.account_marker",xe=12e3,cr=5e3,ur=Object.freeze({google:!1,github:!1,dev_token:!1});let B=null,K=null,Rt=0,_n=0,gt=null;function ea(e){Rt+=1;try{return e()}finally{Rt-=1}}function dr(){try{return typeof sessionStorage>"u"?!1:(sessionStorage.getItem("masc_bearer_token"),!0)}catch{return!1}}function ta(){return ir()?.trim()??null}function tn(e,t={source:"manual"}){ea(()=>{try{e===null?en():lr(e,t)}catch{}})}const v=C({kind:"probing"}),W=C(1),nn=C([{id:"default",label:"Default Workspace"}]),x=C("default");rr(({token:e,meta:t})=>{if(Rt>0)return;const n=B;B=e,n!==e&&E(()=>{j();const a=v.peek();if(a.kind==="single_user_local"||a.kind==="single_user_auth_required")if(e!==null){const o=t?.source==="dev"&&t.role==="admin";v.value={kind:"single_user_local",mode:"single_user",tokenPresent:!0,role:o?"admin":"worker",canTokenAdmin:o,canTokenRead:o,authMethods:a.authMethods,workspaceId:x.peek()}}else v.value={kind:"single_user_auth_required",mode:"single_user",authMethods:a.authMethods,reason:"Token cleared"}})});const pr=Z(()=>{const e=v.value;return e.kind==="single_user_local"||e.kind==="multi_account_signed_in"});Z(()=>{const e=v.value;return e.kind==="probing"||e.kind==="unavailable"?null:e.mode});function fr(e){switch(e.kind){case"multi_account_signed_in":return e.role==="admin";case"single_user_local":return e.role===void 0||e.role==="admin";case"probing":case"unavailable":case"account_changed":case"multi_account_signed_out":case"single_user_auth_required":return!1}}function G(e){switch(e.kind){case"multi_account_signed_in":return!0;case"single_user_local":return e.role!=="player";case"probing":case"unavailable":case"account_changed":case"multi_account_signed_out":case"single_user_auth_required":return!1}}function mr(e){return e.kind==="single_user_local"&&e.role!=="player"}function ws(e){return e.kind!=="single_user_local"?!1:e.canTokenRead!==void 0?e.canTokenRead:e.role!=="player"}function hr(e){return e.kind!=="single_user_local"?!1:e.canTokenAdmin!==void 0?e.canTokenAdmin:e.role===void 0||e.role==="admin"}function Ot(e){switch(e.kind){case"multi_account_signed_in":return e.role==="admin";case"single_user_local":return hr(e);case"probing":case"unavailable":case"account_changed":case"multi_account_signed_out":case"single_user_auth_required":return!1}}function Mt(e){switch(e.kind){case"multi_account_signed_in":return e.role==="admin";case"single_user_local":return e.role!=="player";case"probing":case"unavailable":case"account_changed":case"multi_account_signed_out":case"single_user_auth_required":return!1}}function H(){return W.peek()}function P(e){return W.peek()===e}function j(){kr();const e=W.peek()+1;return W.value=e,e}const na=5e3;let it=null,Fe=null;function kr(){it=null,Fe=null}function gr(){Fe=null}function vr(e){const t=it;return!t||t.epoch!==e||Date.now()-t.capturedAt>na?null:(it=null,t.payload)}function br(e,t,n){const a=Fe;return!a||a.epoch!==e||a.token!==t||a.workspaceId!==n||Date.now()-a.capturedAt>na?null:(Fe=null,{payload:a.payload,etag:a.etag})}function an(){return B}function aa(){const e=v.peek();return e.kind==="multi_account_signed_in"?K??e.csrfToken:null}function yn(e){const t=Ve(e);if(!t.ok)return;const n=t.token,a=Xt()?.source??null,o=n===null?null:"manual";B===n&&ta()===n&&a===o||E(()=>{const s=B!==n;B=n,j();const i=v.peek();if(i.kind==="single_user_local"||i.kind==="single_user_auth_required")if(n!==null){const r=!s&&i.kind==="single_user_local";v.value={kind:"single_user_local",mode:"single_user",tokenPresent:!0,role:r?i.role:"worker",canTokenAdmin:r?i.canTokenAdmin:!1,canTokenRead:r?i.canTokenRead:!1,authMethods:i.authMethods,workspaceId:x.peek()}}else v.value={kind:"single_user_auth_required",mode:"single_user",authMethods:i.authMethods,reason:"Token cleared"};tn(n)})}function _r(){B=null,K=null}function $s(e){const t=e.length>0?[...e]:[{id:"default",label:"Default Workspace"}];E(()=>{nn.value=Object.freeze(t),t.some(n=>n.id===x.peek())||ra(t[0].id)})}function ra(e){const t=e.trim();return!t||t===x.peek()?!1:(E(()=>{x.value=t,j();const n=v.peek();n.kind==="single_user_local"?v.value={...n,workspaceId:t}:n.kind==="multi_account_signed_in"&&(v.value={...n,workspaceId:t})}),!0)}function lt(e){const t=x.peek(),a=nn.peek().find(s=>s.id===t)?.baseUrl?.trim();if(!a)return e;const o=e.startsWith("/")?e:`/${e}`;if(a.startsWith("/")&&!a.startsWith("//"))return`${a.replace(/\/+$/,"")}${o}`;if(typeof window<"u"&&window.location?.origin)try{const s=new URL(a,window.location.origin);return s.origin!==window.location.origin?o:`${s.pathname.replace(/\/+$/,"")}${o}`}catch{return o}return o}function oa(e){return e==null?"single_user":e==="Multi_account"||e==="multi_account"?"multi_account":e==="Single_user"||e==="single_user"?"single_user":"invalid"}function sa(e){if(typeof e!="object"||e===null)return ur;const t=e;return Object.freeze({google:t.google===!0,github:t.github===!0,dev_token:t.dev_token===!0})}function ia(e){const t=typeof e=="string"?e.trim().toLowerCase():"";return t==="admin"?"admin":t==="worker"?"worker":"viewer"}function yr(e){const t=typeof e=="string"?e.trim().toLowerCase():"";return t==="admin"?"admin":t==="worker"?"worker":t==="player"?"player":null}function la(e){if(typeof e!="object"||e===null||Array.isArray(e))return{kind:"malformed",reason:"GET /api/v1/dashboard/shell returned malformed payload"};const n=e.auth;if(n===void 0)return{kind:"ok",role:"worker",canTokenAdmin:!1,canTokenRead:!1};if(typeof n!="object"||n===null||Array.isArray(n))return{kind:"malformed",reason:"GET /api/v1/dashboard/shell returned malformed auth metadata"};const a=n,o=a.enabled===!0,s=a.require_token===!0,i=a.token_valid===!0,r=a.effective_admin===!0,f=yr(a.effective_role);if(o&&s&&!i){const u=de(a.auth_error_detail),_=de(a.auth_error_code);return{kind:"auth_required",reason:u??_??"Authorization required (missing or invalid bearer token)"}}const l=f!==null?f:r?"admin":o?"worker":"admin";return{kind:"ok",role:l,canTokenAdmin:o&&s&&i&&r,canTokenRead:o&&s&&i&&l!=="player"}}function ge(e){try{if(typeof localStorage>"u")return;e===null?localStorage.removeItem(Lt):localStorage.setItem(Lt,e)}catch{}}function de(e){return typeof e=="string"&&e.trim().length>0?e.trim():null}async function rn(e,t,n,a=xe,o=()=>!0){const s=await me(e,"/auth/session",{method:"GET",credentials:"same-origin",headers:{Accept:"application/json"}},a);if(!o())return v.peek();if(s.status===401||s.status===403)return K=null,ge(null),n!==null?{kind:"account_changed",mode:"multi_account",previousAccountId:n,nextAccountId:null,authMethods:t}:{kind:"multi_account_signed_out",mode:"multi_account",authMethods:t};if(!s.ok)return{kind:"unavailable",reason:`GET /auth/session failed (${s.status})`};const i=await s.json().catch(()=>null);if(!o())return v.peek();const r=de(i?.user_id),f=de(i?.csrf_token);if(i===null||r===null||f===null)return K=null,{kind:"unavailable",reason:"GET /auth/session returned malformed payload"};if(n!==null&&n!==r)return K=null,ge(r),{kind:"account_changed",mode:"multi_account",previousAccountId:n,nextAccountId:r,authMethods:t};const l=await me(e,"/api/v1/auth/whoami",{method:"GET",credentials:"same-origin",headers:{Accept:"application/json"}},a);if(!o())return v.peek();if(l.status===401||l.status===403)return K=null,ge(null),n!==null?{kind:"account_changed",mode:"multi_account",previousAccountId:n,nextAccountId:null,authMethods:t}:{kind:"multi_account_signed_out",mode:"multi_account",authMethods:t};if(!l.ok)return K=null,{kind:"unavailable",reason:`GET /api/v1/auth/whoami failed (${l.status})`};const c=await l.json().catch(()=>null);if(!o())return v.peek();if(c===null)return K=null,{kind:"unavailable",reason:"GET /api/v1/auth/whoami returned malformed payload"};const p=c.principal?.kind,u=de(c.principal?.id);if(p!=="human"||u===null)return K=null,{kind:"unavailable",reason:"GET /api/v1/auth/whoami did not return a human principal"};if(u!==r)return K=null,ge(u),{kind:"account_changed",mode:"multi_account",previousAccountId:r,nextAccountId:u,authMethods:t};if(!o())return v.peek();K=f;const _=x.peek(),g=de(c.workspace_id)??de(i.workspace_id)??_;return g!==_&&E(()=>{x.value=g,j()}),ge(r),{kind:"multi_account_signed_in",mode:"multi_account",accountId:r,email:null,displayName:r,role:ia(c.role),csrfToken:f,authMethods:t,workspaceId:g}}async function me(e,t,n,a){if(typeof AbortController>"u"||a<=0)return e(t,n);const o=new AbortController;let s=!1;const i=setTimeout(()=>{s=!0,o.abort()},a);try{return await e(t,{...n,signal:o.signal})}catch(r){if(s){const f=Math.max(1,Math.round(a/1e3));throw new Error(`서버 응답 시간 초과 (${f}초) — 서버가 일시적으로 바쁘거나 read_pool이 포화 상태일 수 있습니다.`)}throw r}finally{clearTimeout(i)}}async function wr(e,t={}){const n=Ve(e);if(!n.ok)return{ok:!1,error:n.error};if(n.token===null)return{ok:!1,error:"토큰을 입력한 뒤 적용해 주세요."};const a=t.fetchImpl??globalThis.fetch,o=t.timeoutMs??xe,s=n.token,i=H(),r=ue();try{const f=await me(a,"/health",{method:"GET",credentials:"same-origin",headers:{Accept:"application/json"}},o);if(!f.ok)return{ok:!1,error:`GET /health 실패 (HTTP ${f.status})`};const l=await f.json();if(oa(l.account_mode)!=="single_user")return{ok:!1,error:"현재 서버는 싱글유저 Bearer 토큰 모드가 아닙니다."};const p=sa(l.auth_methods),u=await me(a,"/api/v1/dashboard/shell",{method:"GET",credentials:"same-origin",headers:{Accept:"application/json",Authorization:`Bearer ${s}`}},o);if(!P(i)||ue()!==r)return{ok:!1,error:"검증 중 다른 인증 변경이 발생했습니다. 다시 시도하세요."};if(u.status===401||u.status===403)return{ok:!1,error:`토큰 인증 실패 (HTTP ${u.status}) — 유효한 오퍼레이터 토큰인지 확인하세요.`};if(!u.ok)return{ok:!1,error:`서버 상태 오류 (HTTP ${u.status})`};const _=await u.json().catch(()=>null);if(!P(i)||ue()!==r)return{ok:!1,error:"검증 중 다른 인증 변경이 발생했습니다. 다시 시도하세요."};const d=la(_);if(d.kind==="auth_required")return{ok:!1,error:`토큰 인증 실패 (${d.reason}) — 유효한 토큰인지 확인하세요.`};if(d.kind==="malformed")return{ok:!1,error:d.reason};const g={kind:"single_user_local",mode:"single_user",tokenPresent:!0,role:d.role,canTokenAdmin:d.canTokenAdmin,canTokenRead:d.canTokenRead,authMethods:p,workspaceId:x.peek()};return E(()=>{B=s,j(),v.value=g,tn(s,{source:"manual"})}),{ok:!0,session:g}}catch(f){return{ok:!1,error:f instanceof Error?f.message:String(f)}}}async function Se(e={}){const t=e.fetchImpl??globalThis.fetch,n=e.timeoutMs??xe,a=v.peek(),o=a.kind==="multi_account_signed_in"?a.accountId:null,s=H();let i=ue();const r=()=>P(s)&&ue()===i,f=(c,p)=>{B=c,tn(c,p),i=ue()},l=sr();try{const c=await me(t,"/health",{method:"GET",credentials:"same-origin",headers:{Accept:"application/json"}},n),p=c.ok?await c.json():{};if(!r())return v.peek();if(!c.ok){const A={kind:"unavailable",reason:`GET /health failed (${c.status})`};return v.value=A,A}t===globalThis.fetch&&(it={epoch:s,payload:p,capturedAt:Date.now()});const u=oa(p.account_mode);if(u==="invalid"){const A={kind:"unavailable",reason:`Unsupported account_mode: ${String(p.account_mode)}`};return v.value=A,A}const _=sa(p.auth_methods);if(u==="multi_account"){f(null);const A=x.peek(),m=await rn(t,_,o,n,r),$=x.peek()!==A&&ue()===i;return!r()&&!$?v.peek():(m.kind==="account_changed"?E(()=>{j(),v.value=m}):v.value=m,m)}if(K=null,l!==null)f(l,{source:"url"});else{const A=ea(()=>ta());i=ue(),A!==null?B=A:B!==null&&(dr()?B=null:Ve(B).ok||f(null))}if(_.dev_token&&B===null){let A=null;try{const m=await me(t,"/api/v1/dashboard/dev-token",{method:"GET",credentials:"same-origin",headers:{Accept:"application/json"}},n);if(m.ok){const $=await m.json(),h=typeof $?.token=="string"?Ve($.token):null;A=h?.ok?h.token:null}}catch{}if(!r())return v.peek();A!==null&&f(A,{source:"dev",actor:"dashboard",role:"admin"})}if(!r())return v.peek();let d="worker",g=!1,S=!1;if(e.probeShell!==!1){const A={Accept:"application/json"};B&&(A.Authorization=`Bearer ${B}`);const m=await me(t,"/api/v1/dashboard/shell",{method:"GET",credentials:"same-origin",headers:A},n);if(!r())return v.peek();if(m.status===401||m.status===403){f(null);const k={kind:"single_user_auth_required",mode:"single_user",authMethods:_,reason:`Authorization required (${m.status})`};return v.value=k,k}if(!m.ok){const k={kind:"unavailable",reason:`GET /api/v1/dashboard/shell failed (${m.status})`};return v.value=k,k}const $=await m.json().catch(()=>null);if(!r())return v.peek();const h=la($);if(h.kind==="auth_required"){f(null);const k={kind:"single_user_auth_required",mode:"single_user",authMethods:_,reason:h.reason};return v.value=k,k}if(h.kind==="malformed"){const k={kind:"unavailable",reason:h.reason};return v.value=k,k}d=h.role,g=h.canTokenAdmin,S=h.canTokenRead,t===globalThis.fetch&&$!==null&&(Fe={epoch:s,token:B,workspaceId:x.peek(),payload:$,etag:m.headers.get("etag"),capturedAt:Date.now()})}const y={kind:"single_user_local",mode:"single_user",tokenPresent:B!==null,role:d,canTokenAdmin:g,canTokenRead:S,authMethods:_,workspaceId:x.peek()};return v.value=y,y}catch(c){if(!r())return v.peek();const p={kind:"unavailable",reason:c instanceof Error?c.message:String(c)};return v.value=p,p}}function ca(e,t){if(t.kind==="account_changed"||t.kind==="multi_account_signed_out"){K=null,E(()=>{j(),v.value=t});return}if(t.kind==="multi_account_signed_in"){const n=e.role!==t.role;E(()=>{n&&j(),v.value=t})}}async function $r(e=globalThis.fetch){const t=v.peek();if(t.kind!=="multi_account_signed_in")return null;const n=H(),a=x.peek(),o=await rn(e,t.authMethods,t.accountId,xe,()=>P(n)).catch(()=>null);if(o===null)return null;const s=x.peek()!==a;return!P(n)&&!s?null:o.kind==="unavailable"?(v.value=o,null):(ca(t,o),o.kind==="multi_account_signed_in"?o.csrfToken:null)}function Sr(e=globalThis.fetch){const t=v.peek();if(t.kind!=="multi_account_signed_in")return;const n=Date.now();if(gt!==null||n-_n<cr)return;_n=n;const a=H();gt=me(e,"/api/v1/auth/whoami",{method:"GET",credentials:"same-origin",headers:{Accept:"application/json"}},xe).then(async o=>{if(!P(a))return;if(o.status===401){K=null,ge(null),E(()=>{j(),v.value={kind:"multi_account_signed_out",mode:"multi_account",authMethods:t.authMethods}});return}if(!o.ok)return;const s=await o.json().catch(()=>null);if(!P(a)||s===null)return;const i=s.principal?.kind,r=de(s.principal?.id);if(i!=="human"||r===null)return;if(r!==t.accountId){K=null,ge(r),E(()=>{j(),v.value={kind:"account_changed",mode:"multi_account",previousAccountId:t.accountId,nextAccountId:r,authMethods:t.authMethods}});return}const f=ia(s.role);f!==t.role&&E(()=>{j(),v.value={...t,role:f}})}).catch(()=>{}).finally(()=>{gt=null})}function Er(e=globalThis.fetch){if(typeof window>"u"||typeof document>"u")return()=>{};const t=()=>{_r()},n=o=>{if(o.key!==Lt)return;const s=v.peek();if(s.kind!=="multi_account_signed_in")return;const i=o.newValue;i!==s.accountId&&(K=null,E(()=>{j(),v.value={kind:"account_changed",mode:"multi_account",previousAccountId:s.accountId,nextAccountId:i,authMethods:s.authMethods}}))},a=()=>{if(document.visibilityState!=="visible")return;const o=v.peek();if(o.kind!=="multi_account_signed_in")return;const s=H(),i=x.peek();rn(e,o.authMethods,o.accountId,xe,()=>P(s)).then(r=>{const f=x.peek()!==i;!P(s)&&!f||ca(o,r)}).catch(()=>{})};return window.addEventListener("pagehide",t),window.addEventListener("storage",n),document.addEventListener("visibilitychange",a),()=>{window.removeEventListener("pagehide",t),window.removeEventListener("storage",n),document.removeEventListener("visibilitychange",a)}}function vt(){return{kind:"loading"}}function Tr(e,t=Date.now(),n=!1){return{kind:"value",data:e,stale:n,updatedAt:t}}function wn(e){return e?{kind:"absent",reason:e}:{kind:"absent"}}function Ss(e){return e?{kind:"unreported",reason:e}:{kind:"unreported"}}function $n(e){return{kind:"failed",error:e,retryable:e.retryable}}function Es(e,t=n=>String(n)){switch(e.kind){case"loading":return"불러오는 중…";case"absent":return"없음";case"unreported":return"미보고";case"failed":return"오류";case"value":return t(e.data)}}const Sn=15e3;class Ar{entries=new Map;entriesByTopic=new Map;unsubEpoch;now;constructor(t=()=>Date.now()){this.now=t,this.unsubEpoch=W.subscribe(()=>{this.clearAll()})}indexTopic(t,n){let a=this.entriesByTopic.get(t);a||(a=new Set,this.entriesByTopic.set(t,a)),a.add(n)}markEntryInvalidated(t){t.invalidated=!0,t.invalidationGen+=1;const n=t.state.peek();n.kind==="value"&&!n.stale&&(t.state.value={...n,stale:!0})}getOrCreate(t,n,a){let o=this.entries.get(t);if(o){if(o.ttlMs=n,a.length>0)for(let s=0;s<a.length;s++){const i=a[s];o.topics.has(i)||(o.topics.add(i),this.indexTopic(i,o))}}else{const s=new Set(a);o={state:C(vt()),topics:s,ttlMs:n,updatedAt:0,invalidated:!1,invalidationGen:0,inFlightGen:-1,epoch:H(),inFlight:null,abortController:null},this.entries.set(t,o);for(const i of s)this.indexTopic(i,o)}return o}observe(t){return this.getOrCreate(t,Sn,[]).state}peek(t){return this.entries.get(t)?.state.peek()}fetch(t,n,a={}){const o=a.ttlMs??Sn,s=a.topics??[],i=a.reason??"mount",r=this.getOrCreate(t,o,s),f=H();if(i!=="manual"&&r.inFlight!==null&&r.epoch===f&&r.inFlightGen===r.invalidationGen)return r.inFlight;const l=r.state.peek();if(r.epoch===f&&!r.invalidated&&l.kind==="value"&&this.now()-r.updatedAt<r.ttlMs&&i!=="manual")return Promise.resolve(l);r.abortController!==null&&r.abortController.abort(i==="manual"?"superseded_by_manual_read":"superseded_by_invalidation");const p=new AbortController,u=r.invalidationGen;r.abortController=p,r.inFlightGen=u,r.epoch=f,l.kind==="value"&&!l.stale?r.state.value={...l,stale:!0}:l.kind!=="value"&&l.kind!=="loading"&&(r.state.value=vt());const _=(async()=>{try{let d;try{d=await n(p.signal)}catch(y){if(!P(f)||p.signal.aborted||r.abortController!==p)return r.state.peek();const A=$n({kind:"network",status:null,code:"loader_threw",message:y instanceof Error?y.message:String(y),retryable:!0,cause:y});return r.state.value=A,A}if(!P(f)||p.signal.aborted||r.abortController!==p)return r.state.peek();const g=u===r.invalidationGen;if(d.ok){const y=this.now(),A=d.value===null?wn():Tr(d.value,y,!g);return g&&(r.updatedAt=y,r.invalidated=!1),r.state.value=A,A}if(d.error.kind==="aborted"||d.error.kind==="epoch_stale")return r.state.peek();if(d.error.kind==="not_found"){const y=wn(d.error.message);return g&&(r.updatedAt=this.now(),r.invalidated=!1),r.state.value=y,y}const S=$n(d.error);return r.state.value=S,S}finally{r.abortController===p&&(r.abortController=null,r.inFlight=null)}})();return r.inFlight=_,_}invalidateTopic(t){const n=this.entriesByTopic.get(t);return!n||n.size===0?0:(E(()=>{for(const a of n)this.markEntryInvalidated(a)}),n.size)}invalidateTopics(t){let n=null,a=null;for(const s of t){const i=this.entriesByTopic.get(s);if(!(!i||i.size===0))if(n===null&&a===null)n=i;else{a===null&&(a=new Set(n),n=null);for(const r of i)a.add(r)}}const o=a??n;return!o||o.size===0?0:(E(()=>{for(const s of o)this.markEntryInvalidated(s)}),o.size)}invalidateKey(t){const n=this.entries.get(t);return n?(this.markEntryInvalidated(n),!0):!1}invalidateAll(){if(this.entries.size===0)return 0;let t=0;return E(()=>{for(const n of this.entries.values())this.markEntryInvalidated(n),t+=1}),t}clearAll(){this.entries.size!==0&&E(()=>{for(const t of this.entries.values())t.abortController?.abort("cache_cleared"),t.abortController=null,t.inFlight=null,t.updatedAt=0,t.invalidated=!0,t.invalidationGen+=1,t.state.peek().kind!=="loading"&&(t.state.value=vt())})}size(){return this.entries.size}dispose(){this.clearAll(),this.unsubEpoch(),this.entries.clear(),this.entriesByTopic.clear()}}const on=new Ar,Cr="x-masc-sse-instance-id",Ir="x-masc-observer-idle-timeout-ms",te=C("SNAPSHOT"),fe=C(!1),Le=C(null),pt=C(null),Pr=te,Lr=fe,Rr=Le,Ts=pt,Dt=new Set,xt=new Set,ct=new Set;let qe=null,He=null,Ke=null;const En=new WeakMap;function Or(){return qe===null&&(qe=Array.from(Dt)),qe}function Mr(){return He===null&&(He=Array.from(xt)),He}function Dr(){return Ke===null&&(Ke=Array.from(ct)),Ke}let be=null,Tn=0,sn=0,An=W.peek(),Ee=null,ve=0;const xr=1e3,Nr=3e4,Wr={keeper_row_changed:["keeper","keeper_lifecycle","shell"],keeper_roster_changed:["keeper","keeper_lifecycle","shell"],keeper_turn_changed:["keeper","keeper_turn","shell"],keeper_turn_complete:["keeper","keeper_turn","cost","shell"],keeper_turn_succeeded:["keeper","keeper_turn"],keeper_turns:["keeper","keeper_turn","cost","shell"],keeper_memory_health:["keeper","memory"],keeper_waiting_inventory_changed:["keeper","keeper_turn","tool_approval","approval"],keeper_tool_approval_waits_changed:["tool_approval","approval","keeper_turn"],keeper_tool_approval_mode_changed:["keeper","tool_approval","approval"],keeper_asks_changed:["keeper_ask","ask"],"approval:pending":["approval","tool_approval","gate"],"approval:resolved":["approval","tool_approval","gate"],"approval:summary_updated":["approval","tool_approval","gate"],pending_confirms_changed:["goal","goals","approval"],schedule_store_changed:["schedules","task","tasks"],scheduled_automation_changed:["schedules","task","tasks"],scheduled_automation:["schedules","task","tasks"],goal_projection_changed:["goal","goals","task","tasks","shell"],provider_standing:["provider","quota","keeper"],provider_usage:["provider","quota"],verification_requests:["verification","goal","goals","task","tasks"],board:["board","board_post","board_comment"],board_changed:["board","board_post","board_comment"],"notifications/board":["board","board_post","board_comment"],board_post:["board","board_post"],board_comment:["board","board_comment"],gate:["gate","approval"],channel_gate:["gate","approval"],memory:["memory","world_memory"],world_memory:["memory","world_memory"],workspace_memory:["memory","world_memory"],candle:["candle"],candle_ledger:["candle"],backlog:["task","tasks","goal","goals","shell"],tasks:["task","tasks","shell"],goals:["goal","goals","shell"],keepers:["keeper","keeper_lifecycle","shell"],schedules:["schedules","task","tasks"],runtime_resolved:["runtime","provider_usage","config"],runtime_probe:["runtime_probe","runtime"],lane_addon_asks_changed:["lane_addon","lane_addon_asks"],lane_addon_exports_changed:["lane_addon"],gate_connector_changed:["connectors","gate"],ide_presence:["clients","ide_presence"],tool_metrics:["tool_metrics","tools"],model_metrics:["model_metrics","cache_stats","keeper_costs","keeper_efficiency"],telemetry:["model_metrics","tool_metrics","keeper_costs","keeper_efficiency"],skill_usage:["skills","tools"],skill_activations:["skills","tools"],async_requests:["tools"]};W.subscribe(e=>{e!==An&&(An=e,pa(),ve=0,sn=0,E(()=>{Le.value=null,pt.value=null}))});function Br(){const e=pt.peek();return!e||sn!==H()?null:e}function Be(e){const t=typeof e=="string"&&e.trim().length>0?e.trim():null;pt.value=t,sn=t?H():0}function ua(e){if(e.kind==="multi_account_signed_in")return{url:lt("/api/v1/auth/events"),headers:{Accept:"text/event-stream"}};if(e.kind==="single_user_local"){if(e.role==="player")return null;const t={Accept:"text/event-stream"},n=an();return n&&(t.Authorization=`Bearer ${n}`),{url:lt("/mcp?sse_kind=observer"),headers:t}}return null}function As(){fe.peek()?te.value="LIVE SSE":te.peek()!=="STREAM_GAP"&&(te.value="SYNCED")}function Cs(){fe.peek()||(te.value="SNAPSHOT")}function nt(e){E(()=>{te.value="STREAM_GAP";const t=Mr();for(let n=0;n<t.length;n++)try{t[n](e)}catch{}})}function qr(e){return Dt.add(e),qe=null,()=>{Dt.delete(e)&&(qe=null)}}function Hr(e){return xt.add(e),He=null,()=>{xt.delete(e)&&(He=null)}}function Kr(e){return ct.add(e),Ke=null,()=>{ct.delete(e)&&(Ke=null)}}function Cn(e){let t=null,n="message",a=null,o=null;const s=e.length;let i=0;for(;i<s;){const l=e.indexOf(`
`,i),c=l===-1?s:l,p=c>i&&e.charCodeAt(c-1)===13?c-1:c;if(p>i&&e.charCodeAt(i)!==58){const u=e.indexOf(":",i),_=u!==-1&&u<p?u:-1,d=_===-1?e.slice(i,p):e.slice(i,_);let g;if(_===-1)g="";else{const S=_+1<p&&e.charCodeAt(_+1)===32?_+2:_+1;g=e.slice(S,p)}d==="id"?t=g:d==="event"?n=g||"message":d==="data"&&(o!==null?o.push(g):a===null?a=g:(o=[a,g],a=null))}if(l===-1)break;i=l+1}if(a===null&&o===null&&t===null&&n==="message")return null;const r=o!==null?o.join(`
`):a??"";let f=r;if(r.length>0)try{f=JSON.parse(r)}catch{}return{id:t,event:n,data:f,raw:r}}function M(e,t){if(typeof t=="string"){const n=t.trim();if(n.length>0&&n!=="message"){e.add(n);const a=Wr[n];if(a)for(let o=0;o<a.length;o++)e.add(a[o])}}}function bt(e,t){if(Array.isArray(t))for(let n=0;n<t.length;n++)M(e,t[n])}function da(e){const t=En.get(e);if(t!==void 0)return t;const n=new Set;if(M(n,e.event),typeof e.data=="object"&&e.data!==null){const o=e.data;if(M(n,o.type),M(n,o.event_type),M(n,o.method),M(n,o.kind),M(n,o.topic),M(n,o.dataset),bt(n,o.datasets),typeof o.payload=="object"&&o.payload!==null){const s=o.payload;M(n,s.topic),M(n,s.type),M(n,s.event_type),M(n,s.event),M(n,s.kind),M(n,s.dataset),bt(n,s.datasets)}if(typeof o.params=="object"&&o.params!==null){const s=o.params;M(n,s.topic),M(n,s.type),M(n,s.event_type),M(n,s.event),M(n,s.kind),M(n,s.dataset),bt(n,s.datasets)}}const a=Array.from(n);return En.set(e,a),a}function Gr(e,t){if(e.length!==0){t.size>0&&on.invalidateTopics(t);for(let n=0;n<e.length;n++){const a=e[n];a.id&&(Le.value=a.id);const o=Or();for(let s=0;s<o.length;s++)try{o[s](a)}catch{}}}}function Vr(e){e.length!==0&&E(()=>{let t=null,n=null;const a=()=>{t!==null&&t.length>0&&(Gr(t,n),t.length=0,n.clear())};for(let o=0;o<e.length;o++){const s=e[o],i=da(s);if(i.includes("observer_resync_required")){a(),s.id&&(Le.value=s.id),nt("observer_resync_required");continue}t===null&&(t=[],n=new Set),t.push(s);for(let r=0;r<i.length;r++)n.add(i[r])}a()})}function pa(){Ee!==null&&(clearTimeout(Ee),Ee=null)}function at(){pa(),be&&(be.abort("observer_stopped"),be=null),fe.value=!1,Be(null)}function Fr(e,t){if(t.autoReconnect===!1||!P(e)||Ee!==null)return;const n=Math.max(10,t.reconnectBaseDelayMs??xr),a=Math.min(Nr,n*2**Math.min(ve,5));ve+=1,Ee=setTimeout(()=>{Ee=null,P(e)&&be===null&&ne(t)},a)}async function ne(e={}){const t=e.fetchImpl??globalThis.fetch,n=v.peek(),a=ua(n);if(!a){at(),ve=0,te.value="SNAPSHOT";return}at();const o=H();Tn=o;const s=new AbortController;be=s;const i=W.subscribe(u=>{u!==o&&(ve=0,E(()=>{Le.value=null,at(),te.value="SNAPSHOT"}))}),r={...a.headers},f=Le.peek();f&&(r["Last-Event-ID"]=f);let l=!1,c=null;const p=()=>{c&&c.cancel().catch(()=>{})};s.signal.addEventListener("abort",p,{once:!0});try{const u=await t(a.url,{method:"GET",credentials:"same-origin",headers:r,signal:s.signal});if(P(o)&&!s.signal.aborted)if(!u.ok||!u.body)E(()=>{fe.value=!1,Be(null),nt(`observer_http_${u.status}`)}),l=u.status===408||u.status===429||u.status>=500||u.ok&&!u.body;else{const _=Br(),d=u.headers.get(Cr),g=d&&d.trim().length>0?d.trim():null,S=u.headers.get(Ir)?.trim()??null,y=S!==null&&/^[1-9][0-9]*$/.test(S)?Number(S):NaN,A=Number.isSafeInteger(y)&&y<=2147483647?y:void 0,m=te.peek()==="STREAM_GAP"||ve>0||_!==null&&g!==null&&_!==g;ve=0,E(()=>{if(g&&Be(g),fe.value=!0,te.value=m&&ct.size>0?"SYNCED":"LIVE SSE",m){on.invalidateAll();const L=Dr();for(let R=0;R<L.length;R++)try{L[R]()}catch{}}});const $=u.body.getReader();c=$;const h=new TextDecoder;let k="";const w=/\r?\n\r?\n/g,T=async()=>{if(A===void 0)return $.read();let L;try{return await Promise.race([$.read(),new Promise((R,re)=>{L=setTimeout(()=>{$.cancel().catch(()=>{}),re(new Error("observer stream idle timeout"))},A)})])}finally{L!==void 0&&clearTimeout(L)}};for(;;){const{value:L,done:R}=await T();if(R||!P(o)||s.signal.aborted)break;k+=h.decode(L,{stream:!0});const re=[];if(k.indexOf("\r")===-1){let V=0;for(;;){const J=k.indexOf(`

`,V);if(J===-1)break;const O=k.slice(V,J),oe=Cn(O);oe&&re.push(oe),V=J+2}V>0&&(k=k.slice(V))}else{w.lastIndex=0;let V=0,J;for(;(J=w.exec(k))!==null;){const O=k.slice(V,J.index),oe=Cn(O);oe&&re.push(oe),V=J.index+J[0].length}V>0&&(k=k.slice(V))}re.length>0&&Vr(re)}P(o)&&!s.signal.aborted&&(E(()=>{fe.value=!1,Be(null),nt("observer_eof")}),l=!0)}}catch{P(o)&&!s.signal.aborted&&(E(()=>{fe.value=!1,Be(null),nt("observer_disconnected")}),l=!0)}finally{s.signal.removeEventListener("abort",p),c=null,i(),be===s&&Tn===o&&(be=null)}l&&!s.signal.aborted&&P(o)&&Fr(o,e)}const ut=C(null),Nt=C(0),he=C(!1);let q=null,In=!1;const Is=he;function dt(e){const t=e.controller,n=e.cleanup;if(e.controller=null,e.cleanup=null,t&&!t.signal.aborted&&t.abort("view_stream_preempted"),n)try{n()}catch{}}function fa(e){if(q!==e)return;if(typeof document<"u"&&document.hidden){he.value=!0;return}const t=Nt.peek()+1;E(()=>{he.value=!1,Nt.value=t}),e.generation=t;const n=new AbortController;e.controller=n;try{const a=e.connect(n.signal,t);typeof a=="function"&&(e.cleanup=a)}catch(a){throw e.controller=null,e.cleanup=null,n.signal.aborted||n.abort("view_stream_connect_failed"),q===e&&(q=null,E(()=>{ut.value=null,he.value=!1})),a}}function zr(){In||(In=!0,W.subscribe(()=>{q&&q.epoch!==H()&&ma()}),typeof document<"u"&&document.addEventListener("visibilitychange",()=>{q&&(document.hidden?(dt(q),he.value=!0):q.controller===null&&fa(q))}))}function Ps(e,t){zr(),q&&(dt(q),q=null);const n={key:e,connect:t,epoch:H(),generation:Nt.peek(),controller:null,cleanup:null};return q=n,E(()=>{ut.value=e,fa(n)}),{key:e,get generation(){return n.generation},paused:he,release(){q===n&&(dt(n),q=null,E(()=>{ut.value=null,he.value=!1}))}}}function ma(){q&&(dt(q),q=null),E(()=>{ut.value=null,he.value=!1})}function Te(e){return e.isComposing||e.keyCode===229}function Ls(e){return e.key==="Escape"&&!e.defaultPrevented&&!Te(e)}function Ur(e){if(!(e instanceof HTMLElement))return!1;const t=e.tagName;return t==="INPUT"||t==="TEXTAREA"||t==="SELECT"||e.isContentEditable}const ha=["chat","memory","portrait-candle","work-sandbox","config"],jr=Object.freeze({chat:"Chat",memory:"Memory","portrait-candle":"Portrait & Candle","work-sandbox":"Work & Sandbox",config:"Config"}),ln=Object.freeze([{id:"pulse",label:"Pulse",shortLabel:"Pulse",trunkKey:"1",shortcut:"1",section:"trunk",defaultPath:"/pulse",access:"member",supportsTimeWindow:!0,defaultProvenance:"LIVE SSE",subtabs:[]},{id:"work",label:"Work",shortLabel:"Work",trunkKey:"2",shortcut:"2",section:"trunk",defaultPath:"/work/goals",access:"member",defaultProvenance:"SYNCED",subtabs:[{id:"goals",label:"Goals",path:"/work/goals",access:"member",defaultProvenance:"SYNCED"},{id:"tasks",label:"Tasks",path:"/work/tasks",access:"member",defaultProvenance:"SYNCED"},{id:"inbox",label:"Inbox",path:"/work/inbox",access:"member",defaultProvenance:"LIVE SSE"},{id:"candle",label:"Candle",path:"/work/candle",access:"member",supportsTimeWindow:!0,defaultProvenance:"SYNCED"}]},{id:"knowledge",label:"Knowledge",shortLabel:"Know",trunkKey:"3",shortcut:"3",section:"trunk",defaultPath:"/knowledge/board",access:"member",defaultProvenance:"SYNCED",subtabs:[{id:"board",label:"Board",path:"/knowledge/board",access:"member",defaultProvenance:"SYNCED"},{id:"wiki",label:"Wiki",path:"/knowledge/wiki",access:"member",defaultProvenance:"SYNCED"},{id:"artifacts",label:"Artifacts",path:"/knowledge/artifacts",access:"member",defaultProvenance:"SNAPSHOT"},{id:"memory",label:"Memory",path:"/knowledge/memory",access:"member",supportsTimeWindow:!0,defaultProvenance:"SYNCED"}]},{id:"keepers",label:"Keepers",shortLabel:"Keep",trunkKey:"4",shortcut:"4",section:"trunk",defaultPath:"/keepers",access:"member",defaultProvenance:"LIVE SSE",subtabs:[]},{id:"runtime",label:"Runtime",shortLabel:"Run",trunkKey:"5",shortcut:"5",section:"trunk",defaultPath:"/runtime/quotas",access:"member",supportsTimeWindow:!0,defaultProvenance:"SYNCED",subtabs:[{id:"quotas",label:"Quotas",path:"/runtime/quotas",access:"member",supportsTimeWindow:!0,defaultProvenance:"SYNCED"},{id:"efficiency",label:"Efficiency",path:"/runtime/efficiency",access:"member",supportsTimeWindow:!0,defaultProvenance:"LIVE SSE"},{id:"lanes",label:"Lanes",path:"/runtime/lanes",access:"member",supportsTimeWindow:!0,defaultProvenance:"SYNCED"},{id:"tools",label:"Tools",path:"/runtime/tools",access:"member",supportsTimeWindow:!0,defaultProvenance:"LIVE SSE"},{id:"addons",label:"Add-ons",path:"/runtime/addons",access:"member",supportsTimeWindow:!0,defaultProvenance:"SYNCED"}]},{id:"infra",label:"Infra",shortLabel:"Infra",trunkKey:"6",shortcut:"6",section:"trunk",defaultPath:"/infra/sandboxes",access:"su_read_ma_admin",defaultProvenance:"SYNCED",subtabs:[{id:"sandboxes",label:"Sandboxes",path:"/infra/sandboxes",access:"su_read_ma_admin",defaultProvenance:"SYNCED"},{id:"repos",label:"Repos",path:"/infra/repos",access:"su_read_ma_admin",defaultProvenance:"SNAPSHOT"},{id:"logs",label:"Logs",path:"/infra/logs",access:"su_read_ma_admin",defaultProvenance:"LIVE SSE"}]},{id:"settings",label:"Settings",shortLabel:"Set",shortcut:",",section:"footer",defaultPath:"/settings",access:"admin",defaultProvenance:"SYNCED",subtabs:[]},{id:"account",label:"Account",shortLabel:"Acct",section:"footer",defaultPath:"/account",access:"public",defaultProvenance:"SYNCED",subtabs:[{id:"profile",label:"Profile",path:"/account/profile",access:"public",defaultProvenance:"SYNCED"},{id:"pats",label:"Tokens",path:"/account/pats",access:"member",defaultProvenance:"SYNCED"},{id:"members",label:"Members",path:"/account/members",access:"admin",defaultProvenance:"SYNCED"},{id:"invites",label:"Invites",path:"/account/invites",access:"admin",defaultProvenance:"SYNCED"},{id:"allowlist",label:"Allowlist",path:"/account/allowlist",access:"admin",defaultProvenance:"SYNCED"}]}]),ka=Object.freeze(ln.filter(e=>e.section==="trunk")),Yr=Object.freeze(ln.filter(e=>e.section==="footer")),pe=Object.freeze(Object.fromEntries(ln.map(e=>[e.id,e]))),Rs=Object.freeze([{id:"pulse",workspace:"pulse",subroute:"overview",path:"/pulse",label:"1 Pulse — Fleet Overview",keywords:["overview","home","kpi","heartbeat","펄스","개요"],access:"member",supportsTimeWindow:!0,defaultProvenance:"LIVE SSE"},{id:"work-goals",workspace:"work",subroute:"goals",path:"/work/goals",label:"2 Work → Goals",keywords:["goal","criterion","verification","목표"],access:"member",supportsTimeWindow:!1,defaultProvenance:"SYNCED"},{id:"work-tasks",workspace:"work",subroute:"tasks",path:"/work/tasks",label:"2 Work → Tasks & Schedules",keywords:["task","schedule","backlog","cron","작업","일정"],access:"member",supportsTimeWindow:!1,defaultProvenance:"SYNCED"},{id:"work-inbox",workspace:"work",subroute:"inbox",path:"/work/inbox",label:"2 Work → Unified Inbox (HITL)",keywords:["inbox","approval","ask","gate","승인","질문","인박스"],access:"member",supportsTimeWindow:!1,defaultProvenance:"LIVE SSE"},{id:"work-candle",workspace:"work",subroute:"candle",path:"/work/candle",label:"2 Work → Candle & Scorecard",keywords:["candle","ledger","reward","scorecard","캔들"],access:"member",supportsTimeWindow:!0,defaultProvenance:"SYNCED"},{id:"knowledge-board",workspace:"knowledge",subroute:"board",path:"/knowledge/board",label:"3 Knowledge → Board",keywords:["board","hearth","post","comment","게시판"],access:"member",supportsTimeWindow:!1,defaultProvenance:"SYNCED"},{id:"knowledge-wiki",workspace:"knowledge",subroute:"wiki",path:"/knowledge/wiki",label:"3 Knowledge → Librarian Wiki",keywords:["wiki","lint","librarian","위키"],access:"member",supportsTimeWindow:!1,defaultProvenance:"SYNCED"},{id:"knowledge-artifacts",workspace:"knowledge",subroute:"artifacts",path:"/knowledge/artifacts",label:"3 Knowledge → Artifacts",keywords:["artifact","html","markdown","아티팩트"],access:"member",supportsTimeWindow:!1,defaultProvenance:"SNAPSHOT"},{id:"knowledge-memory",workspace:"knowledge",subroute:"memory",path:"/knowledge/memory",label:"3 Knowledge → World Memory & Diff",keywords:["memory","world","conflict","diff","기억","메모리"],access:"member",supportsTimeWindow:!0,defaultProvenance:"SYNCED"},{id:"keepers-fleet",workspace:"keepers",subroute:"fleet",path:"/keepers",label:"4 Keepers → Fleet Wall",keywords:["keeper","agent","fleet","chat","키퍼"],access:"member",supportsTimeWindow:!1,defaultProvenance:"LIVE SSE"},{id:"runtime-quotas",workspace:"runtime",subroute:"quotas",path:"/runtime/quotas",label:"5 Runtime → Provider Quotas & Rate Limits",keywords:["provider","quota","rate limit","429","api key","프로바이더","할당량"],access:"member",supportsTimeWindow:!0,defaultProvenance:"SYNCED"},{id:"runtime-efficiency",workspace:"runtime",subroute:"efficiency",path:"/runtime/efficiency",label:"5 Runtime → Efficiency & Prompt Cache",keywords:["cache","cost","spend","velocity","캐시","효율"],access:"member",supportsTimeWindow:!0,defaultProvenance:"LIVE SSE"},{id:"runtime-lanes",workspace:"runtime",subroute:"lanes",path:"/runtime/lanes",label:"5 Runtime → Lanes, Exact Output & Fusion",keywords:["lane","failover","exact","fusion","model","레인"],access:"member",supportsTimeWindow:!0,defaultProvenance:"SYNCED"},{id:"runtime-tools",workspace:"runtime",subroute:"tools",path:"/runtime/tools",label:"5 Runtime → Tools, Skills & Connectors",keywords:["tool","skill","connector","discord","slack","도구"],access:"member",supportsTimeWindow:!0,defaultProvenance:"LIVE SSE"},{id:"runtime-addons",workspace:"runtime",subroute:"addons",path:"/runtime/addons",label:"5 Runtime → Lane Add-ons & Browser Lane",keywords:["addon","browser","plugin","애드온"],access:"member",supportsTimeWindow:!0,defaultProvenance:"SYNCED"},{id:"infra-sandboxes",workspace:"infra",subroute:"sandboxes",path:"/infra/sandboxes",label:"6 Infra → Sandboxes (MicroVM / SSH / Docker)",keywords:["sandbox","microvm","ssh","docker","샌드박스"],access:"su_read_ma_admin",supportsTimeWindow:!1,defaultProvenance:"SYNCED"},{id:"infra-repos",workspace:"infra",subroute:"repos",path:"/infra/repos",label:"6 Infra → Repositories & 24h Diffs",keywords:["repo","git","diff","저장소"],access:"su_read_ma_admin",supportsTimeWindow:!1,defaultProvenance:"SNAPSHOT"},{id:"infra-logs",workspace:"infra",subroute:"logs",path:"/infra/logs",label:"6 Infra → Live SSE Logs",keywords:["log","logs","stream","로그"],access:"su_read_ma_admin",supportsTimeWindow:!1,defaultProvenance:"LIVE SSE"},{id:"settings",workspace:"settings",subroute:"runtime",path:"/settings",label:"Settings — Schema Config & TOML Patch",keywords:["setting","config","toml","schema","설정"],access:"admin",supportsTimeWindow:!1,defaultProvenance:"SYNCED"},{id:"account-profile",workspace:"account",subroute:"profile",path:"/account/profile",label:"Account: Profile, Sessions & Workspaces",keywords:["account","profile","login","logout","workspace","bearer","계정"],access:"public",supportsTimeWindow:!1,defaultProvenance:"SYNCED"},{id:"account-pats",workspace:"account",subroute:"pats",path:"/account/pats",label:"Account: Personal Access Tokens (PATs)",keywords:["account","pat","token","mcp","토큰"],access:"member",supportsTimeWindow:!1,defaultProvenance:"SYNCED"},{id:"account-members",workspace:"account",subroute:"members",path:"/account/members",label:"Account: Members & Admin Lifecycle",keywords:["account","member","admin","disable","revoke","구성원"],access:"admin",supportsTimeWindow:!1,defaultProvenance:"SYNCED"},{id:"account-invites",workspace:"account",subroute:"invites",path:"/account/invites",label:"Account: Invitations",keywords:["account","invite","초대"],access:"admin",supportsTimeWindow:!1,defaultProvenance:"SYNCED"},{id:"account-allowlist",workspace:"account",subroute:"allowlist",path:"/account/allowlist",label:"Account: Sign-In Allowlist",keywords:["account","allowlist","google","github","허용 목록"],access:"admin",supportsTimeWindow:!1,defaultProvenance:"SYNCED"}]),Zr=Object.freeze({"":"/pulse","/":"/pulse","/overview":"/pulse","/command":"/pulse","/monitoring":"/runtime/efficiency","/monitor":"/runtime/efficiency","/connectors":"/runtime/tools","/tools":"/runtime/tools","/approvals":"/work/inbox","/inbox":"/work/inbox","/gate":"/work/inbox","/goals":"/work/goals","/tasks":"/work/tasks","/schedule":"/work/tasks","/candle":"/work/candle","/board":"/knowledge/board","/wiki":"/knowledge/wiki","/artifacts":"/knowledge/artifacts","/memory":"/knowledge/memory","/logs":"/infra/logs","/sandboxes":"/infra/sandboxes","/repos":"/infra/repos","/config":"/settings","/accounts":"/account","/login":"/account"});function Qr(e){const t={};return e&&new URLSearchParams(e).forEach((a,o)=>{t[o]=a}),t}function Jr(e){const t=e.trim(),n=t.startsWith("#")?t.slice(1):t,a=n.indexOf("?"),o=a===-1?n:n.slice(0,a),s=a===-1?"":n.slice(a+1),i=Qr(s);let r=o.startsWith("/")?o:`/${o}`;r=r.replace(/\/+/g,"/"),r.length>1&&r.endsWith("/")&&(r=r.slice(0,-1));const f=r.toLowerCase();if((f==="/monitoring"||f==="/monitor")&&i.section==="board")return{pathname:"/knowledge/board",query:i};const l=Zr[f];return l?{pathname:l,query:i}:{pathname:r,query:i}}function Xr(e){return ha.find(t=>t===e)??"chat"}function cn(e){const{pathname:t,query:n}=Jr(e),a=t.split("/").filter(Boolean),o=(a[0]??"pulse").toLowerCase();if(o==="pulse")return{path:"/pulse",workspace:"pulse",subroute:"overview",query:n,access:"member",supportsTimeWindow:!0,defaultProvenance:"LIVE SSE"};if(o==="work"){const s=pe.work.subtabs,i=(a[1]??"goals").toLowerCase(),r=s.find(l=>l.id===i)??s[0],f=a[2]?decodeURIComponent(a[2]):void 0;return{path:f?`/work/${r.id}/${encodeURIComponent(f)}`:r.path,workspace:"work",subroute:r.id,entityId:f,query:n,access:r.access,supportsTimeWindow:r.supportsTimeWindow===!0,defaultProvenance:r.defaultProvenance??"SYNCED"}}if(o==="knowledge"){const s=pe.knowledge.subtabs,i=(a[1]??"board").toLowerCase(),r=s.find(l=>l.id===i)??s[0],f=a[2]?decodeURIComponent(a[2]):r.id==="board"&&n.post||void 0;return{path:f?`/knowledge/${r.id}/${encodeURIComponent(f)}`:r.path,workspace:"knowledge",subroute:r.id,entityId:f,query:n,access:r.access,supportsTimeWindow:r.supportsTimeWindow===!0,defaultProvenance:r.defaultProvenance??"SYNCED"}}if(o==="keepers"){if(!a[1])return{path:"/keepers",workspace:"keepers",subroute:"fleet",query:n,access:"member",supportsTimeWindow:!1,defaultProvenance:"LIVE SSE"};const s=decodeURIComponent(a[1]),i=Xr(a[2]?.toLowerCase());return{path:`/keepers/${encodeURIComponent(s)}/${i}`,workspace:"keepers",subroute:"detail",entityId:s,entityTab:i,query:n,access:"member",supportsTimeWindow:!1,defaultProvenance:i==="chat"?"LIVE SSE":"SYNCED"}}if(o==="runtime"){const s=pe.runtime.subtabs,i=(a[1]??"quotas").toLowerCase(),r=s.find(f=>f.id===i)??s[0];return{path:r.path,workspace:"runtime",subroute:r.id,query:n,access:r.access,supportsTimeWindow:!0,defaultProvenance:r.defaultProvenance??"SYNCED"}}if(o==="infra"){const s=pe.infra.subtabs,i=(a[1]??"sandboxes").toLowerCase(),r=s.find(f=>f.id===i)??s[0];return{path:r.path,workspace:"infra",subroute:r.id,query:n,access:r.access,supportsTimeWindow:!1,defaultProvenance:r.defaultProvenance??"SYNCED"}}if(o==="settings"){const s=a[1]?.toLowerCase()||"runtime";return{path:s==="runtime"?"/settings":`/settings/${encodeURIComponent(s)}`,workspace:"settings",subroute:s,query:n,access:"admin",supportsTimeWindow:!1,defaultProvenance:"SYNCED"}}if(o==="account"){const s=pe.account.subtabs,i=(a[1]??"profile").toLowerCase(),r=s.find(f=>f.id===i)??s[0];return{path:r.id==="profile"&&!a[1]?"/account":r.path,workspace:"account",subroute:r.id,query:n,access:r.access,supportsTimeWindow:!1,defaultProvenance:"SYNCED"}}return{path:"/pulse",workspace:"pulse",subroute:"overview",query:n,access:"member",supportsTimeWindow:!0,defaultProvenance:"LIVE SSE"}}function eo(e,t){if(e==="public")return{allowed:!0};switch(t.kind){case"probing":return{allowed:!1,reason:"probing"};case"unavailable":return{allowed:!1,reason:"unavailable"};case"account_changed":return{allowed:!1,reason:"account_changed"};case"multi_account_signed_out":case"single_user_auth_required":return{allowed:!1,reason:"auth_required"};case"single_user_local":return e==="member"&&!G(t)?{allowed:!1,reason:"role_restricted"}:e==="su_read_ma_admin"&&!Mt(t)?{allowed:!1,reason:"admin_only"}:e==="admin"&&!Ot(t)?{allowed:!1,reason:"admin_only"}:{allowed:!0};case"multi_account_signed_in":return e==="su_read_ma_admin"&&!Mt(t)?{allowed:!1,reason:"admin_only"}:e==="admin"&&!Ot(t)?{allowed:!1,reason:"admin_only"}:{allowed:!0}}}function Re(e,t){return e==="member"?t.kind==="single_user_local"&&t.role==="player":e==="su_read_ma_admin"?!Mt(t):e==="admin"?!Ot(t):!1}function ga(){return typeof window>"u"?"#/pulse":window.location.hash||"#/pulse"}const un=C(cn(ga())),Ne=un;let _t=!1;function N(e,t={}){const n=cn(e),a=Object.entries(n.query),o=a.length>0?`?${new URLSearchParams(a).toString()}`:"",s=`#${n.path}${o}`;return un.value=n,typeof window<"u"&&(t.replace&&typeof window.history?.replaceState=="function"?window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${s}`):window.location.hash!==s&&(window.location.hash=s)),n}function to(){if(typeof window>"u")return()=>{};const e=()=>{un.value=cn(ga())};return e(),_t?()=>{}:(_t=!0,window.addEventListener("hashchange",e),window.addEventListener("popstate",e),()=>{_t=!1,window.removeEventListener("hashchange",e),window.removeEventListener("popstate",e)})}const no=Object.freeze({pulse:{id:"pulse",title:"1 Pulse",load:async()=>({default:(await F(()=>import("./index6.js"),__vite__mapDeps([0,1,2,3,4,5,6,7,8,9,10,11,12,13]))).PulseWorkspace})},work:{id:"work",title:"2 Work",load:async()=>({default:(await F(()=>import("./index5.js"),__vite__mapDeps([14,1,15,16,17,18,19,9,3,2,4,5,11,20,21,22,6,23,24,25,26,27,28,29]))).WorkWorkspace})},knowledge:{id:"knowledge",title:"3 Knowledge",load:async()=>({default:(await F(()=>import("./index2.js"),__vite__mapDeps([30,1,15,31,16,17,5,3,18,19,22,6,24,25,26,28,32]))).KnowledgeWorkspace})},keepers:{id:"keepers",title:"4 Keepers",load:async()=>({default:(await F(()=>import("./index3.js").then(t=>t.O),__vite__mapDeps([33,1,15,2,3,4,5,34,12,35,36,27,31,16,17,18,19,10,37,20,24,25,26,23,38,21,28,39]))).KeepersWorkspace})},runtime:{id:"runtime",title:"5 Runtime",load:async()=>({default:(await F(()=>import("./index8.js"),__vite__mapDeps([40,1,24,25,26,22,41,6,16,17,36,7,42,5,3,43,35,18,19,12,34,11,4,21,28]))).RuntimeWorkspace})},infra:{id:"infra",title:"6 Infra",load:async()=>({default:(await F(()=>import("./index9.js"),__vite__mapDeps([44,1,5,3,35,21,11,4,24,25,26,41,19,17,42,36,37,20,45,6,46]))).InfraWorkspace})},settings:{id:"settings",title:"Settings",load:async()=>({default:(await F(()=>import("./index4.js"),__vite__mapDeps([47,1,45,16,17,6,48,3,28]))).SettingsWorkspace})},account:{id:"account",title:"Account",load:async()=>({default:(await F(()=>import("./index7.js"),__vite__mapDeps([49,1,18,19]))).AccountWorkspace})}}),Qe=new Map,Je=new Map,va=new Map;function Os(e,t){va.set(e,t)}function Pn(e,t){va.get(e)?.(t)}class ba extends Error{constructor(t){super(t instanceof Error?t.message:String(t),{cause:t})}}function _a(e){let t=Je.get(e);if(!t){const n=no[e].load().then(a=>a,a=>{throw Je.get(e)===n&&Je.delete(e),a});t=n,Je.set(e,t)}return t}function Wt(e){_a(e).catch(()=>{})}function ao(e){let t=Qe.get(e);if(!t){const n=De(async()=>{try{return await _a(e)}catch(a){throw Qe.get(e)===n&&Qe.delete(e),new ba(a)}});t=n,Qe.set(e,t)}return t}const ro=Object.freeze({pulse:"M2 12h3.5l2-6 4 12 2.5-6H22",work:"M9 5H7a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V7a2 2 0 0 0-2-2h-2M9 5a2 2 0 0 0 2 2h2a2 2 0 0 0 2-2M9 5a2 2 0 0 1 2-2h2a2 2 0 0 1 2 2m-6 9 2 2 4-4",knowledge:"M4 19.5A2.5 2.5 0 0 1 6.5 17H20M4 19.5A2.5 2.5 0 0 0 6.5 22H20V2H6.5A2.5 2.5 0 0 0 4 4.5v15Z",keepers:"M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2M9 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8Zm14 10v-2a4 4 0 0 0-3-3.87M16 3.13a4 4 0 0 1 0 7.75",runtime:"M13 2 3 14h9l-1 8 10-12h-9l1-8Z",infra:"M2 6a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v4a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V6Zm0 10a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v2a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2v-2Zm4-8h.01M6 17h.01",settings:"M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6Zm7.4-3a7.4 7.4 0 0 0-.1-1l2-1.5-2-3.4-2.3.9a7.7 7.7 0 0 0-1.7-1l-.4-2.5H9.1l-.4 2.5a7.7 7.7 0 0 0-1.7 1l-2.3-.9-2 3.4 2 1.5a7.4 7.4 0 0 0 0 2l-2 1.5 2 3.4 2.3-.9c.5.4 1.1.8 1.7 1l.4 2.5h5.8l.4-2.5c.6-.2 1.2-.6 1.7-1l2.3.9 2-3.4-2-1.5c.1-.3.1-.7.1-1Z",account:"M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2M12 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8Z",lock:"M7 11V7a5 5 0 0 1 10 0v4M5 11h14a2 2 0 0 1 2 2v7a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-7a2 2 0 0 1 2-2Z",search:"M11 19a8 8 0 1 0 0-16 8 8 0 0 0 0 16Zm10 2-4.35-4.35",inbox:"M22 12h-6l-2 3h-4l-2-3H2m20 0v6a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2v-6m20 0-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11L2 12",layers:"M12 2 2 7l10 5 10-5-10-5ZM2 17l10 5 10-5M2 12l10 5 10-5",bell:"M18 8A6 6 0 0 0 6 8c0 7-3 9-3 9h18s-3-2-3-9m-4.27 13a2 2 0 0 1-3.46 0",sidebar:"M3 5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5Zm6-2v18",chevron:"m6 9 6 6 6-6",more:"M12 13a1 1 0 1 0 0-2 1 1 0 0 0 0 2Zm7 0a1 1 0 1 0 0-2 1 1 0 0 0 0 2ZM5 13a1 1 0 1 0 0-2 1 1 0 0 0 0 2Z",check:"M20 6 9 17l-5-5",x:"M18 6 6 18M6 6l12 12",alert:"M10.29 3.86 1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0ZM12 9v4m0 4h.01",refresh:"M23 4v6h-6M1 20v-6h6M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15",sun:"M12 17a5 5 0 1 0 0-10 5 5 0 0 0 0 10Zm0-15v2m0 16v2M4.93 4.93l1.41 1.41m11.32 11.32 1.41 1.41M2 12h2m16 0h2M4.93 19.07l1.41-1.41m11.32-11.32 1.41-1.41",moon:"M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79Z",contrast:"M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20Zm0 2v16a8 8 0 0 0 0-16Z"});function D({name:e,size:t=16,className:n=""}){return b`
    <svg
      width=${t}
      height=${t}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.8"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
      class=${`ap-icon ${n}`.trim()}
    >
      <path d=${ro[e]} />
    </svg>
  `}const oo=["a[href]","button:not([disabled])",'input:not([disabled]):not([type="hidden"])',"select:not([disabled])","textarea:not([disabled])",'[tabindex]:not([tabindex="-1"])','[contenteditable=""]','[contenteditable="true"]'].join(", ");function We(e){const t=e.querySelectorAll(oo);return Array.from(t).filter(n=>n.getAttribute("tabindex")!=="-1")}function se(e){e&&typeof e.focus=="function"&&e.focus()}function so(e){const t=e.loop??!0,n=e.restoreFocus??!0,a=e.initialFocus??"first";let o=!1,s=null,i=null,r=null;function f(){return e.containerRef()}function l(p){if(typeof a=="function"){se(a());return}if(a==="container"){se(p);return}const u=We(p);se(u[0]??p)}function c(p){if(p.key!=="Tab")return;const u=f();if(!u)return;const _=We(u);if(_.length===0){p.preventDefault(),se(u);return}const d=_[0],g=_[_.length-1],S=u.ownerDocument?.activeElement??null;t&&(p.shiftKey&&S===d?(p.preventDefault(),se(g)):!p.shiftKey&&S===g&&(p.preventDefault(),se(d)))}return{activate(){if(o)return;const p=f();if(!p)return;s=(p.ownerDocument??document).activeElement??null,i=c,p.addEventListener("keydown",i),r=p,l(p),o=!0},deactivate(){o&&(r&&i&&r.removeEventListener("keydown",i),i=null,r=null,n&&se(s),s=null,o=!1)},focusFirst(){const p=f();p&&se(We(p)[0])},focusLast(){const p=f();if(!p)return;const u=We(p);se(u[u.length-1])},contains(p){const u=f();return u?u.contains(p):!1},tabbables(){const p=f();return p?We(p):[]}}}function io(e){const{containerRef:t,active:n=!0,loop:a=!0,restoreFocus:o=!0,initialFocus:s="first"}=e,i=U(null);return i.current===null&&(i.current=so({containerRef:()=>t.current,loop:a,restoreFocus:o,initialFocus:s})),le(()=>{const r=i.current;if(r!==null){if(n)return r.activate(),()=>r.deactivate();r.deactivate()}},[n]),{scope:i.current}}function Oe(e){return{ok:!0,value:e}}function I(e){return{ok:!1,error:e}}const Ms={right(e){return{_tag:"Right",right:e}},left(e){return{_tag:"Left",left:e}},isRight(e){return e._tag==="Right"},isLeft(e){return e._tag==="Left"}},yt=Object.freeze({_tag:"None"}),Ds={some(e){return{_tag:"Some",value:e}},none(){return yt},fromNullable(e){return e==null?yt:{_tag:"Some",value:e}},isSome(e){return e._tag==="Some"},isNone(e){return e._tag==="None"},match(e,t){return e._tag==="Some"?t.onSome(e.value):t.onNone()},map(e,t){return e._tag==="Some"?{_tag:"Some",value:t(e.value)}:yt},orElse(e,t){return e._tag==="Some"?e:t()},getOrElse(e,t){return e._tag==="Some"?e.value:t()},getOrNull(e){return e._tag==="Some"?e.value:null},getOrUndefined(e){return e._tag==="Some"?e.value:void 0},getOrThrow(e){if(e._tag==="Some")return e.value;throw new Error("Option.getOrThrow called on None")}},Bt=new Set(["POST","PUT","PATCH","DELETE"]),lo=64,qt=new WeakMap,Ht=new WeakMap,ya=new WeakMap;function Kt(e){return ya.get(e)??0}function co(e){ya.set(e,Kt(e)+1),qt.get(e)?.clear(),Ht.get(e)?.clear(),e===globalThis.fetch&&gr()}function uo(e){let t=qt.get(e);return t||(t=new Map,qt.set(e,t)),t}function wa(e){let t=Ht.get(e);return t||(t=new Map,Ht.set(e,t)),t}function Ln(e,t,n){const a=wa(e);if(a.delete(t),a.set(t,n),a.size>lo){const o=a.keys().next().value;o!==void 0&&a.delete(o)}}function po(e){const t=Object.keys(e).sort();let n="";for(let a=0;a<t.length;a++){const o=t[a];n+=`${o.toLowerCase()}=${e[o]}\0`}return n}function fo(e,t){if(!e)return!1;for(const n of Object.keys(e))if(n.toLowerCase()===t)return!0;return!1}function ze(e){return typeof e=="object"&&e!==null&&!Array.isArray(e)}function Xe(e,t){let n=null,a=`HTTP ${e}`,o;ze(t)&&(ze(t.error)?(typeof t.error.code=="string"&&(n=t.error.code),typeof t.error.message=="string"&&(a=t.error.message),typeof t.error.field=="string"&&(o=t.error.field)):typeof t.error=="string"?(a=t.error,typeof t.code=="string"&&(n=t.code)):typeof t.message=="string"&&(a=t.message,typeof t.code=="string"&&(n=t.code)));const s=t!=null?{body:t}:{};return e===401?{kind:"unauthorized",status:e,code:n,message:a,retryable:!1,field:o,...s}:e===403?{kind:n==="csrf_invalid"||n==="csrf_missing"||/\bcsrf\b/i.test(a)?"csrf_rejected":"forbidden",status:e,code:n,message:a,retryable:!1,field:o,...s}:e===404?{kind:"not_found",status:e,code:n,message:a,retryable:!1,field:o,...s}:e===409?{kind:"conflict_cas",status:e,code:n,message:a,retryable:!1,field:o,...s}:e>=400&&e<500?{kind:"validation",status:e,code:n,message:a,retryable:!1,field:o,...s}:{kind:"server",status:e,code:n,message:a,retryable:e>=500,field:o,...s}}function mo(e){if(!ze(e))return I({kind:"decode",status:200,code:"invalid_envelope",message:"Expected V2 JSON object",retryable:!1});if(ze(e.error)){const t=typeof e.error.code=="string"?e.error.code:"v2_error",n=typeof e.error.message=="string"?e.error.message:"Server error",a=typeof e.error.field=="string"?e.error.field:void 0,o=t==="conflict_cas"?"conflict_cas":t==="unauthorized"?"unauthorized":t==="not_found"?"not_found":t==="store_unavailable"?"server":"validation";return I({kind:o,status:null,code:t,message:n,retryable:o==="server",field:a})}return"data"in e?Oe(e.data):I({kind:"decode",status:200,code:"missing_data",message:"V2 envelope missing data field",retryable:!1})}function ho(e){return!ze(e)||typeof e.ok!="boolean"?I({kind:"decode",status:200,code:"invalid_ok_envelope",message:"Expected { ok, data } object",retryable:!1}):e.ok?Oe(e.data):I({kind:"validation",status:200,code:typeof e.code=="string"?e.code:"not_ok",message:typeof e.error=="string"?e.error:"Request failed",retryable:!1})}function Rn(e,t,n){const a={Accept:"application/json",...n};if(t&&!("Content-Type"in a)&&(a["Content-Type"]="application/json"),v.peek().kind==="multi_account_signed_in"){if(Bt.has(e)){const s=aa();s&&(a["x-masc-csrf-token"]=s)}}else{const s=an();s&&!("Authorization"in a)&&(a.Authorization=`Bearer ${s}`)}return a}function wt(e,t,n){let a=t;if(n.envelope==="v2"){const o=mo(t);if(!o.ok)return o;a=o.value}else if(n.envelope==="ok_data"){const o=ho(t);if(!o.ok)return o;a=o.value}if(n.decode)try{return Oe(n.decode(a))}catch(o){return I({kind:"decode",status:e,code:"schema_drift",message:o instanceof Error?o.message:String(o),retryable:!1,cause:o})}return Oe(a)}async function ft(e){const t=e.method??"GET",n=e.fetchImpl??globalThis.fetch,a=H(),o=new AbortController,s=()=>o.abort(e.signal?.reason);if(e.signal){if(e.signal.aborted)return I({kind:"aborted",status:null,code:null,message:"Request aborted",retryable:!1});e.signal.addEventListener("abort",s,{once:!0})}const i=W.subscribe(l=>{l!==a&&o.abort("epoch_stale")}),r=async()=>{if(!P(a))return I({kind:"epoch_stale",status:null,code:"epoch_stale",message:"Session epoch changed",retryable:!1});if(o.signal.aborted)return I({kind:"aborted",status:null,code:null,message:"Request aborted",retryable:!1});const l=Rn("GET",!1,e.headers),c=lt(e.path),p=po(l),u=e.cache!=="no-store"&&!fo(e.headers,"if-none-match"),_=`${c}\0${p}`;if(n===globalThis.fetch&&!e.headers&&e.cache!=="no-store"&&e.path==="/api/v1/dashboard/shell"&&c==="/api/v1/dashboard/shell"){const w=br(a,an(),x.peek());if(w!==null)return w.etag&&u&&Ln(n,_,{epoch:a,etag:w.etag,parsedBody:w.payload,status:200}),wt(200,w.payload,e)}const d=Kt(n),g=`${a}\0${d}\0${c}\0${e.cache??""}\0${p}`,S=uo(n);let y=S.get(g);if(y&&y.controller.signal.aborted&&(S.delete(g),y=void 0),!y){const w=new AbortController,T=W.subscribe(O=>{O!==a&&(S.get(g)?.controller===w&&S.delete(g),w.abort("epoch_stale"))}),L=u?wa(n).get(_):void 0,R=L&&L.epoch===a?L:void 0,V={method:"GET",credentials:"same-origin",headers:R?{...l,"If-None-Match":R.etag}:l,signal:w.signal,...e.cache&&{cache:e.cache}},J=(async()=>{try{let O;try{O=await n(c,V)}catch(z){return P(a)?w.signal.aborted?I({kind:"aborted",status:null,code:null,message:"Request aborted",retryable:!1,cause:z}):I({kind:"network",status:null,code:"network_error",message:z instanceof Error?z.message:String(z),retryable:!0,cause:z}):I({kind:"epoch_stale",status:null,code:"epoch_stale",message:"Session epoch changed",retryable:!1,cause:z})}if(!P(a))return I({kind:"epoch_stale",status:null,code:"epoch_stale",message:"Dropped stale response after epoch change",retryable:!1});if(O.status===304&&R)return Oe({status:R.status,ok:!0,parsedBody:R.parsedBody,fromCache304:!0});let oe=null;if(O.status!==204&&O.status!==304){const z=O.headers.get("content-type")??"";try{oe=z.includes("application/json")||z===""?await O.json():await O.text()}catch(kt){return P(a)?w.signal.aborted?I({kind:"aborted",status:null,code:null,message:"Request aborted",retryable:!1,cause:kt}):O.ok?I({kind:"decode",status:O.status,code:"invalid_json",message:"Failed to parse JSON response",retryable:!1,cause:kt}):I(Xe(O.status,null)):I({kind:"epoch_stale",status:null,code:"epoch_stale",message:"Session epoch changed",retryable:!1,cause:kt})}}if(!P(a))return I({kind:"epoch_stale",status:null,code:"epoch_stale",message:"Dropped stale response after epoch change",retryable:!1});if(O.ok&&u&&Kt(n)===d){const z=O.headers.get("etag");z&&Ln(n,_,{epoch:a,etag:z,parsedBody:oe,status:O.status})}return Oe({status:O.status,ok:O.ok,parsedBody:oe,fromCache304:!1})}finally{T(),S.get(g)?.controller===w&&S.delete(g)}})();y={controller:w,refCount:0,promise:J},S.set(g,y)}y.refCount+=1;let A=!1;const m=(w,T)=>{A||(A=!0,y.refCount-=1,w&&y.refCount<=0&&(S.get(g)===y&&S.delete(g),y.controller.abort(T)))},$=e.timeoutMs??0;let h=null,k=null;try{const w=new Promise(R=>{if(k=()=>{m(!0,o.signal.reason),P(a)?R(I({kind:"aborted",status:null,code:null,message:"Request aborted",retryable:!1})):R(I({kind:"epoch_stale",status:null,code:"epoch_stale",message:"Session epoch changed",retryable:!1}))},o.signal.aborted){k();return}o.signal.addEventListener("abort",k,{once:!0}),$>0&&(h=setTimeout(()=>{m(!0,"timeout"),R(I({kind:"timeout",status:null,code:"request_timeout",message:`Request timed out after ${$}ms`,retryable:!0}))},$))}),T=await Promise.race([y.promise,w]);if(!P(a))return I({kind:"epoch_stale",status:null,code:"epoch_stale",message:"Dropped stale response after epoch change",retryable:!1});if(!T.ok)return T;const L=T.value;return L.ok?wt(L.status,L.parsedBody,e):I(Xe(L.status,L.parsedBody))}finally{h!==null&&clearTimeout(h),k!==null&&o.signal.removeEventListener("abort",k),m(!1)}},f=async()=>{if(!P(a))return I({kind:"epoch_stale",status:null,code:"epoch_stale",message:"Session epoch changed",retryable:!1});if(o.signal.aborted)return I({kind:"aborted",status:null,code:null,message:"Request aborted",retryable:!1});const l=e.timeoutMs??0,c=new AbortController;let p=!1;const u=()=>c.abort(o.signal.reason);o.signal.addEventListener("abort",u,{once:!0});let _=null;const d=new Promise((y,A)=>{const m=()=>{A(new Error(p?`Request timed out after ${l}ms`:"Request aborted"))};c.signal.addEventListener("abort",m,{once:!0}),l>0&&(_=setTimeout(()=>{p=!0,c.abort("timeout")},l))});d.catch(()=>{});const g=e.body!==void 0,S={method:t,credentials:"same-origin",headers:Rn(t,g,e.headers),signal:c.signal,...e.cache&&{cache:e.cache},...g?{body:typeof e.body=="string"?e.body:JSON.stringify(e.body)}:{}};try{let y;try{y=await Promise.race([n(lt(e.path),S),d])}catch(m){return P(a)?p?I({kind:"timeout",status:null,code:"request_timeout",message:`Request timed out after ${l}ms`,retryable:!0,cause:m}):c.signal.aborted||o.signal.aborted?I({kind:"aborted",status:null,code:null,message:"Request aborted",retryable:!1,cause:m}):I({kind:"network",status:null,code:"network_error",message:m instanceof Error?m.message:String(m),retryable:!0,cause:m}):I({kind:"epoch_stale",status:null,code:"epoch_stale",message:"Session epoch changed",retryable:!1,cause:m})}if(!P(a))return I({kind:"epoch_stale",status:null,code:"epoch_stale",message:"Dropped stale response after epoch change",retryable:!1});let A=null;if(y.status!==204){const m=y.headers.get("content-type")??"";try{A=await Promise.race([m.includes("application/json")||m===""?y.json():y.text(),d])}catch($){return P(a)?p?I({kind:"timeout",status:null,code:"request_timeout",message:`Response body timed out after ${l}ms`,retryable:!0,cause:$}):c.signal.aborted||o.signal.aborted?I({kind:"aborted",status:null,code:null,message:"Request aborted",retryable:!1,cause:$}):y.ok?I({kind:"decode",status:y.status,code:"invalid_json",message:"Failed to parse JSON response",retryable:!1,cause:$}):I(Xe(y.status,null)):I({kind:"epoch_stale",status:null,code:"epoch_stale",message:"Session epoch changed",retryable:!1,cause:$})}}return P(a)?y.ok?(Bt.has(t)&&co(n),wt(y.status,A,e)):I(Xe(y.status,A)):I({kind:"epoch_stale",status:null,code:"epoch_stale",message:"Dropped stale response after epoch change",retryable:!1})}finally{_!==null&&clearTimeout(_),o.signal.removeEventListener("abort",u)}};try{const l=t==="GET"?null:aa(),c=t==="GET"?await r():await f();if(!c.ok&&c.error.kind==="csrf_rejected"&&Bt.has(t)&&v.peek().kind==="multi_account_signed_in"&&P(a)){const p=await $r(n);if(p&&p!==l&&P(a))return await f()}return!c.ok&&c.error.kind==="forbidden"&&v.peek().kind==="multi_account_signed_in"&&P(a)&&e.path!=="/auth/session"&&e.path!=="/api/v1/auth/whoami"&&Sr(n),c}finally{i(),e.signal&&e.signal.removeEventListener("abort",s)}}function _e(e,t={}){return ft({...t,method:"GET",path:e})}function xs(e,t={}){return ft({...t,method:"GET",path:e,envelope:"v2"})}function $a(e,t,n,a={}){return ft({...a,method:e,path:t,body:n})}function Ns(e,t,n,a={}){return ft({...a,method:e,path:t,body:n,envelope:"v2"})}const Sa=["masc-theme","masc-theme-v2","dashboardTheme"],Gt="masc-contrast",ko="theme",go="contrast";function On(e){const t=e?.trim().toLowerCase()??"";return t==="light"||t==="paper"||t==="styleseed"?"light":"dark"}function Mn(e){const t=e?.trim().toLowerCase()??"";return t==="high"||t==="more"?"high":t==="normal"||t==="default"?"normal":null}function Ea(e){typeof document>"u"||(e==="light"?document.documentElement.dataset.theme="light":delete document.documentElement.dataset.theme)}function Ta(e){typeof document>"u"||(e==="high"?document.documentElement.dataset.contrast="high":e==="normal"?document.documentElement.dataset.contrast="normal":delete document.documentElement.dataset.contrast)}function Aa(e){try{for(const t of Sa)localStorage.setItem(t,e)}catch{}}function Ca(e){try{e===null?localStorage.removeItem(Gt):localStorage.setItem(Gt,e)}catch{}}function Ia(){if(typeof window>"u")return"dark";const e=new URLSearchParams(window.location.search).get(ko);if(e!==null){const t=On(e);return Aa(t),t}try{for(const t of Sa){const n=localStorage.getItem(t);if(n)return On(n)}}catch{}return"dark"}function Pa(){if(typeof window>"u")return null;const e=new URLSearchParams(window.location.search).get(go);if(e!==null){const t=Mn(e);return Ca(t),t}try{return Mn(localStorage.getItem(Gt))}catch{return null}}const La="masc.shell.rail_expanded",vo=100,Dn=5;function bo(){return typeof window>"u"?1440:window.innerWidth}function _o(){if(typeof window>"u")return!0;try{const e=localStorage.getItem(La);if(e==="0"||e==="false")return!1;if(e==="1"||e==="true")return!0}catch{}return window.innerWidth>=1024}const dn=C(bo()),pn=Z(()=>dn.value<768),yo=Z(()=>dn.value<=1440),Vt=C(_o()),Y=C(null),Ra=Z(()=>{const e=Y.value;return e?.kind==="inspect"&&e.epoch!==W.value?null:e}),Ue=C(!1),Oa=C(!1),X=C(!1),wo=Z(()=>pn.value||yo.value&&Ra.value!==null?!1:Vt.value);function Ma(){const e=!Vt.peek();Vt.value=e;try{typeof localStorage<"u"&&localStorage.setItem(La,e?"1":"0")}catch{}}function $o(e){Y.value={kind:"inspect",payload:e,epoch:H()}}function fn(){const e=Y.peek();Y.value=e?.kind==="queue_context"?null:{kind:"queue_context"}}function mn(){Y.peek()?.kind==="incidents"?Y.value=null:E(()=>{Po(),Y.value={kind:"incidents"}})}function $t(){Y.value=null}function hn(){E(()=>{Oa.value=!0,Ue.value=!0})}function So(){Ue.value=!1}function Eo(){Ue.peek()?So():hn()}function To(){if(typeof window>"u")return()=>{};const e=()=>{dn.value=window.innerWidth};return e(),window.addEventListener("resize",e,{passive:!0}),()=>window.removeEventListener("resize",e)}const Da=C(Ia()),xa=C(Pa());function Ao(e){Da.value=e,Ea(e),Aa(e)}function Ws(){const e=Da.peek()==="dark"?"light":"dark";return Ao(e),e}function Co(e){xa.value=e,Ta(e),Ca(e)}function Bs(){const e=xa.peek()==="high"?"normal":"high";return Co(e),e}let Io=0;const ae=C([]),qs=ae,Na=Z(()=>ae.value.filter(e=>!e.read&&!e.dismissed).length);function je(e){const t={id:`inc-${++Io}`,ts:Date.now(),severity:e.severity,source:e.source,summary:e.summary,detail:e.detail,read:Y.peek()?.kind==="incidents",dismissed:!1},n=[t,...ae.peek()].slice(0,vo);return ae.value=n,t}function Po(){const e=ae.peek();e.every(t=>t.read)||(ae.value=e.map(t=>t.read?t:{...t,read:!0}))}function Hs(e){ae.value=ae.peek().map(t=>t.id===e?{...t,dismissed:!0,read:!0}:t)}function Ks(){ae.value=ae.peek().filter(e=>!e.dismissed)}const Wa=C({version:null,serverCommit:null,bundleCommit:null,mismatched:!1,checkedAt:null});function ie(e){return typeof e=="object"&&e!==null&&!Array.isArray(e)}function ye(e){return typeof e=="string"&&e.trim().length>0?e.trim():null}async function Ft(e=globalThis.fetch,t={}){const n=H();let a=null,o=null,s=null;const i=l=>ie(l)?{version:ye(l.version),serverCommit:ye(l.source_commit)??ye(l.commit)??ye(l.build_commit),bundleCommit:ye(l.dashboard_commit)??ye(l.bundle_commit)}:{version:null,serverCommit:null,bundleCommit:null},r=!t.force&&e===globalThis.fetch?vr(n):null;if(r!==null){const l=i(r);a=l.version,o=l.serverCommit,s=l.bundleCommit}else try{const l=await e("/health",{method:"GET",credentials:"same-origin",headers:{Accept:"application/json"}});if(l.ok){const c=l.headers.get("content-type")??"";if(c===""||c.includes("application/json")){const p=i(await l.json());a=p.version,o=p.serverCommit,s=p.bundleCommit}}}catch{}if(!P(n))return;const f=!!(o&&s&&!o.startsWith(s)&&!s.startsWith(o));Wa.value={version:a,serverCommit:o,bundleCommit:s,mismatched:f,checkedAt:Date.now()}}const ke=C([]),Ae=C([]),Ce=C([]),Ie=C([]),Ge=C([]),St=C(!1),Ye={approvals:{kind:"unread"},asks:{kind:"unread"},gate:{kind:"unread"},planning:{kind:"unread"},verification:{kind:"unread"}},Q=C(Ye),Lo=Z(()=>{const e=Q.value;return v.value.kind==="multi_account_signed_in"?{approvals:{kind:"unbridged",reason:"multi_account_unbridged"},asks:{kind:"unbridged",reason:"multi_account_unbridged"},gate:{kind:"unbridged",reason:"multi_account_unbridged"},planning:e.planning,verification:{kind:"unbridged",reason:"multi_account_unbridged"}}:e}),Ro={approvals:"도구 승인",asks:"Keeper 질문",gate:"Channel Gate",planning:"Goal 확인",verification:"검증 대기"},Oo=Z(()=>{const e=Lo.value,t=[];for(const n of["approvals","asks","gate","planning","verification"]){const a=e[n];a.kind!=="ok"&&t.push({key:n,label:Ro[n],state:a})}return t}),mt=Z(()=>Oo.value.filter(e=>e.key!=="verification"));function Gs(e){switch(e.kind){case"unread":return"조회 대기";case"unbridged":return"멀티 계정 미지원";case"failed":return"조회 실패";case"partial":return"일부만 확인";case"recovered":return"복구본 · 읽기 전용"}}function kn(e,t){return t?e>0?`${e}건 표시 · 일부 미확인`:"일부 미확인":String(e)}function gn(e,t){return e>0?t?`${e}?`:String(e):t?"?":null}const Mo=15e3,ht=Z(()=>ke.value.length+Ae.value.length+Ce.value.length+Ie.value.length),Do=Z(()=>ht.value>0||G(v.value)&&mt.value.length>0);let Et=0,rt=null;const Ba=new Map;let et=null;function xo(){return et||(et=F(()=>import("./hitl-parsers.js"),__vite__mapDeps([50,8,51])).catch(e=>{throw et=null,e})),et}async function No(){try{return{ok:!0,parsers:await xo()}}catch(e){return{ok:!1,message:e instanceof Error&&e.message?e.message:"HITL 파서 모듈을 불러오지 못했습니다"}}}async function ot(e,t){rt?.abort();const n=++Et,a=v.peek();if(!G(a)){rt=null,E(()=>{St.value=!1,ke.value=[],Ae.value=[],Ce.value=[],Ie.value=[],Ge.value=[],Q.value=Ye});return}const o=a.kind,s=new AbortController;rt=s;const i=H(),r=x.peek(),f={fetchImpl:e,signal:s.signal,timeoutMs:Mo},l=()=>n===Et&&P(i),c=(d,g)=>{Q.value={...Q.peek(),[d]:g}},p=Ba,u=(d,g,S)=>{const y=`${g}|${S}`;p.get(d)!==y&&(p.set(d,y),je({severity:"warn",source:d,summary:g,detail:S}))},_=d=>{p.delete(d)};St.value=!0;try{const d=No();if(o==="multi_account_signed_in"){E(()=>{ke.value=[],Ae.value=[],Ce.value=[],Ge.value=[],Q.value={approvals:{kind:"unbridged",reason:"multi_account_unbridged"},asks:{kind:"unbridged",reason:"multi_account_unbridged"},gate:{kind:"unbridged",reason:"multi_account_unbridged"},planning:Q.peek().planning.kind==="unbridged"?{kind:"unread"}:Q.peek().planning,verification:{kind:"unbridged",reason:"multi_account_unbridged"}}});const[h,k]=await Promise.all([_e("/api/v1/dashboard/planning",f),d]);if(!l())return;E(()=>{if(h.ok){if(!k.ok){c("planning",{kind:"failed",message:k.message}),u("planning","Goal confirmation decoder unavailable",k.message);return}if(!ie(h.value)||h.value.ok===!1||!Array.isArray(h.value.goals)){const w=ie(h.value)&&typeof h.value.error=="string"&&h.value.error.trim()?h.value.error.trim():"목표 확인 큐 응답 형식이 올바르지 않습니다";c("planning",{kind:"failed",message:w}),u("planning","Goal confirmation queue response invalid",w);return}_("planning"),Ie.value=k.parsers.parseAwaitingGoalsPayload(h.value,r),c("planning",{kind:"ok"})}else h.error.kind!=="epoch_stale"&&h.error.kind!=="aborted"&&(c("planning",{kind:"failed",message:h.error.message}),u("planning",`Goal confirmation queue unavailable (${h.error.status??h.error.kind})`,h.error.message))});return}const g=Q.peek();(g.approvals.kind==="unbridged"||g.asks.kind==="unbridged"||g.gate.kind==="unbridged"||g.verification.kind==="unbridged")&&(Q.value=Ye);const S=_e("/api/v1/keepers/tool-approvals",f).then(async h=>{if(!l())return;const k=h.ok?await d:null;l()&&E(()=>{if(h.ok&&k){if(!k.ok){c("approvals",{kind:"failed",message:k.message}),u("approvals","Tool approval decoder unavailable",k.message);return}const w=h.value;if(!(ie(w)&&w.ok!==!1&&Array.isArray(w.pending))){const L=ie(w)&&typeof w.error=="string"&&w.error.trim()?w.error.trim():"도구 승인 큐 응답 형식이 올바르지 않습니다";c("approvals",{kind:"failed",message:L}),u("approvals","Tool approval queue response invalid",L);return}_("approvals"),ke.value=k.parsers.parseToolApprovalsPayload(w,r),c("approvals",{kind:"ok"})}else!h.ok&&h.error.kind!=="epoch_stale"&&h.error.kind!=="aborted"&&(c("approvals",{kind:"failed",message:h.error.message}),u("approvals",`Tool approval queue unavailable (${h.error.status??h.error.kind})`,h.error.message))})}),y=_e("/api/v1/keepers/asks?include_resolved=false",f).then(async h=>{if(!l())return;const k=h.ok?await d:null;l()&&E(()=>{if(h.ok&&k){if(!k.ok){c("asks",{kind:"failed",message:k.message}),u("asks","Keeper asks decoder unavailable",k.message);return}const w=k.parsers.decodeKeeperAsksWire(h.value);if(!w.ok){c("asks",{kind:"failed",message:w.error}),u("asks","Keeper asks queue response invalid",w.error);return}_("asks"),Ae.value=w.asks.map(T=>({askId:T.askId,keeper:T.keeper,prompt:T.promptSummary??"Keeper awaiting operator answer",askedAt:T.askedAt,workspaceId:r,revision:T.revision})),c("asks",{kind:"ok"})}else!h.ok&&h.error.kind!=="epoch_stale"&&h.error.kind!=="aborted"&&(c("asks",{kind:"failed",message:h.error.message}),u("asks",`Keeper asks queue unavailable (${h.error.status??h.error.kind})`,h.error.message))})}),A=_e("/api/v1/dashboard/gate",f).then(async h=>{if(!l())return;const k=h.ok?await d:null;l()&&E(()=>{if(h.ok&&k){if(!k.ok){c("gate",{kind:"failed",message:k.message}),u("gate","Channel gate decoder unavailable",k.message);return}const w=k.parsers.decodeGateQueueStrict(h.value);if(!w.ok){c("gate",{kind:"failed",message:w.error}),u("gate",w.unavailable?"Channel gate approval queue unavailable":"Channel gate queue response invalid",w.error);return}_("gate"),c("gate",{kind:"ok"}),Ce.value=w.rows.map(T=>({id:T.id,keeper:T.keeper,toolName:T.toolName,phase:T.phase??"unknown",waitingSec:T.waitingSec,workspaceId:r}))}else!h.ok&&h.error.kind!=="epoch_stale"&&h.error.kind!=="aborted"&&(c("gate",{kind:"failed",message:h.error.message}),u("gate",`Channel gate queue unavailable (${h.error.status??h.error.kind})`,h.error.message))})}),m=_e("/api/v1/dashboard/planning",f).then(async h=>{if(!l())return;const k=h.ok?await d:null;l()&&E(()=>{if(h.ok&&k){if(!k.ok){c("planning",{kind:"failed",message:k.message}),u("planning","Goal confirmation decoder unavailable",k.message);return}const w=h.value;if(!ie(w)||w.ok===!1||!Array.isArray(w.goals)){const T=ie(w)&&typeof w.error=="string"&&w.error.trim()?w.error.trim():"목표 확인 큐 응답 형식이 올바르지 않습니다";c("planning",{kind:"failed",message:T}),u("planning","Goal confirmation queue response invalid",T);return}_("planning"),Ie.value=k.parsers.parseAwaitingGoalsPayload(w,r),c("planning",{kind:"ok"})}else!h.ok&&h.error.kind!=="epoch_stale"&&h.error.kind!=="aborted"&&(c("planning",{kind:"failed",message:h.error.message}),u("planning",`Goal confirmation queue unavailable (${h.error.status??h.error.kind})`,h.error.message))})}),$=_e("/api/v1/verification/requests?view=awaiting",f).then(async h=>{if(!l())return;const k=h.ok?await d:null;l()&&E(()=>{if(h.ok&&k){if(!k.ok){c("verification",{kind:"failed",message:k.message}),u("verification","Verification decoder unavailable",k.message);return}const w=h.value;if(!ie(w)||!Array.isArray(w.requests)&&!Array.isArray(w.items)){const R="응답에 검증 목록이 없습니다";c("verification",{kind:"failed",message:R}),u("verification","Verification queue response invalid",R);return}const T=k.parsers.decodeVerificationCoverage(w),L=[];if(T.unresolvedTotal!==null&&T.unresolvedTotal>0&&L.push(`대기 기록 누락 ${T.unresolvedTotal}건`),T.unreadableTotal!==null&&T.unreadableTotal>0&&L.push(`읽기 불가 ${T.unreadableTotal}건`),T.truncated&&L.push("일부 항목만 표시"),T.backlogError){const R=[T.backlogError,...L].join(" · ");c("verification",{kind:"failed",message:R}),u("verification","Verification backlog read error",R);return}if(Ge.value=k.parsers.parsePendingVerificationsPayload(w,r),T.backlogRecovery){const R=[T.backlogRecovery,...L].join(" · ");c("verification",{kind:"recovered",message:R}),u("verification","Verification backlog recovered",R)}else if(L.length>0){const R=L.join(" · ");c("verification",{kind:"partial",message:R}),u("verification","Verification backlog partially observed",R)}else _("verification"),c("verification",{kind:"ok"})}else!h.ok&&h.error.kind!=="epoch_stale"&&h.error.kind!=="aborted"&&(c("verification",{kind:"failed",message:h.error.message}),u("verification",`Verification queue unavailable (${h.error.status??h.error.kind})`,h.error.message))})});await Promise.all([S,y,A,m,$])}finally{n===Et&&P(i)&&(St.value=!1)}}async function Vs(e,t,n){const a=v.peek();if(a.kind!=="single_user_local"||!fr(a))return{ok:!1,message:"도구 승인 결정은 싱글유저 관리자 세션에서만 실행할 수 있습니다."};const o=H(),s=await $a("POST","/api/v1/keepers/tool-approval",{name:e.keeper,tool_call_id:e.toolCallId,approval_id:e.approvalId,decision:t},{fetchImpl:n});if(!P(o))return{ok:!1,message:"세션 또는 워크스페이스가 변경되어 요청이 취소되었습니다."};if(!s.ok)return je({severity:"error",source:"approvals",summary:`${t==="approve"?"승인":"거절"} 실패 (${e.keeper}/${e.tool||e.approvalId})`,detail:s.error.message}),{ok:!1,message:s.error.message};const i=ie(s.value)?s.value:null,r=i?.settled===!0,f=i?.remembered===!0;if(!r&&!f){const l="결정 접수를 확인하지 못했습니다.";return je({severity:"error",source:"approvals",summary:`${t==="approve"?"승인":"거절"} 미확인 (${e.keeper}/${e.tool||e.approvalId})`,detail:l}),{ok:!1,message:l}}return E(()=>{ke.value=ke.peek().filter(l=>l.approvalId!==e.approvalId),on.invalidateTopic("tool_approval"),ee(r?`${e.keeper} · ${e.tool||e.approvalId} ${t==="approve"?"승인 완료":"거절 완료"}`:`${e.keeper} · ${e.tool||e.approvalId} · 같은 호출 재시도 시 적용할 결정으로 저장했습니다.`,t==="approve"?"success":"warning")}),{ok:!0,message:"ok"}}let Wo=0;const Ze=C([]),Me=new Map,Bo=Ze;function qa(e){const t=Me.get(e);t&&(t.timerId!==null&&clearTimeout(t.timerId),Me.delete(e))}function Ha(e,t){const n=Me.get(e);n&&n.timerId!==null&&clearTimeout(n.timerId);const a=n?n.pauseReasons:new Set,o=setTimeout(()=>vn(e),t);Me.set(e,{remainingMs:t,startedAt:Date.now(),timerId:o,pauseReasons:a})}function xn(e,t="focus"){const n=Me.get(e);if(!n)return;const a=n.pauseReasons.size>0;if(n.pauseReasons.add(t),a)return;n.timerId!==null&&(clearTimeout(n.timerId),n.timerId=null);const o=Math.max(0,Date.now()-n.startedAt);n.remainingMs=Math.max(0,n.remainingMs-o),n.startedAt=0}function Nn(e,t="focus"){const n=Me.get(e);if(n&&(n.pauseReasons.delete(t),!(n.pauseReasons.size>0||n.timerId!==null))){if(n.remainingMs<=0){vn(e);return}Ha(e,n.remainingMs)}}function ee(e,t="info",n=4e3){const a=++Wo,o=[...Ze.peek(),{id:a,message:e,tone:t}],s=Math.max(0,o.length-Dn);for(let i=0;i<s;i+=1)qa(o[i].id);return Ze.value=o.slice(-Dn),n>0&&Ha(a,n),a}function vn(e){qa(e),Ze.value=Ze.peek().filter(t=>t.id!==e)}function qo(e){const t=Hr(l=>{je({severity:"warn",source:"observer",summary:`Observer stream gap: ${l}`,detail:"Live event sequence gap detected; snapshot resync recommended."})}),n=new Set(["approval","approvals","approval:pending","tool_approval","tool_approvals","ask","asks","keeper_ask","keeper_asks","gate","gate_approval","goal","goals","goal_projection_changed","planning","verification","verification_requests","pending_confirms_changed"]);let a=null;const o=qr(l=>{da(l).some(p=>n.has(p))&&(a||(a=setTimeout(()=>{a=null,ot(e)},350)))});let s=W.peek();const i=W.subscribe(l=>{l!==s&&(s=l,a&&(clearTimeout(a),a=null),rt?.abort(),Ba.clear(),E(()=>{const c=Y.peek();c?.kind==="inspect"&&c.epoch!==l&&(Y.value=null),ke.value=[],Ae.value=[],Ce.value=[],Ie.value=[],Ge.value=[],Q.value=Ye}),G(v.peek())&&ot(e))}),r=v.subscribe(l=>{E(()=>{mr(l)||(ke.value=[],Ae.value=[],Ce.value=[],Ge.value=[]),G(l)||(Ie.value=[],Q.value=Ye)})}),f=Kr(()=>{G(v.peek())&&ot(e)});return()=>{t(),o(),f(),i(),r(),a&&(clearTimeout(a),a=null)}}const Ho=["pulse","work","keepers","runtime"],Wn=["knowledge","infra","settings","account"];function Ko(){const e=Ne.value,t=v.value,n=X.value,a=ht.value,o=G(t)&&mt.value.length>0,s=gn(a,o),i=o?`Inbox ${kn(a,!0)}`:`Inbox ${a}건 대기 중`,r=Na.value,f=U(null);io({containerRef:f,active:n}),le(()=>{if(!n)return;const c=p=>{if(!(p.defaultPrevented||p.isComposing||p.keyCode===229)&&p.key==="Escape"){if(typeof document<"u"&&Array.from(document.querySelectorAll('[role="dialog"][aria-modal="true"]')).some(_=>_!==f.current))return;p.preventDefault(),p.stopPropagation(),X.value=!1}};return window.addEventListener("keydown",c),()=>window.removeEventListener("keydown",c)},[n]);const l=Wn.includes(e.workspace);return b`
    ${n&&b`
      <div
        class="ap-sheet-backdrop"
        aria-hidden="true"
        onClick=${()=>{X.value=!1}}
      />
      <div
        ref=${f}
        class="ap-more-sheet"
        role="dialog"
        aria-modal="true"
        aria-label="더 보기 메뉴"
        data-testid="mobile-more-sheet"
      >
        <div class="ap-more-head">
          <strong>More</strong>
          <button
            type="button"
            class="btn-ghost ap-touch-target"
            aria-label="닫기"
            onClick=${()=>{X.value=!1}}
          >
            <${D} name="x" size=${16} />
          </button>
        </div>

        <div class="ap-more-grid">
          ${Wn.map(c=>{const p=pe[c],u=Re(p.access,t),_=e.workspace===c;return b`
              <button
                key=${c}
                type="button"
                class=${`ap-more-item ap-touch-target${_?" is-active":""}${u?" is-locked":""}`}
                data-rbac-locked=${u?"true":void 0}
                onClick=${()=>{X.value=!1,N(p.defaultPath)}}
              >
                <${D} name=${c} size=${16} />
                <span>${p.label}</span>
                ${u&&b`<${D} name="lock" size=${12} />`}
              </button>
            `})}
        </div>

        <div class="ap-more-tools">
          <button
            type="button"
            class="ap-more-item ap-touch-target"
            onClick=${()=>{X.value=!1,fn()}}
          >
            <${D} name="layers" size=${16} />
            <span>Queue & Context</span>
          </button>
          <button
            type="button"
            class="ap-more-item ap-touch-target"
            onClick=${()=>{X.value=!1,mn()}}
          >
            <${D} name="bell" size=${16} />
            <span>Incidents ${r>0?b`(<span class="tnum">${r}</span>)`:""}</span>
          </button>
          <button
            type="button"
            class="ap-more-item ap-touch-target"
            onClick=${()=>{X.value=!1,hn()}}
          >
            <${D} name="search" size=${16} />
            <span>Command Palette</span>
          </button>
        </div>
      </div>
    `}

    <nav class="ap-mobile-bar" aria-label="모바일 탐색" data-testid="mobile-nav-bar">
      ${Ho.map(c=>{const p=pe[c],u=e.workspace===c,_=c==="work"?s:null;return b`
          <a
            key=${c}
            href=${`#${p.defaultPath}`}
            class=${`ap-mobile-tab ap-touch-target${u?" is-active":""}`}
            aria-current=${u?"page":void 0}
            aria-label=${_!==null?`${p.label} (${i})`:void 0}
            data-mobile-nav-id=${c}
            onClick=${d=>{d.defaultPrevented||d.button!==0||d.metaKey||d.ctrlKey||d.shiftKey||d.altKey||(d.preventDefault(),X.value=!1,N(p.defaultPath))}}
          >
            <${D} name=${c} size=${18} />
            <span>${p.shortLabel}</span>
            ${_!==null&&b`
              <span class="ap-mobile-badge tnum" aria-hidden="true" title=${i}>${_}</span>
            `}
          </a>
        `})}
      <button
        type="button"
        class=${`ap-mobile-tab ap-touch-target${n||l?" is-active":""}`}
        aria-expanded=${n?"true":"false"}
        aria-label=${r>0?`더 보기 (읽지 않은 장애 ${r}건)`:"더 보기"}
        data-testid="mobile-more-trigger"
        onClick=${()=>{X.value=!n}}
      >
        <${D} name="more" size=${18} />
        <span>More</span>
        ${r>0&&b`<span class="ap-mobile-badge tnum" aria-hidden="true">${r}</span>`}
      </button>
    </nav>
  `}function Bn(e,t,n,a,o,s){const i=t===e.id,r=e.id==="work"?a:null,f=s?`${e.label} (관리자 전용)`:e.shortcut?`${e.label} [${e.shortcut}]`:e.label,l=!s&&r!==null&&o?`${f} · ${o}`:f;return b`
    <a
      key=${e.id}
      href=${`#${e.defaultPath}`}
      class=${`ap-rail-item${i?" is-active":""}${s?" is-locked":""}`}
      aria-current=${i?"page":void 0}
      aria-label=${l}
      title=${l}
      data-nav-id=${e.id}
      data-rbac-locked=${s?"true":void 0}
      onPointerEnter=${()=>{!s&&G(v.peek())&&Wt(e.id)}}
      onFocus=${()=>{!s&&G(v.peek())&&Wt(e.id)}}
      onClick=${c=>{c.defaultPrevented||c.button!==0||c.metaKey||c.ctrlKey||c.shiftKey||c.altKey||(c.preventDefault(),N(e.defaultPath))}}
    >
      <span class="ap-rail-icon">
        <${D} name=${e.id} size=${16} />
      </span>
      ${n&&b`
        <span class="ap-rail-label">${e.label}</span>
      `}
      ${s&&b`
        <span class="ap-rail-lock" aria-label="관리자 전용" title="관리자 전용">
          <${D} name="lock" size=${12} />
        </span>
      `}
      ${!s&&r!==null&&b`
        <span
          class="ap-rail-badge tnum"
          aria-label=${o??void 0}
          title=${o??void 0}
        >${r}</span>
      `}
      ${n&&!s&&r===null&&e.shortcut&&b`
        <kbd class="ap-rail-kbd">${e.shortcut}</kbd>
      `}
    </a>
  `}function Go(){const e=wo.value,t=Ne.value,n=v.value,a=ht.value,o=G(n)&&mt.value.length>0,s=gn(a,o),i=o?`Inbox ${kn(a,!0)}`:`Inbox ${a}건 대기 중`;return b`
    <nav
      class="ap-rail"
      aria-label="주 탐색"
      data-expanded=${e?"true":"false"}
    >
      <div class="ap-rail-brand">
        <a
          href="#/pulse"
          class="ap-brand-link"
          aria-label="MASC 홈 (Pulse)"
          onClick=${r=>{r.defaultPrevented||r.button!==0||r.metaKey||r.ctrlKey||r.shiftKey||r.altKey||(r.preventDefault(),N("/pulse"))}}
        >
          <span class="ap-brand-mark" aria-hidden="true">M</span>
          ${e&&b`<span class="ap-brand-name">MASC</span>`}
        </a>
        <button
          type="button"
          class="ap-rail-toggle"
          aria-label=${e?"사이드바 접기 [b]":"사이드바 펼치기 [b]"}
          aria-expanded=${e?"true":"false"}
          title=${e?"사이드바 접기 [b]":"사이드바 펼치기 [b]"}
          onClick=${Ma}
        >
          <${D} name="sidebar" size=${15} />
        </button>
      </div>

      <div class="ap-rail-trunks" role="group" aria-label="워크스페이스">
        ${ka.map(r=>Bn(r,t.workspace,e,s,i,Re(r.access,n)))}
      </div>

      <div class="ap-rail-footer" role="group" aria-label="시스템">
        ${Yr.map(r=>Bn(r,t.workspace,e,null,null,Re(r.access,n)))}
      </div>
    </nav>
  `}const Ka="win",qn=["24h","7d","30d"],Vo="masc-telemetry";function Fo(e){return e==="7d"||e==="30d"||e==="24h"?e:"24h"}function zo(){if(typeof window>"u")return"24h";const e=new URLSearchParams(window.location.search);return Fo(e.get(Ka))}const zt=C(zo()),Uo=zt;function Hn(e){if(zt.peek()!==e&&(zt.value=e,typeof window<"u"&&typeof window.history?.replaceState=="function")){const t=new URL(window.location.href);t.searchParams.set(Ka,e),window.history.replaceState(null,"",`${t.pathname}${t.search}${t.hash}`)}}function Fs(e){switch(e){case"24h":return 1;case"7d":return 7;case"30d":return 14}}const Kn=C({timestamp:null,sourceId:null});function zs(e,t){const n=Kn.peek();n.timestamp===e&&n.sourceId===t||(Kn.value={timestamp:e,sourceId:t})}let Tt=null;function Us(e){return Tt||(Tt=e.sync(Vo)),Tt}const jo=['[role="menuitem"]:not([disabled]):not([aria-disabled="true"])','[role="menuitemradio"]:not([disabled]):not([aria-disabled="true"])','[role="menuitemcheckbox"]:not([disabled]):not([aria-disabled="true"])','.pm-item:not([disabled]):not([aria-disabled="true"])'].join(", ");function tt(e){return e?Array.from(e.querySelectorAll(jo)):[]}function Yo(e){const[t,n]=ce(e.defaultOpen??!1),a=e.open!==void 0,o=a?e.open:t,s=U(null),i=U(null),r=U(null),f=U(null),l=U(e.onOpenChange);l.current=e.onOpenChange;const c=Ga(),p=e.role??"menu",u=e.align??"left",_=e.closeOnSelect??!0,d=m=>{a||n(m),l.current?.(m)},g=()=>{d(!1),i.current?.focus?.()};le(()=>{if(!o)return;const m=f.current;f.current=null,m&&queueMicrotask(()=>{const k=tt(r.current);if(k.length===0)return;(m==="last"?k[k.length-1]:k[0])?.focus?.()});const $=k=>{s.current&&!s.current.contains(k.target)&&d(!1)},h=k=>{if(!(k.defaultPrevented||Te(k))&&k.key==="Escape"){const w=typeof document<"u"?document.querySelector('[role="dialog"][aria-modal="true"]'):null;if(w&&(!s.current||!w.contains(s.current)))return;k.preventDefault(),k.stopPropagation(),k.stopImmediatePropagation(),g()}};return document.addEventListener("mousedown",$),document.addEventListener("keydown",h,!0),()=>{document.removeEventListener("mousedown",$),document.removeEventListener("keydown",h,!0)}},[o]);const S=m=>{if(!(m.defaultPrevented||Te(m))){if(m.key==="ArrowDown"){m.preventDefault(),o?tt(r.current)[0]?.focus?.():(f.current="first",d(!0));return}if(m.key==="ArrowUp")if(m.preventDefault(),!o)f.current="last",d(!0);else{const $=tt(r.current);$[$.length-1]?.focus?.()}}},y=m=>{if(m.defaultPrevented||Te(m))return;if(m.key==="Escape"){m.preventDefault(),m.stopPropagation(),m.stopImmediatePropagation(),g();return}if(m.key==="Tab"){if(p!=="dialog")d(!1);else{const T=r.current?Array.from(r.current.querySelectorAll('a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])')):[],L=typeof document<"u"?document.activeElement:null,R=L instanceof HTMLElement?T.indexOf(L):-1,re=m.shiftKey&&(R<=0||T.length===0),V=!m.shiftKey&&(R<0||R>=T.length-1);(re||V)&&d(!1)}return}if(m.key!=="ArrowDown"&&m.key!=="ArrowUp"&&m.key!=="Home"&&m.key!=="End")return;const $=tt(r.current);if($.length===0)return;const h=typeof document<"u"?document.activeElement:null,k=h instanceof HTMLElement?$.indexOf(h):-1;if(m.preventDefault(),m.key==="Home"){$[0]?.focus?.();return}if(m.key==="End"){$[$.length-1]?.focus?.();return}if(m.key==="ArrowDown"){const T=k<0?0:(k+1)%$.length;$[T]?.focus?.();return}const w=k<=0?$.length-1:k-1;$[w]?.focus?.()},A=typeof e.children=="function"?e.children({close:g}):e.children;return b`
    <div class="pm-wrap" ref=${s}>
      <button
        ref=${i}
        type="button"
        class=${`pm-trigger ${e.triggerClassName??"btn-ghost"}`.trim()}
        aria-haspopup=${p==="dialog"?"dialog":"menu"}
        aria-expanded=${o?"true":"false"}
        aria-controls=${o?c:void 0}
        aria-label=${e.ariaLabel}
        title=${e.triggerTitle??e.ariaLabel}
        data-testid=${e.triggerTestId}
        onClick=${()=>d(!o)}
        onKeyDown=${S}
      >
        ${e.triggerLabel}
        ${e.triggerIcon}
      </button>

      ${o&&b`
        <div
          ref=${r}
          id=${c}
          class=${`pm-popover ${e.popoverClassName??""}`.trim()}
          role=${p}
          aria-label=${e.ariaLabel}
          data-align=${u}
          data-testid=${e.popoverTestId}
          onKeyDown=${y}
        >
          ${e.items?.map(m=>{const $=m.active!==void 0;return b`
              <${Fn} key=${m.id}>
                ${m.separatorBefore&&b`<div class="pm-sep" role="separator" />`}
                <button
                  type="button"
                  role=${$?"menuitemradio":"menuitem"}
                  class=${`pm-item${m.active?" is-active":""}${m.danger?" is-danger":""}`}
                  disabled=${m.disabled}
                  aria-checked=${$?m.active?"true":"false":void 0}
                  data-active=${m.active?"true":void 0}
                  data-testid=${m.testId}
                  onClick=${()=>{m.disabled||(m.onSelect(),_&&(d(!1),typeof document<"u"&&(document.activeElement===null||document.activeElement===document.body||s.current?.contains(document.activeElement))&&i.current?.focus?.()))}}
                >
                  <span class="pm-item-main">
                    ${m.icon}
                    <span class="pm-item-text">
                      <span class="pm-item-label">${m.label}</span>
                      ${m.description&&b`<span class="pm-item-desc">${m.description}</span>`}
                    </span>
                  </span>
                  ${m.shortcut&&b`<kbd class="ap-kbd">${m.shortcut}</kbd>`}
                </button>
              <//>
            `})}
          ${A}
        </div>
      `}
    </div>
  `}function Zo(e){switch(e.kind){case"probing":return{avatar:"…",name:"Checking session",roleBadge:null};case"single_user_local":return{avatar:"OP",name:"Local Operator",roleBadge:e.role==="worker"?"Worker":e.role==="player"?"Player":e.tokenPresent?"Bearer":"Local"};case"single_user_auth_required":return{avatar:"!",name:"Auth Required",roleBadge:"Token"};case"multi_account_signed_out":return{avatar:"?",name:"Sign In",roleBadge:"Multi"};case"multi_account_signed_in":{const t=e.displayName.trim()||e.accountId,n=t.replace(/[^a-zA-Z0-9]/g,"").slice(0,2).toUpperCase()||"AC",a=e.role==="admin"?"Admin":e.role==="worker"?"Worker":"Viewer";return{avatar:n,name:`@${t}`,roleBadge:a}}case"account_changed":return{avatar:"⇄",name:"Account Changed",roleBadge:"Reload"};case"unavailable":return{avatar:"×",name:"Offline",roleBadge:null}}}function Qo(e,t,n){return e==="STREAM_GAP"?"STREAM_GAP":n==="SNAPSHOT"?"SNAPSHOT":n==="LIVE SSE"?t?"LIVE SSE":"SNAPSHOT":t?"SYNCED":"SNAPSHOT"}function Jo(e){switch(e){case"LIVE SSE":return{glyph:"●",tone:"live"};case"SYNCED":return{glyph:"◐",tone:"synced"};case"SNAPSHOT":return{glyph:"○",tone:"snapshot"};case"STREAM_GAP":return{glyph:"⚠",tone:"gap"}}}function Xo(){const[e,t]=ce(!1),[n,a]=ce(""),[o,s]=ce(null),[i,r]=ce(!1),[f,l]=ce(!1),c=U(null),p=U(null),u=v.value,_=nn.value,d=x.value,g=_.find(m=>m.id===d)??_[0],S=Zo(u);le(()=>{if(!e)return;const m=h=>{c.current&&!c.current.contains(h.target)&&t(!1)},$=h=>{if(!(h.defaultPrevented||h.isComposing||h.keyCode===229)&&h.key==="Escape"){if(typeof document<"u"&&document.querySelector('[role="dialog"][aria-modal="true"]'))return;h.preventDefault(),h.stopPropagation(),t(!1),p.current?.focus?.()}};return document.addEventListener("mousedown",m),document.addEventListener("keydown",$),()=>{document.removeEventListener("mousedown",m),document.removeEventListener("keydown",$)}},[e]);const y=async()=>{if(!f){l(!0);try{const m=await $a("POST","/auth/logout");!m.ok&&m.error.kind!=="unauthorized"?ee(`로그아웃 실패: ${m.error.message}`,"error"):(ee("로그아웃되었습니다.","info"),await Se(),t(!1),N("/account"))}finally{l(!1)}}},A=async m=>{if(m.preventDefault(),i)return;const $=n.trim();if(s(null),!$){yn(null),a(""),ee("Bearer 토큰이 제거되었습니다.","info"),Se().then(()=>ne()),t(!1);return}r(!0);try{const h=await wr($);if(!h.ok){s(h.error),ee(h.error,"error");return}a(""),s(null),ee("Bearer 토큰이 적용되었습니다.","success"),ne(),t(!1)}finally{r(!1)}};return b`
    <div class="ap-switcher-wrap" ref=${c}>
      <button
        ref=${p}
        type="button"
        class="ap-switcher-trigger"
        aria-haspopup="menu"
        aria-expanded=${e?"true":"false"}
        aria-label="계정 및 워크스페이스 전환"
        title=${`${S.name} / ${g?.label??d}`}
        data-testid="account-workspace-switcher"
        onClick=${()=>t(m=>!m)}
      >
        <span class="ap-switcher-avatar" aria-hidden="true">${S.avatar}</span>
        <span class="ap-switcher-principal">${S.name}</span>
        ${S.roleBadge&&b`
          <span class="ap-switcher-role">${S.roleBadge}</span>
        `}
        <span class="ap-switcher-sep" aria-hidden="true">/</span>
        <span class="ap-switcher-ws">${g?.label??d}</span>
        <${D} name="chevron" size=${13} />
      </button>

      ${e&&b`
        <div class="ap-popover ap-switcher-menu" role="menu" aria-label="계정 및 워크스페이스">
          <div class="ap-popover-section">
            <div class="ap-popover-eyebrow">OPERATOR IDENTITY</div>
            ${u.kind==="multi_account_signed_in"&&b`
              <div class="ap-switcher-identity-row">
                <div>
                  <div class="ap-switcher-id-name">${u.displayName}</div>
                  <div class="ap-switcher-id-sub mono">${u.accountId} · ${u.role}</div>
                </div>
                <button
                  type="button"
                  class="btn-ghost"
                  disabled=${f}
                  onClick=${()=>{y()}}
                >
                  ${f?"Signing out…":"Sign out"}
                </button>
              </div>
              <div class="ap-popover-links">
                <button
                  type="button"
                  class="ap-popover-item"
                  role="menuitem"
                  onClick=${()=>{t(!1),N("/account/profile")}}
                >
                  Profile & Sessions
                </button>
                <button
                  type="button"
                  class="ap-popover-item"
                  role="menuitem"
                  onClick=${()=>{t(!1),N("/account/pats")}}
                >
                  Personal Access Tokens (PATs)
                </button>
              </div>
            `}

            ${u.kind==="multi_account_signed_out"&&(u.authMethods.google||u.authMethods.github)&&b`
              <div class="ap-switcher-oauth">
                <a href="/" class="btn-primary ap-w-full" data-testid="switcher-signin-link">
                  Sign In (${[u.authMethods.google?"Google":"",u.authMethods.github?"GitHub":""].filter(Boolean).join(" / ")})
                </a>
              </div>
            `}

            ${(u.kind==="single_user_local"||u.kind==="single_user_auth_required")&&b`
              <form class="ap-switcher-bearer" onSubmit=${A}>
                <label class="ap-switcher-label" for="ap-quick-bearer">
                  Local Operator Bearer Token
                </label>
                <div class="ap-switcher-bearer-row">
                  <input
                    id="ap-quick-bearer"
                    type="password"
                    class="ap-input"
                    placeholder=${u.kind==="single_user_local"&&u.tokenPresent?"Token active (enter to rotate)":"Paste Bearer token…"}
                    value=${n}
                    disabled=${i}
                    onInput=${m=>{a(m.currentTarget.value),o&&s(null)}}
                  />
                  <button type="submit" class="btn-primary" disabled=${i}>
                    ${i?"Verifying…":"Apply"}
                  </button>
                </div>
                ${o&&b`
                  <div class="ap-error" role="alert">${o}</div>
                `}
                ${u.kind==="single_user_local"&&u.tokenPresent&&b`
                  <button
                    type="button"
                    class="btn-ghost"
                    onClick=${()=>{yn(null),ee("Bearer 토큰이 해제되었습니다.","info"),t(!1)}}
                  >
                    Clear Token
                  </button>
                `}
              </form>
            `}

            ${u.kind==="account_changed"&&b`
              <div class="ap-switcher-notice">
                다른 탭에서 계정이 변경되었습니다.
                <button
                  type="button"
                  class="btn-primary"
                  onClick=${()=>{t(!1),Se().then(()=>ne())}}
                >
                  Reload Session
                </button>
              </div>
            `}
          </div>

          <div class="ap-popover-section">
            <div class="ap-popover-eyebrow">WORKSPACE TARGET</div>
            <div class="ap-popover-links">
              ${_.map(m=>{const $=m.id===d;return b`
                  <button
                    key=${m.id}
                    type="button"
                    role="menuitemradio"
                    aria-checked=${$?"true":"false"}
                    class=${`ap-popover-item${$?" is-selected":""}`}
                    data-workspace-target=${m.id}
                    onClick=${()=>{const h=ra(m.id);t(!1),h&&(ee(`워크스페이스 전환: ${m.label}`,"info"),ne())}}
                  >
                    <span>${m.label}</span>
                    <span class="mono ap-muted">${m.baseUrl??m.id}</span>
                  </button>
                `})}
            </div>
            <button
              type="button"
              class="ap-popover-item ap-popover-foot-action"
              onClick=${()=>{t(!1),N("/account")}}
            >
              ${u.kind==="multi_account_signed_out"?"Open Sign-In Gate →":"Manage Account & Workspaces →"}
            </button>
          </div>

          <div class="ap-popover-hint">
            Operator identity & workspace access — manage LLM Provider keys in Runtime → Quotas.
          </div>
        </div>
      `}
    </div>
  `}function es(){const[e,t]=ce(!1),n=U(null),a=U(null),o=Ne.value,s=Pr.value,i=Lr.value,r=Rr.value,f=v.value,l=Wa.value,c=W.value,p=Qo(s,i,o.defaultProvenance),u=Jo(p),_=ua(f);le(()=>{if(!e)return;const g=y=>{n.current&&!n.current.contains(y.target)&&t(!1)},S=y=>{if(!(y.defaultPrevented||y.isComposing||y.keyCode===229)&&y.key==="Escape"){if(typeof document<"u"&&document.querySelector('[role="dialog"][aria-modal="true"]'))return;y.preventDefault(),y.stopPropagation(),t(!1),a.current?.focus?.()}};return document.addEventListener("mousedown",g),document.addEventListener("keydown",S),()=>{document.removeEventListener("mousedown",g),document.removeEventListener("keydown",S)}},[e]);const d=`연결 상태: ${p}${l.mismatched?" (빌드 커밋 불일치)":""}`;return b`
    <div class="ap-prov-wrap" ref=${n}>
      <button
        ref=${a}
        type="button"
        class=${`ap-pill ap-pill--${u.tone}`}
        aria-haspopup="dialog"
        aria-expanded=${e?"true":"false"}
        aria-label=${d}
        title=${d}
        data-testid="provenance-pill"
        data-provenance=${p}
        onClick=${()=>{const g=!e;t(g),g&&Ft(void 0,{force:!0})}}
      >
        <span class=${`ap-prov-glyph${u.tone==="live"?" is-live":""}`} aria-hidden="true">
          ${u.glyph}
        </span>
        <span class="ap-prov-label">${p}</span>
        ${l.mismatched&&b`
          <span class="ap-prov-drift-dot" title="서버와 대시보드 빌드 커밋이 다릅니다" aria-hidden="true">•</span>
        `}
      </button>

      ${e&&b`
        <div class="ap-popover ap-prov-popover" role="dialog" aria-label="연결 및 빌드 상태">
          <div class="ap-popover-eyebrow">CONNECTION & PROVENANCE</div>
          <dl class="ap-kv-list mono">
            <div><dt>Provenance</dt><dd>${p}</dd></div>
            <div><dt>Observer</dt><dd>${_?.url??"idle"}</dd></div>
            <div><dt>Last-Event-ID</dt><dd>${r??"없음"}</dd></div>
            <div><dt>Session Epoch</dt><dd>${String(c)}</dd></div>
            <div><dt>Server Version</dt><dd>${l.version??"미보고"}</dd></div>
            <div><dt>Server Commit</dt><dd>${l.serverCommit?.slice(0,10)??"미보고"}</dd></div>
            <div><dt>Bundle Commit</dt><dd>${l.bundleCommit?.slice(0,10)??"미보고"}</dd></div>
          </dl>
          ${l.mismatched&&b`
            <div class="ap-prov-mismatch" role="status">
              서버 빌드 커밋과 대시보드 번들이 다릅니다. 새로고침하거나 번들을 다시 빌드하세요.
            </div>
          `}
          <div class="ap-prov-actions">
            <button
              type="button"
              class="btn-ghost"
              onClick=${()=>{ne(),Ft(void 0,{force:!0})}}
            >
              <${D} name="refresh" size=${13} />
              Reconnect SSE
            </button>
          </div>
        </div>
      `}
    </div>
  `}function ts(){const e=Ne.value,t=v.value,n=pe[e.workspace],a=pn.value,o=ht.value,s=G(t)&&mt.value.length>0,i=s?kn(o,!0):`${o}건 대기`,r=gn(o,s),f=r??"0",l=Na.value,c=Y.value,p=Uo.value,u=e.workspace==="keepers"&&e.entityId?ha.map(d=>({id:d,label:jr[d],path:`/keepers/${encodeURIComponent(e.entityId)}/${d}`,active:e.entityTab===d,locked:!1})):e.workspace==="account"&&t.kind!=="multi_account_signed_in"?[]:n.subtabs.map(d=>({id:d.id,label:d.label,path:d.path,active:e.subroute===d.id,locked:Re(d.access,t)})),_=d=>{const g=e.workspace==="work"&&d.id==="inbox"?r:null,S=d.locked?`${d.label} (관리자 전용)`:g!==null?`${d.label} (${i})`:void 0;return b`
      <a
        key=${d.id}
        href=${`#${d.path}`}
        class=${`ap-subtab${d.active?" is-active":""}${d.locked?" is-locked":""}`}
        aria-current=${d.active?"page":void 0}
        aria-label=${S}
        title=${S}
        data-subtab=${d.id}
        data-rbac-locked=${d.locked?"true":void 0}
        onPointerEnter=${()=>{!d.locked&&G(v.peek())&&Pn(e.workspace,d.id)}}
        onFocus=${()=>{!d.locked&&G(v.peek())&&Pn(e.workspace,d.id)}}
        onClick=${y=>{y.defaultPrevented||y.button!==0||y.metaKey||y.ctrlKey||y.shiftKey||y.altKey||(y.preventDefault(),N(d.path))}}
      >
        <span>${d.label}</span>
        ${g!==null&&b`
          <span
            class="ap-subtab-badge tnum"
            data-testid="subtab-inbox-badge"
            aria-hidden="true"
            title=${i}
          >${g}</span>
        `}
        ${d.locked&&b`<${D} name="lock" size=${11} />`}
      </a>
    `};return b`
    <${Fn}>
      <header class="ap-topbar" role="banner">
      <div class="ap-topbar-left">
        <${Xo} />
      </div>

      ${!a&&u.length>0&&b`
        <nav class="ap-subtabs" aria-label=${`${n.label} 하위 탭`}>
          ${u.map(_)}
        </nav>
      `}

      <div class="ap-topbar-right">
        ${e.supportsTimeWindow&&(a?b`
              <${Yo}
                triggerLabel=${b`<span class="tnum">${p}</span>`}
                triggerIcon=${b`<${D} name="chevron" size=${11} />`}
                triggerClassName="ap-pill ap-win-compact-trigger"
                triggerTestId="time-window-pill"
                popoverTestId="time-window-menu"
                align="right"
                ariaLabel=${`시간 창 선택 (${p})`}
                items=${qn.map(d=>({id:d,label:d,active:p===d,testId:`time-window-option-${d}`,onSelect:()=>Hn(d)}))}
              />
            `:b`
              <div class="ap-win-group" role="group" aria-label="시간 창 선택" data-testid="time-window-pill">
                ${qn.map(d=>b`
                  <button
                    key=${d}
                    type="button"
                    class=${`ap-win-btn tnum${p===d?" is-active":""}`}
                    aria-pressed=${p===d?"true":"false"}
                    onClick=${()=>Hn(d)}
                  >
                    ${d}
                  </button>
                `)}
              </div>
            `)}

        <button
          type="button"
          class="ap-pill"
          aria-label="명령 팔레트 열기 (⌘K)"
          title="명령 팔레트 열기 (⌘K)"
          data-testid="cmdk-trigger"
          onClick=${hn}
        >
          <${D} name="search" size=${13} />
          <kbd class="ap-kbd">⌘K</kbd>
        </button>

        <${es} />

        ${!a&&b`
          <button
            type="button"
            class=${`ap-pill${o>0||s?" ap-pill--warn":""}`}
            aria-label=${`Inbox (${i})`}
            title=${`Inbox (${i})`}
            data-testid="inbox-pill"
            onClick=${()=>N("/work/inbox")}
          >
            <${D} name="inbox" size=${13} />
            <span class="ap-pill-label">Inbox</span>
            <span class="ap-pill-count tnum" title=${i}>${f}</span>
          </button>

          <button
            type="button"
            class=${`ap-pill${c?.kind==="queue_context"?" is-active":""}`}
            aria-pressed=${c?.kind==="queue_context"?"true":"false"}
            aria-label="Queue & Context 빠른 보기 (⌘T)"
            title="Queue & Context 빠른 보기 (⌘T)"
            data-testid="queue-ctx-pill"
            onClick=${fn}
          >
            <${D} name="layers" size=${13} />
            <kbd class="ap-kbd">⌘T</kbd>
          </button>

          <button
            type="button"
            class=${`ap-pill${c?.kind==="incidents"?" is-active":""}${l>0?" ap-pill--err":""}`}
            aria-pressed=${c?.kind==="incidents"?"true":"false"}
            aria-label=${`Incidents 빠른 보기 [I] (읽지 않음 ${l}건)`}
            title=${`Incidents 빠른 보기 [I] (읽지 않음 ${l}건)`}
            data-testid="incidents-pill"
            onClick=${mn}
          >
            <${D} name="bell" size=${13} />
            <kbd class="ap-kbd">I</kbd>
            ${l>0&&b`<span class="ap-pill-count tnum">${l}</span>`}
          </button>
        `}
      </div>
    </header>
      ${a&&u.length>0&&b`
        <nav
          class="ap-mobile-subtabs"
          aria-label=${`${n.label} 하위 탭`}
          data-testid="mobile-subtabs"
        >
          ${u.map(_)}
        </nav>
      `}
    <//>
  `}const ns=De(async()=>({default:(await F(async()=>{const{FastApprovalStrip:e}=await import("./fast-approval-strip.js");return{FastApprovalStrip:e}},__vite__mapDeps([52,1,23]))).FastApprovalStrip})),as=De(async()=>({default:(await F(async()=>{const{CommandPalette:e}=await import("./command-palette.js");return{CommandPalette:e}},__vite__mapDeps([53,1,54,41]))).CommandPalette})),At=De(async()=>({default:(await F(async()=>{const{QuickPeekDrawer:e}=await import("./quick-peek-drawer.js");return{QuickPeekDrawer:e}},__vite__mapDeps([55,1]))).QuickPeekDrawer})),rs=De(async()=>({default:(await F(async()=>{const{QueueContextOverlayBody:e}=await import("./queue-context-overlay.js");return{QueueContextOverlayBody:e}},__vite__mapDeps([56,1,21,16,17,11,4,28]))).QueueContextOverlayBody})),os=De(async()=>({default:(await F(async()=>{const{IncidentsOverlayBody:e}=await import("./incidents-overlay.js");return{IncidentsOverlayBody:e}},__vite__mapDeps([57,1]))).IncidentsOverlayBody}));function ss(e,t){return e.defaultPrevented||Te(e)||e.altKey||e.shiftKey||e.key.toLowerCase()!=="k"?!1:e.metaKey&&!e.ctrlKey||e.ctrlKey&&!e.metaKey}class is extends Va{state={error:null};static getDerivedStateFromError(t){return{error:t}}componentDidUpdate(t){t.resetKey!==this.props.resetKey&&this.state.error!==null&&this.setState({error:null})}componentDidCatch(t){je({severity:"error",source:"workspace",summary:`Workspace render error (${this.props.resetKey})`,detail:t.message})}render(){if(this.state.error){const t=this.state.error instanceof ba||/dynamically imported module|Loading chunk/i.test(this.state.error.message);return b`
        <section class="ap-gate" role="alert">
          <div class="ap-card">
            <h1 class="ap-card-title">
              ${t?"대시보드가 새 버전으로 업데이트되었습니다":"화면을 표시하는 중 오류가 발생했습니다"}
            </h1>
            <p class="ap-muted mono">
              ${t?"이전 번들 청크가 교체되어 새로고침이 필요합니다. 아래 버튼을 눌러 최신 화면을 불러오세요.":this.state.error.message}
            </p>
            <div class="ap-placeholder-actions">
              <button type="button" class="btn-primary" onClick=${()=>{t?window.location.reload():this.setState({error:null})}}>
                ${t?"새로고침":"다시 시도"}
              </button>
              <button type="button" class="btn-ghost" onClick=${()=>N("/pulse")}>
                Pulse로 이동
              </button>
            </div>
          </div>
        </section>
      `}return this.props.children}}function ls(){return b`
    <a
      href="#main-content"
      class="sr-only"
      onClick=${e=>{const t=document.getElementById("main-content");t&&(e.preventDefault(),t.focus())}}
    >
      Skip to main content
    </a>
  `}function cs(){const e=Bo.value;return e.length===0?null:b`
    <div class="ap-toast-host" aria-live="polite" aria-atomic="true">
      ${e.map(t=>b`
        <div
          key=${t.id}
          role=${t.tone==="error"?"alert":"status"}
          class=${`ap-toast ap-toast--${t.tone}`}
          data-toast-id=${t.id}
          onMouseEnter=${()=>xn(t.id,"hover")}
          onMouseLeave=${()=>Nn(t.id,"hover")}
          onFocusIn=${()=>xn(t.id,"focus")}
          onFocusOut=${n=>{const a=n.currentTarget,o=n.relatedTarget;a&&o&&a.contains(o)||Nn(t.id,"focus")}}
        >
          <span>${t.message}</span>
          <button
            type="button"
            class="ap-toast-close"
            aria-label="닫기"
            onClick=${()=>vn(t.id)}
          >
            <${D} name="x" size=${13} />
          </button>
        </div>
      `)}
    </div>
  `}function us(){const e=Ne.value,t=v.value,n=eo(e.access,t);if(!n.allowed)return n.reason==="probing"?(e.access==="member"&&Wt(e.workspace),b`
        <section class="ap-gate" role="status" data-testid="route-gate-probing">
          <div class="ap-card">
            <p class="ap-muted">세션 및 권한을 확인하는 중…</p>
          </div>
        </section>
      `):n.reason==="role_restricted"?b`
        <section class="ap-gate" role="status" data-testid="route-gate-role-restricted">
          <div class="ap-card">
            <span class="ap-eyebrow">RBAC · ROLE RESTRICTED</span>
            <h1 class="ap-card-title">대시보드 접근 권한이 없습니다</h1>
            <p class="ap-muted">
              현재 역할은 <code class="mono">${e.path}</code> 조회 권한이 없습니다.
              권한 없는 API 요청은 전송하지 않습니다.
            </p>
            <div class="ap-placeholder-actions">
              <button type="button" class="btn-primary" onClick=${()=>N("/account")}>
                Account 확인
              </button>
            </div>
          </div>
        </section>
      `:n.reason==="admin_only"?b`
        <section class="ap-gate" role="status" data-testid="route-gate-admin-only">
          <div class="ap-card">
            <span class="ap-eyebrow">RBAC · ADMIN ONLY</span>
            <h1 class="ap-card-title">관리자 전용 경로입니다</h1>
            <p class="ap-muted">
              현재 계정은 <code class="mono">${e.path}</code> 접근 권한이 없습니다.
              권한 없는 API 요청은 전송하지 않습니다.
            </p>
            <div class="ap-placeholder-actions">
              <button type="button" class="btn-primary" onClick=${()=>N("/pulse")}>
                1 Pulse로 이동
              </button>
              <button type="button" class="btn-ghost" onClick=${()=>N("/account")}>
                Account 확인
              </button>
            </div>
          </div>
        </section>
      `:n.reason==="account_changed"?b`
        <section class="ap-gate" role="alert" data-testid="route-gate-account-changed">
          <div class="ap-card ap-inline-panel--err">
            <h1 class="ap-card-title">다른 탭에서 계정이 변경되었습니다</h1>
            <p class="ap-muted">세션을 다시 불러온 뒤 계속 진행하세요.</p>
            <div class="ap-placeholder-actions">
              <button
                type="button"
                class="btn-primary"
                onClick=${()=>{Se().then(()=>ne())}}
              >
                세션 다시 불러오기
              </button>
            </div>
          </div>
        </section>
      `:n.reason==="unavailable"?b`
        <section class="ap-gate" role="alert" data-testid="route-gate-unavailable">
          <div class="ap-card">
            <h1 class="ap-card-title">MASC 서버에 연결할 수 없습니다</h1>
            <p class="ap-muted">${t.kind==="unavailable"?t.reason:"서버 응답 없음"}</p>
            <div class="ap-placeholder-actions">
              <button
                type="button"
                class="btn-primary"
                onClick=${()=>{Se().then(()=>ne())}}
              >
                다시 연결
              </button>
              <button type="button" class="btn-ghost" onClick=${()=>N("/account")}>
                Account / Targets
              </button>
            </div>
          </div>
        </section>
      `:b`
      <section class="ap-gate" role="status" data-testid="route-gate-auth-required">
        <div class="ap-card">
          <span class="ap-eyebrow">AUTHENTICATION REQUIRED</span>
          <h1 class="ap-card-title">로그인이 필요합니다</h1>
          <p class="ap-muted">
            인증되지 않은 상태에서는 보호된 데이터를 요청하지 않습니다. Account 화면에서 로그인하거나 토큰을 설정하세요.
          </p>
          <div class="ap-placeholder-actions">
            <button type="button" class="btn-primary" onClick=${()=>N("/account")}>
              Account 로그인으로 이동
            </button>
          </div>
        </div>
      </section>
    `;const a=W.value,o=ao(e.workspace);return b`
    <${is} resetKey=${`${a}:${e.path}`}>
      <${$e} fallback=${b`<section class="ap-gate" role="status"><div class="ap-card"><p class="ap-muted">워크스페이스 불러오는 중…</p></div></section>`}>
        <${o}
          key=${a}
          subroute=${e.subroute}
          entityId=${e.entityId}
          entityTab=${e.entityTab}
          onNavigate=${s=>{N(s)}}
          onInspect=${$o}
        />
      <//>
    <//>
  `}function ds(){return Do.value?b`
    <${$e} fallback=${null}>
      <${ns} />
    <//>
  `:null}function ps(){const e=Ra.value;if(e===null)return null;if(e.kind==="queue_context")return b`
      <${$e} fallback=${null}>
        <${At}
          open=${!0}
          title="Queue & Context"
          subtitle="⌘T Read-Only Quick-Peek"
          onClose=${$t}
        >
          <${rs} />
        <//>
      <//>
    `;if(e.kind==="incidents")return b`
      <${$e} fallback=${null}>
        <${At}
          open=${!0}
          title="Historical Incidents (Ch3)"
          subtitle="[I] Read-Only · Isolated from Live SSOT"
          onClose=${$t}
        >
          <${os} />
        <//>
      <//>
    `;const{payload:t}=e;return b`
    <${$e} fallback=${null}>
      <${At}
        open=${!0}
        title=${t.title}
        subtitle=${t.subtitle}
        onClose=${$t}
      >
        ${t.render?t.render():b`<pre class="ap-inspect-json mono">${JSON.stringify(t.data??{},null,2)}</pre>`}
      <//>
    <//>
  `}function Gn(){return typeof document>"u"?!0:document.visibilityState==="hidden"?!1:typeof document.hasFocus=="function"?document.hasFocus():!0}function fs(){const e=pn.value,t=Ne.value,n=Oa.value,a=U(null),[o,s]=ce(Gn);return le(()=>{a.current&&(a.current.scrollTop=0)},[t.workspace,t.subroute]),le(()=>{if(typeof window>"u"||typeof document>"u")return;const i=()=>s(document.visibilityState!=="hidden"),r=()=>s(!1),f=()=>s(Gn());return window.addEventListener("focus",i),window.addEventListener("blur",r),document.addEventListener("visibilitychange",f),()=>{window.removeEventListener("focus",i),window.removeEventListener("blur",r),document.removeEventListener("visibilitychange",f)}},[]),le(()=>{let i=!1,r=!1,f=W.peek();const l=To(),c=to(),p=Er(),u=qo(),_=W.subscribe(d=>{if(i||!r||d===f)return;f=d;const g=v.peek();G(g)&&ne()});return Se().then(d=>{i||(r=!0,f=W.peek(),G(d)&&(ne(),Ft(),ot()))}),()=>{i=!0,_(),l(),c(),p(),u(),at(),ma()}},[]),le(()=>{const i=r=>{if(r.defaultPrevented||Te(r))return;const f=r.metaKey&&!r.ctrlKey||r.ctrlKey&&!r.metaKey,l=r.key.toLowerCase();if(ss(r)){r.preventDefault(),Eo();return}if(f&&!r.altKey&&!r.shiftKey&&l==="t"){if(Ue.peek()||typeof document<"u"&&document.querySelector('[role="dialog"][aria-modal="true"]'))return;r.preventDefault(),fn();return}if(!(f||r.altKey||r.ctrlKey||r.metaKey)&&!Ur(r.target)&&!Ue.peek()&&!(typeof document<"u"&&document.querySelector('[role="dialog"][aria-modal="true"]'))){if(!r.shiftKey&&l==="b"){r.preventDefault(),Ma();return}if(!r.shiftKey&&l==="i"){r.preventDefault(),mn();return}if(r.key===","){if(r.preventDefault(),Re("admin",v.peek())){ee("설정은 관리자 전용입니다.","info");return}N("/settings");return}if(r.key>="1"&&r.key<="6"){const c=ka[Number(r.key)-1];if(c){if(r.preventDefault(),Re(c.access,v.peek())){ee(c.access==="member"?`${c.label} 워크스페이스에 접근할 권한이 없습니다.`:`${c.label} 워크스페이스는 관리자 전용입니다.`,"info");return}N(c.defaultPath)}}}};return document.addEventListener("keydown",i),()=>document.removeEventListener("keydown",i)},[]),b`
    <div
      class="ap-shell"
      data-workspace=${t.workspace}
      data-mobile=${e?"true":"false"}
      data-authenticated=${pr.value?"true":"false"}
      data-window-focused=${o?"true":"false"}
    >
      <${ls} />
      <${ts} />
      <${ds} />

      <div class="ap-stage">
        ${!e&&b`<${Go} />`}
        <main ref=${a} id="main-content" tabindex=${-1} class="ap-main">
          <${us} />
        </main>
        <${ps} />
      </div>

      ${e&&b`<${Ko} />`}
      <${cs} />

      ${n&&b`
        <${$e} fallback=${null}>
          <${as} />
        <//>
      `}
    </div>
  `}Ea(Ia());Ta(Pa());const Vn=document.getElementById("app");Vn&&Fa(b`<${fs} />`,Vn);export{ws as $,_e as A,P as B,qr as C,da as D,$t as E,Es as F,qs as G,Ks as H,Hs as I,Ne as J,As as K,Hr as L,Kr as M,Lr as N,Re as O,Yo as P,$a as Q,mr as R,hr as S,xs as T,I as U,Oe as V,wn as W,Tr as X,H as Y,Cs as Z,Uo as _,v as a,Ns as a0,Da as a1,xa as a2,So as a3,D as a4,Rs as a5,Se as a6,ne as a7,Ws as a8,Bs as a9,sr as aA,lr as aB,Br as aC,Cr as aD,$r as aE,nn as aF,yn as aG,ra as aH,$s as aI,wr as aJ,ft as aK,Ts as aL,Ps as aM,Ds as aN,Ms as aO,rr as aP,Mt as aQ,Is as aR,Ot as aS,ha as aT,jr as aU,Xr as aV,mn as aa,Ma as ab,je as ac,cn as ad,F as ae,Us as af,zs as ag,lt as ah,aa as ai,an as aj,Ao as ak,Co as al,Os as am,Fs as an,$n as ao,Ss as ap,vt as aq,Ls as ar,Xt as as,ks as at,_s as au,bs as av,hs as aw,ue as ax,ir as ay,ys as az,Ae as b,fr as c,Ce as d,Ie as e,pn as f,Ue as g,Ur as h,mt as i,x as j,kn as k,G as l,X as m,N as n,ee as o,ke as p,Vs as q,ot as r,W as s,fn as t,Gs as u,io as v,Ge as w,ht as x,Lo as y,on as z};
