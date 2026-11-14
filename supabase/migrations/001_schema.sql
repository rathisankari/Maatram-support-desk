-- =====================================================================
-- Maatram Support Desk (MH26-04)  |  001_schema.sql
-- Run ONCE in the Supabase SQL editor on a fresh project.
-- Contains: types, tables, indexes, helper functions, workflow triggers,
-- row-level security (4 roles), table grants, RPC functions, starter data.
-- Assumes: "Enable Data API" ON, "Automatically expose new tables" OFF.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. TYPES
-- ---------------------------------------------------------------------
create type public.user_role as enum ('student', 'rep', 'coordinator', 'admin');
create type public.query_status as enum
  ('new', 'assigned', 'in_progress', 'waiting_for_student', 'resolved', 'closed');
create type public.priority_level as enum ('high', 'medium', 'low');
create type public.query_channel as enum
  ('whatsapp', 'phone', 'email', 'form', 'in_person', 'other');
create type public.event_type as enum
  ('created', 'status_change', 'assignment', 'overdue', 'escalation', 'reminder');
create type public.notification_channel as enum ('email', 'whatsapp', 'sms', 'in_app');
create type public.notification_status as enum ('pending', 'sent', 'failed', 'simulated');

-- ---------------------------------------------------------------------
-- 2. TABLES
-- ---------------------------------------------------------------------
create table public.institutions (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  created_at timestamptz not null default now()
);

create table public.categories (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  default_priority public.priority_level not null default 'medium',
  is_active boolean not null default true
);

-- One row per signed-in person. Created automatically on first sign-in.
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  full_name text not null default '',
  email text not null default '',
  phone text,
  role public.user_role not null default 'student',
  institution_id uuid references public.institutions (id),
  is_senior boolean not null default false,
  on_leave boolean not null default false,
  created_at timestamptz not null default now()
);

-- People who ask for help. profile_id is filled when they sign in (matched by email).
create table public.students (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid unique references public.profiles (id) on delete set null,
  full_name text not null,
  email text,
  phone text,
  institution_id uuid references public.institutions (id),
  language text not null default 'en' check (language in ('en', 'ta')),
  created_at timestamptz not null default now()
);
create unique index students_email_key on public.students (lower(email)) where email is not null;

create table public.queries (
  id uuid primary key default gen_random_uuid(),
  ticket_no bigint generated always as identity unique,
  student_id uuid not null references public.students (id),
  institution_id uuid references public.institutions (id),
  category_id uuid not null references public.categories (id),
  channel public.query_channel not null default 'form',
  priority public.priority_level not null default 'medium',
  description text not null check (length(trim(description)) > 0),
  status public.query_status not null default 'new',
  logged_by uuid not null references public.profiles (id),
  raised_by_student boolean not null default false,
  assigned_to uuid references public.profiles (id),
  is_overdue boolean not null default false,
  nudge_sent boolean not null default false,
  escalation_stage smallint not null default 0 check (escalation_stage between 0 and 2),
  created_at timestamptz not null default now(),
  last_update_at timestamptz not null default now(),
  resolved_at timestamptz,
  closed_at timestamptz,
  paused_at timestamptz,
  total_paused_seconds bigint not null default 0
);

create table public.query_messages (
  id uuid primary key default gen_random_uuid(),
  query_id uuid not null references public.queries (id) on delete cascade,
  author_id uuid references public.profiles (id) on delete set null,
  visible_to_student boolean not null default true,   -- false = internal note
  recorded_by_rep boolean not null default false,     -- reply typed in by a rep
  body text not null check (length(trim(body)) > 0),
  created_at timestamptz not null default now()
);

create table public.query_attachments (
  id uuid primary key default gen_random_uuid(),
  query_id uuid not null references public.queries (id) on delete cascade,
  message_id uuid references public.query_messages (id) on delete set null,
  file_path text not null,
  file_type text,
  size_bytes bigint,
  uploaded_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now()
);

-- Time-stamped history. Written by triggers only.
create table public.query_events (
  id uuid primary key default gen_random_uuid(),
  query_id uuid not null references public.queries (id) on delete cascade,
  type public.event_type not null,
  from_value text,
  to_value text,
  actor_id uuid references public.profiles (id) on delete set null,
  reason text,
  created_at timestamptz not null default now()
);

