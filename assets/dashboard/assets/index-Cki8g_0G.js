var pi=Object.defineProperty;var vi=(t,e,n)=>e in t?pi(t,e,{enumerable:!0,configurable:!0,writable:!0,value:n}):t[e]=n;var ht=(t,e,n)=>vi(t,typeof e!="symbol"?e+"":e,n);(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const a of document.querySelectorAll('link[rel="modulepreload"]'))s(a);new MutationObserver(a=>{for(const i of a)if(i.type==="childList")for(const r of i.addedNodes)r.tagName==="LINK"&&r.rel==="modulepreload"&&s(r)}).observe(document,{childList:!0,subtree:!0});function n(a){const i={};return a.integrity&&(i.integrity=a.integrity),a.referrerPolicy&&(i.referrerPolicy=a.referrerPolicy),a.crossOrigin==="use-credentials"?i.credentials="include":a.crossOrigin==="anonymous"?i.credentials="omit":i.credentials="same-origin",i}function s(a){if(a.ep)return;a.ep=!0;const i=n(a);fetch(a.href,i)}})();var Ue,L,Ks,qs,pt,vs,Gs,Js,Ws,Yn,kn,wn,Zt={},Vs=[],fi=/acit|ex(?:s|g|n|p|$)|rph|grid|ows|mnc|ntw|ine[ch]|zoo|^ord|itera/i,He=Array.isArray;function nt(t,e){for(var n in e)t[n]=e[n];return t}function Qn(t){t&&t.parentNode&&t.parentNode.removeChild(t)}function Ys(t,e,n){var s,a,i,r={};for(i in e)i=="key"?s=e[i]:i=="ref"?a=e[i]:r[i]=e[i];if(arguments.length>2&&(r.children=arguments.length>3?Ue.call(arguments,2):n),typeof t=="function"&&t.defaultProps!=null)for(i in t.defaultProps)r[i]===void 0&&(r[i]=t.defaultProps[i]);return be(t,r,s,a,null)}function be(t,e,n,s,a){var i={type:t,props:e,key:n,ref:s,__k:null,__:null,__b:0,__e:null,__c:null,constructor:void 0,__v:a??++Ks,__i:-1,__u:0};return a==null&&L.vnode!=null&&L.vnode(i),i}function ie(t){return t.children}function jt(t,e){this.props=t,this.context=e}function At(t,e){if(e==null)return t.__?At(t.__,t.__i+1):null;for(var n;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null)return n.__e;return typeof t.type=="function"?At(t):null}function Qs(t){var e,n;if((t=t.__)!=null&&t.__c!=null){for(t.__e=t.__c.base=null,e=0;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null){t.__e=t.__c.base=n.__e;break}return Qs(t)}}function fs(t){(!t.__d&&(t.__d=!0)&&pt.push(t)&&!Ce.__r++||vs!=L.debounceRendering)&&((vs=L.debounceRendering)||Gs)(Ce)}function Ce(){for(var t,e,n,s,a,i,r,c=1;pt.length;)pt.length>c&&pt.sort(Js),t=pt.shift(),c=pt.length,t.__d&&(n=void 0,s=void 0,a=(s=(e=t).__v).__e,i=[],r=[],e.__P&&((n=nt({},s)).__v=s.__v+1,L.vnode&&L.vnode(n),Xn(e.__P,n,s,e.__n,e.__P.namespaceURI,32&s.__u?[a]:null,i,a??At(s),!!(32&s.__u),r),n.__v=s.__v,n.__.__k[n.__i]=n,ta(i,n,r),s.__e=s.__=null,n.__e!=a&&Qs(n)));Ce.__r=0}function Xs(t,e,n,s,a,i,r,c,u,p,f){var l,d,v,$,x,S,A,C=s&&s.__k||Vs,D=e.length;for(u=mi(n,e,C,u,D),l=0;l<D;l++)(v=n.__k[l])!=null&&(d=v.__i==-1?Zt:C[v.__i]||Zt,v.__i=l,S=Xn(t,v,d,a,i,r,c,u,p,f),$=v.__e,v.ref&&d.ref!=v.ref&&(d.ref&&Zn(d.ref,null,v),f.push(v.ref,v.__c||$,v)),x==null&&$!=null&&(x=$),(A=!!(4&v.__u))||d.__k===v.__k?u=Zs(v,u,t,A):typeof v.type=="function"&&S!==void 0?u=S:$&&(u=$.nextSibling),v.__u&=-7);return n.__e=x,u}function mi(t,e,n,s,a){var i,r,c,u,p,f=n.length,l=f,d=0;for(t.__k=new Array(a),i=0;i<a;i++)(r=e[i])!=null&&typeof r!="boolean"&&typeof r!="function"?(typeof r=="string"||typeof r=="number"||typeof r=="bigint"||r.constructor==String?r=t.__k[i]=be(null,r,null,null,null):He(r)?r=t.__k[i]=be(ie,{children:r},null,null,null):r.constructor===void 0&&r.__b>0?r=t.__k[i]=be(r.type,r.props,r.key,r.ref?r.ref:null,r.__v):t.__k[i]=r,u=i+d,r.__=t,r.__b=t.__b+1,c=null,(p=r.__i=_i(r,n,u,l))!=-1&&(l--,(c=n[p])&&(c.__u|=2)),c==null||c.__v==null?(p==-1&&(a>f?d--:a<f&&d++),typeof r.type!="function"&&(r.__u|=4)):p!=u&&(p==u-1?d--:p==u+1?d++:(p>u?d--:d++,r.__u|=4))):t.__k[i]=null;if(l)for(i=0;i<f;i++)(c=n[i])!=null&&(2&c.__u)==0&&(c.__e==s&&(s=At(c)),na(c,c));return s}function Zs(t,e,n,s){var a,i;if(typeof t.type=="function"){for(a=t.__k,i=0;a&&i<a.length;i++)a[i]&&(a[i].__=t,e=Zs(a[i],e,n,s));return e}t.__e!=e&&(s&&(e&&t.type&&!e.parentNode&&(e=At(t)),n.insertBefore(t.__e,e||null)),e=t.__e);do e=e&&e.nextSibling;while(e!=null&&e.nodeType==8);return e}function _i(t,e,n,s){var a,i,r,c=t.key,u=t.type,p=e[n],f=p!=null&&(2&p.__u)==0;if(p===null&&c==null||f&&c==p.key&&u==p.type)return n;if(s>(f?1:0)){for(a=n-1,i=n+1;a>=0||i<e.length;)if((p=e[r=a>=0?a--:i++])!=null&&(2&p.__u)==0&&c==p.key&&u==p.type)return r}return-1}function ms(t,e,n){e[0]=="-"?t.setProperty(e,n??""):t[e]=n==null?"":typeof n!="number"||fi.test(e)?n:n+"px"}function de(t,e,n,s,a){var i,r;t:if(e=="style")if(typeof n=="string")t.style.cssText=n;else{if(typeof s=="string"&&(t.style.cssText=s=""),s)for(e in s)n&&e in n||ms(t.style,e,"");if(n)for(e in n)s&&n[e]==s[e]||ms(t.style,e,n[e])}else if(e[0]=="o"&&e[1]=="n")i=e!=(e=e.replace(Ws,"$1")),r=e.toLowerCase(),e=r in t||e=="onFocusOut"||e=="onFocusIn"?r.slice(2):e.slice(2),t.l||(t.l={}),t.l[e+i]=n,n?s?n.u=s.u:(n.u=Yn,t.addEventListener(e,i?wn:kn,i)):t.removeEventListener(e,i?wn:kn,i);else{if(a=="http://www.w3.org/2000/svg")e=e.replace(/xlink(H|:h)/,"h").replace(/sName$/,"s");else if(e!="width"&&e!="height"&&e!="href"&&e!="list"&&e!="form"&&e!="tabIndex"&&e!="download"&&e!="rowSpan"&&e!="colSpan"&&e!="role"&&e!="popover"&&e in t)try{t[e]=n??"";break t}catch{}typeof n=="function"||(n==null||n===!1&&e[4]!="-"?t.removeAttribute(e):t.setAttribute(e,e=="popover"&&n==1?"":n))}}function _s(t){return function(e){if(this.l){var n=this.l[e.type+t];if(e.t==null)e.t=Yn++;else if(e.t<n.u)return;return n(L.event?L.event(e):e)}}}function Xn(t,e,n,s,a,i,r,c,u,p){var f,l,d,v,$,x,S,A,C,D,M,E,q,ut,dt,G,et,R=e.type;if(e.constructor!==void 0)return null;128&n.__u&&(u=!!(32&n.__u),i=[c=e.__e=n.__e]),(f=L.__b)&&f(e);t:if(typeof R=="function")try{if(A=e.props,C="prototype"in R&&R.prototype.render,D=(f=R.contextType)&&s[f.__c],M=f?D?D.props.value:f.__:s,n.__c?S=(l=e.__c=n.__c).__=l.__E:(C?e.__c=l=new R(A,M):(e.__c=l=new jt(A,M),l.constructor=R,l.render=$i),D&&D.sub(l),l.state||(l.state={}),l.__n=s,d=l.__d=!0,l.__h=[],l._sb=[]),C&&l.__s==null&&(l.__s=l.state),C&&R.getDerivedStateFromProps!=null&&(l.__s==l.state&&(l.__s=nt({},l.__s)),nt(l.__s,R.getDerivedStateFromProps(A,l.__s))),v=l.props,$=l.state,l.__v=e,d)C&&R.getDerivedStateFromProps==null&&l.componentWillMount!=null&&l.componentWillMount(),C&&l.componentDidMount!=null&&l.__h.push(l.componentDidMount);else{if(C&&R.getDerivedStateFromProps==null&&A!==v&&l.componentWillReceiveProps!=null&&l.componentWillReceiveProps(A,M),e.__v==n.__v||!l.__e&&l.shouldComponentUpdate!=null&&l.shouldComponentUpdate(A,l.__s,M)===!1){for(e.__v!=n.__v&&(l.props=A,l.state=l.__s,l.__d=!1),e.__e=n.__e,e.__k=n.__k,e.__k.some(function(O){O&&(O.__=e)}),E=0;E<l._sb.length;E++)l.__h.push(l._sb[E]);l._sb=[],l.__h.length&&r.push(l);break t}l.componentWillUpdate!=null&&l.componentWillUpdate(A,l.__s,M),C&&l.componentDidUpdate!=null&&l.__h.push(function(){l.componentDidUpdate(v,$,x)})}if(l.context=M,l.props=A,l.__P=t,l.__e=!1,q=L.__r,ut=0,C){for(l.state=l.__s,l.__d=!1,q&&q(e),f=l.render(l.props,l.state,l.context),dt=0;dt<l._sb.length;dt++)l.__h.push(l._sb[dt]);l._sb=[]}else do l.__d=!1,q&&q(e),f=l.render(l.props,l.state,l.context),l.state=l.__s;while(l.__d&&++ut<25);l.state=l.__s,l.getChildContext!=null&&(s=nt(nt({},s),l.getChildContext())),C&&!d&&l.getSnapshotBeforeUpdate!=null&&(x=l.getSnapshotBeforeUpdate(v,$)),G=f,f!=null&&f.type===ie&&f.key==null&&(G=ea(f.props.children)),c=Xs(t,He(G)?G:[G],e,n,s,a,i,r,c,u,p),l.base=e.__e,e.__u&=-161,l.__h.length&&r.push(l),S&&(l.__E=l.__=null)}catch(O){if(e.__v=null,u||i!=null)if(O.then){for(e.__u|=u?160:128;c&&c.nodeType==8&&c.nextSibling;)c=c.nextSibling;i[i.indexOf(c)]=null,e.__e=c}else{for(et=i.length;et--;)Qn(i[et]);Sn(e)}else e.__e=n.__e,e.__k=n.__k,O.then||Sn(e);L.__e(O,e,n)}else i==null&&e.__v==n.__v?(e.__k=n.__k,e.__e=n.__e):c=e.__e=gi(n.__e,e,n,s,a,i,r,u,p);return(f=L.diffed)&&f(e),128&e.__u?void 0:c}function Sn(t){t&&t.__c&&(t.__c.__e=!0),t&&t.__k&&t.__k.forEach(Sn)}function ta(t,e,n){for(var s=0;s<n.length;s++)Zn(n[s],n[++s],n[++s]);L.__c&&L.__c(e,t),t.some(function(a){try{t=a.__h,a.__h=[],t.some(function(i){i.call(a)})}catch(i){L.__e(i,a.__v)}})}function ea(t){return typeof t!="object"||t==null||t.__b&&t.__b>0?t:He(t)?t.map(ea):nt({},t)}function gi(t,e,n,s,a,i,r,c,u){var p,f,l,d,v,$,x,S=n.props||Zt,A=e.props,C=e.type;if(C=="svg"?a="http://www.w3.org/2000/svg":C=="math"?a="http://www.w3.org/1998/Math/MathML":a||(a="http://www.w3.org/1999/xhtml"),i!=null){for(p=0;p<i.length;p++)if((v=i[p])&&"setAttribute"in v==!!C&&(C?v.localName==C:v.nodeType==3)){t=v,i[p]=null;break}}if(t==null){if(C==null)return document.createTextNode(A);t=document.createElementNS(a,C,A.is&&A),c&&(L.__m&&L.__m(e,i),c=!1),i=null}if(C==null)S===A||c&&t.data==A||(t.data=A);else{if(i=i&&Ue.call(t.childNodes),!c&&i!=null)for(S={},p=0;p<t.attributes.length;p++)S[(v=t.attributes[p]).name]=v.value;for(p in S)if(v=S[p],p!="children"){if(p=="dangerouslySetInnerHTML")l=v;else if(!(p in A)){if(p=="value"&&"defaultValue"in A||p=="checked"&&"defaultChecked"in A)continue;de(t,p,null,v,a)}}for(p in A)v=A[p],p=="children"?d=v:p=="dangerouslySetInnerHTML"?f=v:p=="value"?$=v:p=="checked"?x=v:c&&typeof v!="function"||S[p]===v||de(t,p,v,S[p],a);if(f)c||l&&(f.__html==l.__html||f.__html==t.innerHTML)||(t.innerHTML=f.__html),e.__k=[];else if(l&&(t.innerHTML=""),Xs(e.type=="template"?t.content:t,He(d)?d:[d],e,n,s,C=="foreignObject"?"http://www.w3.org/1999/xhtml":a,i,r,i?i[0]:n.__k&&At(n,0),c,u),i!=null)for(p=i.length;p--;)Qn(i[p]);c||(p="value",C=="progress"&&$==null?t.removeAttribute("value"):$!=null&&($!==t[p]||C=="progress"&&!$||C=="option"&&$!=S[p])&&de(t,p,$,S[p],a),p="checked",x!=null&&x!=t[p]&&de(t,p,x,S[p],a))}return t}function Zn(t,e,n){try{if(typeof t=="function"){var s=typeof t.__u=="function";s&&t.__u(),s&&e==null||(t.__u=t(e))}else t.current=e}catch(a){L.__e(a,n)}}function na(t,e,n){var s,a;if(L.unmount&&L.unmount(t),(s=t.ref)&&(s.current&&s.current!=t.__e||Zn(s,null,e)),(s=t.__c)!=null){if(s.componentWillUnmount)try{s.componentWillUnmount()}catch(i){L.__e(i,e)}s.base=s.__P=null}if(s=t.__k)for(a=0;a<s.length;a++)s[a]&&na(s[a],e,n||typeof t.type!="function");n||Qn(t.__e),t.__c=t.__=t.__e=void 0}function $i(t,e,n){return this.constructor(t,n)}function hi(t,e,n){var s,a,i,r;e==document&&(e=document.documentElement),L.__&&L.__(t,e),a=(s=!1)?null:e.__k,i=[],r=[],Xn(e,t=e.__k=Ys(ie,null,[t]),a||Zt,Zt,e.namespaceURI,a?null:e.firstChild?Ue.call(e.childNodes):null,i,a?a.__e:e.firstChild,s,r),ta(i,t,r)}Ue=Vs.slice,L={__e:function(t,e,n,s){for(var a,i,r;e=e.__;)if((a=e.__c)&&!a.__)try{if((i=a.constructor)&&i.getDerivedStateFromError!=null&&(a.setState(i.getDerivedStateFromError(t)),r=a.__d),a.componentDidCatch!=null&&(a.componentDidCatch(t,s||{}),r=a.__d),r)return a.__E=a}catch(c){t=c}throw t}},Ks=0,qs=function(t){return t!=null&&t.constructor===void 0},jt.prototype.setState=function(t,e){var n;n=this.__s!=null&&this.__s!=this.state?this.__s:this.__s=nt({},this.state),typeof t=="function"&&(t=t(nt({},n),this.props)),t&&nt(n,t),t!=null&&this.__v&&(e&&this._sb.push(e),fs(this))},jt.prototype.forceUpdate=function(t){this.__v&&(this.__e=!0,t&&this.__h.push(t),fs(this))},jt.prototype.render=ie,pt=[],Gs=typeof Promise=="function"?Promise.prototype.then.bind(Promise.resolve()):setTimeout,Js=function(t,e){return t.__v.__b-e.__v.__b},Ce.__r=0,Ws=/(PointerCapture)$|Capture$/i,Yn=0,kn=_s(!1),wn=_s(!0);var sa=function(t,e,n,s){var a;e[0]=0;for(var i=1;i<e.length;i++){var r=e[i++],c=e[i]?(e[0]|=r?1:2,n[e[i++]]):e[++i];r===3?s[0]=c:r===4?s[1]=Object.assign(s[1]||{},c):r===5?(s[1]=s[1]||{})[e[++i]]=c:r===6?s[1][e[++i]]+=c+"":r?(a=t.apply(c,sa(t,c,n,["",null])),s.push(a),c[0]?e[0]|=2:(e[i-2]=0,e[i]=a)):s.push(c)}return s},gs=new Map;function yi(t){var e=gs.get(this);return e||(e=new Map,gs.set(this,e)),(e=sa(this,e.get(t)||(e.set(t,e=(function(n){for(var s,a,i=1,r="",c="",u=[0],p=function(d){i===1&&(d||(r=r.replace(/^\s*\n\s*|\s*\n\s*$/g,"")))?u.push(0,d,r):i===3&&(d||r)?(u.push(3,d,r),i=2):i===2&&r==="..."&&d?u.push(4,d,0):i===2&&r&&!d?u.push(5,0,!0,r):i>=5&&((r||!d&&i===5)&&(u.push(i,0,r,a),i=6),d&&(u.push(i,d,0,a),i=6)),r=""},f=0;f<n.length;f++){f&&(i===1&&p(),p(f));for(var l=0;l<n[f].length;l++)s=n[f][l],i===1?s==="<"?(p(),u=[u],i=3):r+=s:i===4?r==="--"&&s===">"?(i=1,r=""):r=s+r[0]:c?s===c?c="":r+=s:s==='"'||s==="'"?c=s:s===">"?(p(),i=1):i&&(s==="="?(i=5,a=r,r=""):s==="/"&&(i<5||n[f][l+1]===">")?(p(),i===3&&(u=u[0]),i=u,(u=u[0]).push(2,0,i),i=0):s===" "||s==="	"||s===`
`||s==="\r"?(p(),i=2):r+=s),i===3&&r==="!--"&&(i=4,u=u[0])}return p(),u})(t)),e),arguments,[])).length>1?e:e[0]}var o=yi.bind(Ys),te,P,Ve,$s,Cn=0,aa=[],I=L,hs=I.__b,ys=I.__r,bs=I.diffed,xs=I.__c,ks=I.unmount,ws=I.__;function ts(t,e){I.__h&&I.__h(P,t,Cn||e),Cn=0;var n=P.__H||(P.__H={__:[],__h:[]});return t>=n.__.length&&n.__.push({}),n.__[t]}function pe(t){return Cn=1,bi(ra,t)}function bi(t,e,n){var s=ts(te++,2);if(s.t=t,!s.__c&&(s.__=[ra(void 0,e),function(c){var u=s.__N?s.__N[0]:s.__[0],p=s.t(u,c);u!==p&&(s.__N=[p,s.__[1]],s.__c.setState({}))}],s.__c=P,!P.__f)){var a=function(c,u,p){if(!s.__c.__H)return!0;var f=s.__c.__H.__.filter(function(d){return!!d.__c});if(f.every(function(d){return!d.__N}))return!i||i.call(this,c,u,p);var l=s.__c.props!==c;return f.forEach(function(d){if(d.__N){var v=d.__[0];d.__=d.__N,d.__N=void 0,v!==d.__[0]&&(l=!0)}}),i&&i.call(this,c,u,p)||l};P.__f=!0;var i=P.shouldComponentUpdate,r=P.componentWillUpdate;P.componentWillUpdate=function(c,u,p){if(this.__e){var f=i;i=void 0,a(c,u,p),i=f}r&&r.call(this,c,u,p)},P.shouldComponentUpdate=a}return s.__N||s.__}function ft(t,e){var n=ts(te++,3);!I.__s&&oa(n.__H,e)&&(n.__=t,n.u=e,P.__H.__h.push(n))}function ia(t,e){var n=ts(te++,7);return oa(n.__H,e)&&(n.__=t(),n.__H=e,n.__h=t),n.__}function xi(){for(var t;t=aa.shift();)if(t.__P&&t.__H)try{t.__H.__h.forEach(xe),t.__H.__h.forEach(An),t.__H.__h=[]}catch(e){t.__H.__h=[],I.__e(e,t.__v)}}I.__b=function(t){P=null,hs&&hs(t)},I.__=function(t,e){t&&e.__k&&e.__k.__m&&(t.__m=e.__k.__m),ws&&ws(t,e)},I.__r=function(t){ys&&ys(t),te=0;var e=(P=t.__c).__H;e&&(Ve===P?(e.__h=[],P.__h=[],e.__.forEach(function(n){n.__N&&(n.__=n.__N),n.u=n.__N=void 0})):(e.__h.forEach(xe),e.__h.forEach(An),e.__h=[],te=0)),Ve=P},I.diffed=function(t){bs&&bs(t);var e=t.__c;e&&e.__H&&(e.__H.__h.length&&(aa.push(e)!==1&&$s===I.requestAnimationFrame||(($s=I.requestAnimationFrame)||ki)(xi)),e.__H.__.forEach(function(n){n.u&&(n.__H=n.u),n.u=void 0})),Ve=P=null},I.__c=function(t,e){e.some(function(n){try{n.__h.forEach(xe),n.__h=n.__h.filter(function(s){return!s.__||An(s)})}catch(s){e.some(function(a){a.__h&&(a.__h=[])}),e=[],I.__e(s,n.__v)}}),xs&&xs(t,e)},I.unmount=function(t){ks&&ks(t);var e,n=t.__c;n&&n.__H&&(n.__H.__.forEach(function(s){try{xe(s)}catch(a){e=a}}),n.__H=void 0,e&&I.__e(e,n.__v))};var Ss=typeof requestAnimationFrame=="function";function ki(t){var e,n=function(){clearTimeout(s),Ss&&cancelAnimationFrame(e),setTimeout(t)},s=setTimeout(n,35);Ss&&(e=requestAnimationFrame(n))}function xe(t){var e=P,n=t.__c;typeof n=="function"&&(t.__c=void 0,n()),P=e}function An(t){var e=P;t.__c=t.__(),P=e}function oa(t,e){return!t||t.length!==e.length||e.some(function(n,s){return n!==t[s]})}function ra(t,e){return typeof e=="function"?e(t):e}var wi=Symbol.for("preact-signals");function Be(){if(ot>1)ot--;else{for(var t,e=!1;Mt!==void 0;){var n=Mt;for(Mt=void 0,Nn++;n!==void 0;){var s=n.o;if(n.o=void 0,n.f&=-3,!(8&n.f)&&ua(n))try{n.c()}catch(a){e||(t=a,e=!0)}n=s}}if(Nn=0,ot--,e)throw t}}function Si(t){if(ot>0)return t();ot++;try{return t()}finally{Be()}}var T=void 0;function la(t){var e=T;T=void 0;try{return t()}finally{T=e}}var Mt=void 0,ot=0,Nn=0,Ae=0;function ca(t){if(T!==void 0){var e=t.n;if(e===void 0||e.t!==T)return e={i:0,S:t,p:T.s,n:void 0,t:T,e:void 0,x:void 0,r:e},T.s!==void 0&&(T.s.n=e),T.s=e,t.n=e,32&T.f&&t.S(e),e;if(e.i===-1)return e.i=0,e.n!==void 0&&(e.n.p=e.p,e.p!==void 0&&(e.p.n=e.n),e.p=T.s,e.n=void 0,T.s.n=e,T.s=e),e}}function j(t,e){this.v=t,this.i=0,this.n=void 0,this.t=void 0,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}j.prototype.brand=wi;j.prototype.h=function(){return!0};j.prototype.S=function(t){var e=this,n=this.t;n!==t&&t.e===void 0&&(t.x=n,this.t=t,n!==void 0?n.e=t:la(function(){var s;(s=e.W)==null||s.call(e)}))};j.prototype.U=function(t){var e=this;if(this.t!==void 0){var n=t.e,s=t.x;n!==void 0&&(n.x=s,t.e=void 0),s!==void 0&&(s.e=n,t.x=void 0),t===this.t&&(this.t=s,s===void 0&&la(function(){var a;(a=e.Z)==null||a.call(e)}))}};j.prototype.subscribe=function(t){var e=this;return oe(function(){var n=e.value,s=T;T=void 0;try{t(n)}finally{T=s}},{name:"sub"})};j.prototype.valueOf=function(){return this.value};j.prototype.toString=function(){return this.value+""};j.prototype.toJSON=function(){return this.value};j.prototype.peek=function(){var t=T;T=void 0;try{return this.value}finally{T=t}};Object.defineProperty(j.prototype,"value",{get:function(){var t=ca(this);return t!==void 0&&(t.i=this.i),this.v},set:function(t){if(t!==this.v){if(Nn>100)throw new Error("Cycle detected");this.v=t,this.i++,Ae++,ot++;try{for(var e=this.t;e!==void 0;e=e.x)e.t.N()}finally{Be()}}}});function _(t,e){return new j(t,e)}function ua(t){for(var e=t.s;e!==void 0;e=e.n)if(e.S.i!==e.i||!e.S.h()||e.S.i!==e.i)return!0;return!1}function da(t){for(var e=t.s;e!==void 0;e=e.n){var n=e.S.n;if(n!==void 0&&(e.r=n),e.S.n=e,e.i=-1,e.n===void 0){t.s=e;break}}}function pa(t){for(var e=t.s,n=void 0;e!==void 0;){var s=e.p;e.i===-1?(e.S.U(e),s!==void 0&&(s.n=e.n),e.n!==void 0&&(e.n.p=s)):n=e,e.S.n=e.r,e.r!==void 0&&(e.r=void 0),e=s}t.s=n}function mt(t,e){j.call(this,void 0),this.x=t,this.s=void 0,this.g=Ae-1,this.f=4,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}mt.prototype=new j;mt.prototype.h=function(){if(this.f&=-3,1&this.f)return!1;if((36&this.f)==32||(this.f&=-5,this.g===Ae))return!0;if(this.g=Ae,this.f|=1,this.i>0&&!ua(this))return this.f&=-2,!0;var t=T;try{da(this),T=this;var e=this.x();(16&this.f||this.v!==e||this.i===0)&&(this.v=e,this.f&=-17,this.i++)}catch(n){this.v=n,this.f|=16,this.i++}return T=t,pa(this),this.f&=-2,!0};mt.prototype.S=function(t){if(this.t===void 0){this.f|=36;for(var e=this.s;e!==void 0;e=e.n)e.S.S(e)}j.prototype.S.call(this,t)};mt.prototype.U=function(t){if(this.t!==void 0&&(j.prototype.U.call(this,t),this.t===void 0)){this.f&=-33;for(var e=this.s;e!==void 0;e=e.n)e.S.U(e)}};mt.prototype.N=function(){if(!(2&this.f)){this.f|=6;for(var t=this.t;t!==void 0;t=t.x)t.t.N()}};Object.defineProperty(mt.prototype,"value",{get:function(){if(1&this.f)throw new Error("Cycle detected");var t=ca(this);if(this.h(),t!==void 0&&(t.i=this.i),16&this.f)throw this.v;return this.v}});function lt(t,e){return new mt(t,e)}function va(t){var e=t.u;if(t.u=void 0,typeof e=="function"){ot++;var n=T;T=void 0;try{e()}catch(s){throw t.f&=-2,t.f|=8,es(t),s}finally{T=n,Be()}}}function es(t){for(var e=t.s;e!==void 0;e=e.n)e.S.U(e);t.x=void 0,t.s=void 0,va(t)}function Ci(t){if(T!==this)throw new Error("Out-of-order effect");pa(this),T=t,this.f&=-2,8&this.f&&es(this),Be()}function Rt(t,e){this.x=t,this.u=void 0,this.s=void 0,this.o=void 0,this.f=32,this.name=e==null?void 0:e.name}Rt.prototype.c=function(){var t=this.S();try{if(8&this.f||this.x===void 0)return;var e=this.x();typeof e=="function"&&(this.u=e)}finally{t()}};Rt.prototype.S=function(){if(1&this.f)throw new Error("Cycle detected");this.f|=1,this.f&=-9,va(this),da(this),ot++;var t=T;return T=this,Ci.bind(this,t)};Rt.prototype.N=function(){2&this.f||(this.f|=2,this.o=Mt,Mt=this)};Rt.prototype.d=function(){this.f|=8,1&this.f||es(this)};Rt.prototype.dispose=function(){this.d()};function oe(t,e){var n=new Rt(t,e);try{n.c()}catch(a){throw n.d(),a}var s=n.d.bind(n);return s[Symbol.dispose]=s,s}var fa,ve,Ai=typeof window<"u"&&!!window.__PREACT_SIGNALS_DEVTOOLS__,ma=[];oe(function(){fa=this.N})();function Lt(t,e){L[t]=e.bind(null,L[t]||function(){})}function Ne(t){if(ve){var e=ve;ve=void 0,e()}ve=t&&t.S()}function _a(t){var e=this,n=t.data,s=Ti(n);s.value=n;var a=ia(function(){for(var c=e,u=e.__v;u=u.__;)if(u.__c){u.__c.__$f|=4;break}var p=lt(function(){var v=s.value.value;return v===0?0:v===!0?"":v||""}),f=lt(function(){return!Array.isArray(p.value)&&!qs(p.value)}),l=oe(function(){if(this.N=ga,f.value){var v=p.value;c.__v&&c.__v.__e&&c.__v.__e.nodeType===3&&(c.__v.__e.data=v)}}),d=e.__$u.d;return e.__$u.d=function(){l(),d.call(this)},[f,p]},[]),i=a[0],r=a[1];return i.value?r.peek():r.value}_a.displayName="ReactiveTextNode";Object.defineProperties(j.prototype,{constructor:{configurable:!0,value:void 0},type:{configurable:!0,value:_a},props:{configurable:!0,get:function(){return{data:this}}},__b:{configurable:!0,value:1}});Lt("__b",function(t,e){if(typeof e.type=="string"){var n,s=e.props;for(var a in s)if(a!=="children"){var i=s[a];i instanceof j&&(n||(e.__np=n={}),n[a]=i,s[a]=i.peek())}}t(e)});Lt("__r",function(t,e){if(t(e),e.type!==ie){Ne();var n,s=e.__c;s&&(s.__$f&=-2,(n=s.__$u)===void 0&&(s.__$u=n=(function(a,i){var r;return oe(function(){r=this},{name:i}),r.c=a,r})(function(){var a;Ai&&((a=n.y)==null||a.call(n)),s.__$f|=1,s.setState({})},typeof e.type=="function"?e.type.displayName||e.type.name:""))),Ne(n)}});Lt("__e",function(t,e,n,s){Ne(),t(e,n,s)});Lt("diffed",function(t,e){Ne();var n;if(typeof e.type=="string"&&(n=e.__e)){var s=e.__np,a=e.props;if(s){var i=n.U;if(i)for(var r in i){var c=i[r];c!==void 0&&!(r in s)&&(c.d(),i[r]=void 0)}else i={},n.U=i;for(var u in s){var p=i[u],f=s[u];p===void 0?(p=Ni(n,u,f),i[u]=p):p.o(f,a)}for(var l in s)a[l]=s[l]}}t(e)});function Ni(t,e,n,s){var a=e in t&&t.ownerSVGElement===void 0,i=_(n),r=n.peek();return{o:function(c,u){i.value=c,r=c.peek()},d:oe(function(){this.N=ga;var c=i.value.value;r!==c?(r=void 0,a?t[e]=c:c!=null&&(c!==!1||e[4]==="-")?t.setAttribute(e,c):t.removeAttribute(e)):r=void 0})}}Lt("unmount",function(t,e){if(typeof e.type=="string"){var n=e.__e;if(n){var s=n.U;if(s){n.U=void 0;for(var a in s){var i=s[a];i&&i.d()}}}e.__np=void 0}else{var r=e.__c;if(r){var c=r.__$u;c&&(r.__$u=void 0,c.d())}}t(e)});Lt("__h",function(t,e,n,s){(s<3||s===9)&&(e.__$f|=2),t(e,n,s)});jt.prototype.shouldComponentUpdate=function(t,e){if(this.__R)return!0;var n=this.__$u,s=n&&n.s!==void 0;for(var a in e)return!0;if(this.__f||typeof this.u=="boolean"&&this.u===!0){var i=2&this.__$f;if(!(s||i||4&this.__$f)||1&this.__$f)return!0}else if(!(s||4&this.__$f)||3&this.__$f)return!0;for(var r in t)if(r!=="__source"&&t[r]!==this.props[r])return!0;for(var c in this.props)if(!(c in t))return!0;return!1};function Ti(t,e){return ia(function(){return _(t,e)},[])}var Ri=function(t){queueMicrotask(function(){queueMicrotask(t)})};function Li(){Si(function(){for(var t;t=ma.shift();)fa.call(t)})}function ga(){ma.push(this)===1&&(L.requestAnimationFrame||Ri)(Li)}const Ei=["overview","execution","board","activity","agents","tasks","goals","journal","trpg","council"],$a={tab:"overview",params:{},postId:null};function Cs(t){return!!t&&Ei.includes(t)}function Tn(t){try{return decodeURIComponent(t)}catch{return t}}function Rn(t){const e={};return t&&new URLSearchParams(t).forEach((s,a)=>{e[a]=s}),e}function Di(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function ha(t,e){const n=t[0],s=e.tab,a=Cs(n)?n:Cs(s)?s:"overview";let i=null;return a==="board"&&(t[0]==="board"&&t[1]==="post"&&t[2]?i=Tn(t[2]):t[0]==="post"&&t[1]&&(i=Tn(t[1]))),{tab:a,params:e,postId:i}}function Te(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return $a;const n=Tn(e);let s=n,a;if(n.startsWith("?"))s="",a=n.slice(1);else{const c=n.indexOf("?");c>=0&&(s=n.slice(0,c),a=n.slice(c+1))}!a&&s.includes("=")&&!s.includes("/")&&(a=s,s="");const i=Rn(a),r=Di(s);return ha(r,i)}function Pi(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const s=n.slice(1);if(s.length===0)return{...$a,params:Rn(e.replace(/^\?/,""))};if(s[0]==="assets"||s[0]==="credits"||s[0]==="lodge")return null;const a=Rn(e.replace(/^\?/,""));return ha(s,a)}function ya(t){const e=t.postId?`board/post/${encodeURIComponent(t.postId)}`:t.tab,n=Object.entries(t.params).filter(([a])=>a!=="tab");if(n.length===0)return`#${e}`;const s=new URLSearchParams(n);return`#${e}?${s.toString()}`}const Z=_(Te(window.location.hash));window.addEventListener("hashchange",()=>{Z.value=Te(window.location.hash)});function Ke(t,e){const n={tab:t,params:{},postId:null};window.location.hash=ya(n)}function Ii(t){window.location.hash=`#board/post/${encodeURIComponent(t)}`}function Oi(){if(window.location.hash&&window.location.hash!=="#"){Z.value=Te(window.location.hash);return}const t=Pi(window.location.pathname,window.location.search);if(t){Z.value=t;const e=ya(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#overview",Z.value=Te(window.location.hash)}const ba=[{id:"overview",label:"Overview",icon:"🏠"},{id:"council",label:"Council",icon:"🏛️"},{id:"board",label:"Board",icon:"💬"},{id:"activity",label:"Activity",icon:"📊"},{id:"agents",label:"Agents",icon:"🤖"},{id:"tasks",label:"Tasks",icon:"📋"},{id:"goals",label:"Goals",icon:"🎯"},{id:"execution",label:"Execution",icon:"🛠️"},{id:"journal",label:"Journal",icon:"📓"},{id:"trpg",label:"TRPG",icon:"⚔️"}];function ji(){const t=Z.value.tab;return o`
    <div class="main-tab-bar">
      ${ba.map(e=>o`
        <button
          class="main-tab-btn ${t===e.id?"active":""}"
          onClick=${()=>Ke(e.id)}
        >
          ${e.icon} ${e.label}
        </button>
      `)}
    </div>
  `}const As="masc_dashboard_sse_session_id",Mi=1e3,Fi=15e3,Nt=_(!1),ns=_(0),xa=_(null),Re=_([]);function zi(){let t=sessionStorage.getItem(As);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(As,t)),t}const Ui=200;function J(t,e){const n={agent:t,text:e,timestamp:Date.now()};Re.value=[n,...Re.value].slice(0,Ui)}let X=null,St=null,Ln=0;function ka(){St&&(clearTimeout(St),St=null)}function Hi(){if(St)return;Ln++;const t=Math.min(Ln,5),e=Math.min(Fi,Mi*Math.pow(2,t));St=setTimeout(()=>{St=null,wa()},e)}function wa(){ka(),X&&(X.close(),X=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),s=t.get("token");n&&e.set("agent",n),s&&e.set("token",s),e.set("session_id",zi());const a=e.toString()?`/sse?${e.toString()}`:"/sse",i=new EventSource(a);X=i,i.onopen=()=>{X===i&&(Ln=0,Nt.value=!0)},i.onerror=()=>{X===i&&(Nt.value=!1,i.close(),X=null,Hi())},i.onmessage=r=>{try{const c=JSON.parse(r.data);ns.value++,xa.value=c,Bi(c)}catch{}}}function Bi(t){const e=t.type,n=t.agent??t.from??t.from_agent??"";switch(e){case"agent_joined":J(n,"Joined");break;case"agent_left":J(n,"Left");break;case"broadcast":J(n,`${(t.message??t.content??"").slice(0,80)}`);break;case"task_update":J(n,`Task: ${t.task_id??""} -> ${t.status??""}`);break;case"board_post":J(n,"New post");break;case"board_comment":J(n,"New comment");break;case"keeper_heartbeat":J(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`);break;case"keeper_handoff":J(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`);break;case"keeper_compaction":J(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`);break;case"keeper_guardrail":J(t.name??n,`Guardrail: ${t.reason??"stopped"}`);break;default:J(n,e)}}function Ki(){ka(),X&&(X.close(),X=null),Nt.value=!1}function Sa(){return new URLSearchParams(window.location.search)}function Ca(){const t=Sa(),e={},n=t.get("token"),s=t.get("agent")??t.get("agent_name");return n&&(e.Authorization=`Bearer ${n}`),s&&(e["X-MASC-Agent"]=s),e}function Aa(){return{...Ca(),"Content-Type":"application/json"}}const qi=15e3,Na=3e4,Gi=6e4,Ns=new Set([408,425,429,500,502,503,504]);class re extends Error{constructor(n){const s=n.method.toUpperCase(),a=n.timeout===!0,i=a?`${s} ${n.path}: timeout after ${n.timeoutMs??0}ms`:`${s} ${n.path}: ${n.status??"unknown"} ${n.statusText??""}`.trim();super(i);ht(this,"method");ht(this,"path");ht(this,"status");ht(this,"statusText");ht(this,"timeout");this.name="ApiRequestError",this.method=s,this.path=n.path,this.status=n.status,this.statusText=n.statusText,this.timeout=a}}async function ss(t,e,n){const s=new AbortController,a=setTimeout(()=>s.abort(),n);try{return await fetch(t,{...e,signal:s.signal})}catch(i){if(i instanceof Error&&i.name==="AbortError"){const r=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new re({method:r,path:t,timeout:!0,timeoutMs:n})}throw i}finally{clearTimeout(a)}}function Ji(){var e,n;const t=Sa();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function ct(t){const e=await ss(t,{headers:Ca()},qi);if(!e.ok)throw new re({method:"GET",path:t,status:e.status,statusText:e.statusText});return e.json()}function Wi(t){return new Promise(e=>setTimeout(e,t))}function Vi(t){const e=t.match(/\b(\d{3})\b/);if(!e)return null;const n=e[1];if(!n)return null;const s=Number.parseInt(n,10);return Number.isFinite(s)?s:null}function Yi(t){if(t instanceof re)return t.timeout||typeof t.status=="number"&&Ns.has(t.status);if(!(t instanceof Error))return!1;if(/timeout after \d+ms/i.test(t.message))return!0;const e=Vi(t.message);return e!==null&&Ns.has(e)}async function le(t,e,n=2){let s=0;for(;;)try{return await e()}catch(a){if(!Yi(a)||s>=n)throw a;const i=250*(s+1);console.warn(`[dashboard/api] ${t} failed (attempt ${s+1}), retrying in ${i}ms`,a),await Wi(i),s+=1}}async function _t(t,e){const n=await ss(t,{method:"POST",headers:Aa(),body:JSON.stringify(e)},Na);if(!n.ok)throw new re({method:"POST",path:t,status:n.status,statusText:n.statusText});return n.json()}async function Qi(t,e,n,s=Na){const a=await ss(t,{method:"POST",headers:{...Aa(),...n??{}},body:JSON.stringify(e)},s);if(!a.ok)throw new re({method:"POST",path:t,status:a.status,statusText:a.statusText});return a.text()}function Xi(t){const e=t.split(`
`).find(s=>s.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function Zi(t){var e,n,s,a,i,r,c;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const u=((a=(s=t.result.content)==null?void 0:s[0])==null?void 0:a.text)??"MCP tool call failed";throw new Error(u)}return((c=(r=(i=t.result)==null?void 0:i.content)==null?void 0:r[0])==null?void 0:c.text)??""}async function H(t,e){const n=await Qi("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},Gi),s=Xi(n);return Zi(s)}function to(t="compact"){return ct(`/api/v1/dashboard?mode=${t}`)}function Tt(t){if(typeof t=="string"&&t.trim())return t;if(typeof t!="number"||Number.isNaN(t))return new Date().toISOString();const e=t<1e12?t*1e3:t;return new Date(e).toISOString()}function eo(t){var a;const e=t.trim(),s=((a=(e.startsWith("[flair:")?e.replace(/^\[flair:[^\]]+\]\s*/i,""):e).split(`
`)[0])==null?void 0:a.trim())||"Untitled post";return s.length<=96?s:`${s.slice(0,93)}...`}function Ta(t){if(!w(t))return null;const e=m(t.id,"").trim(),n=m(t.author,"").trim(),s=m(t.content,"").trim();if(!e||!n)return null;const a=N(t.score,0),i=N(t.votes_up,0),r=N(t.votes_down,0),c=N(t.votes,a||i-r),u=N(t.comment_count,N(t.reply_count,0)),p=(()=>{const $=t.flair;if(typeof $=="string"&&$.trim())return $.trim();if(w($)){const S=m($.name,"").trim();if(S)return S}return m(t.flair_name,"").trim()||void 0})(),f=m(t.created_at_iso,"").trim()||Tt(t.created_at),l=m(t.updated_at_iso,"").trim()||(t.updated_at!==void 0?Tt(t.updated_at):f),v=m(t.title,"").trim()||eo(s);return{id:e,author:n,title:v,content:s,tags:[],votes:c,vote_balance:a,comment_count:u,created_at:f,updated_at:l,flair:p,hearth_count:N(t.hearth_count,0)}}function no(t){if(!w(t))return null;const e=m(t.id,"").trim(),n=m(t.post_id,"").trim(),s=m(t.author,"").trim();return!e||!s?null:{id:e,post_id:n,author:s,content:m(t.content,""),created_at:Tt(t.created_at)}}async function so(t){return le("fetchBoard",async()=>{const e=new URLSearchParams;t&&e.set("sort_by",t),e.set("limit","100");const n=e.toString(),s=await ct(`/api/v1/board${n?`?${n}`:""}`);return{posts:Array.isArray(s.posts)?s.posts.map(Ta).filter(i=>i!==null):[]}})}async function ao(t){return le("fetchBoardPost",async()=>{const e=await ct(`/api/v1/board/${t}?format=flat`),n=w(e.post)?e.post:e,s=Ta(n)??{id:t,author:"unknown",title:"Post",content:"",tags:[],votes:0,comment_count:0,created_at:new Date().toISOString(),updated_at:new Date().toISOString()},i=(Array.isArray(e.comments)?e.comments:[]).map(no).filter(r=>r!==null);return{...s,comments:i}})}function Ra(t,e){return _t("/api/v1/tools/masc_board_vote",{post_id:t,direction:e,vote:e,voter:Ji()})}function io(t,e,n){return _t("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function oo(t){const e=m(t,"").trim().toLowerCase();if(e==="win"||e==="won"||e==="victory")return"victory";if(e==="lose"||e==="lost"||e==="defeat")return"defeat";if(e==="draw"||e==="stalemate"||e==="tie")return"draw"}function z(...t){for(const e of t){const n=m(e,"");if(n.trim())return n.trim()}return""}function Ts(t){const e=oo(z(t.outcome,t.result,t.result_code));if(!e)return;const n=z(t.reason,t.reason_code,t.description,t.detail),s=z(t.summary,t.summary_ko,t.summary_en,t.note),a=z(t.details,t.details_text,t.text,t.note),i=z(t.winner,t.winner_name,t.actor_winner,t.winner_actor),r=z(t.winner_actor_id,t.winner_actor,t.actor_winner_id),c=z(t.raw_reason,t.raw_reason_code,t.error_message),u=(()=>{const l=t.evidence??t.evidence_ids??t.supporting_events??t.event_ids??[];return typeof l=="string"?[l]:Array.isArray(l)?l.map(d=>{if(typeof d=="string")return d.trim();if(w(d)){const v=m(d.summary,"").trim();if(v)return v;const $=m(d.text,"").trim();if($)return $;const x=m(d.type,"").trim();return x||m(d.event_id,"").trim()}return""}).filter(d=>d.length>0):[]})(),p=(()=>{const l=N(t.turn,Number.NaN);if(Number.isFinite(l))return l;const d=N(t.turn_number,Number.NaN);if(Number.isFinite(d))return d;const v=N(t.current_turn,Number.NaN);if(Number.isFinite(v))return v;const $=N(t.round,Number.NaN);return Number.isFinite($)?$:void 0})(),f=z(t.phase,t.phase_name,t.current_phase,t.phase_id);return{result:e,reason:n||void 0,summary:s||void 0,details:a||void 0,winner:i||void 0,winner_actor_id:r||void 0,evidence:u.length>0?u:void 0,raw_reason:c||void 0,turn:p,phase:f||void 0}}function ro(t,e){const n=w(t.state)?t.state:{};if(m(n.status,"active").toLowerCase()!=="ended")return;const a=[...e].reverse().find(r=>w(r)?m(r.type,"")==="session.outcome":!1),i=w(n.session_outcome)?n.session_outcome:{};if(w(i)&&Object.keys(i).length>0){const r=Ts(i);if(r)return r}if(w(a))return Ts(w(a.payload)?a.payload:{})}function w(t){return typeof t=="object"&&t!==null}function m(t,e=""){return typeof t=="string"?t:e}function N(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function lo(t){if(typeof t=="number"&&Number.isFinite(t))return Math.trunc(t);if(typeof t=="string"){const e=Number.parseInt(t.trim(),10);if(Number.isFinite(e))return e}}function En(t,e=!1){return typeof t=="boolean"?t:e}function It(t){return Array.isArray(t)?t.map(e=>{if(typeof e=="string")return e.trim();if(w(e)){const n=m(e.name,"").trim(),s=m(e.id,"").trim(),a=m(e.skill,"").trim();return n||s||a}return""}).filter(e=>e.length>0):[]}function co(t){const e={};if(!w(t)&&!Array.isArray(t))return e;if(w(t))return Object.entries(t).forEach(([n,s])=>{const a=n.trim(),i=m(s,"").trim();!a||!i||(e[a]=i)}),e;for(const n of t){if(!w(n))continue;const s=z(n.to,n.target,n.actor_id,n.name,n.id),a=z(n.relationship,n.relation,n.type,n.kind);!s||!a||(e[s]=a)}return e}function uo(t,e,n){if(t==="dm"||t==="player"||t==="npc")return t;const s=e.trim().toLowerCase();return s==="dm"||s.startsWith("dm-")?"dm":s.startsWith("npc-")||s.startsWith("enemy-")||s.startsWith("mob-")?"npc":/^p\d+$/i.test(s)||s.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function B(t,e,n,s=0){const a=t[e];if(typeof a=="number"&&Number.isFinite(a))return a;if(n){const i=t[n];if(typeof i=="number"&&Number.isFinite(i))return i}return s}const po=new Set(["str","dex","con","int","wis","cha","strength","dexterity","constitution","intelligence","wisdom","charisma","hp","max_hp","mp","max_mp","level","xp"]);function vo(t){const e=w(t.stats)?t.stats:{},n={};return Object.entries(e).forEach(([s,a])=>{const i=s.trim();i&&(po.has(i.toLowerCase())||typeof a=="number"&&Number.isFinite(a)&&(n[i]=a))}),n}function fo(t,e){if(t!=="dice.rolled")return;const n=N(e.raw_d20,0),s=N(e.total,0),a=N(e.bonus,0),i=m(e.action,"roll"),r=N(e.dc,0);return{notation:r>0?`${i} (DC ${r})`:i,rolls:n>0?[n]:[],total:s,modifier:a}}function mo(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function _o(t){const e=t.trim().toLowerCase();return e?e.startsWith("dice.")?"dice":e.startsWith("combat.")||e.includes(".attack")||e.includes(".damage")?"combat":e.includes("actor.")?"actor":e.includes("turn.")||e==="turn.started"||e==="phase.changed"?"turn":e.includes("join.")?"join":e.includes("memory")?"memory":e.includes("world.")?"world":e.includes("narration")?"story":"meta":"meta"}function go(t,e,n,s){const a=n||e||m(s.actor_id,"")||m(s.actor_name,"");switch(t){case"turn.action.proposed":{const i=m(s.proposed_action,m(s.reply,""));return i?`${a||"actor"}: ${i}`:"Action proposed"}case"turn.action.resolved":{const i=m(s.reply,m(s.result,""));return i?`Resolved: ${i}`:"Action resolved"}case"narration.posted":return m(s.reply,m(s.content,m(s.text,"Narration")));case"dice.rolled":{const i=m(s.action,"roll"),r=N(s.total,0),c=N(s.dc,0),u=m(s.label,""),p=a||"actor",f=c>0?` vs DC ${c}`:"",l=u?` (${u})`:"";return`${p} ${i}: ${r}${f}${l}`}case"turn.started":return`Turn ${N(s.turn,1)} started`;case"phase.changed":return`Phase: ${m(s.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${m(s.name,w(s.actor)?m(s.actor.name,a||"unknown"):a||"unknown")}`;case"actor.claimed":return`${m(s.keeper_name,m(s.keeper,"keeper"))} claimed ${a||"actor"}`;case"actor.released":return`${m(s.keeper_name,m(s.keeper,"keeper"))} released ${a||"actor"}`;case"join.window.opened":return`Join window opened (turn ${N(s.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${N(s.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${a||m(s.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${a||m(s.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${m(s.reason_code,"unknown")}`;case"memory.signal":{const i=w(s.entity_refs)?s.entity_refs:{},r=m(i.requested_tier,""),c=m(i.effective_tier,""),u=En(i.guardrail_applied,!1),p=m(s.summary_en,m(s.summary_ko,"Memory signal"));if(!r&&!c)return p;const f=r&&c?`${r}->${c}`:c||r;return`${p} [${f}${u?" (guardrail)":""}]`}case"world.event":{if(m(s.event_type,"")==="canon.check"){const r=m(s.status,"unknown"),c=m(s.contract_id,"n/a");return`Canon ${r}: ${c}`}return m(s.description,m(s.summary,"World event"))}case"combat.attack":return m(s.summary,m(s.result,"Attack resolved"));case"combat.defense":return m(s.summary,m(s.result,"Defense resolved"));case"session.outcome":return m(s.summary,m(s.outcome,"Session ended"));default:{const i=mo(s);return i?`${t}: ${i}`:t}}}function $o(t,e){const n=w(t)?t:{},s=m(n.type,"event"),a=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",i=m(n.actor_name,"").trim()||e[a]||m(w(n.payload)?n.payload.actor_name:"",""),r=w(n.payload)?n.payload:{},c=m(n.ts,m(n.timestamp,new Date().toISOString())),u=m(n.phase,m(r.phase,"")),p=m(n.category,"");return{type:s,actor:i||a||m(r.actor_name,""),actor_id:a||m(r.actor_id,""),actor_name:i,seq:n.seq,room_id:m(n.room_id,""),phase:u||void 0,category:p||_o(s),visibility:m(n.visibility,m(r.visibility,"public")),event_id:m(n.event_id,""),content:go(s,a,i,r),dice_roll:fo(s,r),timestamp:c}}function ho(t,e,n){var G,et;const s=m(t.room_id,"")||n||"default",a=w(t.state)?t.state:{},i=w(a.party)?a.party:{},r=w(a.actor_control)?a.actor_control:{},c=w(a.join_gate)?a.join_gate:{},u=w(a.contribution_ledger)?a.contribution_ledger:{},p=Object.entries(i).map(([R,O])=>{const g=w(O)?O:{},ue=B(g,"max_hp",void 0,10),us=B(g,"hp",void 0,ue),ti=B(g,"max_mp",void 0,0),ei=B(g,"mp",void 0,0),ni=B(g,"level",void 0,1),si=B(g,"xp",void 0,0),ai=En(g.alive,us>0),ds=r[R],ps=typeof ds=="string"?ds:void 0,ii=uo(g.role,R,ps),oi=lo(g.generation),ri=z(g.joined_at,g.joinedAt,g.started_at,g.startedAt),li=z(g.claimed_at,g.claimedAt,g.assigned_at,g.assignedAt,g.assigned_time),ci=z(g.last_seen,g.lastSeen,g.last_seen_at,g.lastSeenAt,g.last_active,g.lastActive),ui=z(g.scene,g.current_scene,g.currentScene,g.world_scene,g.scene_name,g.sceneName),di=z(g.location,g.current_location,g.currentLocation,g.position,g.zone,g.area);return{id:R,name:m(g.name,R),role:ii,keeper:ps,archetype:m(g.archetype,""),persona:m(g.persona,""),portrait:m(g.portrait,"")||void 0,background:m(g.background,"")||void 0,traits:It(g.traits),skills:It(g.skills),stats_raw:vo(g),status:ai?"active":"dead",generation:oi,joined_at:ri||void 0,claimed_at:li||void 0,last_seen:ci||void 0,scene:ui||void 0,location:di||void 0,inventory:It(g.inventory),notes:It(g.notes),relationships:co(g.relationships),stats:{hp:us,max_hp:ue,mp:ei,max_mp:ti,level:ni,xp:si,strength:B(g,"strength","str",10),dexterity:B(g,"dexterity","dex",10),constitution:B(g,"constitution","con",10),intelligence:B(g,"intelligence","int",10),wisdom:B(g,"wisdom","wis",10),charisma:B(g,"charisma","cha",10)}}}),f=p.filter(R=>R.status!=="dead"),l=ro(t,e),d={phase_open:En(c.phase_open,!0),min_points:N(c.min_points,3),window:m(c.window,"round_boundary_only"),last_opened_turn:typeof c.last_opened_turn=="number"?c.last_opened_turn:null,last_closed_turn:typeof c.last_closed_turn=="number"?c.last_closed_turn:null},v=Object.entries(u).map(([R,O])=>{const g=w(O)?O:{};return{actor_id:R,score:N(g.score,0),last_reason:m(g.last_reason,"")||null,reasons:It(g.reasons)}}),$=p.reduce((R,O)=>(R[O.id]=O.name,R),{}),x=e.map(R=>$o(R,$)),S=N(a.turn,1),A=m(a.phase,"round"),C=m(a.map,""),D=w(a.world)?a.world:{},M=C||m(D.ascii_map,m(D.map,"")),E=x.filter((R,O)=>{const g=e[O];if(!w(g))return!1;const ue=w(g.payload)?g.payload:{};return N(ue.turn,-1)===S}),q=(E.length>0?E:x).slice(-12),ut=m(a.status,"active");return{session:{id:s,room:s,status:ut==="ended"?"ended":ut==="paused"?"paused":"active",round:S,actors:f,created_at:((G=x[0])==null?void 0:G.timestamp)??new Date().toISOString()},current_round:{round_number:S,phase:A,events:q,timestamp:((et=x[x.length-1])==null?void 0:et.timestamp)??new Date().toISOString()},map:M||void 0,join_gate:d,contribution_ledger:v,outcome:l,party:f,story_log:x,history:[]}}async function yo(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await ct(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function bo(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,s]=await Promise.all([ct(`/api/v1/trpg/state${e}`),yo(t)]);return ho(n,s,t)}function xo(t){return _t("/api/v1/trpg/rounds/run",{room_id:t})}function ko(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function wo(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),_t("/api/v1/trpg/dice/roll",e)}function So(t,e){const n=ko();return _t("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}function Co(t,e){const n={room_id:t};return e.actor_id&&e.actor_id.trim()&&(n.actor_id=e.actor_id.trim()),e.name&&e.name.trim()&&(n.name=e.name.trim()),e.role&&(n.role=e.role),e.archetype&&e.archetype.trim()&&(n.archetype=e.archetype.trim()),e.persona&&e.persona.trim()&&(n.persona=e.persona.trim()),e.portrait&&e.portrait.trim()&&(n.portrait=e.portrait.trim()),e.background&&e.background.trim()&&(n.background=e.background.trim()),e.hp!=null&&(n.hp=e.hp),e.max_hp!=null&&(n.max_hp=e.max_hp),e.alive!=null&&(n.alive=e.alive),Array.isArray(e.traits)&&e.traits.length>0&&(n.traits=e.traits),Array.isArray(e.skills)&&e.skills.length>0&&(n.skills=e.skills),Array.isArray(e.inventory)&&e.inventory.length>0&&(n.inventory=e.inventory),e.stats&&Object.keys(e.stats).length>0&&(n.stats=e.stats),_t("/api/v1/trpg/actors/spawn",n)}function Ao(t,e,n){return _t("/api/v1/trpg/actors/claim",{room_id:t,actor_id:e,keeper:n})}async function No(t,e,n){const s=await H("trpg.join.eligibility",{room_id:t,actor_id:e,...n?{keeper_name:n}:{}});return JSON.parse(s)}async function To(t){const e=await H("trpg.mid_join.request",t);return JSON.parse(e)}async function La(t,e){await H("masc_broadcast",{agent_name:t,message:e})}async function Ro(t,e,n=1){await H("masc_add_task",{title:t,description:e,priority:n})}async function Lo(t){return H("masc_join",{agent_name:t})}async function Ea(t){await H("masc_leave",{agent_name:t})}async function Eo(t){await H("masc_heartbeat",{agent_name:t})}async function Do(t=40){return(await H("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function Po(t,e=20){return H("masc_task_history",{task_id:t,limit:e})}async function Io(){return le("fetchDebates",async()=>{const t=await ct("/api/v1/council/debates?limit=100");return Array.isArray(t.debates)?t.debates.map(e=>{if(!w(e))return null;const n=m(e.id,"").trim(),s=m(e.topic,"").trim();return!n||!s?null:{id:n,topic:s,status:m(e.status,"open"),argument_count:N(e.argument_count,0),created_at:Tt(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]})}async function Oo(){return le("fetchCouncilSessions",async()=>{const t=await ct("/api/v1/council/sessions?limit=100");return Array.isArray(t.sessions)?t.sessions.map(e=>{if(!w(e))return null;const n=m(e.id,"").trim(),s=m(e.topic,"").trim();return!n||!s?null:{id:n,topic:s,initiator:m(e.initiator,"system"),votes:N(e.votes,0),quorum:N(e.quorum,0),state:m(e.state,"open"),created_at:Tt(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]})}async function jo(t){const e=await H("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}async function Mo(t){return le("fetchDebateStatus",async()=>{const e=encodeURIComponent(t),n=await ct(`/api/v1/council/debates/${e}/summary`);if(!w(n))return null;const s=m(n.id,"").trim();return s?{id:s,topic:m(n.topic,""),status:m(n.status,"open"),support_count:N(n.support_count,0),oppose_count:N(n.oppose_count,0),neutral_count:N(n.neutral_count,0),total_arguments:N(n.total_arguments,0),created_at:Tt(n.created_at_iso??n.created_at),summary_text:m(n.summary_text,"")}:null})}async function Fo(){try{const t=await H("masc_goal_list",{});if(typeof t=="string"){const e=JSON.parse(t);return Array.isArray(e)?e:e.goals??[]}return Array.isArray(t)?t:t.goals??[]}catch{return[]}}const Et=_([]),ce=_([]),Da=_([]),Dt=_([]),gt=_(null),Ot=_(null),Dn=_(new Map),Pa=_([]),Pn=_("hot"),Ia=_(null),st=_(""),qe=_([]),Ft=_(!1),In=_(!1),On=_(!1),jn=_(!1),Oa=lt(()=>Et.value.filter(t=>t.status==="active"||t.status==="idle")),as=lt(()=>{const t=ce.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}});function zo(t){var a;const e=t.metrics_series;if(!e||e.length===0){const i=((a=t.status)==null?void 0:a.toLowerCase())??"";return i==="offline"||i==="inactive"?"offline":"idle"}const n=e[e.length-1];if(!n)return"idle";if(n.is_handoff)return"handoff-imminent";if(n.is_compaction)return"compacting";const s=n.context_ratio;return s>.85?"handoff-imminent":s>.7?"preparing":s>.5?"compacting":"active"}const Uo=lt(()=>{const t=new Map;for(const e of Dt.value)t.set(e.name,zo(e));return t}),Ho=12e4,Bo=lt(()=>{const t=Date.now(),e=new Set,n=Dn.value;for(const s of Dt.value){const a=n.get(s.name);a!=null&&t-a>Ho&&e.add(s.name)}return e}),Le={},Ko=5e3;function Mn(){delete Le.compact,delete Le.full}function V(t){return typeof t=="object"&&t!==null}function h(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function k(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function zt(t){if(!Array.isArray(t))return;const e=t.filter(n=>typeof n=="string"&&n.trim()!=="");return e.length>0?e:void 0}function ja(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="idle"||e==="inactive"||e==="offline"?e:e==="busy"||e==="in_progress"||e==="claimed"?"active":"offline"}function qo(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function Go(t){if(!V(t))return null;const e=h(t.name);return e?{name:e,status:ja(t.status),current_task:h(t.current_task)??null,last_seen:h(t.last_seen),emoji:h(t.emoji),koreanName:h(t.koreanName)??h(t.korean_name),model:h(t.model),traits:zt(t.traits),interests:zt(t.interests),activityLevel:k(t.activityLevel)??k(t.activity_level),primaryValue:h(t.primaryValue)??h(t.primary_value)}:null}function Jo(t){if(!V(t))return null;const e=h(t.id),n=h(t.title);return!e||!n?null:{id:e,title:n,status:qo(t.status),priority:k(t.priority),assignee:h(t.assignee),description:h(t.description),created_at:h(t.created_at),updated_at:h(t.updated_at)}}function Wo(t){if(!V(t))return null;const e=h(t.from)??h(t.from_agent)??"system",n=h(t.content)??"",s=h(t.timestamp)??new Date().toISOString();return{id:h(t.id),seq:k(t.seq),from:e,content:n,timestamp:s,type:h(t.type)}}function Vo(t){return Array.isArray(t)?t.map(e=>{if(!V(e))return null;const n=k(e.ts_unix);if(n==null)return null;const s=V(e.handoff)?e.handoff:null;return{ts:n,context_ratio:k(e.context_ratio)??0,context_tokens:k(e.context_tokens)??0,context_max:k(e.context_max)??0,latency_ms:k(e.latency_ms)??0,generation:k(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:s!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:k(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:k(e.cost_usd)??0,handoff_to_model:s&&typeof s.to_model=="string"?s.to_model:null,handoff_new_generation:s?k(s.new_generation)??null:null}}).filter(e=>e!==null):[]}function Yo(t){return(Array.isArray(t)?t:V(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(n=>{if(!V(n))return null;const s=V(n.agent)?n.agent:null,a=V(n.context)?n.context:null,i=V(n.metrics_window)?n.metrics_window:void 0,r=h(n.name);if(!r)return null;const c=k(n.context_ratio)??k(a==null?void 0:a.context_ratio),u=h(n.status)??h(s==null?void 0:s.status)??"offline",p=ja(u),f=h(n.model)??h(n.active_model)??h(n.primary_model),l=zt(n.skill_secondary),d=a?{source:h(a.source),context_ratio:k(a.context_ratio),context_tokens:k(a.context_tokens),context_max:k(a.context_max),message_count:k(a.message_count),has_checkpoint:typeof a.has_checkpoint=="boolean"?a.has_checkpoint:void 0}:void 0,v=s?{name:h(s.name),status:h(s.status),current_task:h(s.current_task)??null,last_seen:h(s.last_seen)}:void 0,$=Vo(n.metrics_series);return{name:r,emoji:h(n.emoji),koreanName:h(n.koreanName)??h(n.korean_name),agent_name:h(n.agent_name),trace_id:h(n.trace_id),model:f,primary_model:h(n.primary_model),active_model:h(n.active_model),next_model_hint:h(n.next_model_hint)??null,status:p,last_heartbeat:h(n.last_heartbeat)??h(s==null?void 0:s.last_seen),generation:k(n.generation),turn_count:k(n.turn_count)??k(n.total_turns),context_ratio:c,context_tokens:k(n.context_tokens)??k(a==null?void 0:a.context_tokens),context_max:k(n.context_max)??k(a==null?void 0:a.context_max),context_source:h(n.context_source)??h(a==null?void 0:a.source),context:d,traits:zt(n.traits),interests:zt(n.interests),primaryValue:h(n.primaryValue)??h(n.primary_value),activityLevel:k(n.activityLevel)??k(n.activity_level),memory_recent_note:h(n.memory_recent_note)??null,conversation_tail_count:k(n.conversation_tail_count),k2k_count:k(n.k2k_count),handoff_count_total:k(n.handoff_count_total)??k(n.trace_history_count),compaction_count:k(n.compaction_count),last_compaction_saved_tokens:k(n.last_compaction_saved_tokens),skill_primary:h(n.skill_primary)??null,skill_secondary:l,skill_reason:h(n.skill_reason)??null,metrics_series:$.length>0?$:void 0,metrics_window:i,agent:v}}).filter(n=>n!==null)}async function Ge(t="full"){var s,a,i;const e=Date.now(),n=Le[t];if(!(n&&e-n.time<Ko)){In.value=!0;try{const r=await to(t);Le[t]={data:r,time:e},Et.value=(Array.isArray((s=r.agents)==null?void 0:s.agents)?r.agents.agents:[]).map(Go).filter(c=>c!==null),ce.value=(Array.isArray((a=r.tasks)==null?void 0:a.tasks)?r.tasks.tasks:[]).map(Jo).filter(c=>c!==null),Da.value=(Array.isArray((i=r.messages)==null?void 0:i.messages)?r.messages.messages:[]).map(Wo).filter(c=>c!==null),Dt.value=Yo(r.keepers),gt.value=V(r.status)?r.status:null,Ot.value=r.perpetual??null}catch(r){console.error("Dashboard fetch error:",r)}finally{In.value=!1}}}async function $t(){On.value=!0;try{const t=await so(Pn.value);Pa.value=t.posts??[]}catch(t){console.error("Board fetch error:",t)}finally{On.value=!1}}async function at(){var t;jn.value=!0;try{const e=st.value||((t=gt.value)==null?void 0:t.room)||"default";st.value||(st.value=e);const n=await bo(e);Ia.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{jn.value=!1}}async function Fn(){Ft.value=!0;try{const t=await Fo();qe.value=Array.isArray(t)?t:[]}catch(t){console.error("Goals fetch error:",t)}finally{Ft.value=!1}}let Ye=null,Qe=null;function Qo(){return xa.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map(Dn.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),Dn.value=n}Mn(),Ye||(Ye=setTimeout(()=>{Ge(),Ye=null},500)),(e.type==="board_post"||e.type==="board_comment")&&(Qe||(Qe=setTimeout(()=>{$t(),Qe=null},500))),(e.type==="keeper_handoff"||e.type==="keeper_compaction"||e.type==="keeper_guardrail")&&Mn()}})}let Ut=null;function Xo(){Ut||(Ut=setInterval(()=>{Mn(),Ge()},1e4))}function Zo(){Ut&&(clearInterval(Ut),Ut=null)}function y({title:t,class:e,children:n}){return o`
    <div class="card ${e??""}">
      ${t?o`<div class="card-title">${t}</div>`:null}
      ${n}
    </div>
  `}function tt({status:t,label:e}){return o`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??t}
    </span>
  `}function tr(t){const e=Date.now(),n=typeof t=="number"?t<1e12?t*1e3:t:new Date(t).getTime(),s=Math.floor((e-n)/1e3);if(s<60)return`${s}s ago`;const a=Math.floor(s/60);if(a<60)return`${a}m ago`;const i=Math.floor(a/60);return i<24?`${i}h ago`:`${Math.floor(i/24)}d ago`}function F({timestamp:t}){const e=tr(t),n=typeof t=="string"?t:new Date(t<1e12?t*1e3:t).toISOString();return o`<span class="time-ago" title=${n}>${e}</span>`}const is=_(null);function Ma(t){is.value=t}function Rs(){is.value=null}const xt=[{level:"L1_Reactive",label:"L1 Reactive",color:"#6b7280"},{level:"L2_Suggestive",label:"L2 Suggestive",color:"#3b82f6"},{level:"L3_Guided",label:"L3 Guided",color:"#f59e0b"},{level:"L4_Autonomous",label:"L4 Autonomous",color:"#f97316"},{level:"L5_Independent",label:"L5 Independent",color:"#ef4444"}];function er(t){if(!t)return 0;const e=xt.findIndex(n=>n.level===t);return e>=0?e:0}function nr({keeper:t}){const e=er(t.autonomy_level),n=xt[e]??xt[0];if(!n)return null;const s=(e+1)/xt.length*100;return o`
    <div class="keeper-signal-list">
      <div style="margin-bottom:8px;">
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:4px;">
          <span style="font-size:13px; font-weight:600; color:${n.color};">${n.label}</span>
          <span style="font-size:11px; color:#888;">${e+1} / ${xt.length}</span>
        </div>
        <div style="width:100%; height:6px; background:#1a1a2e; border-radius:3px; overflow:hidden;">
          <div style="width:${s}%; height:100%; background:${n.color}; border-radius:3px; transition:width 0.3s;"></div>
        </div>
        <div style="display:flex; justify-content:space-between; margin-top:2px;">
          ${xt.map((a,i)=>o`
            <span style="width:8px; height:8px; border-radius:50%; background:${i<=e?a.color:"#333"}; display:inline-block;"></span>
          `)}
        </div>
      </div>
      <div class="keeper-signal-row">
        <span>Autonomous actions</span>
        <strong>${t.autonomous_action_count??0}</strong>
      </div>
      ${t.last_autonomous_action_at?o`<div class="keeper-signal-row">
            <span>Last autonomous action</span>
            <strong><${F} timestamp=${t.last_autonomous_action_at} /></strong>
          </div>`:null}
      ${t.active_goal_ids&&t.active_goal_ids.length>0?o`<div class="keeper-signal-row">
            <span>Active goals</span>
            <strong>${t.active_goal_ids.length}</strong>
          </div>`:null}
    </div>
  `}function ke(t){return t?t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}K`:String(t):"—"}function sr({keeper:t}){const e=t.metrics_series??[],n=e[e.length-1],s=(n==null?void 0:n.cost_usd)!=null?`$${n.cost_usd.toFixed(4)}`:"—",a=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return o`
    <div class="keeper-kpis">
      ${a.map(i=>o`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${i.label}</div>
          <div class="keeper-kpi-value">${i.value}</div>
          ${i.hint?o`<div class="keeper-kpi-hint">${i.hint}</div>`:null}
        </div>
      `)}
      <div class="kpi-tile">
        <div class="kpi-value">${ke(t.context_tokens)}</div>
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
        <div class="kpi-value">${s}</div>
        <div class="kpi-label">Cost (USD)</div>
      </div>
    </div>
  `}function ar({keeper:t}){var f,l;const e=t.metrics_series??[];if(e.length<2){const d=(((f=t.context)==null?void 0:f.context_ratio)??0)*100,v=d>85?"#ef4444":d>70?"#f59e0b":"#22c55e";return o`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${d.toFixed(1)}%;background:${v}"></div>
        </div>
        <span class="chart-pct">${d.toFixed(1)}%</span>
      </div>`}const n=200,s=60,a=2,i=e.length,r=e.map((d,v)=>{const $=a+v/(i-1)*(n-2*a),x=s-a-(d.context_ratio??0)*(s-2*a);return{x:$,y:x,p:d}}),c=r.map(({x:d,y:v})=>`${d.toFixed(1)},${v.toFixed(1)}`).join(" "),u=(((l=e[e.length-1])==null?void 0:l.context_ratio)??0)*100,p=u>85?"#ef4444":u>70?"#f59e0b":"#22c55e";return o`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${s}" width="${n}" height="${s}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${a}" y1="${(s-a-.5*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.5*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.7*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.7*(s-2*a)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${a}" y1="${(s-a-.85*(s-2*a)).toFixed(1)}" x2="${n-a}" y2="${(s-a-.85*(s-2*a)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${r.filter(({p:d})=>d.is_handoff).map(({x:d})=>o`
          <line x1="${d.toFixed(1)}" y1="${a}" x2="${d.toFixed(1)}" y2="${s-a}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${c}" fill="none" stroke="${p}" stroke-width="1.5"/>
        ${r.filter(({p:d})=>d.is_compaction).map(({x:d,y:v})=>o`
          <circle cx="${d.toFixed(1)}" cy="${v.toFixed(1)}" r="2.5" fill="#a855f7"/>
        `)}
      </svg>
      <span class="chart-pct">${u.toFixed(1)}%</span>
    </div>`}const Xe=_("");function ir({keeper:t}){var a,i,r,c;const e=Xe.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji??"-"},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((a=t.traits)==null?void 0:a.join(", "))||"-"},{title:"Interests",key:"interests",value:((i=t.interests)==null?void 0:i.join(", "))||"-"}],s=e?n.filter(u=>u.title.toLowerCase().includes(e)||u.key.includes(e)||u.value.toLowerCase().includes(e)):n;return o`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${Xe.value}
        onInput=${u=>{Xe.value=u.target.value}}
      />
      ${s.map(u=>o`
        <div class="keeper-field-row">
          <span class="keeper-field-title">${u.title}</span>
          <span class="keeper-field-key">${u.key}</span>
          <span style="flex:1; text-align:right; color:#ccc;">${u.value}</span>
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
      ${t.context_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Tokens</span><span style="flex:1; text-align:right; color:#ccc;">${ke(t.context_tokens)}</span></div>`:""}
      ${t.context_max!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Max</span><span style="flex:1; text-align:right; color:#ccc;">${ke(t.context_max)}</span></div>`:""}
      ${t.memory_recent_note?o`<div class="keeper-field-row"><span class="keeper-field-title">Memory Note</span><span style="flex:1; text-align:right; color:#ccc;">${t.memory_recent_note}</span></div>`:""}
      ${t.k2k_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">K2K Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.k2k_count}</span></div>`:""}
      ${t.conversation_tail_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Conv Tail</span><span style="flex:1; text-align:right; color:#ccc;">${t.conversation_tail_count}</span></div>`:""}
      ${t.handoff_count_total!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Total Handoffs</span><span style="flex:1; text-align:right; color:#ccc;">${t.handoff_count_total}</span></div>`:""}
      ${t.compaction_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Compactions</span><span style="flex:1; text-align:right; color:#ccc;">${t.compaction_count}</span></div>`:""}
      ${t.last_compaction_saved_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Last Compact Saved</span><span style="flex:1; text-align:right; color:#ccc;">${ke(t.last_compaction_saved_tokens)}</span></div>`:""}
      ${((r=t.context)==null?void 0:r.message_count)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.message_count}</span></div>`:""}
      ${((c=t.context)==null?void 0:c.has_checkpoint)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function or({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return o`
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
        ${[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}].map(s=>o`
          <div style="text-align:center; padding:6px; background:rgba(255,255,255,0.03); border-radius:6px;">
            <div style="font-size:10px; color:#888; text-transform:uppercase;">${s.label}</div>
            <div style="font-size:16px; font-weight:bold; color:#e0e0e0;">${s.value}</div>
          </div>
        `)}
      </div>
      <div style="margin-top:8px; font-size:12px; color:#888;">
        Level ${t.level} — XP ${t.xp}
      </div>
    </div>
  `}function rr({items:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No equipment</div>`:o`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>o`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function lr({rels:t}){const e=Object.entries(t);return e.length===0?o`<div class="empty-state" style="font-size:13px">No relationships</div>`:o`
    <div class="keeper-k2k-list">
      ${e.map(([n,s])=>o`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${s}</span>
        </div>
      `)}
    </div>
  `}function Ls({traits:t,label:e}){return t.length===0?null:o`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>o`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function Ze(t){return t==null||Number.isNaN(t)?"-":`${Math.round(t*100)}%`}function cr({keeper:t}){const e=t.metrics_window,n=[{label:"Model fallback",value:Ze(typeof(e==null?void 0:e.model_fallback_rate)=="number"?e.model_fallback_rate:void 0)},{label:"Proactive fallback",value:Ze(typeof(e==null?void 0:e.proactive_fallback_rate)=="number"?e.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:Ze(typeof(e==null?void 0:e.memory_pass_rate)=="number"?e.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(e==null?void 0:e.handoff_count)=="number"?e.handoff_count:t.handoff_count_total??"-"},{label:"Compactions",value:typeof(e==null?void 0:e.compaction_events)=="number"?e.compaction_events:t.compaction_count??"-"},{label:"Saved tokens",value:typeof(e==null?void 0:e.compaction_saved_tokens)=="number"?e.compaction_saved_tokens:t.last_compaction_saved_tokens??"-"},{label:"K2K events",value:t.k2k_count??"-"},{label:"Conversation tail",value:t.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(e==null?void 0:e.tool_call_count)=="number"?e.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(e==null?void 0:e.proactive_preview_similarity_avg)=="number"?`${(e.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(e==null?void 0:e.memory_avg_score)=="number"?e.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(e==null?void 0:e.fallback_rate)=="number"?`${(e.fallback_rate*100).toFixed(1)}%`:"-"}];return o`
    <div class="keeper-signal-list">
      ${n.map(s=>o`
        <div class="keeper-signal-row">
          <span>${s.label}</span>
          <strong>${s.value}</strong>
        </div>
      `)}
    </div>
  `}function ur({keeperName:t}){const[e,n]=pe("Loading internal monologue..."),[s,a]=pe(""),[i,r]=pe([]),[c,u]=pe(!1),p=async()=>{try{const l=await H("masc_keeper_status",{name:t,fast:!1,include_history_tail:!0,include_context:!0});n(typeof l=="string"?l:JSON.stringify(l,null,2))}catch(l){n("Failed to load: "+String(l))}};ft(()=>{p()},[t]);const f=async()=>{if(!s.trim())return;u(!0);const l=s;a(""),r(d=>[...d,{role:"You",text:l}]);try{const d=await H("masc_keeper_msg",{name:t,message:l});r(v=>[...v,{role:t,text:typeof d=="string"?d:JSON.stringify(d)}]),p()}catch(d){r(v=>[...v,{role:"System",text:"Error: "+String(d)}])}finally{u(!1)}};return o`
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
              value=${s} 
              onInput=${l=>a(l.currentTarget.value)} 
              onKeyDown=${l=>l.key==="Enter"&&!l.shiftKey&&f()}
              placeholder="Ping the agent..."
              disabled=${c}
              style="flex: 1; background: rgba(255,255,255,0.05); border: 1px solid var(--border); border-radius: 8px; padding: 8px 12px; color: var(--text-primary); font-family: var(--font-body);"
            />
            <button 
              onClick=${f} 
              disabled=${c||!s.trim()}
              style="background: var(--accent-cyan); color: #000; border: none; border-radius: 8px; padding: 8px 16px; font-weight: bold; cursor: pointer; opacity: ${c?.5:1};"
            >
              ${c?"Sending...":"Send"}
            </button>
          </div>
        </div>

        <!-- Monologue / Status Area -->
        <div style="background: #050810; border: 1px solid var(--card-border); border-radius: 12px; padding: 12px; height: 345px; overflow-y: auto; font-family: monospace; font-size: 0.75rem; color: var(--ok); white-space: pre-wrap; box-shadow: inset 0 0 15px rgba(0,0,0,0.8);">
          ${e}
        </div>
        
      </div>
    </div>
  `}function dr(){var e,n,s;const t=is.value;return t?o`
    <div
      class="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${a=>{a.target.classList.contains("keeper-detail-overlay")&&Rs()}}
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
            <${tt} status=${t.status} />
            ${t.model?o`<span class="pill">${t.model}</span>`:null}
          </div>
          <button
            onClick=${()=>Rs()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${sr} keeper=${t} />

        ${""}
        <${ar} keeper=${t} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${y} title="Field Dictionary">
            <${ir} keeper=${t} />
          <//>

          ${""}
          <${y} title="Profile">
            <${Ls} traits=${t.traits??[]} label="Traits" />
            <${Ls} traits=${t.interests??[]} label="Interests" />
            ${t.primaryValue?o`<div style="font-size:12px; color:#888;">Primary value: <span style="color:#4ade80;">${t.primaryValue}</span></div>`:null}
            ${t.skill_primary?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Skill route: <span style="color:#22d3ee;">${t.skill_primary}</span>
                </div>`:null}
            ${t.skill_reason?o`<div style="font-size:12px; color:#888; margin-top:4px;">${t.skill_reason}</div>`:null}
            ${t.last_heartbeat?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Last heartbeat: <${F} timestamp=${t.last_heartbeat} />
                </div>`:null}
          <//>

          ${""}
          ${t.autonomy_level?o`
              <${y} title="Autonomy">
                <${nr} keeper=${t} />
              <//>
            `:null}

          ${""}
          ${t.trpg_stats?o`
              <${y} title="TRPG Stats">
                <${or} stats=${t.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?o`
              <${y} title="Equipment (${t.inventory.length})">
                <${rr} items=${t.inventory} />
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?o`
              <${y} title="Relationships (${Object.keys(t.relationships).length})">
                <${lr} rels=${t.relationships} />
              <//>
            `:null}

          <${y} title="Runtime Signals">
            <${cr} keeper=${t} />
          <//>

          <${y} title="Memory & Context">
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
                  ${t.context_max??((s=t.context)==null?void 0:s.context_max)??"-"}
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
        <${ur} keeperName=${t.name} />
      </div>
    </div>
  `:null}let pr=0;const vt=_([]);function b(t,e="success",n=4e3){const s=++pr;vt.value=[...vt.value,{id:s,message:t,type:e}],setTimeout(()=>{vt.value=vt.value.filter(a=>a.id!==s)},n)}function vr(t){vt.value=vt.value.filter(e=>e.id!==t)}function fr(){const t=vt.value;return t.length===0?null:o`
    <div class="toast-container">
      ${t.map(e=>o`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>vr(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}const mr="masc_dashboard_agent_name",Pt=_(null),Ee=_(!1),ee=_(""),De=_([]),ne=_([]),Ct=_(""),Ht=_(!1);function Fa(t){Pt.value=t,os()}function Es(){Pt.value=null,ee.value="",De.value=[],ne.value=[],Ct.value=""}function _r(){const t=Pt.value;return t?Et.value.find(e=>e.name===t)??null:null}function za(t){return t?ce.value.filter(e=>e.assignee===t):[]}async function os(){const t=Pt.value;if(t){Ee.value=!0,ee.value="",De.value=[],ne.value=[];try{const e=await Do(80);De.value=e.filter(a=>a.includes(t)).slice(0,20);const n=za(t).slice(0,6);if(n.length===0)return;const s=await Promise.all(n.map(async a=>{try{const i=await Po(a.id,25);return{taskId:a.id,text:i.trim()}}catch(i){const r=i instanceof Error?i.message:"history load failed";return{taskId:a.id,text:`Failed to load history: ${r}`}}}));ne.value=s}catch(e){ee.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{Ee.value=!1}}}async function Ds(){var s;const t=Pt.value,e=Ct.value.trim();if(!t||!e)return;const n=((s=localStorage.getItem(mr))==null?void 0:s.trim())||"dashboard";Ht.value=!0;try{await La(n,`@${t} ${e}`),Ct.value="",b(`Mention sent to ${t}`,"success"),os()}catch(a){const i=a instanceof Error?a.message:"Failed to send mention";b(i,"error")}finally{Ht.value=!1}}function gr({task:t}){return o`
    <div class="agent-detail-task">
      <span class="pill">${t.id}</span>
      <span class="agent-detail-task-title">${t.title}</span>
      <${tt} status=${t.status} />
    </div>
  `}function $r({row:t}){return o`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${t.taskId}</span>
      </div>
      <pre class="agent-history-pre">${t.text||"No task history yet"}</pre>
    </div>
  `}function hr(){var a,i,r,c;const t=Pt.value;if(!t)return null;const e=_r(),n=za(t),s=De.value;return o`
    <div
      class="agent-detail-overlay"
      onClick=${u=>{u.target.classList.contains("agent-detail-overlay")&&Es()}}
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
                        <${tt} status=${e.status} />
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
            ${(((a=e==null?void 0:e.traits)==null?void 0:a.length)??0)>0?o`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(i=e==null?void 0:e.traits)==null?void 0:i.map(u=>o`<span style="font-size:0.7rem;background:#1e3a5f;color:#60a5fa;padding:2px 8px;border-radius:10px">${u}</span>`)}
              </div>
            `:""}
            ${(((r=e==null?void 0:e.interests)==null?void 0:r.length)??0)>0?o`
              <div style="display:flex;flex-wrap:wrap;gap:4px">
                ${(c=e==null?void 0:e.interests)==null?void 0:c.map(u=>o`<span style="font-size:0.7rem;background:#3b1f4e;color:#c084fc;padding:2px 8px;border-radius:10px">${u}</span>`)}
              </div>
            `:""}
            <div class="agent-detail-sub">
              ${e?o`
                    ${e.current_task?o`<span>Task: ${e.current_task}</span>`:null}
                    ${e.last_seen?o`<span>Last seen: <${F} timestamp=${e.last_seen} /></span>`:null}
                  `:null}
            </div>
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{os()}} disabled=${Ee.value}>
              ${Ee.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${Es}>Close</button>
          </div>
        </div>

        ${ee.value?o`<div class="council-error">${ee.value}</div>`:null}

        <div class="agent-detail-grid">
          <${y} title="Assigned Tasks">
            ${n.length===0?o`<div class="empty-state">No assigned tasks</div>`:o`<div class="agent-detail-task-list">${n.map(u=>o`<${gr} key=${u.id} task=${u} />`)}</div>`}
          <//>

          <${y} title="Recent Activity">
            ${s.length===0?o`<div class="empty-state">No recent room activity match</div>`:o`<div class="agent-activity-list">${s.map((u,p)=>o`<div key=${p} class="agent-activity-line">${u}</div>`)}</div>`}
          <//>
        </div>

        <${y} title="Task History">
          ${ne.value.length===0?o`<div class="empty-state">No task history loaded</div>`:o`<div class="agent-history-list">${ne.value.map(u=>o`<${$r} key=${u.taskId} row=${u} />`)}</div>`}
        <//>

        <${y} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${Ct.value}
              onInput=${u=>{Ct.value=u.target.value}}
              onKeyDown=${u=>{u.key==="Enter"&&Ds()}}
              disabled=${Ht.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{Ds()}}
              disabled=${Ht.value||Ct.value.trim()===""}
            >
              ${Ht.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}function yt({label:t,value:e,color:n}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color: ${n}`:""}>${e}</div>
    </div>
  `}function yr({agent:t}){return o`
    <div class="agent" onClick=${()=>Fa(t.name)} style="cursor: pointer">
      <span class="agent-emoji">${t.emoji??""}</span>
      <span class="agent-status ${t.status}"></span>
      <span class="agent-name">${t.name}</span>
      <${tt} status=${t.status} />
      ${t.current_task?o`<span class="agent-task">${t.current_task}</span>`:null}
    </div>
  `}function br(t){return t==null?"—":t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}k`:String(t)}function xr(t,e){return t.length>e?t.slice(0,e-1)+"…":t}function Ps(t){return t>.8?"ctx-bar-bad":t>.6?"ctx-bar-warn":"ctx-bar-ok"}function kr({keeper:t}){const e=t.context_ratio,n=e!=null?Math.round(e*100):null,s=Uo.value.get(t.name),a=Bo.value.has(t.name);return o`
    <div class="live-agent keeper-card ${a?"stale":""}" onClick=${()=>Ma(t)} style="cursor: pointer">
      <div class="live-agent-main">
        <!-- Row 1: Identity -->
        <div class="live-agent-title">
          <span class="live-agent-name">${t.emoji??""} ${t.name}</span>
          <${tt} status=${t.status} />
          ${s?o`<span class="pill pill-lifecycle pill-lifecycle-${s}">${s}</span>`:null}
          ${a?o`<span class="pill pill-stale">stale</span>`:null}
          ${t.model?o`<span class="pill">${t.model}</span>`:null}
          ${t.skill_primary?o`<span class="pill pill-skill">${t.skill_primary}</span>`:null}
        </div>
        <div class="live-agent-sub">${t.koreanName??""}</div>

        <!-- Row 2: Context bar -->
        ${e!=null?o`
          <div class="keeper-ctx-row">
            <div class="keeper-ctx-bar">
              <div class="keeper-ctx-fill ${Ps(e)}" style="width: ${n}%"></div>
            </div>
            <span class="keeper-ctx-label ${Ps(e)}">
              ${n}%
              ${t.context_tokens!=null?o` (${br(t.context_tokens)})`:null}
            </span>
          </div>
        `:null}

        <!-- Row 3: Operational metrics -->
        ${t.generation!=null?o`
          <div class="keeper-metrics-row">
            <span>Gen ${t.generation}</span>
            <span>T${t.turn_count??0}</span>
            ${(t.handoff_count_total??0)>0?o`<span class="keeper-metric-hl">↻${t.handoff_count_total}</span>`:null}
            ${(t.compaction_count??0)>0?o`<span class="keeper-metric-compact">◆${t.compaction_count}</span>`:null}
            ${(t.k2k_count??0)>0?o`<span>K2K:${t.k2k_count}</span>`:null}
            ${(t.conversation_tail_count??0)>0?o`<span>💬${t.conversation_tail_count}</span>`:null}
          </div>
        `:null}

        <!-- Row 4: Heartbeat freshness -->
        ${t.last_heartbeat?o`
          <div class="keeper-heartbeat-row">
            <span class="keeper-heartbeat-dot ${t.status==="active"?"pulse":""}"></span>
            <${F} timestamp=${t.last_heartbeat} />
          </div>
        `:null}

        <!-- Row 5: Trait chips -->
        ${t.traits&&t.traits.length>0?o`
          <div class="keeper-trait-row">
            ${t.traits.slice(0,3).map(i=>o`<span class="keeper-trait-chip">${i}</span>`)}
            ${t.traits.length>3?o`<span class="keeper-trait-more">+${t.traits.length-3}</span>`:null}
          </div>
        `:null}

        <!-- Row 6: Memory note preview -->
        ${t.memory_recent_note?o`
          <div class="keeper-note-preview">${xr(t.memory_recent_note,80)}</div>
        `:null}
      </div>
    </div>
  `}function Is(){var r,c,u,p,f;const t=gt.value,e=Et.value,n=Dt.value,s=as.value,a=(r=t==null?void 0:t.monitoring)==null?void 0:r.board,i=(c=t==null?void 0:t.monitoring)==null?void 0:c.council;return o`
    <div class="stats-grid">
      <${yt} label="Agents" value=${e.length} />
      <${yt} label="Active" value=${Oa.value.length} color="#4ade80" />
      <${yt} label="Keepers" value=${n.length} color="#22d3ee" />
      <${yt} label="Tasks" value=${ce.value.length} />
      <${yt} label="In Progress" value=${s.inProgress.length} color="#fbbf24" />
      <${yt} label="Done" value=${s.done.length} color="#4ade80" />
    </div>

    ${a||i?o`
        <${y} title="Operations SLO" class="section">
          <div class="grid-2col">
            <div class="stat-card">
              <div class="stat-label">Board Feed</div>
              <div class="stat-value" style=${`color: ${js(a==null?void 0:a.alert_level)}`}>
                ${Os(a==null?void 0:a.alert_level)}
              </div>
              <div class="council-sub">
                <span>Freshness: ${fe(a==null?void 0:a.last_activity_age_s)}</span>
                <span>SLO: ≤ ${fe(a==null?void 0:a.slo_target_age_s)}</span>
                <span>SLO Breach: ${a!=null&&a.slo_breached?"Yes":"No"}</span>
                <span>Posts (24h): ${(a==null?void 0:a.new_posts_24h)??0}</span>
                <span>Unanswered: ${(a==null?void 0:a.unanswered_posts)??0}</span>
              </div>
            </div>

            <div class="stat-card">
              <div class="stat-label">Council Feed</div>
              <div class="stat-value" style=${`color: ${js(i==null?void 0:i.alert_level)}`}>
                ${Os(i==null?void 0:i.alert_level)}
              </div>
              <div class="council-sub">
                <span>Freshness: ${fe(i==null?void 0:i.last_activity_age_s)}</span>
                <span>Open Debates: ${(i==null?void 0:i.debates_open)??0}</span>
                <span>Pending Debates: ${(i==null?void 0:i.debates_pending)??0}</span>
                <span>Quorum Risk: ${(i==null?void 0:i.sessions_without_quorum)??0}</span>
                <span>SLO: ≤ ${fe(i==null?void 0:i.slo_target_quorum_age_s)}</span>
                <span>SLO Breach: ${i!=null&&i.slo_breached?"Yes":"No"}</span>
              </div>
            </div>
          </div>
        <//>
      `:null}

    <div class="grid-2col">
      <${y} title="Agents" class="section">
        <div class="agent-list">
          ${e.length===0?o`<div class="empty-state">No agents connected</div>`:e.map(l=>o`<${yr} key=${l.name} agent=${l} />`)}
        </div>
      <//>

      <${y} title="Keepers" class="section">
        <div class="live-agent-list">
          ${n.length===0?o`<div class="empty-state">No keepers active</div>`:n.map(l=>o`<${kr} key=${l.name} keeper=${l} />`)}
        </div>
      <//>
    </div>

    ${Ot.value?o`
        <${y} title="Perpetual Runtime" class="section">
          <div class="live-agent-meta">
            <span>Status: ${Ot.value.running?"Running":"Stopped"}</span>
            ${Ot.value.goal?o`<span>Goal: ${Ot.value.goal}</span>`:null}
          </div>
        <//>
      `:null}

    ${t!=null&&t.room?o`
        <${y} title="Room" class="section">
          <div class="live-agent-meta">
            <span>Room: ${t.room}</span>
            ${t.cluster?o`<span>Cluster: ${t.cluster}</span>`:null}
            ${t.project?o`<span>Project: ${t.project}</span>`:null}
            ${t.version?o`<span>Version: ${t.version}</span>`:null}
            <span>Uptime: ${wr(t.uptime_seconds??0)}</span>
            ${t.paused?o`<span class="pill pill-stale">Paused</span>`:null}
            ${t.tempo?o`<span>Tempo: ${t.tempo}</span>`:null}
            ${t.tempo_interval_s!=null?o`<span>Interval: ${t.tempo_interval_s}s</span>`:null}
            ${((u=t.data_quality)==null?void 0:u.board_contract_ok)===!1?o`<span class="pill pill-stale">Board Contract: Degraded</span>`:null}
            ${((p=t.data_quality)==null?void 0:p.council_feed_ok)===!1?o`<span class="pill pill-stale">Council Feed: Degraded</span>`:null}
            ${(f=t.data_quality)!=null&&f.last_sync_at?o`<span>Data Sync: <${F} timestamp=${t.data_quality.last_sync_at} /></span>`:null}
          </div>
        <//>
      `:null}
  `}function wr(t){if(!t)return"N/A";const e=Math.floor(t/3600),n=Math.floor(t%3600/60);return e>0?`${e}h ${n}m`:`${n}m`}function fe(t){if(t==null||!Number.isFinite(t))return"No data";if(t<60)return`${Math.max(0,Math.round(t))}s`;const e=Math.floor(t/60);if(e<60)return`${e}m`;const n=Math.floor(e/60),s=e%60;return s>0?`${n}h ${s}m`:`${n}h`}function Os(t){const e=(t??"").toLowerCase();return e==="ok"?"Healthy":e==="warn"?"Warning":e==="bad"?"Degraded":"Unknown"}function js(t){const e=(t??"").toLowerCase();return e==="ok"?"#4ade80":e==="warn"?"#fbbf24":e==="bad"?"#fb7185":"#94a3b8"}const zn=_([]),Un=_([]),Bt=_(""),Pe=_(!1),Kt=_(!1),se=_(""),Ie=_(null),W=_(null),Hn=_(!1);async function Bn(){Pe.value=!0,se.value="";try{const[t,e]=await Promise.all([Io(),Oo()]);zn.value=t,Un.value=e}catch(t){se.value=t instanceof Error?t.message:"Failed to load council data"}finally{Pe.value=!1}}async function Ms(){const t=Bt.value.trim();if(t){Kt.value=!0;try{const e=await jo(t);Bt.value="",b(e!=null&&e.id?`Debate started: ${e.id}`:"Debate started","success"),await Bn()}catch(e){const n=e instanceof Error?e.message:"Failed to start debate";b(n,"error")}finally{Kt.value=!1}}}async function Sr(t){Ie.value=t,Hn.value=!0,W.value=null;try{W.value=await Mo(t)}catch(e){se.value=e instanceof Error?e.message:"Failed to load debate status",W.value=null}finally{Hn.value=!1}}function Cr({debate:t}){const e=Ie.value===t.id;return o`
    <button
      class="council-row ${e?"selected":""}"
      onClick=${()=>Sr(t.id)}
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
  `}function Ar({session:t}){return o`
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
  `}function Nr(){var e;const t=(e=gt.value)==null?void 0:e.data_quality;return!t||t.council_feed_ok!==!1&&!t.last_sync_at?null:o`
    <div class="feed-health-banner ${t.council_feed_ok===!1?"degraded":"ok"}">
      <span class="feed-health-title">
        ${t.council_feed_ok===!1?"Council feed degraded":"Council feed synced"}
      </span>
      ${t.last_sync_at?o`<span class="feed-health-meta">Last sync: <${F} timestamp=${t.last_sync_at} /></span>`:o`<span class="feed-health-meta">No sync timestamp</span>`}
    </div>
  `}function Tr(){var e,n;ft(()=>{Bn()},[]);const t=((n=(e=gt.value)==null?void 0:e.data_quality)==null?void 0:n.council_feed_ok)===!1;return o`
    <div>
      <${Nr} />
      <${y} title="Council Command" class="section">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${Bt.value}
            onInput=${s=>{Bt.value=s.target.value}}
            onKeyDown=${s=>{s.key==="Enter"&&Ms()}}
            disabled=${Kt.value}
          />
          <button
            class="control-btn secondary"
            onClick=${Ms}
            disabled=${Kt.value||Bt.value.trim()===""}
          >
            ${Kt.value?"Starting...":"Start Debate"}
          </button>
          <button class="control-btn ghost" onClick=${Bn} disabled=${Pe.value}>
            ${Pe.value?"Refreshing...":"Refresh"}
          </button>
        </div>
        ${se.value?o`<div class="council-error">${se.value}</div>`:null}
      <//>

      <div class="council-grid">
        <${y} title="Debates" class="section">
          <div class="council-list">
            ${zn.value.length===0?o`
                  <div class="empty-state">
                    ${t?"No debates loaded (council feed degraded).":"No debates yet"}
                  </div>
                `:zn.value.map(s=>o`<${Cr} key=${s.id} debate=${s} />`)}
          </div>
        <//>

        <${y} title="Voting Sessions" class="section">
          <div class="council-list">
            ${Un.value.length===0?o`
                  <div class="empty-state">
                    ${t?"No sessions loaded (council feed degraded).":"No active sessions"}
                  </div>
                `:Un.value.map(s=>o`<${Ar} key=${s.id} session=${s} />`)}
          </div>
        <//>
      </div>

      <${y} title=${Ie.value?`Debate Detail (${Ie.value})`:"Debate Detail"} class="section">
        ${Hn.value?o`<div class="loading-indicator">Loading debate detail...</div>`:W.value?o`
                <div class="council-sub" style="margin-bottom: 8px;">
                  <span>Status: ${W.value.status}</span>
                  <span>Total arguments: ${W.value.total_arguments}</span>
                </div>
                <div class="council-sub" style="margin-bottom: 8px;">
                  <span>Support: ${W.value.support_count}</span>
                  <span>Oppose: ${W.value.oppose_count}</span>
                  <span>Neutral: ${W.value.neutral_count}</span>
                </div>
                ${W.value.summary_text?o`<pre class="council-detail">${W.value.summary_text}</pre>`:null}
              `:o`<div class="empty-state">Select a debate to view summary</div>`}
      <//>
    </div>
  `}function Rr({text:t}){if(!t)return null;const e=Lr(t);return o`<div class="markdown-content">${e}</div>`}function Lr(t){const e=t.split(`
`),n=[];let s=0;for(;s<e.length;){const a=e[s];if(/^(`{3,}|~{3,})/.test(a)){const r=a.match(/^(`{3,}|~{3,})/)[0],c=a.slice(r.length).trim(),u=[];for(s++;s<e.length&&!e[s].startsWith(r);)u.push(e[s]),s++;s++,n.push(o`<pre><code class=${c?`language-${c}`:""}>${u.join(`
`)}</code></pre>`);continue}if(a.trim()==="<think>"||a.trim().startsWith("<think>")){const r=[],c=a.trim().replace(/^<think>/,"").trim();for(c&&c!=="</think>"&&r.push(c),s++;s<e.length&&!e[s].includes("</think>");)r.push(e[s]),s++;if(s<e.length){const p=e[s].replace("</think>","").trim();p&&r.push(p),s++}const u=r.join(`
`).trim();n.push(o`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${tn(u)}</div>
        </details>
      `);continue}if(a.startsWith("> ")){const r=[];for(;s<e.length&&e[s].startsWith("> ");)r.push(e[s].slice(2)),s++;n.push(o`<blockquote>${tn(r.join(`
`))}</blockquote>`);continue}if(a.trim()===""){s++;continue}const i=[];for(;s<e.length;){const r=e[s];if(r.trim()===""||/^(`{3,}|~{3,})/.test(r)||r.startsWith("> ")||r.trim().startsWith("<think>"))break;i.push(r),s++}i.length>0&&n.push(o`<p>${tn(i.join(`
`))}</p>`)}return n}function tn(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let s=0,a;for(;(a=n.exec(t))!==null;){if(a.index>s&&e.push(t.slice(s,a.index)),a[1]){const i=a[1].slice(1,-1);e.push(o`<code>${i}</code>`)}else if(a[2]){const i=a[2].slice(2,-2);e.push(o`<strong>${i}</strong>`)}else if(a[3]){const i=a[3].slice(1,-1);e.push(o`<em>${i}</em>`)}else a[4]&&a[5]&&e.push(o`<a href=${a[5]} target="_blank" rel="noopener">${a[4]}</a>`);s=a.index+a[0].length}return s<t.length&&e.push(t.slice(s)),e.length>0?e:[t]}const Er=[{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"recent",label:"Recent"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],Kn=_([]),qt=_(!1),qn=_(null),Gt=_(""),Dr=_("dashboard-user"),Jt=_(!1);async function Ua(t){qn.value=t,qt.value=!0;try{const e=await ao(t);if(qn.value!==t)return;Kn.value=e.comments??[]}catch{}finally{qt.value=!1}}async function Fs(t){const e=Gt.value.trim();if(e){Jt.value=!0;try{await io(t,Dr.value,e),Gt.value="",b("Comment posted","success"),await Ua(t),$t()}catch{b("Failed to post comment","error")}finally{Jt.value=!1}}}function Pr(){const t=Pn.value;return o`
    <div class="board-controls">
      ${Er.map(e=>o`
        <button
          class="board-sort-btn ${t===e.id?"active":""}"
          onClick=${()=>{Pn.value=e.id,$t()}}
        >
          ${e.label}
        </button>
      `)}
    </div>
  `}function en(){var e;const t=(e=gt.value)==null?void 0:e.data_quality;return!t||t.board_contract_ok!==!1&&!t.last_sync_at?null:o`
    <div class="feed-health-banner ${t.board_contract_ok===!1?"degraded":"ok"}">
      <span class="feed-health-title">
        ${t.board_contract_ok===!1?"Board feed degraded":"Board feed synced"}
      </span>
      ${t.last_sync_at?o`<span class="feed-health-meta">Last sync: <${F} timestamp=${t.last_sync_at} /></span>`:o`<span class="feed-health-meta">No sync timestamp</span>`}
    </div>
  `}function Ha({flair:t}){return t?o`<span class="post-flair ${t}">${t}</span>`:null}function Ir({post:t}){const e=async(n,s)=>{s.stopPropagation();try{await Ra(t.id,n),$t()}catch{b("Failed to vote","error")}};return o`
    <div class="board-post" onClick=${()=>Ii(t.id)}>
      <div class="vote-column">
        <button class="vote-btn upvote" onClick=${n=>e("up",n)}>▲</button>
        <span class="vote-count">${t.votes??0}</span>
        <button class="vote-btn downvote" onClick=${n=>e("down",n)}>▼</button>
      </div>
      <div class="post-content">
        <div class="post-title">
          ${t.title}
          ${" "}
          <${Ha} flair=${t.flair} />
        </div>
        <div class="post-meta">
          <span>${t.author}</span>
          <${F} timestamp=${t.created_at} />
          ${t.comment_count>0?o`<span>${t.comment_count} comments</span>`:null}
          ${(t.hearth_count??0)>0?o`<span>♥ ${t.hearth_count}</span>`:null}
        </div>
      </div>
    </div>
  `}function Or({comments:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No comments yet</div>`:o`
    <div class="comment-thread">
      ${t.map(e=>o`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${F} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function jr({postId:t}){return o`
    <div class="comment-form" style="margin-top: 12px; display: flex; gap: 8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${Gt.value}
        onInput=${e=>{Gt.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&Fs(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${Jt.value}
      />
      <button
        onClick=${()=>Fs(t)}
        disabled=${Jt.value||Gt.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${Jt.value?"...":"Post"}
      </button>
    </div>
  `}function Mr({post:t}){qn.value!==t.id&&!qt.value&&Ua(t.id);const e=async n=>{try{await Ra(t.id,n),$t()}catch{b("Failed to vote","error")}};return o`
    <div>
      <button class="back-btn" onClick=${()=>Ke("board")}>← Back to Board</button>
      <${y} title=${o`${t.title} <${Ha} flair=${t.flair} />`}>
        <div class="board-detail">
          <div class="post-body">
            <${Rr} text=${t.content} />
          </div>
          <div class="post-meta" style="margin-top: 12px;">
            <span>${t.author}</span>
            <${F} timestamp=${t.created_at} />
            <span>${t.votes??0} votes</span>
            ${(t.hearth_count??0)>0?o`<span>♥ ${t.hearth_count}</span>`:null}
          </div>
          <div style="margin-top: 8px; display: flex; gap: 6px;">
            <button class="vote-btn upvote" onClick=${()=>e("up")}>▲ Upvote</button>
            <button class="vote-btn downvote" onClick=${()=>e("down")}>▼ Downvote</button>
          </div>
        </div>
      <//>

      <${y} title="Comments (${qt.value?"...":Kn.value.length})">
        ${qt.value?o`<div class="loading-indicator">Loading comments...</div>`:o`<${Or} comments=${Kn.value} />`}
        <${jr} postId=${t.id} />
      <//>
    </div>
  `}function Fr(){var a,i;const t=Pa.value,e=On.value,n=Z.value.postId,s=((i=(a=gt.value)==null?void 0:a.data_quality)==null?void 0:i.board_contract_ok)===!1;if(n){const r=t.find(c=>c.id===n);return r?o`
          <${en} />
          <${Mr} post=${r} />
        `:o`
          <div>
            <${en} />
            <button class="back-btn" onClick=${()=>Ke("board")}>← Back to Board</button>
            <div class="empty-state">
              ${s?"Post not available while board feed is degraded":"Post not found"}
            </div>
          </div>
        `}return o`
    <${en} />
    <${Pr} />
    ${e?o`<div class="loading-indicator">Loading board...</div>`:t.length===0?o`
            <div class="empty-state">
              ${s?"No posts loaded (board feed degraded). Check board contract sync.":"No posts yet"}
            </div>
          `:o`<div class="board-post-list">
            ${t.map(r=>o`<${Ir} key=${r.id} post=${r} />`)}
          </div>`}
  `}function zr(t,e){return{id:t.id??`msg-${t.seq??e}`,source:"message",actor:t.from??"system",content:t.content,timestamp:t.timestamp}}function Ur(t,e){return{id:`evt-${t.timestamp}-${e}`,source:"event",actor:t.agent||"system",content:t.text,timestamp:new Date(t.timestamp).toISOString()}}function zs(t){const e=Date.parse(t);return Number.isNaN(e)?0:e}function Hr({row:t}){const e=new Date(t.timestamp),n=isNaN(e.getTime())?"00:00:00":e.toLocaleTimeString("en-US",{hour12:!1});return o`
    <div class="term-row">
      <span class="term-time">${n}</span>
      <span class="term-actor">${t.actor}</span>
      <span class="term-source ${t.source}">${t.source==="message"?"msg":"evt"}</span>
      <span class="term-text">${t.content}</span>
    </div>
  `}function Br(){const t=Da.value.map(zr),e=Re.value.map(Ur),n=[...t,...e].sort((s,a)=>zs(a.timestamp)-zs(s.timestamp)).slice(0,100);return o`
    <div class="section">
      <h2 style="color: var(--accent); text-shadow: 0 0 10px rgba(0,240,255,0.5); margin-bottom: 16px; font-family: monospace;">> LIVE_ACTIVITY_STREAM</h2>
      <div class="terminal-feed">
        ${n.length===0?o`<div class="empty-state" style="font-family: monospace; color: var(--ok);">> Waiting for signal...</div>`:n.map(s=>o`<${Hr} key=${s.id} row=${s} />`)}
      </div>
    </div>
  `}function Ba({ratio:t,size:e=40,stroke:n=4}){if(t==null)return null;const s=(e-n)/2,a=e/2,i=2*Math.PI*s,r=i*((100-t*100)/100);let c="mitosis-safe";return t>=.8?c="mitosis-critical":t>=.5&&(c="mitosis-warn"),o`
    <div class="mitosis-ring-container" title="Mitosis Context Load: ${Math.round(t*100)}%">
      <svg class="mitosis-ring" width="${e}" height="${e}" viewBox="0 0 ${e} ${e}">
        <circle class="mitosis-ring-bg" cx="${a}" cy="${a}" r="${s}" stroke-width="${n}" />
        <circle 
          class="mitosis-ring-fg ${c}" 
          cx="${a}" cy="${a}" r="${s}" 
          stroke-width="${n}" 
          stroke-dasharray="${i}" 
          stroke-dashoffset="${r}" 
        />
      </svg>
      <span class="mitosis-text ${c}">${Math.round(t*100)}%</span>
    </div>
  `}const Kr={born_at:{label:"Born",description:"Keeper 메타가 생성된 시각입니다.",sourcePath:"keepers[].created_at",interpretation:"최근 생성일수록 신규 Keeper입니다."},generation:{label:"Generation",description:"승계/핸드오프를 거치며 누적된 세대 번호입니다.",sourcePath:"keepers[].generation",interpretation:"값이 높을수록 세대 전환을 더 많이 경험했습니다."},status:{label:"Status",description:"현재 실행 상태입니다.",sourcePath:"keepers[].status",interpretation:"active/idle은 동작 중, offline/inactive는 비활성 상태입니다."},recent_activity:{label:"Recent",description:"가장 최근 변화/행동 요약입니다.",sourcePath:"keepers[].last_drift_reason | keepers[].last_proactive_reason | keepers[].memory_recent_note",formula:"first_non_null(last_drift_reason, last_proactive_reason, memory_recent_note)",interpretation:"최근 어떤 일을 했는지 한 줄로 파악합니다."},relations:{label:"Relations",description:"다른 Keeper와의 최근 상호작용 빈도입니다.",sourcePath:"keepers[].k2k_count, keepers[].k2k_mentions",formula:"k2k_count + top(k2k_mentions)",interpretation:"값이 높을수록 협업/호출이 잦습니다."},personality_change:{label:"Personality Change",description:"성향 변화 추세를 드리프트 지표로 요약한 값입니다.",sourcePath:"keepers[].drift_count_total, keepers[].metrics_window.goal_drift_avg",formula:"drift_count_total + goal_drift_avg",interpretation:"높을수록 최근 성향/목표 정렬 변화가 컸습니다."}};function qr(t){return Kr[t]}function bt({metric:t}){const e=qr(t);return o`
    <span
      class="metric-tip"
      tabindex="0"
      role="button"
      aria-label="${e.label} 설명"
      title="${e.description} (source: ${e.sourcePath})"
    >
      i
      <span class="metric-tip-pop" role="tooltip">
        <strong>${e.label}</strong>
        <span>${e.description}</span>
        ${e.formula?o`<span><code>formula:</code> ${e.formula}</span>`:null}
        <span><code>source:</code> ${e.sourcePath}</span>
        ${e.interpretation?o`<span>${e.interpretation}</span>`:null}
      </span>
    </span>
  `}function Gr({agent:t}){return o`
    <button class="agent-card ${t.status}" onClick=${()=>Fa(t.name)}>
      <div class="agent-card-header">
        <span class="agent-emoji">${t.emoji??""}</span>
        <div class="agent-card-info">
          <span class="agent-name">${t.name}</span>
          ${t.koreanName?o`<span class="agent-korean">${t.koreanName}</span>`:null}
        </div>
        <${Ba} ratio=${t.context_ratio} />
        <${tt} status=${t.status} />
      </div>
      ${t.current_task?o`<div class="agent-task">${t.current_task}</div>`:null}
      ${t.model?o`<div class="agent-model"><span class="pill">${t.model}</span></div>`:null}
    </button>
  `}function Jr(t){return typeof t!="number"||Number.isNaN(t)?null:`${Math.round(t*100)}%`}function Wr(t){var a,i,r;const e=(a=t.last_drift_reason)==null?void 0:a.trim();if(e)return e;const n=(i=t.last_proactive_reason)==null?void 0:i.trim();if(n)return n;const s=(r=t.memory_recent_note)==null?void 0:r.trim();return s||"—"}function Vr(t){var s;const e=t.k2k_count??0,n=(s=t.k2k_mentions)==null?void 0:s[0];return n?`${e} · ${n.keeper}(${n.count})`:String(e)}function Yr(t){var s;const e=t.drift_count_total??0,n=Jr((s=t.metrics_window)==null?void 0:s.goal_drift_avg);return e===0&&!n?"Stable":n?`Drift ${e} · Δ${n}`:`Drift ${e}`}function Qr({keeper:t}){var a;const e=Wr(t),n=Vr(t),s=Yr(t);return o`
    <div class="live-agent keeper-card" onClick=${()=>Ma(t)} style="cursor:pointer;">
      <div class="live-agent-main">
        <div class="live-agent-title">
          <span class="live-agent-name">${t.emoji??""} ${t.name}</span>
          <${Ba} ratio=${t.context_ratio} />
        <${tt} status=${t.status} />
          ${t.model?o`<span class="pill">${t.model}</span>`:null}
        </div>
        ${t.koreanName?o`<div class="live-agent-sub">${t.koreanName}</div>`:null}
        <div class="keeper-core-grid">
          <div class="keeper-core-item">
            <span class="keeper-core-label">Born <${bt} metric="born_at" /></span>
            <strong class="keeper-core-value">
              ${t.created_at?o`<${F} timestamp=${t.created_at} />`:"—"}
            </strong>
          </div>
          <div class="keeper-core-item">
            <span class="keeper-core-label">Gen <${bt} metric="generation" /></span>
            <strong class="keeper-core-value">${t.generation??"—"}</strong>
          </div>
          <div class="keeper-core-item">
            <span class="keeper-core-label">Status <${bt} metric="status" /></span>
            <strong class="keeper-core-value">${t.status}</strong>
          </div>
          <div class="keeper-core-item">
            <span class="keeper-core-label">Relations <${bt} metric="relations" /></span>
            <strong class="keeper-core-value">${n}</strong>
          </div>
          <div class="keeper-core-item keeper-core-item-span">
            <span class="keeper-core-label">Recent <${bt} metric="recent_activity" /></span>
            <strong class="keeper-core-value keeper-core-text">${e}</strong>
          </div>
          <div class="keeper-core-item keeper-core-item-span">
            <span class="keeper-core-label">Personality <${bt} metric="personality_change" /></span>
            <strong class="keeper-core-value">${s}</strong>
          </div>
        </div>

        <!-- Inner Information Section -->
        <div class="keeper-inner-info">
          ${(a=t.agent)!=null&&a.current_task?o`
            <div class="keeper-detail-row">
              <span class="keeper-label">Task</span>
              <span class="keeper-value">${t.agent.current_task}</span>
            </div>
          `:null}
          ${t.will?o`
            <div class="keeper-detail-row">
              <span class="keeper-label">Will (의지)</span>
              <span class="keeper-value">${t.will}</span>
            </div>
          `:null}
          ${t.needs?o`
            <div class="keeper-detail-row">
              <span class="keeper-label">Needs (니즈)</span>
              <span class="keeper-value">${t.needs}</span>
            </div>
          `:null}
          ${t.desires?o`
            <div class="keeper-detail-row">
              <span class="keeper-label">Desires (욕구)</span>
              <span class="keeper-value">${t.desires}</span>
            </div>
          `:null}
          ${t.memory_recent_note?o`
            <div class="keeper-detail-row">
              <span class="keeper-label">Memory Note</span>
              <span class="keeper-value memory-note">"${t.memory_recent_note}"</span>
            </div>
          `:null}
        </div>
      </div>
    </div>
  `}function Xr(){const t=Et.value,e=Dt.value;return o`
    <div>
      ${e.length>0?o`
          <div class="section" style="margin-bottom: 20px">
            <h2>Keepers (Live)</h2>
            <div class="live-agent-list">
              ${e.map(n=>o`<${Qr} key=${n.name} keeper=${n} />`)}
            </div>
          </div>
        `:null}

      <div class="section">
        <h2>All Agents</h2>
        ${t.length===0?o`<div class="empty-state">No agents registered</div>`:o`
            <div class="agent-grid">
              ${t.map(n=>o`<${Gr} key=${n.name} agent=${n} />`)}
            </div>
          `}
      </div>
    </div>
  `}function nn({task:t}){const e=(t.priority??4)<=1?"p1":(t.priority??4)===2?"p2":(t.priority??4)===3?"p3":"p4";return o`
    <div class="kanban-card ${e}">
      <div class="kanban-card-title">${t.title}</div>
      <div class="kanban-card-meta">
        ${t.created_at?o`<${F} timestamp=${t.created_at} />`:o`<span>-</span>`}
        ${t.assignee?o`<span class="kanban-assignee">${t.assignee}</span>`:null}
      </div>
    </div>
  `}function Zr(){const{todo:t,inProgress:e,done:n}=as.value;return o`
    <div class="kanban-board">
      <!-- TODO Column -->
      <div class="kanban-column">
        <div class="kanban-header todo">
          <span>TO DO</span>
          <span class="kanban-badge">${t.length}</span>
        </div>
        ${t.length===0?o`<div class="empty-state" style="opacity: 0.5;">No pending tasks</div>`:t.map(s=>o`<${nn} key=${s.id} task=${s} />`)}
      </div>

      <!-- IN PROGRESS Column -->
      <div class="kanban-column">
        <div class="kanban-header inprogress">
          <span>IN PROGRESS</span>
          <span class="kanban-badge">${e.length}</span>
        </div>
        ${e.length===0?o`<div class="empty-state" style="opacity: 0.5;">No active tasks</div>`:e.map(s=>o`<${nn} key=${s.id} task=${s} />`)}
      </div>

      <!-- DONE Column -->
      <div class="kanban-column">
        <div class="kanban-header done">
          <span>DONE</span>
          <span class="kanban-badge">${n.length}</span>
        </div>
        ${n.length===0?o`<div class="empty-state" style="opacity: 0.5;">No completed tasks</div>`:n.slice(0,20).map(s=>o`<${nn} key=${s.id} task=${s} />`)}
        ${n.length>20?o`<div class="empty-state" style="opacity: 0.5;">...and ${n.length-20} more</div>`:null}
      </div>
    </div>
  `}function tl(t){return t==null?"P3":t<=1?"P1":t===2?"P2":t>=4?"P4+":"P3"}function sn({task:t}){return o`
    <div class="council-row session">
      <div class="council-row-main">
        <div class="council-topic">${t.title}</div>
        <div class="council-sub">
          <span>${tl(t.priority)}</span>
          ${t.assignee?o`<span>Assignee: ${t.assignee}</span>`:o`<span>Unassigned</span>`}
          ${t.created_at?o`<span><${F} timestamp=${t.created_at} /></span>`:null}
        </div>
      </div>
      <span class="council-state ${t.status}">${t.status}</span>
    </div>
  `}function el(){const t=as.value,e=t.inProgress,n=t.todo,s=t.done,a=Oa.value,i=n.filter(c=>(c.priority??3)<=2),r=n.filter(c=>!c.assignee);return o`
    <div class="stats-grid">
      <div class="stat-card">
        <div class="stat-label">In Progress</div>
        <div class="stat-value" style="color:#fbbf24">${e.length}</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">Ready Queue</div>
        <div class="stat-value">${n.length}</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">Urgent Ready</div>
        <div class="stat-value" style="color:#fb7185">${i.length}</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">Done (Visible)</div>
        <div class="stat-value" style="color:#4ade80">${s.length}</div>
      </div>
    </div>

    <div class="council-grid">
      <${y} title="Execution Queue" class="section">
        <div class="council-list">
          ${e.length===0?o`<div class="empty-state">No active execution tasks</div>`:e.slice(0,20).map(c=>o`<${sn} key=${c.id} task=${c} />`)}
        </div>
      <//>

      <${y} title="Ready Queue" class="section">
        <div class="council-list">
          ${n.length===0?o`<div class="empty-state">No ready tasks</div>`:n.slice(0,20).map(c=>o`<${sn} key=${c.id} task=${c} />`)}
        </div>
      <//>
    </div>

    <div class="grid-2col">
      <${y} title="Assignee Coverage" class="section">
        <div class="council-list">
          ${a.length===0?o`<div class="empty-state">No active agents</div>`:a.map(c=>o`
                <div class="council-row session">
                  <div class="council-row-main">
                    <div class="council-topic">${c.name}</div>
                    <div class="council-sub">
                      ${c.current_task?o`<span>${c.current_task}</span>`:o`<span>Idle</span>`}
                    </div>
                  </div>
                  <${tt} status=${c.status} />
                </div>
              `)}
        </div>
      <//>

      <${y} title="Attention Needed" class="section">
        <div class="council-list">
          ${r.length===0?o`<div class="empty-state">No unassigned tasks</div>`:r.slice(0,20).map(c=>o`<${sn} key=${c.id} task=${c} />`)}
        </div>
      <//>
    </div>
  `}function nl({event:t}){const n={agent_joined:"#4ade80",agent_left:"#ef4444",broadcast:"#22d3ee",task_update:"#fbbf24",board_post:"#a78bfa",board_comment:"#a78bfa",heartbeat:"#666"}[t.type]??"#888",s=t.message??t.content??t.status??"";return o`
    <div class="journal-entry">
      <span class="journal-type" style="color: ${n}">${t.type}</span>
      <span class="journal-agent">${t.agent??t.from??t.from_agent??""}</span>
      <span class="journal-data">${s}</span>
    </div>
  `}function sl(){const t=Re.value;return o`
    <div class="section">
      <h2>Event Journal</h2>
      <div class="journal-list">
        ${t.length===0?o`<div class="empty-state">No events recorded yet</div>`:t.map((e,n)=>o`<${nl} key=${n} event=${e} />`)}
      </div>
    </div>
  `}const Oe=_("all"),je=_("all"),Ka=lt(()=>{let t=qe.value;return Oe.value!=="all"&&(t=t.filter(e=>e.horizon===Oe.value)),je.value!=="all"&&(t=t.filter(e=>e.status===je.value)),t}),al=lt(()=>{const t={short:[],mid:[],long:[]};for(const e of Ka.value){const n=t[e.horizon];n&&n.push(e)}return t});function il(t){return"★".repeat(Math.min(t,5))+"☆".repeat(Math.max(0,5-t))}function rs(t){switch(t){case"short":return"Short-term";case"mid":return"Mid-term";case"long":return"Long-term";default:return t}}function we(t){switch(t){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function ol({goal:t}){return o`
    <div class="goal-row">
      <div class="goal-row-main">
        <div style="display:flex; align-items:center; gap:8px;">
          <span class="goal-horizon-badge" style="color:${we(t.horizon)}">
            ${rs(t.horizon)}
          </span>
          <span class="goal-title">${t.title}</span>
        </div>
        <div class="goal-meta">
          <span class="goal-priority" title="Priority ${t.priority}">${il(t.priority)}</span>
          ${t.metric?o`<span class="goal-metric">${t.metric}${t.target_value?` → ${t.target_value}`:""}</span>`:null}
          ${t.due_date?o`<span class="goal-due">Due: <${F} timestamp=${t.due_date} /></span>`:null}
        </div>
        ${t.last_review_note?o`
          <div class="goal-review-note">${t.last_review_note}</div>
        `:null}
      </div>
      <div class="goal-row-right">
        <${tt} status=${t.status} />
        <div class="goal-updated">
          <${F} timestamp=${t.updated_at} />
        </div>
      </div>
    </div>
  `}function an({horizon:t,items:e}){if(e.length===0)return null;const n=[...e].sort((s,a)=>a.priority-s.priority);return o`
    <${y} title="${rs(t)} Goals (${e.length})" class="section">
      <div class="goal-list">
        ${n.map(s=>o`<${ol} key=${s.id} goal=${s} />`)}
      </div>
    <//>
  `}function rl(){return o`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">Horizon</label>
        ${["all","short","mid","long"].map(t=>o`
          <button
            class="goal-filter-btn ${Oe.value===t?"active":""}"
            onClick=${()=>{Oe.value=t}}
          >
            ${t==="all"?"All":rs(t)}
          </button>
        `)}
      </div>
      <div class="goal-filter-group">
        <label class="goal-filter-label">Status</label>
        ${["all","active","completed","paused"].map(t=>o`
          <button
            class="goal-filter-btn ${je.value===t?"active":""}"
            onClick=${()=>{je.value=t}}
          >
            ${t==="all"?"All":t.charAt(0).toUpperCase()+t.slice(1)}
          </button>
        `)}
      </div>
    </div>
  `}function ll(){const t=qe.value,e=t.filter(a=>a.status==="active").length,n=t.filter(a=>a.status==="completed").length,s={short:0,mid:0,long:0};for(const a of t)a.horizon in s&&s[a.horizon]++;return o`
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
        <div class="goal-summary-value" style="color:${we("short")}">${s.short}</div>
        <div class="goal-summary-label">Short</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${we("mid")}">${s.mid}</div>
        <div class="goal-summary-label">Mid</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${we("long")}">${s.long}</div>
        <div class="goal-summary-label">Long</div>
      </div>
    </div>
  `}function cl(){ft(()=>{Fn()},[]);const t=al.value;return o`
    <div>
      <${y} title="Goals Overview" class="section">
        <${ll} />
        <${rl} />
        <div style="margin-top:8px;">
          <button class="control-btn ghost" onClick=${Fn} disabled=${Ft.value}>
            ${Ft.value?"Refreshing...":"Refresh"}
          </button>
        </div>
      <//>

      ${Ft.value&&qe.value.length===0?o`<div class="loading-indicator">Loading goals...</div>`:Ka.value.length===0?o`<div class="empty-state">No goals match the current filters</div>`:o`
            <${an} horizon="short" items=${t.short??[]} />
            <${an} horizon="mid" items=${t.mid??[]} />
            <${an} horizon="long" items=${t.long??[]} />
          `}
    </div>
  `}const kt=_(""),on=_("ability_check"),rn=_("10"),ln=_("12"),me=_(""),_e=_("idle"),it=_(""),ge=_("keeper-late"),cn=_("player"),un=_(""),K=_("idle"),dn=_(null),$e=_(""),pn=_(""),vn=_("player"),fn=_(""),mn=_(""),_n=_(""),gn=_("20"),$n=_("20"),hn=_(""),he=_("idle"),Gn=_(null),qa=_("overview"),yn=_("all"),bn=_("all"),xn=_("all"),ul=12e4,Je=_(null),Us=_(Date.now());function dl(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function pl(t,e){return e>0?Math.round(t/e*100):0}const vl={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},fl={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function ye(t){const e=t.trim();return e?e.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):t}function ml(t){const e=t.trim().toLowerCase();return vl[e]??"행동 선택 가중치에 영향을 주는 성향입니다."}function _l(t){const e=t.trim().toLowerCase();return fl[e]??"상황에 따라 선택되는 전술 액션입니다."}function rt(t){return typeof t=="object"&&t!==null}function U(t,e,n=""){const s=t[e];return typeof s=="string"?s:n}function Q(t,e,n=0){const s=t[e];return typeof s=="number"&&Number.isFinite(s)?s:n}function ae(t,e,n=!1){const s=t[e];return typeof s=="boolean"?s:n}const gl=new Set(["str","dex","con","int","wis","cha"]);function $l(t){const e=t.trim();if(!e)return{};let n;try{n=JSON.parse(e)}catch(a){throw new Error(`능력치 JSON 파싱 실패: ${a instanceof Error?a.message:"invalid json"}`)}if(!rt(n))throw new Error('능력치 JSON은 object여야 합니다. 예: {"luck":7}');const s={};return Object.entries(n).forEach(([a,i])=>{const r=a.trim();if(r){if(typeof i=="number"&&Number.isFinite(i)){s[r]=Math.max(0,Math.trunc(i));return}if(typeof i=="string"){const c=Number.parseFloat(i.trim());if(Number.isFinite(c)){s[r]=Math.max(0,Math.trunc(c));return}}throw new Error(`능력치 '${r}' 값은 숫자여야 합니다.`)}}),s}function Jn(t){const n=(t.actor_name??t.actor??t.actor_id??"system").trim();return n===""?"system":n}function hl(t){var n;return(((n=t.timestamp)==null?void 0:n.trim())??"")||"-"}function yl(t){qa.value=t}function Ga(t){const e=Je.value;return e==null||e<=t}function bl(t){const e=Je.value;return e==null||e<=t?0:Math.max(0,Math.ceil((e-t)/1e3))}function Me(){Je.value=null}function Ja(t){return typeof window>"u"||typeof window.confirm!="function"?!0:window.confirm(t)}function xl(t,e){Ja(["관전 모드 잠금을 해제하시겠습니까?",`ROOM: ${t||"-"}`,`PHASE: ${e||"-"}`,"해제 시간: 120초 (시간 경과 또는 위험 액션 실행 후 자동 재잠금)"].join(`
`))&&(Je.value=Date.now()+ul,b("조작 잠금이 120초 동안 해제되었습니다.","warning"))}function Se(t){return Ga(t)?(b("관전 모드 잠금 상태입니다. 먼저 잠금을 해제하세요.","warning"),!1):!0}function Wn(t,e,n){return Ja([`[위험 액션 확인] ${t}`,`ROOM: ${e||"-"}`,`PHASE: ${n||"-"}`,"이 액션은 즉시 실행되며 되돌리기 어렵습니다.","계속 진행하시겠습니까?"].join(`
`))}function kl({hp:t,max:e}){const n=pl(t,e),s=dl(t,e);return o`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${s}" style="width:${n}%" />
    </div>
  `}function wl({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return o`
    <div class="trpg-actor-stats">
      ${e.map(n=>o`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function Sl({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return o`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function Wa({actor:t}){var u,p,f,l;const e=(u=t.archetype)==null?void 0:u.trim(),n=(p=t.persona)==null?void 0:p.trim(),s=(f=t.portrait)==null?void 0:f.trim(),a=(l=t.background)==null?void 0:l.trim(),i=t.traits??[],r=t.skills??[],c=Object.entries(t.stats_raw??{}).filter(([d,v])=>Number.isFinite(v)).filter(([d])=>!gl.has(d.toLowerCase()));return o`
    <div class="trpg-actor">
      ${s?o`
          <div class="trpg-actor-portrait-wrap">
            <img
              class="trpg-actor-portrait"
              src=${s}
              alt=${`${t.name} portrait`}
              loading="lazy"
              onError=${d=>{const v=d.target;v&&(v.style.display="none")}}
            />
          </div>
        `:null}
      <div class="trpg-actor-header">
        <span class="trpg-actor-name">${t.name}</span>
        <${tt} status=${t.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${t.role}">${t.role}</span>
        <${Sl} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?o`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?o`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${kl} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${wl} stats=${t.stats} />
          </div>
        `:null}
      ${e?o`<div class="trpg-actor-meta">Archetype: ${ye(e)}</div>`:null}
      ${a?o`<div class="trpg-actor-meta">Background: ${a}</div>`:null}
      ${n?o`<div class="trpg-actor-persona">${n}</div>`:null}
      ${c.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Custom Stats</div>
            <div class="trpg-custom-stats">
              ${c.map(([d,v])=>o`
                <span class="trpg-custom-stat-chip">${ye(d)} ${v}</span>
              `)}
            </div>
          </div>
        `:null}
      ${i.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Traits</div>
            <div class="trpg-annot-list">
              ${i.map(d=>o`
                <span class="trpg-annot-chip trait">
                  <span class="trpg-annot-name">${ye(d)}</span>
                  <span class="trpg-annot-desc">${ml(d)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
      ${r.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Skills</div>
            <div class="trpg-annot-list">
              ${r.map(d=>o`
                <span class="trpg-annot-chip skill">
                  <span class="trpg-annot-name">${ye(d)}</span>
                  <span class="trpg-annot-desc">${_l(d)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function Cl({mapStr:t}){return o`<pre class="trpg-map">${t}</pre>`}function Va({events:t,emptyLabel:e="아직 이벤트가 없습니다."}){return t.length===0?o`<div class="empty-state" style="font-size:13px">${e}</div>`:o`
    <div class="trpg-story" role="list" aria-label="TRPG story events">
      ${t.map((n,s)=>{var a;return o`
        <div key=${s} class="trpg-event ${n.type??""}" role="listitem">
          <div class="trpg-event-meta-row">
            <span class="trpg-event-meta">${hl(n)}</span>
            <span class="trpg-event-meta">${n.phase??"phase:-"}</span>
            <span class="trpg-event-meta">${n.type??"type:-"}</span>
          </div>
          <div class="trpg-event-main">
            <strong>${Jn(n)}</strong>
            ${" "}
          ${n.dice_roll?o`<span class="trpg-dice">[${n.dice_roll.notation}: ${(a=n.dice_roll.rolls)==null?void 0:a.join(",")} = ${n.dice_roll.total}${n.dice_roll.modifier?` +${n.dice_roll.modifier}`:""}]</span>${" "}`:null}
            <span class="trpg-event-text">${n.content??""}</span>
            <span class="trpg-event-ts"><${F} timestamp=${n.timestamp} /></span>
          </div>
        </div>
      `})}
    </div>
  `}function Al({events:t}){const e="__none__",n=yn.value,s=bn.value,a=xn.value,i=Array.from(new Set(t.map(Jn).map(l=>l.trim()).filter(l=>l!==""))).sort((l,d)=>l.localeCompare(d)),r=Array.from(new Set(t.map(l=>(l.type??"").trim()).filter(l=>l!==""))).sort((l,d)=>l.localeCompare(d)),c=t.some(l=>(l.type??"").trim()===""),u=Array.from(new Set(t.map(l=>(l.phase??"").trim()).filter(l=>l!==""))).sort((l,d)=>l.localeCompare(d)),p=t.some(l=>(l.phase??"").trim()===""),f=t.filter(l=>{if(n!=="all"&&Jn(l)!==n)return!1;const d=(l.type??"").trim(),v=(l.phase??"").trim();if(s===e){if(d!=="")return!1}else if(s!=="all"&&d!==s)return!1;if(a===e){if(v!=="")return!1}else if(a!=="all"&&v!==a)return!1;return!0});return o`
    <div class="trpg-story-toolbar">
      <div class="trpg-story-filter">
        <label>Actor</label>
        <select value=${n} onChange=${l=>{yn.value=l.target.value}}>
          <option value="all">all</option>
          ${i.map(l=>o`<option value=${l}>${l}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Type</label>
        <select value=${s} onChange=${l=>{bn.value=l.target.value}}>
          <option value="all">all</option>
          ${c?o`<option value=${e}>(none)</option>`:null}
          ${r.map(l=>o`<option value=${l}>${l}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Phase</label>
        <select value=${a} onChange=${l=>{xn.value=l.target.value}}>
          <option value="all">all</option>
          ${p?o`<option value=${e}>(none)</option>`:null}
          ${u.map(l=>o`<option value=${l}>${l}</option>`)}
        </select>
      </div>
      <button
        class="trpg-run-btn secondary"
        style="align-self:flex-end;"
        onClick=${()=>{yn.value="all",bn.value="all",xn.value="all"}}
      >
        필터 초기화
      </button>
      <span style="margin-left:auto; font-size:11px; color:#9ca3af; align-self:flex-end;">
        표시 ${f.length} / 전체 ${t.length}
      </span>
    </div>
    <${Va} events=${f.slice(-120)} emptyLabel="필터 조건에 맞는 이벤트가 없습니다." />
  `}function Nl({outcome:t}){if(!t)return null;const e=i=>{const r=i.trim();return r&&(/[A-Z]/.test(r)&&!r.includes(" ")?r.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():r.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())},n=t.result==="victory"?"승리":t.result==="defeat"?"패배":t.result==="draw"?"무승부":"종료",s=t.result==="victory"?"#34d399":t.result==="defeat"?"#f87171":"#9ca3af",a=[t.reason?`원인: ${e(t.reason)}`:null,t.phase?`페이즈: ${e(t.phase)}`:null,typeof t.turn=="number"?`턴: ${t.turn}`:null].filter(Boolean).join(" · ");return o`
    <div style="margin-bottom:16px; padding:10px 12px; border:1px solid rgba(255,255,255,0.12); border-radius:10px; background:rgba(255,255,255,0.03);">
      <div style="font-size:12px; color:#9ca3af; text-transform:uppercase; letter-spacing:0.08em;">Session Outcome</div>
      <div style="font-size:18px; font-weight:700; color:${s}; margin-top:4px;">${n}</div>
      ${t.summary?o`<div style="margin-top:4px; font-size:13px; color:#d1d5db;">${e(t.summary)}</div>`:null}
      ${a?o`<div style="margin-top:4px; font-size:11px; color:#9ca3af;">${a}</div>`:null}
    </div>
  `}function Ya({state:t}){const e=t.history??[];return e.length===0?null:o`
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
  `}function Tl({state:t,nowMs:e}){var p;const n=st.value||((p=t.session)==null?void 0:p.room)||"",s=_e.value,a=t.party??[];if(!a.find(f=>f.id===kt.value)&&a.length>0){const f=a[0];f&&(kt.value=f.id)}const r=async()=>{var l,d;if(!n){b("Room ID가 비어 있습니다.","error");return}if(!Se(e))return;const f=((l=t.current_round)==null?void 0:l.phase)??((d=t.session)==null?void 0:d.status)??"unknown";if(Wn("라운드 실행",n,f)){_e.value="running";try{const v=await xo(n);Gn.value=v,_e.value="ok";const $=rt(v.summary)?v.summary:null,x=$?ae($,"advanced",!1):!1,S=$?U($,"progress_reason",""):"";b(x?"라운드가 정상 진행되었습니다.":`라운드가 정체되었습니다${S?`: ${S}`:""}`,x?"success":"warning"),at()}catch(v){Gn.value=null,_e.value="error";const $=v instanceof Error?v.message:"라운드 실행에 실패했습니다.";b($,"error")}finally{Me()}}},c=async()=>{var l,d;if(!n||!Se(e))return;const f=((l=t.current_round)==null?void 0:l.phase)??((d=t.session)==null?void 0:d.status)??"unknown";if(Wn("턴 강제 진행",n,f))try{await So(n),b("턴을 다음 단계로 이동했습니다.","success"),at()}catch{b("턴 이동에 실패했습니다.","error")}finally{Me()}},u=async()=>{if(!n||!Se(e))return;const f=kt.value.trim();if(!f){b("먼저 Actor를 선택하세요.","warning");return}const l=Number.parseInt(rn.value,10),d=Number.parseInt(ln.value,10);if(Number.isNaN(l)||Number.isNaN(d)){b("stat/dc는 숫자여야 합니다.","warning");return}const v=Number.parseInt(me.value,10),$=me.value.trim()===""||Number.isNaN(v)?void 0:v;try{await wo({roomId:n,actorId:f,action:on.value.trim()||"ability_check",statValue:l,dc:d,rawD20:$}),b("주사위 판정을 기록했습니다.","success"),at()}catch{b("주사위 판정 기록에 실패했습니다.","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            id="trpg-room-input"
            name="trpg-room-input"
            type="text"
            value=${n}
            onInput=${f=>{st.value=f.target.value}}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${kt.value}
            onChange=${f=>{kt.value=f.target.value}}
          >
            <option value="">Actor 선택</option>
            ${a.map(f=>o`<option value=${f.id}>${f.name} (${f.id})</option>`)}
          </select>
        </div>

        <div class="trpg-control-field">
          <label>Dice</label>
          <div style="display:grid; grid-template-columns: 1fr 1fr; gap:6px;">
            <input
              id="trpg-dice-action-input"
              name="trpg-dice-action-input"
              type="text"
              value=${on.value}
              onInput=${f=>{on.value=f.target.value}}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${rn.value}
              onInput=${f=>{rn.value=f.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${ln.value}
              onInput=${f=>{ln.value=f.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              id="trpg-dice-raw-input"
              name="trpg-dice-raw-input"
              type="text"
              value=${me.value}
              onInput=${f=>{me.value=f.target.value}}
              onKeyDown=${f=>{f.key==="Enter"&&u()}}
              placeholder="raw d20 (optional)"
            />
          </div>
        </div>

        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:4px;">
            <button class="trpg-run-btn secondary" onClick=${u}>Roll</button>
            <button
              class="trpg-run-btn recommend"
              onClick=${r}
              disabled=${s==="running"}
            >
              ${s==="running"?"실행 중...":"Run Round"}
            </button>
            <button class="trpg-run-btn secondary" onClick=${c}>
              Next Turn
            </button>
          </div>
        </div>
      </div>

      ${s!=="idle"?o`<div class="trpg-run-status ${s}">${s==="running"?"처리 중...":s==="ok"?"완료":"실패"}</div>`:null}
    </div>
  `}function Rl({state:t}){var a;const e=st.value||((a=t.session)==null?void 0:a.room)||"",n=he.value,s=async()=>{if(!e){b("Room ID가 비어 있습니다.","warning");return}const i=$e.value.trim(),r=pn.value.trim();if(!r&&!i){b("이름 또는 Actor ID를 입력하세요.","warning");return}const c=Number.parseInt(gn.value.trim(),10),u=Number.parseInt($n.value.trim(),10),p=Number.isFinite(u)?Math.max(1,u):20,f=Number.isFinite(c)?Math.max(0,Math.min(p,c)):p;let l={};try{l=$l(hn.value)}catch(d){b(d instanceof Error?d.message:"능력치 JSON 오류","error");return}he.value="spawning";try{const d=await Co(e,{actor_id:i||void 0,name:r||void 0,role:vn.value,portrait:mn.value.trim()||void 0,background:_n.value.trim()||void 0,hp:f,max_hp:p,alive:f>0,stats:Object.keys(l).length>0?l:void 0}),v=typeof d.actor_id=="string"?d.actor_id.trim():"";if(!v)throw new Error("생성 응답에 actor_id가 없습니다.");const $=fn.value.trim();$&&await Ao(e,v,$),kt.value=v,it.value=v,i||($e.value=""),he.value="ok",b(`Actor 생성 완료: ${v}`,"success"),await at()}catch(d){he.value="error",b(d instanceof Error?d.message:"Actor 생성에 실패했습니다.","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Name</label>
          <input
            id="trpg-spawn-name-input"
            name="trpg-spawn-name-input"
            type="text"
            value=${pn.value}
            onInput=${i=>{pn.value=i.target.value}}
            placeholder="Night Fox"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${vn.value}
            onChange=${i=>{vn.value=i.target.value}}
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
            value=${fn.value}
            onInput=${i=>{fn.value=i.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn recommend" onClick=${s} disabled=${n==="spawning"}>
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
              value=${$e.value}
              onInput=${i=>{$e.value=i.target.value}}
              placeholder="auto when blank"
            />
          </div>
          <div class="trpg-control-field">
            <label>Portrait URL</label>
            <input
              id="trpg-spawn-portrait-input"
              name="trpg-spawn-portrait-input"
              type="text"
              value=${mn.value}
              onInput=${i=>{mn.value=i.target.value}}
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
              value=${gn.value}
              onInput=${i=>{gn.value=i.target.value}}
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
              value=${$n.value}
              onInput=${i=>{$n.value=i.target.value}}
              placeholder="20"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Background</label>
            <input
              id="trpg-spawn-background-input"
              name="trpg-spawn-background-input"
              type="text"
              value=${_n.value}
              onInput=${i=>{_n.value=i.target.value}}
              placeholder="망명 기사 · 폐허 수색 전문가"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Stats JSON</label>
            <input
              id="trpg-spawn-stats-json-input"
              name="trpg-spawn-stats-json-input"
              type="text"
              value=${hn.value}
              onInput=${i=>{hn.value=i.target.value}}
              placeholder='{"luck":7,"stealth":12,"str":10}'
            />
          </div>
        </div>
      </details>

      ${n!=="idle"?o`<div class="trpg-run-status ${n==="spawning"?"running":n}">${n==="spawning"?"생성 중...":n==="ok"?"생성 완료":"생성 실패"}</div>`:null}
    </div>
  `}function Ll({state:t,nowMs:e}){var d;const n=st.value||((d=t.session)==null?void 0:d.room)||"",s=t.join_gate,a=dn.value,i=rt(a)?a:null,r=(t.party??[]).filter(v=>v.role!=="dm"),c=it.value.trim(),u=r.some(v=>v.id===c),p=u?c:c?"__manual__":"",f=async()=>{const v=it.value.trim(),$=ge.value.trim();if(!n||!v){b("Room/Actor가 필요합니다.","warning");return}K.value="checking";try{const x=await No(n,v,$||void 0);dn.value=x,K.value="ok",b("참가 가능 여부를 갱신했습니다.","success")}catch(x){K.value="error";const S=x instanceof Error?x.message:"참가 가능 여부 확인에 실패했습니다.";b(S,"error")}},l=async()=>{var A,C;const v=it.value.trim(),$=ge.value.trim(),x=un.value.trim();if(!n||!v||!$){b("Room/Actor/Keeper가 필요합니다.","warning");return}if(!Se(e))return;const S=((A=t.current_round)==null?void 0:A.phase)??((C=t.session)==null?void 0:C.status)??"unknown";if(Wn("Mid-Join 승인 요청",n,S)){K.value="requesting";try{const D=await To({room_id:n,actor_id:v,keeper_name:$,role:cn.value,...x?{name:x}:{}});dn.value=D;const M=rt(D)?ae(D,"granted",!1):!1,E=rt(D)?U(D,"reason_code",""):"";M?b("Mid-Join이 승인되었습니다.","success"):b(`Mid-Join이 거절되었습니다${E?`: ${E}`:""}`,"warning"),K.value=M?"ok":"error",at()}catch(D){K.value="error";const M=D instanceof Error?D.message:"Mid-Join 요청에 실패했습니다.";b(M,"error")}finally{Me()}}};return o`
    <div class="trpg-control-box">
      <div style="font-size:12px; color:#9ca3af; margin-bottom:8px;">
        Window: <strong>${s!=null&&s.phase_open?"OPEN":"CLOSED"}</strong>
        ${s!=null&&s.window?o`<span style="margin-left:8px;">(${s.window})</span>`:null}
        <span style="margin-left:8px;">Required: ${(s==null?void 0:s.min_points)??3} pts</span>
      </div>
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Actor ID</label>
          <select
            value=${p}
            onChange=${v=>{const $=v.target.value;if($==="__manual__"){(u||!c)&&(it.value="");return}it.value=$}}
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
                value=${it.value}
                onInput=${v=>{it.value=v.target.value}}
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
            value=${ge.value}
            onInput=${v=>{ge.value=v.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${cn.value}
            onChange=${v=>{cn.value=v.target.value}}
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
            value=${un.value}
            onInput=${v=>{un.value=v.target.value}}
            placeholder="display name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn secondary" onClick=${f} disabled=${K.value==="checking"||K.value==="requesting"}>
              ${K.value==="checking"?"Checking...":"Check"}
            </button>
            <button class="trpg-run-btn recommend" onClick=${l} disabled=${K.value==="checking"||K.value==="requesting"}>
              ${K.value==="requesting"?"Requesting...":"Request Join"}
            </button>
          </div>
        </div>
      </div>
      ${i?o`
          <div style="margin-top:8px; font-size:12px; color:#d1d5db;">
            Eligible: <strong>${ae(i,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${Q(i,"effective_score",0)}/${Q(i,"required_points",0)}</span>
            ${U(i,"reason_code","")?o`<span style="margin-left:8px;">Reason: ${U(i,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function Qa({state:t}){const e=[...t.contribution_ledger??[]].sort((n,s)=>(s.score??0)-(n.score??0)).slice(0,8);return e.length===0?o`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:o`
    <div class="trpg-round-list">
      ${e.map(n=>o`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function Xa({state:t}){var n;const e=t.current_round;return e?o`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?o`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function Za(){const t=Gn.value;if(!t)return o`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const e=t.summary,n=rt(e)?e:null,a=(Array.isArray(t.statuses)?t.statuses:[]).filter(rt).slice(-8),i=t.canon_check,r=rt(i)?i:null,c=r&&Array.isArray(r.warnings)?r.warnings.filter(E=>typeof E=="string").slice(0,3):[],u=r&&Array.isArray(r.violations)?r.violations.filter(E=>typeof E=="string").slice(0,3):[],p=n?ae(n,"advanced",!1):!1,f=n?U(n,"progress_reason",""):"",l=n?U(n,"progress_detail",""):"",d=n?Q(n,"player_successes",0):0,v=n?Q(n,"player_required_successes",0):0,$=n?ae(n,"dm_success",!1):!1,x=n?Q(n,"timeouts",0):0,S=n?Q(n,"unavailable",0):0,A=n?Q(n,"reprompts",0):0,C=n?Q(n,"npc_attacks",0):0,D=n?Q(n,"keeper_timeout_sec",0):0,M=n?Q(n,"roll_audit_count",0):0;return o`
    <div style="display:grid; gap:10px;">
      <div class="trpg-round-item ${p?"active":"failed"}" style="display:block;">
        <div style="display:flex; align-items:center; gap:8px;">
          <strong>${p?"ADVANCED":"STALLED"}</strong>
          <span style="font-size:11px; color:#9ca3af;">
            turn ${t.turn_before??0} → ${t.turn_after??0}
          </span>
          <span style="margin-left:auto; font-size:11px; color:#9ca3af;">
            ${$?"DM ok":"DM stalled"} / players ${d}/${v}
          </span>
        </div>
        ${f?o`<div style="margin-top:4px; font-size:12px;">${f}</div>`:null}
        ${l?o`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${l}</div>`:null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${x}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${S}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${A}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${C}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${D||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${M}</div></div>
      </div>

      ${a.length>0?o`
          <div class="trpg-round-list">
            ${a.map(E=>{const q=U(E,"status","unknown"),ut=U(E,"actor_id","-"),dt=U(E,"role","-"),G=U(E,"reason",""),et=U(E,"action_type",""),R=U(E,"reply","");return o`
                <div class="trpg-round-item ${q.includes("fallback")||q.includes("timeout")?"failed":"active"}">
                  <span>${ut} (${dt})</span>
                  <span style="margin-left:auto; font-size:11px;">${q}</span>
                  ${et?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${et}</div>`:null}
                  ${G?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${G}</div>`:null}
                  ${R?o`<div style="width:100%; font-size:11px; color:#d1d5db; margin-top:2px;">${R.slice(0,120)}</div>`:null}
                </div>
              `})}
          </div>`:null}

      ${r?o`
          <div class="trpg-control-box">
            <div style="font-size:12px; color:#9ca3af;">
              Canon status: <strong>${U(r,"status","unknown")}</strong>
            </div>
            ${u.length>0?o`
                <div style="margin-top:6px; font-size:11px; color:#fca5a5;">
                  ${u.map(E=>o`<div>violation: ${E}</div>`)}
                </div>`:null}
            ${c.length>0?o`
                <div style="margin-top:6px; font-size:11px; color:#fbbf24;">
                  ${c.map(E=>o`<div>warning: ${E}</div>`)}
                </div>`:null}
          </div>
        `:null}
    </div>
  `}function El({state:t,nowMs:e}){var r,c,u;const n=st.value||((r=t.session)==null?void 0:r.room)||"",s=((c=t.current_round)==null?void 0:c.phase)??((u=t.session)==null?void 0:u.status)??"unknown",a=Ga(e),i=bl(e);return o`
    <${y} title="조작 안전 잠금" style="margin-bottom:16px;">
      <div class="trpg-control-lock ${a?"locked":"unlocked"}">
        <div class="trpg-control-lock-title">
          ${a?"잠금 상태: 관전 전용":"잠금 해제됨"}
        </div>
        <div class="trpg-control-lock-desc">
          ${a?"조작 액션은 실행되지 않습니다. 필요할 때만 잠금을 해제하세요.":`위험 액션 실행 또는 ${i}초 후 자동으로 다시 잠깁니다.`}
        </div>
        <div class="trpg-control-lock-meta">room: ${n||"-"} · phase: ${s||"-"}</div>
        <div style="display:flex; gap:8px; margin-top:10px; flex-wrap:wrap;">
          ${a?o`<button class="trpg-run-btn recommend" onClick=${()=>xl(n,s)}>잠금 해제 (120초)</button>`:o`<button class="trpg-run-btn secondary" onClick=${()=>{Me(),b("조작 잠금으로 전환했습니다.","success")}}>즉시 다시 잠금</button>`}
        </div>
      </div>
    <//>
  `}function Dl({active:t}){return o`
    <div class="trpg-screen-tabs" role="tablist" aria-label="TRPG 화면 선택">
      ${[{id:"overview",label:"Overview",desc:"관전 요약"},{id:"timeline",label:"Timeline",desc:"이벤트 흐름"},{id:"control",label:"Control",desc:"운영/개입"}].map(n=>o`
        <button
          class="trpg-screen-tab ${t===n.id?"active":""}"
          role="tab"
          aria-selected=${t===n.id}
          onClick=${()=>yl(n.id)}
        >
          <span class="trpg-screen-tab-label">${n.label}</span>
          <span class="trpg-screen-tab-desc">${n.desc}</span>
        </button>
      `)}
    </div>
  `}function Pl({state:t}){const e=t.party??[],n=t.story_log??[];return o`
    <div class="trpg-layout">
      <div>
        <${y} title="관전 가이드">
          <div class="trpg-guide-box">
            <div class="trpg-guide-title">권장 운영 순서</div>
            <div class="trpg-guide-text">1) Overview에서 상태 파악 → 2) Timeline에서 원인 확인 → 3) 필요 시 Control에서 최소 개입</div>
            <div class="trpg-guide-meta">관전자 기본 모드 / 위험 액션은 Control 잠금 해제 후 실행</div>
          </div>
        <//>

        <${y} title=${`최근 스토리 (${Math.min(n.length,20)})`} style="margin-top:16px;">
          <${Va} events=${n.slice(-20)} />
        <//>

        ${t.map?o`
            <${y} title="맵" style="margin-top:16px;">
              <${Cl} mapStr=${t.map} />
            <//>
          `:null}
      </div>

      <div class="trpg-sidebar">
        <${y} title="현재 라운드">
          <${Xa} state=${t} />
        <//>

        <${y} title="기여도" style="margin-top:16px;">
          <${Qa} state=${t} />
        <//>

        <${y} title=${`파티 (${e.length})`} style="margin-top:16px;">
          <div class="trpg-actor-list">
            ${e.map(s=>o`<${Wa} key=${s.id??s.name} actor=${s} />`)}
            ${e.length===0?o`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
          </div>
        <//>

        ${t.history&&t.history.length>0?o`
            <${y} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
              <${Ya} state=${t} />
            <//>
          `:null}
      </div>
    </div>
  `}function Il({state:t}){const e=t.story_log??[];return o`
    <div class="trpg-layout">
      <div>
        <${y} title=${`이벤트 타임라인 (${e.length})`}>
          <${Al} events=${e} />
        <//>
      </div>

      <div class="trpg-sidebar">
        <${y} title="최근 라운드 결과">
          <${Za} />
        <//>

        <${y} title="현재 라운드" style="margin-top:16px;">
          <${Xa} state=${t} />
        <//>
      </div>
    </div>
  `}function Ol({state:t,nowMs:e}){const n=t.party??[];return o`
    <div>
      <${El} state=${t} nowMs=${e} />
      <div class="trpg-layout">
        <div>
          <${y} title="조작 패널">
            <${Tl} state=${t} nowMs=${e} />
          <//>

          <${y} title="Actor Spawn" style="margin-top:16px;">
            <${Rl} state=${t} />
          <//>

          <${y} title="Mid-Join Gate" style="margin-top:16px;">
            <${Ll} state=${t} nowMs=${e} />
          <//>

          <${y} title="최근 라운드 결과" style="margin-top:16px;">
            <${Za} />
          <//>
        </div>

        <div class="trpg-sidebar">
          <${y} title="기여도" style="margin-top:0;">
            <${Qa} state=${t} />
          <//>

          <${y} title=${`파티 (${n.length})`} style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(s=>o`<${Wa} key=${s.id??s.name} actor=${s} />`)}
              ${n.length===0?o`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
            </div>
          <//>

          ${t.history&&t.history.length>0?o`
              <${y} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
                <${Ya} state=${t} />
              <//>
            `:null}
        </div>
      </div>
    </div>
  `}function jl(){var c,u,p,f,l;const t=Ia.value,e=jn.value;if(ft(()=>{if(typeof window>"u"||typeof window.setInterval!="function")return;const d=window.setInterval(()=>{Us.value=Date.now()},1e3);return()=>{window.clearInterval(d)}},[]),e&&!t)return o`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return o`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>at()}>Refresh</button>
      </div>
    `;const n=t.party??[],s=t.story_log??[],a=t.outcome,i=qa.value,r=Us.value;return o`
    <div>
      <div style="display:flex; gap:8px; align-items:center; justify-content:space-between; margin-bottom:8px;">
        <div style="font-size:11px; color:#8ea9d6;">
          room: ${st.value||((c=t.session)==null?void 0:c.room)||"-"} · phase: ${((u=t.current_round)==null?void 0:u.phase)??((p=t.session)==null?void 0:p.status)??"-"}
        </div>
        <button class="trpg-run-btn secondary" onClick=${()=>at()}>새로고침</button>
      </div>

      <${Nl} outcome=${a} />

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
          <div class="stat-value">${s.length}</div>
        </div>
      </div>

      <${Dl} active=${i} />

      ${i==="overview"?o`<${Pl} state=${t} />`:i==="timeline"?o`<${Il} state=${t} />`:o`<${Ol} state=${t} nowMs=${r} />`}
    </div>
  `}const ls="masc_dashboard_agent_name";function Ml(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem(ls);return e??n??"dashboard"}const Y=_(Ml()),Wt=_(""),Vt=_(""),Fe=_(""),Yt=_(!1),wt=_(!1),Qt=_(!1),Xt=_(!1),ze=_(!1),We=_(!1);function cs(t){const e=t.trim();Y.value=e,e&&localStorage.setItem(ls,e)}function Fl(t){const n=(t.split(`
`).find(s=>s.includes(" joined"))??t).match(/✅\s+(\S+)\s+joined/i);return(n==null?void 0:n[1])??null}async function Vn(){const t=Y.value.trim();if(t){Qt.value=!0;try{const e=await Lo(t),n=Fl(e);n&&cs(n),We.value=!0,b(`Joined as ${n??t}`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to join room";b(n,"error")}finally{Qt.value=!1}}}async function zl(){const t=Y.value.trim();if(t){Xt.value=!0;try{await Ea(t),We.value=!1,b(`Left room (${t})`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to leave room";b(n,"error")}finally{Xt.value=!1}}}async function Ul(){const t=Y.value.trim();if(t)try{await Ea(t)}catch{}localStorage.removeItem(ls),cs("dashboard"),We.value=!1,await Vn()}async function Hl(){const t=Y.value.trim();if(t){ze.value=!0;try{await Eo(t),b("Heartbeat sent","success")}catch(e){const n=e instanceof Error?e.message:"Failed to send heartbeat";b(n,"error")}finally{ze.value=!1}}}async function Hs(){const t=Y.value.trim(),e=Wt.value.trim();if(!(!t||!e)){Yt.value=!0;try{await La(t,e),Wt.value="",b("Broadcast sent","success")}catch(n){const s=n instanceof Error?n.message:"Failed to send broadcast";b(s,"error")}finally{Yt.value=!1}}}async function Bl(){const t=Vt.value.trim(),e=Fe.value.trim()||"Created from dashboard";if(t){wt.value=!0;try{await Ro(t,e,1),Vt.value="",Fe.value="",b("Task created","success")}catch(n){const s=n instanceof Error?n.message:"Failed to create task";b(s,"error")}finally{wt.value=!1}}}function Kl(){return ft(()=>{Vn()},[]),o`
    <section class="rail-card control-dock">
      <h3>Control Dock</h3>

      <label class="control-label" for="dock-agent">Agent</label>
      <input
        id="dock-agent"
        class="control-input"
        type="text"
        value=${Y.value}
        onInput=${t=>cs(t.target.value)}
      />

      <label class="control-label" for="dock-message">Broadcast</label>
      <div class="control-row">
        <input
          id="dock-message"
          class="control-input"
          type="text"
          placeholder="@agent message or room update"
          value=${Wt.value}
          onInput=${t=>{Wt.value=t.target.value}}
          onKeyDown=${t=>{t.key==="Enter"&&Hs()}}
          disabled=${Yt.value}
        />
        <button
          class="control-btn"
          onClick=${Hs}
          disabled=${Yt.value||Wt.value.trim()===""||Y.value.trim()===""}
        >
          ${Yt.value?"Sending...":"Send"}
        </button>
      </div>

      <div class="control-row">
        <button
          class="control-btn ghost"
          onClick=${()=>{Vn()}}
          disabled=${Qt.value||Y.value.trim()===""}
        >
          ${Qt.value?"Joining...":We.value?"Rejoin":"Join"}
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{zl()}}
          disabled=${Xt.value||Y.value.trim()===""}
        >
          ${Xt.value?"Leaving...":"Leave"}
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{Ul()}}
          disabled=${Qt.value||Xt.value}
        >
          Reset ID
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{Hl()}}
          disabled=${ze.value||Y.value.trim()===""}
        >
          ${ze.value?"Pinging...":"Heartbeat"}
        </button>
      </div>

      <label class="control-label" for="dock-task">Quick Task</label>
      <input
        id="dock-task"
        class="control-input"
        type="text"
        placeholder="Task title"
        value=${Vt.value}
        onInput=${t=>{Vt.value=t.target.value}}
        disabled=${wt.value}
      />
      <textarea
        class="control-textarea"
        placeholder="Task description (optional)"
        value=${Fe.value}
        onInput=${t=>{Fe.value=t.target.value}}
        disabled=${wt.value}
      ></textarea>
      <button
        class="control-btn secondary"
        onClick=${Bl}
        disabled=${wt.value||Vt.value.trim()===""}
      >
        ${wt.value?"Creating...":"Create Task"}
      </button>
    </section>
  `}function ql(){const t=Nt.value;return o`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"Live":"Reconnecting..."}</span>
      <span class="event-count">${ns.value} events</span>
    </div>
  `}function Gl(){const t=Z.value.tab,e=Nt.value;return o`
    <aside class="dashboard-rail">
      <section class="rail-card">
        <h3>Views</h3>
        <div class="rail-tab-list">
          ${ba.map(n=>o`
            <button
              class="rail-tab-btn ${t===n.id?"active":""}"
              onClick=${()=>Ke(n.id)}
            >
              ${n.icon} ${n.label}
            </button>
          `)}
        </div>
        <div class="rail-links">
          <a class="rail-link" href="/dashboard/lodge">Legacy Lodge</a>
          <a class="rail-link" href="/dashboard/credits">Legacy Credits</a>
        </div>
      </section>

      <section class="rail-card">
        <h3>Live Snapshot</h3>
        <div class="rail-stats">
          <div class="rail-stat-row">
            <span>Connection</span>
            <strong>${e?"Online":"Offline"}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Agents</span>
            <strong>${Et.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Keepers</span>
            <strong>${Dt.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Tasks</span>
            <strong>${ce.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Events</span>
            <strong>${ns.value}</strong>
          </div>
        </div>
        <button
          class="rail-refresh-btn"
          onClick=${()=>{Ge(),t==="board"&&$t(),t==="trpg"&&at()}}
        >
          Refresh Now
        </button>
      </section>

      <${Kl} />
    </aside>
  `}function Jl(){switch(Z.value.tab){case"overview":return o`<${Is} />`;case"council":return o`<${Tr} />`;case"board":return o`<${Fr} />`;case"execution":return o`<${el} />`;case"activity":return o`<${Br} />`;case"agents":return o`<${Xr} />`;case"tasks":return o`<${Zr} />`;case"goals":return o`<${cl} />`;case"journal":return o`<${sl} />`;case"trpg":return o`<${jl} />`;default:return o`<${Is} />`}}function Wl(){return ft(()=>{Oi(),wa(),Ge();const t=Qo();return Xo(),()=>{Ki(),t(),Zo()}},[]),ft(()=>{const t=Z.value.tab;t==="board"&&$t(),t==="trpg"&&at(),t==="goals"&&Fn()},[Z.value.tab]),o`
    <div class="app-shell">
      <header class="dashboard-header">
        <div class="header-title-wrap">
          <h1>
            MASC Dashboard
            <span class="version-badge">SPA</span>
          </h1>
          <p class="header-subtitle">Decision and execution operations console</p>
        </div>
        <div class="header-right">
          <${ql} />
          <div class="header-links">
            <a href="/dashboard/lodge">Lodge</a>
            <a href="/dashboard/credits">Credits</a>
          </div>
        </div>
      </header>

      <div class="tab-sticky-wrap">
        <${ji} />
      </div>

      <div class="dashboard-layout">
        <main class="dashboard-main">
          ${In.value&&!Nt.value?o`<div class="loading-indicator">Loading dashboard...</div>`:o`<${Jl} />`}
        </main>
        <${Gl} />
      </div>

      <${dr} />
      <${hr} />
      <${fr} />
    </div>
  `}const Bs=document.getElementById("app");Bs&&hi(o`<${Wl} />`,Bs);
