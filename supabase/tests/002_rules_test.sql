-- =====================================================================
-- supabase/tests/002_rules_test.sql
-- LOCAL TEST ONLY. Do not run this file on Supabase.
--
-- It builds an empty PostgreSQL 16 database with a small stand-in for
-- Supabase's auth schema, applies 002_final_schema.sql, and checks the
-- rules. Run from the repository root against an EMPTY database:
--
--   psql -X -v ON_ERROR_STOP=1 -d <empty_db> -f supabase/tests/002_rules_test.sql
--
-- Each check prints "pass: ..." (or "pass (blocked): ..."). The first
-- failure stops the run with "FAILED: ...". Query references (MQ-0001 ...)
-- assume the reference sequence starts at 1, so run on a fresh database.
-- =====================================================================
\set ON_ERROR_STOP on

-- ---------------------------------------------------------------------
-- 0. Stand-in for Supabase auth (auth.users, auth.uid())
-- ---------------------------------------------------------------------
create schema if not exists auth;

create table auth.users (
  id uuid primary key,
  email text,
  raw_user_meta_data jsonb not null default '{}'::jsonb
);

create function auth.uid() returns uuid
language sql stable
as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;

do $$
begin
  create role anon nologin;
  create role authenticated nologin;
  create role service_role nologin bypassrls;
exception when duplicate_object then
  null;
end $$;

grant usage on schema auth to anon, authenticated, service_role;
grant execute on function auth.uid() to anon, authenticated, service_role;

-- ---------------------------------------------------------------------
-- 1. Apply the migration under test
-- ---------------------------------------------------------------------
\echo '== applying 002_final_schema.sql =='
\i supabase/migrations/002_final_schema.sql

-- ---------------------------------------------------------------------
-- 2. Test helpers (schema tst, dropped at the end)
-- ---------------------------------------------------------------------
create schema tst;
grant usage on schema tst to public;

create function tst.assert(p_ok boolean, p_label text) returns void
language plpgsql as $$
begin
  if p_ok is not true then
    raise exception 'FAILED: %', p_label;
  end if;
  raise notice 'pass: %', p_label;
end $$;

create function tst.expect_fail(p_sql text, p_label text) returns void
language plpgsql as $$
declare
  v_blocked boolean := false;
begin
  begin
    execute p_sql;
  exception when others then
    v_blocked := true;
    raise notice 'pass (blocked): % -- %', p_label, sqlerrm;
  end;
  if not v_blocked then
    raise exception 'FAILED (was allowed): %', p_label;
  end if;
end $$;

create function tst.as_user(p_user uuid, p_role text) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_user::text, ''), false);
  execute format('set role %I', p_role);
end $$;

-- Lookups run as the owner, so they see every row whoever asks.
create function tst.q(p_ref text) returns uuid
language sql stable security definer set search_path = ''
as $$ select q.id from public.queries q where q.reference = p_ref $$;

create function tst.inst(p_name text) returns uuid
language sql stable security definer set search_path = ''
as $$ select i.id from public.institutions i where i.name = p_name $$;

create function tst.cat(p_name text) returns uuid
language sql stable security definer set search_path = ''
as $$ select c.id from public.categories c where c.name = p_name $$;

-- Fixed ids used below
--   admin      00000000-0000-0000-0000-0000000000a1
--   coord1     00000000-0000-0000-0000-0000000000c1
--   coord2     00000000-0000-0000-0000-0000000000c2
--   rep1       00000000-0000-0000-0000-0000000000e1
--   inactive   00000000-0000-0000-0000-0000000000f1
--   student01  10000000-0000-0000-0000-000000000001
--   student02  10000000-0000-0000-0000-000000000002

