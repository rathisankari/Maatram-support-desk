-- =====================================================================
-- Maatram Support Desk (MH26-04)  |  002_final_schema.sql
-- Version 1.0 · 22 November 2026
-- Matches the Final Solution Document v1.1 (docs/SPEC.md) and the data
-- model v1.0 (docs/data-model.md), with its section 5 decisions at their
-- defaults.
--
-- Run ONCE in the Supabase SQL Editor on a project whose public schema is
-- empty (after the reset). This replaces 001_schema.sql, which was run and
-- then reset. Do not run both.
--
-- Prerequisites: Data API on; "Automatically expose new tables" OFF.
-- Students have no login. They are records only.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. TYPES
-- ---------------------------------------------------------------------
create type public.user_role as enum ('rep', 'coordinator', 'admin');

create type public.query_status as enum (
  'new', 'assigned', 'in_progress', 'waiting_for_student', 'resolved', 'closed');

create type public.priority_level as enum ('urgent', 'high', 'normal', 'low');

create type public.query_channel as enum (
  'whatsapp', 'phone', 'email', 'form', 'in_person', 'other');

create type public.event_type as enum (
  'created', 'assigned', 'reassigned', 'status_changed', 'note',
  'student_question', 'student_reply', 'nudge', 'overdue', 'escalated',
  'student_reminder', 'stall_alert', 'attachment_added', 'email_sent', 'email_failed');

create type public.notification_kind as enum (
  'query_assigned', 'nudge', 'overdue', 'escalation', 'question',
  'student_reminder', 'stall_alert', 'resolved', 'unassigned');

create type public.send_status as enum ('pending', 'sent', 'failed');

-- ---------------------------------------------------------------------
-- 2. TABLES (the 11 entities in the data model)
-- ---------------------------------------------------------------------
create table public.institutions (
  id uuid primary key default gen_random_uuid(),
  name text not null unique check (length(trim(name)) > 0),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.categories (
  id uuid primary key default gen_random_uuid(),
  name text not null unique check (length(trim(name)) > 0),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

-- Staff only. Created on first sign-in and switched off until an admin
-- activates the account and sets the role.
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  name text not null default '',
  email text not null unique,
  role public.user_role not null default 'rep',
  active boolean not null default false,
  last_assigned_at timestamptz,
  created_at timestamptz not null default now()
);

-- People who ask for help. No login. Email and phone are restricted (see grants).
create table public.students (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) > 0),
  institution_id uuid not null references public.institutions (id),
  email text not null check (position('@' in email) > 1),
  phone text,
  created_at timestamptz not null default now()
);
create unique index students_email_key on public.students (lower(email));

-- One row only (id = 1). Every timer is in minutes, so demo mode is just smaller numbers.
create table public.app_settings (
  id integer primary key default 1 check (id = 1),
  nudge_minutes integer not null default 1440 check (nudge_minutes > 0),
  resolve_urgent_minutes integer not null default 1440 check (resolve_urgent_minutes > 0),
  resolve_high_minutes integer not null default 2880 check (resolve_high_minutes > 0),
  resolve_normal_minutes integer not null default 4320 check (resolve_normal_minutes > 0),
  resolve_low_minutes integer not null default 10080 check (resolve_low_minutes > 0),
  escalation_minutes integer not null default 2880 check (escalation_minutes > 0),
  student_reminder_1_minutes integer not null default 2880 check (student_reminder_1_minutes > 0),
  student_reminder_2_minutes integer not null default 5760 check (student_reminder_2_minutes > 0),
  escalation_recipient_id uuid references public.profiles (id),
  updated_at timestamptz not null default now(),
  check (student_reminder_2_minutes > student_reminder_1_minutes)
);
insert into public.app_settings (id) values (1);

create sequence public.query_reference_seq;

create table public.queries (
  id uuid primary key default gen_random_uuid(),
  reference text not null unique
    default ('MQ-' || lpad(nextval('public.query_reference_seq')::text, 4, '0')),
  student_id uuid not null references public.students (id),
  institution_id uuid not null references public.institutions (id),
  category_id uuid not null references public.categories (id),
  channel public.query_channel not null,
  priority public.priority_level not null,
  description text not null
    check (length(trim(description)) > 0 and length(description) <= 500),
  status public.query_status not null default 'new',
  logged_by uuid not null references public.profiles (id),
  assigned_to uuid references public.profiles (id),          -- null = unassigned
  created_at timestamptz not null default now(),
  last_update_at timestamptz not null default now(),
  resolve_by timestamptz not null,
  waiting_since timestamptz,                                  -- set only while waiting
  total_waiting_seconds integer not null default 0 check (total_waiting_seconds >= 0),
  nudged_at timestamptz,                                      -- cleared on every update
  overdue_at timestamptz,                                     -- kept until resolved or closed
  escalated_at timestamptz,
  student_reminder_1_at timestamptz,
  student_reminder_2_at timestamptz,
  stall_alert_at timestamptz,
  resolved_at timestamptz,
  closed_at timestamptz,
  check ((status = 'new') = (assigned_to is null)),
  check ((status = 'waiting_for_student') = (waiting_since is not null))
);

