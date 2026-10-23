// Optional browser installation; account and training access never depend on it.
export function setupHomeScreenInstall(){
 let deferredPrompt=null, installed=window.matchMedia('(display-mode: standalone)').matches||navigator.standalone===true, prompting=false, status='';
 const dialog=document.createElement('dialog');
 dialog.className='install-dialog';dialog.setAttribute('aria-labelledby','install-title');
 document.body.append(dialog);
 const isIOS=/iPad|iPhone|iPod/.test(navigator.userAgent)||(navigator.platform==='MacIntel'&&navigator.maxTouchPoints>1);
 const isAndroid=/Android/.test(navigator.userAgent);
 function render(){
  dialog.innerHTML=`<div class="install-heading"><span class="brand-mark" aria-hidden="true">c↗</span><button type="button" class="button secondary" data-install-action="close" aria-label="Close installation instructions">Close</button></div><h1 id="install-title">${installed?'colTRAIN is installed':'Add colTRAIN to your home screen'}</h1><p>Open your courses and team updates from a colTRAIN icon on your phone.</p>${installed?'<p class="account-note">You’re ready. Use the colTRAIN icon to open your training.</p>':`${deferredPrompt?`<button type="button" class="button install-primary" data-install-action="install" ${prompting?'disabled':''}>${prompting?'Opening installation…':'Install colTRAIN'}</button>`:''}<details ${isIOS?'open':''}><summary>iPhone and iPad</summary><ol><li>Open the colTRAIN website in <strong>Safari</strong>.</li><li>Tap <strong>Share</strong> (the square with an upward arrow).</li><li>Scroll down and tap <strong>Add to Home Screen</strong>.</li><li>If shown, leave <strong>Open as Web App</strong> turned on. Tap <strong>Add</strong>.</li></ol></details><details ${isAndroid?'open':''}><summary>Android phones</summary><ol><li>Open the colTRAIN website in <strong>Chrome</strong>.</li><li>Tap the <strong>three-dot menu</strong>.</li><li>Choose <strong>Add to home screen</strong> or <strong>Install app</strong>, then confirm.</li></ol></details><details ${!isIOS&&!isAndroid?'open':''}><summary>On a computer</summary><p>Open colTRAIN in Chrome or Edge. Use the install icon near the address bar, or look for <strong>Install colTRAIN</strong> in the browser’s menu.</p></details><p class="account-small">If you opened this link inside an email or another app, open it in Safari or Chrome first.</p>`}<p class="install-status" role="status" aria-live="polite">${status}</p><p class="account-small">An internet connection is needed for training and team posts. On a shared device, sign out when you finish. You may need to sign in when you reopen colTRAIN.</p>`;
 }
 window.addEventListener('beforeinstallprompt',event=>{event.preventDefault();deferredPrompt=event;if(dialog.open)render();});
 window.addEventListener('appinstalled',()=>{installed=true;deferredPrompt=null;prompting=false;status='';if(dialog.open)render();});
 document.addEventListener('click',async event=>{
  const target=event.target.closest('[data-install-action]');
  if(!target)return;
  event.preventDefault();
  if(target.dataset.installAction==='open'){status='';render();if(!dialog.open)dialog.showModal();return;}
  if(target.dataset.installAction==='close'){dialog.close();return;}
  if(target.dataset.installAction==='install'&&deferredPrompt&&!prompting){
   const prompt=deferredPrompt;deferredPrompt=null;prompting=true;
   target.disabled=true;target.textContent='Opening installation…';
   try{
    await prompt.prompt();
    const choice=await prompt.userChoice;
    status=installed?'':choice?.outcome==='accepted'?'Follow your browser’s installation steps.':'You can add colTRAIN later using the steps below.';
   }catch{status=installed?'':'Use the steps below to add colTRAIN.';}
   finally{prompting=false;if(dialog.open)render();}
  }
 });
 // Only the hosted /accounts/ app is controlled. Downloaded HTML and previews stay independent.
 if(window.isSecureContext&&location.pathname.startsWith('/accounts/')&&'serviceWorker' in navigator){
  try{navigator.serviceWorker.register('/accounts/sw.js',{scope:'/accounts/',updateViaCache:'none'}).catch(()=>{});}catch{/* Sandboxed previews can expose the property but deny access to it. */}
 }
}