-- ---------------------------------------------------------------------
-- 3. Seed: users, roles, rules, students (as the owner)
-- ---------------------------------------------------------------------
\echo '== 3. seed =='
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000a1', 'admin@test.local',    '{"full_name":"Test Admin"}'),
  ('00000000-0000-0000-0000-0000000000c1', 'coord1@test.local',   '{}'),
  ('00000000-0000-0000-0000-0000000000c2', 'coord2@test.local',   '{}'),
  ('00000000-0000-0000-0000-0000000000e1', 'rep1@test.local',     '{}'),
  ('00000000-0000-0000-0000-0000000000f1', 'inactive@test.local', '{}');

update public.profiles set role = 'admin', active = true, name = 'Test Admin'
 where email = 'admin@test.local';
update public.profiles set role = 'coordinator', active = true,
       last_assigned_at = now() - interval '1 day'
 where email = 'coord1@test.local';
update public.profiles set role = 'coordinator', active = true
 where email = 'coord2@test.local';
update public.profiles set role = 'rep', active = true
 where email = 'rep1@test.local';

update public.app_settings
   set escalation_recipient_id = (select id from public.profiles where email = 'admin@test.local')
 where id = 1;

insert into public.assignment_rules (position, category_id) values
  (1, (select id from public.categories where name = 'Technical')),
  (2, (select id from public.categories where name = 'Scholarship'));

insert into public.rule_coordinators (rule_id, profile_id)
select r.id, p.id
  from public.assignment_rules r
  join public.profiles p on p.email in ('coord1@test.local', 'coord2@test.local')
 where r.position = 1;

insert into public.rule_coordinators (rule_id, profile_id)
select r.id, p.id
  from public.assignment_rules r
  join public.profiles p on p.email = 'coord2@test.local'
 where r.position = 2;

insert into public.students (id, name, institution_id, email, phone)
select '10000000-0000-0000-0000-000000000001', 'Dummy Student 01', i.id, 'dummy01@example.test', null
  from public.institutions i where i.name = 'Demo Institute of Technology';

insert into public.students (id, name, institution_id, email, phone)
select '10000000-0000-0000-0000-000000000002', 'Dummy Student 02', i.id, 'dummy02@example.test', '0000000000'
  from public.institutions i where i.name = 'Demo Institute of Technology';

do $$
begin
  perform tst.assert((select count(*) from public.profiles) = 5, 'five profiles created by the sign-up trigger');
  perform tst.assert((select active from public.profiles where email = 'inactive@test.local') = false,
                     'a new sign-in starts inactive');
end $$;

-- ---------------------------------------------------------------------
-- 4. Representative logs queries: routing and timers
-- ---------------------------------------------------------------------
\echo '== 4. logging and routing (representative) =='
select tst.as_user('00000000-0000-0000-0000-0000000000e1', 'authenticated');

do $$
declare
  v_inst uuid := tst.inst('Demo Institute of Technology');
  v_tech uuid := tst.cat('Technical');
  v_other uuid := tst.cat('Other');
  v_scho uuid := tst.cat('Scholarship');
