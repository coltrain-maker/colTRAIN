import {pointSummary,pointHeaders,pointCells} from './points.js';
import {createAdminUpdates} from './admin-updates.js';
import {coursePicker,updateCoursePicker} from './course-picker.js';
import {createDailyDrill} from './daily-drill.js';
import {avatarMarkup} from './avatars.js';
import {academyPlan,academyLabel,skillLevels,skillLabel,libraryPaths,filterLibrary} from './course-library.js';
import { notificationsPage } from './notifications.js';
import { createTeamCorner, teamSupportRequests } from './team-corner.js';
import { setAccountHeader } from './header.js';
import { competitionSpotlight, competitionPoints, competitionsPage, startCompetitionPage, competitionRecipients, leaderboardPage } from './competitions.js';
import { learningTimer } from './learning-time.js';
const starterDepartments = [
  "Front Counter & Customer Service",
  "Paint",
  "Hardware & Fasteners",
  "Plumbing",
  "Electrical",
  "Lawn & Garden"
];
const esc = (value) => String(value ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
const trophy = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M8 3h8v7a4 4 0 0 1-8 0V3z M8 5H4v3a4 4 0 0 0 4 4 M16 5h4v3a4 4 0 0 1-4 4 M12 14v6 M8 21h8"/></svg>';
const btn = (label, action, extra = "", kind = "") => `<button type="button" class="button ${kind}" data-training-action="${action}" ${extra}>${label}</button>`;
const bar = (pct) => `<div class="progress-track" aria-label="${pct}% complete"><span style="width:${pct}%"></span></div>`;
const day = (value) => value ? new Intl.DateTimeFormat("en-US", { month: "short", day: "numeric", year: "numeric", timeZone: "UTC" }).format(/* @__PURE__ */ new Date(value + "T12:00:00Z")) : "No deadline";
const dueLabel = value => value ? `Due ${day(value)}` : 'No deadline set';
function defaultDeadline(zone, offset = 0) {
  const parts = new Intl.DateTimeFormat("en-US", { timeZone: zone || "America/New_York", year: "numeric", month: "2-digit", day: "2-digit" }).formatToParts(/* @__PURE__ */ new Date());
  const part = (type) => parts.find((p) => p.type === type).value;
  const today = /* @__PURE__ */ new Date(`${part("year")}-${part("month")}-${part("day")}T12:00:00Z`);
  today.setUTCDate(today.getUTCDate() + offset);
  return today.toISOString().slice(0, 10);
}
async function mountTraining({ client, root, user, profile, stores, initialStore, initialView = "home", avatars, onNavigate, onAccounts, notify }) {
  const events = new AbortController();
  const timer = learningTimer(client);
  let selectedCompetition, leaderboardTab = "competition", challengeMode = false, challengeResult = null, refresherCompetition = null;
  let active = true, busy = false, view = initialView, menu = false, storeId = initialStore, workspace, selectedCourse, assignment, lessons = [], questions = [], completions = [], lessonIndex = 0, quizQuestions = [], questionIndex = 0, answers = {}, submissionKey = null, result = null, review = [], librarySearch = "";
  const daily = createDailyDrill({client,notify,isVisible:()=>active&&view==='daily'&&!menu,getPoints:()=>workspace?.totals,onPointsChanged:async()=>{workspace=await rpc('get_training_workspace',{store:storeId});}});
  let notifications = {items:[],unread_count:0};
  let libraryLevel='',libraryTopic='',libraryPath='',libraryAcademy='',libraryCourse='';
  let adminUpdates=null;
  let accountMarkup = "", corner = null, cornerStore = null, supportRequests = [];
  async function loadTeam(){
    if(!corner || cornerStore !== storeId){corner?.close();cornerStore=storeId;corner=createTeamCorner({client,store:storeId,user,notify,onRender:()=>{if(active&&view==='team')render();},isVisible:()=>active&&view==='team'});}
    await corner.load();
  }
  const headerButton = document.createElement("button");
  headerButton.className = "icon-button training-menu-toggle";
  headerButton.type = "button";
  headerButton.dataset.trainingAction = "menu";
  headerButton.setAttribute("aria-label", "Open menu");
  headerButton.setAttribute("aria-expanded", "false");
  headerButton.textContent = "\u2630";
  document.querySelector("header")?.append(headerButton);
  root.classList.add("training-main");
  async function rpc(name, args) {
    const { data, error } = await client.rpc(name, args);
    if (error) throw new Error(error.code === "PGRST202" || error.code === "42P01" ? "Training is not available yet. Please contact colTRAIN support." : error.message);
    return data;
  }
  async function refresh() {
    workspace = await rpc("get_training_workspace", { store: storeId });
    notifications = await rpc("get_my_training_notifications", { store: storeId });
    await daily.load(storeId);
    const role = workspace.is_admin ? 'Administrator' : workspace.members.find(m => m.id === workspace.my_membership)?.role === 'manager' ? 'Manager' : 'Employee';
    setAccountHeader({storeName:workspace.store.name,profile,user,role});
    avatars?.hydrate(document.querySelector("header"));
  }
  async function loadAdminUpdates(){if(!workspace.is_admin)throw new Error('Administrator access required');adminUpdates ||= createAdminUpdates({client,stores,currentStore:storeId,notify});await adminUpdates.load();}
  const courseById = (id) => workspace.courses.find((c) => c.id === id);
  const mine = () => workspace.assignments.filter((a) => a.membership_id === workspace.my_membership);
  const progress = (a) => a.completed_at ? 100 : Math.floor(a.lessons_completed / ((courseById(a.course_id)?.lesson_count || 0) + 1) * 100);
  const status = (a) => !a ? "Not assigned" : a.completed_at ? "Completed" : a.attempts_used >= a.attempt_limit ? "Manager help needed" : a.started_at ? "In progress" : "Not started";
  const title = (name, copy = "", action = "") => `<div class="page-heading"><div><h1>${esc(name)}</h1>${copy ? `<p>${esc(copy)}</p>` : ""}</div>${action}</div>`;
  const stat = (number, label) => `<div class="stat"><div><strong>${esc(number)}</strong><small>${esc(label)}</small></div></div>`;
  function navigation() {
    if (!menu) return "";
    const link = (page, label) => `<button type="button" data-training-action="navigate" data-view="${page}" ${page === "notifications" ? 'aria-label="Notifications"' : ""} ${view === page ? 'aria-current="page"' : ""}>${label}${page === "notifications" && notifications.unread_count ? `<span class="notification-count" aria-hidden="true">${notifications.unread_count}</span>` : ""}</button>`;
    const group = (name, content) => `<div class="training-menu-group" role="group" aria-label="${name}">${content}</div>`;
    return `<div class="training-menu-shade"><nav class="training-drawer" aria-label="Main navigation"><div class="panel-top"><h2>colTRAIN</h2>${btn("Close", "menu", "", "secondary")}</div>${link("home", workspace.can_manage ? "Dashboard" : "Home")}${group("Training", link("courses", "My training") + link("library", "Course library") + (workspace.can_manage ? link("assign", "Assign training") : "") + link("notifications", "Notifications") + (workspace.is_admin?link("admin-updates","Admin updates"):""))}${group("Team Corner", link("team", "Team Corner") + (workspace.is_admin ? link("team-support", "Team support") : ""))}${group("Competitions", link("competitions", "Competitions") + link("leaderboard", "Store leaderboard"))}${group("Settings", `<button type="button" data-training-action="accounts" ${view === "accounts" ? 'aria-current="page"' : ""}>Account & team settings</button>${workspace.can_manage ? link("departments", "Departments") : ""}<button type="button" data-install-action="open">Add to home screen</button>`)}<button type="button" class="account-danger training-menu-signout" data-action="signout">Sign out and switch accounts</button></nav></div>`;
  }
  function cover() {
    return '<div class="course-cover"><div class="cover-grid"></div><div class="cover-scene"><div class="scene-person"></div><div class="scene-person second"></div><div class="scene-desk"></div><div class="scene-chat">\xB7\xB7\xB7</div></div></div>';
  }
  function courseCard(c, a, compact = false) {
    const pct = a ? progress(a) : 0;
    return `<article class="course-card${compact?' library-course-card':''}">${compact?'':cover()}<div class="course-info"><div class="chips"><span class="chip">${esc(academyLabel(c))}</span><span class="chip gray">${esc(skillLabel(c))}</span><span class="chip ${a?.completed_at ? "green" : a?.overdue ? "amber" : "gray"}">${esc(a ? status(a) : c.released ? "Available to your store" : "Not released to this store")}</span></div><h2>${esc(c.title)}</h2><p class="library-description">${esc(c.description)}</p><div class="meta"><span>${c.lesson_count} lessons</span><span>${c.question_count} questions</span><span>Up to ${c.question_count * 10} Course points</span></div>${a ? `<p class="training-due ${a.overdue ? "account-danger" : ""}">${a.overdue ? "Overdue \xB7 " : ""}${dueLabel(a.due_date)}</p><p class="progress-label">${a.lessons_completed} of ${c.lesson_count} lessons complete \xB7 ${pct}%</p>${bar(pct)}` : ""}<div class="course-bottom">${btn(a?.completed_at ? "Review course" : a?.started_at ? "Continue learning" : a ? "Start learning" : "Preview course", "open-course", `data-course="${c.id}"`)}${a?.latest_attempt ? btn("View result", "latest-result", `data-assignment="${a.id}"`, "secondary") : ""}${workspace.can_manage && c.released ? btn("Assign training", "assign-course", `data-course="${c.id}"`, "secondary") : ""}${workspace.is_admin ? btn(c.released ? "Remove from library" : "Make available to store", "release", `data-course="${c.id}" data-available="${!c.released}"`, "secondary") : ""}</div></div></article>`;
  }
  function learningHome() {
    const items = mine();
    const first = items.find((a) => !a.completed_at);
    const c = first && courseById(first.course_id);
    return title(`Welcome, ${profile?.full_name?.split(" ")[0] || "teammate"}`, "One useful lesson at a time.") + competitionSpotlight(workspace) + daily.card() + `${pointSummary(workspace.totals)}<div class="stats">${stat(workspace.totals.completed_courses, "Courses completed")}${stat(workspace.totals.trophies, "Trophies earned")}</div><section class="learning-section"><div class="section-title"><h2>Your next chapter</h2>${btn("All my training", "navigate", 'data-view="courses"', "secondary")}</div>${first ? `<section class="panel training-progress"><h2>Your course progress</h2><p>${progress(first)}% complete \xB7 ${first.lessons_completed} of ${c.lesson_count} lessons</p>${bar(progress(first))}</section>${courseCard(c, first)}` : `<section class="panel"><h2>${items.length ? "You\u2019re all caught up." : "Your training starts here."}</h2><p class="muted">${items.length ? "Your completed courses and trophies are saved." : "Your manager will assign courses and set deadlines. You can explore the store\u2019s course library while you wait."}</p></section>`}</section>`;
  }
  function alerts(items, heading) {
    return items?.length ? `<section class="panel training-alerts"><h2>${heading}</h2><p class="muted">At least three different employees missed these questions on their first attempt. Review the lesson with your team.</p>${items.map((a) => `<div class="training-alert"><strong>${esc(a.course_title)}</strong><p>${esc(a.prompt)}</p><span>${a.missed_count} employees \xB7 no individual answers shown</span></div>`).join("")}</section>` : "";
  }
  function managerHome() {
    const members = workspace.members.filter((m) => m.status === "active" && m.role === "employee");
    const assignments = workspace.assignments.filter((a) => workspace.members.some((m) => m.id === a.membership_id && m.status === "active"));
    const locked = assignments.filter((a) => !a.completed_at && a.attempts_used >= a.attempt_limit);
    return title("Your team, learning together.", "Assignments, deadlines, and lifelong progress in one place.", btn("Assign training", "navigate", 'data-view="assign"')) + competitionSpotlight(workspace) + daily.card() + `<div class="stats manager-stats">${stat(members.length, "Active employees")}${stat(assignments.filter((a) => a.completed_at).length, "Completed assignments")}${stat(assignments.filter((a) => a.overdue).length, "Overdue assignments")}</div>${pointSummary({course_points:members.reduce((n,m)=>n+(m.course_points??0),0),daily_points:members.reduce((n,m)=>n+(m.daily_points??0),0),lifetime_points:members.reduce((n,m)=>n+m.lifetime_points,0)},{label:'Team points',prefix:'Team '})}<section class="panel"><h2>Your team: current competition & lifetime points</h2><p class="muted">Competition scores come from the separate challenge. Lifetime points include all earned course and Daily Drill points.</p><div class="manager-table-wrap"><table class="table"><thead><tr><th>Employee</th><th>Course status</th><th>Current course</th><th>Competition points</th>${pointHeaders()}</tr></thead><tbody>${members.length ? members.flatMap((m) => {
      const assigned = assignments.filter((a) => a.membership_id === m.id);
      return (assigned.length ? assigned : [null]).map((a) => `<tr><td><div class="person-with-avatar">${avatarMarkup(m.name,m.avatar_path)}<div><strong>${esc(m.name)}</strong><small>${m.departments.map((d) => esc(workspace.departments.find((x) => x.id === d)?.name || "")).join(", ") || "No department"}</small></div></div></td><td>${esc(status(a))}${a ? `<small>${progress(a)}% \xB7 ${a.attempts_used} attempts${a.latest_attempt ? ` \xB7 Latest score ${a.latest_attempt.score}%` : ""}</small>` : ""}</td><td>${a ? `${esc(courseById(a.course_id)?.title)}<small class="${a.overdue ? "account-danger" : ""}">${a.overdue ? "Overdue \xB7 " : ""}${dueLabel(a.due_date)}</small>` : "\u2014"}</td><td>${competitionPoints(workspace,m.id)}</td>${pointCells(m)}</tr>`);
    }).join("") : '<tr><td colspan="7">Invite employees in Account & team settings to get started.</td></tr>'}</tbody></table></div></section>${locked.length ? `<section class="panel"><h2>Help an employee retry</h2><p class="muted">Review the material together, then unlock one additional attempt. Previous points and attempts stay saved.</p><form id="training-unlock-form"><label class="field">Assignment<select name="assignment">${locked.map((a) => `<option value="${a.id}">${esc(workspace.members.find((m) => m.id === a.membership_id)?.name)} \xB7 ${esc(courseById(a.course_id)?.title)}</option>`).join("")}</select></label><label class="field">How did you help?<textarea name="reason" minlength="5" maxlength="500" required></textarea></label><button class="button">Unlock one attempt</button></form></section>` : ""}${alerts(workspace.question_alerts, "Questions to revisit with your store")}${workspace.is_admin ? alerts(workspace.global_question_alerts, "Questions to revisit across all stores") : ""}`;
  }
  function myCourses() {
    return title("My training", "Your assigned courses, deadlines, and saved progress.") + `<div class="stack">${mine().length ? mine().map((a) => courseCard(courseById(a.course_id), a)).join("") : '<section class="panel"><h2>No courses assigned yet</h2><p class="muted">Your manager can assign training from the store\u2019s library.</p></section>'}</div>`;
  }
  function academyPlanning() {
    return `<details class="panel academy-plan"><summary>Academy plan: 10 academies · 260 planned modules</summary><p>Planned allocations only. These modules are not all created or available. Full courses and colTRAIN Daily lessons remain separate completion records. The library result count below reflects actual courses visible to this account; your completed courses appear on Home.</p><div style="overflow-x:auto"><table><caption>Planned modules by skill level</caption><thead><tr><th>Academy</th><th>Foundations</th><th>Application</th><th>Expertise</th><th>Total planned</th></tr></thead><tbody>${academyPlan.academies.map(a=>`<tr><th scope="row">${esc(a.name)}</th><td>${a.planned_modules.foundations}</td><td>${a.planned_modules.application}</td><td>${a.planned_modules.expertise}</td><td>${a.planned_modules.total}</td></tr>`).join('')}</tbody><tfoot><tr><th>Total planned</th><td>88</td><td>112</td><td>60</td><td>260</td></tr></tfoot></table></div></details>`;
  }
  function library() {
    const visible=filterLibrary(workspace.courses,{search:librarySearch,level:libraryLevel,subtopic:libraryTopic,path:libraryPath,academy:libraryAcademy,course:libraryCourse});
    const filtered=Boolean(librarySearch||libraryLevel||libraryTopic||libraryPath||libraryAcademy||libraryCourse);
    return title("Course library", `Explore training for ${workspace.store.name}. Your manager assigns courses and deadlines.`) + (workspace.is_admin ? academyPlanning() : "") + `<form id="training-search-form" class="panel library-filters"><div class="library-filter-fields">${coursePicker(workspace.courses,{academy:libraryAcademy,subtopic:libraryTopic,course:libraryCourse,allowAll:true})}<label class="field">Skill level<select name="level" aria-label="Skill level"><option value="">All skill levels</option>${skillLevels.map(([value,label])=>`<option value="${value}" ${libraryLevel===value?'selected':''}>${label}</option>`).join('')}</select></label><label class="field">Learning path<select name="path" aria-label="Learning path"><option value="">All learning paths</option>${libraryPaths(workspace.courses).map(path=>`<option value="${esc(path)}" ${libraryPath===path?'selected':''}>${esc(path)}</option>`).join('')}</select></label><label class="field library-keywords">Search courses<input name="search" type="search" placeholder="Course name, code, or keywords" value="${esc(librarySearch)}"></label></div><div class="library-filter-actions"><button class="button" type="submit">Search</button>${btn('Clear filters','clear-library','','secondary')}</div></form><p class="library-result-count" role="status">${visible.length} ${visible.length===1?'course':'courses'}${filtered?(visible.length===1?' matches your search':' match your search'):' available to browse'}</p><div class="library-cards">${visible.length ? visible.map((c) => courseCard(c, mine().find((a) => a.course_id === c.id), true)).join("") : `<section class="panel"><h2>${workspace.courses.length?'No matching courses':'No courses available'}</h2><p class="muted">${workspace.courses.length?'Try another skill level, topic, learning path, or keyword, or clear your filters.':'Your colTRAIN administrator releases courses to this store.'}</p></section>`}</div>`;
  }
  function assignPage() {
    const released = workspace.courses.filter((c) => c.released);
    return title("Assign training", "Choose employees, departments, or the whole team. Existing progress is kept when you change a deadline.") + `<section class="panel">${released.length ? `<form id="training-assign-form">${coursePicker(released,{course:selectedCourse})}<label class="field">Deadline (optional)<input type="date" name="deadline" value=""></label><p class="muted">Choose a deadline, or leave it blank for no deadline. Applying this to an existing assignment replaces its deadline; saved progress is kept.</p><fieldset><legend>Employees</legend><label class="training-check"><input type="checkbox" name="all" value="yes">All active employees</label>${workspace.members.filter((m) => m.status === "active").map((m) => `<label class="training-check"><input type="checkbox" name="employee" value="${m.id}">${esc(m.name)}${m.role === "manager" ? " (manager)" : ""}</label>`).join("")}</fieldset><fieldset><legend>Departments</legend>${workspace.departments.length ? workspace.departments.map((d) => `<label class="training-check"><input type="checkbox" name="department" value="${d.id}">${esc(d.name)}</label>`).join("") : '<p class="muted">Create departments and place employees in them on the Departments page.</p>'}</fieldset><button class="button">Assign course</button></form>` : '<h2>No released courses yet</h2><p class="muted">Ask the colTRAIN administrator to make a course available to your store first.</p>'}</section>`;
  }
  function missingStarterDepartments() {
    const existing = new Set(workspace.departments.map((d) => d.name.trim().toLocaleLowerCase()));
    return starterDepartments.filter((name) => !existing.has(name.toLocaleLowerCase()));
  }
  async function addStarterDepartments() {
    let created = 0;
    try {
      await refresh();
      for (const name of missingStarterDepartments()) {
        try {
          await rpc("create_training_department", { store: storeId, department_name: name });
          created++;
        } catch (error) {
          // Another manager may have created the same name since our last read.
          await refresh();
          if (!workspace.departments.some((d) => d.name.trim().toLocaleLowerCase() === name.toLocaleLowerCase())) throw error;
        }
      }
      await refresh();
      render();
      notify(created ? `${created} starter ${created === 1 ? "department added" : "departments added"}. Existing departments and employee placements are kept.` : "All starter departments are already available in this store.");
    } catch (error) {
      await refresh();
      render();
      throw error;
    }
  }
  function departmentsPage() {
    return title("Departments", "Employees can belong to more than one department.") + `<section class="panel training-department-template"><h2>Starter departments</h2><p class="muted">Start with these six departments, then add others to match your store. Existing departments and employee placements are kept.</p><ul>${starterDepartments.map((name) => `<li>${esc(name)}</li>`).join("")}</ul>${btn("Add starter departments", "starter-departments", missingStarterDepartments().length ? "" : "disabled")}${missingStarterDepartments().length ? "" : '<p class="muted">All six starter departments are available in this store.</p>'}</section><section class="panel"><h2>Add a department</h2><form id="training-department-form"><label class="field">Department name<input name="name" maxlength="100" required></label><button class="button">Add department</button></form></section><section class="panel"><h2>Employee departments</h2><form id="training-membership-form"><label class="field">Employee<select name="member" id="training-department-member">${workspace.members.filter((m) => m.status === "active").map((m) => `<option value="${m.id}">${esc(m.name)}</option>`).join("")}</select></label><div id="training-department-options">${departmentOptions(workspace.members.find((m) => m.status === "active"))}</div><button class="button" ${!workspace.departments.length ? "disabled" : ""}>Save departments</button></form></section>`;
  }
  function departmentOptions(member) {
    return workspace.departments.length ? workspace.departments.map((d) => `<label class="training-check"><input type="checkbox" name="department" value="${d.id}" ${member?.departments.includes(d.id) ? "checked" : ""}>${esc(d.name)}</label>`).join("") : '<p class="muted">Add your first department above.</p>';
  }
  function content(blocks) {
    return blocks.map((b) => b.type === "heading" ? `<h3>${esc(b.text)}</h3>` : b.type === "callout" ? `<div class="callout">${esc(b.text)}</div>` : b.type === "bullet" ? `<p class="training-bullet">\u2022 ${esc(b.text)}</p>` : `<p>${esc(b.text)}</p>`).join("");
  }
  function quizEntryButton() {
    if (refresherCompetition) {
      const event = workspace.competitions.find(c => c.id === refresherCompetition);
      const participant = event?.standings.find(p => p.is_you && !p.withdrawn);
      const available = event?.status === 'active' && participant && participant.attempts_used < participant.attempt_limit;
      return btn(available ? participant.attempts_used ? 'Retake competition quiz' : 'Take competition quiz' : 'Back to competition', available ? 'competition-challenge' : 'competition-standings', `data-competition="${refresherCompetition}"`, 'secondary');
    }
    if (!assignment) return btn("Knowledge check", "start-quiz", "disabled", "secondary");
    if (assignment.completed_at) return btn("View course result", "latest-result", `data-assignment="${assignment.id}"`, "secondary");
    const label = assignment.attempts_used >= assignment.attempt_limit ? "Get manager help" : assignment.attempts_used ? "Try knowledge check again" : "Knowledge check";
    return btn(label, "start-quiz", completions.length < lessons.length ? "disabled" : "", "secondary");
  }
  function lessonPage() {
    const c = courseById(selectedCourse), l = lessons[lessonIndex];
    if (!l) return '<section class="panel">This course has no lessons yet.</section>';
    const done = completions.includes(l.id), unlocked = !assignment || lessonIndex === 0 || completions.includes(lessons[lessonIndex - 1].id);
    const last = lessonIndex === lessons.length - 1;
    const action = !assignment ? btn(last ? "Back to library" : "Next lesson", "preview-next") : done ? last ? quizEntryButton() : btn("Next lesson", "review-next") : btn(last ? "Complete & take quiz" : "Mark complete & continue", "complete-lesson", unlocked ? "" : "disabled");
    return `${refresherCompetition ? `<section class="panel"><h2>Review before your competition quiz</h2><p class="muted">This refresher is optional. Your lessons are already complete. Review any lesson, or go straight to the competition quiz.</p>${quizEntryButton()}</section>` : ''}<div class="breadcrumb">${btn("My training", "navigate", 'data-view="courses"', "secondary")} / ${esc(academyLabel(c))}</div><div class="course-layout"><aside class="panel lesson-nav"><h3>${esc(c.title)}</h3><p>${completions.length} of ${lessons.length} lessons complete</p>${bar(assignment ? progress(assignment) : 0)}${lessons.map((item, i) => `<button type="button" class="lesson-item ${i === lessonIndex ? "active" : ""}" data-training-action="lesson" data-index="${i}" ${assignment && i > 0 && !completions.includes(lessons[i - 1].id) ? "disabled" : ""}><span class="lesson-number">${completions.includes(item.id) ? "\u2713" : i + 1}</span><span>${esc(item.title)}</span></button>`).join("")}${quizEntryButton()}</aside><article class="panel lesson-content"><div class="chips"><span class="chip">Lesson ${lessonIndex + 1} of ${lessons.length}</span>${!assignment ? '<span class="chip gray">Course preview</span>' : ""}</div><h1>${esc(l.title)}</h1>${content(l.body)}<div class="lesson-actions"><span>${done ? "\u2713 Lesson already complete. You can review it without marking it again." : assignment ? "Mark complete when you\u2019re ready to continue." : "Preview only. Your manager must assign this course before you can earn points or a trophy."}</span>${action}</div>${assignment ? `<p class="quiz-note">Lessons earn completion checkmarks. Quiz answers earn points. ${dueLabel(assignment.due_date)}${assignment.overdue ? " \xB7 Overdue training remains available." : ""}</p>` : ""}</article></div>`;
  }
  function quizPage() {
    if (challengeMode) return challengeQuizPage();
    if (!assignment) return "";
    if (assignment.completed_at) return '<section class="panel"><h2>Course already completed</h2><p>Your trophy and points are saved.</p></section>';
    if (assignment.attempts_used >= assignment.attempt_limit) return `<section class="panel result-panel"><h1>A little teamwork can help.</h1><p>You\u2019ve used all ${assignment.attempt_limit} available attempts. Ask your manager to review the lesson with you and unlock one more.</p>${btn("Back to course", "open-course", `data-course="${selectedCourse}"`)}</section>`;
    const q = quizQuestions[questionIndex];
    return `<div class="quiz-wrap"><div class="quiz-header"><span>Question ${questionIndex + 1} of ${quizQuestions.length}</span><span>Attempt ${assignment.attempts_used + 1} of ${assignment.attempt_limit}</span></div>${bar(Math.round((questionIndex + 1) / quizQuestions.length * 100))}<section class="panel quiz-panel"><h2>${esc(q.prompt)}</h2><form id="training-quiz-form">${q.options.map((option, i) => `<label class="option"><input type="radio" name="answer" value="${i}" ${answers[q.id] === i ? "checked" : ""} required><span>${esc(option)}</span></label>`).join("")}<div class="lesson-actions">${btn("Back", "quiz-back", questionIndex === 0 ? "disabled" : "", "secondary")}<button class="button">${questionIndex === quizQuestions.length - 1 ? "Finish quiz" : "Next question"}</button></div></form></section><p class="quiz-note">${courseById(selectedCourse).passing_percent}% to pass. Earn 10 points the first time each answer is correct. No speed bonuses.<br>Only submitting the completed quiz uses an attempt. Refreshing before submission clears your unsaved answers.</p></div>`;
  }
  function resultsPage() {
    return `<section class="panel result-panel"><div class="trophy-big">${result.passed ? trophy : "\u2726"}</div><span class="chip ${result.passed ? "green" : "amber"}">${result.passed ? "Course passed" : "Keep learning"}</span><h1>${result.passed ? "Trust starts with you." : "You\u2019re getting there."}</h1><p>${result.passed ? "Your course completion and standard trophy are saved." : "Review the explanations and return to the lessons before trying again."}</p><div class="result-stats"><div><strong>${result.score}%</strong><small>${result.correct_count} of ${result.question_count} correct</small></div><div><strong>+${result.new_points}</strong><small>New Course points this attempt</small></div><div><strong>${result.course_points}</strong><small>This course’s points</small></div></div>${pointSummary(workspace.totals)}${!result.passed ? `<div class="answer-review"><h2>A few things to revisit</h2>${review.filter((r) => !r.is_correct).map((r) => `<p><strong>${esc(r.prompt)}</strong><br>Correct answer: ${esc(r.options[r.correct_option])}<br>${esc(r.explanation)}</p>`).join("")}</div>` : ""}<div class="result-actions">${btn("Back to home", "navigate", 'data-view="home"', "secondary")}${btn(result.passed ? "Review course" : "Review lessons", "open-course", `data-course="${selectedCourse}"`)}</div><p class="quiz-note">${result.attempts_used} of ${result.attempt_limit} attempts used. Previously earned points are kept.</p></section>`;
  }
  function challengeQuizPage() {
    const q=quizQuestions[questionIndex];
    return `<div class="quiz-wrap"><h1>Competition knowledge check</h1><p class="muted">Question ${questionIndex+1} of ${quizQuestions.length}. Your best score counts. Lifetime points and course attempts stay saved.</p><section class="panel quiz-panel"><h2>${esc(q.prompt)}</h2><form id="training-quiz-form">${q.options.map((option,i)=>`<label class="option"><input type="radio" name="answer" value="${i}" ${answers[q.id]===i?'checked':''} required><span>${esc(option)}</span></label>`).join('')}<div class="lesson-actions">${btn("Back","quiz-back",questionIndex===0?'disabled':'',"secondary")}<button class="button">${questionIndex===quizQuestions.length-1?'Finish challenge':'Next question'}</button></div></form></section></div>`;
  }
  function challengeResultsPage(){return `<section class="panel result-panel"><h1>Challenge saved</h1><p>${challengeResult.correct_count} of ${challengeResult.question_count} correct · ${challengeResult.points} competition points on this attempt.</p><p>Your best challenge score counts. Lifetime points, course credit, and trophies stay saved.</p>${pointSummary(workspace.totals)}<p>${challengeResult.attempts_used} of ${challengeResult.attempt_limit} attempts used.</p><div class="answer-review">${challengeResult.review.filter(r=>!r.is_correct).map(r=>`<p><strong>${esc(r.prompt)}</strong><br>Correct answer: ${esc(r.correct_answer)}<br>${esc(r.explanation)}</p>`).join('')}</div>${btn("See standings","competition-standings",`data-competition="${selectedCompetition}"`)}</section>`;}
  async function startChallenge(id){
    await refresh();
    const event=workspace.competitions.find(c=>c.id===id), participant=event?.standings.find(p=>p.is_you&&!p.withdrawn);
    if(!participant||event.status!=='active')throw new Error('An active competition invitation is required.');
    if(!participant.course_completed)throw new Error('Pass the required course first, then return for the competition knowledge check.');
    if(participant.attempts_used>=participant.attempt_limit)throw new Error('Ask your manager to help and unlock another challenge attempt.');
    selectedCompetition=id; selectedCourse=event.course_id;
    assignment=mine().find(a=>a.course_id===selectedCourse);
    const response=await client.from('training_questions').select('id,prompt,options,position').eq('course_id',selectedCourse).order('position');
    if(response.error)throw response.error;
    quizQuestions=[...response.data].sort(()=>Math.random()-.5);questionIndex=0;answers={};submissionKey=crypto.randomUUID();challengeMode=true;view='quiz';render();
  }
  function render() {
    if (!active) return;
    onNavigate?.(view,storeId);
    headerButton.setAttribute("aria-expanded", String(menu));
    headerButton.innerHTML = `☰${notifications.unread_count?'<span class="notification-dot" aria-hidden="true"></span>':''}`;
    headerButton.setAttribute('aria-description',`${notifications.unread_count} unread notifications`);
    root.innerHTML = `${workspace.is_admin && stores.length > 1 ? `<label class="training-store-selector">View store<select id="training-store">${stores.map((s) => `<option value="${s.id}" ${s.id === storeId ? "selected" : ""}>${esc(s.name)}</option>`).join("")}</select></label>` : ""}<div class="stack">${view === "admin-updates" ? adminUpdates?.page()||"" : view === "daily" ? daily.page() : view === "notifications" ? notificationsPage(notifications,workspace.store.name) : view === "team-support" ? teamSupportRequests(supportRequests) : view === "team" ? corner?.html() || "" : view === "accounts" ? `<div class="training-account-settings">${accountMarkup}</div>` : view === "home" ? workspace.can_manage ? managerHome() : learningHome() : view === "courses" ? myCourses() : view === "library" ? library() : view === "assign" ? assignPage() : view === "departments" ? departmentsPage() : view === "course" ? lessonPage() : view === "quiz" ? quizPage() : view === "results" ? resultsPage() : view === "competitions" ? competitionsPage(workspace) : view === "competition-new" ? startCompetitionPage(workspace,selectedCourse,defaultDeadline(workspace.store.time_zone,0),defaultDeadline(workspace.store.time_zone,14)) : view === "leaderboard" ? leaderboardPage(workspace,selectedCompetition,leaderboardTab) : view === "challenge-results" ? challengeResultsPage() : ""}</div>${navigation()}`;
    daily.setVisible(view==='daily'&&!menu);
    avatars?.hydrate(root);
    if(view==='team')corner?.hydrate(root);else corner?.pause();
    timer.set(!menu && (view === "course" || view === "quiz" && (challengeMode || assignment && !assignment.completed_at && assignment.attempts_used < assignment.attempt_limit)) ? assignment?.id || null : null);
  }
  async function run(action) {
    if (busy) return;
    busy = true;
    headerButton.disabled = true;
    const buttons = [...root.querySelectorAll("button")].map((button) => ({ button, disabled: button.disabled }));
    buttons.forEach(({ button }) => button.disabled = true);
    try {
      await action();
    } catch (e) {
      notify(e.message || "The request could not be completed.", true);
    } finally {
      busy = false;
      headerButton.disabled = false;
      buttons.forEach(({ button, disabled }) => {
        if (button.isConnected) button.disabled = disabled;
      });
    }
  }
  async function openCourse(id, competition = null) {
    refresherCompetition = competition;
    challengeMode=false;
    await refresh();
    selectedCourse = id;
    assignment = mine().find((a) => a.course_id === id);
    const responses = await Promise.all([client.from("training_lessons").select("id,title,body,position").eq("course_id", id).order("position"), client.from("training_questions").select("id,prompt,options,position").eq("course_id", id).order("position"), assignment ? client.from("training_lesson_completions").select("lesson_id").eq("assignment_id", assignment.id) : Promise.resolve({ data: [] })]);
    const error = responses.find((r) => r.error)?.error;
    if (error) throw error;
    lessons = responses[0].data;
    questions = responses[1].data;
    completions = responses[2].data.map((d) => d.lesson_id);
    lessonIndex = Math.max(0, lessons.findIndex((l) => !completions.includes(l.id)));
    view = "course";
    render();
  }
  async function startQuiz() {
    challengeMode=false;
    await refresh();
    assignment = mine().find((a) => a.course_id === selectedCourse);
    if (!assignment) throw new Error("Ask your manager to assign this course first.");
    if (completions.length < lessons.length) throw new Error("Complete all lessons before taking the quiz.");
    if (assignment.completed_at) throw new Error("This course is already passed. Your trophy and points are saved.");
    if (assignment.attempts_used >= assignment.attempt_limit) {
      view = "quiz";
      render();
      return;
    }
    quizQuestions = [...questions];
    for (let i = quizQuestions.length - 1; i > 0; i--) {
      const j = Math.floor(Math.random() * (i + 1));
      [quizQuestions[i], quizQuestions[j]] = [quizQuestions[j], quizQuestions[i]];
    }
    questionIndex = 0;
    answers = {};
    submissionKey = crypto.randomUUID();
    view = "quiz";
    render();
  }
  async function showResult(attempt, related) {
    assignment = related;
    selectedCourse = related.course_id;
    result = { ...attempt, course_points: related.course_points, attempts_used: related.attempts_used, attempt_limit: related.attempt_limit };
    review = await rpc("get_training_attempt_review", { attempt: attempt.id });
    view = "results";
    render();
  }
  function focusDaily(){if(view!=='daily')return;const heading=root.querySelector('.page-heading h1');if(heading){heading.tabIndex=-1;heading.focus();heading.scrollIntoView({block:'start'});}}
  async function handleForm(form) {
    if(form.id==='training-admin-update-form'){await adminUpdates.prepare(form);render();return;}
    if(form.dataset.teamForm){await corner.submit(form);render();return;}
    if(form.id==='training-daily-form'){await daily.submit(form);render();focusDaily();return;}
    const data = new FormData(form);
    if (form.id === "training-search-form") {
      librarySearch = data.get("search").trim();
      libraryLevel=data.get('level')||'';
      libraryTopic=data.get('subtopic')||'';
      libraryAcademy=data.get('academy')||'';libraryCourse=data.get('course')||'';
      libraryPath=data.get('path')||'';
      render();
      return;
    }
    if (form.id === "training-quiz-form") {
      answers[quizQuestions[questionIndex].id] = Number(data.get("answer"));
      if (questionIndex < quizQuestions.length - 1) {
        questionIndex++;
        render();
        return;
      }
      const answerPayload = quizQuestions.map((q) => ({ question_id: q.id, option: answers[q.id] }));
      if(challengeMode){
        challengeResult=await rpc('submit_training_challenge',{competition:selectedCompetition,answers:answerPayload,submission:submissionKey});
        await refresh();view='challenge-results';render();notify('Competition challenge saved. Your best score counts.');return;
      }
      const finished = await rpc("submit_training_quiz", { assignment: assignment.id, answers: answerPayload, submission: submissionKey });
      await refresh();
      await showResult(finished, mine().find((a) => a.id === assignment.id));
      notify(finished.passed ? "Course passed. Your points and trophy are saved." : "Quiz saved. Review the explanations before trying again.");
      return;
    }
    if(form.id==='training-competition-form'){
      const event=await rpc('create_training_competition',{store:storeId,course:data.get('course'),competition_name:data.get('name').trim(),starts_on:data.get('start'),ends_on:data.get('end'),prize:data.get('reward').trim(),prize_type:data.get('reward_type'),employee_ids:data.getAll('employee'),department_ids:data.getAll('department'),all_employees:data.get('all')==='yes'});
      selectedCompetition=event.competition_id;await refresh();view='competitions';render();notify(`Competition saved for ${event.participants} ${event.participants === 1 ? "employee" : "employees"}.`);return;
    }
    if(form.id==='training-challenge-unlock-form'){
      await rpc('unlock_training_challenge',{competition:data.get('competition'),member:data.get('member'),support_note:data.get('reason').trim()});await refresh();render();notify('One additional challenge attempt is available.');return;
    }
    if (form.id === "training-assign-form") {
      const count = await rpc("assign_training", { course: data.get("course"), store: storeId, employee_ids: data.getAll("employee"), department_ids: data.getAll("department"), all_employees: data.get("all") === "yes", deadline: data.get("deadline") || null });
      await refresh();
      view = "home";
      render();
      notify(`Training assigned to ${count} ${count === 1 ? "person" : "people"}.`);
    }
    if (form.id === "training-department-form") {
      await rpc("create_training_department", { store: storeId, department_name: data.get("name").trim() });
      await refresh();
      render();
      notify("Department created.");
    }
    if (form.id === "training-membership-form") {
      await rpc("set_training_departments", { member: data.get("member"), departments: data.getAll("department") });
      await refresh();
      render();
      notify("Departments saved.");
    }
    if (form.id === "training-unlock-form") {
      await rpc("unlock_training_retry", { assignment: data.get("assignment"), support_note: data.get("reason").trim() });
      await refresh();
      render();
      notify("One additional quiz attempt is available.");
    }
  }
  document.addEventListener("submit", (e) => {
    if (!active || !root.contains(e.target) || !e.target.id.startsWith("training-")) return;
    e.preventDefault();
    run(() => handleForm(e.target));
  }, { signal: events.signal });
  document.addEventListener('input',e=>{if(active&&view==='team')corner?.input(e.target);if(active&&view==='admin-updates')adminUpdates?.capture(e.target.closest('form'));},{signal:events.signal});
  document.addEventListener("change", (e) => {
    if (!active) return;
    if(view==='team')corner?.input(e.target);
    daily.input(e.target);
    if(view==='admin-updates')adminUpdates?.capture(e.target.closest('form'));
    if(e.target.matches('[data-team-files]')){run(async()=>{await corner.choosePhotos(e.target);render();});return;}
    const picker=e.target.closest('[data-course-picker]');
    if(picker){
      const form=picker.closest('form'),course=picker.querySelector('[name=course]');
      if(e.target.name!=='course')updateCoursePicker(picker,form.id==='training-search-form'?workspace.courses:workspace.courses.filter(c=>c.released));
      if(form.id==='training-competition-form'){selectedCourse=course.value;document.querySelector('#training-competition-recipients').innerHTML=competitionRecipients(workspace,course.value);}
      if(form.id==='training-assign-form')selectedCourse=course.value;
    }
    if(e.target.matches('#training-competition-form input[name=start]'))document.querySelector('#training-competition-form input[name=end]').min=e.target.value;
    if (e.target.id === "training-department-member") document.querySelector("#training-department-options").innerHTML = departmentOptions(workspace.members.find((m) => m.id === e.target.value));
    if (e.target.id === "training-store") run(async () => {
      storeId = e.target.value;librarySearch='';libraryLevel='';libraryTopic='';libraryPath='';libraryAcademy='';libraryCourse='';
      await refresh();
      view = "home";
      render();
    });
    if (e.target.closest("#training-quiz-form") && e.target.name === "answer") answers[quizQuestions[questionIndex].id] = Number(e.target.value);
  }, { signal: events.signal });
  document.addEventListener('keydown',e=>{if(active&&menu&&e.key==='Escape'){menu=false;render();headerButton.focus();}},{signal:events.signal});
  document.addEventListener("click", (e) => {
    if (!active) return;
    if(menu&&e.target.classList.contains('training-menu-shade')){menu=false;render();headerButton.focus();return;}
    const submit = e.target.closest("button");
    if (submit?.form?.id.startsWith("training-") && submit.type === "submit") {
      e.preventDefault();
      if (submit.form.reportValidity()) run(() => handleForm(submit.form));
      return;
    }
    const adminTarget=e.target.closest('[data-admin-update-action]');
    if(adminTarget&&root.contains(adminTarget)){run(async()=>{await adminUpdates.action(adminTarget.dataset.adminUpdateAction,adminTarget.dataset.update);await refresh();render();});return;}
    const dailyTarget=e.target.closest('[data-daily-action]');
    if(dailyTarget&&root.contains(dailyTarget)){
      run(async()=>{
        if(dailyTarget.dataset.dailyAction==='home'){view='home';await refresh();}
        else{await daily.action(dailyTarget.dataset.dailyAction,dailyTarget.dataset.assignment);if(dailyTarget.dataset.dailyAction!=='reload')view='daily';}
        menu=false;render();focusDaily();
      });return;
    }
    const target = e.target.closest("[data-training-action]");
    if (!target) return;
    run(async () => {
      const action = target.dataset.trainingAction;
      if (action === "menu") {
        menu = !menu;
        render();
        return;
      }
      if (action === "accounts") {
        accountMarkup = await onAccounts();
        view = "accounts";
        menu = false;
        render();
        return;
      }
      if (action === "navigate") {
        view = target.dataset.view;
        menu = false;
        await refresh();
        if(view==='team')await loadTeam();
        if(view==='admin-updates')await loadAdminUpdates();
        if(view==='team-support')supportRequests=await rpc('get_team_corner_support_requests',{});
        render();
        return;
      }
      if(action==='clear-library'){librarySearch='';libraryLevel='';libraryTopic='';libraryPath='';libraryAcademy='';libraryCourse='';render();return;}
      if(action==='notifications-refresh'){await refresh();render();return;}
      if(action==='notifications-read-all'||action==='notifications-read'||action==='notifications-open'){
        const item=notifications.items.find(n=>n.id===target.dataset.notification);
        if(action!=='notifications-read-all'&&!item)return;
        await rpc('mark_training_notifications_read',{store:storeId,notification_ids:item?[item.id]:[],mark_all:action==='notifications-read-all'});
        await refresh();
        if(action==='notifications-open'){
          const current=notifications.items.find(n=>n.id===item.id);
          if(!current){view='notifications';render();return;}
          if(current.target_view==='course'){await openCourse(current.course_id);return;}
          selectedCompetition=current.competition_id;view=current.target_view;menu=false;
        }
        render();return;
      }
      if(action==='team-support-open'){
        storeId=target.dataset.store;librarySearch='';libraryLevel='';libraryTopic='';libraryPath='';libraryAcademy='';libraryCourse='';await refresh();await loadTeam();view='team';menu=false;render();return;
      }
      if(action==='team-support-refresh'){supportRequests=await rpc('get_team_corner_support_requests',{});render();return;}
      if(action.startsWith('team-')){await corner.action(target);render();return;}
      if(action==='competition-new'){await refresh();view='competition-new';menu=false;render();return;}
      if(action==='competition-standings'||action==='leaderboard-lifetime'||action==='leaderboard-tab'){
        if(target.dataset.competition)selectedCompetition=target.dataset.competition;
        leaderboardTab=action==='leaderboard-lifetime'?'lifetime':action==='leaderboard-tab'?target.dataset.tab:'competition';
        await refresh();view='leaderboard';render();return;
      }
      if(action==='competition-review'){await openCourse(target.dataset.course,target.dataset.competition);return;}
      if(action==='competition-challenge'){await startChallenge(target.dataset.competition);return;}
      if(action==='competition-finish'){
        if(!window.confirm(target.dataset.state==='scheduled'?'Cancel this scheduled competition? Course assignments will remain available.':'End this competition now? Current scores will become final.'))return;
        await rpc('finish_training_competition',{competition:target.dataset.competition});await refresh();render();notify('Competition closed. History is saved.');return;
      }
      if (action === "starter-departments") {
        await addStarterDepartments();
        return;
      }
      if (action === "assign-course") {
        selectedCourse = target.dataset.course;
        view = "assign";
        render();
        return;
      }
      if (action === "release") {
        await rpc("release_training_course", { store: storeId, course: target.dataset.course, available: target.dataset.available === "true" });
        await refresh();
        render();
        notify(target.dataset.available === "true" ? "Course is available to this store. Assign it when you\u2019re ready." : "Course removed from the library. Existing assignments remain available.");
        return;
      }
      if (action === "open-course") {
        await openCourse(target.dataset.course);
        return;
      }
      if (action === "lesson") {
        lessonIndex = Number(target.dataset.index);
        render();
        return;
      }
      if (action === "review-next") {
        lessonIndex = Math.min(lessonIndex + 1, lessons.length - 1);
        render();
        return;
      }
      if (action === "preview-next") {
        if (lessonIndex === lessons.length - 1) view = "library";
        else lessonIndex++;
        render();
        return;
      }
      if (action === "complete-lesson") {
        const last = lessonIndex === lessons.length - 1;
        await rpc("complete_training_lesson", { assignment: assignment.id, lesson: lessons[lessonIndex].id });
        await refresh();
        await openCourse(selectedCourse);
        if (last) await startQuiz();
        return;
      }
      if (action === "start-quiz") {
        await startQuiz();
        return;
      }
      if (action === "quiz-back") {
        questionIndex = Math.max(0, questionIndex - 1);
        render();
        return;
      }
      if (action === "latest-result") {
        const a = mine().find((a2) => a2.id === target.dataset.assignment);
        await showResult(a.latest_attempt, a);
      }
    });
  }, { signal: events.signal });
  function close() {
    if (!active) return;
    active = false;
    timer.close();
    daily.close();
    adminUpdates?.close();
    corner?.close();
    events.abort();
    headerButton.remove();
    root.classList.remove("training-main");
    setAccountHeader();
  }
  try {
    await refresh();
    if(view==='daily')await daily.resume();
    if(view==='admin-updates')await loadAdminUpdates();
    if (view === "accounts") accountMarkup = await onAccounts();
    if (view === "team") await loadTeam();
    if (view === "team-support") supportRequests=await rpc('get_team_corner_support_requests',{});
    render();
  } catch (e) {
    close();
    throw e;
  }
  return { close };
}
export {
  mountTraining
};
