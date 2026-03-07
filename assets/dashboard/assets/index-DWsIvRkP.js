var Gr=Object.defineProperty;var Jr=(t,e,n)=>e in t?Gr(t,e,{enumerable:!0,configurable:!0,writable:!0,value:n}):t[e]=n;var me=(t,e,n)=>Jr(t,typeof e!="symbol"?e+"":e,n);(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const s of document.querySelectorAll('link[rel="modulepreload"]'))a(s);new MutationObserver(s=>{for(const i of s)if(i.type==="childList")for(const r of i.addedNodes)r.tagName==="LINK"&&r.rel==="modulepreload"&&a(r)}).observe(document,{childList:!0,subtree:!0});function n(s){const i={};return s.integrity&&(i.integrity=s.integrity),s.referrerPolicy&&(i.referrerPolicy=s.referrerPolicy),s.crossOrigin==="use-credentials"?i.credentials="include":s.crossOrigin==="anonymous"?i.credentials="omit":i.credentials="same-origin",i}function a(s){if(s.ep)return;s.ep=!0;const i=n(s);fetch(s.href,i)}})();var Ea,j,ko,xo,se,ki,wo,So,Ao,oi,ys,bs,mn={},To=[],Vr=/acit|ex(?:s|g|n|p|$)|rph|grid|ows|mnc|ntw|ine[ch]|zoo|^ord|itera/i,Pa=Array.isArray;function Dt(t,e){for(var n in e)t[n]=e[n];return t}function ri(t){t&&t.parentNode&&t.parentNode.removeChild(t)}function No(t,e,n){var a,s,i,r={};for(i in e)i=="key"?a=e[i]:i=="ref"?s=e[i]:r[i]=e[i];if(arguments.length>2&&(r.children=arguments.length>3?Ea.call(arguments,2):n),typeof t=="function"&&t.defaultProps!=null)for(i in t.defaultProps)r[i]===void 0&&(r[i]=t.defaultProps[i]);return Gn(t,r,a,s,null)}function Gn(t,e,n,a,s){var i={type:t,props:e,key:n,ref:a,__k:null,__:null,__b:0,__e:null,__c:null,constructor:void 0,__v:s??++ko,__i:-1,__u:0};return s==null&&j.vnode!=null&&j.vnode(i),i}function Sn(t){return t.children}function Be(t,e){this.props=t,this.context=e}function Re(t,e){if(e==null)return t.__?Re(t.__,t.__i+1):null;for(var n;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null)return n.__e;return typeof t.type=="function"?Re(t):null}function Co(t){var e,n;if((t=t.__)!=null&&t.__c!=null){for(t.__e=t.__c.base=null,e=0;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null){t.__e=t.__c.base=n.__e;break}return Co(t)}}function xi(t){(!t.__d&&(t.__d=!0)&&se.push(t)&&!sa.__r++||ki!=j.debounceRendering)&&((ki=j.debounceRendering)||wo)(sa)}function sa(){for(var t,e,n,a,s,i,r,u=1;se.length;)se.length>u&&se.sort(So),t=se.shift(),u=se.length,t.__d&&(n=void 0,a=void 0,s=(a=(e=t).__v).__e,i=[],r=[],e.__P&&((n=Dt({},a)).__v=a.__v+1,j.vnode&&j.vnode(n),li(e.__P,n,a,e.__n,e.__P.namespaceURI,32&a.__u?[s]:null,i,s??Re(a),!!(32&a.__u),r),n.__v=a.__v,n.__.__k[n.__i]=n,Do(i,n,r),a.__e=a.__=null,n.__e!=s&&Co(n)));sa.__r=0}function Ro(t,e,n,a,s,i,r,u,d,p,f){var l,c,m,h,y,w,C,S=a&&a.__k||To,P=e.length;for(d=Qr(n,e,S,d,P),l=0;l<P;l++)(m=n.__k[l])!=null&&(c=m.__i==-1?mn:S[m.__i]||mn,m.__i=l,w=li(t,m,c,s,i,r,u,d,p,f),h=m.__e,m.ref&&c.ref!=m.ref&&(c.ref&&ci(c.ref,null,m),f.push(m.ref,m.__c||h,m)),y==null&&h!=null&&(y=h),(C=!!(4&m.__u))||c.__k===m.__k?d=Lo(m,d,t,C):typeof m.type=="function"&&w!==void 0?d=w:h&&(d=h.nextSibling),m.__u&=-7);return n.__e=y,d}function Qr(t,e,n,a,s){var i,r,u,d,p,f=n.length,l=f,c=0;for(t.__k=new Array(s),i=0;i<s;i++)(r=e[i])!=null&&typeof r!="boolean"&&typeof r!="function"?(typeof r=="string"||typeof r=="number"||typeof r=="bigint"||r.constructor==String?r=t.__k[i]=Gn(null,r,null,null,null):Pa(r)?r=t.__k[i]=Gn(Sn,{children:r},null,null,null):r.constructor===void 0&&r.__b>0?r=t.__k[i]=Gn(r.type,r.props,r.key,r.ref?r.ref:null,r.__v):t.__k[i]=r,d=i+c,r.__=t,r.__b=t.__b+1,u=null,(p=r.__i=Yr(r,n,d,l))!=-1&&(l--,(u=n[p])&&(u.__u|=2)),u==null||u.__v==null?(p==-1&&(s>f?c--:s<f&&c++),typeof r.type!="function"&&(r.__u|=4)):p!=d&&(p==d-1?c--:p==d+1?c++:(p>d?c--:c++,r.__u|=4))):t.__k[i]=null;if(l)for(i=0;i<f;i++)(u=n[i])!=null&&(2&u.__u)==0&&(u.__e==a&&(a=Re(u)),Po(u,u));return a}function Lo(t,e,n,a){var s,i;if(typeof t.type=="function"){for(s=t.__k,i=0;s&&i<s.length;i++)s[i]&&(s[i].__=t,e=Lo(s[i],e,n,a));return e}t.__e!=e&&(a&&(e&&t.type&&!e.parentNode&&(e=Re(t)),n.insertBefore(t.__e,e||null)),e=t.__e);do e=e&&e.nextSibling;while(e!=null&&e.nodeType==8);return e}function Yr(t,e,n,a){var s,i,r,u=t.key,d=t.type,p=e[n],f=p!=null&&(2&p.__u)==0;if(p===null&&u==null||f&&u==p.key&&d==p.type)return n;if(a>(f?1:0)){for(s=n-1,i=n+1;s>=0||i<e.length;)if((p=e[r=s>=0?s--:i++])!=null&&(2&p.__u)==0&&u==p.key&&d==p.type)return r}return-1}function wi(t,e,n){e[0]=="-"?t.setProperty(e,n??""):t[e]=n==null?"":typeof n!="number"||Vr.test(e)?n:n+"px"}function In(t,e,n,a,s){var i,r;t:if(e=="style")if(typeof n=="string")t.style.cssText=n;else{if(typeof a=="string"&&(t.style.cssText=a=""),a)for(e in a)n&&e in n||wi(t.style,e,"");if(n)for(e in n)a&&n[e]==a[e]||wi(t.style,e,n[e])}else if(e[0]=="o"&&e[1]=="n")i=e!=(e=e.replace(Ao,"$1")),r=e.toLowerCase(),e=r in t||e=="onFocusOut"||e=="onFocusIn"?r.slice(2):e.slice(2),t.l||(t.l={}),t.l[e+i]=n,n?a?n.u=a.u:(n.u=oi,t.addEventListener(e,i?bs:ys,i)):t.removeEventListener(e,i?bs:ys,i);else{if(s=="http://www.w3.org/2000/svg")e=e.replace(/xlink(H|:h)/,"h").replace(/sName$/,"s");else if(e!="width"&&e!="height"&&e!="href"&&e!="list"&&e!="form"&&e!="tabIndex"&&e!="download"&&e!="rowSpan"&&e!="colSpan"&&e!="role"&&e!="popover"&&e in t)try{t[e]=n??"";break t}catch{}typeof n=="function"||(n==null||n===!1&&e[4]!="-"?t.removeAttribute(e):t.setAttribute(e,e=="popover"&&n==1?"":n))}}function Si(t){return function(e){if(this.l){var n=this.l[e.type+t];if(e.t==null)e.t=oi++;else if(e.t<n.u)return;return n(j.event?j.event(e):e)}}}function li(t,e,n,a,s,i,r,u,d,p){var f,l,c,m,h,y,w,C,S,P,A,L,tt,bt,kt,et,ut,I=e.type;if(e.constructor!==void 0)return null;128&n.__u&&(d=!!(32&n.__u),i=[u=e.__e=n.__e]),(f=j.__b)&&f(e);t:if(typeof I=="function")try{if(C=e.props,S="prototype"in I&&I.prototype.render,P=(f=I.contextType)&&a[f.__c],A=f?P?P.props.value:f.__:a,n.__c?w=(l=e.__c=n.__c).__=l.__E:(S?e.__c=l=new I(C,A):(e.__c=l=new Be(C,A),l.constructor=I,l.render=Zr),P&&P.sub(l),l.state||(l.state={}),l.__n=a,c=l.__d=!0,l.__h=[],l._sb=[]),S&&l.__s==null&&(l.__s=l.state),S&&I.getDerivedStateFromProps!=null&&(l.__s==l.state&&(l.__s=Dt({},l.__s)),Dt(l.__s,I.getDerivedStateFromProps(C,l.__s))),m=l.props,h=l.state,l.__v=e,c)S&&I.getDerivedStateFromProps==null&&l.componentWillMount!=null&&l.componentWillMount(),S&&l.componentDidMount!=null&&l.__h.push(l.componentDidMount);else{if(S&&I.getDerivedStateFromProps==null&&C!==m&&l.componentWillReceiveProps!=null&&l.componentWillReceiveProps(C,A),e.__v==n.__v||!l.__e&&l.shouldComponentUpdate!=null&&l.shouldComponentUpdate(C,l.__s,A)===!1){for(e.__v!=n.__v&&(l.props=C,l.state=l.__s,l.__d=!1),e.__e=n.__e,e.__k=n.__k,e.__k.some(function(W){W&&(W.__=e)}),L=0;L<l._sb.length;L++)l.__h.push(l._sb[L]);l._sb=[],l.__h.length&&r.push(l);break t}l.componentWillUpdate!=null&&l.componentWillUpdate(C,l.__s,A),S&&l.componentDidUpdate!=null&&l.__h.push(function(){l.componentDidUpdate(m,h,y)})}if(l.context=A,l.props=C,l.__P=t,l.__e=!1,tt=j.__r,bt=0,S){for(l.state=l.__s,l.__d=!1,tt&&tt(e),f=l.render(l.props,l.state,l.context),kt=0;kt<l._sb.length;kt++)l.__h.push(l._sb[kt]);l._sb=[]}else do l.__d=!1,tt&&tt(e),f=l.render(l.props,l.state,l.context),l.state=l.__s;while(l.__d&&++bt<25);l.state=l.__s,l.getChildContext!=null&&(a=Dt(Dt({},a),l.getChildContext())),S&&!c&&l.getSnapshotBeforeUpdate!=null&&(y=l.getSnapshotBeforeUpdate(m,h)),et=f,f!=null&&f.type===Sn&&f.key==null&&(et=Eo(f.props.children)),u=Ro(t,Pa(et)?et:[et],e,n,a,s,i,r,u,d,p),l.base=e.__e,e.__u&=-161,l.__h.length&&r.push(l),w&&(l.__E=l.__=null)}catch(W){if(e.__v=null,d||i!=null)if(W.then){for(e.__u|=d?160:128;u&&u.nodeType==8&&u.nextSibling;)u=u.nextSibling;i[i.indexOf(u)]=null,e.__e=u}else{for(ut=i.length;ut--;)ri(i[ut]);ks(e)}else e.__e=n.__e,e.__k=n.__k,W.then||ks(e);j.__e(W,e,n)}else i==null&&e.__v==n.__v?(e.__k=n.__k,e.__e=n.__e):u=e.__e=Xr(n.__e,e,n,a,s,i,r,d,p);return(f=j.diffed)&&f(e),128&e.__u?void 0:u}function ks(t){t&&t.__c&&(t.__c.__e=!0),t&&t.__k&&t.__k.forEach(ks)}function Do(t,e,n){for(var a=0;a<n.length;a++)ci(n[a],n[++a],n[++a]);j.__c&&j.__c(e,t),t.some(function(s){try{t=s.__h,s.__h=[],t.some(function(i){i.call(s)})}catch(i){j.__e(i,s.__v)}})}function Eo(t){return typeof t!="object"||t==null||t.__b&&t.__b>0?t:Pa(t)?t.map(Eo):Dt({},t)}function Xr(t,e,n,a,s,i,r,u,d){var p,f,l,c,m,h,y,w=n.props||mn,C=e.props,S=e.type;if(S=="svg"?s="http://www.w3.org/2000/svg":S=="math"?s="http://www.w3.org/1998/Math/MathML":s||(s="http://www.w3.org/1999/xhtml"),i!=null){for(p=0;p<i.length;p++)if((m=i[p])&&"setAttribute"in m==!!S&&(S?m.localName==S:m.nodeType==3)){t=m,i[p]=null;break}}if(t==null){if(S==null)return document.createTextNode(C);t=document.createElementNS(s,S,C.is&&C),u&&(j.__m&&j.__m(e,i),u=!1),i=null}if(S==null)w===C||u&&t.data==C||(t.data=C);else{if(i=i&&Ea.call(t.childNodes),!u&&i!=null)for(w={},p=0;p<t.attributes.length;p++)w[(m=t.attributes[p]).name]=m.value;for(p in w)if(m=w[p],p!="children"){if(p=="dangerouslySetInnerHTML")l=m;else if(!(p in C)){if(p=="value"&&"defaultValue"in C||p=="checked"&&"defaultChecked"in C)continue;In(t,p,null,m,s)}}for(p in C)m=C[p],p=="children"?c=m:p=="dangerouslySetInnerHTML"?f=m:p=="value"?h=m:p=="checked"?y=m:u&&typeof m!="function"||w[p]===m||In(t,p,m,w[p],s);if(f)u||l&&(f.__html==l.__html||f.__html==t.innerHTML)||(t.innerHTML=f.__html),e.__k=[];else if(l&&(t.innerHTML=""),Ro(e.type=="template"?t.content:t,Pa(c)?c:[c],e,n,a,S=="foreignObject"?"http://www.w3.org/1999/xhtml":s,i,r,i?i[0]:n.__k&&Re(n,0),u,d),i!=null)for(p=i.length;p--;)ri(i[p]);u||(p="value",S=="progress"&&h==null?t.removeAttribute("value"):h!=null&&(h!==t[p]||S=="progress"&&!h||S=="option"&&h!=w[p])&&In(t,p,h,w[p],s),p="checked",y!=null&&y!=t[p]&&In(t,p,y,w[p],s))}return t}function ci(t,e,n){try{if(typeof t=="function"){var a=typeof t.__u=="function";a&&t.__u(),a&&e==null||(t.__u=t(e))}else t.current=e}catch(s){j.__e(s,n)}}function Po(t,e,n){var a,s;if(j.unmount&&j.unmount(t),(a=t.ref)&&(a.current&&a.current!=t.__e||ci(a,null,e)),(a=t.__c)!=null){if(a.componentWillUnmount)try{a.componentWillUnmount()}catch(i){j.__e(i,e)}a.base=a.__P=null}if(a=t.__k)for(s=0;s<a.length;s++)a[s]&&Po(a[s],e,n||typeof t.type!="function");n||ri(t.__e),t.__c=t.__=t.__e=void 0}function Zr(t,e,n){return this.constructor(t,n)}function tl(t,e,n){var a,s,i,r;e==document&&(e=document.documentElement),j.__&&j.__(t,e),s=(a=!1)?null:e.__k,i=[],r=[],li(e,t=e.__k=No(Sn,null,[t]),s||mn,mn,e.namespaceURI,s?null:e.firstChild?Ea.call(e.childNodes):null,i,s?s.__e:e.firstChild,a,r),Do(i,t,r)}Ea=To.slice,j={__e:function(t,e,n,a){for(var s,i,r;e=e.__;)if((s=e.__c)&&!s.__)try{if((i=s.constructor)&&i.getDerivedStateFromError!=null&&(s.setState(i.getDerivedStateFromError(t)),r=s.__d),s.componentDidCatch!=null&&(s.componentDidCatch(t,a||{}),r=s.__d),r)return s.__E=s}catch(u){t=u}throw t}},ko=0,xo=function(t){return t!=null&&t.constructor===void 0},Be.prototype.setState=function(t,e){var n;n=this.__s!=null&&this.__s!=this.state?this.__s:this.__s=Dt({},this.state),typeof t=="function"&&(t=t(Dt({},n),this.props)),t&&Dt(n,t),t!=null&&this.__v&&(e&&this._sb.push(e),xi(this))},Be.prototype.forceUpdate=function(t){this.__v&&(this.__e=!0,t&&this.__h.push(t),xi(this))},Be.prototype.render=Sn,se=[],wo=typeof Promise=="function"?Promise.prototype.then.bind(Promise.resolve()):setTimeout,So=function(t,e){return t.__v.__b-e.__v.__b},sa.__r=0,Ao=/(PointerCapture)$|Capture$/i,oi=0,ys=Si(!1),bs=Si(!0);var Io=function(t,e,n,a){var s;e[0]=0;for(var i=1;i<e.length;i++){var r=e[i++],u=e[i]?(e[0]|=r?1:2,n[e[i++]]):e[++i];r===3?a[0]=u:r===4?a[1]=Object.assign(a[1]||{},u):r===5?(a[1]=a[1]||{})[e[++i]]=u:r===6?a[1][e[++i]]+=u+"":r?(s=t.apply(u,Io(t,u,n,["",null])),a.push(s),u[0]?e[0]|=2:(e[i-2]=0,e[i]=s)):a.push(u)}return a},Ai=new Map;function el(t){var e=Ai.get(this);return e||(e=new Map,Ai.set(this,e)),(e=Io(this,e.get(t)||(e.set(t,e=(function(n){for(var a,s,i=1,r="",u="",d=[0],p=function(c){i===1&&(c||(r=r.replace(/^\s*\n\s*|\s*\n\s*$/g,"")))?d.push(0,c,r):i===3&&(c||r)?(d.push(3,c,r),i=2):i===2&&r==="..."&&c?d.push(4,c,0):i===2&&r&&!c?d.push(5,0,!0,r):i>=5&&((r||!c&&i===5)&&(d.push(i,0,r,s),i=6),c&&(d.push(i,c,0,s),i=6)),r=""},f=0;f<n.length;f++){f&&(i===1&&p(),p(f));for(var l=0;l<n[f].length;l++)a=n[f][l],i===1?a==="<"?(p(),d=[d],i=3):r+=a:i===4?r==="--"&&a===">"?(i=1,r=""):r=a+r[0]:u?a===u?u="":r+=a:a==='"'||a==="'"?u=a:a===">"?(p(),i=1):i&&(a==="="?(i=5,s=r,r=""):a==="/"&&(i<5||n[f][l+1]===">")?(p(),i===3&&(d=d[0]),i=d,(d=d[0]).push(2,0,i),i=0):a===" "||a==="	"||a===`
`||a==="\r"?(p(),i=2):r+=a),i===3&&r==="!--"&&(i=4,d=d[0])}return p(),d})(t)),e),arguments,[])).length>1?e:e[0]}var o=el.bind(No),fn,B,za,Ti,xs=0,Mo=[],J=j,Ni=J.__b,Ci=J.__r,Ri=J.diffed,Li=J.__c,Di=J.unmount,Ei=J.__;function ui(t,e){J.__h&&J.__h(B,t,xs||e),xs=0;var n=B.__H||(B.__H={__:[],__h:[]});return t>=n.__.length&&n.__.push({}),n.__[t]}function Oo(t){return xs=1,nl(qo,t)}function nl(t,e,n){var a=ui(fn++,2);if(a.t=t,!a.__c&&(a.__=[qo(void 0,e),function(u){var d=a.__N?a.__N[0]:a.__[0],p=a.t(d,u);d!==p&&(a.__N=[p,a.__[1]],a.__c.setState({}))}],a.__c=B,!B.__f)){var s=function(u,d,p){if(!a.__c.__H)return!0;var f=a.__c.__H.__.filter(function(c){return!!c.__c});if(f.every(function(c){return!c.__N}))return!i||i.call(this,u,d,p);var l=a.__c.props!==u;return f.forEach(function(c){if(c.__N){var m=c.__[0];c.__=c.__N,c.__N=void 0,m!==c.__[0]&&(l=!0)}}),i&&i.call(this,u,d,p)||l};B.__f=!0;var i=B.shouldComponentUpdate,r=B.componentWillUpdate;B.componentWillUpdate=function(u,d,p){if(this.__e){var f=i;i=void 0,s(u,d,p),i=f}r&&r.call(this,u,d,p)},B.shouldComponentUpdate=s}return a.__N||a.__}function Rt(t,e){var n=ui(fn++,3);!J.__s&&jo(n.__H,e)&&(n.__=t,n.u=e,B.__H.__h.push(n))}function Fo(t,e){var n=ui(fn++,7);return jo(n.__H,e)&&(n.__=t(),n.__H=e,n.__h=t),n.__}function al(){for(var t;t=Mo.shift();)if(t.__P&&t.__H)try{t.__H.__h.forEach(Jn),t.__H.__h.forEach(ws),t.__H.__h=[]}catch(e){t.__H.__h=[],J.__e(e,t.__v)}}J.__b=function(t){B=null,Ni&&Ni(t)},J.__=function(t,e){t&&e.__k&&e.__k.__m&&(t.__m=e.__k.__m),Ei&&Ei(t,e)},J.__r=function(t){Ci&&Ci(t),fn=0;var e=(B=t.__c).__H;e&&(za===B?(e.__h=[],B.__h=[],e.__.forEach(function(n){n.__N&&(n.__=n.__N),n.u=n.__N=void 0})):(e.__h.forEach(Jn),e.__h.forEach(ws),e.__h=[],fn=0)),za=B},J.diffed=function(t){Ri&&Ri(t);var e=t.__c;e&&e.__H&&(e.__H.__h.length&&(Mo.push(e)!==1&&Ti===J.requestAnimationFrame||((Ti=J.requestAnimationFrame)||sl)(al)),e.__H.__.forEach(function(n){n.u&&(n.__H=n.u),n.u=void 0})),za=B=null},J.__c=function(t,e){e.some(function(n){try{n.__h.forEach(Jn),n.__h=n.__h.filter(function(a){return!a.__||ws(a)})}catch(a){e.some(function(s){s.__h&&(s.__h=[])}),e=[],J.__e(a,n.__v)}}),Li&&Li(t,e)},J.unmount=function(t){Di&&Di(t);var e,n=t.__c;n&&n.__H&&(n.__H.__.forEach(function(a){try{Jn(a)}catch(s){e=s}}),n.__H=void 0,e&&J.__e(e,n.__v))};var Pi=typeof requestAnimationFrame=="function";function sl(t){var e,n=function(){clearTimeout(a),Pi&&cancelAnimationFrame(e),setTimeout(t)},a=setTimeout(n,35);Pi&&(e=requestAnimationFrame(n))}function Jn(t){var e=B,n=t.__c;typeof n=="function"&&(t.__c=void 0,n()),B=e}function ws(t){var e=B;t.__c=t.__(),B=e}function jo(t,e){return!t||t.length!==e.length||e.some(function(n,a){return n!==t[a]})}function qo(t,e){return typeof e=="function"?e(t):e}var il=Symbol.for("preact-signals");function Ia(){if(Qt>1)Qt--;else{for(var t,e=!1;We!==void 0;){var n=We;for(We=void 0,Ss++;n!==void 0;){var a=n.o;if(n.o=void 0,n.f&=-3,!(8&n.f)&&Ko(n))try{n.c()}catch(s){e||(t=s,e=!0)}n=a}}if(Ss=0,Qt--,e)throw t}}function ol(t){if(Qt>0)return t();Qt++;try{return t()}finally{Ia()}}var F=void 0;function zo(t){var e=F;F=void 0;try{return t()}finally{F=e}}var We=void 0,Qt=0,Ss=0,ia=0;function Ho(t){if(F!==void 0){var e=t.n;if(e===void 0||e.t!==F)return e={i:0,S:t,p:F.s,n:void 0,t:F,e:void 0,x:void 0,r:e},F.s!==void 0&&(F.s.n=e),F.s=e,t.n=e,32&F.f&&t.S(e),e;if(e.i===-1)return e.i=0,e.n!==void 0&&(e.n.p=e.p,e.p!==void 0&&(e.p.n=e.n),e.p=F.s,e.n=void 0,F.s.n=e,F.s=e),e}}function Q(t,e){this.v=t,this.i=0,this.n=void 0,this.t=void 0,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}Q.prototype.brand=il;Q.prototype.h=function(){return!0};Q.prototype.S=function(t){var e=this,n=this.t;n!==t&&t.e===void 0&&(t.x=n,this.t=t,n!==void 0?n.e=t:zo(function(){var a;(a=e.W)==null||a.call(e)}))};Q.prototype.U=function(t){var e=this;if(this.t!==void 0){var n=t.e,a=t.x;n!==void 0&&(n.x=a,t.e=void 0),a!==void 0&&(a.e=n,t.x=void 0),t===this.t&&(this.t=a,a===void 0&&zo(function(){var s;(s=e.Z)==null||s.call(e)}))}};Q.prototype.subscribe=function(t){var e=this;return An(function(){var n=e.value,a=F;F=void 0;try{t(n)}finally{F=a}},{name:"sub"})};Q.prototype.valueOf=function(){return this.value};Q.prototype.toString=function(){return this.value+""};Q.prototype.toJSON=function(){return this.value};Q.prototype.peek=function(){var t=F;F=void 0;try{return this.value}finally{F=t}};Object.defineProperty(Q.prototype,"value",{get:function(){var t=Ho(this);return t!==void 0&&(t.i=this.i),this.v},set:function(t){if(t!==this.v){if(Ss>100)throw new Error("Cycle detected");this.v=t,this.i++,ia++,Qt++;try{for(var e=this.t;e!==void 0;e=e.x)e.t.N()}finally{Ia()}}}});function _(t,e){return new Q(t,e)}function Ko(t){for(var e=t.s;e!==void 0;e=e.n)if(e.S.i!==e.i||!e.S.h()||e.S.i!==e.i)return!0;return!1}function Uo(t){for(var e=t.s;e!==void 0;e=e.n){var n=e.S.n;if(n!==void 0&&(e.r=n),e.S.n=e,e.i=-1,e.n===void 0){t.s=e;break}}}function Bo(t){for(var e=t.s,n=void 0;e!==void 0;){var a=e.p;e.i===-1?(e.S.U(e),a!==void 0&&(a.n=e.n),e.n!==void 0&&(e.n.p=a)):n=e,e.S.n=e.r,e.r!==void 0&&(e.r=void 0),e=a}t.s=n}function de(t,e){Q.call(this,void 0),this.x=t,this.s=void 0,this.g=ia-1,this.f=4,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}de.prototype=new Q;de.prototype.h=function(){if(this.f&=-3,1&this.f)return!1;if((36&this.f)==32||(this.f&=-5,this.g===ia))return!0;if(this.g=ia,this.f|=1,this.i>0&&!Ko(this))return this.f&=-2,!0;var t=F;try{Uo(this),F=this;var e=this.x();(16&this.f||this.v!==e||this.i===0)&&(this.v=e,this.f&=-17,this.i++)}catch(n){this.v=n,this.f|=16,this.i++}return F=t,Bo(this),this.f&=-2,!0};de.prototype.S=function(t){if(this.t===void 0){this.f|=36;for(var e=this.s;e!==void 0;e=e.n)e.S.S(e)}Q.prototype.S.call(this,t)};de.prototype.U=function(t){if(this.t!==void 0&&(Q.prototype.U.call(this,t),this.t===void 0)){this.f&=-33;for(var e=this.s;e!==void 0;e=e.n)e.S.U(e)}};de.prototype.N=function(){if(!(2&this.f)){this.f|=6;for(var t=this.t;t!==void 0;t=t.x)t.t.N()}};Object.defineProperty(de.prototype,"value",{get:function(){if(1&this.f)throw new Error("Cycle detected");var t=Ho(this);if(this.h(),t!==void 0&&(t.i=this.i),16&this.f)throw this.v;return this.v}});function ct(t,e){return new de(t,e)}function Wo(t){var e=t.u;if(t.u=void 0,typeof e=="function"){Qt++;var n=F;F=void 0;try{e()}catch(a){throw t.f&=-2,t.f|=8,di(t),a}finally{F=n,Ia()}}}function di(t){for(var e=t.s;e!==void 0;e=e.n)e.S.U(e);t.x=void 0,t.s=void 0,Wo(t)}function rl(t){if(F!==this)throw new Error("Out-of-order effect");Bo(this),F=t,this.f&=-2,8&this.f&&di(this),Ia()}function Pe(t,e){this.x=t,this.u=void 0,this.s=void 0,this.o=void 0,this.f=32,this.name=e==null?void 0:e.name}Pe.prototype.c=function(){var t=this.S();try{if(8&this.f||this.x===void 0)return;var e=this.x();typeof e=="function"&&(this.u=e)}finally{t()}};Pe.prototype.S=function(){if(1&this.f)throw new Error("Cycle detected");this.f|=1,this.f&=-9,Wo(this),Uo(this),Qt++;var t=F;return F=this,rl.bind(this,t)};Pe.prototype.N=function(){2&this.f||(this.f|=2,this.o=We,We=this)};Pe.prototype.d=function(){this.f|=8,1&this.f||di(this)};Pe.prototype.dispose=function(){this.d()};function An(t,e){var n=new Pe(t,e);try{n.c()}catch(s){throw n.d(),s}var a=n.d.bind(n);return a[Symbol.dispose]=a,a}var Go,Mn,ll=typeof window<"u"&&!!window.__PREACT_SIGNALS_DEVTOOLS__,Jo=[];An(function(){Go=this.N})();function Ie(t,e){j[t]=e.bind(null,j[t]||function(){})}function oa(t){if(Mn){var e=Mn;Mn=void 0,e()}Mn=t&&t.S()}function Vo(t){var e=this,n=t.data,a=ul(n);a.value=n;var s=Fo(function(){for(var u=e,d=e.__v;d=d.__;)if(d.__c){d.__c.__$f|=4;break}var p=ct(function(){var m=a.value.value;return m===0?0:m===!0?"":m||""}),f=ct(function(){return!Array.isArray(p.value)&&!xo(p.value)}),l=An(function(){if(this.N=Qo,f.value){var m=p.value;u.__v&&u.__v.__e&&u.__v.__e.nodeType===3&&(u.__v.__e.data=m)}}),c=e.__$u.d;return e.__$u.d=function(){l(),c.call(this)},[f,p]},[]),i=s[0],r=s[1];return i.value?r.peek():r.value}Vo.displayName="ReactiveTextNode";Object.defineProperties(Q.prototype,{constructor:{configurable:!0,value:void 0},type:{configurable:!0,value:Vo},props:{configurable:!0,get:function(){return{data:this}}},__b:{configurable:!0,value:1}});Ie("__b",function(t,e){if(typeof e.type=="string"){var n,a=e.props;for(var s in a)if(s!=="children"){var i=a[s];i instanceof Q&&(n||(e.__np=n={}),n[s]=i,a[s]=i.peek())}}t(e)});Ie("__r",function(t,e){if(t(e),e.type!==Sn){oa();var n,a=e.__c;a&&(a.__$f&=-2,(n=a.__$u)===void 0&&(a.__$u=n=(function(s,i){var r;return An(function(){r=this},{name:i}),r.c=s,r})(function(){var s;ll&&((s=n.y)==null||s.call(n)),a.__$f|=1,a.setState({})},typeof e.type=="function"?e.type.displayName||e.type.name:""))),oa(n)}});Ie("__e",function(t,e,n,a){oa(),t(e,n,a)});Ie("diffed",function(t,e){oa();var n;if(typeof e.type=="string"&&(n=e.__e)){var a=e.__np,s=e.props;if(a){var i=n.U;if(i)for(var r in i){var u=i[r];u!==void 0&&!(r in a)&&(u.d(),i[r]=void 0)}else i={},n.U=i;for(var d in a){var p=i[d],f=a[d];p===void 0?(p=cl(n,d,f),i[d]=p):p.o(f,s)}for(var l in a)s[l]=a[l]}}t(e)});function cl(t,e,n,a){var s=e in t&&t.ownerSVGElement===void 0,i=_(n),r=n.peek();return{o:function(u,d){i.value=u,r=u.peek()},d:An(function(){this.N=Qo;var u=i.value.value;r!==u?(r=void 0,s?t[e]=u:u!=null&&(u!==!1||e[4]==="-")?t.setAttribute(e,u):t.removeAttribute(e)):r=void 0})}}Ie("unmount",function(t,e){if(typeof e.type=="string"){var n=e.__e;if(n){var a=n.U;if(a){n.U=void 0;for(var s in a){var i=a[s];i&&i.d()}}}e.__np=void 0}else{var r=e.__c;if(r){var u=r.__$u;u&&(r.__$u=void 0,u.d())}}t(e)});Ie("__h",function(t,e,n,a){(a<3||a===9)&&(e.__$f|=2),t(e,n,a)});Be.prototype.shouldComponentUpdate=function(t,e){if(this.__R)return!0;var n=this.__$u,a=n&&n.s!==void 0;for(var s in e)return!0;if(this.__f||typeof this.u=="boolean"&&this.u===!0){var i=2&this.__$f;if(!(a||i||4&this.__$f)||1&this.__$f)return!0}else if(!(a||4&this.__$f)||3&this.__$f)return!0;for(var r in t)if(r!=="__source"&&t[r]!==this.props[r])return!0;for(var u in this.props)if(!(u in t))return!0;return!1};function ul(t,e){return Fo(function(){return _(t,e)},[])}var dl=function(t){queueMicrotask(function(){queueMicrotask(t)})};function pl(){ol(function(){for(var t;t=Jo.shift();)Go.call(t)})}function Qo(){Jo.push(this)===1&&(j.requestAnimationFrame||dl)(pl)}const vl=["overview","board","activity","council","goals","execution","tasks","agents","ops","trpg"],Yo={tab:"overview",params:{},postId:null},ml={journal:"activity",mdal:"goals"};function Ii(t){return!!t&&vl.includes(t)}function Mi(t){if(t)return ml[t]??t}function As(t){try{return decodeURIComponent(t)}catch{return t}}function Ts(t){const e={};return t&&new URLSearchParams(t).forEach((a,s)=>{e[s]=a}),e}function fl(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function Xo(t,e){const n=Mi(t[0]),a=Mi(e.tab),s=Ii(n)?n:Ii(a)?a:"overview";let i=null;return s==="board"&&(t[0]==="board"&&t[1]==="post"&&t[2]?i=As(t[2]):t[0]==="post"&&t[1]&&(i=As(t[1]))),{tab:s,params:e,postId:i}}function ra(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return Yo;const n=As(e);let a=n,s;if(n.startsWith("?"))a="",s=n.slice(1);else{const u=n.indexOf("?");u>=0&&(a=n.slice(0,u),s=n.slice(u+1))}!s&&a.includes("=")&&!a.includes("/")&&(s=a,a="");const i=Ts(s),r=fl(a);return Xo(r,i)}function _l(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const a=n.slice(1);if(a.length===0)return{...Yo,params:Ts(e.replace(/^\?/,""))};if(a[0]==="assets"||a[0]==="credits"||a[0]==="lodge")return null;const s=Ts(e.replace(/^\?/,""));return Xo(a,s)}function Zo(t){const e=t.postId?`board/post/${encodeURIComponent(t.postId)}`:t.tab,n=Object.entries(t.params).filter(([s])=>s!=="tab");if(n.length===0)return`#${e}`;const a=new URLSearchParams(n);return`#${e}?${a.toString()}`}const Nt=_(ra(window.location.hash));window.addEventListener("hashchange",()=>{Nt.value=ra(window.location.hash)});function _t(t,e){const n={tab:t,params:{},postId:null};window.location.hash=Zo(n)}function gl(t){window.location.hash=`#board/post/${encodeURIComponent(t)}`}function hl(){if(window.location.hash&&window.location.hash!=="#"){Nt.value=ra(window.location.hash);return}const t=_l(window.location.pathname,window.location.search);if(t){Nt.value=t;const e=Zo(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#overview",Nt.value=ra(window.location.hash)}const Oi="masc_dashboard_sse_session_id",$l=1e3,yl=15e3,It=_(!1),Tn=_(0),tr=_(null),Xt=_([]);function bl(){let t=sessionStorage.getItem(Oi);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(Oi,t)),t}const kl=200;function xl(t,e,n="system",a={}){const s={agent:t,text:e,timestamp:Date.now(),kind:n,...a};Xt.value=[s,...Xt.value].slice(0,kl)}function Ns(t,e=88){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:void 0}function Fi(t,e){const n=Ns(e);return n?`${t}: ${n}`:`New ${t.toLowerCase()}`}function mt(t,e,n,a,s={}){xl(t,e,n,{eventType:a,...s})}let Tt=null,Ae=null,Cs=0;function er(){Ae&&(clearTimeout(Ae),Ae=null)}function wl(){if(Ae)return;Cs++;const t=Math.min(Cs,5),e=Math.min(yl,$l*Math.pow(2,t));Ae=setTimeout(()=>{Ae=null,nr()},e)}function nr(){er(),Tt&&(Tt.close(),Tt=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),a=t.get("token");n&&e.set("agent",n),a&&e.set("token",a),e.set("session_id",bl());const s=e.toString()?`/sse?${e.toString()}`:"/sse",i=new EventSource(s);Tt=i,i.onopen=()=>{Tt===i&&(Cs=0,It.value=!0)},i.onerror=()=>{Tt===i&&(It.value=!1,i.close(),Tt=null,wl())},i.onmessage=r=>{try{const u=JSON.parse(r.data);Tn.value++,tr.value=u,Sl(u)}catch{}}}function Sl(t){const e=t.type,n=t.agent??t.author??t.from??t.from_agent??"";switch(e){case"agent_joined":mt(n,"Joined","system","agent_joined");break;case"agent_left":mt(n,"Left","system","agent_left");break;case"broadcast":mt(n,`${(t.message??t.content??"").slice(0,80)}`,"system","broadcast");break;case"task_update":mt(n,`Task: ${t.task_id??""} -> ${t.status??""}`,"tasks","task_update");break;case"board_post":case"masc/board_post":mt(n,Fi("Post",t.content??t.message),"board","board_post",{author:t.author??n,preview:Ns(t.content??t.message),postId:t.post_id});break;case"board_comment":case"masc/board_comment":mt(n,Fi("Comment",t.content??t.message),"board","board_comment",{author:t.author??n,preview:Ns(t.content??t.message),postId:t.post_id});break;case"keeper_heartbeat":mt(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`,"keepers","keeper_heartbeat");break;case"keeper_handoff":mt(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`,"keepers","keeper_handoff");break;case"keeper_compaction":mt(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`,"keepers","keeper_compaction");break;case"keeper_guardrail":mt(t.name??n,`Guardrail: ${t.reason??"stopped"}`,"keepers","keeper_guardrail");break;default:mt(n,e,"system","unknown")}}function Al(){er(),Tt&&(Tt.close(),Tt=null),It.value=!1}function ar(){return new URLSearchParams(window.location.search)}function sr(){const t=ar(),e={},n=t.get("token"),a=t.get("agent")??t.get("agent_name");return n&&(e.Authorization=`Bearer ${n}`),a&&(e["X-MASC-Agent"]=a),e}function ir(){return{...sr(),"Content-Type":"application/json"}}const Tl=15e3,or=3e4,Nl=6e4,ji=new Set([408,425,429,500,502,503,504]);class Nn extends Error{constructor(n){const a=n.method.toUpperCase(),s=n.timeout===!0,i=s?`${a} ${n.path}: timeout after ${n.timeoutMs??0}ms`:`${a} ${n.path}: ${n.status??"unknown"} ${n.statusText??""}`.trim();super(i);me(this,"method");me(this,"path");me(this,"status");me(this,"statusText");me(this,"timeout");this.name="ApiRequestError",this.method=a,this.path=n.path,this.status=n.status,this.statusText=n.statusText,this.timeout=s}}async function pi(t,e,n){const a=new AbortController,s=setTimeout(()=>a.abort(),n);try{return await fetch(t,{...e,signal:a.signal})}catch(i){if(i instanceof Error&&i.name==="AbortError"){const r=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new Nn({method:r,path:t,timeout:!0,timeoutMs:n})}throw i}finally{clearTimeout(s)}}function Cl(){var e,n;const t=ar();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function jt(t){const e=await pi(t,{headers:sr()},Tl);if(!e.ok)throw new Nn({method:"GET",path:t,status:e.status,statusText:e.statusText});return e.json()}function Rl(t){return new Promise(e=>setTimeout(e,t))}function Ll(t){const e=t.match(/\b(\d{3})\b/);if(!e)return null;const n=e[1];if(!n)return null;const a=Number.parseInt(n,10);return Number.isFinite(a)?a:null}function Dl(t){if(t instanceof Nn)return t.timeout||typeof t.status=="number"&&ji.has(t.status);if(!(t instanceof Error))return!1;if(/timeout after \d+ms/i.test(t.message))return!0;const e=Ll(t.message);return e!==null&&ji.has(e)}async function Cn(t,e,n=2){let a=0;for(;;)try{return await e()}catch(s){if(!Dl(s)||a>=n)throw s;const i=250*(a+1);console.warn(`[dashboard/api] ${t} failed (attempt ${a+1}), retrying in ${i}ms`,s),await Rl(i),a+=1}}async function qt(t,e,n){const a=await pi(t,{method:"POST",headers:{...ir(),...n??{}},body:JSON.stringify(e)},or);if(!a.ok)throw new Nn({method:"POST",path:t,status:a.status,statusText:a.statusText});return a.json()}async function El(t,e,n,a=or){const s=await pi(t,{method:"POST",headers:{...ir(),...n??{}},body:JSON.stringify(e)},a);if(!s.ok)throw new Nn({method:"POST",path:t,status:s.status,statusText:s.statusText});return s.text()}function Pl(t){const e=t.split(`
`).find(a=>a.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function Il(t){var e,n,a,s,i,r,u;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const d=((s=(a=t.result.content)==null?void 0:a[0])==null?void 0:s.text)??"MCP tool call failed";throw new Error(d)}return((u=(r=(i=t.result)==null?void 0:i.content)==null?void 0:r[0])==null?void 0:u.text)??""}async function st(t,e){const n=await El("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},Nl),a=Pl(n);return Il(a)}function Ml(t="compact"){return jt(`/api/v1/dashboard?mode=${t}`)}function Ol(){return jt("/api/v1/operator")}function Rn(t){return qt("/api/v1/operator/action",t)}function Fl(t,e){return qt("/api/v1/operator/confirm",{actor:t,confirm_token:e})}const jl=new Set(["lodge-system","team-session"]);function Le(t){if(typeof t=="string"&&t.trim())return t;if(typeof t!="number"||Number.isNaN(t))return new Date().toISOString();const e=t<1e12?t*1e3:t;return new Date(e).toISOString()}function ql(t){return jl.has(t.trim().toLowerCase())}function zl(t){return t.filter(e=>!ql(e.author))}function Hl(t){var s;const e=t.trim(),a=((s=(e.startsWith("[flair:")?e.replace(/^\[flair:[^\]]+\]\s*/i,""):e).split(`
`)[0])==null?void 0:s.trim())||"Untitled post";return a.length<=96?a:`${a.slice(0,93)}...`}function rr(t){if(!E(t))return null;const e=g(t.id,"").trim(),n=g(t.author,"").trim(),a=g(t.content,"").trim();if(!e||!n)return null;const s=D(t.score,0),i=D(t.votes_up,0),r=D(t.votes_down,0),u=D(t.votes,s||i-r),d=D(t.comment_count,D(t.reply_count,0)),p=(()=>{const h=t.flair;if(typeof h=="string"&&h.trim())return h.trim();if(E(h)){const w=g(h.name,"").trim();if(w)return w}return g(t.flair_name,"").trim()||void 0})(),f=g(t.created_at_iso,"").trim()||Le(t.created_at),l=g(t.updated_at_iso,"").trim()||(t.updated_at!==void 0?Le(t.updated_at):f),m=g(t.title,"").trim()||Hl(a);return{id:e,author:n,title:m,content:a,tags:[],votes:u,vote_balance:s,comment_count:d,created_at:f,updated_at:l,flair:p,hearth_count:D(t.hearth_count,0)}}function Kl(t){if(!E(t))return null;const e=g(t.id,"").trim(),n=g(t.post_id,"").trim(),a=g(t.author,"").trim();return!e||!a?null:{id:e,post_id:n,author:a,content:g(t.content,""),created_at:Le(t.created_at)}}async function Ul(t,e){return Cn("fetchBoard",async()=>{const n=new URLSearchParams;t&&n.set("sort_by",t),e!=null&&e.excludeSystem&&n.set("exclude_system","true"),n.set("limit",e!=null&&e.excludeSystem?"150":"100");const a=n.toString(),s=await jt(`/api/v1/board${a?`?${a}`:""}`),i=Array.isArray(s.posts)?s.posts.map(rr).filter(u=>u!==null):[];return{posts:e!=null&&e.excludeSystem?zl(i):i}})}async function Bl(t){return Cn("fetchBoardPost",async()=>{const e=await jt(`/api/v1/board/${t}?format=flat`),n=E(e.post)?e.post:e,a=rr(n)??{id:t,author:"unknown",title:"Post",content:"",tags:[],votes:0,comment_count:0,created_at:new Date().toISOString(),updated_at:new Date().toISOString()},i=(Array.isArray(e.comments)?e.comments:[]).map(Kl).filter(r=>r!==null);return{...a,comments:i}})}function lr(t,e){return qt("/api/v1/tools/masc_board_vote",{post_id:t,direction:e,vote:e,voter:Cl()})}function Wl(t,e,n){return qt("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function Gl(t){const e=g(t,"").trim().toLowerCase();if(e==="win"||e==="won"||e==="victory")return"victory";if(e==="lose"||e==="lost"||e==="defeat")return"defeat";if(e==="draw"||e==="stalemate"||e==="tie")return"draw"}function X(...t){for(const e of t){const n=g(e,"");if(n.trim())return n.trim()}return""}function qi(t){const e=Gl(X(t.outcome,t.result,t.result_code));if(!e)return;const n=X(t.reason,t.reason_code,t.description,t.detail),a=X(t.summary,t.summary_ko,t.summary_en,t.note),s=X(t.details,t.details_text,t.text,t.note),i=X(t.winner,t.winner_name,t.actor_winner,t.winner_actor),r=X(t.winner_actor_id,t.winner_actor,t.actor_winner_id),u=X(t.raw_reason,t.raw_reason_code,t.error_message),d=(()=>{const l=t.evidence??t.evidence_ids??t.supporting_events??t.event_ids??[];return typeof l=="string"?[l]:Array.isArray(l)?l.map(c=>{if(typeof c=="string")return c.trim();if(E(c)){const m=g(c.summary,"").trim();if(m)return m;const h=g(c.text,"").trim();if(h)return h;const y=g(c.type,"").trim();return y||g(c.event_id,"").trim()}return""}).filter(c=>c.length>0):[]})(),p=(()=>{const l=D(t.turn,Number.NaN);if(Number.isFinite(l))return l;const c=D(t.turn_number,Number.NaN);if(Number.isFinite(c))return c;const m=D(t.current_turn,Number.NaN);if(Number.isFinite(m))return m;const h=D(t.round,Number.NaN);return Number.isFinite(h)?h:void 0})(),f=X(t.phase,t.phase_name,t.current_phase,t.phase_id);return{result:e,reason:n||void 0,summary:a||void 0,details:s||void 0,winner:i||void 0,winner_actor_id:r||void 0,evidence:d.length>0?d:void 0,raw_reason:u||void 0,turn:p,phase:f||void 0}}function Jl(t,e){const n=E(t.state)?t.state:{};if(g(n.status,"active").toLowerCase()!=="ended")return;const s=[...e].reverse().find(r=>E(r)?g(r.type,"")==="session.outcome":!1),i=E(n.session_outcome)?n.session_outcome:{};if(E(i)&&Object.keys(i).length>0){const r=qi(i);if(r)return r}if(E(s))return qi(E(s.payload)?s.payload:{})}function E(t){return typeof t=="object"&&t!==null}function g(t,e=""){return typeof t=="string"?t:e}function D(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function Vt(t){if(typeof t=="number"&&Number.isFinite(t))return Math.trunc(t);if(typeof t=="string"){const e=Number.parseInt(t.trim(),10);if(Number.isFinite(e))return e}}function Rs(t,e=!1){return typeof t=="boolean"?t:e}function je(t){return Array.isArray(t)?t.map(e=>{if(typeof e=="string")return e.trim();if(E(e)){const n=g(e.name,"").trim(),a=g(e.id,"").trim(),s=g(e.skill,"").trim();return n||a||s}return""}).filter(e=>e.length>0):[]}function Vl(t){const e={};if(!E(t)&&!Array.isArray(t))return e;if(E(t))return Object.entries(t).forEach(([n,a])=>{const s=n.trim(),i=g(a,"").trim();!s||!i||(e[s]=i)}),e;for(const n of t){if(!E(n))continue;const a=X(n.to,n.target,n.actor_id,n.name,n.id),s=X(n.relationship,n.relation,n.type,n.kind);!a||!s||(e[a]=s)}return e}function Ql(t,e,n){if(t==="dm"||t==="player"||t==="npc")return t;const a=e.trim().toLowerCase();return a==="dm"||a.startsWith("dm-")?"dm":a.startsWith("npc-")||a.startsWith("enemy-")||a.startsWith("mob-")?"npc":/^p\d+$/i.test(a)||a.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function dt(t,e,n,a=0){const s=t[e];if(typeof s=="number"&&Number.isFinite(s))return s;if(n){const i=t[n];if(typeof i=="number"&&Number.isFinite(i))return i}return a}const Yl=new Set(["str","dex","con","int","wis","cha","strength","dexterity","constitution","intelligence","wisdom","charisma","hp","max_hp","mp","max_mp","level","xp"]);function Xl(t){const e=E(t.stats)?t.stats:{},n={};return Object.entries(e).forEach(([a,s])=>{const i=a.trim();i&&(Yl.has(i.toLowerCase())||typeof s=="number"&&Number.isFinite(s)&&(n[i]=s))}),n}function Zl(t,e){if(t!=="dice.rolled")return;const n=D(e.raw_d20,0),a=D(e.total,0),s=D(e.bonus,0),i=g(e.action,"roll"),r=D(e.dc,0);return{notation:r>0?`${i} (DC ${r})`:i,rolls:n>0?[n]:[],total:a,modifier:s}}function tc(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function ec(t){const e=t.trim().toLowerCase();return e?e.startsWith("dice.")?"dice":e.startsWith("combat.")||e.includes(".attack")||e.includes(".damage")?"combat":e.includes("actor.")?"actor":e.includes("turn.")||e==="turn.started"||e==="phase.changed"?"turn":e.includes("join.")?"join":e.includes("memory")?"memory":e.includes("world.")?"world":e.includes("narration")?"story":"meta":"meta"}function nc(t,e,n,a){const s=n||e||g(a.actor_id,"")||g(a.actor_name,"");switch(t){case"turn.action.proposed":{const i=g(a.proposed_action,g(a.reply,""));return i?`${s||"actor"}: ${i}`:"Action proposed"}case"turn.action.resolved":{const i=g(a.reply,g(a.result,""));return i?`Resolved: ${i}`:"Action resolved"}case"narration.posted":return g(a.reply,g(a.content,g(a.text,"Narration")));case"dice.rolled":{const i=g(a.action,"roll"),r=D(a.total,0),u=D(a.dc,0),d=g(a.label,""),p=s||"actor",f=u>0?` vs DC ${u}`:"",l=d?` (${d})`:"";return`${p} ${i}: ${r}${f}${l}`}case"turn.started":return`Turn ${D(a.turn,1)} started`;case"phase.changed":return`Phase: ${g(a.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${g(a.name,E(a.actor)?g(a.actor.name,s||"unknown"):s||"unknown")}`;case"actor.claimed":return`${g(a.keeper_name,g(a.keeper,"keeper"))} claimed ${s||"actor"}`;case"actor.released":return`${g(a.keeper_name,g(a.keeper,"keeper"))} released ${s||"actor"}`;case"join.window.opened":return`Join window opened (turn ${D(a.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${D(a.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${s||g(a.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${s||g(a.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${g(a.reason_code,"unknown")}`;case"memory.signal":{const i=E(a.entity_refs)?a.entity_refs:{},r=g(i.requested_tier,""),u=g(i.effective_tier,""),d=Rs(i.guardrail_applied,!1),p=g(a.summary_en,g(a.summary_ko,"Memory signal"));if(!r&&!u)return p;const f=r&&u?`${r}->${u}`:u||r;return`${p} [${f}${d?" (guardrail)":""}]`}case"world.event":{if(g(a.event_type,"")==="canon.check"){const r=g(a.status,"unknown"),u=g(a.contract_id,"n/a");return`Canon ${r}: ${u}`}return g(a.description,g(a.summary,"World event"))}case"combat.attack":return g(a.summary,g(a.result,"Attack resolved"));case"combat.defense":return g(a.summary,g(a.result,"Defense resolved"));case"session.outcome":return g(a.summary,g(a.outcome,"Session ended"));default:{const i=tc(a);return i?`${t}: ${i}`:t}}}function ac(t,e){const n=E(t)?t:{},a=g(n.type,"event"),s=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",i=g(n.actor_name,"").trim()||e[s]||g(E(n.payload)?n.payload.actor_name:"",""),r=E(n.payload)?n.payload:{},u=g(n.ts,g(n.timestamp,new Date().toISOString())),d=g(n.phase,g(r.phase,"")),p=g(n.category,"");return{type:a,actor:i||s||g(r.actor_name,""),actor_id:s||g(r.actor_id,""),actor_name:i,seq:n.seq,room_id:g(n.room_id,""),phase:d||void 0,category:p||ec(a),visibility:g(n.visibility,g(r.visibility,"public")),event_id:g(n.event_id,""),content:nc(a,s,i,r),dice_roll:Zl(a,r),timestamp:u}}function sc(t,e,n){var et,ut;const a=g(t.room_id,"")||n||"default",s=E(t.state)?t.state:{},i=E(s.party)?s.party:{},r=E(s.actor_control)?s.actor_control:{},u=E(s.join_gate)?s.join_gate:{},d=E(s.contribution_ledger)?s.contribution_ledger:{},p=Object.entries(i).map(([I,W])=>{const $=E(W)?W:{},ne=dt($,"max_hp",void 0,10),Fe=dt($,"hp",void 0,ne),Dn=dt($,"max_mp",void 0,0),En=dt($,"mp",void 0,0),Pn=dt($,"level",void 0,1),v=dt($,"xp",void 0,0),T=Rs($.alive,Fe>0),M=r[I],V=typeof M=="string"?M:void 0,O=Ql($.role,I,V),nt=Vt($.generation),G=X($.joined_at,$.joinedAt,$.started_at,$.startedAt),U=X($.claimed_at,$.claimedAt,$.assigned_at,$.assignedAt,$.assigned_time),at=X($.last_seen,$.lastSeen,$.last_seen_at,$.lastSeenAt,$.last_active,$.lastActive),Ht=X($.scene,$.current_scene,$.currentScene,$.world_scene,$.scene_name,$.sceneName),Kt=X($.location,$.current_location,$.currentLocation,$.position,$.zone,$.area);return{id:I,name:g($.name,I),role:O,keeper:V,archetype:g($.archetype,""),persona:g($.persona,""),portrait:g($.portrait,"")||void 0,background:g($.background,"")||void 0,traits:je($.traits),skills:je($.skills),stats_raw:Xl($),status:T?"active":"dead",generation:nt,joined_at:G||void 0,claimed_at:U||void 0,last_seen:at||void 0,scene:Ht||void 0,location:Kt||void 0,inventory:je($.inventory),notes:je($.notes),relationships:Vl($.relationships),stats:{hp:Fe,max_hp:ne,mp:En,max_mp:Dn,level:Pn,xp:v,strength:dt($,"strength","str",10),dexterity:dt($,"dexterity","dex",10),constitution:dt($,"constitution","con",10),intelligence:dt($,"intelligence","int",10),wisdom:dt($,"wisdom","wis",10),charisma:dt($,"charisma","cha",10)}}}),f=p.filter(I=>I.status!=="dead"),l=Jl(t,e),c={phase_open:Rs(u.phase_open,!0),min_points:D(u.min_points,3),window:g(u.window,"round_boundary_only"),last_opened_turn:typeof u.last_opened_turn=="number"?u.last_opened_turn:null,last_closed_turn:typeof u.last_closed_turn=="number"?u.last_closed_turn:null},m=Object.entries(d).map(([I,W])=>{const $=E(W)?W:{};return{actor_id:I,score:D($.score,0),last_reason:g($.last_reason,"")||null,reasons:je($.reasons)}}),h=p.reduce((I,W)=>(I[W.id]=W.name,I),{}),y=e.map(I=>ac(I,h)),w=D(s.turn,1),C=g(s.phase,"round"),S=g(s.map,""),P=E(s.world)?s.world:{},A=S||g(P.ascii_map,g(P.map,"")),L=y.filter((I,W)=>{const $=e[W];if(!E($))return!1;const ne=E($.payload)?$.payload:{};return D(ne.turn,-1)===w}),tt=(L.length>0?L:y).slice(-12),bt=g(s.status,"active");return{session:{id:a,room:a,status:bt==="ended"?"ended":bt==="paused"?"paused":"active",round:w,actors:f,created_at:((et=y[0])==null?void 0:et.timestamp)??new Date().toISOString()},current_round:{round_number:w,phase:C,events:tt,timestamp:((ut=y[y.length-1])==null?void 0:ut.timestamp)??new Date().toISOString()},map:A||void 0,join_gate:c,contribution_ledger:m,outcome:l,party:f,story_log:y,history:[]}}async function ic(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await jt(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function oc(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,a]=await Promise.all([jt(`/api/v1/trpg/state${e}`),ic(t)]);return sc(n,a,t)}function rc(t){return qt("/api/v1/trpg/rounds/run",{room_id:t})}function lc(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function cc(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),qt("/api/v1/trpg/dice/roll",e)}function uc(t,e){const n=lc();return qt("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}function dc(t,e){var s;const n=(s=e.idempotencyKey)==null?void 0:s.trim(),a={room_id:t};return e.actor_id&&e.actor_id.trim()&&(a.actor_id=e.actor_id.trim()),e.name&&e.name.trim()&&(a.name=e.name.trim()),e.role&&(a.role=e.role),e.archetype&&e.archetype.trim()&&(a.archetype=e.archetype.trim()),e.persona&&e.persona.trim()&&(a.persona=e.persona.trim()),e.portrait&&e.portrait.trim()&&(a.portrait=e.portrait.trim()),e.background&&e.background.trim()&&(a.background=e.background.trim()),e.hp!=null&&(a.hp=e.hp),e.max_hp!=null&&(a.max_hp=e.max_hp),e.alive!=null&&(a.alive=e.alive),Array.isArray(e.traits)&&e.traits.length>0&&(a.traits=e.traits),Array.isArray(e.skills)&&e.skills.length>0&&(a.skills=e.skills),Array.isArray(e.inventory)&&e.inventory.length>0&&(a.inventory=e.inventory),e.stats&&Object.keys(e.stats).length>0&&(a.stats=e.stats),n&&(a.idempotency_key=n),qt("/api/v1/trpg/actors/spawn",a,n?{"Idempotency-Key":n}:void 0)}function pc(t,e,n){return qt("/api/v1/trpg/actors/claim",{room_id:t,actor_id:e,keeper:n})}async function vc(t,e,n){const a=await st("trpg.join.eligibility",{room_id:t,actor_id:e,...n?{keeper_name:n}:{}});return JSON.parse(a)}async function mc(t){const e=await st("trpg.mid_join.request",t);return JSON.parse(e)}async function cr(t,e){await st("masc_broadcast",{agent_name:t,message:e})}async function fc(t,e,n=1){await st("masc_add_task",{title:t,description:e,priority:n})}async function _c(t){return st("masc_join",{agent_name:t})}async function ur(t){await st("masc_leave",{agent_name:t})}async function gc(t){await st("masc_heartbeat",{agent_name:t})}async function hc(t=40){return(await st("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function $c(t,e=20){return st("masc_task_history",{task_id:t,limit:e})}async function yc(){return Cn("fetchDebates",async()=>{const t=await jt("/api/v1/council/debates?limit=100");return Array.isArray(t.debates)?t.debates.map(e=>{if(!E(e))return null;const n=g(e.id,"").trim(),a=g(e.topic,"").trim();return!n||!a?null:{id:n,topic:a,status:g(e.status,"open"),argument_count:D(e.argument_count,0),created_at:Le(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]})}async function bc(){return Cn("fetchCouncilSessions",async()=>{const t=await jt("/api/v1/council/sessions?limit=100");return Array.isArray(t.sessions)?t.sessions.map(e=>{if(!E(e))return null;const n=g(e.id,"").trim(),a=g(e.topic,"").trim();return!n||!a?null:{id:n,topic:a,initiator:g(e.initiator,"system"),votes:D(e.votes,0),quorum:D(e.quorum,0),state:g(e.state,"open"),created_at:Le(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]})}async function kc(t){const e=await st("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}async function xc(t){return Cn("fetchDebateStatus",async()=>{const e=encodeURIComponent(t),n=await jt(`/api/v1/council/debates/${e}/summary`);if(!E(n))return null;const a=g(n.id,"").trim();return a?{id:a,topic:g(n.topic,""),status:g(n.status,"open"),support_count:D(n.support_count,0),oppose_count:D(n.oppose_count,0),neutral_count:D(n.neutral_count,0),total_arguments:D(n.total_arguments,0),created_at:Le(n.created_at_iso??n.created_at),summary_text:g(n.summary_text,"")}:null})}function wc(t,e,n){return st("masc_keeper_msg",{name:t,message:e})}function Sc(t){const e=g(t,"").trim().toLowerCase();return e.startsWith("error")?"error":e==="running"||e==="completed"||e==="stopped"?e:"running"}function Ac(t){return E(t)?{iteration:Vt(t.iteration)??0,metric_before:D(t.metric_before,0),metric_after:D(t.metric_after,0),delta:D(t.delta,0),changes:g(t.changes,""),failed_attempts:g(t.failed_attempts,""),next_suggestion:g(t.next_suggestion,""),elapsed_ms:Vt(t.elapsed_ms)??0,cost_usd:typeof t.cost_usd=="number"&&Number.isFinite(t.cost_usd)?t.cost_usd:null}:null}function Tc(t){if(!E(t))return null;const e=g(t.loop_id,"").trim();if(!e)return null;const n=Array.isArray(t.history)?t.history.map(Ac).filter(a=>a!==null):[];return{loop_id:e,profile:g(t.profile,"custom"),status:Sc(t.status),current_iteration:Vt(t.iteration)??Vt(t.current_iteration)??0,max_iterations:Vt(t.max_iterations)??0,baseline_metric:D(t.baseline_metric,0),current_metric:D(t.current_metric,D(t.baseline_metric,0)),target:g(t.target,""),stagnation_streak:Vt(t.stagnation_streak)??0,stagnation_limit:Vt(t.stagnation_limit)??0,elapsed_seconds:D(t.elapsed_seconds,0),history:n}}function zi(t){return t.trim().toLowerCase().includes("no mdal loop running")}async function Nc(){try{const t=await st("masc_mdal_status",{}),e=JSON.parse(t),n=E(e)?g(e.error,"").trim():"";if(zi(n))return{state:"idle"};if(n)return{state:"error",message:n};const a=Tc(e);return a?{state:"ready",loop:a}:{state:"error",message:"Unexpected MDAL payload"}}catch(t){const e=t instanceof Error?t.message:"Unknown MDAL fetch error";return zi(e)?{state:"idle"}:{state:"error",message:e}}}async function Cc(){try{const t=await st("masc_goal_list",{});if(typeof t=="string"){const e=JSON.parse(t);return Array.isArray(e)?e:e.goals??[]}return Array.isArray(t)?t:t.goals??[]}catch{return[]}}const Ge=_(""),Mt=_({}),Z=_({}),Ls=_({}),Ds=_({}),Es=_({}),Ps=_({}),Ot=_({});function Y(t,e,n){t.value={...t.value,[e]:n}}function zt(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function z(t){return typeof t=="string"&&t.trim()!==""?t.trim():void 0}function gt(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function ke(t){return typeof t=="boolean"?t:void 0}function Is(t){return typeof t=="string"&&t.trim()!==""?t:typeof t!="number"||!Number.isFinite(t)||t<=0?null:new Date(t*1e3).toISOString()}function Ms(t){return Array.isArray(t)?t.map(e=>z(e)).filter(e=>!!e):[]}function Rc(t){var n;const e=(n=z(t))==null?void 0:n.toLowerCase();return e==="user"||e==="assistant"||e==="system"||e==="tool"?e:"other"}function Lc(t){switch(t){case"user":return"User";case"assistant":return"Keeper";case"system":return"System";case"tool":return"Tool";default:return"Event"}}function Ha(t,e){if(!Array.isArray(t))return[];const n=[];for(const a of t){if(!zt(a))continue;const s=z(a.name);if(!s)continue;const i=z(a[e]);e==="summary"?n.push({name:s,summary:i}):n.push({name:s,reason:i})}return n}function Dc(t){if(!zt(t))return null;const e=z(t.name);return e?{name:e,trigger:z(t.trigger),outcome:z(t.outcome),summary:z(t.summary),reason:z(t.reason)}:null}function Ec(t){const e=t.toLowerCase();return e.includes("graphql")?"graphql_error":e.includes("timeout")||e.includes("model")||e.includes("llm")||e.includes("api key")||e.includes("api_key")||e.includes("provider")?"llm_error":"unknown"}function Pc(t,e){return t==="offline"||t==="degraded"||t==="stale"?"Keeper is not in a healthy reply state. Probe or recover before relying on automation.":e==="quiet_hours"?"Lodge quiet hours are active. Direct messages still work, but scheduled social ticks may look asleep.":e==="min_gap"?"Keeper is inside its proactive cooldown window. Direct messages work now; autonomous check-ins will wait.":e==="never_started"?"Keeper metadata exists but no reply turn has been recorded yet.":"Keeper is reachable. Send a direct message for an immediate response."}function la(t){if(!zt(t))return null;const e=z(t.health_state),n=z(t.next_action_path),a=z(t.last_reply_status);return!e||!n||!a?null:{health_state:e,quiet_reason:z(t.quiet_reason)??null,next_action_path:n,last_reply_status:a,last_reply_at:Is(t.last_reply_at),last_reply_preview:z(t.last_reply_preview)??null,last_error:z(t.last_error)??null,next_eligible_at_s:gt(t.next_eligible_at_s)??null,recoverable:typeof t.recoverable=="boolean"?t.recoverable:void 0,summary:z(t.summary),keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function vi(t){return zt(t)?{hour:gt(t.hour),checked:gt(t.checked)??0,acted:gt(t.acted)??0,acted_names:Ms(t.acted_names),activity_report:z(t.activity_report),quiet_hours_overridden:ke(t.quiet_hours_overridden),skipped_reason:z(t.skipped_reason),acted_rows:Ha(t.acted_rows,"summary").map(e=>({name:e.name,summary:e.summary})),passed_rows:Ha(t.passed_rows,"reason").map(e=>({name:e.name,reason:e.reason})),skipped_rows:Ha(t.skipped_rows,"reason").map(e=>({name:e.name,reason:e.reason})),checkins:Array.isArray(t.checkins)?t.checkins.map(Dc).filter(e=>e!==null):[]}:null}function Ic(t){return zt(t)?{enabled:ke(t.enabled)??!1,interval_s:gt(t.interval_s)??0,quiet_start:gt(t.quiet_start),quiet_end:gt(t.quiet_end),quiet_active:ke(t.quiet_active),use_planner:ke(t.use_planner),delegate_llm:ke(t.delegate_llm),agent_count:gt(t.agent_count),agents:Ms(t.agents),last_tick_ago_s:gt(t.last_tick_ago_s)??null,last_tick_ago:z(t.last_tick_ago),total_ticks:gt(t.total_ticks),total_checkins:gt(t.total_checkins),last_skip_reason:z(t.last_skip_reason)??null,last_tick_result:vi(t.last_tick_result),active_self_heartbeats:Ms(t.active_self_heartbeats)}:null}function Mc(t){return zt(t)?{status:t.status,diagnostic:la(t.diagnostic)}:null}function Oc(t){return zt(t)?{recovered:ke(t.recovered)??!1,skipped_reason:z(t.skipped_reason)??null,before:la(t.before),after:la(t.after),down:t.down,up:t.up}:null}function Fc(t,e){var S,P;if(!(t!=null&&t.name))return null;const n=z((S=t.agent)==null?void 0:S.status)??z(t.status)??"unknown",a=z((P=t.agent)==null?void 0:P.error)??null,s=t.presence_keepalive??!0,i=t.keepalive_running??!1,r=t.turn_count??0,u=t.last_turn_ago_s??null,d=t.proactive_enabled??!1,p=t.proactive_cooldown_sec??0,f=t.last_proactive_ago_s??null,l=d&&f!=null?Math.max(0,p-f):null,c=r<=0||u==null?"never":u>900?"stale":"fresh",m=typeof t.last_heartbeat=="string"&&t.last_heartbeat.trim()?t.last_heartbeat:null,h=a??(s&&!i?"keeper keepalive is not running":null),y=n==="offline"||n==="inactive"?"offline":h?"degraded":c==="stale"?"stale":c==="never"?"idle":"healthy",w=h?Ec(h):e!=null&&e.quiet_active&&c!=="fresh"?"quiet_hours":s&&!i?"disabled":r<=0?"never_started":l!=null&&l>0?"min_gap":c==="fresh"||c==="stale"?"no_recent_activity":"unknown",C=y==="offline"||y==="degraded"||y==="stale"?"recover":w==="quiet_hours"?"manual_lodge_poke":w==="unknown"?"probe":"direct_message";return{health_state:y,quiet_reason:w,next_action_path:C,last_reply_status:c,last_reply_at:m,last_reply_preview:null,last_error:h,next_eligible_at_s:l!=null&&l>0?l:null,recoverable:C==="recover",summary:Pc(y,w),keepalive_running:i}}function jc(t,e){if(!zt(t))return null;const n=Rc(t.role),a=z(t.content)??z(t.preview);if(!a)return null;const s=Is(t.ts_unix)??Is(t.timestamp);return{id:`${n}-${s??"entry"}-${e}`,role:n,label:Lc(n),text:a,timestamp:s,delivery:"history"}}function qc(t,e,n){const a=zt(n)?n:null,s=Array.isArray(a==null?void 0:a.history_tail)?a.history_tail.map((i,r)=>jc(i,r)).filter(i=>i!==null):[];return{name:t,diagnostic:la(a==null?void 0:a.diagnostic),history:s,rawText:e,rawStatus:n,loadedAt:new Date().toISOString()}}function Hi(t,e){const n=Z.value[t]??[];Z.value={...Z.value,[t]:[...n,e].slice(-50)}}function zc(t,e){return t.role!==e.role||t.text!==e.text?!1:t.timestamp&&e.timestamp?t.timestamp===e.timestamp:!0}function Hc(t,e){const a=(Z.value[t]??[]).filter(s=>s.delivery!=="history"&&!e.some(i=>zc(s,i)));Z.value={...Z.value,[t]:[...e,...a].slice(-50)}}function Ma(t,e){Mt.value={...Mt.value,[t]:e},Hc(t,e.history)}function Ki(t,e){const n=Mt.value[t];if(!n)return;const a=n.diagnostic??{health_state:"idle",next_action_path:"direct_message",last_reply_status:"unknown"};Ma(t,{...n,diagnostic:{...a,...e}})}async function mi(){De();try{await pe()}catch(t){console.warn("[keeper-runtime] dashboard refresh failed",t)}}function Vn(t){Ge.value=t.trim()}async function dr(t,e=!1){const n=t.trim();if(!n)return null;if(!e&&Mt.value[n])return Mt.value[n];Y(Ls,n,!0),Y(Ot,n,null);try{const a=await st("masc_keeper_status",{name:n,fast:!1,include_context:!0,include_metrics_overview:!0,include_memory_bank:!1,include_history_tail:!0,include_compaction_history:!1,tail_turns:5,tail_messages:10});let s=null;try{s=JSON.parse(a)}catch{s=null}const i=qc(n,a,s);return Ma(n,i),i}catch(a){const s=a instanceof Error?a.message:`Failed to inspect ${n}`;return Y(Ot,n,s),null}finally{Y(Ls,n,!1)}}async function Kc(t,e){const n=t.trim(),a=e.trim();if(!n||!a)return;const s=`local-${Date.now()}`;Hi(n,{id:s,role:"user",label:"You",text:a,timestamp:new Date().toISOString(),delivery:"sending"}),Y(Ds,n,!0),Y(Ot,n,null);try{const i=await wc(n,a);Z.value={...Z.value,[n]:(Z.value[n]??[]).map(r=>r.id===s?{...r,delivery:"delivered"}:r)},Hi(n,{id:`reply-${Date.now()}`,role:"assistant",label:n,text:i.trim()||"(empty reply)",timestamp:new Date().toISOString(),delivery:"delivered"}),Ki(n,{last_reply_status:"delivered",last_reply_at:new Date().toISOString(),last_reply_preview:(i.trim()||"(empty reply)").slice(0,200),last_error:null}),await mi()}catch(i){const r=i instanceof Error?i.message:`Failed to send direct message to ${n}`;throw Z.value={...Z.value,[n]:(Z.value[n]??[]).map(u=>u.id===s?{...u,delivery:"error",error:r}:u)},Ki(n,{last_reply_status:"error",last_error:r}),Y(Ot,n,r),i}finally{Y(Ds,n,!1)}}async function Uc(t,e){const n=t.trim();if(!n)return null;Y(Es,n,!0),Y(Ot,n,null);try{const a=await Rn({actor:e,action_type:"keeper_probe",target_type:"keeper",target_id:n,payload:{}}),s=Mc(a.result),i=(s==null?void 0:s.diagnostic)??null;if(i){const r=Mt.value[n];Ma(n,{name:n,diagnostic:i,history:(r==null?void 0:r.history)??Z.value[n]??[],rawText:(r==null?void 0:r.rawText)??"",rawStatus:a.result,loadedAt:new Date().toISOString()})}return await mi(),i}catch(a){const s=a instanceof Error?a.message:`Failed to probe ${n}`;throw Y(Ot,n,s),a}finally{Y(Es,n,!1)}}async function Bc(t,e){const n=t.trim();if(!n)return null;Y(Ps,n,!0),Y(Ot,n,null);try{const a=await Rn({actor:e,action_type:"keeper_recover",target_type:"keeper",target_id:n,payload:{}}),s=Oc(a.result),i=(s==null?void 0:s.after)??null;if(i){const r=Mt.value[n];Ma(n,{name:n,diagnostic:i,history:(r==null?void 0:r.history)??Z.value[n]??[],rawText:(r==null?void 0:r.rawText)??"",rawStatus:a.result,loadedAt:new Date().toISOString()})}return await mi(),i}catch(a){const s=a instanceof Error?a.message:`Failed to recover ${n}`;throw Y(Ot,n,s),a}finally{Y(Ps,n,!1)}}const te=_([]),Lt=_([]),ue=_([]),$t=_([]),ee=_(null),Ue=_(null),Os=_(new Map),Ft=_([]),_n=_("hot"),ie=_(!0),pr=_(null),Et=_(""),gn=_([]),xe=_(!1),ht=_(new Map),Qn=_("unknown"),Fs=_(null),js=_(!1),hn=_(!1),qs=_(!1),we=_(!1),Wc=_(null),zs=_(null),vr=_(null),mr=_(null),Gc=ct(()=>te.value.filter(t=>t.status==="active"||t.status==="idle")),fr=ct(()=>{const t=Lt.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}});function Jc(t){var i;const e=((i=t.status)==null?void 0:i.toLowerCase())??"";if(e==="offline"||e==="inactive")return"offline";const n=t.metrics_series;if(!n||n.length===0)return"idle";const a=n[n.length-1];if(!a)return"idle";if(a.is_handoff)return"handoff-imminent";if(a.is_compaction)return"compacting";const s=a.context_ratio;return s>.85?"handoff-imminent":s>.7?"preparing":s>.5?"compacting":"active"}const _r=ct(()=>{const t=new Map;for(const e of $t.value)t.set(e.name,Jc(e));return t}),Vc=12e4;function Qc(t,e){const n=e.get(t.name);if(n!=null)return n;const a=t.last_heartbeat?Date.parse(t.last_heartbeat):Number.NaN;if(!Number.isNaN(a))return a;const s=[t.last_turn_ago_s,t.last_proactive_ago_s,t.last_handoff_ago_s,t.last_compaction_ago_s].find(i=>typeof i=="number"&&Number.isFinite(i)&&i>=0);return typeof s=="number"?Date.now()-s*1e3:null}const gr=ct(()=>{const t=Date.now(),e=new Set,n=Os.value;for(const a of $t.value){const s=Qc(a,n);s!=null&&t-s>Vc&&e.add(a.name)}return e}),ca={},Yc=5e3;function De(){delete ca.compact,delete ca.full}function vt(t){return typeof t=="object"&&t!==null}function k(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function N(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Je(t){if(!Array.isArray(t))return;const e=t.filter(n=>typeof n=="string"&&n.trim()!=="");return e.length>0?e:void 0}function Xc(t){if(typeof t=="string"&&t.trim()!=="")return t;if(!(typeof t!="number"||!Number.isFinite(t)||t<=0))return new Date(t*1e3).toISOString()}function hr(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="idle"||e==="inactive"||e==="offline"?e:e==="busy"||e==="in_progress"||e==="claimed"?"active":"offline"}function Zc(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function tu(t){if(!vt(t))return null;const e=k(t.name);return e?{name:e,status:hr(t.status),current_task:k(t.current_task)??null,last_seen:k(t.last_seen),emoji:k(t.emoji),koreanName:k(t.koreanName)??k(t.korean_name),model:k(t.model),traits:Je(t.traits),interests:Je(t.interests),activityLevel:N(t.activityLevel)??N(t.activity_level),primaryValue:k(t.primaryValue)??k(t.primary_value)}:null}function eu(t){if(!vt(t))return null;const e=k(t.id),n=k(t.title);return!e||!n?null:{id:e,title:n,status:Zc(t.status),priority:N(t.priority),assignee:k(t.assignee),description:k(t.description),created_at:k(t.created_at),updated_at:k(t.updated_at)}}function nu(t){if(!vt(t))return null;const e=k(t.from)??k(t.from_agent)??"system",n=k(t.content)??"",a=k(t.timestamp)??new Date().toISOString();return{id:k(t.id),seq:N(t.seq),from:e,content:n,timestamp:a,type:k(t.type)}}function au(t){return Array.isArray(t)?t.map(e=>{if(!vt(e))return null;const n=N(e.ts_unix);if(n==null)return null;const a=vt(e.handoff)?e.handoff:null;return{ts:n,context_ratio:N(e.context_ratio)??0,context_tokens:N(e.context_tokens)??0,context_max:N(e.context_max)??0,latency_ms:N(e.latency_ms)??0,generation:N(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:a!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:N(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:N(e.cost_usd)??0,handoff_to_model:a&&typeof a.to_model=="string"?a.to_model:null,handoff_new_generation:a?N(a.new_generation)??null:null}}).filter(e=>e!==null):[]}function Ui(t){if(!vt(t))return null;const e=k(t.health_state),n=k(t.next_action_path),a=k(t.last_reply_status);return!e||!n||!a?null:{health_state:e,quiet_reason:k(t.quiet_reason)??null,next_action_path:n,last_reply_status:a,last_reply_at:Xc(t.last_reply_at)??k(t.last_reply_at)??null,last_reply_preview:k(t.last_reply_preview)??null,last_error:k(t.last_error)??null,next_eligible_at_s:N(t.next_eligible_at_s)??null,recoverable:typeof t.recoverable=="boolean"?t.recoverable:void 0,summary:k(t.summary),keepalive_running:typeof t.keepalive_running=="boolean"?t.keepalive_running:void 0}}function su(t,e){return(Array.isArray(t)?t:vt(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(a=>{if(!vt(a))return null;const s=vt(a.agent)?a.agent:null,i=vt(a.context)?a.context:null,r=vt(a.metrics_window)?a.metrics_window:void 0,u=k(a.name);if(!u)return null;const d=N(a.context_ratio)??N(i==null?void 0:i.context_ratio),p=k(a.status)??k(s==null?void 0:s.status)??"offline",f=hr(p),l=k(a.model)??k(a.active_model)??k(a.primary_model),c=Je(a.skill_secondary),m=i?{source:k(i.source),context_ratio:N(i.context_ratio),context_tokens:N(i.context_tokens),context_max:N(i.context_max),message_count:N(i.message_count),has_checkpoint:typeof i.has_checkpoint=="boolean"?i.has_checkpoint:void 0}:void 0,h=s?{name:k(s.name),exists:typeof s.exists=="boolean"?s.exists:void 0,error:k(s.error),status:k(s.status),current_task:k(s.current_task)??null,last_seen:k(s.last_seen),last_seen_ago_s:N(s.last_seen_ago_s),is_zombie:typeof s.is_zombie=="boolean"?s.is_zombie:void 0}:void 0,y=au(a.metrics_series),w={name:u,emoji:k(a.emoji),koreanName:k(a.koreanName)??k(a.korean_name),agent_name:k(a.agent_name),trace_id:k(a.trace_id),model:l,primary_model:k(a.primary_model),active_model:k(a.active_model),next_model_hint:k(a.next_model_hint)??null,status:f,presence_keepalive:typeof a.presence_keepalive=="boolean"?a.presence_keepalive:void 0,presence_keepalive_sec:N(a.presence_keepalive_sec),keepalive_running:typeof a.keepalive_running=="boolean"?a.keepalive_running:void 0,proactive_enabled:typeof a.proactive_enabled=="boolean"?a.proactive_enabled:void 0,proactive_idle_sec:N(a.proactive_idle_sec),proactive_cooldown_sec:N(a.proactive_cooldown_sec),last_heartbeat:k(a.last_heartbeat)??k(s==null?void 0:s.last_seen),generation:N(a.generation),turn_count:N(a.turn_count)??N(a.total_turns),keeper_age_s:N(a.keeper_age_s),last_turn_ago_s:N(a.last_turn_ago_s),last_handoff_ago_s:N(a.last_handoff_ago_s),last_compaction_ago_s:N(a.last_compaction_ago_s),last_proactive_ago_s:N(a.last_proactive_ago_s),context_ratio:d,context_tokens:N(a.context_tokens)??N(i==null?void 0:i.context_tokens),context_max:N(a.context_max)??N(i==null?void 0:i.context_max),context_source:k(a.context_source)??k(i==null?void 0:i.source),context:m,traits:Je(a.traits),interests:Je(a.interests),primaryValue:k(a.primaryValue)??k(a.primary_value),activityLevel:N(a.activityLevel)??N(a.activity_level),memory_recent_note:k(a.memory_recent_note)??null,conversation_tail_count:N(a.conversation_tail_count),k2k_count:N(a.k2k_count),handoff_count_total:N(a.handoff_count_total)??N(a.trace_history_count),compaction_count:N(a.compaction_count),last_compaction_saved_tokens:N(a.last_compaction_saved_tokens),diagnostic:Ui(a.diagnostic),skill_primary:k(a.skill_primary)??null,skill_secondary:c,skill_reason:k(a.skill_reason)??null,metrics_series:y.length>0?y:void 0,metrics_window:r,agent:h};return w.diagnostic=Ui(a.diagnostic)??Fc(w,(e==null?void 0:e.lodge)??null),w}).filter(a=>a!==null)}function iu(t){return vt(t)?{...t,lodge:Ic(t.lodge)??void 0}:null}async function pe(t="full"){var a,s,i;const e=Date.now(),n=ca[t];if(!(n&&e-n.time<Yc)){js.value=!0;try{const r=await Ml(t);ca[t]={data:r,time:e},te.value=(Array.isArray((a=r.agents)==null?void 0:a.agents)?r.agents.agents:[]).map(tu).filter(d=>d!==null),Lt.value=(Array.isArray((s=r.tasks)==null?void 0:s.tasks)?r.tasks.tasks:[]).map(eu).filter(d=>d!==null),ue.value=(Array.isArray((i=r.messages)==null?void 0:i.messages)?r.messages.messages:[]).map(nu).filter(d=>d!==null);const u=iu(r.status);ee.value=u,$t.value=su(r.keepers,u),Ue.value=r.perpetual??null,Wc.value=new Date().toISOString()}catch(r){console.error("Dashboard fetch error:",r)}finally{js.value=!1}}}async function Ct(){hn.value=!0;try{const t=await Ul(_n.value,{excludeSystem:ie.value});Ft.value=t.posts??[],zs.value=new Date().toISOString()}catch(t){console.error("Board fetch error:",t)}finally{hn.value=!1}}async function Pt(){var t;qs.value=!0;try{const e=Et.value||((t=ee.value)==null?void 0:t.room)||"default";Et.value||(Et.value=e);const n=await oc(e);pr.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{qs.value=!1}}async function Ve(){xe.value=!0;try{const t=await Cc();gn.value=Array.isArray(t)?t:[],vr.value=new Date().toISOString()}catch(t){console.error("Goals fetch error:",t)}finally{xe.value=!1}}async function Qe(){const t=++Ba;we.value=!0;try{const e=await Nc();if(t!==Ba)return;if(e.state==="error"){Qn.value="error",Fs.value=e.message;return}if(mr.value=new Date().toISOString(),Fs.value=null,e.state==="idle"){Qn.value="idle";const i=new Map(ht.value);for(const[r,u]of i.entries())u.status==="running"&&i.set(r,{...u,status:"stopped"});ht.value=i;return}const n=e.loop;Qn.value="ready";const a=new Map(ht.value),s=a.get(n.loop_id);a.set(n.loop_id,{...s??{},...n,history:n.history.length>0?n.history:(s==null?void 0:s.history)??[]}),ht.value=a}catch(e){console.error("MDAL fetch error:",e)}finally{t===Ba&&(we.value=!1)}}let Ka=null,Ua=null,Ba=0;function ou(){return tr.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map(Os.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),Os.value=n}if(De(),Ka||(Ka=setTimeout(()=>{pe(),Ka=null},500)),(e.type==="board_post"||e.type==="masc/board_post"||e.type==="board_comment"||e.type==="masc/board_comment")&&(Ua||(Ua=setTimeout(()=>{Ct(),Ua=null},500))),(e.type==="keeper_handoff"||e.type==="keeper_compaction"||e.type==="keeper_guardrail")&&De(),e.type==="mdal_started"&&e.loop_id){const n=new Map(ht.value);n.set(e.loop_id,{...n.get(e.loop_id)??{},loop_id:e.loop_id,profile:e.profile??"custom",status:"running",current_iteration:e.iteration??0,max_iterations:0,baseline_metric:e.baseline??0,current_metric:e.baseline??0,target:e.target??"",stagnation_streak:0,stagnation_limit:0,elapsed_seconds:0,history:[]}),ht.value=n}if(e.type==="mdal_iteration"&&e.loop_id){const n=new Map(ht.value),a=e.metric_before??e.metric_after??0,s=e.metric_after??a,i=n.get(e.loop_id)??{loop_id:e.loop_id,profile:e.profile??"unknown",status:"running",current_iteration:e.iteration??0,max_iterations:0,baseline_metric:a,current_metric:s,target:e.target??"",stagnation_streak:0,stagnation_limit:0,elapsed_seconds:0,history:[]},r={iteration:e.iteration??0,metric_before:a,metric_after:s,delta:e.delta??0,changes:"",failed_attempts:"",next_suggestion:"",elapsed_ms:0,cost_usd:null};n.set(e.loop_id,{...i,current_iteration:e.iteration??i.current_iteration,current_metric:s,history:[r,...i.history]}),ht.value=n}if((e.type==="mdal_completed"||e.type==="mdal_stopped")&&e.loop_id){const n=new Map(ht.value),a=n.get(e.loop_id)??{loop_id:e.loop_id,profile:e.profile??"unknown",status:"running",current_iteration:e.iteration??0,max_iterations:0,baseline_metric:e.baseline??e.metric_before??e.metric_after??0,current_metric:e.metric_after??e.metric_before??e.baseline??0,target:e.target??"",stagnation_streak:0,stagnation_limit:0,elapsed_seconds:0,history:[]};n.set(e.loop_id,{...a,current_iteration:e.iteration??a.current_iteration,current_metric:e.metric_after??a.current_metric,status:e.type==="mdal_completed"?"completed":"stopped"}),ht.value=n}}})}let Ye=null;function ru(){Ye||(Ye=setInterval(()=>{De(),pe()},1e4))}function lu(){Ye&&(clearInterval(Ye),Ye=null)}function x({title:t,class:e,children:n}){return o`
    <div class="card ${e??""}">
      ${t?o`<div class="card-title">${t}</div>`:null}
      ${n}
    </div>
  `}function yt({status:t,label:e}){return o`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??t}
    </span>
  `}function cu(t){const e=Date.now(),n=typeof t=="number"?t<1e12?t*1e3:t:new Date(t).getTime(),a=Math.floor((e-n)/1e3);if(a<60)return`${a}s ago`;const s=Math.floor(a/60);if(s<60)return`${s}m ago`;const i=Math.floor(s/60);return i<24?`${i}h ago`:`${Math.floor(i/24)}d ago`}function q({timestamp:t}){const e=cu(t),n=typeof t=="string"?t:new Date(t<1e12?t*1e3:t).toISOString();return o`<span class="time-ago" title=${n}>${e}</span>`}function ae(t){return(t??"").trim().toLowerCase()}function it(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function Yn(t,e=88){const n=t.replace(/\s+/g," ").trim();return n&&(n.length>e?`${n.slice(0,e-3)}...`:n)}function On(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function qe(t){return t.last_heartbeat??On(t.last_turn_ago_s)??On(t.last_proactive_ago_s)??On(t.last_handoff_ago_s)??On(t.last_compaction_ago_s)}function uu(t){const e=t.title.trim();return e||Yn(t.content)}function du(t){const e=t.generation??"?",n=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return t.last_heartbeat?`Heartbeat gen=${e} ctx=${n}`:`Keeper snapshot gen=${e} ctx=${n}`}function $n(t,e,n,a,s={}){var P;const i=ae(t),r=e.filter(A=>ae(A.assignee)===i&&(A.status==="claimed"||A.status==="in_progress")).length,u=n.filter(A=>ae(A.from)===i).sort((A,L)=>it(L.timestamp)-it(A.timestamp))[0],d=a.filter(A=>ae(A.agent)===i||ae(A.author)===i).sort((A,L)=>it(L.timestamp)-it(A.timestamp))[0],p=(s.boardPosts??[]).filter(A=>ae(A.author)===i).sort((A,L)=>it(L.updated_at||L.created_at)-it(A.updated_at||A.created_at))[0],f=(s.keepers??[]).filter(A=>ae(A.name)===i&&qe(A)!==null).sort((A,L)=>it(qe(L)??0)-it(qe(A)??0))[0],l=u?it(u.timestamp):0,c=d?it(d.timestamp):0,m=p?it(p.updated_at||p.created_at):0,h=f?it(qe(f)??0):0,y=s.lastSeen?it(s.lastSeen):0,w=((P=s.currentTask)==null?void 0:P.trim())||(r>0?`${r} claimed tasks`:null);if(l===0&&c===0&&m===0&&h===0&&y===0)return{activeAssignedCount:r,lastActivityAt:null,lastActivityText:w};const S=[u?{timestamp:u.timestamp,ts:l,text:Yn(u.content)}:null,p?{timestamp:p.updated_at||p.created_at,ts:m,text:`Post: ${Yn(uu(p))}`}:null,f?{timestamp:qe(f),ts:h,text:du(f)}:null,d?{timestamp:new Date(d.timestamp).toISOString(),ts:c,text:Yn(d.text)}:null].filter(A=>A!==null).sort((A,L)=>L.ts-A.ts)[0];return S&&S.ts>=y?{activeAssignedCount:r,lastActivityAt:S.timestamp,lastActivityText:S.text}:{activeAssignedCount:r,lastActivityAt:s.lastSeen??null,lastActivityText:w??"Presence heartbeat"}}let pu=0;const oe=_([]);function b(t,e="success",n=4e3){const a=++pu;oe.value=[...oe.value,{id:a,message:t,type:e}],setTimeout(()=>{oe.value=oe.value.filter(s=>s.id!==a)},n)}function vu(t){oe.value=oe.value.filter(e=>e.id!==t)}function mu(){const t=oe.value;return t.length===0?null:o`
    <div class="toast-container">
      ${t.map(e=>o`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>vu(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}function fu(t){switch(t){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function _u(t){switch(t){case"manual_lodge_poke":return"Poke Lodge";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function gu(t){switch(t.delivery){case"sending":return"sending";case"timeout":return"timeout";case"error":return"error";case"delivered":return"delivered";default:return t.role}}function Bi(t){return t.delivery==="error"||t.delivery==="timeout"?"bad":t.delivery==="sending"?"warn":t.role==="assistant"?"assistant":t.role==="user"?"user":"warn"}function $r(t){if(!t)return null;const e=new Date(t);return Number.isNaN(e.getTime())?null:e.toLocaleTimeString()}function hu(t){return typeof t!="number"||!Number.isFinite(t)||t<=0?null:t<60?`${Math.round(t)}s`:`${Math.ceil(t/60)}m`}function yr(t){if(!t)return null;const e=Mt.value[t.name];return(e==null?void 0:e.diagnostic)??t.diagnostic??null}function br({keeper:t,showRawStatus:e=!1}){if(Rt(()=>{t!=null&&t.name&&dr(t.name)},[t==null?void 0:t.name]),!t)return o`<div class="control-status-copy">Select a keeper to inspect direct reply state.</div>`;const n=Mt.value[t.name],a=yr(t),s=Ls.value[t.name];return o`
    <div class="control-result-box">
      <div class="control-inline-meta">
        <span class="pill">${(a==null?void 0:a.health_state)??"unknown"}</span>
        <span class="pill">${fu(a==null?void 0:a.quiet_reason)}</span>
        <span class="pill">next ${_u((a==null?void 0:a.next_action_path)??"direct_message")}</span>
        ${s?o`<span class="pill">refreshing</span>`:null}
      </div>
      <div class="control-status-copy">
        ${(a==null?void 0:a.summary)??"Keeper diagnostic summary is not available yet. Probe or open the detail overlay to inspect current runtime state."}
      </div>
      <div class="control-status-copy">
        Reply: ${(a==null?void 0:a.last_reply_status)??"unknown"}
        ${a!=null&&a.last_reply_at?o` · ${$r(a.last_reply_at)}`:null}
        ${a!=null&&a.next_eligible_at_s?o` · next eligible ${hu(a.next_eligible_at_s)}`:null}
      </div>
      ${a!=null&&a.last_error?o`<div class="control-status-copy control-error-copy">${a.last_error}</div>`:null}
      ${e?o`<pre class="keeper-status-console">${(n==null?void 0:n.rawText)??"No keeper status loaded yet."}</pre>`:null}
    </div>
  `}function kr({keeperName:t,placeholder:e}){const[n,a]=Oo("");Rt(()=>{t&&dr(t)},[t]);const s=Z.value[t]??[],i=Ds.value[t]??!1,r=Ot.value[t],u=async()=>{const d=n.trim();if(!(!t||!d)){a("");try{await Kc(t,d)}catch(p){const f=p instanceof Error?p.message:`Failed to message ${t}`;b(f,"error")}}};return o`
    <div class="keeper-conversation-shell">
      <div class="keeper-conversation-list">
        ${s.length===0?o`<div class="control-status-copy">No direct keeper conversation yet.</div>`:s.map(d=>o`
              <div class="keeper-conversation-item" key=${d.id}>
                <div class="keeper-conversation-meta">
                  <span class=${`keeper-role-chip ${Bi(d)}`}>${d.label}</span>
                  <span class=${`keeper-role-chip ${Bi(d)}`}>${gu(d)}</span>
                  ${d.timestamp?o`<span class="keeper-conversation-time">${$r(d.timestamp)}</span>`:null}
                </div>
                <div class="keeper-conversation-text">${d.text}</div>
                ${d.error?o`<div class="keeper-conversation-error">${d.error}</div>`:null}
              </div>
            `)}
      </div>
      <div class="keeper-conversation-compose">
        <textarea
          class="control-textarea"
          placeholder=${e}
          value=${n}
          onInput=${d=>{a(d.target.value)}}
          disabled=${i||!t}
        ></textarea>
        <div class="control-actions">
          <button
            class="control-btn"
            onClick=${()=>{u()}}
            disabled=${i||n.trim()===""||!t}
          >
            ${i?"Waiting...":"Send Direct Message"}
          </button>
        </div>
        ${r?o`<div class="control-status-copy control-error-copy">${r}</div>`:null}
      </div>
    </div>
  `}function xr({actor:t,keeper:e,onPokeLodge:n}){if(!e)return null;const a=yr(e),s=Es.value[e.name]??!1,i=Ps.value[e.name]??!1,r=(a==null?void 0:a.next_action_path)??"direct_message";return o`
    <div class="control-actions">
      <button
        class=${`control-btn ghost ${r==="probe"?"is-active":""}`}
        onClick=${()=>{Uc(e.name,t).catch(u=>{const d=u instanceof Error?u.message:`Failed to probe ${e.name}`;b(d,"error")})}}
        disabled=${s||!t.trim()}
      >
        ${s?"Probing...":"Probe"}
      </button>
      <button
        class=${`control-btn secondary ${r==="recover"?"is-active":""}`}
        onClick=${()=>{Bc(e.name,t).catch(u=>{const d=u instanceof Error?u.message:`Failed to recover ${e.name}`;b(d,"error")})}}
        disabled=${i||!(a!=null&&a.recoverable)||!t.trim()}
      >
        ${i?"Recovering...":"Recover"}
      </button>
      <button
        class=${`control-btn ghost ${r==="manual_lodge_poke"?"is-active":""}`}
        onClick=${n}
      >
        Poke Lodge
      </button>
    </div>
  `}const fi=_(null);function ua(t){fi.value=t,Vn(t.name)}function Wi(){fi.value=null}const he=[{level:"L1_Reactive",label:"L1 Reactive",color:"#6b7280"},{level:"L2_Suggestive",label:"L2 Suggestive",color:"#3b82f6"},{level:"L3_Guided",label:"L3 Guided",color:"#f59e0b"},{level:"L4_Autonomous",label:"L4 Autonomous",color:"#f97316"},{level:"L5_Independent",label:"L5 Independent",color:"#ef4444"}];function $u(t){if(!t)return 0;const e=he.findIndex(n=>n.level===t);return e>=0?e:0}function yu({keeper:t}){const e=$u(t.autonomy_level),n=he[e]??he[0];if(!n)return null;const a=(e+1)/he.length*100;return o`
    <div class="keeper-signal-list">
      <div style="margin-bottom:8px;">
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:4px;">
          <span style="font-size:13px; font-weight:600; color:${n.color};">${n.label}</span>
          <span style="font-size:11px; color:#888;">${e+1} / ${he.length}</span>
        </div>
        <div style="width:100%; height:6px; background:#1a1a2e; border-radius:3px; overflow:hidden;">
          <div style="width:${a}%; height:100%; background:${n.color}; border-radius:3px; transition:width 0.3s;"></div>
        </div>
        <div style="display:flex; justify-content:space-between; margin-top:2px;">
          ${he.map((s,i)=>o`
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
            <strong><${q} timestamp=${t.last_autonomous_action_at} /></strong>
          </div>`:null}
      ${t.active_goal_ids&&t.active_goal_ids.length>0?o`<div class="keeper-signal-row">
            <span>Active goals</span>
            <strong>${t.active_goal_ids.length}</strong>
          </div>`:null}
    </div>
  `}function Xn(t){return t?t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}K`:String(t):"—"}function bu({keeper:t}){const e=t.metrics_series??[],n=e[e.length-1],a=(n==null?void 0:n.cost_usd)!=null?`$${n.cost_usd.toFixed(4)}`:"—",s=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return o`
    <div class="keeper-kpis">
      ${s.map(i=>o`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${i.label}</div>
          <div class="keeper-kpi-value">${i.value}</div>
          ${i.hint?o`<div class="keeper-kpi-hint">${i.hint}</div>`:null}
        </div>
      `)}
      <div class="kpi-tile">
        <div class="kpi-value">${Xn(t.context_tokens)}</div>
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
  `}function ku({keeper:t}){var f,l;const e=t.metrics_series??[];if(e.length<2){const c=(((f=t.context)==null?void 0:f.context_ratio)??0)*100,m=c>85?"#ef4444":c>70?"#f59e0b":"#22c55e";return o`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${c.toFixed(1)}%;background:${m}"></div>
        </div>
        <span class="chart-pct">${c.toFixed(1)}%</span>
      </div>`}const n=200,a=60,s=2,i=e.length,r=e.map((c,m)=>{const h=s+m/(i-1)*(n-2*s),y=a-s-(c.context_ratio??0)*(a-2*s);return{x:h,y,p:c}}),u=r.map(({x:c,y:m})=>`${c.toFixed(1)},${m.toFixed(1)}`).join(" "),d=(((l=e[e.length-1])==null?void 0:l.context_ratio)??0)*100,p=d>85?"#ef4444":d>70?"#f59e0b":"#22c55e";return o`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${a}" width="${n}" height="${a}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${s}" y1="${(a-s-.5*(a-2*s)).toFixed(1)}" x2="${n-s}" y2="${(a-s-.5*(a-2*s)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${s}" y1="${(a-s-.7*(a-2*s)).toFixed(1)}" x2="${n-s}" y2="${(a-s-.7*(a-2*s)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${s}" y1="${(a-s-.85*(a-2*s)).toFixed(1)}" x2="${n-s}" y2="${(a-s-.85*(a-2*s)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${r.filter(({p:c})=>c.is_handoff).map(({x:c})=>o`
          <line x1="${c.toFixed(1)}" y1="${s}" x2="${c.toFixed(1)}" y2="${a-s}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${u}" fill="none" stroke="${p}" stroke-width="1.5"/>
        ${r.filter(({p:c})=>c.is_compaction).map(({x:c,y:m})=>o`
          <circle cx="${c.toFixed(1)}" cy="${m.toFixed(1)}" r="2.5" fill="#a855f7"/>
        `)}
      </svg>
      <span class="chart-pct">${d.toFixed(1)}%</span>
    </div>`}const Wa=_("");function xu({keeper:t}){var s,i,r,u;const e=Wa.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji??"-"},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((s=t.traits)==null?void 0:s.join(", "))||"-"},{title:"Interests",key:"interests",value:((i=t.interests)==null?void 0:i.join(", "))||"-"}],a=e?n.filter(d=>d.title.toLowerCase().includes(e)||d.key.includes(e)||d.value.toLowerCase().includes(e)):n;return o`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${Wa.value}
        onInput=${d=>{Wa.value=d.target.value}}
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
      ${t.context_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Tokens</span><span style="flex:1; text-align:right; color:#ccc;">${Xn(t.context_tokens)}</span></div>`:""}
      ${t.context_max!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Max</span><span style="flex:1; text-align:right; color:#ccc;">${Xn(t.context_max)}</span></div>`:""}
      ${t.memory_recent_note?o`<div class="keeper-field-row"><span class="keeper-field-title">Memory Note</span><span style="flex:1; text-align:right; color:#ccc;">${t.memory_recent_note}</span></div>`:""}
      ${t.k2k_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">K2K Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.k2k_count}</span></div>`:""}
      ${t.conversation_tail_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Conv Tail</span><span style="flex:1; text-align:right; color:#ccc;">${t.conversation_tail_count}</span></div>`:""}
      ${t.handoff_count_total!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Total Handoffs</span><span style="flex:1; text-align:right; color:#ccc;">${t.handoff_count_total}</span></div>`:""}
      ${t.compaction_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Compactions</span><span style="flex:1; text-align:right; color:#ccc;">${t.compaction_count}</span></div>`:""}
      ${t.last_compaction_saved_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Last Compact Saved</span><span style="flex:1; text-align:right; color:#ccc;">${Xn(t.last_compaction_saved_tokens)}</span></div>`:""}
      ${((r=t.context)==null?void 0:r.message_count)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.message_count}</span></div>`:""}
      ${((u=t.context)==null?void 0:u.has_checkpoint)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function wu({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return o`
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
  `}function Su({items:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No equipment</div>`:o`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>o`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function Au({rels:t}){const e=Object.entries(t);return e.length===0?o`<div class="empty-state" style="font-size:13px">No relationships</div>`:o`
    <div class="keeper-k2k-list">
      ${e.map(([n,a])=>o`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${a}</span>
        </div>
      `)}
    </div>
  `}function Gi({traits:t,label:e}){return t.length===0?null:o`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>o`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function Ga(t){return t==null||Number.isNaN(t)?"-":`${Math.round(t*100)}%`}function Tu({keeper:t}){const e=t.metrics_window,n=[{label:"Model fallback",value:Ga(typeof(e==null?void 0:e.model_fallback_rate)=="number"?e.model_fallback_rate:void 0)},{label:"Proactive fallback",value:Ga(typeof(e==null?void 0:e.proactive_fallback_rate)=="number"?e.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:Ga(typeof(e==null?void 0:e.memory_pass_rate)=="number"?e.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(e==null?void 0:e.handoff_count)=="number"?e.handoff_count:t.handoff_count_total??"-"},{label:"Compactions",value:typeof(e==null?void 0:e.compaction_events)=="number"?e.compaction_events:t.compaction_count??"-"},{label:"Saved tokens",value:typeof(e==null?void 0:e.compaction_saved_tokens)=="number"?e.compaction_saved_tokens:t.last_compaction_saved_tokens??"-"},{label:"K2K events",value:t.k2k_count??"-"},{label:"Conversation tail",value:t.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(e==null?void 0:e.tool_call_count)=="number"?e.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(e==null?void 0:e.proactive_preview_similarity_avg)=="number"?`${(e.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(e==null?void 0:e.memory_avg_score)=="number"?e.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(e==null?void 0:e.fallback_rate)=="number"?`${(e.fallback_rate*100).toFixed(1)}%`:"-"}];return o`
    <div class="keeper-signal-list">
      ${n.map(a=>o`
        <div class="keeper-signal-row">
          <span>${a.label}</span>
          <strong>${a.value}</strong>
        </div>
      `)}
    </div>
  `}function wr(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem("masc_dashboard_agent_name");return(e??n??"dashboard").trim()||"dashboard"}async function Nu(){try{const t=await Rn({actor:wr(),action_type:"lodge_tick",target_type:"room",payload:{}}),e=vi(t.result);De(),await pe(),e!=null&&e.skipped_reason?b(e.skipped_reason,"warning"):b(e?`Poke finished: ${e.acted}/${e.checked} acted`:"Poke finished",e&&e.acted>0?"success":"warning")}catch(t){const e=t instanceof Error?t.message:"Failed to run Lodge poke";b(e,"error")}}function Cu({keeper:t}){return o`
    <div style="margin-top: 24px; border-top: 1px solid rgba(255,255,255,0.1); padding-top: 24px;">
      <h3 style="margin: 0 0 16px; color: var(--accent-cyan); font-family: var(--font-display);">Direct Comms & Runtime Diagnostics</h3>

      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 20px;">
        <div style="display: flex; flex-direction: column; gap: 12px;">
          <${br} keeper=${t} />
          <${xr}
            actor=${wr()}
            keeper=${t}
            onPokeLodge=${()=>{Nu()}}
          />
        </div>

        <div style="min-height: 345px;">
          <${kr}
            keeperName=${t.name}
            placeholder="Direct prompt for this keeper"
          />
        </div>
      </div>
    </div>
  `}function Ru(){var e,n,a;const t=fi.value;return t?o`
    <div
      class="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${s=>{s.target.classList.contains("keeper-detail-overlay")&&Wi()}}
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
            <${yt} status=${t.status} />
            ${t.model?o`<span class="pill">${t.model}</span>`:null}
          </div>
          <button
            onClick=${()=>Wi()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${bu} keeper=${t} />

        ${""}
        <${ku} keeper=${t} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${x} title="Field Dictionary">
            <${xu} keeper=${t} />
          <//>

          ${""}
          <${x} title="Profile">
            <${Gi} traits=${t.traits??[]} label="Traits" />
            <${Gi} traits=${t.interests??[]} label="Interests" />
            ${t.primaryValue?o`<div style="font-size:12px; color:#888;">Primary value: <span style="color:#4ade80;">${t.primaryValue}</span></div>`:null}
            ${t.skill_primary?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Skill route: <span style="color:#22d3ee;">${t.skill_primary}</span>
                </div>`:null}
            ${t.skill_reason?o`<div style="font-size:12px; color:#888; margin-top:4px;">${t.skill_reason}</div>`:null}
            ${t.last_heartbeat?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Last heartbeat: <${q} timestamp=${t.last_heartbeat} />
                </div>`:null}
          <//>

          ${""}
          ${t.autonomy_level?o`
              <${x} title="Autonomy">
                <${yu} keeper=${t} />
              <//>
            `:null}

          ${""}
          ${t.trpg_stats?o`
              <${x} title="TRPG Stats">
                <${wu} stats=${t.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?o`
              <${x} title="Equipment (${t.inventory.length})">
                <${Su} items=${t.inventory} />
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?o`
              <${x} title="Relationships (${Object.keys(t.relationships).length})">
                <${Au} rels=${t.relationships} />
              <//>
            `:null}

          <${x} title="Runtime Signals">
            <${Tu} keeper=${t} />
          <//>

          <${x} title="Memory & Context">
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
        <${Cu} keeper=${t} />
      </div>
    </div>
  `:null}const Lu="masc_dashboard_agent_name",Me=_(null),da=_(!1),yn=_(""),pa=_([]),bn=_([]),Te=_(""),Xe=_(!1);function Ne(t){Me.value=t,_i()}function Ji(){Me.value=null,yn.value="",pa.value=[],bn.value=[],Te.value=""}function Du(){const t=Me.value;return t?te.value.find(e=>e.name===t)??null:null}function Sr(t){return t?Lt.value.filter(e=>e.assignee===t):[]}async function _i(){const t=Me.value;if(t){da.value=!0,yn.value="",pa.value=[],bn.value=[];try{const e=await hc(80);pa.value=e.filter(s=>s.includes(t)).slice(0,20);const n=Sr(t).slice(0,6);if(n.length===0)return;const a=await Promise.all(n.map(async s=>{try{const i=await $c(s.id,25);return{taskId:s.id,text:i.trim()}}catch(i){const r=i instanceof Error?i.message:"history load failed";return{taskId:s.id,text:`Failed to load history: ${r}`}}}));bn.value=a}catch(e){yn.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{da.value=!1}}}async function Vi(){var a;const t=Me.value,e=Te.value.trim();if(!t||!e)return;const n=((a=localStorage.getItem(Lu))==null?void 0:a.trim())||"dashboard";Xe.value=!0;try{await cr(n,`@${t} ${e}`),Te.value="",b(`Mention sent to ${t}`,"success"),_i()}catch(s){const i=s instanceof Error?s.message:"Failed to send mention";b(i,"error")}finally{Xe.value=!1}}function Eu({task:t}){return o`
    <div class="agent-detail-task">
      <span class="pill">${t.id}</span>
      <span class="agent-detail-task-title">${t.title}</span>
      <${yt} status=${t.status} />
    </div>
  `}function Pu({row:t}){return o`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${t.taskId}</span>
      </div>
      <pre class="agent-history-pre">${t.text||"No task history yet"}</pre>
    </div>
  `}function Iu(){var s,i,r,u;const t=Me.value;if(!t)return null;const e=Du(),n=Sr(t),a=pa.value;return o`
    <div
      class="agent-detail-overlay"
      onClick=${d=>{d.target.classList.contains("agent-detail-overlay")&&Ji()}}
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
                        <${yt} status=${e.status} />
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
                    ${e.last_seen?o`<span>Last seen: <${q} timestamp=${e.last_seen} /></span>`:null}
                  `:null}
            </div>
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{_i()}} disabled=${da.value}>
              ${da.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${Ji}>Close</button>
          </div>
        </div>

        ${yn.value?o`<div class="council-error">${yn.value}</div>`:null}

        <div class="agent-detail-grid">
          <${x} title="Assigned Tasks">
            ${n.length===0?o`<div class="empty-state">No assigned tasks</div>`:o`<div class="agent-detail-task-list">${n.map(d=>o`<${Eu} key=${d.id} task=${d} />`)}</div>`}
          <//>

          <${x} title="Recent Activity">
            ${a.length===0?o`<div class="empty-state">No recent room activity match</div>`:o`<div class="agent-activity-list">${a.map((d,p)=>o`<div key=${p} class="agent-activity-line">${d}</div>`)}</div>`}
          <//>
        </div>

        <${x} title="Task History">
          ${bn.value.length===0?o`<div class="empty-state">No task history loaded</div>`:o`<div class="agent-history-list">${bn.value.map(d=>o`<${Pu} key=${d.taskId} row=${d} />`)}</div>`}
        <//>

        <${x} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${Te.value}
              onInput=${d=>{Te.value=d.target.value}}
              onKeyDown=${d=>{d.key==="Enter"&&Vi()}}
              disabled=${Xe.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{Vi()}}
              disabled=${Xe.value||Te.value.trim()===""}
            >
              ${Xe.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}const Ja=600*1e3,Va=1200*1e3,Qi=.8;function xt(t){if(t==null)return 0;const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function Ut(t){switch(t){case"bad":return 2;case"warn":return 1;default:return 0}}function Yi(t){return(t??"").trim().toLowerCase()}function Bt(t,e=96){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:null}function $e(t){return typeof t!="number"||Number.isNaN(t)?3:t}function Mu(t){const e=$e(t);return e<=1?"P1":e===2?"P2":e>=4?"P4+":"P3"}function fe(t){const e=(t??"").toLowerCase();return e==="bad"?"bad":e==="warn"?"warn":"ok"}function Fn(t){switch(t){case"bad":return"#fb7185";case"warn":return"#fbbf24";default:return"#4ade80"}}function Xi(t){return typeof t!="number"||!Number.isFinite(t)?"??:00":`${String(Math.max(0,t)).padStart(2,"0")}:00`}function Zi(t){if(t==null||!Number.isFinite(t))return"unknown";if(t<60)return`${Math.round(t)}s`;const e=Math.round(t/60);if(e<60)return`${e}m`;const n=Math.floor(e/60),a=e%60;return a>0?`${n}h ${a}m`:`${n}h`}function Ou(t){if(!t)return"N/A";const e=Math.floor(t/3600),n=Math.floor(t%3600/60);return e>0?`${e}h ${n}m`:`${n}m`}function Qa(t){if(t==null||!Number.isFinite(t))return"No data";if(t<60)return`${Math.max(0,Math.round(t))}s`;const e=Math.floor(t/60);if(e<60)return`${e}m`;const n=Math.floor(e/60),a=e%60;return a>0?`${n}h ${a}m`:`${n}h`}function Fu(t){return t==null?"—":t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}k`:String(t)}function ju(t){switch(t){case"quiet_hours":return"quiet hours";case"min_gap":return"cooldown gate";case"no_recent_activity":return"waiting for activity";case"disabled":return"runtime disabled";case"startup":return"warming up";case"llm_error":return"llm error";case"graphql_error":return"graphql error";case"never_started":return"never started";default:return"unknown"}}function qu(t){switch(t){case"manual_lodge_poke":return"Poke Lodge";case"probe":return"Probe";case"recover":return"Recover";default:return"Message"}}function zu(t){return t?t.enabled?t.quiet_active?`Quiet hours ${Xi(t.quiet_start)}-${Xi(t.quiet_end)} KST are active. Scheduled ticks may appear asleep until the window ends.`:t.last_tick_ago_s==null?`Lodge is enabled and scheduled every ${Zi(t.interval_s)}, but no tick has run yet.`:`Lodge ticks every ${Zi(t.interval_s)} with planner ${t.use_planner?"on":"off"} and delegated LLM ${t.delegate_llm?"on":"off"}.`:"Lodge automation is disabled.":"Lodge runtime status is unavailable in the current dashboard payload."}function to(t){const e=(t??"").toLowerCase();return e==="ok"?"Healthy":e==="warn"?"Warning":e==="bad"?"Degraded":"Unknown"}function _e({label:t,value:e,color:n,caption:a}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color: ${n}`:""}>${e}</div>
      ${a?o`<div class="monitor-stat-caption">${a}</div>`:null}
    </div>
  `}function Hu({item:t}){return o`
    <button class="monitor-alert ${t.tone}" onClick=${t.action}>
      <div class="monitor-alert-main">
        <div class="monitor-alert-title">${t.title}</div>
        <div class="monitor-alert-subtitle">${t.detail}</div>
      </div>
      <div class="monitor-alert-meta">
        <span class="monitor-pill ${t.tone}">${t.tone==="bad"?"Act now":t.tone==="warn"?"Watch":"Stable"}</span>
        ${t.timestamp?o`<span><${q} timestamp=${t.timestamp} /></span>`:null}
      </div>
    </button>
  `}function Ya({tone:t,title:e,subtitle:n,meta:a,focus:s,onClick:i}){return o`
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
  `}function eo(){var A,L,tt,bt,kt,et,ut,I,W,$,ne,Fe,Dn,En,Pn;const t=ee.value,e=te.value,n=Lt.value,a=$t.value,s=fr.value,i=(A=t==null?void 0:t.monitoring)==null?void 0:A.board,r=(L=t==null?void 0:t.monitoring)==null?void 0:L.council,u=It.value,d=new Map(e.map(v=>[Yi(v.name),v])),p=e.map(v=>{var bi;const T=$n(v.name,n,ue.value,Xt.value,{currentTask:v.current_task,lastSeen:v.last_seen,boardPosts:Ft.value,keepers:a}),M=T.lastActivityAt??v.last_seen??null,V=M?Math.max(0,Date.now()-xt(M)):Number.POSITIVE_INFINITY,O=T.activeAssignedCount,nt=!!((bi=v.current_task)!=null&&bi.trim()),G=nt||O>0;let U="ok",at="Fresh and ready",Ht=!1,Kt=!1;return v.status==="offline"||v.status==="inactive"?(U=G?"bad":"warn",at=G?"Load without an available owner":"Offline"):G&&V>Va?(U="bad",at="Execution is stale"):O>0&&!nt?(U="warn",at="Claimed work has no current_task",Kt=!0):nt&&O===0?(U="warn",at="current_task has no claimed work",Kt=!0):!G&&V<=Ja?(U="ok",at="Dispatchable now",Ht=!0):!G&&V>Va?(U="warn",at="Idle but not freshly active"):G&&V>Ja&&(U="warn",at="Execution is getting quiet"),{agent:v,lastSignalAt:M,activeTaskCount:O,tone:U,note:at,focus:Bt(v.current_task)??T.lastActivityText??(Ht?"Ready for assignment.":"Waiting for a clearer signal."),dispatchable:Ht,drift:Kt}}).sort((v,T)=>{const M=Ut(T.tone)-Ut(v.tone);return M!==0?M:xt(T.lastSignalAt)-xt(v.lastSignalAt)}),f=a.map(v=>{var U;const T=_r.value.get(v.name)??"idle",M=gr.value.has(v.name),V=v.context_ratio??0,O=v.diagnostic??null;let nt="ok",G="Healthy keeper";return M||v.status==="offline"||T==="handoff-imminent"||(O==null?void 0:O.health_state)==="offline"||(O==null?void 0:O.health_state)==="degraded"?(nt="bad",G=Bt(O==null?void 0:O.summary,56)??(M?"Heartbeat stale":T==="handoff-imminent"?"Handoff imminent":(O==null?void 0:O.health_state)==="degraded"?"Keeper degraded":"Keeper offline")):((O==null?void 0:O.health_state)==="stale"||V>=Qi||T==="preparing"||T==="compacting")&&(nt="warn",G=Bt(O==null?void 0:O.summary,56)??(V>=Qi?"High context pressure":`Lifecycle ${T}`)),{keeper:v,tone:nt,note:G,focus:Bt(O==null?void 0:O.summary,120)??Bt((U=v.agent)==null?void 0:U.current_task)??v.skill_primary??v.last_proactive_reason??v.memory_recent_note??"No active focus",timestamp:v.last_heartbeat??null}}).sort((v,T)=>{const M=Ut(T.tone)-Ut(v.tone);return M!==0?M:xt(T.timestamp)-xt(v.timestamp)}),l=n.filter(v=>v.status==="todo"||v.status==="claimed"||v.status==="in_progress").map(v=>{var Ht,Kt;const T=v.assignee?d.get(Yi(v.assignee))??null:null,M=T?$n(T.name,n,ue.value,Xt.value,{currentTask:T.current_task,lastSeen:T.last_seen,boardPosts:Ft.value,keepers:a}):null,V=(M==null?void 0:M.lastActivityAt)??(T==null?void 0:T.last_seen)??null,O=V?Math.max(0,Date.now()-xt(V)):Number.POSITIVE_INFINITY,nt=v.status==="claimed"||v.status==="in_progress";let G="ok",U="Covered",at=!1;return v.assignee?!T||T.status==="offline"||T.status==="inactive"?(G="bad",U="Assigned owner is unavailable",at=!0):nt&&O>Va?(G="bad",U="Execution has lost a fresh signal"):nt&&O>Ja?(G="warn",U="Execution is drifting quiet"):v.status==="todo"&&$e(v.priority)<=2&&!((Ht=T.current_task)!=null&&Ht.trim())&&((M==null?void 0:M.activeAssignedCount)??0)===0?(G="ok",U="Ready for dispatch"):nt&&!((Kt=T.current_task)!=null&&Kt.trim())&&(G="warn",U="Owner focus is not explicit"):(G=$e(v.priority)<=2?"bad":"warn",U=nt?"Active work has no owner":"Ready work has no owner",at=!0),{task:v,owner:T,lastSignalAt:V,tone:G,note:U,focus:Bt(T==null?void 0:T.current_task)??(M==null?void 0:M.lastActivityText)??Bt(v.description)??"Needs operator attention.",ownerGap:at}}).sort((v,T)=>{const M=Ut(T.tone)-Ut(v.tone);if(M!==0)return M;const V=$e(v.task.priority)-$e(T.task.priority);return V!==0?V:xt(T.lastSignalAt??T.task.updated_at??T.task.created_at)-xt(v.lastSignalAt??v.task.updated_at??v.task.created_at)}),c=l.filter(v=>v.task.status==="todo"&&$e(v.task.priority)<=2),m=l.filter(v=>v.ownerGap).length,h=p.filter(v=>v.dispatchable),y=p.filter(v=>v.drift||v.tone!=="ok"),w=f.filter(v=>v.tone!=="ok"),C=t!=null&&t.paused?"bad":((tt=t==null?void 0:t.data_quality)==null?void 0:tt.board_contract_ok)===!1||((bt=t==null?void 0:t.data_quality)==null?void 0:bt.council_feed_ok)===!1?"warn":u?"ok":"warn",S=[];t!=null&&t.paused&&S.push({key:"paused",tone:"bad",title:"Room is paused",detail:t.tempo?`Tempo is ${t.tempo}. Resume from Ops when ready.`:"Resume from Ops when ready.",timestamp:((kt=t.data_quality)==null?void 0:kt.last_sync_at)??null,action:()=>_t("ops")}),u||S.push({key:"live-connection",tone:"warn",title:"Live feed is reconnecting",detail:"Dashboard telemetry is stale until the SSE stream recovers.",timestamp:null,action:()=>_t("activity")}),fe(i==null?void 0:i.alert_level)!=="ok"&&S.push({key:"board-monitor",tone:fe(i==null?void 0:i.alert_level),title:"Board feed needs attention",detail:`Freshness ${Qa(i==null?void 0:i.last_activity_age_s)} · ${(i==null?void 0:i.unanswered_posts)??0} unanswered posts.`,timestamp:null,action:()=>_t("board")}),fe(r==null?void 0:r.alert_level)!=="ok"&&S.push({key:"council-monitor",tone:fe(r==null?void 0:r.alert_level),title:"Council quorum risk is elevated",detail:`${(r==null?void 0:r.sessions_without_quorum)??0} sessions without quorum · freshness ${Qa(r==null?void 0:r.last_activity_age_s)}.`,timestamp:null,action:()=>_t("council")}),(((et=t==null?void 0:t.data_quality)==null?void 0:et.board_contract_ok)===!1||((ut=t==null?void 0:t.data_quality)==null?void 0:ut.council_feed_ok)===!1)&&S.push({key:"data-quality",tone:"warn",title:"Dashboard data quality is degraded",detail:`${((I=t.data_quality)==null?void 0:I.board_contract_ok)===!1?"Board contract":"Board contract ok"} · ${((W=t.data_quality)==null?void 0:W.council_feed_ok)===!1?"Council feed degraded":"Council feed ok"}.`,timestamp:(($=t.data_quality)==null?void 0:$.last_sync_at)??null,action:()=>_t("ops")});const P=[...S,...l.filter(v=>v.tone!=="ok").slice(0,3).map(v=>({key:`task-${v.task.id}`,tone:v.tone,title:v.task.title,detail:`${v.note} · ${v.focus}`,timestamp:v.lastSignalAt??v.task.updated_at??v.task.created_at??null,action:()=>_t("execution")})),...w.slice(0,2).map(v=>({key:`keeper-${v.keeper.name}`,tone:v.tone,title:v.keeper.name,detail:`${v.note} · ${v.focus}`,timestamp:v.timestamp,action:()=>ua(v.keeper)})),...y.slice(0,2).map(v=>({key:`agent-${v.agent.name}`,tone:v.tone,title:v.agent.name,detail:`${v.note} · ${v.focus}`,timestamp:v.lastSignalAt,action:()=>Ne(v.agent.name)}))].sort((v,T)=>{const M=Ut(T.tone)-Ut(v.tone);return M!==0?M:xt(T.timestamp)-xt(v.timestamp)}).slice(0,8);return o`
    <div class="stats-grid">
      <${_e}
        label="Room State"
        value=${t!=null&&t.paused?"Paused":"Running"}
        color=${Fn(C)}
        caption=${(t==null?void 0:t.room)??(t==null?void 0:t.project)??"default room"}
      />
      <${_e}
        label="Urgent Queue"
        value=${c.length}
        color=${c.length>0?"#fb7185":"#4ade80"}
        caption="todo tasks at P1/P2"
      />
      <${_e}
        label="Active Work"
        value=${s.inProgress.length}
        color="#fbbf24"
        caption="claimed + in progress"
      />
      <${_e}
        label="Dispatchable"
        value=${h.length}
        color="#22d3ee"
        caption="fresh agents with no load"
      />
      <${_e}
        label="Keeper Pressure"
        value=${w.length}
        color=${w.length>0?"#fbbf24":"#4ade80"}
        caption="stale or high-context keepers"
      />
      <${_e}
        label="Owner Gaps"
        value=${m}
        color=${m>0?"#fb7185":"#4ade80"}
        caption="tasks missing a live owner"
      />
    </div>

    <${x} title="Room Health" class="section">
      <div class="monitor-section-head">
        <h2 class="monitor-headline">Operational health at a glance</h2>
        <p class="monitor-subheadline">The Overview now prioritizes room state, feed freshness, and immediate intervention signals over full entity dumps.</p>
      </div>
      <div class="overview-health-grid">
        <div class="stat-card">
          <div class="stat-label">Live Feed</div>
          <div class="stat-value" style=${`color:${u?"#4ade80":"#fbbf24"}`}>${u?"Online":"Retrying"}</div>
          <div class="monitor-stat-caption">${Tn.value} events seen in this session</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Board Feed</div>
          <div class="stat-value" style=${`color:${Fn(fe(i==null?void 0:i.alert_level))}`}>${to(i==null?void 0:i.alert_level)}</div>
          <div class="monitor-stat-caption">Freshness ${Qa(i==null?void 0:i.last_activity_age_s)}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Council Feed</div>
          <div class="stat-value" style=${`color:${Fn(fe(r==null?void 0:r.alert_level))}`}>${to(r==null?void 0:r.alert_level)}</div>
          <div class="monitor-stat-caption">${(r==null?void 0:r.sessions_without_quorum)??0} sessions without quorum</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Runtime</div>
          <div class="stat-value" style=${`color:${Fn(C)}`}>${t!=null&&t.paused?"Paused":"Stable"}</div>
          <div class="monitor-stat-caption">Uptime ${Ou((t==null?void 0:t.uptime_seconds)??0)}</div>
        </div>
      </div>
      <div class="overview-note-stack">
        <div class="overview-inline-note">
          ${(ne=t==null?void 0:t.data_quality)!=null&&ne.last_sync_at?o`Last sync <${q} timestamp=${t.data_quality.last_sync_at} />`:o`No sync metadata yet`}
        </div>
        <div class="overview-inline-note">
          ${t!=null&&t.tempo?`Tempo ${t.tempo}`:"Tempo unavailable"}${(t==null?void 0:t.tempo_interval_s)!=null?` · ${t.tempo_interval_s}s interval`:""}
        </div>
        <div class="overview-inline-note">${zu(t==null?void 0:t.lodge)}</div>
      </div>
    <//>

    <div class="grid-2col">
      <${x} title="Intervention Queue" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">What needs intervention right now</h2>
          <p class="monitor-subheadline">Room-level risks, stalled work, and keeper/agent drift are sorted into one operator-facing queue.</p>
        </div>
        <div class="monitor-alert-list">
          ${P.length===0?o`<div class="empty-state">No immediate intervention required</div>`:P.map(v=>o`<${Hu} key=${v.key} item=${v} />`)}
        </div>
      <//>

      <${x} title="Dispatch Window" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Who can pick up work next</h2>
          <p class="monitor-subheadline">Fresh capacity stays visible here so dispatch does not require opening the full Agents tab.</p>
        </div>
        <div class="monitor-list">
          ${h.length===0?o`<div class="empty-state">No fully dispatchable agents right now</div>`:h.slice(0,5).map(v=>o`
                <${Ya}
                  key=${v.agent.name}
                  tone=${v.tone}
                  title=${v.agent.name}
                  subtitle=${v.note}
                  meta=${[v.lastSignalAt?`Signal ${new Date(v.lastSignalAt).toLocaleTimeString()}`:"No recent signal",v.agent.model??"model n/a",v.agent.koreanName??"room agent"]}
                  focus=${v.focus}
                  onClick=${()=>Ne(v.agent.name)}
                />
              `)}
        </div>
      <//>
    </div>

    <div class="grid-2col">
      <${x} title="Execution Pulse" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Priority work and ownership drift</h2>
          <p class="monitor-subheadline">Urgent ready tasks and active execution issues stay visible without duplicating the full Execution surface.</p>
        </div>
        <div class="monitor-list">
          ${l.length===0?o`<div class="empty-state">No active or ready tasks</div>`:l.slice(0,6).map(v=>o`
                <${Ya}
                  key=${v.task.id}
                  tone=${v.tone}
                  title=${v.task.title}
                  subtitle=${`${Mu(v.task.priority)} · ${v.note}`}
                  meta=${[v.task.assignee?`Owner ${v.task.assignee}`:"Unassigned",v.lastSignalAt?`Signal ${new Date(v.lastSignalAt).toLocaleTimeString()}`:"No live signal",v.task.updated_at?`Touched ${new Date(v.task.updated_at).toLocaleTimeString()}`:"No task timestamp"]}
                  focus=${v.focus}
                  onClick=${()=>_t("execution")}
                />
              `)}
        </div>
      <//>

      <${x} title="Keeper Pressure" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Long-running keepers under pressure</h2>
          <p class="monitor-subheadline">Only keepers with real pressure stay in the Overview. The full keeper census still lives in the Agents tab.</p>
        </div>
        <div class="monitor-list">
          ${w.length===0?o`<div class="empty-state">No keeper pressure signals right now</div>`:w.slice(0,5).map(v=>{var T;return o`
                <${Ya}
                  key=${v.keeper.name}
                  tone=${v.tone}
                  title=${v.keeper.name}
                  subtitle=${(T=v.keeper.diagnostic)!=null&&T.health_state?`${v.note} · ${v.keeper.diagnostic.health_state}`:v.note}
                  meta=${[v.timestamp?`Heartbeat ${new Date(v.timestamp).toLocaleTimeString()}`:"No heartbeat",`Context ${typeof v.keeper.context_ratio=="number"?Math.round(v.keeper.context_ratio*100):0}%`,v.keeper.model?`Model ${v.keeper.model}`:"model n/a",v.keeper.diagnostic?`${ju(v.keeper.diagnostic.quiet_reason)} · next ${qu(v.keeper.diagnostic.next_action_path)} · reply ${v.keeper.diagnostic.last_reply_status}`:"Diagnostic unavailable"]}
                  focus=${v.focus}
                  onClick=${()=>ua(v.keeper)}
                />
              `})}
        </div>
      <//>
    </div>

    <div class="grid-2col">
      <${x} title="Agent Watch" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Agents with drift or aging load</h2>
          <p class="monitor-subheadline">This is the short list. Use the Agents tab when you need the full live monitor.</p>
        </div>
        <div class="monitor-list">
          ${y.length===0?o`<div class="empty-state">No agent drift or stale load right now</div>`:y.slice(0,5).map(v=>o`
                <button class="monitor-row ${v.tone}" onClick=${()=>Ne(v.agent.name)}>
                  <div class="monitor-row-header">
                    <div class="monitor-row-title">
                      <div class="monitor-name-line">
                        <span class="monitor-title">${v.agent.name}</span>
                        ${v.agent.koreanName?o`<span class="monitor-sub">${v.agent.koreanName}</span>`:null}
                      </div>
                      <div class="monitor-note">${v.note}</div>
                    </div>
                    <${yt} status=${v.agent.status} />
                    <span class="monitor-pill ${v.tone}">${v.dispatchable?"Ready":v.drift?"Drift":"Watch"}</span>
                  </div>
                  <div class="monitor-meta">
                    ${v.lastSignalAt?o`<span>Signal <${q} timestamp=${v.lastSignalAt} /></span>`:o`<span>No recent signal</span>`}
                    <span>${v.activeTaskCount>0?`${v.activeTaskCount} active tasks`:"No active tasks"}</span>
                    ${v.agent.model?o`<span>${v.agent.model}</span>`:null}
                  </div>
                  <div class="monitor-focus">${v.focus}</div>
                </button>
              `)}
        </div>
      <//>

      <${x} title="Runtime Notes" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Secondary runtime context</h2>
          <p class="monitor-subheadline">This stays below the triage queue so operators can scan first and drill later.</p>
        </div>
        <div class="overview-note-stack">
          <div class="overview-inline-note">
            Room ${(t==null?void 0:t.room)??"default"}${t!=null&&t.cluster?` · Cluster ${t.cluster}`:""}${t!=null&&t.project?` · Project ${t.project}`:""}
          </div>
          <div class="overview-inline-note">
            ${t!=null&&t.version?`Version ${t.version}`:"Version unavailable"} · Active agents ${Gc.value.length} · Total tasks ${n.length}
          </div>
          <div class="overview-inline-note">
            ${Ue.value?`Perpetual runtime ${Ue.value.running?"running":"stopped"}${Ue.value.goal?` · ${Bt(Ue.value.goal,120)}`:""}`:"Perpetual runtime unavailable"}
          </div>
          <div class="overview-inline-note">
            Lodge ${(Fe=t==null?void 0:t.lodge)!=null&&Fe.enabled?"enabled":"disabled"} · Last tick ${((Dn=t==null?void 0:t.lodge)==null?void 0:Dn.last_tick_ago)??"never"} · Self heartbeats ${((Pn=(En=t==null?void 0:t.lodge)==null?void 0:En.active_self_heartbeats)==null?void 0:Pn.length)??0}
          </div>
          <div class="overview-inline-note">
            ${a.length>0?`Hot keepers: ${w.length} · Highest context ${Fu(Math.max(...a.map(v=>v.context_tokens??0)))}`:"No keepers registered"}
          </div>
        </div>
      <//>
    </div>
  `}const Ln=_(null),va=_(!1),Zt=_(null),H=_(!1),ma=_([]);let Ku=1;function K(t){return typeof t=="object"&&t!==null&&!Array.isArray(t)}function R(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function rt(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Ar(t){return typeof t=="boolean"?t:void 0}function Uu(t){return Array.isArray(t)?t.map(e=>typeof e=="string"?e.trim():"").filter(Boolean):[]}function ye(t,e=[]){if(Array.isArray(t))return t;if(!K(t))return[];for(const n of e){const a=t[n];if(Array.isArray(a))return a}return[]}function Bu(t){return K(t)?{id:R(t.id),seq:rt(t.seq),from:R(t.from)??R(t.from_agent)??"system",content:R(t.content)??"",timestamp:R(t.timestamp)??new Date().toISOString(),type:R(t.type)}:null}function Wu(t){return K(t)?{room_id:R(t.room_id),current_room:R(t.current_room)??R(t.room),project:R(t.project),cluster:R(t.cluster),paused:Ar(t.paused),pause_reason:R(t.pause_reason)??null,paused_by:R(t.paused_by)??null,paused_at:R(t.paused_at)??null}:{}}function no(t){if(!K(t))return;const e=Object.entries(t).map(([n,a])=>{const s=R(a);return s?[n,s]:null}).filter(n=>n!==null);return e.length>0?Object.fromEntries(e):void 0}function Gu(t){if(!K(t))return null;const e=K(t.status)?t.status:void 0,n=K(t.summary)?t.summary:K(e==null?void 0:e.summary)?e.summary:void 0,a=K(t.session)?t.session:K(e==null?void 0:e.session)?e.session:void 0,s=R(t.session_id)??R(n==null?void 0:n.session_id)??R(a==null?void 0:a.session_id);if(!s)return null;const i=no(t.report_paths)??no(e==null?void 0:e.report_paths),r=ye(t.recent_events,["events"]).filter(K);return{session_id:s,status:R(t.status)??R(n==null?void 0:n.status)??R(a==null?void 0:a.status),progress_pct:rt(t.progress_pct)??rt(n==null?void 0:n.progress_pct),elapsed_sec:rt(t.elapsed_sec)??rt(n==null?void 0:n.elapsed_sec),remaining_sec:rt(t.remaining_sec)??rt(n==null?void 0:n.remaining_sec),done_delta_total:rt(t.done_delta_total)??rt(n==null?void 0:n.done_delta_total),summary:n,team_health:K(t.team_health)?t.team_health:K(e==null?void 0:e.team_health)?e.team_health:void 0,communication_metrics:K(t.communication_metrics)?t.communication_metrics:K(e==null?void 0:e.communication_metrics)?e.communication_metrics:void 0,orchestration_state:K(t.orchestration_state)?t.orchestration_state:K(e==null?void 0:e.orchestration_state)?e.orchestration_state:void 0,cascade_metrics:K(t.cascade_metrics)?t.cascade_metrics:K(e==null?void 0:e.cascade_metrics)?e.cascade_metrics:void 0,report_paths:i,session:a,recent_events:r}}function Ju(t){if(!K(t))return null;const e=R(t.name);if(!e)return null;const n=K(t.context)?t.context:void 0;return{name:e,agent_name:R(t.agent_name),status:R(t.status),autonomy_level:R(t.autonomy_level),context_ratio:rt(t.context_ratio)??rt(n==null?void 0:n.context_ratio),generation:rt(t.generation),active_goal_ids:Uu(t.active_goal_ids),last_autonomous_action_at:R(t.last_autonomous_action_at)??null,last_turn_ago_s:rt(t.last_turn_ago_s),model:R(t.model)??R(t.active_model)??R(t.primary_model)}}function Vu(t){if(!K(t))return null;const e=R(t.confirm_token)??R(t.token);return e?{confirm_token:e,actor:R(t.actor),action_type:R(t.action_type),target_type:R(t.target_type),target_id:R(t.target_id)??null,delegated_tool:R(t.delegated_tool),created_at:R(t.created_at),preview:t.preview}:null}function Qu(t){const e=K(t)?t:{};return{room:Wu(e.room),sessions:ye(e.sessions,["items","sessions"]).map(Gu).filter(n=>n!==null),keepers:ye(e.keepers,["items","keepers"]).map(Ju).filter(n=>n!==null),recent_messages:ye(e.recent_messages,["messages"]).map(Bu).filter(n=>n!==null),pending_confirms:ye(e.pending_confirms,["items","confirms"]).map(Vu).filter(n=>n!==null),available_actions:ye(e.available_actions,["actions"]).filter(K).map(n=>({action_type:R(n.action_type)??"unknown",target_type:R(n.target_type)??"unknown",description:R(n.description),confirm_required:Ar(n.confirm_required)}))}}function jn(t){if(typeof t=="string")return t;if(t==null)return"";try{return JSON.stringify(t)}catch{return String(t)}}function ao(t){return t.target_id?`${t.target_type}:${t.target_id}`:t.target_type}function fa(t){ma.value=[{...t,id:Ku++,at:new Date().toISOString()},...ma.value].slice(0,20)}function Tr(t){return t.confirm_required?jn(t.preview)||"Confirmation required":jn(t.result)||jn(t.executed_action)||jn(t.delegated_tool_result)||t.status}async function Ee(){va.value=!0,Zt.value=null;try{const t=await Ol();Ln.value=Qu(t)}catch(t){Zt.value=t instanceof Error?t.message:"Failed to load operator snapshot"}finally{va.value=!1}}async function Yu(t){H.value=!0,Zt.value=null;try{const e=await Rn(t);return fa({actor:t.actor,action_type:t.action_type,target_label:ao(t),outcome:e.confirm_required?"preview":"executed",message:Tr(e),delegated_tool:e.delegated_tool}),await Ee(),e}catch(e){const n=e instanceof Error?e.message:"Operator action failed";throw Zt.value=n,fa({actor:t.actor,action_type:t.action_type,target_label:ao(t),outcome:"error",message:n}),e}finally{H.value=!1}}async function Xu(t,e){H.value=!0,Zt.value=null;try{const n=await Fl(t,e);return fa({actor:t,action_type:"confirm",target_label:e,outcome:"confirmed",message:Tr(n),delegated_tool:n.delegated_tool}),await Ee(),n}catch(n){const a=n instanceof Error?n.message:"Operator confirmation failed";throw Zt.value=a,fa({actor:t,action_type:"confirm",target_label:e,outcome:"error",message:a}),n}finally{H.value=!1}}const Nr="masc_dashboard_agent_name";function Zu(){var e,n,a;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||((a=localStorage.getItem(Nr))==null?void 0:a.trim())||"dashboard"}const Oa=_(Zu()),Ze=_(""),Hs=_("Operator pause"),tn=_(""),_a=_(""),Ks=_("2"),ga=_(""),Ce=_("note"),ha=_(""),$a=_(""),ya=_(""),Us=_("2"),Bs=_("Operator stop request"),Ws=_(""),en=_("");function td(t){const e=t.trim()||"dashboard";Oa.value=e,localStorage.setItem(Nr,e)}function so(t){if(t==null)return"";if(typeof t=="string")return t;try{return JSON.stringify(t,null,2)}catch{return String(t)}}function ed(t){return typeof t!="number"||!Number.isFinite(t)?"n/a":t<60?`${Math.round(t)}s ago`:t<3600?`${Math.round(t/60)}m ago`:`${Math.round(t/3600)}h ago`}function ba(t){return typeof t=="string"?t.trim().toLowerCase():""}function nd(t){var a;const e=ba(t.status);if(e==="paused")return"bad";const n=ba((a=t.team_health)==null?void 0:a.status);return n&&n!=="ok"&&n!=="healthy"&&n!=="green"||e&&e!=="active"&&e!=="running"&&e!=="ended"?"warn":"ok"}function io(t){const e=ba(t.status);return e==="offline"||e==="inactive"||e==="error"?"bad":(t.context_ratio??0)>=.8||(t.last_turn_ago_s??0)>=3600?"warn":"ok"}async function ve(t){const e=Oa.value.trim()||"dashboard";try{const n=await Yu({actor:e,action_type:t.action_type,target_type:t.target_type,target_id:t.target_id,payload:t.payload});return n.confirm_required?b("Confirmation queued","warning"):b(t.successMessage,"success"),n}catch(n){const a=n instanceof Error?n.message:"Operator action failed";return b(a,"error"),null}}async function oo(){const t=Ze.value.trim();if(!t)return;await ve({action_type:"broadcast",target_type:"room",payload:{message:t},successMessage:"Broadcast sent"})&&(Ze.value="")}async function ad(){await ve({action_type:"room_pause",target_type:"room",payload:{reason:Hs.value.trim()||"Operator pause"},successMessage:"Pause request sent"})}async function sd(){await ve({action_type:"room_resume",target_type:"room",payload:{},successMessage:"Room resumed"})}async function id(){const t=tn.value.trim();if(!t)return;await ve({action_type:"task_inject",target_type:"room",payload:{title:t,description:_a.value.trim()||"Injected from Ops tab",priority:Number.parseInt(Ks.value,10)||2},successMessage:"Task injection submitted"})&&(tn.value="",_a.value="")}async function od(){var i;const t=Ln.value,e=ga.value||((i=t==null?void 0:t.sessions[0])==null?void 0:i.session_id)||"";if(!e){b("Select a team session first","warning");return}const n={turn_kind:Ce.value},a=ha.value.trim();a&&(n.message=a),Ce.value==="task"&&(n.task_title=$a.value.trim()||"Operator injected task",n.task_description=ya.value.trim()||"Injected from Ops tab",n.task_priority=Number.parseInt(Us.value,10)||2),await ve({action_type:"team_turn",target_type:"team_session",target_id:e,payload:n,successMessage:"Team session updated"})&&(ha.value="",Ce.value==="task"&&($a.value="",ya.value=""))}async function rd(){var n;const t=Ln.value,e=ga.value||((n=t==null?void 0:t.sessions[0])==null?void 0:n.session_id)||"";if(!e){b("Select a team session first","warning");return}await ve({action_type:"team_stop",target_type:"team_session",target_id:e,payload:{reason:Bs.value.trim()||"Operator stop request"},successMessage:"Team stop requested"})}async function ld(){var s;const t=Ln.value,e=Ws.value||((s=t==null?void 0:t.keepers[0])==null?void 0:s.name)||"",n=en.value.trim();if(!e){b("Select a keeper first","warning");return}if(!n)return;await ve({action_type:"keeper_msg",target_type:"keeper",target_id:e,payload:{message:n},successMessage:`Message sent to ${e}`})&&(en.value="")}async function cd(t){const e=Oa.value.trim()||"dashboard";try{await Xu(e,t),b("Confirmation executed","success")}catch(n){const a=n instanceof Error?n.message:"Confirmation failed";b(a,"error")}}function ud(){var l;Rt(()=>{Ee()},[]);const t=Ln.value,e=(t==null?void 0:t.room)??{},n=(t==null?void 0:t.sessions)??[],a=(t==null?void 0:t.keepers)??[],s=(t==null?void 0:t.pending_confirms)??[],i=(t==null?void 0:t.recent_messages)??[],r=n.find(c=>c.session_id===ga.value)??n[0]??null,u=a.find(c=>c.name===Ws.value)??a[0]??null,d=n.filter(c=>nd(c)!=="ok"),p=a.filter(c=>io(c)!=="ok"),f=[{key:"room",label:"Room Gate",value:e.paused?"Paused":"Open",detail:e.paused?`Resume gate armed${e.pause_reason?` · ${e.pause_reason}`:""}`:"Commands are live and the room is accepting new work",tone:e.paused?"bad":"ok"},{key:"confirm",label:"Pending Confirm",value:s.length,detail:s.length>0?"Previewed operator actions are waiting for confirmation":"No confirm gates are currently blocking execution",tone:s.length>0?"warn":"ok"},{key:"session",label:"Session Risk",value:d.length,detail:d.length>0?"Team sessions need steering, stop, or checkpoint attention":"Team sessions look healthy from the operator snapshot",tone:d.some(c=>ba(c.status)==="paused")?"bad":d.length>0?"warn":"ok"},{key:"keeper",label:"Keeper Pressure",value:p.length,detail:p.length>0?"At least one keeper is stale, offline, or running hot":"Keepers are available for direct intervention",tone:p.some(c=>io(c)==="bad")?"bad":p.length>0?"warn":"ok"}];return o`
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
            value=${Oa.value}
            onInput=${c=>td(c.target.value)}
          />
          <button class="control-btn ghost" onClick=${()=>{Ee()}} disabled=${va.value||H.value}>
            ${va.value?"Refreshing...":"Refresh"}
          </button>
        </div>
      </div>

      ${Zt.value?o`
        <section class="ops-banner error">${Zt.value}</section>
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
                ${c.preview?o`<pre class="ops-code-block">${so(c.preview)}</pre>`:null}
                <div class="ops-confirmation-actions">
                  <button class="control-btn" onClick=${()=>{cd(c.confirm_token)}} disabled=${H.value}>
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
              value=${Ze.value}
              onInput=${c=>{Ze.value=c.target.value}}
              onKeyDown=${c=>{c.key==="Enter"&&oo()}}
              disabled=${H.value}
            />
            <button class="control-btn" onClick=${()=>{oo()}} disabled=${H.value||Ze.value.trim()===""}>
              Send
            </button>
          </div>

          <label class="control-label" for="ops-pause-reason">Pause Reason</label>
          <div class="control-row ops-split-row">
            <input
              id="ops-pause-reason"
              class="control-input"
              type="text"
              value=${Hs.value}
              onInput=${c=>{Hs.value=c.target.value}}
              disabled=${H.value}
            />
            <button class="control-btn ghost" onClick=${()=>{ad()}} disabled=${H.value}>
              Pause
            </button>
            <button class="control-btn ghost" onClick=${()=>{sd()}} disabled=${H.value}>
              Resume
            </button>
          </div>

          <div class="ops-section-head">Task Inject</div>
          <input
            class="control-input"
            type="text"
            placeholder="Task title"
            value=${tn.value}
            onInput=${c=>{tn.value=c.target.value}}
            disabled=${H.value}
          />
          <textarea
            class="control-textarea"
            rows=${3}
            placeholder="Task description"
            value=${_a.value}
            onInput=${c=>{_a.value=c.target.value}}
            disabled=${H.value}
          ></textarea>
          <div class="control-row ops-split-row">
            <select
              class="control-input ops-select"
              value=${Ks.value}
              onChange=${c=>{Ks.value=c.target.value}}
              disabled=${H.value}
            >
              <option value="1">P1</option>
              <option value="2">P2</option>
              <option value="3">P3</option>
              <option value="4">P4</option>
              <option value="5">P5</option>
            </select>
            <button class="control-btn" onClick=${()=>{id()}} disabled=${H.value||tn.value.trim()===""}>
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
            ${n.length===0?o`<div class="ops-empty">No team sessions available.</div>`:n.map(c=>{var m;return o`
              <button
                key=${c.session_id}
                class="ops-entity-card ${(r==null?void 0:r.session_id)===c.session_id?"active":""}"
                onClick=${()=>{ga.value=c.session_id}}
              >
                <div class="ops-entity-title-row">
                  <strong>${c.session_id}</strong>
                  <span class="status-badge ${c.status??"idle"}">${c.status??"unknown"}</span>
                </div>
                <div class="ops-entity-meta">
                  <span>${Math.round(c.progress_pct??0)}%</span>
                  <span>${c.done_delta_total??0} done</span>
                  <span>${(m=c.team_health)!=null&&m.status?String(c.team_health.status):"health n/a"}</span>
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
                <pre class="ops-code-block compact">${so(r.recent_events.slice(-3))}</pre>
              `:null}
            </div>
          `:null}

          <label class="control-label" for="ops-turn-kind">Session Action</label>
          <div class="control-row ops-split-row">
            <select
              id="ops-turn-kind"
              class="control-input ops-select"
              value=${Ce.value}
              onChange=${c=>{Ce.value=c.target.value}}
              disabled=${H.value||!r}
            >
              <option value="note">Note</option>
              <option value="broadcast">Broadcast</option>
              <option value="task">Task</option>
              <option value="checkpoint">Checkpoint</option>
            </select>
            <button class="control-btn" onClick=${()=>{od()}} disabled=${H.value||!r}>
              Apply
            </button>
          </div>
          <textarea
            class="control-textarea"
            rows=${3}
            placeholder="Session message"
            value=${ha.value}
            onInput=${c=>{ha.value=c.target.value}}
            disabled=${H.value||!r}
          ></textarea>
          ${Ce.value==="task"?o`
            <input
              class="control-input"
              type="text"
              placeholder="Injected task title"
              value=${$a.value}
              onInput=${c=>{$a.value=c.target.value}}
              disabled=${H.value||!r}
            />
            <textarea
              class="control-textarea"
              rows=${2}
              placeholder="Injected task description"
              value=${ya.value}
              onInput=${c=>{ya.value=c.target.value}}
              disabled=${H.value||!r}
            ></textarea>
            <select
              class="control-input ops-select"
              value=${Us.value}
              onChange=${c=>{Us.value=c.target.value}}
              disabled=${H.value||!r}
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
              value=${Bs.value}
              onInput=${c=>{Bs.value=c.target.value}}
              disabled=${H.value||!r}
            />
            <button class="control-btn ghost" onClick=${()=>{rd()}} disabled=${H.value||!r}>
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
                onClick=${()=>{Ws.value=c.name}}
              >
                <div class="ops-entity-title-row">
                  <strong>${c.name}</strong>
                  <span class="status-badge ${c.status??"idle"}">${c.status??"unknown"}</span>
                </div>
                <div class="ops-entity-meta">
                  <span>${c.model??"model n/a"}</span>
                  <span>${typeof c.context_ratio=="number"?`${Math.round(c.context_ratio*100)}% ctx`:"ctx n/a"}</span>
                  <span>${ed(c.last_turn_ago_s)}</span>
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
            value=${en.value}
            onInput=${c=>{en.value=c.target.value}}
            disabled=${H.value||!u}
          ></textarea>
          <div class="control-row">
            <button class="control-btn" onClick=${()=>{ld()}} disabled=${H.value||!u||en.value.trim()===""}>
              Send Keeper Message
            </button>
          </div>
        </section>
      </div>

      <section class="card ops-log-panel">
        <div class="card-title">Recent Operator Actions</div>
        <div class="ops-log-list">
          ${ma.value.length===0?o`
            <div class="ops-empty">No operator actions in this session yet.</div>
          `:ma.value.map(c=>o`
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
  `}const Gs=_([]),Js=_([]),nn=_(""),ka=_(!1),an=_(!1),kn=_(""),xa=_(null),ft=_(null),Vs=_(!1);async function Qs(){ka.value=!0,kn.value="";try{const[t,e]=await Promise.all([yc(),bc()]);Gs.value=t,Js.value=e}catch(t){kn.value=t instanceof Error?t.message:"Failed to load council data"}finally{ka.value=!1}}async function ro(){const t=nn.value.trim();if(t){an.value=!0;try{const e=await kc(t);nn.value="",b(e!=null&&e.id?`Debate started: ${e.id}`:"Debate started","success"),await Qs()}catch(e){const n=e instanceof Error?e.message:"Failed to start debate";b(n,"error")}finally{an.value=!1}}}async function dd(t){xa.value=t,Vs.value=!0,ft.value=null;try{ft.value=await xc(t)}catch(e){kn.value=e instanceof Error?e.message:"Failed to load debate status",ft.value=null}finally{Vs.value=!1}}function pd({debate:t}){const e=xa.value===t.id;return o`
    <button
      class="council-row ${e?"selected":""}"
      onClick=${()=>dd(t.id)}
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
  `}function vd({session:t}){return o`
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
  `}function md(){var e;const t=(e=ee.value)==null?void 0:e.data_quality;return!t||t.council_feed_ok!==!1&&!t.last_sync_at?null:o`
    <div class="feed-health-banner ${t.council_feed_ok===!1?"degraded":"ok"}">
      <span class="feed-health-title">
        ${t.council_feed_ok===!1?"Council feed degraded":"Council feed synced"}
      </span>
      ${t.last_sync_at?o`<span class="feed-health-meta">Last sync: <${q} timestamp=${t.last_sync_at} /></span>`:o`<span class="feed-health-meta">No sync timestamp</span>`}
    </div>
  `}function fd(){var e,n;Rt(()=>{Qs()},[]);const t=((n=(e=ee.value)==null?void 0:e.data_quality)==null?void 0:n.council_feed_ok)===!1;return o`
    <div>
      <${md} />
      <${x} title="Council Command" class="section">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${nn.value}
            onInput=${a=>{nn.value=a.target.value}}
            onKeyDown=${a=>{a.key==="Enter"&&ro()}}
            disabled=${an.value}
          />
          <button
            class="control-btn secondary"
            onClick=${ro}
            disabled=${an.value||nn.value.trim()===""}
          >
            ${an.value?"Starting...":"Start Debate"}
          </button>
          <button class="control-btn ghost" onClick=${Qs} disabled=${ka.value}>
            ${ka.value?"Refreshing...":"Refresh"}
          </button>
        </div>
        ${kn.value?o`<div class="council-error">${kn.value}</div>`:null}
      <//>

      <div class="council-grid">
        <${x} title="Debates" class="section">
          <div class="council-list">
            ${Gs.value.length===0?o`
                  <div class="empty-state">
                    ${t?"No debates loaded (council feed degraded).":"No debates yet"}
                  </div>
                `:Gs.value.map(a=>o`<${pd} key=${a.id} debate=${a} />`)}
          </div>
        <//>

        <${x} title="Voting Sessions" class="section">
          <div class="council-list">
            ${Js.value.length===0?o`
                  <div class="empty-state">
                    ${t?"No sessions loaded (council feed degraded).":"No active sessions"}
                  </div>
                `:Js.value.map(a=>o`<${vd} key=${a.id} session=${a} />`)}
          </div>
        <//>
      </div>

      <${x} title=${xa.value?`Debate Detail (${xa.value})`:"Debate Detail"} class="section">
        ${Vs.value?o`<div class="loading-indicator">Loading debate detail...</div>`:ft.value?o`
                <div class="council-sub" style="margin-bottom: 8px;">
                  <span>Status: ${ft.value.status}</span>
                  <span>Total arguments: ${ft.value.total_arguments}</span>
                </div>
                <div class="council-sub" style="margin-bottom: 8px;">
                  <span>Support: ${ft.value.support_count}</span>
                  <span>Oppose: ${ft.value.oppose_count}</span>
                  <span>Neutral: ${ft.value.neutral_count}</span>
                </div>
                ${ft.value.summary_text?o`<pre class="council-detail">${ft.value.summary_text}</pre>`:null}
              `:o`<div class="empty-state">Select a debate to view summary</div>`}
      <//>
    </div>
  `}function _d({text:t}){if(!t)return null;const e=gd(t);return o`<div class="markdown-content">${e}</div>`}function gd(t){const e=t.split(`
`),n=[];let a=0;for(;a<e.length;){const s=e[a];if(/^(`{3,}|~{3,})/.test(s)){const r=s.match(/^(`{3,}|~{3,})/)[0],u=s.slice(r.length).trim(),d=[];for(a++;a<e.length&&!e[a].startsWith(r);)d.push(e[a]),a++;a++,n.push(o`<pre><code class=${u?`language-${u}`:""}>${d.join(`
`)}</code></pre>`);continue}if(s.trim()==="<think>"||s.trim().startsWith("<think>")){const r=[],u=s.trim().replace(/^<think>/,"").trim();for(u&&u!=="</think>"&&r.push(u),a++;a<e.length&&!e[a].includes("</think>");)r.push(e[a]),a++;if(a<e.length){const p=e[a].replace("</think>","").trim();p&&r.push(p),a++}const d=r.join(`
`).trim();n.push(o`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${Xa(d)}</div>
        </details>
      `);continue}if(s.startsWith("> ")){const r=[];for(;a<e.length&&e[a].startsWith("> ");)r.push(e[a].slice(2)),a++;n.push(o`<blockquote>${Xa(r.join(`
`))}</blockquote>`);continue}if(s.trim()===""){a++;continue}const i=[];for(;a<e.length;){const r=e[a];if(r.trim()===""||/^(`{3,}|~{3,})/.test(r)||r.startsWith("> ")||r.trim().startsWith("<think>"))break;i.push(r),a++}i.length>0&&n.push(o`<p>${Xa(i.join(`
`))}</p>`)}return n}function Xa(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let a=0,s;for(;(s=n.exec(t))!==null;){if(s.index>a&&e.push(t.slice(a,s.index)),s[1]){const i=s[1].slice(1,-1);e.push(o`<code>${i}</code>`)}else if(s[2]){const i=s[2].slice(2,-2);e.push(o`<strong>${i}</strong>`)}else if(s[3]){const i=s[3].slice(1,-1);e.push(o`<em>${i}</em>`)}else s[4]&&s[5]&&e.push(o`<a href=${s[5]} target="_blank" rel="noopener">${s[4]}</a>`);a=s.index+s[0].length}return a<t.length&&e.push(t.slice(a)),e.length>0?e:[t]}const Cr=[{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"recent",label:"Recent"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],Zn=_(null),sn=_([]),le=_(!1),re=_(null),on=_("");function hd(){var e,n;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}const $d=_(hd()),rn=_(!1);async function gi(t){re.value=t,Zn.value=null,sn.value=[],le.value=!0;try{const e=await Bl(t);if(re.value!==t)return;Zn.value={id:e.id,author:e.author,title:e.title,content:e.content,tags:e.tags,votes:e.votes,vote_balance:e.vote_balance,comment_count:e.comment_count,created_at:e.created_at,updated_at:e.updated_at,flair:e.flair,hearth_count:e.hearth_count},sn.value=e.comments??[]}catch{re.value===t&&(Zn.value=null,sn.value=[])}finally{re.value===t&&(le.value=!1)}}async function lo(t){const e=on.value.trim();if(e){rn.value=!0;try{await Wl(t,$d.value,e),on.value="",b("Comment posted","success"),await gi(t),Ct()}catch{b("Failed to post comment","error")}finally{rn.value=!1}}}function yd(){const t=_n.value;return o`
    <div class="board-toolbar">
      <div class="board-controls">
        ${Cr.map(e=>o`
          <button
            class="board-sort-btn ${t===e.id?"active":""}"
            onClick=${()=>{_n.value=e.id,Ct()}}
          >
            ${e.label}
          </button>
        `)}
      </div>
      <div class="board-toolbar-actions">
        <button
          class="control-btn ghost ${ie.value?"is-active":""}"
          onClick=${()=>{ie.value=!ie.value,Ct()}}
        >
          ${ie.value?"Hiding auto reports":"Show auto reports"}
        </button>
        <button class="control-btn ghost" onClick=${Ct} disabled=${hn.value}>
          ${hn.value?"Refreshing...":"Refresh"}
        </button>
      </div>
    </div>
  `}function Za(){var e;const t=(e=ee.value)==null?void 0:e.data_quality;return!t||t.board_contract_ok!==!1&&!t.last_sync_at?null:o`
    <div class="feed-health-banner ${t.board_contract_ok===!1?"degraded":"ok"}">
      <span class="feed-health-title">
        ${t.board_contract_ok===!1?"Board feed degraded":"Board feed synced"}
      </span>
      ${t.last_sync_at?o`<span class="feed-health-meta">Last sync: <${q} timestamp=${t.last_sync_at} /></span>`:o`<span class="feed-health-meta">No sync timestamp</span>`}
    </div>
  `}function Rr({flair:t}){return t?o`<span class="post-flair ${t}">${t}</span>`:null}function bd(t){const e=t.replace(/!\[[^\]]*\]\([^)]+\)/g," ").replace(/\[[^\]]+\]\([^)]+\)/g,"$1").replace(/[`#>*_~-]/g," ").replace(/\s+/g," ").trim();return e?e.length>180?`${e.slice(0,177)}...`:e:"No preview available"}function co(t){return t.updated_at!==t.created_at}function ts(){var n;const t=((n=Cr.find(a=>a.id===_n.value))==null?void 0:n.label)??_n.value,e=Ft.value.length;return o`
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
        <strong>${ie.value?"Auto reports hidden by default":"All posts visible"}</strong>
      </div>
      <div class="board-summary-item">
        <span class="board-summary-label">Last refresh</span>
        <strong>${zs.value?o`<${q} timestamp=${zs.value} />`:"Not loaded"}</strong>
      </div>
    </div>
  `}function kd({post:t}){const e=async(n,a)=>{a.stopPropagation();try{await lr(t.id,n),Ct()}catch{b("Failed to vote","error")}};return o`
    <div class="board-post" onClick=${()=>gl(t.id)}>
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
              <${Rr} flair=${t.flair} />
              ${co(t)?o`<span class="board-meta-chip">Updated</span>`:null}
            </div>
          </div>
          <div class="post-meta">
            <span>By ${t.author}</span>
            <span><${q} timestamp=${t.created_at} /></span>
            ${co(t)?o`<span>Updated <${q} timestamp=${t.updated_at} /></span>`:null}
            <span>${t.comment_count} comments</span>
            <span>${t.votes??0} votes</span>
            ${(t.hearth_count??0)>0?o`<span>♥ ${t.hearth_count}</span>`:null}
          </div>
        </div>
        <div class="post-snippet">${bd(t.content)}</div>
      </div>
    </div>
  `}function xd({comments:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No comments yet</div>`:o`
    <div class="comment-thread">
      ${t.map(e=>o`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${q} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function wd({postId:t}){return o`
    <div class="comment-form" style="margin-top: 12px; display: flex; gap: 8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${on.value}
        onInput=${e=>{on.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&lo(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${rn.value}
      />
      <button
        onClick=${()=>lo(t)}
        disabled=${rn.value||on.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${rn.value?"...":"Post"}
      </button>
    </div>
  `}function Sd({post:t}){re.value!==t.id&&!le.value&&gi(t.id);const e=async n=>{try{await lr(t.id,n),Ct()}catch{b("Failed to vote","error")}};return o`
    <div>
      <button class="back-btn" onClick=${()=>_t("board")}>← Back to Board</button>
      <${x} title=${o`${t.title} <${Rr} flair=${t.flair} />`}>
        <div class="board-detail">
          <div class="post-body">
            <${_d} text=${t.content} />
          </div>
          <div class="post-meta" style="margin-top: 12px;">
            <span>${t.author}</span>
            <${q} timestamp=${t.created_at} />
            <span>${t.votes??0} votes</span>
            ${(t.hearth_count??0)>0?o`<span>♥ ${t.hearth_count}</span>`:null}
          </div>
          <div style="margin-top: 8px; display: flex; gap: 6px;">
            <button class="vote-btn upvote" onClick=${()=>e("up")}>▲ Upvote</button>
            <button class="vote-btn downvote" onClick=${()=>e("down")}>▼ Downvote</button>
          </div>
        </div>
      <//>

      <${x} title="Comments (${le.value?"...":sn.value.length})">
        ${le.value?o`<div class="loading-indicator">Loading comments...</div>`:o`<${xd} comments=${sn.value} />`}
        <${wd} postId=${t.id} />
      <//>
    </div>
  `}function Ad(){var s,i;const t=Ft.value,e=hn.value,n=Nt.value.postId,a=((i=(s=ee.value)==null?void 0:s.data_quality)==null?void 0:i.board_contract_ok)===!1;if(n){const r=t.find(u=>u.id===n)??(re.value===n?Zn.value:null);return!r&&re.value!==n&&!le.value&&gi(n),r?o`
          <${Za} />
          <${ts} />
          <${Sd} post=${r} />
        `:o`
          <div>
            <${Za} />
            <${ts} />
            <button class="back-btn" onClick=${()=>_t("board")}>← Back to Board</button>
            ${le.value?o`<div class="loading-indicator">Loading post...</div>`:o`
                  <div class="empty-state">
                    ${a?"Post not available while board feed is degraded":"Post not found"}
                  </div>
                `}
          </div>
        `}return o`
    <${Za} />
    <${ts} />
    <${yd} />
    ${e?o`<div class="loading-indicator">Loading board...</div>`:t.length===0?o`
            <div class="empty-state">
              ${a?"No posts loaded (board feed degraded). Check board contract sync.":ie.value?"No visible posts right now. Automated reports may be hidden; toggle them back on if you need the raw feed.":"No posts yet"}
            </div>
          `:o`<div class="board-post-list">
            ${t.map(r=>o`<${kd} key=${r.id} post=${r} />`)}
          </div>`}
  `}function Td(t){if(t.kind)return t.kind;switch(t.eventType){case"board_post":case"board_comment":return"board";case"task_update":return"tasks";case"keeper_heartbeat":case"keeper_handoff":case"keeper_compaction":case"keeper_guardrail":return"keepers";default:return"system"}}function Nd(t){var e,n;return((e=t.author)==null?void 0:e.trim())||((n=t.agent)==null?void 0:n.trim())||"system"}function Cd(t){switch(t.eventType){case"board_post":return t.preview?`Post: ${t.preview}`:t.text||"New post";case"board_comment":return t.preview?`Comment: ${t.preview}`:t.text||"New comment";default:return t.text}}const Lr=120,Rd=12,Ld=16,Dd=12,Ys=_("all"),Ed={all:"All",messages:"Messages",board:"Board",tasks:"Tasks",keepers:"Keepers",system:"System"},Pd={messages:"MSG",board:"BOARD",tasks:"TASK",keepers:"KEEPER",system:"SYS"};function Id(t,e){return{id:t.id??`msg-${t.seq??e}`,source:"message",kind:"messages",actor:t.from??"system",content:t.content,timestamp:t.timestamp}}function Md(t,e){return{id:t.postId?`evt-${t.eventType??"event"}-${t.postId}-${e}`:`evt-${t.timestamp}-${e}`,source:"event",kind:Td(t),actor:Nd(t),content:Cd(t),timestamp:new Date(t.timestamp).toISOString()}}function Od(t,e){var s;const n=(s=t.assignee)==null?void 0:s.trim(),a=t.updated_at??t.created_at;return!n||!a?null:{id:`task-${t.id}-${e}`,source:"snapshot",kind:"tasks",actor:n,content:`Task: ${t.title} (${t.status})`,timestamp:a}}function Fd(t,e){return{id:`board-${t.id}-${e}`,source:"snapshot",kind:"board",actor:t.author,content:`Post: ${t.title||t.content}`,timestamp:t.updated_at||t.created_at}}function qn(t){return typeof t!="number"||!Number.isFinite(t)||t<0?null:new Date(Date.now()-t*1e3).toISOString()}function Xs(t){return t.last_heartbeat??qn(t.last_turn_ago_s)??qn(t.last_proactive_ago_s)??qn(t.last_handoff_ago_s)??qn(t.last_compaction_ago_s)}function jd(t,e){const n=Xs(t);if(!n)return null;const a=typeof t.context_ratio=="number"&&Number.isFinite(t.context_ratio)?`${Math.round(t.context_ratio*100)}%`:"?";return{id:`keeper-${t.name}-${e}`,source:"snapshot",kind:"keepers",actor:t.name,content:t.last_heartbeat?`Heartbeat gen=${t.generation??"?"} ctx=${a}`:`Keeper snapshot gen=${t.generation??"?"} ctx=${a}`,timestamp:n}}function wt(t){const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}const Zs=ct(()=>{const t=ue.value.map(Id),e=Xt.value.map(Md),n=[...Lt.value].sort((i,r)=>wt(r.updated_at??r.created_at??0)-wt(i.updated_at??i.created_at??0)).slice(0,Rd).map(Od).filter(i=>i!==null),a=[...Ft.value].sort((i,r)=>wt(r.updated_at||r.created_at)-wt(i.updated_at||i.created_at)).slice(0,Ld).map(Fd),s=[...$t.value].sort((i,r)=>wt(Xs(r)??0)-wt(Xs(i)??0)).slice(0,Dd).map(jd).filter(i=>i!==null);return[...t,...e,...n,...a,...s].sort((i,r)=>wt(r.timestamp)-wt(i.timestamp))}),qd=ct(()=>{const t=Zs.value;return{total:t.length,messages:t.filter(e=>e.kind==="messages").length,board:t.filter(e=>e.kind==="board").length,tasks:t.filter(e=>e.kind==="tasks").length,keepers:t.filter(e=>e.kind==="keepers").length,system:t.filter(e=>e.kind==="system").length}}),zd=ct(()=>{const t=Ys.value;return(t==="all"?Zs.value:Zs.value.filter(n=>n.kind===t)).slice(0,Lr)}),Hd=ct(()=>te.value.map(t=>({agent:t,motion:$n(t.name,Lt.value,ue.value,Xt.value,{currentTask:t.current_task,lastSeen:t.last_seen,boardPosts:Ft.value,keepers:$t.value})})).sort((t,e)=>{const n=e.motion.activeAssignedCount-t.motion.activeAssignedCount;return n!==0?n:wt(e.motion.lastActivityAt??0)-wt(t.motion.lastActivityAt??0)}));function Kd(t){const e=new Date(t);return Number.isNaN(e.getTime())?"00:00:00":e.toLocaleTimeString("en-US",{hour12:!1})}function ze({label:t,value:e,color:n}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
    </div>
  `}function Ud({row:t}){return o`
    <div class="term-row activity-row ${t.kind}">
      <span class="term-time">${Kd(t.timestamp)}</span>
      <span class="activity-kind-badge ${t.kind}">${Pd[t.kind]}</span>
      <span class="term-actor">${t.actor}</span>
      <span class="term-text">${t.content}</span>
    </div>
  `}function Bd(){const t=qd.value,e=zd.value,n=e[0],a=Hd.value;return o`
    <div class="stats-grid">
      <${ze} label="Visible rows" value=${e.length} />
      <${ze} label="Tracked messages" value=${t.messages} color="#47b8ff" />
      <${ze} label="Keeper signals" value=${t.keepers} color="#4ade80" />
      <${ze} label="Board signals" value=${t.board} color="#fbbf24" />
      <${ze} label="SSE events" value=${Tn.value} color="#c084fc" />
    </div>

    <${x} title="Unified Activity" class="section">
      <div class="activity-toolbar">
        <div class="activity-filter-row">
          ${["all","messages","board","tasks","keepers","system"].map(s=>o`
            <button
              class="goal-filter-btn ${Ys.value===s?"active":""}"
              onClick=${()=>{Ys.value=s}}
            >
              ${Ed[s]}
            </button>
          `)}
        </div>
        <div class="activity-toolbar-meta">
          <span class="pill ${It.value?"":"pill-stale"}">
            ${It.value?"Live SSE":"Reconnecting"}
          </span>
          <span>${n?o`Latest: <${q} timestamp=${n.timestamp} />`:"Latest: —"}</span>
          <span>Showing up to ${Lr} rows</span>
          <span>Live events + current snapshot merged here</span>
        </div>
      </div>

      <div class="terminal-feed">
        ${e.length===0?o`<div class="empty-state">Waiting for live or snapshot signals...</div>`:e.map(s=>o`<${Ud} key=${s.id} row=${s} />`)}
      </div>
    <//>

    <${x} title="Agent Motion" class="section">
      <div class="activity-motion-list">
        ${a.length===0?o`<div class="empty-state">No active agents</div>`:a.map(({agent:s,motion:i})=>o`
              <div class="activity-motion-row">
                <div>
                  <div class="activity-motion-agent">${s.name}</div>
                  <div class="activity-motion-meta">
                    ${i.activeAssignedCount>0?`${i.activeAssignedCount} claimed tasks`:"No claimed tasks"}
                    ${i.lastActivityAt?o` · <${q} timestamp=${i.lastActivityAt} />`:null}
                  </div>
                </div>
                <div class="activity-motion-text">${i.lastActivityText??"No recent message/event signal"}</div>
              </div>
            `)}
      </div>
    <//>
  `}function Dr({ratio:t,size:e=40,stroke:n=4}){if(t==null)return null;const a=(e-n)/2,s=e/2,i=2*Math.PI*a,r=i*((100-t*100)/100);let u="mitosis-safe";return t>=.8?u="mitosis-critical":t>=.5&&(u="mitosis-warn"),o`
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
  `}const es=600*1e3,Wd=1200*1e3,uo=.8;function Gt(t){if(t==null)return 0;const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function ge(t){switch(t){case"bad":return 2;case"warn":return 1;default:return 0}}function Gd(t){switch(t){case"working":return"Working";case"watching":return"Watching";case"quiet":return"Quiet";case"offline":return"Offline"}}function Jd(t){switch(t){case"critical":return"Critical";case"warning":return"Watch";default:return"Healthy"}}function Vd(t){return typeof t!="number"||Number.isNaN(t)?"—":`${Math.round(t*100)}%`}function Qd(t){var e;return((e=t.agent)==null?void 0:e.current_task)??t.skill_primary??t.last_proactive_reason??t.memory_recent_note??"No active focus"}function Yd(t){const e=[`Gen ${t.generation??"—"}`,`Turns ${t.turn_count??0}`,`Handoffs ${t.handoff_count_total??0}`];return(t.compaction_count??0)>0&&e.push(`Compactions ${t.compaction_count}`),e.join(" · ")}function Xd(t){var d,p;const e=$n(t.name,Lt.value,ue.value,Xt.value,{currentTask:t.current_task,lastSeen:t.last_seen,boardPosts:Ft.value,keepers:$t.value}),n=e.lastActivityAt??t.last_seen??null,a=n?Math.max(0,Date.now()-Gt(n)):Number.POSITIVE_INFINITY,s=!!((d=t.current_task)!=null&&d.trim())||e.activeAssignedCount>0;let i="watching",r="ok",u="Healthy live signal";return t.status==="offline"||t.status==="inactive"?(i="offline",r="bad",u=n?"Offline or inactive":"No recent presence"):a>Wd?(i="quiet",r="bad",u=s?"Working without a fresh signal":"No fresh agent signal"):s?(i="working",r=a>es?"warn":"ok",u=a>es?"Execution looks quiet for too long":"Task and live signal aligned"):a>es?(i="quiet",r="warn",u="Quiet but still reachable"):t.status==="idle"&&(i="watching",r="ok",u="Standing by for the next task"),{agent:t,motion:e,lastSignalAt:n,activeTaskCount:e.activeAssignedCount,state:i,tone:r,focus:((p=t.current_task)==null?void 0:p.trim())||(e.activeAssignedCount>0?`${e.activeAssignedCount} claimed tasks waiting for explicit current_task`:e.lastActivityText??"Idle / waiting for assignment"),note:u}}function Zd(t){const e=_r.value.get(t.name)??"idle",n=gr.value.has(t.name),a=t.context_ratio??0;let s="healthy",i="ok",r="Heartbeat and context look healthy";return t.status==="offline"||n||e==="handoff-imminent"?(s="critical",i="bad",r=n?"Heartbeat stale":e==="handoff-imminent"?"Handoff imminent":"Keeper offline"):(e==="preparing"||e==="compacting"||a>=uo)&&(s="warning",i="warn",r=a>=uo?"High context pressure":e==="compacting"?"Compaction in progress":"Preparing for handoff"),{keeper:t,lifecycle:e,state:s,tone:i,focus:Qd(t),note:r}}function He({label:t,value:e,color:n,caption:a}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
      ${a?o`<div class="monitor-stat-caption">${a}</div>`:null}
    </div>
  `}function tp({item:t}){const e=t.kind==="agent"?()=>Ne(t.agent.name):()=>ua(t.keeper);return o`
    <button class="monitor-alert ${t.tone}" onClick=${e}>
      <div class="monitor-alert-main">
        <div class="monitor-alert-title">${t.title}</div>
        <div class="monitor-alert-subtitle">${t.subtitle}</div>
      </div>
      <div class="monitor-alert-meta">
        <span class="monitor-pill ${t.tone}">
          ${t.kind==="agent"?"Agent":"Keeper"}
        </span>
        ${t.timestamp?o`<span><${q} timestamp=${t.timestamp} /></span>`:o`<span>No signal</span>`}
      </div>
    </button>
  `}function ep({row:t}){const{agent:e,motion:n}=t;return o`
    <button class="monitor-row ${t.tone}" onClick=${()=>Ne(e.name)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?o`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${Dr} ratio=${e.context_ratio} size=${34} stroke=${4} />
        <${yt} status=${e.status} />
        <span class="monitor-pill ${t.tone}">${Gd(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${t.lastSignalAt?o`<span>Signal <${q} timestamp=${t.lastSignalAt} /></span>`:o`<span>No recent signal</span>`}
        <span>${t.activeTaskCount>0?`${t.activeTaskCount} active tasks`:"No active tasks"}</span>
        ${e.model?o`<span>${e.model}</span>`:null}
        ${e.last_seen?o`<span>Seen <${q} timestamp=${e.last_seen} /></span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${n.lastActivityText&&n.lastActivityText!==t.focus?o`<div class="monitor-footnote">Latest detail: ${n.lastActivityText}</div>`:null}
    </button>
  `}function np({row:t}){const{keeper:e}=t;return o`
    <button class="monitor-row ${t.tone}" onClick=${()=>ua(e)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?o`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${Dr} ratio=${e.context_ratio} size=${34} stroke=${4} />
        <${yt} status=${e.status} />
        <span class="monitor-pill ${t.tone}">${Jd(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${e.last_heartbeat?o`<span>Heartbeat <${q} timestamp=${e.last_heartbeat} /></span>`:o`<span>No heartbeat</span>`}
        <span>${Yd(e)}</span>
        <span>Lifecycle ${t.lifecycle}</span>
        <span>Context ${Vd(e.context_ratio)}</span>
        ${e.model?o`<span>${e.model}</span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${e.skill_reason?o`<div class="monitor-footnote">Skill route: ${e.skill_reason}</div>`:null}
    </button>
  `}function ap(){const t=[...te.value].map(Xd).sort((d,p)=>{const f=ge(p.tone)-ge(d.tone);if(f!==0)return f;const l=p.activeTaskCount-d.activeTaskCount;return l!==0?l:Gt(p.lastSignalAt)-Gt(d.lastSignalAt)}),e=[...$t.value].map(Zd).sort((d,p)=>{const f=ge(p.tone)-ge(d.tone);if(f!==0)return f;const l=(p.keeper.context_ratio??0)-(d.keeper.context_ratio??0);return l!==0?l:Gt(p.keeper.last_heartbeat)-Gt(d.keeper.last_heartbeat)}),n=t.filter(d=>d.state!=="offline").length,a=t.filter(d=>d.state==="working").length,s=t.filter(d=>d.lastSignalAt&&Date.now()-Gt(d.lastSignalAt)<=12e4).length,i=t.filter(d=>d.tone!=="ok"),r=e.filter(d=>d.tone!=="ok"),u=[...r.map(d=>({kind:"keeper",key:`keeper-${d.keeper.name}`,tone:d.tone,title:d.keeper.name,subtitle:`${d.note} · ${d.focus}`,timestamp:d.keeper.last_heartbeat??null,keeper:d.keeper})),...i.map(d=>({kind:"agent",key:`agent-${d.agent.name}`,tone:d.tone,title:d.agent.name,subtitle:`${d.note} · ${d.focus}`,timestamp:d.lastSignalAt,agent:d.agent}))].sort((d,p)=>{const f=ge(p.tone)-ge(d.tone);return f!==0?f:Gt(p.timestamp)-Gt(d.timestamp)}).slice(0,8);return o`
    <div class="agents-monitor">
      <div class="stats-grid">
        <${He} label="Agents online" value=${n} color="#4ade80" caption="active + idle" />
        <${He} label="Working now" value=${a} color="#fbbf24" caption="task or claimed load" />
        <${He} label="Fresh signals" value=${s} color="#22d3ee" caption="within last 2 minutes" />
        <${He} label="Agent alerts" value=${i.length} color=${i.length>0?"#fb7185":"#4ade80"} caption="quiet or offline" />
        <${He} label="Keeper alerts" value=${r.length} color=${r.length>0?"#fb7185":"#4ade80"} caption="stale or high pressure" />
      </div>

      <${x} title="Attention Queue" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Who needs intervention right now</h2>
          <p class="monitor-subheadline">Rows are sorted by severity first, then by the freshest signal we have.</p>
        </div>
        <div class="monitor-alert-list">
          ${u.length===0?o`<div class="empty-state">No agent or keeper alerts right now</div>`:u.map(d=>o`<${tp} key=${d.key} item=${d} />`)}
        </div>
      <//>

      <div class="grid-2col">
        <${x} title="Keeper Watch" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Long-running keeper health</h2>
            <p class="monitor-subheadline">Heartbeat, context pressure, and continuity state in one list.</p>
          </div>
          <div class="monitor-list">
            ${e.length===0?o`<div class="empty-state">No keepers active</div>`:e.map(d=>o`<${np} key=${d.keeper.name} row=${d} />`)}
          </div>
        <//>

        <${x} title="Agent Watch" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Short-horizon execution monitor</h2>
            <p class="monitor-subheadline">Current task, recent signal, and quiet drift are surfaced together.</p>
          </div>
          <div class="monitor-list">
            ${t.length===0?o`<div class="empty-state">No agents registered</div>`:t.map(d=>o`<${ep} key=${d.agent.name} row=${d} />`)}
          </div>
        <//>
      </div>
    </div>
  `}function ns({task:t}){const e=(t.priority??4)<=1?"p1":(t.priority??4)===2?"p2":(t.priority??4)===3?"p3":"p4";return o`
    <div class="kanban-card ${e}">
      <div class="kanban-card-title">${t.title}</div>
      <div class="kanban-card-meta">
        ${t.created_at?o`<${q} timestamp=${t.created_at} />`:o`<span>-</span>`}
        ${t.assignee?o`<span class="kanban-assignee">${t.assignee}</span>`:null}
      </div>
    </div>
  `}function sp(){const{todo:t,inProgress:e,done:n}=fr.value;return o`
    <div class="kanban-board">
      <!-- TODO Column -->
      <div class="kanban-column">
        <div class="kanban-header todo">
          <span>TO DO</span>
          <span class="kanban-badge">${t.length}</span>
        </div>
        ${t.length===0?o`<div class="empty-state" style="opacity: 0.5;">No pending tasks</div>`:t.map(a=>o`<${ns} key=${a.id} task=${a} />`)}
      </div>

      <!-- IN PROGRESS Column -->
      <div class="kanban-column">
        <div class="kanban-header inprogress">
          <span>IN PROGRESS</span>
          <span class="kanban-badge">${e.length}</span>
        </div>
        ${e.length===0?o`<div class="empty-state" style="opacity: 0.5;">No active tasks</div>`:e.map(a=>o`<${ns} key=${a.id} task=${a} />`)}
      </div>

      <!-- DONE Column -->
      <div class="kanban-column">
        <div class="kanban-header done">
          <span>DONE</span>
          <span class="kanban-badge">${n.length}</span>
        </div>
        ${n.length===0?o`<div class="empty-state" style="opacity: 0.5;">No completed tasks</div>`:n.slice(0,20).map(a=>o`<${ns} key=${a.id} task=${a} />`)}
        ${n.length>20?o`<div class="empty-state" style="opacity: 0.5;">...and ${n.length-20} more</div>`:null}
      </div>
    </div>
  `}const wa=600*1e3,ta=1200*1e3;function Fa(t){return(t??"").trim().toLowerCase()}function St(t){if(t==null)return 0;const e=typeof t=="number"?t:Date.parse(t);return Number.isNaN(e)?0:e}function ce(t,e=96){const n=(t??"").replace(/\s+/g," ").trim();return n?n.length>e?`${n.slice(0,e-3)}...`:n:null}function Wt(t){switch(t){case"bad":return 2;case"warn":return 1;default:return 0}}function xn(t){return typeof t!="number"||Number.isNaN(t)?3:t}function Er(t){const e=xn(t);return e<=1?"P1":e===2?"P2":e>=4?"P4+":"P3"}function Pr(t){switch(t){case"in_progress":return"In Progress";case"claimed":return"Claimed";case"done":return"Done";case"cancelled":return"Cancelled";default:return"Todo"}}function Ir(t){switch(t){case"dispatchable":return"Dispatch";case"drift":return"Drift";case"quiet":return"Quiet";case"offline":return"Offline";default:return"Loaded"}}function ip(t){return t.updated_at??t.created_at??null}function op(t){const e=new Map;for(const n of t)e.set(Fa(n.name),$n(n.name,Lt.value,ue.value,Xt.value,{currentTask:n.current_task,lastSeen:n.last_seen,boardPosts:Ft.value,keepers:$t.value}));return e}function po(t,e,n){var w,C;const a=Fa(t.assignee),s=a?e.get(a)??null:null,i=s?n.get(a)??null:null,r=(i==null?void 0:i.lastActivityAt)??(s==null?void 0:s.last_seen)??null,u=r?Math.max(0,Date.now()-St(r)):Number.POSITIVE_INFINITY,d=ce(t.description),p=ce(s==null?void 0:s.current_task)??(i==null?void 0:i.lastActivityText)??null,f=t.status==="claimed"||t.status==="in_progress";let l="ok",c="Fresh owner coverage",m=p??d??t.id,h=!1,y=!1;return t.status==="todo"?t.assignee?s?s.status==="offline"||s.status==="inactive"?(h=!0,l="bad",c="Assigned owner is offline",m="Queue item is blocked until ownership changes."):u>wa?(l="warn",c="Owner exists but live signal is quiet",m=p??"Owner may need a nudge before pickup."):((i==null?void 0:i.activeAssignedCount)??0)>0||(w=s.current_task)!=null&&w.trim()?(l="warn",c="Owner is already carrying active work",m=p??`${(i==null?void 0:i.activeAssignedCount)??0} active tasks already assigned.`):(c="Ready and covered by a fresh operator",m=p??d??"This can be picked up immediately."):(h=!0,l="bad",c="Assigned owner is not present in the room",m="Reassign or bring the owner back online."):(h=!0,l=xn(t.priority)<=2?"bad":"warn",c=xn(t.priority)<=2?"Urgent ready work has no owner":"Ready work has no owner",m="Assign an agent before this queue item slips."):f&&(t.assignee?s?s.status==="offline"||s.status==="inactive"?(h=!0,l="bad",c="Assigned owner is offline",m=p??"Execution has no live operator right now."):u>ta?(y=!0,l="bad",c="Assigned owner has gone quiet",m=p??"Fresh operator signal is missing."):u>wa?(y=!0,l="warn",c="Execution has been quiet for too long",m=p??"Check whether this work is blocked."):(C=s.current_task)!=null&&C.trim()?(c="Execution has fresh owner coverage",m=p??d??t.id):(l="warn",c=t.status==="claimed"?"Claimed work is waiting for explicit focus":"Owner is live but current_task is empty",m=p??"Task state and agent focus are drifting apart."):(h=!0,l="bad",c="Assigned owner is not active in the room",m="Execution is orphaned until ownership is restored."):(h=!0,l="bad",c="Active work has no assignee",m="Claim or reassign this task immediately.")),{task:t,assigneeAgent:s,motion:i,tone:l,note:c,focus:m,lastSignalAt:r,lastTouchedAt:ip(t),ownerGap:h,quiet:y}}function rp(t,e){var c;const n=e.get(Fa(t.name))??{activeAssignedCount:0,lastActivityAt:null,lastActivityText:null},a=n.lastActivityAt??t.last_seen??null,s=a?Math.max(0,Date.now()-St(a)):Number.POSITIVE_INFINITY,i=!!((c=t.current_task)!=null&&c.trim()),r=n.activeAssignedCount,u=i||r>0;let d="loaded",p="ok",f="Healthy active load",l=ce(t.current_task)??n.lastActivityText??"Ready for assignment";return t.status==="offline"||t.status==="inactive"?(d="offline",p="bad",f="Agent is unavailable"):u&&s>ta?(d="quiet",p="bad",f="Working without a fresh signal"):r>0&&!i?(d="drift",p="warn",f="Claimed work exists but current_task is empty",l=`${r} active tasks need explicit focus.`):i&&r===0?(d="drift",p="warn",f="current_task has no matching claimed work",l=ce(t.current_task)??"Task metadata and operator state drifted."):!u&&s<=wa?(d="dispatchable",p="ok",f="Fresh signal and no active load",l=n.lastActivityText??"Ready for assignment."):u?s>wa&&(d="loaded",p="warn",f="Execution load is healthy but slightly quiet",l=ce(t.current_task)??`${r} active tasks in flight.`):(d="quiet",p=s>ta?"bad":"warn",f=s>ta?"No fresh signal while idle":"Reachable, but not freshly active",l=n.lastActivityText??"Likely available after a quick check-in."),{agent:t,motion:n,tone:p,state:d,note:f,focus:l,lastSignalAt:a,activeTaskCount:r}}function Ke({label:t,value:e,color:n,caption:a}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color:${n}`:""}>${e}</div>
      ${a?o`<div class="monitor-stat-caption">${a}</div>`:null}
    </div>
  `}function lp({item:t}){return o`
    <div class="execution-alert ${t.tone}">
      <div class="monitor-alert-main">
        <div class="monitor-alert-title">${t.title}</div>
        <div class="monitor-alert-subtitle">${t.subtitle}</div>
      </div>
      <div class="monitor-alert-meta">
        <span class="monitor-pill ${t.tone}">
          ${t.kind==="task"?Er(t.taskRow.task.priority):Ir(t.agentRow.state)}
        </span>
        ${t.kind==="task"?o`<span>${Pr(t.taskRow.task.status)}</span>`:o`<span>${t.agentRow.agent.name}</span>`}
        ${t.timestamp?o`<span><${q} timestamp=${t.timestamp} /></span>`:o`<span>No signal</span>`}
      </div>
    </div>
  `}function vo({row:t}){var e;return o`
    <div class="execution-task-row ${t.tone}">
      <div class="monitor-row-header">
        <span class="monitor-pill ${t.tone}">${Er(t.task.priority)}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${t.task.title}</span>
            <span class="monitor-sub">${t.task.id}</span>
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        ${t.assigneeAgent?o`<${yt} status=${t.assigneeAgent.status} />`:o`<span class="monitor-sub">No owner</span>`}
        <span class="monitor-pill ${t.tone}">${Pr(t.task.status)}</span>
      </div>

      <div class="monitor-meta">
        ${t.task.assignee?o`<span>Owner ${t.task.assignee}</span>`:o`<span>Unassigned</span>`}
        ${t.lastTouchedAt?o`<span>Touched <${q} timestamp=${t.lastTouchedAt} /></span>`:null}
        ${t.lastSignalAt?o`<span>Signal <${q} timestamp=${t.lastSignalAt} /></span>`:o`<span>No live signal</span>`}
      </div>

      <div class="monitor-focus">${t.focus}</div>
      ${(e=t.assigneeAgent)!=null&&e.current_task&&ce(t.assigneeAgent.current_task)!==t.focus?o`<div class="monitor-footnote">Owner focus: ${ce(t.assigneeAgent.current_task)}</div>`:null}
    </div>
  `}function cp({row:t}){const{agent:e}=t;return o`
    <button class="monitor-row ${t.tone}" onClick=${()=>Ne(e.name)}>
      <div class="monitor-row-header">
        <span class="agent-emoji">${e.emoji??""}</span>
        <div class="monitor-row-title">
          <div class="monitor-name-line">
            <span class="monitor-title">${e.name}</span>
            ${e.koreanName?o`<span class="monitor-sub">${e.koreanName}</span>`:null}
          </div>
          <div class="monitor-note">${t.note}</div>
        </div>
        <${yt} status=${e.status} />
        <span class="monitor-pill ${t.tone}">${Ir(t.state)}</span>
      </div>

      <div class="monitor-meta">
        ${t.lastSignalAt?o`<span>Signal <${q} timestamp=${t.lastSignalAt} /></span>`:o`<span>No recent signal</span>`}
        <span>${t.activeTaskCount>0?`${t.activeTaskCount} active tasks`:"No active tasks"}</span>
        ${e.model?o`<span>${e.model}</span>`:null}
      </div>

      <div class="monitor-focus">${t.focus}</div>
    </button>
  `}function up(){const t=te.value,e=Lt.value,n=new Map(t.map(l=>[Fa(l.name),l])),a=op(t),s=e.filter(l=>l.status==="claimed"||l.status==="in_progress").map(l=>po(l,n,a)).sort((l,c)=>{const m=Wt(c.tone)-Wt(l.tone);return m!==0?m:St(c.lastSignalAt??c.lastTouchedAt)-St(l.lastSignalAt??l.lastTouchedAt)}),i=e.filter(l=>l.status==="todo").map(l=>po(l,n,a)).sort((l,c)=>{const m=Wt(c.tone)-Wt(l.tone);if(m!==0)return m;const h=xn(l.task.priority)-xn(c.task.priority);return h!==0?h:St(l.lastTouchedAt)-St(c.lastTouchedAt)}),r=t.map(l=>rp(l,a)).filter(l=>l.state==="dispatchable"||l.state==="drift"||l.state==="quiet").sort((l,c)=>{if(l.state==="dispatchable"&&c.state!=="dispatchable")return-1;if(c.state==="dispatchable"&&l.state!=="dispatchable")return 1;const m=Wt(c.tone)-Wt(l.tone);return m!==0?m:St(c.lastSignalAt)-St(l.lastSignalAt)}),u=[...s.filter(l=>l.tone!=="ok").map(l=>({kind:"task",key:`active-${l.task.id}`,tone:l.tone,title:l.task.title,subtitle:`${l.note} · ${l.focus}`,timestamp:l.lastSignalAt??l.lastTouchedAt,taskRow:l})),...i.filter(l=>l.tone==="bad").map(l=>({kind:"task",key:`ready-${l.task.id}`,tone:l.tone,title:l.task.title,subtitle:`${l.note} · ${l.focus}`,timestamp:l.lastTouchedAt,taskRow:l})),...r.filter(l=>l.state==="drift"||l.tone==="bad").map(l=>({kind:"agent",key:`agent-${l.agent.name}`,tone:l.tone,title:l.agent.name,subtitle:`${l.note} · ${l.focus}`,timestamp:l.lastSignalAt,agentRow:l}))].sort((l,c)=>{const m=Wt(c.tone)-Wt(l.tone);return m!==0?m:St(c.timestamp)-St(l.timestamp)}).slice(0,8),d=r.filter(l=>l.state==="dispatchable"),p=[...s,...i].filter(l=>l.ownerGap),f=s.filter(l=>l.quiet);return o`
    <div class="agents-monitor">
      <div class="stats-grid">
        <${Ke} label="Active work" value=${s.length} color="#fbbf24" caption="claimed + in progress" />
        <${Ke} label="Needs intervention" value=${u.length} color=${u.length>0?"#fb7185":"#4ade80"} caption="stalled or drifting now" />
        <${Ke} label="Ownership gaps" value=${p.length} color=${p.length>0?"#fb7185":"#4ade80"} caption="missing or unavailable owners" />
        <${Ke} label="Dispatchable agents" value=${d.length} color="#22d3ee" caption="fresh signal, no active load" />
        <${Ke} label="Quiet execution" value=${f.length} color=${f.length>0?"#fbbf24":"#4ade80"} caption="active tasks with aging signals" />
      </div>

      <${x} title="Intervention Queue" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">What needs a nudge right now</h2>
          <p class="monitor-subheadline">Severity comes first, then the freshest evidence we have about the stall or drift.</p>
        </div>
        <div class="monitor-alert-list">
          ${u.length===0?o`<div class="empty-state">No active execution risks right now</div>`:u.map(l=>o`<${lp} key=${l.key} item=${l} />`)}
        </div>
      <//>

      <div class="grid-2col">
        <${x} title="Ready Queue" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Ready work, sorted by dispatch risk</h2>
            <p class="monitor-subheadline">Ownerless or owner-unavailable items float to the top before healthy assigned queue items.</p>
          </div>
          <div class="monitor-list">
            ${i.length===0?o`<div class="empty-state">No ready tasks in the queue</div>`:i.slice(0,10).map(l=>o`<${vo} key=${l.task.id} row=${l} />`)}
          </div>
        <//>

        <${x} title="Dispatch Window" class="section">
          <div class="monitor-section-head">
            <h2 class="monitor-headline">Who can pick up work next</h2>
            <p class="monitor-subheadline">Fresh capacity appears first. Task-state drift stays visible so owners can clean up metadata fast.</p>
          </div>
          <div class="monitor-list">
            ${r.length===0?o`<div class="empty-state">No agent capacity or drift signals right now</div>`:r.map(l=>o`<${cp} key=${l.agent.name} row=${l} />`)}
          </div>
        <//>
      </div>

      <${x} title="Active Execution Watch" class="section">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Claimed and in-progress work</h2>
          <p class="monitor-subheadline">Rows are sorted by risk first, then by the freshest operator signal tied to each task.</p>
        </div>
        <div class="monitor-list">
          ${s.length===0?o`<div class="empty-state">No active execution tasks</div>`:s.map(l=>o`<${vo} key=${l.task.id} row=${l} />`)}
        </div>
      <//>
    </div>
  `}const Sa=_("all"),Aa=_("all"),ti=ct(()=>{let t=gn.value;return Sa.value!=="all"&&(t=t.filter(e=>e.horizon===Sa.value)),Aa.value!=="all"&&(t=t.filter(e=>e.status===Aa.value)),t}),dp=ct(()=>{const t={short:[],mid:[],long:[]};for(const e of ti.value){const n=t[e.horizon];n&&n.push(e)}return t}),pp=ct(()=>{const t=Array.from(ht.value.values());return t.sort((e,n)=>e.status==="running"&&n.status!=="running"?-1:n.status==="running"&&e.status!=="running"?1:n.elapsed_seconds-e.elapsed_seconds),t});function vp(t){return"★".repeat(Math.min(t,5))+"☆".repeat(Math.max(0,5-t))}function hi(t){switch(t){case"short":return"Short-term";case"mid":return"Mid-term";case"long":return"Long-term";default:return t}}function ea(t){switch(t){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function mp(t){return t<60?`${Math.round(t)}s`:t<3600?`${Math.floor(t/60)}m ${Math.round(t%60)}s`:`${Math.floor(t/3600)}h ${Math.floor(t%3600/60)}m`}function mo(t){return t.toFixed(4)}function fo(t){const e=t.current_metric-t.baseline_metric;return`${e>=0?"+":""}${e.toFixed(4)}`}function fp({goal:t}){return o`
    <div class="goal-row">
      <div class="goal-row-main">
        <div style="display:flex; align-items:center; gap:8px;">
          <span class="goal-horizon-badge" style="color:${ea(t.horizon)}">
            ${hi(t.horizon)}
          </span>
          <span class="goal-title">${t.title}</span>
        </div>
        <div class="goal-meta">
          <span class="goal-priority" title="Priority ${t.priority}">${vp(t.priority)}</span>
          ${t.metric?o`<span class="goal-metric">${t.metric}${t.target_value?` → ${t.target_value}`:""}</span>`:null}
          ${t.due_date?o`<span class="goal-due">Due: <${q} timestamp=${t.due_date} /></span>`:null}
        </div>
        ${t.last_review_note?o`
          <div class="goal-review-note">${t.last_review_note}</div>
        `:null}
      </div>
      <div class="goal-row-right">
        <${yt} status=${t.status} />
        <div class="goal-updated">
          <${q} timestamp=${t.updated_at} />
        </div>
      </div>
    </div>
  `}function _o({label:t,timestamp:e,source:n,note:a}){return o`
    <div class="planning-freshness-row">
      <div>
        <div class="planning-freshness-label">${t}</div>
        <div class="planning-freshness-source">${n}</div>
        ${a?o`<div class="planning-freshness-source">${a}</div>`:null}
      </div>
      <strong class="planning-freshness-value">
        ${e?o`<${q} timestamp=${e} />`:"Not loaded"}
      </strong>
    </div>
  `}function as({horizon:t,items:e}){if(e.length===0)return null;const n=[...e].sort((a,s)=>s.priority-a.priority);return o`
    <${x} title="${hi(t)} Goals (${e.length})" class="section">
      <div class="goal-list">
        ${n.map(a=>o`<${fp} key=${a.id} goal=${a} />`)}
      </div>
    <//>
  `}function _p(){return o`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">Horizon</label>
        ${["all","short","mid","long"].map(t=>o`
          <button
            class="goal-filter-btn ${Sa.value===t?"active":""}"
            onClick=${()=>{Sa.value=t}}
          >
            ${t==="all"?"All":hi(t)}
          </button>
        `)}
      </div>
      <div class="goal-filter-group">
        <label class="goal-filter-label">Status</label>
        ${["all","active","completed","paused"].map(t=>o`
          <button
            class="goal-filter-btn ${Aa.value===t?"active":""}"
            onClick=${()=>{Aa.value=t}}
          >
            ${t==="all"?"All":t.charAt(0).toUpperCase()+t.slice(1)}
          </button>
        `)}
      </div>
    </div>
  `}function gp(){const t=gn.value,e=t.filter(s=>s.status==="active").length,n=t.filter(s=>s.status==="completed").length,a={short:0,mid:0,long:0};for(const s of t)s.horizon in a&&a[s.horizon]++;return o`
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
        <div class="goal-summary-value" style="color:${ea("short")}">${a.short}</div>
        <div class="goal-summary-label">Short</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${ea("mid")}">${a.mid}</div>
        <div class="goal-summary-label">Mid</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${ea("long")}">${a.long}</div>
        <div class="goal-summary-label">Long</div>
      </div>
    </div>
  `}function hp({loop:t}){const e=t.history[0];return o`
    <div class="planning-loop-row">
      <div class="planning-loop-main">
        <div class="planning-loop-head">
          <div>
            <div class="planning-loop-id">${t.profile}</div>
            <div class="planning-loop-sub">${t.loop_id}</div>
          </div>
          <div class="planning-loop-badges">
            <${yt} status=${t.status} />
            <span class="pill">${t.current_iteration}${t.max_iterations>0?`/${t.max_iterations}`:""}</span>
          </div>
        </div>

        <div class="planning-loop-metrics">
          <span>Baseline ${mo(t.baseline_metric)}</span>
          <span>Current ${mo(t.current_metric)}</span>
          <span class=${fo(t).startsWith("+")?"planning-loop-good":"planning-loop-bad"}>
            Delta ${fo(t)}
          </span>
          <span>Elapsed ${mp(t.elapsed_seconds)}</span>
        </div>

        <div class="planning-loop-target">${t.target||"No explicit target provided"}</div>
        ${e?o`
              <div class="planning-loop-footnote">
                Latest iteration #${e.iteration}: ${e.changes||e.next_suggestion||"No narrative"}
              </div>
            `:o`<div class="planning-loop-footnote">No iteration history yet</div>`}
      </div>
    </div>
  `}function $p(){Rt(()=>{Ve(),Qe()},[]);const t=dp.value,e=pp.value,n=e.filter(r=>r.status==="running").length,a=gn.value.filter(r=>r.status==="active").length,s=Qn.value,i=s==="idle"?"No loop running":s==="error"?Fs.value??"MDAL snapshot unavailable":"Current loop snapshot";return o`
    <div>
      <div class="stats-grid">
        <div class="stat-card">
          <div class="stat-label">Active goals</div>
          <div class="stat-value" style="color:#4ade80">${a}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Visible goals</div>
          <div class="stat-value">${ti.value.length}</div>
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

      <${x} title="Planning Surface" class="section">
        <div class="planning-header">
          <div>
            <h2 class="planning-headline">Direction lives here. Goals define intent, MDAL shows whether iteration is moving the metric.</h2>
            <p class="planning-subtitle">
              Goals refresh on tab open or manual refresh. MDAL reads the current loop snapshot exposed by <code>masc_mdal_status</code>.
            </p>
          </div>
          <div class="planning-actions">
            <button class="control-btn ghost" onClick=${Ve} disabled=${xe.value}>
              ${xe.value?"Refreshing goals...":"Refresh goals"}
            </button>
            <button class="control-btn ghost" onClick=${Qe} disabled=${we.value}>
              ${we.value?"Refreshing loops...":"Refresh loops"}
            </button>
            <button
              class="control-btn secondary"
              onClick=${()=>{Ve(),Qe()}}
              disabled=${xe.value||we.value}
            >
              Refresh all
            </button>
          </div>
        </div>

        <div class="planning-freshness-grid">
          <${_o} label="Goals" timestamp=${vr.value} source="masc_goal_list" />
          <${_o}
            label="MDAL loops"
            timestamp=${mr.value}
            source="masc_mdal_status"
            note=${i}
          />
        </div>
      <//>

      <${x} title="Goal Pipeline" class="section">
        <${gp} />
        <${_p} />
      <//>

      ${xe.value&&gn.value.length===0?o`<div class="loading-indicator">Loading goals...</div>`:ti.value.length===0?o`<div class="empty-state">No goals match the current filters</div>`:o`
              <${as} horizon="short" items=${t.short??[]} />
              <${as} horizon="mid" items=${t.mid??[]} />
              <${as} horizon="long" items=${t.long??[]} />
            `}

      <${x} title="MDAL Loops" class="section">
        ${we.value&&e.length===0?o`<div class="loading-indicator">Loading MDAL loops...</div>`:e.length===0&&s==="error"?o`
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
                  ${e.map(r=>o`<${hp} key=${r.loop_id} loop=${r} />`)}
                </div>
              `}
      <//>
    </div>
  `}const be=_(""),ss=_("ability_check"),is=_("10"),os=_("12"),zn=_(""),Hn=_("idle"),Jt=_(""),Kn=_("keeper-late"),rs=_("player"),ls=_(""),pt=_("idle"),cs=_(null),Un=_(""),us=_(""),ds=_("player"),ps=_(""),vs=_(""),ms=_(""),ln=_("20"),fs=_("20"),_s=_(""),Bn=_("idle"),ei=_(null),Mr=_("overview"),gs=_("all"),hs=_("all"),$s=_("all"),yp=12e4,ja=_(null),go=_(Date.now());function bp(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function kp(t,e){return e>0?Math.round(t/e*100):0}const xp={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},wp={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function Wn(t){const e=t.trim();return e?e.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):t}function Sp(t){const e=t.trim().toLowerCase();return xp[e]??"행동 선택 가중치에 영향을 주는 성향입니다."}function Ap(t){const e=t.trim().toLowerCase();return wp[e]??"상황에 따라 선택되는 전술 액션입니다."}function Yt(t){return typeof t=="object"&&t!==null}function ot(t,e,n=""){const a=t[e];return typeof a=="string"?a:n}function At(t,e,n=0){const a=t[e];return typeof a=="number"&&Number.isFinite(a)?a:n}function wn(t,e,n=!1){const a=t[e];return typeof a=="boolean"?a:n}const Tp=new Set(["str","dex","con","int","wis","cha"]);function Np(t){const e=t.trim();if(!e)return{};let n;try{n=JSON.parse(e)}catch(s){throw new Error(`능력치 JSON 파싱 실패: ${s instanceof Error?s.message:"invalid json"}`)}if(!Yt(n))throw new Error('능력치 JSON은 object여야 합니다. 예: {"luck":7}');const a={};return Object.entries(n).forEach(([s,i])=>{const r=s.trim();if(r){if(typeof i=="number"&&Number.isFinite(i)){a[r]=Math.max(0,Math.trunc(i));return}if(typeof i=="string"){const u=Number.parseFloat(i.trim());if(Number.isFinite(u)){a[r]=Math.max(0,Math.trunc(u));return}}throw new Error(`능력치 '${r}' 값은 숫자여야 합니다.`)}}),a}function Cp(t){const e=Number.parseInt(t.trim(),10);if(!Number.isFinite(e))return;const n=Math.max(1,e),a=Number.parseInt(ln.value.trim(),10);Number.isFinite(a)&&a>n&&(ln.value=String(n))}function ni(t){const n=(t.actor_name??t.actor??t.actor_id??"system").trim();return n===""?"system":n}function Rp(t){var n;return(((n=t.timestamp)==null?void 0:n.trim())??"")||"-"}function Lp(t){Mr.value=t}function Or(t){const e=ja.value;return e==null||e<=t}function Dp(t){const e=ja.value;return e==null||e<=t?0:Math.max(0,Math.ceil((e-t)/1e3))}function Ta(){ja.value=null}function Fr(t){return typeof window>"u"||typeof window.confirm!="function"?!0:window.confirm(t)}function Ep(t,e){Fr(["관전 모드 잠금을 해제하시겠습니까?",`ROOM: ${t||"-"}`,`PHASE: ${e||"-"}`,"해제 시간: 120초 (시간 경과 또는 위험 액션 실행 후 자동 재잠금)"].join(`
`))&&(ja.value=Date.now()+yp,b("조작 잠금이 120초 동안 해제되었습니다.","warning"))}function na(t){return Or(t)?(b("관전 모드 잠금 상태입니다. 먼저 잠금을 해제하세요.","warning"),!1):!0}function ai(t,e,n){return Fr([`[위험 액션 확인] ${t}`,`ROOM: ${e||"-"}`,`PHASE: ${n||"-"}`,"이 액션은 즉시 실행되며 되돌리기 어렵습니다.","계속 진행하시겠습니까?"].join(`
`))}function Pp({hp:t,max:e}){const n=kp(t,e),a=bp(t,e);return o`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${a}" style="width:${n}%" />
    </div>
  `}function Ip({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return o`
    <div class="trpg-actor-stats">
      ${e.map(n=>o`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function Mp({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return o`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function jr({actor:t}){var d,p,f,l;const e=(d=t.archetype)==null?void 0:d.trim(),n=(p=t.persona)==null?void 0:p.trim(),a=(f=t.portrait)==null?void 0:f.trim(),s=(l=t.background)==null?void 0:l.trim(),i=t.traits??[],r=t.skills??[],u=Object.entries(t.stats_raw??{}).filter(([c,m])=>Number.isFinite(m)).filter(([c])=>!Tp.has(c.toLowerCase()));return o`
    <div class="trpg-actor">
      ${a?o`
          <div class="trpg-actor-portrait-wrap">
            <img
              class="trpg-actor-portrait"
              src=${a}
              alt=${`${t.name} portrait`}
              loading="lazy"
              onError=${c=>{const m=c.target;m&&(m.style.display="none")}}
            />
          </div>
        `:null}
      <div class="trpg-actor-header">
        <span class="trpg-actor-name">${t.name}</span>
        <${yt} status=${t.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${t.role}">${t.role}</span>
        <${Mp} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?o`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?o`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${Pp} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${Ip} stats=${t.stats} />
          </div>
        `:null}
      ${e?o`<div class="trpg-actor-meta">Archetype: ${Wn(e)}</div>`:null}
      ${s?o`<div class="trpg-actor-meta">Background: ${s}</div>`:null}
      ${n?o`<div class="trpg-actor-persona">${n}</div>`:null}
      ${u.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Custom Stats</div>
            <div class="trpg-custom-stats">
              ${u.map(([c,m])=>o`
                <span class="trpg-custom-stat-chip">${Wn(c)} ${m}</span>
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
                  <span class="trpg-annot-name">${Wn(c)}</span>
                  <span class="trpg-annot-desc">${Sp(c)}</span>
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
                  <span class="trpg-annot-name">${Wn(c)}</span>
                  <span class="trpg-annot-desc">${Ap(c)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function Op({mapStr:t}){return o`<pre class="trpg-map">${t}</pre>`}function qr({events:t,emptyLabel:e="아직 이벤트가 없습니다."}){return t.length===0?o`<div class="empty-state" style="font-size:13px">${e}</div>`:o`
    <div class="trpg-story" role="list" aria-label="TRPG story events">
      ${t.map((n,a)=>{var s;return o`
        <div key=${a} class="trpg-event ${n.type??""}" role="listitem">
          <div class="trpg-event-meta-row">
            <span class="trpg-event-meta">${Rp(n)}</span>
            <span class="trpg-event-meta">${n.phase??"phase:-"}</span>
            <span class="trpg-event-meta">${n.type??"type:-"}</span>
          </div>
          <div class="trpg-event-main">
            <strong>${ni(n)}</strong>
            ${" "}
          ${n.dice_roll?o`<span class="trpg-dice">[${n.dice_roll.notation}: ${(s=n.dice_roll.rolls)==null?void 0:s.join(",")} = ${n.dice_roll.total}${n.dice_roll.modifier?` +${n.dice_roll.modifier}`:""}]</span>${" "}`:null}
            <span class="trpg-event-text">${n.content??""}</span>
            <span class="trpg-event-ts"><${q} timestamp=${n.timestamp} /></span>
          </div>
        </div>
      `})}
    </div>
  `}function Fp({events:t}){const e="__none__",n=gs.value,a=hs.value,s=$s.value,i=Array.from(new Set(t.map(ni).map(l=>l.trim()).filter(l=>l!==""))).sort((l,c)=>l.localeCompare(c)),r=Array.from(new Set(t.map(l=>(l.type??"").trim()).filter(l=>l!==""))).sort((l,c)=>l.localeCompare(c)),u=t.some(l=>(l.type??"").trim()===""),d=Array.from(new Set(t.map(l=>(l.phase??"").trim()).filter(l=>l!==""))).sort((l,c)=>l.localeCompare(c)),p=t.some(l=>(l.phase??"").trim()===""),f=t.filter(l=>{if(n!=="all"&&ni(l)!==n)return!1;const c=(l.type??"").trim(),m=(l.phase??"").trim();if(a===e){if(c!=="")return!1}else if(a!=="all"&&c!==a)return!1;if(s===e){if(m!=="")return!1}else if(s!=="all"&&m!==s)return!1;return!0});return o`
    <div class="trpg-story-toolbar">
      <div class="trpg-story-filter">
        <label>Actor</label>
        <select value=${n} onChange=${l=>{gs.value=l.target.value}}>
          <option value="all">all</option>
          ${i.map(l=>o`<option value=${l}>${l}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Type</label>
        <select value=${a} onChange=${l=>{hs.value=l.target.value}}>
          <option value="all">all</option>
          ${u?o`<option value=${e}>(none)</option>`:null}
          ${r.map(l=>o`<option value=${l}>${l}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Phase</label>
        <select value=${s} onChange=${l=>{$s.value=l.target.value}}>
          <option value="all">all</option>
          ${p?o`<option value=${e}>(none)</option>`:null}
          ${d.map(l=>o`<option value=${l}>${l}</option>`)}
        </select>
      </div>
      <button
        class="trpg-run-btn secondary"
        style="align-self:flex-end;"
        onClick=${()=>{gs.value="all",hs.value="all",$s.value="all"}}
      >
        필터 초기화
      </button>
      <span style="margin-left:auto; font-size:11px; color:#9ca3af; align-self:flex-end;">
        표시 ${f.length} / 전체 ${t.length}
      </span>
    </div>
    <${qr} events=${f.slice(-120)} emptyLabel="필터 조건에 맞는 이벤트가 없습니다." />
  `}function jp({outcome:t}){if(!t)return null;const e=i=>{const r=i.trim();return r&&(/[A-Z]/.test(r)&&!r.includes(" ")?r.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():r.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())},n=t.result==="victory"?"승리":t.result==="defeat"?"패배":t.result==="draw"?"무승부":"종료",a=t.result==="victory"?"#34d399":t.result==="defeat"?"#f87171":"#9ca3af",s=[t.reason?`원인: ${e(t.reason)}`:null,t.phase?`페이즈: ${e(t.phase)}`:null,typeof t.turn=="number"?`턴: ${t.turn}`:null].filter(Boolean).join(" · ");return o`
    <div style="margin-bottom:16px; padding:10px 12px; border:1px solid rgba(255,255,255,0.12); border-radius:10px; background:rgba(255,255,255,0.03);">
      <div style="font-size:12px; color:#9ca3af; text-transform:uppercase; letter-spacing:0.08em;">Session Outcome</div>
      <div style="font-size:18px; font-weight:700; color:${a}; margin-top:4px;">${n}</div>
      ${t.summary?o`<div style="margin-top:4px; font-size:13px; color:#d1d5db;">${e(t.summary)}</div>`:null}
      ${s?o`<div style="margin-top:4px; font-size:11px; color:#9ca3af;">${s}</div>`:null}
    </div>
  `}function zr({state:t}){const e=t.history??[];return e.length===0?null:o`
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
  `}function qp({state:t,nowMs:e}){var p;const n=Et.value||((p=t.session)==null?void 0:p.room)||"",a=Hn.value,s=t.party??[];if(!s.find(f=>f.id===be.value)&&s.length>0){const f=s[0];f&&(be.value=f.id)}const r=async()=>{var l,c;if(!n){b("Room ID가 비어 있습니다.","error");return}if(!na(e))return;const f=((l=t.current_round)==null?void 0:l.phase)??((c=t.session)==null?void 0:c.status)??"unknown";if(ai("라운드 실행",n,f)){Hn.value="running";try{const m=await rc(n);ei.value=m,Hn.value="ok";const h=Yt(m.summary)?m.summary:null,y=h?wn(h,"advanced",!1):!1,w=h?ot(h,"progress_reason",""):"";b(y?"라운드가 정상 진행되었습니다.":`라운드가 정체되었습니다${w?`: ${w}`:""}`,y?"success":"warning"),Pt()}catch(m){ei.value=null,Hn.value="error";const h=m instanceof Error?m.message:"라운드 실행에 실패했습니다.";b(h,"error")}finally{Ta()}}},u=async()=>{var l,c;if(!n||!na(e))return;const f=((l=t.current_round)==null?void 0:l.phase)??((c=t.session)==null?void 0:c.status)??"unknown";if(ai("턴 강제 진행",n,f))try{await uc(n),b("턴을 다음 단계로 이동했습니다.","success"),Pt()}catch{b("턴 이동에 실패했습니다.","error")}finally{Ta()}},d=async()=>{if(!n||!na(e))return;const f=be.value.trim();if(!f){b("먼저 Actor를 선택하세요.","warning");return}const l=Number.parseInt(is.value,10),c=Number.parseInt(os.value,10);if(Number.isNaN(l)||Number.isNaN(c)){b("stat/dc는 숫자여야 합니다.","warning");return}const m=Number.parseInt(zn.value,10),h=zn.value.trim()===""||Number.isNaN(m)?void 0:m;try{await cc({roomId:n,actorId:f,action:ss.value.trim()||"ability_check",statValue:l,dc:c,rawD20:h}),b("주사위 판정을 기록했습니다.","success"),Pt()}catch{b("주사위 판정 기록에 실패했습니다.","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            id="trpg-room-input"
            name="trpg-room-input"
            type="text"
            value=${n}
            onInput=${f=>{Et.value=f.target.value}}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${be.value}
            onChange=${f=>{be.value=f.target.value}}
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
              value=${ss.value}
              onInput=${f=>{ss.value=f.target.value}}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${is.value}
              onInput=${f=>{is.value=f.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${os.value}
              onInput=${f=>{os.value=f.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              id="trpg-dice-raw-input"
              name="trpg-dice-raw-input"
              type="text"
              value=${zn.value}
              onInput=${f=>{zn.value=f.target.value}}
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
  `}function zp({state:t}){var s;const e=Et.value||((s=t.session)==null?void 0:s.room)||"",n=Bn.value,a=async()=>{if(!e){b("Room ID가 비어 있습니다.","warning");return}const i=Un.value.trim(),r=us.value.trim();if(!r&&!i){b("이름 또는 Actor ID를 입력하세요.","warning");return}const u=Number.parseInt(ln.value.trim(),10),d=Number.parseInt(fs.value.trim(),10),p=Number.isFinite(d)?Math.max(1,d):20,f=Number.isFinite(u)?Math.max(0,Math.min(p,u)):p;let l={};try{l=Np(_s.value)}catch(c){b(c instanceof Error?c.message:"능력치 JSON 오류","error");return}Bn.value="spawning";try{const c=typeof crypto<"u"&&typeof crypto.randomUUID=="function"?`trpg_spawn_${crypto.randomUUID()}`:`trpg_spawn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,m=await dc(e,{actor_id:i||void 0,name:r||void 0,role:ds.value,idempotencyKey:c,portrait:vs.value.trim()||void 0,background:ms.value.trim()||void 0,hp:f,max_hp:p,alive:f>0,stats:Object.keys(l).length>0?l:void 0}),h=typeof m.actor_id=="string"?m.actor_id.trim():"";if(!h)throw new Error("생성 응답에 actor_id가 없습니다.");const y=ps.value.trim();y&&await pc(e,h,y),be.value=h,Jt.value=h,i||(Un.value=""),Bn.value="ok",b(`Actor 생성 완료: ${h}`,"success"),await Pt()}catch(c){Bn.value="error",b(c instanceof Error?c.message:"Actor 생성에 실패했습니다.","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Name</label>
          <input
            id="trpg-spawn-name-input"
            name="trpg-spawn-name-input"
            type="text"
            value=${us.value}
            onInput=${i=>{us.value=i.target.value}}
            placeholder="Night Fox"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${ds.value}
            onChange=${i=>{ds.value=i.target.value}}
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
            value=${ps.value}
            onInput=${i=>{ps.value=i.target.value}}
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
              value=${Un.value}
              onInput=${i=>{Un.value=i.target.value}}
              placeholder="auto when blank"
            />
          </div>
          <div class="trpg-control-field">
            <label>Portrait URL</label>
            <input
              id="trpg-spawn-portrait-input"
              name="trpg-spawn-portrait-input"
              type="text"
              value=${vs.value}
              onInput=${i=>{vs.value=i.target.value}}
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
              value=${ln.value}
              onInput=${i=>{ln.value=i.target.value}}
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
              value=${fs.value}
              onInput=${i=>{const r=i.target.value;fs.value=r,Cp(r)}}
              placeholder="20"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Background</label>
            <input
              id="trpg-spawn-background-input"
              name="trpg-spawn-background-input"
              type="text"
              value=${ms.value}
              onInput=${i=>{ms.value=i.target.value}}
              placeholder="망명 기사 · 폐허 수색 전문가"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Stats JSON</label>
            <input
              id="trpg-spawn-stats-json-input"
              name="trpg-spawn-stats-json-input"
              type="text"
              value=${_s.value}
              onInput=${i=>{_s.value=i.target.value}}
              placeholder='{"luck":7,"stealth":12,"str":10}'
            />
          </div>
        </div>
      </details>

      ${n!=="idle"?o`<div class="trpg-run-status ${n==="spawning"?"running":n}">${n==="spawning"?"생성 중...":n==="ok"?"생성 완료":"생성 실패"}</div>`:null}
    </div>
  `}function Hp({state:t,nowMs:e}){var c;const n=Et.value||((c=t.session)==null?void 0:c.room)||"",a=t.join_gate,s=cs.value,i=Yt(s)?s:null,r=(t.party??[]).filter(m=>m.role!=="dm"),u=Jt.value.trim(),d=r.some(m=>m.id===u),p=d?u:u?"__manual__":"",f=async()=>{const m=Jt.value.trim(),h=Kn.value.trim();if(!n||!m){b("Room/Actor가 필요합니다.","warning");return}pt.value="checking";try{const y=await vc(n,m,h||void 0);cs.value=y,pt.value="ok",b("참가 가능 여부를 갱신했습니다.","success")}catch(y){pt.value="error";const w=y instanceof Error?y.message:"참가 가능 여부 확인에 실패했습니다.";b(w,"error")}},l=async()=>{var C,S;const m=Jt.value.trim(),h=Kn.value.trim(),y=ls.value.trim();if(!n||!m||!h){b("Room/Actor/Keeper가 필요합니다.","warning");return}if(!na(e))return;const w=((C=t.current_round)==null?void 0:C.phase)??((S=t.session)==null?void 0:S.status)??"unknown";if(ai("Mid-Join 승인 요청",n,w)){pt.value="requesting";try{const P=await mc({room_id:n,actor_id:m,keeper_name:h,role:rs.value,...y?{name:y}:{}});cs.value=P;const A=Yt(P)?wn(P,"granted",!1):!1,L=Yt(P)?ot(P,"reason_code",""):"";A?b("Mid-Join이 승인되었습니다.","success"):b(`Mid-Join이 거절되었습니다${L?`: ${L}`:""}`,"warning"),pt.value=A?"ok":"error",Pt()}catch(P){pt.value="error";const A=P instanceof Error?P.message:"Mid-Join 요청에 실패했습니다.";b(A,"error")}finally{Ta()}}};return o`
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
            onChange=${m=>{const h=m.target.value;if(h==="__manual__"){(d||!u)&&(Jt.value="");return}Jt.value=h}}
          >
            <option value="">Actor 선택</option>
            ${r.map(m=>o`
              <option value=${m.id}>${m.name} (${m.id})</option>
            `)}
            <option value="__manual__">직접 입력</option>
          </select>
          ${p==="__manual__"?o`
              <input
                id="trpg-join-actor-input"
                name="trpg-join-actor-input"
                type="text"
                value=${Jt.value}
                onInput=${m=>{Jt.value=m.target.value}}
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
            value=${Kn.value}
            onInput=${m=>{Kn.value=m.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${rs.value}
            onChange=${m=>{rs.value=m.target.value}}
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
            value=${ls.value}
            onInput=${m=>{ls.value=m.target.value}}
            placeholder="display name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn secondary" onClick=${f} disabled=${pt.value==="checking"||pt.value==="requesting"}>
              ${pt.value==="checking"?"Checking...":"Check"}
            </button>
            <button class="trpg-run-btn recommend" onClick=${l} disabled=${pt.value==="checking"||pt.value==="requesting"}>
              ${pt.value==="requesting"?"Requesting...":"Request Join"}
            </button>
          </div>
        </div>
      </div>
      ${i?o`
          <div style="margin-top:8px; font-size:12px; color:#d1d5db;">
            Eligible: <strong>${wn(i,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${At(i,"effective_score",0)}/${At(i,"required_points",0)}</span>
            ${ot(i,"reason_code","")?o`<span style="margin-left:8px;">Reason: ${ot(i,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function Hr({state:t}){const e=[...t.contribution_ledger??[]].sort((n,a)=>(a.score??0)-(n.score??0)).slice(0,8);return e.length===0?o`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:o`
    <div class="trpg-round-list">
      ${e.map(n=>o`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function Kr({state:t}){var n;const e=t.current_round;return e?o`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?o`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function Ur(){const t=ei.value;if(!t)return o`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const e=t.summary,n=Yt(e)?e:null,s=(Array.isArray(t.statuses)?t.statuses:[]).filter(Yt).slice(-8),i=t.canon_check,r=Yt(i)?i:null,u=r&&Array.isArray(r.warnings)?r.warnings.filter(L=>typeof L=="string").slice(0,3):[],d=r&&Array.isArray(r.violations)?r.violations.filter(L=>typeof L=="string").slice(0,3):[],p=n?wn(n,"advanced",!1):!1,f=n?ot(n,"progress_reason",""):"",l=n?ot(n,"progress_detail",""):"",c=n?At(n,"player_successes",0):0,m=n?At(n,"player_required_successes",0):0,h=n?wn(n,"dm_success",!1):!1,y=n?At(n,"timeouts",0):0,w=n?At(n,"unavailable",0):0,C=n?At(n,"reprompts",0):0,S=n?At(n,"npc_attacks",0):0,P=n?At(n,"keeper_timeout_sec",0):0,A=n?At(n,"roll_audit_count",0):0;return o`
    <div style="display:grid; gap:10px;">
      <div class="trpg-round-item ${p?"active":"failed"}" style="display:block;">
        <div style="display:flex; align-items:center; gap:8px;">
          <strong>${p?"ADVANCED":"STALLED"}</strong>
          <span style="font-size:11px; color:#9ca3af;">
            turn ${t.turn_before??0} → ${t.turn_after??0}
          </span>
          <span style="margin-left:auto; font-size:11px; color:#9ca3af;">
            ${h?"DM ok":"DM stalled"} / players ${c}/${m}
          </span>
        </div>
        ${f?o`<div style="margin-top:4px; font-size:12px;">${f}</div>`:null}
        ${l?o`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${l}</div>`:null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${y}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${w}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${C}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${S}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${P||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${A}</div></div>
      </div>

      ${s.length>0?o`
          <div class="trpg-round-list">
            ${s.map(L=>{const tt=ot(L,"status","unknown"),bt=ot(L,"actor_id","-"),kt=ot(L,"role","-"),et=ot(L,"reason",""),ut=ot(L,"action_type",""),I=ot(L,"reply","");return o`
                <div class="trpg-round-item ${tt.includes("fallback")||tt.includes("timeout")?"failed":"active"}">
                  <span>${bt} (${kt})</span>
                  <span style="margin-left:auto; font-size:11px;">${tt}</span>
                  ${ut?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${ut}</div>`:null}
                  ${et?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${et}</div>`:null}
                  ${I?o`<div style="width:100%; font-size:11px; color:#d1d5db; margin-top:2px;">${I.slice(0,120)}</div>`:null}
                </div>
              `})}
          </div>`:null}

      ${r?o`
          <div class="trpg-control-box">
            <div style="font-size:12px; color:#9ca3af;">
              Canon status: <strong>${ot(r,"status","unknown")}</strong>
            </div>
            ${d.length>0?o`
                <div style="margin-top:6px; font-size:11px; color:#fca5a5;">
                  ${d.map(L=>o`<div>violation: ${L}</div>`)}
                </div>`:null}
            ${u.length>0?o`
                <div style="margin-top:6px; font-size:11px; color:#fbbf24;">
                  ${u.map(L=>o`<div>warning: ${L}</div>`)}
                </div>`:null}
          </div>
        `:null}
    </div>
  `}function Kp({state:t,nowMs:e}){var r,u,d;const n=Et.value||((r=t.session)==null?void 0:r.room)||"",a=((u=t.current_round)==null?void 0:u.phase)??((d=t.session)==null?void 0:d.status)??"unknown",s=Or(e),i=Dp(e);return o`
    <${x} title="조작 안전 잠금" style="margin-bottom:16px;">
      <div class="trpg-control-lock ${s?"locked":"unlocked"}">
        <div class="trpg-control-lock-title">
          ${s?"잠금 상태: 관전 전용":"잠금 해제됨"}
        </div>
        <div class="trpg-control-lock-desc">
          ${s?"조작 액션은 실행되지 않습니다. 필요할 때만 잠금을 해제하세요.":`위험 액션 실행 또는 ${i}초 후 자동으로 다시 잠깁니다.`}
        </div>
        <div class="trpg-control-lock-meta">room: ${n||"-"} · phase: ${a||"-"}</div>
        <div style="display:flex; gap:8px; margin-top:10px; flex-wrap:wrap;">
          ${s?o`<button class="trpg-run-btn recommend" onClick=${()=>Ep(n,a)}>잠금 해제 (120초)</button>`:o`<button class="trpg-run-btn secondary" onClick=${()=>{Ta(),b("조작 잠금으로 전환했습니다.","success")}}>즉시 다시 잠금</button>`}
        </div>
      </div>
    <//>
  `}function Up({active:t}){return o`
    <div class="trpg-screen-tabs" role="tablist" aria-label="TRPG 화면 선택">
      ${[{id:"overview",label:"Overview",desc:"관전 요약"},{id:"timeline",label:"Timeline",desc:"이벤트 흐름"},{id:"control",label:"Control",desc:"운영/개입"}].map(n=>o`
        <button
          class="trpg-screen-tab ${t===n.id?"active":""}"
          role="tab"
          aria-selected=${t===n.id}
          onClick=${()=>Lp(n.id)}
        >
          <span class="trpg-screen-tab-label">${n.label}</span>
          <span class="trpg-screen-tab-desc">${n.desc}</span>
        </button>
      `)}
    </div>
  `}function Bp({state:t}){const e=t.party??[],n=t.story_log??[];return o`
    <div class="trpg-layout">
      <div>
        <${x} title="관전 가이드">
          <div class="trpg-guide-box">
            <div class="trpg-guide-title">권장 운영 순서</div>
            <div class="trpg-guide-text">1) Overview에서 상태 파악 → 2) Timeline에서 원인 확인 → 3) 필요 시 Control에서 최소 개입</div>
            <div class="trpg-guide-meta">관전자 기본 모드 / 위험 액션은 Control 잠금 해제 후 실행</div>
          </div>
        <//>

        <${x} title=${`최근 스토리 (${Math.min(n.length,20)})`} style="margin-top:16px;">
          <${qr} events=${n.slice(-20)} />
        <//>

        ${t.map?o`
            <${x} title="맵" style="margin-top:16px;">
              <${Op} mapStr=${t.map} />
            <//>
          `:null}
      </div>

      <div class="trpg-sidebar">
        <${x} title="현재 라운드">
          <${Kr} state=${t} />
        <//>

        <${x} title="기여도" style="margin-top:16px;">
          <${Hr} state=${t} />
        <//>

        <${x} title=${`파티 (${e.length})`} style="margin-top:16px;">
          <div class="trpg-actor-list">
            ${e.map(a=>o`<${jr} key=${a.id??a.name} actor=${a} />`)}
            ${e.length===0?o`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
          </div>
        <//>

        ${t.history&&t.history.length>0?o`
            <${x} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
              <${zr} state=${t} />
            <//>
          `:null}
      </div>
    </div>
  `}function Wp({state:t}){const e=t.story_log??[];return o`
    <div class="trpg-layout">
      <div>
        <${x} title=${`이벤트 타임라인 (${e.length})`}>
          <${Fp} events=${e} />
        <//>
      </div>

      <div class="trpg-sidebar">
        <${x} title="최근 라운드 결과">
          <${Ur} />
        <//>

        <${x} title="현재 라운드" style="margin-top:16px;">
          <${Kr} state=${t} />
        <//>
      </div>
    </div>
  `}function Gp({state:t,nowMs:e}){const n=t.party??[];return o`
    <div>
      <${Kp} state=${t} nowMs=${e} />
      <div class="trpg-layout">
        <div>
          <${x} title="조작 패널">
            <${qp} state=${t} nowMs=${e} />
          <//>

          <${x} title="Actor Spawn" style="margin-top:16px;">
            <${zp} state=${t} />
          <//>

          <${x} title="Mid-Join Gate" style="margin-top:16px;">
            <${Hp} state=${t} nowMs=${e} />
          <//>

          <${x} title="최근 라운드 결과" style="margin-top:16px;">
            <${Ur} />
          <//>
        </div>

        <div class="trpg-sidebar">
          <${x} title="기여도" style="margin-top:0;">
            <${Hr} state=${t} />
          <//>

          <${x} title=${`파티 (${n.length})`} style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(a=>o`<${jr} key=${a.id??a.name} actor=${a} />`)}
              ${n.length===0?o`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
            </div>
          <//>

          ${t.history&&t.history.length>0?o`
              <${x} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
                <${zr} state=${t} />
              <//>
            `:null}
        </div>
      </div>
    </div>
  `}function Jp(){var u,d,p,f,l;const t=pr.value,e=qs.value;if(Rt(()=>{if(typeof window>"u"||typeof window.setInterval!="function")return;const c=window.setInterval(()=>{go.value=Date.now()},1e3);return()=>{window.clearInterval(c)}},[]),e&&!t)return o`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return o`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>Pt()}>Refresh</button>
      </div>
    `;const n=t.party??[],a=t.story_log??[],s=t.outcome,i=Mr.value,r=go.value;return o`
    <div>
      <div style="display:flex; gap:8px; align-items:center; justify-content:space-between; margin-bottom:8px;">
        <div style="font-size:11px; color:#8ea9d6;">
          room: ${Et.value||((u=t.session)==null?void 0:u.room)||"-"} · phase: ${((d=t.current_round)==null?void 0:d.phase)??((p=t.session)==null?void 0:p.status)??"-"}
        </div>
        <button class="trpg-run-btn secondary" onClick=${()=>Pt()}>새로고침</button>
      </div>

      <${jp} outcome=${s} />

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

      <${Up} active=${i} />

      ${i==="overview"?o`<${Bp} state=${t} />`:i==="timeline"?o`<${Wp} state=${t} />`:o`<${Gp} state=${t} nowMs=${r} />`}
    </div>
  `}const $i="masc_dashboard_agent_name";function Vp(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem($i);return e??n??"dashboard"}const lt=_(Vp()),cn=_(""),un=_(""),Na=_(""),Br=_(null),Ca=_(null),dn=_(!1),Se=_(!1),pn=_(!1),vn=_(!1),Ra=_(!1),La=_(!1),qa=_(!1);function Da(t){return typeof t!="number"||!Number.isFinite(t)?"??:00":`${String(Math.max(0,t)).padStart(2,"0")}:00`}function aa(t){if(typeof t!="number"||!Number.isFinite(t)||t<=0)return"unknown";if(t<60)return`${Math.round(t)}s`;if(t<3600)return`${Math.round(t/60)}m`;const e=Math.floor(t/3600),n=Math.round(t%3600/60);return n>0?`${e}h ${n}m`:`${e}h`}function Wr(t){return!t||t.length===0?"none":t.join(", ")}function Qp(t){return t?t.enabled?t.quiet_active?`Quiet hours ${Da(t.quiet_start)}-${Da(t.quiet_end)} KST are active. Scheduled ticks may look asleep until the window ends; Poke Now bypasses only that quiet-hours gate.`:t.last_tick_ago_s==null?`Lodge is enabled and scheduled every ${aa(t.interval_s)}, but no tick has run yet in this runtime.`:t.last_skip_reason?`Lodge last skipped work because ${t.last_skip_reason}. Scheduled ticks still run every ${aa(t.interval_s)}.`:`Lodge ticks every ${aa(t.interval_s)}. Planner is ${t.use_planner?"on":"off"} and delegated LLM is ${t.delegate_llm?"on":"off"}.`:"Lodge automation is disabled. Manual poke will report the disabled state but will not revive a stopped runtime.":"Lodge runtime status is unavailable. Refresh the dashboard to inspect scheduling state."}async function Oe(){De();try{await pe()}catch(t){console.warn("[control-dock] dashboard refresh failed",t)}}function yi(t){const e=t.trim();lt.value=e,e&&localStorage.setItem($i,e)}function Yp(t){const n=(t.split(`
`).find(a=>a.includes(" joined"))??t).match(/✅\s+(\S+)\s+joined/i);return(n==null?void 0:n[1])??null}async function si(){const t=lt.value.trim();if(t){pn.value=!0;try{const e=await _c(t),n=Yp(e);n&&yi(n),qa.value=!0,await Oe(),b(`Joined as ${n??t}`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to join room";b(n,"error")}finally{pn.value=!1}}}async function Xp(){const t=lt.value.trim();if(t){vn.value=!0;try{await ur(t),qa.value=!1,await Oe(),b(`Left room (${t})`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to leave room";b(n,"error")}finally{vn.value=!1}}}async function Zp(){const t=lt.value.trim();if(t)try{await ur(t)}catch{}localStorage.removeItem($i),yi("dashboard"),qa.value=!1,await si()}async function tv(){const t=lt.value.trim();if(t){Ra.value=!0;try{await gc(t),await Oe(),b("Heartbeat sent","success")}catch(e){const n=e instanceof Error?e.message:"Failed to send heartbeat";b(n,"error")}finally{Ra.value=!1}}}async function ho(){const t=lt.value.trim(),e=cn.value.trim();if(!(!t||!e)){dn.value=!0;try{await cr(t,e),cn.value="",await Oe(),b("Broadcast sent","success")}catch(n){const a=n instanceof Error?n.message:"Failed to send broadcast";b(a,"error")}finally{dn.value=!1}}}async function ev(){const t=un.value.trim(),e=Na.value.trim()||"Created from dashboard";if(t){Se.value=!0;try{await fc(t,e,1),un.value="",Na.value="",await Oe(),b("Task created","success")}catch(n){const a=n instanceof Error?n.message:"Failed to create task";b(a,"error")}finally{Se.value=!1}}}async function $o(){const t=lt.value.trim()||"dashboard";La.value=!0,Ca.value=null;try{const e=await Rn({actor:t,action_type:"lodge_tick",target_type:"room",payload:{}}),n=vi(e.result);Br.value=n,await Oe(),n!=null&&n.skipped_reason?b(n.skipped_reason,"warning"):b(n?`Poke finished: ${n.acted}/${n.checked} acted`:"Poke finished",n&&n.acted>0?"success":"warning")}catch(e){const n=e instanceof Error?e.message:"Failed to run Lodge poke";Ca.value=n,b(n,"error")}finally{La.value=!1}}function nv({runtime:t}){var s,i;const e=Br.value??(t==null?void 0:t.last_tick_result)??null;if(Ca.value)return o`<div class="control-result-box is-error">${Ca.value}</div>`;if(!e)return o`<div class="control-status-copy">No poke result yet. The latest scheduled tick will appear here after the first run.</div>`;const n=((s=e.skipped_rows)==null?void 0:s.slice(0,3))??[],a=((i=e.passed_rows)==null?void 0:i.slice(0,3))??[];return o`
    <div class="control-result-box">
      <div class="control-inline-meta">
        <span class="pill">${e.checked} checked</span>
        <span class="pill">${e.acted} acted</span>
        ${e.quiet_hours_overridden?o`<span class="pill">quiet hours bypassed</span>`:null}
      </div>
      <div class="control-status-copy">Last acted: ${Wr(e.acted_names)}</div>
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
  `}function av(t){return t.find(n=>n.name===Ge.value)??t[0]??null}function sv(){var a,s;const t=$t.value,e=((a=ee.value)==null?void 0:a.lodge)??null,n=av(t);return Rt(()=>{si()},[]),Rt(()=>{var r;const i=((r=t[0])==null?void 0:r.name)??"";if(!Ge.value&&i){Vn(i);return}Ge.value&&!t.some(u=>u.name===Ge.value)&&Vn(i)},[t.map(i=>i.name).join("|")]),o`
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
          value=${lt.value}
          onInput=${i=>yi(i.target.value)}
        />

        <div class="control-actions">
          <button
            class="control-btn ghost"
            onClick=${()=>{si()}}
            disabled=${pn.value||lt.value.trim()===""}
          >
            ${pn.value?"Joining...":qa.value?"Rejoin":"Join"}
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{Xp()}}
            disabled=${vn.value||lt.value.trim()===""}
          >
            ${vn.value?"Leaving...":"Leave"}
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{Zp()}}
            disabled=${pn.value||vn.value}
          >
            Reset ID
          </button>
          <button
            class="control-btn ghost"
            onClick=${()=>{tv()}}
            disabled=${Ra.value||lt.value.trim()===""}
          >
            ${Ra.value?"Pinging...":"Heartbeat"}
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
            value=${cn.value}
            onInput=${i=>{cn.value=i.target.value}}
            onKeyDown=${i=>{i.key==="Enter"&&ho()}}
            disabled=${dn.value}
          />
          <button
            class="control-btn"
            onClick=${()=>{ho()}}
            disabled=${dn.value||cn.value.trim()===""||lt.value.trim()===""}
          >
            ${dn.value?"Sending...":"Send"}
          </button>
        </div>
      </div>

      <div class="control-section">
        <div class="control-section-head">
          <h4>Keeper Direct Message</h4>
          <p class="control-help">This sends a 1:1 message through <code>masc_keeper_msg</code> and keeps the actual reply thread in the dock so you can see whether the keeper answered.</p>
        </div>

        <label class="control-label" for="dock-keeper">Keeper</label>
        <select
          id="dock-keeper"
          class="control-input"
          value=${(n==null?void 0:n.name)??""}
          onInput=${i=>{Vn(i.target.value)}}
          disabled=${t.length===0}
        >
          ${t.length===0?o`<option value="">No keepers available</option>`:t.map(i=>o`<option value=${i.name}>${i.name}</option>`)}
        </select>

        <${br} keeper=${n} />
        <${xr}
          actor=${lt.value.trim()||"dashboard"}
          keeper=${n}
          onPokeLodge=${()=>{$o()}}
        />
        <${kr}
          keeperName=${(n==null?void 0:n.name)??""}
          placeholder=${t.length===0?"No keeper is active yet":"Direct prompt for the selected keeper"}
        />
      </div>

      <div class="control-section">
        <div class="control-section-head">
          <h4>Lodge Status</h4>
          <p class="control-help">${Qp(e)}</p>
        </div>

        <div class="control-inline-meta">
          <span class="pill">${e!=null&&e.enabled?"enabled":"disabled"}</span>
          <span class="pill">every ${aa(e==null?void 0:e.interval_s)}</span>
          <span class="pill">quiet ${Da(e==null?void 0:e.quiet_start)}-${Da(e==null?void 0:e.quiet_end)} KST</span>
          <span class="pill">${e!=null&&e.quiet_active?"quiet active":"quiet inactive"}</span>
          <span class="pill">${e!=null&&e.use_planner?"planner on":"planner off"}</span>
          <span class="pill">${e!=null&&e.delegate_llm?"delegate llm on":"delegate llm off"}</span>
        </div>

        <div class="control-status-copy">
          Last tick: ${(e==null?void 0:e.last_tick_ago)??"never"} · Total ticks: ${(e==null?void 0:e.total_ticks)??0} · Last acted: ${Wr((s=e==null?void 0:e.last_tick_result)==null?void 0:s.acted_names)}
        </div>
        ${e!=null&&e.last_skip_reason?o`<div class="control-status-copy">Last skip reason: ${e.last_skip_reason}</div>`:null}

        <div class="control-actions">
          <button
            class="control-btn secondary"
            onClick=${()=>{$o()}}
            disabled=${La.value}
          >
            ${La.value?"Poking...":"Poke Now"}
          </button>
        </div>

        <${nv} runtime=${e} />
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
          value=${un.value}
          onInput=${i=>{un.value=i.target.value}}
          disabled=${Se.value}
        />
        <textarea
          class="control-textarea"
          placeholder="Task description (optional)"
          value=${Na.value}
          onInput=${i=>{Na.value=i.target.value}}
          disabled=${Se.value}
        ></textarea>
        <button
          class="control-btn secondary"
          onClick=${()=>{ev()}}
          disabled=${Se.value||un.value.trim()===""}
        >
          ${Se.value?"Creating...":"Create Task"}
        </button>
      </div>
    </section>
  `}const yo=[{id:"observe",label:"Observe",description:"Live health, execution state, and room-wide telemetry"},{id:"coordinate",label:"Coordinate",description:"Conversation, decisions, planning, and backlog context"},{id:"command",label:"Command",description:"Direct control surfaces and intervention workflows"}],ii=[{id:"overview",label:"Overview",icon:"🏠",group:"observe",description:"Room health, keeper pressure, and top-line execution status"},{id:"execution",label:"Execution",icon:"🛠️",group:"observe",description:"Intervention queue for stalled work, ownership gaps, and execution drift"},{id:"agents",label:"Agents",icon:"🤖",group:"observe",description:"Live monitor for agent status, keeper pressure, and current execution focus"},{id:"activity",label:"Activity",icon:"📊",group:"observe",description:"Unified live stream for messages, task changes, board events, and keeper events"},{id:"board",label:"Board",icon:"💬",group:"coordinate",description:"Human and agent discussion feed with system noise filtered by default"},{id:"council",label:"Council",icon:"🏛️",group:"coordinate",description:"Debates, quorum status, and decision flow"},{id:"goals",label:"Planning",icon:"🎯",group:"coordinate",description:"Goals and MDAL loops in one planning surface with freshness signals"},{id:"tasks",label:"Tasks",icon:"📋",group:"coordinate",description:"Kanban-style task distribution"},{id:"ops",label:"Ops",icon:"🎮",group:"command",description:"Guided operator controls for room, sessions, and keepers"},{id:"trpg",label:"TRPG",icon:"⚔️",group:"command",description:"Narrative room control and state visibility"}];function iv(){const t=It.value;return o`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"Live":"Reconnecting..."}</span>
      <span class="event-count">${Tn.value} events</span>
    </div>
  `}function ov(){const t=Nt.value.tab,e=It.value,n=ii.find(r=>r.id===t),a=yo.find(r=>r.id===(n==null?void 0:n.group)),[s,i]=Oo(!1);return o`
    <aside class="dashboard-rail">
      <section class="rail-card">
        <div class="rail-card-head">
          <h3>Navigate</h3>
          ${a?o`<span class="rail-section-chip">${a.label}</span>`:null}
        </div>
        ${yo.map(r=>o`
          <div class="rail-nav-group" key=${r.id}>
            <div class="rail-group-label">${r.label}</div>
            <div class="rail-group-copy">${r.description}</div>
            <div class="rail-tab-list">
              ${ii.filter(u=>u.group===r.id).map(u=>o`
                  <button
                    class="rail-tab-btn ${t===u.id?"active":""}"
                    onClick=${()=>_t(u.id)}
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
            <strong>${te.value.length}</strong>
          </div>
          <div class="rail-stat-card">
            <span>Keepers</span>
            <strong>${$t.value.length}</strong>
          </div>
          <div class="rail-stat-card">
            <span>Tasks</span>
            <strong>${Lt.value.length}</strong>
          </div>
          <div class="rail-stat-card">
            <span>Events</span>
            <strong>${Tn.value}</strong>
          </div>
        </div>
        <div class="rail-snapshot-copy">
          <span>Connection ${e?"healthy":"recovering"}</span>
          <span>${(a==null?void 0:a.label)??"Observe"} workspace active</span>
        </div>
        <div class="rail-inline-actions">
          <button
            class="rail-refresh-btn"
            onClick=${()=>{pe(),t==="ops"&&Ee(),t==="board"&&Ct(),t==="trpg"&&Pt(),t==="goals"&&(Ve(),Qe())}}
          >
            Refresh Now
          </button>
          <button class="rail-secondary-btn" onClick=${()=>_t("ops")}>
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
        ${s?o`<div class="rail-fold-body"><${sv} /></div>`:o`<div class="rail-fold-hint">Use inline actions for quick room nudges. Open the Ops tab for structured intervention work.</div>`}
      </section>
    </aside>
  `}function rv(){switch(Nt.value.tab){case"overview":return o`<${eo} />`;case"ops":return o`<${ud} />`;case"council":return o`<${fd} />`;case"board":return o`<${Ad} />`;case"execution":return o`<${up} />`;case"activity":return o`<${Bd} />`;case"agents":return o`<${ap} />`;case"tasks":return o`<${sp} />`;case"goals":return o`<${$p} />`;case"trpg":return o`<${Jp} />`;default:return o`<${eo} />`}}function lv(){Rt(()=>{hl(),nr(),pe(),Ct();const n=ou();return ru(),()=>{Al(),n(),lu()}},[]),Rt(()=>{const n=Nt.value.tab;n==="ops"&&Ee(),n==="board"&&Ct(),n==="trpg"&&Pt(),n==="goals"&&(Ve(),Qe())},[Nt.value.tab]);const t=Nt.value.tab,e=ii.find(n=>n.id===t);return o`
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
          <${iv} />
        </div>
      </header>

      <div class="dashboard-layout">
        <${ov} />
        <main class="dashboard-main">
          ${js.value&&!It.value?o`<div class="loading-indicator">Loading dashboard...</div>`:o`<${rv} />`}
        </main>
      </div>

      <${Ru} />
      <${Iu} />
      <${mu} />
    </div>
  `}const bo=document.getElementById("app");bo&&tl(o`<${lv} />`,bo);
