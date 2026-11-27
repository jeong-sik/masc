import{A as x,d as m,y as F,q as Y,m as l,$ as gt}from"./vendor.js";import{u as ht,i as bt,b as vt,c as $t,p as yt,e as lt,f as ut,g as wt,h as at,j as nt,a as kt}from"./markdown-renderer.js";import{v as At,ar as Tt,s as H,ah as ot,a as Ut,aj as Lt,Y as Dt}from"./index.js";import{f as It,D as _t}from"./core.js";import{c as rt}from"./copyable-code.js";const xt=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;function Et(){if(typeof crypto<"u"&&typeof crypto.randomUUID=="function")return crypto.randomUUID();const t=new Uint8Array(16);return crypto.getRandomValues(t),t[6]=t[6]&15|64,t[8]=t[8]&63|128,Ct(t)}function oe(t){return typeof t=="string"&&xt.test(t)}function Ct(t){const n=Array.from(t,o=>o.toString(16).padStart(2,"0")).join("");return`${n.slice(0,8)}-${n.slice(8,12)}-${n.slice(12,16)}-${n.slice(16,20)}-${n.slice(20,32)}`}const Rt=["image/png","image/jpeg","image/webp","image/gif"],jt=["application/pdf"],Mt=["audio/mpeg","audio/wav","audio/ogg","audio/midi","audio/mp4","audio/webm"],ft=20*1024*1024,Ot=8,Pt="image/*,application/pdf,audio/*",St={png:"image/png",jpg:"image/jpeg",jpeg:"image/jpeg",webp:"image/webp",gif:"image/gif",pdf:"application/pdf",mp3:"audio/mpeg",wav:"audio/wav",ogg:"audio/ogg",mid:"audio/midi",midi:"audio/midi",m4a:"audio/mp4",webm:"audio/webm"},Wt=new Set(["image/svg+xml","text/html","application/xhtml+xml"]);function pt(t){const n=t.type.trim().toLowerCase().split(";",1)[0]?.trim()??"";if(n!=="")return n==="image/jpg"?"image/jpeg":n;const o=t.name.lastIndexOf("."),a=o>=0?t.name.slice(o+1).toLowerCase():"";return St[a]??""}function Ft(t){const n=t.toLowerCase();return n.startsWith("image/")?"image":n.startsWith("audio/")?"audio":"document"}function zt(t,n=ft){const o=pt(t);return Wt.has(o)?`보안상 업로드할 수 없는 형식입니다: ${o}`:Rt.includes(o)||jt.includes(o)||Mt.includes(o)?t.size<=0?`빈 파일은 첨부할 수 없습니다: ${t.name||"파일"}`:t.size>n?`파일 크기 초과 (최대 ${Math.round(n/1048576)}MB): ${t.name}`:null:`지원하지 않는 파일 형식입니다: ${o===""?t.name||"알 수 없음":o}`}function Bt(t){return typeof Image>"u"||typeof URL>"u"||typeof URL.createObjectURL!="function"?Promise.resolve(null):new Promise(n=>{const o=new Image,a=URL.createObjectURL(t),r=g=>{try{URL.revokeObjectURL(a)}catch{}n(g)};o.onload=()=>{o.naturalWidth>0&&o.naturalHeight>0?r({width:o.naturalWidth,height:o.naturalHeight}):r(null)},o.onerror=()=>r(null),o.src=a})}function Nt(t,n){if(!n.startsWith("image/")||typeof URL>"u"||typeof URL.createObjectURL!="function")return null;try{return URL.createObjectURL(t)}catch{return null}}function mt(t){if(!(!t||!t.startsWith("blob:"))&&!(typeof URL>"u"||typeof URL.revokeObjectURL!="function"))try{URL.revokeObjectURL(t)}catch{}}function ct(t){if(!t)return[];const n=[];if(t.items&&t.items.length>0)for(let o=0;o<t.items.length;o+=1){const a=t.items[o];if(!a||a.kind!=="file")continue;const r=a.getAsFile();r&&n.push(r)}if(n.length===0&&t.files&&t.files.length>0)for(let o=0;o<t.files.length;o+=1){const a=t.files[o];a&&n.push(a)}return n}function tt(t){return t==null||!Number.isFinite(t)||t<0?"":t<1024?`${Math.trunc(t)} B`:t<1024*1024?`${(t/1024).toFixed(1)} KB`:`${(t/(1024*1024)).toFixed(2)} MB`}function it(t){if(!t)return null;switch(t){case"user_upload":return"사용자 업로드";case"tool_capture":return"도구 캡처";case"model_generated":return"모델 생성";case"connector_inbound":return"외부 채널";default:return t}}function ae(t){const n=[];for(const o of t)o.status==="ready"&&o.ref&&n.push(o.ref);return n}function re(t){return t.some(n=>n.status==="uploading")}function Ht(t){return t.some(n=>n.status==="error")}function ie(t){for(const n of t)mt(n.previewUrl)}function se({items:t,onChange:n,disabled:o=!1,maxItems:a=Ot,maxBytes:r=ft,accept:g=Pt,showTrigger:i=!0,triggerLabel:T="첨부",pickerRef:v,className:w,onError:U,uploadImpl:f=ht,children:h}){const D=x(null),y=x(0),[k,E]=m(!1),$=x(!0),O=x(t);O.current=t;const K=x(n);K.current=n;const A=x(new Map);F(()=>($.current=!0,()=>{$.current=!1;const e=new Set(A.current.keys());for(const s of A.current.values())s.abort("unmounted");A.current.clear(),e.size>0&&K.current(s=>s.map(d=>e.has(d.localId)&&d.status==="uploading"?{...d,status:"error",progress:0,error:"업로드가 중단되었습니다. 다시 시도하거나 제거하세요."}:d))}),[]);const P=Y(()=>{o||D.current?.click()},[o]);F(()=>{if(v)return v.current=P,()=>{v.current===P&&(v.current=null)}},[v,P]);const z=Y(e=>{A.current.get(e.localId)?.abort("retry");const s=new AbortController;A.current.set(e.localId,s),f(e.file,{filename:e.filename,mimeType:e.mimeType,signal:s.signal,onProgress:d=>{!$.current||s.signal.aborted||n(p=>p.map(L=>L.localId===e.localId?{...L,progress:d}:L))}}).then(d=>{if(A.current.get(e.localId)===s&&A.current.delete(e.localId),!$.current||s.signal.aborted)return;if(!d.ok){n(L=>L.map(u=>u.localId===e.localId?{...u,status:"error",progress:0,error:d.error.message,ref:null}:u)),U?.(`${e.filename} 업로드 실패: ${d.error.message}`);return}const p=d.value;n(L=>L.map(u=>u.localId===e.localId?{...u,status:"ready",progress:100,error:null,ref:p,width:p.width??u.width,height:p.height??u.height,bytes:p.bytes>0?p.bytes:u.bytes}:u))})},[n,U,f]),S=Y(e=>{if(o||e.length===0)return;const s=Math.max(0,a-O.current.length);if(s===0){U?.(`첨부 파일은 최대 ${a}개까지 추가할 수 있습니다.`);return}const d=[],p=[],L=e.slice(0,s);e.length>s&&p.push(`최대 ${a}개까지만 첨부할 수 있어 일부 파일이 제외되었습니다.`);for(const u of L){const I=zt(u,r);if(I){p.push(I);continue}const R=pt(u),_=Ft(R),j=`draft-${Et()}`,et=u.name||`clipboard-${j.slice(-6)}.${R.split("/")[1]??"bin"}`,Z=Nt(u,R),c={localId:j,file:u,filename:et,mimeType:R,kind:_,bytes:u.size,width:null,height:null,previewUrl:Z,status:"uploading",progress:5,error:null,ref:null};d.push(c)}if(p.length>0&&U?.(p.join(" · ")),d.length!==0){n(u=>[...u,...d]);for(const u of d)u.kind==="image"&&Bt(u.file).then(I=>{!$.current||!I||n(R=>R.map(_=>_.localId===u.localId?{..._,width:_.width??I.width,height:_.height??I.height}:_))}),z(u)}},[o,r,a,n,U,z]),q=Y(e=>{A.current.get(e)?.abort("removed"),A.current.delete(e),n(s=>{const d=s.find(p=>p.localId===e);return d&&mt(d.previewUrl),s.filter(p=>p.localId!==e)})},[n]),G=Y(e=>{o||(n(s=>s.map(d=>d.localId===e.localId?{...d,status:"uploading",progress:5,error:null}:d)),z(e))},[o,n,z]),B=e=>{const s=e.currentTarget,d=s.files?Array.from(s.files):[];s.value="",S(d)},V=e=>{if(o)return;const s=ct(e.clipboardData);s.length!==0&&(e.preventDefault(),S(s))},J=e=>{if(o)return;const s=Array.from(e.dataTransfer?.types??[]);s.length>0&&!s.includes("Files")||(e.preventDefault(),y.current+=1,E(!0))},st=e=>{o||(e.preventDefault(),e.dataTransfer&&(e.dataTransfer.dropEffect="copy"),k||E(!0))},W=e=>{e.preventDefault(),y.current=Math.max(0,y.current-1),y.current===0&&E(!1)},Q=e=>{if(e.preventDefault(),y.current=0,E(!1),o)return;const s=ct(e.dataTransfer);S(s)},C=["att-composer-zone",w].filter(Boolean).join(" ");return l`
    <div
      class=${C}
      data-testid="attachment-composer"
      data-drag-over=${k?"true":"false"}
      onPaste=${V}
      onDragEnter=${J}
      onDragOver=${st}
      onDragLeave=${W}
      onDrop=${Q}
    >
      ${k&&l`
        <div class="att-drop-overlay" role="status" data-testid="attachment-drop-overlay">
          여기에 이미지 · PDF · 오디오 파일을 놓아 첨부하세요
        </div>
      `}

      ${t.length>0&&l`
        <div class="att-chip-tray" role="list" aria-label="첨부 파일 목록" data-testid="attachment-chip-tray">
          ${t.map(e=>{const s=e.width&&e.height?`${e.width}×${e.height}`:null,d=tt(e.bytes),p=[s,d].filter(Boolean).join(" · ");return l`
              <div
                key=${e.localId}
                role="listitem"
                class="att-chip"
                data-status=${e.status}
                data-kind=${e.kind}
                data-testid="attachment-chip"
              >
                ${e.kind==="image"&&e.previewUrl?l`<img class="att-chip-thumb" src=${e.previewUrl} alt=${e.filename} />`:l`<span class="att-chip-icon mono" aria-hidden="true">${e.kind==="audio"?"AUDIO":e.mimeType==="application/pdf"?"PDF":"FILE"}</span>`}
                <div class="att-chip-body">
                  <div class="att-chip-name" title=${e.filename}>${e.filename}</div>
                  <div class="att-chip-meta mono">
                    ${e.status==="uploading"?`업로드 중… ${e.progress}%`:e.status==="error"?e.error??"업로드 실패":p||e.mimeType}
                  </div>
                </div>
                ${e.status==="error"&&l`
                  <button
                    type="button"
                    class="btn-ghost btn-compact"
                    aria-label=${`${e.filename} 재시도`}
                    onClick=${()=>G(e)}
                  >
                    재시도
                  </button>
                `}
                <button
                  type="button"
                  class="att-chip-remove"
                  aria-label=${`${e.filename} 첨부 제거`}
                  onClick=${()=>q(e.localId)}
                >
                  ×
                </button>
              </div>
            `})}
        </div>
      `}

      ${Ht(t)&&l`
        <div class="ap-error" role="alert" data-testid="attachment-error-blocker">
          업로드에 실패한 첨부 파일을 재시도하거나 제거한 뒤 전송하세요.
        </div>
      `}

      ${h}

      <input
        ref=${D}
        type="file"
        multiple
        accept=${g}
        class="kp-hidden-input"
        aria-label="첨부 파일 선택"
        data-testid="attachment-file-input"
        disabled=${o}
        onChange=${B}
      />

      ${i&&l`
        <div class="att-composer-bar">
          <button
            type="button"
            class="btn-ghost btn-compact"
            disabled=${o||t.length>=a}
            onClick=${P}
          >
            📎 ${T}
          </button>
          <span class="att-composer-hint">이미지 붙여넣기(⌘V) · 드래그 앤 드롭 지원</span>
        </div>
      `}
    </div>
  `}function Kt({title:t,subtitle:n,actions:o,footer:a,onClose:r,children:g}){const i=x(null),T=x(r);return T.current=r,At({containerRef:i,active:!0}),F(()=>{const v=w=>{Tt(w)&&(w.preventDefault(),w.stopPropagation(),T.current())};return window.addEventListener("keydown",v,!0),()=>window.removeEventListener("keydown",v,!0)},[]),gt(l`
    <div
      ref=${i}
      class="fixed inset-0 z-[var(--z-modal)] flex items-center justify-center bg-black/60 p-4 backdrop-blur-sm"
      onClick=${r}
      role="dialog"
      aria-modal="true"
      aria-label=${t}
    >
      <div
        class="relative flex max-h-[92vh] max-w-[92vw] flex-col overflow-hidden rounded-[var(--r-2)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-4 shadow-[var(--shadow-raised)]"
        onClick=${v=>v.stopPropagation()}
      >
        <div class="mb-3 flex flex-wrap items-center justify-between gap-3">
          <div class="min-w-0 flex-1">
            <div class="truncate text-sm font-semibold text-[var(--color-fg-primary)]">${t}</div>
            ${n&&l`
              <div class="mono truncate text-xs text-[var(--color-fg-secondary)]">${n}</div>
            `}
          </div>
          <div class="flex shrink-0 items-center gap-2">
            ${o}
            <button
              type="button"
              class="rounded-[var(--r-0)] px-2 py-1 text-xs text-[var(--color-fg-secondary)] hover:bg-[var(--color-bg-hover)] hover:text-[var(--color-fg-primary)]"
              onClick=${r}
              aria-label="닫기"
            >
              ✕
            </button>
          </div>
        </div>
        <div class="chat-preview-modal-body min-h-0 flex-1 overflow-auto">${g}</div>
        ${a&&l`
          <div class="chat-preview-modal-footer mt-3 flex flex-wrap items-center justify-between gap-2 border-t border-[var(--line-1)] pt-2 text-xs text-[var(--fg-2)]">
            ${a}
          </div>
        `}
      </div>
    </div>
  `,document.body)}const dt=50*1024*1024,Xt=640;async function Yt(t){const n=t.headers.get("content-type")?.split(";",1)[0]?.trim();if(!t.ok||!nt(n)||Number(t.headers.get("content-length"))>dt||!t.body)return await t.body?.cancel(),null;const o=t.body.getReader(),a=[];let r=0;try{for(;;){const{done:g,value:i}=await o.read();if(g)return r>0?{blob:new Blob(a,{type:n}),contentType:n}:null;if(r+=i.byteLength,r>dt)return await o.cancel(),null;a.push(i.slice().buffer)}}finally{o.releaseLock()}}function qt({path:t,caption:n,workspaceEpoch:o,attachment:a,thumbnailMaxPx:r,compact:g=!1}){const i=x(null),[T,v]=m(typeof IntersectionObserver>"u"),[w,U]=m(0),f=H.value,h=o===f,[D,y]=m(null),[k,E]=m(null),[$,O]=m(!1),[K,A]=m(!1),[P,z]=m(null),[S,q]=m(!1),[G,B]=m(null),[V,J]=m(null),W=bt(t)?r===void 0?Xt:r:null,Q=W!==null&&W>0?vt(t,{max_px:W}):t;if(F(()=>{const c=i.current;if(!h||!c||typeof IntersectionObserver>"u")return;const b=new IntersectionObserver(([M])=>{M?.isIntersecting&&(v(!0),b.disconnect())},{rootMargin:"160px"});return b.observe(c),()=>b.disconnect()},[h]),F(()=>{if(!T||!h||H.peek()!==f||!$t(t))return;const c=yt(ot(Q),window.location.origin);if(!c||c.origin!==window.location.origin){y({path:t,epoch:f,src:null,contentType:null});return}const b=new AbortController,M=Ut.peek().kind==="multi_account_signed_in"?null:Lt(),X=N=>{!b.signal.aborted&&H.peek()===f&&y({path:t,epoch:f,src:N.src,contentType:N.contentType})};return It(c.href,{credentials:"same-origin",mode:"same-origin",redirect:"error",signal:b.signal,headers:M?{Authorization:`Bearer ${M}`}:void 0},_t,Yt).then(async N=>N?{src:await lt(N.blob),contentType:N.contentType}:{src:null,contentType:null}).then(X,()=>X({src:null,contentType:null})),()=>b.abort()},[w,h,f,t,Q,T]),F(()=>{if(!$||!h||W===null||k?.path===t&&k.epoch===f&&k.src)return;const c=new AbortController;return ut(t,{maxPx:null,requireRasterImage:!0,signal:c.signal}).then(async b=>{if(c.signal.aborted||H.peek()!==f||!b.ok)return;const M=await lt(b.value.blob);!c.signal.aborted&&H.peek()===f&&M&&E({path:t,epoch:f,src:M,contentType:b.value.contentType})}),()=>c.abort()},[$,h,W,f,t,k]),!h)return null;const C=D?.path===t&&D.epoch===f?D:null,e=k?.path===t&&k.epoch===f&&k.src?k.src:C?.src??null,s=a?.attachment_id??a?.id??wt(t)??t,d=n||a?.caption||a?.filename||"첨부 이미지",p=a?.width??P?.width??null,L=a?.height??P?.height??null,u=p&&L?`${p}×${L}`:null,I=a?.mime_type??C?.contentType??null,R=a&&a.bytes>0?tt(a.bytes):null,_=it(a?.origin),j=[u,I,R,_].filter(c=>!!c),et=async()=>{if(!S){q(!0),B(null);try{const c=await at({url:t,id:s,mime_type:I??"image/png",filename:a?.filename??null});c.ok||B(c.error.message)}finally{q(!1)}}},Z=async c=>{const b=c==="id"?s:ot(t);await rt(b)&&(J(c),setTimeout(()=>J(X=>X===c?null:X),1500))};return l`
    <figure class=${`img-out${g?" img-out--compact":""}`} ref=${i} data-attachment-id=${s}>
      ${C?.src?l`
        <div
          class="chat-block-media-frame img-frame cursor-zoom-in"
          role="button"
          tabIndex=${0}
          aria-label=${`${d} 크게 보기`}
          onClick=${()=>{A(!1),B(null),O(!0)}}
          onKeyDown=${c=>{c.isComposing||c.keyCode===229||(c.key==="Enter"||c.key===" ")&&(c.preventDefault(),A(!1),B(null),O(!0))}}
        >
          <img
            src=${C.src}
            alt=${d}
            class=${g?"max-h-48 w-full rounded-[var(--r-1)] object-contain":"max-h-96 w-full rounded-[var(--r-1)] object-contain"}
            onLoad=${c=>{const b=c.currentTarget;b.naturalWidth>0&&b.naturalHeight>0&&z({width:b.naturalWidth,height:b.naturalHeight})}}
            onError=${()=>{O(!1),y({path:t,epoch:f,src:null,contentType:null})}}
          />
        </div>
      `:l`
        <div class="chat-block-media-ph img-ph">
          <span role="status">${C?"이미지를 불러올 수 없습니다":d}</span>
          ${C&&l`
            <button type="button" class="btn-ghost" aria-label="이미지 다시 시도" onClick=${()=>{y(null),U(c=>c+1)}}>다시 시도</button>
          `}
        </div>
      `}
      ${(n||j.length>0)&&l`
        <figcaption class="att-figcaption">
          ${n&&l`<span>${n}</span>`}
          ${j.length>0&&l`<span class="mono att-meta-inline">${j.join(" · ")}</span>`}
        </figcaption>
      `}
      ${$&&e&&l`
        <${Kt}
          title=${d}
          subtitle=${j.join(" · ")||void 0}
          onClose=${()=>O(!1)}
          actions=${l`
            <button
              type="button"
              class="btn-ghost btn-compact"
              onClick=${()=>A(c=>!c)}
            >
              ${K?"화면에 맞추기":"원본 크기 (1:1)"}
            </button>
            <button
              type="button"
              class="btn-ghost btn-compact"
              disabled=${S}
              onClick=${()=>{et()}}
            >
              ${S?"다운로드 중…":"다운로드"}
            </button>
            <button
              type="button"
              class="btn-ghost btn-compact"
              onClick=${()=>{Z("id")}}
            >
              ${V==="id"?"ID 복사됨":"ID 복사"}
            </button>
            <button
              type="button"
              class="btn-ghost btn-compact"
              onClick=${()=>{Z("url")}}
            >
              ${V==="url"?"URL 복사됨":"URL 복사"}
            </button>
          `}
          footer=${l`
            <span class="mono" data-testid="lightbox-meta-id">${s}</span>
            <span class="mono" data-testid="lightbox-meta-details">
              ${j.join(" · ")||t}
            </span>
          `}
        >
          <img
            src=${e}
            alt=${d}
            class=${K?"max-w-none rounded-[var(--r-1)]":"max-h-[75vh] max-w-full rounded-[var(--r-1)] object-contain"}
          />
          ${G&&l`
            <div class="ap-error mt-2" role="alert" data-testid="lightbox-download-error">${G}</div>
          `}
        <//>
      `}
    </figure>
  `}function Gt({attachment:t,workspaceEpoch:n}){const o=H.value,a=n===o,[r,g]=m(null),[i,T]=m(!1),[v,w]=m(null),[U,f]=m(!1),[h,D]=m(!1);if(F(()=>()=>{if(r&&r.startsWith("blob:"))try{URL.revokeObjectURL(r)}catch{}},[r]),!a)return null;const y=async()=>{if(i||r)return;T(!0),w(null);const $=await ut(t.url);if(T(!1),!$.ok){w($.error.message);return}g(URL.createObjectURL($.value.blob))},k=it(t.origin),E=[t.mime_type,tt(t.bytes),k].filter(Boolean).join(" · ");return l`
    <div class="att-card att-audio-card" data-testid="attachment-audio-card" data-attachment-id=${t.attachment_id}>
      <div class="att-card-head">
        <span class="att-card-badge mono">AUDIO</span>
        <div class="att-card-info">
          <div class="att-card-title">${t.filename||t.attachment_id}</div>
          <div class="att-card-meta mono">${E}</div>
        </div>
        <div class="att-card-actions">
          ${!r&&l`
            <button type="button" class="btn-ghost btn-compact" disabled=${i} onClick=${()=>{y()}}>
              ${i?"불러오는 중…":"재생 불러오기"}
            </button>
          `}
          <button
            type="button"
            class="btn-ghost btn-compact"
            disabled=${U}
            onClick=${async()=>{f(!0),w(null);try{const $=await at(t);$.ok||w($.error.message)}finally{f(!1)}}}
          >
            ${U?"다운로드 중…":"다운로드"}
          </button>
          <button
            type="button"
            class="btn-ghost btn-compact"
            onClick=${async()=>{await rt(t.attachment_id)&&(D(!0),setTimeout(()=>D(!1),1500))}}
          >
            ${h?"ID 복사됨":"ID 복사"}
          </button>
        </div>
      </div>
      ${v&&l`<div class="ap-error" role="alert">${v}</div>`}
      ${r&&l`<audio class="att-audio-player" controls src=${r} preload="metadata" />`}
    </div>
  `}function Vt({attachment:t}){const[n,o]=m(!1),[a,r]=m(null),[g,i]=m(null),T=t.mime_type==="application/pdf"?"PDF":"DOC",v=it(t.origin),w=[t.mime_type,tt(t.bytes),v].filter(Boolean).join(" · "),U=async()=>{if(!n){o(!0),i(null);try{const h=await at(t);h.ok||i(h.error.message)}finally{o(!1)}}},f=async h=>{const D=h==="id"?t.attachment_id:ot(t.url);await rt(D)&&(r(h),setTimeout(()=>r(y=>y===h?null:y),1500))};return l`
    <div class="att-card att-doc-card" data-testid="attachment-document-card" data-attachment-id=${t.attachment_id}>
      <div class="att-card-head">
        <span class="att-card-badge mono">${T}</span>
        <div class="att-card-info">
          <div class="att-card-title">${t.filename||t.attachment_id}</div>
          <div class="att-card-meta mono">${w}</div>
        </div>
        <div class="att-card-actions">
          <button
            type="button"
            class="btn-ghost btn-compact"
            disabled=${n}
            onClick=${()=>{U()}}
          >
            ${n?"다운로드 중…":"다운로드"}
          </button>
          <button
            type="button"
            class="btn-ghost btn-compact"
            onClick=${()=>{f("id")}}
          >
            ${a==="id"?"ID 복사됨":"ID 복사"}
          </button>
          <button
            type="button"
            class="btn-ghost btn-compact"
            onClick=${()=>{f("url")}}
          >
            ${a==="url"?"URL 복사됨":"URL 복사"}
          </button>
        </div>
      </div>
      ${g&&l`<div class="ap-error" role="alert">${g}</div>`}
    </div>
  `}function le({attachments:t,workspaceEpoch:n=Dt(),compact:o=!1}){const a=kt(t);if(a.length===0)return null;const r=a.filter(i=>i.kind==="image"||nt(i.mime_type)),g=a.filter(i=>i.kind!=="image"&&!nt(i.mime_type));return l`
    <div class=${`att-gallery${o?" att-gallery--compact":""}`} data-testid="attachment-gallery">
      ${r.length>0&&l`
        <div class=${`att-image-grid${r.length===1?" att-image-grid--single":""}`}>
          ${r.map(i=>l`
            <${qt}
              key=${i.attachment_id||i.url}
              path=${i.url}
              caption=${i.caption??void 0}
              attachment=${i}
              workspaceEpoch=${n}
              compact=${o}
            />
          `)}
        </div>
      `}
      ${g.length>0&&l`
        <div class="att-nonimage-list">
          ${g.map(i=>i.kind==="audio"?l`<${Gt} key=${i.attachment_id||i.url} attachment=${i} workspaceEpoch=${n} />`:l`<${Vt} key=${i.attachment_id||i.url} attachment=${i} />`)}
        </div>
      `}
    </div>
  `}export{se as A,Ht as a,le as b,ae as c,Et as d,re as h,oe as i,ie as r};