begin
  -- MQ-0001: Technical, normal. Coordinator 2 has never been assigned, so it goes first.
  perform public.log_query('10000000-0000-0000-0000-000000000001', v_inst, v_tech,
                           'whatsapp', 'normal', 'Dummy query one: portal login');
  -- MQ-0002: Technical, urgent. Coordinator 2 now has one open query, so coordinator 1 gets this one.
  perform public.log_query('10000000-0000-0000-0000-000000000002', v_inst, v_tech,
                           'phone', 'urgent', 'Dummy query two: fee receipt');
  -- MQ-0003: Other. No rule matches, so it stays New and goes to the admins.
  perform public.log_query('10000000-0000-0000-0000-000000000001', v_inst, v_other,
                           'email', 'low', 'Dummy query three: general');
  -- MQ-0004: Scholarship. Rule 2 names coordinator 2 only.
  perform public.log_query('10000000-0000-0000-0000-000000000001', v_inst, v_scho,
                           'form', 'high', 'Dummy query four: scholarship form');

  perform tst.assert((select count(*) from public.queries) = 4,
                     'representative sees the four queries it logged');

  perform tst.assert(
    (select status from public.queries where reference = 'MQ-0001') = 'assigned'
    and (select assigned_to from public.queries where reference = 'MQ-0001')
        = '00000000-0000-0000-0000-0000000000c2',
    'MQ-0001 routed to coordinator 2 (never assigned before, so it goes first)');

  perform tst.assert(
    (select assigned_to from public.queries where reference = 'MQ-0002')
        = '00000000-0000-0000-0000-0000000000c1',
    'MQ-0002 routed to coordinator 1 (fewer open queries)');

  perform tst.assert(
    extract(epoch from ((select resolve_by from public.queries where reference = 'MQ-0002')
                      - (select created_at from public.queries where reference = 'MQ-0002'))) / 60 = 1440,
    'urgent query: resolve-by is 1440 minutes after logging');

  perform tst.assert(
    extract(epoch from ((select resolve_by from public.queries where reference = 'MQ-0001')
                      - (select created_at from public.queries where reference = 'MQ-0001'))) / 60 = 4320,
    'normal query: resolve-by is 4320 minutes after logging');

  perform tst.assert(
    (select status from public.queries where reference = 'MQ-0003') = 'new'
    and (select assigned_to from public.queries where reference = 'MQ-0003') is null,
    'query with no matching rule stays New and unassigned');

  perform tst.assert(
    (select assigned_to from public.queries where reference = 'MQ-0004')
        = '00000000-0000-0000-0000-0000000000c2',
    'Scholarship query routed to coordinator 2 by rule 2');

  -- Representatives may add students.
  insert into public.students (name, institution_id, email)
  values ('Dummy Student 03', v_inst, 'dummy03@example.test');
  perform tst.assert((select count(*) from public.students) = 3,
                     'representative can add a student');
end $$;

-- ---------------------------------------------------------------------
-- 5. Access limits for the representative
-- ---------------------------------------------------------------------
\echo '== 5. representative limits =='
select tst.expect_fail($x$
  select public.assign_query(tst.q('MQ-0003'), '00000000-0000-0000-0000-0000000000c1', 'nope')
$x$, 'representative cannot assign queries');

select tst.expect_fail($x$ select email from public.students $x$,
                       'representative cannot read student email');

select tst.expect_fail($x$
  update public.queries set status = 'closed' where reference = 'MQ-0001'
$x$, 'representative cannot update queries directly');

select tst.expect_fail($x$
  insert into public.institutions (name) values ('Rogue College')
$x$, 'representative cannot add institutions');

-- ---------------------------------------------------------------------
-- 6. Inactive account cannot log (regression: NULL role check)
-- ---------------------------------------------------------------------
\echo '== 6. inactive account =='
select tst.as_user('00000000-0000-0000-0000-0000000000f1', 'authenticated');

select tst.expect_fail($x$
  select public.log_query('10000000-0000-0000-0000-000000000001', tst.inst('Demo Institute of Technology'),
                          tst.cat('Other'), 'form', 'low', 'Dummy from an inactive account')
$x$, 'inactive account cannot log a query');

-- ---------------------------------------------------------------------
-- 7. Coordinator 1 sees and acts only on its own queries
-- ---------------------------------------------------------------------
\echo '== 7. coordinator 1 limits =='
select tst.as_user('00000000-0000-0000-0000-0000000000c1', 'authenticated');

do $$
declare
  v_n integer;
begin
  perform tst.assert((select count(*) from public.queries where reference = 'MQ-0001') = 0,
                     'coordinator 1 cannot see MQ-0001 (owned by coordinator 2)');
  perform tst.assert((select count(*) from public.queries where reference = 'MQ-0002') = 1,
                     'coordinator 1 sees its own MQ-0002');

  update public.profiles set role = 'admin' where id = auth.uid();
  get diagnostics v_n = row_count;
  perform tst.assert(v_n = 0, 'coordinator cannot promote itself (no rows updated)');
end $$;