create table public.assignment_rules (
  id uuid primary key default gen_random_uuid(),
  category_id uuid references public.categories (id),
  institution_id uuid references public.institutions (id),
  coordinator_id uuid not null references public.profiles (id) on delete cascade,
  priority_order int not null default 100,
  is_active boolean not null default true
);

create table public.time_limits (
  priority public.priority_level primary key,
  nudge_hours int not null,
  overdue_hours int not null,
  escalate_senior_hours int not null,  -- hours AFTER overdue
  escalate_admin_hours int not null    -- hours AFTER overdue
);

create table public.templates (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  category_id uuid references public.categories (id),
  priority public.priority_level not null default 'medium',
  description text not null
);

create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  query_id uuid references public.queries (id) on delete cascade,
  recipient_id uuid references public.profiles (id) on delete set null,
  recipient_student_id uuid references public.students (id) on delete set null,
  channel public.notification_channel not null,
  template text not null,
  body text,
  status public.notification_status not null default 'pending',
  scheduled_at timestamptz not null default now(),
  sent_at timestamptz,
  error text
);

create table public.feedback (
  id uuid primary key default gen_random_uuid(),
  query_id uuid not null unique references public.queries (id) on delete cascade,
  rating smallint not null check (rating between 1 and 5),
  comment text,
  created_at timestamptz not null default now()
);

