(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const s of document.querySelectorAll('link[rel="modulepreload"]'))a(s);new MutationObserver(s=>{for(const i of s)if(i.type==="childList")for(const r of i.addedNodes)r.tagName==="LINK"&&r.rel==="modulepreload"&&a(r)}).observe(document,{childList:!0,subtree:!0});function n(s){const i={};return s.integrity&&(i.integrity=s.integrity),s.referrerPolicy&&(i.referrerPolicy=s.referrerPolicy),s.crossOrigin==="use-credentials"?i.credentials="include":s.crossOrigin==="anonymous"?i.credentials="omit":i.credentials="same-origin",i}function a(s){if(s.ep)return;s.ep=!0;const i=n(s);fetch(s.href,i)}})();var de,b,Pn,En,Z,an,Rn,Ln,In,Ke,Ae,Ne,It={},Mn=[],Ea=/acit|ex(?:s|g|n|p|$)|rph|grid|ows|mnc|ntw|ine[ch]|zoo|^ord|itera/i,ve=Array.isArray;function B(t,e){for(var n in e)t[n]=e[n];return t}function Ve(t){t&&t.parentNode&&t.parentNode.removeChild(t)}function jn(t,e,n){var a,s,i,r={};for(i in e)i=="key"?a=e[i]:i=="ref"?s=e[i]:r[i]=e[i];if(arguments.length>2&&(r.children=arguments.length>3?de.call(arguments,2):n),typeof t=="function"&&t.defaultProps!=null)for(i in t.defaultProps)r[i]===void 0&&(r[i]=t.defaultProps[i]);return Gt(t,r,a,s,null)}function Gt(t,e,n,a,s){var i={type:t,props:e,key:n,ref:a,__k:null,__:null,__b:0,__e:null,__c:null,constructor:void 0,__v:s??++Pn,__i:-1,__u:0};return s==null&&b.vnode!=null&&b.vnode(i),i}function Ot(t){return t.children}function ht(t,e){this.props=t,this.context=e}function lt(t,e){if(e==null)return t.__?lt(t.__,t.__i+1):null;for(var n;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null)return n.__e;return typeof t.type=="function"?lt(t):null}function On(t){var e,n;if((t=t.__)!=null&&t.__c!=null){for(t.__e=t.__c.base=null,e=0;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null){t.__e=t.__c.base=n.__e;break}return On(t)}}function sn(t){(!t.__d&&(t.__d=!0)&&Z.push(t)&&!Xt.__r++||an!=b.debounceRendering)&&((an=b.debounceRendering)||Rn)(Xt)}function Xt(){for(var t,e,n,a,s,i,r,u=1;Z.length;)Z.length>u&&Z.sort(Ln),t=Z.shift(),u=Z.length,t.__d&&(n=void 0,a=void 0,s=(a=(e=t).__v).__e,i=[],r=[],e.__P&&((n=B({},a)).__v=a.__v+1,b.vnode&&b.vnode(n),We(e.__P,n,a,e.__n,e.__P.namespaceURI,32&a.__u?[s]:null,i,s??lt(a),!!(32&a.__u),r),n.__v=a.__v,n.__.__k[n.__i]=n,Fn(i,n,r),a.__e=a.__=null,n.__e!=s&&On(n)));Xt.__r=0}function Hn(t,e,n,a,s,i,r,u,d,c,p){var l,m,f,C,P,T,x,y=a&&a.__k||Mn,I=e.length;for(d=Ra(n,e,y,d,I),l=0;l<I;l++)(f=n.__k[l])!=null&&(m=f.__i==-1?It:y[f.__i]||It,f.__i=l,T=We(t,f,m,s,i,r,u,d,c,p),C=f.__e,f.ref&&m.ref!=f.ref&&(m.ref&&Ge(m.ref,null,f),p.push(f.ref,f.__c||C,f)),P==null&&C!=null&&(P=C),(x=!!(4&f.__u))||m.__k===f.__k?d=Un(f,d,t,x):typeof f.type=="function"&&T!==void 0?d=T:C&&(d=C.nextSibling),f.__u&=-7);return n.__e=P,d}function Ra(t,e,n,a,s){var i,r,u,d,c,p=n.length,l=p,m=0;for(t.__k=new Array(s),i=0;i<s;i++)(r=e[i])!=null&&typeof r!="boolean"&&typeof r!="function"?(typeof r=="string"||typeof r=="number"||typeof r=="bigint"||r.constructor==String?r=t.__k[i]=Gt(null,r,null,null,null):ve(r)?r=t.__k[i]=Gt(Ot,{children:r},null,null,null):r.constructor===void 0&&r.__b>0?r=t.__k[i]=Gt(r.type,r.props,r.key,r.ref?r.ref:null,r.__v):t.__k[i]=r,d=i+m,r.__=t,r.__b=t.__b+1,u=null,(c=r.__i=La(r,n,d,l))!=-1&&(l--,(u=n[c])&&(u.__u|=2)),u==null||u.__v==null?(c==-1&&(s>p?m--:s<p&&m++),typeof r.type!="function"&&(r.__u|=4)):c!=d&&(c==d-1?m--:c==d+1?m++:(c>d?m--:m++,r.__u|=4))):t.__k[i]=null;if(l)for(i=0;i<p;i++)(u=n[i])!=null&&(2&u.__u)==0&&(u.__e==a&&(a=lt(u)),Bn(u,u));return a}function Un(t,e,n,a){var s,i;if(typeof t.type=="function"){for(s=t.__k,i=0;s&&i<s.length;i++)s[i]&&(s[i].__=t,e=Un(s[i],e,n,a));return e}t.__e!=e&&(a&&(e&&t.type&&!e.parentNode&&(e=lt(t)),n.insertBefore(t.__e,e||null)),e=t.__e);do e=e&&e.nextSibling;while(e!=null&&e.nodeType==8);return e}function La(t,e,n,a){var s,i,r,u=t.key,d=t.type,c=e[n],p=c!=null&&(2&c.__u)==0;if(c===null&&u==null||p&&u==c.key&&d==c.type)return n;if(a>(p?1:0)){for(s=n-1,i=n+1;s>=0||i<e.length;)if((c=e[r=s>=0?s--:i++])!=null&&(2&c.__u)==0&&u==c.key&&d==c.type)return r}return-1}function on(t,e,n){e[0]=="-"?t.setProperty(e,n??""):t[e]=n==null?"":typeof n!="number"||Ea.test(e)?n:n+"px"}function Bt(t,e,n,a,s){var i,r;t:if(e=="style")if(typeof n=="string")t.style.cssText=n;else{if(typeof a=="string"&&(t.style.cssText=a=""),a)for(e in a)n&&e in n||on(t.style,e,"");if(n)for(e in n)a&&n[e]==a[e]||on(t.style,e,n[e])}else if(e[0]=="o"&&e[1]=="n")i=e!=(e=e.replace(In,"$1")),r=e.toLowerCase(),e=r in t||e=="onFocusOut"||e=="onFocusIn"?r.slice(2):e.slice(2),t.l||(t.l={}),t.l[e+i]=n,n?a?n.u=a.u:(n.u=Ke,t.addEventListener(e,i?Ne:Ae,i)):t.removeEventListener(e,i?Ne:Ae,i);else{if(s=="http://www.w3.org/2000/svg")e=e.replace(/xlink(H|:h)/,"h").replace(/sName$/,"s");else if(e!="width"&&e!="height"&&e!="href"&&e!="list"&&e!="form"&&e!="tabIndex"&&e!="download"&&e!="rowSpan"&&e!="colSpan"&&e!="role"&&e!="popover"&&e in t)try{t[e]=n??"";break t}catch{}typeof n=="function"||(n==null||n===!1&&e[4]!="-"?t.removeAttribute(e):t.setAttribute(e,e=="popover"&&n==1?"":n))}}function rn(t){return function(e){if(this.l){var n=this.l[e.type+t];if(e.t==null)e.t=Ke++;else if(e.t<n.u)return;return n(b.event?b.event(e):e)}}}function We(t,e,n,a,s,i,r,u,d,c){var p,l,m,f,C,P,T,x,y,I,E,U,w,q,X,Q,ft,R=e.type;if(e.constructor!==void 0)return null;128&n.__u&&(d=!!(32&n.__u),i=[u=e.__e=n.__e]),(p=b.__b)&&p(e);t:if(typeof R=="function")try{if(x=e.props,y="prototype"in R&&R.prototype.render,I=(p=R.contextType)&&a[p.__c],E=p?I?I.props.value:p.__:a,n.__c?T=(l=e.__c=n.__c).__=l.__E:(y?e.__c=l=new R(x,E):(e.__c=l=new ht(x,E),l.constructor=R,l.render=Ma),I&&I.sub(l),l.state||(l.state={}),l.__n=a,m=l.__d=!0,l.__h=[],l._sb=[]),y&&l.__s==null&&(l.__s=l.state),y&&R.getDerivedStateFromProps!=null&&(l.__s==l.state&&(l.__s=B({},l.__s)),B(l.__s,R.getDerivedStateFromProps(x,l.__s))),f=l.props,C=l.state,l.__v=e,m)y&&R.getDerivedStateFromProps==null&&l.componentWillMount!=null&&l.componentWillMount(),y&&l.componentDidMount!=null&&l.__h.push(l.componentDidMount);else{if(y&&R.getDerivedStateFromProps==null&&x!==f&&l.componentWillReceiveProps!=null&&l.componentWillReceiveProps(x,E),e.__v==n.__v||!l.__e&&l.shouldComponentUpdate!=null&&l.shouldComponentUpdate(x,l.__s,E)===!1){for(e.__v!=n.__v&&(l.props=x,l.state=l.__s,l.__d=!1),e.__e=n.__e,e.__k=n.__k,e.__k.some(function(W){W&&(W.__=e)}),U=0;U<l._sb.length;U++)l.__h.push(l._sb[U]);l._sb=[],l.__h.length&&r.push(l);break t}l.componentWillUpdate!=null&&l.componentWillUpdate(x,l.__s,E),y&&l.componentDidUpdate!=null&&l.__h.push(function(){l.componentDidUpdate(f,C,P)})}if(l.context=E,l.props=x,l.__P=t,l.__e=!1,w=b.__r,q=0,y){for(l.state=l.__s,l.__d=!1,w&&w(e),p=l.render(l.props,l.state,l.context),X=0;X<l._sb.length;X++)l.__h.push(l._sb[X]);l._sb=[]}else do l.__d=!1,w&&w(e),p=l.render(l.props,l.state,l.context),l.state=l.__s;while(l.__d&&++q<25);l.state=l.__s,l.getChildContext!=null&&(a=B(B({},a),l.getChildContext())),y&&!m&&l.getSnapshotBeforeUpdate!=null&&(P=l.getSnapshotBeforeUpdate(f,C)),Q=p,p!=null&&p.type===Ot&&p.key==null&&(Q=zn(p.props.children)),u=Hn(t,ve(Q)?Q:[Q],e,n,a,s,i,r,u,d,c),l.base=e.__e,e.__u&=-161,l.__h.length&&r.push(l),T&&(l.__E=l.__=null)}catch(W){if(e.__v=null,d||i!=null)if(W.then){for(e.__u|=d?160:128;u&&u.nodeType==8&&u.nextSibling;)u=u.nextSibling;i[i.indexOf(u)]=null,e.__e=u}else{for(ft=i.length;ft--;)Ve(i[ft]);De(e)}else e.__e=n.__e,e.__k=n.__k,W.then||De(e);b.__e(W,e,n)}else i==null&&e.__v==n.__v?(e.__k=n.__k,e.__e=n.__e):u=e.__e=Ia(n.__e,e,n,a,s,i,r,d,c);return(p=b.diffed)&&p(e),128&e.__u?void 0:u}function De(t){t&&t.__c&&(t.__c.__e=!0),t&&t.__k&&t.__k.forEach(De)}function Fn(t,e,n){for(var a=0;a<n.length;a++)Ge(n[a],n[++a],n[++a]);b.__c&&b.__c(e,t),t.some(function(s){try{t=s.__h,s.__h=[],t.some(function(i){i.call(s)})}catch(i){b.__e(i,s.__v)}})}function zn(t){return typeof t!="object"||t==null||t.__b&&t.__b>0?t:ve(t)?t.map(zn):B({},t)}function Ia(t,e,n,a,s,i,r,u,d){var c,p,l,m,f,C,P,T=n.props||It,x=e.props,y=e.type;if(y=="svg"?s="http://www.w3.org/2000/svg":y=="math"?s="http://www.w3.org/1998/Math/MathML":s||(s="http://www.w3.org/1999/xhtml"),i!=null){for(c=0;c<i.length;c++)if((f=i[c])&&"setAttribute"in f==!!y&&(y?f.localName==y:f.nodeType==3)){t=f,i[c]=null;break}}if(t==null){if(y==null)return document.createTextNode(x);t=document.createElementNS(s,y,x.is&&x),u&&(b.__m&&b.__m(e,i),u=!1),i=null}if(y==null)T===x||u&&t.data==x||(t.data=x);else{if(i=i&&de.call(t.childNodes),!u&&i!=null)for(T={},c=0;c<t.attributes.length;c++)T[(f=t.attributes[c]).name]=f.value;for(c in T)if(f=T[c],c!="children"){if(c=="dangerouslySetInnerHTML")l=f;else if(!(c in x)){if(c=="value"&&"defaultValue"in x||c=="checked"&&"defaultChecked"in x)continue;Bt(t,c,null,f,s)}}for(c in x)f=x[c],c=="children"?m=f:c=="dangerouslySetInnerHTML"?p=f:c=="value"?C=f:c=="checked"?P=f:u&&typeof f!="function"||T[c]===f||Bt(t,c,f,T[c],s);if(p)u||l&&(p.__html==l.__html||p.__html==t.innerHTML)||(t.innerHTML=p.__html),e.__k=[];else if(l&&(t.innerHTML=""),Hn(e.type=="template"?t.content:t,ve(m)?m:[m],e,n,a,y=="foreignObject"?"http://www.w3.org/1999/xhtml":s,i,r,i?i[0]:n.__k&&lt(n,0),u,d),i!=null)for(c=i.length;c--;)Ve(i[c]);u||(c="value",y=="progress"&&C==null?t.removeAttribute("value"):C!=null&&(C!==t[c]||y=="progress"&&!C||y=="option"&&C!=T[c])&&Bt(t,c,C,T[c],s),c="checked",P!=null&&P!=t[c]&&Bt(t,c,P,T[c],s))}return t}function Ge(t,e,n){try{if(typeof t=="function"){var a=typeof t.__u=="function";a&&t.__u(),a&&e==null||(t.__u=t(e))}else t.current=e}catch(s){b.__e(s,n)}}function Bn(t,e,n){var a,s;if(b.unmount&&b.unmount(t),(a=t.ref)&&(a.current&&a.current!=t.__e||Ge(a,null,e)),(a=t.__c)!=null){if(a.componentWillUnmount)try{a.componentWillUnmount()}catch(i){b.__e(i,e)}a.base=a.__P=null}if(a=t.__k)for(s=0;s<a.length;s++)a[s]&&Bn(a[s],e,n||typeof t.type!="function");n||Ve(t.__e),t.__c=t.__=t.__e=void 0}function Ma(t,e,n){return this.constructor(t,n)}function ja(t,e,n){var a,s,i,r;e==document&&(e=document.documentElement),b.__&&b.__(t,e),s=(a=!1)?null:e.__k,i=[],r=[],We(e,t=e.__k=jn(Ot,null,[t]),s||It,It,e.namespaceURI,s?null:e.firstChild?de.call(e.childNodes):null,i,s?s.__e:e.firstChild,a,r),Fn(i,t,r)}de=Mn.slice,b={__e:function(t,e,n,a){for(var s,i,r;e=e.__;)if((s=e.__c)&&!s.__)try{if((i=s.constructor)&&i.getDerivedStateFromError!=null&&(s.setState(i.getDerivedStateFromError(t)),r=s.__d),s.componentDidCatch!=null&&(s.componentDidCatch(t,a||{}),r=s.__d),r)return s.__E=s}catch(u){t=u}throw t}},Pn=0,En=function(t){return t!=null&&t.constructor===void 0},ht.prototype.setState=function(t,e){var n;n=this.__s!=null&&this.__s!=this.state?this.__s:this.__s=B({},this.state),typeof t=="function"&&(t=t(B({},n),this.props)),t&&B(n,t),t!=null&&this.__v&&(e&&this._sb.push(e),sn(this))},ht.prototype.forceUpdate=function(t){this.__v&&(this.__e=!0,t&&this.__h.push(t),sn(this))},ht.prototype.render=Ot,Z=[],Rn=typeof Promise=="function"?Promise.prototype.then.bind(Promise.resolve()):setTimeout,Ln=function(t,e){return t.__v.__b-e.__v.__b},Xt.__r=0,In=/(PointerCapture)$|Capture$/i,Ke=0,Ae=rn(!1),Ne=rn(!0);var Kn=function(t,e,n,a){var s;e[0]=0;for(var i=1;i<e.length;i++){var r=e[i++],u=e[i]?(e[0]|=r?1:2,n[e[i++]]):e[++i];r===3?a[0]=u:r===4?a[1]=Object.assign(a[1]||{},u):r===5?(a[1]=a[1]||{})[e[++i]]=u:r===6?a[1][e[++i]]+=u+"":r?(s=t.apply(u,Kn(t,u,n,["",null])),a.push(s),u[0]?e[0]|=2:(e[i-2]=0,e[i]=s)):a.push(u)}return a},ln=new Map;function Oa(t){var e=ln.get(this);return e||(e=new Map,ln.set(this,e)),(e=Kn(this,e.get(t)||(e.set(t,e=(function(n){for(var a,s,i=1,r="",u="",d=[0],c=function(m){i===1&&(m||(r=r.replace(/^\s*\n\s*|\s*\n\s*$/g,"")))?d.push(0,m,r):i===3&&(m||r)?(d.push(3,m,r),i=2):i===2&&r==="..."&&m?d.push(4,m,0):i===2&&r&&!m?d.push(5,0,!0,r):i>=5&&((r||!m&&i===5)&&(d.push(i,0,r,s),i=6),m&&(d.push(i,m,0,s),i=6)),r=""},p=0;p<n.length;p++){p&&(i===1&&c(),c(p));for(var l=0;l<n[p].length;l++)a=n[p][l],i===1?a==="<"?(c(),d=[d],i=3):r+=a:i===4?r==="--"&&a===">"?(i=1,r=""):r=a+r[0]:u?a===u?u="":r+=a:a==='"'||a==="'"?u=a:a===">"?(c(),i=1):i&&(a==="="?(i=5,s=r,r=""):a==="/"&&(i<5||n[p][l+1]===">")?(c(),i===3&&(d=d[0]),i=d,(d=d[0]).push(2,0,i),i=0):a===" "||a==="	"||a===`
`||a==="\r"?(c(),i=2):r+=a),i===3&&r==="!--"&&(i=4,d=d[0])}return c(),d})(t)),e),arguments,[])).length>1?e:e[0]}var o=Oa.bind(jn),Qt,D,$e,cn,un=0,Vn=[],A=b,dn=A.__b,vn=A.__r,pn=A.diffed,fn=A.__c,_n=A.unmount,mn=A.__;function Wn(t,e){A.__h&&A.__h(D,t,un||e),un=0;var n=D.__H||(D.__H={__:[],__h:[]});return t>=n.__.length&&n.__.push({}),n.__[t]}function Yt(t,e){var n=Wn(Qt++,3);!A.__s&&Jn(n.__H,e)&&(n.__=t,n.u=e,D.__H.__h.push(n))}function Gn(t,e){var n=Wn(Qt++,7);return Jn(n.__H,e)&&(n.__=t(),n.__H=e,n.__h=t),n.__}function Ha(){for(var t;t=Vn.shift();)if(t.__P&&t.__H)try{t.__H.__h.forEach(Jt),t.__H.__h.forEach(Pe),t.__H.__h=[]}catch(e){t.__H.__h=[],A.__e(e,t.__v)}}A.__b=function(t){D=null,dn&&dn(t)},A.__=function(t,e){t&&e.__k&&e.__k.__m&&(t.__m=e.__k.__m),mn&&mn(t,e)},A.__r=function(t){vn&&vn(t),Qt=0;var e=(D=t.__c).__H;e&&($e===D?(e.__h=[],D.__h=[],e.__.forEach(function(n){n.__N&&(n.__=n.__N),n.u=n.__N=void 0})):(e.__h.forEach(Jt),e.__h.forEach(Pe),e.__h=[],Qt=0)),$e=D},A.diffed=function(t){pn&&pn(t);var e=t.__c;e&&e.__H&&(e.__H.__h.length&&(Vn.push(e)!==1&&cn===A.requestAnimationFrame||((cn=A.requestAnimationFrame)||Ua)(Ha)),e.__H.__.forEach(function(n){n.u&&(n.__H=n.u),n.u=void 0})),$e=D=null},A.__c=function(t,e){e.some(function(n){try{n.__h.forEach(Jt),n.__h=n.__h.filter(function(a){return!a.__||Pe(a)})}catch(a){e.some(function(s){s.__h&&(s.__h=[])}),e=[],A.__e(a,n.__v)}}),fn&&fn(t,e)},A.unmount=function(t){_n&&_n(t);var e,n=t.__c;n&&n.__H&&(n.__H.__.forEach(function(a){try{Jt(a)}catch(s){e=s}}),n.__H=void 0,e&&A.__e(e,n.__v))};var hn=typeof requestAnimationFrame=="function";function Ua(t){var e,n=function(){clearTimeout(a),hn&&cancelAnimationFrame(e),setTimeout(t)},a=setTimeout(n,35);hn&&(e=requestAnimationFrame(n))}function Jt(t){var e=D,n=t.__c;typeof n=="function"&&(t.__c=void 0,n()),D=e}function Pe(t){var e=D;t.__c=t.__(),D=e}function Jn(t,e){return!t||t.length!==e.length||e.some(function(n,a){return n!==t[a]})}var Fa=Symbol.for("preact-signals");function pe(){if(G>1)G--;else{for(var t,e=!1;$t!==void 0;){var n=$t;for($t=void 0,Ee++;n!==void 0;){var a=n.o;if(n.o=void 0,n.f&=-3,!(8&n.f)&&Qn(n))try{n.c()}catch(s){e||(t=s,e=!0)}n=a}}if(Ee=0,G--,e)throw t}}function za(t){if(G>0)return t();G++;try{return t()}finally{pe()}}var $=void 0;function qn(t){var e=$;$=void 0;try{return t()}finally{$=e}}var $t=void 0,G=0,Ee=0,Zt=0;function Xn(t){if($!==void 0){var e=t.n;if(e===void 0||e.t!==$)return e={i:0,S:t,p:$.s,n:void 0,t:$,e:void 0,x:void 0,r:e},$.s!==void 0&&($.s.n=e),$.s=e,t.n=e,32&$.f&&t.S(e),e;if(e.i===-1)return e.i=0,e.n!==void 0&&(e.n.p=e.p,e.p!==void 0&&(e.p.n=e.n),e.p=$.s,e.n=void 0,$.s.n=e,$.s=e),e}}function N(t,e){this.v=t,this.i=0,this.n=void 0,this.t=void 0,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}N.prototype.brand=Fa;N.prototype.h=function(){return!0};N.prototype.S=function(t){var e=this,n=this.t;n!==t&&t.e===void 0&&(t.x=n,this.t=t,n!==void 0?n.e=t:qn(function(){var a;(a=e.W)==null||a.call(e)}))};N.prototype.U=function(t){var e=this;if(this.t!==void 0){var n=t.e,a=t.x;n!==void 0&&(n.x=a,t.e=void 0),a!==void 0&&(a.e=n,t.x=void 0),t===this.t&&(this.t=a,a===void 0&&qn(function(){var s;(s=e.Z)==null||s.call(e)}))}};N.prototype.subscribe=function(t){var e=this;return Ht(function(){var n=e.value,a=$;$=void 0;try{t(n)}finally{$=a}},{name:"sub"})};N.prototype.valueOf=function(){return this.value};N.prototype.toString=function(){return this.value+""};N.prototype.toJSON=function(){return this.value};N.prototype.peek=function(){var t=$;$=void 0;try{return this.value}finally{$=t}};Object.defineProperty(N.prototype,"value",{get:function(){var t=Xn(this);return t!==void 0&&(t.i=this.i),this.v},set:function(t){if(t!==this.v){if(Ee>100)throw new Error("Cycle detected");this.v=t,this.i++,Zt++,G++;try{for(var e=this.t;e!==void 0;e=e.x)e.t.N()}finally{pe()}}}});function v(t,e){return new N(t,e)}function Qn(t){for(var e=t.s;e!==void 0;e=e.n)if(e.S.i!==e.i||!e.S.h()||e.S.i!==e.i)return!0;return!1}function Yn(t){for(var e=t.s;e!==void 0;e=e.n){var n=e.S.n;if(n!==void 0&&(e.r=n),e.S.n=e,e.i=-1,e.n===void 0){t.s=e;break}}}function Zn(t){for(var e=t.s,n=void 0;e!==void 0;){var a=e.p;e.i===-1?(e.S.U(e),a!==void 0&&(a.n=e.n),e.n!==void 0&&(e.n.p=a)):n=e,e.S.n=e.r,e.r!==void 0&&(e.r=void 0),e=a}t.s=n}function et(t,e){N.call(this,void 0),this.x=t,this.s=void 0,this.g=Zt-1,this.f=4,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}et.prototype=new N;et.prototype.h=function(){if(this.f&=-3,1&this.f)return!1;if((36&this.f)==32||(this.f&=-5,this.g===Zt))return!0;if(this.g=Zt,this.f|=1,this.i>0&&!Qn(this))return this.f&=-2,!0;var t=$;try{Yn(this),$=this;var e=this.x();(16&this.f||this.v!==e||this.i===0)&&(this.v=e,this.f&=-17,this.i++)}catch(n){this.v=n,this.f|=16,this.i++}return $=t,Zn(this),this.f&=-2,!0};et.prototype.S=function(t){if(this.t===void 0){this.f|=36;for(var e=this.s;e!==void 0;e=e.n)e.S.S(e)}N.prototype.S.call(this,t)};et.prototype.U=function(t){if(this.t!==void 0&&(N.prototype.U.call(this,t),this.t===void 0)){this.f&=-33;for(var e=this.s;e!==void 0;e=e.n)e.S.U(e)}};et.prototype.N=function(){if(!(2&this.f)){this.f|=6;for(var t=this.t;t!==void 0;t=t.x)t.t.N()}};Object.defineProperty(et.prototype,"value",{get:function(){if(1&this.f)throw new Error("Cycle detected");var t=Xn(this);if(this.h(),t!==void 0&&(t.i=this.i),16&this.f)throw this.v;return this.v}});function te(t,e){return new et(t,e)}function ta(t){var e=t.u;if(t.u=void 0,typeof e=="function"){G++;var n=$;$=void 0;try{e()}catch(a){throw t.f&=-2,t.f|=8,Je(t),a}finally{$=n,pe()}}}function Je(t){for(var e=t.s;e!==void 0;e=e.n)e.S.U(e);t.x=void 0,t.s=void 0,ta(t)}function Ba(t){if($!==this)throw new Error("Out-of-order effect");Zn(this),$=t,this.f&=-2,8&this.f&&Je(this),pe()}function ut(t,e){this.x=t,this.u=void 0,this.s=void 0,this.o=void 0,this.f=32,this.name=e==null?void 0:e.name}ut.prototype.c=function(){var t=this.S();try{if(8&this.f||this.x===void 0)return;var e=this.x();typeof e=="function"&&(this.u=e)}finally{t()}};ut.prototype.S=function(){if(1&this.f)throw new Error("Cycle detected");this.f|=1,this.f&=-9,ta(this),Yn(this),G++;var t=$;return $=this,Ba.bind(this,t)};ut.prototype.N=function(){2&this.f||(this.f|=2,this.o=$t,$t=this)};ut.prototype.d=function(){this.f|=8,1&this.f||Je(this)};ut.prototype.dispose=function(){this.d()};function Ht(t,e){var n=new ut(t,e);try{n.c()}catch(s){throw n.d(),s}var a=n.d.bind(n);return a[Symbol.dispose]=a,a}var ea,Kt,Ka=typeof window<"u"&&!!window.__PREACT_SIGNALS_DEVTOOLS__,na=[];Ht(function(){ea=this.N})();function dt(t,e){b[t]=e.bind(null,b[t]||function(){})}function ee(t){if(Kt){var e=Kt;Kt=void 0,e()}Kt=t&&t.S()}function aa(t){var e=this,n=t.data,a=Wa(n);a.value=n;var s=Gn(function(){for(var u=e,d=e.__v;d=d.__;)if(d.__c){d.__c.__$f|=4;break}var c=te(function(){var f=a.value.value;return f===0?0:f===!0?"":f||""}),p=te(function(){return!Array.isArray(c.value)&&!En(c.value)}),l=Ht(function(){if(this.N=sa,p.value){var f=c.value;u.__v&&u.__v.__e&&u.__v.__e.nodeType===3&&(u.__v.__e.data=f)}}),m=e.__$u.d;return e.__$u.d=function(){l(),m.call(this)},[p,c]},[]),i=s[0],r=s[1];return i.value?r.peek():r.value}aa.displayName="ReactiveTextNode";Object.defineProperties(N.prototype,{constructor:{configurable:!0,value:void 0},type:{configurable:!0,value:aa},props:{configurable:!0,get:function(){return{data:this}}},__b:{configurable:!0,value:1}});dt("__b",function(t,e){if(typeof e.type=="string"){var n,a=e.props;for(var s in a)if(s!=="children"){var i=a[s];i instanceof N&&(n||(e.__np=n={}),n[s]=i,a[s]=i.peek())}}t(e)});dt("__r",function(t,e){if(t(e),e.type!==Ot){ee();var n,a=e.__c;a&&(a.__$f&=-2,(n=a.__$u)===void 0&&(a.__$u=n=(function(s,i){var r;return Ht(function(){r=this},{name:i}),r.c=s,r})(function(){var s;Ka&&((s=n.y)==null||s.call(n)),a.__$f|=1,a.setState({})},typeof e.type=="function"?e.type.displayName||e.type.name:""))),ee(n)}});dt("__e",function(t,e,n,a){ee(),t(e,n,a)});dt("diffed",function(t,e){ee();var n;if(typeof e.type=="string"&&(n=e.__e)){var a=e.__np,s=e.props;if(a){var i=n.U;if(i)for(var r in i){var u=i[r];u!==void 0&&!(r in a)&&(u.d(),i[r]=void 0)}else i={},n.U=i;for(var d in a){var c=i[d],p=a[d];c===void 0?(c=Va(n,d,p),i[d]=c):c.o(p,s)}for(var l in a)s[l]=a[l]}}t(e)});function Va(t,e,n,a){var s=e in t&&t.ownerSVGElement===void 0,i=v(n),r=n.peek();return{o:function(u,d){i.value=u,r=u.peek()},d:Ht(function(){this.N=sa;var u=i.value.value;r!==u?(r=void 0,s?t[e]=u:u!=null&&(u!==!1||e[4]==="-")?t.setAttribute(e,u):t.removeAttribute(e)):r=void 0})}}dt("unmount",function(t,e){if(typeof e.type=="string"){var n=e.__e;if(n){var a=n.U;if(a){n.U=void 0;for(var s in a){var i=a[s];i&&i.d()}}}e.__np=void 0}else{var r=e.__c;if(r){var u=r.__$u;u&&(r.__$u=void 0,u.d())}}t(e)});dt("__h",function(t,e,n,a){(a<3||a===9)&&(e.__$f|=2),t(e,n,a)});ht.prototype.shouldComponentUpdate=function(t,e){if(this.__R)return!0;var n=this.__$u,a=n&&n.s!==void 0;for(var s in e)return!0;if(this.__f||typeof this.u=="boolean"&&this.u===!0){var i=2&this.__$f;if(!(a||i||4&this.__$f)||1&this.__$f)return!0}else if(!(a||4&this.__$f)||3&this.__$f)return!0;for(var r in t)if(r!=="__source"&&t[r]!==this.props[r])return!0;for(var u in this.props)if(!(u in t))return!0;return!1};function Wa(t,e){return Gn(function(){return v(t,e)},[])}var Ga=function(t){queueMicrotask(function(){queueMicrotask(t)})};function Ja(){za(function(){for(var t;t=na.shift();)ea.call(t)})}function sa(){na.push(this)===1&&(b.requestAnimationFrame||Ga)(Ja)}const qa=["overview","board","activity","agents","tasks","journal","trpg","council"],ia={tab:"overview",params:{},postId:null};function $n(t){return!!t&&qa.includes(t)}function Re(t){try{return decodeURIComponent(t)}catch{return t}}function Le(t){const e={};return t&&new URLSearchParams(t).forEach((a,s)=>{e[s]=a}),e}function Xa(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function oa(t,e){const n=t[0],a=e.tab,s=$n(n)?n:$n(a)?a:"overview";let i=null;return s==="board"&&(t[0]==="board"&&t[1]==="post"&&t[2]?i=Re(t[2]):t[0]==="post"&&t[1]&&(i=Re(t[1]))),{tab:s,params:e,postId:i}}function ne(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return ia;const n=Re(e);let a=n,s;if(n.startsWith("?"))a="",s=n.slice(1);else{const u=n.indexOf("?");u>=0&&(a=n.slice(0,u),s=n.slice(u+1))}!s&&a.includes("=")&&!a.includes("/")&&(s=a,a="");const i=Le(s),r=Xa(a);return oa(r,i)}function Qa(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const a=n.slice(1);if(a.length===0)return{...ia,params:Le(e.replace(/^\?/,""))};if(a[0]==="assets"||a[0]==="credits"||a[0]==="lodge")return null;const s=Le(e.replace(/^\?/,""));return oa(a,s)}function ra(t){const e=t.postId?`board/post/${encodeURIComponent(t.postId)}`:t.tab,n=Object.entries(t.params).filter(([s])=>s!=="tab");if(n.length===0)return`#${e}`;const a=new URLSearchParams(n);return`#${e}?${a.toString()}`}const H=v(ne(window.location.hash));window.addEventListener("hashchange",()=>{H.value=ne(window.location.hash)});function fe(t,e){const n={tab:t,params:{},postId:null};window.location.hash=ra(n)}function Ya(t){window.location.hash=`#board/post/${encodeURIComponent(t)}`}function Za(){if(window.location.hash&&window.location.hash!=="#"){H.value=ne(window.location.hash);return}const t=Qa(window.location.pathname,window.location.search);if(t){H.value=t;const e=ra(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#overview",H.value=ne(window.location.hash)}const ts=[{id:"overview",label:"Overview",icon:"🏠"},{id:"council",label:"Council",icon:"🏛️"},{id:"board",label:"Board",icon:"💬"},{id:"activity",label:"Activity",icon:"📊"},{id:"agents",label:"Agents",icon:"🤖"},{id:"tasks",label:"Tasks",icon:"📋"},{id:"journal",label:"Journal",icon:"📓"},{id:"trpg",label:"TRPG",icon:"⚔️"}];function es(){const t=H.value.tab;return o`
    <div class="main-tab-bar">
      ${ts.map(e=>o`
        <button
          class="main-tab-btn ${t===e.id?"active":""}"
          onClick=${()=>fe(e.id)}
        >
          ${e.icon} ${e.label}
        </button>
      `)}
    </div>
  `}const gn="masc_dashboard_sse_session_id",ns=1e3,as=15e3,ct=v(!1),qe=v(0),la=v(null),ae=v([]);function ss(){let t=sessionStorage.getItem(gn);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(gn,t)),t}const is=200;function Y(t,e){const n={agent:t,text:e,timestamp:Date.now()};ae.value=[n,...ae.value].slice(0,is)}let O=null,it=null,Ie=0;function ca(){it&&(clearTimeout(it),it=null)}function os(){if(it)return;Ie++;const t=Math.min(Ie,5),e=Math.min(as,ns*Math.pow(2,t));it=setTimeout(()=>{it=null,ua()},e)}function ua(){ca(),O&&(O.close(),O=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),a=t.get("token");n&&e.set("agent",n),a&&e.set("token",a),e.set("session_id",ss());const s=e.toString()?`/sse?${e.toString()}`:"/sse",i=new EventSource(s);O=i,i.onopen=()=>{O===i&&(Ie=0,ct.value=!0)},i.onerror=()=>{O===i&&(ct.value=!1,i.close(),O=null,os())},i.onmessage=r=>{try{const u=JSON.parse(r.data);qe.value++,la.value=u,rs(u)}catch{}}}function rs(t){const e=t.type,n=t.agent??t.from??t.from_agent??"";switch(e){case"agent_joined":Y(n,"Joined");break;case"agent_left":Y(n,"Left");break;case"broadcast":Y(n,`${(t.message??t.content??"").slice(0,80)}`);break;case"task_update":Y(n,`Task: ${t.task_id??""} -> ${t.status??""}`);break;case"board_post":Y(n,"New post");break;case"board_comment":Y(n,"New comment");break;default:Y(n,e)}}function ls(){ca(),O&&(O.close(),O=null),ct.value=!1}function da(){return new URLSearchParams(window.location.search)}function va(){const t=da(),e={},n=t.get("token"),a=t.get("agent")??t.get("agent_name");return n&&(e.Authorization=`Bearer ${n}`),a&&(e["X-MASC-Agent"]=a),e}function pa(){return{...va(),"Content-Type":"application/json"}}const cs=15e3,fa=3e4,us=6e4;async function Xe(t,e,n){const a=new AbortController,s=setTimeout(()=>a.abort(),n);try{return await fetch(t,{...e,signal:a.signal})}catch(i){if(i instanceof Error&&i.name==="AbortError"){const r=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new Error(`${r} ${t}: timeout after ${n}ms`)}throw i}finally{clearTimeout(s)}}function ds(){var e,n;const t=da();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function Ut(t){const e=await Xe(t,{headers:va()},cs);if(!e.ok)throw new Error(`GET ${t}: ${e.status} ${e.statusText}`);return e.json()}async function Ft(t,e){const n=await Xe(t,{method:"POST",headers:pa(),body:JSON.stringify(e)},fa);if(!n.ok)throw new Error(`POST ${t}: ${n.status} ${n.statusText}`);return n.json()}async function vs(t,e,n,a=fa){const s=await Xe(t,{method:"POST",headers:{...pa(),...n??{}},body:JSON.stringify(e)},a);if(!s.ok)throw new Error(`POST ${t}: ${s.status} ${s.statusText}`);return s.text()}function ps(t){const e=t.split(`
`).find(a=>a.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function fs(t){var e,n,a,s,i,r,u;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const d=((s=(a=t.result.content)==null?void 0:a[0])==null?void 0:s.text)??"MCP tool call failed";throw new Error(d)}return((u=(r=(i=t.result)==null?void 0:i.content)==null?void 0:r[0])==null?void 0:u.text)??""}async function j(t,e){const n=await vs("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},us),a=ps(n);return fs(a)}function _a(t){const e=t.trim();if(!e)return[];const n=JSON.parse(e);return Array.isArray(n)?n:[]}function _s(){return Ut("/api/v1/dashboard")}function ms(){return Ut("/api/v1/board")}function hs(t){return Ut(`/api/v1/board/${t}`)}function ma(t,e){return Ft("/api/v1/tools/masc_board_vote",{post_id:t,vote:e,voter:ds()})}function $s(t,e,n){return Ft("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function F(t){return typeof t=="object"&&t!==null}function h(t,e=""){return typeof t=="string"?t:e}function K(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function gs(t,e=!1){return typeof t=="boolean"?t:e}function ys(t){return t==="dm"||t==="player"||t==="npc"?t:"npc"}function L(t,e,n,a=0){const s=t[e];if(typeof s=="number"&&Number.isFinite(s))return s;if(n){const i=t[n];if(typeof i=="number"&&Number.isFinite(i))return i}return a}function bs(t,e){if(t!=="dice.rolled")return;const n=K(e.raw_d20,0),a=K(e.total,0),s=K(e.bonus,0),i=h(e.action,"roll"),r=K(e.dc,0);return{notation:r>0?`${i} (DC ${r})`:i,rolls:n>0?[n]:[],total:a,modifier:s}}function ks(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function xs(t,e,n){const a=e||h(n.actor_id,"");switch(t){case"turn.action.proposed":{const s=h(n.proposed_action,h(n.reply,""));return s?`${a||"actor"}: ${s}`:"Action proposed"}case"turn.action.resolved":{const s=h(n.reply,h(n.result,""));return s?`Resolved: ${s}`:"Action resolved"}case"narration.posted":return h(n.reply,h(n.content,h(n.text,"Narration")));case"dice.rolled":{const s=h(n.action,"roll"),i=K(n.total,0),r=K(n.dc,0),u=h(n.label,""),d=a||"actor",c=r>0?` vs DC ${r}`:"",p=u?` (${u})`:"";return`${d} ${s}: ${i}${c}${p}`}case"turn.started":return`Turn ${K(n.turn,1)} started`;case"phase.changed":return`Phase: ${h(n.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${h(n.name,a||"unknown")}`;case"actor.claimed":return`${h(n.keeper,"keeper")} claimed ${a||"actor"}`;case"actor.released":return`${h(n.keeper,"keeper")} released ${a||"actor"}`;case"combat.attack":return h(n.summary,h(n.result,"Attack resolved"));case"combat.defense":return h(n.summary,h(n.result,"Defense resolved"));case"session.outcome":return h(n.summary,h(n.outcome,"Session ended"));default:{const s=ks(n);return s?`${t}: ${s}`:t}}}function ws(t){const e=F(t)?t:{},n=h(e.type,"event"),a=typeof e.actor_id=="string"?e.actor_id:"",s=F(e.payload)?e.payload:{};return{type:n,actor:a||h(s.actor_id,""),content:xs(n,a,s),dice_roll:bs(n,s),timestamp:h(e.ts,new Date().toISOString())}}function Ss(t,e,n){var y,I;const a=h(t.room_id,"")||n||"default",s=F(t.state)?t.state:{},i=F(s.party)?s.party:{},r=F(s.actor_control)?s.actor_control:{},u=Object.entries(i).map(([E,U])=>{const w=F(U)?U:{},q=L(w,"max_hp",void 0,10),X=L(w,"hp",void 0,q),Q=L(w,"max_mp",void 0,0),ft=L(w,"mp",void 0,0),R=L(w,"level",void 0,1),W=L(w,"xp",void 0,0),Da=gs(w.alive,X>0),nn=r[E],Pa=typeof nn=="string"?nn:void 0;return{id:E,name:h(w.name,E),role:ys(w.role),keeper:Pa,status:Da?"active":"dead",stats:{hp:X,max_hp:q,mp:ft,max_mp:Q,level:R,xp:W,strength:L(w,"strength","str",10),dexterity:L(w,"dexterity","dex",10),constitution:L(w,"constitution","con",10),intelligence:L(w,"intelligence","int",10),wisdom:L(w,"wisdom","wis",10),charisma:L(w,"charisma","cha",10)}}}),d=e.map(ws),c=K(s.turn,1),p=h(s.phase,"round"),l=h(s.map,""),m=F(s.world)?s.world:{},f=l||h(m.ascii_map,h(m.map,"")),C=d.filter((E,U)=>{const w=e[U];if(!F(w))return!1;const q=F(w.payload)?w.payload:{};return K(q.turn,-1)===c}),P=(C.length>0?C:d).slice(-12),T=h(s.status,"active");return{session:{id:a,room:a,status:T==="ended"?"ended":T==="paused"?"paused":"active",round:c,actors:u,created_at:((y=d[0])==null?void 0:y.timestamp)??new Date().toISOString()},current_round:{round_number:c,phase:p,events:P,timestamp:((I=d[d.length-1])==null?void 0:I.timestamp)??new Date().toISOString()},map:f||void 0,party:u,story_log:d,history:[]}}async function Cs(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await Ut(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function Ts(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,a]=await Promise.all([Ut(`/api/v1/trpg/state${e}`),Cs(t)]);return Ss(n,a,t)}function As(t){return Ft("/api/v1/trpg/rounds/run",{room_id:t})}function Ns(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),Ft("/api/v1/trpg/dice/roll",e)}function Ds(t,e){return Ft("/api/v1/trpg/turns/advance",{room_id:t})}async function ha(t,e){await j("masc_broadcast",{agent_name:t,message:e})}async function Ps(t,e,n=1){await j("masc_add_task",{title:t,description:e,priority:n})}async function Es(t){return j("masc_join",{agent_name:t})}async function $a(t){await j("masc_leave",{agent_name:t})}async function Rs(t){await j("masc_heartbeat",{agent_name:t})}async function Ls(t=40){return(await j("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function Is(t,e=20){return j("masc_task_history",{task_id:t,limit:e})}async function Ms(){const t=await j("masc_debates",{});return _a(t)}async function js(){const t=await j("masc_sessions",{});return _a(t)}async function Os(t){const e=await j("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}function Hs(t){return j("masc_debate_status",{debate_id:t})}const vt=v([]),zt=v([]),ga=v([]),_e=v([]),Qe=v(null),mt=v(null),ya=v([]),yn=v("hot"),ba=v(null),gt=v(""),Me=v(!1),je=v(!1),Oe=v(!1),Us=te(()=>vt.value.filter(t=>t.status==="active"||t.status==="idle")),ka=te(()=>{const t=zt.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}});let qt=null;const Fs=5e3;function xa(){qt=null}function z(t){return typeof t=="object"&&t!==null}function _(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function S(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function yt(t){if(!Array.isArray(t))return;const e=t.filter(n=>typeof n=="string"&&n.trim()!=="");return e.length>0?e:void 0}function wa(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="idle"||e==="inactive"||e==="offline"?e:e==="busy"||e==="in_progress"||e==="claimed"?"active":"offline"}function zs(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function Bs(t){if(!z(t))return null;const e=_(t.name);return e?{name:e,status:wa(t.status),current_task:_(t.current_task)??null,last_seen:_(t.last_seen),emoji:_(t.emoji),koreanName:_(t.koreanName)??_(t.korean_name),model:_(t.model),traits:yt(t.traits),interests:yt(t.interests),activityLevel:S(t.activityLevel)??S(t.activity_level),primaryValue:_(t.primaryValue)??_(t.primary_value)}:null}function Ks(t){if(!z(t))return null;const e=_(t.id),n=_(t.title);return!e||!n?null:{id:e,title:n,status:zs(t.status),priority:S(t.priority),assignee:_(t.assignee),description:_(t.description),created_at:_(t.created_at),updated_at:_(t.updated_at)}}function Vs(t){if(!z(t))return null;const e=_(t.from)??_(t.from_agent)??"system",n=_(t.content)??"",a=_(t.timestamp)??new Date().toISOString();return{id:_(t.id),seq:S(t.seq),from:e,content:n,timestamp:a,type:_(t.type)}}function Ws(t){return(Array.isArray(t)?t:z(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(n=>{if(!z(n))return null;const a=z(n.agent)?n.agent:null,s=z(n.context)?n.context:null,i=z(n.metrics_window)?n.metrics_window:void 0,r=_(n.name);if(!r)return null;const u=S(n.context_ratio)??S(s==null?void 0:s.context_ratio),d=_(n.status)??_(a==null?void 0:a.status)??"offline",c=wa(d),p=_(n.model)??_(n.active_model)??_(n.primary_model),l=yt(n.skill_secondary),m=s?{source:_(s.source),context_ratio:S(s.context_ratio),context_tokens:S(s.context_tokens),context_max:S(s.context_max),message_count:S(s.message_count),has_checkpoint:typeof s.has_checkpoint=="boolean"?s.has_checkpoint:void 0}:void 0,f=a?{name:_(a.name),status:_(a.status),current_task:_(a.current_task)??null,last_seen:_(a.last_seen)}:void 0;return{name:r,emoji:_(n.emoji),koreanName:_(n.koreanName)??_(n.korean_name),agent_name:_(n.agent_name),trace_id:_(n.trace_id),model:p,primary_model:_(n.primary_model),active_model:_(n.active_model),next_model_hint:_(n.next_model_hint)??null,status:c,last_heartbeat:_(n.last_heartbeat)??_(a==null?void 0:a.last_seen),generation:S(n.generation),turn_count:S(n.turn_count)??S(n.total_turns),context_ratio:u,context_tokens:S(n.context_tokens)??S(s==null?void 0:s.context_tokens),context_max:S(n.context_max)??S(s==null?void 0:s.context_max),context_source:_(n.context_source)??_(s==null?void 0:s.source),context:m,traits:yt(n.traits),interests:yt(n.interests),primaryValue:_(n.primaryValue)??_(n.primary_value),activityLevel:S(n.activityLevel)??S(n.activity_level),memory_recent_note:_(n.memory_recent_note)??null,conversation_tail_count:S(n.conversation_tail_count),k2k_count:S(n.k2k_count),handoff_count_total:S(n.handoff_count_total)??S(n.trace_history_count),compaction_count:S(n.compaction_count),last_compaction_saved_tokens:S(n.last_compaction_saved_tokens),skill_primary:_(n.skill_primary)??null,skill_secondary:l,skill_reason:_(n.skill_reason)??null,metrics_window:i,agent:f}}).filter(n=>n!==null)}async function me(){var e,n,a;const t=Date.now();if(!(qt&&t-qt.time<Fs)){Me.value=!0;try{const s=await _s();qt={data:s,time:t},vt.value=(Array.isArray((e=s.agents)==null?void 0:e.agents)?s.agents.agents:[]).map(Bs).filter(i=>i!==null),zt.value=(Array.isArray((n=s.tasks)==null?void 0:n.tasks)?s.tasks.tasks:[]).map(Ks).filter(i=>i!==null),ga.value=(Array.isArray((a=s.messages)==null?void 0:a.messages)?s.messages.messages:[]).map(Vs).filter(i=>i!==null),_e.value=Ws(s.keepers),Qe.value=z(s.status)?s.status:null,mt.value=s.perpetual??null}catch(s){console.error("Dashboard fetch error:",s)}finally{Me.value=!1}}}async function nt(){je.value=!0;try{const t=await ms();ya.value=t.posts??[]}catch(t){console.error("Board fetch error:",t)}finally{je.value=!1}}async function ot(){var t;Oe.value=!0;try{const e=gt.value||((t=Qe.value)==null?void 0:t.room)||"default";gt.value||(gt.value=e);const n=await Ts(e);ba.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{Oe.value=!1}}let ge=null,ye=null;function Gs(){return la.subscribe(e=>{e&&(xa(),ge||(ge=setTimeout(()=>{me(),ge=null},500)),(e.type==="board_post"||e.type==="board_comment")&&(ye||(ye=setTimeout(()=>{nt(),ye=null},500))))})}let bt=null;function Js(){bt||(bt=setInterval(()=>{xa(),me()},1e4))}function qs(){bt&&(clearInterval(bt),bt=null)}function g({title:t,class:e,children:n}){return o`
    <div class="card ${e??""}">
      ${t?o`<div class="card-title">${t}</div>`:null}
      ${n}
    </div>
  `}function V({status:t,label:e}){return o`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??t}
    </span>
  `}function Xs(t){const e=Date.now(),n=typeof t=="number"?t:new Date(t).getTime(),a=Math.floor((e-n)/1e3);if(a<60)return`${a}s ago`;const s=Math.floor(a/60);if(s<60)return`${s}m ago`;const i=Math.floor(s/60);return i<24?`${i}h ago`:`${Math.floor(i/24)}d ago`}function J({timestamp:t}){const e=Xs(t);return o`<span class="time-ago" title=${typeof t=="string"?t:new Date(t).toISOString()}>${e}</span>`}const Ye=v(null);function Sa(t){Ye.value=t}function bn(){Ye.value=null}function Qs({keeper:t}){const e=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return o`
    <div class="keeper-kpis">
      ${e.map(n=>o`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${n.label}</div>
          <div class="keeper-kpi-value">${n.value}</div>
          ${n.hint?o`<div class="keeper-kpi-hint">${n.hint}</div>`:null}
        </div>
      `)}
    </div>
  `}function Ys({keeper:t}){const e=t.context_ratio;if(e==null)return null;const n=Math.round(e*100),a=n>80?"bad":n>60?"warn":"";return o`
    <div class="keeper-chart-card">
      <div class="keeper-chart-container" style="display: flex; align-items: flex-end; gap: 2px; padding: 0 20px;">
        <div style="flex:1; background: rgba(74,222,128,0.3); height: ${Math.min(n,100)}%; border-radius: 4px 4px 0 0; min-height: 4px; transition: height 0.3s;" />
        <div style="flex:1; background: rgba(255,255,255,0.06); height: 100%; border-radius: 4px 4px 0 0;" />
      </div>
      <div class="keeper-chart-meta">
        Context usage: <span class=${a}>${n}%</span>
        ${n>70?o` — <span class="warn">Compaction soon</span>`:null}
        ${n>85?o` — <span class="bad">Handoff imminent</span>`:null}
      </div>
    </div>
  `}const be=v("");function Zs({keeper:t}){var s,i;const e=be.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji??"-"},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((s=t.traits)==null?void 0:s.join(", "))||"-"},{title:"Interests",key:"interests",value:((i=t.interests)==null?void 0:i.join(", "))||"-"}],a=e?n.filter(r=>r.title.toLowerCase().includes(e)||r.key.includes(e)||r.value.toLowerCase().includes(e)):n;return o`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${be.value}
        onInput=${r=>{be.value=r.target.value}}
      />
      ${a.map(r=>o`
        <div class="keeper-field-row">
          <span class="keeper-field-title">${r.title}</span>
          <span class="keeper-field-key">${r.key}</span>
          <span style="flex:1; text-align:right; color:#ccc;">${r.value}</span>
        </div>
      `)}
    </div>
  `}function ti({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return o`
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
  `}function ei({items:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No equipment</div>`:o`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>o`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function ni({rels:t}){const e=Object.entries(t);return e.length===0?o`<div class="empty-state" style="font-size:13px">No relationships</div>`:o`
    <div class="keeper-k2k-list">
      ${e.map(([n,a])=>o`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${a}</span>
        </div>
      `)}
    </div>
  `}function kn({traits:t,label:e}){return t.length===0?null:o`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>o`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function ke(t){return t==null||Number.isNaN(t)?"-":`${Math.round(t*100)}%`}function ai({keeper:t}){const e=t.metrics_window,n=[{label:"Model fallback",value:ke(typeof(e==null?void 0:e.model_fallback_rate)=="number"?e.model_fallback_rate:void 0)},{label:"Proactive fallback",value:ke(typeof(e==null?void 0:e.proactive_fallback_rate)=="number"?e.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:ke(typeof(e==null?void 0:e.memory_pass_rate)=="number"?e.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(e==null?void 0:e.handoff_count)=="number"?e.handoff_count:t.handoff_count_total??"-"},{label:"Compactions",value:typeof(e==null?void 0:e.compaction_events)=="number"?e.compaction_events:t.compaction_count??"-"},{label:"Saved tokens",value:typeof(e==null?void 0:e.compaction_saved_tokens)=="number"?e.compaction_saved_tokens:t.last_compaction_saved_tokens??"-"},{label:"K2K events",value:t.k2k_count??"-"},{label:"Conversation tail",value:t.conversation_tail_count??"-"}];return o`
    <div class="keeper-signal-list">
      ${n.map(a=>o`
        <div class="keeper-signal-row">
          <span>${a.label}</span>
          <strong>${a.value}</strong>
        </div>
      `)}
    </div>
  `}function si(){var e,n,a;const t=Ye.value;return t?o`
    <div
      class="keeper-detail-overlay"
      style="position:fixed; inset:0; z-index:1000; background:rgba(0,0,0,0.7); display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${s=>{s.target.classList.contains("keeper-detail-overlay")&&bn()}}
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
            <${V} status=${t.status} />
            ${t.model?o`<span class="pill">${t.model}</span>`:null}
          </div>
          <button
            onClick=${()=>bn()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${Qs} keeper=${t} />

        ${""}
        <${Ys} keeper=${t} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${g} title="Field Dictionary">
            <${Zs} keeper=${t} />
          <//>

          ${""}
          <${g} title="Profile">
            <${kn} traits=${t.traits??[]} label="Traits" />
            <${kn} traits=${t.interests??[]} label="Interests" />
            ${t.primaryValue?o`<div style="font-size:12px; color:#888;">Primary value: <span style="color:#4ade80;">${t.primaryValue}</span></div>`:null}
            ${t.skill_primary?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Skill route: <span style="color:#22d3ee;">${t.skill_primary}</span>
                </div>`:null}
            ${t.skill_reason?o`<div style="font-size:12px; color:#888; margin-top:4px;">${t.skill_reason}</div>`:null}
            ${t.last_heartbeat?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Last heartbeat: <${J} timestamp=${t.last_heartbeat} />
                </div>`:null}
          <//>

          ${""}
          ${t.trpg_stats?o`
              <${g} title="TRPG Stats">
                <${ti} stats=${t.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?o`
              <${g} title="Equipment (${t.inventory.length})">
                <${ei} items=${t.inventory} />
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?o`
              <${g} title="Relationships (${Object.keys(t.relationships).length})">
                <${ni} rels=${t.relationships} />
              <//>
            `:null}

          <${g} title="Runtime Signals">
            <${ai} keeper=${t} />
          <//>

          <${g} title="Memory & Context">
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
      </div>
    </div>
  `:null}let ii=0;const tt=v([]);function k(t,e="success",n=4e3){const a=++ii;tt.value=[...tt.value,{id:a,message:t,type:e}],setTimeout(()=>{tt.value=tt.value.filter(s=>s.id!==a)},n)}function oi(t){tt.value=tt.value.filter(e=>e.id!==t)}function ri(){const t=tt.value;return t.length===0?null:o`
    <div class="toast-container">
      ${t.map(e=>o`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>oi(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}const li="masc_dashboard_agent_name",pt=v(null),se=v(!1),Mt=v(""),ie=v([]),jt=v([]),rt=v(""),kt=v(!1);function Ca(t){pt.value=t,Ze()}function xn(){pt.value=null,Mt.value="",ie.value=[],jt.value=[],rt.value=""}function ci(){const t=pt.value;return t?vt.value.find(e=>e.name===t)??null:null}function Ta(t){return t?zt.value.filter(e=>e.assignee===t):[]}async function Ze(){const t=pt.value;if(t){se.value=!0,Mt.value="",ie.value=[],jt.value=[];try{const e=await Ls(80);ie.value=e.filter(s=>s.includes(t)).slice(0,20);const n=Ta(t).slice(0,6);if(n.length===0)return;const a=await Promise.all(n.map(async s=>{try{const i=await Is(s.id,25);return{taskId:s.id,text:i.trim()}}catch(i){const r=i instanceof Error?i.message:"history load failed";return{taskId:s.id,text:`Failed to load history: ${r}`}}}));jt.value=a}catch(e){Mt.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{se.value=!1}}}async function wn(){var a;const t=pt.value,e=rt.value.trim();if(!t||!e)return;const n=((a=localStorage.getItem(li))==null?void 0:a.trim())||"dashboard";kt.value=!0;try{await ha(n,`@${t} ${e}`),rt.value="",k(`Mention sent to ${t}`,"success"),Ze()}catch(s){const i=s instanceof Error?s.message:"Failed to send mention";k(i,"error")}finally{kt.value=!1}}function ui({task:t}){return o`
    <div class="agent-detail-task">
      <span class="pill">${t.id}</span>
      <span class="agent-detail-task-title">${t.title}</span>
      <${V} status=${t.status} />
    </div>
  `}function di({row:t}){return o`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${t.taskId}</span>
      </div>
      <pre class="agent-history-pre">${t.text||"No task history yet"}</pre>
    </div>
  `}function vi(){const t=pt.value;if(!t)return null;const e=ci(),n=Ta(t),a=ie.value;return o`
    <div
      class="agent-detail-overlay"
      onClick=${s=>{s.target.classList.contains("agent-detail-overlay")&&xn()}}
    >
      <div class="agent-detail-modal">
        <div class="agent-detail-header">
          <div>
            <h2>${t}</h2>
            <div class="agent-detail-sub">
              ${e?o`
                    <${V} status=${e.status} />
                    ${e.current_task?o`<span>Task: ${e.current_task}</span>`:null}
                    ${e.last_seen?o`<span>Last seen: <${J} timestamp=${e.last_seen} /></span>`:null}
                  `:o`<span>Agent snapshot not found in current state</span>`}
            </div>
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{Ze()}} disabled=${se.value}>
              ${se.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${xn}>Close</button>
          </div>
        </div>

        ${Mt.value?o`<div class="council-error">${Mt.value}</div>`:null}

        <div class="agent-detail-grid">
          <${g} title="Assigned Tasks">
            ${n.length===0?o`<div class="empty-state">No assigned tasks</div>`:o`<div class="agent-detail-task-list">${n.map(s=>o`<${ui} key=${s.id} task=${s} />`)}</div>`}
          <//>

          <${g} title="Recent Activity">
            ${a.length===0?o`<div class="empty-state">No recent room activity match</div>`:o`<div class="agent-activity-list">${a.map((s,i)=>o`<div key=${i} class="agent-activity-line">${s}</div>`)}</div>`}
          <//>
        </div>

        <${g} title="Task History">
          ${jt.value.length===0?o`<div class="empty-state">No task history loaded</div>`:o`<div class="agent-history-list">${jt.value.map(s=>o`<${di} key=${s.taskId} row=${s} />`)}</div>`}
        <//>

        <${g} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${rt.value}
              onInput=${s=>{rt.value=s.target.value}}
              onKeyDown=${s=>{s.key==="Enter"&&wn()}}
              disabled=${kt.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{wn()}}
              disabled=${kt.value||rt.value.trim()===""}
            >
              ${kt.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}function at({label:t,value:e,color:n}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color: ${n}`:""}>${e}</div>
    </div>
  `}function pi({agent:t}){return o`
    <button class="agent" onClick=${()=>Ca(t.name)}>
      <span class="agent-emoji">${t.emoji??""}</span>
      <span class="agent-status ${t.status}"></span>
      <span class="agent-name">${t.name}</span>
      <${V} status=${t.status} />
      ${t.current_task?o`<span class="agent-task">${t.current_task}</span>`:null}
    </button>
  `}function fi({keeper:t}){var n;const e=t.context_ratio??((n=t.context)==null?void 0:n.context_ratio);return o`
    <button class="live-agent keeper-card" onClick=${()=>Sa(t)}>
      <div class="live-agent-main">
        <div class="live-agent-title">
          <span class="live-agent-name">${t.emoji??""} ${t.name}</span>
          <${V} status=${t.status} />
          ${t.model?o`<span class="pill">${t.model}</span>`:null}
        </div>
        <div class="live-agent-sub">${t.koreanName??""}</div>
        ${t.generation!=null?o`<div class="live-agent-meta">
              <span>Gen ${t.generation}</span>
              <span>Turn ${t.turn_count??0}</span>
              ${e!=null?o`<span class=${e>.7?"warn-metric":""}>
                    Ctx ${Math.round(e*100)}%
                  </span>`:null}
            </div>`:null}
      </div>
    </button>
  `}function Sn(){const t=Qe.value,e=vt.value,n=_e.value,a=ka.value;return o`
    <div class="stats-grid">
      <${at} label="Agents" value=${e.length} />
      <${at} label="Active" value=${Us.value.length} color="#4ade80" />
      <${at} label="Keepers" value=${n.length} color="#22d3ee" />
      <${at} label="Tasks" value=${zt.value.length} />
      <${at} label="In Progress" value=${a.inProgress.length} color="#fbbf24" />
      <${at} label="Done" value=${a.done.length} color="#4ade80" />
    </div>

    <div class="grid-2col">
      <${g} title="Agents" class="section">
        <div class="agent-list">
          ${e.length===0?o`<div class="empty-state">No agents connected</div>`:e.map(s=>o`<${pi} key=${s.name} agent=${s} />`)}
        </div>
      <//>

      <${g} title="Keepers" class="section">
        <div class="live-agent-list">
          ${n.length===0?o`<div class="empty-state">No keepers active</div>`:n.map(s=>o`<${fi} key=${s.name} keeper=${s} />`)}
        </div>
      <//>
    </div>

    ${mt.value?o`
        <${g} title="Perpetual Runtime" class="section">
          <div class="live-agent-meta">
            <span>Status: ${mt.value.running?"Running":"Stopped"}</span>
            ${mt.value.goal?o`<span>Goal: ${mt.value.goal}</span>`:null}
          </div>
        <//>
      `:null}

    ${t!=null&&t.room?o`
        <${g} title="Room" class="section">
          <div class="live-agent-meta">
            <span>Room: ${t.room}</span>
            <span>Uptime: ${_i(t.uptime_seconds??0)}</span>
          </div>
        <//>
      `:null}

    ${t?o`
        <${g} title="Runtime Health" class="section">
          <div class="live-agent-meta">
            ${t.cluster?o`<span>Cluster: ${t.cluster}</span>`:null}
            ${t.project?o`<span>Project: ${t.project}</span>`:null}
            ${t.tempo_interval_s!=null?o`<span>Tempo: ${t.tempo_interval_s}s</span>`:null}
            ${t.paused!=null?o`<span>Paused: ${t.paused?"Yes":"No"}</span>`:null}
          </div>
          ${t.tool_call_health?o`
              <div class="live-agent-meta" style="margin-top:8px;">
                <span>Tool timeouts: ${t.tool_call_health.timeouts}</span>
                <span>
                  Tool p95:
                  ${t.tool_call_health.p95_duration_ms!=null?`${Math.round(t.tool_call_health.p95_duration_ms)}ms`:"N/A"}
                </span>
                <span>Window: ${t.tool_call_health.window_hours}h</span>
              </div>
            `:null}
        <//>
      `:null}
  `}function _i(t){if(!t)return"N/A";const e=Math.floor(t/3600),n=Math.floor(t%3600/60);return e>0?`${e}h ${n}m`:`${n}m`}const He=v([]),Ue=v([]),xt=v(""),oe=v(!1),wt=v(!1),re=v(""),le=v(null),St=v(""),Fe=v(!1);async function ze(){oe.value=!0,re.value="";try{const[t,e]=await Promise.all([Ms(),js()]);He.value=t,Ue.value=e}catch(t){re.value=t instanceof Error?t.message:"Failed to load council data"}finally{oe.value=!1}}async function Cn(){const t=xt.value.trim();if(t){wt.value=!0;try{const e=await Os(t);xt.value="",k(e!=null&&e.id?`Debate started: ${e.id}`:"Debate started","success"),await ze()}catch(e){const n=e instanceof Error?e.message:"Failed to start debate";k(n,"error")}finally{wt.value=!1}}}async function mi(t){le.value=t,Fe.value=!0,St.value="";try{St.value=await Hs(t)}catch(e){St.value=e instanceof Error?e.message:"Failed to load debate status"}finally{Fe.value=!1}}function hi({debate:t}){const e=le.value===t.id;return o`
    <button
      class="council-row ${e?"selected":""}"
      onClick=${()=>mi(t.id)}
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
  `}function $i({session:t}){return o`
    <div class="council-row session">
      <div class="council-row-main">
        <div class="council-topic">${t.topic}</div>
        <div class="council-sub">
          <span>ID: ${t.id.slice(0,10)}</span>
          <span>Initiator: ${t.initiator}</span>
        </div>
      </div>
      <span class="council-state vote">${t.votes}/${t.quorum}</span>
    </div>
  `}function gi(){return Yt(()=>{ze()},[]),o`
    <div>
      <${g} title="Council Command" class="section">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${xt.value}
            onInput=${t=>{xt.value=t.target.value}}
            onKeyDown=${t=>{t.key==="Enter"&&Cn()}}
            disabled=${wt.value}
          />
          <button
            class="control-btn secondary"
            onClick=${Cn}
            disabled=${wt.value||xt.value.trim()===""}
          >
            ${wt.value?"Starting...":"Start Debate"}
          </button>
          <button class="control-btn ghost" onClick=${ze} disabled=${oe.value}>
            ${oe.value?"Refreshing...":"Refresh"}
          </button>
        </div>
        ${re.value?o`<div class="council-error">${re.value}</div>`:null}
      <//>

      <div class="council-grid">
        <${g} title="Debates" class="section">
          <div class="council-list">
            ${He.value.length===0?o`<div class="empty-state">No debates yet</div>`:He.value.map(t=>o`<${hi} key=${t.id} debate=${t} />`)}
          </div>
        <//>

        <${g} title="Voting Sessions" class="section">
          <div class="council-list">
            ${Ue.value.length===0?o`<div class="empty-state">No active sessions</div>`:Ue.value.map(t=>o`<${$i} key=${t.id} session=${t} />`)}
          </div>
        <//>
      </div>

      <${g} title=${le.value?`Debate Detail (${le.value})`:"Debate Detail"} class="section">
        ${Fe.value?o`<div class="loading-indicator">Loading debate detail...</div>`:St.value?o`<pre class="council-detail">${St.value}</pre>`:o`<div class="empty-state">Select a debate to view summary</div>`}
      <//>
    </div>
  `}function yi({text:t}){if(!t)return null;const e=bi(t);return o`<div class="markdown-content">${e}</div>`}function bi(t){const e=t.split(`
`),n=[];let a=0;for(;a<e.length;){const s=e[a];if(/^(`{3,}|~{3,})/.test(s)){const r=s.match(/^(`{3,}|~{3,})/)[0],u=s.slice(r.length).trim(),d=[];for(a++;a<e.length&&!e[a].startsWith(r);)d.push(e[a]),a++;a++,n.push(o`<pre><code class=${u?`language-${u}`:""}>${d.join(`
`)}</code></pre>`);continue}if(s.trim()==="<think>"||s.trim().startsWith("<think>")){const r=[],u=s.trim().replace(/^<think>/,"").trim();for(u&&u!=="</think>"&&r.push(u),a++;a<e.length&&!e[a].includes("</think>");)r.push(e[a]),a++;if(a<e.length){const c=e[a].replace("</think>","").trim();c&&r.push(c),a++}const d=r.join(`
`).trim();n.push(o`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${xe(d)}</div>
        </details>
      `);continue}if(s.startsWith("> ")){const r=[];for(;a<e.length&&e[a].startsWith("> ");)r.push(e[a].slice(2)),a++;n.push(o`<blockquote>${xe(r.join(`
`))}</blockquote>`);continue}if(s.trim()===""){a++;continue}const i=[];for(;a<e.length;){const r=e[a];if(r.trim()===""||/^(`{3,}|~{3,})/.test(r)||r.startsWith("> ")||r.trim().startsWith("<think>"))break;i.push(r),a++}i.length>0&&n.push(o`<p>${xe(i.join(`
`))}</p>`)}return n}function xe(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let a=0,s;for(;(s=n.exec(t))!==null;){if(s.index>a&&e.push(t.slice(a,s.index)),s[1]){const i=s[1].slice(1,-1);e.push(o`<code>${i}</code>`)}else if(s[2]){const i=s[2].slice(2,-2);e.push(o`<strong>${i}</strong>`)}else if(s[3]){const i=s[3].slice(1,-1);e.push(o`<em>${i}</em>`)}else s[4]&&s[5]&&e.push(o`<a href=${s[5]} target="_blank" rel="noopener">${s[4]}</a>`);a=s.index+s[0].length}return a<t.length&&e.push(t.slice(a)),e.length>0?e:[t]}const ki=[{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"recent",label:"Recent"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],Ct=v([]),Tt=v(!1),At=v(""),xi=v("dashboard-user"),Nt=v(!1);async function Aa(t){Tt.value=!0,Ct.value=[];try{const e=await hs(t);Ct.value=e.comments??[]}catch{}finally{Tt.value=!1}}async function Tn(t){const e=At.value.trim();if(e){Nt.value=!0;try{await $s(t,xi.value,e),At.value="",k("Comment posted","success"),await Aa(t),nt()}catch{k("Failed to post comment","error")}finally{Nt.value=!1}}}function wi(){const t=yn.value;return o`
    <div class="board-controls">
      ${ki.map(e=>o`
        <button
          class="board-sort-btn ${t===e.id?"active":""}"
          onClick=${()=>{yn.value=e.id,nt()}}
        >
          ${e.label}
        </button>
      `)}
    </div>
  `}function Na({flair:t}){return t?o`<span class="post-flair ${t}">${t}</span>`:null}function Si({post:t}){const e=async(n,a)=>{a.stopPropagation();try{await ma(t.id,n),nt()}catch{k("Failed to vote","error")}};return o`
    <div class="board-post" onClick=${()=>Ya(t.id)}>
      <div class="vote-column">
        <button class="vote-btn upvote" onClick=${n=>e("up",n)}>▲</button>
        <span class="vote-count">${t.votes??0}</span>
        <button class="vote-btn downvote" onClick=${n=>e("down",n)}>▼</button>
      </div>
      <div class="post-content">
        <div class="post-title">
          ${t.title}
          ${" "}
          <${Na} flair=${t.flair} />
        </div>
        <div class="post-meta">
          <span>${t.author}</span>
          <${J} timestamp=${t.created_at} />
          ${t.comment_count>0?o`<span>${t.comment_count} comments</span>`:null}
          ${(t.hearth_count??0)>0?o`<span>♥ ${t.hearth_count}</span>`:null}
        </div>
      </div>
    </div>
  `}function Ci({comments:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No comments yet</div>`:o`
    <div class="comment-thread">
      ${t.map(e=>o`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${J} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function Ti({postId:t}){return o`
    <div class="comment-form" style="margin-top: 12px; display: flex; gap: 8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${At.value}
        onInput=${e=>{At.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&Tn(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${Nt.value}
      />
      <button
        onClick=${()=>Tn(t)}
        disabled=${Nt.value||At.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${Nt.value?"...":"Post"}
      </button>
    </div>
  `}function Ai({post:t}){Ct.value.length===0&&!Tt.value&&Aa(t.id);const e=async n=>{try{await ma(t.id,n),nt()}catch{k("Failed to vote","error")}};return o`
    <div>
      <button class="back-btn" onClick=${()=>fe("board")}>← Back to Board</button>
      <${g} title=${o`${t.title} <${Na} flair=${t.flair} />`}>
        <div class="board-detail">
          <div class="post-body">
            <${yi} text=${t.content} />
          </div>
          <div class="post-meta" style="margin-top: 12px;">
            <span>${t.author}</span>
            <${J} timestamp=${t.created_at} />
            <span>${t.votes??0} votes</span>
            ${(t.hearth_count??0)>0?o`<span>♥ ${t.hearth_count}</span>`:null}
          </div>
          <div style="margin-top: 8px; display: flex; gap: 6px;">
            <button class="vote-btn upvote" onClick=${()=>e("up")}>▲ Upvote</button>
            <button class="vote-btn downvote" onClick=${()=>e("down")}>▼ Downvote</button>
          </div>
        </div>
      <//>

      <${g} title="Comments (${Tt.value?"...":Ct.value.length})">
        ${Tt.value?o`<div class="loading-indicator">Loading comments...</div>`:o`<${Ci} comments=${Ct.value} />`}
        <${Ti} postId=${t.id} />
      <//>
    </div>
  `}function Ni(){const t=ya.value,e=je.value,n=H.value.postId;if(n){const a=t.find(s=>s.id===n);return a?o`<${Ai} post=${a} />`:o`
          <div>
            <button class="back-btn" onClick=${()=>fe("board")}>← Back to Board</button>
            <div class="empty-state">Post not found</div>
          </div>
        `}return o`
    <${wi} />
    ${e?o`<div class="loading-indicator">Loading board...</div>`:t.length===0?o`<div class="empty-state">No posts yet</div>`:o`<div class="board-post-list">
            ${t.map(a=>o`<${Si} key=${a.id} post=${a} />`)}
          </div>`}
  `}function Di(t,e){return{id:t.id??`msg-${t.seq??e}`,source:"message",actor:t.from??"system",content:t.content,timestamp:t.timestamp}}function Pi(t,e){return{id:`evt-${t.timestamp}-${e}`,source:"event",actor:t.agent||"system",content:t.text,timestamp:new Date(t.timestamp).toISOString()}}function An(t){const e=Date.parse(t);return Number.isNaN(e)?0:e}function Ei({row:t}){return o`
    <div class="message-row">
      <span class="message-agent">${t.actor}</span>
      <span class="message-source ${t.source}">${t.source}</span>
      <span class="message-text">${t.content}</span>
      <span class="message-time"><${J} timestamp=${t.timestamp} /></span>
    </div>
  `}function Ri(){const t=ga.value.map(Di),e=ae.value.map(Pi),n=[...t,...e].sort((a,s)=>An(s.timestamp)-An(a.timestamp)).slice(0,80);return o`
    <div class="section">
      <h2>Recent Activity</h2>
      <div class="message-list">
        ${n.length===0?o`<div class="empty-state">No recent activity</div>`:n.map(a=>o`<${Ei} key=${a.id} row=${a} />`)}
      </div>
    </div>
  `}function Li({agent:t}){return o`
    <button class="agent-card ${t.status}" onClick=${()=>Ca(t.name)}>
      <div class="agent-card-header">
        <span class="agent-emoji">${t.emoji??""}</span>
        <div class="agent-card-info">
          <span class="agent-name">${t.name}</span>
          ${t.koreanName?o`<span class="agent-korean">${t.koreanName}</span>`:null}
        </div>
        <${V} status=${t.status} />
      </div>
      ${t.current_task?o`<div class="agent-task">${t.current_task}</div>`:null}
      ${t.model?o`<div class="agent-model"><span class="pill">${t.model}</span></div>`:null}
    </button>
  `}function Ii({keeper:t}){const e=t.context_ratio!=null?Math.round(t.context_ratio*100):null,n=e!=null?e>80?"bad":e>60?"warn":"":"";return o`
    <div class="live-agent keeper-card" onClick=${()=>Sa(t)} style="cursor:pointer;">
      <div class="live-agent-main">
        <div class="live-agent-title">
          <span class="live-agent-name">${t.emoji??""} ${t.name}</span>
          <${V} status=${t.status} />
          ${t.model?o`<span class="pill">${t.model}</span>`:null}
        </div>
        ${t.koreanName?o`<div class="live-agent-sub">${t.koreanName}</div>`:null}
        <div class="live-agent-meta">
          ${t.generation!=null?o`<span>Gen ${t.generation}</span>`:null}
          ${t.turn_count!=null?o`<span>Turn ${t.turn_count}</span>`:null}
          ${e!=null?o`<span class=${n?`${n}-metric`:""}>Ctx ${e}%</span>`:null}
        </div>
        ${e!=null?o`<div class="ctx-bar"><div class="ctx-fill ${n}" style="width: ${e}%"></div></div>`:null}
      </div>
    </div>
  `}function Mi(){const t=vt.value,e=_e.value;return o`
    <div>
      ${e.length>0?o`
          <div class="section" style="margin-bottom: 20px">
            <h2>Keepers (Live)</h2>
            <div class="live-agent-list">
              ${e.map(n=>o`<${Ii} key=${n.name} keeper=${n} />`)}
            </div>
          </div>
        `:null}

      <div class="section">
        <h2>All Agents</h2>
        ${t.length===0?o`<div class="empty-state">No agents registered</div>`:o`
            <div class="agent-grid">
              ${t.map(n=>o`<${Li} key=${n.name} agent=${n} />`)}
            </div>
          `}
      </div>
    </div>
  `}function we({task:t}){return o`
    <div class="task-row">
      <${V} status=${t.status} />
      <div class="task-info">
        <span class="task-title">${t.title}</span>
        ${t.assignee?o`<span class="task-assignee">${t.assignee}</span>`:null}
      </div>
      ${t.created_at?o`<${J} timestamp=${t.created_at} />`:null}
    </div>
  `}function ji(){const{todo:t,inProgress:e,done:n}=ka.value;return o`
    <div class="grid-2col">
      <${g} title="In Progress (${e.length})" class="section">
        <div class="task-list">
          ${e.length===0?o`<div class="empty-state">No tasks in progress</div>`:e.map(a=>o`<${we} key=${a.id} task=${a} />`)}
        </div>
      <//>

      <${g} title="To Do (${t.length})" class="section">
        <div class="task-list">
          ${t.length===0?o`<div class="empty-state">No pending tasks</div>`:t.map(a=>o`<${we} key=${a.id} task=${a} />`)}
        </div>
      <//>
    </div>

    ${n.length>0?o`
        <${g} title="Done (${n.length})" class="section" style="margin-top: 20px">
          <div class="task-list">
            ${n.slice(0,20).map(a=>o`<${we} key=${a.id} task=${a} />`)}
            ${n.length>20?o`<div class="empty-state">...and ${n.length-20} more</div>`:null}
          </div>
        <//>
      `:null}
  `}function Oi({event:t}){const n={agent_joined:"#4ade80",agent_left:"#ef4444",broadcast:"#22d3ee",task_update:"#fbbf24",board_post:"#a78bfa",board_comment:"#a78bfa",heartbeat:"#666"}[t.type]??"#888",a=t.message??t.content??t.status??"";return o`
    <div class="journal-entry">
      <span class="journal-type" style="color: ${n}">${t.type}</span>
      <span class="journal-agent">${t.agent??t.from??t.from_agent??""}</span>
      <span class="journal-data">${a}</span>
    </div>
  `}function Hi(){const t=ae.value;return o`
    <div class="section">
      <h2>Event Journal</h2>
      <div class="journal-list">
        ${t.length===0?o`<div class="empty-state">No events recorded yet</div>`:t.map((e,n)=>o`<${Oi} key=${n} event=${e} />`)}
      </div>
    </div>
  `}const _t=v(""),Se=v("ability_check"),Ce=v("10"),Te=v("12"),Vt=v(""),Wt=v("idle");function Ui(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function Fi(t,e){return e>0?Math.round(t/e*100):0}function zi({hp:t,max:e}){const n=Fi(t,e),a=Ui(t,e);return o`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${a}" style="width:${n}%" />
    </div>
  `}function Bi({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return o`
    <div class="trpg-actor-stats">
      ${e.map(n=>o`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function Ki({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return o`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function Vi({actor:t}){return o`
    <div class="trpg-actor">
      <div class="trpg-actor-info">
        <span class="trpg-actor-name">${t.name}</span>
        <${V} status=${t.status??"idle"} />
        <span class="pill">${t.role}</span>
        <${Ki} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?o`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?o`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${zi} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${Bi} stats=${t.stats} />
          </div>
        `:null}
    </div>
  `}function Wi({mapStr:t}){return o`<pre class="trpg-map">${t}</pre>`}function Gi({events:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No story events yet</div>`:o`
    <div class="trpg-story">
      ${t.slice(-30).map((e,n)=>{var a;return o`
        <div key=${n} class="trpg-event ${e.type??""}">
          ${e.actor?o`<strong>${e.actor}</strong>${" "}`:null}
          ${e.dice_roll?o`<span class="trpg-dice">[${e.dice_roll.notation}: ${(a=e.dice_roll.rolls)==null?void 0:a.join(",")} = ${e.dice_roll.total}${e.dice_roll.modifier?` +${e.dice_roll.modifier}`:""}]</span>${" "}`:null}
          <span class="trpg-event-text">${e.content??""}</span>
          <span style="float:right; font-size:10px; color:#555;"><${J} timestamp=${e.timestamp} /></span>
        </div>
      `})}
    </div>
  `}function Ji({state:t}){const e=t.history??[];return e.length===0?null:o`
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
  `}function qi({state:t}){var d;const e=gt.value||((d=t.session)==null?void 0:d.room)||"",n=Wt.value,a=t.party??[];if(!a.find(c=>c.id===_t.value)&&a.length>0){const c=a[0];c&&(_t.value=c.id)}const i=async()=>{if(!e){k("No room set","error");return}Wt.value="running";try{await As(e),Wt.value="ok",k("Round executed","success"),ot()}catch{Wt.value="error",k("Round failed","error")}},r=async()=>{if(e)try{await Ds(e),k("Turn advanced","success"),ot()}catch{k("Advance failed","error")}},u=async()=>{if(!e)return;const c=_t.value.trim();if(!c){k("Select actor first","warning");return}const p=Number.parseInt(Ce.value,10),l=Number.parseInt(Te.value,10);if(Number.isNaN(p)||Number.isNaN(l)){k("Stat/DC must be numbers","warning");return}const m=Number.parseInt(Vt.value,10),f=Vt.value.trim()===""||Number.isNaN(m)?void 0:m;try{await Ns({roomId:e,actorId:c,action:Se.value.trim()||"ability_check",statValue:p,dc:l,rawD20:f}),k("Dice rolled","success"),ot()}catch{k("Dice roll failed","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            type="text"
            value=${e}
            onInput=${c=>{gt.value=c.target.value}}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${_t.value}
            onChange=${c=>{_t.value=c.target.value}}
          >
            <option value="">Select actor</option>
            ${a.map(c=>o`<option value=${c.id}>${c.name} (${c.id})</option>`)}
          </select>
        </div>

        <div class="trpg-control-field">
          <label>Dice</label>
          <div style="display:grid; grid-template-columns: 1fr 1fr; gap:6px;">
            <input
              type="text"
              value=${Se.value}
              onInput=${c=>{Se.value=c.target.value}}
              placeholder="action"
            />
            <input
              type="text"
              value=${Ce.value}
              onInput=${c=>{Ce.value=c.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              type="text"
              value=${Te.value}
              onInput=${c=>{Te.value=c.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              type="text"
              value=${Vt.value}
              onInput=${c=>{Vt.value=c.target.value}}
              onKeyDown=${c=>{c.key==="Enter"&&u()}}
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
              onClick=${i}
              disabled=${n==="running"}
            >
              ${n==="running"?"Running...":"Run Round"}
            </button>
            <button class="trpg-run-btn secondary" onClick=${r}>
              Next Turn
            </button>
          </div>
        </div>
      </div>

      ${n!=="idle"?o`<div class="trpg-run-status ${n}">${n==="running"?"Processing...":n==="ok"?"Done":"Failed"}</div>`:null}
    </div>
  `}function Xi({state:t}){var n;const e=t.current_round;return e?o`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?o`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function Qi(){var s,i;const t=ba.value;if(Oe.value&&!t)return o`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return o`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>ot()}>Refresh</button>
      </div>
    `;const n=t.party??[],a=t.story_log??[];return o`
    <div>
      ${""}
      <div class="stats-grid" style="margin-bottom:16px;">
        <div class="stat-card">
          <div class="stat-label">Session</div>
          <div class="stat-value" style="font-size:16px;">${((s=t.session)==null?void 0:s.status)??"Active"}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Round</div>
          <div class="stat-value">${((i=t.current_round)==null?void 0:i.round_number)??0}</div>
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

      ${""}
      <${Xi} state=${t} />

      ${""}
      <div class="trpg-layout">
        <div>
          ${""}
          <${g} title="Story Log (${a.length})">
            <${Gi} events=${a} />
          <//>

          ${""}
          ${t.map?o`
              <${g} title="Map" style="margin-top:16px;">
                <${Wi} mapStr=${t.map} />
              <//>`:null}
        </div>

        <div class="trpg-sidebar">
          ${""}
          <${g} title="Controls">
            <${qi} state=${t} />
          <//>

          ${""}
          <${g} title="Party (${n.length})" style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(r=>o`<${Vi} key=${r.id??r.name} actor=${r} />`)}
              ${n.length===0?o`<div class="empty-state" style="font-size:13px">No actors</div>`:null}
            </div>
          <//>

          ${""}
          ${t.history&&t.history.length>0?o`
              <${g} title="History (${t.history.length})" style="margin-top:16px;">
                <${Ji} state=${t} />
              <//>`:null}
        </div>
      </div>
    </div>
  `}const tn="masc_dashboard_agent_name";function Yi(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem(tn);return e??n??"dashboard"}const M=v(Yi()),Dt=v(""),Pt=v(""),ce=v(""),Et=v(!1),st=v(!1),Rt=v(!1),Lt=v(!1),ue=v(!1),he=v(!1);function en(t){const e=t.trim();M.value=e,e&&localStorage.setItem(tn,e)}function Zi(t){const n=(t.split(`
`).find(a=>a.includes(" joined"))??t).match(/✅\s+(\S+)\s+joined/i);return(n==null?void 0:n[1])??null}async function Be(){const t=M.value.trim();if(t){Rt.value=!0;try{const e=await Es(t),n=Zi(e);n&&en(n),he.value=!0,k(`Joined as ${n??t}`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to join room";k(n,"error")}finally{Rt.value=!1}}}async function to(){const t=M.value.trim();if(t){Lt.value=!0;try{await $a(t),he.value=!1,k(`Left room (${t})`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to leave room";k(n,"error")}finally{Lt.value=!1}}}async function eo(){const t=M.value.trim();if(t)try{await $a(t)}catch{}localStorage.removeItem(tn),en("dashboard"),he.value=!1,await Be()}async function no(){const t=M.value.trim();if(t){ue.value=!0;try{await Rs(t),k("Heartbeat sent","success")}catch(e){const n=e instanceof Error?e.message:"Failed to send heartbeat";k(n,"error")}finally{ue.value=!1}}}async function Nn(){const t=M.value.trim(),e=Dt.value.trim();if(!(!t||!e)){Et.value=!0;try{await ha(t,e),Dt.value="",k("Broadcast sent","success")}catch(n){const a=n instanceof Error?n.message:"Failed to send broadcast";k(a,"error")}finally{Et.value=!1}}}async function ao(){const t=Pt.value.trim(),e=ce.value.trim()||"Created from dashboard";if(t){st.value=!0;try{await Ps(t,e,1),Pt.value="",ce.value="",k("Task created","success")}catch(n){const a=n instanceof Error?n.message:"Failed to create task";k(a,"error")}finally{st.value=!1}}}function so(){return Yt(()=>{Be()},[]),o`
    <section class="rail-card control-dock">
      <h3>Control Dock</h3>

      <label class="control-label" for="dock-agent">Agent</label>
      <input
        id="dock-agent"
        class="control-input"
        type="text"
        value=${M.value}
        onInput=${t=>en(t.target.value)}
      />

      <label class="control-label" for="dock-message">Broadcast</label>
      <div class="control-row">
        <input
          id="dock-message"
          class="control-input"
          type="text"
          placeholder="@agent message or room update"
          value=${Dt.value}
          onInput=${t=>{Dt.value=t.target.value}}
          onKeyDown=${t=>{t.key==="Enter"&&Nn()}}
          disabled=${Et.value}
        />
        <button
          class="control-btn"
          onClick=${Nn}
          disabled=${Et.value||Dt.value.trim()===""||M.value.trim()===""}
        >
          ${Et.value?"Sending...":"Send"}
        </button>
      </div>

      <div class="control-row">
        <button
          class="control-btn ghost"
          onClick=${()=>{Be()}}
          disabled=${Rt.value||M.value.trim()===""}
        >
          ${Rt.value?"Joining...":he.value?"Rejoin":"Join"}
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{to()}}
          disabled=${Lt.value||M.value.trim()===""}
        >
          ${Lt.value?"Leaving...":"Leave"}
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{eo()}}
          disabled=${Rt.value||Lt.value}
        >
          Reset ID
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{no()}}
          disabled=${ue.value||M.value.trim()===""}
        >
          ${ue.value?"Pinging...":"Heartbeat"}
        </button>
      </div>

      <label class="control-label" for="dock-task">Quick Task</label>
      <input
        id="dock-task"
        class="control-input"
        type="text"
        placeholder="Task title"
        value=${Pt.value}
        onInput=${t=>{Pt.value=t.target.value}}
        disabled=${st.value}
      />
      <textarea
        class="control-textarea"
        placeholder="Task description (optional)"
        value=${ce.value}
        onInput=${t=>{ce.value=t.target.value}}
        disabled=${st.value}
      ></textarea>
      <button
        class="control-btn secondary"
        onClick=${ao}
        disabled=${st.value||Pt.value.trim()===""}
      >
        ${st.value?"Creating...":"Create Task"}
      </button>
    </section>
  `}function io(){const t=ct.value;return o`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"Live":"Reconnecting..."}</span>
      <span class="event-count">${qe.value} events</span>
    </div>
  `}const oo=[{id:"overview",label:"Overview"},{id:"council",label:"Council"},{id:"board",label:"Board"},{id:"activity",label:"Activity"},{id:"agents",label:"Agents"},{id:"tasks",label:"Tasks"},{id:"journal",label:"Journal"},{id:"trpg",label:"TRPG"}];function ro(){const t=H.value.tab,e=ct.value;return o`
    <aside class="dashboard-rail">
      <section class="rail-card">
        <h3>Views</h3>
        <div class="rail-tab-list">
          ${oo.map(n=>o`
            <button
              class="rail-tab-btn ${t===n.id?"active":""}"
              onClick=${()=>fe(n.id)}
            >
              ${n.label}
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
            <strong>${vt.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Keepers</span>
            <strong>${_e.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Tasks</span>
            <strong>${zt.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Events</span>
            <strong>${qe.value}</strong>
          </div>
        </div>
        <button
          class="rail-refresh-btn"
          onClick=${()=>{me(),t==="board"&&nt(),t==="trpg"&&ot()}}
        >
          Refresh Now
        </button>
      </section>

      <${so} />
    </aside>
  `}function lo(){switch(H.value.tab){case"overview":return o`<${Sn} />`;case"council":return o`<${gi} />`;case"board":return o`<${Ni} />`;case"activity":return o`<${Ri} />`;case"agents":return o`<${Mi} />`;case"tasks":return o`<${ji} />`;case"journal":return o`<${Hi} />`;case"trpg":return o`<${Qi} />`;default:return o`<${Sn} />`}}function co(){return Yt(()=>{Za(),ua(),me();const t=Gs();return Js(),()=>{ls(),t(),qs()}},[]),Yt(()=>{const t=H.value.tab;t==="board"&&nt(),t==="trpg"&&ot()},[H.value.tab]),o`
    <div class="app-shell">
      <header class="dashboard-header">
        <div class="header-title-wrap">
          <h1>
            MASC Dashboard
            <span class="version-badge">SPA</span>
          </h1>
          <p class="header-subtitle">Real-time multi-agent operations console</p>
        </div>
        <div class="header-right">
          <${io} />
          <div class="header-links">
            <a href="/dashboard/lodge">Lodge</a>
            <a href="/dashboard/credits">Credits</a>
          </div>
        </div>
      </header>

      <div class="tab-sticky-wrap">
        <${es} />
      </div>

      <div class="dashboard-layout">
        <main class="dashboard-main">
          ${Me.value&&!ct.value?o`<div class="loading-indicator">Loading dashboard...</div>`:o`<${lo} />`}
        </main>
        <${ro} />
      </div>

      <${si} />
      <${vi} />
      <${ri} />
    </div>
  `}const Dn=document.getElementById("app");Dn&&ja(o`<${co} />`,Dn);
