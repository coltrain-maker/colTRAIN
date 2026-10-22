import test from 'node:test';
import assert from 'node:assert/strict';
import {pointValues,pointHeaders,pointCells,pointSummary} from '../accounts/points.js';
test('course and Daily points remain separate, including future earning sources in server lifetime totals',()=>{
 assert.deepEqual(pointValues({course_points:40,daily_points:15,lifetime_points:55}),{course:40,daily:15,lifetime:55});
 assert.deepEqual(pointValues({course_points:40,daily_points:15,lifetime_points:65}),{course:40,daily:15,lifetime:65});
 assert.deepEqual(pointValues({points:55,daily_points:15}),{course:40,daily:15,lifetime:55});
 assert.deepEqual(pointValues({course_points:40,daily_points:15}),{course:40,daily:15,lifetime:55});
});
test('every reusable point display uses course, Daily, lifetime column order and escapes context labels',()=>{
 assert.equal(pointHeaders(),'<th>Course points</th><th>Daily Drill points</th><th>Lifetime points</th>');
 assert.equal(pointCells({course_points:40,daily_points:15,lifetime_points:55}),'<td>40</td><td>15</td><td>55</td>');
 const html=pointSummary({course_points:40,daily_points:15,lifetime_points:55},{label:'Team "points"',prefix:'<Team> '});
 assert.ok(html.indexOf('Course points')<html.indexOf('Daily Drill points')&&html.indexOf('Daily Drill points')<html.indexOf('Lifetime points'));
 assert.match(html,/Team &quot;points&quot;/);assert.match(html,/&lt;Team&gt;/);assert.ok(!html.includes('<Team>'));
});