select tst.expect_fail($x$
  select public.change_status(tst.q('MQ-0001'), 'in_progress', null)
$x$, 'coordinator 1 cannot move MQ-0001');

select tst.expect_fail($x$
  select public.assign_query(tst.q('MQ-0002'), '00000000-0000-0000-0000-0000000000c2', 'nope')
$x$, 'coordinator cannot assign queries');

-- ---------------------------------------------------------------------
-- 8. Status flow for MQ-0001 (coordinator 2)
-- ---------------------------------------------------------------------
\echo '== 8. status flow MQ-0001 (coordinator 2) =='
select tst.as_user('00000000-0000-0000-0000-0000000000c2', 'authenticated');

select tst.expect_fail($x$
  select public.change_status(tst.q('MQ-0001'), 'waiting_for_student', null)
$x$, 'waiting is set only through ask_student');

select tst.expect_fail($x$
  select public.change_status(tst.q('MQ-0001'), 'closed', null)
$x$, 'assigned cannot jump straight to closed');

select public.change_status(tst.q('MQ-0001'), 'in_progress', null);

select tst.expect_fail($x$
  select public.change_status(tst.q('MQ-0001'), 'resolved', '   ')
$x$, 'resolving needs a closing message');

select tst.expect_fail($x$
  select public.change_status(tst.q('MQ-0001'), 'closed', null)
$x$, 'in progress cannot jump straight to closed');

select tst.expect_fail($x$
  select public.ask_student(tst.q('MQ-0001'), '   ')
$x$, 'a question for the student is required');

select public.ask_student(tst.q('MQ-0001'), 'Please send your fee receipt');

do $$
begin
  perform tst.assert((select status from public.queries where reference = 'MQ-0001') = 'waiting_for_student',
                     'ask_student sets Waiting for student');
  perform tst.assert((select waiting_since from public.queries where reference = 'MQ-0001') is not null,
                     'waiting_since is set while waiting');
end $$;

select tst.expect_fail($x$
  select public.change_status(tst.q('MQ-0001'), 'resolved', 'x')
$x$, 'cannot resolve while waiting for the student');

-- Simulate two hours of waiting (superuser), then the student replies.
select tst.as_user(null, 'postgres');
update public.queries set waiting_since = now() - interval '2 hours'
 where reference = 'MQ-0001';

select tst.as_user('00000000-0000-0000-0000-0000000000c2', 'authenticated');
do $$
declare
  v_before timestamptz;
  v_after record;
begin
  select resolve_by into v_before from public.queries where reference = 'MQ-0001';

  perform public.record_student_reply(tst.q('MQ-0001'), 'Receipt uploaded by the student');

  select status, waiting_since, total_waiting_seconds, resolve_by, nudged_at
    into v_after
    from public.queries where reference = 'MQ-0001';

  perform tst.assert(v_after.status = 'in_progress' and v_after.waiting_since is null,
                     'a reply returns the query to In progress');
  perform tst.assert(v_after.total_waiting_seconds >= 7200,
                     'waiting time is added to the query (at least two hours)');
  perform tst.assert(
    extract(epoch from (v_after.resolve_by - v_before))::integer = v_after.total_waiting_seconds,
    'resolve-by moves by exactly the waiting time');
  perform tst.assert(v_after.nudged_at is null, 'nudge flag is cleared on update');
end $$;

select tst.expect_fail($x$
  select public.record_student_reply(tst.q('MQ-0001'), 'again')
$x$, 'a reply needs a waiting query');

select public.change_status(tst.q('MQ-0001'), 'resolved',
                            'Receipt checked; closing with the student');

select tst.expect_fail($x$
  select public.change_status(tst.q('MQ-0001'), 'in_progress', null)
$x$, 'resolved cannot go back to in progress');

select public.change_status(tst.q('MQ-0001'), 'closed', null);

select tst.expect_fail($x$
  select public.change_status(tst.q('MQ-0001'), 'in_progress', null)
$x$, 'closed is final');

