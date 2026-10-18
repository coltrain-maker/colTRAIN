const esc=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
export function avatarMarkup(name,path,large=false){
 const parts=String(name||'Teammate').trim().split(/\s+/),initials=(parts[0]?.[0]||'T')+(parts.length>1?parts.at(-1)[0]:'');
 return `<span class="profile-avatar ${large?'profile-avatar-large':''}" aria-hidden="true" ${path?`data-avatar-path="${esc(path)}"`:''}><span>${esc(initials.toUpperCase())}</span>${path?'<img alt="" hidden>':''}</span>`;
}
export function createAvatarLoader(client){
 let generation=0;
 const urls=new Map(),pending=new Map();
 function clear(){generation++;for(const url of urls.values())URL.revokeObjectURL(url);urls.clear();pending.clear();}
 function hydrate(root=document){
  if(!client)return;
  for(const element of root.querySelectorAll('.profile-avatar[data-avatar-path]')){
   const path=element.dataset.avatarPath,img=element.querySelector('img'),version=generation;
   const show=url=>{if(!url||version!==generation||!element.isConnected)return;img.onload=()=>{if(version===generation&&element.isConnected){img.hidden=false;element.querySelector('span').hidden=true;}};img.onerror=()=>{img.hidden=true;element.querySelector('span').hidden=false;};if(img.getAttribute('src')!==url)img.src=url;};
   if(urls.has(path)){show(urls.get(path));continue;}
   if(!pending.has(path)){
    const request=client.storage.from('profile-photos').download(path).then(({data,error})=>{
     if(error||version!==generation)return null;
     const url=URL.createObjectURL(data);urls.set(path,url);return url;
    }).catch(()=>null).finally(()=>{if(pending.get(path)===request)pending.delete(path);});
    pending.set(path,request);
   }
   pending.get(path).then(show);
  }
 }
 return {hydrate,clear};
}
export async function prepareAvatar(file){
 if(!['image/jpeg','image/png','image/webp'].includes(file.type))throw new Error('Choose a JPG, PNG, or WebP photo.');
 if(file.size>20*1024*1024)throw new Error('Choose a photo smaller than 20 MB.');
 const source=URL.createObjectURL(file),image=new Image();
 try{
  image.src=source;await image.decode();
  if(!image.naturalWidth||!image.naturalHeight)throw new Error();
  const canvas=document.createElement('canvas');canvas.width=canvas.height=512;
  const context=canvas.getContext('2d');if(!context)throw new Error();
  const side=Math.min(image.naturalWidth,image.naturalHeight);
  context.fillStyle='#fff';context.fillRect(0,0,512,512);
  context.drawImage(image,(image.naturalWidth-side)/2,(image.naturalHeight-side)/2,side,side,0,0,512,512);
  const blob=await new Promise(resolve=>canvas.toBlob(resolve,'image/jpeg',0.85));
  if(!blob||blob.size>1048576)throw new Error();
  return {id:crypto.randomUUID(),blob,preview:URL.createObjectURL(blob),path:null,uploaded:false};
 }catch{throw new Error('This photo could not be opened. Choose another JPG, PNG, or WebP image.');}
 finally{URL.revokeObjectURL(source);}
}
