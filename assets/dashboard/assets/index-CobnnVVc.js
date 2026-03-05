var gi=Object.defineProperty;var $i=(t,e,n)=>e in t?gi(t,e,{enumerable:!0,configurable:!0,writable:!0,value:n}):t[e]=n;var bt=(t,e,n)=>$i(t,typeof e!="symbol"?e+"":e,n);(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const s of document.querySelectorAll('link[rel="modulepreload"]'))a(s);new MutationObserver(s=>{for(const i of s)if(i.type==="childList")for(const r of i.addedNodes)r.tagName==="LINK"&&r.rel==="modulepreload"&&a(r)}).observe(document,{childList:!0,subtree:!0});function n(s){const i={};return s.integrity&&(i.integrity=s.integrity),s.referrerPolicy&&(i.referrerPolicy=s.referrerPolicy),s.crossOrigin==="use-credentials"?i.credentials="include":s.crossOrigin==="anonymous"?i.credentials="omit":i.credentials="same-origin",i}function a(s){if(s.ep)return;s.ep=!0;const i=n(s);fetch(s.href,i)}})();var qe,R,Ja,Ga,mt,_a,Va,Ya,Qa,Zn,An,Nn,ne={},Xa=[],hi=/acit|ex(?:s|g|n|p|$)|rph|grid|ows|mnc|ntw|ine[ch]|zoo|^ord|itera/i,We=Array.isArray;function st(t,e){for(var n in e)t[n]=e[n];return t}function ta(t){t&&t.parentNode&&t.parentNode.removeChild(t)}function Za(t,e,n){var a,s,i,r={};for(i in e)i=="key"?a=e[i]:i=="ref"?s=e[i]:r[i]=e[i];if(arguments.length>2&&(r.children=arguments.length>3?qe.call(arguments,2):n),typeof t=="function"&&t.defaultProps!=null)for(i in t.defaultProps)r[i]===void 0&&(r[i]=t.defaultProps[i]);return we(t,r,a,s,null)}function we(t,e,n,a,s){var i={type:t,props:e,key:n,ref:a,__k:null,__:null,__b:0,__e:null,__c:null,constructor:void 0,__v:s??++Ja,__i:-1,__u:0};return s==null&&R.vnode!=null&&R.vnode(i),i}function le(t){return t.children}function Ft(t,e){this.props=t,this.context=e}function Tt(t,e){if(e==null)return t.__?Tt(t.__,t.__i+1):null;for(var n;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null)return n.__e;return typeof t.type=="function"?Tt(t):null}function ts(t){var e,n;if((t=t.__)!=null&&t.__c!=null){for(t.__e=t.__c.base=null,e=0;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null){t.__e=t.__c.base=n.__e;break}return ts(t)}}function ga(t){(!t.__d&&(t.__d=!0)&&mt.push(t)&&!Te.__r++||_a!=R.debounceRendering)&&((_a=R.debounceRendering)||Va)(Te)}function Te(){for(var t,e,n,a,s,i,r,c=1;mt.length;)mt.length>c&&mt.sort(Ya),t=mt.shift(),c=mt.length,t.__d&&(n=void 0,a=void 0,s=(a=(e=t).__v).__e,i=[],r=[],e.__P&&((n=st({},a)).__v=a.__v+1,R.vnode&&R.vnode(n),ea(e.__P,n,a,e.__n,e.__P.namespaceURI,32&a.__u?[s]:null,i,s??Tt(a),!!(32&a.__u),r),n.__v=a.__v,n.__.__k[n.__i]=n,as(i,n,r),a.__e=a.__=null,n.__e!=s&&ts(n)));Te.__r=0}function es(t,e,n,a,s,i,r,c,u,d,m){var l,p,v,g,x,C,N,A=a&&a.__k||Xa,E=e.length;for(u=yi(n,e,A,u,E),l=0;l<E;l++)(v=n.__k[l])!=null&&(p=v.__i==-1?ne:A[v.__i]||ne,v.__i=l,C=ea(t,v,p,s,i,r,c,u,d,m),g=v.__e,v.ref&&p.ref!=v.ref&&(p.ref&&na(p.ref,null,v),m.push(v.ref,v.__c||g,v)),x==null&&g!=null&&(x=g),(N=!!(4&v.__u))||p.__k===v.__k?u=ns(v,u,t,N):typeof v.type=="function"&&C!==void 0?u=C:g&&(u=g.nextSibling),v.__u&=-7);return n.__e=x,u}function yi(t,e,n,a,s){var i,r,c,u,d,m=n.length,l=m,p=0;for(t.__k=new Array(s),i=0;i<s;i++)(r=e[i])!=null&&typeof r!="boolean"&&typeof r!="function"?(typeof r=="string"||typeof r=="number"||typeof r=="bigint"||r.constructor==String?r=t.__k[i]=we(null,r,null,null,null):We(r)?r=t.__k[i]=we(le,{children:r},null,null,null):r.constructor===void 0&&r.__b>0?r=t.__k[i]=we(r.type,r.props,r.key,r.ref?r.ref:null,r.__v):t.__k[i]=r,u=i+p,r.__=t,r.__b=t.__b+1,c=null,(d=r.__i=bi(r,n,u,l))!=-1&&(l--,(c=n[d])&&(c.__u|=2)),c==null||c.__v==null?(d==-1&&(s>m?p--:s<m&&p++),typeof r.type!="function"&&(r.__u|=4)):d!=u&&(d==u-1?p--:d==u+1?p++:(d>u?p--:p++,r.__u|=4))):t.__k[i]=null;if(l)for(i=0;i<m;i++)(c=n[i])!=null&&(2&c.__u)==0&&(c.__e==a&&(a=Tt(c)),is(c,c));return a}function ns(t,e,n,a){var s,i;if(typeof t.type=="function"){for(s=t.__k,i=0;s&&i<s.length;i++)s[i]&&(s[i].__=t,e=ns(s[i],e,n,a));return e}t.__e!=e&&(a&&(e&&t.type&&!e.parentNode&&(e=Tt(t)),n.insertBefore(t.__e,e||null)),e=t.__e);do e=e&&e.nextSibling;while(e!=null&&e.nodeType==8);return e}function bi(t,e,n,a){var s,i,r,c=t.key,u=t.type,d=e[n],m=d!=null&&(2&d.__u)==0;if(d===null&&c==null||m&&c==d.key&&u==d.type)return n;if(a>(m?1:0)){for(s=n-1,i=n+1;s>=0||i<e.length;)if((d=e[r=s>=0?s--:i++])!=null&&(2&d.__u)==0&&c==d.key&&u==d.type)return r}return-1}function $a(t,e,n){e[0]=="-"?t.setProperty(e,n??""):t[e]=n==null?"":typeof n!="number"||hi.test(e)?n:n+"px"}function me(t,e,n,a,s){var i,r;t:if(e=="style")if(typeof n=="string")t.style.cssText=n;else{if(typeof a=="string"&&(t.style.cssText=a=""),a)for(e in a)n&&e in n||$a(t.style,e,"");if(n)for(e in n)a&&n[e]==a[e]||$a(t.style,e,n[e])}else if(e[0]=="o"&&e[1]=="n")i=e!=(e=e.replace(Qa,"$1")),r=e.toLowerCase(),e=r in t||e=="onFocusOut"||e=="onFocusIn"?r.slice(2):e.slice(2),t.l||(t.l={}),t.l[e+i]=n,n?a?n.u=a.u:(n.u=Zn,t.addEventListener(e,i?Nn:An,i)):t.removeEventListener(e,i?Nn:An,i);else{if(s=="http://www.w3.org/2000/svg")e=e.replace(/xlink(H|:h)/,"h").replace(/sName$/,"s");else if(e!="width"&&e!="height"&&e!="href"&&e!="list"&&e!="form"&&e!="tabIndex"&&e!="download"&&e!="rowSpan"&&e!="colSpan"&&e!="role"&&e!="popover"&&e in t)try{t[e]=n??"";break t}catch{}typeof n=="function"||(n==null||n===!1&&e[4]!="-"?t.removeAttribute(e):t.setAttribute(e,e=="popover"&&n==1?"":n))}}function ha(t){return function(e){if(this.l){var n=this.l[e.type+t];if(e.t==null)e.t=Zn++;else if(e.t<n.u)return;return n(R.event?R.event(e):e)}}}function ea(t,e,n,a,s,i,r,c,u,d){var m,l,p,v,g,x,C,N,A,E,O,D,q,pt,vt,W,at,L=e.type;if(e.constructor!==void 0)return null;128&n.__u&&(u=!!(32&n.__u),i=[c=e.__e=n.__e]),(m=R.__b)&&m(e);t:if(typeof L=="function")try{if(N=e.props,A="prototype"in L&&L.prototype.render,E=(m=L.contextType)&&a[m.__c],O=m?E?E.props.value:m.__:a,n.__c?C=(l=e.__c=n.__c).__=l.__E:(A?e.__c=l=new L(N,O):(e.__c=l=new Ft(N,O),l.constructor=L,l.render=ki),E&&E.sub(l),l.state||(l.state={}),l.__n=a,p=l.__d=!0,l.__h=[],l._sb=[]),A&&l.__s==null&&(l.__s=l.state),A&&L.getDerivedStateFromProps!=null&&(l.__s==l.state&&(l.__s=st({},l.__s)),st(l.__s,L.getDerivedStateFromProps(N,l.__s))),v=l.props,g=l.state,l.__v=e,p)A&&L.getDerivedStateFromProps==null&&l.componentWillMount!=null&&l.componentWillMount(),A&&l.componentDidMount!=null&&l.__h.push(l.componentDidMount);else{if(A&&L.getDerivedStateFromProps==null&&N!==v&&l.componentWillReceiveProps!=null&&l.componentWillReceiveProps(N,O),e.__v==n.__v||!l.__e&&l.shouldComponentUpdate!=null&&l.shouldComponentUpdate(N,l.__s,O)===!1){for(e.__v!=n.__v&&(l.props=N,l.state=l.__s,l.__d=!1),e.__e=n.__e,e.__k=n.__k,e.__k.some(function(M){M&&(M.__=e)}),D=0;D<l._sb.length;D++)l.__h.push(l._sb[D]);l._sb=[],l.__h.length&&r.push(l);break t}l.componentWillUpdate!=null&&l.componentWillUpdate(N,l.__s,O),A&&l.componentDidUpdate!=null&&l.__h.push(function(){l.componentDidUpdate(v,g,x)})}if(l.context=O,l.props=N,l.__P=t,l.__e=!1,q=R.__r,pt=0,A){for(l.state=l.__s,l.__d=!1,q&&q(e),m=l.render(l.props,l.state,l.context),vt=0;vt<l._sb.length;vt++)l.__h.push(l._sb[vt]);l._sb=[]}else do l.__d=!1,q&&q(e),m=l.render(l.props,l.state,l.context),l.state=l.__s;while(l.__d&&++pt<25);l.state=l.__s,l.getChildContext!=null&&(a=st(st({},a),l.getChildContext())),A&&!p&&l.getSnapshotBeforeUpdate!=null&&(x=l.getSnapshotBeforeUpdate(v,g)),W=m,m!=null&&m.type===le&&m.key==null&&(W=ss(m.props.children)),c=es(t,We(W)?W:[W],e,n,a,s,i,r,c,u,d),l.base=e.__e,e.__u&=-161,l.__h.length&&r.push(l),C&&(l.__E=l.__=null)}catch(M){if(e.__v=null,u||i!=null)if(M.then){for(e.__u|=u?160:128;c&&c.nodeType==8&&c.nextSibling;)c=c.nextSibling;i[i.indexOf(c)]=null,e.__e=c}else{for(at=i.length;at--;)ta(i[at]);Tn(e)}else e.__e=n.__e,e.__k=n.__k,M.then||Tn(e);R.__e(M,e,n)}else i==null&&e.__v==n.__v?(e.__k=n.__k,e.__e=n.__e):c=e.__e=xi(n.__e,e,n,a,s,i,r,u,d);return(m=R.diffed)&&m(e),128&e.__u?void 0:c}function Tn(t){t&&t.__c&&(t.__c.__e=!0),t&&t.__k&&t.__k.forEach(Tn)}function as(t,e,n){for(var a=0;a<n.length;a++)na(n[a],n[++a],n[++a]);R.__c&&R.__c(e,t),t.some(function(s){try{t=s.__h,s.__h=[],t.some(function(i){i.call(s)})}catch(i){R.__e(i,s.__v)}})}function ss(t){return typeof t!="object"||t==null||t.__b&&t.__b>0?t:We(t)?t.map(ss):st({},t)}function xi(t,e,n,a,s,i,r,c,u){var d,m,l,p,v,g,x,C=n.props||ne,N=e.props,A=e.type;if(A=="svg"?s="http://www.w3.org/2000/svg":A=="math"?s="http://www.w3.org/1998/Math/MathML":s||(s="http://www.w3.org/1999/xhtml"),i!=null){for(d=0;d<i.length;d++)if((v=i[d])&&"setAttribute"in v==!!A&&(A?v.localName==A:v.nodeType==3)){t=v,i[d]=null;break}}if(t==null){if(A==null)return document.createTextNode(N);t=document.createElementNS(s,A,N.is&&N),c&&(R.__m&&R.__m(e,i),c=!1),i=null}if(A==null)C===N||c&&t.data==N||(t.data=N);else{if(i=i&&qe.call(t.childNodes),!c&&i!=null)for(C={},d=0;d<t.attributes.length;d++)C[(v=t.attributes[d]).name]=v.value;for(d in C)if(v=C[d],d!="children"){if(d=="dangerouslySetInnerHTML")l=v;else if(!(d in N)){if(d=="value"&&"defaultValue"in N||d=="checked"&&"defaultChecked"in N)continue;me(t,d,null,v,s)}}for(d in N)v=N[d],d=="children"?p=v:d=="dangerouslySetInnerHTML"?m=v:d=="value"?g=v:d=="checked"?x=v:c&&typeof v!="function"||C[d]===v||me(t,d,v,C[d],s);if(m)c||l&&(m.__html==l.__html||m.__html==t.innerHTML)||(t.innerHTML=m.__html),e.__k=[];else if(l&&(t.innerHTML=""),es(e.type=="template"?t.content:t,We(p)?p:[p],e,n,a,A=="foreignObject"?"http://www.w3.org/1999/xhtml":s,i,r,i?i[0]:n.__k&&Tt(n,0),c,u),i!=null)for(d=i.length;d--;)ta(i[d]);c||(d="value",A=="progress"&&g==null?t.removeAttribute("value"):g!=null&&(g!==t[d]||A=="progress"&&!g||A=="option"&&g!=C[d])&&me(t,d,g,C[d],s),d="checked",x!=null&&x!=t[d]&&me(t,d,x,C[d],s))}return t}function na(t,e,n){try{if(typeof t=="function"){var a=typeof t.__u=="function";a&&t.__u(),a&&e==null||(t.__u=t(e))}else t.current=e}catch(s){R.__e(s,n)}}function is(t,e,n){var a,s;if(R.unmount&&R.unmount(t),(a=t.ref)&&(a.current&&a.current!=t.__e||na(a,null,e)),(a=t.__c)!=null){if(a.componentWillUnmount)try{a.componentWillUnmount()}catch(i){R.__e(i,e)}a.base=a.__P=null}if(a=t.__k)for(s=0;s<a.length;s++)a[s]&&is(a[s],e,n||typeof t.type!="function");n||ta(t.__e),t.__c=t.__=t.__e=void 0}function ki(t,e,n){return this.constructor(t,n)}function wi(t,e,n){var a,s,i,r;e==document&&(e=document.documentElement),R.__&&R.__(t,e),s=(a=!1)?null:e.__k,i=[],r=[],ea(e,t=e.__k=Za(le,null,[t]),s||ne,ne,e.namespaceURI,s?null:e.firstChild?qe.call(e.childNodes):null,i,s?s.__e:e.firstChild,a,r),as(i,t,r)}qe=Xa.slice,R={__e:function(t,e,n,a){for(var s,i,r;e=e.__;)if((s=e.__c)&&!s.__)try{if((i=s.constructor)&&i.getDerivedStateFromError!=null&&(s.setState(i.getDerivedStateFromError(t)),r=s.__d),s.componentDidCatch!=null&&(s.componentDidCatch(t,a||{}),r=s.__d),r)return s.__E=s}catch(c){t=c}throw t}},Ja=0,Ga=function(t){return t!=null&&t.constructor===void 0},Ft.prototype.setState=function(t,e){var n;n=this.__s!=null&&this.__s!=this.state?this.__s:this.__s=st({},this.state),typeof t=="function"&&(t=t(st({},n),this.props)),t&&st(n,t),t!=null&&this.__v&&(e&&this._sb.push(e),ga(this))},Ft.prototype.forceUpdate=function(t){this.__v&&(this.__e=!0,t&&this.__h.push(t),ga(this))},Ft.prototype.render=le,mt=[],Va=typeof Promise=="function"?Promise.prototype.then.bind(Promise.resolve()):setTimeout,Ya=function(t,e){return t.__v.__b-e.__v.__b},Te.__r=0,Qa=/(PointerCapture)$|Capture$/i,Zn=0,An=ha(!1),Nn=ha(!0);var os=function(t,e,n,a){var s;e[0]=0;for(var i=1;i<e.length;i++){var r=e[i++],c=e[i]?(e[0]|=r?1:2,n[e[i++]]):e[++i];r===3?a[0]=c:r===4?a[1]=Object.assign(a[1]||{},c):r===5?(a[1]=a[1]||{})[e[++i]]=c:r===6?a[1][e[++i]]+=c+"":r?(s=t.apply(c,os(t,c,n,["",null])),a.push(s),c[0]?e[0]|=2:(e[i-2]=0,e[i]=s)):a.push(c)}return a},ya=new Map;function Si(t){var e=ya.get(this);return e||(e=new Map,ya.set(this,e)),(e=os(this,e.get(t)||(e.set(t,e=(function(n){for(var a,s,i=1,r="",c="",u=[0],d=function(p){i===1&&(p||(r=r.replace(/^\s*\n\s*|\s*\n\s*$/g,"")))?u.push(0,p,r):i===3&&(p||r)?(u.push(3,p,r),i=2):i===2&&r==="..."&&p?u.push(4,p,0):i===2&&r&&!p?u.push(5,0,!0,r):i>=5&&((r||!p&&i===5)&&(u.push(i,0,r,s),i=6),p&&(u.push(i,p,0,s),i=6)),r=""},m=0;m<n.length;m++){m&&(i===1&&d(),d(m));for(var l=0;l<n[m].length;l++)a=n[m][l],i===1?a==="<"?(d(),u=[u],i=3):r+=a:i===4?r==="--"&&a===">"?(i=1,r=""):r=a+r[0]:c?a===c?c="":r+=a:a==='"'||a==="'"?c=a:a===">"?(d(),i=1):i&&(a==="="?(i=5,s=r,r=""):a==="/"&&(i<5||n[m][l+1]===">")?(d(),i===3&&(u=u[0]),i=u,(u=u[0]).push(2,0,i),i=0):a===" "||a==="	"||a===`
`||a==="\r"?(d(),i=2):r+=a),i===3&&r==="!--"&&(i=4,u=u[0])}return d(),u})(t)),e),arguments,[])).length>1?e:e[0]}var o=Si.bind(Za),ae,I,Ze,ba,Ln=0,rs=[],P=R,xa=P.__b,ka=P.__r,wa=P.diffed,Sa=P.__c,Ca=P.unmount,Aa=P.__;function aa(t,e){P.__h&&P.__h(I,t,Ln||e),Ln=0;var n=I.__H||(I.__H={__:[],__h:[]});return t>=n.__.length&&n.__.push({}),n.__[t]}function fe(t){return Ln=1,Ci(us,t)}function Ci(t,e,n){var a=aa(ae++,2);if(a.t=t,!a.__c&&(a.__=[us(void 0,e),function(c){var u=a.__N?a.__N[0]:a.__[0],d=a.t(u,c);u!==d&&(a.__N=[d,a.__[1]],a.__c.setState({}))}],a.__c=I,!I.__f)){var s=function(c,u,d){if(!a.__c.__H)return!0;var m=a.__c.__H.__.filter(function(p){return!!p.__c});if(m.every(function(p){return!p.__N}))return!i||i.call(this,c,u,d);var l=a.__c.props!==c;return m.forEach(function(p){if(p.__N){var v=p.__[0];p.__=p.__N,p.__N=void 0,v!==p.__[0]&&(l=!0)}}),i&&i.call(this,c,u,d)||l};I.__f=!0;var i=I.shouldComponentUpdate,r=I.componentWillUpdate;I.componentWillUpdate=function(c,u,d){if(this.__e){var m=i;i=void 0,s(c,u,d),i=m}r&&r.call(this,c,u,d)},I.shouldComponentUpdate=s}return a.__N||a.__}function _t(t,e){var n=aa(ae++,3);!P.__s&&cs(n.__H,e)&&(n.__=t,n.u=e,I.__H.__h.push(n))}function ls(t,e){var n=aa(ae++,7);return cs(n.__H,e)&&(n.__=t(),n.__H=e,n.__h=t),n.__}function Ai(){for(var t;t=rs.shift();)if(t.__P&&t.__H)try{t.__H.__h.forEach(Se),t.__H.__h.forEach(Rn),t.__H.__h=[]}catch(e){t.__H.__h=[],P.__e(e,t.__v)}}P.__b=function(t){I=null,xa&&xa(t)},P.__=function(t,e){t&&e.__k&&e.__k.__m&&(t.__m=e.__k.__m),Aa&&Aa(t,e)},P.__r=function(t){ka&&ka(t),ae=0;var e=(I=t.__c).__H;e&&(Ze===I?(e.__h=[],I.__h=[],e.__.forEach(function(n){n.__N&&(n.__=n.__N),n.u=n.__N=void 0})):(e.__h.forEach(Se),e.__h.forEach(Rn),e.__h=[],ae=0)),Ze=I},P.diffed=function(t){wa&&wa(t);var e=t.__c;e&&e.__H&&(e.__H.__h.length&&(rs.push(e)!==1&&ba===P.requestAnimationFrame||((ba=P.requestAnimationFrame)||Ni)(Ai)),e.__H.__.forEach(function(n){n.u&&(n.__H=n.u),n.u=void 0})),Ze=I=null},P.__c=function(t,e){e.some(function(n){try{n.__h.forEach(Se),n.__h=n.__h.filter(function(a){return!a.__||Rn(a)})}catch(a){e.some(function(s){s.__h&&(s.__h=[])}),e=[],P.__e(a,n.__v)}}),Sa&&Sa(t,e)},P.unmount=function(t){Ca&&Ca(t);var e,n=t.__c;n&&n.__H&&(n.__H.__.forEach(function(a){try{Se(a)}catch(s){e=s}}),n.__H=void 0,e&&P.__e(e,n.__v))};var Na=typeof requestAnimationFrame=="function";function Ni(t){var e,n=function(){clearTimeout(a),Na&&cancelAnimationFrame(e),setTimeout(t)},a=setTimeout(n,35);Na&&(e=requestAnimationFrame(n))}function Se(t){var e=I,n=t.__c;typeof n=="function"&&(t.__c=void 0,n()),I=e}function Rn(t){var e=I;t.__c=t.__(),I=e}function cs(t,e){return!t||t.length!==e.length||e.some(function(n,a){return n!==t[a]})}function us(t,e){return typeof e=="function"?e(t):e}var Ti=Symbol.for("preact-signals");function Je(){if(ct>1)ct--;else{for(var t,e=!1;zt!==void 0;){var n=zt;for(zt=void 0,Dn++;n!==void 0;){var a=n.o;if(n.o=void 0,n.f&=-3,!(8&n.f)&&vs(n))try{n.c()}catch(s){e||(t=s,e=!0)}n=a}}if(Dn=0,ct--,e)throw t}}function Li(t){if(ct>0)return t();ct++;try{return t()}finally{Je()}}var T=void 0;function ds(t){var e=T;T=void 0;try{return t()}finally{T=e}}var zt=void 0,ct=0,Dn=0,Le=0;function ps(t){if(T!==void 0){var e=t.n;if(e===void 0||e.t!==T)return e={i:0,S:t,p:T.s,n:void 0,t:T,e:void 0,x:void 0,r:e},T.s!==void 0&&(T.s.n=e),T.s=e,t.n=e,32&T.f&&t.S(e),e;if(e.i===-1)return e.i=0,e.n!==void 0&&(e.n.p=e.p,e.p!==void 0&&(e.p.n=e.n),e.p=T.s,e.n=void 0,T.s.n=e,T.s=e),e}}function j(t,e){this.v=t,this.i=0,this.n=void 0,this.t=void 0,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}j.prototype.brand=Ti;j.prototype.h=function(){return!0};j.prototype.S=function(t){var e=this,n=this.t;n!==t&&t.e===void 0&&(t.x=n,this.t=t,n!==void 0?n.e=t:ds(function(){var a;(a=e.W)==null||a.call(e)}))};j.prototype.U=function(t){var e=this;if(this.t!==void 0){var n=t.e,a=t.x;n!==void 0&&(n.x=a,t.e=void 0),a!==void 0&&(a.e=n,t.x=void 0),t===this.t&&(this.t=a,a===void 0&&ds(function(){var s;(s=e.Z)==null||s.call(e)}))}};j.prototype.subscribe=function(t){var e=this;return ce(function(){var n=e.value,a=T;T=void 0;try{t(n)}finally{T=a}},{name:"sub"})};j.prototype.valueOf=function(){return this.value};j.prototype.toString=function(){return this.value+""};j.prototype.toJSON=function(){return this.value};j.prototype.peek=function(){var t=T;T=void 0;try{return this.value}finally{T=t}};Object.defineProperty(j.prototype,"value",{get:function(){var t=ps(this);return t!==void 0&&(t.i=this.i),this.v},set:function(t){if(t!==this.v){if(Dn>100)throw new Error("Cycle detected");this.v=t,this.i++,Le++,ct++;try{for(var e=this.t;e!==void 0;e=e.x)e.t.N()}finally{Je()}}}});function _(t,e){return new j(t,e)}function vs(t){for(var e=t.s;e!==void 0;e=e.n)if(e.S.i!==e.i||!e.S.h()||e.S.i!==e.i)return!0;return!1}function ms(t){for(var e=t.s;e!==void 0;e=e.n){var n=e.S.n;if(n!==void 0&&(e.r=n),e.S.n=e,e.i=-1,e.n===void 0){t.s=e;break}}}function fs(t){for(var e=t.s,n=void 0;e!==void 0;){var a=e.p;e.i===-1?(e.S.U(e),a!==void 0&&(a.n=e.n),e.n!==void 0&&(e.n.p=a)):n=e,e.S.n=e.r,e.r!==void 0&&(e.r=void 0),e=a}t.s=n}function gt(t,e){j.call(this,void 0),this.x=t,this.s=void 0,this.g=Le-1,this.f=4,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}gt.prototype=new j;gt.prototype.h=function(){if(this.f&=-3,1&this.f)return!1;if((36&this.f)==32||(this.f&=-5,this.g===Le))return!0;if(this.g=Le,this.f|=1,this.i>0&&!vs(this))return this.f&=-2,!0;var t=T;try{ms(this),T=this;var e=this.x();(16&this.f||this.v!==e||this.i===0)&&(this.v=e,this.f&=-17,this.i++)}catch(n){this.v=n,this.f|=16,this.i++}return T=t,fs(this),this.f&=-2,!0};gt.prototype.S=function(t){if(this.t===void 0){this.f|=36;for(var e=this.s;e!==void 0;e=e.n)e.S.S(e)}j.prototype.S.call(this,t)};gt.prototype.U=function(t){if(this.t!==void 0&&(j.prototype.U.call(this,t),this.t===void 0)){this.f&=-33;for(var e=this.s;e!==void 0;e=e.n)e.S.U(e)}};gt.prototype.N=function(){if(!(2&this.f)){this.f|=6;for(var t=this.t;t!==void 0;t=t.x)t.t.N()}};Object.defineProperty(gt.prototype,"value",{get:function(){if(1&this.f)throw new Error("Cycle detected");var t=ps(this);if(this.h(),t!==void 0&&(t.i=this.i),16&this.f)throw this.v;return this.v}});function X(t,e){return new gt(t,e)}function _s(t){var e=t.u;if(t.u=void 0,typeof e=="function"){ct++;var n=T;T=void 0;try{e()}catch(a){throw t.f&=-2,t.f|=8,sa(t),a}finally{T=n,Je()}}}function sa(t){for(var e=t.s;e!==void 0;e=e.n)e.S.U(e);t.x=void 0,t.s=void 0,_s(t)}function Ri(t){if(T!==this)throw new Error("Out-of-order effect");fs(this),T=t,this.f&=-2,8&this.f&&sa(this),Je()}function Dt(t,e){this.x=t,this.u=void 0,this.s=void 0,this.o=void 0,this.f=32,this.name=e==null?void 0:e.name}Dt.prototype.c=function(){var t=this.S();try{if(8&this.f||this.x===void 0)return;var e=this.x();typeof e=="function"&&(this.u=e)}finally{t()}};Dt.prototype.S=function(){if(1&this.f)throw new Error("Cycle detected");this.f|=1,this.f&=-9,_s(this),ms(this),ct++;var t=T;return T=this,Ri.bind(this,t)};Dt.prototype.N=function(){2&this.f||(this.f|=2,this.o=zt,zt=this)};Dt.prototype.d=function(){this.f|=8,1&this.f||sa(this)};Dt.prototype.dispose=function(){this.d()};function ce(t,e){var n=new Dt(t,e);try{n.c()}catch(s){throw n.d(),s}var a=n.d.bind(n);return a[Symbol.dispose]=a,a}var gs,_e,Di=typeof window<"u"&&!!window.__PREACT_SIGNALS_DEVTOOLS__,$s=[];ce(function(){gs=this.N})();function Et(t,e){R[t]=e.bind(null,R[t]||function(){})}function Re(t){if(_e){var e=_e;_e=void 0,e()}_e=t&&t.S()}function hs(t){var e=this,n=t.data,a=Ii(n);a.value=n;var s=ls(function(){for(var c=e,u=e.__v;u=u.__;)if(u.__c){u.__c.__$f|=4;break}var d=X(function(){var v=a.value.value;return v===0?0:v===!0?"":v||""}),m=X(function(){return!Array.isArray(d.value)&&!Ga(d.value)}),l=ce(function(){if(this.N=ys,m.value){var v=d.value;c.__v&&c.__v.__e&&c.__v.__e.nodeType===3&&(c.__v.__e.data=v)}}),p=e.__$u.d;return e.__$u.d=function(){l(),p.call(this)},[m,d]},[]),i=s[0],r=s[1];return i.value?r.peek():r.value}hs.displayName="ReactiveTextNode";Object.defineProperties(j.prototype,{constructor:{configurable:!0,value:void 0},type:{configurable:!0,value:hs},props:{configurable:!0,get:function(){return{data:this}}},__b:{configurable:!0,value:1}});Et("__b",function(t,e){if(typeof e.type=="string"){var n,a=e.props;for(var s in a)if(s!=="children"){var i=a[s];i instanceof j&&(n||(e.__np=n={}),n[s]=i,a[s]=i.peek())}}t(e)});Et("__r",function(t,e){if(t(e),e.type!==le){Re();var n,a=e.__c;a&&(a.__$f&=-2,(n=a.__$u)===void 0&&(a.__$u=n=(function(s,i){var r;return ce(function(){r=this},{name:i}),r.c=s,r})(function(){var s;Di&&((s=n.y)==null||s.call(n)),a.__$f|=1,a.setState({})},typeof e.type=="function"?e.type.displayName||e.type.name:""))),Re(n)}});Et("__e",function(t,e,n,a){Re(),t(e,n,a)});Et("diffed",function(t,e){Re();var n;if(typeof e.type=="string"&&(n=e.__e)){var a=e.__np,s=e.props;if(a){var i=n.U;if(i)for(var r in i){var c=i[r];c!==void 0&&!(r in a)&&(c.d(),i[r]=void 0)}else i={},n.U=i;for(var u in a){var d=i[u],m=a[u];d===void 0?(d=Ei(n,u,m),i[u]=d):d.o(m,s)}for(var l in a)s[l]=a[l]}}t(e)});function Ei(t,e,n,a){var s=e in t&&t.ownerSVGElement===void 0,i=_(n),r=n.peek();return{o:function(c,u){i.value=c,r=c.peek()},d:ce(function(){this.N=ys;var c=i.value.value;r!==c?(r=void 0,s?t[e]=c:c!=null&&(c!==!1||e[4]==="-")?t.setAttribute(e,c):t.removeAttribute(e)):r=void 0})}}Et("unmount",function(t,e){if(typeof e.type=="string"){var n=e.__e;if(n){var a=n.U;if(a){n.U=void 0;for(var s in a){var i=a[s];i&&i.d()}}}e.__np=void 0}else{var r=e.__c;if(r){var c=r.__$u;c&&(r.__$u=void 0,c.d())}}t(e)});Et("__h",function(t,e,n,a){(a<3||a===9)&&(e.__$f|=2),t(e,n,a)});Ft.prototype.shouldComponentUpdate=function(t,e){if(this.__R)return!0;var n=this.__$u,a=n&&n.s!==void 0;for(var s in e)return!0;if(this.__f||typeof this.u=="boolean"&&this.u===!0){var i=2&this.__$f;if(!(a||i||4&this.__$f)||1&this.__$f)return!0}else if(!(a||4&this.__$f)||3&this.__$f)return!0;for(var r in t)if(r!=="__source"&&t[r]!==this.props[r])return!0;for(var c in this.props)if(!(c in t))return!0;return!1};function Ii(t,e){return ls(function(){return _(t,e)},[])}var Pi=function(t){queueMicrotask(function(){queueMicrotask(t)})};function Mi(){Li(function(){for(var t;t=$s.shift();)gs.call(t)})}function ys(){$s.push(this)===1&&(R.requestAnimationFrame||Pi)(Mi)}const ji=["overview","execution","board","activity","agents","tasks","goals","journal","trpg","council","mdal"],bs={tab:"overview",params:{},postId:null};function Ta(t){return!!t&&ji.includes(t)}function En(t){try{return decodeURIComponent(t)}catch{return t}}function In(t){const e={};return t&&new URLSearchParams(t).forEach((a,s)=>{e[s]=a}),e}function Oi(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function xs(t,e){const n=t[0],a=e.tab,s=Ta(n)?n:Ta(a)?a:"overview";let i=null;return s==="board"&&(t[0]==="board"&&t[1]==="post"&&t[2]?i=En(t[2]):t[0]==="post"&&t[1]&&(i=En(t[1]))),{tab:s,params:e,postId:i}}function De(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return bs;const n=En(e);let a=n,s;if(n.startsWith("?"))a="",s=n.slice(1);else{const c=n.indexOf("?");c>=0&&(a=n.slice(0,c),s=n.slice(c+1))}!s&&a.includes("=")&&!a.includes("/")&&(s=a,a="");const i=In(s),r=Oi(a);return xs(r,i)}function Fi(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const a=n.slice(1);if(a.length===0)return{...bs,params:In(e.replace(/^\?/,""))};if(a[0]==="assets"||a[0]==="credits"||a[0]==="lodge")return null;const s=In(e.replace(/^\?/,""));return xs(a,s)}function ks(t){const e=t.postId?`board/post/${encodeURIComponent(t.postId)}`:t.tab,n=Object.entries(t.params).filter(([s])=>s!=="tab");if(n.length===0)return`#${e}`;const a=new URLSearchParams(n);return`#${e}?${a.toString()}`}const nt=_(De(window.location.hash));window.addEventListener("hashchange",()=>{nt.value=De(window.location.hash)});function Ge(t,e){const n={tab:t,params:{},postId:null};window.location.hash=ks(n)}function zi(t){window.location.hash=`#board/post/${encodeURIComponent(t)}`}function Ui(){if(window.location.hash&&window.location.hash!=="#"){nt.value=De(window.location.hash);return}const t=Fi(window.location.pathname,window.location.search);if(t){nt.value=t;const e=ks(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#overview",nt.value=De(window.location.hash)}const ws=[{id:"overview",label:"Overview",icon:"🏠"},{id:"council",label:"Council",icon:"🏛️"},{id:"board",label:"Board",icon:"💬"},{id:"activity",label:"Activity",icon:"📊"},{id:"agents",label:"Agents",icon:"🤖"},{id:"tasks",label:"Tasks",icon:"📋"},{id:"goals",label:"Goals",icon:"🎯"},{id:"execution",label:"Execution",icon:"🛠️"},{id:"journal",label:"Journal",icon:"📓"},{id:"trpg",label:"TRPG",icon:"⚔️"},{id:"mdal",label:"MDAL",icon:"📈"}];function Hi(){const t=nt.value.tab;return o`
    <div class="main-tab-bar">
      ${ws.map(e=>o`
        <button
          class="main-tab-btn ${t===e.id?"active":""}"
          onClick=${()=>Ge(e.id)}
        >
          ${e.icon} ${e.label}
        </button>
      `)}
    </div>
  `}const La="masc_dashboard_sse_session_id",Bi=1e3,Ki=15e3,Lt=_(!1),ia=_(0),Ss=_(null),Ee=_([]);function qi(){let t=sessionStorage.getItem(La);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(La,t)),t}const Wi=200;function J(t,e){const n={agent:t,text:e,timestamp:Date.now()};Ee.value=[n,...Ee.value].slice(0,Wi)}let et=null,At=null,Pn=0;function Cs(){At&&(clearTimeout(At),At=null)}function Ji(){if(At)return;Pn++;const t=Math.min(Pn,5),e=Math.min(Ki,Bi*Math.pow(2,t));At=setTimeout(()=>{At=null,As()},e)}function As(){Cs(),et&&(et.close(),et=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),a=t.get("token");n&&e.set("agent",n),a&&e.set("token",a),e.set("session_id",qi());const s=e.toString()?`/sse?${e.toString()}`:"/sse",i=new EventSource(s);et=i,i.onopen=()=>{et===i&&(Pn=0,Lt.value=!0)},i.onerror=()=>{et===i&&(Lt.value=!1,i.close(),et=null,Ji())},i.onmessage=r=>{try{const c=JSON.parse(r.data);ia.value++,Ss.value=c,Gi(c)}catch{}}}function Gi(t){const e=t.type,n=t.agent??t.from??t.from_agent??"";switch(e){case"agent_joined":J(n,"Joined");break;case"agent_left":J(n,"Left");break;case"broadcast":J(n,`${(t.message??t.content??"").slice(0,80)}`);break;case"task_update":J(n,`Task: ${t.task_id??""} -> ${t.status??""}`);break;case"board_post":J(n,"New post");break;case"board_comment":J(n,"New comment");break;case"keeper_heartbeat":J(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`);break;case"keeper_handoff":J(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`);break;case"keeper_compaction":J(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`);break;case"keeper_guardrail":J(t.name??n,`Guardrail: ${t.reason??"stopped"}`);break;default:J(n,e)}}function Vi(){Cs(),et&&(et.close(),et=null),Lt.value=!1}function Ns(){return new URLSearchParams(window.location.search)}function Ts(){const t=Ns(),e={},n=t.get("token"),a=t.get("agent")??t.get("agent_name");return n&&(e.Authorization=`Bearer ${n}`),a&&(e["X-MASC-Agent"]=a),e}function Ls(){return{...Ts(),"Content-Type":"application/json"}}const Yi=15e3,Rs=3e4,Qi=6e4,Ra=new Set([408,425,429,500,502,503,504]);class ue extends Error{constructor(n){const a=n.method.toUpperCase(),s=n.timeout===!0,i=s?`${a} ${n.path}: timeout after ${n.timeoutMs??0}ms`:`${a} ${n.path}: ${n.status??"unknown"} ${n.statusText??""}`.trim();super(i);bt(this,"method");bt(this,"path");bt(this,"status");bt(this,"statusText");bt(this,"timeout");this.name="ApiRequestError",this.method=a,this.path=n.path,this.status=n.status,this.statusText=n.statusText,this.timeout=s}}async function oa(t,e,n){const a=new AbortController,s=setTimeout(()=>a.abort(),n);try{return await fetch(t,{...e,signal:a.signal})}catch(i){if(i instanceof Error&&i.name==="AbortError"){const r=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new ue({method:r,path:t,timeout:!0,timeoutMs:n})}throw i}finally{clearTimeout(s)}}function Xi(){var e,n;const t=Ns();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function dt(t){const e=await oa(t,{headers:Ts()},Yi);if(!e.ok)throw new ue({method:"GET",path:t,status:e.status,statusText:e.statusText});return e.json()}function Zi(t){return new Promise(e=>setTimeout(e,t))}function to(t){const e=t.match(/\b(\d{3})\b/);if(!e)return null;const n=e[1];if(!n)return null;const a=Number.parseInt(n,10);return Number.isFinite(a)?a:null}function eo(t){if(t instanceof ue)return t.timeout||typeof t.status=="number"&&Ra.has(t.status);if(!(t instanceof Error))return!1;if(/timeout after \d+ms/i.test(t.message))return!0;const e=to(t.message);return e!==null&&Ra.has(e)}async function de(t,e,n=2){let a=0;for(;;)try{return await e()}catch(s){if(!eo(s)||a>=n)throw s;const i=250*(a+1);console.warn(`[dashboard/api] ${t} failed (attempt ${a+1}), retrying in ${i}ms`,s),await Zi(i),a+=1}}async function $t(t,e,n){const a=await oa(t,{method:"POST",headers:{...Ls(),...n??{}},body:JSON.stringify(e)},Rs);if(!a.ok)throw new ue({method:"POST",path:t,status:a.status,statusText:a.statusText});return a.json()}async function no(t,e,n,a=Rs){const s=await oa(t,{method:"POST",headers:{...Ls(),...n??{}},body:JSON.stringify(e)},a);if(!s.ok)throw new ue({method:"POST",path:t,status:s.status,statusText:s.statusText});return s.text()}function ao(t){const e=t.split(`
`).find(a=>a.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function so(t){var e,n,a,s,i,r,c;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const u=((s=(a=t.result.content)==null?void 0:a[0])==null?void 0:s.text)??"MCP tool call failed";throw new Error(u)}return((c=(r=(i=t.result)==null?void 0:i.content)==null?void 0:r[0])==null?void 0:c.text)??""}async function U(t,e){const n=await no("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},Qi),a=ao(n);return so(a)}function io(t="compact"){return dt(`/api/v1/dashboard?mode=${t}`)}function Rt(t){if(typeof t=="string"&&t.trim())return t;if(typeof t!="number"||Number.isNaN(t))return new Date().toISOString();const e=t<1e12?t*1e3:t;return new Date(e).toISOString()}function oo(t){var s;const e=t.trim(),a=((s=(e.startsWith("[flair:")?e.replace(/^\[flair:[^\]]+\]\s*/i,""):e).split(`
`)[0])==null?void 0:s.trim())||"Untitled post";return a.length<=96?a:`${a.slice(0,93)}...`}function Ds(t){if(!w(t))return null;const e=f(t.id,"").trim(),n=f(t.author,"").trim(),a=f(t.content,"").trim();if(!e||!n)return null;const s=k(t.score,0),i=k(t.votes_up,0),r=k(t.votes_down,0),c=k(t.votes,s||i-r),u=k(t.comment_count,k(t.reply_count,0)),d=(()=>{const g=t.flair;if(typeof g=="string"&&g.trim())return g.trim();if(w(g)){const C=f(g.name,"").trim();if(C)return C}return f(t.flair_name,"").trim()||void 0})(),m=f(t.created_at_iso,"").trim()||Rt(t.created_at),l=f(t.updated_at_iso,"").trim()||(t.updated_at!==void 0?Rt(t.updated_at):m),v=f(t.title,"").trim()||oo(a);return{id:e,author:n,title:v,content:a,tags:[],votes:c,vote_balance:s,comment_count:u,created_at:m,updated_at:l,flair:d,hearth_count:k(t.hearth_count,0)}}function ro(t){if(!w(t))return null;const e=f(t.id,"").trim(),n=f(t.post_id,"").trim(),a=f(t.author,"").trim();return!e||!a?null:{id:e,post_id:n,author:a,content:f(t.content,""),created_at:Rt(t.created_at)}}async function lo(t){return de("fetchBoard",async()=>{const e=new URLSearchParams;t&&e.set("sort_by",t),e.set("limit","100");const n=e.toString(),a=await dt(`/api/v1/board${n?`?${n}`:""}`);return{posts:Array.isArray(a.posts)?a.posts.map(Ds).filter(i=>i!==null):[]}})}async function co(t){return de("fetchBoardPost",async()=>{const e=await dt(`/api/v1/board/${t}?format=flat`),n=w(e.post)?e.post:e,a=Ds(n)??{id:t,author:"unknown",title:"Post",content:"",tags:[],votes:0,comment_count:0,created_at:new Date().toISOString(),updated_at:new Date().toISOString()},i=(Array.isArray(e.comments)?e.comments:[]).map(ro).filter(r=>r!==null);return{...a,comments:i}})}function Es(t,e){return $t("/api/v1/tools/masc_board_vote",{post_id:t,direction:e,vote:e,voter:Xi()})}function uo(t,e,n){return $t("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function po(t){const e=f(t,"").trim().toLowerCase();if(e==="win"||e==="won"||e==="victory")return"victory";if(e==="lose"||e==="lost"||e==="defeat")return"defeat";if(e==="draw"||e==="stalemate"||e==="tie")return"draw"}function z(...t){for(const e of t){const n=f(e,"");if(n.trim())return n.trim()}return""}function Da(t){const e=po(z(t.outcome,t.result,t.result_code));if(!e)return;const n=z(t.reason,t.reason_code,t.description,t.detail),a=z(t.summary,t.summary_ko,t.summary_en,t.note),s=z(t.details,t.details_text,t.text,t.note),i=z(t.winner,t.winner_name,t.actor_winner,t.winner_actor),r=z(t.winner_actor_id,t.winner_actor,t.actor_winner_id),c=z(t.raw_reason,t.raw_reason_code,t.error_message),u=(()=>{const l=t.evidence??t.evidence_ids??t.supporting_events??t.event_ids??[];return typeof l=="string"?[l]:Array.isArray(l)?l.map(p=>{if(typeof p=="string")return p.trim();if(w(p)){const v=f(p.summary,"").trim();if(v)return v;const g=f(p.text,"").trim();if(g)return g;const x=f(p.type,"").trim();return x||f(p.event_id,"").trim()}return""}).filter(p=>p.length>0):[]})(),d=(()=>{const l=k(t.turn,Number.NaN);if(Number.isFinite(l))return l;const p=k(t.turn_number,Number.NaN);if(Number.isFinite(p))return p;const v=k(t.current_turn,Number.NaN);if(Number.isFinite(v))return v;const g=k(t.round,Number.NaN);return Number.isFinite(g)?g:void 0})(),m=z(t.phase,t.phase_name,t.current_phase,t.phase_id);return{result:e,reason:n||void 0,summary:a||void 0,details:s||void 0,winner:i||void 0,winner_actor_id:r||void 0,evidence:u.length>0?u:void 0,raw_reason:c||void 0,turn:d,phase:m||void 0}}function vo(t,e){const n=w(t.state)?t.state:{};if(f(n.status,"active").toLowerCase()!=="ended")return;const s=[...e].reverse().find(r=>w(r)?f(r.type,"")==="session.outcome":!1),i=w(n.session_outcome)?n.session_outcome:{};if(w(i)&&Object.keys(i).length>0){const r=Da(i);if(r)return r}if(w(s))return Da(w(s.payload)?s.payload:{})}function w(t){return typeof t=="object"&&t!==null}function f(t,e=""){return typeof t=="string"?t:e}function k(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function lt(t){if(typeof t=="number"&&Number.isFinite(t))return Math.trunc(t);if(typeof t=="string"){const e=Number.parseInt(t.trim(),10);if(Number.isFinite(e))return e}}function Mn(t,e=!1){return typeof t=="boolean"?t:e}function jt(t){return Array.isArray(t)?t.map(e=>{if(typeof e=="string")return e.trim();if(w(e)){const n=f(e.name,"").trim(),a=f(e.id,"").trim(),s=f(e.skill,"").trim();return n||a||s}return""}).filter(e=>e.length>0):[]}function mo(t){const e={};if(!w(t)&&!Array.isArray(t))return e;if(w(t))return Object.entries(t).forEach(([n,a])=>{const s=n.trim(),i=f(a,"").trim();!s||!i||(e[s]=i)}),e;for(const n of t){if(!w(n))continue;const a=z(n.to,n.target,n.actor_id,n.name,n.id),s=z(n.relationship,n.relation,n.type,n.kind);!a||!s||(e[a]=s)}return e}function fo(t,e,n){if(t==="dm"||t==="player"||t==="npc")return t;const a=e.trim().toLowerCase();return a==="dm"||a.startsWith("dm-")?"dm":a.startsWith("npc-")||a.startsWith("enemy-")||a.startsWith("mob-")?"npc":/^p\d+$/i.test(a)||a.startsWith("player-")?"player":typeof n=="string"&&n.trim()!==""?n.trim().toLowerCase().includes("dm")?"dm":"player":"npc"}function B(t,e,n,a=0){const s=t[e];if(typeof s=="number"&&Number.isFinite(s))return s;if(n){const i=t[n];if(typeof i=="number"&&Number.isFinite(i))return i}return a}const _o=new Set(["str","dex","con","int","wis","cha","strength","dexterity","constitution","intelligence","wisdom","charisma","hp","max_hp","mp","max_mp","level","xp"]);function go(t){const e=w(t.stats)?t.stats:{},n={};return Object.entries(e).forEach(([a,s])=>{const i=a.trim();i&&(_o.has(i.toLowerCase())||typeof s=="number"&&Number.isFinite(s)&&(n[i]=s))}),n}function $o(t,e){if(t!=="dice.rolled")return;const n=k(e.raw_d20,0),a=k(e.total,0),s=k(e.bonus,0),i=f(e.action,"roll"),r=k(e.dc,0);return{notation:r>0?`${i} (DC ${r})`:i,rolls:n>0?[n]:[],total:a,modifier:s}}function ho(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function yo(t){const e=t.trim().toLowerCase();return e?e.startsWith("dice.")?"dice":e.startsWith("combat.")||e.includes(".attack")||e.includes(".damage")?"combat":e.includes("actor.")?"actor":e.includes("turn.")||e==="turn.started"||e==="phase.changed"?"turn":e.includes("join.")?"join":e.includes("memory")?"memory":e.includes("world.")?"world":e.includes("narration")?"story":"meta":"meta"}function bo(t,e,n,a){const s=n||e||f(a.actor_id,"")||f(a.actor_name,"");switch(t){case"turn.action.proposed":{const i=f(a.proposed_action,f(a.reply,""));return i?`${s||"actor"}: ${i}`:"Action proposed"}case"turn.action.resolved":{const i=f(a.reply,f(a.result,""));return i?`Resolved: ${i}`:"Action resolved"}case"narration.posted":return f(a.reply,f(a.content,f(a.text,"Narration")));case"dice.rolled":{const i=f(a.action,"roll"),r=k(a.total,0),c=k(a.dc,0),u=f(a.label,""),d=s||"actor",m=c>0?` vs DC ${c}`:"",l=u?` (${u})`:"";return`${d} ${i}: ${r}${m}${l}`}case"turn.started":return`Turn ${k(a.turn,1)} started`;case"phase.changed":return`Phase: ${f(a.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${f(a.name,w(a.actor)?f(a.actor.name,s||"unknown"):s||"unknown")}`;case"actor.claimed":return`${f(a.keeper_name,f(a.keeper,"keeper"))} claimed ${s||"actor"}`;case"actor.released":return`${f(a.keeper_name,f(a.keeper,"keeper"))} released ${s||"actor"}`;case"join.window.opened":return`Join window opened (turn ${k(a.turn,0)})`;case"join.window.closed":return`Join window closed (turn ${k(a.turn,0)})`;case"mid.join.requested":return`Mid-join requested: ${s||f(a.actor_id,"actor")}`;case"mid.join.granted":return`Mid-join granted: ${s||f(a.actor_id,"actor")}`;case"mid.join.rejected":return`Mid-join rejected: ${f(a.reason_code,"unknown")}`;case"memory.signal":{const i=w(a.entity_refs)?a.entity_refs:{},r=f(i.requested_tier,""),c=f(i.effective_tier,""),u=Mn(i.guardrail_applied,!1),d=f(a.summary_en,f(a.summary_ko,"Memory signal"));if(!r&&!c)return d;const m=r&&c?`${r}->${c}`:c||r;return`${d} [${m}${u?" (guardrail)":""}]`}case"world.event":{if(f(a.event_type,"")==="canon.check"){const r=f(a.status,"unknown"),c=f(a.contract_id,"n/a");return`Canon ${r}: ${c}`}return f(a.description,f(a.summary,"World event"))}case"combat.attack":return f(a.summary,f(a.result,"Attack resolved"));case"combat.defense":return f(a.summary,f(a.result,"Defense resolved"));case"session.outcome":return f(a.summary,f(a.outcome,"Session ended"));default:{const i=ho(a);return i?`${t}: ${i}`:t}}}function xo(t,e){const n=w(t)?t:{},a=f(n.type,"event"),s=typeof n.actor_id=="string"&&n.actor_id.trim()?n.actor_id.trim():"",i=f(n.actor_name,"").trim()||e[s]||f(w(n.payload)?n.payload.actor_name:"",""),r=w(n.payload)?n.payload:{},c=f(n.ts,f(n.timestamp,new Date().toISOString())),u=f(n.phase,f(r.phase,"")),d=f(n.category,"");return{type:a,actor:i||s||f(r.actor_name,""),actor_id:s||f(r.actor_id,""),actor_name:i,seq:n.seq,room_id:f(n.room_id,""),phase:u||void 0,category:d||yo(a),visibility:f(n.visibility,f(r.visibility,"public")),event_id:f(n.event_id,""),content:bo(a,s,i,r),dice_roll:$o(a,r),timestamp:c}}function ko(t,e,n){var W,at;const a=f(t.room_id,"")||n||"default",s=w(t.state)?t.state:{},i=w(s.party)?s.party:{},r=w(s.actor_control)?s.actor_control:{},c=w(s.join_gate)?s.join_gate:{},u=w(s.contribution_ledger)?s.contribution_ledger:{},d=Object.entries(i).map(([L,M])=>{const $=w(M)?M:{},ve=B($,"max_hp",void 0,10),va=B($,"hp",void 0,ve),ii=B($,"max_mp",void 0,0),oi=B($,"mp",void 0,0),ri=B($,"level",void 0,1),li=B($,"xp",void 0,0),ci=Mn($.alive,va>0),ma=r[L],fa=typeof ma=="string"?ma:void 0,ui=fo($.role,L,fa),di=lt($.generation),pi=z($.joined_at,$.joinedAt,$.started_at,$.startedAt),vi=z($.claimed_at,$.claimedAt,$.assigned_at,$.assignedAt,$.assigned_time),mi=z($.last_seen,$.lastSeen,$.last_seen_at,$.lastSeenAt,$.last_active,$.lastActive),fi=z($.scene,$.current_scene,$.currentScene,$.world_scene,$.scene_name,$.sceneName),_i=z($.location,$.current_location,$.currentLocation,$.position,$.zone,$.area);return{id:L,name:f($.name,L),role:ui,keeper:fa,archetype:f($.archetype,""),persona:f($.persona,""),portrait:f($.portrait,"")||void 0,background:f($.background,"")||void 0,traits:jt($.traits),skills:jt($.skills),stats_raw:go($),status:ci?"active":"dead",generation:di,joined_at:pi||void 0,claimed_at:vi||void 0,last_seen:mi||void 0,scene:fi||void 0,location:_i||void 0,inventory:jt($.inventory),notes:jt($.notes),relationships:mo($.relationships),stats:{hp:va,max_hp:ve,mp:oi,max_mp:ii,level:ri,xp:li,strength:B($,"strength","str",10),dexterity:B($,"dexterity","dex",10),constitution:B($,"constitution","con",10),intelligence:B($,"intelligence","int",10),wisdom:B($,"wisdom","wis",10),charisma:B($,"charisma","cha",10)}}}),m=d.filter(L=>L.status!=="dead"),l=vo(t,e),p={phase_open:Mn(c.phase_open,!0),min_points:k(c.min_points,3),window:f(c.window,"round_boundary_only"),last_opened_turn:typeof c.last_opened_turn=="number"?c.last_opened_turn:null,last_closed_turn:typeof c.last_closed_turn=="number"?c.last_closed_turn:null},v=Object.entries(u).map(([L,M])=>{const $=w(M)?M:{};return{actor_id:L,score:k($.score,0),last_reason:f($.last_reason,"")||null,reasons:jt($.reasons)}}),g=d.reduce((L,M)=>(L[M.id]=M.name,L),{}),x=e.map(L=>xo(L,g)),C=k(s.turn,1),N=f(s.phase,"round"),A=f(s.map,""),E=w(s.world)?s.world:{},O=A||f(E.ascii_map,f(E.map,"")),D=x.filter((L,M)=>{const $=e[M];if(!w($))return!1;const ve=w($.payload)?$.payload:{};return k(ve.turn,-1)===C}),q=(D.length>0?D:x).slice(-12),pt=f(s.status,"active");return{session:{id:a,room:a,status:pt==="ended"?"ended":pt==="paused"?"paused":"active",round:C,actors:m,created_at:((W=x[0])==null?void 0:W.timestamp)??new Date().toISOString()},current_round:{round_number:C,phase:N,events:q,timestamp:((at=x[x.length-1])==null?void 0:at.timestamp)??new Date().toISOString()},map:O||void 0,join_gate:p,contribution_ledger:v,outcome:l,party:m,story_log:x,history:[]}}async function wo(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await dt(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function So(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,a]=await Promise.all([dt(`/api/v1/trpg/state${e}`),wo(t)]);return ko(n,a,t)}function Co(t){return $t("/api/v1/trpg/rounds/run",{room_id:t})}function Ao(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function No(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),$t("/api/v1/trpg/dice/roll",e)}function To(t,e){const n=Ao();return $t("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}function Lo(t,e){var s;const n=(s=e.idempotencyKey)==null?void 0:s.trim(),a={room_id:t};return e.actor_id&&e.actor_id.trim()&&(a.actor_id=e.actor_id.trim()),e.name&&e.name.trim()&&(a.name=e.name.trim()),e.role&&(a.role=e.role),e.archetype&&e.archetype.trim()&&(a.archetype=e.archetype.trim()),e.persona&&e.persona.trim()&&(a.persona=e.persona.trim()),e.portrait&&e.portrait.trim()&&(a.portrait=e.portrait.trim()),e.background&&e.background.trim()&&(a.background=e.background.trim()),e.hp!=null&&(a.hp=e.hp),e.max_hp!=null&&(a.max_hp=e.max_hp),e.alive!=null&&(a.alive=e.alive),Array.isArray(e.traits)&&e.traits.length>0&&(a.traits=e.traits),Array.isArray(e.skills)&&e.skills.length>0&&(a.skills=e.skills),Array.isArray(e.inventory)&&e.inventory.length>0&&(a.inventory=e.inventory),e.stats&&Object.keys(e.stats).length>0&&(a.stats=e.stats),n&&(a.idempotency_key=n),$t("/api/v1/trpg/actors/spawn",a,n?{"Idempotency-Key":n}:void 0)}function Ro(t,e,n){return $t("/api/v1/trpg/actors/claim",{room_id:t,actor_id:e,keeper:n})}async function Do(t,e,n){const a=await U("trpg.join.eligibility",{room_id:t,actor_id:e,...n?{keeper_name:n}:{}});return JSON.parse(a)}async function Eo(t){const e=await U("trpg.mid_join.request",t);return JSON.parse(e)}async function Is(t,e){await U("masc_broadcast",{agent_name:t,message:e})}async function Io(t,e,n=1){await U("masc_add_task",{title:t,description:e,priority:n})}async function Po(t){return U("masc_join",{agent_name:t})}async function Ps(t){await U("masc_leave",{agent_name:t})}async function Mo(t){await U("masc_heartbeat",{agent_name:t})}async function jo(t=40){return(await U("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function Oo(t,e=20){return U("masc_task_history",{task_id:t,limit:e})}async function Fo(){return de("fetchDebates",async()=>{const t=await dt("/api/v1/council/debates?limit=100");return Array.isArray(t.debates)?t.debates.map(e=>{if(!w(e))return null;const n=f(e.id,"").trim(),a=f(e.topic,"").trim();return!n||!a?null:{id:n,topic:a,status:f(e.status,"open"),argument_count:k(e.argument_count,0),created_at:Rt(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]})}async function zo(){return de("fetchCouncilSessions",async()=>{const t=await dt("/api/v1/council/sessions?limit=100");return Array.isArray(t.sessions)?t.sessions.map(e=>{if(!w(e))return null;const n=f(e.id,"").trim(),a=f(e.topic,"").trim();return!n||!a?null:{id:n,topic:a,initiator:f(e.initiator,"system"),votes:k(e.votes,0),quorum:k(e.quorum,0),state:f(e.state,"open"),created_at:Rt(e.created_at_iso??e.created_at)}}).filter(e=>e!==null):[]})}async function Uo(t){const e=await U("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}async function Ho(t){return de("fetchDebateStatus",async()=>{const e=encodeURIComponent(t),n=await dt(`/api/v1/council/debates/${e}/summary`);if(!w(n))return null;const a=f(n.id,"").trim();return a?{id:a,topic:f(n.topic,""),status:f(n.status,"open"),support_count:k(n.support_count,0),oppose_count:k(n.oppose_count,0),neutral_count:k(n.neutral_count,0),total_arguments:k(n.total_arguments,0),created_at:Rt(n.created_at_iso??n.created_at),summary_text:f(n.summary_text,"")}:null})}function Bo(t){const e=f(t,"").trim().toLowerCase();return e.startsWith("error")?"error":e==="running"||e==="completed"||e==="stopped"?e:"running"}function Ko(t){return w(t)?{iteration:lt(t.iteration)??0,metric_before:k(t.metric_before,0),metric_after:k(t.metric_after,0),delta:k(t.delta,0),changes:f(t.changes,""),failed_attempts:f(t.failed_attempts,""),next_suggestion:f(t.next_suggestion,""),elapsed_ms:lt(t.elapsed_ms)??0,cost_usd:typeof t.cost_usd=="number"&&Number.isFinite(t.cost_usd)?t.cost_usd:null}:null}function qo(t){if(!w(t))return null;const e=f(t.loop_id,"").trim();if(!e)return null;const n=Array.isArray(t.history)?t.history.map(Ko).filter(a=>a!==null):[];return{loop_id:e,profile:f(t.profile,"custom"),status:Bo(t.status),current_iteration:lt(t.iteration)??lt(t.current_iteration)??0,max_iterations:lt(t.max_iterations)??0,baseline_metric:k(t.baseline_metric,0),current_metric:k(t.current_metric,k(t.baseline_metric,0)),target:f(t.target,""),stagnation_streak:lt(t.stagnation_streak)??0,stagnation_limit:lt(t.stagnation_limit)??0,elapsed_seconds:k(t.elapsed_seconds,0),history:n}}async function Wo(){try{const t=await U("masc_mdal_status",{}),e=JSON.parse(t);return w(e)&&f(e.error,"").trim()!==""?null:qo(e)}catch{return null}}async function Jo(){try{const t=await U("masc_goal_list",{});if(typeof t=="string"){const e=JSON.parse(t);return Array.isArray(e)?e:e.goals??[]}return Array.isArray(t)?t:t.goals??[]}catch{return[]}}const It=_([]),pe=_([]),Ms=_([]),Pt=_([]),ht=_(null),Ot=_(null),jn=_(new Map),js=_([]),On=_("hot"),Os=_(null),it=_(""),Ve=_([]),Ut=_(!1),V=_(new Map),Fn=_(!1),zn=_(!1),Un=_(!1),Fs=X(()=>It.value.filter(t=>t.status==="active"||t.status==="idle")),ra=X(()=>{const t=pe.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}});function Go(t){var s;const e=t.metrics_series;if(!e||e.length===0){const i=((s=t.status)==null?void 0:s.toLowerCase())??"";return i==="offline"||i==="inactive"?"offline":"idle"}const n=e[e.length-1];if(!n)return"idle";if(n.is_handoff)return"handoff-imminent";if(n.is_compaction)return"compacting";const a=n.context_ratio;return a>.85?"handoff-imminent":a>.7?"preparing":a>.5?"compacting":"active"}const Vo=X(()=>{const t=new Map;for(const e of Pt.value)t.set(e.name,Go(e));return t}),Yo=12e4,Qo=X(()=>{const t=Date.now(),e=new Set,n=jn.value;for(const a of Pt.value){const s=n.get(a.name);s!=null&&t-s>Yo&&e.add(a.name)}return e}),Ie={},Xo=5e3;function Hn(){delete Ie.compact,delete Ie.full}function Y(t){return typeof t=="object"&&t!==null}function h(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function S(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function Ht(t){if(!Array.isArray(t))return;const e=t.filter(n=>typeof n=="string"&&n.trim()!=="");return e.length>0?e:void 0}function zs(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="idle"||e==="inactive"||e==="offline"?e:e==="busy"||e==="in_progress"||e==="claimed"?"active":"offline"}function Zo(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function tr(t){if(!Y(t))return null;const e=h(t.name);return e?{name:e,status:zs(t.status),current_task:h(t.current_task)??null,last_seen:h(t.last_seen),emoji:h(t.emoji),koreanName:h(t.koreanName)??h(t.korean_name),model:h(t.model),traits:Ht(t.traits),interests:Ht(t.interests),activityLevel:S(t.activityLevel)??S(t.activity_level),primaryValue:h(t.primaryValue)??h(t.primary_value)}:null}function er(t){if(!Y(t))return null;const e=h(t.id),n=h(t.title);return!e||!n?null:{id:e,title:n,status:Zo(t.status),priority:S(t.priority),assignee:h(t.assignee),description:h(t.description),created_at:h(t.created_at),updated_at:h(t.updated_at)}}function nr(t){if(!Y(t))return null;const e=h(t.from)??h(t.from_agent)??"system",n=h(t.content)??"",a=h(t.timestamp)??new Date().toISOString();return{id:h(t.id),seq:S(t.seq),from:e,content:n,timestamp:a,type:h(t.type)}}function ar(t){return Array.isArray(t)?t.map(e=>{if(!Y(e))return null;const n=S(e.ts_unix);if(n==null)return null;const a=Y(e.handoff)?e.handoff:null;return{ts:n,context_ratio:S(e.context_ratio)??0,context_tokens:S(e.context_tokens)??0,context_max:S(e.context_max)??0,latency_ms:S(e.latency_ms)??0,generation:S(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:a!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:S(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:S(e.cost_usd)??0,handoff_to_model:a&&typeof a.to_model=="string"?a.to_model:null,handoff_new_generation:a?S(a.new_generation)??null:null}}).filter(e=>e!==null):[]}function sr(t){return(Array.isArray(t)?t:Y(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(n=>{if(!Y(n))return null;const a=Y(n.agent)?n.agent:null,s=Y(n.context)?n.context:null,i=Y(n.metrics_window)?n.metrics_window:void 0,r=h(n.name);if(!r)return null;const c=S(n.context_ratio)??S(s==null?void 0:s.context_ratio),u=h(n.status)??h(a==null?void 0:a.status)??"offline",d=zs(u),m=h(n.model)??h(n.active_model)??h(n.primary_model),l=Ht(n.skill_secondary),p=s?{source:h(s.source),context_ratio:S(s.context_ratio),context_tokens:S(s.context_tokens),context_max:S(s.context_max),message_count:S(s.message_count),has_checkpoint:typeof s.has_checkpoint=="boolean"?s.has_checkpoint:void 0}:void 0,v=a?{name:h(a.name),status:h(a.status),current_task:h(a.current_task)??null,last_seen:h(a.last_seen)}:void 0,g=ar(n.metrics_series);return{name:r,emoji:h(n.emoji),koreanName:h(n.koreanName)??h(n.korean_name),agent_name:h(n.agent_name),trace_id:h(n.trace_id),model:m,primary_model:h(n.primary_model),active_model:h(n.active_model),next_model_hint:h(n.next_model_hint)??null,status:d,last_heartbeat:h(n.last_heartbeat)??h(a==null?void 0:a.last_seen),generation:S(n.generation),turn_count:S(n.turn_count)??S(n.total_turns),context_ratio:c,context_tokens:S(n.context_tokens)??S(s==null?void 0:s.context_tokens),context_max:S(n.context_max)??S(s==null?void 0:s.context_max),context_source:h(n.context_source)??h(s==null?void 0:s.source),context:p,traits:Ht(n.traits),interests:Ht(n.interests),primaryValue:h(n.primaryValue)??h(n.primary_value),activityLevel:S(n.activityLevel)??S(n.activity_level),memory_recent_note:h(n.memory_recent_note)??null,conversation_tail_count:S(n.conversation_tail_count),k2k_count:S(n.k2k_count),handoff_count_total:S(n.handoff_count_total)??S(n.trace_history_count),compaction_count:S(n.compaction_count),last_compaction_saved_tokens:S(n.last_compaction_saved_tokens),skill_primary:h(n.skill_primary)??null,skill_secondary:l,skill_reason:h(n.skill_reason)??null,metrics_series:g.length>0?g:void 0,metrics_window:i,agent:v}}).filter(n=>n!==null)}async function Ye(t="full"){var a,s,i;const e=Date.now(),n=Ie[t];if(!(n&&e-n.time<Xo)){Fn.value=!0;try{const r=await io(t);Ie[t]={data:r,time:e},It.value=(Array.isArray((a=r.agents)==null?void 0:a.agents)?r.agents.agents:[]).map(tr).filter(c=>c!==null),pe.value=(Array.isArray((s=r.tasks)==null?void 0:s.tasks)?r.tasks.tasks:[]).map(er).filter(c=>c!==null),Ms.value=(Array.isArray((i=r.messages)==null?void 0:i.messages)?r.messages.messages:[]).map(nr).filter(c=>c!==null),Pt.value=sr(r.keepers),ht.value=Y(r.status)?r.status:null,Ot.value=r.perpetual??null}catch(r){console.error("Dashboard fetch error:",r)}finally{Fn.value=!1}}}async function yt(){zn.value=!0;try{const t=await lo(On.value);js.value=t.posts??[]}catch(t){console.error("Board fetch error:",t)}finally{zn.value=!1}}async function ot(){var t;Un.value=!0;try{const e=it.value||((t=ht.value)==null?void 0:t.room)||"default";it.value||(it.value=e);const n=await So(e);Os.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{Un.value=!1}}async function Pe(){Ut.value=!0;try{const t=await Jo();Ve.value=Array.isArray(t)?t:[]}catch(t){console.error("Goals fetch error:",t)}finally{Ut.value=!1}}async function Us(){try{const t=await Wo();if(!t)return;const e=new Map(V.value),n=e.get(t.loop_id);e.set(t.loop_id,{...n??{},...t,history:t.history.length>0?t.history:(n==null?void 0:n.history)??[]}),V.value=e}catch(t){console.error("MDAL fetch error:",t)}}let tn=null,en=null;function ir(){return Ss.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map(jn.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),jn.value=n}if(Hn(),tn||(tn=setTimeout(()=>{Ye(),tn=null},500)),(e.type==="board_post"||e.type==="board_comment")&&(en||(en=setTimeout(()=>{yt(),en=null},500))),(e.type==="keeper_handoff"||e.type==="keeper_compaction"||e.type==="keeper_guardrail")&&Hn(),e.type==="mdal_started"&&e.loop_id){const n=new Map(V.value);n.set(e.loop_id,{...n.get(e.loop_id)??{},loop_id:e.loop_id,profile:e.profile??"custom",status:"running",current_iteration:e.iteration??0,max_iterations:0,baseline_metric:e.baseline??0,current_metric:e.baseline??0,target:e.target??"",stagnation_streak:0,stagnation_limit:0,elapsed_seconds:0,history:[]}),V.value=n}if(e.type==="mdal_iteration"&&e.loop_id){const n=new Map(V.value),a=e.metric_before??e.metric_after??0,s=e.metric_after??a,i=n.get(e.loop_id)??{loop_id:e.loop_id,profile:e.profile??"unknown",status:"running",current_iteration:e.iteration??0,max_iterations:0,baseline_metric:a,current_metric:s,target:e.target??"",stagnation_streak:0,stagnation_limit:0,elapsed_seconds:0,history:[]},r={iteration:e.iteration??0,metric_before:a,metric_after:s,delta:e.delta??0,changes:"",failed_attempts:"",next_suggestion:"",elapsed_ms:0,cost_usd:null};n.set(e.loop_id,{...i,current_iteration:e.iteration??i.current_iteration,current_metric:s,history:[r,...i.history]}),V.value=n}if((e.type==="mdal_completed"||e.type==="mdal_stopped")&&e.loop_id){const n=new Map(V.value),a=n.get(e.loop_id)??{loop_id:e.loop_id,profile:e.profile??"unknown",status:"running",current_iteration:e.iteration??0,max_iterations:0,baseline_metric:e.baseline??e.metric_before??e.metric_after??0,current_metric:e.metric_after??e.metric_before??e.baseline??0,target:e.target??"",stagnation_streak:0,stagnation_limit:0,elapsed_seconds:0,history:[]};n.set(e.loop_id,{...a,current_iteration:e.iteration??a.current_iteration,current_metric:e.metric_after??a.current_metric,status:e.type==="mdal_completed"?"completed":"stopped"}),V.value=n}}})}let Bt=null;function or(){Bt||(Bt=setInterval(()=>{Hn(),Ye()},1e4))}function rr(){Bt&&(clearInterval(Bt),Bt=null)}function y({title:t,class:e,children:n}){return o`
    <div class="card ${e??""}">
      ${t?o`<div class="card-title">${t}</div>`:null}
      ${n}
    </div>
  `}function Z({status:t,label:e}){return o`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??t}
    </span>
  `}function lr(t){const e=Date.now(),n=typeof t=="number"?t<1e12?t*1e3:t:new Date(t).getTime(),a=Math.floor((e-n)/1e3);if(a<60)return`${a}s ago`;const s=Math.floor(a/60);if(s<60)return`${s}m ago`;const i=Math.floor(s/60);return i<24?`${i}h ago`:`${Math.floor(i/24)}d ago`}function F({timestamp:t}){const e=lr(t),n=typeof t=="string"?t:new Date(t<1e12?t*1e3:t).toISOString();return o`<span class="time-ago" title=${n}>${e}</span>`}const la=_(null);function Hs(t){la.value=t}function Ea(){la.value=null}const wt=[{level:"L1_Reactive",label:"L1 Reactive",color:"#6b7280"},{level:"L2_Suggestive",label:"L2 Suggestive",color:"#3b82f6"},{level:"L3_Guided",label:"L3 Guided",color:"#f59e0b"},{level:"L4_Autonomous",label:"L4 Autonomous",color:"#f97316"},{level:"L5_Independent",label:"L5 Independent",color:"#ef4444"}];function cr(t){if(!t)return 0;const e=wt.findIndex(n=>n.level===t);return e>=0?e:0}function ur({keeper:t}){const e=cr(t.autonomy_level),n=wt[e]??wt[0];if(!n)return null;const a=(e+1)/wt.length*100;return o`
    <div class="keeper-signal-list">
      <div style="margin-bottom:8px;">
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:4px;">
          <span style="font-size:13px; font-weight:600; color:${n.color};">${n.label}</span>
          <span style="font-size:11px; color:#888;">${e+1} / ${wt.length}</span>
        </div>
        <div style="width:100%; height:6px; background:#1a1a2e; border-radius:3px; overflow:hidden;">
          <div style="width:${a}%; height:100%; background:${n.color}; border-radius:3px; transition:width 0.3s;"></div>
        </div>
        <div style="display:flex; justify-content:space-between; margin-top:2px;">
          ${wt.map((s,i)=>o`
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
            <strong><${F} timestamp=${t.last_autonomous_action_at} /></strong>
          </div>`:null}
      ${t.active_goal_ids&&t.active_goal_ids.length>0?o`<div class="keeper-signal-row">
            <span>Active goals</span>
            <strong>${t.active_goal_ids.length}</strong>
          </div>`:null}
    </div>
  `}function Ce(t){return t?t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}K`:String(t):"—"}function dr({keeper:t}){const e=t.metrics_series??[],n=e[e.length-1],a=(n==null?void 0:n.cost_usd)!=null?`$${n.cost_usd.toFixed(4)}`:"—",s=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return o`
    <div class="keeper-kpis">
      ${s.map(i=>o`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${i.label}</div>
          <div class="keeper-kpi-value">${i.value}</div>
          ${i.hint?o`<div class="keeper-kpi-hint">${i.hint}</div>`:null}
        </div>
      `)}
      <div class="kpi-tile">
        <div class="kpi-value">${Ce(t.context_tokens)}</div>
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
  `}function pr({keeper:t}){var m,l;const e=t.metrics_series??[];if(e.length<2){const p=(((m=t.context)==null?void 0:m.context_ratio)??0)*100,v=p>85?"#ef4444":p>70?"#f59e0b":"#22c55e";return o`
      <div class="context-chart">
        <div class="chart-bar-bg">
          <div class="chart-bar" style="width:${p.toFixed(1)}%;background:${v}"></div>
        </div>
        <span class="chart-pct">${p.toFixed(1)}%</span>
      </div>`}const n=200,a=60,s=2,i=e.length,r=e.map((p,v)=>{const g=s+v/(i-1)*(n-2*s),x=a-s-(p.context_ratio??0)*(a-2*s);return{x:g,y:x,p}}),c=r.map(({x:p,y:v})=>`${p.toFixed(1)},${v.toFixed(1)}`).join(" "),u=(((l=e[e.length-1])==null?void 0:l.context_ratio)??0)*100,d=u>85?"#ef4444":u>70?"#f59e0b":"#22c55e";return o`
    <div class="context-chart" style="display:flex;align-items:center;gap:8px">
      <svg viewBox="0 0 ${n} ${a}" width="${n}" height="${a}" style="background:#1a1a2e;border-radius:4px">
        <line x1="${s}" y1="${(a-s-.5*(a-2*s)).toFixed(1)}" x2="${n-s}" y2="${(a-s-.5*(a-2*s)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${s}" y1="${(a-s-.7*(a-2*s)).toFixed(1)}" x2="${n-s}" y2="${(a-s-.7*(a-2*s)).toFixed(1)}" stroke="#666" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${s}" y1="${(a-s-.85*(a-2*s)).toFixed(1)}" x2="${n-s}" y2="${(a-s-.85*(a-2*s)).toFixed(1)}" stroke="#f59e0b" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${r.filter(({p})=>p.is_handoff).map(({x:p})=>o`
          <line x1="${p.toFixed(1)}" y1="${s}" x2="${p.toFixed(1)}" y2="${a-s}" stroke="#ef4444" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${c}" fill="none" stroke="${d}" stroke-width="1.5"/>
        ${r.filter(({p})=>p.is_compaction).map(({x:p,y:v})=>o`
          <circle cx="${p.toFixed(1)}" cy="${v.toFixed(1)}" r="2.5" fill="#a855f7"/>
        `)}
      </svg>
      <span class="chart-pct">${u.toFixed(1)}%</span>
    </div>`}const nn=_("");function vr({keeper:t}){var s,i,r,c;const e=nn.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji??"-"},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((s=t.traits)==null?void 0:s.join(", "))||"-"},{title:"Interests",key:"interests",value:((i=t.interests)==null?void 0:i.join(", "))||"-"}],a=e?n.filter(u=>u.title.toLowerCase().includes(e)||u.key.includes(e)||u.value.toLowerCase().includes(e)):n;return o`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${nn.value}
        onInput=${u=>{nn.value=u.target.value}}
      />
      ${a.map(u=>o`
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
      ${t.context_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Tokens</span><span style="flex:1; text-align:right; color:#ccc;">${Ce(t.context_tokens)}</span></div>`:""}
      ${t.context_max!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Context Max</span><span style="flex:1; text-align:right; color:#ccc;">${Ce(t.context_max)}</span></div>`:""}
      ${t.memory_recent_note?o`<div class="keeper-field-row"><span class="keeper-field-title">Memory Note</span><span style="flex:1; text-align:right; color:#ccc;">${t.memory_recent_note}</span></div>`:""}
      ${t.k2k_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">K2K Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.k2k_count}</span></div>`:""}
      ${t.conversation_tail_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Conv Tail</span><span style="flex:1; text-align:right; color:#ccc;">${t.conversation_tail_count}</span></div>`:""}
      ${t.handoff_count_total!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Total Handoffs</span><span style="flex:1; text-align:right; color:#ccc;">${t.handoff_count_total}</span></div>`:""}
      ${t.compaction_count!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Compactions</span><span style="flex:1; text-align:right; color:#ccc;">${t.compaction_count}</span></div>`:""}
      ${t.last_compaction_saved_tokens!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Last Compact Saved</span><span style="flex:1; text-align:right; color:#ccc;">${Ce(t.last_compaction_saved_tokens)}</span></div>`:""}
      ${((r=t.context)==null?void 0:r.message_count)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Message Count</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.message_count}</span></div>`:""}
      ${((c=t.context)==null?void 0:c.has_checkpoint)!=null?o`<div class="keeper-field-row"><span class="keeper-field-title">Has Checkpoint</span><span style="flex:1; text-align:right; color:#ccc;">${t.context.has_checkpoint?"Yes":"No"}</span></div>`:""}
    </div>
  `}function mr({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return o`
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
  `}function fr({items:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No equipment</div>`:o`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>o`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function _r({rels:t}){const e=Object.entries(t);return e.length===0?o`<div class="empty-state" style="font-size:13px">No relationships</div>`:o`
    <div class="keeper-k2k-list">
      ${e.map(([n,a])=>o`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${a}</span>
        </div>
      `)}
    </div>
  `}function Ia({traits:t,label:e}){return t.length===0?null:o`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>o`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function an(t){return t==null||Number.isNaN(t)?"-":`${Math.round(t*100)}%`}function gr({keeper:t}){const e=t.metrics_window,n=[{label:"Model fallback",value:an(typeof(e==null?void 0:e.model_fallback_rate)=="number"?e.model_fallback_rate:void 0)},{label:"Proactive fallback",value:an(typeof(e==null?void 0:e.proactive_fallback_rate)=="number"?e.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:an(typeof(e==null?void 0:e.memory_pass_rate)=="number"?e.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(e==null?void 0:e.handoff_count)=="number"?e.handoff_count:t.handoff_count_total??"-"},{label:"Compactions",value:typeof(e==null?void 0:e.compaction_events)=="number"?e.compaction_events:t.compaction_count??"-"},{label:"Saved tokens",value:typeof(e==null?void 0:e.compaction_saved_tokens)=="number"?e.compaction_saved_tokens:t.last_compaction_saved_tokens??"-"},{label:"K2K events",value:t.k2k_count??"-"},{label:"Conversation tail",value:t.conversation_tail_count??"-"},{label:"Tool Calls",value:typeof(e==null?void 0:e.tool_call_count)=="number"?e.tool_call_count:"-"},{label:"Preview Similarity",value:typeof(e==null?void 0:e.proactive_preview_similarity_avg)=="number"?`${(e.proactive_preview_similarity_avg*100).toFixed(1)}%`:"-"},{label:"Memory Avg Score",value:typeof(e==null?void 0:e.memory_avg_score)=="number"?e.memory_avg_score.toFixed(3):"-"},{label:"Fallback Rate",value:typeof(e==null?void 0:e.fallback_rate)=="number"?`${(e.fallback_rate*100).toFixed(1)}%`:"-"}];return o`
    <div class="keeper-signal-list">
      ${n.map(a=>o`
        <div class="keeper-signal-row">
          <span>${a.label}</span>
          <strong>${a.value}</strong>
        </div>
      `)}
    </div>
  `}function $r({keeperName:t}){const[e,n]=fe("Loading internal monologue..."),[a,s]=fe(""),[i,r]=fe([]),[c,u]=fe(!1),d=async()=>{try{const l=await U("masc_keeper_status",{name:t,fast:!1,include_history_tail:!0,include_context:!0});n(typeof l=="string"?l:JSON.stringify(l,null,2))}catch(l){n("Failed to load: "+String(l))}};_t(()=>{d()},[t]);const m=async()=>{if(!a.trim())return;u(!0);const l=a;s(""),r(p=>[...p,{role:"You",text:l}]);try{const p=await U("masc_keeper_msg",{name:t,message:l});r(v=>[...v,{role:t,text:typeof p=="string"?p:JSON.stringify(p)}]),d()}catch(p){r(v=>[...v,{role:"System",text:"Error: "+String(p)}])}finally{u(!1)}};return o`
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
              onKeyDown=${l=>l.key==="Enter"&&!l.shiftKey&&m()}
              placeholder="Ping the agent..."
              disabled=${c}
              style="flex: 1; background: rgba(255,255,255,0.05); border: 1px solid var(--border); border-radius: 8px; padding: 8px 12px; color: var(--text-primary); font-family: var(--font-body);"
            />
            <button 
              onClick=${m} 
              disabled=${c||!a.trim()}
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
  `}function hr(){var e,n,a;const t=la.value;return t?o`
    <div
      class="keeper-detail-overlay"
      style="display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${s=>{s.target.classList.contains("keeper-detail-overlay")&&Ea()}}
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
            <${Z} status=${t.status} />
            ${t.model?o`<span class="pill">${t.model}</span>`:null}
          </div>
          <button
            onClick=${()=>Ea()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${dr} keeper=${t} />

        ${""}
        <${pr} keeper=${t} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${y} title="Field Dictionary">
            <${vr} keeper=${t} />
          <//>

          ${""}
          <${y} title="Profile">
            <${Ia} traits=${t.traits??[]} label="Traits" />
            <${Ia} traits=${t.interests??[]} label="Interests" />
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
                <${ur} keeper=${t} />
              <//>
            `:null}

          ${""}
          ${t.trpg_stats?o`
              <${y} title="TRPG Stats">
                <${mr} stats=${t.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?o`
              <${y} title="Equipment (${t.inventory.length})">
                <${fr} items=${t.inventory} />
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?o`
              <${y} title="Relationships (${Object.keys(t.relationships).length})">
                <${_r} rels=${t.relationships} />
              <//>
            `:null}

          <${y} title="Runtime Signals">
            <${gr} keeper=${t} />
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
        <${$r} keeperName=${t.name} />
      </div>
    </div>
  `:null}let yr=0;const ft=_([]);function b(t,e="success",n=4e3){const a=++yr;ft.value=[...ft.value,{id:a,message:t,type:e}],setTimeout(()=>{ft.value=ft.value.filter(s=>s.id!==a)},n)}function br(t){ft.value=ft.value.filter(e=>e.id!==t)}function xr(){const t=ft.value;return t.length===0?null:o`
    <div class="toast-container">
      ${t.map(e=>o`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>br(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}const kr="masc_dashboard_agent_name",Mt=_(null),Me=_(!1),se=_(""),je=_([]),ie=_([]),Nt=_(""),Kt=_(!1);function Bs(t){Mt.value=t,ca()}function Pa(){Mt.value=null,se.value="",je.value=[],ie.value=[],Nt.value=""}function wr(){const t=Mt.value;return t?It.value.find(e=>e.name===t)??null:null}function Ks(t){return t?pe.value.filter(e=>e.assignee===t):[]}async function ca(){const t=Mt.value;if(t){Me.value=!0,se.value="",je.value=[],ie.value=[];try{const e=await jo(80);je.value=e.filter(s=>s.includes(t)).slice(0,20);const n=Ks(t).slice(0,6);if(n.length===0)return;const a=await Promise.all(n.map(async s=>{try{const i=await Oo(s.id,25);return{taskId:s.id,text:i.trim()}}catch(i){const r=i instanceof Error?i.message:"history load failed";return{taskId:s.id,text:`Failed to load history: ${r}`}}}));ie.value=a}catch(e){se.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{Me.value=!1}}}async function Ma(){var a;const t=Mt.value,e=Nt.value.trim();if(!t||!e)return;const n=((a=localStorage.getItem(kr))==null?void 0:a.trim())||"dashboard";Kt.value=!0;try{await Is(n,`@${t} ${e}`),Nt.value="",b(`Mention sent to ${t}`,"success"),ca()}catch(s){const i=s instanceof Error?s.message:"Failed to send mention";b(i,"error")}finally{Kt.value=!1}}function Sr({task:t}){return o`
    <div class="agent-detail-task">
      <span class="pill">${t.id}</span>
      <span class="agent-detail-task-title">${t.title}</span>
      <${Z} status=${t.status} />
    </div>
  `}function Cr({row:t}){return o`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${t.taskId}</span>
      </div>
      <pre class="agent-history-pre">${t.text||"No task history yet"}</pre>
    </div>
  `}function Ar(){var s,i,r,c;const t=Mt.value;if(!t)return null;const e=wr(),n=Ks(t),a=je.value;return o`
    <div
      class="agent-detail-overlay"
      onClick=${u=>{u.target.classList.contains("agent-detail-overlay")&&Pa()}}
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
                        <${Z} status=${e.status} />
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
            <button class="control-btn ghost" onClick=${()=>{ca()}} disabled=${Me.value}>
              ${Me.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${Pa}>Close</button>
          </div>
        </div>

        ${se.value?o`<div class="council-error">${se.value}</div>`:null}

        <div class="agent-detail-grid">
          <${y} title="Assigned Tasks">
            ${n.length===0?o`<div class="empty-state">No assigned tasks</div>`:o`<div class="agent-detail-task-list">${n.map(u=>o`<${Sr} key=${u.id} task=${u} />`)}</div>`}
          <//>

          <${y} title="Recent Activity">
            ${a.length===0?o`<div class="empty-state">No recent room activity match</div>`:o`<div class="agent-activity-list">${a.map((u,d)=>o`<div key=${d} class="agent-activity-line">${u}</div>`)}</div>`}
          <//>
        </div>

        <${y} title="Task History">
          ${ie.value.length===0?o`<div class="empty-state">No task history loaded</div>`:o`<div class="agent-history-list">${ie.value.map(u=>o`<${Cr} key=${u.taskId} row=${u} />`)}</div>`}
        <//>

        <${y} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${Nt.value}
              onInput=${u=>{Nt.value=u.target.value}}
              onKeyDown=${u=>{u.key==="Enter"&&Ma()}}
              disabled=${Kt.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{Ma()}}
              disabled=${Kt.value||Nt.value.trim()===""}
            >
              ${Kt.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}function xt({label:t,value:e,color:n}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color: ${n}`:""}>${e}</div>
    </div>
  `}function Nr({agent:t}){return o`
    <div class="agent" onClick=${()=>Bs(t.name)} style="cursor: pointer">
      <span class="agent-emoji">${t.emoji??""}</span>
      <span class="agent-status ${t.status}"></span>
      <span class="agent-name">${t.name}</span>
      <${Z} status=${t.status} />
      ${t.current_task?o`<span class="agent-task">${t.current_task}</span>`:null}
    </div>
  `}function Tr(t){return t==null?"—":t>=1e6?`${(t/1e6).toFixed(1)}M`:t>=1e3?`${(t/1e3).toFixed(1)}k`:String(t)}function Lr(t,e){return t.length>e?t.slice(0,e-1)+"…":t}function ja(t){return t>.8?"ctx-bar-bad":t>.6?"ctx-bar-warn":"ctx-bar-ok"}function Rr({keeper:t}){const e=t.context_ratio,n=e!=null?Math.round(e*100):null,a=Vo.value.get(t.name),s=Qo.value.has(t.name);return o`
    <div class="live-agent keeper-card ${s?"stale":""}" onClick=${()=>Hs(t)} style="cursor: pointer">
      <div class="live-agent-main">
        <!-- Row 1: Identity -->
        <div class="live-agent-title">
          <span class="live-agent-name">${t.emoji??""} ${t.name}</span>
          <${Z} status=${t.status} />
          ${a?o`<span class="pill pill-lifecycle pill-lifecycle-${a}">${a}</span>`:null}
          ${s?o`<span class="pill pill-stale">stale</span>`:null}
          ${t.model?o`<span class="pill">${t.model}</span>`:null}
          ${t.skill_primary?o`<span class="pill pill-skill">${t.skill_primary}</span>`:null}
        </div>
        <div class="live-agent-sub">${t.koreanName??""}</div>

        <!-- Row 2: Context bar -->
        ${e!=null?o`
          <div class="keeper-ctx-row">
            <div class="keeper-ctx-bar">
              <div class="keeper-ctx-fill ${ja(e)}" style="width: ${n}%"></div>
            </div>
            <span class="keeper-ctx-label ${ja(e)}">
              ${n}%
              ${t.context_tokens!=null?o` (${Tr(t.context_tokens)})`:null}
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
          <div class="keeper-note-preview">${Lr(t.memory_recent_note,80)}</div>
        `:null}
      </div>
    </div>
  `}function Oa(){var r,c,u,d,m;const t=ht.value,e=It.value,n=Pt.value,a=ra.value,s=(r=t==null?void 0:t.monitoring)==null?void 0:r.board,i=(c=t==null?void 0:t.monitoring)==null?void 0:c.council;return o`
    <div class="stats-grid">
      <${xt} label="Agents" value=${e.length} />
      <${xt} label="Active" value=${Fs.value.length} color="#4ade80" />
      <${xt} label="Keepers" value=${n.length} color="#22d3ee" />
      <${xt} label="Tasks" value=${pe.value.length} />
      <${xt} label="In Progress" value=${a.inProgress.length} color="#fbbf24" />
      <${xt} label="Done" value=${a.done.length} color="#4ade80" />
    </div>

    ${s||i?o`
        <${y} title="Operations SLO" class="section">
          <div class="grid-2col">
            <div class="stat-card">
              <div class="stat-label">Board Feed</div>
              <div class="stat-value" style=${`color: ${za(s==null?void 0:s.alert_level)}`}>
                ${Fa(s==null?void 0:s.alert_level)}
              </div>
              <div class="council-sub">
                <span>Freshness: ${ge(s==null?void 0:s.last_activity_age_s)}</span>
                <span>SLO: ≤ ${ge(s==null?void 0:s.slo_target_age_s)}</span>
                <span>SLO Breach: ${s!=null&&s.slo_breached?"Yes":"No"}</span>
                <span>Posts (24h): ${(s==null?void 0:s.new_posts_24h)??0}</span>
                <span>Unanswered: ${(s==null?void 0:s.unanswered_posts)??0}</span>
              </div>
            </div>

            <div class="stat-card">
              <div class="stat-label">Council Feed</div>
              <div class="stat-value" style=${`color: ${za(i==null?void 0:i.alert_level)}`}>
                ${Fa(i==null?void 0:i.alert_level)}
              </div>
              <div class="council-sub">
                <span>Freshness: ${ge(i==null?void 0:i.last_activity_age_s)}</span>
                <span>Open Debates: ${(i==null?void 0:i.debates_open)??0}</span>
                <span>Pending Debates: ${(i==null?void 0:i.debates_pending)??0}</span>
                <span>Quorum Risk: ${(i==null?void 0:i.sessions_without_quorum)??0}</span>
                <span>SLO: ≤ ${ge(i==null?void 0:i.slo_target_quorum_age_s)}</span>
                <span>SLO Breach: ${i!=null&&i.slo_breached?"Yes":"No"}</span>
              </div>
            </div>
          </div>
        <//>
      `:null}

    <div class="grid-2col">
      <${y} title="Agents" class="section">
        <div class="agent-list">
          ${e.length===0?o`<div class="empty-state">No agents connected</div>`:e.map(l=>o`<${Nr} key=${l.name} agent=${l} />`)}
        </div>
      <//>

      <${y} title="Keepers" class="section">
        <div class="live-agent-list">
          ${n.length===0?o`<div class="empty-state">No keepers active</div>`:n.map(l=>o`<${Rr} key=${l.name} keeper=${l} />`)}
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
            <span>Uptime: ${Dr(t.uptime_seconds??0)}</span>
            ${t.paused?o`<span class="pill pill-stale">Paused</span>`:null}
            ${t.tempo?o`<span>Tempo: ${t.tempo}</span>`:null}
            ${t.tempo_interval_s!=null?o`<span>Interval: ${t.tempo_interval_s}s</span>`:null}
            ${((u=t.data_quality)==null?void 0:u.board_contract_ok)===!1?o`<span class="pill pill-stale">Board Contract: Degraded</span>`:null}
            ${((d=t.data_quality)==null?void 0:d.council_feed_ok)===!1?o`<span class="pill pill-stale">Council Feed: Degraded</span>`:null}
            ${(m=t.data_quality)!=null&&m.last_sync_at?o`<span>Data Sync: <${F} timestamp=${t.data_quality.last_sync_at} /></span>`:null}
          </div>
        <//>
      `:null}
  `}function Dr(t){if(!t)return"N/A";const e=Math.floor(t/3600),n=Math.floor(t%3600/60);return e>0?`${e}h ${n}m`:`${n}m`}function ge(t){if(t==null||!Number.isFinite(t))return"No data";if(t<60)return`${Math.max(0,Math.round(t))}s`;const e=Math.floor(t/60);if(e<60)return`${e}m`;const n=Math.floor(e/60),a=e%60;return a>0?`${n}h ${a}m`:`${n}h`}function Fa(t){const e=(t??"").toLowerCase();return e==="ok"?"Healthy":e==="warn"?"Warning":e==="bad"?"Degraded":"Unknown"}function za(t){const e=(t??"").toLowerCase();return e==="ok"?"#4ade80":e==="warn"?"#fbbf24":e==="bad"?"#fb7185":"#94a3b8"}const Bn=_([]),Kn=_([]),qt=_(""),Oe=_(!1),Wt=_(!1),oe=_(""),Fe=_(null),G=_(null),qn=_(!1);async function Wn(){Oe.value=!0,oe.value="";try{const[t,e]=await Promise.all([Fo(),zo()]);Bn.value=t,Kn.value=e}catch(t){oe.value=t instanceof Error?t.message:"Failed to load council data"}finally{Oe.value=!1}}async function Ua(){const t=qt.value.trim();if(t){Wt.value=!0;try{const e=await Uo(t);qt.value="",b(e!=null&&e.id?`Debate started: ${e.id}`:"Debate started","success"),await Wn()}catch(e){const n=e instanceof Error?e.message:"Failed to start debate";b(n,"error")}finally{Wt.value=!1}}}async function Er(t){Fe.value=t,qn.value=!0,G.value=null;try{G.value=await Ho(t)}catch(e){oe.value=e instanceof Error?e.message:"Failed to load debate status",G.value=null}finally{qn.value=!1}}function Ir({debate:t}){const e=Fe.value===t.id;return o`
    <button
      class="council-row ${e?"selected":""}"
      onClick=${()=>Er(t.id)}
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
  `}function Pr({session:t}){return o`
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
  `}function Mr(){var e;const t=(e=ht.value)==null?void 0:e.data_quality;return!t||t.council_feed_ok!==!1&&!t.last_sync_at?null:o`
    <div class="feed-health-banner ${t.council_feed_ok===!1?"degraded":"ok"}">
      <span class="feed-health-title">
        ${t.council_feed_ok===!1?"Council feed degraded":"Council feed synced"}
      </span>
      ${t.last_sync_at?o`<span class="feed-health-meta">Last sync: <${F} timestamp=${t.last_sync_at} /></span>`:o`<span class="feed-health-meta">No sync timestamp</span>`}
    </div>
  `}function jr(){var e,n;_t(()=>{Wn()},[]);const t=((n=(e=ht.value)==null?void 0:e.data_quality)==null?void 0:n.council_feed_ok)===!1;return o`
    <div>
      <${Mr} />
      <${y} title="Council Command" class="section">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${qt.value}
            onInput=${a=>{qt.value=a.target.value}}
            onKeyDown=${a=>{a.key==="Enter"&&Ua()}}
            disabled=${Wt.value}
          />
          <button
            class="control-btn secondary"
            onClick=${Ua}
            disabled=${Wt.value||qt.value.trim()===""}
          >
            ${Wt.value?"Starting...":"Start Debate"}
          </button>
          <button class="control-btn ghost" onClick=${Wn} disabled=${Oe.value}>
            ${Oe.value?"Refreshing...":"Refresh"}
          </button>
        </div>
        ${oe.value?o`<div class="council-error">${oe.value}</div>`:null}
      <//>

      <div class="council-grid">
        <${y} title="Debates" class="section">
          <div class="council-list">
            ${Bn.value.length===0?o`
                  <div class="empty-state">
                    ${t?"No debates loaded (council feed degraded).":"No debates yet"}
                  </div>
                `:Bn.value.map(a=>o`<${Ir} key=${a.id} debate=${a} />`)}
          </div>
        <//>

        <${y} title="Voting Sessions" class="section">
          <div class="council-list">
            ${Kn.value.length===0?o`
                  <div class="empty-state">
                    ${t?"No sessions loaded (council feed degraded).":"No active sessions"}
                  </div>
                `:Kn.value.map(a=>o`<${Pr} key=${a.id} session=${a} />`)}
          </div>
        <//>
      </div>

      <${y} title=${Fe.value?`Debate Detail (${Fe.value})`:"Debate Detail"} class="section">
        ${qn.value?o`<div class="loading-indicator">Loading debate detail...</div>`:G.value?o`
                <div class="council-sub" style="margin-bottom: 8px;">
                  <span>Status: ${G.value.status}</span>
                  <span>Total arguments: ${G.value.total_arguments}</span>
                </div>
                <div class="council-sub" style="margin-bottom: 8px;">
                  <span>Support: ${G.value.support_count}</span>
                  <span>Oppose: ${G.value.oppose_count}</span>
                  <span>Neutral: ${G.value.neutral_count}</span>
                </div>
                ${G.value.summary_text?o`<pre class="council-detail">${G.value.summary_text}</pre>`:null}
              `:o`<div class="empty-state">Select a debate to view summary</div>`}
      <//>
    </div>
  `}function Or({text:t}){if(!t)return null;const e=Fr(t);return o`<div class="markdown-content">${e}</div>`}function Fr(t){const e=t.split(`
`),n=[];let a=0;for(;a<e.length;){const s=e[a];if(/^(`{3,}|~{3,})/.test(s)){const r=s.match(/^(`{3,}|~{3,})/)[0],c=s.slice(r.length).trim(),u=[];for(a++;a<e.length&&!e[a].startsWith(r);)u.push(e[a]),a++;a++,n.push(o`<pre><code class=${c?`language-${c}`:""}>${u.join(`
`)}</code></pre>`);continue}if(s.trim()==="<think>"||s.trim().startsWith("<think>")){const r=[],c=s.trim().replace(/^<think>/,"").trim();for(c&&c!=="</think>"&&r.push(c),a++;a<e.length&&!e[a].includes("</think>");)r.push(e[a]),a++;if(a<e.length){const d=e[a].replace("</think>","").trim();d&&r.push(d),a++}const u=r.join(`
`).trim();n.push(o`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${sn(u)}</div>
        </details>
      `);continue}if(s.startsWith("> ")){const r=[];for(;a<e.length&&e[a].startsWith("> ");)r.push(e[a].slice(2)),a++;n.push(o`<blockquote>${sn(r.join(`
`))}</blockquote>`);continue}if(s.trim()===""){a++;continue}const i=[];for(;a<e.length;){const r=e[a];if(r.trim()===""||/^(`{3,}|~{3,})/.test(r)||r.startsWith("> ")||r.trim().startsWith("<think>"))break;i.push(r),a++}i.length>0&&n.push(o`<p>${sn(i.join(`
`))}</p>`)}return n}function sn(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let a=0,s;for(;(s=n.exec(t))!==null;){if(s.index>a&&e.push(t.slice(a,s.index)),s[1]){const i=s[1].slice(1,-1);e.push(o`<code>${i}</code>`)}else if(s[2]){const i=s[2].slice(2,-2);e.push(o`<strong>${i}</strong>`)}else if(s[3]){const i=s[3].slice(1,-1);e.push(o`<em>${i}</em>`)}else s[4]&&s[5]&&e.push(o`<a href=${s[5]} target="_blank" rel="noopener">${s[4]}</a>`);a=s.index+s[0].length}return a<t.length&&e.push(t.slice(a)),e.length>0?e:[t]}const zr=[{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"recent",label:"Recent"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],Jn=_([]),Jt=_(!1),Gn=_(null),Gt=_("");function Ur(){var e,n;const t=new URLSearchParams(window.location.search);return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}const Hr=_(Ur()),Vt=_(!1);async function qs(t){Gn.value=t,Jt.value=!0;try{const e=await co(t);if(Gn.value!==t)return;Jn.value=e.comments??[]}catch{}finally{Jt.value=!1}}async function Ha(t){const e=Gt.value.trim();if(e){Vt.value=!0;try{await uo(t,Hr.value,e),Gt.value="",b("Comment posted","success"),await qs(t),yt()}catch{b("Failed to post comment","error")}finally{Vt.value=!1}}}function Br(){const t=On.value;return o`
    <div class="board-controls">
      ${zr.map(e=>o`
        <button
          class="board-sort-btn ${t===e.id?"active":""}"
          onClick=${()=>{On.value=e.id,yt()}}
        >
          ${e.label}
        </button>
      `)}
    </div>
  `}function on(){var e;const t=(e=ht.value)==null?void 0:e.data_quality;return!t||t.board_contract_ok!==!1&&!t.last_sync_at?null:o`
    <div class="feed-health-banner ${t.board_contract_ok===!1?"degraded":"ok"}">
      <span class="feed-health-title">
        ${t.board_contract_ok===!1?"Board feed degraded":"Board feed synced"}
      </span>
      ${t.last_sync_at?o`<span class="feed-health-meta">Last sync: <${F} timestamp=${t.last_sync_at} /></span>`:o`<span class="feed-health-meta">No sync timestamp</span>`}
    </div>
  `}function Ws({flair:t}){return t?o`<span class="post-flair ${t}">${t}</span>`:null}function Kr({post:t}){const e=async(n,a)=>{a.stopPropagation();try{await Es(t.id,n),yt()}catch{b("Failed to vote","error")}};return o`
    <div class="board-post" onClick=${()=>zi(t.id)}>
      <div class="vote-column">
        <button class="vote-btn upvote" onClick=${n=>e("up",n)}>▲</button>
        <span class="vote-count">${t.votes??0}</span>
        <button class="vote-btn downvote" onClick=${n=>e("down",n)}>▼</button>
      </div>
      <div class="post-content">
        <div class="post-title">
          ${t.title}
          ${" "}
          <${Ws} flair=${t.flair} />
        </div>
        <div class="post-meta">
          <span>${t.author}</span>
          <${F} timestamp=${t.created_at} />
          ${t.comment_count>0?o`<span>${t.comment_count} comments</span>`:null}
          ${(t.hearth_count??0)>0?o`<span>♥ ${t.hearth_count}</span>`:null}
        </div>
      </div>
    </div>
  `}function qr({comments:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No comments yet</div>`:o`
    <div class="comment-thread">
      ${t.map(e=>o`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${F} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function Wr({postId:t}){return o`
    <div class="comment-form" style="margin-top: 12px; display: flex; gap: 8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${Gt.value}
        onInput=${e=>{Gt.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&Ha(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${Vt.value}
      />
      <button
        onClick=${()=>Ha(t)}
        disabled=${Vt.value||Gt.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${Vt.value?"...":"Post"}
      </button>
    </div>
  `}function Jr({post:t}){Gn.value!==t.id&&!Jt.value&&qs(t.id);const e=async n=>{try{await Es(t.id,n),yt()}catch{b("Failed to vote","error")}};return o`
    <div>
      <button class="back-btn" onClick=${()=>Ge("board")}>← Back to Board</button>
      <${y} title=${o`${t.title} <${Ws} flair=${t.flair} />`}>
        <div class="board-detail">
          <div class="post-body">
            <${Or} text=${t.content} />
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

      <${y} title="Comments (${Jt.value?"...":Jn.value.length})">
        ${Jt.value?o`<div class="loading-indicator">Loading comments...</div>`:o`<${qr} comments=${Jn.value} />`}
        <${Wr} postId=${t.id} />
      <//>
    </div>
  `}function Gr(){var s,i;const t=js.value,e=zn.value,n=nt.value.postId,a=((i=(s=ht.value)==null?void 0:s.data_quality)==null?void 0:i.board_contract_ok)===!1;if(n){const r=t.find(c=>c.id===n);return r?o`
          <${on} />
          <${Jr} post=${r} />
        `:o`
          <div>
            <${on} />
            <button class="back-btn" onClick=${()=>Ge("board")}>← Back to Board</button>
            <div class="empty-state">
              ${a?"Post not available while board feed is degraded":"Post not found"}
            </div>
          </div>
        `}return o`
    <${on} />
    <${Br} />
    ${e?o`<div class="loading-indicator">Loading board...</div>`:t.length===0?o`
            <div class="empty-state">
              ${a?"No posts loaded (board feed degraded). Check board contract sync.":"No posts yet"}
            </div>
          `:o`<div class="board-post-list">
            ${t.map(r=>o`<${Kr} key=${r.id} post=${r} />`)}
          </div>`}
  `}function Vr(t,e){return{id:t.id??`msg-${t.seq??e}`,source:"message",actor:t.from??"system",content:t.content,timestamp:t.timestamp}}function Yr(t,e){return{id:`evt-${t.timestamp}-${e}`,source:"event",actor:t.agent||"system",content:t.text,timestamp:new Date(t.timestamp).toISOString()}}function Ba(t){const e=Date.parse(t);return Number.isNaN(e)?0:e}function Qr({row:t}){const e=new Date(t.timestamp),n=isNaN(e.getTime())?"00:00:00":e.toLocaleTimeString("en-US",{hour12:!1});return o`
    <div class="term-row">
      <span class="term-time">${n}</span>
      <span class="term-actor">${t.actor}</span>
      <span class="term-source ${t.source}">${t.source==="message"?"msg":"evt"}</span>
      <span class="term-text">${t.content}</span>
    </div>
  `}function Xr(){const t=Ms.value.map(Vr),e=Ee.value.map(Yr),n=[...t,...e].sort((a,s)=>Ba(s.timestamp)-Ba(a.timestamp)).slice(0,100);return o`
    <div class="section">
      <h2 style="color: var(--accent); text-shadow: 0 0 10px rgba(0,240,255,0.5); margin-bottom: 16px; font-family: monospace;">> LIVE_ACTIVITY_STREAM</h2>
      <div class="terminal-feed">
        ${n.length===0?o`<div class="empty-state" style="font-family: monospace; color: var(--ok);">> Waiting for signal...</div>`:n.map(a=>o`<${Qr} key=${a.id} row=${a} />`)}
      </div>
    </div>
  `}function Js({ratio:t,size:e=40,stroke:n=4}){if(t==null)return null;const a=(e-n)/2,s=e/2,i=2*Math.PI*a,r=i*((100-t*100)/100);let c="mitosis-safe";return t>=.8?c="mitosis-critical":t>=.5&&(c="mitosis-warn"),o`
    <div class="mitosis-ring-container" title="Mitosis Context Load: ${Math.round(t*100)}%">
      <svg class="mitosis-ring" width="${e}" height="${e}" viewBox="0 0 ${e} ${e}">
        <circle class="mitosis-ring-bg" cx="${s}" cy="${s}" r="${a}" stroke-width="${n}" />
        <circle 
          class="mitosis-ring-fg ${c}" 
          cx="${s}" cy="${s}" r="${a}" 
          stroke-width="${n}" 
          stroke-dasharray="${i}" 
          stroke-dashoffset="${r}" 
        />
      </svg>
      <span class="mitosis-text ${c}">${Math.round(t*100)}%</span>
    </div>
  `}const Zr={born_at:{label:"Born",description:"Keeper 메타가 생성된 시각입니다.",sourcePath:"keepers[].created_at",interpretation:"최근 생성일수록 신규 Keeper입니다."},generation:{label:"Generation",description:"승계/핸드오프를 거치며 누적된 세대 번호입니다.",sourcePath:"keepers[].generation",interpretation:"값이 높을수록 세대 전환을 더 많이 경험했습니다."},status:{label:"Status",description:"현재 실행 상태입니다.",sourcePath:"keepers[].status",interpretation:"active/idle은 동작 중, offline/inactive는 비활성 상태입니다."},recent_activity:{label:"Recent",description:"가장 최근 변화/행동 요약입니다.",sourcePath:"keepers[].last_drift_reason | keepers[].last_proactive_reason | keepers[].memory_recent_note",formula:"first_non_null(last_drift_reason, last_proactive_reason, memory_recent_note)",interpretation:"최근 어떤 일을 했는지 한 줄로 파악합니다."},relations:{label:"Relations",description:"다른 Keeper와의 최근 상호작용 빈도입니다.",sourcePath:"keepers[].k2k_count, keepers[].k2k_mentions",formula:"k2k_count + top(k2k_mentions)",interpretation:"값이 높을수록 협업/호출이 잦습니다."},personality_change:{label:"Personality Change",description:"성향 변화 추세를 드리프트 지표로 요약한 값입니다.",sourcePath:"keepers[].drift_count_total, keepers[].metrics_window.goal_drift_avg",formula:"drift_count_total + goal_drift_avg",interpretation:"높을수록 최근 성향/목표 정렬 변화가 컸습니다."}};function tl(t){return Zr[t]}function kt({metric:t}){const e=tl(t);return o`
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
  `}function el({agent:t}){return o`
    <button class="agent-card ${t.status}" onClick=${()=>Bs(t.name)}>
      <div class="agent-card-header">
        <span class="agent-emoji">${t.emoji??""}</span>
        <div class="agent-card-info">
          <span class="agent-name">${t.name}</span>
          ${t.koreanName?o`<span class="agent-korean">${t.koreanName}</span>`:null}
        </div>
        <${Js} ratio=${t.context_ratio} />
        <${Z} status=${t.status} />
      </div>
      ${t.current_task?o`<div class="agent-task">${t.current_task}</div>`:null}
      ${t.model?o`<div class="agent-model"><span class="pill">${t.model}</span></div>`:null}
    </button>
  `}function nl(t){return typeof t!="number"||Number.isNaN(t)?null:`${Math.round(t*100)}%`}function al(t){var s,i,r;const e=(s=t.last_drift_reason)==null?void 0:s.trim();if(e)return e;const n=(i=t.last_proactive_reason)==null?void 0:i.trim();if(n)return n;const a=(r=t.memory_recent_note)==null?void 0:r.trim();return a||"—"}function sl(t){var a;const e=t.k2k_count??0,n=(a=t.k2k_mentions)==null?void 0:a[0];return n?`${e} · ${n.keeper}(${n.count})`:String(e)}function il(t){var a;const e=t.drift_count_total??0,n=nl((a=t.metrics_window)==null?void 0:a.goal_drift_avg);return e===0&&!n?"Stable":n?`Drift ${e} · Δ${n}`:`Drift ${e}`}function ol({keeper:t}){var s;const e=al(t),n=sl(t),a=il(t);return o`
    <div class="live-agent keeper-card" onClick=${()=>Hs(t)} style="cursor:pointer;">
      <div class="live-agent-main">
        <div class="live-agent-title">
          <span class="live-agent-name">${t.emoji??""} ${t.name}</span>
          <${Js} ratio=${t.context_ratio} />
        <${Z} status=${t.status} />
          ${t.model?o`<span class="pill">${t.model}</span>`:null}
        </div>
        ${t.koreanName?o`<div class="live-agent-sub">${t.koreanName}</div>`:null}
        <div class="keeper-core-grid">
          <div class="keeper-core-item">
            <span class="keeper-core-label">Born <${kt} metric="born_at" /></span>
            <strong class="keeper-core-value">
              ${t.created_at?o`<${F} timestamp=${t.created_at} />`:"—"}
            </strong>
          </div>
          <div class="keeper-core-item">
            <span class="keeper-core-label">Gen <${kt} metric="generation" /></span>
            <strong class="keeper-core-value">${t.generation??"—"}</strong>
          </div>
          <div class="keeper-core-item">
            <span class="keeper-core-label">Status <${kt} metric="status" /></span>
            <strong class="keeper-core-value">${t.status}</strong>
          </div>
          <div class="keeper-core-item">
            <span class="keeper-core-label">Relations <${kt} metric="relations" /></span>
            <strong class="keeper-core-value">${n}</strong>
          </div>
          <div class="keeper-core-item keeper-core-item-span">
            <span class="keeper-core-label">Recent <${kt} metric="recent_activity" /></span>
            <strong class="keeper-core-value keeper-core-text">${e}</strong>
          </div>
          <div class="keeper-core-item keeper-core-item-span">
            <span class="keeper-core-label">Personality <${kt} metric="personality_change" /></span>
            <strong class="keeper-core-value">${a}</strong>
          </div>
        </div>

        <!-- Inner Information Section -->
        <div class="keeper-inner-info">
          ${(s=t.agent)!=null&&s.current_task?o`
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
  `}function rl(){const t=It.value,e=Pt.value;return o`
    <div>
      ${e.length>0?o`
          <div class="section" style="margin-bottom: 20px">
            <h2>Keepers (Live)</h2>
            <div class="live-agent-list">
              ${e.map(n=>o`<${ol} key=${n.name} keeper=${n} />`)}
            </div>
          </div>
        `:null}

      <div class="section">
        <h2>All Agents</h2>
        ${t.length===0?o`<div class="empty-state">No agents registered</div>`:o`
            <div class="agent-grid">
              ${t.map(n=>o`<${el} key=${n.name} agent=${n} />`)}
            </div>
          `}
      </div>
    </div>
  `}function rn({task:t}){const e=(t.priority??4)<=1?"p1":(t.priority??4)===2?"p2":(t.priority??4)===3?"p3":"p4";return o`
    <div class="kanban-card ${e}">
      <div class="kanban-card-title">${t.title}</div>
      <div class="kanban-card-meta">
        ${t.created_at?o`<${F} timestamp=${t.created_at} />`:o`<span>-</span>`}
        ${t.assignee?o`<span class="kanban-assignee">${t.assignee}</span>`:null}
      </div>
    </div>
  `}function ll(){const{todo:t,inProgress:e,done:n}=ra.value;return o`
    <div class="kanban-board">
      <!-- TODO Column -->
      <div class="kanban-column">
        <div class="kanban-header todo">
          <span>TO DO</span>
          <span class="kanban-badge">${t.length}</span>
        </div>
        ${t.length===0?o`<div class="empty-state" style="opacity: 0.5;">No pending tasks</div>`:t.map(a=>o`<${rn} key=${a.id} task=${a} />`)}
      </div>

      <!-- IN PROGRESS Column -->
      <div class="kanban-column">
        <div class="kanban-header inprogress">
          <span>IN PROGRESS</span>
          <span class="kanban-badge">${e.length}</span>
        </div>
        ${e.length===0?o`<div class="empty-state" style="opacity: 0.5;">No active tasks</div>`:e.map(a=>o`<${rn} key=${a.id} task=${a} />`)}
      </div>

      <!-- DONE Column -->
      <div class="kanban-column">
        <div class="kanban-header done">
          <span>DONE</span>
          <span class="kanban-badge">${n.length}</span>
        </div>
        ${n.length===0?o`<div class="empty-state" style="opacity: 0.5;">No completed tasks</div>`:n.slice(0,20).map(a=>o`<${rn} key=${a.id} task=${a} />`)}
        ${n.length>20?o`<div class="empty-state" style="opacity: 0.5;">...and ${n.length-20} more</div>`:null}
      </div>
    </div>
  `}function cl(t){return t==null?"P3":t<=1?"P1":t===2?"P2":t>=4?"P4+":"P3"}function ln({task:t}){return o`
    <div class="council-row session">
      <div class="council-row-main">
        <div class="council-topic">${t.title}</div>
        <div class="council-sub">
          <span>${cl(t.priority)}</span>
          ${t.assignee?o`<span>Assignee: ${t.assignee}</span>`:o`<span>Unassigned</span>`}
          ${t.created_at?o`<span><${F} timestamp=${t.created_at} /></span>`:null}
        </div>
      </div>
      <span class="council-state ${t.status}">${t.status}</span>
    </div>
  `}function ul(){const t=ra.value,e=t.inProgress,n=t.todo,a=t.done,s=Fs.value,i=n.filter(c=>(c.priority??3)<=2),r=n.filter(c=>!c.assignee);return o`
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
        <div class="stat-value" style="color:#4ade80">${a.length}</div>
      </div>
    </div>

    <div class="council-grid">
      <${y} title="Execution Queue" class="section">
        <div class="council-list">
          ${e.length===0?o`<div class="empty-state">No active execution tasks</div>`:e.slice(0,20).map(c=>o`<${ln} key=${c.id} task=${c} />`)}
        </div>
      <//>

      <${y} title="Ready Queue" class="section">
        <div class="council-list">
          ${n.length===0?o`<div class="empty-state">No ready tasks</div>`:n.slice(0,20).map(c=>o`<${ln} key=${c.id} task=${c} />`)}
        </div>
      <//>
    </div>

    <div class="grid-2col">
      <${y} title="Assignee Coverage" class="section">
        <div class="council-list">
          ${s.length===0?o`<div class="empty-state">No active agents</div>`:s.map(c=>o`
                <div class="council-row session">
                  <div class="council-row-main">
                    <div class="council-topic">${c.name}</div>
                    <div class="council-sub">
                      ${c.current_task?o`<span>${c.current_task}</span>`:o`<span>Idle</span>`}
                    </div>
                  </div>
                  <${Z} status=${c.status} />
                </div>
              `)}
        </div>
      <//>

      <${y} title="Attention Needed" class="section">
        <div class="council-list">
          ${r.length===0?o`<div class="empty-state">No unassigned tasks</div>`:r.slice(0,20).map(c=>o`<${ln} key=${c.id} task=${c} />`)}
        </div>
      <//>
    </div>
  `}function dl(t){const e=t.text;return e==="Joined"?{label:"agent_joined",color:"#4ade80"}:e==="Left"?{label:"agent_left",color:"#ef4444"}:e.startsWith("Task:")?{label:"task_update",color:"#fbbf24"}:e.startsWith("Heartbeat")?{label:"keeper_heartbeat",color:"#22d3ee"}:e.startsWith("Handoff")?{label:"keeper_handoff",color:"#a78bfa"}:e.startsWith("Compaction")?{label:"keeper_compaction",color:"#a78bfa"}:e.startsWith("Guardrail")?{label:"keeper_guardrail",color:"#fb7185"}:{label:"event",color:"#94a3b8"}}function pl({entry:t}){const e={event:"#94a3b8"},n=dl(t),a=e[n.label]??n.color,s=t.text,i=new Date(t.timestamp),r=Number.isNaN(i.getTime())?"00:00:00":i.toLocaleTimeString("en-US",{hour12:!1});return o`
    <div class="journal-entry">
      <span class="journal-type" style="color: ${a}" title=${r}>${n.label}</span>
      <span class="journal-agent">${t.agent||"system"}</span>
      <span class="journal-data">${s}</span>
    </div>
  `}function vl(){const t=Ee.value;return o`
    <div class="section">
      <h2>Event Journal</h2>
      <div class="journal-list">
        ${t.length===0?o`<div class="empty-state">No events recorded yet</div>`:t.map((e,n)=>o`<${pl} key=${n} entry=${e} />`)}
      </div>
    </div>
  `}const ze=_("all"),Ue=_("all"),Gs=X(()=>{let t=Ve.value;return ze.value!=="all"&&(t=t.filter(e=>e.horizon===ze.value)),Ue.value!=="all"&&(t=t.filter(e=>e.status===Ue.value)),t}),ml=X(()=>{const t={short:[],mid:[],long:[]};for(const e of Gs.value){const n=t[e.horizon];n&&n.push(e)}return t});function fl(t){return"★".repeat(Math.min(t,5))+"☆".repeat(Math.max(0,5-t))}function ua(t){switch(t){case"short":return"Short-term";case"mid":return"Mid-term";case"long":return"Long-term";default:return t}}function Ae(t){switch(t){case"short":return"#4ade80";case"mid":return"#f59e0b";case"long":return"#818cf8";default:return"#888"}}function _l({goal:t}){return o`
    <div class="goal-row">
      <div class="goal-row-main">
        <div style="display:flex; align-items:center; gap:8px;">
          <span class="goal-horizon-badge" style="color:${Ae(t.horizon)}">
            ${ua(t.horizon)}
          </span>
          <span class="goal-title">${t.title}</span>
        </div>
        <div class="goal-meta">
          <span class="goal-priority" title="Priority ${t.priority}">${fl(t.priority)}</span>
          ${t.metric?o`<span class="goal-metric">${t.metric}${t.target_value?` → ${t.target_value}`:""}</span>`:null}
          ${t.due_date?o`<span class="goal-due">Due: <${F} timestamp=${t.due_date} /></span>`:null}
        </div>
        ${t.last_review_note?o`
          <div class="goal-review-note">${t.last_review_note}</div>
        `:null}
      </div>
      <div class="goal-row-right">
        <${Z} status=${t.status} />
        <div class="goal-updated">
          <${F} timestamp=${t.updated_at} />
        </div>
      </div>
    </div>
  `}function cn({horizon:t,items:e}){if(e.length===0)return null;const n=[...e].sort((a,s)=>s.priority-a.priority);return o`
    <${y} title="${ua(t)} Goals (${e.length})" class="section">
      <div class="goal-list">
        ${n.map(a=>o`<${_l} key=${a.id} goal=${a} />`)}
      </div>
    <//>
  `}function gl(){return o`
    <div class="goal-filters">
      <div class="goal-filter-group">
        <label class="goal-filter-label">Horizon</label>
        ${["all","short","mid","long"].map(t=>o`
          <button
            class="goal-filter-btn ${ze.value===t?"active":""}"
            onClick=${()=>{ze.value=t}}
          >
            ${t==="all"?"All":ua(t)}
          </button>
        `)}
      </div>
      <div class="goal-filter-group">
        <label class="goal-filter-label">Status</label>
        ${["all","active","completed","paused"].map(t=>o`
          <button
            class="goal-filter-btn ${Ue.value===t?"active":""}"
            onClick=${()=>{Ue.value=t}}
          >
            ${t==="all"?"All":t.charAt(0).toUpperCase()+t.slice(1)}
          </button>
        `)}
      </div>
    </div>
  `}function $l(){const t=Ve.value,e=t.filter(s=>s.status==="active").length,n=t.filter(s=>s.status==="completed").length,a={short:0,mid:0,long:0};for(const s of t)s.horizon in a&&a[s.horizon]++;return o`
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
        <div class="goal-summary-value" style="color:${Ae("short")}">${a.short}</div>
        <div class="goal-summary-label">Short</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${Ae("mid")}">${a.mid}</div>
        <div class="goal-summary-label">Mid</div>
      </div>
      <div class="goal-summary-item">
        <div class="goal-summary-value" style="color:${Ae("long")}">${a.long}</div>
        <div class="goal-summary-label">Long</div>
      </div>
    </div>
  `}function hl(){_t(()=>{Pe()},[]);const t=ml.value;return o`
    <div>
      <${y} title="Goals Overview" class="section">
        <${$l} />
        <${gl} />
        <div style="margin-top:8px;">
          <button class="control-btn ghost" onClick=${Pe} disabled=${Ut.value}>
            ${Ut.value?"Refreshing...":"Refresh"}
          </button>
        </div>
      <//>

      ${Ut.value&&Ve.value.length===0?o`<div class="loading-indicator">Loading goals...</div>`:Gs.value.length===0?o`<div class="empty-state">No goals match the current filters</div>`:o`
            <${cn} horizon="short" items=${t.short??[]} />
            <${cn} horizon="mid" items=${t.mid??[]} />
            <${cn} horizon="long" items=${t.long??[]} />
          `}
    </div>
  `}const St=_(""),un=_("ability_check"),dn=_("10"),pn=_("12"),$e=_(""),he=_("idle"),rt=_(""),ye=_("keeper-late"),vn=_("player"),mn=_(""),K=_("idle"),fn=_(null),be=_(""),_n=_(""),gn=_("player"),$n=_(""),hn=_(""),yn=_(""),Yt=_("20"),bn=_("20"),xn=_(""),xe=_("idle"),Vn=_(null),Vs=_("overview"),kn=_("all"),wn=_("all"),Sn=_("all"),yl=12e4,Qe=_(null),Ka=_(Date.now());function bl(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function xl(t,e){return e>0?Math.round(t/e*100):0}const kl={pragmatic:"리스크보다 확실한 이득을 우선합니다.",frugal:"자원 소모를 줄이고 효율을 챙깁니다.",impatient:"짧은 템포로 즉시 압박을 선호합니다.",stubborn:"한 번 정한 전술을 끝까지 밀어붙입니다.",protective:"아군 피해를 줄이는 선택을 우선합니다.","honor-bound":"약속과 규율을 지키는 행동에 보너스가 납니다.",intense:"집중 화력을 짧게 폭발시킵니다.",empathetic:"아군/약자 보호 쪽 선택 확률이 높아집니다.",fatalistic:"위험을 감수하는 고배수 선택을 탑니다.",suspicious:"함정/매복 경계 행동을 우선합니다.",precise:"단일 목표를 정확히 노리는 경향입니다.",vengeful:"직전 위협 대상에게 강하게 반응합니다.",aggressive:"공격적인 전진 행동을 우선합니다.",opportunistic:"빈틈이 열리면 즉시 추격합니다."},wl={supply_scan:"전장/자원 상태를 스캔해 약한 지점을 찾습니다.",ration_shift:"소모를 줄이고 지속 전투 능력을 확보합니다.",logistics_patch:"무너진 운영 라인을 빠르게 복구합니다.",frontline_shield:"전열에서 아군 피해를 흡수합니다.",oath_intercept:"핵심 타깃을 가로막아 위협을 차단합니다.",morale_anchor:"아군 안정도를 높여 붕괴를 막습니다.",omen_trace:"다음 위험 신호를 먼저 감지합니다.",arc_flash:"짧은 순간 광역 압박을 넣습니다.",ward_bloom:"방어 장막을 펼쳐 생존률을 올립니다.",mark_prey:"우선 제거 대상을 지정합니다.",silent_route:"은밀한 진입 경로를 확보합니다.",finisher_strike:"약화된 적을 마무리하는 일격입니다.",shadow_claw:"근접 급습으로 출혈 피해를 노립니다.",lunge:"짧은 돌진으로 전열을 흔듭니다."};function ke(t){const e=t.trim();return e?e.split(/[_-]+/g).filter(n=>n.length>0).map(n=>n[0]?`${n[0].toUpperCase()}${n.slice(1)}`:n).join(" "):t}function Sl(t){const e=t.trim().toLowerCase();return kl[e]??"행동 선택 가중치에 영향을 주는 성향입니다."}function Cl(t){const e=t.trim().toLowerCase();return wl[e]??"상황에 따라 선택되는 전술 액션입니다."}function ut(t){return typeof t=="object"&&t!==null}function H(t,e,n=""){const a=t[e];return typeof a=="string"?a:n}function tt(t,e,n=0){const a=t[e];return typeof a=="number"&&Number.isFinite(a)?a:n}function re(t,e,n=!1){const a=t[e];return typeof a=="boolean"?a:n}const Al=new Set(["str","dex","con","int","wis","cha"]);function Nl(t){const e=t.trim();if(!e)return{};let n;try{n=JSON.parse(e)}catch(s){throw new Error(`능력치 JSON 파싱 실패: ${s instanceof Error?s.message:"invalid json"}`)}if(!ut(n))throw new Error('능력치 JSON은 object여야 합니다. 예: {"luck":7}');const a={};return Object.entries(n).forEach(([s,i])=>{const r=s.trim();if(r){if(typeof i=="number"&&Number.isFinite(i)){a[r]=Math.max(0,Math.trunc(i));return}if(typeof i=="string"){const c=Number.parseFloat(i.trim());if(Number.isFinite(c)){a[r]=Math.max(0,Math.trunc(c));return}}throw new Error(`능력치 '${r}' 값은 숫자여야 합니다.`)}}),a}function Tl(t){const e=Number.parseInt(t.trim(),10);if(!Number.isFinite(e))return;const n=Math.max(1,e),a=Number.parseInt(Yt.value.trim(),10);Number.isFinite(a)&&a>n&&(Yt.value=String(n))}function Yn(t){const n=(t.actor_name??t.actor??t.actor_id??"system").trim();return n===""?"system":n}function Ll(t){var n;return(((n=t.timestamp)==null?void 0:n.trim())??"")||"-"}function Rl(t){Vs.value=t}function Ys(t){const e=Qe.value;return e==null||e<=t}function Dl(t){const e=Qe.value;return e==null||e<=t?0:Math.max(0,Math.ceil((e-t)/1e3))}function He(){Qe.value=null}function Qs(t){return typeof window>"u"||typeof window.confirm!="function"?!0:window.confirm(t)}function El(t,e){Qs(["관전 모드 잠금을 해제하시겠습니까?",`ROOM: ${t||"-"}`,`PHASE: ${e||"-"}`,"해제 시간: 120초 (시간 경과 또는 위험 액션 실행 후 자동 재잠금)"].join(`
`))&&(Qe.value=Date.now()+yl,b("조작 잠금이 120초 동안 해제되었습니다.","warning"))}function Ne(t){return Ys(t)?(b("관전 모드 잠금 상태입니다. 먼저 잠금을 해제하세요.","warning"),!1):!0}function Qn(t,e,n){return Qs([`[위험 액션 확인] ${t}`,`ROOM: ${e||"-"}`,`PHASE: ${n||"-"}`,"이 액션은 즉시 실행되며 되돌리기 어렵습니다.","계속 진행하시겠습니까?"].join(`
`))}function Il({hp:t,max:e}){const n=xl(t,e),a=bl(t,e);return o`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${a}" style="width:${n}%" />
    </div>
  `}function Pl({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return o`
    <div class="trpg-actor-stats">
      ${e.map(n=>o`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function Ml({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return o`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function Xs({actor:t}){var u,d,m,l;const e=(u=t.archetype)==null?void 0:u.trim(),n=(d=t.persona)==null?void 0:d.trim(),a=(m=t.portrait)==null?void 0:m.trim(),s=(l=t.background)==null?void 0:l.trim(),i=t.traits??[],r=t.skills??[],c=Object.entries(t.stats_raw??{}).filter(([p,v])=>Number.isFinite(v)).filter(([p])=>!Al.has(p.toLowerCase()));return o`
    <div class="trpg-actor">
      ${a?o`
          <div class="trpg-actor-portrait-wrap">
            <img
              class="trpg-actor-portrait"
              src=${a}
              alt=${`${t.name} portrait`}
              loading="lazy"
              onError=${p=>{const v=p.target;v&&(v.style.display="none")}}
            />
          </div>
        `:null}
      <div class="trpg-actor-header">
        <span class="trpg-actor-name">${t.name}</span>
        <${Z} status=${t.status??"idle"} />
        <span class="pill trpg-role-pill trpg-role-${t.role}">${t.role}</span>
        <${Ml} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?o`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?o`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${Il} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${Pl} stats=${t.stats} />
          </div>
        `:null}
      ${e?o`<div class="trpg-actor-meta">Archetype: ${ke(e)}</div>`:null}
      ${s?o`<div class="trpg-actor-meta">Background: ${s}</div>`:null}
      ${n?o`<div class="trpg-actor-persona">${n}</div>`:null}
      ${c.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Custom Stats</div>
            <div class="trpg-custom-stats">
              ${c.map(([p,v])=>o`
                <span class="trpg-custom-stat-chip">${ke(p)} ${v}</span>
              `)}
            </div>
          </div>
        `:null}
      ${i.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Traits</div>
            <div class="trpg-annot-list">
              ${i.map(p=>o`
                <span class="trpg-annot-chip trait">
                  <span class="trpg-annot-name">${ke(p)}</span>
                  <span class="trpg-annot-desc">${Sl(p)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
      ${r.length>0?o`
          <div class="trpg-annot-group">
            <div class="trpg-annot-title">Skills</div>
            <div class="trpg-annot-list">
              ${r.map(p=>o`
                <span class="trpg-annot-chip skill">
                  <span class="trpg-annot-name">${ke(p)}</span>
                  <span class="trpg-annot-desc">${Cl(p)}</span>
                </span>
              `)}
            </div>
          </div>
        `:null}
    </div>
  `}function jl({mapStr:t}){return o`<pre class="trpg-map">${t}</pre>`}function Zs({events:t,emptyLabel:e="아직 이벤트가 없습니다."}){return t.length===0?o`<div class="empty-state" style="font-size:13px">${e}</div>`:o`
    <div class="trpg-story" role="list" aria-label="TRPG story events">
      ${t.map((n,a)=>{var s;return o`
        <div key=${a} class="trpg-event ${n.type??""}" role="listitem">
          <div class="trpg-event-meta-row">
            <span class="trpg-event-meta">${Ll(n)}</span>
            <span class="trpg-event-meta">${n.phase??"phase:-"}</span>
            <span class="trpg-event-meta">${n.type??"type:-"}</span>
          </div>
          <div class="trpg-event-main">
            <strong>${Yn(n)}</strong>
            ${" "}
          ${n.dice_roll?o`<span class="trpg-dice">[${n.dice_roll.notation}: ${(s=n.dice_roll.rolls)==null?void 0:s.join(",")} = ${n.dice_roll.total}${n.dice_roll.modifier?` +${n.dice_roll.modifier}`:""}]</span>${" "}`:null}
            <span class="trpg-event-text">${n.content??""}</span>
            <span class="trpg-event-ts"><${F} timestamp=${n.timestamp} /></span>
          </div>
        </div>
      `})}
    </div>
  `}function Ol({events:t}){const e="__none__",n=kn.value,a=wn.value,s=Sn.value,i=Array.from(new Set(t.map(Yn).map(l=>l.trim()).filter(l=>l!==""))).sort((l,p)=>l.localeCompare(p)),r=Array.from(new Set(t.map(l=>(l.type??"").trim()).filter(l=>l!==""))).sort((l,p)=>l.localeCompare(p)),c=t.some(l=>(l.type??"").trim()===""),u=Array.from(new Set(t.map(l=>(l.phase??"").trim()).filter(l=>l!==""))).sort((l,p)=>l.localeCompare(p)),d=t.some(l=>(l.phase??"").trim()===""),m=t.filter(l=>{if(n!=="all"&&Yn(l)!==n)return!1;const p=(l.type??"").trim(),v=(l.phase??"").trim();if(a===e){if(p!=="")return!1}else if(a!=="all"&&p!==a)return!1;if(s===e){if(v!=="")return!1}else if(s!=="all"&&v!==s)return!1;return!0});return o`
    <div class="trpg-story-toolbar">
      <div class="trpg-story-filter">
        <label>Actor</label>
        <select value=${n} onChange=${l=>{kn.value=l.target.value}}>
          <option value="all">all</option>
          ${i.map(l=>o`<option value=${l}>${l}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Type</label>
        <select value=${a} onChange=${l=>{wn.value=l.target.value}}>
          <option value="all">all</option>
          ${c?o`<option value=${e}>(none)</option>`:null}
          ${r.map(l=>o`<option value=${l}>${l}</option>`)}
        </select>
      </div>
      <div class="trpg-story-filter">
        <label>Phase</label>
        <select value=${s} onChange=${l=>{Sn.value=l.target.value}}>
          <option value="all">all</option>
          ${d?o`<option value=${e}>(none)</option>`:null}
          ${u.map(l=>o`<option value=${l}>${l}</option>`)}
        </select>
      </div>
      <button
        class="trpg-run-btn secondary"
        style="align-self:flex-end;"
        onClick=${()=>{kn.value="all",wn.value="all",Sn.value="all"}}
      >
        필터 초기화
      </button>
      <span style="margin-left:auto; font-size:11px; color:#9ca3af; align-self:flex-end;">
        표시 ${m.length} / 전체 ${t.length}
      </span>
    </div>
    <${Zs} events=${m.slice(-120)} emptyLabel="필터 조건에 맞는 이벤트가 없습니다." />
  `}function Fl({outcome:t}){if(!t)return null;const e=i=>{const r=i.trim();return r&&(/[A-Z]/.test(r)&&!r.includes(" ")?r.replace(/([a-z0-9])([A-Z])/g,"$1 $2").replace(/[_\.]/g," ").replace(/\s+/g," ").trim():r.replace(/[_\.]/g," ").replace(/\s+/g," ").trim())},n=t.result==="victory"?"승리":t.result==="defeat"?"패배":t.result==="draw"?"무승부":"종료",a=t.result==="victory"?"#34d399":t.result==="defeat"?"#f87171":"#9ca3af",s=[t.reason?`원인: ${e(t.reason)}`:null,t.phase?`페이즈: ${e(t.phase)}`:null,typeof t.turn=="number"?`턴: ${t.turn}`:null].filter(Boolean).join(" · ");return o`
    <div style="margin-bottom:16px; padding:10px 12px; border:1px solid rgba(255,255,255,0.12); border-radius:10px; background:rgba(255,255,255,0.03);">
      <div style="font-size:12px; color:#9ca3af; text-transform:uppercase; letter-spacing:0.08em;">Session Outcome</div>
      <div style="font-size:18px; font-weight:700; color:${a}; margin-top:4px;">${n}</div>
      ${t.summary?o`<div style="margin-top:4px; font-size:13px; color:#d1d5db;">${e(t.summary)}</div>`:null}
      ${s?o`<div style="margin-top:4px; font-size:11px; color:#9ca3af;">${s}</div>`:null}
    </div>
  `}function ti({state:t}){const e=t.history??[];return e.length===0?null:o`
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
  `}function zl({state:t,nowMs:e}){var d;const n=it.value||((d=t.session)==null?void 0:d.room)||"",a=he.value,s=t.party??[];if(!s.find(m=>m.id===St.value)&&s.length>0){const m=s[0];m&&(St.value=m.id)}const r=async()=>{var l,p;if(!n){b("Room ID가 비어 있습니다.","error");return}if(!Ne(e))return;const m=((l=t.current_round)==null?void 0:l.phase)??((p=t.session)==null?void 0:p.status)??"unknown";if(Qn("라운드 실행",n,m)){he.value="running";try{const v=await Co(n);Vn.value=v,he.value="ok";const g=ut(v.summary)?v.summary:null,x=g?re(g,"advanced",!1):!1,C=g?H(g,"progress_reason",""):"";b(x?"라운드가 정상 진행되었습니다.":`라운드가 정체되었습니다${C?`: ${C}`:""}`,x?"success":"warning"),ot()}catch(v){Vn.value=null,he.value="error";const g=v instanceof Error?v.message:"라운드 실행에 실패했습니다.";b(g,"error")}finally{He()}}},c=async()=>{var l,p;if(!n||!Ne(e))return;const m=((l=t.current_round)==null?void 0:l.phase)??((p=t.session)==null?void 0:p.status)??"unknown";if(Qn("턴 강제 진행",n,m))try{await To(n),b("턴을 다음 단계로 이동했습니다.","success"),ot()}catch{b("턴 이동에 실패했습니다.","error")}finally{He()}},u=async()=>{if(!n||!Ne(e))return;const m=St.value.trim();if(!m){b("먼저 Actor를 선택하세요.","warning");return}const l=Number.parseInt(dn.value,10),p=Number.parseInt(pn.value,10);if(Number.isNaN(l)||Number.isNaN(p)){b("stat/dc는 숫자여야 합니다.","warning");return}const v=Number.parseInt($e.value,10),g=$e.value.trim()===""||Number.isNaN(v)?void 0:v;try{await No({roomId:n,actorId:m,action:un.value.trim()||"ability_check",statValue:l,dc:p,rawD20:g}),b("주사위 판정을 기록했습니다.","success"),ot()}catch{b("주사위 판정 기록에 실패했습니다.","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            id="trpg-room-input"
            name="trpg-room-input"
            type="text"
            value=${n}
            onInput=${m=>{it.value=m.target.value}}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${St.value}
            onChange=${m=>{St.value=m.target.value}}
          >
            <option value="">Actor 선택</option>
            ${s.map(m=>o`<option value=${m.id}>${m.name} (${m.id})</option>`)}
          </select>
        </div>

        <div class="trpg-control-field">
          <label>Dice</label>
          <div style="display:grid; grid-template-columns: 1fr 1fr; gap:6px;">
            <input
              id="trpg-dice-action-input"
              name="trpg-dice-action-input"
              type="text"
              value=${un.value}
              onInput=${m=>{un.value=m.target.value}}
              placeholder="action"
            />
            <input
              id="trpg-dice-stat-input"
              name="trpg-dice-stat-input"
              type="text"
              value=${dn.value}
              onInput=${m=>{dn.value=m.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              id="trpg-dice-dc-input"
              name="trpg-dice-dc-input"
              type="text"
              value=${pn.value}
              onInput=${m=>{pn.value=m.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              id="trpg-dice-raw-input"
              name="trpg-dice-raw-input"
              type="text"
              value=${$e.value}
              onInput=${m=>{$e.value=m.target.value}}
              onKeyDown=${m=>{m.key==="Enter"&&u()}}
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
              disabled=${a==="running"}
            >
              ${a==="running"?"실행 중...":"Run Round"}
            </button>
            <button class="trpg-run-btn secondary" onClick=${c}>
              Next Turn
            </button>
          </div>
        </div>
      </div>

      ${a!=="idle"?o`<div class="trpg-run-status ${a}">${a==="running"?"처리 중...":a==="ok"?"완료":"실패"}</div>`:null}
    </div>
  `}function Ul({state:t}){var s;const e=it.value||((s=t.session)==null?void 0:s.room)||"",n=xe.value,a=async()=>{if(!e){b("Room ID가 비어 있습니다.","warning");return}const i=be.value.trim(),r=_n.value.trim();if(!r&&!i){b("이름 또는 Actor ID를 입력하세요.","warning");return}const c=Number.parseInt(Yt.value.trim(),10),u=Number.parseInt(bn.value.trim(),10),d=Number.isFinite(u)?Math.max(1,u):20,m=Number.isFinite(c)?Math.max(0,Math.min(d,c)):d;let l={};try{l=Nl(xn.value)}catch(p){b(p instanceof Error?p.message:"능력치 JSON 오류","error");return}xe.value="spawning";try{const p=typeof crypto<"u"&&typeof crypto.randomUUID=="function"?`trpg_spawn_${crypto.randomUUID()}`:`trpg_spawn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,v=await Lo(e,{actor_id:i||void 0,name:r||void 0,role:gn.value,idempotencyKey:p,portrait:hn.value.trim()||void 0,background:yn.value.trim()||void 0,hp:m,max_hp:d,alive:m>0,stats:Object.keys(l).length>0?l:void 0}),g=typeof v.actor_id=="string"?v.actor_id.trim():"";if(!g)throw new Error("생성 응답에 actor_id가 없습니다.");const x=$n.value.trim();x&&await Ro(e,g,x),St.value=g,rt.value=g,i||(be.value=""),xe.value="ok",b(`Actor 생성 완료: ${g}`,"success"),await ot()}catch(p){xe.value="error",b(p instanceof Error?p.message:"Actor 생성에 실패했습니다.","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Name</label>
          <input
            id="trpg-spawn-name-input"
            name="trpg-spawn-name-input"
            type="text"
            value=${_n.value}
            onInput=${i=>{_n.value=i.target.value}}
            placeholder="Night Fox"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${gn.value}
            onChange=${i=>{gn.value=i.target.value}}
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
            value=${$n.value}
            onInput=${i=>{$n.value=i.target.value}}
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
              value=${be.value}
              onInput=${i=>{be.value=i.target.value}}
              placeholder="auto when blank"
            />
          </div>
          <div class="trpg-control-field">
            <label>Portrait URL</label>
            <input
              id="trpg-spawn-portrait-input"
              name="trpg-spawn-portrait-input"
              type="text"
              value=${hn.value}
              onInput=${i=>{hn.value=i.target.value}}
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
              value=${Yt.value}
              onInput=${i=>{Yt.value=i.target.value}}
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
              value=${bn.value}
              onInput=${i=>{const r=i.target.value;bn.value=r,Tl(r)}}
              placeholder="20"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Background</label>
            <input
              id="trpg-spawn-background-input"
              name="trpg-spawn-background-input"
              type="text"
              value=${yn.value}
              onInput=${i=>{yn.value=i.target.value}}
              placeholder="망명 기사 · 폐허 수색 전문가"
            />
          </div>
          <div class="trpg-control-field" style="grid-column:1 / -1;">
            <label>Stats JSON</label>
            <input
              id="trpg-spawn-stats-json-input"
              name="trpg-spawn-stats-json-input"
              type="text"
              value=${xn.value}
              onInput=${i=>{xn.value=i.target.value}}
              placeholder='{"luck":7,"stealth":12,"str":10}'
            />
          </div>
        </div>
      </details>

      ${n!=="idle"?o`<div class="trpg-run-status ${n==="spawning"?"running":n}">${n==="spawning"?"생성 중...":n==="ok"?"생성 완료":"생성 실패"}</div>`:null}
    </div>
  `}function Hl({state:t,nowMs:e}){var p;const n=it.value||((p=t.session)==null?void 0:p.room)||"",a=t.join_gate,s=fn.value,i=ut(s)?s:null,r=(t.party??[]).filter(v=>v.role!=="dm"),c=rt.value.trim(),u=r.some(v=>v.id===c),d=u?c:c?"__manual__":"",m=async()=>{const v=rt.value.trim(),g=ye.value.trim();if(!n||!v){b("Room/Actor가 필요합니다.","warning");return}K.value="checking";try{const x=await Do(n,v,g||void 0);fn.value=x,K.value="ok",b("참가 가능 여부를 갱신했습니다.","success")}catch(x){K.value="error";const C=x instanceof Error?x.message:"참가 가능 여부 확인에 실패했습니다.";b(C,"error")}},l=async()=>{var N,A;const v=rt.value.trim(),g=ye.value.trim(),x=mn.value.trim();if(!n||!v||!g){b("Room/Actor/Keeper가 필요합니다.","warning");return}if(!Ne(e))return;const C=((N=t.current_round)==null?void 0:N.phase)??((A=t.session)==null?void 0:A.status)??"unknown";if(Qn("Mid-Join 승인 요청",n,C)){K.value="requesting";try{const E=await Eo({room_id:n,actor_id:v,keeper_name:g,role:vn.value,...x?{name:x}:{}});fn.value=E;const O=ut(E)?re(E,"granted",!1):!1,D=ut(E)?H(E,"reason_code",""):"";O?b("Mid-Join이 승인되었습니다.","success"):b(`Mid-Join이 거절되었습니다${D?`: ${D}`:""}`,"warning"),K.value=O?"ok":"error",ot()}catch(E){K.value="error";const O=E instanceof Error?E.message:"Mid-Join 요청에 실패했습니다.";b(O,"error")}finally{He()}}};return o`
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
            value=${d}
            onChange=${v=>{const g=v.target.value;if(g==="__manual__"){(u||!c)&&(rt.value="");return}rt.value=g}}
          >
            <option value="">Actor 선택</option>
            ${r.map(v=>o`
              <option value=${v.id}>${v.name} (${v.id})</option>
            `)}
            <option value="__manual__">직접 입력</option>
          </select>
          ${d==="__manual__"?o`
              <input
                id="trpg-join-actor-input"
                name="trpg-join-actor-input"
                type="text"
                value=${rt.value}
                onInput=${v=>{rt.value=v.target.value}}
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
            value=${ye.value}
            onInput=${v=>{ye.value=v.target.value}}
            placeholder="keeper-name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Role</label>
          <select
            value=${vn.value}
            onChange=${v=>{vn.value=v.target.value}}
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
            value=${mn.value}
            onInput=${v=>{mn.value=v.target.value}}
            placeholder="display name"
          />
        </div>
        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:6px;">
            <button class="trpg-run-btn secondary" onClick=${m} disabled=${K.value==="checking"||K.value==="requesting"}>
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
            Eligible: <strong>${re(i,"eligible",!1)?"YES":"NO"}</strong>
            <span style="margin-left:8px;">Score ${tt(i,"effective_score",0)}/${tt(i,"required_points",0)}</span>
            ${H(i,"reason_code","")?o`<span style="margin-left:8px;">Reason: ${H(i,"reason_code","")}</span>`:null}
          </div>
        `:null}
    </div>
  `}function ei({state:t}){const e=[...t.contribution_ledger??[]].sort((n,a)=>(a.score??0)-(n.score??0)).slice(0,8);return e.length===0?o`<div class="empty-state" style="font-size:13px;">No contribution data yet</div>`:o`
    <div class="trpg-round-list">
      ${e.map(n=>o`
        <div class="trpg-round-item active">
          <span>${n.actor_id}</span>
          <span style="margin-left:auto; font-size:11px;">score ${n.score}</span>
          ${n.last_reason?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:4px;">${n.last_reason}</div>`:null}
        </div>
      `)}
    </div>
  `}function ni({state:t}){var n;const e=t.current_round;return e?o`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?o`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function ai(){const t=Vn.value;if(!t)return o`<div class="empty-state" style="font-size:13px;">Run Round 결과가 아직 없습니다.</div>`;const e=t.summary,n=ut(e)?e:null,s=(Array.isArray(t.statuses)?t.statuses:[]).filter(ut).slice(-8),i=t.canon_check,r=ut(i)?i:null,c=r&&Array.isArray(r.warnings)?r.warnings.filter(D=>typeof D=="string").slice(0,3):[],u=r&&Array.isArray(r.violations)?r.violations.filter(D=>typeof D=="string").slice(0,3):[],d=n?re(n,"advanced",!1):!1,m=n?H(n,"progress_reason",""):"",l=n?H(n,"progress_detail",""):"",p=n?tt(n,"player_successes",0):0,v=n?tt(n,"player_required_successes",0):0,g=n?re(n,"dm_success",!1):!1,x=n?tt(n,"timeouts",0):0,C=n?tt(n,"unavailable",0):0,N=n?tt(n,"reprompts",0):0,A=n?tt(n,"npc_attacks",0):0,E=n?tt(n,"keeper_timeout_sec",0):0,O=n?tt(n,"roll_audit_count",0):0;return o`
    <div style="display:grid; gap:10px;">
      <div class="trpg-round-item ${d?"active":"failed"}" style="display:block;">
        <div style="display:flex; align-items:center; gap:8px;">
          <strong>${d?"ADVANCED":"STALLED"}</strong>
          <span style="font-size:11px; color:#9ca3af;">
            turn ${t.turn_before??0} → ${t.turn_after??0}
          </span>
          <span style="margin-left:auto; font-size:11px; color:#9ca3af;">
            ${g?"DM ok":"DM stalled"} / players ${p}/${v}
          </span>
        </div>
        ${m?o`<div style="margin-top:4px; font-size:12px;">${m}</div>`:null}
        ${l?o`<div style="margin-top:2px; font-size:11px; color:#9ca3af;">${l}</div>`:null}
      </div>

      <div class="stats-grid" style="grid-template-columns:repeat(4, minmax(0, 1fr)); gap:8px;">
        <div class="stat-card"><div class="stat-label">Timeouts</div><div class="stat-value">${x}</div></div>
        <div class="stat-card"><div class="stat-label">Unavailable</div><div class="stat-value">${C}</div></div>
        <div class="stat-card"><div class="stat-label">Reprompts</div><div class="stat-value">${N}</div></div>
        <div class="stat-card"><div class="stat-label">NPC Attacks</div><div class="stat-value">${A}</div></div>
        <div class="stat-card"><div class="stat-label">Keeper Timeout</div><div class="stat-value">${E||0}s</div></div>
        <div class="stat-card"><div class="stat-label">Roll Audit</div><div class="stat-value">${O}</div></div>
      </div>

      ${s.length>0?o`
          <div class="trpg-round-list">
            ${s.map(D=>{const q=H(D,"status","unknown"),pt=H(D,"actor_id","-"),vt=H(D,"role","-"),W=H(D,"reason",""),at=H(D,"action_type",""),L=H(D,"reply","");return o`
                <div class="trpg-round-item ${q.includes("fallback")||q.includes("timeout")?"failed":"active"}">
                  <span>${pt} (${vt})</span>
                  <span style="margin-left:auto; font-size:11px;">${q}</span>
                  ${at?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">action: ${at}</div>`:null}
                  ${W?o`<div style="width:100%; font-size:11px; color:#9ca3af; margin-top:2px;">reason: ${W}</div>`:null}
                  ${L?o`<div style="width:100%; font-size:11px; color:#d1d5db; margin-top:2px;">${L.slice(0,120)}</div>`:null}
                </div>
              `})}
          </div>`:null}

      ${r?o`
          <div class="trpg-control-box">
            <div style="font-size:12px; color:#9ca3af;">
              Canon status: <strong>${H(r,"status","unknown")}</strong>
            </div>
            ${u.length>0?o`
                <div style="margin-top:6px; font-size:11px; color:#fca5a5;">
                  ${u.map(D=>o`<div>violation: ${D}</div>`)}
                </div>`:null}
            ${c.length>0?o`
                <div style="margin-top:6px; font-size:11px; color:#fbbf24;">
                  ${c.map(D=>o`<div>warning: ${D}</div>`)}
                </div>`:null}
          </div>
        `:null}
    </div>
  `}function Bl({state:t,nowMs:e}){var r,c,u;const n=it.value||((r=t.session)==null?void 0:r.room)||"",a=((c=t.current_round)==null?void 0:c.phase)??((u=t.session)==null?void 0:u.status)??"unknown",s=Ys(e),i=Dl(e);return o`
    <${y} title="조작 안전 잠금" style="margin-bottom:16px;">
      <div class="trpg-control-lock ${s?"locked":"unlocked"}">
        <div class="trpg-control-lock-title">
          ${s?"잠금 상태: 관전 전용":"잠금 해제됨"}
        </div>
        <div class="trpg-control-lock-desc">
          ${s?"조작 액션은 실행되지 않습니다. 필요할 때만 잠금을 해제하세요.":`위험 액션 실행 또는 ${i}초 후 자동으로 다시 잠깁니다.`}
        </div>
        <div class="trpg-control-lock-meta">room: ${n||"-"} · phase: ${a||"-"}</div>
        <div style="display:flex; gap:8px; margin-top:10px; flex-wrap:wrap;">
          ${s?o`<button class="trpg-run-btn recommend" onClick=${()=>El(n,a)}>잠금 해제 (120초)</button>`:o`<button class="trpg-run-btn secondary" onClick=${()=>{He(),b("조작 잠금으로 전환했습니다.","success")}}>즉시 다시 잠금</button>`}
        </div>
      </div>
    <//>
  `}function Kl({active:t}){return o`
    <div class="trpg-screen-tabs" role="tablist" aria-label="TRPG 화면 선택">
      ${[{id:"overview",label:"Overview",desc:"관전 요약"},{id:"timeline",label:"Timeline",desc:"이벤트 흐름"},{id:"control",label:"Control",desc:"운영/개입"}].map(n=>o`
        <button
          class="trpg-screen-tab ${t===n.id?"active":""}"
          role="tab"
          aria-selected=${t===n.id}
          onClick=${()=>Rl(n.id)}
        >
          <span class="trpg-screen-tab-label">${n.label}</span>
          <span class="trpg-screen-tab-desc">${n.desc}</span>
        </button>
      `)}
    </div>
  `}function ql({state:t}){const e=t.party??[],n=t.story_log??[];return o`
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
          <${Zs} events=${n.slice(-20)} />
        <//>

        ${t.map?o`
            <${y} title="맵" style="margin-top:16px;">
              <${jl} mapStr=${t.map} />
            <//>
          `:null}
      </div>

      <div class="trpg-sidebar">
        <${y} title="현재 라운드">
          <${ni} state=${t} />
        <//>

        <${y} title="기여도" style="margin-top:16px;">
          <${ei} state=${t} />
        <//>

        <${y} title=${`파티 (${e.length})`} style="margin-top:16px;">
          <div class="trpg-actor-list">
            ${e.map(a=>o`<${Xs} key=${a.id??a.name} actor=${a} />`)}
            ${e.length===0?o`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
          </div>
        <//>

        ${t.history&&t.history.length>0?o`
            <${y} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
              <${ti} state=${t} />
            <//>
          `:null}
      </div>
    </div>
  `}function Wl({state:t}){const e=t.story_log??[];return o`
    <div class="trpg-layout">
      <div>
        <${y} title=${`이벤트 타임라인 (${e.length})`}>
          <${Ol} events=${e} />
        <//>
      </div>

      <div class="trpg-sidebar">
        <${y} title="최근 라운드 결과">
          <${ai} />
        <//>

        <${y} title="현재 라운드" style="margin-top:16px;">
          <${ni} state=${t} />
        <//>
      </div>
    </div>
  `}function Jl({state:t,nowMs:e}){const n=t.party??[];return o`
    <div>
      <${Bl} state=${t} nowMs=${e} />
      <div class="trpg-layout">
        <div>
          <${y} title="조작 패널">
            <${zl} state=${t} nowMs=${e} />
          <//>

          <${y} title="Actor Spawn" style="margin-top:16px;">
            <${Ul} state=${t} />
          <//>

          <${y} title="Mid-Join Gate" style="margin-top:16px;">
            <${Hl} state=${t} nowMs=${e} />
          <//>

          <${y} title="최근 라운드 결과" style="margin-top:16px;">
            <${ai} />
          <//>
        </div>

        <div class="trpg-sidebar">
          <${y} title="기여도" style="margin-top:0;">
            <${ei} state=${t} />
          <//>

          <${y} title=${`파티 (${n.length})`} style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(a=>o`<${Xs} key=${a.id??a.name} actor=${a} />`)}
              ${n.length===0?o`<div class="empty-state" style="font-size:13px">등록된 actor가 없습니다.</div>`:null}
            </div>
          <//>

          ${t.history&&t.history.length>0?o`
              <${y} title=${`히스토리 (${t.history.length})`} style="margin-top:16px;">
                <${ti} state=${t} />
              <//>
            `:null}
        </div>
      </div>
    </div>
  `}function Gl(){var c,u,d,m,l;const t=Os.value,e=Un.value;if(_t(()=>{if(typeof window>"u"||typeof window.setInterval!="function")return;const p=window.setInterval(()=>{Ka.value=Date.now()},1e3);return()=>{window.clearInterval(p)}},[]),e&&!t)return o`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return o`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>ot()}>Refresh</button>
      </div>
    `;const n=t.party??[],a=t.story_log??[],s=t.outcome,i=Vs.value,r=Ka.value;return o`
    <div>
      <div style="display:flex; gap:8px; align-items:center; justify-content:space-between; margin-bottom:8px;">
        <div style="font-size:11px; color:#8ea9d6;">
          room: ${it.value||((c=t.session)==null?void 0:c.room)||"-"} · phase: ${((u=t.current_round)==null?void 0:u.phase)??((d=t.session)==null?void 0:d.status)??"-"}
        </div>
        <button class="trpg-run-btn secondary" onClick=${()=>ot()}>새로고침</button>
      </div>

      <${Fl} outcome=${s} />

      <div class="stats-grid" style="margin-bottom:16px;">
        <div class="stat-card">
          <div class="stat-label">Session</div>
          <div class="stat-value" style="font-size:16px;">${((m=t.session)==null?void 0:m.status)??"active"}</div>
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

      <${Kl} active=${i} />

      ${i==="overview"?o`<${ql} state=${t} />`:i==="timeline"?o`<${Wl} state=${t} />`:o`<${Jl} state=${t} nowMs=${r} />`}
    </div>
  `}const Vl=X(()=>{const t=Array.from(V.value.values());return t.sort((e,n)=>e.status==="running"&&n.status!=="running"?-1:n.status==="running"&&e.status!=="running"?1:n.elapsed_seconds-e.elapsed_seconds),t}),Yl=X(()=>Array.from(V.value.values()).filter(t=>t.status==="running").length),Ql=X(()=>Array.from(V.value.values()).filter(t=>t.status==="completed").length);function Cn(t){switch(t){case"running":return"#fbbf24";case"completed":return"#4ade80";case"stopped":return"#94a3b8";case"error":return"#fb7185";default:return"#888"}}function si(t){return`${t>=0?"+":""}${t.toFixed(4)}`}function Xl(t){return t<60?`${Math.round(t)}s`:t<3600?`${Math.floor(t/60)}m ${Math.round(t%60)}s`:`${Math.floor(t/3600)}h ${Math.floor(t%3600/60)}m`}function Zl({history:t}){if(t.length===0)return o`<span class="mdal-spark-empty">No iterations yet</span>`;const n=[...t].reverse().map(u=>u.metric_after),a=Math.min(...n),i=Math.max(...n)-a||1,r="▁▂▃▄▅▆▇█",c=n.map(u=>{const d=Math.min(Math.floor((u-a)/i*7),7);return r[d]}).join("");return o`
    <span class="mdal-spark" title="Metric progression (${n.length} iterations)">
      ${c}
    </span>
  `}function tc({record:t}){const e=t.delta>0?"positive":t.delta<0?"negative":"neutral";return o`
    <div class="mdal-iter-row">
      <span class="mdal-iter-num">#${t.iteration}</span>
      <span class="mdal-iter-metric">${t.metric_before.toFixed(4)}</span>
      <span class="mdal-iter-arrow">\u2192</span>
      <span class="mdal-iter-metric">${t.metric_after.toFixed(4)}</span>
      <span class="mdal-iter-delta ${e}">${si(t.delta)}</span>
      <span class="mdal-iter-time">${t.elapsed_ms}ms</span>
    </div>
  `}function ec({loop:t}){const e=t.current_metric-t.baseline_metric;return o`
    <${y} title=${`${t.loop_id}`} class="mdal-loop-card">
      <div class="mdal-loop-header">
        <div class="mdal-loop-badges">
          <${Z} status=${t.status} />
          <span class="mdal-profile-badge">${t.profile}</span>
        </div>
        <span class="mdal-loop-target" title="Target">${t.target}</span>
      </div>

      <div class="mdal-loop-metrics">
        <div class="mdal-metric-pair">
          <span class="mdal-metric-label">Baseline</span>
          <span class="mdal-metric-value">${t.baseline_metric.toFixed(4)}</span>
        </div>
        <div class="mdal-metric-pair">
          <span class="mdal-metric-label">Current</span>
          <span class="mdal-metric-value">${t.current_metric.toFixed(4)}</span>
        </div>
        <div class="mdal-metric-pair">
          <span class="mdal-metric-label">Total Delta</span>
          <span class="mdal-metric-value ${e>=0?"positive":"negative"}">
            ${si(e)}
          </span>
        </div>
        <div class="mdal-metric-pair">
          <span class="mdal-metric-label">Iteration</span>
          <span class="mdal-metric-value">
            ${t.current_iteration}${t.max_iterations>0?`/${t.max_iterations}`:""}
          </span>
        </div>
        <div class="mdal-metric-pair">
          <span class="mdal-metric-label">Stagnation</span>
          <span class="mdal-metric-value">
            ${t.stagnation_streak}${t.stagnation_limit>0?`/${t.stagnation_limit}`:""}
          </span>
        </div>
        <div class="mdal-metric-pair">
          <span class="mdal-metric-label">Elapsed</span>
          <span class="mdal-metric-value">${Xl(t.elapsed_seconds)}</span>
        </div>
      </div>

      <div class="mdal-spark-section">
        <span class="mdal-metric-label">Progress</span>
        <${Zl} history=${t.history} />
      </div>

      ${t.history.length>0?o`
        <details class="mdal-history-details">
          <summary>Iteration History (${t.history.length})</summary>
          <div class="mdal-iter-list">
            ${t.history.map(n=>o`<${tc} key=${n.iteration} record=${n} />`)}
          </div>
        </details>
      `:null}
    <//>
  `}function nc(){const t=Vl.value,e=Yl.value,n=Ql.value,a=t.filter(s=>s.status==="stopped").length;return o`
    <style>
      .mdal-loop-card { margin-bottom: 12px; }
      .mdal-loop-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 8px; flex-wrap: wrap; gap: 4px; }
      .mdal-loop-badges { display: flex; gap: 6px; align-items: center; }
      .mdal-profile-badge { background: #334155; color: #e2e8f0; padding: 2px 8px; border-radius: 4px; font-size: 12px; }
      .mdal-loop-target { color: #94a3b8; font-size: 13px; }
      .mdal-loop-metrics { display: grid; grid-template-columns: repeat(auto-fill, minmax(130px, 1fr)); gap: 8px; margin: 8px 0; }
      .mdal-metric-pair { display: flex; flex-direction: column; }
      .mdal-metric-label { font-size: 11px; color: #64748b; text-transform: uppercase; letter-spacing: 0.5px; }
      .mdal-metric-value { font-size: 16px; font-weight: 600; font-variant-numeric: tabular-nums; }
      .mdal-metric-value.positive { color: #4ade80; }
      .mdal-metric-value.negative { color: #fb7185; }
      .mdal-spark-section { margin: 8px 0; }
      .mdal-spark { font-family: monospace; font-size: 18px; letter-spacing: 1px; color: #38bdf8; }
      .mdal-spark-empty { color: #64748b; font-size: 13px; }
      .mdal-history-details { margin-top: 8px; }
      .mdal-history-details summary { cursor: pointer; color: #94a3b8; font-size: 13px; }
      .mdal-iter-list { margin-top: 6px; }
      .mdal-iter-row { display: flex; gap: 8px; align-items: center; padding: 3px 0; font-size: 13px; font-variant-numeric: tabular-nums; border-bottom: 1px solid #1e293b; }
      .mdal-iter-num { color: #64748b; min-width: 28px; }
      .mdal-iter-metric { color: #e2e8f0; min-width: 60px; text-align: right; }
      .mdal-iter-arrow { color: #475569; }
      .mdal-iter-delta { min-width: 70px; text-align: right; font-weight: 600; }
      .mdal-iter-delta.positive { color: #4ade80; }
      .mdal-iter-delta.negative { color: #fb7185; }
      .mdal-iter-delta.neutral { color: #94a3b8; }
      .mdal-iter-time { color: #64748b; margin-left: auto; }
    </style>

    <div class="stats-grid">
      <div class="stat-card">
        <div class="stat-label">Running</div>
        <div class="stat-value" style="color:${Cn("running")}">${e}</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">Completed</div>
        <div class="stat-value" style="color:${Cn("completed")}">${n}</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">Stopped</div>
        <div class="stat-value" style="color:${Cn("stopped")}">${a}</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">Total Loops</div>
        <div class="stat-value">${t.length}</div>
      </div>
    </div>

    <div class="council-grid">
      ${t.length===0?o`
          <${y} title="MDAL Loops" class="section">
            <div class="empty-state">
              No MDAL loops active. Start one with <code>masc_mdal_start</code>.
            </div>
          <//>
        `:t.map(s=>o`<${ec} key=${s.loop_id} loop=${s} />`)}
    </div>
  `}const da="masc_dashboard_agent_name";function ac(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem(da);return e??n??"dashboard"}const Q=_(ac()),Qt=_(""),Xt=_(""),Be=_(""),Zt=_(!1),Ct=_(!1),te=_(!1),ee=_(!1),Ke=_(!1),Xe=_(!1);function pa(t){const e=t.trim();Q.value=e,e&&localStorage.setItem(da,e)}function sc(t){const n=(t.split(`
`).find(a=>a.includes(" joined"))??t).match(/✅\s+(\S+)\s+joined/i);return(n==null?void 0:n[1])??null}async function Xn(){const t=Q.value.trim();if(t){te.value=!0;try{const e=await Po(t),n=sc(e);n&&pa(n),Xe.value=!0,b(`Joined as ${n??t}`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to join room";b(n,"error")}finally{te.value=!1}}}async function ic(){const t=Q.value.trim();if(t){ee.value=!0;try{await Ps(t),Xe.value=!1,b(`Left room (${t})`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to leave room";b(n,"error")}finally{ee.value=!1}}}async function oc(){const t=Q.value.trim();if(t)try{await Ps(t)}catch{}localStorage.removeItem(da),pa("dashboard"),Xe.value=!1,await Xn()}async function rc(){const t=Q.value.trim();if(t){Ke.value=!0;try{await Mo(t),b("Heartbeat sent","success")}catch(e){const n=e instanceof Error?e.message:"Failed to send heartbeat";b(n,"error")}finally{Ke.value=!1}}}async function qa(){const t=Q.value.trim(),e=Qt.value.trim();if(!(!t||!e)){Zt.value=!0;try{await Is(t,e),Qt.value="",b("Broadcast sent","success")}catch(n){const a=n instanceof Error?n.message:"Failed to send broadcast";b(a,"error")}finally{Zt.value=!1}}}async function lc(){const t=Xt.value.trim(),e=Be.value.trim()||"Created from dashboard";if(t){Ct.value=!0;try{await Io(t,e,1),Xt.value="",Be.value="",b("Task created","success")}catch(n){const a=n instanceof Error?n.message:"Failed to create task";b(a,"error")}finally{Ct.value=!1}}}function cc(){return _t(()=>{Xn()},[]),o`
    <section class="rail-card control-dock">
      <h3>Control Dock</h3>

      <label class="control-label" for="dock-agent">Agent</label>
      <input
        id="dock-agent"
        class="control-input"
        type="text"
        value=${Q.value}
        onInput=${t=>pa(t.target.value)}
      />

      <label class="control-label" for="dock-message">Broadcast</label>
      <div class="control-row">
        <input
          id="dock-message"
          class="control-input"
          type="text"
          placeholder="@agent message or room update"
          value=${Qt.value}
          onInput=${t=>{Qt.value=t.target.value}}
          onKeyDown=${t=>{t.key==="Enter"&&qa()}}
          disabled=${Zt.value}
        />
        <button
          class="control-btn"
          onClick=${qa}
          disabled=${Zt.value||Qt.value.trim()===""||Q.value.trim()===""}
        >
          ${Zt.value?"Sending...":"Send"}
        </button>
      </div>

      <div class="control-row">
        <button
          class="control-btn ghost"
          onClick=${()=>{Xn()}}
          disabled=${te.value||Q.value.trim()===""}
        >
          ${te.value?"Joining...":Xe.value?"Rejoin":"Join"}
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{ic()}}
          disabled=${ee.value||Q.value.trim()===""}
        >
          ${ee.value?"Leaving...":"Leave"}
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{oc()}}
          disabled=${te.value||ee.value}
        >
          Reset ID
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{rc()}}
          disabled=${Ke.value||Q.value.trim()===""}
        >
          ${Ke.value?"Pinging...":"Heartbeat"}
        </button>
      </div>

      <label class="control-label" for="dock-task">Quick Task</label>
      <input
        id="dock-task"
        class="control-input"
        type="text"
        placeholder="Task title"
        value=${Xt.value}
        onInput=${t=>{Xt.value=t.target.value}}
        disabled=${Ct.value}
      />
      <textarea
        class="control-textarea"
        placeholder="Task description (optional)"
        value=${Be.value}
        onInput=${t=>{Be.value=t.target.value}}
        disabled=${Ct.value}
      ></textarea>
      <button
        class="control-btn secondary"
        onClick=${lc}
        disabled=${Ct.value||Xt.value.trim()===""}
      >
        ${Ct.value?"Creating...":"Create Task"}
      </button>
    </section>
  `}function uc(){const t=Lt.value;return o`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"Live":"Reconnecting..."}</span>
      <span class="event-count">${ia.value} events</span>
    </div>
  `}function dc(){const t=nt.value.tab,e=Lt.value;return o`
    <aside class="dashboard-rail">
      <section class="rail-card">
        <h3>Views</h3>
        <div class="rail-tab-list">
          ${ws.map(n=>o`
            <button
              class="rail-tab-btn ${t===n.id?"active":""}"
              onClick=${()=>Ge(n.id)}
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
            <strong>${It.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Keepers</span>
            <strong>${Pt.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Tasks</span>
            <strong>${pe.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Events</span>
            <strong>${ia.value}</strong>
          </div>
        </div>
        <button
          class="rail-refresh-btn"
          onClick=${()=>{Ye(),t==="board"&&yt(),t==="trpg"&&ot(),t==="goals"&&Pe(),t==="mdal"&&Us()}}
        >
          Refresh Now
        </button>
      </section>

      <${cc} />
    </aside>
  `}function pc(){switch(nt.value.tab){case"overview":return o`<${Oa} />`;case"council":return o`<${jr} />`;case"board":return o`<${Gr} />`;case"execution":return o`<${ul} />`;case"activity":return o`<${Xr} />`;case"agents":return o`<${rl} />`;case"tasks":return o`<${ll} />`;case"goals":return o`<${hl} />`;case"journal":return o`<${vl} />`;case"trpg":return o`<${Gl} />`;case"mdal":return o`<${nc} />`;default:return o`<${Oa} />`}}function vc(){return _t(()=>{Ui(),As(),Ye();const t=ir();return or(),()=>{Vi(),t(),rr()}},[]),_t(()=>{const t=nt.value.tab;t==="board"&&yt(),t==="trpg"&&ot(),t==="goals"&&Pe(),t==="mdal"&&Us()},[nt.value.tab]),o`
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
          <${uc} />
          <div class="header-links">
            <a href="/dashboard/lodge">Lodge</a>
            <a href="/dashboard/credits">Credits</a>
          </div>
        </div>
      </header>

      <div class="tab-sticky-wrap">
        <${Hi} />
      </div>

      <div class="dashboard-layout">
        <main class="dashboard-main">
          ${Fn.value&&!Lt.value?o`<div class="loading-indicator">Loading dashboard...</div>`:o`<${pc} />`}
        </main>
        <${dc} />
      </div>

      <${hr} />
      <${Ar} />
      <${xr} />
    </div>
  `}const Wa=document.getElementById("app");Wa&&wi(o`<${vc} />`,Wa);