do $$
begin
  perform tst.assert((select status from public.queries where reference = 'MQ-0001') = 'closed'
                     and (select closed_at from public.queries where reference = 'MQ-0001') is not null,
                     'MQ-0001 closed with closed_at set');
end $$;

-- ---------------------------------------------------------------------
-- 9. Admin assigns an unrouted query; reassignment rules
-- ---------------------------------------------------------------------
\echo '== 9. admin assignment =='
select tst.as_user('00000000-0000-0000-0000-0000000000a1', 'authenticated');

select tst.expect_fail($x$
  select public.assign_query(tst.q('MQ-0001'), '00000000-0000-0000-0000-0000000000c1', 'late')
$x$, 'a closed query cannot be assigned');

select public.assign_query(tst.q('MQ-0003'), '00000000-0000-0000-0000-0000000000c1', null);

select tst.expect_fail($x$
  select public.assign_query(tst.q('MQ-0003'), '00000000-0000-0000-0000-0000000000c2', null)
$x$, 'reassignment needs a reason');

select tst.expect_fail($x$
  select public.assign_query(tst.q('MQ-0003'), '00000000-0000-0000-0000-0000000000e1', 'Rebalance')
$x$, 'only an active coordinator can be assigned');

select tst.expect_fail($x$
  select public.assign_query(tst.q('MQ-0003'), '00000000-0000-0000-0000-0000000000c1', 'Rebalance')
$x$, 'a query cannot be reassigned to its current owner');

select public.assign_query(tst.q('MQ-0003'), '00000000-0000-0000-0000-0000000000c2', 'Rebalancing load');

do $$
begin
  perform tst.assert((select status from public.queries where reference = 'MQ-0003') = 'assigned'
                     and (select assigned_to from public.queries where reference = 'MQ-0003')
                         = '00000000-0000-0000-0000-0000000000c2',
                     'MQ-0003 is Assigned to coordinator 2 after reassignment');
  perform tst.assert((select count(*) from public.query_events
                       where query_id = tst.q('MQ-0003') and type = 'reassigned') = 1,
                     'reassignment is written to the history');
end $$;

-- Coordinator 2 takes MQ-0003 into progress.
select tst.as_user('00000000-0000-0000-0000-0000000000c2', 'authenticated');
select public.change_status(tst.q('MQ-0003'), 'in_progress', null);

-- ---------------------------------------------------------------------
-- 10. Attachments (at most three; pdf, jpg, png, docx; path under the query id)
-- ---------------------------------------------------------------------
\echo '== 10. attachments =='
select tst.expect_fail($x$
  select public.add_attachment(tst.q('MQ-0003'), 'wrong/prefix.pdf', 'a.pdf', 'pdf', 1000)
$x$, 'attachment path must start with the query id');

select tst.expect_fail($x$
  select public.add_attachment(tst.q('MQ-0003'), tst.q('MQ-0003')::text || '/a.exe', 'a.exe', 'exe', 1000)
$x$, 'only pdf, jpg, png and docx are accepted');

select tst.expect_fail($x$
  select public.add_attachment(tst.q('MQ-0003'), tst.q('MQ-0003')::text || '/big.pdf', 'big.pdf', 'pdf', 10485761)
$x$, 'attachment size is capped at 10 MB');

do $$
declare
  v_q uuid := tst.q('MQ-0003');
begin
  perform public.add_attachment(v_q, v_q::text || '/referral.pdf', 'referral.pdf', 'pdf', 120000);
  perform public.add_attachment(v_q, v_q::text || '/id-proof.jpg', 'id-proof.jpg', 'JPG', 80000);
  perform public.add_attachment(v_q, v_q::text || '/letter.docx', 'letter.docx', 'docx', 60000);
  perform tst.assert((select count(*) from public.attachments where query_id = v_q) = 3,
                     'three attachments stored, with the file type lower-cased');
end $$;