create index queries_status_idx on public.queries (status);
create index queries_assigned_to_idx on public.queries (assigned_to);
create index queries_logged_by_idx on public.queries (logged_by);
create index queries_student_idx on public.queries (student_id);
create index queries_category_idx on public.queries (category_id);
create index queries_last_update_idx on public.queries (last_update_at);
create index queries_created_at_idx on public.queries (created_at);

-- History. Append-only: a trigger rejects every update and delete.
create table public.query_events (
  id uuid primary key default gen_random_uuid(),
  query_id uuid not null references public.queries (id),
  actor_id uuid references public.profiles (id),              -- null = system
  type public.event_type not null,
  from_value text,
  to_value text,
  note text,
  created_at timestamptz not null default now()
);
create index query_events_query_idx on public.query_events (query_id, created_at);

create table public.attachments (
  id uuid primary key default gen_random_uuid(),
  query_id uuid not null references public.queries (id),
  uploaded_by uuid not null references public.profiles (id),
  storage_path text not null unique,
  file_name text not null check (length(trim(file_name)) > 0),
  file_type text not null check (file_type in ('pdf', 'jpg', 'png', 'docx')),
  size_bytes integer not null check (size_bytes > 0 and size_bytes <= 10485760),
  created_at timestamptz not null default now()
);
create index attachments_query_idx on public.attachments (query_id);

create table public.assignment_rules (
  id uuid primary key default gen_random_uuid(),
  position integer not null unique check (position > 0),     -- evaluated in order
  category_id uuid references public.categories (id),         -- null = any category
  institution_id uuid references public.institutions (id),    -- null = any institution
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.rule_coordinators (
  rule_id uuid not null references public.assignment_rules (id) on delete cascade,
  profile_id uuid not null references public.profiles (id) on delete cascade,
  primary key (rule_id, profile_id)
);

-- Outbox. The database writes rows; the service-side sender sends them.
create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  query_id uuid not null references public.queries (id),
  recipient_profile_id uuid references public.profiles (id),  -- null for student emails
  recipient_email text not null,
  kind public.notification_kind not null,
  subject text not null,
  body text not null,
  status public.send_status not null default 'pending',
  attempts integer not null default 0 check (attempts between 0 and 5),
  last_error text,
  created_at timestamptz not null default now(),
  sent_at timestamptz
);
create index notifications_status_idx on public.notifications (status, created_at);
create index notifications_query_idx on public.notifications (query_id);

-- ---------------------------------------------------------------------
-- 3. ACCESS HELPERS (used by row-level security and the action functions)
-- ---------------------------------------------------------------------
-- The signed-in user's role, or null if the account is not active.
create or replace function public.app_role()
returns public.user_role
language sql stable security definer set search_path = ''
as $$
  select p.role from public.profiles p where p.id = auth.uid() and p.active
$$;

-- Read rule: admin all; coordinator the queries assigned to them; rep the queries they logged.
create or replace function public.can_see_query(p_query_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.queries q
     where q.id = p_query_id
       and (public.app_role() = 'admin'
            or (public.app_role() = 'coordinator' and q.assigned_to = auth.uid())
            or (public.app_role() = 'rep' and q.logged_by = auth.uid())))
$$;

-- Write rule for status and notes: admin all; coordinator only own assigned queries.
create or replace function public.can_work_query(p_query_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.queries q
     where q.id = p_query_id
       and (public.app_role() = 'admin'
            or (public.app_role() = 'coordinator' and q.assigned_to = auth.uid())))
$$;

-- Timer for resolve-by, from the admin settings, in minutes.
create or replace function public.resolve_minutes(p_priority public.priority_level)
returns integer
language sql stable security definer set search_path = ''
as $$
  select case p_priority
           when 'urgent' then s.resolve_urgent_minutes
           when 'high' then s.resolve_high_minutes
           when 'normal' then s.resolve_normal_minutes
           else s.resolve_low_minutes end
    from public.app_settings s where s.id = 1
