(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const s of document.querySelectorAll('link[rel="modulepreload"]'))a(s);new MutationObserver(s=>{for(const i of s)if(i.type==="childList")for(const r of i.addedNodes)r.tagName==="LINK"&&r.rel==="modulepreload"&&a(r)}).observe(document,{childList:!0,subtree:!0});function n(s){const i={};return s.integrity&&(i.integrity=s.integrity),s.referrerPolicy&&(i.referrerPolicy=s.referrerPolicy),s.crossOrigin==="use-credentials"?i.credentials="include":s.crossOrigin==="anonymous"?i.credentials="omit":i.credentials="same-origin",i}function a(s){if(s.ep)return;s.ep=!0;const i=n(s);fetch(s.href,i)}})();var Jt,g,rn,ln,G,Me,cn,un,dn,Te,ue,de,xt={},vn=[],ea=/acit|ex(?:s|g|n|p|$)|rph|grid|ows|mnc|ntw|ine[ch]|zoo|^ord|itera/i,qt=Array.isArray;function j(t,e){for(var n in e)t[n]=e[n];return t}function Ne(t){t&&t.parentNode&&t.parentNode.removeChild(t)}function pn(t,e,n){var a,s,i,r={};for(i in e)i=="key"?a=e[i]:i=="ref"?s=e[i]:r[i]=e[i];if(arguments.length>2&&(r.children=arguments.length>3?Jt.call(arguments,2):n),typeof t=="function"&&t.defaultProps!=null)for(i in t.defaultProps)r[i]===void 0&&(r[i]=t.defaultProps[i]);return Lt(t,r,a,s,null)}function Lt(t,e,n,a,s){var i={type:t,props:e,key:n,ref:a,__k:null,__:null,__b:0,__e:null,__c:null,constructor:void 0,__v:s??++rn,__i:-1,__u:0};return s==null&&g.vnode!=null&&g.vnode(i),i}function St(t){return t.children}function ut(t,e){this.props=t,this.context=e}function nt(t,e){if(e==null)return t.__?nt(t.__,t.__i+1):null;for(var n;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null)return n.__e;return typeof t.type=="function"?nt(t):null}function fn(t){var e,n;if((t=t.__)!=null&&t.__c!=null){for(t.__e=t.__c.base=null,e=0;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null){t.__e=t.__c.base=n.__e;break}return fn(t)}}function Oe(t){(!t.__d&&(t.__d=!0)&&G.push(t)&&!Ot.__r++||Me!=g.debounceRendering)&&((Me=g.debounceRendering)||cn)(Ot)}function Ot(){for(var t,e,n,a,s,i,r,u=1;G.length;)G.length>u&&G.sort(un),t=G.shift(),u=G.length,t.__d&&(n=void 0,a=void 0,s=(a=(e=t).__v).__e,i=[],r=[],e.__P&&((n=j({},a)).__v=a.__v+1,g.vnode&&g.vnode(n),Ae(e.__P,n,a,e.__n,e.__P.namespaceURI,32&a.__u?[s]:null,i,s??nt(a),!!(32&a.__u),r),n.__v=a.__v,n.__.__k[n.__i]=n,mn(i,n,r),a.__e=a.__=null,n.__e!=s&&fn(n)));Ot.__r=0}function _n(t,e,n,a,s,i,r,u,d,c,v){var l,_,p,k,A,x,y,$=a&&a.__k||vn,E=e.length;for(d=na(n,e,$,d,E),l=0;l<E;l++)(p=n.__k[l])!=null&&(_=p.__i==-1?xt:$[p.__i]||xt,p.__i=l,x=Ae(t,p,_,s,i,r,u,d,c,v),k=p.__e,p.ref&&_.ref!=p.ref&&(_.ref&&Pe(_.ref,null,p),v.push(p.ref,p.__c||k,p)),A==null&&k!=null&&(A=k),(y=!!(4&p.__u))||_.__k===p.__k?d=hn(p,d,t,y):typeof p.type=="function"&&x!==void 0?d=x:k&&(d=k.nextSibling),p.__u&=-7);return n.__e=A,d}function na(t,e,n,a,s){var i,r,u,d,c,v=n.length,l=v,_=0;for(t.__k=new Array(s),i=0;i<s;i++)(r=e[i])!=null&&typeof r!="boolean"&&typeof r!="function"?(typeof r=="string"||typeof r=="number"||typeof r=="bigint"||r.constructor==String?r=t.__k[i]=Lt(null,r,null,null,null):qt(r)?r=t.__k[i]=Lt(St,{children:r},null,null,null):r.constructor===void 0&&r.__b>0?r=t.__k[i]=Lt(r.type,r.props,r.key,r.ref?r.ref:null,r.__v):t.__k[i]=r,d=i+_,r.__=t,r.__b=t.__b+1,u=null,(c=r.__i=aa(r,n,d,l))!=-1&&(l--,(u=n[c])&&(u.__u|=2)),u==null||u.__v==null?(c==-1&&(s>v?_--:s<v&&_++),typeof r.type!="function"&&(r.__u|=4)):c!=d&&(c==d-1?_--:c==d+1?_++:(c>d?_--:_++,r.__u|=4))):t.__k[i]=null;if(l)for(i=0;i<v;i++)(u=n[i])!=null&&(2&u.__u)==0&&(u.__e==a&&(a=nt(u)),gn(u,u));return a}function hn(t,e,n,a){var s,i;if(typeof t.type=="function"){for(s=t.__k,i=0;s&&i<s.length;i++)s[i]&&(s[i].__=t,e=hn(s[i],e,n,a));return e}t.__e!=e&&(a&&(e&&t.type&&!e.parentNode&&(e=nt(t)),n.insertBefore(t.__e,e||null)),e=t.__e);do e=e&&e.nextSibling;while(e!=null&&e.nodeType==8);return e}function aa(t,e,n,a){var s,i,r,u=t.key,d=t.type,c=e[n],v=c!=null&&(2&c.__u)==0;if(c===null&&u==null||v&&u==c.key&&d==c.type)return n;if(a>(v?1:0)){for(s=n-1,i=n+1;s>=0||i<e.length;)if((c=e[r=s>=0?s--:i++])!=null&&(2&c.__u)==0&&u==c.key&&d==c.type)return r}return-1}function je(t,e,n){e[0]=="-"?t.setProperty(e,n??""):t[e]=n==null?"":typeof n!="number"||ea.test(e)?n:n+"px"}function Pt(t,e,n,a,s){var i,r;t:if(e=="style")if(typeof n=="string")t.style.cssText=n;else{if(typeof a=="string"&&(t.style.cssText=a=""),a)for(e in a)n&&e in n||je(t.style,e,"");if(n)for(e in n)a&&n[e]==a[e]||je(t.style,e,n[e])}else if(e[0]=="o"&&e[1]=="n")i=e!=(e=e.replace(dn,"$1")),r=e.toLowerCase(),e=r in t||e=="onFocusOut"||e=="onFocusIn"?r.slice(2):e.slice(2),t.l||(t.l={}),t.l[e+i]=n,n?a?n.u=a.u:(n.u=Te,t.addEventListener(e,i?de:ue,i)):t.removeEventListener(e,i?de:ue,i);else{if(s=="http://www.w3.org/2000/svg")e=e.replace(/xlink(H|:h)/,"h").replace(/sName$/,"s");else if(e!="width"&&e!="height"&&e!="href"&&e!="list"&&e!="form"&&e!="tabIndex"&&e!="download"&&e!="rowSpan"&&e!="colSpan"&&e!="role"&&e!="popover"&&e in t)try{t[e]=n??"";break t}catch{}typeof n=="function"||(n==null||n===!1&&e[4]!="-"?t.removeAttribute(e):t.setAttribute(e,e=="popover"&&n==1?"":n))}}function Ue(t){return function(e){if(this.l){var n=this.l[e.type+t];if(e.t==null)e.t=Te++;else if(e.t<n.u)return;return n(g.event?g.event(e):e)}}}function Ae(t,e,n,a,s,i,r,u,d,c){var v,l,_,p,k,A,x,y,$,E,P,M,b,B,F,W,rt,D=e.type;if(e.constructor!==void 0)return null;128&n.__u&&(d=!!(32&n.__u),i=[u=e.__e=n.__e]),(v=g.__b)&&v(e);t:if(typeof D=="function")try{if(y=e.props,$="prototype"in D&&D.prototype.render,E=(v=D.contextType)&&a[v.__c],P=v?E?E.props.value:v.__:a,n.__c?x=(l=e.__c=n.__c).__=l.__E:($?e.__c=l=new D(y,P):(e.__c=l=new ut(y,P),l.constructor=D,l.render=ia),E&&E.sub(l),l.state||(l.state={}),l.__n=a,_=l.__d=!0,l.__h=[],l._sb=[]),$&&l.__s==null&&(l.__s=l.state),$&&D.getDerivedStateFromProps!=null&&(l.__s==l.state&&(l.__s=j({},l.__s)),j(l.__s,D.getDerivedStateFromProps(y,l.__s))),p=l.props,k=l.state,l.__v=e,_)$&&D.getDerivedStateFromProps==null&&l.componentWillMount!=null&&l.componentWillMount(),$&&l.componentDidMount!=null&&l.__h.push(l.componentDidMount);else{if($&&D.getDerivedStateFromProps==null&&y!==p&&l.componentWillReceiveProps!=null&&l.componentWillReceiveProps(y,P),e.__v==n.__v||!l.__e&&l.shouldComponentUpdate!=null&&l.shouldComponentUpdate(y,l.__s,P)===!1){for(e.__v!=n.__v&&(l.props=y,l.state=l.__s,l.__d=!1),e.__e=n.__e,e.__k=n.__k,e.__k.some(function(H){H&&(H.__=e)}),M=0;M<l._sb.length;M++)l.__h.push(l._sb[M]);l._sb=[],l.__h.length&&r.push(l);break t}l.componentWillUpdate!=null&&l.componentWillUpdate(y,l.__s,P),$&&l.componentDidUpdate!=null&&l.__h.push(function(){l.componentDidUpdate(p,k,A)})}if(l.context=P,l.props=y,l.__P=t,l.__e=!1,b=g.__r,B=0,$){for(l.state=l.__s,l.__d=!1,b&&b(e),v=l.render(l.props,l.state,l.context),F=0;F<l._sb.length;F++)l.__h.push(l._sb[F]);l._sb=[]}else do l.__d=!1,b&&b(e),v=l.render(l.props,l.state,l.context),l.state=l.__s;while(l.__d&&++B<25);l.state=l.__s,l.getChildContext!=null&&(a=j(j({},a),l.getChildContext())),$&&!_&&l.getSnapshotBeforeUpdate!=null&&(A=l.getSnapshotBeforeUpdate(p,k)),W=v,v!=null&&v.type===St&&v.key==null&&(W=$n(v.props.children)),u=_n(t,qt(W)?W:[W],e,n,a,s,i,r,u,d,c),l.base=e.__e,e.__u&=-161,l.__h.length&&r.push(l),x&&(l.__E=l.__=null)}catch(H){if(e.__v=null,d||i!=null)if(H.then){for(e.__u|=d?160:128;u&&u.nodeType==8&&u.nextSibling;)u=u.nextSibling;i[i.indexOf(u)]=null,e.__e=u}else{for(rt=i.length;rt--;)Ne(i[rt]);ve(e)}else e.__e=n.__e,e.__k=n.__k,H.then||ve(e);g.__e(H,e,n)}else i==null&&e.__v==n.__v?(e.__k=n.__k,e.__e=n.__e):u=e.__e=sa(n.__e,e,n,a,s,i,r,d,c);return(v=g.diffed)&&v(e),128&e.__u?void 0:u}function ve(t){t&&t.__c&&(t.__c.__e=!0),t&&t.__k&&t.__k.forEach(ve)}function mn(t,e,n){for(var a=0;a<n.length;a++)Pe(n[a],n[++a],n[++a]);g.__c&&g.__c(e,t),t.some(function(s){try{t=s.__h,s.__h=[],t.some(function(i){i.call(s)})}catch(i){g.__e(i,s.__v)}})}function $n(t){return typeof t!="object"||t==null||t.__b&&t.__b>0?t:qt(t)?t.map($n):j({},t)}function sa(t,e,n,a,s,i,r,u,d){var c,v,l,_,p,k,A,x=n.props||xt,y=e.props,$=e.type;if($=="svg"?s="http://www.w3.org/2000/svg":$=="math"?s="http://www.w3.org/1998/Math/MathML":s||(s="http://www.w3.org/1999/xhtml"),i!=null){for(c=0;c<i.length;c++)if((p=i[c])&&"setAttribute"in p==!!$&&($?p.localName==$:p.nodeType==3)){t=p,i[c]=null;break}}if(t==null){if($==null)return document.createTextNode(y);t=document.createElementNS(s,$,y.is&&y),u&&(g.__m&&g.__m(e,i),u=!1),i=null}if($==null)x===y||u&&t.data==y||(t.data=y);else{if(i=i&&Jt.call(t.childNodes),!u&&i!=null)for(x={},c=0;c<t.attributes.length;c++)x[(p=t.attributes[c]).name]=p.value;for(c in x)if(p=x[c],c!="children"){if(c=="dangerouslySetInnerHTML")l=p;else if(!(c in y)){if(c=="value"&&"defaultValue"in y||c=="checked"&&"defaultChecked"in y)continue;Pt(t,c,null,p,s)}}for(c in y)p=y[c],c=="children"?_=p:c=="dangerouslySetInnerHTML"?v=p:c=="value"?k=p:c=="checked"?A=p:u&&typeof p!="function"||x[c]===p||Pt(t,c,p,x[c],s);if(v)u||l&&(v.__html==l.__html||v.__html==t.innerHTML)||(t.innerHTML=v.__html),e.__k=[];else if(l&&(t.innerHTML=""),_n(e.type=="template"?t.content:t,qt(_)?_:[_],e,n,a,$=="foreignObject"?"http://www.w3.org/1999/xhtml":s,i,r,i?i[0]:n.__k&&nt(n,0),u,d),i!=null)for(c=i.length;c--;)Ne(i[c]);u||(c="value",$=="progress"&&k==null?t.removeAttribute("value"):k!=null&&(k!==t[c]||$=="progress"&&!k||$=="option"&&k!=x[c])&&Pt(t,c,k,x[c],s),c="checked",A!=null&&A!=t[c]&&Pt(t,c,A,x[c],s))}return t}function Pe(t,e,n){try{if(typeof t=="function"){var a=typeof t.__u=="function";a&&t.__u(),a&&e==null||(t.__u=t(e))}else t.current=e}catch(s){g.__e(s,n)}}function gn(t,e,n){var a,s;if(g.unmount&&g.unmount(t),(a=t.ref)&&(a.current&&a.current!=t.__e||Pe(a,null,e)),(a=t.__c)!=null){if(a.componentWillUnmount)try{a.componentWillUnmount()}catch(i){g.__e(i,e)}a.base=a.__P=null}if(a=t.__k)for(s=0;s<a.length;s++)a[s]&&gn(a[s],e,n||typeof t.type!="function");n||Ne(t.__e),t.__c=t.__=t.__e=void 0}function ia(t,e,n){return this.constructor(t,n)}function oa(t,e,n){var a,s,i,r;e==document&&(e=document.documentElement),g.__&&g.__(t,e),s=(a=!1)?null:e.__k,i=[],r=[],Ae(e,t=e.__k=pn(St,null,[t]),s||xt,xt,e.namespaceURI,s?null:e.firstChild?Jt.call(e.childNodes):null,i,s?s.__e:e.firstChild,a,r),mn(i,t,r)}Jt=vn.slice,g={__e:function(t,e,n,a){for(var s,i,r;e=e.__;)if((s=e.__c)&&!s.__)try{if((i=s.constructor)&&i.getDerivedStateFromError!=null&&(s.setState(i.getDerivedStateFromError(t)),r=s.__d),s.componentDidCatch!=null&&(s.componentDidCatch(t,a||{}),r=s.__d),r)return s.__E=s}catch(u){t=u}throw t}},rn=0,ln=function(t){return t!=null&&t.constructor===void 0},ut.prototype.setState=function(t,e){var n;n=this.__s!=null&&this.__s!=this.state?this.__s:this.__s=j({},this.state),typeof t=="function"&&(t=t(j({},n),this.props)),t&&j(n,t),t!=null&&this.__v&&(e&&this._sb.push(e),Oe(this))},ut.prototype.forceUpdate=function(t){this.__v&&(this.__e=!0,t&&this.__h.push(t),Oe(this))},ut.prototype.render=St,G=[],cn=typeof Promise=="function"?Promise.prototype.then.bind(Promise.resolve()):setTimeout,un=function(t,e){return t.__v.__b-e.__v.__b},Ot.__r=0,dn=/(PointerCapture)$|Capture$/i,Te=0,ue=Ue(!1),de=Ue(!0);var yn=function(t,e,n,a){var s;e[0]=0;for(var i=1;i<e.length;i++){var r=e[i++],u=e[i]?(e[0]|=r?1:2,n[e[i++]]):e[++i];r===3?a[0]=u:r===4?a[1]=Object.assign(a[1]||{},u):r===5?(a[1]=a[1]||{})[e[++i]]=u:r===6?a[1][e[++i]]+=u+"":r?(s=t.apply(u,yn(t,u,n,["",null])),a.push(s),u[0]?e[0]|=2:(e[i-2]=0,e[i]=s)):a.push(u)}return a},He=new Map;function ra(t){var e=He.get(this);return e||(e=new Map,He.set(this,e)),(e=yn(this,e.get(t)||(e.set(t,e=(function(n){for(var a,s,i=1,r="",u="",d=[0],c=function(_){i===1&&(_||(r=r.replace(/^\s*\n\s*|\s*\n\s*$/g,"")))?d.push(0,_,r):i===3&&(_||r)?(d.push(3,_,r),i=2):i===2&&r==="..."&&_?d.push(4,_,0):i===2&&r&&!_?d.push(5,0,!0,r):i>=5&&((r||!_&&i===5)&&(d.push(i,0,r,s),i=6),_&&(d.push(i,_,0,s),i=6)),r=""},v=0;v<n.length;v++){v&&(i===1&&c(),c(v));for(var l=0;l<n[v].length;l++)a=n[v][l],i===1?a==="<"?(c(),d=[d],i=3):r+=a:i===4?r==="--"&&a===">"?(i=1,r=""):r=a+r[0]:u?a===u?u="":r+=a:a==='"'||a==="'"?u=a:a===">"?(c(),i=1):i&&(a==="="?(i=5,s=r,r=""):a==="/"&&(i<5||n[v][l+1]===">")?(c(),i===3&&(d=d[0]),i=d,(d=d[0]).push(2,0,i),i=0):a===" "||a==="	"||a===`
`||a==="\r"?(c(),i=2):r+=a),i===3&&r==="!--"&&(i=4,d=d[0])}return c(),d})(t)),e),arguments,[])).length>1?e:e[0]}var o=ra.bind(pn),jt,N,ee,ze,Be=0,bn=[],S=g,Fe=S.__b,We=S.__r,Ke=S.diffed,Ge=S.__c,Ve=S.unmount,Je=S.__;function wn(t,e){S.__h&&S.__h(N,t,Be||e),Be=0;var n=N.__H||(N.__H={__:[],__h:[]});return t>=n.__.length&&n.__.push({}),n.__[t]}function pe(t,e){var n=wn(jt++,3);!S.__s&&xn(n.__H,e)&&(n.__=t,n.u=e,N.__H.__h.push(n))}function kn(t,e){var n=wn(jt++,7);return xn(n.__H,e)&&(n.__=t(),n.__H=e,n.__h=t),n.__}function la(){for(var t;t=bn.shift();)if(t.__P&&t.__H)try{t.__H.__h.forEach(It),t.__H.__h.forEach(fe),t.__H.__h=[]}catch(e){t.__H.__h=[],S.__e(e,t.__v)}}S.__b=function(t){N=null,Fe&&Fe(t)},S.__=function(t,e){t&&e.__k&&e.__k.__m&&(t.__m=e.__k.__m),Je&&Je(t,e)},S.__r=function(t){We&&We(t),jt=0;var e=(N=t.__c).__H;e&&(ee===N?(e.__h=[],N.__h=[],e.__.forEach(function(n){n.__N&&(n.__=n.__N),n.u=n.__N=void 0})):(e.__h.forEach(It),e.__h.forEach(fe),e.__h=[],jt=0)),ee=N},S.diffed=function(t){Ke&&Ke(t);var e=t.__c;e&&e.__H&&(e.__H.__h.length&&(bn.push(e)!==1&&ze===S.requestAnimationFrame||((ze=S.requestAnimationFrame)||ca)(la)),e.__H.__.forEach(function(n){n.u&&(n.__H=n.u),n.u=void 0})),ee=N=null},S.__c=function(t,e){e.some(function(n){try{n.__h.forEach(It),n.__h=n.__h.filter(function(a){return!a.__||fe(a)})}catch(a){e.some(function(s){s.__h&&(s.__h=[])}),e=[],S.__e(a,n.__v)}}),Ge&&Ge(t,e)},S.unmount=function(t){Ve&&Ve(t);var e,n=t.__c;n&&n.__H&&(n.__H.__.forEach(function(a){try{It(a)}catch(s){e=s}}),n.__H=void 0,e&&S.__e(e,n.__v))};var qe=typeof requestAnimationFrame=="function";function ca(t){var e,n=function(){clearTimeout(a),qe&&cancelAnimationFrame(e),setTimeout(t)},a=setTimeout(n,35);qe&&(e=requestAnimationFrame(n))}function It(t){var e=N,n=t.__c;typeof n=="function"&&(t.__c=void 0,n()),N=e}function fe(t){var e=N;t.__c=t.__(),N=e}function xn(t,e){return!t||t.length!==e.length||e.some(function(n,a){return n!==t[a]})}var ua=Symbol.for("preact-signals");function Xt(){if(z>1)z--;else{for(var t,e=!1;dt!==void 0;){var n=dt;for(dt=void 0,_e++;n!==void 0;){var a=n.o;if(n.o=void 0,n.f&=-3,!(8&n.f)&&Tn(n))try{n.c()}catch(s){e||(t=s,e=!0)}n=a}}if(_e=0,z--,e)throw t}}function da(t){if(z>0)return t();z++;try{return t()}finally{Xt()}}var m=void 0;function Sn(t){var e=m;m=void 0;try{return t()}finally{m=e}}var dt=void 0,z=0,_e=0,Ut=0;function Cn(t){if(m!==void 0){var e=t.n;if(e===void 0||e.t!==m)return e={i:0,S:t,p:m.s,n:void 0,t:m,e:void 0,x:void 0,r:e},m.s!==void 0&&(m.s.n=e),m.s=e,t.n=e,32&m.f&&t.S(e),e;if(e.i===-1)return e.i=0,e.n!==void 0&&(e.n.p=e.p,e.p!==void 0&&(e.p.n=e.n),e.p=m.s,e.n=void 0,m.s.n=e,m.s=e),e}}function T(t,e){this.v=t,this.i=0,this.n=void 0,this.t=void 0,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}T.prototype.brand=ua;T.prototype.h=function(){return!0};T.prototype.S=function(t){var e=this,n=this.t;n!==t&&t.e===void 0&&(t.x=n,this.t=t,n!==void 0?n.e=t:Sn(function(){var a;(a=e.W)==null||a.call(e)}))};T.prototype.U=function(t){var e=this;if(this.t!==void 0){var n=t.e,a=t.x;n!==void 0&&(n.x=a,t.e=void 0),a!==void 0&&(a.e=n,t.x=void 0),t===this.t&&(this.t=a,a===void 0&&Sn(function(){var s;(s=e.Z)==null||s.call(e)}))}};T.prototype.subscribe=function(t){var e=this;return Ct(function(){var n=e.value,a=m;m=void 0;try{t(n)}finally{m=a}},{name:"sub"})};T.prototype.valueOf=function(){return this.value};T.prototype.toString=function(){return this.value+""};T.prototype.toJSON=function(){return this.value};T.prototype.peek=function(){var t=m;m=void 0;try{return this.value}finally{m=t}};Object.defineProperty(T.prototype,"value",{get:function(){var t=Cn(this);return t!==void 0&&(t.i=this.i),this.v},set:function(t){if(t!==this.v){if(_e>100)throw new Error("Cycle detected");this.v=t,this.i++,Ut++,z++;try{for(var e=this.t;e!==void 0;e=e.x)e.t.N()}finally{Xt()}}}});function f(t,e){return new T(t,e)}function Tn(t){for(var e=t.s;e!==void 0;e=e.n)if(e.S.i!==e.i||!e.S.h()||e.S.i!==e.i)return!0;return!1}function Nn(t){for(var e=t.s;e!==void 0;e=e.n){var n=e.S.n;if(n!==void 0&&(e.r=n),e.S.n=e,e.i=-1,e.n===void 0){t.s=e;break}}}function An(t){for(var e=t.s,n=void 0;e!==void 0;){var a=e.p;e.i===-1?(e.S.U(e),a!==void 0&&(a.n=e.n),e.n!==void 0&&(e.n.p=a)):n=e,e.S.n=e.r,e.r!==void 0&&(e.r=void 0),e=a}t.s=n}function J(t,e){T.call(this,void 0),this.x=t,this.s=void 0,this.g=Ut-1,this.f=4,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}J.prototype=new T;J.prototype.h=function(){if(this.f&=-3,1&this.f)return!1;if((36&this.f)==32||(this.f&=-5,this.g===Ut))return!0;if(this.g=Ut,this.f|=1,this.i>0&&!Tn(this))return this.f&=-2,!0;var t=m;try{Nn(this),m=this;var e=this.x();(16&this.f||this.v!==e||this.i===0)&&(this.v=e,this.f&=-17,this.i++)}catch(n){this.v=n,this.f|=16,this.i++}return m=t,An(this),this.f&=-2,!0};J.prototype.S=function(t){if(this.t===void 0){this.f|=36;for(var e=this.s;e!==void 0;e=e.n)e.S.S(e)}T.prototype.S.call(this,t)};J.prototype.U=function(t){if(this.t!==void 0&&(T.prototype.U.call(this,t),this.t===void 0)){this.f&=-33;for(var e=this.s;e!==void 0;e=e.n)e.S.U(e)}};J.prototype.N=function(){if(!(2&this.f)){this.f|=6;for(var t=this.t;t!==void 0;t=t.x)t.t.N()}};Object.defineProperty(J.prototype,"value",{get:function(){if(1&this.f)throw new Error("Cycle detected");var t=Cn(this);if(this.h(),t!==void 0&&(t.i=this.i),16&this.f)throw this.v;return this.v}});function Ht(t,e){return new J(t,e)}function Pn(t){var e=t.u;if(t.u=void 0,typeof e=="function"){z++;var n=m;m=void 0;try{e()}catch(a){throw t.f&=-2,t.f|=8,De(t),a}finally{m=n,Xt()}}}function De(t){for(var e=t.s;e!==void 0;e=e.n)e.S.U(e);t.x=void 0,t.s=void 0,Pn(t)}function va(t){if(m!==this)throw new Error("Out-of-order effect");An(this),m=t,this.f&=-2,8&this.f&&De(this),Xt()}function st(t,e){this.x=t,this.u=void 0,this.s=void 0,this.o=void 0,this.f=32,this.name=e==null?void 0:e.name}st.prototype.c=function(){var t=this.S();try{if(8&this.f||this.x===void 0)return;var e=this.x();typeof e=="function"&&(this.u=e)}finally{t()}};st.prototype.S=function(){if(1&this.f)throw new Error("Cycle detected");this.f|=1,this.f&=-9,Pn(this),Nn(this),z++;var t=m;return m=this,va.bind(this,t)};st.prototype.N=function(){2&this.f||(this.f|=2,this.o=dt,dt=this)};st.prototype.d=function(){this.f|=8,1&this.f||De(this)};st.prototype.dispose=function(){this.d()};function Ct(t,e){var n=new st(t,e);try{n.c()}catch(s){throw n.d(),s}var a=n.d.bind(n);return a[Symbol.dispose]=a,a}var Dn,Dt,pa=typeof window<"u"&&!!window.__PREACT_SIGNALS_DEVTOOLS__,Rn=[];Ct(function(){Dn=this.N})();function it(t,e){g[t]=e.bind(null,g[t]||function(){})}function zt(t){if(Dt){var e=Dt;Dt=void 0,e()}Dt=t&&t.S()}function En(t){var e=this,n=t.data,a=_a(n);a.value=n;var s=kn(function(){for(var u=e,d=e.__v;d=d.__;)if(d.__c){d.__c.__$f|=4;break}var c=Ht(function(){var p=a.value.value;return p===0?0:p===!0?"":p||""}),v=Ht(function(){return!Array.isArray(c.value)&&!ln(c.value)}),l=Ct(function(){if(this.N=Ln,v.value){var p=c.value;u.__v&&u.__v.__e&&u.__v.__e.nodeType===3&&(u.__v.__e.data=p)}}),_=e.__$u.d;return e.__$u.d=function(){l(),_.call(this)},[v,c]},[]),i=s[0],r=s[1];return i.value?r.peek():r.value}En.displayName="ReactiveTextNode";Object.defineProperties(T.prototype,{constructor:{configurable:!0,value:void 0},type:{configurable:!0,value:En},props:{configurable:!0,get:function(){return{data:this}}},__b:{configurable:!0,value:1}});it("__b",function(t,e){if(typeof e.type=="string"){var n,a=e.props;for(var s in a)if(s!=="children"){var i=a[s];i instanceof T&&(n||(e.__np=n={}),n[s]=i,a[s]=i.peek())}}t(e)});it("__r",function(t,e){if(t(e),e.type!==St){zt();var n,a=e.__c;a&&(a.__$f&=-2,(n=a.__$u)===void 0&&(a.__$u=n=(function(s,i){var r;return Ct(function(){r=this},{name:i}),r.c=s,r})(function(){var s;pa&&((s=n.y)==null||s.call(n)),a.__$f|=1,a.setState({})},typeof e.type=="function"?e.type.displayName||e.type.name:""))),zt(n)}});it("__e",function(t,e,n,a){zt(),t(e,n,a)});it("diffed",function(t,e){zt();var n;if(typeof e.type=="string"&&(n=e.__e)){var a=e.__np,s=e.props;if(a){var i=n.U;if(i)for(var r in i){var u=i[r];u!==void 0&&!(r in a)&&(u.d(),i[r]=void 0)}else i={},n.U=i;for(var d in a){var c=i[d],v=a[d];c===void 0?(c=fa(n,d,v),i[d]=c):c.o(v,s)}for(var l in a)s[l]=a[l]}}t(e)});function fa(t,e,n,a){var s=e in t&&t.ownerSVGElement===void 0,i=f(n),r=n.peek();return{o:function(u,d){i.value=u,r=u.peek()},d:Ct(function(){this.N=Ln;var u=i.value.value;r!==u?(r=void 0,s?t[e]=u:u!=null&&(u!==!1||e[4]==="-")?t.setAttribute(e,u):t.removeAttribute(e)):r=void 0})}}it("unmount",function(t,e){if(typeof e.type=="string"){var n=e.__e;if(n){var a=n.U;if(a){n.U=void 0;for(var s in a){var i=a[s];i&&i.d()}}}e.__np=void 0}else{var r=e.__c;if(r){var u=r.__$u;u&&(r.__$u=void 0,u.d())}}t(e)});it("__h",function(t,e,n,a){(a<3||a===9)&&(e.__$f|=2),t(e,n,a)});ut.prototype.shouldComponentUpdate=function(t,e){if(this.__R)return!0;var n=this.__$u,a=n&&n.s!==void 0;for(var s in e)return!0;if(this.__f||typeof this.u=="boolean"&&this.u===!0){var i=2&this.__$f;if(!(a||i||4&this.__$f)||1&this.__$f)return!0}else if(!(a||4&this.__$f)||3&this.__$f)return!0;for(var r in t)if(r!=="__source"&&t[r]!==this.props[r])return!0;for(var u in this.props)if(!(u in t))return!0;return!1};function _a(t,e){return kn(function(){return f(t,e)},[])}var ha=function(t){queueMicrotask(function(){queueMicrotask(t)})};function ma(){da(function(){for(var t;t=Rn.shift();)Dn.call(t)})}function Ln(){Rn.push(this)===1&&(g.requestAnimationFrame||ha)(ma)}const $a=["overview","board","activity","agents","tasks","journal","trpg","council"],In={tab:"overview",params:{},postId:null};function Xe(t){return!!t&&$a.includes(t)}function he(t){try{return decodeURIComponent(t)}catch{return t}}function me(t){const e={};return t&&new URLSearchParams(t).forEach((a,s)=>{e[s]=a}),e}function ga(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function Mn(t,e){const n=t[0],a=e.tab,s=Xe(n)?n:Xe(a)?a:"overview";let i=null;return s==="board"&&(t[0]==="board"&&t[1]==="post"&&t[2]?i=he(t[2]):t[0]==="post"&&t[1]&&(i=he(t[1]))),{tab:s,params:e,postId:i}}function Bt(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return In;const n=he(e);let a=n,s;if(n.startsWith("?"))a="",s=n.slice(1);else{const u=n.indexOf("?");u>=0&&(a=n.slice(0,u),s=n.slice(u+1))}!s&&a.includes("=")&&!a.includes("/")&&(s=a,a="");const i=me(s),r=ga(a);return Mn(r,i)}function ya(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const a=n.slice(1);if(a.length===0)return{...In,params:me(e.replace(/^\?/,""))};if(a[0]==="assets"||a[0]==="credits"||a[0]==="lodge")return null;const s=me(e.replace(/^\?/,""));return Mn(a,s)}function On(t){const e=t.postId?`board/post/${encodeURIComponent(t.postId)}`:t.tab,n=Object.entries(t.params).filter(([s])=>s!=="tab");if(n.length===0)return`#${e}`;const a=new URLSearchParams(n);return`#${e}?${a.toString()}`}const I=f(Bt(window.location.hash));window.addEventListener("hashchange",()=>{I.value=Bt(window.location.hash)});function Qt(t,e){const n={tab:t,params:{},postId:null};window.location.hash=On(n)}function ba(t){window.location.hash=`#board/post/${encodeURIComponent(t)}`}function wa(){if(window.location.hash&&window.location.hash!=="#"){I.value=Bt(window.location.hash);return}const t=ya(window.location.pathname,window.location.search);if(t){I.value=t;const e=On(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#overview",I.value=Bt(window.location.hash)}const ka=[{id:"overview",label:"Overview",icon:"🏠"},{id:"council",label:"Council",icon:"🏛️"},{id:"board",label:"Board",icon:"💬"},{id:"activity",label:"Activity",icon:"📊"},{id:"agents",label:"Agents",icon:"🤖"},{id:"tasks",label:"Tasks",icon:"📋"},{id:"journal",label:"Journal",icon:"📓"},{id:"trpg",label:"TRPG",icon:"⚔️"}];function xa(){const t=I.value.tab;return o`
    <div class="main-tab-bar">
      ${ka.map(e=>o`
        <button
          class="main-tab-btn ${t===e.id?"active":""}"
          onClick=${()=>Qt(e.id)}
        >
          ${e.icon} ${e.label}
        </button>
      `)}
    </div>
  `}const Qe="masc_dashboard_sse_session_id",Sa=1e3,Ca=15e3,at=f(!1),Re=f(0),jn=f(null),$e=f([]);function Ta(){let t=sessionStorage.getItem(Qe);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(Qe,t)),t}const Na=200;function K(t,e){const n={agent:t,text:e,timestamp:Date.now()};$e.value=[n,...$e.value].slice(0,Na)}let L=null,tt=null,ge=0;function Un(){tt&&(clearTimeout(tt),tt=null)}function Aa(){if(tt)return;ge++;const t=Math.min(ge,5),e=Math.min(Ca,Sa*Math.pow(2,t));tt=setTimeout(()=>{tt=null,Hn()},e)}function Hn(){Un(),L&&(L.close(),L=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),a=t.get("token");n&&e.set("agent",n),a&&e.set("token",a),e.set("session_id",Ta());const s=e.toString()?`/sse?${e.toString()}`:"/sse",i=new EventSource(s);L=i,i.onopen=()=>{L===i&&(ge=0,at.value=!0)},i.onerror=()=>{L===i&&(at.value=!1,i.close(),L=null,Aa())},i.onmessage=r=>{try{const u=JSON.parse(r.data);Re.value++,jn.value=u,Pa(u)}catch{}}}function Pa(t){const e=t.type,n=t.agent??t.from??t.from_agent??"";switch(e){case"agent_joined":K(n,"Joined");break;case"agent_left":K(n,"Left");break;case"broadcast":K(n,`${(t.message??t.content??"").slice(0,80)}`);break;case"task_update":K(n,`Task: ${t.task_id??""} -> ${t.status??""}`);break;case"board_post":K(n,"New post");break;case"board_comment":K(n,"New comment");break;default:K(n,e)}}function Da(){Un(),L&&(L.close(),L=null),at.value=!1}function Ra(){return new URLSearchParams(window.location.search)}function zn(){const t=Ra(),e={},n=t.get("token"),a=t.get("agent")??t.get("agent_name");return n&&(e.Authorization=`Bearer ${n}`),a&&(e["X-MASC-Agent"]=a),e}function Bn(){return{...zn(),"Content-Type":"application/json"}}async function Tt(t){const e=await fetch(t,{headers:zn()});if(!e.ok)throw new Error(`GET ${t}: ${e.status} ${e.statusText}`);return e.json()}async function Nt(t,e){const n=await fetch(t,{method:"POST",headers:Bn(),body:JSON.stringify(e)});if(!n.ok)throw new Error(`POST ${t}: ${n.status} ${n.statusText}`);return n.json()}async function Ea(t,e,n){const a=await fetch(t,{method:"POST",headers:{...Bn(),...n??{}},body:JSON.stringify(e)});if(!a.ok)throw new Error(`POST ${t}: ${a.status} ${a.statusText}`);return a.text()}function La(t){const e=t.split(`
`).find(a=>a.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function Ia(t){var e,n,a,s,i,r,u;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const d=((s=(a=t.result.content)==null?void 0:a[0])==null?void 0:s.text)??"MCP tool call failed";throw new Error(d)}return((u=(r=(i=t.result)==null?void 0:i.content)==null?void 0:r[0])==null?void 0:u.text)??""}async function ot(t,e){const n=await Ea("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"}),a=La(n);return Ia(a)}function Fn(t){const e=t.trim();if(!e)return[];const n=JSON.parse(e);return Array.isArray(n)?n:[]}function Ma(){return Tt("/api/v1/dashboard")}function Oa(){return Tt("/api/v1/board")}function ja(t){return Tt(`/api/v1/board/${t}`)}function Wn(t,e){return Nt(`/api/v1/board/${t}/vote`,{direction:e})}function Ua(t,e,n){return Nt("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function O(t){return typeof t=="object"&&t!==null}function h(t,e=""){return typeof t=="string"?t:e}function U(t,e=0){return typeof t=="number"&&Number.isFinite(t)?t:e}function Ha(t,e=!1){return typeof t=="boolean"?t:e}function za(t){return t==="dm"||t==="player"||t==="npc"?t:"npc"}function R(t,e,n,a=0){const s=t[e];if(typeof s=="number"&&Number.isFinite(s))return s;if(n){const i=t[n];if(typeof i=="number"&&Number.isFinite(i))return i}return a}function Ba(t,e){if(t!=="dice.rolled")return;const n=U(e.raw_d20,0),a=U(e.total,0),s=U(e.bonus,0),i=h(e.action,"roll"),r=U(e.dc,0);return{notation:r>0?`${i} (DC ${r})`:i,rolls:n>0?[n]:[],total:a,modifier:s}}function Fa(t){const e=JSON.stringify(t);return e?e.length>160?`${e.slice(0,157)}...`:e:""}function Wa(t,e,n){const a=e||h(n.actor_id,"");switch(t){case"turn.action.proposed":{const s=h(n.proposed_action,h(n.reply,""));return s?`${a||"actor"}: ${s}`:"Action proposed"}case"turn.action.resolved":{const s=h(n.reply,h(n.result,""));return s?`Resolved: ${s}`:"Action resolved"}case"narration.posted":return h(n.reply,h(n.content,h(n.text,"Narration")));case"dice.rolled":{const s=h(n.action,"roll"),i=U(n.total,0),r=U(n.dc,0),u=h(n.label,""),d=a||"actor",c=r>0?` vs DC ${r}`:"",v=u?` (${u})`:"";return`${d} ${s}: ${i}${c}${v}`}case"turn.started":return`Turn ${U(n.turn,1)} started`;case"phase.changed":return`Phase: ${h(n.phase,"round")}`;case"actor.spawned":return`Actor spawned: ${h(n.name,a||"unknown")}`;case"actor.claimed":return`${h(n.keeper,"keeper")} claimed ${a||"actor"}`;case"actor.released":return`${h(n.keeper,"keeper")} released ${a||"actor"}`;case"combat.attack":return h(n.summary,h(n.result,"Attack resolved"));case"combat.defense":return h(n.summary,h(n.result,"Defense resolved"));case"session.outcome":return h(n.summary,h(n.outcome,"Session ended"));default:{const s=Fa(n);return s?`${t}: ${s}`:t}}}function Ka(t){const e=O(t)?t:{},n=h(e.type,"event"),a=typeof e.actor_id=="string"?e.actor_id:"",s=O(e.payload)?e.payload:{};return{type:n,actor:a||h(s.actor_id,""),content:Wa(n,a,s),dice_roll:Ba(n,s),timestamp:h(e.ts,new Date().toISOString())}}function Ga(t,e,n){var $,E;const a=h(t.room_id,"")||n||"default",s=O(t.state)?t.state:{},i=O(s.party)?s.party:{},r=O(s.actor_control)?s.actor_control:{},u=Object.entries(i).map(([P,M])=>{const b=O(M)?M:{},B=R(b,"max_hp",void 0,10),F=R(b,"hp",void 0,B),W=R(b,"max_mp",void 0,0),rt=R(b,"mp",void 0,0),D=R(b,"level",void 0,1),H=R(b,"xp",void 0,0),Yn=Ha(b.alive,F>0),Ie=r[P],ta=typeof Ie=="string"?Ie:void 0;return{id:P,name:h(b.name,P),role:za(b.role),keeper:ta,status:Yn?"active":"dead",stats:{hp:F,max_hp:B,mp:rt,max_mp:W,level:D,xp:H,strength:R(b,"strength","str",10),dexterity:R(b,"dexterity","dex",10),constitution:R(b,"constitution","con",10),intelligence:R(b,"intelligence","int",10),wisdom:R(b,"wisdom","wis",10),charisma:R(b,"charisma","cha",10)}}}),d=e.map(Ka),c=U(s.turn,1),v=h(s.phase,"round"),l=h(s.map,""),_=O(s.world)?s.world:{},p=l||h(_.ascii_map,h(_.map,"")),k=d.filter((P,M)=>{const b=e[M];if(!O(b))return!1;const B=O(b.payload)?b.payload:{};return U(B.turn,-1)===c}),A=(k.length>0?k:d).slice(-12),x=h(s.status,"active");return{session:{id:a,room:a,status:x==="ended"?"ended":x==="paused"?"paused":"active",round:c,actors:u,created_at:(($=d[0])==null?void 0:$.timestamp)??new Date().toISOString()},current_round:{round_number:c,phase:v,events:A,timestamp:((E=d[d.length-1])==null?void 0:E.timestamp)??new Date().toISOString()},map:p||void 0,party:u,story_log:d,history:[]}}async function Va(t){const e=`?room_id=${encodeURIComponent(t)}`,n=await Tt(`/api/v1/trpg/events${e}`);return Array.isArray(n.events)?n.events:[]}async function Ja(t){const e=`?room_id=${encodeURIComponent(t)}`,[n,a]=await Promise.all([Tt(`/api/v1/trpg/state${e}`),Va(t)]);return Ga(n,a,t)}function qa(t){return Nt("/api/v1/trpg/rounds/run",{room_id:t})}function Xa(t){const e={room_id:t.roomId,actor_id:t.actorId,action:t.action,stat_value:t.statValue,dc:t.dc};return t.rawD20!=null&&(e.raw_d20=t.rawD20),t.ruleModule&&(e.rule_module=t.ruleModule),Nt("/api/v1/trpg/dice/roll",e)}function Qa(t,e){return Nt("/api/v1/trpg/turns/advance",{room_id:t})}async function Za(t,e){await ot("masc_broadcast",{agent_name:t,message:e})}async function Ya(t,e,n=1){await ot("masc_add_task",{title:t,description:e,priority:n})}async function ts(){const t=await ot("masc_debates",{});return Fn(t)}async function es(){const t=await ot("masc_sessions",{});return Fn(t)}async function ns(t){const e=await ot("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}function as(t){return ot("masc_debate_status",{debate_id:t})}const At=f([]),Zt=f([]),Kn=f([]),Yt=f([]),Ee=f(null),ct=f(null),Gn=f([]),Ze=f("hot"),Vn=f(null),vt=f(""),ye=f(!1),be=f(!1),we=f(!1),ss=Ht(()=>At.value.filter(t=>t.status==="active"||t.status==="idle")),Jn=Ht(()=>{const t=Zt.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}});let Mt=null;const is=5e3;function qn(){Mt=null}function os(t){return Array.isArray(t)?t:t&&Array.isArray(t.keepers)?t.keepers:[]}async function te(){var e,n,a;const t=Date.now();if(!(Mt&&t-Mt.time<is)){ye.value=!0;try{const s=await Ma();Mt={data:s,time:t},At.value=((e=s.agents)==null?void 0:e.agents)??[],Zt.value=((n=s.tasks)==null?void 0:n.tasks)??[],Kn.value=((a=s.messages)==null?void 0:a.messages)??[],Yt.value=os(s.keepers),Ee.value=s.status??null,ct.value=s.perpetual??null}catch(s){console.error("Dashboard fetch error:",s)}finally{ye.value=!1}}}async function q(){be.value=!0;try{const t=await Oa();Gn.value=t.posts??[]}catch(t){console.error("Board fetch error:",t)}finally{be.value=!1}}async function et(){var t;we.value=!0;try{const e=vt.value||((t=Ee.value)==null?void 0:t.room)||"default";vt.value||(vt.value=e);const n=await Ja(e);Vn.value=n}catch(e){console.error("TRPG fetch error:",e)}finally{we.value=!1}}let ne=null,ae=null;function rs(){return jn.subscribe(e=>{e&&(qn(),ne||(ne=setTimeout(()=>{te(),ne=null},500)),(e.type==="board_post"||e.type==="board_comment")&&(ae||(ae=setTimeout(()=>{q(),ae=null},500))))})}let pt=null;function ls(){pt||(pt=setInterval(()=>{qn(),te()},1e4))}function cs(){pt&&(clearInterval(pt),pt=null)}function w({title:t,class:e,children:n}){return o`
    <div class="card ${e??""}">
      ${t?o`<div class="card-title">${t}</div>`:null}
      ${n}
    </div>
  `}function X({status:t,label:e}){return o`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??t}
    </span>
  `}function Z({label:t,value:e,color:n}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color: ${n}`:""}>${e}</div>
    </div>
  `}function us({agent:t}){return o`
    <div class="agent">
      <span class="agent-emoji">${t.emoji??""}</span>
      <span class="agent-status ${t.status}"></span>
      <span class="agent-name">${t.name}</span>
      <${X} status=${t.status} />
      ${t.current_task?o`<span class="agent-task">${t.current_task}</span>`:null}
    </div>
  `}function ds({keeper:t}){return o`
    <div class="live-agent keeper-card">
      <div class="live-agent-main">
        <div class="live-agent-title">
          <span class="live-agent-name">${t.emoji??""} ${t.name}</span>
          <${X} status=${t.status} />
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
  `}function Ye(){const t=Ee.value,e=At.value,n=Yt.value,a=Jn.value;return o`
    <div class="stats-grid">
      <${Z} label="Agents" value=${e.length} />
      <${Z} label="Active" value=${ss.value.length} color="#4ade80" />
      <${Z} label="Keepers" value=${n.length} color="#22d3ee" />
      <${Z} label="Tasks" value=${Zt.value.length} />
      <${Z} label="In Progress" value=${a.inProgress.length} color="#fbbf24" />
      <${Z} label="Done" value=${a.done.length} color="#4ade80" />
    </div>

    <div class="grid-2col">
      <${w} title="Agents" class="section">
        <div class="agent-list">
          ${e.length===0?o`<div class="empty-state">No agents connected</div>`:e.map(s=>o`<${us} key=${s.name} agent=${s} />`)}
        </div>
      <//>

      <${w} title="Keepers" class="section">
        <div class="live-agent-list">
          ${n.length===0?o`<div class="empty-state">No keepers active</div>`:n.map(s=>o`<${ds} key=${s.name} keeper=${s} />`)}
        </div>
      <//>
    </div>

    ${ct.value?o`
        <${w} title="Perpetual Runtime" class="section">
          <div class="live-agent-meta">
            <span>Status: ${ct.value.running?"Running":"Stopped"}</span>
            ${ct.value.goal?o`<span>Goal: ${ct.value.goal}</span>`:null}
          </div>
        <//>
      `:null}

    ${t!=null&&t.room?o`
        <${w} title="Room" class="section">
          <div class="live-agent-meta">
            <span>Room: ${t.room}</span>
            <span>Uptime: ${vs(t.uptime_seconds)}</span>
          </div>
        <//>
      `:null}
  `}function vs(t){if(!t)return"N/A";const e=Math.floor(t/3600),n=Math.floor(t%3600/60);return e>0?`${e}h ${n}m`:`${n}m`}let ps=0;const V=f([]);function C(t,e="success",n=4e3){const a=++ps;V.value=[...V.value,{id:a,message:t,type:e}],setTimeout(()=>{V.value=V.value.filter(s=>s.id!==a)},n)}function fs(t){V.value=V.value.filter(e=>e.id!==t)}function _s(){const t=V.value;return t.length===0?null:o`
    <div class="toast-container">
      ${t.map(e=>o`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>fs(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}const ke=f([]),xe=f([]),ft=f(""),Ft=f(!1),_t=f(!1),Wt=f(""),Kt=f(null),ht=f(""),Se=f(!1);async function Ce(){Ft.value=!0,Wt.value="";try{const[t,e]=await Promise.all([ts(),es()]);ke.value=t,xe.value=e}catch(t){Wt.value=t instanceof Error?t.message:"Failed to load council data"}finally{Ft.value=!1}}async function tn(){const t=ft.value.trim();if(t){_t.value=!0;try{const e=await ns(t);ft.value="",C(e!=null&&e.id?`Debate started: ${e.id}`:"Debate started","success"),await Ce()}catch(e){const n=e instanceof Error?e.message:"Failed to start debate";C(n,"error")}finally{_t.value=!1}}}async function hs(t){Kt.value=t,Se.value=!0,ht.value="";try{ht.value=await as(t)}catch(e){ht.value=e instanceof Error?e.message:"Failed to load debate status"}finally{Se.value=!1}}function ms({debate:t}){const e=Kt.value===t.id;return o`
    <button
      class="council-row ${e?"selected":""}"
      onClick=${()=>hs(t.id)}
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
  `}function $s({session:t}){return o`
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
  `}function gs(){return pe(()=>{Ce()},[]),o`
    <div>
      <${w} title="Council Command" class="section">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${ft.value}
            onInput=${t=>{ft.value=t.target.value}}
            onKeyDown=${t=>{t.key==="Enter"&&tn()}}
            disabled=${_t.value}
          />
          <button
            class="control-btn secondary"
            onClick=${tn}
            disabled=${_t.value||ft.value.trim()===""}
          >
            ${_t.value?"Starting...":"Start Debate"}
          </button>
          <button class="control-btn ghost" onClick=${Ce} disabled=${Ft.value}>
            ${Ft.value?"Refreshing...":"Refresh"}
          </button>
        </div>
        ${Wt.value?o`<div class="council-error">${Wt.value}</div>`:null}
      <//>

      <div class="council-grid">
        <${w} title="Debates" class="section">
          <div class="council-list">
            ${ke.value.length===0?o`<div class="empty-state">No debates yet</div>`:ke.value.map(t=>o`<${ms} key=${t.id} debate=${t} />`)}
          </div>
        <//>

        <${w} title="Voting Sessions" class="section">
          <div class="council-list">
            ${xe.value.length===0?o`<div class="empty-state">No active sessions</div>`:xe.value.map(t=>o`<${$s} key=${t.id} session=${t} />`)}
          </div>
        <//>
      </div>

      <${w} title=${Kt.value?`Debate Detail (${Kt.value})`:"Debate Detail"} class="section">
        ${Se.value?o`<div class="loading-indicator">Loading debate detail...</div>`:ht.value?o`<pre class="council-detail">${ht.value}</pre>`:o`<div class="empty-state">Select a debate to view summary</div>`}
      <//>
    </div>
  `}function ys(t){const e=Date.now(),n=typeof t=="number"?t:new Date(t).getTime(),a=Math.floor((e-n)/1e3);if(a<60)return`${a}s ago`;const s=Math.floor(a/60);if(s<60)return`${s}m ago`;const i=Math.floor(s/60);return i<24?`${i}h ago`:`${Math.floor(i/24)}d ago`}function Q({timestamp:t}){const e=ys(t);return o`<span class="time-ago" title=${typeof t=="string"?t:new Date(t).toISOString()}>${e}</span>`}function bs({text:t}){if(!t)return null;const e=ws(t);return o`<div class="markdown-content">${e}</div>`}function ws(t){const e=t.split(`
`),n=[];let a=0;for(;a<e.length;){const s=e[a];if(/^(`{3,}|~{3,})/.test(s)){const r=s.match(/^(`{3,}|~{3,})/)[0],u=s.slice(r.length).trim(),d=[];for(a++;a<e.length&&!e[a].startsWith(r);)d.push(e[a]),a++;a++,n.push(o`<pre><code class=${u?`language-${u}`:""}>${d.join(`
`)}</code></pre>`);continue}if(s.trim()==="<think>"||s.trim().startsWith("<think>")){const r=[],u=s.trim().replace(/^<think>/,"").trim();for(u&&u!=="</think>"&&r.push(u),a++;a<e.length&&!e[a].includes("</think>");)r.push(e[a]),a++;if(a<e.length){const c=e[a].replace("</think>","").trim();c&&r.push(c),a++}const d=r.join(`
`).trim();n.push(o`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${se(d)}</div>
        </details>
      `);continue}if(s.startsWith("> ")){const r=[];for(;a<e.length&&e[a].startsWith("> ");)r.push(e[a].slice(2)),a++;n.push(o`<blockquote>${se(r.join(`
`))}</blockquote>`);continue}if(s.trim()===""){a++;continue}const i=[];for(;a<e.length;){const r=e[a];if(r.trim()===""||/^(`{3,}|~{3,})/.test(r)||r.startsWith("> ")||r.trim().startsWith("<think>"))break;i.push(r),a++}i.length>0&&n.push(o`<p>${se(i.join(`
`))}</p>`)}return n}function se(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let a=0,s;for(;(s=n.exec(t))!==null;){if(s.index>a&&e.push(t.slice(a,s.index)),s[1]){const i=s[1].slice(1,-1);e.push(o`<code>${i}</code>`)}else if(s[2]){const i=s[2].slice(2,-2);e.push(o`<strong>${i}</strong>`)}else if(s[3]){const i=s[3].slice(1,-1);e.push(o`<em>${i}</em>`)}else s[4]&&s[5]&&e.push(o`<a href=${s[5]} target="_blank" rel="noopener">${s[4]}</a>`);a=s.index+s[0].length}return a<t.length&&e.push(t.slice(a)),e.length>0?e:[t]}const ks=[{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"recent",label:"Recent"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],mt=f([]),$t=f(!1),gt=f(""),xs=f("dashboard-user"),yt=f(!1);async function Xn(t){$t.value=!0,mt.value=[];try{const e=await ja(t);mt.value=e.comments??[]}catch{}finally{$t.value=!1}}async function en(t){const e=gt.value.trim();if(e){yt.value=!0;try{await Ua(t,xs.value,e),gt.value="",C("Comment posted","success"),await Xn(t),q()}catch{C("Failed to post comment","error")}finally{yt.value=!1}}}function Ss(){const t=Ze.value;return o`
    <div class="board-controls">
      ${ks.map(e=>o`
        <button
          class="board-sort-btn ${t===e.id?"active":""}"
          onClick=${()=>{Ze.value=e.id,q()}}
        >
          ${e.label}
        </button>
      `)}
    </div>
  `}function Qn({flair:t}){return t?o`<span class="post-flair ${t}">${t}</span>`:null}function Cs({post:t}){const e=async(n,a)=>{a.stopPropagation(),await Wn(t.id,n),q()};return o`
    <div class="board-post" onClick=${()=>ba(t.id)}>
      <div class="vote-column">
        <button class="vote-btn upvote" onClick=${n=>e("up",n)}>▲</button>
        <span class="vote-count">${t.votes??0}</span>
        <button class="vote-btn downvote" onClick=${n=>e("down",n)}>▼</button>
      </div>
      <div class="post-content">
        <div class="post-title">
          ${t.title}
          ${" "}
          <${Qn} flair=${t.flair} />
        </div>
        <div class="post-meta">
          <span>${t.author}</span>
          <${Q} timestamp=${t.created_at} />
          ${t.comment_count>0?o`<span>${t.comment_count} comments</span>`:null}
          ${(t.hearth_count??0)>0?o`<span>♥ ${t.hearth_count}</span>`:null}
        </div>
      </div>
    </div>
  `}function Ts({comments:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No comments yet</div>`:o`
    <div class="comment-thread">
      ${t.map(e=>o`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${Q} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function Ns({postId:t}){return o`
    <div class="comment-form" style="margin-top: 12px; display: flex; gap: 8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${gt.value}
        onInput=${e=>{gt.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&en(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${yt.value}
      />
      <button
        onClick=${()=>en(t)}
        disabled=${yt.value||gt.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${yt.value?"...":"Post"}
      </button>
    </div>
  `}function As({post:t}){mt.value.length===0&&!$t.value&&Xn(t.id);const e=async n=>{await Wn(t.id,n),q()};return o`
    <div>
      <button class="back-btn" onClick=${()=>Qt("board")}>← Back to Board</button>
      <${w} title=${o`${t.title} <${Qn} flair=${t.flair} />`}>
        <div class="board-detail">
          <div class="post-body">
            <${bs} text=${t.content} />
          </div>
          <div class="post-meta" style="margin-top: 12px;">
            <span>${t.author}</span>
            <${Q} timestamp=${t.created_at} />
            <span>${t.votes??0} votes</span>
            ${(t.hearth_count??0)>0?o`<span>♥ ${t.hearth_count}</span>`:null}
          </div>
          <div style="margin-top: 8px; display: flex; gap: 6px;">
            <button class="vote-btn upvote" onClick=${()=>e("up")}>▲ Upvote</button>
            <button class="vote-btn downvote" onClick=${()=>e("down")}>▼ Downvote</button>
          </div>
        </div>
      <//>

      <${w} title="Comments (${$t.value?"...":mt.value.length})">
        ${$t.value?o`<div class="loading-indicator">Loading comments...</div>`:o`<${Ts} comments=${mt.value} />`}
        <${Ns} postId=${t.id} />
      <//>
    </div>
  `}function Ps(){const t=Gn.value,e=be.value,n=I.value.postId;if(n){const a=t.find(s=>s.id===n);return a?o`<${As} post=${a} />`:o`
          <div>
            <button class="back-btn" onClick=${()=>Qt("board")}>← Back to Board</button>
            <div class="empty-state">Post not found</div>
          </div>
        `}return o`
    <${Ss} />
    ${e?o`<div class="loading-indicator">Loading board...</div>`:t.length===0?o`<div class="empty-state">No posts yet</div>`:o`<div class="board-post-list">
            ${t.map(a=>o`<${Cs} key=${a.id} post=${a} />`)}
          </div>`}
  `}function Ds({msg:t}){return o`
    <div class="message-row">
      <span class="message-author">${t.from??"system"}</span>
      <span class="message-content">${t.content}</span>
      <${Q} timestamp=${t.timestamp} />
    </div>
  `}function Rs(){const t=Kn.value;return o`
    <div class="section">
      <h2>Recent Activity</h2>
      <div class="message-list">
        ${t.length===0?o`<div class="empty-state">No recent activity</div>`:t.slice(0,50).map((e,n)=>o`<${Ds} key=${n} msg=${e} />`)}
      </div>
    </div>
  `}const Le=f(null);function Es(t){Le.value=t}function nn(){Le.value=null}function Ls({keeper:t}){const e=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return o`
    <div class="keeper-kpis">
      ${e.map(n=>o`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${n.label}</div>
          <div class="keeper-kpi-value">${n.value}</div>
          ${n.hint?o`<div class="keeper-kpi-hint">${n.hint}</div>`:null}
        </div>
      `)}
    </div>
  `}function Is({keeper:t}){const e=t.context_ratio;if(e==null)return null;const n=Math.round(e*100),a=n>80?"bad":n>60?"warn":"";return o`
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
  `}const ie=f("");function Ms({keeper:t}){var s,i;const e=ie.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((s=t.traits)==null?void 0:s.join(", "))||"-"},{title:"Interests",key:"interests",value:((i=t.interests)==null?void 0:i.join(", "))||"-"}],a=e?n.filter(r=>r.title.toLowerCase().includes(e)||r.key.includes(e)||r.value.toLowerCase().includes(e)):n;return o`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${ie.value}
        onInput=${r=>{ie.value=r.target.value}}
      />
      ${a.map(r=>o`
        <div class="keeper-field-row">
          <span class="keeper-field-title">${r.title}</span>
          <span class="keeper-field-key">${r.key}</span>
          <span style="flex:1; text-align:right; color:#ccc;">${r.value}</span>
        </div>
      `)}
    </div>
  `}function Os({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return o`
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
  `}function js({items:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No equipment</div>`:o`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>o`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function Us({rels:t}){const e=Object.entries(t);return e.length===0?o`<div class="empty-state" style="font-size:13px">No relationships</div>`:o`
    <div class="keeper-k2k-list">
      ${e.map(([n,a])=>o`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${a}</span>
        </div>
      `)}
    </div>
  `}function an({traits:t,label:e}){return t.length===0?null:o`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>o`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function Hs(){const t=Le.value;return t?o`
    <div
      class="keeper-detail-overlay"
      style="position:fixed; inset:0; z-index:1000; background:rgba(0,0,0,0.7); display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${e=>{e.target.classList.contains("keeper-detail-overlay")&&nn()}}
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
            <${X} status=${t.status} />
            ${t.model?o`<span class="pill">${t.model}</span>`:null}
          </div>
          <button
            onClick=${()=>nn()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${Ls} keeper=${t} />

        ${""}
        <${Is} keeper=${t} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${w} title="Field Dictionary">
            <${Ms} keeper=${t} />
          <//>

          ${""}
          <${w} title="Profile">
            <${an} traits=${t.traits??[]} label="Traits" />
            <${an} traits=${t.interests??[]} label="Interests" />
            ${t.primaryValue?o`<div style="font-size:12px; color:#888;">Primary value: <span style="color:#4ade80;">${t.primaryValue}</span></div>`:null}
            ${t.last_heartbeat?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Last heartbeat: <${Q} timestamp=${t.last_heartbeat} />
                </div>`:null}
          <//>

          ${""}
          ${t.trpg_stats?o`
              <${w} title="TRPG Stats">
                <${Os} stats=${t.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?o`
              <${w} title="Equipment (${t.inventory.length})">
                <${js} items=${t.inventory} />
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?o`
              <${w} title="Relationships (${Object.keys(t.relationships).length})">
                <${Us} rels=${t.relationships} />
              <//>
            `:null}
        </div>
      </div>
    </div>
  `:null}function zs({agent:t}){return o`
    <div class="agent-card ${t.status}">
      <div class="agent-card-header">
        <span class="agent-emoji">${t.emoji??""}</span>
        <div class="agent-card-info">
          <span class="agent-name">${t.name}</span>
          ${t.koreanName?o`<span class="agent-korean">${t.koreanName}</span>`:null}
        </div>
        <${X} status=${t.status} />
      </div>
      ${t.current_task?o`<div class="agent-task">${t.current_task}</div>`:null}
      ${t.model?o`<div class="agent-model"><span class="pill">${t.model}</span></div>`:null}
    </div>
  `}function Bs({keeper:t}){const e=t.context_ratio!=null?Math.round(t.context_ratio*100):null,n=e!=null?e>80?"bad":e>60?"warn":"":"";return o`
    <div class="live-agent keeper-card" onClick=${()=>Es(t)} style="cursor:pointer;">
      <div class="live-agent-main">
        <div class="live-agent-title">
          <span class="live-agent-name">${t.emoji??""} ${t.name}</span>
          <${X} status=${t.status} />
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
  `}function Fs(){const t=At.value,e=Yt.value;return o`
    <div>
      ${e.length>0?o`
          <div class="section" style="margin-bottom: 20px">
            <h2>Keepers (Live)</h2>
            <div class="live-agent-list">
              ${e.map(n=>o`<${Bs} key=${n.name} keeper=${n} />`)}
            </div>
          </div>
        `:null}

      <div class="section">
        <h2>All Agents</h2>
        ${t.length===0?o`<div class="empty-state">No agents registered</div>`:o`
            <div class="agent-grid">
              ${t.map(n=>o`<${zs} key=${n.name} agent=${n} />`)}
            </div>
          `}
      </div>
    </div>
  `}function oe({task:t}){return o`
    <div class="task-row">
      <${X} status=${t.status} />
      <div class="task-info">
        <span class="task-title">${t.title}</span>
        ${t.assignee?o`<span class="task-assignee">${t.assignee}</span>`:null}
      </div>
      ${t.created_at?o`<${Q} timestamp=${t.created_at} />`:null}
    </div>
  `}function Ws(){const{todo:t,inProgress:e,done:n}=Jn.value;return o`
    <div class="grid-2col">
      <${w} title="In Progress (${e.length})" class="section">
        <div class="task-list">
          ${e.length===0?o`<div class="empty-state">No tasks in progress</div>`:e.map(a=>o`<${oe} key=${a.id} task=${a} />`)}
        </div>
      <//>

      <${w} title="To Do (${t.length})" class="section">
        <div class="task-list">
          ${t.length===0?o`<div class="empty-state">No pending tasks</div>`:t.map(a=>o`<${oe} key=${a.id} task=${a} />`)}
        </div>
      <//>
    </div>

    ${n.length>0?o`
        <${w} title="Done (${n.length})" class="section" style="margin-top: 20px">
          <div class="task-list">
            ${n.slice(0,20).map(a=>o`<${oe} key=${a.id} task=${a} />`)}
            ${n.length>20?o`<div class="empty-state">...and ${n.length-20} more</div>`:null}
          </div>
        <//>
      `:null}
  `}function Ks({event:t}){const n={agent_joined:"#4ade80",agent_left:"#ef4444",broadcast:"#22d3ee",task_update:"#fbbf24",board_post:"#a78bfa",board_comment:"#a78bfa",heartbeat:"#666"}[t.type]??"#888",a=t.message??t.content??t.status??"";return o`
    <div class="journal-entry">
      <span class="journal-type" style="color: ${n}">${t.type}</span>
      <span class="journal-agent">${t.agent??t.from??t.from_agent??""}</span>
      <span class="journal-data">${a}</span>
    </div>
  `}function Gs(){const t=$e.value;return o`
    <div class="section">
      <h2>Event Journal</h2>
      <div class="journal-list">
        ${t.length===0?o`<div class="empty-state">No events recorded yet</div>`:t.map((e,n)=>o`<${Ks} key=${n} event=${e} />`)}
      </div>
    </div>
  `}const lt=f(""),re=f("ability_check"),le=f("10"),ce=f("12"),Rt=f(""),Et=f("idle");function Vs(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function Js(t,e){return e>0?Math.round(t/e*100):0}function qs({hp:t,max:e}){const n=Js(t,e),a=Vs(t,e);return o`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${a}" style="width:${n}%" />
    </div>
  `}function Xs({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return o`
    <div class="trpg-actor-stats">
      ${e.map(n=>o`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function Qs({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return o`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function Zs({actor:t}){return o`
    <div class="trpg-actor">
      <div class="trpg-actor-info">
        <span class="trpg-actor-name">${t.name}</span>
        <${X} status=${t.status??"idle"} />
        <span class="pill">${t.role}</span>
        <${Qs} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?o`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?o`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${qs} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${Xs} stats=${t.stats} />
          </div>
        `:null}
    </div>
  `}function Ys({mapStr:t}){return o`<pre class="trpg-map">${t}</pre>`}function ti({events:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No story events yet</div>`:o`
    <div class="trpg-story">
      ${t.slice(-30).map((e,n)=>{var a;return o`
        <div key=${n} class="trpg-event ${e.type??""}">
          ${e.actor?o`<strong>${e.actor}</strong>${" "}`:null}
          ${e.dice_roll?o`<span class="trpg-dice">[${e.dice_roll.notation}: ${(a=e.dice_roll.rolls)==null?void 0:a.join(",")} = ${e.dice_roll.total}${e.dice_roll.modifier?` +${e.dice_roll.modifier}`:""}]</span>${" "}`:null}
          <span class="trpg-event-text">${e.content??""}</span>
          <span style="float:right; font-size:10px; color:#555;"><${Q} timestamp=${e.timestamp} /></span>
        </div>
      `})}
    </div>
  `}function ei({state:t}){const e=t.history??[];return e.length===0?null:o`
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
  `}function ni({state:t}){var d;const e=vt.value||((d=t.session)==null?void 0:d.room)||"",n=Et.value,a=t.party??[];if(!a.find(c=>c.id===lt.value)&&a.length>0){const c=a[0];c&&(lt.value=c.id)}const i=async()=>{if(!e){C("No room set","error");return}Et.value="running";try{await qa(e),Et.value="ok",C("Round executed","success"),et()}catch{Et.value="error",C("Round failed","error")}},r=async()=>{if(e)try{await Qa(e),C("Turn advanced","success"),et()}catch{C("Advance failed","error")}},u=async()=>{if(!e)return;const c=lt.value.trim();if(!c){C("Select actor first","warning");return}const v=Number.parseInt(le.value,10),l=Number.parseInt(ce.value,10);if(Number.isNaN(v)||Number.isNaN(l)){C("Stat/DC must be numbers","warning");return}const _=Number.parseInt(Rt.value,10),p=Rt.value.trim()===""||Number.isNaN(_)?void 0:_;try{await Xa({roomId:e,actorId:c,action:re.value.trim()||"ability_check",statValue:v,dc:l,rawD20:p}),C("Dice rolled","success"),et()}catch{C("Dice roll failed","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Room</label>
          <input
            type="text"
            value=${e}
            onInput=${c=>{vt.value=c.target.value}}
            placeholder="room_id"
          />
        </div>

        <div class="trpg-control-field">
          <label>Actor</label>
          <select
            value=${lt.value}
            onChange=${c=>{lt.value=c.target.value}}
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
              value=${re.value}
              onInput=${c=>{re.value=c.target.value}}
              placeholder="action"
            />
            <input
              type="text"
              value=${le.value}
              onInput=${c=>{le.value=c.target.value}}
              placeholder="stat (e.g. 14)"
            />
            <input
              type="text"
              value=${ce.value}
              onInput=${c=>{ce.value=c.target.value}}
              placeholder="dc (e.g. 15)"
            />
            <input
              type="text"
              value=${Rt.value}
              onInput=${c=>{Rt.value=c.target.value}}
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
  `}function ai({state:t}){var n;const e=t.current_round;return e?o`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?o`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function si(){var s,i;const t=Vn.value;if(we.value&&!t)return o`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return o`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>et()}>Refresh</button>
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
      <${ai} state=${t} />

      ${""}
      <div class="trpg-layout">
        <div>
          ${""}
          <${w} title="Story Log (${a.length})">
            <${ti} events=${a} />
          <//>

          ${""}
          ${t.map?o`
              <${w} title="Map" style="margin-top:16px;">
                <${Ys} mapStr=${t.map} />
              <//>`:null}
        </div>

        <div class="trpg-sidebar">
          ${""}
          <${w} title="Controls">
            <${ni} state=${t} />
          <//>

          ${""}
          <${w} title="Party (${n.length})" style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(r=>o`<${Zs} key=${r.id??r.name} actor=${r} />`)}
              ${n.length===0?o`<div class="empty-state" style="font-size:13px">No actors</div>`:null}
            </div>
          <//>

          ${""}
          ${t.history&&t.history.length>0?o`
              <${w} title="History (${t.history.length})" style="margin-top:16px;">
                <${ei} state=${t} />
              <//>`:null}
        </div>
      </div>
    </div>
  `}const Zn="masc_dashboard_agent_name";function ii(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem(Zn);return e??n??"dashboard"}const Gt=f(ii()),bt=f(""),wt=f(""),Vt=f(""),kt=f(!1),Y=f(!1);function oi(t){const e=t.trim();Gt.value=e,e&&localStorage.setItem(Zn,e)}async function sn(){const t=Gt.value.trim(),e=bt.value.trim();if(!(!t||!e)){kt.value=!0;try{await Za(t,e),bt.value="",C("Broadcast sent","success")}catch(n){const a=n instanceof Error?n.message:"Failed to send broadcast";C(a,"error")}finally{kt.value=!1}}}async function ri(){const t=wt.value.trim(),e=Vt.value.trim()||"Created from dashboard";if(t){Y.value=!0;try{await Ya(t,e,1),wt.value="",Vt.value="",C("Task created","success")}catch(n){const a=n instanceof Error?n.message:"Failed to create task";C(a,"error")}finally{Y.value=!1}}}function li(){return o`
    <section class="rail-card control-dock">
      <h3>Control Dock</h3>

      <label class="control-label" for="dock-agent">Agent</label>
      <input
        id="dock-agent"
        class="control-input"
        type="text"
        value=${Gt.value}
        onInput=${t=>oi(t.target.value)}
      />

      <label class="control-label" for="dock-message">Broadcast</label>
      <div class="control-row">
        <input
          id="dock-message"
          class="control-input"
          type="text"
          placeholder="@agent message or room update"
          value=${bt.value}
          onInput=${t=>{bt.value=t.target.value}}
          onKeyDown=${t=>{t.key==="Enter"&&sn()}}
          disabled=${kt.value}
        />
        <button
          class="control-btn"
          onClick=${sn}
          disabled=${kt.value||bt.value.trim()===""||Gt.value.trim()===""}
        >
          ${kt.value?"Sending...":"Send"}
        </button>
      </div>

      <label class="control-label" for="dock-task">Quick Task</label>
      <input
        id="dock-task"
        class="control-input"
        type="text"
        placeholder="Task title"
        value=${wt.value}
        onInput=${t=>{wt.value=t.target.value}}
        disabled=${Y.value}
      />
      <textarea
        class="control-textarea"
        placeholder="Task description (optional)"
        value=${Vt.value}
        onInput=${t=>{Vt.value=t.target.value}}
        disabled=${Y.value}
      ></textarea>
      <button
        class="control-btn secondary"
        onClick=${ri}
        disabled=${Y.value||wt.value.trim()===""}
      >
        ${Y.value?"Creating...":"Create Task"}
      </button>
    </section>
  `}function ci(){const t=at.value;return o`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"Live":"Reconnecting..."}</span>
      <span class="event-count">${Re.value} events</span>
    </div>
  `}const ui=[{id:"overview",label:"Overview"},{id:"council",label:"Council"},{id:"board",label:"Board"},{id:"activity",label:"Activity"},{id:"agents",label:"Agents"},{id:"tasks",label:"Tasks"},{id:"journal",label:"Journal"},{id:"trpg",label:"TRPG"}];function di(){const t=I.value.tab,e=at.value;return o`
    <aside class="dashboard-rail">
      <section class="rail-card">
        <h3>Views</h3>
        <div class="rail-tab-list">
          ${ui.map(n=>o`
            <button
              class="rail-tab-btn ${t===n.id?"active":""}"
              onClick=${()=>Qt(n.id)}
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
            <strong>${At.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Keepers</span>
            <strong>${Yt.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Tasks</span>
            <strong>${Zt.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Events</span>
            <strong>${Re.value}</strong>
          </div>
        </div>
        <button
          class="rail-refresh-btn"
          onClick=${()=>{te(),t==="board"&&q(),t==="trpg"&&et()}}
        >
          Refresh Now
        </button>
      </section>

      <${li} />
    </aside>
  `}function vi(){switch(I.value.tab){case"overview":return o`<${Ye} />`;case"council":return o`<${gs} />`;case"board":return o`<${Ps} />`;case"activity":return o`<${Rs} />`;case"agents":return o`<${Fs} />`;case"tasks":return o`<${Ws} />`;case"journal":return o`<${Gs} />`;case"trpg":return o`<${si} />`;default:return o`<${Ye} />`}}function pi(){return pe(()=>{wa(),Hn(),te();const t=rs();return ls(),()=>{Da(),t(),cs()}},[]),pe(()=>{const t=I.value.tab;t==="board"&&q(),t==="trpg"&&et()},[I.value.tab]),o`
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
          <${ci} />
          <div class="header-links">
            <a href="/dashboard/lodge">Lodge</a>
            <a href="/dashboard/credits">Credits</a>
          </div>
        </div>
      </header>

      <div class="tab-sticky-wrap">
        <${xa} />
      </div>

      <div class="dashboard-layout">
        <main class="dashboard-main">
          ${ye.value&&!at.value?o`<div class="loading-indicator">Loading dashboard...</div>`:o`<${vi} />`}
        </main>
        <${di} />
      </div>

      <${Hs} />
      <${_s} />
    </div>
  `}const on=document.getElementById("app");on&&oa(o`<${pi} />`,on);