select tst.expect_fail($x$
  select public.add_attachment(tst.q('MQ-0003'), tst.q('MQ-0003')::text || '/fourth.pdf', 'fourth.pdf', 'pdf', 1000)
$x$, 'a fourth attachment is refused');

select tst.as_user('00000000-0000-0000-0000-0000000000c1', 'authenticated');
select tst.expect_fail($x$
  select public.add_attachment(tst.q('MQ-0003'), tst.q('MQ-0003')::text || '/c1.pdf', 'c1.pdf', 'pdf', 1000)
$x$, 'a coordinator not assigned to the query cannot attach files');

-- ---------------------------------------------------------------------
-- 11. Student contact details
-- ---------------------------------------------------------------------
\echo '== 11. student contact =='
select tst.as_user('00000000-0000-0000-0000-0000000000e1', 'authenticated');
do $$
begin
  perform tst.assert((select count(*) from public.student_contact('10000000-0000-0000-0000-000000000001')) = 0,
                     'representative gets no student contact details');
end $$;

select tst.as_user('00000000-0000-0000-0000-0000000000c2', 'authenticated');
do $$
begin
  perform tst.assert((select count(*) from public.student_contact('10000000-0000-0000-0000-000000000001')) = 1,
                     'coordinator 2 gets contact details for a student on its queries');
end $$;

select tst.as_user('00000000-0000-0000-0000-0000000000c1', 'authenticated');
do $$
begin
  perform tst.assert((select count(*) from public.student_contact('10000000-0000-0000-0000-000000000001')) = 0,
                     'coordinator 1 gets no contact for a student it has no query for');
end $$;

select tst.as_user('00000000-0000-0000-0000-0000000000a1', 'authenticated');
do $$
begin
  perform tst.assert((select count(*) from public.student_contact('10000000-0000-0000-0000-000000000001')) = 1,
                     'admin gets contact details for any student');
  perform tst.assert((select count(*) from public.queries) = 4,
                     'admin sees all four queries');
end $$;

-- ---------------------------------------------------------------------
-- 12. History is append-only; identity and status are guarded
-- ---------------------------------------------------------------------
\echo '== 12. append-only history and guards =='
select tst.as_user(null, 'postgres');

select tst.expect_fail($x$ update public.query_events set note = 'tampered' $x$,
                       'history cannot be edited');

select tst.expect_fail($x$ delete from public.query_events $x$,
                       'history cannot be deleted');

select tst.expect_fail($x$
  update public.queries set reference = 'MQ-9999' where reference = 'MQ-0001'
$x$, 'query reference cannot be changed');

select tst.expect_fail($x$
  update public.queries set status = 'closed' where reference = 'MQ-0003'
$x$, 'an in-progress query cannot be closed directly');

-- ---------------------------------------------------------------------
-- 13. Timers and reminders (run_reminder_check)
-- ---------------------------------------------------------------------
\echo '== 13. timers and reminders =='
select tst.as_user(null, 'postgres');

-- 13a. MQ-0003: no update for three days, resolve-by has passed.
update public.queries
   set last_update_at = now() - interval '3 days',
       resolve_by = now() - interval '1 minute'
 where reference = 'MQ-0003';

select public.run_reminder_check();   -- run 1: nudge and overdue

do $$
declare
  v_q uuid := tst.q('MQ-0003');
begin
  perform tst.assert((select nudged_at from public.queries where id = v_q) is not null,
                     'nudge set after three days without an update');
  perform tst.assert((select overdue_at from public.queries where id = v_q) is not null,
                     'overdue set after resolve-by');
  perform tst.assert((select escalated_at from public.queries where id = v_q) is null,
                     'not escalated on the same run as overdue');
  perform tst.assert((select count(*) from public.query_events where query_id = v_q and type = 'nudge') = 1,
                     'one nudge in the history');
  perform tst.assert((select count(*) from public.notifications
                       where query_id = v_q and kind = 'nudge'
                         and recipient_profile_id = '00000000-0000-0000-0000-0000000000c2') = 1,
                     'nudge email queued for the coordinator');
