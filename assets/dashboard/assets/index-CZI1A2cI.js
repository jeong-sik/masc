(function(){const e=document.createElement("link").relList;if(e&&e.supports&&e.supports("modulepreload"))return;for(const s of document.querySelectorAll('link[rel="modulepreload"]'))a(s);new MutationObserver(s=>{for(const i of s)if(i.type==="childList")for(const r of i.addedNodes)r.tagName==="LINK"&&r.rel==="modulepreload"&&a(r)}).observe(document,{childList:!0,subtree:!0});function n(s){const i={};return s.integrity&&(i.integrity=s.integrity),s.referrerPolicy&&(i.referrerPolicy=s.referrerPolicy),s.crossOrigin==="use-credentials"?i.credentials="include":s.crossOrigin==="anonymous"?i.credentials="omit":i.credentials="same-origin",i}function a(s){if(s.ep)return;s.ep=!0;const i=n(s);fetch(s.href,i)}})();var Ut,$,Ve,Xe,I,Se,Qe,Ze,Ye,me,ee,ne,ft={},tn=[],qn=/acit|ex(?:s|g|n|p|$)|rph|grid|ows|mnc|ntw|ine[ch]|zoo|^ord|itera/i,Ht=Array.isArray;function D(t,e){for(var n in e)t[n]=e[n];return t}function ge(t){t&&t.parentNode&&t.parentNode.removeChild(t)}function en(t,e,n){var a,s,i,r={};for(i in e)i=="key"?a=e[i]:i=="ref"?s=e[i]:r[i]=e[i];if(arguments.length>2&&(r.children=arguments.length>3?Ut.call(arguments,2):n),typeof t=="function"&&t.defaultProps!=null)for(i in t.defaultProps)r[i]===void 0&&(r[i]=t.defaultProps[i]);return xt(t,r,a,s,null)}function xt(t,e,n,a,s){var i={type:t,props:e,key:n,ref:a,__k:null,__:null,__b:0,__e:null,__c:null,constructor:void 0,__v:s??++Ve,__i:-1,__u:0};return s==null&&$.vnode!=null&&$.vnode(i),i}function _t(t){return t.children}function et(t,e){this.props=t,this.context=e}function G(t,e){if(e==null)return t.__?G(t.__,t.__i+1):null;for(var n;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null)return n.__e;return typeof t.type=="function"?G(t):null}function nn(t){var e,n;if((t=t.__)!=null&&t.__c!=null){for(t.__e=t.__c.base=null,e=0;e<t.__k.length;e++)if((n=t.__k[e])!=null&&n.__e!=null){t.__e=t.__c.base=n.__e;break}return nn(t)}}function Ce(t){(!t.__d&&(t.__d=!0)&&I.push(t)&&!Tt.__r++||Se!=$.debounceRendering)&&((Se=$.debounceRendering)||Qe)(Tt)}function Tt(){for(var t,e,n,a,s,i,r,c=1;I.length;)I.length>c&&I.sort(Ze),t=I.shift(),c=I.length,t.__d&&(n=void 0,a=void 0,s=(a=(e=t).__v).__e,i=[],r=[],e.__P&&((n=D({},a)).__v=a.__v+1,$.vnode&&$.vnode(n),ye(e.__P,n,a,e.__n,e.__P.namespaceURI,32&a.__u?[s]:null,i,s??G(a),!!(32&a.__u),r),n.__v=a.__v,n.__.__k[n.__i]=n,on(i,n,r),a.__e=a.__=null,n.__e!=s&&nn(n)));Tt.__r=0}function an(t,e,n,a,s,i,r,c,d,u,p){var l,_,v,k,T,w,g,m=a&&a.__k||tn,R=e.length;for(d=Kn(n,e,m,d,R),l=0;l<R;l++)(v=n.__k[l])!=null&&(_=v.__i==-1?ft:m[v.__i]||ft,v.__i=l,w=ye(t,v,_,s,i,r,c,d,u,p),k=v.__e,v.ref&&_.ref!=v.ref&&(_.ref&&be(_.ref,null,v),p.push(v.ref,v.__c||k,v)),T==null&&k!=null&&(T=k),(g=!!(4&v.__u))||_.__k===v.__k?d=sn(v,d,t,g):typeof v.type=="function"&&w!==void 0?d=w:k&&(d=k.nextSibling),v.__u&=-7);return n.__e=T,d}function Kn(t,e,n,a,s){var i,r,c,d,u,p=n.length,l=p,_=0;for(t.__k=new Array(s),i=0;i<s;i++)(r=e[i])!=null&&typeof r!="boolean"&&typeof r!="function"?(typeof r=="string"||typeof r=="number"||typeof r=="bigint"||r.constructor==String?r=t.__k[i]=xt(null,r,null,null,null):Ht(r)?r=t.__k[i]=xt(_t,{children:r},null,null,null):r.constructor===void 0&&r.__b>0?r=t.__k[i]=xt(r.type,r.props,r.key,r.ref?r.ref:null,r.__v):t.__k[i]=r,d=i+_,r.__=t,r.__b=t.__b+1,c=null,(u=r.__i=Wn(r,n,d,l))!=-1&&(l--,(c=n[u])&&(c.__u|=2)),c==null||c.__v==null?(u==-1&&(s>p?_--:s<p&&_++),typeof r.type!="function"&&(r.__u|=4)):u!=d&&(u==d-1?_--:u==d+1?_++:(u>d?_--:_++,r.__u|=4))):t.__k[i]=null;if(l)for(i=0;i<p;i++)(c=n[i])!=null&&(2&c.__u)==0&&(c.__e==a&&(a=G(c)),ln(c,c));return a}function sn(t,e,n,a){var s,i;if(typeof t.type=="function"){for(s=t.__k,i=0;s&&i<s.length;i++)s[i]&&(s[i].__=t,e=sn(s[i],e,n,a));return e}t.__e!=e&&(a&&(e&&t.type&&!e.parentNode&&(e=G(t)),n.insertBefore(t.__e,e||null)),e=t.__e);do e=e&&e.nextSibling;while(e!=null&&e.nodeType==8);return e}function Wn(t,e,n,a){var s,i,r,c=t.key,d=t.type,u=e[n],p=u!=null&&(2&u.__u)==0;if(u===null&&c==null||p&&c==u.key&&d==u.type)return n;if(a>(p?1:0)){for(s=n-1,i=n+1;s>=0||i<e.length;)if((u=e[r=s>=0?s--:i++])!=null&&(2&u.__u)==0&&c==u.key&&d==u.type)return r}return-1}function Te(t,e,n){e[0]=="-"?t.setProperty(e,n??""):t[e]=n==null?"":typeof n!="number"||qn.test(e)?n:n+"px"}function bt(t,e,n,a,s){var i,r;t:if(e=="style")if(typeof n=="string")t.style.cssText=n;else{if(typeof a=="string"&&(t.style.cssText=a=""),a)for(e in a)n&&e in n||Te(t.style,e,"");if(n)for(e in n)a&&n[e]==a[e]||Te(t.style,e,n[e])}else if(e[0]=="o"&&e[1]=="n")i=e!=(e=e.replace(Ye,"$1")),r=e.toLowerCase(),e=r in t||e=="onFocusOut"||e=="onFocusIn"?r.slice(2):e.slice(2),t.l||(t.l={}),t.l[e+i]=n,n?a?n.u=a.u:(n.u=me,t.addEventListener(e,i?ne:ee,i)):t.removeEventListener(e,i?ne:ee,i);else{if(s=="http://www.w3.org/2000/svg")e=e.replace(/xlink(H|:h)/,"h").replace(/sName$/,"s");else if(e!="width"&&e!="height"&&e!="href"&&e!="list"&&e!="form"&&e!="tabIndex"&&e!="download"&&e!="rowSpan"&&e!="colSpan"&&e!="role"&&e!="popover"&&e in t)try{t[e]=n??"";break t}catch{}typeof n=="function"||(n==null||n===!1&&e[4]!="-"?t.removeAttribute(e):t.setAttribute(e,e=="popover"&&n==1?"":n))}}function Pe(t){return function(e){if(this.l){var n=this.l[e.type+t];if(e.t==null)e.t=me++;else if(e.t<n.u)return;return n($.event?$.event(e):e)}}}function ye(t,e,n,a,s,i,r,c,d,u){var p,l,_,v,k,T,w,g,m,R,L,gt,Z,xe,yt,Y,Gt,P=e.type;if(e.constructor!==void 0)return null;128&n.__u&&(d=!!(32&n.__u),i=[c=e.__e=n.__e]),(p=$.__b)&&p(e);t:if(typeof P=="function")try{if(g=e.props,m="prototype"in P&&P.prototype.render,R=(p=P.contextType)&&a[p.__c],L=p?R?R.props.value:p.__:a,n.__c?w=(l=e.__c=n.__c).__=l.__E:(m?e.__c=l=new P(g,L):(e.__c=l=new et(g,L),l.constructor=P,l.render=Jn),R&&R.sub(l),l.state||(l.state={}),l.__n=a,_=l.__d=!0,l.__h=[],l._sb=[]),m&&l.__s==null&&(l.__s=l.state),m&&P.getDerivedStateFromProps!=null&&(l.__s==l.state&&(l.__s=D({},l.__s)),D(l.__s,P.getDerivedStateFromProps(g,l.__s))),v=l.props,k=l.state,l.__v=e,_)m&&P.getDerivedStateFromProps==null&&l.componentWillMount!=null&&l.componentWillMount(),m&&l.componentDidMount!=null&&l.__h.push(l.componentDidMount);else{if(m&&P.getDerivedStateFromProps==null&&g!==v&&l.componentWillReceiveProps!=null&&l.componentWillReceiveProps(g,L),e.__v==n.__v||!l.__e&&l.shouldComponentUpdate!=null&&l.shouldComponentUpdate(g,l.__s,L)===!1){for(e.__v!=n.__v&&(l.props=g,l.state=l.__s,l.__d=!1),e.__e=n.__e,e.__k=n.__k,e.__k.some(function(z){z&&(z.__=e)}),gt=0;gt<l._sb.length;gt++)l.__h.push(l._sb[gt]);l._sb=[],l.__h.length&&r.push(l);break t}l.componentWillUpdate!=null&&l.componentWillUpdate(g,l.__s,L),m&&l.componentDidUpdate!=null&&l.__h.push(function(){l.componentDidUpdate(v,k,T)})}if(l.context=L,l.props=g,l.__P=t,l.__e=!1,Z=$.__r,xe=0,m){for(l.state=l.__s,l.__d=!1,Z&&Z(e),p=l.render(l.props,l.state,l.context),yt=0;yt<l._sb.length;yt++)l.__h.push(l._sb[yt]);l._sb=[]}else do l.__d=!1,Z&&Z(e),p=l.render(l.props,l.state,l.context),l.state=l.__s;while(l.__d&&++xe<25);l.state=l.__s,l.getChildContext!=null&&(a=D(D({},a),l.getChildContext())),m&&!_&&l.getSnapshotBeforeUpdate!=null&&(T=l.getSnapshotBeforeUpdate(v,k)),Y=p,p!=null&&p.type===_t&&p.key==null&&(Y=rn(p.props.children)),c=an(t,Ht(Y)?Y:[Y],e,n,a,s,i,r,c,d,u),l.base=e.__e,e.__u&=-161,l.__h.length&&r.push(l),w&&(l.__E=l.__=null)}catch(z){if(e.__v=null,d||i!=null)if(z.then){for(e.__u|=d?160:128;c&&c.nodeType==8&&c.nextSibling;)c=c.nextSibling;i[i.indexOf(c)]=null,e.__e=c}else{for(Gt=i.length;Gt--;)ge(i[Gt]);ae(e)}else e.__e=n.__e,e.__k=n.__k,z.then||ae(e);$.__e(z,e,n)}else i==null&&e.__v==n.__v?(e.__k=n.__k,e.__e=n.__e):c=e.__e=Gn(n.__e,e,n,a,s,i,r,d,u);return(p=$.diffed)&&p(e),128&e.__u?void 0:c}function ae(t){t&&t.__c&&(t.__c.__e=!0),t&&t.__k&&t.__k.forEach(ae)}function on(t,e,n){for(var a=0;a<n.length;a++)be(n[a],n[++a],n[++a]);$.__c&&$.__c(e,t),t.some(function(s){try{t=s.__h,s.__h=[],t.some(function(i){i.call(s)})}catch(i){$.__e(i,s.__v)}})}function rn(t){return typeof t!="object"||t==null||t.__b&&t.__b>0?t:Ht(t)?t.map(rn):D({},t)}function Gn(t,e,n,a,s,i,r,c,d){var u,p,l,_,v,k,T,w=n.props||ft,g=e.props,m=e.type;if(m=="svg"?s="http://www.w3.org/2000/svg":m=="math"?s="http://www.w3.org/1998/Math/MathML":s||(s="http://www.w3.org/1999/xhtml"),i!=null){for(u=0;u<i.length;u++)if((v=i[u])&&"setAttribute"in v==!!m&&(m?v.localName==m:v.nodeType==3)){t=v,i[u]=null;break}}if(t==null){if(m==null)return document.createTextNode(g);t=document.createElementNS(s,m,g.is&&g),c&&($.__m&&$.__m(e,i),c=!1),i=null}if(m==null)w===g||c&&t.data==g||(t.data=g);else{if(i=i&&Ut.call(t.childNodes),!c&&i!=null)for(w={},u=0;u<t.attributes.length;u++)w[(v=t.attributes[u]).name]=v.value;for(u in w)if(v=w[u],u!="children"){if(u=="dangerouslySetInnerHTML")l=v;else if(!(u in g)){if(u=="value"&&"defaultValue"in g||u=="checked"&&"defaultChecked"in g)continue;bt(t,u,null,v,s)}}for(u in g)v=g[u],u=="children"?_=v:u=="dangerouslySetInnerHTML"?p=v:u=="value"?k=v:u=="checked"?T=v:c&&typeof v!="function"||w[u]===v||bt(t,u,v,w[u],s);if(p)c||l&&(p.__html==l.__html||p.__html==t.innerHTML)||(t.innerHTML=p.__html),e.__k=[];else if(l&&(t.innerHTML=""),an(e.type=="template"?t.content:t,Ht(_)?_:[_],e,n,a,m=="foreignObject"?"http://www.w3.org/1999/xhtml":s,i,r,i?i[0]:n.__k&&G(n,0),c,d),i!=null)for(u=i.length;u--;)ge(i[u]);c||(u="value",m=="progress"&&k==null?t.removeAttribute("value"):k!=null&&(k!==t[u]||m=="progress"&&!k||m=="option"&&k!=w[u])&&bt(t,u,k,w[u],s),u="checked",T!=null&&T!=t[u]&&bt(t,u,T,w[u],s))}return t}function be(t,e,n){try{if(typeof t=="function"){var a=typeof t.__u=="function";a&&t.__u(),a&&e==null||(t.__u=t(e))}else t.current=e}catch(s){$.__e(s,n)}}function ln(t,e,n){var a,s;if($.unmount&&$.unmount(t),(a=t.ref)&&(a.current&&a.current!=t.__e||be(a,null,e)),(a=t.__c)!=null){if(a.componentWillUnmount)try{a.componentWillUnmount()}catch(i){$.__e(i,e)}a.base=a.__P=null}if(a=t.__k)for(s=0;s<a.length;s++)a[s]&&ln(a[s],e,n||typeof t.type!="function");n||ge(t.__e),t.__c=t.__=t.__e=void 0}function Jn(t,e,n){return this.constructor(t,n)}function Vn(t,e,n){var a,s,i,r;e==document&&(e=document.documentElement),$.__&&$.__(t,e),s=(a=!1)?null:e.__k,i=[],r=[],ye(e,t=e.__k=en(_t,null,[t]),s||ft,ft,e.namespaceURI,s?null:e.firstChild?Ut.call(e.childNodes):null,i,s?s.__e:e.firstChild,a,r),on(i,t,r)}Ut=tn.slice,$={__e:function(t,e,n,a){for(var s,i,r;e=e.__;)if((s=e.__c)&&!s.__)try{if((i=s.constructor)&&i.getDerivedStateFromError!=null&&(s.setState(i.getDerivedStateFromError(t)),r=s.__d),s.componentDidCatch!=null&&(s.componentDidCatch(t,a||{}),r=s.__d),r)return s.__E=s}catch(c){t=c}throw t}},Ve=0,Xe=function(t){return t!=null&&t.constructor===void 0},et.prototype.setState=function(t,e){var n;n=this.__s!=null&&this.__s!=this.state?this.__s:this.__s=D({},this.state),typeof t=="function"&&(t=t(D({},n),this.props)),t&&D(n,t),t!=null&&this.__v&&(e&&this._sb.push(e),Ce(this))},et.prototype.forceUpdate=function(t){this.__v&&(this.__e=!0,t&&this.__h.push(t),Ce(this))},et.prototype.render=_t,I=[],Qe=typeof Promise=="function"?Promise.prototype.then.bind(Promise.resolve()):setTimeout,Ze=function(t,e){return t.__v.__b-e.__v.__b},Tt.__r=0,Ye=/(PointerCapture)$|Capture$/i,me=0,ee=Pe(!1),ne=Pe(!0);var cn=function(t,e,n,a){var s;e[0]=0;for(var i=1;i<e.length;i++){var r=e[i++],c=e[i]?(e[0]|=r?1:2,n[e[i++]]):e[++i];r===3?a[0]=c:r===4?a[1]=Object.assign(a[1]||{},c):r===5?(a[1]=a[1]||{})[e[++i]]=c:r===6?a[1][e[++i]]+=c+"":r?(s=t.apply(c,cn(t,c,n,["",null])),a.push(s),c[0]?e[0]|=2:(e[i-2]=0,e[i]=s)):a.push(c)}return a},Ae=new Map;function Xn(t){var e=Ae.get(this);return e||(e=new Map,Ae.set(this,e)),(e=cn(this,e.get(t)||(e.set(t,e=(function(n){for(var a,s,i=1,r="",c="",d=[0],u=function(_){i===1&&(_||(r=r.replace(/^\s*\n\s*|\s*\n\s*$/g,"")))?d.push(0,_,r):i===3&&(_||r)?(d.push(3,_,r),i=2):i===2&&r==="..."&&_?d.push(4,_,0):i===2&&r&&!_?d.push(5,0,!0,r):i>=5&&((r||!_&&i===5)&&(d.push(i,0,r,s),i=6),_&&(d.push(i,_,0,s),i=6)),r=""},p=0;p<n.length;p++){p&&(i===1&&u(),u(p));for(var l=0;l<n[p].length;l++)a=n[p][l],i===1?a==="<"?(u(),d=[d],i=3):r+=a:i===4?r==="--"&&a===">"?(i=1,r=""):r=a+r[0]:c?a===c?c="":r+=a:a==='"'||a==="'"?c=a:a===">"?(u(),i=1):i&&(a==="="?(i=5,s=r,r=""):a==="/"&&(i<5||n[p][l+1]===">")?(u(),i===3&&(d=d[0]),i=d,(d=d[0]).push(2,0,i),i=0):a===" "||a==="	"||a===`
`||a==="\r"?(u(),i=2):r+=a),i===3&&r==="!--"&&(i=4,d=d[0])}return u(),d})(t)),e),arguments,[])).length>1?e:e[0]}var o=Xn.bind(en),Pt,C,Jt,Ne,De=0,un=[],b=$,Re=b.__b,Ee=b.__r,Le=b.diffed,Me=b.__c,Ie=b.unmount,Oe=b.__;function dn(t,e){b.__h&&b.__h(C,t,De||e),De=0;var n=C.__H||(C.__H={__:[],__h:[]});return t>=n.__.length&&n.__.push({}),n.__[t]}function se(t,e){var n=dn(Pt++,3);!b.__s&&pn(n.__H,e)&&(n.__=t,n.u=e,C.__H.__h.push(n))}function vn(t,e){var n=dn(Pt++,7);return pn(n.__H,e)&&(n.__=t(),n.__H=e,n.__h=t),n.__}function Qn(){for(var t;t=un.shift();)if(t.__P&&t.__H)try{t.__H.__h.forEach(St),t.__H.__h.forEach(ie),t.__H.__h=[]}catch(e){t.__H.__h=[],b.__e(e,t.__v)}}b.__b=function(t){C=null,Re&&Re(t)},b.__=function(t,e){t&&e.__k&&e.__k.__m&&(t.__m=e.__k.__m),Oe&&Oe(t,e)},b.__r=function(t){Ee&&Ee(t),Pt=0;var e=(C=t.__c).__H;e&&(Jt===C?(e.__h=[],C.__h=[],e.__.forEach(function(n){n.__N&&(n.__=n.__N),n.u=n.__N=void 0})):(e.__h.forEach(St),e.__h.forEach(ie),e.__h=[],Pt=0)),Jt=C},b.diffed=function(t){Le&&Le(t);var e=t.__c;e&&e.__H&&(e.__H.__h.length&&(un.push(e)!==1&&Ne===b.requestAnimationFrame||((Ne=b.requestAnimationFrame)||Zn)(Qn)),e.__H.__.forEach(function(n){n.u&&(n.__H=n.u),n.u=void 0})),Jt=C=null},b.__c=function(t,e){e.some(function(n){try{n.__h.forEach(St),n.__h=n.__h.filter(function(a){return!a.__||ie(a)})}catch(a){e.some(function(s){s.__h&&(s.__h=[])}),e=[],b.__e(a,n.__v)}}),Me&&Me(t,e)},b.unmount=function(t){Ie&&Ie(t);var e,n=t.__c;n&&n.__H&&(n.__H.__.forEach(function(a){try{St(a)}catch(s){e=s}}),n.__H=void 0,e&&b.__e(e,n.__v))};var je=typeof requestAnimationFrame=="function";function Zn(t){var e,n=function(){clearTimeout(a),je&&cancelAnimationFrame(e),setTimeout(t)},a=setTimeout(n,35);je&&(e=requestAnimationFrame(n))}function St(t){var e=C,n=t.__c;typeof n=="function"&&(t.__c=void 0,n()),C=e}function ie(t){var e=C;t.__c=t.__(),C=e}function pn(t,e){return!t||t.length!==e.length||e.some(function(n,a){return n!==t[a]})}var Yn=Symbol.for("preact-signals");function Bt(){if(E>1)E--;else{for(var t,e=!1;nt!==void 0;){var n=nt;for(nt=void 0,oe++;n!==void 0;){var a=n.o;if(n.o=void 0,n.f&=-3,!(8&n.f)&&hn(n))try{n.c()}catch(s){e||(t=s,e=!0)}n=a}}if(oe=0,E--,e)throw t}}function ta(t){if(E>0)return t();E++;try{return t()}finally{Bt()}}var h=void 0;function fn(t){var e=h;h=void 0;try{return t()}finally{h=e}}var nt=void 0,E=0,oe=0,At=0;function _n(t){if(h!==void 0){var e=t.n;if(e===void 0||e.t!==h)return e={i:0,S:t,p:h.s,n:void 0,t:h,e:void 0,x:void 0,r:e},h.s!==void 0&&(h.s.n=e),h.s=e,t.n=e,32&h.f&&t.S(e),e;if(e.i===-1)return e.i=0,e.n!==void 0&&(e.n.p=e.p,e.p!==void 0&&(e.p.n=e.n),e.p=h.s,e.n=void 0,h.s.n=e,h.s=e),e}}function x(t,e){this.v=t,this.i=0,this.n=void 0,this.t=void 0,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}x.prototype.brand=Yn;x.prototype.h=function(){return!0};x.prototype.S=function(t){var e=this,n=this.t;n!==t&&t.e===void 0&&(t.x=n,this.t=t,n!==void 0?n.e=t:fn(function(){var a;(a=e.W)==null||a.call(e)}))};x.prototype.U=function(t){var e=this;if(this.t!==void 0){var n=t.e,a=t.x;n!==void 0&&(n.x=a,t.e=void 0),a!==void 0&&(a.e=n,t.x=void 0),t===this.t&&(this.t=a,a===void 0&&fn(function(){var s;(s=e.Z)==null||s.call(e)}))}};x.prototype.subscribe=function(t){var e=this;return ht(function(){var n=e.value,a=h;h=void 0;try{t(n)}finally{h=a}},{name:"sub"})};x.prototype.valueOf=function(){return this.value};x.prototype.toString=function(){return this.value+""};x.prototype.toJSON=function(){return this.value};x.prototype.peek=function(){var t=h;h=void 0;try{return this.value}finally{h=t}};Object.defineProperty(x.prototype,"value",{get:function(){var t=_n(this);return t!==void 0&&(t.i=this.i),this.v},set:function(t){if(t!==this.v){if(oe>100)throw new Error("Cycle detected");this.v=t,this.i++,At++,E++;try{for(var e=this.t;e!==void 0;e=e.x)e.t.N()}finally{Bt()}}}});function f(t,e){return new x(t,e)}function hn(t){for(var e=t.s;e!==void 0;e=e.n)if(e.S.i!==e.i||!e.S.h()||e.S.i!==e.i)return!0;return!1}function $n(t){for(var e=t.s;e!==void 0;e=e.n){var n=e.S.n;if(n!==void 0&&(e.r=n),e.S.n=e,e.i=-1,e.n===void 0){t.s=e;break}}}function mn(t){for(var e=t.s,n=void 0;e!==void 0;){var a=e.p;e.i===-1?(e.S.U(e),a!==void 0&&(a.n=e.n),e.n!==void 0&&(e.n.p=a)):n=e,e.S.n=e.r,e.r!==void 0&&(e.r=void 0),e=a}t.s=n}function j(t,e){x.call(this,void 0),this.x=t,this.s=void 0,this.g=At-1,this.f=4,this.W=e==null?void 0:e.watched,this.Z=e==null?void 0:e.unwatched,this.name=e==null?void 0:e.name}j.prototype=new x;j.prototype.h=function(){if(this.f&=-3,1&this.f)return!1;if((36&this.f)==32||(this.f&=-5,this.g===At))return!0;if(this.g=At,this.f|=1,this.i>0&&!hn(this))return this.f&=-2,!0;var t=h;try{$n(this),h=this;var e=this.x();(16&this.f||this.v!==e||this.i===0)&&(this.v=e,this.f&=-17,this.i++)}catch(n){this.v=n,this.f|=16,this.i++}return h=t,mn(this),this.f&=-2,!0};j.prototype.S=function(t){if(this.t===void 0){this.f|=36;for(var e=this.s;e!==void 0;e=e.n)e.S.S(e)}x.prototype.S.call(this,t)};j.prototype.U=function(t){if(this.t!==void 0&&(x.prototype.U.call(this,t),this.t===void 0)){this.f&=-33;for(var e=this.s;e!==void 0;e=e.n)e.S.U(e)}};j.prototype.N=function(){if(!(2&this.f)){this.f|=6;for(var t=this.t;t!==void 0;t=t.x)t.t.N()}};Object.defineProperty(j.prototype,"value",{get:function(){if(1&this.f)throw new Error("Cycle detected");var t=_n(this);if(this.h(),t!==void 0&&(t.i=this.i),16&this.f)throw this.v;return this.v}});function Nt(t,e){return new j(t,e)}function gn(t){var e=t.u;if(t.u=void 0,typeof e=="function"){E++;var n=h;h=void 0;try{e()}catch(a){throw t.f&=-2,t.f|=8,ke(t),a}finally{h=n,Bt()}}}function ke(t){for(var e=t.s;e!==void 0;e=e.n)e.S.U(e);t.x=void 0,t.s=void 0,gn(t)}function ea(t){if(h!==this)throw new Error("Out-of-order effect");mn(this),h=t,this.f&=-2,8&this.f&&ke(this),Bt()}function V(t,e){this.x=t,this.u=void 0,this.s=void 0,this.o=void 0,this.f=32,this.name=e==null?void 0:e.name}V.prototype.c=function(){var t=this.S();try{if(8&this.f||this.x===void 0)return;var e=this.x();typeof e=="function"&&(this.u=e)}finally{t()}};V.prototype.S=function(){if(1&this.f)throw new Error("Cycle detected");this.f|=1,this.f&=-9,gn(this),$n(this),E++;var t=h;return h=this,ea.bind(this,t)};V.prototype.N=function(){2&this.f||(this.f|=2,this.o=nt,nt=this)};V.prototype.d=function(){this.f|=8,1&this.f||ke(this)};V.prototype.dispose=function(){this.d()};function ht(t,e){var n=new V(t,e);try{n.c()}catch(s){throw n.d(),s}var a=n.d.bind(n);return a[Symbol.dispose]=a,a}var yn,kt,na=typeof window<"u"&&!!window.__PREACT_SIGNALS_DEVTOOLS__,bn=[];ht(function(){yn=this.N})();function X(t,e){$[t]=e.bind(null,$[t]||function(){})}function Dt(t){if(kt){var e=kt;kt=void 0,e()}kt=t&&t.S()}function kn(t){var e=this,n=t.data,a=sa(n);a.value=n;var s=vn(function(){for(var c=e,d=e.__v;d=d.__;)if(d.__c){d.__c.__$f|=4;break}var u=Nt(function(){var v=a.value.value;return v===0?0:v===!0?"":v||""}),p=Nt(function(){return!Array.isArray(u.value)&&!Xe(u.value)}),l=ht(function(){if(this.N=wn,p.value){var v=u.value;c.__v&&c.__v.__e&&c.__v.__e.nodeType===3&&(c.__v.__e.data=v)}}),_=e.__$u.d;return e.__$u.d=function(){l(),_.call(this)},[p,u]},[]),i=s[0],r=s[1];return i.value?r.peek():r.value}kn.displayName="ReactiveTextNode";Object.defineProperties(x.prototype,{constructor:{configurable:!0,value:void 0},type:{configurable:!0,value:kn},props:{configurable:!0,get:function(){return{data:this}}},__b:{configurable:!0,value:1}});X("__b",function(t,e){if(typeof e.type=="string"){var n,a=e.props;for(var s in a)if(s!=="children"){var i=a[s];i instanceof x&&(n||(e.__np=n={}),n[s]=i,a[s]=i.peek())}}t(e)});X("__r",function(t,e){if(t(e),e.type!==_t){Dt();var n,a=e.__c;a&&(a.__$f&=-2,(n=a.__$u)===void 0&&(a.__$u=n=(function(s,i){var r;return ht(function(){r=this},{name:i}),r.c=s,r})(function(){var s;na&&((s=n.y)==null||s.call(n)),a.__$f|=1,a.setState({})},typeof e.type=="function"?e.type.displayName||e.type.name:""))),Dt(n)}});X("__e",function(t,e,n,a){Dt(),t(e,n,a)});X("diffed",function(t,e){Dt();var n;if(typeof e.type=="string"&&(n=e.__e)){var a=e.__np,s=e.props;if(a){var i=n.U;if(i)for(var r in i){var c=i[r];c!==void 0&&!(r in a)&&(c.d(),i[r]=void 0)}else i={},n.U=i;for(var d in a){var u=i[d],p=a[d];u===void 0?(u=aa(n,d,p),i[d]=u):u.o(p,s)}for(var l in a)s[l]=a[l]}}t(e)});function aa(t,e,n,a){var s=e in t&&t.ownerSVGElement===void 0,i=f(n),r=n.peek();return{o:function(c,d){i.value=c,r=c.peek()},d:ht(function(){this.N=wn;var c=i.value.value;r!==c?(r=void 0,s?t[e]=c:c!=null&&(c!==!1||e[4]==="-")?t.setAttribute(e,c):t.removeAttribute(e)):r=void 0})}}X("unmount",function(t,e){if(typeof e.type=="string"){var n=e.__e;if(n){var a=n.U;if(a){n.U=void 0;for(var s in a){var i=a[s];i&&i.d()}}}e.__np=void 0}else{var r=e.__c;if(r){var c=r.__$u;c&&(r.__$u=void 0,c.d())}}t(e)});X("__h",function(t,e,n,a){(a<3||a===9)&&(e.__$f|=2),t(e,n,a)});et.prototype.shouldComponentUpdate=function(t,e){if(this.__R)return!0;var n=this.__$u,a=n&&n.s!==void 0;for(var s in e)return!0;if(this.__f||typeof this.u=="boolean"&&this.u===!0){var i=2&this.__$f;if(!(a||i||4&this.__$f)||1&this.__$f)return!0}else if(!(a||4&this.__$f)||3&this.__$f)return!0;for(var r in t)if(r!=="__source"&&t[r]!==this.props[r])return!0;for(var c in this.props)if(!(c in t))return!0;return!1};function sa(t,e){return vn(function(){return f(t,e)},[])}var ia=function(t){queueMicrotask(function(){queueMicrotask(t)})};function oa(){ta(function(){for(var t;t=bn.shift();)yn.call(t)})}function wn(){bn.push(this)===1&&($.requestAnimationFrame||ia)(oa)}const ra=["overview","board","activity","agents","tasks","journal","trpg","council"],xn={tab:"overview",params:{},postId:null};function Ue(t){return!!t&&ra.includes(t)}function re(t){try{return decodeURIComponent(t)}catch{return t}}function le(t){const e={};return t&&new URLSearchParams(t).forEach((a,s)=>{e[s]=a}),e}function la(t){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);return n[0]==="dashboard"?n.slice(1):n}function Sn(t,e){const n=t[0],a=e.tab,s=Ue(n)?n:Ue(a)?a:"overview";let i=null;return s==="board"&&(t[0]==="board"&&t[1]==="post"&&t[2]?i=re(t[2]):t[0]==="post"&&t[1]&&(i=re(t[1]))),{tab:s,params:e,postId:i}}function Rt(t){const e=(t||"").replace(/^#/,"").trim();if(!e)return xn;const n=re(e);let a=n,s;if(n.startsWith("?"))a="",s=n.slice(1);else{const c=n.indexOf("?");c>=0&&(a=n.slice(0,c),s=n.slice(c+1))}!s&&a.includes("=")&&!a.includes("/")&&(s=a,a="");const i=le(s),r=la(a);return Sn(r,i)}function ca(t,e){const n=t.replace(/^\/+/,"").split("/").filter(Boolean);if(n[0]!=="dashboard")return null;const a=n.slice(1);if(a.length===0)return{...xn,params:le(e.replace(/^\?/,""))};if(a[0]==="assets"||a[0]==="credits"||a[0]==="lodge")return null;const s=le(e.replace(/^\?/,""));return Sn(a,s)}function Cn(t){const e=t.postId?`board/post/${encodeURIComponent(t.postId)}`:t.tab,n=Object.entries(t.params).filter(([s])=>s!=="tab");if(n.length===0)return`#${e}`;const a=new URLSearchParams(n);return`#${e}?${a.toString()}`}const N=f(Rt(window.location.hash));window.addEventListener("hashchange",()=>{N.value=Rt(window.location.hash)});function zt(t,e){const n={tab:t,params:{},postId:null};window.location.hash=Cn(n)}function ua(t){window.location.hash=`#board/post/${encodeURIComponent(t)}`}function da(){if(window.location.hash&&window.location.hash!=="#"){N.value=Rt(window.location.hash);return}const t=ca(window.location.pathname,window.location.search);if(t){N.value=t;const e=Cn(t);window.history.replaceState(null,"",`${window.location.pathname}${window.location.search}${e}`);return}window.location.hash="#overview",N.value=Rt(window.location.hash)}const va=[{id:"overview",label:"Overview",icon:"🏠"},{id:"council",label:"Council",icon:"🏛️"},{id:"board",label:"Board",icon:"💬"},{id:"activity",label:"Activity",icon:"📊"},{id:"agents",label:"Agents",icon:"🤖"},{id:"tasks",label:"Tasks",icon:"📋"},{id:"journal",label:"Journal",icon:"📓"},{id:"trpg",label:"TRPG",icon:"⚔️"}];function pa(){const t=N.value.tab;return o`
    <div class="main-tab-bar">
      ${va.map(e=>o`
        <button
          class="main-tab-btn ${t===e.id?"active":""}"
          onClick=${()=>zt(e.id)}
        >
          ${e.icon} ${e.label}
        </button>
      `)}
    </div>
  `}const He="masc_dashboard_sse_session_id",fa=1e3,_a=15e3,J=f(!1),Et=f(0),Tn=f(null),ce=f([]);function ha(){let t=sessionStorage.getItem(He);return t||(t=typeof crypto.randomUUID=="function"?`dash_${crypto.randomUUID()}`:`dash_${Date.now().toString(36)}_${Math.random().toString(36).slice(2,10)}`,sessionStorage.setItem(He,t)),t}const $a=200;function M(t,e){const n={agent:t,text:e,timestamp:Date.now()};ce.value=[n,...ce.value].slice(0,$a)}let A=null,K=null,ue=0;function Pn(){K&&(clearTimeout(K),K=null)}function ma(){if(K)return;ue++;const t=Math.min(ue,5),e=Math.min(_a,fa*Math.pow(2,t));K=setTimeout(()=>{K=null,An()},e)}function An(){Pn(),A&&(A.close(),A=null);const t=new URLSearchParams(window.location.search),e=new URLSearchParams,n=t.get("agent")??t.get("agent_name"),a=t.get("token");n&&e.set("agent",n),a&&e.set("token",a),e.set("session_id",ha());const s=e.toString()?`/sse?${e.toString()}`:"/sse",i=new EventSource(s);A=i,i.onopen=()=>{A===i&&(ue=0,J.value=!0)},i.onerror=()=>{A===i&&(J.value=!1,i.close(),A=null,ma())},i.onmessage=r=>{try{const c=JSON.parse(r.data);Et.value++,Tn.value=c,ga(c)}catch{}}}function ga(t){const e=t.type,n=t.agent??t.from??t.from_agent??"";switch(e){case"agent_joined":M(n,"Joined");break;case"agent_left":M(n,"Left");break;case"broadcast":M(n,`${(t.message??t.content??"").slice(0,80)}`);break;case"task_update":M(n,`Task: ${t.task_id??""} -> ${t.status??""}`);break;case"board_post":M(n,"New post");break;case"board_comment":M(n,"New comment");break;default:M(n,e)}}function ya(){Pn(),A&&(A.close(),A=null),J.value=!1}function ba(){return new URLSearchParams(window.location.search)}function Nn(){const t=ba(),e={},n=t.get("token"),a=t.get("agent")??t.get("agent_name");return n&&(e.Authorization=`Bearer ${n}`),a&&(e["X-MASC-Agent"]=a),e}function Dn(){return{...Nn(),"Content-Type":"application/json"}}async function Ft(t){const e=await fetch(t,{headers:Nn()});if(!e.ok)throw new Error(`GET ${t}: ${e.status} ${e.statusText}`);return e.json()}async function $t(t,e){const n=await fetch(t,{method:"POST",headers:Dn(),body:JSON.stringify(e)});if(!n.ok)throw new Error(`POST ${t}: ${n.status} ${n.statusText}`);return n.json()}async function ka(t,e,n){const a=await fetch(t,{method:"POST",headers:{...Dn(),...n??{}},body:JSON.stringify(e)});if(!a.ok)throw new Error(`POST ${t}: ${a.status} ${a.statusText}`);return a.text()}function wa(t){const e=t.split(`
`).find(a=>a.startsWith("data: ")),n=e?e.slice(6).trim():t.trim();return JSON.parse(n)}function xa(t){var e,n,a,s,i,r,c;if((e=t.error)!=null&&e.message)throw new Error(t.error.message);if((n=t.result)!=null&&n.isError){const d=((s=(a=t.result.content)==null?void 0:a[0])==null?void 0:s.text)??"MCP tool call failed";throw new Error(d)}return((c=(r=(i=t.result)==null?void 0:i.content)==null?void 0:r[0])==null?void 0:c.text)??""}async function Q(t,e){const n=await ka("/mcp",{jsonrpc:"2.0",method:"tools/call",params:{name:t,arguments:e},id:Math.floor(Date.now()%1e6)},{Accept:"application/json, text/event-stream"}),a=wa(n);return xa(a)}function Rn(t){const e=t.trim();if(!e)return[];const n=JSON.parse(e);return Array.isArray(n)?n:[]}function Sa(){return Ft("/api/v1/dashboard")}function Ca(){return Ft("/api/v1/board")}function Ta(t){return Ft(`/api/v1/board/${t}`)}function En(t,e){return $t(`/api/v1/board/${t}/vote`,{direction:e})}function Pa(t,e,n){return $t("/api/v1/tools/masc_board_comment",{post_id:t,author:e,content:n})}function Aa(t){const e=t?`?room=${encodeURIComponent(t)}`:"";return Ft(`/api/v1/trpg/state${e}`)}function Na(t){return $t("/api/v1/trpg/rounds/run",{room:t})}function Da(t,e){return $t("/api/v1/trpg/dice/roll",{room:t,notation:e})}function Ra(t){return $t("/api/v1/trpg/turns/advance",{room:t})}async function Ea(t,e){await Q("masc_broadcast",{agent_name:t,message:e})}async function La(t,e,n=1){await Q("masc_add_task",{title:t,description:e,priority:n})}async function Ma(){const t=await Q("masc_debates",{});return Rn(t)}async function Ia(){const t=await Q("masc_sessions",{});return Rn(t)}async function Oa(t){const e=await Q("masc_debate_start",{topic:t});try{return JSON.parse(e)}catch{return null}}function ja(t){return Q("masc_debate_status",{debate_id:t})}const mt=f([]),qt=f([]),Ln=f([]),Kt=f([]),Mn=f(null),tt=f(null),In=f([]),Be=f("hot"),On=f(null),jn=f(""),de=f(!1),ve=f(!1),pe=f(!1),Ua=Nt(()=>mt.value.filter(t=>t.status==="active"||t.status==="idle")),Un=Nt(()=>{const t=qt.value;return{todo:t.filter(e=>e.status==="todo"),inProgress:t.filter(e=>e.status==="in_progress"||e.status==="claimed"),done:t.filter(e=>e.status==="done")}});let Ct=null;const Ha=5e3;function Hn(){Ct=null}function Ba(t){return Array.isArray(t)?t:t&&Array.isArray(t.keepers)?t.keepers:[]}async function Wt(){var e,n,a;const t=Date.now();if(!(Ct&&t-Ct.time<Ha)){de.value=!0;try{const s=await Sa();Ct={data:s,time:t},mt.value=((e=s.agents)==null?void 0:e.agents)??[],qt.value=((n=s.tasks)==null?void 0:n.tasks)??[],Ln.value=((a=s.messages)==null?void 0:a.messages)??[],Kt.value=Ba(s.keepers),Mn.value=s.status??null,tt.value=s.perpetual??null}catch(s){console.error("Dashboard fetch error:",s)}finally{de.value=!1}}}async function U(){ve.value=!0;try{const t=await Ca();In.value=t.posts??[]}catch(t){console.error("Board fetch error:",t)}finally{ve.value=!1}}async function W(){pe.value=!0;try{const t=jn.value||void 0,e=await Aa(t);On.value=e}catch(t){console.error("TRPG fetch error:",t)}finally{pe.value=!1}}let Vt=null,Xt=null;function za(){return Tn.subscribe(e=>{e&&(Hn(),Vt||(Vt=setTimeout(()=>{Wt(),Vt=null},500)),(e.type==="board_post"||e.type==="board_comment")&&(Xt||(Xt=setTimeout(()=>{U(),Xt=null},500))))})}let at=null;function Fa(){at||(at=setInterval(()=>{Hn(),Wt()},1e4))}function qa(){at&&(clearInterval(at),at=null)}function y({title:t,class:e,children:n}){return o`
    <div class="card ${e??""}">
      ${t?o`<div class="card-title">${t}</div>`:null}
      ${n}
    </div>
  `}function H({status:t,label:e}){return o`
    <span class="status-badge ${t}">
      <span class="status-dot-inline ${t}"></span>
      ${e??t}
    </span>
  `}function F({label:t,value:e,color:n}){return o`
    <div class="stat-card">
      <div class="stat-label">${t}</div>
      <div class="stat-value" style=${n?`color: ${n}`:""}>${e}</div>
    </div>
  `}function Ka({agent:t}){return o`
    <div class="agent">
      <span class="agent-emoji">${t.emoji??""}</span>
      <span class="agent-status ${t.status}"></span>
      <span class="agent-name">${t.name}</span>
      <${H} status=${t.status} />
      ${t.current_task?o`<span class="agent-task">${t.current_task}</span>`:null}
    </div>
  `}function Wa({keeper:t}){return o`
    <div class="live-agent keeper-card">
      <div class="live-agent-main">
        <div class="live-agent-title">
          <span class="live-agent-name">${t.emoji??""} ${t.name}</span>
          <${H} status=${t.status} />
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
  `}function ze(){const t=Mn.value,e=mt.value,n=Kt.value,a=Un.value;return o`
    <div class="stats-grid">
      <${F} label="Agents" value=${e.length} />
      <${F} label="Active" value=${Ua.value.length} color="#4ade80" />
      <${F} label="Keepers" value=${n.length} color="#22d3ee" />
      <${F} label="Tasks" value=${qt.value.length} />
      <${F} label="In Progress" value=${a.inProgress.length} color="#fbbf24" />
      <${F} label="Done" value=${a.done.length} color="#4ade80" />
    </div>

    <div class="grid-2col">
      <${y} title="Agents" class="section">
        <div class="agent-list">
          ${e.length===0?o`<div class="empty-state">No agents connected</div>`:e.map(s=>o`<${Ka} key=${s.name} agent=${s} />`)}
        </div>
      <//>

      <${y} title="Keepers" class="section">
        <div class="live-agent-list">
          ${n.length===0?o`<div class="empty-state">No keepers active</div>`:n.map(s=>o`<${Wa} key=${s.name} keeper=${s} />`)}
        </div>
      <//>
    </div>

    ${tt.value?o`
        <${y} title="Perpetual Runtime" class="section">
          <div class="live-agent-meta">
            <span>Status: ${tt.value.running?"Running":"Stopped"}</span>
            ${tt.value.goal?o`<span>Goal: ${tt.value.goal}</span>`:null}
          </div>
        <//>
      `:null}

    ${t!=null&&t.room?o`
        <${y} title="Room" class="section">
          <div class="live-agent-meta">
            <span>Room: ${t.room}</span>
            <span>Uptime: ${Ga(t.uptime_seconds)}</span>
          </div>
        <//>
      `:null}
  `}function Ga(t){if(!t)return"N/A";const e=Math.floor(t/3600),n=Math.floor(t%3600/60);return e>0?`${e}h ${n}m`:`${n}m`}let Ja=0;const O=f([]);function S(t,e="success",n=4e3){const a=++Ja;O.value=[...O.value,{id:a,message:t,type:e}],setTimeout(()=>{O.value=O.value.filter(s=>s.id!==a)},n)}function Va(t){O.value=O.value.filter(e=>e.id!==t)}function Xa(){const t=O.value;return t.length===0?null:o`
    <div class="toast-container">
      ${t.map(e=>o`
        <div key=${e.id} class="toast ${e.type}" onClick=${()=>Va(e.id)}>
          ${e.message}
        </div>
      `)}
    </div>
  `}const fe=f([]),_e=f([]),st=f(""),Lt=f(!1),it=f(!1),Mt=f(""),It=f(null),ot=f(""),he=f(!1);async function $e(){Lt.value=!0,Mt.value="";try{const[t,e]=await Promise.all([Ma(),Ia()]);fe.value=t,_e.value=e}catch(t){Mt.value=t instanceof Error?t.message:"Failed to load council data"}finally{Lt.value=!1}}async function Fe(){const t=st.value.trim();if(t){it.value=!0;try{const e=await Oa(t);st.value="",S(e!=null&&e.id?`Debate started: ${e.id}`:"Debate started","success"),await $e()}catch(e){const n=e instanceof Error?e.message:"Failed to start debate";S(n,"error")}finally{it.value=!1}}}async function Qa(t){It.value=t,he.value=!0,ot.value="";try{ot.value=await ja(t)}catch(e){ot.value=e instanceof Error?e.message:"Failed to load debate status"}finally{he.value=!1}}function Za({debate:t}){const e=It.value===t.id;return o`
    <button
      class="council-row ${e?"selected":""}"
      onClick=${()=>Qa(t.id)}
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
  `}function Ya({session:t}){return o`
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
  `}function ts(){return se(()=>{$e()},[]),o`
    <div>
      <${y} title="Council Command" class="section">
        <div class="council-create">
          <input
            class="control-input"
            type="text"
            placeholder="Start debate topic..."
            value=${st.value}
            onInput=${t=>{st.value=t.target.value}}
            onKeyDown=${t=>{t.key==="Enter"&&Fe()}}
            disabled=${it.value}
          />
          <button
            class="control-btn secondary"
            onClick=${Fe}
            disabled=${it.value||st.value.trim()===""}
          >
            ${it.value?"Starting...":"Start Debate"}
          </button>
          <button class="control-btn ghost" onClick=${$e} disabled=${Lt.value}>
            ${Lt.value?"Refreshing...":"Refresh"}
          </button>
        </div>
        ${Mt.value?o`<div class="council-error">${Mt.value}</div>`:null}
      <//>

      <div class="council-grid">
        <${y} title="Debates" class="section">
          <div class="council-list">
            ${fe.value.length===0?o`<div class="empty-state">No debates yet</div>`:fe.value.map(t=>o`<${Za} key=${t.id} debate=${t} />`)}
          </div>
        <//>

        <${y} title="Voting Sessions" class="section">
          <div class="council-list">
            ${_e.value.length===0?o`<div class="empty-state">No active sessions</div>`:_e.value.map(t=>o`<${Ya} key=${t.id} session=${t} />`)}
          </div>
        <//>
      </div>

      <${y} title=${It.value?`Debate Detail (${It.value})`:"Debate Detail"} class="section">
        ${he.value?o`<div class="loading-indicator">Loading debate detail...</div>`:ot.value?o`<pre class="council-detail">${ot.value}</pre>`:o`<div class="empty-state">Select a debate to view summary</div>`}
      <//>
    </div>
  `}function es(t){const e=Date.now(),n=typeof t=="number"?t:new Date(t).getTime(),a=Math.floor((e-n)/1e3);if(a<60)return`${a}s ago`;const s=Math.floor(a/60);if(s<60)return`${s}m ago`;const i=Math.floor(s/60);return i<24?`${i}h ago`:`${Math.floor(i/24)}d ago`}function B({timestamp:t}){const e=es(t);return o`<span class="time-ago" title=${typeof t=="string"?t:new Date(t).toISOString()}>${e}</span>`}function ns({text:t}){if(!t)return null;const e=as(t);return o`<div class="markdown-content">${e}</div>`}function as(t){const e=t.split(`
`),n=[];let a=0;for(;a<e.length;){const s=e[a];if(/^(`{3,}|~{3,})/.test(s)){const r=s.match(/^(`{3,}|~{3,})/)[0],c=s.slice(r.length).trim(),d=[];for(a++;a<e.length&&!e[a].startsWith(r);)d.push(e[a]),a++;a++,n.push(o`<pre><code class=${c?`language-${c}`:""}>${d.join(`
`)}</code></pre>`);continue}if(s.trim()==="<think>"||s.trim().startsWith("<think>")){const r=[],c=s.trim().replace(/^<think>/,"").trim();for(c&&c!=="</think>"&&r.push(c),a++;a<e.length&&!e[a].includes("</think>");)r.push(e[a]),a++;if(a<e.length){const u=e[a].replace("</think>","").trim();u&&r.push(u),a++}const d=r.join(`
`).trim();n.push(o`
        <details class="think-block">
          <summary>Thinking...</summary>
          <div>${Qt(d)}</div>
        </details>
      `);continue}if(s.startsWith("> ")){const r=[];for(;a<e.length&&e[a].startsWith("> ");)r.push(e[a].slice(2)),a++;n.push(o`<blockquote>${Qt(r.join(`
`))}</blockquote>`);continue}if(s.trim()===""){a++;continue}const i=[];for(;a<e.length;){const r=e[a];if(r.trim()===""||/^(`{3,}|~{3,})/.test(r)||r.startsWith("> ")||r.trim().startsWith("<think>"))break;i.push(r),a++}i.length>0&&n.push(o`<p>${Qt(i.join(`
`))}</p>`)}return n}function Qt(t){const e=[],n=/(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|\[([^\]]+)\]\(([^)]+)\)/g;let a=0,s;for(;(s=n.exec(t))!==null;){if(s.index>a&&e.push(t.slice(a,s.index)),s[1]){const i=s[1].slice(1,-1);e.push(o`<code>${i}</code>`)}else if(s[2]){const i=s[2].slice(2,-2);e.push(o`<strong>${i}</strong>`)}else if(s[3]){const i=s[3].slice(1,-1);e.push(o`<em>${i}</em>`)}else s[4]&&s[5]&&e.push(o`<a href=${s[5]} target="_blank" rel="noopener">${s[4]}</a>`);a=s.index+s[0].length}return a<t.length&&e.push(t.slice(a)),e.length>0?e:[t]}const ss=[{id:"hot",label:"Hot"},{id:"trending",label:"Trending"},{id:"recent",label:"Recent"},{id:"updated",label:"Updated"},{id:"discussed",label:"Discussed"}],rt=f([]),lt=f(!1),ct=f(""),is=f("dashboard-user"),ut=f(!1);async function Bn(t){lt.value=!0,rt.value=[];try{const e=await Ta(t);rt.value=e.comments??[]}catch{}finally{lt.value=!1}}async function qe(t){const e=ct.value.trim();if(e){ut.value=!0;try{await Pa(t,is.value,e),ct.value="",S("Comment posted","success"),await Bn(t),U()}catch{S("Failed to post comment","error")}finally{ut.value=!1}}}function os(){const t=Be.value;return o`
    <div class="board-controls">
      ${ss.map(e=>o`
        <button
          class="board-sort-btn ${t===e.id?"active":""}"
          onClick=${()=>{Be.value=e.id,U()}}
        >
          ${e.label}
        </button>
      `)}
    </div>
  `}function zn({flair:t}){return t?o`<span class="post-flair ${t}">${t}</span>`:null}function rs({post:t}){const e=async(n,a)=>{a.stopPropagation(),await En(t.id,n),U()};return o`
    <div class="board-post" onClick=${()=>ua(t.id)}>
      <div class="vote-column">
        <button class="vote-btn upvote" onClick=${n=>e("up",n)}>▲</button>
        <span class="vote-count">${t.votes??0}</span>
        <button class="vote-btn downvote" onClick=${n=>e("down",n)}>▼</button>
      </div>
      <div class="post-content">
        <div class="post-title">
          ${t.title}
          ${" "}
          <${zn} flair=${t.flair} />
        </div>
        <div class="post-meta">
          <span>${t.author}</span>
          <${B} timestamp=${t.created_at} />
          ${t.comment_count>0?o`<span>${t.comment_count} comments</span>`:null}
          ${(t.hearth_count??0)>0?o`<span>♥ ${t.hearth_count}</span>`:null}
        </div>
      </div>
    </div>
  `}function ls({comments:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No comments yet</div>`:o`
    <div class="comment-thread">
      ${t.map(e=>o`
        <div key=${e.id} class="board-comment">
          <span class="comment-author">${e.author}</span>
          <span class="comment-time"><${B} timestamp=${e.created_at} /></span>
          <div class="comment-text">${e.content}</div>
        </div>
      `)}
    </div>
  `}function cs({postId:t}){return o`
    <div class="comment-form" style="margin-top: 12px; display: flex; gap: 8px;">
      <input
        type="text"
        placeholder="Add a comment..."
        value=${ct.value}
        onInput=${e=>{ct.value=e.target.value}}
        onKeyDown=${e=>{e.key==="Enter"&&qe(t)}}
        style="flex:1; padding:8px 12px; background:rgba(255,255,255,0.06); border:1px solid rgba(255,255,255,0.1); border-radius:8px; color:#eee; font-size:13px;"
        disabled=${ut.value}
      />
      <button
        onClick=${()=>qe(t)}
        disabled=${ut.value||ct.value.trim()===""}
        style="padding:8px 16px; background:rgba(74,222,128,0.15); border:1px solid rgba(74,222,128,0.3); border-radius:8px; color:#4ade80; cursor:pointer; font-size:13px;"
      >
        ${ut.value?"...":"Post"}
      </button>
    </div>
  `}function us({post:t}){rt.value.length===0&&!lt.value&&Bn(t.id);const e=async n=>{await En(t.id,n),U()};return o`
    <div>
      <button class="back-btn" onClick=${()=>zt("board")}>← Back to Board</button>
      <${y} title=${o`${t.title} <${zn} flair=${t.flair} />`}>
        <div class="board-detail">
          <div class="post-body">
            <${ns} text=${t.content} />
          </div>
          <div class="post-meta" style="margin-top: 12px;">
            <span>${t.author}</span>
            <${B} timestamp=${t.created_at} />
            <span>${t.votes??0} votes</span>
            ${(t.hearth_count??0)>0?o`<span>♥ ${t.hearth_count}</span>`:null}
          </div>
          <div style="margin-top: 8px; display: flex; gap: 6px;">
            <button class="vote-btn upvote" onClick=${()=>e("up")}>▲ Upvote</button>
            <button class="vote-btn downvote" onClick=${()=>e("down")}>▼ Downvote</button>
          </div>
        </div>
      <//>

      <${y} title="Comments (${lt.value?"...":rt.value.length})">
        ${lt.value?o`<div class="loading-indicator">Loading comments...</div>`:o`<${ls} comments=${rt.value} />`}
        <${cs} postId=${t.id} />
      <//>
    </div>
  `}function ds(){const t=In.value,e=ve.value,n=N.value.postId;if(n){const a=t.find(s=>s.id===n);return a?o`<${us} post=${a} />`:o`
          <div>
            <button class="back-btn" onClick=${()=>zt("board")}>← Back to Board</button>
            <div class="empty-state">Post not found</div>
          </div>
        `}return o`
    <${os} />
    ${e?o`<div class="loading-indicator">Loading board...</div>`:t.length===0?o`<div class="empty-state">No posts yet</div>`:o`<div class="board-post-list">
            ${t.map(a=>o`<${rs} key=${a.id} post=${a} />`)}
          </div>`}
  `}function vs({msg:t}){return o`
    <div class="message-row">
      <span class="message-author">${t.from??"system"}</span>
      <span class="message-content">${t.content}</span>
      <${B} timestamp=${t.timestamp} />
    </div>
  `}function ps(){const t=Ln.value;return o`
    <div class="section">
      <h2>Recent Activity</h2>
      <div class="message-list">
        ${t.length===0?o`<div class="empty-state">No recent activity</div>`:t.slice(0,50).map((e,n)=>o`<${vs} key=${n} msg=${e} />`)}
      </div>
    </div>
  `}const we=f(null);function fs(t){we.value=t}function Ke(){we.value=null}function _s({keeper:t}){const e=[{label:"Generation",value:t.generation??"-",hint:"Succession count"},{label:"Turns",value:t.turn_count??"-",hint:"Total loop turns"},{label:"Context",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-",hint:t.context_ratio!=null&&t.context_ratio>.8?"Near limit":void 0},{label:"Activity",value:t.activityLevel??"-",hint:"Level 0–5"}];return o`
    <div class="keeper-kpis">
      ${e.map(n=>o`
        <div class="keeper-kpi">
          <div class="keeper-kpi-label">${n.label}</div>
          <div class="keeper-kpi-value">${n.value}</div>
          ${n.hint?o`<div class="keeper-kpi-hint">${n.hint}</div>`:null}
        </div>
      `)}
    </div>
  `}function hs({keeper:t}){const e=t.context_ratio;if(e==null)return null;const n=Math.round(e*100),a=n>80?"bad":n>60?"warn":"";return o`
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
  `}const Zt=f("");function $s({keeper:t}){var s,i;const e=Zt.value.toLowerCase(),n=[{title:"Name",key:"name",value:t.name},{title:"Emoji",key:"emoji",value:t.emoji},{title:"Korean",key:"koreanName",value:t.koreanName??"-"},{title:"Model",key:"model",value:t.model??"-"},{title:"Status",key:"status",value:t.status},{title:"Primary",key:"primaryValue",value:t.primaryValue??"-"},{title:"Activity",key:"activityLevel",value:String(t.activityLevel??"-")},{title:"Gen",key:"generation",value:String(t.generation??"-")},{title:"Turns",key:"turn_count",value:String(t.turn_count??"-")},{title:"Context",key:"context_ratio",value:t.context_ratio!=null?`${Math.round(t.context_ratio*100)}%`:"-"},{title:"Heartbeat",key:"last_heartbeat",value:t.last_heartbeat??"-"},{title:"Traits",key:"traits",value:((s=t.traits)==null?void 0:s.join(", "))||"-"},{title:"Interests",key:"interests",value:((i=t.interests)==null?void 0:i.join(", "))||"-"}],a=e?n.filter(r=>r.title.toLowerCase().includes(e)||r.key.includes(e)||r.value.toLowerCase().includes(e)):n;return o`
    <div class="keeper-field-dict">
      <input
        class="keeper-field-search"
        type="text"
        placeholder="Search fields..."
        value=${Zt.value}
        onInput=${r=>{Zt.value=r.target.value}}
      />
      ${a.map(r=>o`
        <div class="keeper-field-row">
          <span class="keeper-field-title">${r.title}</span>
          <span class="keeper-field-key">${r.key}</span>
          <span style="flex:1; text-align:right; color:#ccc;">${r.value}</span>
        </div>
      `)}
    </div>
  `}function ms({stats:t}){const e=t.max_hp>0?Math.round(t.hp/t.max_hp*100):0,n=t.max_mp>0?Math.round(t.mp/t.max_mp*100):0;return o`
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
  `}function gs({items:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No equipment</div>`:o`
    <div class="keeper-equipment-list">
      ${t.map((e,n)=>o`
        <div class="keeper-equipment-row">
          <span>${e}</span>
          <span class="keeper-gen-label">#${n+1}</span>
        </div>
      `)}
    </div>
  `}function ys({rels:t}){const e=Object.entries(t);return e.length===0?o`<div class="empty-state" style="font-size:13px">No relationships</div>`:o`
    <div class="keeper-k2k-list">
      ${e.map(([n,a])=>o`
        <div style="display:flex; align-items:center; gap:8px; padding:6px 10px; background:rgba(255,255,255,0.03); border-radius:6px;">
          <span class="keeper-mention-chip">${n}</span>
          <span class="keeper-k2k-route">${a}</span>
        </div>
      `)}
    </div>
  `}function We({traits:t,label:e}){return t.length===0?null:o`
    <div style="margin-bottom: 12px;">
      <div style="font-size:11px; color:#888; text-transform:uppercase; letter-spacing:1px; margin-bottom:6px;">${e}</div>
      <div style="display:flex; flex-wrap:wrap; gap:6px;">
        ${t.map(n=>o`<span class="keeper-mention-chip">${n}</span>`)}
      </div>
    </div>
  `}function bs(){const t=we.value;return t?o`
    <div
      class="keeper-detail-overlay"
      style="position:fixed; inset:0; z-index:1000; background:rgba(0,0,0,0.7); display:flex; align-items:center; justify-content:center; padding:20px;"
      onClick=${e=>{e.target.classList.contains("keeper-detail-overlay")&&Ke()}}
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
            <${H} status=${t.status} />
            ${t.model?o`<span class="pill">${t.model}</span>`:null}
          </div>
          <button
            onClick=${()=>Ke()}
            style="background:none; border:none; color:#888; cursor:pointer; font-size:20px; padding:4px 8px;"
          >✕</button>
        </div>

        ${""}
        <${_s} keeper=${t} />

        ${""}
        <${hs} keeper=${t} />

        ${""}
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-top:16px;">

          ${""}
          <${y} title="Field Dictionary">
            <${$s} keeper=${t} />
          <//>

          ${""}
          <${y} title="Profile">
            <${We} traits=${t.traits??[]} label="Traits" />
            <${We} traits=${t.interests??[]} label="Interests" />
            ${t.primaryValue?o`<div style="font-size:12px; color:#888;">Primary value: <span style="color:#4ade80;">${t.primaryValue}</span></div>`:null}
            ${t.last_heartbeat?o`<div style="font-size:12px; color:#888; margin-top:6px;">
                  Last heartbeat: <${B} timestamp=${t.last_heartbeat} />
                </div>`:null}
          <//>

          ${""}
          ${t.trpg_stats?o`
              <${y} title="TRPG Stats">
                <${ms} stats=${t.trpg_stats} />
              <//>
            `:null}

          ${""}
          ${t.inventory&&t.inventory.length>0?o`
              <${y} title="Equipment (${t.inventory.length})">
                <${gs} items=${t.inventory} />
              <//>
            `:null}

          ${""}
          ${t.relationships&&Object.keys(t.relationships).length>0?o`
              <${y} title="Relationships (${Object.keys(t.relationships).length})">
                <${ys} rels=${t.relationships} />
              <//>
            `:null}
        </div>
      </div>
    </div>
  `:null}function ks({agent:t}){return o`
    <div class="agent-card ${t.status}">
      <div class="agent-card-header">
        <span class="agent-emoji">${t.emoji??""}</span>
        <div class="agent-card-info">
          <span class="agent-name">${t.name}</span>
          ${t.koreanName?o`<span class="agent-korean">${t.koreanName}</span>`:null}
        </div>
        <${H} status=${t.status} />
      </div>
      ${t.current_task?o`<div class="agent-task">${t.current_task}</div>`:null}
      ${t.model?o`<div class="agent-model"><span class="pill">${t.model}</span></div>`:null}
    </div>
  `}function ws({keeper:t}){const e=t.context_ratio!=null?Math.round(t.context_ratio*100):null,n=e!=null?e>80?"bad":e>60?"warn":"":"";return o`
    <div class="live-agent keeper-card" onClick=${()=>fs(t)} style="cursor:pointer;">
      <div class="live-agent-main">
        <div class="live-agent-title">
          <span class="live-agent-name">${t.emoji??""} ${t.name}</span>
          <${H} status=${t.status} />
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
  `}function xs(){const t=mt.value,e=Kt.value;return o`
    <div>
      ${e.length>0?o`
          <div class="section" style="margin-bottom: 20px">
            <h2>Keepers (Live)</h2>
            <div class="live-agent-list">
              ${e.map(n=>o`<${ws} key=${n.name} keeper=${n} />`)}
            </div>
          </div>
        `:null}

      <div class="section">
        <h2>All Agents</h2>
        ${t.length===0?o`<div class="empty-state">No agents registered</div>`:o`
            <div class="agent-grid">
              ${t.map(n=>o`<${ks} key=${n.name} agent=${n} />`)}
            </div>
          `}
      </div>
    </div>
  `}function Yt({task:t}){return o`
    <div class="task-row">
      <${H} status=${t.status} />
      <div class="task-info">
        <span class="task-title">${t.title}</span>
        ${t.assignee?o`<span class="task-assignee">${t.assignee}</span>`:null}
      </div>
      ${t.created_at?o`<${B} timestamp=${t.created_at} />`:null}
    </div>
  `}function Ss(){const{todo:t,inProgress:e,done:n}=Un.value;return o`
    <div class="grid-2col">
      <${y} title="In Progress (${e.length})" class="section">
        <div class="task-list">
          ${e.length===0?o`<div class="empty-state">No tasks in progress</div>`:e.map(a=>o`<${Yt} key=${a.id} task=${a} />`)}
        </div>
      <//>

      <${y} title="To Do (${t.length})" class="section">
        <div class="task-list">
          ${t.length===0?o`<div class="empty-state">No pending tasks</div>`:t.map(a=>o`<${Yt} key=${a.id} task=${a} />`)}
        </div>
      <//>
    </div>

    ${n.length>0?o`
        <${y} title="Done (${n.length})" class="section" style="margin-top: 20px">
          <div class="task-list">
            ${n.slice(0,20).map(a=>o`<${Yt} key=${a.id} task=${a} />`)}
            ${n.length>20?o`<div class="empty-state">...and ${n.length-20} more</div>`:null}
          </div>
        <//>
      `:null}
  `}function Cs({event:t}){const n={agent_joined:"#4ade80",agent_left:"#ef4444",broadcast:"#22d3ee",task_update:"#fbbf24",board_post:"#a78bfa",board_comment:"#a78bfa",heartbeat:"#666"}[t.type]??"#888",a=t.message??t.content??t.status??"";return o`
    <div class="journal-entry">
      <span class="journal-type" style="color: ${n}">${t.type}</span>
      <span class="journal-agent">${t.agent??t.from??t.from_agent??""}</span>
      <span class="journal-data">${a}</span>
    </div>
  `}function Ts(){const t=ce.value;return o`
    <div class="section">
      <h2>Event Journal</h2>
      <div class="journal-list">
        ${t.length===0?o`<div class="empty-state">No events recorded yet</div>`:t.map((e,n)=>o`<${Cs} key=${n} event=${e} />`)}
      </div>
    </div>
  `}const te=f("1d20"),wt=f("idle");function Ps(t,e){const n=e>0?t/e*100:0;return n>50?"hp-high":n>25?"hp-mid":"hp-low"}function As(t,e){return e>0?Math.round(t/e*100):0}function Ns({hp:t,max:e}){const n=As(t,e),a=Ps(t,e);return o`
    <div class="trpg-hp-bar">
      <div class="hp-fill ${a}" style="width:${n}%" />
    </div>
  `}function Ds({stats:t}){const e=[{label:"STR",value:t.strength},{label:"DEX",value:t.dexterity},{label:"CON",value:t.constitution},{label:"INT",value:t.intelligence},{label:"WIS",value:t.wisdom},{label:"CHA",value:t.charisma}];return o`
    <div class="trpg-actor-stats">
      ${e.map(n=>o`<span>${n.label} ${n.value}</span>`)}
    </div>
  `}function Rs({keeper:t,role:e}){if(!t)return null;const n=e==="dm"?"dm":"player";return o`
    <span class="trpg-keeper-chip">
      <span class="trpg-keeper-tag ${n}">${n}</span>
      ${t}
    </span>
  `}function Es({actor:t}){return o`
    <div class="trpg-actor">
      <div class="trpg-actor-info">
        <span class="trpg-actor-name">${t.name}</span>
        <${H} status=${t.status??"idle"} />
        <span class="pill">${t.role}</span>
        <${Rs} keeper=${t.keeper} role=${t.role} />
      </div>
      ${t.stats?o`
          <div style="margin-top:4px;">
            <div style="display:flex; align-items:center; gap:6px; font-size:11px; color:#888;">
              HP ${t.stats.hp}/${t.stats.max_hp}
              ${t.stats.max_mp>0?o`<span style="margin-left:8px;">MP ${t.stats.mp}/${t.stats.max_mp}</span>`:null}
              <span style="margin-left:auto; font-size:10px;">Lv ${t.stats.level}</span>
            </div>
            <${Ns} hp=${t.stats.hp} max=${t.stats.max_hp} />
            <${Ds} stats=${t.stats} />
          </div>
        `:null}
    </div>
  `}function Ls({mapStr:t}){return o`<pre class="trpg-map">${t}</pre>`}function Ms({events:t}){return t.length===0?o`<div class="empty-state" style="font-size:13px">No story events yet</div>`:o`
    <div class="trpg-story">
      ${t.slice(-30).map((e,n)=>{var a;return o`
        <div key=${n} class="trpg-event ${e.type??""}">
          ${e.actor?o`<strong>${e.actor}</strong>${" "}`:null}
          ${e.dice_roll?o`<span class="trpg-dice">[${e.dice_roll.notation}: ${(a=e.dice_roll.rolls)==null?void 0:a.join(",")} = ${e.dice_roll.total}${e.dice_roll.modifier?` +${e.dice_roll.modifier}`:""}]</span>${" "}`:null}
          <span class="trpg-event-text">${e.content??""}</span>
          <span style="float:right; font-size:10px; color:#555;"><${B} timestamp=${e.timestamp} /></span>
        </div>
      `})}
    </div>
  `}function Is({state:t}){const e=t.history??[];return e.length===0?null:o`
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
  `}function Os({state:t}){var r;const e=jn.value||((r=t.session)==null?void 0:r.room)||"",n=wt.value,a=async()=>{if(!e){S("No room set","error");return}wt.value="running";try{await Na(e),wt.value="ok",S("Round executed","success"),W()}catch{wt.value="error",S("Round failed","error")}},s=async()=>{if(e)try{await Ra(e),S("Turn advanced","success"),W()}catch{S("Advance failed","error")}},i=async()=>{const c=te.value.trim();if(!(!e||!c))try{await Da(e,c),S(`Rolled ${c}`,"success"),W()}catch{S("Dice roll failed","error")}};return o`
    <div class="trpg-control-box">
      <div class="trpg-control-grid">
        <div class="trpg-control-field">
          <label>Dice</label>
          <div style="display:flex; gap:4px;">
            <input
              type="text"
              value=${te.value}
              onInput=${c=>{te.value=c.target.value}}
              onKeyDown=${c=>{c.key==="Enter"&&i()}}
              placeholder="1d20+3"
              style="flex:1;"
            />
            <button class="trpg-run-btn secondary" onClick=${i}>Roll</button>
          </div>
        </div>

        <div class="trpg-control-field">
          <label>Actions</label>
          <div style="display:flex; gap:4px;">
            <button
              class="trpg-run-btn recommend"
              onClick=${a}
              disabled=${n==="running"}
            >
              ${n==="running"?"Running...":"Run Round"}
            </button>
            <button class="trpg-run-btn secondary" onClick=${s}>
              Next Turn
            </button>
          </div>
        </div>
      </div>

      ${n!=="idle"?o`<div class="trpg-run-status ${n}">${n==="running"?"Processing...":n==="ok"?"Done":"Failed"}</div>`:null}
    </div>
  `}function js({state:t}){var n;const e=t.current_round;return e?o`
    <div class="trpg-next-action">
      <div class="trpg-next-action-title">Round ${e.round_number}</div>
      <div class="trpg-next-action-desc">Phase: ${e.phase}</div>
      ${e.events.length>0?o`<div class="trpg-next-action-target">
            Last: ${(n=e.events[e.events.length-1].content)==null?void 0:n.slice(0,80)}
          </div>`:null}
    </div>
  `:null}function Us(){var s,i;const t=On.value;if(pe.value&&!t)return o`<div class="loading-indicator">Loading TRPG state...</div>`;if(!t)return o`
      <div class="section">
        <h2>TRPG</h2>
        <div class="empty-state">No active TRPG session</div>
        <button class="board-sort-btn" onClick=${()=>W()}>Refresh</button>
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
      <${js} state=${t} />

      ${""}
      <div class="trpg-layout">
        <div>
          ${""}
          <${y} title="Story Log (${a.length})">
            <${Ms} events=${a} />
          <//>

          ${""}
          ${t.map?o`
              <${y} title="Map" style="margin-top:16px;">
                <${Ls} mapStr=${t.map} />
              <//>`:null}
        </div>

        <div class="trpg-sidebar">
          ${""}
          <${y} title="Controls">
            <${Os} state=${t} />
          <//>

          ${""}
          <${y} title="Party (${n.length})" style="margin-top:16px;">
            <div class="trpg-actor-list">
              ${n.map(r=>o`<${Es} key=${r.id??r.name} actor=${r} />`)}
              ${n.length===0?o`<div class="empty-state" style="font-size:13px">No actors</div>`:null}
            </div>
          <//>

          ${""}
          ${t.history&&t.history.length>0?o`
              <${y} title="History (${t.history.length})" style="margin-top:16px;">
                <${Is} state=${t} />
              <//>`:null}
        </div>
      </div>
    </div>
  `}const Fn="masc_dashboard_agent_name";function Hs(){const t=new URLSearchParams(window.location.search),e=t.get("agent")??t.get("agent_name"),n=localStorage.getItem(Fn);return e??n??"dashboard"}const Ot=f(Hs()),dt=f(""),vt=f(""),jt=f(""),pt=f(!1),q=f(!1);function Bs(t){const e=t.trim();Ot.value=e,e&&localStorage.setItem(Fn,e)}async function Ge(){const t=Ot.value.trim(),e=dt.value.trim();if(!(!t||!e)){pt.value=!0;try{await Ea(t,e),dt.value="",S("Broadcast sent","success")}catch(n){const a=n instanceof Error?n.message:"Failed to send broadcast";S(a,"error")}finally{pt.value=!1}}}async function zs(){const t=vt.value.trim(),e=jt.value.trim()||"Created from dashboard";if(t){q.value=!0;try{await La(t,e,1),vt.value="",jt.value="",S("Task created","success")}catch(n){const a=n instanceof Error?n.message:"Failed to create task";S(a,"error")}finally{q.value=!1}}}function Fs(){return o`
    <section class="rail-card control-dock">
      <h3>Control Dock</h3>

      <label class="control-label" for="dock-agent">Agent</label>
      <input
        id="dock-agent"
        class="control-input"
        type="text"
        value=${Ot.value}
        onInput=${t=>Bs(t.target.value)}
      />

      <label class="control-label" for="dock-message">Broadcast</label>
      <div class="control-row">
        <input
          id="dock-message"
          class="control-input"
          type="text"
          placeholder="@agent message or room update"
          value=${dt.value}
          onInput=${t=>{dt.value=t.target.value}}
          onKeyDown=${t=>{t.key==="Enter"&&Ge()}}
          disabled=${pt.value}
        />
        <button
          class="control-btn"
          onClick=${Ge}
          disabled=${pt.value||dt.value.trim()===""||Ot.value.trim()===""}
        >
          ${pt.value?"Sending...":"Send"}
        </button>
      </div>

      <label class="control-label" for="dock-task">Quick Task</label>
      <input
        id="dock-task"
        class="control-input"
        type="text"
        placeholder="Task title"
        value=${vt.value}
        onInput=${t=>{vt.value=t.target.value}}
        disabled=${q.value}
      />
      <textarea
        class="control-textarea"
        placeholder="Task description (optional)"
        value=${jt.value}
        onInput=${t=>{jt.value=t.target.value}}
        disabled=${q.value}
      ></textarea>
      <button
        class="control-btn secondary"
        onClick=${zs}
        disabled=${q.value||vt.value.trim()===""}
      >
        ${q.value?"Creating...":"Create Task"}
      </button>
    </section>
  `}function qs(){const t=J.value;return o`
    <div class="connection-status ${t?"connected":"disconnected"}">
      <span class="status-dot ${t?"connected":"disconnected"}"></span>
      <span class="status-text">${t?"Live":"Reconnecting..."}</span>
      ${Et.value>0?o`<span class="event-count">${Et.value} events</span>`:null}
    </div>
  `}const Ks=[{id:"overview",label:"Overview"},{id:"council",label:"Council"},{id:"board",label:"Board"},{id:"activity",label:"Activity"},{id:"agents",label:"Agents"},{id:"tasks",label:"Tasks"},{id:"journal",label:"Journal"},{id:"trpg",label:"TRPG"}];function Ws(){const t=N.value.tab,e=J.value;return o`
    <aside class="dashboard-rail">
      <section class="rail-card">
        <h3>Views</h3>
        <div class="rail-tab-list">
          ${Ks.map(n=>o`
            <button
              class="rail-tab-btn ${t===n.id?"active":""}"
              onClick=${()=>zt(n.id)}
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
            <strong>${mt.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Keepers</span>
            <strong>${Kt.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Tasks</span>
            <strong>${qt.value.length}</strong>
          </div>
          <div class="rail-stat-row">
            <span>Events</span>
            <strong>${Et.value}</strong>
          </div>
        </div>
        <button
          class="rail-refresh-btn"
          onClick=${()=>{Wt(),t==="board"&&U(),t==="trpg"&&W()}}
        >
          Refresh Now
        </button>
      </section>

      <${Fs} />
    </aside>
  `}function Gs(){switch(N.value.tab){case"overview":return o`<${ze} />`;case"council":return o`<${ts} />`;case"board":return o`<${ds} />`;case"activity":return o`<${ps} />`;case"agents":return o`<${xs} />`;case"tasks":return o`<${Ss} />`;case"journal":return o`<${Ts} />`;case"trpg":return o`<${Us} />`;default:return o`<${ze} />`}}function Js(){return se(()=>{da(),An(),Wt();const t=za();return Fa(),()=>{ya(),t(),qa()}},[]),se(()=>{const t=N.value.tab;t==="board"&&U(),t==="trpg"&&W()},[N.value.tab]),o`
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
          <${qs} />
          <div class="header-links">
            <a href="/dashboard/lodge">Lodge</a>
            <a href="/dashboard/credits">Credits</a>
          </div>
        </div>
      </header>

      <div class="tab-sticky-wrap">
        <${pa} />
      </div>

      <div class="dashboard-layout">
        <main class="dashboard-main">
          ${de.value&&!J.value?o`<div class="loading-indicator">Loading dashboard...</div>`:o`<${Gs} />`}
        </main>
        <${Ws} />
      </div>

      <${bs} />
      <${Xa} />
    </div>
  `}const Je=document.getElementById("app");Je&&Vn(o`<${Js} />`,Je);
