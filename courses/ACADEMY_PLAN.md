# Approved academy plan

Version 3.0 supersedes the previous eight-academy grouping. Machine-readable source: `academy-plan.json`. Existing 25 launch-course codes, titles, content, IDs, and six learning paths remain unchanged. All 25 existing courses remain Foundations. The 260-module plan does not create 260 full courses or Daily lessons and does not change completion credit.

| Academy | Foundations | Application | Expertise | Planned total | Existing full courses |
| --- | ---: | ---: | ---: | ---: | --- |
| Paint & Surface Care | 10 | 14 | 8 | 32 | PD-101, PD-102, PD-103 |
| Plumbing | 10 | 14 | 8 | 32 | HB-102 |
| Electrical | 8 | 10 | 6 | 24 | HB-101 |
| HVAC | 6 | 8 | 4 | 18 | HB-103 |
| Hand Tools & Fasteners | 8 | 10 | 4 | 22 | HT-101, HT-102 |
| Power Tools & Accessories | 10 | 12 | 6 | 28 | HT-103 |
| Lawn, Garden & Outdoor Equipment | 10 | 14 | 8 | 32 | LG-101, LG-102 |
| Building & Home Maintenance | 10 | 12 | 6 | 28 | HB-104 |
| Customer Service & Retail Readiness | 8 | 10 | 6 | 24 | RF-101, RF-102, RF-104, CS-101, CS-102, CS-103 |
| Operations & Leadership | 8 | 8 | 4 | 20 | IM-101, IM-102, IM-103, BL-101, BL-102, BL-103 |
| **Total planned** | **88** | **112** | **60** | **260** | **24 mapped; RF-103 pending** |

## Mapping review

RF-103 Store Safety Fundamentals spans retail readiness and operations. It keeps its current category and remains available under existing permissions until the owner chooses an academy. Store-specific courses with no explicit mapping keep their current category; no title-based guesses. The original customer-trust sample maps to Customer Service & Retail Readiness without merging it with CS-101.

RF onboarding courses map to Customer Service & Retail Readiness; inventory, merchandising and loss prevention map to Operations & Leadership. HB-101 electrical, HB-102 plumbing, HB-103 HVAC and HB-104 building materials are split individually. HT-101 and HT-102 stay together; HT-103 moves to Power Tools & Accessories.

## Boundaries and levels

Foundations: recognize products, understand terminology and explain basic uses. Application: recommend solutions, assemble complete project purchases and demonstrate skills in customer scenarios. Expertise: troubleshoot complex situations, evaluate tradeoffs, recognize referral boundaries and coach others. Expertise is not a trade license or professional certification.

HVAC means Heating, Ventilation & Air Conditioning: retail product knowledge for heating, cooling, ventilation, filters, thermostats and maintenance needs. Power Tools & Accessories includes portable and benchtop tools, batteries, chargers, blades, bits, abrasives and compatible attachments. Mowers, chainsaws, trimmers and similar equipment stay in Lawn, Garden & Outdoor Equipment.

All future content must be independently authored. No NHPA content, assessments, images or proprietary curriculum structure were imported or reviewed for this update. The supplied folder summary is unverified reference material.

## Release

This is a website/configuration update; no Supabase migration or reimport is required. Academy labels are resolved from stable codes, while immutable database categories and original source packages are preserved. Legacy category text remains searchable, but mapped academy labels replace it in card badges and academy filter options. Existing access rules still determine which courses and filter options each account sees.

Admins can expand the academy plan in Course library. Its planned module counts are separate from actual visible course results and completed-course totals on Home. No employee progress is divided by 260. Daily scheduling/completions are not implemented by this change.

Prepared locally; not deployed. Batch `design/coltrain-website.zip` with the next Netlify release. Do not rerun SETUP.sql or course imports.

## Validation

Nine library/configuration tests passed, including exact allocation totals, full 25-code mapping coverage (24 mapped plus one pending), split-academy filtering, legacy keyword search and unchanged source objects. The full Chromium training/Team Corner integration suite passed against isolated PostgreSQL/RLS, including admin planning display, real HVAC course filtering, mobile cards, lesson/quiz/award persistence and competition retries. PWA/package checks passed. Hosted deployment remains pending.