end $$;

select public.run_reminder_check();   -- run 2: nothing new

do $$
declare
  v_q uuid := tst.q('MQ-0003');
begin
  perform tst.assert((select count(*) from public.query_events where query_id = v_q and type = 'nudge') = 1
                     and (select count(*) from public.query_events where query_id = v_q and type = 'overdue') = 1,
                     'running the check again sends nothing twice');
end $$;

update public.queries set overdue_at = now() - interval '3 days' where reference = 'MQ-0003';
select public.run_reminder_check();   -- run 3: escalation

do $$
declare
  v_q uuid := tst.q('MQ-0003');
begin
  perform tst.assert((select escalated_at from public.queries where id = v_q) is not null,
                     'escalated two days after overdue');
  perform tst.assert((select count(*) from public.notifications
                       where query_id = v_q and kind = 'escalation'
                         and recipient_profile_id = '00000000-0000-0000-0000-0000000000a1') = 1,
                     'escalation email goes to the escalation recipient');
  perform tst.assert((select count(*) from public.notifications
                       where query_id = tst.q('MQ-0003') and kind = 'unassigned') = 1,
                     'the unrouted query alerted the admin when it was logged');
end $$;

-- 13b. MQ-0002: waiting for the student. Waiting time is excluded from nudge and overdue.
select tst.as_user('00000000-0000-0000-0000-0000000000c1', 'authenticated');
select public.change_status(tst.q('MQ-0002'), 'in_progress', null);
select public.ask_student(tst.q('MQ-0002'), 'Please confirm the email address on your application');

select tst.as_user(null, 'postgres');
update public.queries
   set waiting_since = now() - interval '2 days 1 hour',
       resolve_by = now() - interval '1 minute'
 where reference = 'MQ-0002';

select public.run_reminder_check();   -- run A: first student reminder only

do $$
declare
  v_q uuid := tst.q('MQ-0002');
begin
  perform tst.assert((select student_reminder_1_at from public.queries where id = v_q) is not null,
                     'first student reminder sent after two days waiting');
  perform tst.assert((select student_reminder_2_at from public.queries where id = v_q) is null,
                     'second reminder does not go out in the same run');
  perform tst.assert((select overdue_at from public.queries where id = v_q) is null,
                     'waiting query is not marked overdue, even past resolve-by');
  perform tst.assert((select count(*) from public.notifications
                       where query_id = v_q and kind = 'student_reminder'
                         and recipient_email = 'dummy02@example.test') = 1,
                     'first reminder queued to the student email');
end $$;

select public.run_reminder_check();   -- run B: still only one reminder

do $$
begin
  perform tst.assert((select count(*) from public.notifications
                       where query_id = tst.q('MQ-0002') and kind = 'student_reminder') = 1,
                     'no repeat reminder before the four-day mark');
end $$;

update public.queries set waiting_since = now() - interval '5 days' where reference = 'MQ-0002';
select public.run_reminder_check();   -- run C: second reminder and one stall alert

do $$
declare
  v_q uuid := tst.q('MQ-0002');
begin
  perform tst.assert((select student_reminder_2_at from public.queries where id = v_q) is not null,
                     'second student reminder sent after four days waiting');
  perform tst.assert((select stall_alert_at from public.queries where id = v_q) is not null,
                     'stall alert recorded');
  perform tst.assert((select count(*) from public.notifications
                       where query_id = v_q and kind = 'stall_alert'
                         and recipient_profile_id = '00000000-0000-0000-0000-0000000000c1') = 1,
                     'coordinator 1 is told the query has stalled');
end $$;

select public.run_reminder_check();   -- run D: nothing more

do $$
begin
  perform tst.assert((select count(*) from public.notifications
                       where query_id = tst.q('MQ-0002') and kind = 'stall_alert') = 1,
                     'the stall alert is sent once');
end $$;

