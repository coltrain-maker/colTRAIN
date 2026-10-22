import {avatarMarkup} from './avatars.js';
const esc = (value) => String(value ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
const button = (label, action, extra = "", kind = "secondary") => `<button type="button" class="button ${kind}" data-training-action="${action}" ${extra}>${label}</button>`;
const when = (value) => new Intl.DateTimeFormat("en-US", { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }).format(new Date(value));
const emptyDraft = () => ({ id: crypto.randomUUID(), body: "", photos: [], announcement: false, pin: false, comments: true });
async function preparePhoto(file) {
  if (!["image/jpeg", "image/png", "image/webp"].includes(file.type)) throw new Error("Choose a JPG, PNG, or WebP photo.");
  if (file.size > 20 * 1024 * 1024) throw new Error("Choose a photo smaller than 20 MB.");
  const source = URL.createObjectURL(file), image = new Image();
  try {
    image.src = source;
    await image.decode();
    let scale = Math.min(1, 1600 / Math.max(image.naturalWidth, image.naturalHeight));
    const canvas = document.createElement("canvas"), context = canvas.getContext("2d");
    if (!context || !image.naturalWidth || !image.naturalHeight) throw new Error("This photo could not be opened. Choose a different photo.");
    let blob;
    for (let attempt = 0; attempt < 4; attempt++) {
      canvas.width = Math.max(1, Math.round(image.naturalWidth * scale));
      canvas.height = Math.max(1, Math.round(image.naturalHeight * scale));
      context.fillStyle = "#fff";
      context.fillRect(0, 0, canvas.width, canvas.height);
      context.drawImage(image, 0, 0, canvas.width, canvas.height);
      blob = await new Promise((resolve) => canvas.toBlob(resolve, "image/jpeg", 0.82));
      if (blob && blob.size <= 1048576) return { id: crypto.randomUUID(), blob, preview: URL.createObjectURL(blob), path: null, uploaded: false };
      scale *= 0.7;
    }
    throw new Error("This photo could not be prepared. Choose a different photo.");
  } catch (error) {
    throw new Error(error.message?.startsWith("Choose") || error.message?.startsWith("This photo") ? error.message : "This photo could not be opened. Choose another JPG, PNG, or WebP image.");
  } finally {
    URL.revokeObjectURL(source);
  }
}
function createTeamCorner({ client, store, user, onRender, notify, isVisible }) {
  let data = null, postDraft = emptyDraft(), closed = false, morePosts = [], focusedPost = null, supportTimer = null, observer = null;
  const drafts = /* @__PURE__ */ new Map(), images = /* @__PURE__ */ new Map(), pendingImages = /* @__PURE__ */ new Set();
  const commentsDraft = (id) => {
    if (!drafts.has(id)) drafts.set(id, emptyDraft());
    return drafts.get(id);
  };
  async function rpc(name, args) {
    const { data: data2, error } = await client.rpc(name, args);
    if (error) throw new Error(error.code === "PGRST202" || error.code === "42P01" ? "Team Corner is not available yet. Please contact colTRAIN support." : error.message);
    return data2;
  }
  function clearImages() {
    for (const url of images.values()) URL.revokeObjectURL(url);
    images.clear();
  }
  function resetPhotoDraft(draft) {
    for (const photo of draft.photos) URL.revokeObjectURL(photo.preview);
  }
  function scheduleSupportCheck() {
    clearTimeout(supportTimer);
    if (data?.support && !data.can_post) {
      supportTimer = setTimeout(() => {
        if (closed) return;
        clearImages();
        data = { can_read: false, posts: [], pinned: [] };
        onRender();
      }, Math.max(0, Math.min(2147483647, new Date(data.support.expires_at) - Date.now() + 100)));
    }
  }
  async function load(postId = null) {
    if(postId)focusedPost=postId;
    const result = await rpc("get_team_corner", { store });
    if (closed) return;
    data = result;
    if(focusedPost&&data.can_read){
      try{
        const selected=await rpc('get_team_corner_post',{post:focusedPost});
        if(closed)return;
        data.pinned=data.pinned.filter(p=>p.id!==focusedPost);data.posts=data.posts.filter(p=>p.id!==focusedPost);
        (selected.pinned?data.pinned:data.posts).unshift(selected);
      }catch(error){focusedPost=null;if(postId)throw error;}
    }
    morePosts = [];
    clearImages();
    scheduleSupportCheck();
  }
  const supportPoll = setInterval(async () => {
    if (!closed && isVisible() && !document.hidden && data?.can_read && !data.can_post) {
      try {
        await load();
        onRender();
      } catch {
        clearImages();
        data = { can_read: false, posts: [], pinned: [] };
        onRender();
      }
    }
  }, 3e4);
  function draftPhotos(draft, key) {
    return draft.photos.length ? `<div class="team-photo-previews">${draft.photos.map((photo) => `<div><img src="${photo.preview}" alt="Selected photo"><button type="button" aria-label="Remove selected photo" data-training-action="team-remove-photo" data-draft="${key}" data-photo="${photo.id}">\xD7</button></div>`).join("")}</div>` : "";
  }
  function media(items) {
    return items?.length ? `<div class="team-photo-grid">${items.map((photo) => `<figure><img data-team-image="${esc(photo.object_name)}" alt="Team photo" loading="lazy"><figcaption hidden>Photo could not be loaded. Refresh the feed to try again.</figcaption></figure>`).join("")}</div>` : "";
  }
  function comment(c) {
    return `<div class="team-comment" data-comment="${c.id}"><div class="team-comment-top">${avatarMarkup(c.author_name,c.avatar_path)}<strong>${esc(c.author_name)}</strong><time>${when(c.created_at)}</time>${c.can_remove ? button("Remove", "team-remove", `data-item="${c.id}" data-comment="true"`, "text-button") : ""}</div>${c.body ? `<p class="team-message">${esc(c.body)}</p>` : ""}${media(c.media)}</div>`;
  }
  function post(p) {
    const draft = commentsDraft(p.id);
    return `<article class="panel team-post ${p.pinned ? "team-post-pinned" : ""}" data-post="${p.id}"><div class="panel-top"><div class="person-with-avatar">${avatarMarkup(p.author_name,p.avatar_path)}<div><h2>${esc(p.author_name)}</h2><time>${when(p.created_at)}</time></div></div><div class="chips">${p.pinned ? '<span class="chip">Pinned announcement</span>' : p.announcement ? '<span class="chip">Announcement</span>' : ""}</div></div>${p.body ? `<p class="team-message">${esc(p.body)}</p>` : ""}${media(p.media)}<div class="team-post-actions">${data.can_post ? `<button type="button" class="button secondary" aria-pressed="${p.liked}" data-training-action="team-like" data-post="${p.id}" data-liked="${!p.liked}">${p.liked ? "Liked" : "Like"} \xB7 ${p.like_count}</button>` : `<span>${p.like_count} ${p.like_count === 1 ? "like" : "likes"}</span>`}${data.is_manager ? `${button(p.pinned ? "Unpin" : "Pin announcement", "team-options", `data-post="${p.id}" data-pin="${!p.pinned}" data-comments="${p.comments_open}"`)}${button(p.comments_open ? "Turn off comments" : "Turn on comments", "team-options", `data-post="${p.id}" data-pin="${p.pinned}" data-comments="${!p.comments_open}"`)}` : ""}${p.can_remove ? button("Remove post", "team-remove", `data-item="${p.id}"`) : ""}</div><section class="team-comments" aria-label="Comments">${p.more_comments ? button("View earlier comments", "team-earlier-comments", `data-post="${p.id}"`, "text-button") : ""}${p.comments.map(comment).join("")}${data.can_post && p.comments_open ? `<form id="training-team-comment-${p.id}" data-team-form="comment" data-post="${p.id}"><label class="field">Write a comment<textarea name="message" maxlength="2000" rows="2" placeholder="Add to the conversation\u2026">${esc(draft.body)}</textarea></label>${draftPhotos(draft, p.id)}<div class="team-compose-actions"><label class="team-photo-picker">Add photos<input type="file" accept="image/jpeg,image/png,image/webp" multiple data-team-files="${p.id}"></label><button class="button">Comment</button></div></form>` : !p.comments_open ? '<p class="muted team-comments-closed">Comments are turned off for this post.</p>' : ""}</section></article>`;
  }
  function html() {
    const title = '<div class="page-heading"><div><h1>Team Corner</h1><p>Your store. Your people. A place to stay connected.</p></div>' + button("Refresh feed", "team-refresh") + "</div>";
    if (!data) return title + '<section class="panel"><p>Loading your team\u2026</p></section>';
    if (!data.can_read) return title + '<section class="panel"><h2>This team feed is private</h2><p class="muted">A store manager must request support access before a colTRAIN administrator can view this feed. Support access is read-only and lasts up to 24 hours.</p></section>';
    return title + `<div class="team-corner-layout"><div class="stack">${data.can_post ? `<section class="panel team-composer"><h2>Share with your team</h2><form id="training-team-post-form" data-team-form="post"><label class="field">Your post<textarea name="message" maxlength="5000" rows="3" placeholder="Share a win, ask a question, or post a photo\u2026">${esc(postDraft.body)}</textarea></label>${draftPhotos(postDraft, "post")}${data.is_manager ? `<div class="team-announcement-options"><label class="training-check"><input type="checkbox" name="announcement" ${postDraft.announcement ? "checked" : ""}>Announcement</label><label class="training-check"><input type="checkbox" name="pin" ${postDraft.pin ? "checked" : ""}>Pin announcement</label><label class="training-check"><input type="checkbox" name="comments" ${postDraft.comments ? "checked" : ""}>Allow comments</label></div>` : ""}<div class="team-compose-actions"><label class="team-photo-picker">Add photos<input type="file" accept="image/jpeg,image/png,image/webp" multiple data-team-files="post"></label><span class="muted">Up to four photos</span><button class="button">Post to team</button></div></form></section>` : '<section class="panel team-support-notice"><h2>Read-only support access</h2><p>Your access expires ' + when(data.support.expires_at) + ". The store manager can revoke it sooner.</p></section>"}${[...data.pinned, ...data.posts, ...morePosts].map(post).join("") || '<section class="panel"><h2>Start the conversation</h2><p class="muted">No posts yet. Share something with your store team.</p></section>'}${data.has_more ? button("Load more posts", "team-more") : ""}</div>${data.is_manager ? `<aside class="panel team-support-panel"><h2>Get help from colTRAIN</h2>${data.support ? `<p class="muted">Read-only administrator access is active until ${when(data.support.expires_at)}.</p><p class="team-message">${esc(data.support.reason)}</p>${button("Revoke support access", "team-revoke-support")}` : `<p class="muted">If you need help with this feed, grant colTRAIN administrators read-only access for 24 hours. You can revoke it at any time.</p><form id="training-team-support-form" data-team-form="support"><label class="field">What do you need help with?<textarea name="reason" minlength="5" maxlength="500" required></textarea></label><button class="button secondary">Request admin support</button></form>`}</aside>` : ""}</div>`;
  }
  function hydrate(root) {
    observer?.disconnect();
    const download = (img) => {
      const path = img.dataset.teamImage;
      if (images.has(path)) {
        img.src = images.get(path);
        return;
      }
      if (pendingImages.has(img)) return;
      pendingImages.add(img);
      client.storage.from("team-media").download(path).then(({ data: blob, error }) => {
        if (closed || !img.isConnected || !isVisible()) return;
        if (error) {
          img.hidden = true;
          img.nextElementSibling.hidden = false;
          return;
        }
        const url = URL.createObjectURL(blob);
        const previous = images.get(path);
        if (previous) URL.revokeObjectURL(previous);
        images.set(path, url);
        img.src = url;
      }).catch(() => {
        if (img.isConnected) {
          img.hidden = true;
          img.nextElementSibling.hidden = false;
        }
      }).finally(() => pendingImages.delete(img));
    };
    observer = new IntersectionObserver((entries) => {
      for (const entry of entries) if (entry.isIntersecting) {
        observer.unobserve(entry.target);
        download(entry.target);
      }
    }, { rootMargin: "250px" });
    for (const img of root.querySelectorAll("[data-team-image]")) {
      if (images.has(img.dataset.teamImage)) img.src = images.get(img.dataset.teamImage);
      else observer.observe(img);
    }
  }
  function input(target) {
    const form = target.closest("[data-team-form]");
    if (!form) return;
    const draft = form.dataset.teamForm === "post" ? postDraft : form.dataset.teamForm === "comment" ? commentsDraft(form.dataset.post) : null;
    if (!draft) return;
    if (target.name === "message") draft.body = target.value;
    else if (["announcement", "pin", "comments"].includes(target.name)) draft[target.name] = target.checked;
  }
  async function choosePhotos(input2) {
    const draft = input2.dataset.teamFiles === "post" ? postDraft : commentsDraft(input2.dataset.teamFiles), files = [...input2.files];
    if (draft.photos.length + files.length > 4) throw new Error("Choose up to four photos per post or comment.");
    const added = [];
    try {
      for (const file of files) added.push(await preparePhoto(file));
      draft.photos.push(...added);
    } catch (error) {
      for (const photo of added) URL.revokeObjectURL(photo.preview);
      throw error;
    }
  }
  async function upload(draft) {
    for (const photo of draft.photos) {
      if (!photo.path) {
        const record = await rpc("register_team_corner_media", { store, media: photo.id, content_type: "image/jpeg" });
        photo.path = record.object_name;
      }
      if (!photo.uploaded) {
        const { error } = await client.storage.from("team-media").upload(photo.path, photo.blob, { contentType: "image/jpeg", upsert: false });
        if (error) {
          if (!/already exists|duplicate/i.test(error.message || "")) throw new Error("The photo could not be uploaded. Your draft is kept; please try again.");
          const check = await client.storage.from("team-media").download(photo.path);
          if (check.error) throw new Error("The photo could not be verified. Please try again.");
        }
        photo.uploaded = true;
      }
    }
    return draft.photos.map((photo) => photo.id);
  }
  async function submit(form) {
    const type = form.dataset.teamForm;
    if (type === "support") {
      await rpc("request_team_corner_support", { store, support_reason: new FormData(form).get("reason").trim() });
      await load();
      notify("Read-only administrator support access is available for 24 hours.");
      return;
    }
    const draft = type === "post" ? postDraft : commentsDraft(form.dataset.post);
    draft.body = new FormData(form).get("message");
    if (!draft.body.trim() && !draft.photos.length) throw new Error("Write a message or add a photo first.");
    const media_ids = await upload(draft);
    if (type === "post") await rpc("create_team_corner_post", { store, submission: draft.id, message: draft.body, media_ids, is_announcement: draft.announcement, pin: draft.pin, allow_comments: draft.comments });
    else await rpc("create_team_corner_comment", { post: form.dataset.post, submission: draft.id, message: draft.body, media_ids });
    resetPhotoDraft(draft);
    if (type === "post") postDraft = emptyDraft();
    else drafts.delete(form.dataset.post);
    await load();
    notify(type === "post" ? "Your post is shared with the team." : "Your comment is saved.");
  }
  async function action(target) {
    const action2 = target.dataset.trainingAction;
    if(action2==='team-refresh')focusedPost=null;
    if (action2 === "team-remove-photo") {
      const draft = target.dataset.draft === "post" ? postDraft : commentsDraft(target.dataset.draft), photo = draft.photos.find((p) => p.id === target.dataset.photo);
      if (photo) {
        if (photo.uploaded) await client.storage.from("team-media").remove([photo.path]);
        URL.revokeObjectURL(photo.preview);
        draft.photos = draft.photos.filter((p) => p !== photo);
      }
      return;
    }
    if (action2 === "team-more") {
      const last = [...data.posts, ...morePosts].at(-1);
      if (!last) return;
      const page = await rpc("get_team_corner", { store, before_time: last.created_at, before_id: last.id });
      if (!page.can_read) {
        clearImages();
        data = page;
        morePosts = [];
        return;
      }
      const seen = new Set([...data.pinned, ...data.posts, ...morePosts].map((p) => p.id));
      morePosts.push(...page.posts.filter((p) => !seen.has(p.id)));
      data.has_more = page.has_more;
      return;
    }
    if (action2 === "team-earlier-comments") {
      const post2 = [...data.pinned, ...data.posts, ...morePosts].find((p) => p.id === target.dataset.post), first = post2.comments[0];
      const page = await rpc("get_team_corner_comments", { post: post2.id, before_time: first.created_at, before_id: first.id });
      post2.comments = [...page.comments, ...post2.comments];
      post2.more_comments = page.has_more;
      return;
    }
    if (action2 === "team-like") await rpc("set_team_corner_like", { post: target.dataset.post, liked: target.dataset.liked === "true" });
    if (action2 === "team-options") await rpc("set_team_corner_post_options", { post: target.dataset.post, is_pinned: target.dataset.pin === "true", allow_comments: target.dataset.comments === "true" });
    if (action2 === "team-remove") {
      if (!window.confirm("Remove this " + (target.dataset.comment === "true" ? "comment" : "post and its comments") + " from the team feed?")) return;
      await rpc("remove_team_corner_item", { item: target.dataset.item, is_comment: target.dataset.comment === "true" });
      notify("Removed from the team feed.");
    }
    if (action2 === "team-revoke-support") {
      await rpc("revoke_team_corner_support", { store });
      notify("Administrator support access revoked.");
    }
    await load();
  }
  function close() {
    closed = true;
    observer?.disconnect();
    clearInterval(supportPoll);
    clearTimeout(supportTimer);
    clearImages();
    resetPhotoDraft(postDraft);
    for (const d of drafts.values()) resetPhotoDraft(d);
  }
  return { load, html, hydrate, input, choosePhotos, submit, action, close, pause: () => observer?.disconnect() };
}
function teamSupportRequests(requests) {
  return '<div class="page-heading"><div><h1>Team support requests</h1><p>Stores that have granted temporary read-only access to their Team Corner.</p></div>' + button("Refresh requests", "team-support-refresh") + '</div><div class="stack">' + (requests.length ? requests.map((request) => `<section class="panel"><h2>${esc(request.store_name)}</h2><p class="muted">Requested by ${esc(request.requested_by)} \xB7 Access until ${when(request.expires_at)}</p><p class="team-message">${esc(request.reason)}</p>${button("Open store feed", "team-support-open", `data-store="${request.store_id}"`)}</section>`).join("") : '<section class="panel"><h2>No active support requests</h2><p class="muted">A store manager can request support from their Team Corner page.</p></section>') + "</div>";
}
export {
  createTeamCorner,
  teamSupportRequests
};
