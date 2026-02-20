(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const s of document.querySelectorAll('link[rel="modulepreload"]'))a(s);new MutationObserver(s=>{for(const i of s)if(i.type==="childList")for(const r of i.addedNodes)r.tagName==="LINK"&&r.rel==="modulepreload"&&a(r)}).observe(document,{childList:!0,subtree:!0});function n(s){const i={};return s.integrity&&(i.integrity=s.integrity),s.referrerPolicy&&(i.referrerPolicy=s.referrerPolicy),s.crossOrigin==="use-credentials"?i.credentials="include":s.crossOrigin==="anonymous"?i.credentials="omit":i.credentials="same-origin",i}function a(s){if(s.ep)return;s.ep=!0;const i=n(s);fetch(s.href,i)}})();var ve,k,Ln,In,Z,rn,Mn,jn,On,Ge,Ae,Ne,jt={},Hn=[],Pa=/acit|ex(?:s|g|n|p|$)|rph|grid|ows|mnc|ntw|ine[ch]|zoo|^ord|itera/i,pe=Array.isArray;function K(t,e){for(var n in e)t[n]=e[n];return t}function We(t){t&&t.parentNode&&t.parentNode.removeChild(t)}function Un(t,e,n){var a,s,i,r={};for(i in e)i=="key"?a=e[i]:i=="ref"?s=e[i]:r[i]=e[i];if(arguments.length>2&&(r.children=arguments.length>3?ve.call(arguments,2):n),typeof t=="function"&&t.defaultProps!=null)for(i in t.defaultProps)r[i]===void 0&&(r[i]=t.defaultProps[i]);return qt(t,r,a,s,null)}function qt(t,e,n,a,s){var i={type:t,props:e,key:n,ref:a,__k:null,__:null,__b:0,__e:null,__c:null,constructor:void 0,__v:s??++Ln,__i:-1,__u:0};return s==null&&k.vnode!=null&&k.vnode(i),i}function Ut(t){return t.children}function gt(t,e){this.props=t,this.context=e}function lt(t,e){if(e==null)return t.__?lt(t.__,t.__i+1):null;for(var n;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null)return n.__e;return typeof t.type=="function"?lt(t):null}function zn(t){var e,n;if((t=t.__)!=null&&t.__c!=null){for(t.__e=t.__c.base=null,e=0;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null){t.__e=t.__c.base=n.__e;break}return zn(t)}}function ln(t){(!t.__d&&(t.__d=!0)&&Z.push(t)&&!Yt.__r++||rn!=k.debounceRendering)&&((rn=k.debounceRendering)||Mn)(Yt)}function Yt(){for(var t,e,n,a,s,i,r,u=1;Z.length;)Z.length>u&&Z.sort(jn),t=Z.shift(),u=Z.length,t.__d&&(n=void 0,a=void 0,s=(a=(e=t).__v).__e,i=[],r=[],e.__P&&((n=K({},a)).__v=a.__v+1,k.vnode&&k.vnode(n),Je(e.__P,n,a,e.__n,e.__P.namespaceURI,32&a.__u?[s]:null,i,s??lt(a),!!(32&a.__u),r),n.__v=a.__v,n.__.__k[n.__i]=n,Kn(i,n,r),a.__e=a.__=null,n.__e!=s&&zn(n)));Yt.__r=0}function Fn(t,e,n,a,s,i,r,u,d,c,p){var l,m,f,C,E,T,w,y=a&&a.__k||Hn,I=e.length;for(d=Ra(n,e,y,d,I),l=0;l<I;l++)(f=n.__k[l])!=null&&(m=f.__i==-1?jt:y[f.__i]||jt,f.__i=l,T=Je(t,f,m,s,i,r,u,d,c,p),C=f.__e,f.ref&&m.ref!=f.ref&&(m.ref&&qe(m.ref,null,f),p.push(f.ref,f.__c||C,f)),E==null&&C!=null&&(E=C),(w=!!(4&f.__u))||m.__k===f.__k?d=Bn(f,d,t,w):typeof f.type=="function"&&T!==void 0?d=T:C&&(d=C.nextSibling),f.__u&=-7);return n.__e=E,d}function Ra(t,e,n,a,s){var i,r,u,d,c,p=n.length,l=p,m=0;for(t.__k=new Array(s),i=0;i<s;i++)(r=e[i])!=null&&typeof r!="boolean"&&typeof r!="function"?(typeof r=="string"||typeof r=="number"||typeof r=="bigint"||r.constructor==String?r=t.__k[i]=qt(null,r,null,null,null):pe(r)?r=t.__k[i]=qt(Ut,{children:r},null,null,null):r.constructor===void 0&&r.__b>0?r=t.__k[i]=qt(r.type,r.props,r.key,r.ref?r.ref:null,r.__v):t.__k[i]=r,d=i+m,r.__=t,r.__b=t.__b+1,u=null,(c=r.__i=La(r,n,d,l))!=-1&&(l--,(u=n[c])&&(u.__u|=2)),u==null||u.__v==null?(c==-1&&(s>p?m--:s<p&&m++),typeof r.type!="function"&&(r.__u|=4)):c!=d&&(c==d-1?m--:c==d+1?m++:(c>d?m--:m++,r.__u|=4))):t.__k[i]=null;if(l)for(i=0;i<p;i++)(u=n[i])!=null&&(2&u.__u)==0&&(u.__e==a&&(a=lt(u)),Gn(u,u));return a}function Bn(t,e,n,a){var s,i;if(typeof t.type=="function"){for(s=t.__k,i=0;s&&i<s.length;i++)s[i]&&(s[i].__=t,e=Bn(s[i],e,n,a));return e}t.__e!=e&&(a&&(e&&t.type&&!e.parentNode&&(e=lt(t)),n.insertBefore(t.__e,e||null)),e=t.__e);do e=e&&e.nextSibling;while(e!=null&&e.nodeType==8);return e}function La(t,e,n,a){var s,i,r,u=t.key,d=t.type,c=e[n],p=c!=null&&(2&c.__u)==0;if(c===null&&u==null||p&&u==c.key&&d==c.type)return n;if(a>(p?1:0)){for(s=n-1,i=n+1;s>=0||i<e.length;)if((c=e[r=s>=0?s--:i++])!=null&&(2&c.__u)==0&&u==c.key&&d==c.type)return r}return-1}function cn(t,e,n){e[0]=="-"?t.setProperty(e,n??""):t[e]=n==null?"":typeof n!="number"||Pa.test(e)?n:n+"px"}function Vt(t,e,n,a,s){var i,r;t:if(e=="style")if(typeof n=="string")t.style.cssText=n;else{if(typeof a=="string"&&(t.style.cssText=a=""),a)for(e in a)n&&e in n||cn(t.style,e,"");if(n)for(e in n)a&&n[e]==a[e]||cn(t.style,e,n[e])}else if(e[0]=="o"&&e[1]=="n")i=e!=(e=e.replace(On,"$1")),r=e.toLowerCase(),e=r in t||e=="onFocusOut"||e=="onFocusIn"?r.slice(2):e.slice(2),t.l||(t.l={}),t.l[e+i]=n,n?a?n.u=a.u:(n.u=Ge,t.addEventListener(e,i?Ne:Ae,i)):t.removeEventListener(e,i?Ne:Ae,i);else{if(s=="http://www.w3.org/2000/svg")e=e.replace(/xlink(H|:h)/,"h").replace(/sName$/,"s");else if(e!="width"&&e!="height"&&e!="href"&&e!="list"&&e!="form"&&e!="tabIndex"&&e!="download"&&e!="rowSpan"&&e!="colSpan"&&e!="role"&&e!="popover"&&e in t)try{t[e]=n??"";break t}catch{}typeof n=="function"||(n==null||n===!1&&e[4]!="-"?t.removeAttribute(e):t.setAttribute(e,e=="popover"&&n==1?"":n))}}function un(t){return function(e){if(this.l){var n=this.l[e.type+t];if(e.t==null)e.t=Ge++;else if(e.t<n.u)return;return n(k.event?k.event(e):e)}}}function Je(t,e,n,a,s,i,r,u,d,c){var p,l,m,f,C,E,T,w,y,I,P,F,S,X,Q,Y,mt,R=e.type;if(e.constructor!==void 0)return null;128&n.__u&&(d=!!(32&n.__u),i=[u=e.__e=n.__e]),(p=k.__b)&&p(e);t:if(typeof R=="function")try{if(w=e.props,y="prototype"in R&&R.prototype.render,I=(p=R.contextType)&&a[p.__c],P=p?I?I.props.value:p.__:a,n.__c?T=(l=e.__c=n.__c).__=l.__E:(y?e.__c=l=new R(w,P):(e.__c=l=new gt(w,P),l.constructor=R,l.render=Ma),I&&I.sub(l),l.state||(l.state={}),l.__n=a,m=l.__d=!0,l.__h=[],l._sb=[]),y&&l.__s==null&&(l.__s=l.state),y&&R.getDerivedStateFromProps!=null&&(l.__s==l.state&&(l.__s=K({},l.__s)),K(l.__s,R.getDerivedStateFromProps(w,l.__s))),f=l.props,C=l.state,l.__v=e,m)y&&R.getDerivedStateFromProps==null&&l.componentWillMount!=null&&l.componentWillMount(),y&&l.componentDidMount!=null&&l.__h.push(l.componentDidMount);else{if(y&&R.getDerivedStateFromProps==null&&w!==f&&l.componentWillReceiveProps!=null&&l.componentWillReceiveProps(w,P),e.__v==n.__v||!l.__e&&l.shouldComponentUpdate!=null&&l.shouldComponentUpdate(w,l.__s,P)===!1){for(e.__v!=n.__v&&(l.props=w,l.state=l.__s,l.__d=!1),e.__e=n.__e,e.__k=n.__k,e.__k.some(function(W){W&&(W.__=e)}),F=0;F<l._sb.length;F++)l.__h.push(l._sb[F]);l._sb=[],l.__h.length&&r.push(l);break t}l.componentWillUpdate!=null&&l.componentWillUpdate(w,l.__s,P),y&&l.componentDidUpdate!=null&&l.__h.push(function(){l.componentDidUpdate(f,C,E)})}if(l.context=P,l.props=w,l.__P=t,l.__e=!1,S=k.__r,X=0,y){for(l.state=l.__s,l.__d=!1,S&&S(e),p=l.render(l.props,l.state,l.context),Q=0;Q<l._sb.length;Q++)l.__h.push(l._sb[Q]);l._sb=[]}else do l.__d=!1,S&&S(e),p=l.render(l.props,l.state,l.context),l.state=l.__s;while(l.__d&&++X<25);l.state=l.__s,l.getChildContext!=null&&(a=K(K({},a),l.getChildContext())),y&&!m&&l.getSnapshotBeforeUpdate!=null&&(E=l.getSnapshotBeforeUpdate(f,C)),Y=p,p!=null&&p.type===Ut&&p.key==null&&(Y=Vn(p.props.children)),u=Fn(t,pe(Y)?Y:[Y],e,n,a,s,i,r,u,d,c),l.base=e.__e,e.__u&=-161,l.__h.length&&r.push(l),T&&(l.__E=l.__=null)}catch(W){if(e.__v=null,d||i!=null)if(W.then){for(e.__u|=d?160:128;u&&u.nodeType==8&&u.nextSibling;)u=u.nextSibling;i[i.indexOf(u)]=null,e.__e=u}else{for(mt=i.length;mt--;)We(i[mt]);De(e)}else e.__e=n.__e,e.__k=n.__k,W.then||De(e);k.__e(W,e,n)}else i==null&&e.__v==n.__v?(e.__k=n.__k,e.__e=n.__e):u=e.__e=Ia(n.__e,e,n,a,s,i,r,d,c);return(p=k.diffed)&&p(e),128&e.__u?void 0:u}function De(t){t&&t.__c&&(t.__c.__e=!0),t&&t.__k&&t.__k.forEach(De)}function Kn(t,e,n){for(var a=0;a<n.length;a++)qe(n[a],n[++a],n[++a]);k.__c&&k.__c(e,t),t.some(function(s){try{t=s.__h,s.__h=[],t.some(function(i){i.call(s)})}catch(i){k.__e(i,s.__v)}})}function Vn(t){return typeof t!="object"||t==null||t.__b&&t.__b>0?t:pe(t)?t.map(Vn):K({},t)}function Ia(t,e,n,a,s,i,r,u,d){var c,p,l,m,f,C,E,T=n.props||jt,w=e.props,y=e.type;if(y=="svg"?s="http://www.w3.org/2000/svg":y=="math"?s="http://www.w3.org/1998/Math/MathML":s||(s="http://www.w3.org/1999/xhtml"),i!=null){for(c=0;c<i.length;c++)if((f=i[c])&&"setAttribute"in f==!!y&&(y?f.localName==y:f.nodeType==3)){t=f,i[c]=null;break}}if(t==null){if(y==null)return document.createTextNode(w);t=document.createElementNS(s,y,w.is&&w),u&&(k.__m&&k.__m(e,i),u=!1),i=null}if(y==null)T===w||u&&t.data==w||(t.data=w);else{if(i=i&&ve.call(t.childNodes),!u&&i!=null)for(T={},c=0;c<t.attributes.length;c++)T[(f=t.attributes[c]).name]=f.value;for(c in T)if(f=T[c],c!="children"){if(c=="dangerouslySetInnerHTML")l=f;else if(!(c in w)){if(c=="value"&&"defaultValue"in w||c=="checked"&&"defaultChecked"in w)continue;Vt(t,c,null,f,s)}}for(c in w)f=w[c],c=="children"?m=f:c=="dangerouslySetInnerHTML"?p=f:c=="value"?C=f:c=="checked"?E=f:u&&typeof f!="function"||T[c]===f||Vt(t,c,f,T[c],s);if(p)u||l&&(p.__html==l.__html||p.__html==t.innerHTML)||(t.innerHTML=p.__html),e.__k=[];else if(l&&(t.innerHTML=""),Fn(e.type=="template"?t.content:t,pe(m)?m:[m],e,n,a,y=="foreignObject"?"http://www.w3.org/1999/xhtml":s,i,r,i?i[0]:n.__k&&lt(n,0),u,d),i!=null)for(c=i.length;c--;)We(i[c]);u||(c="value",y=="progress"&&C==null?t.removeAttribute("value"):C!=null&&(C!==t[c]||y=="progress"&&!C||y=="option"&&C!=T[c])&&Vt(t,c,C,T[c],s),c="checked",E!=null&&E!=t[c]&&Vt(t,c,E,T[c],s))}return t}function qe(t,e,n){try{if(typeof t=="function"){var a=typeof t.__u=="function";a&&t.__u(),a&&e==null||(t.__u=t(e))}else t.current=e}catch(s){k.__e(s,n)}}function Gn(t,e,n){var a,s;if(k.unmount&&k.unmount(t),(a=t.ref)&&(a.current&&a.current!=t.__e||qe(a,null,e)),(a=t.__c)!=null){if(a.componentWillUnmount)try{a.componentWillUnmount()}catch(i){k.__e(i,e)}a.base=a.__P=null}if(a=t.__k)for(s=0;s<a.length;s++)a[s]&&Gn(a[s],e,n||typeof t.type!="function");n||We(t.__e),t.__c=t.__=t.__e=void 0}function Ma(t,e,n){return this.constructor(t,n)}function ja(t,e,n){var a,s,i,r;e==document&&(e=document.documentElement),k.__&&k.__(t,e),s=(a=!1)?null:e.__k,i=[],r=[],Je(e,t=e.__k=Un(Ut,null,[t]),s||jt,jt,e.namespaceURI,s?null:e.firstChild?ve.call(e.childNodes):null,i,s?s.__e:e.firstChild,a,r),Kn(i,t,r)}ve=Hn.slice,k={__e:function(t,e,n,a){for(var s,i,r;e=e.__;)if((s=e.__c)&&!s.__)try{if((i=s.constructor)&&i.getDerivedStateFromError!=null&&(s.setState(i.getDerivedStateFromError(t)),r=s.__d),s.componentDidCatch!=null&&(s.componentDidCatch(t,a||{}),r=s.__d),r)return s.__E=s}catch(u){t=u}throw t}},Ln=0,In=function(t){return t!=null&&t.constructor===void 0},gt.prototype.setState=function(t,e){var n;n=this.__s!=null&&this.__s!=this.state?this.__s:this.__s=K({},this.state),typeof t=="function"&&(t=t(K({},n),this.props)),t&&K(n,t),t!=null&&this.__v&&(e&&this._sb.push(e),ln(this))},gt.prototype.forceUpdate=function(t){this.__v&&(this.__e=!0,t&&this.__h.push(t),ln(this))},gt.prototype.render=Ut,Z=[],Mn=typeof Promise=="function"?Promise.prototype.then.bind(Promise.resolve()):setTimeout,jn=function(t,e){return t.__v.__b-e.__v.__b},Yt.__r=0,On=/(PointerCapture)$|Capture$/i,Ge=0,Ae=un(!1),Ne=un(!0);var Wn=function(t,e,n,a){var s;e[0]=0;for(var i=1;i<e.length;i++){var r=e[i++],u=e[i]?(e[0]|=r?1:2,n[e[i++]]):e[++i];r===3?a[0]=u:r===4?a[1]=Object.assign(a[1]||{},u):r===5?(a[1]=a[1]||{})[e[++i]]=u:r===6?a[1][e[++i]]+=u+"":r?(s=t.apply(u,Wn(t,u,n,["",null])),a.push(s),u[0]?e[0]|=2:(e[i-2]=0,e[i]=s)):a.push(u)}return a},dn=new Map;function Oa(t){var e=dn.get(this);return e||(e=new Map,dn.set(this,e)),(e=Wn(this,e.get(t)||(e.set(t,e=(function(n){for(var a,s,i=1,r="",u="",d=[0],c=function(m){i===1&&(m||(r=r.replace(/^\s*\n\s*|\s*\n\s*$/g,"")))?d.push(0,m,r):i===3&&(m||r)?(d.push(3,m,r),i=2):i===2&&r==="..."&&m?d.push(4,m,0):i===2&&r&&!m?d.push(5,0,!0,r):i>=5&&((r||!m&&i===5)&&(d.push(i,0,r,s),i=6),m&&(d.push(i,m,0,s),i=6)),r=""},p=0;p<n.length;p++){p&&(i===1&&c(),c(p));for(var l=0;l<n[p].length;l++)a=n[p][l],i===1?a==="<"?(c(),d=[d],i=3):r+=a:i===4?r==="--"&&a===">"?(i=1,r=""):r=a+r[0]:u?a===u?u="":r+=a:a==='"'||a==="'"?u=a:a===">"?(c(),i=1):i&&(a==="="?(i=5,s=r,r=""):a==="/"&&(i<5||n[p][l+1]===">")?(c(),i===3&&(d=d[0]),i=d,(d=d[0]).push(2,0,i),i=0):a===" "||a==="	"||a===`
`||a==="\r"?(c(),i=2):r+=a),i===3&&r==="!--"&&(i=4,d=d[0])}return c(),d})(t)),e),arguments,[])).length>1?e:e[0]}var o=Oa.bind(Un),Zt,D,$e,vn,pn=0,Jn=[],A=k,fn=A.__b,_n=A.__r,mn=A.diffed,hn=A.__c,$n=A.unmount,gn=A.__;function qn(t,e){A.__h&&A.__h(D,t,pn||e),pn=0;var n=D.__H||(D.__H={__:[],__h:[]});return t>=n.__.length&&n.__.push({}),n.__[t]}function te(t,e){var n=qn(Zt++,3);!A.__s&&Qn(n.__H,e)&&(n.__=t,n.u=e,D.__H.__h.push(n))}function Xn(t,e){var n=qn(Zt++,7);return Qn(n.__H,e)&&(n.__=t(),n.__H=e,n.__h=t),n.__}function Ha(){for(var t;t=Jn.shift();)if(t.__P&&t.__H)try{t.__H.__h.forEach(Xt),t.__H.__h.forEach(Ee),t.__H.__h=[]}catch(e){t.__H.__h=[],A.__e(e,t.__v)}}A.__b=function(t){D=null,fn&&fn(t)},A.__=function(t,e){t&&e.__k&&e.__k.__m&&(t.__m=e.__k.__m),gn&&gn(t,e)},A.__r=function(t){_n&&_n(t),Zt=0;var e=(D=t.__c).__H;e&&($e===D?(e.__h=[],D.__h=[],e.__.forEach(function(n){n.__N&&(n.__=n.__N),n.u=n.__N=void 0})):(e.__h.forEach(Xt),e.__h.forEach(Ee),e.__h=[],Zt=0)),$e=D},A.diffed=function(t){mn&&mn(t);var e=t.__c;e&&e.__H&&(e.__H.__h.length&&(Jn.push(e)!==1&&vn===A.requestAnimationFrame||((vn=A.requestAnimationFrame)||Ua)(Ha)),e.__H.__.forEach(function(n){n.u&&(n.__H=n.u),n.u=void 0})),$e=D=null},A.__c=function(t,e){e.some(function(n){try{n.__h.forEach(Xt),n.__h=n.__h.filter(function(a){return!a.__||Ee(a)})}catch(a){e.some(function(s){s.__h&&(s.__h=[])}),e=[],A.__e(a,n.__v)}}),hn&&hn(t,e)},A.unmount=function(t){$n&&$n(t);var e,n=t.__c;n&&n.__H&&(n.__H.__.forEach(function(a){try{Xt(a)}catch(s){e=s}}),n.__H=void 0,e&&A.__e(e,n.__v))};var yn=typeof requestAnimationFrame=="function";function Ua(t){var e,n=function(){clearTimeout(a),yn&&cancelAnimationFrame(e),setTimeout(t)},a=setTimeout(n,35);yn&&(e=requestAnimationFrame(n))}function Xt(t){var e=D,n=t.__c;typeof n=="function"&&(t.__c=void 0,n()),D=e}function Ee(t){var e=D;t.__c=t.__(),D=e}function Qn(t,e){return!t||t.length!==e.length||e.some(function(n,a){return n!==t[a]})}var za=Symbol.for("preact-signals");function fe(){if(J>1)J--;else{for(var t,e=!1;yt!==void 0;){var n=yt;for(yt=void 0,Pe++;n!==void 0;){var a=n.o;if(n.o=void 0,n.f&=-3,!(8&n.f)&&ta(n))try{n.c()}catch(s){e||(t=s,e=!0)}n=a}}if(Pe=0,J--,e)throw t}}function Fa(t){if(J>0)return t();J++;try{return t()}finally{fe()}}var g=void 0;function Yn(t){var e=g;g=void 0;try{return t()}finally{g=e}}var yt=void 0,J=0,Pe=0,ee=0;function Zn(t){if(g!==void 0){var e=t.n;if(e===void 0||e.t!==g)return e={i:0,S:t,p:g.s,n:void 0,t:g,e:void 0,x:void 0,r:e},g.s!==void 0&&(g.s.n=e),g.s=e,t.n=e,32&g.f&&t.S(e),e;if(e.i===-1)return e.i=0,e.n!==void 0&&(e.n.p=e.p,e.p!==void 0&&(e.p.n=e.n),e.p=g.s,e.n=void 0,g.s.n=e,g.s=e),e}}function N(t,e){this.v=t,this.i=0,this.n=void 0,this.t=void 0,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}N.prototype.brand=za;N.prototype.h=function(){return!0};N.prototype.S=function(t){var e=this,n=this.t;n!==t&&t.e===void 0&&(t.x=n,this.t=t,n!==void 0?n.e=t:Yn(function(){var a;(a=e.W)==null||a.call(e)}))};N.prototype.U=function(t){var e=this;if(this.t!==void 0){var n=t.e,a=t.x;n!==void 0&&(n.x=a,t.e=void 0),a!==void 0&&(a.e=n,t.x=void 0),t===this.t&&(this.t=a,a===void 0&&Yn(function(){var s;(s=e.Z)==null||s.call(e)}))}};N.prototype.subscribe=function(t){var e=this;return zt(function(){var n=e.value,a=g;g=void 0;try{t(n)}finally{g=a}},{name:"sub"})};N.prototype.valueOf=function(){return this.value};N.prototype.toString=function(){return this.value+""};N.prototype.toJSON=function(){return this.value};N.prototype.peek=function(){var t=g;g=void 0;try{return this.value}finally{g=t}};Object.defineProperty(N.prototype,"value",{get:function(){var t=Zn(this);return t!==void 0&&(t.i=this.i),this.v},set:function(t){if(t!==this.v){if(Pe>100)throw new Error("Cycle detected");this.v=t,this.i++,ee++,J++;try{for(var e=this.t;e!==void 0;e=e.x)e.t.N()}finally{fe()}}}});function v(t,e){return new N(t,e)}function ta(t){for(var e=t.s;e!==void 0;e=e.n)if(e.S.i!==e.i||!e.S.h()||e.S.i!==e.i)return!0;return!1}function ea(t){for(var e=t.s;e!==void 0;e=e.n){var n=e.S.n;if(n!==void 0&&(e.r=n),e.S.n=e,e.i=-1,e.n===void 0){t.s=e;break}}}function na(t){for(var e=t.s,n=void 0;e!==void 0;){var a=e.p;e.i===-1?(e.S.U(e),a!==void 0&&(a.n=e.n),e.n!==void 0&&(e.n.p=a)):n=e,e.S.n=e.r,e.r!==void 0&&(e.r=void 0),e=a}t.s=n}function et(t,e){N.call(this,void 0),this.x=t,this.s=void 0,this.g=ee-1,this.f=4,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}et.prototype=new N;et.prototype.h=function(){if(this.f&=-3,1&this.f)return!1;if((36&this.f)==32||(this.f&=-5,this.g===ee))return!0;if(this.g=ee,this.f|=1,this.i>0&&!ta(this))return this.f&=-2,!0;var t=g;try{ea(this),g=this;var e=this.x();(16&this.f||this.v!==e||this.i===0)&&(this.v=e,this.f&=-17,this.i++)}catch(n){this.v=n,this.f|=16,this.i++}return g=t,na(this),this.f&=-2,!0};et.prototype.S=function(t){if(this.t===void 0){this.f|=36;for(var e=this.s;e!==void 0;e=e.n)e.S.S(e)}N.prototype.S.call(this,t)};et.prototype.U=function(t){if(this.t!==void 0&&(N.prototype.U.call(this,t),this.t===void 0)){this.f&=-33;for(var e=this.s;e!==void 0;e=e.n)e.S.U(e)}};et.prototype.N=function(){if(!(2&this.f)){this.f|=6;for(var t=this.t;t!==void 0;t=t.x)t.t.N()}};Object.defineProperty(et.prototype,"value",{get:function(){if(1&this.f)throw new Error("Cycle detected");var t=Zn(this);if(this.h(),t!==void 0&&(t.i=this.i),16&this.f)throw this.v;return this.v}});function ct(t,e){return new et(t,e)}function aa(t){var e=t.u;if(t.u=void 0,typeof e=="function"){J++;var n=g;g=void 0;try{e()}catch(a){throw t.f&=-2,t.f|=8,Xe(t),a}finally{g=n,fe()}}}function Xe(t){for(var e=t.s;e!==void 0;e=e.n)e.S.U(e);t.x=void 0,t.s=void 0,aa(t)}function Ba(t){if(g!==this)throw new Error("Out-of-order effect");na(this),g=t,this.f&=-2,8&this.f&&Xe(this),fe()}function dt(t,e){this.x=t,this.u=void 0,this.s=void 0,this.o=void 0,this.f=32,this.name=e==null?void 0:e.name}dt.prototype.c=function(){var t=this.S();try{if(8&this.f||this.x===void 0)return;var e=this.x();typeof e=="function"&&(this.u=e)}finally{t()}};dt.prototype.S=function(){if(1&this.f)throw new Error("Cycle detected");this.f|=1,this.f&=-9,aa(this),ea(this),J++;var t=g;return g=this,Ba.bind(this,t)};dt.prototype.N=function(){2&this.f||(this.f|=2,this.o=yt,yt=this)};dt.prototype.d=function(){this.f|=8,1&this.f||Xe(this)};dt.prototype.dispose=function(){this.d()};function zt(t,e){var n=new dt(t,e);try{n.c()}catch(s){throw n.d(),s}var a=n.d.bind(n);return a[Symbol.dispose]=a,a}var sa,Gt,Ka=typeof window<"u"&&!!window.__PREACT_SIGNALS_DEVTOOLS__,ia=[];zt(function(){sa=this.N})();function vt(t,e){k[t]=e.bind(null,k[t]||function(){})}function ne(t){if(Gt){var e=Gt;Gt=void 0,e()}Gt=t&&t.S()}function oa(t){var e=this,n=t.data,a=Ga(n);a.value=n;var s=Xn(function(){for(var u=e,d=e.__v;d=d.__;)if(d.__c){d.__c.__$f|=4;break}var c=ct(function(){var f=a.value.value;return f===0?0:f===!0?"":f||""}),p=ct(function(){return!Array.isArray(c.value)&&!In(c.value)}),l=zt(function(){if(this.N=ra,p.value){var f=c.value;u.__v&&u.__v.__e&&u.__v.__e.nodeType===3&&(u.__v.__e.data=f)}}),m=e.__$u.d;return e.__$u.d=function(){l(),m.call(this)},[p,c]},[]),i=s[0],r=s[1];return i.value?r.peek():r.value}oa.displayName="ReactiveTextNode";Object.defineProperties(N.prototype,{constructor:{configurable:!0,value:void 0},type:{configurable:!0,value:oa},props:{configurable:!0,get:function(){return{data:this}}},__b:{configurable:!0,value:1}});vt("__b",function(t,e){if(typeof e.type=="string"){var n,a=e.props;for(var s in a)if(s!=="children"){var i=a[s];i instanceof N&&(n||(e.__np=n={}),n[s]=i,a[s]=i.peek())}}t(e)});vt("__r",function(t,e){if(t(e),e.type!==Ut){ne();var n,a=e.__c;a&&(a.__$f&=-2,(n=a.__$u)===void 0&&(a.__$u=n=(function(s,i){var r;return zt(function(){r=this},{name:i}),r.c=s,r})(function(){var s;Ka&&((s=n.y)==null||s.call(n)),a.__$f|=1,a.setState({})},typeof e.type=="function"?e.type.displayName||e.type.name:""))),ne(n)}});vt("__e",function(t,e,n,a){ne(),t(e,n,a)});vt("diffed",function(t,e){ne();var n;if(typeof e.type=="string"&&(n=e.__e)){var a=e.__np,s=e.props;if(a){var i=n.U;if(i)for(var r in i){var u=i[r];u!==void 0&&!(r in a)&&(u.d(),i[r]=void 0)}else i={},n.U=i;for(var d in a){var c=i[d],p=a[d];c===void 0?(c=Va(n,d,p),i[d]=c):c.o(p,s)}for(var l in a)s[l]=a[l]}}t(e)});function Va(t,e,n,a){var s=e in t&&t.ownerSVGElement===void 0,i=v(n),r=n.peek();return{o:function(u,d){i.value=u,r=u.peek()},d:zt(function(){this.N=ra;var u=i.value.value;r!==u?(r=void 0,s?t[e]=u:u!=null&&(u!==!1||e[4]==="-")?t.setAttribute(e,u):t.removeAttribute(e)):r=void 0})}}vt("unmount",function(t,e){if(typeof e.type=="string"){var n=e.__e;if(n){var a=n.U;if(a){n.U=void 0;for(var s in a){var i=a[s];i&&i.d()}}}e.__np=void 0}else{var r=e.__c;if(r){var u=r.__$u;u&&(r.__$u=void 0,u.d())}}t(e)});vt("__h",function(t,e,n,a){(a<3||a===9)&&(e.__$f|=2),t(e,n,a)});gt.prototype.shouldComponentUpdate=function(t,e){if(this.__R)return!0;var n=this.__$u,a=n&&n.s!==void 0;for(var s in e)return!0;if(this.__f||typeof this.u=="boolean"&&this.u===!0){var i=2&this.__$f;if(!(a||i||4&this.__$f)||1&this.__$f)return!0}else if(!(a||4&this.__$f)||3&this.__$f)return!0;for(var r in t)if(r!=="__source"&&t[r]!==this.props[r])return!0;for(var u in this.props)if(!(u in t))return!0;return!1};function Ga(t,e){return Xn(function(){return v(t,e)},[])}var Wa=function(t){queueMicrotask(function(){queueMicrotask(t)})};function Ja(){Fa(function(){for(var t;t=ia.shift();)sa.call(t)})}function ra(){ia.push(this)===1&&(k.requestAnimationFrame||Wa)(Ja)}const qa=["overview","board","activity","agents","tasks","journal","trpg","council"],la={tab:"overview",params:{},postId:null};function bn(t){return!!t&&qa.includes(t)}function Re(t){try{return decodeURIComponent(t)}catch{return t}}function Le(t){const e={};return t&&new URLSearchParams(t).forEach((a,s)=>{e[s]=a}),e}function Xa(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function ca(t,e){const n=t[0],a=e.tab,s=bn(n)?n:bn(a)?a:"overview";let i=null;return s==="board"&&(t[0]==="board"&&t[1]==="post"&&t[2]?i=Re(t[2]):t[0]==="post"&&t[1]&&(i=Re(t[1]))),{tab:s,params:e,postId:i}}function ae(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return la;const n=Re(e);let a=n,s;if(n.startsWith("?"))a="",s=n.slice(1);else{const u=n.indexOf("?");u>=0&&(a=n.slice(0,u),s=n.slice(u+1))}!s&&a.includes("=")&&!a.includes("/")&&(s=a,a="");const i=Le(s),r=Xa(a);return ca(r,i)}function Qa(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const a=n.slice(1);if(a.length===0)return{...la,params:Le(e.replace(/^\?/,""))};if(a[0]==="assets"||a[0]==="credits"||a[0]==="lodge")return null;const s=Le(e.replace(/^\?/,""));return ca(a,s)}function ua(t){const e=t.postId?`board/post/${encodeURIComponent(t.postId)}`:t.tab,n=Object.entries(t.params).filter(([s])=>s!=="tab");if(n.length===0)return`#${e}`;const a=new URLSearchParams(n);return`#${e}?${a.toString()}`}const z=v(ae(window.location.hash));window.addEventListener("hashchange",()=>{z.value=ae(window.location.hash)});function _e(t,e){const n={tab:t,params:{},postId:null};window.location.hash=ua(n)}function Ya(t){window.location.hash=`#board/post/${encodeURIComponent(t)}`}function Za(){if(window.location.hash&&window.location.hash!=="#"){z.value=ae(window.location.hash);return}const t=Qa(window.location.pathname,window.location.search);if(t){z.value=t;const e=ua(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#overview",z.value=ae(window.location.hash)}const ts=[{id:"overview",label:"Overview",icon:"🏠"},{id:"council",label:"Council",icon:"🏛️"},{id:"board",label:"Board",icon:"💬"},{id:"activity",label:"Activity",icon:"📊"},{id:"agents",label:"Agents",icon:"🤖"},{id:"tasks",label:"Tasks",icon:"📋"},{id:"journal",label:"Journal",icon:"📓"},{id:"trpg",label:"TRPG",icon:"⚔️"}];function es(){const t=z.value.tab;return o`
    <div class="main-tab-bar">
      ${ts.map(e=>o`
        <button
          class="main-tab-btn ${t===e.id?"active":""}"
          onClick=${()=>_e(e.id)}
        >
          ${e.icon} ${e.label}
        </button>
      `)}
    </div>
  `}const kn="masc_dashboard_sse_session_id",ns=1e3,as=15e3,ut=v(!1),Qe=v(0),da=v(null),se=v([]);function ss(){let t=sessionStorage.getItem(kn);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(kn,t)),t}const is=200;function M(t,e){const n={agent:t,text:e,timestamp:Date.now()};se.value=[n,...se.value].slice(0,is)}let U=null,it=null,Ie=0;function va(){it&&(clearTimeout(it),it=null)}function os(){if(it)return;Ie++;const t=Math.min(Ie,5),e=Math.min(as,ns*Math.pow(2,t));it=setTimeout(()=>{it=null,pa()},e)}function pa(){va(),U&&(U.close(),U=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),a=t.get("token");n&&e.set("agent",n),a&&e.set("token",a),e.set("session_id",ss());const s=e.toString()?`/sse?${e.toString()}`:"/sse",i=new EventSource(s);U=i,i.onopen=()=>{U===i&&(Ie=0,ut.value=!0)},i.onerror=()=>{U===i&&(ut.value=!1,i.close(),U=null,os())},i.onmessage=r=>{try{const u=JSON.parse(r.data);Qe.value++,da.value=u,rs(u)}catch{}}}function rs(t){const e=t.type,n=t.agent??t.from??t.from_agent??"";switch(e){case"agent_joined":M(n,"Joined");break;case"agent_left":M(n,"Left");break;case"broadcast":M(n,`${(t.message??t.content??"").slice(0,80)}`);break;case"task_update":M(n,`Task: ${t.task_id??""} -> ${t.status??""}`);break;case"board_post":M(n,"New post");break;case"board_comment":M(n,"New comment");break;case"keeper_heartbeat":M(t.name??n,`Heartbeat gen=${t.generation??"?"} ctx=${t.context_ratio!=null?Math.round(t.context_ratio*100)+"%":"?"}`);break;case"keeper_handoff":M(t.name??n,`Handoff gen ${t.from_generation??"?"} -> ${t.to_generation??"?"} (${t.to_model??"?"})`);break;case"keeper_compaction":M(t.name??n,`Compaction saved ${t.saved_tokens??"?"} tokens (${t.trigger??"?"})`);break;case"keeper_guardrail":M(t.name??n,`Guardrail: ${t.reason??"stopped"}`);break;default:M(n,e)}}function ls(){va(),U&&(U.close(),U=null),ut.value=!1}function fa(){return new URLSearchParams(window.location.search)}function _a(){const t=fa(),e={},n=t.get("token"),a=t.get("agent")??t.get("agent_name");return n&&(e.Authorization=`Bearer ${n}`),a&&(e["X-MASC-Agent"]=a),e}function ma(){return{..._a(),"Content-Type":"application/json"}}const cs=15e3,ha=3e4,us=6e4;async function Ye(t,e,n){const a=new AbortController,s=setTimeout(()=>a.abort(),n);try{return await fetch(t,{...e,signal:a.signal})}catch(i){if(i instanceof Error&&i.name==="AbortError"){const r=typeof e.method=="string"?e.method.toUpperCase():"GET";throw new Error(`${r} ${t}: timeout after ${n}ms`)}throw i}finally{clearTimeout(s)}}function ds(){var e,n;const t=fa();return((e=t.get("agent"))==null?void 0:e.trim())||((n=t.get("agent_name"))==null?void 0:n.trim())||"dashboard-user"}async function Ft(t){const e=await Ye(t,{headers:_a()},cs);if(!e.ok)throw new Error(`GET ${t}: ${e.status} ${e.statusText}`);return e.json()}async function Bt(t,e){const n=await Ye(t,{method:"POST",headers:ma(),body:JSON.stringify(e)},ha);if(!n.ok)throw new Error(`POST ${t}: ${n.status} ${n.statusText}`);return n.json()}async function vs(t,e,n,a=ha){const s=await Ye(t,{method:"POST",headers:{...ma(),...n??{}},body:JSON.stringify(e)},a);if(!s.ok)throw new Error(`POST ${t}: ${s.status} ${s.statusText}`);return s.text()}function ps(t){const e=t.split(`
`).find(a=>a.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function fs(t){var e,n,a,s,i,r,u;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const d=((s=(a=t.result.content)==null?void 0:a[0])==null?void 0:s.text)??"MCP tool call failed";throw new Error(d)}return((u=(r=(i=t.result)==null?void 0:i.content)==null?void 0:r[0])==null?void 0:u.text)??""}async function H(t,e){const n=await vs("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"},us),a=ps(n);return fs(a)}function $a(t){const e=t.trim();if(!e)return[];const n=JSON.parse(e);return Array.isArray(n)?n:[]}function _s(){return Ft("/api/v1/dashboard")}function ms(){return Ft("/api/v1/board")}function hs(t){return Ft(`/api/v1/board/${t}`)}function ga(t,e){return Bt("/api/v1/tools/masc_board_vote",{post_id:t,vote:e,voter:ds()})}function $s(t,e,n){return Bt("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function B(t){return typeof t=="object"&&t!==null}function $(t,e=""){return typeof t=="string"?t:e}function V(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function gs(t,e=!1){return typeof t=="boolean"?t:e}function ys(t){return t==="dm"||t==="player"||t==="npc"?t:"npc"}function L(t,e,n,a=0){const s=t[e];if(typeof s=="number"&&Number.isFinite(s))return s;if(n){const i=t[n];if(typeof i=="number"&&Number.isFinite(i))return i}return a}function bs(t,e){if(t!=="dice.rolled")return;const n=V(e.raw_d20,0),a=V(e.total,0),s=V(e.bonus,0),i=$(e.action,"roll"),r=V(e.dc,0);return{notation:r>0?`${i} (DC ${r})`:i,rolls:n>0?[n]:[],total:a,modifier:s}}function ks(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function xs(t,e,n){const a=e||$(n.actor_id,"");switch(t){case"turn.action.proposed":{const s=$(n.proposed_action,$(n.reply,""));return s?`${a||"actor"}: ${s}`:"Action proposed"}case"turn.action.resolved":{const s=$(n.reply,$(n.result,""));return s?`Resolved: ${s}`:"Action resolved"}case"narration.posted":return $(n.reply,$(n.content,$(n.text,"Narration")));case"dice.rolled":{const s=$(n.action,"roll"),i=V(n.total,0),r=V(n.dc,0),u=$(n.label,""),d=a||"actor",c=r>0?` vs DC ${r}`:"",p=u?` (${u})`:"";return`${d} ${s}: ${i}${c}${p}`}case"turn.started":return`Turn ${V(n.turn,1)} started`;case"phase.changed":return`Phase: ${$(n.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${$(n.name,a||"unknown")}`;case"actor.claimed":return`${$(n.keeper,"keeper")} claimed ${a||"actor"}`;case"actor.released":return`${$(n.keeper,"keeper")} released ${a||"actor"}`;case"combat.attack":return $(n.summary,$(n.result,"Attack resolved"));case"combat.defense":return $(n.summary,$(n.result,"Defense resolved"));case"session.outcome":return $(n.summary,$(n.outcome,"Session ended"));default:{const s=ks(n);return s?`${t}: ${s}`:t}}}function ws(t){const e=B(t)?t:{},n=$(e.type,"event"),a=typeof e.actor_id=="string"?e.actor_id:"",s=B(e.payload)?e.payload:{};return{type:n,actor:a||$(s.actor_id,""),content:xs(n,a,s),dice_roll:bs(n,s),timestamp:$(e.ts,new Date().toISOString())}}function Ss(t,e,n){var y,I;const a=$(t.room_id,"")||n||"default",s=B(t.state)?t.state:{},i=B(s.party)?s.party:{},r=B(s.actor_control)?s.actor_control:{},u=Object.entries(i).map(([P,F])=>{const S=B(F)?F:{},X=L(S,"max_hp",void 0,10),Q=L(S,"hp",void 0,X),Y=L(S,"max_mp",void 0,0),mt=L(S,"mp",void 0,0),R=L(S,"level",void 0,1),W=L(S,"xp",void 0,0),Da=gs(S.alive,Q>0),on=r[P],Ea=typeof on=="string"?on:void 0;return{id:P,name:$(S.name,P),role:ys(S.role),keeper:Ea,status:Da?"active":"dead",stats:{hp:Q,max_hp:X,mp:mt,max_mp:Y,level:R,xp:W,strength:L(S,"strength","str",10),dexterity:L(S,"dexterity","dex",10),constitution:L(S,"constitution","con",10),intelligence:L(S,"intelligence","int",10),wisdom:L(S,"wisdom","wis",10),charisma:L(S,"charisma","cha",10)}}}),d=e.map(ws),c=V(s.turn,1),p=$(s.phase,"round"),l=$(s.map,""),m=B(s.world)?s.world:{},f=l||$(m.ascii_map,$(m.map,"")),C=d.filter((P,F)=>{const S=e[F];if(!B(S))return!1;const X=B(S.payload)?S.payload:{};return V(X.turn,-1)===c}),E=(C.length>0?C:d).slice(-12),T=$(s.status,"active");return{session:{id:a,room:a,status:T==="ended"?"ended":T==="paused"?"paused":"active",round:c,actors:u,created_at:((y=d[0])==null?void 0:y.timestamp)??new Date().toISOString()},current_round:{round_number:c,phase:p,events:E,timestamp:((I=d[d.length-1])==null?void 0:I.timestamp)??new Date().toISOString()},map:f||void 0,party:u,story_log:d,history:[]}}async function Cs(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await Ft(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function Ts(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,a]=await Promise.all([Ft(`/api/v1/trpg/state${e}`),Cs(t)]);return Ss(n,a,t)}function As(t){return Bt("/api/v1/trpg/rounds/run",{room_id:t})}function Ns(t){const e="".trim().toLowerCase();if(e)switch(e){case"discussion":case"discuss":case"party_discussion":case"player_discussion":case"action":case"dice":return"round";case"ended":return"end";default:return e}}function Ds(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),Bt("/api/v1/trpg/dice/roll",e)}function Es(t,e){const n=Ns();return Bt("/api/v1/trpg/turns/advance",{room_id:t,...n?{phase:n}:{}})}async function ya(t,e){await H("masc_broadcast",{agent_name:t,message:e})}async function Ps(t,e,n=1){await H("masc_add_task",{title:t,description:e,priority:n})}async function Rs(t){return H("masc_join",{agent_name:t})}async function ba(t){await H("masc_leave",{agent_name:t})}async function Ls(t){await H("masc_heartbeat",{agent_name:t})}async function Is(t=40){return(await H("masc_messages",{limit:t})).split(`
`).map(n=>n.trim()).filter(n=>n!=="")}async function Ms(t,e=20){return H("masc_task_history",{task_id:t,limit:e})}async function js(){const t=await H("masc_debates",{});return $a(t)}async function Os(){const t=await H("masc_sessions",{});return $a(t)}async function Hs(t){const e=await H("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}function Us(t){return H("masc_debate_status",{debate_id:t})}const pt=v([]),Kt=v([]),ka=v([]),ft=v([]),Ze=v(null),$t=v(null),Me=v(new Map),xa=v([]),xn=v("hot"),wa=v(null),bt=v(""),je=v(!1),Oe=v(!1),He=v(!1),zs=ct(()=>pt.value.filter(t=>t.status==="active"||t.status==="idle")),Sa=ct(()=>{const t=Kt.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}});function Fs(t){var s;const e=t.metrics_series;if(!e||e.length===0){const i=((s=t.status)==null?void 0:s.toLowerCase())??"";return i==="offline"||i==="inactive"?"offline":"idle"}const n=e[e.length-1];if(!n)return"idle";if(n.is_handoff)return"handoff-imminent";if(n.is_compaction)return"compacting";const a=n.context_ratio;return a>.85?"handoff-imminent":a>.7?"preparing":a>.5?"compacting":"active"}ct(()=>{const t=new Map;for(const e of ft.value)t.set(e.name,Fs(e));return t});const Bs=12e4;ct(()=>{const t=Date.now(),e=new Set,n=Me.value;for(const a of ft.value){const s=n.get(a.name);s!=null&&t-s>Bs&&e.add(a.name)}return e});let Qt=null;const Ks=5e3;function Ue(){Qt=null}function j(t){return typeof t=="object"&&t!==null}function _(t){return typeof t=="string"&&t.trim()!==""?t:void 0}function h(t){return typeof t=="number"&&Number.isFinite(t)?t:void 0}function kt(t){if(!Array.isArray(t))return;const e=t.filter(n=>typeof n=="string"&&n.trim()!=="");return e.length>0?e:void 0}function Ca(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="active"||e==="idle"||e==="inactive"||e==="offline"?e:e==="busy"||e==="in_progress"||e==="claimed"?"active":"offline"}function Vs(t){const e=typeof t=="string"?t.toLowerCase():"";return e==="todo"||e==="in_progress"||e==="claimed"||e==="done"||e==="cancelled"?e:e==="inprogress"?"in_progress":"todo"}function Gs(t){if(!j(t))return null;const e=_(t.name);return e?{name:e,status:Ca(t.status),current_task:_(t.current_task)??null,last_seen:_(t.last_seen),emoji:_(t.emoji),koreanName:_(t.koreanName)??_(t.korean_name),model:_(t.model),traits:kt(t.traits),interests:kt(t.interests),activityLevel:h(t.activityLevel)??h(t.activity_level),primaryValue:_(t.primaryValue)??_(t.primary_value)}:null}function Ws(t){if(!j(t))return null;const e=_(t.id),n=_(t.title);return!e||!n?null:{id:e,title:n,status:Vs(t.status),priority:h(t.priority),assignee:_(t.assignee),description:_(t.description),created_at:_(t.created_at),updated_at:_(t.updated_at)}}function Js(t){if(!j(t))return null;const e=_(t.from)??_(t.from_agent)??"system",n=_(t.content)??"",a=_(t.timestamp)??new Date().toISOString();return{id:_(t.id),seq:h(t.seq),from:e,content:n,timestamp:a,type:_(t.type)}}function qs(t){return Array.isArray(t)?t.map(e=>{if(!j(e))return null;const n=h(e.ts_unix);if(n==null)return null;const a=j(e.handoff)?e.handoff:null;return{ts:n,context_ratio:h(e.context_ratio)??0,context_tokens:h(e.context_tokens)??0,context_max:h(e.context_max)??0,latency_ms:h(e.latency_ms)??0,generation:h(e.generation)??0,channel:typeof e.channel=="string"?e.channel:"turn",is_handoff:a!=null&&e.handoff_performed===!0,is_compaction:e.compacted===!0,compaction_saved_tokens:h(e.compaction_saved_tokens)??0,compaction_trigger:typeof e.compaction_trigger=="string"?e.compaction_trigger:null,model_used:typeof e.model_used=="string"?e.model_used:"",cost_usd:h(e.cost_usd)??0,handoff_to_model:a&&typeof a.to_model=="string"?a.to_model:null,handoff_new_generation:a?h(a.new_generation)??null:null}}).filter(e=>e!==null):[]}function Xs(t){return(Array.isArray(t)?t:j(t)&&Array.isArray(t.keepers)?t.keepers:[]).map(n=>{if(!j(n))return null;const a=j(n.agent)?n.agent:null,s=j(n.context)?n.context:null,i=j(n.metrics_window)?n.metrics_window:void 0,r=_(n.name);if(!r)return null;const u=h(n.context_ratio)??h(s==null?void 0:s.context_ratio),d=_(n.status)??_(a==null?void 0:a.status)??"offline",c=Ca(d),p=_(n.model)??_(n.active_model)??_(n.primary_model),l=kt(n.skill_secondary),m=s?{source:_(s.source),context_ratio:h(s.context_ratio),context_tokens:h(s.context_tokens),context_max:h(s.context_max),message_count:h(s.message_count),has_checkpoint:typeof s.has_checkpoint=="boolean"?s.has_checkpoint:void 0}:void 0,f=a?{name:_(a.name),status:_(a.status),current_task:_(a.current_task)??null,last_seen:_(a.last_seen)}:void 0,C=qs(n.metrics_series);return{name:r,emoji:_(n.emoji),koreanName:_(n.koreanName)??_(n.korean_name),agent_name:_(n.agent_name),trace_id:_(n.trace_id),model:p,primary_model:_(n.primary_model),active_model:_(n.active_model),next_model_hint:_(n.next_model_hint)??null,status:c,last_heartbeat:_(n.last_heartbeat)??_(a==null?void 0:a.last_seen),generation:h(n.generation),turn_count:h(n.turn_count)??h(n.total_turns),context_ratio:u,context_tokens:h(n.context_tokens)??h(s==null?void 0:s.context_tokens),context_max:h(n.context_max)??h(s==null?void 0:s.context_max),context_source:_(n.context_source)??_(s==null?void 0:s.source),context:m,traits:kt(n.traits),interests:kt(n.interests),primaryValue:_(n.primaryValue)??_(n.primary_value),activityLevel:h(n.activityLevel)??h(n.activity_level),memory_recent_note:_(n.memory_recent_note)??null,conversation_tail_count:h(n.conversation_tail_count),k2k_count:h(n.k2k_count),handoff_count_total:h(n.handoff_count_total)??h(n.trace_history_count),compaction_count:h(n.compaction_count),last_compaction_saved_tokens:h(n.last_compaction_saved_tokens),skill_primary:_(n.skill_primary)??null,skill_secondary:l,skill_reason:_(n.skill_reason)??null,metrics_series:C.length>0?C:void 0,metrics_window:i,agent:f}}).filter(n=>n!==null)}async function me(){var e,n,a;const t=Date.now();if(!(Qt&&t-Qt.time<Ks)){je.value=!0;try{const s=await _s();Qt={data:s,time:t},pt.value=(Array.isArray((e=s.agents)==null?void 0:e.agents)?s.agents.agents:[]).map(Gs).filter(i=>i!==null),Kt.value=(Array.isArray((n=s.tasks)==null?void 0:n.tasks)?s.tasks.tasks:[]).map(Ws).filter(i=>i!==null),ka.value=(Array.isArray((a=s.messages)==null?void 0:a.messages)?s.messages.messages:[]).map(Js).filter(i=>i!==null),ft.value=Xs(s.keepers),Ze.value=j(s.status)?s.status:null,$t.value=s.perpetual??null}catch(s){console.error("Dashboard fetch error:",s)}finally{je.value=!1}}}async function nt(){Oe.value=!0;try{const t=await ms();xa.value=t.posts??[]}catch(t){console.error("Board fetch error:",t)}finally{Oe.value=!1}}async function ot(){var t;He.value=!0;try{const e=bt.value||((t=Ze.value)==null?void 0:t.room)||"default";bt.value||(bt.value=e);const n=await Ts(e);wa.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{He.value=!1}}let ge=null,ye=null;function Qs(){return da.subscribe(e=>{if(e){if(e.type==="keeper_heartbeat"&&e.name){const n=new Map(Me.value);n.set(e.name,e.ts_unix?e.ts_unix*1e3:Date.now()),Me.value=n}Ue(),ge||(ge=setTimeout(()=>{me(),ge=null},500)),(e.type==="board_post"||e.type==="board_comment")&&(ye||(ye=setTimeout(()=>{nt(),ye=null},500))),(e.type==="keeper_handoff"||e.type==="keeper_compaction"||e.type==="keeper_guardrail")&&Ue()}})}let xt=null;function Ys(){xt||(xt=setInterval(()=>{Ue(),me()},1e4))}function Zs(){xt&&(clearInterval(xt),xt=null)}function b({title:t,class:e,children:n}){return o`
    <div class="card ${e??""}">
      ${t?o`<div class="card-title">${t}</div>`:null}
      ${n}
    </div>
  `}function G({status:t,label:e}){return o`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??t}
    </span>
  `}function ti(t){const e=Date.now(),n=typeof t=="number"?t:new Date(t).getTime(),a=Math.floor((e-n)/1e3);if(a<60)return`${a}s ago`;const s=Math.floor(a/60);if(s<60)return`${s}m ago`;const i=Math.floor(s/60);return i<24?`${i}h ago`:`${Math.floor(i/24)}d ago`}function q({timestamp:t}){const e=ti(t);return o`<span class="time-ago" title=${typeof t=="string"?t:new Date(t).toISOString()}>${e}</span>`}const tn=v(null);function en(t){tn.value=t}function wn(){tn.value=null}function ei({keeper:t}){const e=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return o`
    <div class="keeper-kpis">
      ${e.map(n=>o`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${n.label}</div>
          <div class="keeper-kpi-value">${n.value}</div>
          ${n.hint?o`<div class="keeper-kpi-hint">${n.hint}</div>`:null}
        </div>
      `)}
    </div>
  `}function ni({keeper:t}){const e=t.context_ratio;if(e==null)return null;const n=Math.round(e*100),a=n>80?"bad":n>60?"warn":"";return o`
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
  `}const be=v("");function ai({keeper:t}){var s,i;const e=be.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji??"-"},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((s=t.traits)==null?void 0:s.join(", "))||"-"},{title:"Interests",key:"interests",value:((i=t.interests)==null?void 0:i.join(", "))||"-"}],a=e?n.filter(r=>r.title.toLowerCase().includes(e)||r.key.includes(e)||r.value.toLowerCase().includes(e)):n;return o`
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
  `}function si({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return o`
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
  `}function ii({items:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No equipment</div>`:o`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>o`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function oi({rels:t}){const e=Object.entries(t);return e.length===0?o`<div class="empty-state" style="font-size:13px">No relationships</div>`:o`
    <div class="keeper-k2k-list">
      ${e.map(([n,a])=>o`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${a}</span>
        </div>
      `)}
    </div>
  `}function Sn({traits:t,label:e}){return t.length===0?null:o`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>o`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function ke(t){return t==null||Number.isNaN(t)?"-":`${Math.round(t*100)}%`}function ri({keeper:t}){const e=t.metrics_window,n=[{label:"Model fallback",value:ke(typeof(e==null?void 0:e.model_fallback_rate)=="number"?e.model_fallback_rate:void 0)},{label:"Proactive fallback",value:ke(typeof(e==null?void 0:e.proactive_fallback_rate)=="number"?e.proactive_fallback_rate:void 0)},{label:"Memory pass rate",value:ke(typeof(e==null?void 0:e.memory_pass_rate)=="number"?e.memory_pass_rate:void 0)},{label:"Handoffs",value:typeof(e==null?void 0:e.handoff_count)=="number"?e.handoff_count:t.handoff_count_total??"-"},{label:"Compactions",value:typeof(e==null?void 0:e.compaction_events)=="number"?e.compaction_events:t.compaction_count??"-"},{label:"Saved tokens",value:typeof(e==null?void 0:e.compaction_saved_tokens)=="number"?e.compaction_saved_tokens:t.last_compaction_saved_tokens??"-"},{label:"K2K events",value:t.k2k_count??"-"},{label:"Conversation tail",value:t.conversation_tail_count??"-"}];return o`
    <div class="keeper-signal-list">
      ${n.map(a=>o`
        <div class="keeper-signal-row">
          <span>${a.label}</span>
          <strong>${a.value}</strong>
        </div>
      `)}
    </div>
  `}function li(){var e,n,a;const t=tn.value;return t?o`
    <div
      class="keeper-detail-overlay"
      style="position:fixed; inset:0; z-index:1000; background:rgba(0,0,0,0.7); display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${s=>{s.target.classList.contains("keeper-detail-overlay")&&wn()}}
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
            <${G} status=${t.status} />
            ${t.model?o`<span class="pill">${t.model}</span>`:null}
          </div>
          <button
            onClick=${()=>wn()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${ei} keeper=${t} />

        ${""}
        <${ni} keeper=${t} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${b} title="Field Dictionary">
            <${ai} keeper=${t} />
          <//>

          ${""}
          <${b} title="Profile">
            <${Sn} traits=${t.traits??[]} label="Traits" />
            <${Sn} traits=${t.interests??[]} label="Interests" />
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
          ${t.trpg_stats?o`
              <${b} title="TRPG Stats">
                <${si} stats=${t.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?o`
              <${b} title="Equipment (${t.inventory.length})">
                <${ii} items=${t.inventory} />
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?o`
              <${b} title="Relationships (${Object.keys(t.relationships).length})">
                <${oi} rels=${t.relationships} />
              <//>
            `:null}

          <${b} title="Runtime Signals">
            <${ri} keeper=${t} />
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
      </div>
    </div>
  `:null}function at({label:t,value:e,color:n}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color: ${n}`:""}>${e}</div>
    </div>
  `}function ci({agent:t}){return o`
    <div class="agent" onClick=${()=>en(t)} style="cursor: pointer">
      <span class="agent-emoji">${t.emoji??""}</span>
      <span class="agent-status ${t.status}"></span>
      <span class="agent-name">${t.name}</span>
      <${G} status=${t.status} />
      ${t.current_task?o`<span class="agent-task">${t.current_task}</span>`:null}
    </div>
  `}function ui({keeper:t}){return o`
    <div class="live-agent keeper-card" onClick=${()=>en(t)} style="cursor: pointer">
      <div class="live-agent-main">
        <div class="live-agent-title">
          <span class="live-agent-name">${t.emoji??""} ${t.name}</span>
          <${G} status=${t.status} />
          ${t.model?o`<span class="pill">${t.model}</span>`:null}
        </div>
        <div class="live-agent-sub">${t.koreanName??""}</div>
        ${t.generation!=null?o`<div class="live-agent-meta">
              <span>Gen ${t.generation}</span>
              <span>Turn ${t.turn_count??0}</span>
              ${t.context_ratio!=null?o`<span class=${t.context_ratio>.7?"warn-metric":""}>
                    Ctx ${Math.round(t.context_ratio*100)}%
                  </span>`:null}
            </div>`:null}
      </div>
    </div>
  `}function Cn(){const t=Ze.value,e=pt.value,n=ft.value,a=Sa.value;return o`
    <div class="stats-grid">
      <${at} label="Agents" value=${e.length} />
      <${at} label="Active" value=${zs.value.length} color="#4ade80" />
      <${at} label="Keepers" value=${n.length} color="#22d3ee" />
      <${at} label="Tasks" value=${Kt.value.length} />
      <${at} label="In Progress" value=${a.inProgress.length} color="#fbbf24" />
      <${at} label="Done" value=${a.done.length} color="#4ade80" />
    </div>

    <div class="grid-2col">
      <${b} title="Agents" class="section">
        <div class="agent-list">
          ${e.length===0?o`<div class="empty-state">No agents connected</div>`:e.map(s=>o`<${ci} key=${s.name} agent=${s} />`)}
        </div>
      <//>

      <${b} title="Keepers" class="section">
        <div class="live-agent-list">
          ${n.length===0?o`<div class="empty-state">No keepers active</div>`:n.map(s=>o`<${ui} key=${s.name} keeper=${s} />`)}
        </div>
      <//>
    </div>

    ${$t.value?o`
        <${b} title="Perpetual Runtime" class="section">
          <div class="live-agent-meta">
            <span>Status: ${$t.value.running?"Running":"Stopped"}</span>
            ${$t.value.goal?o`<span>Goal: ${$t.value.goal}</span>`:null}
          </div>
        <//>
      `:null}

    ${t!=null&&t.room?o`
        <${b} title="Room" class="section">
          <div class="live-agent-meta">
            <span>Room: ${t.room}</span>
            <span>Uptime: ${di(t.uptime_seconds??0)}</span>
          </div>
        <//>
      `:null}
  `}function di(t){if(!t)return"N/A";const e=Math.floor(t/3600),n=Math.floor(t%3600/60);return e>0?`${e}h ${n}m`:`${n}m`}let vi=0;const tt=v([]);function x(t,e="success",n=4e3){const a=++vi;tt.value=[...tt.value,{id:a,message:t,type:e}],setTimeout(()=>{tt.value=tt.value.filter(s=>s.id!==a)},n)}function pi(t){tt.value=tt.value.filter(e=>e.id!==t)}function fi(){const t=tt.value;return t.length===0?null:o`
    <div class="toast-container">
      ${t.map(e=>o`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>pi(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}const ze=v([]),Fe=v([]),wt=v(""),ie=v(!1),St=v(!1),oe=v(""),re=v(null),Ct=v(""),Be=v(!1);async function Ke(){ie.value=!0,oe.value="";try{const[t,e]=await Promise.all([js(),Os()]);ze.value=t,Fe.value=e}catch(t){oe.value=t instanceof Error?t.message:"Failed to load council data"}finally{ie.value=!1}}async function Tn(){const t=wt.value.trim();if(t){St.value=!0;try{const e=await Hs(t);wt.value="",x(e!=null&&e.id?`Debate started: ${e.id}`:"Debate started","success"),await Ke()}catch(e){const n=e instanceof Error?e.message:"Failed to start debate";x(n,"error")}finally{St.value=!1}}}async function _i(t){re.value=t,Be.value=!0,Ct.value="";try{Ct.value=await Us(t)}catch(e){Ct.value=e instanceof Error?e.message:"Failed to load debate status"}finally{Be.value=!1}}function mi({debate:t}){const e=re.value===t.id;return o`
    <button
      class="council-row ${e?"selected":""}"
      onClick=${()=>_i(t.id)}
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
  `}function hi({session:t}){return o`
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
  `}function $i(){return te(()=>{Ke()},[]),o`
    <div>
      <${b} title="Council Command" class="section">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${wt.value}
            onInput=${t=>{wt.value=t.target.value}}
            onKeyDown=${t=>{t.key==="Enter"&&Tn()}}
            disabled=${St.value}
          />
          <button
            class="control-btn secondary"
            onClick=${Tn}
            disabled=${St.value||wt.value.trim()===""}
          >
            ${St.value?"Starting...":"Start Debate"}
          </button>
          <button class="control-btn ghost" onClick=${Ke} disabled=${ie.value}>
            ${ie.value?"Refreshing...":"Refresh"}
          </button>
        </div>
        ${oe.value?o`<div class="council-error">${oe.value}</div>`:null}
      <//>

      <div class="council-grid">
        <${b} title="Debates" class="section">
          <div class="council-list">
            ${ze.value.length===0?o`<div class="empty-state">No debates yet</div>`:ze.value.map(t=>o`<${mi} key=${t.id} debate=${t} />`)}
          </div>
        <//>

        <${b} title="Voting Sessions" class="section">
          <div class="council-list">
            ${Fe.value.length===0?o`<div class="empty-state">No active sessions</div>`:Fe.value.map(t=>o`<${hi} key=${t.id} session=${t} />`)}
          </div>
        <//>
      </div>

      <${b} title=${re.value?`Debate Detail (${re.value})`:"Debate Detail"} class="section">
        ${Be.value?o`<div class="loading-indicator">Loading debate detail...</div>`:Ct.value?o`<pre class="council-detail">${Ct.value}</pre>`:o`<div class="empty-state">Select a debate to view summary</div>`}
      <//>
    </div>
  `}function gi({text:t}){if(!t)return null;const e=yi(t);return o`<div class="markdown-content">${e}</div>`}function yi(t){const e=t.split(`
`),n=[];let a=0;for(;a<e.length;){const s=e[a];if(/^(`{3,}|~{3,})/.test(s)){const r=s.match(/^(`{3,}|~{3,})/)[0],u=s.slice(r.length).trim(),d=[];for(a++;a<e.length&&!e[a].startsWith(r);)d.push(e[a]),a++;a++,n.push(o`<pre><code class=${u?`language-${u}`:""}>${d.join(`
`)}</code></pre>`);continue}if(s.trim()==="<think>"||s.trim().startsWith("<think>")){const r=[],u=s.trim().replace(/^<think>/,"").trim();for(u&&u!=="</think>"&&r.push(u),a++;a<e.length&&!e[a].includes("</think>");)r.push(e[a]),a++;if(a<e.length){const c=e[a].replace("</think>","").trim();c&&r.push(c),a++}const d=r.join(`
`).trim();n.push(o`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${xe(d)}</div>
        </details>
      `);continue}if(s.startsWith("> ")){const r=[];for(;a<e.length&&e[a].startsWith("> ");)r.push(e[a].slice(2)),a++;n.push(o`<blockquote>${xe(r.join(`
`))}</blockquote>`);continue}if(s.trim()===""){a++;continue}const i=[];for(;a<e.length;){const r=e[a];if(r.trim()===""||/^(`{3,}|~{3,})/.test(r)||r.startsWith("> ")||r.trim().startsWith("<think>"))break;i.push(r),a++}i.length>0&&n.push(o`<p>${xe(i.join(`
`))}</p>`)}return n}function xe(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let a=0,s;for(;(s=n.exec(t))!==null;){if(s.index>a&&e.push(t.slice(a,s.index)),s[1]){const i=s[1].slice(1,-1);e.push(o`<code>${i}</code>`)}else if(s[2]){const i=s[2].slice(2,-2);e.push(o`<strong>${i}</strong>`)}else if(s[3]){const i=s[3].slice(1,-1);e.push(o`<em>${i}</em>`)}else s[4]&&s[5]&&e.push(o`<a href=${s[5]} target="_blank" rel="noopener">${s[4]}</a>`);a=s.index+s[0].length}return a<t.length&&e.push(t.slice(a)),e.length>0?e:[t]}const bi=[{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"recent",label:"Recent"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],Tt=v([]),At=v(!1),Nt=v(""),ki=v("dashboard-user"),Dt=v(!1);async function Ta(t){At.value=!0,Tt.value=[];try{const e=await hs(t);Tt.value=e.comments??[]}catch{}finally{At.value=!1}}async function An(t){const e=Nt.value.trim();if(e){Dt.value=!0;try{await $s(t,ki.value,e),Nt.value="",x("Comment posted","success"),await Ta(t),nt()}catch{x("Failed to post comment","error")}finally{Dt.value=!1}}}function xi(){const t=xn.value;return o`
    <div class="board-controls">
      ${bi.map(e=>o`
        <button
          class="board-sort-btn ${t===e.id?"active":""}"
          onClick=${()=>{xn.value=e.id,nt()}}
        >
          ${e.label}
        </button>
      `)}
    </div>
  `}function Aa({flair:t}){return t?o`<span class="post-flair ${t}">${t}</span>`:null}function wi({post:t}){const e=async(n,a)=>{a.stopPropagation();try{await ga(t.id,n),nt()}catch{x("Failed to vote","error")}};return o`
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
          <${Aa} flair=${t.flair} />
        </div>
        <div class="post-meta">
          <span>${t.author}</span>
          <${q} timestamp=${t.created_at} />
          ${t.comment_count>0?o`<span>${t.comment_count} comments</span>`:null}
          ${(t.hearth_count??0)>0?o`<span>♥ ${t.hearth_count}</span>`:null}
        </div>
      </div>
    </div>
  `}function Si({comments:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No comments yet</div>`:o`
    <div class="comment-thread">
      ${t.map(e=>o`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${q} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function Ci({postId:t}){return o`
    <div class="comment-form" style="margin-top: 12px; display: flex; gap: 8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${Nt.value}
        onInput=${e=>{Nt.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&An(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${Dt.value}
      />
      <button
        onClick=${()=>An(t)}
        disabled=${Dt.value||Nt.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${Dt.value?"...":"Post"}
      </button>
    </div>
  `}function Ti({post:t}){Tt.value.length===0&&!At.value&&Ta(t.id);const e=async n=>{try{await ga(t.id,n),nt()}catch{x("Failed to vote","error")}};return o`
    <div>
      <button class="back-btn" onClick=${()=>_e("board")}>← Back to Board</button>
      <${b} title=${o`${t.title} <${Aa} flair=${t.flair} />`}>
        <div class="board-detail">
          <div class="post-body">
            <${gi} text=${t.content} />
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

      <${b} title="Comments (${At.value?"...":Tt.value.length})">
        ${At.value?o`<div class="loading-indicator">Loading comments...</div>`:o`<${Si} comments=${Tt.value} />`}
        <${Ci} postId=${t.id} />
      <//>
    </div>
  `}function Ai(){const t=xa.value,e=Oe.value,n=z.value.postId;if(n){const a=t.find(s=>s.id===n);return a?o`<${Ti} post=${a} />`:o`
          <div>
            <button class="back-btn" onClick=${()=>_e("board")}>← Back to Board</button>
            <div class="empty-state">Post not found</div>
          </div>
        `}return o`
    <${xi} />
    ${e?o`<div class="loading-indicator">Loading board...</div>`:t.length===0?o`<div class="empty-state">No posts yet</div>`:o`<div class="board-post-list">
            ${t.map(a=>o`<${wi} key=${a.id} post=${a} />`)}
          </div>`}
  `}function Ni(t,e){return{id:t.id??`msg-${t.seq??e}`,source:"message",actor:t.from??"system",content:t.content,timestamp:t.timestamp}}function Di(t,e){return{id:`evt-${t.timestamp}-${e}`,source:"event",actor:t.agent||"system",content:t.text,timestamp:new Date(t.timestamp).toISOString()}}function Nn(t){const e=Date.parse(t);return Number.isNaN(e)?0:e}function Ei({row:t}){return o`
    <div class="message-row">
      <span class="message-agent">${t.actor}</span>
      <span class="message-source ${t.source}">${t.source}</span>
      <span class="message-text">${t.content}</span>
      <span class="message-time"><${q} timestamp=${t.timestamp} /></span>
    </div>
  `}function Pi(){const t=ka.value.map(Ni),e=se.value.map(Di),n=[...t,...e].sort((a,s)=>Nn(s.timestamp)-Nn(a.timestamp)).slice(0,80);return o`
    <div class="section">
      <h2>Recent Activity</h2>
      <div class="message-list">
        ${n.length===0?o`<div class="empty-state">No recent activity</div>`:n.map(a=>o`<${Ei} key=${a.id} row=${a} />`)}
      </div>
    </div>
  `}const Ri="masc_dashboard_agent_name",_t=v(null),le=v(!1),Ot=v(""),ce=v([]),Ht=v([]),rt=v(""),Et=v(!1);function Li(t){_t.value=t,nn()}function Dn(){_t.value=null,Ot.value="",ce.value=[],Ht.value=[],rt.value=""}function Ii(){const t=_t.value;return t?pt.value.find(e=>e.name===t)??null:null}function Na(t){return t?Kt.value.filter(e=>e.assignee===t):[]}async function nn(){const t=_t.value;if(t){le.value=!0,Ot.value="",ce.value=[],Ht.value=[];try{const e=await Is(80);ce.value=e.filter(s=>s.includes(t)).slice(0,20);const n=Na(t).slice(0,6);if(n.length===0)return;const a=await Promise.all(n.map(async s=>{try{const i=await Ms(s.id,25);return{taskId:s.id,text:i.trim()}}catch(i){const r=i instanceof Error?i.message:"history load failed";return{taskId:s.id,text:`Failed to load history: ${r}`}}}));Ht.value=a}catch(e){Ot.value=e instanceof Error?e.message:"Failed to load agent detail"}finally{le.value=!1}}}async function En(){var a;const t=_t.value,e=rt.value.trim();if(!t||!e)return;const n=((a=localStorage.getItem(Ri))==null?void 0:a.trim())||"dashboard";Et.value=!0;try{await ya(n,`@${t} ${e}`),rt.value="",x(`Mention sent to ${t}`,"success"),nn()}catch(s){const i=s instanceof Error?s.message:"Failed to send mention";x(i,"error")}finally{Et.value=!1}}function Mi({task:t}){return o`
    <div class="agent-detail-task">
      <span class="pill">${t.id}</span>
      <span class="agent-detail-task-title">${t.title}</span>
      <${G} status=${t.status} />
    </div>
  `}function ji({row:t}){return o`
    <div class="agent-history-row">
      <div class="agent-history-head">
        <span class="pill">${t.taskId}</span>
      </div>
      <pre class="agent-history-pre">${t.text||"No task history yet"}</pre>
    </div>
  `}function Oi(){const t=_t.value;if(!t)return null;const e=Ii(),n=Na(t),a=ce.value;return o`
    <div
      class="agent-detail-overlay"
      onClick=${s=>{s.target.classList.contains("agent-detail-overlay")&&Dn()}}
    >
      <div class="agent-detail-modal">
        <div class="agent-detail-header">
          <div>
            <h2>${t}</h2>
            <div class="agent-detail-sub">
              ${e?o`
                    <${G} status=${e.status} />
                    ${e.current_task?o`<span>Task: ${e.current_task}</span>`:null}
                    ${e.last_seen?o`<span>Last seen: <${q} timestamp=${e.last_seen} /></span>`:null}
                  `:o`<span>Agent snapshot not found in current state</span>`}
            </div>
          </div>
          <div class="agent-detail-actions">
            <button class="control-btn ghost" onClick=${()=>{nn()}} disabled=${le.value}>
              ${le.value?"Refreshing...":"Refresh"}
            </button>
            <button class="control-btn ghost" onClick=${Dn}>Close</button>
          </div>
        </div>

        ${Ot.value?o`<div class="council-error">${Ot.value}</div>`:null}

        <div class="agent-detail-grid">
          <${b} title="Assigned Tasks">
            ${n.length===0?o`<div class="empty-state">No assigned tasks</div>`:o`<div class="agent-detail-task-list">${n.map(s=>o`<${Mi} key=${s.id} task=${s} />`)}</div>`}
          <//>

          <${b} title="Recent Activity">
            ${a.length===0?o`<div class="empty-state">No recent room activity match</div>`:o`<div class="agent-activity-list">${a.map((s,i)=>o`<div key=${i} class="agent-activity-line">${s}</div>`)}</div>`}
          <//>
        </div>

        <${b} title="Task History">
          ${Ht.value.length===0?o`<div class="empty-state">No task history loaded</div>`:o`<div class="agent-history-list">${Ht.value.map(s=>o`<${ji} key=${s.taskId} row=${s} />`)}</div>`}
        <//>

        <${b} title="Direct Mention">
          <div class="agent-mention-row">
            <input
              class="control-input"
              type="text"
              placeholder="@mention message"
              value=${rt.value}
              onInput=${s=>{rt.value=s.target.value}}
              onKeyDown=${s=>{s.key==="Enter"&&En()}}
              disabled=${Et.value}
            />
            <button
              class="control-btn"
              onClick=${()=>{En()}}
              disabled=${Et.value||rt.value.trim()===""}
            >
              ${Et.value?"Sending...":"Send"}
            </button>
          </div>
        <//>
      </div>
    </div>
  `}function Hi({agent:t}){return o`
    <button class="agent-card ${t.status}" onClick=${()=>Li(t.name)}>
      <div class="agent-card-header">
        <span class="agent-emoji">${t.emoji??""}</span>
        <div class="agent-card-info">
          <span class="agent-name">${t.name}</span>
          ${t.koreanName?o`<span class="agent-korean">${t.koreanName}</span>`:null}
        </div>
        <${G} status=${t.status} />
      </div>
      ${t.current_task?o`<div class="agent-task">${t.current_task}</div>`:null}
      ${t.model?o`<div class="agent-model"><span class="pill">${t.model}</span></div>`:null}
    </button>
  `}function Ui({keeper:t}){const e=t.context_ratio!=null?Math.round(t.context_ratio*100):null,n=e!=null?e>80?"bad":e>60?"warn":"":"";return o`
    <div class="live-agent keeper-card" onClick=${()=>en(t)} style="cursor:pointer;">
      <div class="live-agent-main">
        <div class="live-agent-title">
          <span class="live-agent-name">${t.emoji??""} ${t.name}</span>
          <${G} status=${t.status} />
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
  `}function zi(){const t=pt.value,e=ft.value;return o`
    <div>
      ${e.length>0?o`
          <div class="section" style="margin-bottom: 20px">
            <h2>Keepers (Live)</h2>
            <div class="live-agent-list">
              ${e.map(n=>o`<${Ui} key=${n.name} keeper=${n} />`)}
            </div>
          </div>
        `:null}

      <div class="section">
        <h2>All Agents</h2>
        ${t.length===0?o`<div class="empty-state">No agents registered</div>`:o`
            <div class="agent-grid">
              ${t.map(n=>o`<${Hi} key=${n.name} agent=${n} />`)}
            </div>
          `}
      </div>
    </div>
  `}function we({task:t}){return o`
    <div class="task-row">
      <${G} status=${t.status} />
      <div class="task-info">
        <span class="task-title">${t.title}</span>
        ${t.assignee?o`<span class="task-assignee">${t.assignee}</span>`:null}
      </div>
      ${t.created_at?o`<${q} timestamp=${t.created_at} />`:null}
    </div>
  `}function Fi(){const{todo:t,inProgress:e,done:n}=Sa.value;return o`
    <div class="grid-2col">
      <${b} title="In Progress (${e.length})" class="section">
        <div class="task-list">
          ${e.length===0?o`<div class="empty-state">No tasks in progress</div>`:e.map(a=>o`<${we} key=${a.id} task=${a} />`)}
        </div>
      <//>

      <${b} title="To Do (${t.length})" class="section">
        <div class="task-list">
          ${t.length===0?o`<div class="empty-state">No pending tasks</div>`:t.map(a=>o`<${we} key=${a.id} task=${a} />`)}
        </div>
      <//>
    </div>

    ${n.length>0?o`
        <${b} title="Done (${n.length})" class="section" style="margin-top: 20px">
          <div class="task-list">
            ${n.slice(0,20).map(a=>o`<${we} key=${a.id} task=${a} />`)}
            ${n.length>20?o`<div class="empty-state">...and ${n.length-20} more</div>`:null}
          </div>
        <//>
      `:null}
  `}function Bi({event:t}){const n={agent_joined:"#4ade80",agent_left:"#ef4444",broadcast:"#22d3ee",task_update:"#fbbf24",board_post:"#a78bfa",board_comment:"#a78bfa",heartbeat:"#666"}[t.type]??"#888",a=t.message??t.content??t.status??"";return o`
    <div class="journal-entry">
      <span class="journal-type" style="color: ${n}">${t.type}</span>
      <span class="journal-agent">${t.agent??t.from??t.from_agent??""}</span>
      <span class="journal-data">${a}</span>
    </div>
  `}function Ki(){const t=se.value;return o`
    <div class="section">
      <h2>Event Journal</h2>
      <div class="journal-list">
        ${t.length===0?o`<div class="empty-state">No events recorded yet</div>`:t.map((e,n)=>o`<${Bi} key=${n} event=${e} />`)}
      </div>
    </div>
  `}const ht=v(""),Se=v("ability_check"),Ce=v("10"),Te=v("12"),Wt=v(""),Jt=v("idle");function Vi(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function Gi(t,e){return e>0?Math.round(t/e*100):0}function Wi({hp:t,max:e}){const n=Gi(t,e),a=Vi(t,e);return o`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${a}" style="width:${n}%" />
    </div>
  `}function Ji({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return o`
    <div class="trpg-actor-stats">
      ${e.map(n=>o`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function qi({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return o`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function Xi({actor:t}){return o`
    <div class="trpg-actor">
      <div class="trpg-actor-info">
        <span class="trpg-actor-name">${t.name}</span>
        <${G} status=${t.status??"idle"} />
        <span class="pill">${t.role}</span>
        <${qi} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?o`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?o`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${Wi} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${Ji} stats=${t.stats} />
          </div>
        `:null}
    </div>
  `}function Qi({mapStr:t}){return o`<pre class="trpg-map">${t}</pre>`}function Yi({events:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No story events yet</div>`:o`
    <div class="trpg-story">
      ${t.slice(-30).map((e,n)=>{var a;return o`
        <div key=${n} class="trpg-event ${e.type??""}">
          ${e.actor?o`<strong>${e.actor}</strong>${" "}`:null}
          ${e.dice_roll?o`<span class="trpg-dice">[${e.dice_roll.notation}: ${(a=e.dice_roll.rolls)==null?void 0:a.join(",")} = ${e.dice_roll.total}${e.dice_roll.modifier?` +${e.dice_roll.modifier}`:""}]</span>${" "}`:null}
          <span class="trpg-event-text">${e.content??""}</span>
          <span style="float:right; font-size:10px; color:#555;"><${q} timestamp=${e.timestamp} /></span>
        </div>
      `})}
    </div>
  `}function Zi({state:t}){const e=t.history??[];return e.length===0?null:o`
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
  `}function to({state:t}){var d;const e=bt.value||((d=t.session)==null?void 0:d.room)||"",n=Jt.value,a=t.party??[];if(!a.find(c=>c.id===ht.value)&&a.length>0){const c=a[0];c&&(ht.value=c.id)}const i=async()=>{if(!e){x("No room set","error");return}Jt.value="running";try{await As(e),Jt.value="ok",x("Round executed","success"),ot()}catch{Jt.value="error",x("Round failed","error")}},r=async()=>{if(e)try{await Es(e),x("Turn advanced","success"),ot()}catch{x("Advance failed","error")}},u=async()=>{if(!e)return;const c=ht.value.trim();if(!c){x("Select actor first","warning");return}const p=Number.parseInt(Ce.value,10),l=Number.parseInt(Te.value,10);if(Number.isNaN(p)||Number.isNaN(l)){x("Stat/DC must be numbers","warning");return}const m=Number.parseInt(Wt.value,10),f=Wt.value.trim()===""||Number.isNaN(m)?void 0:m;try{await Ds({roomId:e,actorId:c,action:Se.value.trim()||"ability_check",statValue:p,dc:l,rawD20:f}),x("Dice rolled","success"),ot()}catch{x("Dice roll failed","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            type="text"
            value=${e}
            onInput=${c=>{bt.value=c.target.value}}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${ht.value}
            onChange=${c=>{ht.value=c.target.value}}
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
              value=${Wt.value}
              onInput=${c=>{Wt.value=c.target.value}}
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
  `}function eo({state:t}){var n;const e=t.current_round;return e?o`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?o`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function no(){var s,i;const t=wa.value;if(He.value&&!t)return o`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return o`
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
      <${eo} state=${t} />

      ${""}
      <div class="trpg-layout">
        <div>
          ${""}
          <${b} title="Story Log (${a.length})">
            <${Yi} events=${a} />
          <//>

          ${""}
          ${t.map?o`
              <${b} title="Map" style="margin-top:16px;">
                <${Qi} mapStr=${t.map} />
              <//>`:null}
        </div>

        <div class="trpg-sidebar">
          ${""}
          <${b} title="Controls">
            <${to} state=${t} />
          <//>

          ${""}
          <${b} title="Party (${n.length})" style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(r=>o`<${Xi} key=${r.id??r.name} actor=${r} />`)}
              ${n.length===0?o`<div class="empty-state" style="font-size:13px">No actors</div>`:null}
            </div>
          <//>

          ${""}
          ${t.history&&t.history.length>0?o`
              <${b} title="History (${t.history.length})" style="margin-top:16px;">
                <${Zi} state=${t} />
              <//>`:null}
        </div>
      </div>
    </div>
  `}const an="masc_dashboard_agent_name";function ao(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem(an);return e??n??"dashboard"}const O=v(ao()),Pt=v(""),Rt=v(""),ue=v(""),Lt=v(!1),st=v(!1),It=v(!1),Mt=v(!1),de=v(!1),he=v(!1);function sn(t){const e=t.trim();O.value=e,e&&localStorage.setItem(an,e)}function so(t){const n=(t.split(`
`).find(a=>a.includes(" joined"))??t).match(/✅\s+(\S+)\s+joined/i);return(n==null?void 0:n[1])??null}async function Ve(){const t=O.value.trim();if(t){It.value=!0;try{const e=await Rs(t),n=so(e);n&&sn(n),he.value=!0,x(`Joined as ${n??t}`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to join room";x(n,"error")}finally{It.value=!1}}}async function io(){const t=O.value.trim();if(t){Mt.value=!0;try{await ba(t),he.value=!1,x(`Left room (${t})`,"success")}catch(e){const n=e instanceof Error?e.message:"Failed to leave room";x(n,"error")}finally{Mt.value=!1}}}async function oo(){const t=O.value.trim();if(t)try{await ba(t)}catch{}localStorage.removeItem(an),sn("dashboard"),he.value=!1,await Ve()}async function ro(){const t=O.value.trim();if(t){de.value=!0;try{await Ls(t),x("Heartbeat sent","success")}catch(e){const n=e instanceof Error?e.message:"Failed to send heartbeat";x(n,"error")}finally{de.value=!1}}}async function Pn(){const t=O.value.trim(),e=Pt.value.trim();if(!(!t||!e)){Lt.value=!0;try{await ya(t,e),Pt.value="",x("Broadcast sent","success")}catch(n){const a=n instanceof Error?n.message:"Failed to send broadcast";x(a,"error")}finally{Lt.value=!1}}}async function lo(){const t=Rt.value.trim(),e=ue.value.trim()||"Created from dashboard";if(t){st.value=!0;try{await Ps(t,e,1),Rt.value="",ue.value="",x("Task created","success")}catch(n){const a=n instanceof Error?n.message:"Failed to create task";x(a,"error")}finally{st.value=!1}}}function co(){return te(()=>{Ve()},[]),o`
    <section class="rail-card control-dock">
      <h3>Control Dock</h3>

      <label class="control-label" for="dock-agent">Agent</label>
      <input
        id="dock-agent"
        class="control-input"
        type="text"
        value=${O.value}
        onInput=${t=>sn(t.target.value)}
      />

      <label class="control-label" for="dock-message">Broadcast</label>
      <div class="control-row">
        <input
          id="dock-message"
          class="control-input"
          type="text"
          placeholder="@agent message or room update"
          value=${Pt.value}
          onInput=${t=>{Pt.value=t.target.value}}
          onKeyDown=${t=>{t.key==="Enter"&&Pn()}}
          disabled=${Lt.value}
        />
        <button
          class="control-btn"
          onClick=${Pn}
          disabled=${Lt.value||Pt.value.trim()===""||O.value.trim()===""}
        >
          ${Lt.value?"Sending...":"Send"}
        </button>
      </div>

      <div class="control-row">
        <button
          class="control-btn ghost"
          onClick=${()=>{Ve()}}
          disabled=${It.value||O.value.trim()===""}
        >
          ${It.value?"Joining...":he.value?"Rejoin":"Join"}
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{io()}}
          disabled=${Mt.value||O.value.trim()===""}
        >
          ${Mt.value?"Leaving...":"Leave"}
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{oo()}}
          disabled=${It.value||Mt.value}
        >
          Reset ID
        </button>
        <button
          class="control-btn ghost"
          onClick=${()=>{ro()}}
          disabled=${de.value||O.value.trim()===""}
        >
          ${de.value?"Pinging...":"Heartbeat"}
        </button>
      </div>

      <label class="control-label" for="dock-task">Quick Task</label>
      <input
        id="dock-task"
        class="control-input"
        type="text"
        placeholder="Task title"
        value=${Rt.value}
        onInput=${t=>{Rt.value=t.target.value}}
        disabled=${st.value}
      />
      <textarea
        class="control-textarea"
        placeholder="Task description (optional)"
        value=${ue.value}
        onInput=${t=>{ue.value=t.target.value}}
        disabled=${st.value}
      ></textarea>
      <button
        class="control-btn secondary"
        onClick=${lo}
        disabled=${st.value||Rt.value.trim()===""}
      >
        ${st.value?"Creating...":"Create Task"}
      </button>
    </section>
  `}function uo(){const t=ut.value;return o`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"Live":"Reconnecting..."}</span>
      <span class="event-count">${Qe.value} events</span>
    </div>
  `}const vo=[{id:"overview",label:"Overview"},{id:"council",label:"Council"},{id:"board",label:"Board"},{id:"activity",label:"Activity"},{id:"agents",label:"Agents"},{id:"tasks",label:"Tasks"},{id:"journal",label:"Journal"},{id:"trpg",label:"TRPG"}];function po(){const t=z.value.tab,e=ut.value;return o`
    <aside class="dashboard-rail">
      <section class="rail-card">
        <h3>Views</h3>
        <div class="rail-tab-list">
          ${vo.map(n=>o`
            <button
              class="rail-tab-btn ${t===n.id?"active":""}"
              onClick=${()=>_e(n.id)}
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
            <strong>${pt.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Keepers</span>
            <strong>${ft.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Tasks</span>
            <strong>${Kt.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Events</span>
            <strong>${Qe.value}</strong>
          </div>
        </div>
        <button
          class="rail-refresh-btn"
          onClick=${()=>{me(),t==="board"&&nt(),t==="trpg"&&ot()}}
        >
          Refresh Now
        </button>
      </section>

      <${co} />
    </aside>
  `}function fo(){switch(z.value.tab){case"overview":return o`<${Cn} />`;case"council":return o`<${$i} />`;case"board":return o`<${Ai} />`;case"activity":return o`<${Pi} />`;case"agents":return o`<${zi} />`;case"tasks":return o`<${Fi} />`;case"journal":return o`<${Ki} />`;case"trpg":return o`<${no} />`;default:return o`<${Cn} />`}}function _o(){return te(()=>{Za(),pa(),me();const t=Qs();return Ys(),()=>{ls(),t(),Zs()}},[]),te(()=>{const t=z.value.tab;t==="board"&&nt(),t==="trpg"&&ot()},[z.value.tab]),o`
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
          <${uo} />
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
          ${je.value&&!ut.value?o`<div class="loading-indicator">Loading dashboard...</div>`:o`<${fo} />`}
        </main>
        <${po} />
      </div>

      <${li} />
      <${Oi} />
      <${fi} />
    </div>
  `}const Rn=document.getElementById("app");Rn&&ja(o`<${_o} />`,Rn);