$$;

-- ---------------------------------------------------------------------
-- 4. SIGN-UP AND TRIGGERS
-- ---------------------------------------------------------------------
-- First sign-in creates an inactive staff profile. An admin activates it.
create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  insert into public.profiles (id, email, name)
  values (
    new.id,
    lower(coalesce(new.email, '')),
    coalesce(nullif(new.raw_user_meta_data ->> 'full_name', ''),
             split_part(coalesce(new.email, ''), '@', 1))
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Give existing sign-in accounts a profile too (inactive until an admin activates them).
insert into public.profiles (id, email, name)
select u.id,
       lower(coalesce(u.email, '')),
       coalesce(nullif(u.raw_user_meta_data ->> 'full_name', ''),
                split_part(coalesce(u.email, ''), '@', 1))
  from auth.users u
on conflict (id) do nothing;

-- Only the allowed status moves and protected fields. Action functions do the work.
create or replace function public.queries_guard()
returns trigger
language plpgsql set search_path = ''
as $$
begin
  if new.reference is distinct from old.reference
     or new.student_id is distinct from old.student_id
     or new.logged_by is distinct from old.logged_by
     or new.created_at is distinct from old.created_at then
    raise exception 'Query identity fields cannot be changed' using errcode = 'P0001';
  end if;

  if new.status is distinct from old.status and not (
       (old.status = 'new' and new.status = 'assigned')
    or (old.status = 'assigned' and new.status = 'in_progress')
    or (old.status = 'in_progress' and new.status in ('waiting_for_student', 'resolved'))
    or (old.status = 'waiting_for_student' and new.status = 'in_progress')
    or (old.status = 'resolved' and new.status = 'closed')) then
    raise exception 'Status change from % to % is not allowed', old.status, new.status
      using errcode = 'P0001';
  end if;
  return new;
end;
$$;

create trigger queries_guard_trg
  before update on public.queries
  for each row execute function public.queries_guard();

create or replace function public.query_events_append_only()
returns trigger
language plpgsql set search_path = ''
as $$
begin
  raise exception 'Query history cannot be changed' using errcode = 'P0001';
end;
$$;

create trigger query_events_append_only_trg
  before update or delete on public.query_events
  for each row execute function public.query_events_append_only();

-- ---------------------------------------------------------------------
-- 5. INTERNAL HELPERS (called by the action functions; not granted to users)
-- ---------------------------------------------------------------------
create or replace function public.record_event(
  p_query_id uuid, p_type public.event_type, p_from text, p_to text,
  p_note text, p_actor uuid)
returns void
language sql security definer set search_path = ''
as $$
  insert into public.query_events (query_id, actor_id, type, from_value, to_value, note)
  values (p_query_id, p_actor, p_type, p_from, p_to,
          nullif(trim(coalesce(p_note, '')), ''))
$$;

create or replace function public.queue_notification(
  p_query_id uuid, p_profile_id uuid, p_email text,
  p_kind public.notification_kind, p_subject text, p_body text)
returns void
language sql security definer set search_path = ''
as $$
  insert into public.notifications
    (query_id, recipient_profile_id, recipient_email, kind, subject, body)
  values (p_query_id, p_profile_id, p_email, p_kind, p_subject, p_body)
$$;

-- Owner if assigned; otherwise every active admin.
create or replace function public.notify_query_owner(
  p_query_id uuid, p_kind public.notification_kind, p_subject text, p_body text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  q public.queries;
  r record;
begin
  select * into q from public.queries where id = p_query_id;
  if q.assigned_to is not null then
    perform public.queue_notification(p_query_id, q.assigned_to,
      (select p.email from public.profiles p where p.id = q.assigned_to),
      p_kind, p_subject, p_body);
  else
    for r in select p.id, p.email from public.profiles p
              where p.role = 'admin' and p.active loop
      perform public.queue_notification(p_query_id, r.id, r.email, p_kind, p_subject, p_body);
    end loop;
  end if;
end;
$$;

-- Assign or reassign. A reassignment needs a reason. Status New becomes Assigned;
-- other statuses are unchanged.
create or replace function public.apply_assignment(
  p_query_id uuid, p_coordinator_id uuid, p_reason text, p_actor uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  q public.queries;
  v_reason text := nullif(trim(coalesce(p_reason, '')), '');
  v_email text;
begin
  select * into q from public.queries where id = p_query_id for update;
  if not found then
    raise exception 'Query not found';
  end if;
  if q.status = 'closed' then
    raise exception 'A closed query cannot be assigned';
  end if;
  if q.assigned_to = p_coordinator_id then
    raise exception 'The query is already assigned to this coordinator';
  end if;
  if q.assigned_to is not null and v_reason is null then
    raise exception 'A reason is required to reassign a query';
  end if;

  update public.queries
     set assigned_to = p_coordinator_id,
         status = case when q.status = 'new' then 'assigned' else q.status end,
         last_update_at = now(),
         nudged_at = null
   where id = p_query_id;

  update public.profiles set last_assigned_at = now() where id = p_coordinator_id;

  perform public.record_event(
    p_query_id,
    (case when q.assigned_to is null then 'assigned' else 'reassigned' end)::public.event_type,
    q.assigned_to::text, p_coordinator_id::text, v_reason, p_actor);

  select p.email into v_email from public.profiles p where p.id = p_coordinator_id;
  perform public.queue_notification(p_query_id, p_coordinator_id, v_email, 'query_assigned',
    'Query ' || q.reference || ' assigned to you',
    'Query ' || q.reference || ' has been assigned to you. Sign in to the Support Desk to see it.');
end;
$$;

-- Routing: the first active rule that matches category and institution. Among its
-- coordinators, the one with fewest open queries; ties go to the least recently assigned.
-- No match: the query stays New and every active admin is emailed.
create or replace function public.route_query(p_query_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  q public.queries;
  v_rule uuid;
  v_coord uuid;
  r record;
begin
  select * into q from public.queries where id = p_query_id;

  select ar.id into v_rule
    from public.assignment_rules ar
   where ar.active
     and (ar.category_id is null or ar.category_id = q.category_id)
     and (ar.institution_id is null or ar.institution_id = q.institution_id)
   order by ar.position
   limit 1;

  if v_rule is not null then
    select rc.profile_id into v_coord
      from public.rule_coordinators rc
      join public.profiles p on p.id = rc.profile_id
     where rc.rule_id = v_rule and p.active and p.role = 'coordinator'
     order by (select count(*) from public.queries x
                where x.assigned_to = rc.profile_id
                  and x.status in ('assigned', 'in_progress', 'waiting_for_student')),
              p.last_assigned_at nulls first
     limit 1;
  end if;

  if v_coord is null then
    for r in select p.id, p.email from public.profiles p
              where p.role = 'admin' and p.active loop
      perform public.queue_notification(p_query_id, r.id, r.email, 'unassigned',
        'Query ' || q.reference || ' has no owner',
        'Query ' || q.reference || ' matched no assignment rule. Please assign it.');
    end loop;
    return;
  end if;

  perform public.apply_assignment(p_query_id, v_coord, null, null);
end;
$$;

-- ---------------------------------------------------------------------
-- 6. ACTION FUNCTIONS (the only way users change a query)
-- ---------------------------------------------------------------------
-- Representative (or admin) logs a query. Assignment rules run at once.
create or replace function public.log_query(
  p_student_id uuid, p_institution_id uuid, p_category_id uuid,
  p_channel public.query_channel, p_priority public.priority_level, p_description text)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_id uuid;
  v_now timestamptz := now();
begin
  if public.app_role() is null or public.app_role() not in ('rep', 'admin') then
    raise exception 'Only a representative or an admin can log a query' using errcode = '42501';
  end if;
  if not exists (select 1 from public.categories c where c.id = p_category_id and c.active) then
    raise exception 'Unknown or inactive category';
  end if;
  if not exists (select 1 from public.institutions i where i.id = p_institution_id and i.active) then
    raise exception 'Unknown or inactive institution';
  end if;

  insert into public.queries
    (student_id, institution_id, category_id, channel, priority, description,
     logged_by, created_at, last_update_at, resolve_by)
  values
    (p_student_id, p_institution_id, p_category_id, p_channel, p_priority, trim(p_description),
     auth.uid(), v_now, v_now,
     v_now + make_interval(mins => public.resolve_minutes(p_priority)))
  returning id into v_id;

  perform public.record_event(v_id, 'created', null, 'new', null, auth.uid());
  perform public.route_query(v_id);
  return v_id;
end;
$$;

-- Admin assigns or reassigns (reassignment needs a reason).
create or replace function public.assign_query(
  p_query_id uuid, p_coordinator_id uuid, p_reason text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if public.app_role() is distinct from 'admin' then
    raise exception 'Only an admin can assign queries' using errcode = '42501';
  end if;
  if not exists (select 1 from public.profiles p
                  where p.id = p_coordinator_id and p.role = 'coordinator' and p.active) then
    raise exception 'The chosen person is not an active coordinator';
  end if;
  perform public.apply_assignment(p_query_id, p_coordinator_id, p_reason, auth.uid());
end;
$$;

-- Status moves the coordinator or admin may make directly:
--   Assigned -> In progress; In progress -> Resolved (closing message required);
--   Resolved -> Closed. Waiting for student uses ask_student; the reply uses
--   record_student_reply. Closed is final.
create or replace function public.change_status(
  p_query_id uuid, p_to public.query_status, p_note text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  q public.queries;
  v_note text := nullif(trim(coalesce(p_note, '')), '');
  v_email text;
begin
  select * into q from public.queries where id = p_query_id for update;
  if not found or not public.can_work_query(p_query_id) then
    raise exception 'You cannot change this query' using errcode = '42501';
  end if;
  if p_to = 'waiting_for_student' then
    raise exception 'Use Ask the student to set Waiting for student';
  end if;

  if q.status = 'in_progress' and p_to = 'resolved' then
    if v_note is null then
      raise exception 'A closing message is required to resolve a query';
    end if;
  elsif not ((q.status = 'assigned' and p_to = 'in_progress')
          or (q.status = 'resolved' and p_to = 'closed')) then
    raise exception 'Status change from % to % is not allowed', q.status, p_to
      using errcode = 'P0001';
  end if;

  update public.queries
     set status = p_to,
         last_update_at = now(),
         nudged_at = null,
         resolved_at = case when p_to = 'resolved' then now() else resolved_at end,
         closed_at = case when p_to = 'closed' then now() else closed_at end
   where id = p_query_id;

  perform public.record_event(p_query_id, 'status_changed',
    q.status::text, p_to::text, v_note, auth.uid());

  if p_to = 'resolved' then
    select s.email into v_email from public.students s where s.id = q.student_id;
    perform public.queue_notification(p_query_id, null, v_email, 'resolved',
      'Query ' || q.reference || ' has been resolved',
      'Query ' || q.reference || ' has been resolved. ' || v_note);
  end if;
end;
$$;

-- Coordinator asks the student a question. Status: In progress -> Waiting for student.
create or replace function public.ask_student(p_query_id uuid, p_question text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  q public.queries;
  v_question text := nullif(trim(coalesce(p_question, '')), '');
  v_email text;
begin
  select * into q from public.queries where id = p_query_id for update;
  if not found or not public.can_work_query(p_query_id) then
    raise exception 'You cannot change this query' using errcode = '42501';
  end if;
  if q.status <> 'in_progress' then
    raise exception 'Move the query to In progress before asking the student';
  end if;
  if v_question is null then
    raise exception 'A question for the student is required';
  end if;

  -- A new waiting period starts with fresh student reminders. stall_alert_at stays (once per query).
  update public.queries
     set status = 'waiting_for_student',
         waiting_since = now(),
         student_reminder_1_at = null,
         student_reminder_2_at = null,
         last_update_at = now(),
         nudged_at = null
   where id = p_query_id;

  perform public.record_event(p_query_id, 'status_changed',
    'in_progress', 'waiting_for_student', null, auth.uid());
  perform public.record_event(p_query_id, 'student_question', null, null, v_question, auth.uid());

  select s.email into v_email from public.students s where s.id = q.student_id;
  perform public.queue_notification(p_query_id, null, v_email, 'question',
    'Query ' || q.reference || ': we need more information',
    'Please reply to this email quoting ' || q.reference || '. ' || v_question);
end;
$$;

-- Coordinator records the student's reply. Waiting time is added to the query and the
-- resolve-by time moves by the same amount.
create or replace function public.record_student_reply(p_query_id uuid, p_reply text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  q public.queries;
  v_reply text := nullif(trim(coalesce(p_reply, '')), '');
  v_waited integer;
begin
  select * into q from public.queries where id = p_query_id for update;
  if not found or not public.can_work_query(p_query_id) then
    raise exception 'You cannot change this query' using errcode = '42501';
  end if;
  if q.status <> 'waiting_for_student' then
    raise exception 'The query is not waiting for the student';
  end if;
  if v_reply is null then
    raise exception 'The reply text is required';
  end if;

  v_waited := greatest(0, floor(extract(epoch from (now() - q.waiting_since)))::integer);

  update public.queries
     set status = 'in_progress',
         waiting_since = null,
         total_waiting_seconds = total_waiting_seconds + v_waited,
         resolve_by = resolve_by + make_interval(secs => v_waited),
         last_update_at = now(),
         nudged_at = null
   where id = p_query_id;

  perform public.record_event(p_query_id, 'student_reply', null, null, v_reply, auth.uid());
  perform public.record_event(p_query_id, 'status_changed',
    'waiting_for_student', 'in_progress', null, auth.uid());
end;
$$;

-- Attachment record. The file itself goes to private storage under <query id>/...
-- At most three per query.
create or replace function public.add_attachment(
  p_query_id uuid, p_storage_path text, p_file_name text,
  p_file_type text, p_size_bytes integer)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_id uuid;
begin
  perform 1 from public.queries q where q.id = p_query_id for update;
  if not found or not public.can_see_query(p_query_id) then
    raise exception 'Query not found' using errcode = '42501';
  end if;
  if (select count(*) from public.attachments a where a.query_id = p_query_id) >= 3 then
    raise exception 'A query can have at most three attachments';
  end if;
  if left(p_storage_path, length(p_query_id::text) + 1) <> p_query_id::text || '/' then
    raise exception 'Storage path must start with the query id';
  end if;

  insert into public.attachments
    (query_id, uploaded_by, storage_path, file_name, file_type, size_bytes)
  values
    (p_query_id, auth.uid(), p_storage_path, p_file_name, lower(p_file_type), p_size_bytes)
  returning id into v_id;

  perform public.record_event(p_query_id, 'attachment_added', null, p_file_name, null, auth.uid());
  return v_id;
end;
$$;

-- Contact details: admin, or the coordinator assigned to a query for this student.
create or replace function public.student_contact(p_student_id uuid)
returns table (email text, phone text)
language sql stable security definer set search_path = ''
as $$
  select s.email, s.phone
    from public.students s
   where s.id = p_student_id
     and (public.app_role() = 'admin'
          or exists (select 1 from public.queries q
                      where q.student_id = s.id and q.assigned_to = auth.uid()))
$$;

-- ---------------------------------------------------------------------
-- 7. SCHEDULER AND SENDER (run as service role or by pg_cron)
-- ---------------------------------------------------------------------
-- Every five minutes. Each stage fires once per query; flags prevent repeats.
-- Waiting time is excluded from the nudge and the overdue checks.
create or replace function public.run_reminder_check()
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  s public.app_settings;
  q public.queries;
  r record;
  v_email text;
begin
  select * into s from public.app_settings where id = 1;

  -- Nudge: the assigned coordinator, after no update for nudge_minutes.
  for q in
    select * from public.queries
     where status in ('assigned', 'in_progress') and assigned_to is not null
       and nudged_at is null
       and last_update_at <= now() - make_interval(mins => s.nudge_minutes)
  loop
    update public.queries set nudged_at = now() where id = q.id;
    perform public.record_event(q.id, 'nudge', null, null, null, null);
    perform public.notify_query_owner(q.id, 'nudge',
      'Query ' || q.reference || ' has had no update',
      'Please update query ' || q.reference || '.');
  end loop;

  -- Overdue: past resolve-by. The flag stays until the query is resolved or closed.
  for q in
    select * from public.queries
     where status in ('new', 'assigned', 'in_progress')
       and overdue_at is null and resolve_by <= now()
  loop
    update public.queries set overdue_at = now() where id = q.id;
    perform public.record_event(q.id, 'overdue', null, null, null, null);
    perform public.notify_query_owner(q.id, 'overdue',
      'Query ' || q.reference || ' is overdue',
      'Query ' || q.reference || ' is past its resolve-by time.');
  end loop;

  -- Escalation: still open escalation_minutes after becoming overdue.
  for q in
    select * from public.queries
     where status in ('new', 'assigned', 'in_progress')
       and overdue_at is not null and escalated_at is null
       and overdue_at <= now() - make_interval(mins => s.escalation_minutes)
  loop
    update public.queries set escalated_at = now() where id = q.id;
    perform public.record_event(q.id, 'escalated', null,
      s.escalation_recipient_id::text, null, null);
    if s.escalation_recipient_id is not null then
      select p.email into v_email from public.profiles p where p.id = s.escalation_recipient_id;
      perform public.queue_notification(q.id, s.escalation_recipient_id, v_email, 'escalation',
        'Query ' || q.reference || ' escalated',
        'Query ' || q.reference || ' is overdue and still open.');
    else
      for r in select p.id, p.email from public.profiles p
                where p.role = 'admin' and p.active loop
        perform public.queue_notification(q.id, r.id, r.email, 'escalation',
          'Query ' || q.reference || ' escalated',
          'Query ' || q.reference || ' is overdue and still open.');
      end loop;
    end if;
  end loop;

  -- Student reminder 1: waiting for student for student_reminder_1_minutes.
  for q in
    select * from public.queries
     where status = 'waiting_for_student' and student_reminder_1_at is null
       and waiting_since <= now() - make_interval(mins => s.student_reminder_1_minutes)
  loop
    update public.queries set student_reminder_1_at = now() where id = q.id;
    perform public.record_event(q.id, 'student_reminder', null, '1', null, null);
    select st.email into v_email from public.students st where st.id = q.student_id;
    perform public.queue_notification(q.id, null, v_email, 'student_reminder',
      'Reminder: query ' || q.reference,
      'Please reply to this email quoting ' || q.reference || '.');
  end loop;

  -- Student reminder 2, then the coordinator is told once (stall alert).
  -- Needs reminder 1 from an earlier run (set at the transaction's now()), so each reminder goes out in its own run.
  for q in
    select * from public.queries
     where status = 'waiting_for_student' and student_reminder_1_at < now()
       and student_reminder_2_at is null
       and waiting_since <= now() - make_interval(mins => s.student_reminder_2_minutes)
  loop
    update public.queries
       set student_reminder_2_at = now(), stall_alert_at = now()
     where id = q.id;
    perform public.record_event(q.id, 'student_reminder', null, '2', null, null);
    select st.email into v_email from public.students st where st.id = q.student_id;
    perform public.queue_notification(q.id, null, v_email, 'student_reminder',
      'Second reminder: query ' || q.reference,
      'Please reply to this email quoting ' || q.reference || '.');
    perform public.record_event(q.id, 'stall_alert', null, null, null, null);
    perform public.notify_query_owner(q.id, 'stall_alert',
      'Query ' || q.reference || ' has stalled',
      'The student has not replied to query ' || q.reference || ' after two reminders.');
  end loop;
end;
$$;

-- Sender: next batch of rows to send (pending, or failed with fewer than five attempts).
create or replace function public.next_notifications(p_limit integer default 20)
returns setof public.notifications
language sql security definer set search_path = ''
as $$
  select * from public.notifications
   where status in ('pending', 'failed') and attempts < 5
   order by created_at
   limit p_limit
   for update skip locked
$$;

create or replace function public.mark_notification_sent(p_notification_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  n public.notifications;
begin
  update public.notifications
     set status = 'sent', sent_at = now(), last_error = null
   where id = p_notification_id
  returning * into n;
  if not found then
    raise exception 'Notification not found';
  end if;
  perform public.record_event(n.query_id, 'email_sent', null, n.kind::text, null, null);
end;
$$;

-- After five failed attempts the row stays failed, and the failure stays in the history.
create or replace function public.mark_notification_failed(p_notification_id uuid, p_error text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  n public.notifications;
begin
  update public.notifications
     set status = 'failed',
         attempts = least(attempts + 1, 5),
         last_error = left(coalesce(p_error, 'unknown error'), 500)
   where id = p_notification_id
  returning * into n;
  if not found then
    raise exception 'Notification not found';
  end if;
  perform public.record_event(n.query_id, 'email_failed', null, n.attempts::text,
    left(coalesce(p_error, 'unknown error'), 500), null);
end;
$$;

-- ---------------------------------------------------------------------
-- 8. ROW-LEVEL SECURITY
-- ---------------------------------------------------------------------
alter table public.institutions enable row level security;
alter table public.categories enable row level security;
alter table public.profiles enable row level security;
alter table public.students enable row level security;
alter table public.app_settings enable row level security;
alter table public.queries enable row level security;
alter table public.query_events enable row level security;
alter table public.attachments enable row level security;
alter table public.assignment_rules enable row level security;
alter table public.rule_coordinators enable row level security;
alter table public.notifications enable row level security;

create policy institutions_read on public.institutions for select to authenticated
  using (public.app_role() is not null);
create policy institutions_admin on public.institutions for all to authenticated
  using (public.app_role() = 'admin') with check (public.app_role() = 'admin');

create policy categories_read on public.categories for select to authenticated
  using (public.app_role() is not null);
create policy categories_admin on public.categories for all to authenticated
  using (public.app_role() = 'admin') with check (public.app_role() = 'admin');

create policy profiles_read on public.profiles for select to authenticated
  using (id = auth.uid() or public.app_role() is not null);
create policy profiles_admin_update on public.profiles for update to authenticated
  using (public.app_role() = 'admin') with check (public.app_role() = 'admin');

create policy students_read on public.students for select to authenticated
  using (public.app_role() is not null);
create policy students_insert on public.students for insert to authenticated
  with check (public.app_role() in ('rep', 'admin'));
create policy students_admin_update on public.students for update to authenticated
  using (public.app_role() = 'admin') with check (public.app_role() = 'admin');

create policy app_settings_read on public.app_settings for select to authenticated
  using (public.app_role() is not null);
create policy app_settings_admin_update on public.app_settings for update to authenticated
  using (public.app_role() = 'admin') with check (public.app_role() = 'admin');

create policy queries_read on public.queries for select to authenticated
  using (public.can_see_query(id));

create policy query_events_read on public.query_events for select to authenticated
  using (public.can_see_query(query_id));

create policy attachments_read on public.attachments for select to authenticated
  using (public.can_see_query(query_id));

create policy assignment_rules_admin on public.assignment_rules for all to authenticated
  using (public.app_role() = 'admin') with check (public.app_role() = 'admin');
create policy rule_coordinators_admin on public.rule_coordinators for all to authenticated
  using (public.app_role() = 'admin') with check (public.app_role() = 'admin');

create policy notifications_read on public.notifications for select to authenticated
  using (public.app_role() = 'admin' or recipient_profile_id = auth.uid());

-- ---------------------------------------------------------------------
-- 9. GRANTS (explicit, because new tables are not exposed by default)
-- ---------------------------------------------------------------------
revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
grant usage on schema public to anon, authenticated, service_role;

grant select on public.institutions, public.categories, public.app_settings,
  public.queries, public.query_events, public.attachments, public.notifications,
  public.profiles, public.assignment_rules, public.rule_coordinators to authenticated;
grant insert, update, delete on public.institutions, public.categories,
  public.assignment_rules, public.rule_coordinators to authenticated;
grant update (name, role, active) on public.profiles to authenticated;
grant update on public.app_settings to authenticated;

-- Students: staff see name and institution only. Email and phone come from student_contact().
grant select (id, name, institution_id, created_at) on public.students to authenticated;
grant insert (name, institution_id, email, phone) on public.students to authenticated;
grant update (name, institution_id, email, phone) on public.students to authenticated;

-- Server side (sender, scheduler) uses the service role.
grant all on all tables in schema public to service_role;
grant all on all sequences in schema public to service_role;

-- Functions: nobody gets execute by default. Users get only the action functions.
revoke execute on all functions in schema public from public, anon, authenticated, service_role;

grant execute on function
  public.app_role(),
  public.can_see_query(uuid),
  public.can_work_query(uuid),
  public.student_contact(uuid),
  public.log_query(uuid, uuid, uuid, public.query_channel, public.priority_level, text),
  public.assign_query(uuid, uuid, text),
  public.change_status(uuid, public.query_status, text),
  public.ask_student(uuid, text),
  public.record_student_reply(uuid, text),
  public.add_attachment(uuid, text, text, text, integer)
  to authenticated;

grant execute on function
  public.run_reminder_check(),
  public.next_notifications(integer),
  public.mark_notification_sent(uuid),
  public.mark_notification_failed(uuid, text)
  to service_role;

-- ---------------------------------------------------------------------
-- 10. STARTER DATA (no personal details)
-- ---------------------------------------------------------------------
insert into public.categories (name) values
  ('Admission'), ('Scholarship'), ('Events'), ('Mentoring'), ('Technical'), ('Other');

insert into public.institutions (name) values
  ('Demo Institute of Technology'), ('Demo Arts College'), ('Demo Polytechnic');

-- =====================================================================
-- AFTER RUNNING THIS SCRIPT
-- 1. Sign in once with your own email (creates an inactive profile).
-- 2. Make yourself an active admin:
--      update public.profiles set role = 'admin', active = true where email = 'you@example.com';
-- 3. Activate coordinators and representatives the same way, with
--    role = 'coordinator' or role = 'rep'. Then add assignment rules and link
--    coordinators (tables assignment_rules and rule_coordinators).
-- 4. Schedule the reminder check (enable pg_cron in Database > Extensions first):
--      select cron.schedule('reminder-check', '*/5 * * * *',
--                           $$select public.run_reminder_check();$$);
-- =====================================================================
