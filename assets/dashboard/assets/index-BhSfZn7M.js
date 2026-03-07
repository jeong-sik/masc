var kr=Object.defineProperty;var xr=(t,e,n)=>e in t?kr(t,e,{enumerable:!0,configurable:!0,writable:!0,value:n}):t[e]=n;var le=(t,e,n)=>xr(t,typeof e!="symbol"?e+"":e,n);(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const s of document.querySelectorAll('link[rel="modulepreload"]'))a(s);new MutationObserver(s=>{for(const i of s)if(i.type==="childList")for(const r of i.addedNodes)r.tagName==="LINK"&&r.rel==="modulepreload"&&a(r)}).observe(document,{childList:!0,subtree:!0});function n(s){const i={};return s.integrity&&(i.integrity=s.integrity),s.referrerPolicy&&(i.referrerPolicy=s.referrerPolicy),s.crossOrigin==="use-credentials"?i.credentials="include":s.crossOrigin==="anonymous"?i.credentials="omit":i.credentials="same-origin",i}function a(s){if(s.ep)return;s.ep=!0;const i=n(s);fetch(s.href,i)}})();var Sa,F,ao,so,Xt,ci,io,oo,ro,Js,ps,vs,ln={},lo=[],wr=/acit|ex(?:s|g|n|p|$)|rph|grid|ows|mnc|ntw|ine[ch]|zoo|^ord|itera/i,Aa=Array.isArray;function Ct(t,e){for(var n in e)t[n]=e[n];return t}function Vs(t){t&&t.parentNode&&t.parentNode.removeChild(t)}function co(t,e,n){var a,s,i,r={};for(i in e)i=="key"?a=e[i]:i=="ref"?s=e[i]:r[i]=e[i];if(arguments.length>2&&(r.children=arguments.length>3?Sa.call(arguments,2):n),typeof t=="function"&&t.defaultProps!=null)for(i in t.defaultProps)r[i]===void 0&&(r[i]=t.defaultProps[i]);return qn(t,r,a,s,null)}function qn(t,e,n,a,s){var i={type:t,props:e,key:n,ref:a,__k:null,__:null,__b:0,__e:null,__c:null,constructor:void 0,__v:s??++ao,__i:-1,__u:0};return s==null&&F.vnode!=null&&F.vnode(i),i}function $n(t){return t.children}function je(t,e){this.props=t,this.context=e}function we(t,e){if(e==null)return t.__?we(t.__,t.__i+1):null;for(var n;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null)return n.__e;return typeof t.type=="function"?we(t):null}function uo(t){var e,n;if((t=t.__)!=null&&t.__c!=null){for(t.__e=t.__c.base=null,e=0;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null){t.__e=t.__c.base=n.__e;break}return uo(t)}}function ui(t){(!t.__d&&(t.__d=!0)&&Xt.push(t)&&!Qn.__r++||ci!=F.debounceRendering)&&((ci=F.debounceRendering)||io)(Qn)}function Qn(){for(var t,e,n,a,s,i,r,u=1;Xt.length;)Xt.length>u&&Xt.sort(oo),t=Xt.shift(),u=Xt.length,t.__d&&(n=void 0,a=void 0,s=(a=(e=t).__v).__e,i=[],r=[],e.__P&&((n=Ct({},a)).__v=a.__v+1,F.vnode&&F.vnode(n),Qs(e.__P,n,a,e.__n,e.__P.namespaceURI,32&a.__u?[s]:null,i,s??we(a),!!(32&a.__u),r),n.__v=a.__v,n.__.__k[n.__i]=n,mo(i,n,r),a.__e=a.__=null,n.__e!=s&&uo(n)));Qn.__r=0}function po(t,e,n,a,s,i,r,u,d,p,f){var l,c,v,h,k,w,C,A=a&&a.__k||lo,O=e.length;for(d=Sr(n,e,A,d,O),l=0;l<O;l++)(v=n.__k[l])!=null&&(c=v.__i==-1?ln:A[v.__i]||ln,v.__i=l,w=Qs(t,v,c,s,i,r,u,d,p,f),h=v.__e,v.ref&&c.ref!=v.ref&&(c.ref&&Ys(c.ref,null,v),f.push(v.ref,v.__c||h,v)),k==null&&h!=null&&(k=h),(C=!!(4&v.__u))||c.__k===v.__k?d=vo(v,d,t,C):typeof v.type=="function"&&w!==void 0?d=w:h&&(d=h.nextSibling),v.__u&=-7);return n.__e=k,d}function Sr(t,e,n,a,s){var i,r,u,d,p,f=n.length,l=f,c=0;for(t.__k=new Array(s),i=0;i<s;i++)(r=e[i])!=null&&typeof r!="boolean"&&typeof r!="function"?(typeof r=="string"||typeof r=="number"||typeof r=="bigint"||r.constructor==String?r=t.__k[i]=qn(null,r,null,null,null):Aa(r)?r=t.__k[i]=qn($n,{children:r},null,null,null):r.constructor===void 0&&r.__b>0?r=t.__k[i]=qn(r.type,r.props,r.key,r.ref?r.ref:null,r.__v):t.__k[i]=r,d=i+c,r.__=t,r.__b=t.__b+1,u=null,(p=r.__i=Ar(r,n,d,l))!=-1&&(l--,(u=n[p])&&(u.__u|=2)),u==null||u.__v==null?(p==-1&&(s>f?c--:s<f&&c++),typeof r.type!="function"&&(r.__u|=4)):p!=d&&(p==d-1?c--:p==d+1?c++:(p>d?c--:c++,r.__u|=4))):t.__k[i]=null;if(l)for(i=0;i<f;i++)(u=n[i])!=null&&(2&u.__u)==0&&(u.__e==a&&(a=we(u)),_o(u,u));return a}function vo(t,e,n,a){var s,i;if(typeof t.type=="function"){for(s=t.__k,i=0;s&&i<s.length;i++)s[i]&&(s[i].__=t,e=vo(s[i],e,n,a));return e}t.__e!=e&&(a&&(e&&t.type&&!e.parentNode&&(e=we(t)),n.insertBefore(t.__e,e||null)),e=t.__e);do e=e&&e.nextSibling;while(e!=null&&e.nodeType==8);return e}function Ar(t,e,n,a){var s,i,r,u=t.key,d=t.type,p=e[n],f=p!=null&&(2&p.__u)==0;if(p===null&&u==null||f&&u==p.key&&d==p.type)return n;if(a>(f?1:0)){for(s=n-1,i=n+1;s>=0||i<e.length;)if((p=e[r=s>=0?s--:i++])!=null&&(2&p.__u)==0&&u==p.key&&d==p.type)return r}return-1}function di(t,e,n){e[0]=="-"?t.setProperty(e,n??""):t[e]=n==null?"":typeof n!="number"||wr.test(e)?n:n+"px"}function Cn(t,e,n,a,s){var i,r;t:if(e=="style")if(typeof n=="string")t.style.cssText=n;else{if(typeof a=="string"&&(t.style.cssText=a=""),a)for(e in a)n&&e in n||di(t.style,e,"");if(n)for(e in n)a&&n[e]==a[e]||di(t.style,e,n[e])}else if(e[0]=="o"&&e[1]=="n")i=e!=(e=e.replace(ro,"$1")),r=e.toLowerCase(),e=r in t||e=="onFocusOut"||e=="onFocusIn"?r.slice(2):e.slice(2),t.l||(t.l={}),t.l[e+i]=n,n?a?n.u=a.u:(n.u=Js,t.addEventListener(e,i?vs:ps,i)):t.removeEventListener(e,i?vs:ps,i);else{if(s=="http://www.w3.org/2000/svg")e=e.replace(/xlink(H|:h)/,"h").replace(/sName$/,"s");else if(e!="width"&&e!="height"&&e!="href"&&e!="list"&&e!="form"&&e!="tabIndex"&&e!="download"&&e!="rowSpan"&&e!="colSpan"&&e!="role"&&e!="popover"&&e in t)try{t[e]=n??"";break t}catch{}typeof n=="function"||(n==null||n===!1&&e[4]!="-"?t.removeAttribute(e):t.setAttribute(e,e=="popover"&&n==1?"":n))}}function pi(t){return function(e){if(this.l){var n=this.l[e.type+t];if(e.t==null)e.t=Js++;else if(e.t<n.u)return;return n(F.event?F.event(e):e)}}}function Qs(t,e,n,a,s,i,r,u,d,p){var f,l,c,v,h,k,w,C,A,O,S,R,Y,gt,ht,X,ot,I=e.type;if(e.constructor!==void 0)return null;128&n.__u&&(d=!!(32&n.__u),i=[u=e.__e=n.__e]),(f=F.__b)&&f(e);t:if(typeof I=="function")try{if(C=e.props,A="prototype"in I&&I.prototype.render,O=(f=I.contextType)&&a[f.__c],S=f?O?O.props.value:f.__:a,n.__c?w=(l=e.__c=n.__c).__=l.__E:(A?e.__c=l=new I(C,S):(e.__c=l=new je(C,S),l.constructor=I,l.render=Nr),O&&O.sub(l),l.state||(l.state={}),l.__n=a,c=l.__d=!0,l.__h=[],l._sb=[]),A&&l.__s==null&&(l.__s=l.state),A&&I.getDerivedStateFromProps!=null&&(l.__s==l.state&&(l.__s=Ct({},l.__s)),Ct(l.__s,I.getDerivedStateFromProps(C,l.__s))),v=l.props,h=l.state,l.__v=e,c)A&&I.getDerivedStateFromProps==null&&l.componentWillMount!=null&&l.componentWillMount(),A&&l.componentDidMount!=null&&l.__h.push(l.componentDidMount);else{if(A&&I.getDerivedStateFromProps==null&&C!==v&&l.componentWillReceiveProps!=null&&l.componentWillReceiveProps(C,S),e.__v==n.__v||!l.__e&&l.shouldComponentUpdate!=null&&l.shouldComponentUpdate(C,l.__s,S)===!1){for(e.__v!=n.__v&&(l.props=C,l.state=l.__s,l.__d=!1),e.__e=n.__e,e.__k=n.__k,e.__k.some(function(U){U&&(U.__=e)}),R=0;R<l._sb.length;R++)l.__h.push(l._sb[R]);l._sb=[],l.__h.length&&r.push(l);break t}l.componentWillUpdate!=null&&l.componentWillUpdate(C,l.__s,S),A&&l.componentDidUpdate!=null&&l.__h.push(function(){l.componentDidUpdate(v,h,k)})}if(l.context=S,l.props=C,l.__P=t,l.__e=!1,Y=F.__r,gt=0,A){for(l.state=l.__s,l.__d=!1,Y&&Y(e),f=l.render(l.props,l.state,l.context),ht=0;ht<l._sb.length;ht++)l.__h.push(l._sb[ht]);l._sb=[]}else do l.__d=!1,Y&&Y(e),f=l.render(l.props,l.state,l.context),l.state=l.__s;while(l.__d&&++gt<25);l.state=l.__s,l.getChildContext!=null&&(a=Ct(Ct({},a),l.getChildContext())),A&&!c&&l.getSnapshotBeforeUpdate!=null&&(k=l.getSnapshotBeforeUpdate(v,h)),X=f,f!=null&&f.type===$n&&f.key==null&&(X=fo(f.props.children)),u=po(t,Aa(X)?X:[X],e,n,a,s,i,r,u,d,p),l.base=e.__e,e.__u&=-161,l.__h.length&&r.push(l),w&&(l.__E=l.__=null)}catch(U){if(e.__v=null,d||i!=null)if(U.then){for(e.__u|=d?160:128;u&&u.nodeType==8&&u.nextSibling;)u=u.nextSibling;i[i.indexOf(u)]=null,e.__e=u}else{for(ot=i.length;ot--;)Vs(i[ot]);ms(e)}else e.__e=n.__e,e.__k=n.__k,U.then||ms(e);F.__e(U,e,n)}else i==null&&e.__v==n.__v?(e.__k=n.__k,e.__e=n.__e):u=e.__e=Tr(n.__e,e,n,a,s,i,r,d,p);return(f=F.diffed)&&f(e),128&e.__u?void 0:u}function ms(t){t&&t.__c&&(t.__c.__e=!0),t&&t.__k&&t.__k.forEach(ms)}function mo(t,e,n){for(var a=0;a<n.length;a++)Ys(n[a],n[++a],n[++a]);F.__c&&F.__c(e,t),t.some(function(s){try{t=s.__h,s.__h=[],t.some(function(i){i.call(s)})}catch(i){F.__e(i,s.__v)}})}function fo(t){return typeof t!="object"||t==null||t.__b&&t.__b>0?t:Aa(t)?t.map(fo):Ct({},t)}function Tr(t,e,n,a,s,i,r,u,d){var p,f,l,c,v,h,k,w=n.props||ln,C=e.props,A=e.type;if(A=="svg"?s="http://www.w3.org/2000/svg":A=="math"?s="http://www.w3.org/1998/Math/MathML":s||(s="http://www.w3.org/1999/xhtml"),i!=null){for(p=0;p<i.length;p++)if((v=i[p])&&"setAttribute"in v==!!A&&(A?v.localName==A:v.nodeType==3)){t=v,i[p]=null;break}}if(t==null){if(A==null)return document.createTextNode(C);t=document.createElementNS(s,A,C.is&&C),u&&(F.__m&&F.__m(e,i),u=!1),i=null}if(A==null)w===C||u&&t.data==C||(t.data=C);else{if(i=i&&Sa.call(t.childNodes),!u&&i!=null)for(w={},p=0;p<t.attributes.length;p++)w[(v=t.attributes[p]).name]=v.value;for(p in w)if(v=w[p],p!="children"){if(p=="dangerouslySetInnerHTML")l=v;else if(!(p in C)){if(p=="value"&&"defaultValue"in C||p=="checked"&&"defaultChecked"in C)continue;Cn(t,p,null,v,s)}}for(p in C)v=C[p],p=="children"?c=v:p=="dangerouslySetInnerHTML"?f=v:p=="value"?h=v:p=="checked"?k=v:u&&typeof v!="function"||w[p]===v||Cn(t,p,v,w[p],s);if(f)u||l&&(f.__html==l.__html||f.__html==t.innerHTML)||(t.innerHTML=f.__html),e.__k=[];else if(l&&(t.innerHTML=""),po(e.type=="template"?t.content:t,Aa(c)?c:[c],e,n,a,A=="foreignObject"?"http://www.w3.org/1999/xhtml":s,i,r,i?i[0]:n.__k&&we(n,0),u,d),i!=null)for(p=i.length;p--;)Vs(i[p]);u||(p="value",A=="progress"&&h==null?t.removeAttribute("value"):h!=null&&(h!==t[p]||A=="progress"&&!h||A=="option"&&h!=w[p])&&Cn(t,p,h,w[p],s),p="checked",k!=null&&k!=t[p]&&Cn(t,p,k,w[p],s))}return t}function Ys(t,e,n){try{if(typeof t=="function"){var a=typeof t.__u=="function";a&&t.__u(),a&&e==null||(t.__u=t(e))}else t.current=e}catch(s){F.__e(s,n)}}function _o(t,e,n){var a,s;if(F.unmount&&F.unmount(t),(a=t.ref)&&(a.current&&a.current!=t.__e||Ys(a,null,e)),(a=t.__c)!=null){if(a.componentWillUnmount)try{a.componentWillUnmount()}catch(i){F.__e(i,e)}a.base=a.__P=null}if(a=t.__k)for(s=0;s<a.length;s++)a[s]&&_o(a[s],e,n||typeof t.type!="function");n||Vs(t.__e),t.__c=t.__=t.__e=void 0}function Nr(t,e,n){return this.constructor(t,n)}function Cr(t,e,n){var a,s,i,r;e==document&&(e=document.documentElement),F.__&&F.__(t,e),s=(a=!1)?null:e.__k,i=[],r=[],Qs(e,t=e.__k=co($n,null,[t]),s||ln,ln,e.namespaceURI,s?null:e.firstChild?Sa.call(e.childNodes):null,i,s?s.__e:e.firstChild,a,r),mo(i,t,r)}Sa=lo.slice,F={__e:function(t,e,n,a){for(var s,i,r;e=e.__;)if((s=e.__c)&&!s.__)try{if((i=s.constructor)&&i.getDerivedStateFromError!=null&&(s.setState(i.getDerivedStateFromError(t)),r=s.__d),s.componentDidCatch!=null&&(s.componentDidCatch(t,a||{}),r=s.__d),r)return s.__E=s}catch(u){t=u}throw t}},ao=0,so=function(t){return t!=null&&t.constructor===void 0},je.prototype.setState=function(t,e){var n;n=this.__s!=null&&this.__s!=this.state?this.__s:this.__s=Ct({},this.state),typeof t=="function"&&(t=t(Ct({},n),this.props)),t&&Ct(n,t),t!=null&&this.__v&&(e&&this._sb.push(e),ui(this))},je.prototype.forceUpdate=function(t){this.__v&&(this.__e=!0,t&&this.__h.push(t),ui(this))},je.prototype.render=$n,Xt=[],io=typeof Promise=="function"?Promise.prototype.then.bind(Promise.resolve()):setTimeout,oo=function(t,e){return t.__v.__b-e.__v.__b},Qn.__r=0,ro=/(PointerCapture)$|Capture$/i,Js=0,ps=pi(!1),vs=pi(!0);var go=function(t,e,n,a){var s;e[0]=0;for(var i=1;i<e.length;i++){var r=e[i++],u=e[i]?(e[0]|=r?1:2,n[e[i++]]):e[++i];r===3?a[0]=u:r===4?a[1]=Object.assign(a[1]||{},u):r===5?(a[1]=a[1]||{})[e[++i]]=u:r===6?a[1][e[++i]]+=u+"":r?(s=t.apply(u,go(t,u,n,["",null])),a.push(s),u[0]?e[0]|=2:(e[i-2]=0,e[i]=s)):a.push(u)}return a},vi=new Map;function Rr(t){var e=vi.get(this);return e||(e=new Map,vi.set(this,e)),(e=go(this,e.get(t)||(e.set(t,e=(function(n){for(var a,s,i=1,r="",u="",d=[0],p=function(c){i===1&&(c||(r=r.replace(/^\s*\n\s*|\s*\n\s*$/g,"")))?d.push(0,c,r):i===3&&(c||r)?(d.push(3,c,r),i=2):i===2&&r==="..."&&c?d.push(4,c,0):i===2&&r&&!c?d.push(5,0,!0,r):i>=5&&((r||!c&&i===5)&&(d.push(i,0,r,s),i=6),c&&(d.push(i,c,0,s),i=6)),r=""},f=0;f<n.length;f++){f&&(i===1&&p(),p(f));for(var l=0;l<n[f].length;l++)a=n[f][l],i===1?a==="<"?(p(),d=[d],i=3):r+=a:i===4?r==="--"&&a===">"?(i=1,r=""):r=a+r[0]:u?a===u?u="":r+=a:a==='"'||a==="'"?u=a:a===">"?(p(),i=1):i&&(a==="="?(i=5,s=r,r=""):a==="/"&&(i<5||n[f][l+1]===">")?(p(),i===3&&(d=d[0]),i=d,(d=d[0]).push(2,0,i),i=0):a===" "||a==="	"||a===`
`||a==="\r"?(p(),i=2):r+=a),i===3&&r==="!--"&&(i=4,d=d[0])}return p(),d})(t)),e),arguments,[])).length>1?e:e[0]}var o=Rr.bind(co),cn,H,Da,mi,fs=0,ho=[],K=F,fi=K.__b,_i=K.__r,gi=K.diffed,hi=K.__c,$i=K.unmount,yi=K.__;function Xs(t,e){K.__h&&K.__h(H,t,fs||e),fs=0;var n=H.__H||(H.__H={__:[],__h:[]});return t>=n.__.length&&n.__.push({}),n.__[t]}function Oe(t){return fs=1,Lr(bo,t)}function Lr(t,e,n){var a=Xs(cn++,2);if(a.t=t,!a.__c&&(a.__=[bo(void 0,e),function(u){var d=a.__N?a.__N[0]:a.__[0],p=a.t(d,u);d!==p&&(a.__N=[p,a.__[1]],a.__c.setState({}))}],a.__c=H,!H.__f)){var s=function(u,d,p){if(!a.__c.__H)return!0;var f=a.__c.__H.__.filter(function(c){return!!c.__c});if(f.every(function(c){return!c.__N}))return!i||i.call(this,u,d,p);var l=a.__c.props!==u;return f.forEach(function(c){if(c.__N){var v=c.__[0];c.__=c.__N,c.__N=void 0,v!==c.__[0]&&(l=!0)}}),i&&i.call(this,u,d,p)||l};H.__f=!0;var i=H.shouldComponentUpdate,r=H.componentWillUpdate;H.componentWillUpdate=function(u,d,p){if(this.__e){var f=i;i=void 0,s(u,d,p),i=f}r&&r.call(this,u,d,p)},H.shouldComponentUpdate=s}return a.__N||a.__}function Dt(t,e){var n=Xs(cn++,3);!K.__s&&yo(n.__H,e)&&(n.__=t,n.u=e,H.__H.__h.push(n))}function $o(t,e){var n=Xs(cn++,7);return yo(n.__H,e)&&(n.__=t(),n.__H=e,n.__h=t),n.__}function Dr(){for(var t;t=ho.shift();)if(t.__P&&t.__H)try{t.__H.__h.forEach(Hn),t.__H.__h.forEach(_s),t.__H.__h=[]}catch(e){t.__H.__h=[],K.__e(e,t.__v)}}K.__b=function(t){H=null,fi&&fi(t)},K.__=function(t,e){t&&e.__k&&e.__k.__m&&(t.__m=e.__k.__m),yi&&yi(t,e)},K.__r=function(t){_i&&_i(t),cn=0;var e=(H=t.__c).__H;e&&(Da===H?(e.__h=[],H.__h=[],e.__.forEach(function(n){n.__N&&(n.__=n.__N),n.u=n.__N=void 0})):(e.__h.forEach(Hn),e.__h.forEach(_s),e.__h=[],cn=0)),Da=H},K.diffed=function(t){gi&&gi(t);var e=t.__c;e&&e.__H&&(e.__H.__h.length&&(ho.push(e)!==1&&mi===K.requestAnimationFrame||((mi=K.requestAnimationFrame)||Er)(Dr)),e.__H.__.forEach(function(n){n.u&&(n.__H=n.u),n.u=void 0})),Da=H=null},K.__c=function(t,e){e.some(function(n){try{n.__h.forEach(Hn),n.__h=n.__h.filter(function(a){return!a.__||_s(a)})}catch(a){e.some(function(s){s.__h&&(s.__h=[])}),e=[],K.__e(a,n.__v)}}),hi&&hi(t,e)},K.unmount=function(t){$i&&$i(t);var e,n=t.__c;n&&n.__H&&(n.__H.__.forEach(function(a){try{Hn(a)}catch(s){e=s}}),n.__H=void 0,e&&K.__e(e,n.__v))};var bi=typeof requestAnimationFrame=="function";function Er(t){var e,n=function(){clearTimeout(a),bi&&cancelAnimationFrame(e),setTimeout(t)},a=setTimeout(n,35);bi&&(e=requestAnimationFrame(n))}function Hn(t){var e=H,n=t.__c;typeof n=="function"&&(t.__c=void 0,n()),H=e}function _s(t){var e=H;t.__c=t.__(),H=e}function yo(t,e){return!t||t.length!==e.length||e.some(function(n,a){return n!==t[a]})}function bo(t,e){return typeof e=="function"?e(t):e}var Ir=Symbol.for("preact-signals");function Ta(){if(Kt>1)Kt--;else{for(var t,e=!1;ze!==void 0;){var n=ze;for(ze=void 0,gs++;n!==void 0;){var a=n.o;if(n.o=void 0,n.f&=-3,!(8&n.f)&&wo(n))try{n.c()}catch(s){e||(t=s,e=!0)}n=a}}if(gs=0,Kt--,e)throw t}}function Pr(t){if(Kt>0)return t();Kt++;try{return t()}finally{Ta()}}var M=void 0;function ko(t){var e=M;M=void 0;try{return t()}finally{M=e}}var ze=void 0,Kt=0,gs=0,Yn=0;function xo(t){if(M!==void 0){var e=t.n;if(e===void 0||e.t!==M)return e={i:0,S:t,p:M.s,n:void 0,t:M,e:void 0,x:void 0,r:e},M.s!==void 0&&(M.s.n=e),M.s=e,t.n=e,32&M.f&&t.S(e),e;if(e.i===-1)return e.i=0,e.n!==void 0&&(e.n.p=e.p,e.p!==void 0&&(e.p.n=e.n),e.p=M.s,e.n=void 0,M.s.n=e,M.s=e),e}}function J(t,e){this.v=t,this.i=0,this.n=void 0,this.t=void 0,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}J.prototype.brand=Ir;J.prototype.h=function(){return!0};J.prototype.S=function(t){var e=this,n=this.t;n!==t&&t.e===void 0&&(t.x=n,this.t=t,n!==void 0?n.e=t:ko(function(){var a;(a=e.W)==null||a.call(e)}))};J.prototype.U=function(t){var e=this;if(this.t!==void 0){var n=t.e,a=t.x;n!==void 0&&(n.x=a,t.e=void 0),a!==void 0&&(a.e=n,t.x=void 0),t===this.t&&(this.t=a,a===void 0&&ko(function(){var s;(s=e.Z)==null||s.call(e)}))}};J.prototype.subscribe=function(t){var e=this;return yn(function(){var n=e.value,a=M;M=void 0;try{t(n)}finally{M=a}},{name:"sub"})};J.prototype.valueOf=function(){return this.value};J.prototype.toString=function(){return this.value+""};J.prototype.toJSON=function(){return this.value};J.prototype.peek=function(){var t=M;M=void 0;try{return this.value}finally{M=t}};Object.defineProperty(J.prototype,"value",{get:function(){var t=xo(this);return t!==void 0&&(t.i=this.i),this.v},set:function(t){if(t!==this.v){if(gs>100)throw new Error("Cycle detected");this.v=t,this.i++,Yn++,Kt++;try{for(var e=this.t;e!==void 0;e=e.x)e.t.N()}finally{Ta()}}}});function _(t,e){return new J(t,e)}function wo(t){for(var e=t.s;e!==void 0;e=e.n)if(e.S.i!==e.i||!e.S.h()||e.S.i!==e.i)return!0;return!1}function So(t){for(var e=t.s;e!==void 0;e=e.n){var n=e.S.n;if(n!==void 0&&(e.r=n),e.S.n=e,e.i=-1,e.n===void 0){t.s=e;break}}}function Ao(t){for(var e=t.s,n=void 0;e!==void 0;){var a=e.p;e.i===-1?(e.S.U(e),a!==void 0&&(a.n=e.n),e.n!==void 0&&(e.n.p=a)):n=e,e.S.n=e.r,e.r!==void 0&&(e.r=void 0),e=a}t.s=n}function ie(t,e){J.call(this,void 0),this.x=t,this.s=void 0,this.g=Yn-1,this.f=4,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}ie.prototype=new J;ie.prototype.h=function(){if(this.f&=-3,1&this.f)return!1;if((36&this.f)==32||(this.f&=-5,this.g===Yn))return!0;if(this.g=Yn,this.f|=1,this.i>0&&!wo(this))return this.f&=-2,!0;var t=M;try{So(this),M=this;var e=this.x();(16&this.f||this.v!==e||this.i===0)&&(this.v=e,this.f&=-17,this.i++)}catch(n){this.v=n,this.f|=16,this.i++}return M=t,Ao(this),this.f&=-2,!0};ie.prototype.S=function(t){if(this.t===void 0){this.f|=36;for(var e=this.s;e!==void 0;e=e.n)e.S.S(e)}J.prototype.S.call(this,t)};ie.prototype.U=function(t){if(this.t!==void 0&&(J.prototype.U.call(this,t),this.t===void 0)){this.f&=-33;for(var e=this.s;e!==void 0;e=e.n)e.S.U(e)}};ie.prototype.N=function(){if(!(2&this.f)){this.f|=6;for(var t=this.t;t!==void 0;t=t.x)t.t.N()}};Object.defineProperty(ie.prototype,"value",{get:function(){if(1&this.f)throw new Error("Cycle detected");var t=xo(this);if(this.h(),t!==void 0&&(t.i=this.i),16&this.f)throw this.v;return this.v}});function it(t,e){return new ie(t,e)}function To(t){var e=t.u;if(t.u=void 0,typeof e=="function"){Kt++;var n=M;M=void 0;try{e()}catch(a){throw t.f&=-2,t.f|=8,Zs(t),a}finally{M=n,Ta()}}}function Zs(t){for(var e=t.s;e!==void 0;e=e.n)e.S.U(e);t.x=void 0,t.s=void 0,To(t)}function Mr(t){if(M!==this)throw new Error("Out-of-order effect");Ao(this),M=t,this.f&=-2,8&this.f&&Zs(this),Ta()}function Te(t,e){this.x=t,this.u=void 0,this.s=void 0,this.o=void 0,this.f=32,this.name=e==null?void 0:e.name}Te.prototype.c=function(){var t=this.S();try{if(8&this.f||this.x===void 0)return;var e=this.x();typeof e=="function"&&(this.u=e)}finally{t()}};Te.prototype.S=function(){if(1&this.f)throw new Error("Cycle detected");this.f|=1,this.f&=-9,To(this),So(this),Kt++;var t=M;return M=this,Mr.bind(this,t)};Te.prototype.N=function(){2&this.f||(this.f|=2,this.o=ze,ze=this)};Te.prototype.d=function(){this.f|=8,1&this.f||Zs(this)};Te.prototype.dispose=function(){this.d()};function yn(t,e){var n=new Te(t,e);try{n.c()}catch(s){throw n.d(),s}var a=n.d.bind(n);return a[Symbol.dispose]=a,a}var No,Rn,Or=typeof window<"u"&&!!window.__PREACT_SIGNALS_DEVTOOLS__,Co=[];yn(function(){No=this.N})();function Ne(t,e){F[t]=e.bind(null,F[t]||function(){})}function Xn(t){if(Rn){var e=Rn;Rn=void 0,e()}Rn=t&&t.S()}function Ro(t){var e=this,n=t.data,a=jr(n);a.value=n;var s=$o(function(){for(var u=e,d=e.__v;d=d.__;)if(d.__c){d.__c.__$f|=4;break}var p=it(function(){var v=a.value.value;return v===0?0:v===!0?"":v||""}),f=it(function(){return!Array.isArray(p.value)&&!so(p.value)}),l=yn(function(){if(this.N=Lo,f.value){var v=p.value;u.__v&&u.__v.__e&&u.__v.__e.nodeType===3&&(u.__v.__e.data=v)}}),c=e.__$u.d;return e.__$u.d=function(){l(),c.call(this)},[f,p]},[]),i=s[0],r=s[1];return i.value?r.peek():r.value}Ro.displayName="ReactiveTextNode";Object.defineProperties(J.prototype,{constructor:{configurable:!0,value:void 0},type:{configurable:!0,value:Ro},props:{configurable:!0,get:function(){return{data:this}}},__b:{configurable:!0,value:1}});Ne("__b",function(t,e){if(typeof e.type=="string"){var n,a=e.props;for(var s in a)if(s!=="children"){var i=a[s];i instanceof J&&(n||(e.__np=n={}),n[s]=i,a[s]=i.peek())}}t(e)});Ne("__r",function(t,e){if(t(e),e.type!==$n){Xn();var n,a=e.__c;a&&(a.__$f&=-2,(n=a.__$u)===void 0&&(a.__$u=n=(function(s,i){var r;return yn(function(){r=this},{name:i}),r.c=s,r})(function(){var s;Or&&((s=n.y)==null||s.call(n)),a.__$f|=1,a.setState({})},typeof e.type=="function"?e.type.displayName||e.type.name:""))),Xn(n)}});Ne("__e",function(t,e,n,a){Xn(),t(e,n,a)});Ne("diffed",function(t,e){Xn();var n;if(typeof e.type=="string"&&(n=e.__e)){var a=e.__np,s=e.props;if(a){var i=n.U;if(i)for(var r in i){var u=i[r];u!==void 0&&!(r in a)&&(u.d(),i[r]=void 0)}else i={},n.U=i;for(var d in a){var p=i[d],f=a[d];p===void 0?(p=Fr(n,d,f),i[d]=p):p.o(f,s)}for(var l in a)s[l]=a[l]}}t(e)});function Fr(t,e,n,a){var s=e in t&&t.ownerSVGElement===void 0,i=_(n),r=n.peek();return{o:function(u,d){i.value=u,r=u.peek()},d:yn(function(){this.N=Lo;var u=i.value.value;r!==u?(r=void 0,s?t[e]=u:u!=null&&(u!==!1||e[4]==="-")?t.setAttribute(e,u):t.removeAttribute(e)):r=void 0})}}Ne("unmount",function(t,e){if(typeof e.type=="string"){var n=e.__e;if(n){var a=n.U;if(a){n.U=void 0;for(var s in a){var i=a[s];i&&i.d()}}}e.__np=void 0}else{var r=e.__c;if(r){var u=r.__$u;u&&(r.__$u=void 0,u.d())}}t(e)});Ne("__h",function(t,e,n,a){(a<3||a===9)&&(e.__$f|=2),t(e,n,a)});je.prototype.shouldComponentUpdate=function(t,e){if(this.__R)return!0;var n=this.__$u,a=n&&n.s!==void 0;for(var s in e)return!0;if(this.__f||typeof this.u=="boolean"&&this.u===!0){var i=2&this.__$f;if(!(a||i||4&this.__$f)||1&this.__$f)return!0}else if(!(a||4&this.__$f)||3&this.__$f)return!0;for(var r in t)if(r!=="__source"&&t[r]!==this.props[r])return!0;for(var u in this.props)if(!(u in t))return!0;return!1};function jr(t,e){return $o(function(){return _(t,e)},[])}var zr=function(t){queueMicrotask(function(){queueMicrotask(t)})};function qr(){Pr(function(){for(var t;t=Co.shift();)No.call(t)})}function Lo(){Co.push(this)===1&&(F.requestAnimationFrame||zr)(qr)}const Hr=["overview","board","activity","council","goals","execution","tasks","agents","ops","trpg"],Do={tab:"overview",params:{},postId:null},Ur={journal:"activity",mdal:"goals"};function ki(t){return!!t&&Hr.includes(t)}function xi(t){if(t)return Ur[t]??t}function hs(t){try{return decodeURIComponent(t)}catch{return t}}function $s(t){const e={};return t&&new URLSearchParams(t).forEach((a,s)=>{e[s]=a}),e}function Kr(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function Eo(t,e){const n=xi(t[0]),a=xi(e.tab),s=ki(n)?n:ki(a)?a:"overview";let i=null;return s==="board"&&(t[0]==="board"&&t[1]==="post"&&t[2]?i=hs(t[2]):t[0]==="post"&&t[1]&&(i=hs(t[1]))),{tab:s,params:e,postId:i}}function Zn(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return Do;const n=hs(e);let a=n,s;if(n.startsWith("?"))a="",s=n.slice(1);else{const u=n.indexOf("?");u>=0&&(a=n.slice(0,u),s=n.slice(u+1))}!s&&a.includes("=")&&!a.includes("/")&&(s=a,a="");const i=$s(s),r=Kr(a);return Eo(r,i)}function Br(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const a=n.slice(1);if(a.length===0)return{...Do,params:$s(e.replace(/^\?/,""))};if(a[0]==="assets"||a[0]==="credits"||a[0]==="lodge")return null;const s=$s(e.replace(/^\?/,""));return Eo(a,s)}function Io(t){const e=t.postId?`board/post/${encodeURIComponent(t.postId)}`:t.tab,n=Object.entries(t.params).filter(([s])=>s!=="tab");if(n.length===0)return`#${e}`;const a=new URLSearchParams(n);return`#${e}?${a.toString()}`}const St=_(Zn(window.location.hash));window.addEventListener("hashchange",()=>{St.value=Zn(window.location.hash)});function pt(t,e){const n={tab:t,params:{},postId:null};window.location.hash=Io(n)}function Wr(t){window.location.hash=`#board/post/${encodeURIComponent(t)}`}function Gr(){if(window.location.hash&&window.location.hash!=="#"){St.value=Zn(window.location.hash);return}const t=Br(window.location.pathname,window.location.search);if(t){St.value=t;const e=Io(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#overview",St.value=Zn(window.location.hash)}const wi="masc_dashboard_sse_session_id",Jr=1e3,Vr=15e3,Et=_(!1),bn=_(0),Po=_(null),Wt=_([]);function Qr(){let t=sessionStorage.getItem(wi);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(wi,t)),t}const Yr=200;function Xr(t,e,n="system",a={}){const s={agent:t,text:e,timestamp:Date.now(),kind:n,...a};Wt.value=[s,...Wt.value].slice(0,Yr)}function ys(t,e=88){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:void 0}function Si(t,e){const n=ys(e);return n?`${t}: ${n}`:`New ${t.toLowerCase()}`}function ut(t,e,n,a,s={}){Xr(t,e,n,{eventType:a,...s})}let xt=null,ye=null,bs=0;function Mo(){ye&&(clearTimeout(ye),ye=null)}function Zr(){if(ye)return;bs++;const t=Math.min(bs,5),e=Math.min(Vr,Jr*Math.pow(2,t));ye=setTimeout(()=>{ye=null,Oo()},e)}function Oo(){Mo(),xt&&(xt.close(),xt=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),a=t.get("token");n&&e.set("agent",n),a&&e.set("token",a),e.set("session_id",Qr());const s=e.toString()?`/sse?${e.toString()}`:"/sse",i=new EventSource(s);xt=i,i.onopen=()=>{xt===i&&(bs=0,Et.value=!0)},i.onerror=()=>{xt===i&&(Et.value=!1,i.close(),xt=null,Zr())},i.onmessage=r=>{try{const u=JSON.parse(r.data);bn.value++,Po.value=u,tl(u)}catch{}}}function tl(t){const e=t.type,n=t.agent??t.author??t.from??t.from_agent??"";switch(e){case"agent_joined":ut(n,"Joined","system","agent_joined");break;case"agent_left":ut(n,"Left","system","agent_left");break;case"broadcast":ut(n,`${(t.message??t.content??"").slice(0,80)}`,"system","broadcast");break;case"task_update":ut(n,`Task: ${t.task_id??""} -> ${t.status??""}`,"tasks","task_update");break;case"board_post":case"masc/board_post":ut(n,Si("Post",t.content??t.message),"board","board_post",{author:t.author??n,preview:ys(t.content??t.message),postId:t.post_id});break;case"board_comment":case"masc/board_comment":ut(n,Si("Comment",t.content??t.message),"board","board_comment",{author:t.author??n,preview:ys(t.content??t.message),postId:t.post_id});break;case"keeper_heartbeat":ut(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`,"keepers","keeper_heartbeat");break;case"keeper_handoff":ut(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`,"keepers","keeper_handoff");break;case"keeper_compaction":ut(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`,"keepers","keeper_compaction");break;case"keeper_guardrail":ut(t.name??n,`Guardrail: ${t.reason??"stopped"}`,"keepers","keeper_guardrail");break;default:ut(n,e,"system","unknown")}}function el(){Mo(),xt&&(xt.close(),xt=null),Et.value=!1}function Fo(){return new URLSearchParams(window.location.search)}function jo(){const t=Fo(),e={},n=t.get("token"),a=t.get("agent")??t.get("agent_name");return n&&(e.Authorization=`Bearer ${n}`),a&&(e["X-MASC-Agent"]=a),e}function zo(){return{...jo(),"Content-Type":"application/json"}}const nl=15e3,qo=3e4,al=6e4,Ai=new Set([408,425,429,500,502,503,504]);class kn extends Error{constructor(n){const a=n.method.toUpperCase(),s=n.timeout===!0,i=s?`${a} ${n.path}: timeout after ${n.timeoutMs??0}ms`:`${a} ${n.path}: ${n.status??"unknown"} ${n.statusText??""}`.trim();super(i);le(this,"method");le(this,"path");le(this,"status");le(this,"statusText");le(this,"timeout");this.name="ApiRequestError",this.method=a,this.path=n.path,this.status=n.status,this.statusText=n.statusText,this.timeout=s}}async function ti(t,e,n){const a=new AbortController,s=setTimeout(()=>a.abort(),n);try{return await fetch(t,{...e,signal:a.signal})}catch(i){if(i instanceof Error&&i.name==="AbortError"){const r=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new kn({method:r,path:t,timeout:!0,timeoutMs:n})}throw i}finally{clearTimeout(s)}}function sl(){var e,n;const t=Fo();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function Pt(t){const e=await ti(t,{headers:jo()},nl);if(!e.ok)throw new kn({method:"GET",path:t,status:e.status,statusText:e.statusText});return e.json()}function il(t){return new Promise(e=>setTimeout(e,t))}function ol(t){const e=t.match(/\b(\d{3})\b/);if(!e)return null;const n=e[1];if(!n)return null;const a=Number.parseInt(n,10);return Number.isFinite(a)?a:null}function rl(t){if(t instanceof kn)return t.timeout||typeof t.status=="number"&&Ai.has(t.status);if(!(t instanceof Error))return!1;if(/timeout after \d+ms/i.test(t.message))return!0;const e=ol(t.message);return e!==null&&Ai.has(e)}async function xn(t,e,n=2){let a=0;for(;;)try{return await e()}catch(s){if(!rl(s)||a>=n)throw s;const i=250*(a+1);console.warn(`[dashboard/api] ${t} failed (attempt ${a+1}), retrying in ${i}ms`,s),await il(i),a+=1}}async function Mt(t,e,n){const a=await ti(t,{method:"POST",headers:{...zo(),...n??{}},body:JSON.stringify(e)},qo);if(!a.ok)throw new kn({method:"POST",path:t,status:a.status,statusText:a.statusText});return a.json()}async function ll(t,e,n,a=qo){const s=await ti(t,{method:"POST",headers:{...zo(),...n??{}},body:JSON.stringify(e)},a);if(!s.ok)throw new kn({method:"POST",path:t,status:s.status,statusText:s.statusText});return s.text()}function cl(t){const e=t.split(`
`).find(a=>a.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function ul(t){var e,n,a,s,i,r,u;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const d=((s=(a=t.result.content)==null?void 0:a[0])==null?void 0:s.text)??"MCP tool call failed";throw new Error(d)}return((u=(r=(i=t.result)==null?void 0:i.content)==null?void 0:r[0])==null?void 0:u.text)??""}async function Q(t,e){const n=await ll("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},al),a=cl(n);return ul(a)}function dl(t="compact"){return Pt(`/api/v1/dashboard?mode=${t}`)}function pl(){return Pt("/api/v1/operator")}function Ho(t){return Mt("/api/v1/operator/action",t)}function vl(t,e){return Mt("/api/v1/operator/confirm",{actor:t,confirm_token:e})}const ml=new Set(["lodge-system","team-session"]);function Se(t){if(typeof t=="string"&&t.trim())return t;if(typeof t!="number"||Number.isNaN(t))return new Date().toISOString();const e=t<1e12?t*1e3:t;return new Date(e).toISOString()}function fl(t){return ml.has(t.trim().toLowerCase())}function _l(t){return t.filter(e=>!fl(e.author))}function gl(t){var s;const e=t.trim(),a=((s=(e.startsWith("[flair:")?e.replace(/^\[flair:[^\]]+\]\s*/i,""):e).split(`
`)[0])==null?void 0:s.trim())||"Untitled post";return a.length<=96?a:`${a.slice(0,93)}...`}function Uo(t){if(!E(t))return null;const e=g(t.id,"").trim(),n=g(t.author,"").trim(),a=g(t.content,"").trim();if(!e||!n)return null;const s=D(t.score,0),i=D(t.votes_up,0),r=D(t.votes_down,0),u=D(t.votes,s||i-r),d=D(t.comment_count,D(t.reply_count,0)),p=(()=>{const h=t.flair;if(typeof h=="string"&&h.trim())return h.trim();if(E(h)){const w=g(h.name,"").trim();if(w)return w}return g(t.flair_name,"").trim()||void 0})(),f=g(t.created_at_iso,"").trim()||Se(t.created_at),l=g(t.updated_at_iso,"").trim()||(t.updated_at!==void 0?Se(t.updated_at):f),v=g(t.title,"").trim()||gl(a);return{id:e,author:n,title:v,content:a,tags:[],votes:u,vote_balance:s,comment_count:d,created_at:f,updated_at:l,flair:p,hearth_count:D(t.hearth_count,0)}}function hl(t){if(!E(t))return null;const e=g(t.id,"").trim(),n=g(t.post_id,"").trim(),a=g(t.author,"").trim();return!e||!a?null:{id:e,post_id:n,author:a,content:g(t.content,""),created_at:Se(t.created_at)}}async function $l(t,e){return xn("fetchBoard",async()=>{const n=new URLSearchParams;t&&n.set("sort_by",t),e!=null&&e.excludeSystem&&n.set("exclude_system","true"),n.set("limit",e!=null&&e.excludeSystem?"150":"100");const a=n.toString(),s=await Pt(`/api/v1/board${a?`?${a}`:""}`),i=Array.isArray(s.posts)?s.posts.map(Uo).filter(u=>u!==null):[];return{posts:e!=null&&e.excludeSystem?_l(i):i}})}async function yl(t){return xn("fetchBoardPost",async()=>{const e=await Pt(`/api/v1/board/${t}?format=flat`),n=E(e.post)?e.post:e,a=Uo(n)??{id:t,author:"unknown",title:"Post",content:"",tags:[],votes:0,comment_count:0,created_at:new Date().toISOString(),updated_at:new Date().toISOString()},i=(Array.isArray(e.comments)?e.comments:[]).map(hl).filter(r=>r!==null);return{...a,comments:i}})}function Ko(t,e){return Mt("/api/v1/tools/masc_board_vote",{post_id:t,direction:e,vote:e,voter:sl()})}function bl(t,e,n){return Mt("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function kl(t){const e=g(t,"").trim().toLowerCase();if(e==="win"||e==="won"||e==="victory")return"victory";if(e==="lose"||e==="lost"||e==="defeat")return"defeat";if(e==="draw"||e==="stalemate"||e==="tie")return"draw"}function V(...t){for(const e of t){const n=g(e,"");if(n.trim())return n.trim()}return""}function Ti(t){const e=kl(V(t.outcome,t.result,t.result_code));if(!e)return;const n=V(t.reason,t.reason_code,t.description,t.detail),a=V(t.summary,t.summary_ko,t.summary_en,t.note),s=V(t.details,t.details_text,t.text,t.note),i=V(t.winner,t.winner_name,t.actor_winner,t.winner_actor),r=V(t.winner_actor_id,t.winner_actor,t.actor_winner_id),u=V(t.raw_reason,t.raw_reason_code,t.error_message),d=(()=>{const l=t.evidence??t.evidence_ids??t.supporting_events??t.event_ids??[];return typeof l=="string"?[l]:Array.isArray(l)?l.map(c=>{if(typeof c=="string")return c.trim();if(E(c)){const v=g(c.summary,"").trim();if(v)return v;const h=g(c.text,"").trim();if(h)return h;const k=g(c.type,"").trim();return k||g(c.event_id,"").trim()}return""}).filter(c=>c.length>0):[]})(),p=(()=>{const l=D(t.turn,Number.NaN);if(Number.isFinite(l))return l;const c=D(t.turn_number,Number.NaN);if(Number.isFinite(c))return c;const v=D(t.current_turn,Number.NaN);if(Number.isFinite(v))return v;const h=D(t.round,Number.NaN);return Number.isFinite(h)?h:void 0})(),f=V(t.phase,t.phase_name,t.current_phase,t.phase_id);return{result:e,reason:n||void 0,summary:a||void 0,details:s||void 0,winner:i||void 0,winner_actor_id:r||void 0,evidence:d.length>0?d:void 0,raw_reason:u||void 0,turn:p,phase:f||void 0}}function xl(t,e){const n=E(t.state)?t.state:{};if(g(n.status,"active").toLowerCase()!=="ended")return;const s=[...e].reverse().find(r=>E(r)?g(r.type,"")==="session.outcome":!1),i=E(n.session_outcome)?n.session_outcome:{};if(E(i)&&Object.keys(i).length>0){const r=Ti(i);if(r)return r}if(E(s))return Ti(E(s.payload)?s.payload:{})}function E(t){return typeof t=="object"&&t!==null}function g(t,e=""){return typeof t=="string"?t:e}function D(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function Ut(t){if(typeof t=="number"&&Number.isFinite(t))return Math.trunc(t);if(typeof t=="string"){const e=Number.parseInt(t.trim(),10);if(Number.isFinite(e))return e}}function ks(t,e=!1){return typeof t=="boolean"?t:e}function Le(t){return Array.isArray(t)?t.map(e=>{if(typeof e=="string")return e.trim();if(E(e)){const n=g(e.name,"").trim(),a=g(e.id,"").trim(),s=g(e.skill,"").trim();return n||a||s}return""}).filter(e=>e.length>0):[]}function wl(t){const e={};if(!E(t)&&!Array.isArray(t))return e;if(E(t))return Object.entries(t).forEach(([n,a])=>{const s=n.trim(),i=g(a,"").trim();!s||!i||(e[s]=i)}),e;for(const n of t){if(!E(n))continue;const a=V(n.to,n.target,n.actor_id,n.name,n.id),s=V(n.relationship,n.relation,n.type,n.kind);!a||!s||(e[a]=s)}return e}function Sl(t,e,n){if(t==="dm"||t==="player"||t==="npc")return t;const a=e.trim().toLowerCase();return a==="dm"||a.startsWith("dm-")?"dm":a.startsWith("npc-")||a.startsWith("enemy-")||a.startsWith("mob-")?"npc":/^p\d+$/i.test(a)||a.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function rt(t,e,n,a=0){const s=t[e];if(typeof s=="number"&&Number.isFinite(s))return s;if(n){const i=t[n];if(typeof i=="number"&&Number.isFinite(i))return i}return a}const Al=new Set(["str","dex","con","int","wis","cha","strength","dexterity","constitution","intelligence","wisdom","charisma","hp","max_hp","mp","max_mp","level","xp"]);function Tl(t){const e=E(t.stats)?t.stats:{},n={};return Object.entries(e).forEach(([a,s])=>{const i=a.trim();i&&(Al.has(i.toLowerCase())||typeof s=="number"&&Number.isFinite(s)&&(n[i]=s))}),n}function Nl(t,e){if(t!=="dice.rolled")return;const n=D(e.raw_d20,0),a=D(e.total,0),s=D(e.bonus,0),i=g(e.action,"roll"),r=D(e.dc,0);return{notation:r>0?`${i} (DC ${r})`:i,rolls:n>0?[n]:[],total:a,modifier:s}}function Cl(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function Rl(t){const e=t.trim().toLowerCase();return e?e.startsWith("dice.")?"dice":e.startsWith("combat.")||e.includes(".attack")||e.includes(".damage")?"combat":e.includes("actor.")?"actor":e.includes("turn.")||e==="turn.started"||e==="phase.changed"?"turn":e.includes("join.")?"join":e.includes("memory")?"memory":e.includes("world.")?"world":e.includes("narration")?"story":"meta":"meta"}function Ll(t,e,n,a){const s=n||e||g(a.actor_id,"")||g(a.actor_name,"");switch(t){case"turn.action.proposed":{const i=g(a.proposed_action,g(a.reply,""));return i?`${s||"actor"}: ${i}`:"Action proposed"}case"turn.action.resolved":{const i=g(a.reply,g(a.result,""));return i?`Resolved: ${i}`:"Action resolved"}case"narration.posted":return g(a.reply,g(a.content,g(a.text,"Narration")));case"dice.rolled":{const i=g(a.action,"roll"),r=D(a.total,0),u=D(a.dc,0),d=g(a.label,""),p=s||"actor",f=u>0?` vs DC ${u}`:"",l=d?` (${d})`:"";return`${p} ${i}: ${r}${f}${l}`}case"turn.started":return`Turn ${D(a.turn,1)} started`;case"phase.changed":return`Phase: ${g(a.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${g(a.name,E(a.actor)?g(a.actor.name,s||"unknown"):s||"unknown")}`;case"actor.claimed":return`${g(a.keeper_name,g(a.keeper,"keeper"))} claimed ${s||"actor"}`;case"actor.released":return`${g(a.keeper_name,g(a.keeper,"keeper"))} released ${s||"actor"}`;case"join.window.opened":return`Join window opened (turn ${D(a.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${D(a.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${s||g(a.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${s||g(a.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${g(a.reason_code,"unknown")}`;case"memory.signal":{const i=E(a.entity_refs)?a.entity_refs:{},r=g(i.requested_tier,""),u=g(i.effective_tier,""),d=ks(i.guardrail_applied,!1),p=g(a.summary_en,g(a.summary_ko,"Memory signal"));if(!r&&!u)return p;const f=r&&u?`${r}->${u}`:u||r;return`${p} [${f}${d?" (guardrail)":""}]`}case"world.event":{if(g(a.event_type,"")==="canon.check"){const r=g(a.status,"unknown"),u=g(a.contract_id,"n/a");return`Canon ${r}: ${u}`}return g(a.description,g(a.summary,"World event"))}case"combat.attack":return g(a.summary,g(a.result,"Attack resolved"));case"combat.defense":return g(a.summary,g(a.result,"Defense resolved"));case"session.outcome":return g(a.summary,g(a.outcome,"Session ended"));default:{const i=Cl(a);return i?`${t}: ${i}`:t}}}function Dl(t,e){const n=E(t)?t:{},a=g(n.type,"event"),s=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",i=g(n.actor_name,"").trim()||e[s]||g(E(n.payload)?n.payload.actor_name:"",""),r=E(n.payload)?n.payload:{},u=g(n.ts,g(n.timestamp,new Date().toISOString())),d=g(n.phase,g(r.phase,"")),p=g(n.category,"");return{type:a,actor:i||s||g(r.actor_name,""),actor_id:s||g(r.actor_id,""),actor_name:i,seq:n.seq,room_id:g(n.room_id,""),phase:d||void 0,category:p||Rl(a),visibility:g(n.visibility,g(r.visibility,"public")),event_id:g(n.event_id,""),content:Ll(a,s,i,r),dice_roll:Nl(a,r),timestamp:u}}function El(t,e,n){var X,ot;const a=g(t.room_id,"")||n||"default",s=E(t.state)?t.state:{},i=E(s.party)?s.party:{},r=E(s.actor_control)?s.actor_control:{},u=E(s.join_gate)?s.join_gate:{},d=E(s.contribution_ledger)?s.contribution_ledger:{},p=Object.entries(i).map(([I,U])=>{const $=E(U)?U:{},Qt=rt($,"max_hp",void 0,10),Re=rt($,"hp",void 0,Qt),An=rt($,"max_mp",void 0,0),Tn=rt($,"mp",void 0,0),Nn=rt($,"level",void 0,1),m=rt($,"xp",void 0,0),T=ks($.alive,Re>0),P=r[I],G=typeof P=="string"?P:void 0,et=Sl($.role,I,G),Z=Ut($.generation),B=V($.joined_at,$.joinedAt,$.started_at,$.startedAt),W=V($.claimed_at,$.claimedAt,$.assigned_at,$.assignedAt,$.assigned_time),tt=V($.last_seen,$.lastSeen,$.last_seen_at,$.lastSeenAt,$.last_active,$.lastActive),Ot=V($.scene,$.current_scene,$.currentScene,$.world_scene,$.scene_name,$.sceneName),Ft=V($.location,$.current_location,$.currentLocation,$.position,$.zone,$.area);return{id:I,name:g($.name,I),role:et,keeper:G,archetype:g($.archetype,""),persona:g($.persona,""),portrait:g($.portrait,"")||void 0,background:g($.background,"")||void 0,traits:Le($.traits),skills:Le($.skills),stats_raw:Tl($),status:T?"active":"dead",generation:Z,joined_at:B||void 0,claimed_at:W||void 0,last_seen:tt||void 0,scene:Ot||void 0,location:Ft||void 0,inventory:Le($.inventory),notes:Le($.notes),relationships:wl($.relationships),stats:{hp:Re,max_hp:Qt,mp:Tn,max_mp:An,level:Nn,xp:m,strength:rt($,"strength","str",10),dexterity:rt($,"dexterity","dex",10),constitution:rt($,"constitution","con",10),intelligence:rt($,"intelligence","int",10),wisdom:rt($,"wisdom","wis",10),charisma:rt($,"charisma","cha",10)}}}),f=p.filter(I=>I.status!=="dead"),l=xl(t,e),c={phase_open:ks(u.phase_open,!0),min_points:D(u.min_points,3),window:g(u.window,"round_boundary_only"),last_opened_turn:typeof u.last_opened_turn=="number"?u.last_opened_turn:null,last_closed_turn:typeof u.last_closed_turn=="number"?u.last_closed_turn:null},v=Object.entries(d).map(([I,U])=>{const $=E(U)?U:{};return{actor_id:I,score:D($.score,0),last_reason:g($.last_reason,"")||null,reasons:Le($.reasons)}}),h=p.reduce((I,U)=>(I[U.id]=U.name,I),{}),k=e.map(I=>Dl(I,h)),w=D(s.turn,1),C=g(s.phase,"round"),A=g(s.map,""),O=E(s.world)?s.world:{},S=A||g(O.ascii_map,g(O.map,"")),R=k.filter((I,U)=>{const $=e[U];if(!E($))return!1;const Qt=E($.payload)?$.payload:{};return D(Qt.turn,-1)===w}),Y=(R.length>0?R:k).slice(-12),gt=g(s.status,"active");return{session:{id:a,room:a,status:gt==="ended"?"ended":gt==="paused"?"paused":"active",round:w,actors:f,created_at:((X=k[0])==null?void 0:X.timestamp)??new Date().toISOString()},current_round:{round_number:w,phase:C,events:Y,timestamp:((ot=k[k.length-1])==null?void 0:ot.timestamp)??new Date().toISOString()},map:S||void 0,join_gate:c,contribution_ledger:v,outcome:l,party:f,story_log:k,history:[]}}async function Il(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await Pt(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function Pl(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,a]=await Promise.all([Pt(`/api/v1/trpg/state${e}`),Il(t)]);return El(n,a,t)}function Ml(t){return Mt("/api/v1/trpg/rounds/run",{room_id:t})}function Ol(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function Fl(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),Mt("/api/v1/trpg/dice/roll",e)}function jl(t,e){const n=Ol();return Mt("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}function zl(t,e){var s;const n=(s=e.idempotencyKey)==null?void 0:s.trim(),a={room_id:t};return e.actor_id&&e.actor_id.trim()&&(a.actor_id=e.actor_id.trim()),e.name&&e.name.trim()&&(a.name=e.name.trim()),e.role&&(a.role=e.role),e.archetype&&e.archetype.trim()&&(a.archetype=e.archetype.trim()),e.persona&&e.persona.trim()&&(a.persona=e.persona.trim()),e.portrait&&e.portrait.trim()&&(a.portrait=e.portrait.trim()),e.background&&e.background.trim()&&(a.background=e.background.trim()),e.hp!=null&&(a.hp=e.hp),e.max_hp!=null&&(a.max_hp=e.max_hp),e.alive!=null&&(a.alive=e.alive),Array.isArray(e.traits)&&e.traits.length>0&&(a.traits=e.traits),Array.isArray(e.skills)&&e.skills.length>0&&(a.skills=e.skills),Array.isArray(e.inventory)&&e.inventory.length>0&&(a.inventory=e.inventory),e.stats&&Object.keys(e.stats).length>0&&(a.stats=e.stats),n&&(a.idempotency_key=n),Mt("/api/v1/trpg/actors/spawn",a,n?{"Idempotency-Key":n}:void 0)}function ql(t,e,n){return Mt("/api/v1/trpg/actors/claim",{room_id:t,actor_id:e,keeper:n})}async function Hl(t,e,n){const a=await Q("trpg.join.eligibility",{room_id:t,actor_id:e,...n?{keeper_name:n}:{}});return JSON.parse(a)}async function Ul(t){const e=await Q("trpg.mid_join.request",t);return JSON.parse(e)}async function Bo(t,e){await Q("masc_broadcast",{agent_name:t,message:e})}async function Kl(t,e,n=1){await Q("masc_add_task",{title:t,description:e,priority:n})}async function Bl(t){return Q("masc_join",{agent_name:t})}async function Wo(t){await Q("masc_leave",{agent_name:t})}async function Wl(t){await Q("masc_heartbeat",{agent_name:t})}async function Gl(t=40){return(await Q("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function Jl(t,e=20){return Q("masc_task_history",{task_id:t,limit:e})}async function Vl(){return xn("fetchDebates",async()=>{const t=await Pt("/api/v1/council/debates?limit=100");return Array.isArray(t.debates)?t.debates.map(e=>{if(!E(e))return null;const n=g(e.id,"").trim(),a=g(e.topic,"").trim();return!n||!a?null:{id:n,topic:a,status:g(e.status,"open"),argument_count:D(e.argument_count,0),created_at:Se(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]})}async function Ql(){return xn("fetchCouncilSessions",async()=>{const t=await Pt("/api/v1/council/sessions?limit=100");return Array.isArray(t.sessions)?t.sessions.map(e=>{if(!E(e))return null;const n=g(e.id,"").trim(),a=g(e.topic,"").trim();return!n||!a?null:{id:n,topic:a,initiator:g(e.initiator,"system"),votes:D(e.votes,0),quorum:D(e.quorum,0),state:g(e.state,"open"),created_at:Se(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]})}async function Yl(t){const e=await Q("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}async function Xl(t){return xn("fetchDebateStatus",async()=>{const e=encodeURIComponent(t),n=await Pt(`/api/v1/council/debates/${e}/summary`);if(!E(n))return null;const a=g(n.id,"").trim();return a?{id:a,topic:g(n.topic,""),status:g(n.status,"open"),support_count:D(n.support_count,0),oppose_count:D(n.oppose_count,0),neutral_count:D(n.neutral_count,0),total_arguments:D(n.total_arguments,0),created_at:Se(n.created_at_iso??n.created_at),summary_text:g(n.summary_text,"")}:null})}function Zl(t,e,n){return Q("masc_keeper_msg",{name:t,message:e})}function tc(t){const e=g(t,"").trim().toLowerCase();return e.startsWith("error")?"error":e==="running"||e==="completed"||e==="stopped"?e:"running"}function ec(t){return E(t)?{iteration:Ut(t.iteration)??0,metric_before:D(t.metric_before,0),metric_after:D(t.metric_after,0),delta:D(t.delta,0),changes:g(t.changes,""),failed_attempts:g(t.failed_attempts,""),next_suggestion:g(t.next_suggestion,""),elapsed_ms:Ut(t.elapsed_ms)??0,cost_usd:typeof t.cost_usd=="number"&&Number.isFinite(t.cost_usd)?t.cost_usd:null}:null}function nc(t){if(!E(t))return null;const e=g(t.loop_id,"").trim();if(!e)return null;const n=Array.isArray(t.history)?t.history.map(ec).filter(a=>a!==null):[];return{loop_id:e,profile:g(t.profile,"custom"),status:tc(t.status),current_iteration:Ut(t.iteration)??Ut(t.current_iteration)??0,max_iterations:Ut(t.max_iterations)??0,baseline_metric:D(t.baseline_metric,0),current_metric:D(t.current_metric,D(t.baseline_metric,0)),target:g(t.target,""),stagnation_streak:Ut(t.stagnation_streak)??0,stagnation_limit:Ut(t.stagnation_limit)??0,elapsed_seconds:D(t.elapsed_seconds,0),history:n}}function Ni(t){return t.trim().toLowerCase().includes("no mdal loop running")}async function ac(){try{const t=await Q("masc_mdal_status",{}),e=JSON.parse(t),n=E(e)?g(e.error,"").trim():"";if(Ni(n))return{state:"idle"};if(n)return{state:"error",message:n};const a=nc(e);return a?{state:"ready",loop:a}:{state:"error",message:"Unexpected MDAL payload"}}catch(t){const e=t instanceof Error?t.message:"Unknown MDAL fetch error";return Ni(e)?{state:"idle"}:{state:"error",message:e}}}async function sc(){try{const t=await Q("masc_goal_list",{});if(typeof t=="string"){const e=JSON.parse(t);return Array.isArray(e)?e:e.goals??[]}return Array.isArray(t)?t:t.goals??[]}catch{return[]}}const Jt=_([]),Tt=_([]),se=_([]),ft=_([]),Vt=_(null),Fe=_(null),xs=_(new Map),It=_([]),un=_("hot"),Zt=_(!0),Go=_(null),Rt=_(""),dn=_([]),_e=_(!1),vt=_(new Map),Un=_("unknown"),ws=_(null),Ss=_(!1),pn=_(!1),As=_(!1),ge=_(!1),ic=_(null),Ts=_(null),Jo=_(null),Vo=_(null),oc=it(()=>Jt.value.filter(t=>t.status==="active"||t.status==="idle")),Qo=it(()=>{const t=Tt.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}});function rc(t){var i;const e=((i=t.status)==null?void 0:i.toLowerCase())??"";if(e==="offline"||e==="inactive")return"offline";const n=t.metrics_series;if(!n||n.length===0)return"idle";const a=n[n.length-1];if(!a)return"idle";if(a.is_handoff)return"handoff-imminent";if(a.is_compaction)return"compacting";const s=a.context_ratio;return s>.85?"handoff-imminent":s>.7?"preparing":s>.5?"compacting":"active"}const Yo=it(()=>{const t=new Map;for(const e of ft.value)t.set(e.name,rc(e));return t}),lc=12e4;function cc(t,e){const n=e.get(t.name);if(n!=null)return n;const a=t.last_heartbeat?Date.parse(t.last_heartbeat):Number.NaN;if(!Number.isNaN(a))return a;const s=[t.last_turn_ago_s,t.last_proactive_ago_s,t.last_handoff_ago_s,t.last_compaction_ago_s].find(i=>typeof i=="number"&&Number.isFinite(i)&&i>=0);return typeof s=="number"?Date.now()-s*1e3:null}const Xo=it(()=>{const t=Date.now(),e=new Set,n=xs.value;for(const a of ft.value){const s=cc(a,n);s!=null&&t-s>lc&&e.add(a.name)}return e}),ta={},uc=5e3;function ea(){delete ta.compact,delete ta.full}function mt(t){return typeof t=="object"&&t!==null}function x(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function L(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function qe(t){if(!Array.isArray(t))return;const e=t.filter(n=>typeof n=="string"&&n.trim()!=="");return e.length>0?e:void 0}function Zo(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="idle"||e==="inactive"||e==="offline"?e:e==="busy"||e==="in_progress"||e==="claimed"?"active":"offline"}function dc(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function pc(t){if(!mt(t))return null;const e=x(t.name);return e?{name:e,status:Zo(t.status),current_task:x(t.current_task)??null,last_seen:x(t.last_seen),emoji:x(t.emoji),koreanName:x(t.koreanName)??x(t.korean_name),model:x(t.model),traits:qe(t.traits),interests:qe(t.interests),activityLevel:L(t.activityLevel)??L(t.activity_level),primaryValue:x(t.primaryValue)??x(t.primary_value)}:null}function vc(t){if(!mt(t))return null;const e=x(t.id),n=x(t.title);return!e||!n?null:{id:e,title:n,status:dc(t.status),priority:L(t.priority),assignee:x(t.assignee),description:x(t.description),created_at:x(t.created_at),updated_at:x(t.updated_at)}}function mc(t){if(!mt(t))return null;const e=x(t.from)??x(t.from_agent)??"system",n=x(t.content)??"",a=x(t.timestamp)??new Date().toISOString();return{id:x(t.id),seq:L(t.seq),from:e,content:n,timestamp:a,type:x(t.type)}}function fc(t){return Array.isArray(t)?t.map(e=>{if(!mt(e))return null;const n=L(e.ts_unix);if(n==null)return null;const a=mt(e.handoff)?e.handoff:null;return{ts:n,context_ratio:L(e.context_ratio)??0,context_tokens:L(e.context_tokens)??0,context_max:L(e.context_max)??0,latency_ms:L(e.latency_ms)??0,generation:L(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:a!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:L(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:L(e.cost_usd)??0,handoff_to_model:a&&typeof a.to_model=="string"?a.to_model:null,handoff_new_generation:a?L(a.new_generation)??null:null}}).filter(e=>e!==null):[]}function _c(t){return(Array.isArray(t)?t:mt(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(n=>{if(!mt(n))return null;const a=mt(n.agent)?n.agent:null,s=mt(n.context)?n.context:null,i=mt(n.metrics_window)?n.metrics_window:void 0,r=x(n.name);if(!r)return null;const u=L(n.context_ratio)??L(s==null?void 0:s.context_ratio),d=x(n.status)??x(a==null?void 0:a.status)??"offline",p=Zo(d),f=x(n.model)??x(n.active_model)??x(n.primary_model),l=qe(n.skill_secondary),c=s?{source:x(s.source),context_ratio:L(s.context_ratio),context_tokens:L(s.context_tokens),context_max:L(s.context_max),message_count:L(s.message_count),has_checkpoint:typeof s.has_checkpoint=="boolean"?s.has_checkpoint:void 0}:void 0,v=a?{name:x(a.name),status:x(a.status),current_task:x(a.current_task)??null,last_seen:x(a.last_seen)}:void 0,h=fc(n.metrics_series);return{name:r,emoji:x(n.emoji),koreanName:x(n.koreanName)??x(n.korean_name),agent_name:x(n.agent_name),trace_id:x(n.trace_id),model:f,primary_model:x(n.primary_model),active_model:x(n.active_model),next_model_hint:x(n.next_model_hint)??null,status:p,last_heartbeat:x(n.last_heartbeat)??x(a==null?void 0:a.last_seen),generation:L(n.generation),turn_count:L(n.turn_count)??L(n.total_turns),keeper_age_s:L(n.keeper_age_s),last_turn_ago_s:L(n.last_turn_ago_s),last_handoff_ago_s:L(n.last_handoff_ago_s),last_compaction_ago_s:L(n.last_compaction_ago_s),last_proactive_ago_s:L(n.last_proactive_ago_s),context_ratio:u,context_tokens:L(n.context_tokens)??L(s==null?void 0:s.context_tokens),context_max:L(n.context_max)??L(s==null?void 0:s.context_max),context_source:x(n.context_source)??x(s==null?void 0:s.source),context:c,traits:qe(n.traits),interests:qe(n.interests),primaryValue:x(n.primaryValue)??x(n.primary_value),activityLevel:L(n.activityLevel)??L(n.activity_level),memory_recent_note:x(n.memory_recent_note)??null,conversation_tail_count:L(n.conversation_tail_count),k2k_count:L(n.k2k_count),handoff_count_total:L(n.handoff_count_total)??L(n.trace_history_count),compaction_count:L(n.compaction_count),last_compaction_saved_tokens:L(n.last_compaction_saved_tokens),skill_primary:x(n.skill_primary)??null,skill_secondary:l,skill_reason:x(n.skill_reason)??null,metrics_series:h.length>0?h:void 0,metrics_window:i,agent:v}}).filter(n=>n!==null)}async function wn(t="full"){var a,s,i;const e=Date.now(),n=ta[t];if(!(n&&e-n.time<uc)){Ss.value=!0;try{const r=await dl(t);ta[t]={data:r,time:e},Jt.value=(Array.isArray((a=r.agents)==null?void 0:a.agents)?r.agents.agents:[]).map(pc).filter(u=>u!==null),Tt.value=(Array.isArray((s=r.tasks)==null?void 0:s.tasks)?r.tasks.tasks:[]).map(vc).filter(u=>u!==null),se.value=(Array.isArray((i=r.messages)==null?void 0:i.messages)?r.messages.messages:[]).map(mc).filter(u=>u!==null),ft.value=_c(r.keepers),Vt.value=mt(r.status)?r.status:null,Fe.value=r.perpetual??null,ic.value=new Date().toISOString()}catch(r){console.error("Dashboard fetch error:",r)}finally{Ss.value=!1}}}async function At(){pn.value=!0;try{const t=await $l(un.value,{excludeSystem:Zt.value});It.value=t.posts??[],Ts.value=new Date().toISOString()}catch(t){console.error("Board fetch error:",t)}finally{pn.value=!1}}async function Lt(){var t;As.value=!0;try{const e=Rt.value||((t=Vt.value)==null?void 0:t.room)||"default";Rt.value||(Rt.value=e);const n=await Pl(e);Go.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{As.value=!1}}async function He(){_e.value=!0;try{const t=await sc();dn.value=Array.isArray(t)?t:[],Jo.value=new Date().toISOString()}catch(t){console.error("Goals fetch error:",t)}finally{_e.value=!1}}async function Ue(){const t=++Pa;ge.value=!0;try{const e=await ac();if(t!==Pa)return;if(e.state==="error"){Un.value="error",ws.value=e.message;return}if(Vo.value=new Date().toISOString(),ws.value=null,e.state==="idle"){Un.value="idle";const i=new Map(vt.value);for(const[r,u]of i.entries())u.status==="running"&&i.set(r,{...u,status:"stopped"});vt.value=i;return}const n=e.loop;Un.value="ready";const a=new Map(vt.value),s=a.get(n.loop_id);a.set(n.loop_id,{...s??{},...n,history:n.history.length>0?n.history:(s==null?void 0:s.history)??[]}),vt.value=a}catch(e){console.error("MDAL fetch error:",e)}finally{t===Pa&&(ge.value=!1)}}let Ea=null,Ia=null,Pa=0;function gc(){return Po.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map(xs.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),xs.value=n}if(ea(),Ea||(Ea=setTimeout(()=>{wn(),Ea=null},500)),(e.type==="board_post"||e.type==="masc/board_post"||e.type==="board_comment"||e.type==="masc/board_comment")&&(Ia||(Ia=setTimeout(()=>{At(),Ia=null},500))),(e.type==="keeper_handoff"||e.type==="keeper_compaction"||e.type==="keeper_guardrail")&&ea(),e.type==="mdal_started"&&e.loop_id){const n=new Map(vt.value);n.set(e.loop_id,{...n.get(e.loop_id)??{},loop_id:e.loop_id,profile:e.profile??"custom",status:"running",current_iteration:e.iteration??0,max_iterations:0,baseline_metric:e.baseline??0,current_metric:e.baseline??0,target:e.target??"",stagnation_streak:0,stagnation_limit:0,elapsed_seconds:0,history:[]}),vt.value=n}if(e.type==="mdal_iteration"&&e.loop_id){const n=new Map(vt.value),a=e.metric_before??e.metric_after??0,s=e.metric_after??a,i=n.get(e.loop_id)??{loop_id:e.loop_id,profile:e.profile??"unknown",status:"running",current_iteration:e.iteration??0,max_iterations:0,baseline_metric:a,current_metric:s,target:e.target??"",stagnation_streak:0,stagnation_limit:0,elapsed_seconds:0,history:[]},r={iteration:e.iteration??0,metric_before:a,metric_after:s,delta:e.delta??0,changes:"",failed_attempts:"",next_suggestion:"",elapsed_ms:0,cost_usd:null};n.set(e.loop_id,{...i,current_iteration:e.iteration??i.current_iteration,current_metric:s,history:[r,...i.history]}),vt.value=n}if((e.type==="mdal_completed"||e.type==="mdal_stopped")&&e.loop_id){const n=new Map(vt.value),a=n.get(e.loop_id)??{loop_id:e.loop_id,profile:e.profile??"unknown",status:"running",current_iteration:e.iteration??0,max_iterations:0,baseline_metric:e.baseline??e.metric_before??e.metric_after??0,current_metric:e.metric_after??e.metric_before??e.baseline??0,target:e.target??"",stagnation_streak:0,stagnation_limit:0,elapsed_seconds:0,history:[]};n.set(e.loop_id,{...a,current_iteration:e.iteration??a.current_iteration,current_metric:e.metric_after??a.current_metric,status:e.type==="mdal_completed"?"completed":"stopped"}),vt.value=n}}})}let Ke=null;function hc(){Ke||(Ke=setInterval(()=>{ea(),wn()},1e4))}function $c(){Ke&&(clearInterval(Ke),Ke=null)}function b({title:t,class:e,children:n}){return o`
    <div class="card ${e??""}">
      ${t?o`<div class="card-title">${t}</div>`:null}
      ${n}
    </div>
  `}function _t({status:t,label:e}){return o`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??t}
    </span>
  `}function yc(t){const e=Date.now(),n=typeof t=="number"?t<1e12?t*1e3:t:new Date(t).getTime(),a=Math.floor((e-n)/1e3);if(a<60)return`${a}s ago`;const s=Math.floor(a/60);if(s<60)return`${s}m ago`;const i=Math.floor(s/60);return i<24?`${i}h ago`:`${Math.floor(i/24)}d ago`}function j({timestamp:t}){const e=yc(t),n=typeof t=="string"?t:new Date(t<1e12?t*1e3:t).toISOString();return o`<span class="time-ago" title=${n}>${e}</span>`}function Yt(t){return(t??"").trim().toLowerCase()}function nt(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function Kn(t,e=88){const n=t.replace(/\s+/g," ").trim();return n&&(n.length>e?`${n.slice(0,e-3)}...`:n)}function Ln(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function De(t){return t.last_heartbeat??Ln(t.last_turn_ago_s)??Ln(t.last_proactive_ago_s)??Ln(t.last_handoff_ago_s)??Ln(t.last_compaction_ago_s)}function bc(t){const e=t.title.trim();return e||Kn(t.content)}function kc(t){const e=t.generation??"?",n=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return t.last_heartbeat?`Heartbeat gen=${e} ctx=${n}`:`Keeper snapshot gen=${e} ctx=${n}`}function vn(t,e,n,a,s={}){var O;const i=Yt(t),r=e.filter(S=>Yt(S.assignee)===i&&(S.status==="claimed"||S.status==="in_progress")).length,u=n.filter(S=>Yt(S.from)===i).sort((S,R)=>nt(R.timestamp)-nt(S.timestamp))[0],d=a.filter(S=>Yt(S.agent)===i||Yt(S.author)===i).sort((S,R)=>nt(R.timestamp)-nt(S.timestamp))[0],p=(s.boardPosts??[]).filter(S=>Yt(S.author)===i).sort((S,R)=>nt(R.updated_at||R.created_at)-nt(S.updated_at||S.created_at))[0],f=(s.keepers??[]).filter(S=>Yt(S.name)===i&&De(S)!==null).sort((S,R)=>nt(De(R)??0)-nt(De(S)??0))[0],l=u?nt(u.timestamp):0,c=d?nt(d.timestamp):0,v=p?nt(p.updated_at||p.created_at):0,h=f?nt(De(f)??0):0,k=s.lastSeen?nt(s.lastSeen):0,w=((O=s.currentTask)==null?void 0:O.trim())||(r>0?`${r} claimed tasks`:null);if(l===0&&c===0&&v===0&&h===0&&k===0)return{activeAssignedCount:r,lastActivityAt:null,lastActivityText:w};const A=[u?{timestamp:u.timestamp,ts:l,text:Kn(u.content)}:null,p?{timestamp:p.updated_at||p.created_at,ts:v,text:`Post: ${Kn(bc(p))}`}:null,f?{timestamp:De(f),ts:h,text:kc(f)}:null,d?{timestamp:new Date(d.timestamp).toISOString(),ts:c,text:Kn(d.text)}:null].filter(S=>S!==null).sort((S,R)=>R.ts-S.ts)[0];return A&&A.ts>=k?{activeAssignedCount:r,lastActivityAt:A.timestamp,lastActivityText:A.text}:{activeAssignedCount:r,lastActivityAt:s.lastSeen??null,lastActivityText:w??"Presence heartbeat"}}const ei=_(null);function na(t){ei.value=t}function Ci(){ei.value=null}const pe=[{level:"L1_Reactive",label:"L1 Reactive",color:"#6b7280"},{level:"L2_Suggestive",label:"L2 Suggestive",color:"#3b82f6"},{level:"L3_Guided",label:"L3 Guided",color:"#f59e0b"},{level:"L4_Autonomous",label:"L4 Autonomous",color:"#f97316"},{level:"L5_Independent",label:"L5 Independent",color:"#ef4444"}];function xc(t){if(!t)return 0;const e=pe.findIndex(n=>n.level===t);return e>=0?e:0}function wc({keeper:t}){const e=xc(t.autonomy_level),n=pe[e]??pe[0];if(!n)return null;const a=(e+1)/pe.length*100;return o`
    <div class="keeper-signal-list">
      <div style="margin-bottom:8px;">
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:4px;">
          <span style="font-size:13px; font-weight:600; color:${n.color};">${n.label}</span>
          <span style="font-size:11px; color:#888;">${e+1} / ${pe.length}</span>
        </div>
        <div style="width:100%; height:6px; background:#1a1a2e; border-radius:3px; overflow:hidden;">
          <div style="width:${a}%; height:100%; background:${n.color}; border-radius:3px; transition:width 0.3s;"></div>
        </div>
        <div style="display:flex; justify-content:space-between; margin-top:2px;">
          ${pe.map((s,i)=>o`
            <span style="width:8px; height:8px; border-radius:50%; background:${i<=e?s.color:"#333"}; display:inline-block;"></span>
          `)}
        </div>
      </div>
      <div class="keeper-signal-row">
        <span>Autonomous actions</span>
        <strong>${t.autonomous_action_count??0}</strong>
      </div>
      ${t.last_autonomous_action_at?o`<div class="keeper-signal-row">
            <span>Last autonomous action</span>
            <strong><${j} timestamp=${t.last_autonomous_action_at} /></strong>
          </div>`:null}
      ${t.active_goal_ids&&t.active_goal_ids.length>0?o`<div class="keeper-signal-row">
            <span>Active goals</span>
            <strong>${t.active_goal_ids.length}</strong>
          </div>`:null}
    </div>
  `}function Bn(t){return t?t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}K`:String(t):"—"}function Sc({keeper:t}){const e=t.metrics_series??[],n=e[e.length-1],a=(n==null?void 0:n.cost_usd)!=null?`$${n.cost_usd.toFixed(4)}`:"—",s=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return o`
    <div class="keeper-kpis">
      ${s.map(i=>o`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${i.label}</div>
          <div class="keeper-kpi-value">${i.value}</div>
          ${i.hint?o`<div class="keeper-kpi-hint">${i.hint}</div>`:null}
        </div>
      `)}
      <div class="kpi-tile">
        <div class="kpi-value">${Bn(t.context_tokens)}</div>
        <div class="kpi-label">Tokens</div>
      </div>
      <div class="kpi-tile">
        <div class="kpi-value">${t.handoff_count_total??"—"}</div>
        <div class="kpi-label">Handoffs</div>
      </div>
      <div class="kpi-tile">
        <div class="kpi-value">${t.compaction_count??"—"}</div>
        <div class="kpi-label">Compactions</div>
      </div>
      <div class="kpi-tile">
        <div class="kpi-value">${a}</div>
        <div class="kpi-label">Cost (USD)</div>
      </div>
    </div>
  `}function Ac({keeper:t}){var f,l;const e=t.metrics_series??[];if(e.length<2){const c=(((f=t.context)==null?void 0:f.context_ratio)??0)*100,v=c>85?"#ef4444":c>70?"#f59e0b":"#22c55e";return o`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${c.toFixed(1)}%;background:${v}"></div>
        </div>
        <span class="chart-pct">${c.toFixed(1)}%</span>
      </div>`}const n=200,a=60,s=2,i=e.length,r=e.map((c,v)=>{const h=s+v/(i-1)*(n-2*s),k=a-s-(c.context_ratio??0)*(a-2*s);return{x:h,y:k,p:c}}),u=r.map(({x:c,y:v})=>`${c.toFixed(1)},${v.toFixed(1)}`).join(" "),d=(((l=e[e.length-1])==null?void 0:l.context_ratio)??0)*100,p=d>85?"#ef4444":d>70?"#f59e0b":"#22c55e";return o`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${a}" width="${n}" height="${a}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${s}" y1="${(a-s-.5*(a-2*s)).toFixed(1)}" x2="${n-s}" y2="${(a-s-.5*(a-2*s)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${s}" y1="${(a-s-.7*(a-2*s)).toFixed(1)}" x2="${n-s}" y2="${(a-s-.7*(a-2*s)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${s}" y1="${(a-s-.85*(a-2*s)).toFixed(1)}" x2="${n-s}" y2="${(a-s-.85*(a-2*s)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${r.filter(({p:c})=>c.is_handoff).map(({x:c})=>o`
          <line x1="${c.toFixed(1)}" y1="${s}" x2="${c.toFixed(1)}" y2="${a-s}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${u}" fill="none" stroke="${p}" stroke-width="1.5"/>
        ${r.filter(({p:c})=>c.is_compaction).map(({x:c,y:v})=>o`
          <circle cx="${c.toFixed(1)}" cy="${v.toFixed(1)}" r="2.5" fill="#a855f7"/>
        `)}
      </svg>
      <span class="chart-pct">${d.toFixed(1)}%</span>
    </div>`}const Ma=_("");function Tc({keeper:t}){var s,i,r,u;const e=Ma.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji??"-"},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((s=t.traits)==null?void 0:s.join(", "))||"-"},{title:"Interests",key:"interests",value:((i=t.interests)==null?void 0:i.join(", "))||"-"}],a=e?n.filter(d=>d.title.toLowerCase().includes(e)||d.key.includes(e)||d.value.toLowerCase().includes(e)):n;return o`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${Ma.value}
        onInput=${d=>{Ma.value=d.target.value}}
      />
      ${a.map(d=>o`
        <div class="keeper-field-row">
          <span class="keeper-field-title">${d.title}</span>
          <span class="keeper-field-key">${d.key}</span>
          <span style="flex:1; text-align:right; color:#ccc;">${d.value}</span>
        </div>
      `)}
      ${t.trace_id?o`<div class="keeper-field-row"><span class="keeper-field-title">Trace ID</span><span class="keeper-field-key mono">${t.trace_id}</span></div>`:""}
      ${t.agent_name?o`<div class="keeper-field-row"><span class="keeper-field-title">Agent</span><span style="flex:1; text-align:right; color:#ccc;">${t.agent_name}</span></div>`:""}
      ${t.primary_model?o`<div class="keeper-field-row"><span class="keeper-field-title">Primary Model</span><span class="mono" style="flex:1; text-align:right; color:#ccc;">${t.primary_model}</span></div>`:""}
      ${t.active_model?o`<div class="keeper-field-row"><span class="keeper-field-title">Active Model</span><span class="mono" style="flex:1; text-align:right; color:#ccc;">${t.active_model}</span></div>`:""}
      ${t.next_model_hint?o`<div class="keeper-field-row"><span class="keeper-field-title">Next Model Hint</span><span class="mono" style="flex:1; text-align:right; color:#ccc;">${t.next_model_hint}</span></div>`:""}
      ${t.skill_primary?o`<div class="keeper-field-row"><span class="keeper-field-title">Skill (Primary)</span><span style="flex:1; text-align:right; color:#ccc;">${t.skill_primary}</span></div>`:""}
      ${t.skill_secondary?o`<div class="keeper-field-row"><span class="keeper-field-title">Skill (Secondary)</span><span style="flex:1; text-align:right; color:#ccc;">${t.skill_secondary}</span></div>`:""}
      ${t.skill_reason?o`<div class="keeper-field-row"><span class="keeper-field-title">Skill Reason</span><span style="flex:1; text-align:right; color:#ccc;">${t.skill_reason}</span></div>`:""}
      ${t.context_source?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Source</span><span style="flex:1; text-align:right; color:#ccc;">${t.context_source}</span></div>`:""}
      ${t.context_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Tokens</span><span style="flex:1; text-align:right; color:#ccc;">${Bn(t.context_tokens)}</span></div>`:""}
      ${t.context_max!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Max</span><span style="flex:1; text-align:right; color:#ccc;">${Bn(t.context_max)}</span></div>`:""}
      ${t.memory_recent_note?o`<div class="keeper-field-row"><span class="keeper-field-title">Memory Note</span><span style="flex:1; text-align:right; color:#ccc;">${t.memory_recent_note}</span></div>`:""}
      ${t.k2k_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">K2K Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.k2k_count}</span></div>`:""}
      ${t.conversation_tail_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Conv Tail</span><span style="flex:1; text-align:right; color:#ccc;">${t.conversation_tail_count}</span></div>`:""}
      ${t.handoff_count_total!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Total Handoffs</span><span style="flex:1; text-align:right; color:#ccc;">${t.handoff_count_total}</span></div>`:""}
      ${t.compaction_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Compactions</span><span style="flex:1; text-align:right; color:#ccc;">${t.compaction_count}</span></div>`:""}
      ${t.last_compaction_saved_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Last Compact Saved</span><span style="flex:1; text-align:right; color:#ccc;">${Bn(t.last_compaction_saved_tokens)}</span></div>`:""}
      ${((r=t.context)==null?void 0:r.message_count)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.message_count}</span></div>`:""}
      ${((u=t.context)==null?void 0:u.has_checkpoint)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function Nc({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return o`
    <div>
      <div style="display: flex; gap: 12px; margin-bottom: 10px;">
        <div style="flex:1;">
          <div style="font-size:11px; color:#888;">HP ${t.hp}/${t.max_hp}</div>
          <div style="height:6px; background:rgba(255,255,255,0.06); border-radius:3px; overflow:hidden;">
            <div style="width:${e}%; height:100%; background:${e>50?"#4ade80":e>25?"#fbbf24":"#ef4444"}; border-radius:3px;" />
          </div>
        </div>
        <div style="flex:1;">
          <div style="font-size:11px; color:#888;">MP ${t.mp}/${t.max_mp}</div>
          <div style="height:6px; background:rgba(255,255,255,0.06); border-radius:3px; overflow:hidden;">
            <div style="width:${n}%; height:100%; background:#818cf8; border-radius:3px;" />
          </div>
        </div>
      </div>
      <div style="display:grid; grid-template-columns: repeat(3,1fr); gap:6px;">
        ${[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}].map(a=>o`
          <div style="text-align:center; padding:6px; background:rgba(255,255,255,0.03); border-radius:6px;">
            <div style="font-size:10px; color:#888; text-transform:uppercase;">${a.label}</div>
            <div style="font-size:16px; font-weight:bold; color:#e0e0e0;">${a.value}</div>
          </div>
        `)}
      </div>
      <div style="margin-top:8px; font-size:12px; color:#888;">
        Level ${t.level} — XP ${t.xp}
      </div>
    </div>
  `}function Cc({items:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No equipment</div>`:o`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>o`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function Rc({rels:t}){const e=Object.entries(t);return e.length===0?o`<div class="empty-state" style="font-size:13px">No relationships</div>`:o`
    <div class="keeper-k2k-list">
      ${e.map(([n,a])=>o`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${a}</span>
        </div>
      `)}
    </div>
  `}function Ri({traits:t,label:e}){return t.length===0?null:o`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>o`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function Oa(t){return t==null||Number.isNaN(t)?"-":`${Math.round(t*100)}%`}function Lc({keeper:t}){const e=t.metrics_window,n=[{label:"Model fallback",value:Oa(typeof(e==null?void 0:e.model_fallback_rate)=="number"?e.model_fallback_rate:void 0)},{label:"Proactive fallback",value:Oa(typeof(e==null?void 0:e.proactive_fallback_rate)=="number"?e.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:Oa(typeof(e==null?void 0:e.memory_pass_rate)=="number"?e.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(e==null?void 0:e.handoff_count)=="number"?e.handoff_count:t.handoff_count_total??"-"},{label:"Compactions",value:typeof(e==null?void 0:e.compaction_events)=="number"?e.compaction_events:t.compaction_count??"-"},{label:"Saved tokens",value:typeof(e==null?void 0:e.compaction_saved_tokens)=="number"?e.compaction_saved_tokens:t.last_compaction_saved_tokens??"-"},{label:"K2K events",value:t.k2k_count??"-"},{label:"Conversation tail",value:t.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(e==null?void 0:e.tool_call_count)=="number"?e.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(e==null?void 0:e.proactive_preview_similarity_avg)=="number"?`${(e.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(e==null?void 0:e.memory_avg_score)=="number"?e.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(e==null?void 0:e.fallback_rate)=="number"?`${(e.fallback_rate*100).toFixed(1)}%`:"-"}];return o`
    <div class="keeper-signal-list">
      ${n.map(a=>o`
        <div class="keeper-signal-row">
          <span>${a.label}</span>
          <strong>${a.value}</strong>
        </div>
      `)}
    </div>
  `}function Dc({keeperName:t}){const[e,n]=Oe("Loading internal monologue..."),[a,s]=Oe(""),[i,r]=Oe([]),[u,d]=Oe(!1),p=async()=>{try{const l=await Q("masc_keeper_status",{name:t,fast:!1,include_history_tail:!0,include_context:!0});n(typeof l=="string"?l:JSON.stringify(l,null,2))}catch(l){n("Failed to load: "+String(l))}};Dt(()=>{p()},[t]);const f=async()=>{if(!a.trim())return;d(!0);const l=a;s(""),r(c=>[...c,{role:"You",text:l}]);try{const c=await Q("masc_keeper_msg",{name:t,message:l});r(v=>[...v,{role:t,text:typeof c=="string"?c:JSON.stringify(c)}]),p()}catch(c){r(v=>[...v,{role:"System",text:"Error: "+String(c)}])}finally{d(!1)}};return o`
    <div style="margin-top: 24px; border-top: 1px solid rgba(255,255,255,0.1); padding-top: 24px;">
      <h3 style="margin: 0 0 16px; color: var(--accent-cyan); font-family: var(--font-display);">Direct Comms & Inner Monologue</h3>
      
      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 20px;">
        <!-- Chat Area -->
        <div style="display: flex; flex-direction: column; gap: 12px;">
          <div style="background: rgba(0,0,0,0.3); border: 1px solid var(--border); border-radius: 12px; height: 300px; overflow-y: auto; padding: 12px; display: flex; flex-direction: column; gap: 8px; font-size: 0.85rem;">
            ${i.length===0?o`<div style="color: var(--text-muted); font-style: italic;">No direct messages yet.</div>`:null}
            ${i.map(l=>o`
              <div style="padding: 8px; border-radius: 8px; background: ${l.role==="You"?"rgba(0, 240, 255, 0.1)":"rgba(255, 255, 255, 0.05)"}; border-left: 2px solid ${l.role==="You"?"var(--accent-cyan)":"var(--text-muted)"};">
                <strong style="color: ${l.role==="You"?"var(--accent-cyan)":"var(--text-primary)"}; display: block; margin-bottom: 4px;">${l.role}</strong>
                <span style="white-space: pre-wrap;">${l.text}</span>
              </div>
            `)}
          </div>
          <div style="display: flex; gap: 8px;">
            <input 
              type="text" 
              value=${a} 
              onInput=${l=>s(l.currentTarget.value)} 
              onKeyDown=${l=>l.key==="Enter"&&!l.shiftKey&&f()}
              placeholder="Ping the agent..."
              disabled=${u}
              style="flex: 1; background: rgba(255,255,255,0.05); border: 1px solid var(--border); border-radius: 8px; padding: 8px 12px; color: var(--text-primary); font-family: var(--font-body);"
            />
            <button 
              onClick=${f} 
              disabled=${u||!a.trim()}
              style="background: var(--accent-cyan); color: #000; border: none; border-radius: 8px; padding: 8px 16px; font-weight: bold; cursor: pointer; opacity: ${u?.5:1};"
            >
              ${u?"Sending...":"Send"}
            </button>
          </div>
        </div>

        <!-- Monologue / Status Area -->
        <div style="background: #050810; border: 1px solid var(--card-border); border-radius: 12px; padding: 12px; height: 345px; overflow-y: auto; font-family: monospace; font-size: 0.75rem; color: var(--ok); white-space: pre-wrap; box-shadow: inset 0 0 15px rgba(0,0,0,0.8);">
          ${e}
        </div>
        
      </div>
    </div>
  `}function Ec(){var e,n,a;const t=ei.value;return t?o`
    <div
      class="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${s=>{s.target.classList.contains("keeper-detail-overlay")&&Ci()}}
    >
      <div style="max-width:780px; width:100%; max-height:90vh; overflow-y:auto; background:#1a1a2e; border-radius:16px; border:1px solid rgba(255,255,255,0.08); padding:24px;">
        ${""}
        <div style="display:flex; align-items:center; justify-content:space-between; margin-bottom:20px;">
          <div style="display:flex; align-items:center; gap:12px;">
            <span style="font-size:32px;">${t.emoji}</span>
            <div>
              <h2 style="margin:0; font-size:20px; color:#e0e0e0;">${t.name}</h2>
              ${t.koreanName?o`<div style="font-size:13px; color:#888;">${t.koreanName}</div>`:null}
            </div>
            <${_t} status=${t.status} />
            ${t.model?o`<span class="pill">${t.model}</span>`:null}
          </div>
          <button
            onClick=${()=>Ci()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${Sc} keeper=${t} />

        ${""}
        <${Ac} keeper=${t} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${b} title="Field Dictionary">
            <${Tc} keeper=${t} />
          <//>

          ${""}
          <${b} title="Profile">
            <${Ri} traits=${t.traits??[]} label="Traits" />
            <${Ri} traits=${t.interests??[]} label="Interests" />
            ${t.primaryValue?o`<div style="font-size:12px; color:#888;">Primary value: <span style="color:#4ade80;">${t.primaryValue}</span></div>`:null}
            ${t.skill_primary?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Skill route: <span style="color:#22d3ee;">${t.skill_primary}</span>
                </div>`:null}
            ${t.skill_reason?o`<div style="font-size:12px; color:#888; margin-top:4px;">${t.skill_reason}</div>`:null}
            ${t.last_heartbeat?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Last heartbeat: <${j} timestamp=${t.last_heartbeat} />
                </div>`:null}
          <//>

          ${""}
          ${t.autonomy_level?o`
              <${b} title="Autonomy">
                <${wc} keeper=${t} />
              <//>
            `:null}

          ${""}
          ${t.trpg_stats?o`
              <${b} title="TRPG Stats">
                <${Nc} stats=${t.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?o`
              <${b} title="Equipment (${t.inventory.length})">
                <${Cc} items=${t.inventory} />
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?o`
              <${b} title="Relationships (${Object.keys(t.relationships).length})">
                <${Rc} rels=${t.relationships} />
              <//>
            `:null}

          <${b} title="Runtime Signals">
            <${Lc} keeper=${t} />
          <//>

          <${b} title="Memory & Context">
            <div class="keeper-signal-list">
              <div class="keeper-signal-row">
                <span>Context source</span>
                <strong>${t.context_source??((e=t.context)==null?void 0:e.source)??"-"}</strong>
              </div>
              <div class="keeper-signal-row">
                <span>Context tokens</span>
                <strong>
                  ${t.context_tokens??((n=t.context)==null?void 0:n.context_tokens)??"-"}
                  /
                  ${t.context_max??((a=t.context)==null?void 0:a.context_max)??"-"}
                </strong>
              </div>
              ${t.memory_recent_note?o`
                  <div class="keeper-memory-note">
                    ${t.memory_recent_note}
                  </div>
                `:o`<div class="empty-state" style="font-size:12px;">No recent memory note</div>`}
            </div>
          <//>
        </div>
        <${Dc} keeperName=${t.name} />
      </div>
    </div>
  `:null}let Ic=0;const te=_([]);function y(t,e="success",n=4e3){const a=++Ic;te.value=[...te.value,{id:a,message:t,type:e}],setTimeout(()=>{te.value=te.value.filter(s=>s.id!==a)},n)}function Pc(t){te.value=te.value.filter(e=>e.id!==t)}function Mc(){const t=te.value;return t.length===0?null:o`
    <div class="toast-container">
      ${t.map(e=>o`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>Pc(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}const Oc="masc_dashboard_agent_name",Ce=_(null),aa=_(!1),mn=_(""),sa=_([]),fn=_([]),be=_(""),Be=_(!1);function ke(t){Ce.value=t,ni()}function Li(){Ce.value=null,mn.value="",sa.value=[],fn.value=[],be.value=""}function Fc(){const t=Ce.value;return t?Jt.value.find(e=>e.name===t)??null:null}function tr(t){return t?Tt.value.filter(e=>e.assignee===t):[]}async function ni(){const t=Ce.value;if(t){aa.value=!0,mn.value="",sa.value=[],fn.value=[];try{const e=await Gl(80);sa.value=e.filter(s=>s.includes(t)).slice(0,20);const n=tr(t).slice(0,6);if(n.length===0)return;const a=await Promise.all(n.map(async s=>{try{const i=await Jl(s.id,25);return{taskId:s.id,text:i.trim()}}catch(i){const r=i instanceof Error?i.message:"history load failed";return{taskId:s.id,text:`Failed to load history: ${r}`}}}));fn.value=a}catch(e){mn.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{aa.value=!1}}}async function Di(){var a;const t=Ce.value,e=be.value.trim();if(!t||!e)return;const n=((a=localStorage.getItem(Oc))==null?void 0:a.trim())||"dashboard";Be.value=!0;try{await Bo(n,`@${t} ${e}`),be.value="",y(`Mention sent to ${t}`,"success"),ni()}catch(s){const i=s instanceof Error?s.message:"Failed to send mention";y(i,"error")}finally{Be.value=!1}}function jc({task:t}){return o`
    <div class="agent-detail-task">
      <span class="pill">${t.id}</span>
      <span class="agent-detail-task-title">${t.title}</span>
      <${_t} status=${t.status} />
    </div>
  `}function zc({row:t}){return o`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${t.taskId}</span>
      </div>
      <pre class="agent-history-pre">${t.text||"No task history yet"}</pre>
    </div>
  `}function qc(){var s,i,r,u;const t=Ce.value;if(!t)return null;const e=Fc(),n=tr(t),a=sa.value;return o`
    <div
      class="agent-detail-overlay"
      onClick=${d=>{d.target.classList.contains("agent-detail-overlay")&&Li()}}
    >
      <div class="agent-detail-modal">
        <div class="agent-detail-header">
          <div style="display:flex;flex-direction:column;gap:8px;flex:1">
            <div style="display:flex;align-items:center;gap:12px">
              ${e!=null&&e.emoji?o`<span style="font-size:2rem">${e.emoji}</span>`:""}
              <div>
                <h2 style="margin:0;display:flex;align-items:baseline;gap:8px">
                  ${t}
                  ${e!=null&&e.koreanName?o`<span style="font-size:0.75em;color:#888">(${e.koreanName})</span>`:""}
                </h2>
                <div style="display:flex;align-items:center;gap:8px;margin-top:4px;flex-wrap:wrap">
                  ${e?o`
                        <${_t} status=${e.status} />
                        ${e.model?o`<span class="mono" style="font-size:0.75rem;background:#2a2a4a;padding:2px 6px;border-radius:4px">${e.model}</span>`:""}
                        ${e.primaryValue?o`<span style="font-size:0.75rem;color:#a78bfa">${e.primaryValue}</span>`:""}
                      `:o`<span>Agent snapshot not found in current state</span>`}
                </div>
              </div>
            </div>
            ${(e==null?void 0:e.activityLevel)!=null?o`
              <div style="display:flex;align-items:center;gap:8px;font-size:0.8rem">
                <span style="color:#888">Activity</span>
                <div style="flex:1;max-width:120px;height:6px;background:#1a1a2e;border-radius:3px;overflow:hidden">
                  <div style="width:${Math.min(e.activityLevel*10,100)}%;height:100%;background:${e.activityLevel>=8?"#22c55e":e.activityLevel>=5?"#f59e0b":"#666"};border-radius:3px"></div>
                </div>
                <span style="color:#888">${e.activityLevel}/10</span>
              </div>
            `:""}
            ${(((s=e==null?void 0:e.traits)==null?void 0:s.length)??0)>0?o`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(i=e==null?void 0:e.traits)==null?void 0:i.map(d=>o`<span style="font-size:0.7rem;background:#1e3a5f;color:#60a5fa;padding:2px 8px;border-radius:10px">${d}</span>`)}
              </div>
            `:""}
            ${(((r=e==null?void 0:e.interests)==null?void 0:r.length)??0)>0?o`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(u=e==null?void 0:e.interests)==null?void 0:u.map(d=>o`<span style="font-size:0.7rem;background:#3b1f4e;color:#c084fc;padding:2px 8px;border-radius:10px">${d}</span>`)}
              </div>
            `:""}
            <div class="agent-detail-sub">
              ${e?o`
                    ${e.current_task?o`<span>Task: ${e.current_task}</span>`:null}
                    ${e.last_seen?o`<span>Last seen: <${j} timestamp=${e.last_seen} /></span>`:null}
                  `:null}
            </div>
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{ni()}} disabled=${aa.value}>
              ${aa.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${Li}>Close</button>
          </div>
        </div>

        ${mn.value?o`<div class="council-error">${mn.value}</div>`:null}

        <div class="agent-detail-grid">
          <${b} title="Assigned Tasks">
            ${n.length===0?o`<div class="empty-state">No assigned tasks</div>`:o`<div class="agent-detail-task-list">${n.map(d=>o`<${jc} key=${d.id} task=${d} />`)}</div>`}
          <//>

          <${b} title="Recent Activity">
            ${a.length===0?o`<div class="empty-state">No recent room activity match</div>`:o`<div class="agent-activity-list">${a.map((d,p)=>o`<div key=${p} class="agent-activity-line">${d}</div>`)}</div>`}
          <//>
        </div>

        <${b} title="Task History">
          ${fn.value.length===0?o`<div class="empty-state">No task history loaded</div>`:o`<div class="agent-history-list">${fn.value.map(d=>o`<${zc} key=${d.taskId} row=${d} />`)}</div>`}
        <//>

        <${b} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${be.value}
              onInput=${d=>{be.value=d.target.value}}
              onKeyDown=${d=>{d.key==="Enter"&&Di()}}
              disabled=${Be.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{Di()}}
              disabled=${Be.value||be.value.trim()===""}
            >
              ${Be.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}const Fa=600*1e3,ja=1200*1e3,Ei=.8;function $t(t){if(t==null)return 0;const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function jt(t){switch(t){case"bad":return 2;case"warn":return 1;default:return 0}}function Ii(t){return(t??"").trim().toLowerCase()}function Ee(t,e=96){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:null}function ve(t){return typeof t!="number"||Number.isNaN(t)?3:t}function Hc(t){const e=ve(t);return e<=1?"P1":e===2?"P2":e>=4?"P4+":"P3"}function ce(t){const e=(t??"").toLowerCase();return e==="bad"?"bad":e==="warn"?"warn":"ok"}function Dn(t){switch(t){case"bad":return"#fb7185";case"warn":return"#fbbf24";default:return"#4ade80"}}function Pi(t){return typeof t!="number"||!Number.isFinite(t)?"??:00":`${String(Math.max(0,t)).padStart(2,"0")}:00`}function Mi(t){if(t==null||!Number.isFinite(t))return"unknown";if(t<60)return`${Math.round(t)}s`;const e=Math.round(t/60);if(e<60)return`${e}m`;const n=Math.floor(e/60),a=e%60;return a>0?`${n}h ${a}m`:`${n}h`}function Uc(t){if(!t)return"N/A";const e=Math.floor(t/3600),n=Math.floor(t%3600/60);return e>0?`${e}h ${n}m`:`${n}m`}function za(t){if(t==null||!Number.isFinite(t))return"No data";if(t<60)return`${Math.max(0,Math.round(t))}s`;const e=Math.floor(t/60);if(e<60)return`${e}m`;const n=Math.floor(e/60),a=e%60;return a>0?`${n}h ${a}m`:`${n}h`}function Kc(t){return t==null?"—":t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}k`:String(t)}function Bc(t){return t?t.enabled?t.quiet_active?`Quiet hours ${Pi(t.quiet_start)}-${Pi(t.quiet_end)} KST are active.`:t.last_tick_ago_s==null?`Lodge is enabled and scheduled every ${Mi(t.interval_s)}, but no tick has run yet.`:`Lodge ticks every ${Mi(t.interval_s)} with planner ${t.use_planner?"on":"off"} and delegated LLM ${t.delegate_llm?"on":"off"}.`:"Lodge automation is disabled.":"Lodge runtime status is unavailable in the current dashboard payload."}function Oi(t){const e=(t??"").toLowerCase();return e==="ok"?"Healthy":e==="warn"?"Warning":e==="bad"?"Degraded":"Unknown"}function ue({label:t,value:e,color:n,caption:a}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color: ${n}`:""}>${e}</div>
      ${a?o`<div class="monitor-stat-caption">${a}</div>`:null}
    </div>
  `}function Wc({item:t}){return o`
    <button class="monitor-alert ${t.tone}" onClick=${t.action}>
      <div class="monitor-alert-main">
        <div class="monitor-alert-title">${t.title}</div>
        <div class="monitor-alert-subtitle">${t.detail}</div>
      </div>
      <div class="monitor-alert-meta">
        <span class="monitor-pill ${t.tone}">${t.tone==="bad"?"Act now":t.tone==="warn"?"Watch":"Stable"}</span>
        ${t.timestamp?o`<span><${j} timestamp=${t.timestamp} /></span>`:null}
      </div>
    </button>
  `}function qa({tone:t,title:e,subtitle:n,meta:a,focus:s,onClick:i}){return o`
    <button class="monitor-row ${t}" onClick=${i}>
      <div class="monitor-row-header">
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e}</span>
            <span class="monitor-sub">${n}</span>
          </div>
        </div>
        <span class="monitor-pill ${t}">${t==="bad"?"Alert":t==="warn"?"Watch":"Ready"}</span>
      </div>
      <div class="monitor-meta">
        ${a.map(r=>o`<span>${r}</span>`)}
      </div>
      <div class="monitor-focus">${s}</div>
    </button>
  `}function Fi(){var S,R,Y,gt,ht,X,ot,I,U,$,Qt,Re,An,Tn,Nn;const t=Vt.value,e=Jt.value,n=Tt.value,a=ft.value,s=Qo.value,i=(S=t==null?void 0:t.monitoring)==null?void 0:S.board,r=(R=t==null?void 0:t.monitoring)==null?void 0:R.council,u=Et.value,d=new Map(e.map(m=>[Ii(m.name),m])),p=e.map(m=>{var li;const T=vn(m.name,n,se.value,Wt.value,{currentTask:m.current_task,lastSeen:m.last_seen,boardPosts:It.value,keepers:a}),P=T.lastActivityAt??m.last_seen??null,G=P?Math.max(0,Date.now()-$t(P)):Number.POSITIVE_INFINITY,et=T.activeAssignedCount,Z=!!((li=m.current_task)!=null&&li.trim()),B=Z||et>0;let W="ok",tt="Fresh and ready",Ot=!1,Ft=!1;return m.status==="offline"||m.status==="inactive"?(W=B?"bad":"warn",tt=B?"Load without an available owner":"Offline"):B&&G>ja?(W="bad",tt="Execution is stale"):et>0&&!Z?(W="warn",tt="Claimed work has no current_task",Ft=!0):Z&&et===0?(W="warn",tt="current_task has no claimed work",Ft=!0):!B&&G<=Fa?(W="ok",tt="Dispatchable now",Ot=!0):!B&&G>ja?(W="warn",tt="Idle but not freshly active"):B&&G>Fa&&(W="warn",tt="Execution is getting quiet"),{agent:m,lastSignalAt:P,activeTaskCount:et,tone:W,note:tt,focus:Ee(m.current_task)??T.lastActivityText??(Ot?"Ready for assignment.":"Waiting for a clearer signal."),dispatchable:Ot,drift:Ft}}).sort((m,T)=>{const P=jt(T.tone)-jt(m.tone);return P!==0?P:$t(T.lastSignalAt)-$t(m.lastSignalAt)}),f=a.map(m=>{var B;const T=Yo.value.get(m.name)??"idle",P=Xo.value.has(m.name),G=m.context_ratio??0;let et="ok",Z="Healthy keeper";return P||m.status==="offline"||T==="handoff-imminent"?(et="bad",Z=P?"Heartbeat stale":T==="handoff-imminent"?"Handoff imminent":"Keeper offline"):(G>=Ei||T==="preparing"||T==="compacting")&&(et="warn",Z=G>=Ei?"High context pressure":`Lifecycle ${T}`),{keeper:m,tone:et,note:Z,focus:Ee((B=m.agent)==null?void 0:B.current_task)??m.skill_primary??m.last_proactive_reason??m.memory_recent_note??"No active focus",timestamp:m.last_heartbeat??null}}).sort((m,T)=>{const P=jt(T.tone)-jt(m.tone);return P!==0?P:$t(T.timestamp)-$t(m.timestamp)}),l=n.filter(m=>m.status==="todo"||m.status==="claimed"||m.status==="in_progress").map(m=>{var Ot,Ft;const T=m.assignee?d.get(Ii(m.assignee))??null:null,P=T?vn(T.name,n,se.value,Wt.value,{currentTask:T.current_task,lastSeen:T.last_seen,boardPosts:It.value,keepers:a}):null,G=(P==null?void 0:P.lastActivityAt)??(T==null?void 0:T.last_seen)??null,et=G?Math.max(0,Date.now()-$t(G)):Number.POSITIVE_INFINITY,Z=m.status==="claimed"||m.status==="in_progress";let B="ok",W="Covered",tt=!1;return m.assignee?!T||T.status==="offline"||T.status==="inactive"?(B="bad",W="Assigned owner is unavailable",tt=!0):Z&&et>ja?(B="bad",W="Execution has lost a fresh signal"):Z&&et>Fa?(B="warn",W="Execution is drifting quiet"):m.status==="todo"&&ve(m.priority)<=2&&!((Ot=T.current_task)!=null&&Ot.trim())&&((P==null?void 0:P.activeAssignedCount)??0)===0?(B="ok",W="Ready for dispatch"):Z&&!((Ft=T.current_task)!=null&&Ft.trim())&&(B="warn",W="Owner focus is not explicit"):(B=ve(m.priority)<=2?"bad":"warn",W=Z?"Active work has no owner":"Ready work has no owner",tt=!0),{task:m,owner:T,lastSignalAt:G,tone:B,note:W,focus:Ee(T==null?void 0:T.current_task)??(P==null?void 0:P.lastActivityText)??Ee(m.description)??"Needs operator attention.",ownerGap:tt}}).sort((m,T)=>{const P=jt(T.tone)-jt(m.tone);if(P!==0)return P;const G=ve(m.task.priority)-ve(T.task.priority);return G!==0?G:$t(T.lastSignalAt??T.task.updated_at??T.task.created_at)-$t(m.lastSignalAt??m.task.updated_at??m.task.created_at)}),c=l.filter(m=>m.task.status==="todo"&&ve(m.task.priority)<=2),v=l.filter(m=>m.ownerGap).length,h=p.filter(m=>m.dispatchable),k=p.filter(m=>m.drift||m.tone!=="ok"),w=f.filter(m=>m.tone!=="ok"),C=t!=null&&t.paused?"bad":((Y=t==null?void 0:t.data_quality)==null?void 0:Y.board_contract_ok)===!1||((gt=t==null?void 0:t.data_quality)==null?void 0:gt.council_feed_ok)===!1?"warn":u?"ok":"warn",A=[];t!=null&&t.paused&&A.push({key:"paused",tone:"bad",title:"Room is paused",detail:t.tempo?`Tempo is ${t.tempo}. Resume from Ops when ready.`:"Resume from Ops when ready.",timestamp:((ht=t.data_quality)==null?void 0:ht.last_sync_at)??null,action:()=>pt("ops")}),u||A.push({key:"live-connection",tone:"warn",title:"Live feed is reconnecting",detail:"Dashboard telemetry is stale until the SSE stream recovers.",timestamp:null,action:()=>pt("activity")}),ce(i==null?void 0:i.alert_level)!=="ok"&&A.push({key:"board-monitor",tone:ce(i==null?void 0:i.alert_level),title:"Board feed needs attention",detail:`Freshness ${za(i==null?void 0:i.last_activity_age_s)} · ${(i==null?void 0:i.unanswered_posts)??0} unanswered posts.`,timestamp:null,action:()=>pt("board")}),ce(r==null?void 0:r.alert_level)!=="ok"&&A.push({key:"council-monitor",tone:ce(r==null?void 0:r.alert_level),title:"Council quorum risk is elevated",detail:`${(r==null?void 0:r.sessions_without_quorum)??0} sessions without quorum · freshness ${za(r==null?void 0:r.last_activity_age_s)}.`,timestamp:null,action:()=>pt("council")}),(((X=t==null?void 0:t.data_quality)==null?void 0:X.board_contract_ok)===!1||((ot=t==null?void 0:t.data_quality)==null?void 0:ot.council_feed_ok)===!1)&&A.push({key:"data-quality",tone:"warn",title:"Dashboard data quality is degraded",detail:`${((I=t.data_quality)==null?void 0:I.board_contract_ok)===!1?"Board contract":"Board contract ok"} · ${((U=t.data_quality)==null?void 0:U.council_feed_ok)===!1?"Council feed degraded":"Council feed ok"}.`,timestamp:(($=t.data_quality)==null?void 0:$.last_sync_at)??null,action:()=>pt("ops")});const O=[...A,...l.filter(m=>m.tone!=="ok").slice(0,3).map(m=>({key:`task-${m.task.id}`,tone:m.tone,title:m.task.title,detail:`${m.note} · ${m.focus}`,timestamp:m.lastSignalAt??m.task.updated_at??m.task.created_at??null,action:()=>pt("execution")})),...w.slice(0,2).map(m=>({key:`keeper-${m.keeper.name}`,tone:m.tone,title:m.keeper.name,detail:`${m.note} · ${m.focus}`,timestamp:m.timestamp,action:()=>na(m.keeper)})),...k.slice(0,2).map(m=>({key:`agent-${m.agent.name}`,tone:m.tone,title:m.agent.name,detail:`${m.note} · ${m.focus}`,timestamp:m.lastSignalAt,action:()=>ke(m.agent.name)}))].sort((m,T)=>{const P=jt(T.tone)-jt(m.tone);return P!==0?P:$t(T.timestamp)-$t(m.timestamp)}).slice(0,8);return o`
    <div class="stats-grid">
      <${ue}
        label="Room State"
        value=${t!=null&&t.paused?"Paused":"Running"}
        color=${Dn(C)}
        caption=${(t==null?void 0:t.room)??(t==null?void 0:t.project)??"default room"}
      />
      <${ue}
        label="Urgent Queue"
        value=${c.length}
        color=${c.length>0?"#fb7185":"#4ade80"}
        caption="todo tasks at P1/P2"
      />
      <${ue}
        label="Active Work"
        value=${s.inProgress.length}
        color="#fbbf24"
        caption="claimed + in progress"
      />
      <${ue}
        label="Dispatchable"
        value=${h.length}
        color="#22d3ee"
        caption="fresh agents with no load"
      />
      <${ue}
        label="Keeper Pressure"
        value=${w.length}
        color=${w.length>0?"#fbbf24":"#4ade80"}
        caption="stale or high-context keepers"
      />
      <${ue}
        label="Owner Gaps"
        value=${v}
        color=${v>0?"#fb7185":"#4ade80"}
        caption="tasks missing a live owner"
      />
    </div>

    <${b} title="Room Health" class="section">
      <div class="monitor-section-head">
        <h2 class="monitor-headline">Operational health at a glance</h2>
        <p class="monitor-subheadline">The Overview now prioritizes room state, feed freshness, and immediate intervention signals over full entity dumps.</p>
      </div>
      <div class="overview-health-grid">
        <div class="stat-card">
          <div class="stat-label">Live Feed</div>
          <div class="stat-value" style=${`color:${u?"#4ade80":"#fbbf24"}`}>${u?"Online":"Retrying"}</div>
          <div class="monitor-stat-caption">${bn.value} events seen in this session</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Board Feed</div>
          <div class="stat-value" style=${`color:${Dn(ce(i==null?void 0:i.alert_level))}`}>${Oi(i==null?void 0:i.alert_level)}</div>
          <div class="monitor-stat-caption">Freshness ${za(i==null?void 0:i.last_activity_age_s)}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Council Feed</div>
          <div class="stat-value" style=${`color:${Dn(ce(r==null?void 0:r.alert_level))}`}>${Oi(r==null?void 0:r.alert_level)}</div>
          <div class="monitor-stat-caption">${(r==null?void 0:r.sessions_without_quorum)??0} sessions without quorum</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Runtime</div>
          <div class="stat-value" style=${`color:${Dn(C)}`}>${t!=null&&t.paused?"Paused":"Stable"}</div>
          <div class="monitor-stat-caption">Uptime ${Uc((t==null?void 0:t.uptime_seconds)??0)}</div>
        </div>
      </div>
      <div class="overview-note-stack">
        <div class="overview-inline-note">
          ${(Qt=t==null?void 0:t.data_quality)!=null&&Qt.last_sync_at?o`Last sync <${j} timestamp=${t.data_quality.last_sync_at} />`:o`No sync metadata yet`}
        </div>
        <div class="overview-inline-note">
          ${t!=null&&t.tempo?`Tempo ${t.tempo}`:"Tempo unavailable"}${(t==null?void 0:t.tempo_interval_s)!=null?` · ${t.tempo_interval_s}s interval`:""}
        </div>
        <div class="overview-inline-note">${Bc(t==null?void 0:t.lodge)}</div>
      </div>
    <//>

    <div class="grid-2col">
      <${b} title="Intervention Queue" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">What needs intervention right now</h2>
          <p class="monitor-subheadline">Room-level risks, stalled work, and keeper/agent drift are sorted into one operator-facing queue.</p>
        </div>
        <div class="monitor-alert-list">
          ${O.length===0?o`<div class="empty-state">No immediate intervention required</div>`:O.map(m=>o`<${Wc} key=${m.key} item=${m} />`)}
        </div>
      <//>

      <${b} title="Dispatch Window" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Who can pick up work next</h2>
          <p class="monitor-subheadline">Fresh capacity stays visible here so dispatch does not require opening the full Agents tab.</p>
        </div>
        <div class="monitor-list">
          ${h.length===0?o`<div class="empty-state">No fully dispatchable agents right now</div>`:h.slice(0,5).map(m=>o`
                <${qa}
                  key=${m.agent.name}
                  tone=${m.tone}
                  title=${m.agent.name}
                  subtitle=${m.note}
                  meta=${[m.lastSignalAt?`Signal ${new Date(m.lastSignalAt).toLocaleTimeString()}`:"No recent signal",m.agent.model??"model n/a",m.agent.koreanName??"room agent"]}
                  focus=${m.focus}
                  onClick=${()=>ke(m.agent.name)}
                />
              `)}
        </div>
      <//>
    </div>

    <div class="grid-2col">
      <${b} title="Execution Pulse" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Priority work and ownership drift</h2>
          <p class="monitor-subheadline">Urgent ready tasks and active execution issues stay visible without duplicating the full Execution surface.</p>
        </div>
        <div class="monitor-list">
          ${l.length===0?o`<div class="empty-state">No active or ready tasks</div>`:l.slice(0,6).map(m=>o`
                <${qa}
                  key=${m.task.id}
                  tone=${m.tone}
                  title=${m.task.title}
                  subtitle=${`${Hc(m.task.priority)} · ${m.note}`}
                  meta=${[m.task.assignee?`Owner ${m.task.assignee}`:"Unassigned",m.lastSignalAt?`Signal ${new Date(m.lastSignalAt).toLocaleTimeString()}`:"No live signal",m.task.updated_at?`Touched ${new Date(m.task.updated_at).toLocaleTimeString()}`:"No task timestamp"]}
                  focus=${m.focus}
                  onClick=${()=>pt("execution")}
                />
              `)}
        </div>
      <//>

      <${b} title="Keeper Pressure" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Long-running keepers under pressure</h2>
          <p class="monitor-subheadline">Only keepers with real pressure stay in the Overview. The full keeper census still lives in the Agents tab.</p>
        </div>
        <div class="monitor-list">
          ${w.length===0?o`<div class="empty-state">No keeper pressure signals right now</div>`:w.slice(0,5).map(m=>o`
                <${qa}
                  key=${m.keeper.name}
                  tone=${m.tone}
                  title=${m.keeper.name}
                  subtitle=${m.note}
                  meta=${[m.timestamp?`Heartbeat ${new Date(m.timestamp).toLocaleTimeString()}`:"No heartbeat",`Context ${typeof m.keeper.context_ratio=="number"?Math.round(m.keeper.context_ratio*100):0}%`,m.keeper.model??"model n/a"]}
                  focus=${m.focus}
                  onClick=${()=>na(m.keeper)}
                />
              `)}
        </div>
      <//>
    </div>

    <div class="grid-2col">
      <${b} title="Agent Watch" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Agents with drift or aging load</h2>
          <p class="monitor-subheadline">This is the short list. Use the Agents tab when you need the full live monitor.</p>
        </div>
        <div class="monitor-list">
          ${k.length===0?o`<div class="empty-state">No agent drift or stale load right now</div>`:k.slice(0,5).map(m=>o`
                <button class="monitor-row ${m.tone}" onClick=${()=>ke(m.agent.name)}>
                  <div class="monitor-row-header">
                    <div class="monitor-row-title">
                      <div class="monitor-name-line">
                        <span class="monitor-title">${m.agent.name}</span>
                        ${m.agent.koreanName?o`<span class="monitor-sub">${m.agent.koreanName}</span>`:null}
                      </div>
                      <div class="monitor-note">${m.note}</div>
                    </div>
                    <${_t} status=${m.agent.status} />
                    <span class="monitor-pill ${m.tone}">${m.dispatchable?"Ready":m.drift?"Drift":"Watch"}</span>
                  </div>
                  <div class="monitor-meta">
                    ${m.lastSignalAt?o`<span>Signal <${j} timestamp=${m.lastSignalAt} /></span>`:o`<span>No recent signal</span>`}
                    <span>${m.activeTaskCount>0?`${m.activeTaskCount} active tasks`:"No active tasks"}</span>
                    ${m.agent.model?o`<span>${m.agent.model}</span>`:null}
                  </div>
                  <div class="monitor-focus">${m.focus}</div>
                </button>
              `)}
        </div>
      <//>

      <${b} title="Runtime Notes" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Secondary runtime context</h2>
          <p class="monitor-subheadline">This stays below the triage queue so operators can scan first and drill later.</p>
        </div>
        <div class="overview-note-stack">
          <div class="overview-inline-note">
            Room ${(t==null?void 0:t.room)??"default"}${t!=null&&t.cluster?` · Cluster ${t.cluster}`:""}${t!=null&&t.project?` · Project ${t.project}`:""}
          </div>
          <div class="overview-inline-note">
            ${t!=null&&t.version?`Version ${t.version}`:"Version unavailable"} · Active agents ${oc.value.length} · Total tasks ${n.length}
          </div>
          <div class="overview-inline-note">
            ${Fe.value?`Perpetual runtime ${Fe.value.running?"running":"stopped"}${Fe.value.goal?` · ${Ee(Fe.value.goal,120)}`:""}`:"Perpetual runtime unavailable"}
          </div>
          <div class="overview-inline-note">
            Lodge ${(Re=t==null?void 0:t.lodge)!=null&&Re.enabled?"enabled":"disabled"} · Last tick ${((An=t==null?void 0:t.lodge)==null?void 0:An.last_tick_ago)??"never"} · Self heartbeats ${((Nn=(Tn=t==null?void 0:t.lodge)==null?void 0:Tn.active_self_heartbeats)==null?void 0:Nn.length)??0}
          </div>
          <div class="overview-inline-note">
            ${a.length>0?`Hot keepers: ${w.length} · Highest context ${Kc(Math.max(...a.map(m=>m.context_tokens??0)))}`:"No keepers registered"}
          </div>
        </div>
      <//>
    </div>
  `}const Sn=_(null),ia=_(!1),Gt=_(null),z=_(!1),oa=_([]);let Gc=1;function q(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function N(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function st(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function er(t){return typeof t=="boolean"?t:void 0}function Jc(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function me(t,e=[]){if(Array.isArray(t))return t;if(!q(t))return[];for(const n of e){const a=t[n];if(Array.isArray(a))return a}return[]}function Vc(t){return q(t)?{id:N(t.id),seq:st(t.seq),from:N(t.from)??N(t.from_agent)??"system",content:N(t.content)??"",timestamp:N(t.timestamp)??new Date().toISOString(),type:N(t.type)}:null}function Qc(t){return q(t)?{room_id:N(t.room_id),current_room:N(t.current_room)??N(t.room),project:N(t.project),cluster:N(t.cluster),paused:er(t.paused),pause_reason:N(t.pause_reason)??null,paused_by:N(t.paused_by)??null,paused_at:N(t.paused_at)??null}:{}}function ji(t){if(!q(t))return;const e=Object.entries(t).map(([n,a])=>{const s=N(a);return s?[n,s]:null}).filter(n=>n!==null);return e.length>0?Object.fromEntries(e):void 0}function Yc(t){if(!q(t))return null;const e=q(t.status)?t.status:void 0,n=q(t.summary)?t.summary:q(e==null?void 0:e.summary)?e.summary:void 0,a=q(t.session)?t.session:q(e==null?void 0:e.session)?e.session:void 0,s=N(t.session_id)??N(n==null?void 0:n.session_id)??N(a==null?void 0:a.session_id);if(!s)return null;const i=ji(t.report_paths)??ji(e==null?void 0:e.report_paths),r=me(t.recent_events,["events"]).filter(q);return{session_id:s,status:N(t.status)??N(n==null?void 0:n.status)??N(a==null?void 0:a.status),progress_pct:st(t.progress_pct)??st(n==null?void 0:n.progress_pct),elapsed_sec:st(t.elapsed_sec)??st(n==null?void 0:n.elapsed_sec),remaining_sec:st(t.remaining_sec)??st(n==null?void 0:n.remaining_sec),done_delta_total:st(t.done_delta_total)??st(n==null?void 0:n.done_delta_total),summary:n,team_health:q(t.team_health)?t.team_health:q(e==null?void 0:e.team_health)?e.team_health:void 0,communication_metrics:q(t.communication_metrics)?t.communication_metrics:q(e==null?void 0:e.communication_metrics)?e.communication_metrics:void 0,orchestration_state:q(t.orchestration_state)?t.orchestration_state:q(e==null?void 0:e.orchestration_state)?e.orchestration_state:void 0,cascade_metrics:q(t.cascade_metrics)?t.cascade_metrics:q(e==null?void 0:e.cascade_metrics)?e.cascade_metrics:void 0,report_paths:i,session:a,recent_events:r}}function Xc(t){if(!q(t))return null;const e=N(t.name);if(!e)return null;const n=q(t.context)?t.context:void 0;return{name:e,agent_name:N(t.agent_name),status:N(t.status),autonomy_level:N(t.autonomy_level),context_ratio:st(t.context_ratio)??st(n==null?void 0:n.context_ratio),generation:st(t.generation),active_goal_ids:Jc(t.active_goal_ids),last_autonomous_action_at:N(t.last_autonomous_action_at)??null,last_turn_ago_s:st(t.last_turn_ago_s),model:N(t.model)??N(t.active_model)??N(t.primary_model)}}function Zc(t){if(!q(t))return null;const e=N(t.confirm_token)??N(t.token);return e?{confirm_token:e,actor:N(t.actor),action_type:N(t.action_type),target_type:N(t.target_type),target_id:N(t.target_id)??null,delegated_tool:N(t.delegated_tool),created_at:N(t.created_at),preview:t.preview}:null}function tu(t){const e=q(t)?t:{};return{room:Qc(e.room),sessions:me(e.sessions,["items","sessions"]).map(Yc).filter(n=>n!==null),keepers:me(e.keepers,["items","keepers"]).map(Xc).filter(n=>n!==null),recent_messages:me(e.recent_messages,["messages"]).map(Vc).filter(n=>n!==null),pending_confirms:me(e.pending_confirms,["items","confirms"]).map(Zc).filter(n=>n!==null),available_actions:me(e.available_actions,["actions"]).filter(q).map(n=>({action_type:N(n.action_type)??"unknown",target_type:N(n.target_type)??"unknown",description:N(n.description),confirm_required:er(n.confirm_required)}))}}function En(t){if(typeof t=="string")return t;if(t==null)return"";try{return JSON.stringify(t)}catch{return String(t)}}function zi(t){return t.target_id?`${t.target_type}:${t.target_id}`:t.target_type}function ra(t){oa.value=[{...t,id:Gc++,at:new Date().toISOString()},...oa.value].slice(0,20)}function nr(t){return t.confirm_required?En(t.preview)||"Confirmation required":En(t.result)||En(t.executed_action)||En(t.delegated_tool_result)||t.status}async function Ae(){ia.value=!0,Gt.value=null;try{const t=await pl();Sn.value=tu(t)}catch(t){Gt.value=t instanceof Error?t.message:"Failed to load operator snapshot"}finally{ia.value=!1}}async function eu(t){z.value=!0,Gt.value=null;try{const e=await Ho(t);return ra({actor:t.actor,action_type:t.action_type,target_label:zi(t),outcome:e.confirm_required?"preview":"executed",message:nr(e),delegated_tool:e.delegated_tool}),await Ae(),e}catch(e){const n=e instanceof Error?e.message:"Operator action failed";throw Gt.value=n,ra({actor:t.actor,action_type:t.action_type,target_label:zi(t),outcome:"error",message:n}),e}finally{z.value=!1}}async function nu(t,e){z.value=!0,Gt.value=null;try{const n=await vl(t,e);return ra({actor:t,action_type:"confirm",target_label:e,outcome:"confirmed",message:nr(n),delegated_tool:n.delegated_tool}),await Ae(),n}catch(n){const a=n instanceof Error?n.message:"Operator confirmation failed";throw Gt.value=a,ra({actor:t,action_type:"confirm",target_label:e,outcome:"error",message:a}),n}finally{z.value=!1}}const ar="masc_dashboard_agent_name";function au(){var e,n,a;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||((a=localStorage.getItem(ar))==null?void 0:a.trim())||"dashboard"}const Na=_(au()),We=_(""),Ns=_("Operator pause"),Ge=_(""),la=_(""),Cs=_("2"),ca=_(""),xe=_("note"),ua=_(""),da=_(""),pa=_(""),Rs=_("2"),Ls=_("Operator stop request"),Ds=_(""),Je=_("");function su(t){const e=t.trim()||"dashboard";Na.value=e,localStorage.setItem(ar,e)}function qi(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function iu(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":t<60?`${Math.round(t)}s ago`:t<3600?`${Math.round(t/60)}m ago`:`${Math.round(t/3600)}h ago`}function va(t){return typeof t=="string"?t.trim().toLowerCase():""}function ou(t){var a;const e=va(t.status);if(e==="paused")return"bad";const n=va((a=t.team_health)==null?void 0:a.status);return n&&n!=="ok"&&n!=="healthy"&&n!=="green"||e&&e!=="active"&&e!=="running"&&e!=="ended"?"warn":"ok"}function Hi(t){const e=va(t.status);return e==="offline"||e==="inactive"||e==="error"?"bad":(t.context_ratio??0)>=.8||(t.last_turn_ago_s??0)>=3600?"warn":"ok"}async function oe(t){const e=Na.value.trim()||"dashboard";try{const n=await eu({actor:e,action_type:t.action_type,target_type:t.target_type,target_id:t.target_id,payload:t.payload});return n.confirm_required?y("Confirmation queued","warning"):y(t.successMessage,"success"),n}catch(n){const a=n instanceof Error?n.message:"Operator action failed";return y(a,"error"),null}}async function Ui(){const t=We.value.trim();if(!t)return;await oe({action_type:"broadcast",target_type:"room",payload:{message:t},successMessage:"Broadcast sent"})&&(We.value="")}async function ru(){await oe({action_type:"room_pause",target_type:"room",payload:{reason:Ns.value.trim()||"Operator pause"},successMessage:"Pause request sent"})}async function lu(){await oe({action_type:"room_resume",target_type:"room",payload:{},successMessage:"Room resumed"})}async function cu(){const t=Ge.value.trim();if(!t)return;await oe({action_type:"task_inject",target_type:"room",payload:{title:t,description:la.value.trim()||"Injected from Ops tab",priority:Number.parseInt(Cs.value,10)||2},successMessage:"Task injection submitted"})&&(Ge.value="",la.value="")}async function uu(){var i;const t=Sn.value,e=ca.value||((i=t==null?void 0:t.sessions[0])==null?void 0:i.session_id)||"";if(!e){y("Select a team session first","warning");return}const n={turn_kind:xe.value},a=ua.value.trim();a&&(n.message=a),xe.value==="task"&&(n.task_title=da.value.trim()||"Operator injected task",n.task_description=pa.value.trim()||"Injected from Ops tab",n.task_priority=Number.parseInt(Rs.value,10)||2),await oe({action_type:"team_turn",target_type:"team_session",target_id:e,payload:n,successMessage:"Team session updated"})&&(ua.value="",xe.value==="task"&&(da.value="",pa.value=""))}async function du(){var n;const t=Sn.value,e=ca.value||((n=t==null?void 0:t.sessions[0])==null?void 0:n.session_id)||"";if(!e){y("Select a team session first","warning");return}await oe({action_type:"team_stop",target_type:"team_session",target_id:e,payload:{reason:Ls.value.trim()||"Operator stop request"},successMessage:"Team stop requested"})}async function pu(){var s;const t=Sn.value,e=Ds.value||((s=t==null?void 0:t.keepers[0])==null?void 0:s.name)||"",n=Je.value.trim();if(!e){y("Select a keeper first","warning");return}if(!n)return;await oe({action_type:"keeper_msg",target_type:"keeper",target_id:e,payload:{message:n},successMessage:`Message sent to ${e}`})&&(Je.value="")}async function vu(t){const e=Na.value.trim()||"dashboard";try{await nu(e,t),y("Confirmation executed","success")}catch(n){const a=n instanceof Error?n.message:"Confirmation failed";y(a,"error")}}function mu(){var l;Dt(()=>{Ae()},[]);const t=Sn.value,e=(t==null?void 0:t.room)??{},n=(t==null?void 0:t.sessions)??[],a=(t==null?void 0:t.keepers)??[],s=(t==null?void 0:t.pending_confirms)??[],i=(t==null?void 0:t.recent_messages)??[],r=n.find(c=>c.session_id===ca.value)??n[0]??null,u=a.find(c=>c.name===Ds.value)??a[0]??null,d=n.filter(c=>ou(c)!=="ok"),p=a.filter(c=>Hi(c)!=="ok"),f=[{key:"room",label:"Room Gate",value:e.paused?"Paused":"Open",detail:e.paused?`Resume gate armed${e.pause_reason?` · ${e.pause_reason}`:""}`:"Commands are live and the room is accepting new work",tone:e.paused?"bad":"ok"},{key:"confirm",label:"Pending Confirm",value:s.length,detail:s.length>0?"Previewed operator actions are waiting for confirmation":"No confirm gates are currently blocking execution",tone:s.length>0?"warn":"ok"},{key:"session",label:"Session Risk",value:d.length,detail:d.length>0?"Team sessions need steering, stop, or checkpoint attention":"Team sessions look healthy from the operator snapshot",tone:d.some(c=>va(c.status)==="paused")?"bad":d.length>0?"warn":"ok"},{key:"keeper",label:"Keeper Pressure",value:p.length,detail:p.length>0?"At least one keeper is stale, offline, or running hot":"Keepers are available for direct intervention",tone:p.some(c=>Hi(c)==="bad")?"bad":p.length>0?"warn":"ok"}];return o`
    <section class="ops-view">
      <div class="ops-header card">
        <div>
          <div class="card-title">Operator Control</div>
          <h2 class="ops-heading">Guided control for room, sessions, and keepers</h2>
          <p class="ops-subheading">
            Structured actions only. Destructive changes remain behind confirmation tokens.
          </p>
        </div>
        <div class="ops-toolbar">
          <label class="control-label" for="ops-actor">Actor</label>
          <input
            id="ops-actor"
            class="control-input ops-actor-input"
            type="text"
            value=${Na.value}
            onInput=${c=>su(c.target.value)}
          />
          <button class="control-btn ghost" onClick=${()=>{Ae()}} disabled=${ia.value||z.value}>
            ${ia.value?"Refreshing...":"Refresh"}
          </button>
        </div>
      </div>

      ${Gt.value?o`
        <section class="ops-banner error">${Gt.value}</section>
      `:null}

      <section class="card">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Action Priority</h2>
          <p class="monitor-subheadline">Ops is the command surface. These four signals explain when to intervene before you drop into a specific control panel.</p>
        </div>
        <div class="ops-priority-grid">
          ${f.map(c=>o`
            <div key=${c.key} class="ops-priority-card ${c.tone}">
              <span class="ops-priority-label">${c.label}</span>
              <strong>${c.value}</strong>
              <div class="ops-priority-detail">${c.detail}</div>
            </div>
          `)}
        </div>
      </section>

      ${s.length>0?o`
        <section class="card ops-confirmations">
          <div class="card-title">Pending Confirmations</div>
          <p class="ops-context-note">Only previewed actions that still need an explicit operator confirmation stay here.</p>
          <div class="ops-confirmation-list">
            ${s.map(c=>o`
              <article key=${c.confirm_token} class="ops-confirmation-card">
                <div class="ops-confirmation-meta">
                  <strong>${c.action_type??"unknown"}</strong>
                  <span>${c.target_type??"target"}${c.target_id?`:${c.target_id}`:""}</span>
                  <span>${c.delegated_tool??"delegated tool pending"}</span>
                </div>
                ${c.preview?o`<pre class="ops-code-block">${qi(c.preview)}</pre>`:null}
                <div class="ops-confirmation-actions">
                  <button class="control-btn" onClick=${()=>{vu(c.confirm_token)}} disabled=${z.value}>
                    Confirm
                  </button>
                  <span class="ops-token">${c.confirm_token}</span>
                </div>
              </article>
            `)}
          </div>
        </section>
      `:null}

      <div class="ops-grid">
        <section class="card ops-panel">
          <div class="card-title">Room Control</div>
          <div class="ops-stat-grid">
            <div class="ops-stat">
              <span>Room</span>
              <strong>${e.current_room??e.room_id??"default"}</strong>
            </div>
            <div class="ops-stat">
              <span>Project</span>
              <strong>${e.project??"n/a"}</strong>
            </div>
            <div class="ops-stat">
              <span>Cluster</span>
              <strong>${e.cluster??"n/a"}</strong>
            </div>
            <div class="ops-stat ${e.paused?"warn":"ok"}">
              <span>Status</span>
              <strong>${e.paused?"Paused":"Running"}</strong>
            </div>
          </div>

          <label class="control-label" for="ops-broadcast">Broadcast</label>
          <div class="control-row">
            <input
              id="ops-broadcast"
              class="control-input"
              type="text"
              placeholder="@agent or room-wide operator update"
              value=${We.value}
              onInput=${c=>{We.value=c.target.value}}
              onKeyDown=${c=>{c.key==="Enter"&&Ui()}}
              disabled=${z.value}
            />
            <button class="control-btn" onClick=${()=>{Ui()}} disabled=${z.value||We.value.trim()===""}>
              Send
            </button>
          </div>

          <label class="control-label" for="ops-pause-reason">Pause Reason</label>
          <div class="control-row ops-split-row">
            <input
              id="ops-pause-reason"
              class="control-input"
              type="text"
              value=${Ns.value}
              onInput=${c=>{Ns.value=c.target.value}}
              disabled=${z.value}
            />
            <button class="control-btn ghost" onClick=${()=>{ru()}} disabled=${z.value}>
              Pause
            </button>
            <button class="control-btn ghost" onClick=${()=>{lu()}} disabled=${z.value}>
              Resume
            </button>
          </div>

          <div class="ops-section-head">Task Inject</div>
          <input
            class="control-input"
            type="text"
            placeholder="Task title"
            value=${Ge.value}
            onInput=${c=>{Ge.value=c.target.value}}
            disabled=${z.value}
          />
          <textarea
            class="control-textarea"
            rows=${3}
            placeholder="Task description"
            value=${la.value}
            onInput=${c=>{la.value=c.target.value}}
            disabled=${z.value}
          ></textarea>
          <div class="control-row ops-split-row">
            <select
              class="control-input ops-select"
              value=${Cs.value}
              onChange=${c=>{Cs.value=c.target.value}}
              disabled=${z.value}
            >
              <option value="1">P1</option>
              <option value="2">P2</option>
              <option value="3">P3</option>
              <option value="4">P4</option>
              <option value="5">P5</option>
            </select>
            <button class="control-btn" onClick=${()=>{cu()}} disabled=${z.value||Ge.value.trim()===""}>
              Inject
            </button>
          </div>

          ${i.length>0?o`
            <div class="ops-section-head">Context Tail</div>
            <div class="ops-context-note">Recent room chatter stays available for context, but command work remains the primary focus of this tab.</div>
            <div class="ops-feed-list">
              ${i.slice(0,6).map(c=>o`
                <article key=${c.seq??c.id??c.timestamp} class="ops-feed-item">
                  <div class="ops-feed-meta">
                    <strong>${c.from}</strong>
                    <span>${c.timestamp}</span>
                  </div>
                  <div class="ops-feed-content">${c.content}</div>
                </article>
              `)}
            </div>
          `:null}
        </section>

        <section class="card ops-panel">
          <div class="card-title">Team Sessions</div>
          <div class="ops-entity-list">
            ${n.length===0?o`<div class="ops-empty">No team sessions available.</div>`:n.map(c=>{var v;return o`
              <button
                key=${c.session_id}
                class="ops-entity-card ${(r==null?void 0:r.session_id)===c.session_id?"active":""}"
                onClick=${()=>{ca.value=c.session_id}}
              >
                <div class="ops-entity-title-row">
                  <strong>${c.session_id}</strong>
                  <span class="status-badge ${c.status??"idle"}">${c.status??"unknown"}</span>
                </div>
                <div class="ops-entity-meta">
                  <span>${Math.round(c.progress_pct??0)}%</span>
                  <span>${c.done_delta_total??0} done</span>
                  <span>${(v=c.team_health)!=null&&v.status?String(c.team_health.status):"health n/a"}</span>
                </div>
              </button>
            `})}
          </div>

          ${r?o`
            <div class="ops-detail-card">
              <div class="ops-detail-title">${r.session_id}</div>
              <div class="ops-detail-meta">
                <span>Status: ${r.status??"unknown"}</span>
                <span>Elapsed: ${r.elapsed_sec??0}s</span>
                <span>Remaining: ${r.remaining_sec??0}s</span>
              </div>
              ${r.recent_events&&r.recent_events.length>0?o`
                <pre class="ops-code-block compact">${qi(r.recent_events.slice(-3))}</pre>
              `:null}
            </div>
          `:null}

          <label class="control-label" for="ops-turn-kind">Session Action</label>
          <div class="control-row ops-split-row">
            <select
              id="ops-turn-kind"
              class="control-input ops-select"
              value=${xe.value}
              onChange=${c=>{xe.value=c.target.value}}
              disabled=${z.value||!r}
            >
              <option value="note">Note</option>
              <option value="broadcast">Broadcast</option>
              <option value="task">Task</option>
              <option value="checkpoint">Checkpoint</option>
            </select>
            <button class="control-btn" onClick=${()=>{uu()}} disabled=${z.value||!r}>
              Apply
            </button>
          </div>
          <textarea
            class="control-textarea"
            rows=${3}
            placeholder="Session message"
            value=${ua.value}
            onInput=${c=>{ua.value=c.target.value}}
            disabled=${z.value||!r}
          ></textarea>
          ${xe.value==="task"?o`
            <input
              class="control-input"
              type="text"
              placeholder="Injected task title"
              value=${da.value}
              onInput=${c=>{da.value=c.target.value}}
              disabled=${z.value||!r}
            />
            <textarea
              class="control-textarea"
              rows=${2}
              placeholder="Injected task description"
              value=${pa.value}
              onInput=${c=>{pa.value=c.target.value}}
              disabled=${z.value||!r}
            ></textarea>
            <select
              class="control-input ops-select"
              value=${Rs.value}
              onChange=${c=>{Rs.value=c.target.value}}
              disabled=${z.value||!r}
            >
              <option value="1">P1</option>
              <option value="2">P2</option>
              <option value="3">P3</option>
              <option value="4">P4</option>
              <option value="5">P5</option>
            </select>
          `:null}

          <div class="ops-section-head">Stop Session</div>
          <div class="control-row ops-split-row">
            <input
              class="control-input"
              type="text"
              value=${Ls.value}
              onInput=${c=>{Ls.value=c.target.value}}
              disabled=${z.value||!r}
            />
            <button class="control-btn ghost" onClick=${()=>{du()}} disabled=${z.value||!r}>
              Stop
            </button>
          </div>
        </section>

        <section class="card ops-panel">
          <div class="card-title">Keepers</div>
          <div class="ops-entity-list">
            ${a.length===0?o`<div class="ops-empty">No keepers available.</div>`:a.map(c=>o`
              <button
                key=${c.name}
                class="ops-entity-card ${(u==null?void 0:u.name)===c.name?"active":""}"
                onClick=${()=>{Ds.value=c.name}}
              >
                <div class="ops-entity-title-row">
                  <strong>${c.name}</strong>
                  <span class="status-badge ${c.status??"idle"}">${c.status??"unknown"}</span>
                </div>
                <div class="ops-entity-meta">
                  <span>${c.model??"model n/a"}</span>
                  <span>${typeof c.context_ratio=="number"?`${Math.round(c.context_ratio*100)}% ctx`:"ctx n/a"}</span>
                  <span>${iu(c.last_turn_ago_s)}</span>
                </div>
              </button>
            `)}
          </div>

          ${u?o`
            <div class="ops-detail-card">
              <div class="ops-detail-title">${u.name}</div>
              <div class="ops-detail-meta">
                <span>Autonomy: ${u.autonomy_level??"n/a"}</span>
                <span>Generation: ${u.generation??0}</span>
                <span>Goals: ${((l=u.active_goal_ids)==null?void 0:l.length)??0}</span>
              </div>
            </div>
          `:null}

          <label class="control-label" for="ops-keeper-message">Keeper Message</label>
          <textarea
            id="ops-keeper-message"
            class="control-textarea"
            rows=${6}
            placeholder="Send a structured intervention or course correction"
            value=${Je.value}
            onInput=${c=>{Je.value=c.target.value}}
            disabled=${z.value||!u}
          ></textarea>
          <div class="control-row">
            <button class="control-btn" onClick=${()=>{pu()}} disabled=${z.value||!u||Je.value.trim()===""}>
              Send Keeper Message
            </button>
          </div>
        </section>
      </div>

      <section class="card ops-log-panel">
        <div class="card-title">Recent Operator Actions</div>
        <div class="ops-log-list">
          ${oa.value.length===0?o`
            <div class="ops-empty">No operator actions in this session yet.</div>
          `:oa.value.map(c=>o`
            <article key=${c.id} class="ops-log-entry ${c.outcome}">
              <div class="ops-log-head">
                <strong>${c.action_type}</strong>
                <span>${c.target_label}</span>
                <span>${c.at}</span>
              </div>
              <div class="ops-log-body">${c.message}</div>
            </article>
          `)}
        </div>
      </section>
    </section>
  `}const Es=_([]),Is=_([]),Ve=_(""),ma=_(!1),Qe=_(!1),_n=_(""),fa=_(null),dt=_(null),Ps=_(!1);async function Ms(){ma.value=!0,_n.value="";try{const[t,e]=await Promise.all([Vl(),Ql()]);Es.value=t,Is.value=e}catch(t){_n.value=t instanceof Error?t.message:"Failed to load council data"}finally{ma.value=!1}}async function Ki(){const t=Ve.value.trim();if(t){Qe.value=!0;try{const e=await Yl(t);Ve.value="",y(e!=null&&e.id?`Debate started: ${e.id}`:"Debate started","success"),await Ms()}catch(e){const n=e instanceof Error?e.message:"Failed to start debate";y(n,"error")}finally{Qe.value=!1}}}async function fu(t){fa.value=t,Ps.value=!0,dt.value=null;try{dt.value=await Xl(t)}catch(e){_n.value=e instanceof Error?e.message:"Failed to load debate status",dt.value=null}finally{Ps.value=!1}}function _u({debate:t}){const e=fa.value===t.id;return o`
    <button
      class="council-row ${e?"selected":""}"
      onClick=${()=>fu(t.id)}
    >
      <div class="council-row-main">
        <div class="council-topic">${t.topic}</div>
        <div class="council-sub">
          <span>ID: ${t.id.slice(0,10)}</span>
          <span>Args: ${t.argument_count}</span>
        </div>
      </div>
      <span class="council-state ${t.status}">${t.status}</span>
    </button>
  `}function gu({session:t}){return o`
    <div class="council-row session">
      <div class="council-row-main">
        <div class="council-topic">${t.topic}</div>
        <div class="council-sub">
          <span>ID: ${t.id.slice(0,10)}</span>
          <span>Initiator: ${t.initiator}</span>
          ${t.state?o`<span>State: ${t.state}</span>`:null}
        </div>
      </div>
      <span class="council-state vote">${t.votes}/${t.quorum}</span>
    </div>
  `}function hu(){var e;const t=(e=Vt.value)==null?void 0:e.data_quality;return!t||t.council_feed_ok!==!1&&!t.last_sync_at?null:o`
    <div class="feed-health-banner ${t.council_feed_ok===!1?"degraded":"ok"}">
      <span class="feed-health-title">
        ${t.council_feed_ok===!1?"Council feed degraded":"Council feed synced"}
      </span>
      ${t.last_sync_at?o`<span class="feed-health-meta">Last sync: <${j} timestamp=${t.last_sync_at} /></span>`:o`<span class="feed-health-meta">No sync timestamp</span>`}
    </div>
  `}function $u(){var e,n;Dt(()=>{Ms()},[]);const t=((n=(e=Vt.value)==null?void 0:e.data_quality)==null?void 0:n.council_feed_ok)===!1;return o`
    <div>
      <${hu} />
      <${b} title="Council Command" class="section">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${Ve.value}
            onInput=${a=>{Ve.value=a.target.value}}
            onKeyDown=${a=>{a.key==="Enter"&&Ki()}}
            disabled=${Qe.value}
          />
          <button
            class="control-btn secondary"
            onClick=${Ki}
            disabled=${Qe.value||Ve.value.trim()===""}
          >
            ${Qe.value?"Starting...":"Start Debate"}
          </button>
          <button class="control-btn ghost" onClick=${Ms} disabled=${ma.value}>
            ${ma.value?"Refreshing...":"Refresh"}
          </button>
        </div>
        ${_n.value?o`<div class="council-error">${_n.value}</div>`:null}
      <//>

      <div class="council-grid">
        <${b} title="Debates" class="section">
          <div class="council-list">
            ${Es.value.length===0?o`
                  <div class="empty-state">
                    ${t?"No debates loaded (council feed degraded).":"No debates yet"}
                  </div>
                `:Es.value.map(a=>o`<${_u} key=${a.id} debate=${a} />`)}
          </div>
        <//>

        <${b} title="Voting Sessions" class="section">
          <div class="council-list">
            ${Is.value.length===0?o`
                  <div class="empty-state">
                    ${t?"No sessions loaded (council feed degraded).":"No active sessions"}
                  </div>
                `:Is.value.map(a=>o`<${gu} key=${a.id} session=${a} />`)}
          </div>
        <//>
      </div>

      <${b} title=${fa.value?`Debate Detail (${fa.value})`:"Debate Detail"} class="section">
        ${Ps.value?o`<div class="loading-indicator">Loading debate detail...</div>`:dt.value?o`
                <div class="council-sub" style="margin-bottom: 8px;">
                  <span>Status: ${dt.value.status}</span>
                  <span>Total arguments: ${dt.value.total_arguments}</span>
                </div>
                <div class="council-sub" style="margin-bottom: 8px;">
                  <span>Support: ${dt.value.support_count}</span>
                  <span>Oppose: ${dt.value.oppose_count}</span>
                  <span>Neutral: ${dt.value.neutral_count}</span>
                </div>
                ${dt.value.summary_text?o`<pre class="council-detail">${dt.value.summary_text}</pre>`:null}
              `:o`<div class="empty-state">Select a debate to view summary</div>`}
      <//>
    </div>
  `}function yu({text:t}){if(!t)return null;const e=bu(t);return o`<div class="markdown-content">${e}</div>`}function bu(t){const e=t.split(`
`),n=[];let a=0;for(;a<e.length;){const s=e[a];if(/^(`{3,}|~{3,})/.test(s)){const r=s.match(/^(`{3,}|~{3,})/)[0],u=s.slice(r.length).trim(),d=[];for(a++;a<e.length&&!e[a].startsWith(r);)d.push(e[a]),a++;a++,n.push(o`<pre><code class=${u?`language-${u}`:""}>${d.join(`
`)}</code></pre>`);continue}if(s.trim()==="<think>"||s.trim().startsWith("<think>")){const r=[],u=s.trim().replace(/^<think>/,"").trim();for(u&&u!=="</think>"&&r.push(u),a++;a<e.length&&!e[a].includes("</think>");)r.push(e[a]),a++;if(a<e.length){const p=e[a].replace("</think>","").trim();p&&r.push(p),a++}const d=r.join(`
`).trim();n.push(o`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${Ha(d)}</div>
        </details>
      `);continue}if(s.startsWith("> ")){const r=[];for(;a<e.length&&e[a].startsWith("> ");)r.push(e[a].slice(2)),a++;n.push(o`<blockquote>${Ha(r.join(`
`))}</blockquote>`);continue}if(s.trim()===""){a++;continue}const i=[];for(;a<e.length;){const r=e[a];if(r.trim()===""||/^(`{3,}|~{3,})/.test(r)||r.startsWith("> ")||r.trim().startsWith("<think>"))break;i.push(r),a++}i.length>0&&n.push(o`<p>${Ha(i.join(`
`))}</p>`)}return n}function Ha(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let a=0,s;for(;(s=n.exec(t))!==null;){if(s.index>a&&e.push(t.slice(a,s.index)),s[1]){const i=s[1].slice(1,-1);e.push(o`<code>${i}</code>`)}else if(s[2]){const i=s[2].slice(2,-2);e.push(o`<strong>${i}</strong>`)}else if(s[3]){const i=s[3].slice(1,-1);e.push(o`<em>${i}</em>`)}else s[4]&&s[5]&&e.push(o`<a href=${s[5]} target="_blank" rel="noopener">${s[4]}</a>`);a=s.index+s[0].length}return a<t.length&&e.push(t.slice(a)),e.length>0?e:[t]}const sr=[{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"recent",label:"Recent"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],Wn=_(null),Ye=_([]),ne=_(!1),ee=_(null),Xe=_("");function ku(){var e,n;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}const xu=_(ku()),Ze=_(!1);async function ai(t){ee.value=t,Wn.value=null,Ye.value=[],ne.value=!0;try{const e=await yl(t);if(ee.value!==t)return;Wn.value={id:e.id,author:e.author,title:e.title,content:e.content,tags:e.tags,votes:e.votes,vote_balance:e.vote_balance,comment_count:e.comment_count,created_at:e.created_at,updated_at:e.updated_at,flair:e.flair,hearth_count:e.hearth_count},Ye.value=e.comments??[]}catch{ee.value===t&&(Wn.value=null,Ye.value=[])}finally{ee.value===t&&(ne.value=!1)}}async function Bi(t){const e=Xe.value.trim();if(e){Ze.value=!0;try{await bl(t,xu.value,e),Xe.value="",y("Comment posted","success"),await ai(t),At()}catch{y("Failed to post comment","error")}finally{Ze.value=!1}}}function wu(){const t=un.value;return o`
    <div class="board-toolbar">
      <div class="board-controls">
        ${sr.map(e=>o`
          <button
            class="board-sort-btn ${t===e.id?"active":""}"
            onClick=${()=>{un.value=e.id,At()}}
          >
            ${e.label}
          </button>
        `)}
      </div>
      <div class="board-toolbar-actions">
        <button
          class="control-btn ghost ${Zt.value?"is-active":""}"
          onClick=${()=>{Zt.value=!Zt.value,At()}}
        >
          ${Zt.value?"Hiding auto reports":"Show auto reports"}
        </button>
        <button class="control-btn ghost" onClick=${At} disabled=${pn.value}>
          ${pn.value?"Refreshing...":"Refresh"}
        </button>
      </div>
    </div>
  `}function Ua(){var e;const t=(e=Vt.value)==null?void 0:e.data_quality;return!t||t.board_contract_ok!==!1&&!t.last_sync_at?null:o`
    <div class="feed-health-banner ${t.board_contract_ok===!1?"degraded":"ok"}">
      <span class="feed-health-title">
        ${t.board_contract_ok===!1?"Board feed degraded":"Board feed synced"}
      </span>
      ${t.last_sync_at?o`<span class="feed-health-meta">Last sync: <${j} timestamp=${t.last_sync_at} /></span>`:o`<span class="feed-health-meta">No sync timestamp</span>`}
    </div>
  `}function ir({flair:t}){return t?o`<span class="post-flair ${t}">${t}</span>`:null}function Su(t){const e=t.replace(/!\[[^\]]*\]\([^)]+\)/g," ").replace(/\[[^\]]+\]\([^)]+\)/g,"$1").replace(/[`#>*_~-]/g," ").replace(/\s+/g," ").trim();return e?e.length>180?`${e.slice(0,177)}...`:e:"No preview available"}function Wi(t){return t.updated_at!==t.created_at}function Ka(){var n;const t=((n=sr.find(a=>a.id===un.value))==null?void 0:n.label)??un.value,e=It.value.length;return o`
    <div class="board-summary-strip">
      <div class="board-summary-item">
        <span class="board-summary-label">Visible posts</span>
        <strong>${e}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Sort</span>
        <strong>${t}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Noise policy</span>
        <strong>${Zt.value?"Auto reports hidden by default":"All posts visible"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Last refresh</span>
        <strong>${Ts.value?o`<${j} timestamp=${Ts.value} />`:"Not loaded"}</strong>
      </div>
    </div>
  `}function Au({post:t}){const e=async(n,a)=>{a.stopPropagation();try{await Ko(t.id,n),At()}catch{y("Failed to vote","error")}};return o`
    <div class="board-post" onClick=${()=>Wr(t.id)}>
      <div class="vote-column">
        <button class="vote-btn upvote" onClick=${n=>e("up",n)}>▲</button>
        <span class="vote-count">${t.votes??0}</span>
        <button class="vote-btn downvote" onClick=${n=>e("down",n)}>▼</button>
      </div>
      <div class="post-content">
        <div class="post-head">
          <div class="post-title-row">
            <div class="post-title">${t.title}</div>
            <div class="post-chip-row">
              <${ir} flair=${t.flair} />
              ${Wi(t)?o`<span class="board-meta-chip">Updated</span>`:null}
            </div>
          </div>
          <div class="post-meta">
            <span>By ${t.author}</span>
            <span><${j} timestamp=${t.created_at} /></span>
            ${Wi(t)?o`<span>Updated <${j} timestamp=${t.updated_at} /></span>`:null}
            <span>${t.comment_count} comments</span>
            <span>${t.votes??0} votes</span>
            ${(t.hearth_count??0)>0?o`<span>♥ ${t.hearth_count}</span>`:null}
          </div>
        </div>
        <div class="post-snippet">${Su(t.content)}</div>
      </div>
    </div>
  `}function Tu({comments:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No comments yet</div>`:o`
    <div class="comment-thread">
      ${t.map(e=>o`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${j} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function Nu({postId:t}){return o`
    <div class="comment-form" style="margin-top: 12px; display: flex; gap: 8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${Xe.value}
        onInput=${e=>{Xe.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&Bi(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${Ze.value}
      />
      <button
        onClick=${()=>Bi(t)}
        disabled=${Ze.value||Xe.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${Ze.value?"...":"Post"}
      </button>
    </div>
  `}function Cu({post:t}){ee.value!==t.id&&!ne.value&&ai(t.id);const e=async n=>{try{await Ko(t.id,n),At()}catch{y("Failed to vote","error")}};return o`
    <div>
      <button class="back-btn" onClick=${()=>pt("board")}>← Back to Board</button>
      <${b} title=${o`${t.title} <${ir} flair=${t.flair} />`}>
        <div class="board-detail">
          <div class="post-body">
            <${yu} text=${t.content} />
          </div>
          <div class="post-meta" style="margin-top: 12px;">
            <span>${t.author}</span>
            <${j} timestamp=${t.created_at} />
            <span>${t.votes??0} votes</span>
            ${(t.hearth_count??0)>0?o`<span>♥ ${t.hearth_count}</span>`:null}
          </div>
          <div style="margin-top: 8px; display: flex; gap: 6px;">
            <button class="vote-btn upvote" onClick=${()=>e("up")}>▲ Upvote</button>
            <button class="vote-btn downvote" onClick=${()=>e("down")}>▼ Downvote</button>
          </div>
        </div>
      <//>

      <${b} title="Comments (${ne.value?"...":Ye.value.length})">
        ${ne.value?o`<div class="loading-indicator">Loading comments...</div>`:o`<${Tu} comments=${Ye.value} />`}
        <${Nu} postId=${t.id} />
      <//>
    </div>
  `}function Ru(){var s,i;const t=It.value,e=pn.value,n=St.value.postId,a=((i=(s=Vt.value)==null?void 0:s.data_quality)==null?void 0:i.board_contract_ok)===!1;if(n){const r=t.find(u=>u.id===n)??(ee.value===n?Wn.value:null);return!r&&ee.value!==n&&!ne.value&&ai(n),r?o`
          <${Ua} />
          <${Ka} />
          <${Cu} post=${r} />
        `:o`
          <div>
            <${Ua} />
            <${Ka} />
            <button class="back-btn" onClick=${()=>pt("board")}>← Back to Board</button>
            ${ne.value?o`<div class="loading-indicator">Loading post...</div>`:o`
                  <div class="empty-state">
                    ${a?"Post not available while board feed is degraded":"Post not found"}
                  </div>
                `}
          </div>
        `}return o`
    <${Ua} />
    <${Ka} />
    <${wu} />
    ${e?o`<div class="loading-indicator">Loading board...</div>`:t.length===0?o`
            <div class="empty-state">
              ${a?"No posts loaded (board feed degraded). Check board contract sync.":Zt.value?"No visible posts right now. Automated reports may be hidden; toggle them back on if you need the raw feed.":"No posts yet"}
            </div>
          `:o`<div class="board-post-list">
            ${t.map(r=>o`<${Au} key=${r.id} post=${r} />`)}
          </div>`}
  `}function Lu(t){if(t.kind)return t.kind;switch(t.eventType){case"board_post":case"board_comment":return"board";case"task_update":return"tasks";case"keeper_heartbeat":case"keeper_handoff":case"keeper_compaction":case"keeper_guardrail":return"keepers";default:return"system"}}function Du(t){var e,n;return((e=t.author)==null?void 0:e.trim())||((n=t.agent)==null?void 0:n.trim())||"system"}function Eu(t){switch(t.eventType){case"board_post":return t.preview?`Post: ${t.preview}`:t.text||"New post";case"board_comment":return t.preview?`Comment: ${t.preview}`:t.text||"New comment";default:return t.text}}const or=120,Iu=12,Pu=16,Mu=12,Os=_("all"),Ou={all:"All",messages:"Messages",board:"Board",tasks:"Tasks",keepers:"Keepers",system:"System"},Fu={messages:"MSG",board:"BOARD",tasks:"TASK",keepers:"KEEPER",system:"SYS"};function ju(t,e){return{id:t.id??`msg-${t.seq??e}`,source:"message",kind:"messages",actor:t.from??"system",content:t.content,timestamp:t.timestamp}}function zu(t,e){return{id:t.postId?`evt-${t.eventType??"event"}-${t.postId}-${e}`:`evt-${t.timestamp}-${e}`,source:"event",kind:Lu(t),actor:Du(t),content:Eu(t),timestamp:new Date(t.timestamp).toISOString()}}function qu(t,e){var s;const n=(s=t.assignee)==null?void 0:s.trim(),a=t.updated_at??t.created_at;return!n||!a?null:{id:`task-${t.id}-${e}`,source:"snapshot",kind:"tasks",actor:n,content:`Task: ${t.title} (${t.status})`,timestamp:a}}function Hu(t,e){return{id:`board-${t.id}-${e}`,source:"snapshot",kind:"board",actor:t.author,content:`Post: ${t.title||t.content}`,timestamp:t.updated_at||t.created_at}}function In(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function Fs(t){return t.last_heartbeat??In(t.last_turn_ago_s)??In(t.last_proactive_ago_s)??In(t.last_handoff_ago_s)??In(t.last_compaction_ago_s)}function Uu(t,e){const n=Fs(t);if(!n)return null;const a=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return{id:`keeper-${t.name}-${e}`,source:"snapshot",kind:"keepers",actor:t.name,content:t.last_heartbeat?`Heartbeat gen=${t.generation??"?"} ctx=${a}`:`Keeper snapshot gen=${t.generation??"?"} ctx=${a}`,timestamp:n}}function yt(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}const js=it(()=>{const t=se.value.map(ju),e=Wt.value.map(zu),n=[...Tt.value].sort((i,r)=>yt(r.updated_at??r.created_at??0)-yt(i.updated_at??i.created_at??0)).slice(0,Iu).map(qu).filter(i=>i!==null),a=[...It.value].sort((i,r)=>yt(r.updated_at||r.created_at)-yt(i.updated_at||i.created_at)).slice(0,Pu).map(Hu),s=[...ft.value].sort((i,r)=>yt(Fs(r)??0)-yt(Fs(i)??0)).slice(0,Mu).map(Uu).filter(i=>i!==null);return[...t,...e,...n,...a,...s].sort((i,r)=>yt(r.timestamp)-yt(i.timestamp))}),Ku=it(()=>{const t=js.value;return{total:t.length,messages:t.filter(e=>e.kind==="messages").length,board:t.filter(e=>e.kind==="board").length,tasks:t.filter(e=>e.kind==="tasks").length,keepers:t.filter(e=>e.kind==="keepers").length,system:t.filter(e=>e.kind==="system").length}}),Bu=it(()=>{const t=Os.value;return(t==="all"?js.value:js.value.filter(n=>n.kind===t)).slice(0,or)}),Wu=it(()=>Jt.value.map(t=>({agent:t,motion:vn(t.name,Tt.value,se.value,Wt.value,{currentTask:t.current_task,lastSeen:t.last_seen,boardPosts:It.value,keepers:ft.value})})).sort((t,e)=>{const n=e.motion.activeAssignedCount-t.motion.activeAssignedCount;return n!==0?n:yt(e.motion.lastActivityAt??0)-yt(t.motion.lastActivityAt??0)}));function Gu(t){const e=new Date(t);return Number.isNaN(e.getTime())?"00:00:00":e.toLocaleTimeString("en-US",{hour12:!1})}function Ie({label:t,value:e,color:n}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
    </div>
  `}function Ju({row:t}){return o`
    <div class="term-row activity-row ${t.kind}">
      <span class="term-time">${Gu(t.timestamp)}</span>
      <span class="activity-kind-badge ${t.kind}">${Fu[t.kind]}</span>
      <span class="term-actor">${t.actor}</span>
      <span class="term-text">${t.content}</span>
    </div>
  `}function Vu(){const t=Ku.value,e=Bu.value,n=e[0],a=Wu.value;return o`
    <div class="stats-grid">
      <${Ie} label="Visible rows" value=${e.length} />
      <${Ie} label="Tracked messages" value=${t.messages} color="#47b8ff" />
      <${Ie} label="Keeper signals" value=${t.keepers} color="#4ade80" />
      <${Ie} label="Board signals" value=${t.board} color="#fbbf24" />
      <${Ie} label="SSE events" value=${bn.value} color="#c084fc" />
    </div>

    <${b} title="Unified Activity" class="section">
      <div class="activity-toolbar">
        <div class="activity-filter-row">
          ${["all","messages","board","tasks","keepers","system"].map(s=>o`
            <button
              class="goal-filter-btn ${Os.value===s?"active":""}"
              onClick=${()=>{Os.value=s}}
            >
              ${Ou[s]}
            </button>
          `)}
        </div>
        <div class="activity-toolbar-meta">
          <span class="pill ${Et.value?"":"pill-stale"}">
            ${Et.value?"Live SSE":"Reconnecting"}
          </span>
          <span>${n?o`Latest: <${j} timestamp=${n.timestamp} />`:"Latest: —"}</span>
          <span>Showing up to ${or} rows</span>
          <span>Live events + current snapshot merged here</span>
        </div>
      </div>

      <div class="terminal-feed">
        ${e.length===0?o`<div class="empty-state">Waiting for live or snapshot signals...</div>`:e.map(s=>o`<${Ju} key=${s.id} row=${s} />`)}
      </div>
    <//>

    <${b} title="Agent Motion" class="section">
      <div class="activity-motion-list">
        ${a.length===0?o`<div class="empty-state">No active agents</div>`:a.map(({agent:s,motion:i})=>o`
              <div class="activity-motion-row">
                <div>
                  <div class="activity-motion-agent">${s.name}</div>
                  <div class="activity-motion-meta">
                    ${i.activeAssignedCount>0?`${i.activeAssignedCount} claimed tasks`:"No claimed tasks"}
                    ${i.lastActivityAt?o` · <${j} timestamp=${i.lastActivityAt} />`:null}
                  </div>
                </div>
                <div class="activity-motion-text">${i.lastActivityText??"No recent message/event signal"}</div>
              </div>
            `)}
      </div>
    <//>
  `}function rr({ratio:t,size:e=40,stroke:n=4}){if(t==null)return null;const a=(e-n)/2,s=e/2,i=2*Math.PI*a,r=i*((100-t*100)/100);let u="mitosis-safe";return t>=.8?u="mitosis-critical":t>=.5&&(u="mitosis-warn"),o`
    <div class="mitosis-ring-container" title="Mitosis Context Load: ${Math.round(t*100)}%">
      <svg class="mitosis-ring" width="${e}" height="${e}" viewBox="0 0 ${e} ${e}">
        <circle class="mitosis-ring-bg" cx="${s}" cy="${s}" r="${a}" stroke-width="${n}" />
        <circle 
          class="mitosis-ring-fg ${u}" 
          cx="${s}" cy="${s}" r="${a}" 
          stroke-width="${n}" 
          stroke-dasharray="${i}" 
          stroke-dashoffset="${r}" 
        />
      </svg>
      <span class="mitosis-text ${u}">${Math.round(t*100)}%</span>
    </div>
  `}const Ba=600*1e3,Qu=1200*1e3,Gi=.8;function qt(t){if(t==null)return 0;const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function de(t){switch(t){case"bad":return 2;case"warn":return 1;default:return 0}}function Yu(t){switch(t){case"working":return"Working";case"watching":return"Watching";case"quiet":return"Quiet";case"offline":return"Offline"}}function Xu(t){switch(t){case"critical":return"Critical";case"warning":return"Watch";default:return"Healthy"}}function Zu(t){return typeof t!="number"||Number.isNaN(t)?"—":`${Math.round(t*100)}%`}function td(t){var e;return((e=t.agent)==null?void 0:e.current_task)??t.skill_primary??t.last_proactive_reason??t.memory_recent_note??"No active focus"}function ed(t){const e=[`Gen ${t.generation??"—"}`,`Turns ${t.turn_count??0}`,`Handoffs ${t.handoff_count_total??0}`];return(t.compaction_count??0)>0&&e.push(`Compactions ${t.compaction_count}`),e.join(" · ")}function nd(t){var d,p;const e=vn(t.name,Tt.value,se.value,Wt.value,{currentTask:t.current_task,lastSeen:t.last_seen,boardPosts:It.value,keepers:ft.value}),n=e.lastActivityAt??t.last_seen??null,a=n?Math.max(0,Date.now()-qt(n)):Number.POSITIVE_INFINITY,s=!!((d=t.current_task)!=null&&d.trim())||e.activeAssignedCount>0;let i="watching",r="ok",u="Healthy live signal";return t.status==="offline"||t.status==="inactive"?(i="offline",r="bad",u=n?"Offline or inactive":"No recent presence"):a>Qu?(i="quiet",r="bad",u=s?"Working without a fresh signal":"No fresh agent signal"):s?(i="working",r=a>Ba?"warn":"ok",u=a>Ba?"Execution looks quiet for too long":"Task and live signal aligned"):a>Ba?(i="quiet",r="warn",u="Quiet but still reachable"):t.status==="idle"&&(i="watching",r="ok",u="Standing by for the next task"),{agent:t,motion:e,lastSignalAt:n,activeTaskCount:e.activeAssignedCount,state:i,tone:r,focus:((p=t.current_task)==null?void 0:p.trim())||(e.activeAssignedCount>0?`${e.activeAssignedCount} claimed tasks waiting for explicit current_task`:e.lastActivityText??"Idle / waiting for assignment"),note:u}}function ad(t){const e=Yo.value.get(t.name)??"idle",n=Xo.value.has(t.name),a=t.context_ratio??0;let s="healthy",i="ok",r="Heartbeat and context look healthy";return t.status==="offline"||n||e==="handoff-imminent"?(s="critical",i="bad",r=n?"Heartbeat stale":e==="handoff-imminent"?"Handoff imminent":"Keeper offline"):(e==="preparing"||e==="compacting"||a>=Gi)&&(s="warning",i="warn",r=a>=Gi?"High context pressure":e==="compacting"?"Compaction in progress":"Preparing for handoff"),{keeper:t,lifecycle:e,state:s,tone:i,focus:td(t),note:r}}function Pe({label:t,value:e,color:n,caption:a}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
      ${a?o`<div class="monitor-stat-caption">${a}</div>`:null}
    </div>
  `}function sd({item:t}){const e=t.kind==="agent"?()=>ke(t.agent.name):()=>na(t.keeper);return o`
    <button class="monitor-alert ${t.tone}" onClick=${e}>
      <div class="monitor-alert-main">
        <div class="monitor-alert-title">${t.title}</div>
        <div class="monitor-alert-subtitle">${t.subtitle}</div>
      </div>
      <div class="monitor-alert-meta">
        <span class="monitor-pill ${t.tone}">
          ${t.kind==="agent"?"Agent":"Keeper"}
        </span>
        ${t.timestamp?o`<span><${j} timestamp=${t.timestamp} /></span>`:o`<span>No signal</span>`}
      </div>
    </button>
  `}function id({row:t}){const{agent:e,motion:n}=t;return o`
    <button class="monitor-row ${t.tone}" onClick=${()=>ke(e.name)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?o`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${rr} ratio=${e.context_ratio} size=${34} stroke=${4} />
        <${_t} status=${e.status} />
        <span class="monitor-pill ${t.tone}">${Yu(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${t.lastSignalAt?o`<span>Signal <${j} timestamp=${t.lastSignalAt} /></span>`:o`<span>No recent signal</span>`}
        <span>${t.activeTaskCount>0?`${t.activeTaskCount} active tasks`:"No active tasks"}</span>
        ${e.model?o`<span>${e.model}</span>`:null}
        ${e.last_seen?o`<span>Seen <${j} timestamp=${e.last_seen} /></span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${n.lastActivityText&&n.lastActivityText!==t.focus?o`<div class="monitor-footnote">Latest detail: ${n.lastActivityText}</div>`:null}
    </button>
  `}function od({row:t}){const{keeper:e}=t;return o`
    <button class="monitor-row ${t.tone}" onClick=${()=>na(e)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?o`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${rr} ratio=${e.context_ratio} size=${34} stroke=${4} />
        <${_t} status=${e.status} />
        <span class="monitor-pill ${t.tone}">${Xu(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${e.last_heartbeat?o`<span>Heartbeat <${j} timestamp=${e.last_heartbeat} /></span>`:o`<span>No heartbeat</span>`}
        <span>${ed(e)}</span>
        <span>Lifecycle ${t.lifecycle}</span>
        <span>Context ${Zu(e.context_ratio)}</span>
        ${e.model?o`<span>${e.model}</span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${e.skill_reason?o`<div class="monitor-footnote">Skill route: ${e.skill_reason}</div>`:null}
    </button>
  `}function rd(){const t=[...Jt.value].map(nd).sort((d,p)=>{const f=de(p.tone)-de(d.tone);if(f!==0)return f;const l=p.activeTaskCount-d.activeTaskCount;return l!==0?l:qt(p.lastSignalAt)-qt(d.lastSignalAt)}),e=[...ft.value].map(ad).sort((d,p)=>{const f=de(p.tone)-de(d.tone);if(f!==0)return f;const l=(p.keeper.context_ratio??0)-(d.keeper.context_ratio??0);return l!==0?l:qt(p.keeper.last_heartbeat)-qt(d.keeper.last_heartbeat)}),n=t.filter(d=>d.state!=="offline").length,a=t.filter(d=>d.state==="working").length,s=t.filter(d=>d.lastSignalAt&&Date.now()-qt(d.lastSignalAt)<=12e4).length,i=t.filter(d=>d.tone!=="ok"),r=e.filter(d=>d.tone!=="ok"),u=[...r.map(d=>({kind:"keeper",key:`keeper-${d.keeper.name}`,tone:d.tone,title:d.keeper.name,subtitle:`${d.note} · ${d.focus}`,timestamp:d.keeper.last_heartbeat??null,keeper:d.keeper})),...i.map(d=>({kind:"agent",key:`agent-${d.agent.name}`,tone:d.tone,title:d.agent.name,subtitle:`${d.note} · ${d.focus}`,timestamp:d.lastSignalAt,agent:d.agent}))].sort((d,p)=>{const f=de(p.tone)-de(d.tone);return f!==0?f:qt(p.timestamp)-qt(d.timestamp)}).slice(0,8);return o`
    <div class="agents-monitor">
      <div class="stats-grid">
        <${Pe} label="Agents online" value=${n} color="#4ade80" caption="active + idle" />
        <${Pe} label="Working now" value=${a} color="#fbbf24" caption="task or claimed load" />
        <${Pe} label="Fresh signals" value=${s} color="#22d3ee" caption="within last 2 minutes" />
        <${Pe} label="Agent alerts" value=${i.length} color=${i.length>0?"#fb7185":"#4ade80"} caption="quiet or offline" />
        <${Pe} label="Keeper alerts" value=${r.length} color=${r.length>0?"#fb7185":"#4ade80"} caption="stale or high pressure" />
      </div>

      <${b} title="Attention Queue" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Who needs intervention right now</h2>
          <p class="monitor-subheadline">Rows are sorted by severity first, then by the freshest signal we have.</p>
        </div>
        <div class="monitor-alert-list">
          ${u.length===0?o`<div class="empty-state">No agent or keeper alerts right now</div>`:u.map(d=>o`<${sd} key=${d.key} item=${d} />`)}
        </div>
      <//>

      <div class="grid-2col">
        <${b} title="Keeper Watch" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Long-running keeper health</h2>
            <p class="monitor-subheadline">Heartbeat, context pressure, and continuity state in one list.</p>
          </div>
          <div class="monitor-list">
            ${e.length===0?o`<div class="empty-state">No keepers active</div>`:e.map(d=>o`<${od} key=${d.keeper.name} row=${d} />`)}
          </div>
        <//>

        <${b} title="Agent Watch" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Short-horizon execution monitor</h2>
            <p class="monitor-subheadline">Current task, recent signal, and quiet drift are surfaced together.</p>
          </div>
          <div class="monitor-list">
            ${t.length===0?o`<div class="empty-state">No agents registered</div>`:t.map(d=>o`<${id} key=${d.agent.name} row=${d} />`)}
          </div>
        <//>
      </div>
    </div>
  `}function Wa({task:t}){const e=(t.priority??4)<=1?"p1":(t.priority??4)===2?"p2":(t.priority??4)===3?"p3":"p4";return o`
    <div class="kanban-card ${e}">
      <div class="kanban-card-title">${t.title}</div>
      <div class="kanban-card-meta">
        ${t.created_at?o`<${j} timestamp=${t.created_at} />`:o`<span>-</span>`}
        ${t.assignee?o`<span class="kanban-assignee">${t.assignee}</span>`:null}
      </div>
    </div>
  `}function ld(){const{todo:t,inProgress:e,done:n}=Qo.value;return o`
    <div class="kanban-board">
      <!-- TODO Column -->
      <div class="kanban-column">
        <div class="kanban-header todo">
          <span>TO DO</span>
          <span class="kanban-badge">${t.length}</span>
        </div>
        ${t.length===0?o`<div class="empty-state" style="opacity: 0.5;">No pending tasks</div>`:t.map(a=>o`<${Wa} key=${a.id} task=${a} />`)}
      </div>

      <!-- IN PROGRESS Column -->
      <div class="kanban-column">
        <div class="kanban-header inprogress">
          <span>IN PROGRESS</span>
          <span class="kanban-badge">${e.length}</span>
        </div>
        ${e.length===0?o`<div class="empty-state" style="opacity: 0.5;">No active tasks</div>`:e.map(a=>o`<${Wa} key=${a.id} task=${a} />`)}
      </div>

      <!-- DONE Column -->
      <div class="kanban-column">
        <div class="kanban-header done">
          <span>DONE</span>
          <span class="kanban-badge">${n.length}</span>
        </div>
        ${n.length===0?o`<div class="empty-state" style="opacity: 0.5;">No completed tasks</div>`:n.slice(0,20).map(a=>o`<${Wa} key=${a.id} task=${a} />`)}
        ${n.length>20?o`<div class="empty-state" style="opacity: 0.5;">...and ${n.length-20} more</div>`:null}
      </div>
    </div>
  `}const _a=600*1e3,Gn=1200*1e3;function Ca(t){return(t??"").trim().toLowerCase()}function bt(t){if(t==null)return 0;const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function ae(t,e=96){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:null}function zt(t){switch(t){case"bad":return 2;case"warn":return 1;default:return 0}}function gn(t){return typeof t!="number"||Number.isNaN(t)?3:t}function lr(t){const e=gn(t);return e<=1?"P1":e===2?"P2":e>=4?"P4+":"P3"}function cr(t){switch(t){case"in_progress":return"In Progress";case"claimed":return"Claimed";case"done":return"Done";case"cancelled":return"Cancelled";default:return"Todo"}}function ur(t){switch(t){case"dispatchable":return"Dispatch";case"drift":return"Drift";case"quiet":return"Quiet";case"offline":return"Offline";default:return"Loaded"}}function cd(t){return t.updated_at??t.created_at??null}function ud(t){const e=new Map;for(const n of t)e.set(Ca(n.name),vn(n.name,Tt.value,se.value,Wt.value,{currentTask:n.current_task,lastSeen:n.last_seen,boardPosts:It.value,keepers:ft.value}));return e}function Ji(t,e,n){var w,C;const a=Ca(t.assignee),s=a?e.get(a)??null:null,i=s?n.get(a)??null:null,r=(i==null?void 0:i.lastActivityAt)??(s==null?void 0:s.last_seen)??null,u=r?Math.max(0,Date.now()-bt(r)):Number.POSITIVE_INFINITY,d=ae(t.description),p=ae(s==null?void 0:s.current_task)??(i==null?void 0:i.lastActivityText)??null,f=t.status==="claimed"||t.status==="in_progress";let l="ok",c="Fresh owner coverage",v=p??d??t.id,h=!1,k=!1;return t.status==="todo"?t.assignee?s?s.status==="offline"||s.status==="inactive"?(h=!0,l="bad",c="Assigned owner is offline",v="Queue item is blocked until ownership changes."):u>_a?(l="warn",c="Owner exists but live signal is quiet",v=p??"Owner may need a nudge before pickup."):((i==null?void 0:i.activeAssignedCount)??0)>0||(w=s.current_task)!=null&&w.trim()?(l="warn",c="Owner is already carrying active work",v=p??`${(i==null?void 0:i.activeAssignedCount)??0} active tasks already assigned.`):(c="Ready and covered by a fresh operator",v=p??d??"This can be picked up immediately."):(h=!0,l="bad",c="Assigned owner is not present in the room",v="Reassign or bring the owner back online."):(h=!0,l=gn(t.priority)<=2?"bad":"warn",c=gn(t.priority)<=2?"Urgent ready work has no owner":"Ready work has no owner",v="Assign an agent before this queue item slips."):f&&(t.assignee?s?s.status==="offline"||s.status==="inactive"?(h=!0,l="bad",c="Assigned owner is offline",v=p??"Execution has no live operator right now."):u>Gn?(k=!0,l="bad",c="Assigned owner has gone quiet",v=p??"Fresh operator signal is missing."):u>_a?(k=!0,l="warn",c="Execution has been quiet for too long",v=p??"Check whether this work is blocked."):(C=s.current_task)!=null&&C.trim()?(c="Execution has fresh owner coverage",v=p??d??t.id):(l="warn",c=t.status==="claimed"?"Claimed work is waiting for explicit focus":"Owner is live but current_task is empty",v=p??"Task state and agent focus are drifting apart."):(h=!0,l="bad",c="Assigned owner is not active in the room",v="Execution is orphaned until ownership is restored."):(h=!0,l="bad",c="Active work has no assignee",v="Claim or reassign this task immediately.")),{task:t,assigneeAgent:s,motion:i,tone:l,note:c,focus:v,lastSignalAt:r,lastTouchedAt:cd(t),ownerGap:h,quiet:k}}function dd(t,e){var c;const n=e.get(Ca(t.name))??{activeAssignedCount:0,lastActivityAt:null,lastActivityText:null},a=n.lastActivityAt??t.last_seen??null,s=a?Math.max(0,Date.now()-bt(a)):Number.POSITIVE_INFINITY,i=!!((c=t.current_task)!=null&&c.trim()),r=n.activeAssignedCount,u=i||r>0;let d="loaded",p="ok",f="Healthy active load",l=ae(t.current_task)??n.lastActivityText??"Ready for assignment";return t.status==="offline"||t.status==="inactive"?(d="offline",p="bad",f="Agent is unavailable"):u&&s>Gn?(d="quiet",p="bad",f="Working without a fresh signal"):r>0&&!i?(d="drift",p="warn",f="Claimed work exists but current_task is empty",l=`${r} active tasks need explicit focus.`):i&&r===0?(d="drift",p="warn",f="current_task has no matching claimed work",l=ae(t.current_task)??"Task metadata and operator state drifted."):!u&&s<=_a?(d="dispatchable",p="ok",f="Fresh signal and no active load",l=n.lastActivityText??"Ready for assignment."):u?s>_a&&(d="loaded",p="warn",f="Execution load is healthy but slightly quiet",l=ae(t.current_task)??`${r} active tasks in flight.`):(d="quiet",p=s>Gn?"bad":"warn",f=s>Gn?"No fresh signal while idle":"Reachable, but not freshly active",l=n.lastActivityText??"Likely available after a quick check-in."),{agent:t,motion:n,tone:p,state:d,note:f,focus:l,lastSignalAt:a,activeTaskCount:r}}function Me({label:t,value:e,color:n,caption:a}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
      ${a?o`<div class="monitor-stat-caption">${a}</div>`:null}
    </div>
  `}function pd({item:t}){return o`
    <div class="execution-alert ${t.tone}">
      <div class="monitor-alert-main">
        <div class="monitor-alert-title">${t.title}</div>
        <div class="monitor-alert-subtitle">${t.subtitle}</div>
      </div>
      <div class="monitor-alert-meta">
        <span class="monitor-pill ${t.tone}">
          ${t.kind==="task"?lr(t.taskRow.task.priority):ur(t.agentRow.state)}
        </span>
        ${t.kind==="task"?o`<span>${cr(t.taskRow.task.status)}</span>`:o`<span>${t.agentRow.agent.name}</span>`}
        ${t.timestamp?o`<span><${j} timestamp=${t.timestamp} /></span>`:o`<span>No signal</span>`}
      </div>
    </div>
  `}function Vi({row:t}){var e;return o`
    <div class="execution-task-row ${t.tone}">
      <div class="monitor-row-header">
        <span class="monitor-pill ${t.tone}">${lr(t.task.priority)}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${t.task.title}</span>
            <span class="monitor-sub">${t.task.id}</span>
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        ${t.assigneeAgent?o`<${_t} status=${t.assigneeAgent.status} />`:o`<span class="monitor-sub">No owner</span>`}
        <span class="monitor-pill ${t.tone}">${cr(t.task.status)}</span>
      </div>

      <div class="monitor-meta">
        ${t.task.assignee?o`<span>Owner ${t.task.assignee}</span>`:o`<span>Unassigned</span>`}
        ${t.lastTouchedAt?o`<span>Touched <${j} timestamp=${t.lastTouchedAt} /></span>`:null}
        ${t.lastSignalAt?o`<span>Signal <${j} timestamp=${t.lastSignalAt} /></span>`:o`<span>No live signal</span>`}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${(e=t.assigneeAgent)!=null&&e.current_task&&ae(t.assigneeAgent.current_task)!==t.focus?o`<div class="monitor-footnote">Owner focus: ${ae(t.assigneeAgent.current_task)}</div>`:null}
    </div>
  `}function vd({row:t}){const{agent:e}=t;return o`
    <button class="monitor-row ${t.tone}" onClick=${()=>ke(e.name)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?o`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${_t} status=${e.status} />
        <span class="monitor-pill ${t.tone}">${ur(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${t.lastSignalAt?o`<span>Signal <${j} timestamp=${t.lastSignalAt} /></span>`:o`<span>No recent signal</span>`}
        <span>${t.activeTaskCount>0?`${t.activeTaskCount} active tasks`:"No active tasks"}</span>
        ${e.model?o`<span>${e.model}</span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
    </button>
  `}function md(){const t=Jt.value,e=Tt.value,n=new Map(t.map(l=>[Ca(l.name),l])),a=ud(t),s=e.filter(l=>l.status==="claimed"||l.status==="in_progress").map(l=>Ji(l,n,a)).sort((l,c)=>{const v=zt(c.tone)-zt(l.tone);return v!==0?v:bt(c.lastSignalAt??c.lastTouchedAt)-bt(l.lastSignalAt??l.lastTouchedAt)}),i=e.filter(l=>l.status==="todo").map(l=>Ji(l,n,a)).sort((l,c)=>{const v=zt(c.tone)-zt(l.tone);if(v!==0)return v;const h=gn(l.task.priority)-gn(c.task.priority);return h!==0?h:bt(l.lastTouchedAt)-bt(c.lastTouchedAt)}),r=t.map(l=>dd(l,a)).filter(l=>l.state==="dispatchable"||l.state==="drift"||l.state==="quiet").sort((l,c)=>{if(l.state==="dispatchable"&&c.state!=="dispatchable")return-1;if(c.state==="dispatchable"&&l.state!=="dispatchable")return 1;const v=zt(c.tone)-zt(l.tone);return v!==0?v:bt(c.lastSignalAt)-bt(l.lastSignalAt)}),u=[...s.filter(l=>l.tone!=="ok").map(l=>({kind:"task",key:`active-${l.task.id}`,tone:l.tone,title:l.task.title,subtitle:`${l.note} · ${l.focus}`,timestamp:l.lastSignalAt??l.lastTouchedAt,taskRow:l})),...i.filter(l=>l.tone==="bad").map(l=>({kind:"task",key:`ready-${l.task.id}`,tone:l.tone,title:l.task.title,subtitle:`${l.note} · ${l.focus}`,timestamp:l.lastTouchedAt,taskRow:l})),...r.filter(l=>l.state==="drift"||l.tone==="bad").map(l=>({kind:"agent",key:`agent-${l.agent.name}`,tone:l.tone,title:l.agent.name,subtitle:`${l.note} · ${l.focus}`,timestamp:l.lastSignalAt,agentRow:l}))].sort((l,c)=>{const v=zt(c.tone)-zt(l.tone);return v!==0?v:bt(c.timestamp)-bt(l.timestamp)}).slice(0,8),d=r.filter(l=>l.state==="dispatchable"),p=[...s,...i].filter(l=>l.ownerGap),f=s.filter(l=>l.quiet);return o`
    <div class="agents-monitor">
      <div class="stats-grid">
        <${Me} label="Active work" value=${s.length} color="#fbbf24" caption="claimed + in progress" />
        <${Me} label="Needs intervention" value=${u.length} color=${u.length>0?"#fb7185":"#4ade80"} caption="stalled or drifting now" />
        <${Me} label="Ownership gaps" value=${p.length} color=${p.length>0?"#fb7185":"#4ade80"} caption="missing or unavailable owners" />
        <${Me} label="Dispatchable agents" value=${d.length} color="#22d3ee" caption="fresh signal, no active load" />
        <${Me} label="Quiet execution" value=${f.length} color=${f.length>0?"#fbbf24":"#4ade80"} caption="active tasks with aging signals" />
      </div>

      <${b} title="Intervention Queue" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">What needs a nudge right now</h2>
          <p class="monitor-subheadline">Severity comes first, then the freshest evidence we have about the stall or drift.</p>
        </div>
        <div class="monitor-alert-list">
          ${u.length===0?o`<div class="empty-state">No active execution risks right now</div>`:u.map(l=>o`<${pd} key=${l.key} item=${l} />`)}
        </div>
      <//>

      <div class="grid-2col">
        <${b} title="Ready Queue" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Ready work, sorted by dispatch risk</h2>
            <p class="monitor-subheadline">Ownerless or owner-unavailable items float to the top before healthy assigned queue items.</p>
          </div>
          <div class="monitor-list">
            ${i.length===0?o`<div class="empty-state">No ready tasks in the queue</div>`:i.slice(0,10).map(l=>o`<${Vi} key=${l.task.id} row=${l} />`)}
          </div>
        <//>

        <${b} title="Dispatch Window" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Who can pick up work next</h2>
            <p class="monitor-subheadline">Fresh capacity appears first. Task-state drift stays visible so owners can clean up metadata fast.</p>
          </div>
          <div class="monitor-list">
            ${r.length===0?o`<div class="empty-state">No agent capacity or drift signals right now</div>`:r.map(l=>o`<${vd} key=${l.agent.name} row=${l} />`)}
          </div>
        <//>
      </div>

      <${b} title="Active Execution Watch" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Claimed and in-progress work</h2>
          <p class="monitor-subheadline">Rows are sorted by risk first, then by the freshest operator signal tied to each task.</p>
        </div>
        <div class="monitor-list">
          ${s.length===0?o`<div class="empty-state">No active execution tasks</div>`:s.map(l=>o`<${Vi} key=${l.task.id} row=${l} />`)}
        </div>
      <//>
    </div>
  `}const ga=_("all"),ha=_("all"),zs=it(()=>{let t=dn.value;return ga.value!=="all"&&(t=t.filter(e=>e.horizon===ga.value)),ha.value!=="all"&&(t=t.filter(e=>e.status===ha.value)),t}),fd=it(()=>{const t={short:[],mid:[],long:[]};for(const e of zs.value){const n=t[e.horizon];n&&n.push(e)}return t}),_d=it(()=>{const t=Array.from(vt.value.values());return t.sort((e,n)=>e.status==="running"&&n.status!=="running"?-1:n.status==="running"&&e.status!=="running"?1:n.elapsed_seconds-e.elapsed_seconds),t});function gd(t){return"★".repeat(Math.min(t,5))+"☆".repeat(Math.max(0,5-t))}function si(t){switch(t){case"short":return"Short-term";case"mid":return"Mid-term";case"long":return"Long-term";default:return t}}function Jn(t){switch(t){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function hd(t){return t<60?`${Math.round(t)}s`:t<3600?`${Math.floor(t/60)}m ${Math.round(t%60)}s`:`${Math.floor(t/3600)}h ${Math.floor(t%3600/60)}m`}function Qi(t){return t.toFixed(4)}function Yi(t){const e=t.current_metric-t.baseline_metric;return`${e>=0?"+":""}${e.toFixed(4)}`}function $d({goal:t}){return o`
    <div class="goal-row">
      <div class="goal-row-main">
        <div style="display:flex; align-items:center; gap:8px;">
          <span class="goal-horizon-badge" style="color:${Jn(t.horizon)}">
            ${si(t.horizon)}
          </span>
          <span class="goal-title">${t.title}</span>
        </div>
        <div class="goal-meta">
          <span class="goal-priority" title="Priority ${t.priority}">${gd(t.priority)}</span>
          ${t.metric?o`<span class="goal-metric">${t.metric}${t.target_value?` → ${t.target_value}`:""}</span>`:null}
          ${t.due_date?o`<span class="goal-due">Due: <${j} timestamp=${t.due_date} /></span>`:null}
        </div>
        ${t.last_review_note?o`
          <div class="goal-review-note">${t.last_review_note}</div>
        `:null}
      </div>
      <div class="goal-row-right">
        <${_t} status=${t.status} />
        <div class="goal-updated">
          <${j} timestamp=${t.updated_at} />
        </div>
      </div>
    </div>
  `}function Xi({label:t,timestamp:e,source:n,note:a}){return o`
    <div class="planning-freshness-row">
      <div>
        <div class="planning-freshness-label">${t}</div>
        <div class="planning-freshness-source">${n}</div>
        ${a?o`<div class="planning-freshness-source">${a}</div>`:null}
      </div>
      <strong class="planning-freshness-value">
        ${e?o`<${j} timestamp=${e} />`:"Not loaded"}
      </strong>
    </div>
  `}function Ga({horizon:t,items:e}){if(e.length===0)return null;const n=[...e].sort((a,s)=>s.priority-a.priority);return o`
    <${b} title="${si(t)} Goals (${e.length})" class="section">
      <div class="goal-list">
        ${n.map(a=>o`<${$d} key=${a.id} goal=${a} />`)}
      </div>
    <//>
  `}function yd(){return o`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">Horizon</label>
        ${["all","short","mid","long"].map(t=>o`
          <button
            class="goal-filter-btn ${ga.value===t?"active":""}"
            onClick=${()=>{ga.value=t}}
          >
            ${t==="all"?"All":si(t)}
          </button>
        `)}
      </div>
      <div class="goal-filter-group">
        <label class="goal-filter-label">Status</label>
        ${["all","active","completed","paused"].map(t=>o`
          <button
            class="goal-filter-btn ${ha.value===t?"active":""}"
            onClick=${()=>{ha.value=t}}
          >
            ${t==="all"?"All":t.charAt(0).toUpperCase()+t.slice(1)}
          </button>
        `)}
      </div>
    </div>
  `}function bd(){const t=dn.value,e=t.filter(s=>s.status==="active").length,n=t.filter(s=>s.status==="completed").length,a={short:0,mid:0,long:0};for(const s of t)s.horizon in a&&a[s.horizon]++;return o`
    <div class="goal-summary">
      <div class="goal-summary-item">
        <div class="goal-summary-value">${t.length}</div>
        <div class="goal-summary-label">Total</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:#4ade80">${e}</div>
        <div class="goal-summary-label">Active</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:#888">${n}</div>
        <div class="goal-summary-label">Completed</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${Jn("short")}">${a.short}</div>
        <div class="goal-summary-label">Short</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${Jn("mid")}">${a.mid}</div>
        <div class="goal-summary-label">Mid</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${Jn("long")}">${a.long}</div>
        <div class="goal-summary-label">Long</div>
      </div>
    </div>
  `}function kd({loop:t}){const e=t.history[0];return o`
    <div class="planning-loop-row">
      <div class="planning-loop-main">
        <div class="planning-loop-head">
          <div>
            <div class="planning-loop-id">${t.profile}</div>
            <div class="planning-loop-sub">${t.loop_id}</div>
          </div>
          <div class="planning-loop-badges">
            <${_t} status=${t.status} />
            <span class="pill">${t.current_iteration}${t.max_iterations>0?`/${t.max_iterations}`:""}</span>
          </div>
        </div>

        <div class="planning-loop-metrics">
          <span>Baseline ${Qi(t.baseline_metric)}</span>
          <span>Current ${Qi(t.current_metric)}</span>
          <span class=${Yi(t).startsWith("+")?"planning-loop-good":"planning-loop-bad"}>
            Delta ${Yi(t)}
          </span>
          <span>Elapsed ${hd(t.elapsed_seconds)}</span>
        </div>

        <div class="planning-loop-target">${t.target||"No explicit target provided"}</div>
        ${e?o`
              <div class="planning-loop-footnote">
                Latest iteration #${e.iteration}: ${e.changes||e.next_suggestion||"No narrative"}
              </div>
            `:o`<div class="planning-loop-footnote">No iteration history yet</div>`}
      </div>
    </div>
  `}function xd(){Dt(()=>{He(),Ue()},[]);const t=fd.value,e=_d.value,n=e.filter(r=>r.status==="running").length,a=dn.value.filter(r=>r.status==="active").length,s=Un.value,i=s==="idle"?"No loop running":s==="error"?ws.value??"MDAL snapshot unavailable":"Current loop snapshot";return o`
    <div>
      <div class="stats-grid">
        <div class="stat-card">
          <div class="stat-label">Active goals</div>
          <div class="stat-value" style="color:#4ade80">${a}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Visible goals</div>
          <div class="stat-value">${zs.value.length}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Running loops</div>
          <div class="stat-value" style="color:#fbbf24">${n}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Known loops</div>
          <div class="stat-value">${e.length}</div>
        </div>
      </div>

      <${b} title="Planning Surface" class="section">
        <div class="planning-header">
          <div>
            <h2 class="planning-headline">Direction lives here. Goals define intent, MDAL shows whether iteration is moving the metric.</h2>
            <p class="planning-subtitle">
              Goals refresh on tab open or manual refresh. MDAL reads the current loop snapshot exposed by <code>masc_mdal_status</code>.
            </p>
          </div>
          <div class="planning-actions">
            <button class="control-btn ghost" onClick=${He} disabled=${_e.value}>
              ${_e.value?"Refreshing goals...":"Refresh goals"}
            </button>
            <button class="control-btn ghost" onClick=${Ue} disabled=${ge.value}>
              ${ge.value?"Refreshing loops...":"Refresh loops"}
            </button>
            <button
              class="control-btn secondary"
              onClick=${()=>{He(),Ue()}}
              disabled=${_e.value||ge.value}
            >
              Refresh all
            </button>
          </div>
        </div>

        <div class="planning-freshness-grid">
          <${Xi} label="Goals" timestamp=${Jo.value} source="masc_goal_list" />
          <${Xi}
            label="MDAL loops"
            timestamp=${Vo.value}
            source="masc_mdal_status"
            note=${i}
          />
        </div>
      <//>

      <${b} title="Goal Pipeline" class="section">
        <${bd} />
        <${yd} />
      <//>

      ${_e.value&&dn.value.length===0?o`<div class="loading-indicator">Loading goals...</div>`:zs.value.length===0?o`<div class="empty-state">No goals match the current filters</div>`:o`
              <${Ga} horizon="short" items=${t.short??[]} />
              <${Ga} horizon="mid" items=${t.mid??[]} />
              <${Ga} horizon="long" items=${t.long??[]} />
            `}

      <${b} title="MDAL Loops" class="section">
        ${ge.value&&e.length===0?o`<div class="loading-indicator">Loading MDAL loops...</div>`:e.length===0&&s==="error"?o`
                <div class="empty-state">
                  MDAL snapshot could not be loaded right now. Check the backend tool contract or runtime health.
                </div>
              `:e.length===0&&s==="idle"?o`
                <div class="empty-state">
                  No loop is running right now. This section wakes up when <code>masc_mdal_start</code> exposes a live loop.
                </div>
              `:e.length===0?o`
                  <div class="empty-state">
                    No loop snapshot is visible yet. Refresh once the backend has reported a planning loop.
                  </div>
                `:o`
                <div class="planning-loop-list">
                  ${e.map(r=>o`<${kd} key=${r.loop_id} loop=${r} />`)}
                </div>
              `}
      <//>
    </div>
  `}const fe=_(""),Ja=_("ability_check"),Va=_("10"),Qa=_("12"),Pn=_(""),Mn=_("idle"),Ht=_(""),On=_("keeper-late"),Ya=_("player"),Xa=_(""),lt=_("idle"),Za=_(null),Fn=_(""),ts=_(""),es=_("player"),ns=_(""),as=_(""),ss=_(""),tn=_("20"),is=_("20"),os=_(""),jn=_("idle"),qs=_(null),dr=_("overview"),rs=_("all"),ls=_("all"),cs=_("all"),wd=12e4,Ra=_(null),Zi=_(Date.now());function Sd(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function Ad(t,e){return e>0?Math.round(t/e*100):0}const Td={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},Nd={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function zn(t){const e=t.trim();return e?e.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):t}function Cd(t){const e=t.trim().toLowerCase();return Td[e]??"행동 선택 가중치에 영향을 주는 성향입니다."}function Rd(t){const e=t.trim().toLowerCase();return Nd[e]??"상황에 따라 선택되는 전술 액션입니다."}function Bt(t){return typeof t=="object"&&t!==null}function at(t,e,n=""){const a=t[e];return typeof a=="string"?a:n}function kt(t,e,n=0){const a=t[e];return typeof a=="number"&&Number.isFinite(a)?a:n}function hn(t,e,n=!1){const a=t[e];return typeof a=="boolean"?a:n}const Ld=new Set(["str","dex","con","int","wis","cha"]);function Dd(t){const e=t.trim();if(!e)return{};let n;try{n=JSON.parse(e)}catch(s){throw new Error(`능력치 JSON 파싱 실패: ${s instanceof Error?s.message:"invalid json"}`)}if(!Bt(n))throw new Error('능력치 JSON은 object여야 합니다. 예: {"luck":7}');const a={};return Object.entries(n).forEach(([s,i])=>{const r=s.trim();if(r){if(typeof i=="number"&&Number.isFinite(i)){a[r]=Math.max(0,Math.trunc(i));return}if(typeof i=="string"){const u=Number.parseFloat(i.trim());if(Number.isFinite(u)){a[r]=Math.max(0,Math.trunc(u));return}}throw new Error(`능력치 '${r}' 값은 숫자여야 합니다.`)}}),a}function Ed(t){const e=Number.parseInt(t.trim(),10);if(!Number.isFinite(e))return;const n=Math.max(1,e),a=Number.parseInt(tn.value.trim(),10);Number.isFinite(a)&&a>n&&(tn.value=String(n))}function Hs(t){const n=(t.actor_name??t.actor??t.actor_id??"system").trim();return n===""?"system":n}function Id(t){var n;return(((n=t.timestamp)==null?void 0:n.trim())??"")||"-"}function Pd(t){dr.value=t}function pr(t){const e=Ra.value;return e==null||e<=t}function Md(t){const e=Ra.value;return e==null||e<=t?0:Math.max(0,Math.ceil((e-t)/1e3))}function $a(){Ra.value=null}function vr(t){return typeof window>"u"||typeof window.confirm!="function"?!0:window.confirm(t)}function Od(t,e){vr(["관전 모드 잠금을 해제하시겠습니까?",`ROOM: ${t||"-"}`,`PHASE: ${e||"-"}`,"해제 시간: 120초 (시간 경과 또는 위험 액션 실행 후 자동 재잠금)"].join(`
`))&&(Ra.value=Date.now()+wd,y("조작 잠금이 120초 동안 해제되었습니다.","warning"))}function Vn(t){return pr(t)?(y("관전 모드 잠금 상태입니다. 먼저 잠금을 해제하세요.","warning"),!1):!0}function Us(t,e,n){return vr([`[위험 액션 확인] ${t}`,`ROOM: ${e||"-"}`,`PHASE: ${n||"-"}`,"이 액션은 즉시 실행되며 되돌리기 어렵습니다.","계속 진행하시겠습니까?"].join(`
`))}function Fd({hp:t,max:e}){const n=Ad(t,e),a=Sd(t,e);return o`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${a}" style="width:${n}%" />
    </div>
  `}function jd({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return o`
    <div class="trpg-actor-stats">
      ${e.map(n=>o`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function zd({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return o`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function mr({actor:t}){var d,p,f,l;const e=(d=t.archetype)==null?void 0:d.trim(),n=(p=t.persona)==null?void 0:p.trim(),a=(f=t.portrait)==null?void 0:f.trim(),s=(l=t.background)==null?void 0:l.trim(),i=t.traits??[],r=t.skills??[],u=Object.entries(t.stats_raw??{}).filter(([c,v])=>Number.isFinite(v)).filter(([c])=>!Ld.has(c.toLowerCase()));return o`
    <div class="trpg-actor">
      ${a?o`
          <div class="trpg-actor-portrait-wrap">
            <img
              class="trpg-actor-portrait"
              src=${a}
              alt=${`${t.name} portrait`}
              loading="lazy"
              onError=${c=>{const v=c.target;v&&(v.style.display="none")}}
            />
          </div>
        `:null}
      <div class="trpg-actor-header">
        <span class="trpg-actor-name">${t.name}</span>
        <${_t} status=${t.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${t.role}">${t.role}</span>
        <${zd} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?o`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?o`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${Fd} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${jd} stats=${t.stats} />
          </div>
        `:null}
      ${e?o`<div class="trpg-actor-meta">Archetype: ${zn(e)}</div>`:null}
      ${s?o`<div class="trpg-actor-meta">Background: ${s}</div>`:null}
      ${n?o`<div class="trpg-actor-persona">${n}</div>`:null}
      ${u.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Custom Stats</div>
            <div class="trpg-custom-stats">
              ${u.map(([c,v])=>o`
                <span class="trpg-custom-stat-chip">${zn(c)} ${v}</span>
              `)}
            </div>
          </div>
        `:null}
      ${i.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Traits</div>
            <div class="trpg-annot-list">
              ${i.map(c=>o`
                <span class="trpg-annot-chip trait">
                  <span class="trpg-annot-name">${zn(c)}</span>
                  <span class="trpg-annot-desc">${Cd(c)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
      ${r.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Skills</div>
            <div class="trpg-annot-list">
              ${r.map(c=>o`
                <span class="trpg-annot-chip skill">
                  <span class="trpg-annot-name">${zn(c)}</span>
                  <span class="trpg-annot-desc">${Rd(c)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function qd({mapStr:t}){return o`<pre class="trpg-map">${t}</pre>`}function fr({events:t,emptyLabel:e="아직 이벤트가 없습니다."}){return t.length===0?o`<div class="empty-state" style="font-size:13px">${e}</div>`:o`
    <div class="trpg-story" role="list" aria-label="TRPG story events">
      ${t.map((n,a)=>{var s;return o`
        <div key=${a} class="trpg-event ${n.type??""}" role="listitem">
          <div class="trpg-event-meta-row">
            <span class="trpg-event-meta">${Id(n)}</span>
            <span class="trpg-event-meta">${n.phase??"phase:-"}</span>
            <span class="trpg-event-meta">${n.type??"type:-"}</span>
          </div>
          <div class="trpg-event-main">
            <strong>${Hs(n)}</strong>
            ${" "}
          ${n.dice_roll?o`<span class="trpg-dice">[${n.dice_roll.notation}: ${(s=n.dice_roll.rolls)==null?void 0:s.join(",")} = ${n.dice_roll.total}${n.dice_roll.modifier?` +${n.dice_roll.modifier}`:""}]</span>${" "}`:null}
            <span class="trpg-event-text">${n.content??""}</span>
            <span class="trpg-event-ts"><${j} timestamp=${n.timestamp} /></span>
          </div>
        </div>
      `})}
    </div>
  `}function Hd({events:t}){const e="__none__",n=rs.value,a=ls.value,s=cs.value,i=Array.from(new Set(t.map(Hs).map(l=>l.trim()).filter(l=>l!==""))).sort((l,c)=>l.localeCompare(c)),r=Array.from(new Set(t.map(l=>(l.type??"").trim()).filter(l=>l!==""))).sort((l,c)=>l.localeCompare(c)),u=t.some(l=>(l.type??"").trim()===""),d=Array.from(new Set(t.map(l=>(l.phase??"").trim()).filter(l=>l!==""))).sort((l,c)=>l.localeCompare(c)),p=t.some(l=>(l.phase??"").trim()===""),f=t.filter(l=>{if(n!=="all"&&Hs(l)!==n)return!1;const c=(l.type??"").trim(),v=(l.phase??"").trim();if(a===e){if(c!=="")return!1}else if(a!=="all"&&c!==a)return!1;if(s===e){if(v!=="")return!1}else if(s!=="all"&&v!==s)return!1;return!0});return o`
    <div class="trpg-story-toolbar">
      <div class="trpg-story-filter">
        <label>Actor</label>
        <select value=${n} onChange=${l=>{rs.value=l.target.value}}>
          <option value="all">all</option>
          ${i.map(l=>o`<option value=${l}>${l}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Type</label>
        <select value=${a} onChange=${l=>{ls.value=l.target.value}}>
          <option value="all">all</option>
          ${u?o`<option value=${e}>(none)</option>`:null}
          ${r.map(l=>o`<option value=${l}>${l}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Phase</label>
        <select value=${s} onChange=${l=>{cs.value=l.target.value}}>
          <option value="all">all</option>
          ${p?o`<option value=${e}>(none)</option>`:null}
          ${d.map(l=>o`<option value=${l}>${l}</option>`)}
        </select>
      </div>
      <button
        class="trpg-run-btn secondary"
        style="align-self:flex-end;"
        onClick=${()=>{rs.value="all",ls.value="all",cs.value="all"}}
      >
        필터 초기화
      </button>
      <span style="margin-left:auto; font-size:11px; color:#9ca3af; align-self:flex-end;">
        표시 ${f.length} / 전체 ${t.length}
      </span>
    </div>
    <${fr} events=${f.slice(-120)} emptyLabel="필터 조건에 맞는 이벤트가 없습니다." />
  `}function Ud({outcome:t}){if(!t)return null;const e=i=>{const r=i.trim();return r&&(/[A-Z]/.test(r)&&!r.includes(" ")?r.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():r.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())},n=t.result==="victory"?"승리":t.result==="defeat"?"패배":t.result==="draw"?"무승부":"종료",a=t.result==="victory"?"#34d399":t.result==="defeat"?"#f87171":"#9ca3af",s=[t.reason?`원인: ${e(t.reason)}`:null,t.phase?`페이즈: ${e(t.phase)}`:null,typeof t.turn=="number"?`턴: ${t.turn}`:null].filter(Boolean).join(" · ");return o`
    <div style="margin-bottom:16px; padding:10px 12px; border:1px solid rgba(255,255,255,0.12); border-radius:10px; background:rgba(255,255,255,0.03);">
      <div style="font-size:12px; color:#9ca3af; text-transform:uppercase; letter-spacing:0.08em;">Session Outcome</div>
      <div style="font-size:18px; font-weight:700; color:${a}; margin-top:4px;">${n}</div>
      ${t.summary?o`<div style="margin-top:4px; font-size:13px; color:#d1d5db;">${e(t.summary)}</div>`:null}
      ${s?o`<div style="margin-top:4px; font-size:11px; color:#9ca3af;">${s}</div>`:null}
    </div>
  `}function _r({state:t}){const e=t.history??[];return e.length===0?null:o`
    <div class="trpg-round-list">
      ${e.slice(-10).map(n=>o`
        <div class="trpg-round-item ${n.status}">
          <span>Session ${n.id.slice(0,8)}</span>
          <span style="margin-left:auto; font-size:11px; color:#888;">
            Round ${n.round} — ${n.status}
          </span>
        </div>
      `)}
    </div>
  `}function Kd({state:t,nowMs:e}){var p;const n=Rt.value||((p=t.session)==null?void 0:p.room)||"",a=Mn.value,s=t.party??[];if(!s.find(f=>f.id===fe.value)&&s.length>0){const f=s[0];f&&(fe.value=f.id)}const r=async()=>{var l,c;if(!n){y("Room ID가 비어 있습니다.","error");return}if(!Vn(e))return;const f=((l=t.current_round)==null?void 0:l.phase)??((c=t.session)==null?void 0:c.status)??"unknown";if(Us("라운드 실행",n,f)){Mn.value="running";try{const v=await Ml(n);qs.value=v,Mn.value="ok";const h=Bt(v.summary)?v.summary:null,k=h?hn(h,"advanced",!1):!1,w=h?at(h,"progress_reason",""):"";y(k?"라운드가 정상 진행되었습니다.":`라운드가 정체되었습니다${w?`: ${w}`:""}`,k?"success":"warning"),Lt()}catch(v){qs.value=null,Mn.value="error";const h=v instanceof Error?v.message:"라운드 실행에 실패했습니다.";y(h,"error")}finally{$a()}}},u=async()=>{var l,c;if(!n||!Vn(e))return;const f=((l=t.current_round)==null?void 0:l.phase)??((c=t.session)==null?void 0:c.status)??"unknown";if(Us("턴 강제 진행",n,f))try{await jl(n),y("턴을 다음 단계로 이동했습니다.","success"),Lt()}catch{y("턴 이동에 실패했습니다.","error")}finally{$a()}},d=async()=>{if(!n||!Vn(e))return;const f=fe.value.trim();if(!f){y("먼저 Actor를 선택하세요.","warning");return}const l=Number.parseInt(Va.value,10),c=Number.parseInt(Qa.value,10);if(Number.isNaN(l)||Number.isNaN(c)){y("stat/dc는 숫자여야 합니다.","warning");return}const v=Number.parseInt(Pn.value,10),h=Pn.value.trim()===""||Number.isNaN(v)?void 0:v;try{await Fl({roomId:n,actorId:f,action:Ja.value.trim()||"ability_check",statValue:l,dc:c,rawD20:h}),y("주사위 판정을 기록했습니다.","success"),Lt()}catch{y("주사위 판정 기록에 실패했습니다.","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            id="trpg-room-input"
            name="trpg-room-input"
            type="text"
            value=${n}
            onInput=${f=>{Rt.value=f.target.value}}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${fe.value}
            onChange=${f=>{fe.value=f.target.value}}
          >
            <option value="">Actor 선택</option>
            ${s.map(f=>o`<option value=${f.id}>${f.name} (${f.id})</option>`)}
          </select>
        </div>

        <div class="trpg-control-field">
          <label>Dice</label>
          <div style="display:grid; grid-template-columns: 1fr 1fr; gap:6px;">
            <input
              id="trpg-dice-action-input"
              name="trpg-dice-action-input"
              type="text"
              value=${Ja.value}
              onInput=${f=>{Ja.value=f.target.value}}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${Va.value}
              onInput=${f=>{Va.value=f.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${Qa.value}
              onInput=${f=>{Qa.value=f.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              id="trpg-dice-raw-input"
              name="trpg-dice-raw-input"
              type="text"
              value=${Pn.value}
              onInput=${f=>{Pn.value=f.target.value}}
              onKeyDown=${f=>{f.key==="Enter"&&d()}}
              placeholder="raw d20 (optional)"
            />
          </div>
        </div>

        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:4px;">
            <button class="trpg-run-btn secondary" onClick=${d}>Roll</button>
            <button
              class="trpg-run-btn recommend"
              onClick=${r}
              disabled=${a==="running"}
            >
              ${a==="running"?"실행 중...":"Run Round"}
            </button>
            <button class="trpg-run-btn secondary" onClick=${u}>
              Next Turn
            </button>
          </div>
        </div>
      </div>

      ${a!=="idle"?o`<div class="trpg-run-status ${a}">${a==="running"?"처리 중...":a==="ok"?"완료":"실패"}</div>`:null}
    </div>
  `}function Bd({state:t}){var s;const e=Rt.value||((s=t.session)==null?void 0:s.room)||"",n=jn.value,a=async()=>{if(!e){y("Room ID가 비어 있습니다.","warning");return}const i=Fn.value.trim(),r=ts.value.trim();if(!r&&!i){y("이름 또는 Actor ID를 입력하세요.","warning");return}const u=Number.parseInt(tn.value.trim(),10),d=Number.parseInt(is.value.trim(),10),p=Number.isFinite(d)?Math.max(1,d):20,f=Number.isFinite(u)?Math.max(0,Math.min(p,u)):p;let l={};try{l=Dd(os.value)}catch(c){y(c instanceof Error?c.message:"능력치 JSON 오류","error");return}jn.value="spawning";try{const c=typeof crypto<"u"&&typeof crypto.randomUUID=="function"?`trpg_spawn_${crypto.randomUUID()}`:`trpg_spawn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,v=await zl(e,{actor_id:i||void 0,name:r||void 0,role:es.value,idempotencyKey:c,portrait:as.value.trim()||void 0,background:ss.value.trim()||void 0,hp:f,max_hp:p,alive:f>0,stats:Object.keys(l).length>0?l:void 0}),h=typeof v.actor_id=="string"?v.actor_id.trim():"";if(!h)throw new Error("생성 응답에 actor_id가 없습니다.");const k=ns.value.trim();k&&await ql(e,h,k),fe.value=h,Ht.value=h,i||(Fn.value=""),jn.value="ok",y(`Actor 생성 완료: ${h}`,"success"),await Lt()}catch(c){jn.value="error",y(c instanceof Error?c.message:"Actor 생성에 실패했습니다.","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Name</label>
          <input
            id="trpg-spawn-name-input"
            name="trpg-spawn-name-input"
            type="text"
            value=${ts.value}
            onInput=${i=>{ts.value=i.target.value}}
            placeholder="Night Fox"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${es.value}
            onChange=${i=>{es.value=i.target.value}}
          >
            <option value="player">player</option>
            <option value="npc">npc</option>
            <option value="dm">dm</option>
          </select>
        </div>
        <div class="trpg-control-field">
          <label>Keeper (optional)</label>
          <input
            id="trpg-spawn-keeper-input"
            name="trpg-spawn-keeper-input"
            type="text"
            value=${ns.value}
            onInput=${i=>{ns.value=i.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn recommend" onClick=${a} disabled=${n==="spawning"}>
              ${n==="spawning"?"Spawning...":"Spawn Actor"}
            </button>
          </div>
        </div>
      </div>

      <details class="trpg-control-details">
        <summary>상세 입력 (선택)</summary>
        <div class="trpg-control-grid">
          <div class="trpg-control-field">
            <label>Actor ID (optional)</label>
            <input
              id="trpg-spawn-actor-id-input"
              name="trpg-spawn-actor-id-input"
              type="text"
              value=${Fn.value}
              onInput=${i=>{Fn.value=i.target.value}}
              placeholder="auto when blank"
            />
          </div>
          <div class="trpg-control-field">
            <label>Portrait URL</label>
            <input
              id="trpg-spawn-portrait-input"
              name="trpg-spawn-portrait-input"
              type="text"
              value=${as.value}
              onInput=${i=>{as.value=i.target.value}}
              placeholder="https://.../portrait.png"
            />
          </div>
          <div class="trpg-control-field">
            <label>HP</label>
            <input
              id="trpg-spawn-hp-input"
              name="trpg-spawn-hp-input"
              type="number"
              min="0"
              value=${tn.value}
              onInput=${i=>{tn.value=i.target.value}}
              placeholder="20"
            />
          </div>
          <div class="trpg-control-field">
            <label>Max HP</label>
            <input
              id="trpg-spawn-max-hp-input"
              name="trpg-spawn-max-hp-input"
              type="number"
              min="1"
              value=${is.value}
              onInput=${i=>{const r=i.target.value;is.value=r,Ed(r)}}
              placeholder="20"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Background</label>
            <input
              id="trpg-spawn-background-input"
              name="trpg-spawn-background-input"
              type="text"
              value=${ss.value}
              onInput=${i=>{ss.value=i.target.value}}
              placeholder="망명 기사 · 폐허 수색 전문가"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Stats JSON</label>
            <input
              id="trpg-spawn-stats-json-input"
              name="trpg-spawn-stats-json-input"
              type="text"
              value=${os.value}
              onInput=${i=>{os.value=i.target.value}}
              placeholder='{"luck":7,"stealth":12,"str":10}'
            />
          </div>
        </div>
      </details>

      ${n!=="idle"?o`<div class="trpg-run-status ${n==="spawning"?"running":n}">${n==="spawning"?"생성 중...":n==="ok"?"생성 완료":"생성 실패"}</div>`:null}
    </div>
  `}function Wd({state:t,nowMs:e}){var c;const n=Rt.value||((c=t.session)==null?void 0:c.room)||"",a=t.join_gate,s=Za.value,i=Bt(s)?s:null,r=(t.party??[]).filter(v=>v.role!=="dm"),u=Ht.value.trim(),d=r.some(v=>v.id===u),p=d?u:u?"__manual__":"",f=async()=>{const v=Ht.value.trim(),h=On.value.trim();if(!n||!v){y("Room/Actor가 필요합니다.","warning");return}lt.value="checking";try{const k=await Hl(n,v,h||void 0);Za.value=k,lt.value="ok",y("참가 가능 여부를 갱신했습니다.","success")}catch(k){lt.value="error";const w=k instanceof Error?k.message:"참가 가능 여부 확인에 실패했습니다.";y(w,"error")}},l=async()=>{var C,A;const v=Ht.value.trim(),h=On.value.trim(),k=Xa.value.trim();if(!n||!v||!h){y("Room/Actor/Keeper가 필요합니다.","warning");return}if(!Vn(e))return;const w=((C=t.current_round)==null?void 0:C.phase)??((A=t.session)==null?void 0:A.status)??"unknown";if(Us("Mid-Join 승인 요청",n,w)){lt.value="requesting";try{const O=await Ul({room_id:n,actor_id:v,keeper_name:h,role:Ya.value,...k?{name:k}:{}});Za.value=O;const S=Bt(O)?hn(O,"granted",!1):!1,R=Bt(O)?at(O,"reason_code",""):"";S?y("Mid-Join이 승인되었습니다.","success"):y(`Mid-Join이 거절되었습니다${R?`: ${R}`:""}`,"warning"),lt.value=S?"ok":"error",Lt()}catch(O){lt.value="error";const S=O instanceof Error?O.message:"Mid-Join 요청에 실패했습니다.";y(S,"error")}finally{$a()}}};return o`
    <div class="trpg-control-box">
      <div style="font-size:12px; color:#9ca3af; margin-bottom:8px;">
        Window: <strong>${a!=null&&a.phase_open?"OPEN":"CLOSED"}</strong>
        ${a!=null&&a.window?o`<span style="margin-left:8px;">(${a.window})</span>`:null}
        <span style="margin-left:8px;">Required: ${(a==null?void 0:a.min_points)??3} pts</span>
      </div>
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Actor ID</label>
          <select
            value=${p}
            onChange=${v=>{const h=v.target.value;if(h==="__manual__"){(d||!u)&&(Ht.value="");return}Ht.value=h}}
          >
            <option value="">Actor 선택</option>
            ${r.map(v=>o`
              <option value=${v.id}>${v.name} (${v.id})</option>
            `)}
            <option value="__manual__">직접 입력</option>
          </select>
          ${p==="__manual__"?o`
              <input
                id="trpg-join-actor-input"
                name="trpg-join-actor-input"
                type="text"
                value=${Ht.value}
                onInput=${v=>{Ht.value=v.target.value}}
                placeholder="player-xyz"
                style="margin-top:6px;"
              />
            `:null}
        </div>
        <div class="trpg-control-field">
          <label>Keeper</label>
          <input
            id="trpg-join-keeper-input"
            name="trpg-join-keeper-input"
            type="text"
            value=${On.value}
            onInput=${v=>{On.value=v.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${Ya.value}
            onChange=${v=>{Ya.value=v.target.value}}
          >
            <option value="player">player</option>
            <option value="npc">npc</option>
            <option value="dm">dm</option>
          </select>
        </div>
        <div class="trpg-control-field">
          <label>Name (optional)</label>
          <input
            id="trpg-join-name-input"
            name="trpg-join-name-input"
            type="text"
            value=${Xa.value}
            onInput=${v=>{Xa.value=v.target.value}}
            placeholder="display name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn secondary" onClick=${f} disabled=${lt.value==="checking"||lt.value==="requesting"}>
              ${lt.value==="checking"?"Checking...":"Check"}
            </button>
            <button class="trpg-run-btn recommend" onClick=${l} disabled=${lt.value==="checking"||lt.value==="requesting"}>
              ${lt.value==="requesting"?"Requesting...":"Request Join"}
            </button>
          </div>
        </div>
      </div>
      ${i?o`
          <div style="margin-top:8px; font-size:12px; color:#d1d5db;">
            Eligible: <strong>${hn(i,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${kt(i,"effective_score",0)}/${kt(i,"required_points",0)}</span>
            ${at(i,"reason_code","")?o`<span style="margin-left:8px;">Reason: ${at(i,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function gr({state:t}){const e=[...t.contribution_ledger??[]].sort((n,a)=>(a.score??0)-(n.score??0)).slice(0,8);return e.length===0?o`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:o`
    <div class="trpg-round-list">
      ${e.map(n=>o`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function hr({state:t}){var n;const e=t.current_round;return e?o`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?o`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function $r(){const t=qs.value;if(!t)return o`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const e=t.summary,n=Bt(e)?e:null,s=(Array.isArray(t.statuses)?t.statuses:[]).filter(Bt).slice(-8),i=t.canon_check,r=Bt(i)?i:null,u=r&&Array.isArray(r.warnings)?r.warnings.filter(R=>typeof R=="string").slice(0,3):[],d=r&&Array.isArray(r.violations)?r.violations.filter(R=>typeof R=="string").slice(0,3):[],p=n?hn(n,"advanced",!1):!1,f=n?at(n,"progress_reason",""):"",l=n?at(n,"progress_detail",""):"",c=n?kt(n,"player_successes",0):0,v=n?kt(n,"player_required_successes",0):0,h=n?hn(n,"dm_success",!1):!1,k=n?kt(n,"timeouts",0):0,w=n?kt(n,"unavailable",0):0,C=n?kt(n,"reprompts",0):0,A=n?kt(n,"npc_attacks",0):0,O=n?kt(n,"keeper_timeout_sec",0):0,S=n?kt(n,"roll_audit_count",0):0;return o`
    <div style="display:grid; gap:10px;">
      <div class="trpg-round-item ${p?"active":"failed"}" style="display:block;">
        <div style="display:flex; align-items:center; gap:8px;">
          <strong>${p?"ADVANCED":"STALLED"}</strong>
          <span style="font-size:11px; color:#9ca3af;">
            turn ${t.turn_before??0} → ${t.turn_after??0}
          </span>
          <span style="margin-left:auto; font-size:11px; color:#9ca3af;">
            ${h?"DM ok":"DM stalled"} / players ${c}/${v}
          </span>
        </div>
        ${f?o`<div style="margin-top:4px; font-size:12px;">${f}</div>`:null}
        ${l?o`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${l}</div>`:null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${k}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${w}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${C}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${A}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${O||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${S}</div></div>
      </div>

      ${s.length>0?o`
          <div class="trpg-round-list">
            ${s.map(R=>{const Y=at(R,"status","unknown"),gt=at(R,"actor_id","-"),ht=at(R,"role","-"),X=at(R,"reason",""),ot=at(R,"action_type",""),I=at(R,"reply","");return o`
                <div class="trpg-round-item ${Y.includes("fallback")||Y.includes("timeout")?"failed":"active"}">
                  <span>${gt} (${ht})</span>
                  <span style="margin-left:auto; font-size:11px;">${Y}</span>
                  ${ot?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${ot}</div>`:null}
                  ${X?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${X}</div>`:null}
                  ${I?o`<div style="width:100%; font-size:11px; color:#d1d5db; margin-top:2px;">${I.slice(0,120)}</div>`:null}
                </div>
              `})}
          </div>`:null}

      ${r?o`
          <div class="trpg-control-box">
            <div style="font-size:12px; color:#9ca3af;">
              Canon status: <strong>${at(r,"status","unknown")}</strong>
            </div>
            ${d.length>0?o`
                <div style="margin-top:6px; font-size:11px; color:#fca5a5;">
                  ${d.map(R=>o`<div>violation: ${R}</div>`)}
                </div>`:null}
            ${u.length>0?o`
                <div style="margin-top:6px; font-size:11px; color:#fbbf24;">
                  ${u.map(R=>o`<div>warning: ${R}</div>`)}
                </div>`:null}
          </div>
        `:null}
    </div>
  `}function Gd({state:t,nowMs:e}){var r,u,d;const n=Rt.value||((r=t.session)==null?void 0:r.room)||"",a=((u=t.current_round)==null?void 0:u.phase)??((d=t.session)==null?void 0:d.status)??"unknown",s=pr(e),i=Md(e);return o`
    <${b} title="조작 안전 잠금" style="margin-bottom:16px;">
      <div class="trpg-control-lock ${s?"locked":"unlocked"}">
        <div class="trpg-control-lock-title">
          ${s?"잠금 상태: 관전 전용":"잠금 해제됨"}
        </div>
        <div class="trpg-control-lock-desc">
          ${s?"조작 액션은 실행되지 않습니다. 필요할 때만 잠금을 해제하세요.":`위험 액션 실행 또는 ${i}초 후 자동으로 다시 잠깁니다.`}
        </div>
        <div class="trpg-control-lock-meta">room: ${n||"-"} · phase: ${a||"-"}</div>
        <div style="display:flex; gap:8px; margin-top:10px; flex-wrap:wrap;">
          ${s?o`<button class="trpg-run-btn recommend" onClick=${()=>Od(n,a)}>잠금 해제 (120초)</button>`:o`<button class="trpg-run-btn secondary" onClick=${()=>{$a(),y("조작 잠금으로 전환했습니다.","success")}}>즉시 다시 잠금</button>`}
        </div>
      </div>
    <//>
  `}function Jd({active:t}){return o`
    <div class="trpg-screen-tabs" role="tablist" aria-label="TRPG 화면 선택">
      ${[{id:"overview",label:"Overview",desc:"관전 요약"},{id:"timeline",label:"Timeline",desc:"이벤트 흐름"},{id:"control",label:"Control",desc:"운영/개입"}].map(n=>o`
        <button
          class="trpg-screen-tab ${t===n.id?"active":""}"
          role="tab"
          aria-selected=${t===n.id}
          onClick=${()=>Pd(n.id)}
        >
          <span class="trpg-screen-tab-label">${n.label}</span>
          <span class="trpg-screen-tab-desc">${n.desc}</span>
        </button>
      `)}
    </div>
  `}function Vd({state:t}){const e=t.party??[],n=t.story_log??[];return o`
    <div class="trpg-layout">
      <div>
        <${b} title="관전 가이드">
          <div class="trpg-guide-box">
            <div class="trpg-guide-title">권장 운영 순서</div>
            <div class="trpg-guide-text">1) Overview에서 상태 파악 → 2) Timeline에서 원인 확인 → 3) 필요 시 Control에서 최소 개입</div>
            <div class="trpg-guide-meta">관전자 기본 모드 / 위험 액션은 Control 잠금 해제 후 실행</div>
          </div>
        <//>

        <${b} title=${`최근 스토리 (${Math.min(n.length,20)})`} style="margin-top:16px;">
          <${fr} events=${n.slice(-20)} />
        <//>

        ${t.map?o`
            <${b} title="맵" style="margin-top:16px;">
              <${qd} mapStr=${t.map} />
            <//>
          `:null}
      </div>

      <div class="trpg-sidebar">
        <${b} title="현재 라운드">
          <${hr} state=${t} />
        <//>

        <${b} title="기여도" style="margin-top:16px;">
          <${gr} state=${t} />
        <//>

        <${b} title=${`파티 (${e.length})`} style="margin-top:16px;">
          <div class="trpg-actor-list">
            ${e.map(a=>o`<${mr} key=${a.id??a.name} actor=${a} />`)}
            ${e.length===0?o`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
          </div>
        <//>

        ${t.history&&t.history.length>0?o`
            <${b} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
              <${_r} state=${t} />
            <//>
          `:null}
      </div>
    </div>
  `}function Qd({state:t}){const e=t.story_log??[];return o`
    <div class="trpg-layout">
      <div>
        <${b} title=${`이벤트 타임라인 (${e.length})`}>
          <${Hd} events=${e} />
        <//>
      </div>

      <div class="trpg-sidebar">
        <${b} title="최근 라운드 결과">
          <${$r} />
        <//>

        <${b} title="현재 라운드" style="margin-top:16px;">
          <${hr} state=${t} />
        <//>
      </div>
    </div>
  `}function Yd({state:t,nowMs:e}){const n=t.party??[];return o`
    <div>
      <${Gd} state=${t} nowMs=${e} />
      <div class="trpg-layout">
        <div>
          <${b} title="조작 패널">
            <${Kd} state=${t} nowMs=${e} />
          <//>

          <${b} title="Actor Spawn" style="margin-top:16px;">
            <${Bd} state=${t} />
          <//>

          <${b} title="Mid-Join Gate" style="margin-top:16px;">
            <${Wd} state=${t} nowMs=${e} />
          <//>

          <${b} title="최근 라운드 결과" style="margin-top:16px;">
            <${$r} />
          <//>
        </div>

        <div class="trpg-sidebar">
          <${b} title="기여도" style="margin-top:0;">
            <${gr} state=${t} />
          <//>

          <${b} title=${`파티 (${n.length})`} style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(a=>o`<${mr} key=${a.id??a.name} actor=${a} />`)}
              ${n.length===0?o`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
            </div>
          <//>

          ${t.history&&t.history.length>0?o`
              <${b} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
                <${_r} state=${t} />
              <//>
            `:null}
        </div>
      </div>
    </div>
  `}function Xd(){var u,d,p,f,l;const t=Go.value,e=As.value;if(Dt(()=>{if(typeof window>"u"||typeof window.setInterval!="function")return;const c=window.setInterval(()=>{Zi.value=Date.now()},1e3);return()=>{window.clearInterval(c)}},[]),e&&!t)return o`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return o`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>Lt()}>Refresh</button>
      </div>
    `;const n=t.party??[],a=t.story_log??[],s=t.outcome,i=dr.value,r=Zi.value;return o`
    <div>
      <div style="display:flex; gap:8px; align-items:center; justify-content:space-between; margin-bottom:8px;">
        <div style="font-size:11px; color:#8ea9d6;">
          room: ${Rt.value||((u=t.session)==null?void 0:u.room)||"-"} · phase: ${((d=t.current_round)==null?void 0:d.phase)??((p=t.session)==null?void 0:p.status)??"-"}
        </div>
        <button class="trpg-run-btn secondary" onClick=${()=>Lt()}>새로고침</button>
      </div>

      <${Ud} outcome=${s} />

      <div class="stats-grid" style="margin-bottom:16px;">
        <div class="stat-card">
          <div class="stat-label">Session</div>
          <div class="stat-value" style="font-size:16px;">${((f=t.session)==null?void 0:f.status)??"active"}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Round</div>
          <div class="stat-value">${((l=t.current_round)==null?void 0:l.round_number)??0}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Party</div>
          <div class="stat-value">${n.length}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Events</div>
          <div class="stat-value">${a.length}</div>
        </div>
      </div>

      <${Jd} active=${i} />

      ${i==="overview"?o`<${Vd} state=${t} />`:i==="timeline"?o`<${Qd} state=${t} />`:o`<${Yd} state=${t} nowMs=${r} />`}
    </div>
  `}const ii="masc_dashboard_agent_name";function Zd(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem(ii);return e??n??"dashboard"}const ct=_(Zd()),en=_(""),nn=_(""),ya=_(""),Nt=_(""),an=_(""),Ks=_(null),yr=_(null),ba=_(null),sn=_(!1),he=_(!1),on=_(!1),rn=_(!1),ka=_(!1),$e=_(!1),xa=_(!1),La=_(!1);function oi(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function wt(t){return typeof t=="string"&&t.trim()!==""?t.trim():void 0}function tp(t){return typeof t=="boolean"?t:void 0}function us(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function ep(t){return Array.isArray(t)?t.map(e=>wt(e)).filter(e=>!!e):[]}function np(t){if(!oi(t))return null;const e=wt(t.name);return e?{name:e,trigger:wt(t.trigger),outcome:wt(t.outcome),summary:wt(t.summary),reason:wt(t.reason)}:null}function ds(t,e){if(!Array.isArray(t))return[];const n=[];for(const a of t){if(!oi(a))continue;const s=wt(a.name);if(!s)continue;const i=wt(a[e]);e==="summary"?n.push({name:s,summary:i}):n.push({name:s,reason:i})}return n}function ap(t){return oi(t)?{hour:us(t.hour),checked:us(t.checked)??0,acted:us(t.acted)??0,acted_names:ep(t.acted_names),activity_report:wt(t.activity_report),quiet_hours_overridden:tp(t.quiet_hours_overridden),skipped_reason:wt(t.skipped_reason),acted_rows:ds(t.acted_rows,"summary").map(e=>({name:e.name,summary:e.summary})),passed_rows:ds(t.passed_rows,"reason").map(e=>({name:e.name,reason:e.reason})),skipped_rows:ds(t.skipped_rows,"reason").map(e=>({name:e.name,reason:e.reason})),checkins:Array.isArray(t.checkins)?t.checkins.map(np).filter(e=>e!==null):[]}:null}function wa(t){return typeof t!="number"||!Number.isFinite(t)?"??:00":`${String(Math.max(0,t)).padStart(2,"0")}:00`}function Bs(t){if(typeof t!="number"||!Number.isFinite(t)||t<=0)return"unknown";if(t<60)return`${Math.round(t)}s`;if(t<3600)return`${Math.round(t/60)}m`;const e=Math.floor(t/3600),n=Math.round(t%3600/60);return n>0?`${e}h ${n}m`:`${e}h`}function br(t){return!t||t.length===0?"none":t.join(", ")}function sp(t){return t?t.enabled?t.quiet_active?`Quiet hours ${wa(t.quiet_start)}-${wa(t.quiet_end)} KST are active. Scheduled ticks may look asleep until the window ends; Poke Now bypasses only that quiet-hours gate.`:t.last_tick_ago_s==null?`Lodge is enabled and scheduled every ${Bs(t.interval_s)}, but no tick has run yet in this runtime.`:`Lodge ticks every ${Bs(t.interval_s)}. Planner is ${t.use_planner?"on":"off"} and delegated LLM is ${t.delegate_llm?"on":"off"}.`:"Lodge automation is disabled. Manual poke will report the disabled state but will not revive a stopped runtime.":"Lodge runtime status is unavailable. Refresh the dashboard to inspect scheduling state."}async function re(){ea();try{await wn()}catch(t){console.warn("[control-dock] dashboard refresh failed",t)}}function ri(t){const e=t.trim();ct.value=e,e&&localStorage.setItem(ii,e)}function ip(t){const n=(t.split(`
`).find(a=>a.includes(" joined"))??t).match(/✅\s+(\S+)\s+joined/i);return(n==null?void 0:n[1])??null}async function Ws(){const t=ct.value.trim();if(t){on.value=!0;try{const e=await Bl(t),n=ip(e);n&&ri(n),La.value=!0,await re(),y(`Joined as ${n??t}`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to join room";y(n,"error")}finally{on.value=!1}}}async function op(){const t=ct.value.trim();if(t){rn.value=!0;try{await Wo(t),La.value=!1,await re(),y(`Left room (${t})`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to leave room";y(n,"error")}finally{rn.value=!1}}}async function rp(){const t=ct.value.trim();if(t)try{await Wo(t)}catch{}localStorage.removeItem(ii),ri("dashboard"),La.value=!1,await Ws()}async function lp(){const t=ct.value.trim();if(t){ka.value=!0;try{await Wl(t),await re(),y("Heartbeat sent","success")}catch(e){const n=e instanceof Error?e.message:"Failed to send heartbeat";y(n,"error")}finally{ka.value=!1}}}async function to(){const t=ct.value.trim(),e=en.value.trim();if(!(!t||!e)){sn.value=!0;try{await Bo(t,e),en.value="",await re(),y("Broadcast sent","success")}catch(n){const a=n instanceof Error?n.message:"Failed to send broadcast";y(a,"error")}finally{sn.value=!1}}}async function cp(){const t=nn.value.trim(),e=ya.value.trim()||"Created from dashboard";if(t){he.value=!0;try{await Kl(t,e,1),nn.value="",ya.value="",await re(),y("Task created","success")}catch(n){const a=n instanceof Error?n.message:"Failed to create task";y(a,"error")}finally{he.value=!1}}}async function up(){const t=Nt.value.trim(),e=an.value.trim();if(!t){y("Select a keeper first","warning");return}if(e){$e.value=!0;try{const n=await Zl(t,e);Ks.value={keeper:t,prompt:e,reply:n.trim()||"(empty reply)",isError:!1,at:new Date().toISOString()},an.value="",await re(),y(`Reply received from ${t}`,"success")}catch(n){const a=n instanceof Error?n.message:`Failed to send direct message to ${t}`;Ks.value={keeper:t,prompt:e,reply:a,isError:!0,at:new Date().toISOString()},y(a,"error")}finally{$e.value=!1}}}async function dp(){const t=ct.value.trim()||"dashboard";xa.value=!0,ba.value=null;try{const e=await Ho({actor:t,action_type:"lodge_tick",target_type:"room",payload:{}}),n=ap(e.result);yr.value=n,await re(),n!=null&&n.skipped_reason?y(n.skipped_reason,"warning"):y(n?`Poke finished: ${n.acted}/${n.checked} acted`:"Poke finished",n&&n.acted>0?"success":"warning")}catch(e){const n=e instanceof Error?e.message:"Failed to run Lodge poke";ba.value=n,y(n,"error")}finally{xa.value=!1}}function pp(){const t=Ks.value;return t?o`
    <div class=${`control-transcript ${t.isError?"is-error":"is-success"}`}>
      <div class="control-transcript-meta">
        <span>Keeper: ${t.keeper}</span>
        <span>${new Date(t.at).toLocaleTimeString()}</span>
      </div>
      <div class="control-transcript-label">Prompt</div>
      <pre class="control-transcript-text">${t.prompt}</pre>
      <div class="control-transcript-label">${t.isError?"Error":"Reply"}</div>
      <pre class="control-transcript-text">${t.reply}</pre>
    </div>
  `:o`<div class="control-status-copy">No direct keeper response yet.</div>`}function vp({runtime:t}){var s,i;const e=yr.value??(t==null?void 0:t.last_tick_result)??null;if(ba.value)return o`<div class="control-result-box is-error">${ba.value}</div>`;if(!e)return o`<div class="control-status-copy">No poke result yet. The latest scheduled tick will appear here after the first run.</div>`;const n=((s=e.skipped_rows)==null?void 0:s.slice(0,3))??[],a=((i=e.passed_rows)==null?void 0:i.slice(0,3))??[];return o`
    <div class="control-result-box">
      <div class="control-inline-meta">
        <span class="pill">${e.checked} checked</span>
        <span class="pill">${e.acted} acted</span>
        ${e.quiet_hours_overridden?o`<span class="pill">quiet hours bypassed</span>`:null}
      </div>
      <div class="control-status-copy">
        Last acted: ${br(e.acted_names)}
      </div>
      ${e.skipped_reason?o`<div class="control-status-copy">${e.skipped_reason}</div>`:null}
      ${e.activity_report?o`<pre class="control-transcript-text">${e.activity_report}</pre>`:null}
      ${n.length>0?o`
            <div class="control-result-list">
              ${n.map(r=>o`<div>${r.name}: ${r.reason??"skipped"}</div>`)}
            </div>
          `:null}
      ${a.length>0?o`
            <div class="control-result-list">
              ${a.map(r=>o`<div>${r.name}: ${r.reason??"passed"}</div>`)}
            </div>
          `:null}
    </div>
  `}function mp(){var n,a;const t=ft.value.map(s=>s.name),e=((n=Vt.value)==null?void 0:n.lodge)??null;return Dt(()=>{Ws()},[]),Dt(()=>{const s=t[0]??"";if(!Nt.value&&s){Nt.value=s;return}Nt.value&&!t.includes(Nt.value)&&(Nt.value=s)},[t.join("|")]),o`
    <section class="rail-card control-dock">
      <h3>Control Dock</h3>

      <div class="control-section">
        <div class="control-section-head">
          <h4>Room Identity</h4>
          <p class="control-help">Broadcasts and operator actions use this agent name.</p>
        </div>

        <label class="control-label" for="dock-agent">Agent</label>
        <input
          id="dock-agent"
          class="control-input"
          type="text"
          value=${ct.value}
          onInput=${s=>ri(s.target.value)}
        />

        <div class="control-actions">
          <button
            class="control-btn ghost"
            onClick=${()=>{Ws()}}
            disabled=${on.value||ct.value.trim()===""}
          >
            ${on.value?"Joining...":La.value?"Rejoin":"Join"}
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{op()}}
            disabled=${rn.value||ct.value.trim()===""}
          >
            ${rn.value?"Leaving...":"Leave"}
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{rp()}}
            disabled=${on.value||rn.value}
          >
            Reset ID
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{lp()}}
            disabled=${ka.value||ct.value.trim()===""}
          >
            ${ka.value?"Pinging...":"Heartbeat"}
          </button>
        </div>
      </div>

      <div class="control-section">
        <div class="control-section-head">
          <h4>Room Broadcast</h4>
          <p class="control-help">This is visible to the room and other agents. Use it for announcements, nudges, and @mentions, not private keeper prompts.</p>
        </div>

        <label class="control-label" for="dock-message">Broadcast</label>
        <div class="control-row">
          <input
            id="dock-message"
            class="control-input"
            type="text"
            placeholder="@agent or room-wide update"
            value=${en.value}
            onInput=${s=>{en.value=s.target.value}}
            onKeyDown=${s=>{s.key==="Enter"&&to()}}
            disabled=${sn.value}
          />
          <button
            class="control-btn"
            onClick=${to}
            disabled=${sn.value||en.value.trim()===""||ct.value.trim()===""}
          >
            ${sn.value?"Sending...":"Send"}
          </button>
        </div>
      </div>

      <div class="control-section">
        <div class="control-section-head">
          <h4>Keeper Direct Message</h4>
          <p class="control-help">This sends a 1:1 message through <code>masc_keeper_msg</code> and keeps the actual reply in the dock so you can see whether the keeper answered.</p>
        </div>

        <label class="control-label" for="dock-keeper">Keeper</label>
        <select
          id="dock-keeper"
          class="control-input"
          value=${Nt.value}
          onInput=${s=>{Nt.value=s.target.value}}
          disabled=${t.length===0||$e.value}
        >
          ${t.length===0?o`<option value="">No keepers available</option>`:t.map(s=>o`<option value=${s}>${s}</option>`)}
        </select>

        <textarea
          class="control-textarea"
          placeholder=${t.length===0?"No keeper is active yet":"Direct prompt for the selected keeper"}
          value=${an.value}
          onInput=${s=>{an.value=s.target.value}}
          disabled=${t.length===0||$e.value}
        ></textarea>

        <div class="control-actions">
          <button
            class="control-btn"
            onClick=${()=>{up()}}
            disabled=${$e.value||an.value.trim()===""||Nt.value.trim()===""}
          >
            ${$e.value?"Waiting...":"Send Direct Message"}
          </button>
        </div>

        <${pp} />
      </div>

      <div class="control-section">
        <div class="control-section-head">
          <h4>Lodge Status</h4>
          <p class="control-help">${sp(e)}</p>
        </div>

        <div class="control-inline-meta">
          <span class="pill">${e!=null&&e.enabled?"enabled":"disabled"}</span>
          <span class="pill">every ${Bs(e==null?void 0:e.interval_s)}</span>
          <span class="pill">quiet ${wa(e==null?void 0:e.quiet_start)}-${wa(e==null?void 0:e.quiet_end)} KST</span>
          <span class="pill">${e!=null&&e.quiet_active?"quiet active":"quiet inactive"}</span>
          <span class="pill">${e!=null&&e.use_planner?"planner on":"planner off"}</span>
          <span class="pill">${e!=null&&e.delegate_llm?"delegate llm on":"delegate llm off"}</span>
        </div>

        <div class="control-status-copy">
          Last tick: ${(e==null?void 0:e.last_tick_ago)??"never"} · Total ticks: ${(e==null?void 0:e.total_ticks)??0} · Last acted: ${br((a=e==null?void 0:e.last_tick_result)==null?void 0:a.acted_names)}
        </div>

        <div class="control-actions">
          <button
            class="control-btn secondary"
            onClick=${()=>{dp()}}
            disabled=${xa.value}
          >
            ${xa.value?"Poking...":"Poke Now"}
          </button>
        </div>

        <${vp} runtime=${e} />
      </div>

      <div class="control-section">
        <div class="control-section-head">
          <h4>Quick Task</h4>
          <p class="control-help">Fast backlog injection for local follow-up work.</p>
        </div>

        <input
          id="dock-task"
          class="control-input"
          type="text"
          placeholder="Task title"
          value=${nn.value}
          onInput=${s=>{nn.value=s.target.value}}
          disabled=${he.value}
        />
        <textarea
          class="control-textarea"
          placeholder="Task description (optional)"
          value=${ya.value}
          onInput=${s=>{ya.value=s.target.value}}
          disabled=${he.value}
        ></textarea>
        <button
          class="control-btn secondary"
          onClick=${cp}
          disabled=${he.value||nn.value.trim()===""}
        >
          ${he.value?"Creating...":"Create Task"}
        </button>
      </div>
    </section>
  `}const eo=[{id:"observe",label:"Observe",description:"Live health, execution state, and room-wide telemetry"},{id:"coordinate",label:"Coordinate",description:"Conversation, decisions, planning, and backlog context"},{id:"command",label:"Command",description:"Direct control surfaces and intervention workflows"}],Gs=[{id:"overview",label:"Overview",icon:"🏠",group:"observe",description:"Room health, keeper pressure, and top-line execution status"},{id:"execution",label:"Execution",icon:"🛠️",group:"observe",description:"Intervention queue for stalled work, ownership gaps, and execution drift"},{id:"agents",label:"Agents",icon:"🤖",group:"observe",description:"Live monitor for agent status, keeper pressure, and current execution focus"},{id:"activity",label:"Activity",icon:"📊",group:"observe",description:"Unified live stream for messages, task changes, board events, and keeper events"},{id:"board",label:"Board",icon:"💬",group:"coordinate",description:"Human and agent discussion feed with system noise filtered by default"},{id:"council",label:"Council",icon:"🏛️",group:"coordinate",description:"Debates, quorum status, and decision flow"},{id:"goals",label:"Planning",icon:"🎯",group:"coordinate",description:"Goals and MDAL loops in one planning surface with freshness signals"},{id:"tasks",label:"Tasks",icon:"📋",group:"coordinate",description:"Kanban-style task distribution"},{id:"ops",label:"Ops",icon:"🎮",group:"command",description:"Guided operator controls for room, sessions, and keepers"},{id:"trpg",label:"TRPG",icon:"⚔️",group:"command",description:"Narrative room control and state visibility"}];function fp(){const t=Et.value;return o`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"Live":"Reconnecting..."}</span>
      <span class="event-count">${bn.value} events</span>
    </div>
  `}function _p(){const t=St.value.tab,e=Et.value,n=Gs.find(r=>r.id===t),a=eo.find(r=>r.id===(n==null?void 0:n.group)),[s,i]=Oe(!1);return o`
    <aside class="dashboard-rail">
      <section class="rail-card">
        <div class="rail-card-head">
          <h3>Navigate</h3>
          ${a?o`<span class="rail-section-chip">${a.label}</span>`:null}
        </div>
        ${eo.map(r=>o`
          <div class="rail-nav-group" key=${r.id}>
            <div class="rail-group-label">${r.label}</div>
            <div class="rail-group-copy">${r.description}</div>
            <div class="rail-tab-list">
              ${Gs.filter(u=>u.group===r.id).map(u=>o`
                  <button
                    class="rail-tab-btn ${t===u.id?"active":""}"
                    onClick=${()=>pt(u.id)}
                  >
                    <span class="rail-tab-icon">${u.icon}</span>
                    <span class="rail-tab-copy">
                      <strong>${u.label}</strong>
                      <span>${u.description}</span>
                    </span>
                  </button>
                `)}
            </div>
          </div>
        `)}
        <div class="rail-view-note">
          <div class="rail-view-note-label">Current focus</div>
          <strong>${(n==null?void 0:n.label)??t}</strong>
          <p>${(n==null?void 0:n.description)??"Live operational view"}</p>
        </div>
      </section>

      <section class="rail-card">
        <div class="rail-card-head">
          <h3>Snapshot</h3>
          <span class="rail-section-chip ${e?"ok":"bad"}">${e?"Live":"Offline"}</span>
        </div>
        <div class="rail-stat-grid">
          <div class="rail-stat-card">
            <span>Agents</span>
            <strong>${Jt.value.length}</strong>
          </div>
          <div class="rail-stat-card">
            <span>Keepers</span>
            <strong>${ft.value.length}</strong>
          </div>
          <div class="rail-stat-card">
            <span>Tasks</span>
            <strong>${Tt.value.length}</strong>
          </div>
          <div class="rail-stat-card">
            <span>Events</span>
            <strong>${bn.value}</strong>
          </div>
        </div>
        <div class="rail-snapshot-copy">
          <span>Connection ${e?"healthy":"recovering"}</span>
          <span>${(a==null?void 0:a.label)??"Observe"} workspace active</span>
        </div>
        <div class="rail-inline-actions">
          <button
            class="rail-refresh-btn"
            onClick=${()=>{wn(),t==="ops"&&Ae(),t==="board"&&At(),t==="trpg"&&Lt(),t==="goals"&&(He(),Ue())}}
          >
            Refresh Now
          </button>
          <button class="rail-secondary-btn" onClick=${()=>pt("ops")}>
            Open Ops
          </button>
        </div>
      </section>

      <section class="rail-card fold-card">
        <div class="rail-card-head">
          <h3>Quick Actions</h3>
          <span class="rail-section-chip">${s?"Open":"Closed"}</span>
        </div>
        <button class="fold-toggle" onClick=${()=>i(r=>!r)}>
          <span>${s?"Hide inline actions":"Show inline actions"}</span>
          <span class="fold-toggle-meta">Join, broadcast, keeper DM, lodge poke</span>
        </button>
        ${s?o`<div class="rail-fold-body"><${mp} /></div>`:o`<div class="rail-fold-hint">Use inline actions for quick room nudges. Open the Ops tab for structured intervention work.</div>`}
      </section>
    </aside>
  `}function gp(){switch(St.value.tab){case"overview":return o`<${Fi} />`;case"ops":return o`<${mu} />`;case"council":return o`<${$u} />`;case"board":return o`<${Ru} />`;case"execution":return o`<${md} />`;case"activity":return o`<${Vu} />`;case"agents":return o`<${rd} />`;case"tasks":return o`<${ld} />`;case"goals":return o`<${xd} />`;case"trpg":return o`<${Xd} />`;default:return o`<${Fi} />`}}function hp(){Dt(()=>{Gr(),Oo(),wn(),At();const n=gc();return hc(),()=>{el(),n(),$c()}},[]),Dt(()=>{const n=St.value.tab;n==="ops"&&Ae(),n==="board"&&At(),n==="trpg"&&Lt(),n==="goals"&&(He(),Ue())},[St.value.tab]);const t=St.value.tab,e=Gs.find(n=>n.id===t);return o`
    <div class="app-shell">
      <header class="dashboard-header">
        <div class="header-title-wrap">
          <h1>
            MASC Dashboard
            <span class="version-badge">SPA</span>
          </h1>
          <p class="header-subtitle">${(e==null?void 0:e.description)??"Decision and execution operations console"}</p>
        </div>
        <div class="header-right">
          <${fp} />
        </div>
      </header>

      <div class="dashboard-layout">
        <${_p} />
        <main class="dashboard-main">
          ${Ss.value&&!Et.value?o`<div class="loading-indicator">Loading dashboard...</div>`:o`<${gp} />`}
        </main>
      </div>

      <${Ec} />
      <${qc} />
      <${Mc} />
    </div>
  `}const no=document.getElementById("app");no&&Cr(o`<${hp} />`,no);
