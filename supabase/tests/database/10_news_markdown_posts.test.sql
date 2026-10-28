-- A post's text is markdown, saved as the HTML News renders it
-- (news.safe_post_html); comments and abouts keep news.safe_html.
begin;
create extension if not exists pgtap with schema extensions;

create schema tests;
grant usage on schema tests to anon, authenticated;

create function tests.as_user(p_id uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', jsonb_build_object('sub', p_id, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
end $$;

create function tests.as_postgres() returns void language plpgsql as $$
begin
  perform set_config('role', 'none', true);
  perform set_config('request.jwt.claims', '', true);
end $$;

create function tests.new_user(p_email text, p_username text) returns uuid language plpgsql as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, recovery_token, email_change_token_new, email_change,
    email_change_token_current, phone_change, phone_change_token, reauthentication_token)
  values ('00000000-0000-0000-0000-000000000000', v_id, 'authenticated', 'authenticated', p_email, '', now(),
          '{"provider": "email", "providers": ["email"]}', '{"signup_app": "news"}', now(), now(),
          '', '', '', '', '', '', '', '');
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_id, 'role', 'authenticated')::text, true);
  -- News is by invitation (20261028130000_news_invites.sql): let the address in.
  insert into news_private.allowed_emails (email) values (lower(p_email)) on conflict do nothing;
  perform news.claim_profile(p_username);
  perform set_config('request.jwt.claims', '', true);
  return v_id;
end $$;

create function tests.item(p_title text) returns bigint language sql stable as $$
  select id from news.items where title = p_title order by id desc limit 1
$$;

create temp table u as select tests.new_user('m_alice@news.test', 'm_alice') as id;
grant select on u to anon, authenticated;

-- What News renders for a post using every piece of markdown it knows.
create temp table rich as select
  E'<h2>Why</h2>\n<p>We <strong>cut</strong> the bill with <em>one</em> trick and <code>code</code>, <s>not two</s>. ' ||
  'See <a href="https://blog.example/a?b=1&amp;c=2" rel="nofollow">the post</a> or ' ||
  E'<a href="https://example.com" rel="nofollow">https://example.com</a>.</p>\n<blockquote>\n<p>Quoted</p>\n</blockquote>\n' ||
  E'<ul>\n<li>a</li>\n<li>b\n<ol>\n<li>nested</li>\n</ol>\n</li>\n</ul>\n<ol start="3">\n<li>three</li>\n</ol>\n' ||
  E'<pre><code>select 1 &lt; 2;\n</code></pre>\n<table>\n<thead>\n<tr>\n<th>a</th>\n<th>b</th>\n</tr>\n</thead>\n' ||
  E'<tbody>\n<tr>\n<td>1</td>\n<td>2</td>\n</tr>\n</tbody>\n</table>\n<p>Line<br>\nbreak</p>\n<hr>\n<h4>Smaller</h4>'
  as html;
grant select on rich to anon, authenticated;

select plan(14);

select tests.as_user((select id from u));

-- ----------------------------------------------------------------------------
-- A post holds what markdown renders to, and nothing else
-- ----------------------------------------------------------------------------

select lives_ok($$select news.submit_story('', 'Rich post', (select html from rich))$$, 'a post holds rendered markdown');
select lives_ok($$select news.submit_story('', 'Arc post', 'First<p>Second <i>it</i><p><pre><code>  x</code></pre>')$$,
                'a post saved the old way still passes');
select throws_ok($$select news.submit_story('', 'Bad 1', '<p>a</p><script>alert(1)</script>')$$, '23514', null, 'no script');
select throws_ok($$select news.submit_story('', 'Bad 2', '<a href="javascript:alert(1)" rel="nofollow">a</a>')$$, '23514', null,
                 'no javascript: link');
select throws_ok($$select news.submit_story('', 'Bad 3', '<a href="https://a.example" onclick="x" rel="nofollow">a</a>')$$, '23514', null,
                 'no handler on a link');
select throws_ok($$select news.submit_story('', 'Bad 4', '<img src="https://a.example/a.png">')$$, '23514', null, 'no image');
select throws_ok($$select news.submit_story('', 'Bad 5', '<h1>a</h1>')$$, '23514', null, 'no h1: the title is the page''s');
select throws_ok($$select news.submit_story('', 'Bad 6', '<p style="color:red">a</p>')$$, '23514', null, 'no attributes');
select throws_ok($$select news.submit_story('', 'Bad 7', '<ol start="1" onclick="x">')$$, '23514', null, 'an ol takes start alone');

-- Editing a post is held to the same.
select lives_ok($$select news.edit_item(tests.item('Arc post'), jsonb_build_object('text', (select html from rich)))$$,
                'an edited post holds rendered markdown');
select throws_ok($$select news.edit_item(tests.item('Arc post'), '{"text": "<script>x</script>"}')$$, '23514', null,
                 'and nothing else');

-- ----------------------------------------------------------------------------
-- Comments and abouts keep news.safe_html
-- ----------------------------------------------------------------------------

select lives_ok($$select news.post_comment(tests.item('Rich post'), 'A <i>plain</i> comment<p>in two paragraphs')$$,
                'a comment in Arc''s way');
select throws_ok($$select news.post_comment(tests.item('Rich post'), '<h2>A heading</h2>')$$, '23514', null,
                 'a comment can''t hold markdown''s HTML');
select throws_ok($$select news.update_profile((select id from u), '{"about": "<strong>me</strong>"}')$$, '23514', null,
                 'nor can an about');

select tests.as_postgres();
select * from finish();
rollback;
