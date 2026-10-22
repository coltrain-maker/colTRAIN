const esc=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const count=value=>Number.isFinite(Number(value))?Math.max(0,Number(value)):0;
export function pointValues(totals={}){
 const daily=count(totals.daily_points);
 const lifetime=totals.lifetime_points??totals.points;
 const course=count(totals.course_points??Math.max(0,count(lifetime)-daily));
 // Use the server's overall total so future earning sources remain part of lifetime points.
 return {course,daily,lifetime:lifetime==null?course+daily:count(lifetime)};
}
export const pointHeaders=()=>'<th>Course points</th><th>Daily Drill points</th><th>Lifetime points</th>';
export function pointCells(totals){const p=pointValues(totals);return `<td>${p.course}</td><td>${p.daily}</td><td>${p.lifetime}</td>`;}
export function pointSummary(totals,{label='Your points',prefix=''}={}){
 const p=pointValues(totals);
 return `<div class="point-summary" role="group" aria-label="${esc(label)}"><div><strong>${p.course}</strong><span>${esc(prefix)}Course points</span></div><div><strong>${p.daily}</strong><span>${esc(prefix)}Daily Drill points</span></div><div><strong>${p.lifetime}</strong><span>${esc(prefix)}Lifetime points</span></div></div>`;
}
