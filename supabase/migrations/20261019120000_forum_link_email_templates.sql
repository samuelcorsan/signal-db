-- ============================================================================
-- EXPONENTIAL FORUM LINK IN EMAIL TEMPLATES
--
-- news.goexponential.org launched as a public forum open to everyone. Point
-- acceptance-track emails (and two rejection templates where we want to keep
-- rejected applicants connected to the broader community) at it, folded in
-- alongside the existing WhatsApp group mentions. Left untouched: Second
-- Interview, Launchpad Welcome, Referral, and "Congrats on the progress" —
-- by those stages candidates already got the link earlier in the funnel.
-- Text can still be edited from Settings like the others.
-- ============================================================================

BEGIN;

UPDATE public.email_templates
SET body = E'Hi {candidate_name},\n\nTL;DR: We''d love to meet you!\n\nWe''ve taken a look at your profile and we''d love to get to know you a bit better.\n\nPlease let us know your availability in the coming days. Ideal slots are 10:00 and 19:00 CET. Do your homework!\n\nIn the meantime, make sure to join both our [WhatsApp group](https://chat.whatsapp.com/E7HWX6GTKsMHClE4nCjprU) and the [Exponential Forum](https://news.goexponential.org/) — great places to connect with the community and see what others are building.\n\nBest,\n'
WHERE action_key = 'fellowship_invite';

UPDATE public.email_templates
SET body = E'Hi {first_name},\n\nCongrats! We''re excited to welcome you to the Exponential Community.\n\nJoin both our [WhatsApp Group](https://chat.whatsapp.com/E7HWX6GTKsMHClE4nCjprU) and the [Exponential Forum](https://news.goexponential.org/) to access all community benefits including:\n- Networking opportunities with fellow members\n- Priority invitations to events and workshops\n- Direct access to startup opportunities\n\nExcited to see you around,\n\nThe Exponential Team'
WHERE action_key = 'community_invite';

UPDATE public.email_templates
SET body = E'Hi {candidate_name},\n\nFirst of all – welcome to Exponential! We''d love to formally invite you to join three initiatives:\n1. The Exponential [Whatsapp Group](https://chat.whatsapp.com/E7HWX6GTKsMHClE4nCjprU). Here you''ll find like minded peers to share learnings and be up to date on the startup and tech scene.\n2. The [Exponential Forum](https://news.goexponential.org/), open to everyone — join in and see what other builders are working on.\n3. Opt-in to the Launchpad program. Launchpad help top candidates land jobs in the best startups in Spain and Europe to learn from top operators locally before jumping to the US leagues. Click [here]({url}/launchpad/opt-in?id={candidate_id}) to opt-in.\n\nExcited to see you around,'
WHERE action_key = 'launchpad_invite';

UPDATE public.email_templates
SET body = E'Hi {candidate_name},\n\nTL;DR: We''d love to meet you!\n\nWe''ve taken a look at your profile and we''d love to get to know you a bit better.\n\nPlease let us know your availability in the coming days. Do your homework!\n\nIn the meantime, if you haven''t already, click [here]({url}/launchpad/opt-in?id={candidate_id}) to opt-in to the Launchpad program. Once you do, you''ll receive an email with instructions on next steps. Also, make sure to join the [Exponential Forum](https://news.goexponential.org/), open to everyone in the community.\n\nBest,\n'
WHERE action_key = 'launchpad_invite_interview';

UPDATE public.email_templates
SET body = E'Hi {candidate_name},\n\nGreat news – we''d love to invite you to join the Launchpad program! Launchpad helps top candidates land jobs in the best startups in Spain and Europe to learn from top operators locally before jumping to the US leagues.\n\nClick [here]({url}/launchpad/opt-in?id={candidate_id}) to opt-in.\n\nOnce you do, you''ll receive an email with instructions on next steps.\n\nIn the meantime, feel free to join both our [Whatsapp Group](https://chat.whatsapp.com/E7HWX6GTKsMHClE4nCjprU) and the [Exponential Forum](https://news.goexponential.org/) to connect with like-minded peers and stay up to date on the startup and tech scene.\n\nExcited to have you on board,'
WHERE name = 'Launchpad Opt-in' AND action_key IS NULL;

UPDATE public.email_templates
SET body = E'Dear {candidate_name},\n\nThanks for your time applying to Exponential. Unfortunately, we cannot continue with your application at this time. Don''t doubt yourself though – Exponential is a highly selective program with a very low acceptance rate, and we turn down many strong applicants every cycle.\n\nWhile we cannot give additional feedback at this time, we''d encourage you to keep building your public profile: ship projects, share what you''re working on, and make your work easy to find. Then apply again in the near future – we''d love to take another look.\n\nWe''d also love to stay connected — join the [Exponential Forum](https://news.goexponential.org/), open to everyone, and take part in the conversation.\n\nBest,'
WHERE action_key = 'archive_generic';

UPDATE public.email_templates
SET body = E'Dear {candidate_name},\n\nThanks for your time applying to Exponential. Exponential is built for builders at the very start of their careers, and based on your experience we don''t think we''re the right fit for where you are today.\n\nWe''re sure you''ll keep building great things, and we''d love to stay in touch — join the [Exponential Forum](https://news.goexponential.org/), open to everyone, and take part in the conversation.\n\nBest,'
WHERE action_key = 'archive_too_old';

COMMIT;