create table public.audit_log (
  id bigint generated always as identity primary key,
  actor_id uuid references public.profiles (id) on delete set null,
  action text not null,
  object_type text not null,
  object_id uuid,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 3. INDEXES
-- ---------------------------------------------------------------------
create index queries_status_idx on public.queries (status);
create index queries_assigned_to_idx on public.queries (assigned_to);
create index queries_last_update_idx on public.queries (last_update_at);
create index queries_created_at_idx on public.queries (created_at);
create index queries_student_idx on public.queries (student_id);
create index queries_category_idx on public.queries (category_id);
create index queries_logged_by_idx on public.queries (logged_by);
create index query_events_query_idx on public.query_events (query_id, created_at);
create index query_messages_query_idx on public.query_messages (query_id, created_at);
create index query_attachments_query_idx on public.query_attachments (query_id);
create index notifications_query_idx on public.notifications (query_id);
create index notifications_status_idx on public.notifications (status, scheduled_at);

-- ---------------------------------------------------------------------
-- 4. HELPER FUNCTIONS (used by the access rules)
-- ---------------------------------------------------------------------
create or replace function public.app_role()
returns public.user_role
language sql stable security definer set search_path = ''
as $$ select role from public.profiles where id = auth.uid() $$;

create or replace function public.is_senior()
returns boolean
language sql stable security definer set search_path = ''
as $$ select coalesce((select is_senior from public.profiles where id = auth.uid()), false) $$;

create or replace function public.my_student_id()
returns uuid
language sql stable security definer set search_path = ''
as $$ select id from public.students where profile_id = auth.uid() $$;

-- Can the signed-in user see this query?
--   admin: all | coordinator: assigned to them, logged by them, or senior
--   rep: logged by them | student: their own
create or replace function public.can_view_query(p_query_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.queries q
    where q.id = p_query_id
      and (
        public.app_role() = 'admin'
        or (public.app_role() = 'coordinator'
            and (q.assigned_to = auth.uid() or q.logged_by = auth.uid() or public.is_senior()))
        or (public.app_role() = 'rep' and q.logged_by = auth.uid())
        or (public.app_role() = 'student' and q.student_id = public.my_student_id())
      )
  );
$$;

-- ---------------------------------------------------------------------
-- 5. SIGN-UP AND STUDENT LINKING
-- ---------------------------------------------------------------------
-- New sign-in -> profile (role 'student' by default) -> link to student record by email.
create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  insert into public.profiles (id, email, full_name)
  values (
    new.id,
    coalesce(new.email, ''),
    coalesce(new.raw_user_meta_data ->> 'full_name', split_part(coalesce(new.email, ''), '@', 1))
  );
  update public.students
     set profile_id = new.id
   where profile_id is null and email is not null and lower(email) = lower(new.email);
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- A student record added AFTER the person already signed in still gets linked.
create or replace function public.students_link_profile()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare v_profile uuid;
begin
  if new.profile_id is null and new.email is not null then
    select p.id into v_profile
      from public.profiles p
     where lower(p.email) = lower(new.email)
       and p.role = 'student'
       and not exists (select 1 from public.students s where s.profile_id = p.id)
     limit 1;
    new.profile_id := v_profile;
  end if;
  return new;
end;
$$;

create trigger students_link_profile_trg
  before insert or update of email on public.students
  for each row execute function public.students_link_profile();

-- ---------------------------------------------------------------------
-- 6. WORKFLOW TRIGGERS ON queries
-- ---------------------------------------------------------------------
create or replace function public.queries_before_insert()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  new.status := 'new';
  new.raised_by_student := (public.app_role() = 'student');
  if new.institution_id is null then
    select institution_id into new.institution_id from public.students where id = new.student_id;
  end if;
  return new;
end;
$$;

create trigger queries_before_insert_trg
  before insert on public.queries
  for each row execute function public.queries_before_insert();

create or replace function public.queries_before_update()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  -- Giving a brand-new query an owner moves it to Assigned.
  if old.status = 'new' and new.status = 'new'
     and new.assigned_to is not null and new.assigned_to is distinct from old.assigned_to then
    new.status := 'assigned';
  end if;

  if new.status is distinct from old.status then
    if not (
      (old.status = 'new' and new.status = 'assigned') or
      (old.status = 'assigned' and new.status = 'in_progress') or
      (old.status = 'in_progress' and new.status in ('waiting_for_student', 'resolved')) or
      (old.status = 'waiting_for_student' and new.status = 'in_progress') or
      (old.status = 'resolved' and new.status in ('closed', 'in_progress')) or
      (old.status = 'closed' and new.status = 'in_progress')
    ) then
      raise exception 'Status change from % to % is not allowed', old.status, new.status
        using errcode = 'P0001';
    end if;

    -- Overdue clock pauses while we wait for the student.
    if new.status = 'waiting_for_student' then
      new.paused_at := now();
    elsif old.status = 'waiting_for_student' then
      new.total_paused_seconds := old.total_paused_seconds
        + coalesce(extract(epoch from (now() - old.paused_at))::bigint, 0);
      new.paused_at := null;
    end if;

    if new.status = 'resolved' then new.resolved_at := now(); end if;
    if new.status = 'closed' then new.closed_at := now(); end if;
    if new.status = 'in_progress' and old.status in ('resolved', 'closed') then
      new.resolved_at := null;
      new.closed_at := null;
    end if;
  end if;

  -- Real progress (status or owner change) resets the reminder timers.
  if new.status is distinct from old.status or new.assigned_to is distinct from old.assigned_to then
    new.last_update_at := now();
    new.is_overdue := false;
    new.nudge_sent := false;
    new.escalation_stage := 0;
  end if;

  return new;
end;
$$;

create trigger queries_before_update_trg
  before update on public.queries
  for each row execute function public.queries_before_update();

-- History: every change is written to query_events.
create or replace function public.queries_after_write()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare v_reason text := nullif(current_setting('app.reason', true), '');
begin
  if tg_op = 'INSERT' then
    insert into public.query_events (query_id, type, to_value, actor_id)
    values (new.id, 'created', new.status::text, auth.uid());
    return new;
  end if;

  if new.status is distinct from old.status then
    insert into public.query_events (query_id, type, from_value, to_value, actor_id, reason)
    values (new.id, 'status_change', old.status::text, new.status::text, auth.uid(), v_reason);
  end if;

  if new.assigned_to is distinct from old.assigned_to then
    insert into public.query_events (query_id, type, from_value, to_value, actor_id, reason)
    values (new.id, 'assignment', old.assigned_to::text, new.assigned_to::text, auth.uid(), v_reason);
  end if;

  if new.is_overdue and not old.is_overdue then
    insert into public.query_events (query_id, type) values (new.id, 'overdue');
  end if;

  if new.escalation_stage > old.escalation_stage then
    insert into public.query_events (query_id, type, to_value)
    values (new.id, 'escalation', new.escalation_stage::text);
  end if;

  return new;
end;
$$;

create trigger queries_after_write_trg
  after insert or update on public.queries
  for each row execute function public.queries_after_write();

-- Any message on a query counts as an update (resets reminder timers).
create or replace function public.messages_after_insert()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  update public.queries
     set last_update_at = now(), is_overdue = false, nudge_sent = false, escalation_stage = 0
   where id = new.query_id;
  return new;
end;
$$;

create trigger messages_after_insert_trg
  after insert on public.query_messages
  for each row execute function public.messages_after_insert();

-- ---------------------------------------------------------------------
-- 7. ACTION FUNCTIONS (the only way to change a query's status or owner)
-- ---------------------------------------------------------------------
-- Admin assigns or reassigns. A reason is required when the query already has an owner.
create or replace function public.assign_query(
  p_query_id uuid, p_coordinator_id uuid, p_reason text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
declare q public.queries;
begin
  if public.app_role() is distinct from 'admin' then
    raise exception 'Only an admin can assign queries' using errcode = '42501';
  end if;
  select * into q from public.queries where id = p_query_id for update;
  if not found then raise exception 'Query not found'; end if;
  if q.status = 'closed' then raise exception 'A closed query cannot be assigned'; end if;
  if not exists (select 1 from public.profiles where id = p_coordinator_id and role = 'coordinator') then
    raise exception 'The chosen person is not a coordinator';
  end if;
  if q.assigned_to is not null and coalesce(trim(p_reason), '') = '' then
    raise exception 'A reason is required to reassign a query';
  end if;
  perform set_config('app.reason', coalesce(p_reason, ''), true);
  update public.queries set assigned_to = p_coordinator_id where id = p_query_id;
end;
$$;

-- Coordinator (own queries, or senior) or admin moves the status.
create or replace function public.change_status(
  p_query_id uuid, p_new_status public.query_status, p_note text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
declare q public.queries; r public.user_role := public.app_role();
begin
  select * into q from public.queries where id = p_query_id for update;
  if not found then raise exception 'Query not found'; end if;
  if not (r = 'admin' or (r = 'coordinator' and (q.assigned_to = auth.uid() or public.is_senior()))) then
    raise exception 'You cannot change this query' using errcode = '42501';
  end if;
  perform set_config('app.reason', coalesce(p_note, ''), true);
  update public.queries set status = p_new_status where id = p_query_id;
end;
$$;

-- Coordinator asks the student something; status becomes Waiting for student.
create or replace function public.ask_student(p_query_id uuid, p_question text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare q public.queries; r public.user_role := public.app_role();
begin
  select * into q from public.queries where id = p_query_id for update;
  if not found then raise exception 'Query not found'; end if;
  if not (r = 'admin' or (r = 'coordinator' and (q.assigned_to = auth.uid() or public.is_senior()))) then
    raise exception 'You cannot change this query' using errcode = '42501';
  end if;
  if q.status <> 'in_progress' then
    raise exception 'Move the query to In progress before asking the student';
  end if;
  insert into public.query_messages (query_id, author_id, visible_to_student, body)
  values (p_query_id, auth.uid(), true, p_question);
  update public.queries set status = 'waiting_for_student' where id = p_query_id;
end;
$$;

-- The student replies (or a rep records a reply received on WhatsApp / phone).
create or replace function public.student_reply(
  p_query_id uuid, p_body text, p_recorded_by_rep boolean default false)
returns void
language plpgsql security definer set search_path = ''
as $$
declare q public.queries; r public.user_role := public.app_role(); v_rec boolean;
begin
  select * into q from public.queries where id = p_query_id for update;
  if not found then raise exception 'Query not found'; end if;
  if r = 'student' and q.student_id = public.my_student_id() then
    v_rec := false;
  elsif r = 'rep' and q.logged_by = auth.uid() then
    v_rec := true;
  else
    raise exception 'You cannot reply on this query' using errcode = '42501';
  end if;
  insert into public.query_messages (query_id, author_id, visible_to_student, recorded_by_rep, body)
  values (p_query_id, auth.uid(), true, v_rec, p_body);
  if q.status = 'waiting_for_student' then
    update public.queries set status = 'in_progress' where id = p_query_id;
  end if;
end;
$$;

-- First name of the assigned coordinator, safe to show to the student.
create or replace function public.assigned_first_name(p_query_id uuid)
returns text
language sql stable security definer set search_path = ''
as $$
  select split_part(p.full_name, ' ', 1)
    from public.queries q join public.profiles p on p.id = q.assigned_to
   where q.id = p_query_id and public.can_view_query(p_query_id);
$$;

-- ---------------------------------------------------------------------
-- 8. ROW-LEVEL SECURITY
-- ---------------------------------------------------------------------
alter table public.institutions enable row level security;
alter table public.categories enable row level security;
alter table public.profiles enable row level security;
alter table public.students enable row level security;
alter table public.queries enable row level security;
alter table public.query_messages enable row level security;
alter table public.query_attachments enable row level security;
alter table public.query_events enable row level security;
alter table public.assignment_rules enable row level security;
alter table public.time_limits enable row level security;
alter table public.templates enable row level security;
alter table public.notifications enable row level security;
alter table public.feedback enable row level security;
alter table public.audit_log enable row level security;

-- Lookup tables: everyone signed in can read; only admin can change.
create policy institutions_read on public.institutions for select to authenticated using (true);
create policy institutions_admin on public.institutions for all to authenticated
  using (public.app_role() = 'admin') with check (public.app_role() = 'admin');

create policy categories_read on public.categories for select to authenticated using (true);
create policy categories_admin on public.categories for all to authenticated
  using (public.app_role() = 'admin') with check (public.app_role() = 'admin');

-- Settings tables: staff read, admin changes.
create policy templates_read on public.templates for select to authenticated
  using (public.app_role() in ('rep', 'coordinator', 'admin'));
create policy templates_admin on public.templates for all to authenticated
  using (public.app_role() = 'admin') with check (public.app_role() = 'admin');

create policy rules_read on public.assignment_rules for select to authenticated
  using (public.app_role() in ('coordinator', 'admin'));
create policy rules_admin on public.assignment_rules for all to authenticated
  using (public.app_role() = 'admin') with check (public.app_role() = 'admin');

create policy limits_read on public.time_limits for select to authenticated
  using (public.app_role() in ('coordinator', 'admin'));
create policy limits_admin on public.time_limits for all to authenticated
  using (public.app_role() = 'admin') with check (public.app_role() = 'admin');

-- profiles: you see yourself; staff see everyone; only admin edits (roles included).
create policy profiles_read on public.profiles for select to authenticated
  using (id = auth.uid() or public.app_role() in ('rep', 'coordinator', 'admin'));
create policy profiles_admin_update on public.profiles for update to authenticated
  using (public.app_role() = 'admin') with check (public.app_role() = 'admin');

-- students: a student sees their own record; staff see all; staff add; admin edits.
create policy students_read on public.students for select to authenticated
  using (profile_id = auth.uid() or public.app_role() in ('rep', 'coordinator', 'admin'));
create policy students_insert on public.students for insert to authenticated
  with check (public.app_role() in ('rep', 'coordinator', 'admin'));
create policy students_admin_update on public.students for update to authenticated
  using (public.app_role() = 'admin') with check (public.app_role() = 'admin');

-- queries: read by the rules in can_view_query(); create by staff or by the student themselves.
-- There is NO direct update/delete: changes go through the action functions above.
create policy queries_read on public.queries for select to authenticated
  using (
    public.app_role() = 'admin'
    or (public.app_role() = 'coordinator'
        and (assigned_to = auth.uid() or logged_by = auth.uid() or public.is_senior()))
    or (public.app_role() = 'rep' and logged_by = auth.uid())
    or (public.app_role() = 'student' and student_id = public.my_student_id())
  );
create policy queries_insert_staff on public.queries for insert to authenticated
  with check (public.app_role() in ('rep', 'coordinator', 'admin') and logged_by = auth.uid());
create policy queries_insert_student on public.queries for insert to authenticated
  with check (
    public.app_role() = 'student'
    and student_id = public.my_student_id()
    and logged_by = auth.uid()
    and assigned_to is null
  );

-- messages: students and reps never see internal notes.
create policy messages_read on public.query_messages for select to authenticated
  using (
    public.can_view_query(query_id)
    and (visible_to_student or public.app_role() in ('coordinator', 'admin'))
  );
create policy messages_insert_staff on public.query_messages for insert to authenticated
  with check (
    author_id = auth.uid()
    and public.app_role() in ('coordinator', 'admin')
    and public.can_view_query(query_id)
  );

create policy attachments_read on public.query_attachments for select to authenticated
  using (public.can_view_query(query_id));
create policy attachments_insert on public.query_attachments for insert to authenticated
  with check (uploaded_by = auth.uid() and public.can_view_query(query_id));

-- history: staff only (students see status and messages, not internal history).
create policy events_read on public.query_events for select to authenticated
  using (public.app_role() in ('rep', 'coordinator', 'admin') and public.can_view_query(query_id));

create policy notifications_read on public.notifications for select to authenticated
  using (recipient_id = auth.uid() or public.app_role() = 'admin');

create policy feedback_read on public.feedback for select to authenticated
  using (public.can_view_query(query_id));
create policy feedback_insert on public.feedback for insert to authenticated
  with check (
    public.app_role() = 'student'
    and public.can_view_query(query_id)
    and exists (select 1 from public.queries q
                 where q.id = query_id and q.status in ('resolved', 'closed'))
  );

create policy audit_read on public.audit_log for select to authenticated
  using (public.app_role() = 'admin');

-- ---------------------------------------------------------------------
-- 9. GRANTS (tables are not exposed by default, so say exactly who gets what)
-- ---------------------------------------------------------------------
-- Signed-in users: the policies above decide which rows they may touch.
grant select on public.institutions, public.categories, public.profiles, public.students,
  public.queries, public.query_messages, public.query_attachments, public.query_events,
  public.assignment_rules, public.time_limits, public.templates, public.notifications,
  public.feedback, public.audit_log to authenticated;
grant insert on public.students, public.queries, public.query_messages,
  public.query_attachments, public.feedback to authenticated;
grant update on public.profiles, public.students to authenticated;
grant insert, update, delete on public.institutions, public.categories, public.templates,
  public.assignment_rules, public.time_limits to authenticated;

-- Server side (scheduler, notification sender, seed scripts) uses the service role.
grant all on all tables in schema public to service_role;
grant usage on schema public to service_role;

-- Nobody who is not signed in gets anything.
revoke all on all tables in schema public from anon;

-- Functions: signed-in users only.
revoke execute on all functions in schema public from public, anon;
grant execute on function
  public.app_role(), public.is_senior(), public.my_student_id(),
  public.can_view_query(uuid), public.assigned_first_name(uuid),
  public.assign_query(uuid, uuid, text), public.change_status(uuid, public.query_status, text),
  public.ask_student(uuid, text), public.student_reply(uuid, text, boolean)
  to authenticated;
grant execute on all functions in schema public to service_role;

-- ---------------------------------------------------------------------
-- 10. STARTER DATA (no personal details)
-- ---------------------------------------------------------------------
insert into public.categories (name, default_priority) values
  ('Admission', 'medium'), ('Scholarship', 'medium'), ('Events', 'low'),
  ('Mentoring', 'low'), ('Technical', 'medium'), ('Other', 'low');

insert into public.institutions (name) values
  ('Demo Institute of Technology'), ('Demo Arts College'), ('Demo Polytechnic');

-- Suggested defaults; the admin can change them later.
insert into public.time_limits
  (priority, nudge_hours, overdue_hours, escalate_senior_hours, escalate_admin_hours) values
  ('high', 4, 24, 12, 24),
  ('medium', 24, 72, 24, 48),
  ('low', 48, 120, 48, 96);

insert into public.templates (name, category_id, priority, description)
select t.name, c.id, t.priority::public.priority_level, t.description
from (values
  ('Bonafide certificate request', 'Admission', 'medium', 'Student needs a bonafide certificate. Purpose and deadline to be confirmed.'),
  ('Scholarship status check', 'Scholarship', 'medium', 'Student is asking for the status of a scholarship application.'),
  ('Event registration help', 'Events', 'low', 'Student needs help registering for an event or session.'),
  ('Mentor request', 'Mentoring', 'low', 'Student is asking to be matched with a mentor.')
) as t(name, category, priority, description)
join public.categories c on c.name = t.category;

-- =====================================================================
-- AFTER RUNNING THIS SCRIPT
-- 1. Sign in to the app once with your own email (a profile is created).
-- 2. Make yourself admin (run this in the SQL editor, with your email):
--      update public.profiles set role = 'admin' where email = 'you@example.com';
-- 3. Create coordinators, reps and test students the same way:
--      update public.profiles set role = 'coordinator' where email = '...';
--      update public.profiles set role = 'rep' where email = '...';
--      update public.profiles set is_senior = true where email = '...';
-- =====================================================================