-- 13c. The student replies, then the coordinator asks again. Reminders start afresh.
select tst.as_user('00000000-0000-0000-0000-0000000000c1', 'authenticated');
select public.record_student_reply(tst.q('MQ-0002'), 'Student confirmed the new email address');
select public.ask_student(tst.q('MQ-0002'), 'Please confirm the phone number on file');

select tst.as_user(null, 'postgres');
do $$
declare
  v_q uuid := tst.q('MQ-0002');
begin
  perform tst.assert((select student_reminder_1_at from public.queries where id = v_q) is null
                     and (select student_reminder_2_at from public.queries where id = v_q) is null,
                     'a new waiting period resets the student reminders');
  perform tst.assert((select stall_alert_at from public.queries where id = v_q) is not null,
                     'the stall alert flag stays, so the coordinator is alerted once per query');
  perform tst.assert((select total_waiting_seconds from public.queries where id = v_q) >= 432000,
                     'five days of waiting are added to the query');
end $$;

-- ---------------------------------------------------------------------
-- 14. Sender queue and visibility
-- ---------------------------------------------------------------------
\echo '== 14. sender queue and visibility =='
select tst.as_user('00000000-0000-0000-0000-0000000000c1', 'authenticated');
select tst.expect_fail($x$ select * from public.next_notifications(5) $x$,
                       'coordinator cannot read the sender queue');
select tst.expect_fail($x$ select public.run_reminder_check() $x$,
                       'coordinator cannot run the reminder check');

select tst.as_user(null, 'service_role');
do $$
declare
  v_n integer;
  v_first uuid;
  v_second uuid;
  i integer;
begin
  select count(*) into v_n from public.next_notifications(1000);
  perform tst.assert(v_n >= 5, 'sender sees the queued emails (' || v_n || ')');

  select id into v_first from public.notifications
   where status = 'pending' order by created_at limit 1;
  perform public.mark_notification_sent(v_first);
  perform tst.assert((select status from public.notifications where id = v_first) = 'sent',
                     'a delivered email is marked sent');
  perform tst.assert((select count(*) from public.query_events where type = 'email_sent') = 1,
                     'the delivery is written to the history');

  select id into v_second from public.notifications
   where status = 'pending' order by created_at limit 1;
  perform public.mark_notification_failed(v_second, 'SMTP 550 mailbox unavailable');
  perform tst.assert((select attempts from public.notifications where id = v_second) = 1,
                     'a failed send counts one attempt');
  perform tst.assert(exists (select 1 from public.next_notifications(1000) n where n.id = v_second),
                     'a failed email is retried');

  for i in 2..5 loop
    perform public.mark_notification_failed(v_second, 'SMTP 550 mailbox unavailable');
  end loop;

  perform tst.assert((select attempts from public.notifications where id = v_second) = 5,
                     'five attempts are recorded');
  perform tst.assert(not exists (select 1 from public.next_notifications(1000) n where n.id = v_second),
                     'after five attempts the email is no longer retried');
  perform tst.assert((select count(*) from public.query_events where type = 'email_failed') = 5,
                     'each failed attempt is in the history');
end $$;

select tst.as_user('00000000-0000-0000-0000-0000000000e1', 'authenticated');
do $$
begin
  perform tst.assert((select count(*) from public.notifications) = 0,
                     'representative sees no notifications');
end $$;

select tst.as_user('00000000-0000-0000-0000-0000000000a1', 'authenticated');
do $$
begin
  perform tst.assert((select count(*) from public.notifications) >= 5,
                     'admin sees the notifications');
end $$;

select tst.as_user(null, 'anon');
select tst.expect_fail($x$ select count(*) from public.queries $x$,
                       'anonymous visitors see no queries');

-- ---------------------------------------------------------------------
-- 15. Clean up
-- ---------------------------------------------------------------------
\echo '== 15. clean up =='
select tst.as_user(null, 'postgres');
drop schema tst cascade;
\echo 'All 002 checks passed.'
