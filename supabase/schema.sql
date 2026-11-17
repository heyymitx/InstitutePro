
-- InstitutePro Phase 1 schema. Run in Supabase SQL Editor.
-- Browser code uses only the publishable/anon key; RLS protects every table.
create extension if not exists pgcrypto;

create table public.organizations(id uuid primary key default gen_random_uuid(),name text not null,created_at timestamptz default now());
create table public.profiles(id uuid primary key references auth.users(id) on delete cascade,organization_id uuid references public.organizations(id) on delete set null,full_name text,role text not null default 'parent' check(role in('admin','teacher','parent','student')),created_at timestamptz default now());
create table public.classes(id uuid primary key default gen_random_uuid(),organization_id uuid not null references public.organizations(id) on delete cascade,name text not null,subject text,timing text,is_active boolean default true,created_at timestamptz default now(),unique(organization_id,name));
create table public.students(id uuid primary key default gen_random_uuid(),organization_id uuid not null references public.organizations(id) on delete cascade,class_id uuid references public.classes(id) on delete set null,parent_user_id uuid references public.profiles(id) on delete set null,student_code text,full_name text not null,parent_name text,parent_phone text,parent_email text,admission_date date default current_date,is_active boolean default true,created_at timestamptz default now(),unique(organization_id,student_code));
create table public.attendance(id uuid primary key default gen_random_uuid(),organization_id uuid not null references public.organizations(id) on delete cascade,student_id uuid not null references public.students(id) on delete cascade,class_id uuid not null references public.classes(id) on delete cascade,attendance_date date not null,status text not null check(status in('present','absent','leave')),marked_by uuid references public.profiles(id),created_at timestamptz default now(),unique(student_id,class_id,attendance_date));
create table public.fee_plans(id uuid primary key default gen_random_uuid(),organization_id uuid not null references public.organizations(id) on delete cascade,name text not null,frequency text not null check(frequency in('monthly','quarterly','one_time')),default_amount numeric(12,2) not null default 0 check(default_amount>=0),is_active boolean default true,created_at timestamptz default now(),unique(organization_id,name));
create table public.student_fees(id uuid primary key default gen_random_uuid(),organization_id uuid not null references public.organizations(id) on delete cascade,student_id uuid not null references public.students(id) on delete cascade,plan_id uuid references public.fee_plans(id) on delete set null,total_amount numeric(12,2) not null check(total_amount>0),paid_amount numeric(12,2) not null default 0,balance_amount numeric(12,2) not null,due_date date not null,status text not null default 'pending' check(status in('pending','partially_paid','paid','overdue')),created_at timestamptz default now(),check(paid_amount>=0 and balance_amount>=0 and paid_amount+balance_amount=total_amount));
create table public.payments(id uuid primary key default gen_random_uuid(),organization_id uuid not null references public.organizations(id) on delete cascade,student_fee_id uuid not null references public.student_fees(id) on delete cascade,student_id uuid not null references public.students(id) on delete cascade,amount numeric(12,2) not null check(amount>0),method text not null check(method in('upi','cash','razorpay','cashfree')),reference text,status text not null default 'pending' check(status in('pending','verified','rejected','refunded')),created_by uuid references public.profiles(id),verified_by uuid references public.profiles(id),verified_at timestamptz,created_at timestamptz default now());
create table public.reminders(id uuid primary key default gen_random_uuid(),organization_id uuid not null references public.organizations(id) on delete cascade,student_fee_id uuid not null references public.student_fees(id) on delete cascade,channel text not null check(channel in('whatsapp','sms','email')),message text not null,status text not null default 'prepared' check(status in('prepared','queued','sent','failed')),scheduled_for timestamptz,sent_at timestamptz,created_at timestamptz default now());
create table public.parent_replies(id uuid primary key default gen_random_uuid(),organization_id uuid not null references public.organizations(id) on delete cascade,student_id uuid not null references public.students(id) on delete cascade,reminder_id uuid references public.reminders(id) on delete set null,reply text not null,notes text,created_at timestamptz default now());
create table public.receipts(id uuid primary key default gen_random_uuid(),organization_id uuid not null references public.organizations(id) on delete cascade,payment_id uuid not null unique references public.payments(id) on delete cascade,receipt_number text not null,issued_at timestamptz default now(),unique(organization_id,receipt_number));
create table public.audit_logs(id uuid primary key default gen_random_uuid(),organization_id uuid not null references public.organizations(id) on delete cascade,actor_id uuid references public.profiles(id),action text not null,entity_type text,entity_id uuid,details jsonb default '{}'::jsonb,created_at timestamptz default now());

create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path=public as $$
begin insert into public.profiles(id,full_name,role) values(new.id,coalesce(new.raw_user_meta_data->>'full_name',''),'parent') on conflict do nothing; return new; end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute procedure public.handle_new_user();

create or replace function public.current_org_id() returns uuid language sql stable security definer set search_path=public as $$ select organization_id from public.profiles where id=auth.uid() $$;
create or replace function public.current_role() returns text language sql stable security definer set search_path=public as $$ select role from public.profiles where id=auth.uid() $$;
create or replace function public.is_org_admin() returns boolean language sql stable security definer set search_path=public as $$ select exists(select 1 from public.profiles where id=auth.uid() and role='admin' and organization_id is not null) $$;

create or replace function public.create_institute(p_name text) returns uuid language plpgsql security definer set search_path=public as $$
declare new_id uuid;
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 if exists(select 1 from public.profiles where id=auth.uid() and organization_id is not null) then raise exception 'Account already belongs to an institute'; end if;
 if length(trim(p_name))<2 then raise exception 'Institute name is too short'; end if;
 insert into public.organizations(name) values(trim(p_name)) returning id into new_id;
 update public.profiles set organization_id=new_id,role='admin' where id=auth.uid();
 insert into public.fee_plans(organization_id,name,frequency) values(new_id,'Monthly','monthly'),(new_id,'Quarterly','quarterly'),(new_id,'Full Course','one_time');
 return new_id;
end $$;

create or replace function public.set_org_id() returns trigger language plpgsql security definer set search_path=public as $$
begin
 if auth.uid() is null or public.current_org_id() is null then raise exception 'Institute membership required'; end if;
 new.organization_id:=public.current_org_id(); return new;
end $$;
do $$ declare t text; begin foreach t in array array['classes','students','attendance','fee_plans','student_fees','payments','reminders','parent_replies','receipts','audit_logs'] loop
 execute format('create trigger set_org_before_insert before insert on public.%I for each row execute function public.set_org_id()',t);
end loop; end $$;

create or replace function public.verify_manual_payment(p_payment_id uuid) returns void language plpgsql security definer set search_path=public as $$
declare p public.payments%rowtype; f public.student_fees%rowtype; n numeric(12,2);
begin
 if not public.is_org_admin() then raise exception 'Admin only'; end if;
 select * into p from public.payments where id=p_payment_id and organization_id=public.current_org_id() for update;
 if not found or p.status<>'pending' then raise exception 'Pending payment not found'; end if;
 select * into f from public.student_fees where id=p.student_fee_id and organization_id=public.current_org_id() for update;
 if not found or p.amount>f.balance_amount then raise exception 'Invalid fee balance'; end if;
 n:=f.paid_amount+p.amount;
 update public.student_fees set paid_amount=n,balance_amount=total_amount-n,status=case when total_amount=n then 'paid' else 'partially_paid' end where id=f.id;
 update public.payments set status='verified',verified_by=auth.uid(),verified_at=now() where id=p.id;
 insert into public.receipts(organization_id,payment_id,receipt_number) values(public.current_org_id(),p.id,'IP-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,10)));
 insert into public.audit_logs(organization_id,actor_id,action,entity_type,entity_id) values(public.current_org_id(),auth.uid(),'payment_verified','payment',p.id);
end $$;

alter table public.organizations enable row level security;
alter table public.profiles enable row level security;
do $$ declare t text; begin foreach t in array array['classes','students','attendance','fee_plans','student_fees','payments','reminders','parent_replies','receipts','audit_logs'] loop execute format('alter table public.%I enable row level security',t); end loop; end $$;

create policy org_member_read on public.organizations for select to authenticated using(id=public.current_org_id());
create policy profile_self_read on public.profiles for select to authenticated using(id=auth.uid() or (organization_id=public.current_org_id() and public.is_org_admin()));
create policy profile_self_update on public.profiles for update to authenticated using(id=auth.uid()) with check(id=auth.uid() and role=public.current_role() and organization_id is not distinct from public.current_org_id());

do $$ declare t text; begin foreach t in array array['classes','students','attendance','fee_plans','student_fees','payments','reminders','parent_replies','receipts','audit_logs'] loop
 execute format('create policy %I on public.%I for select to authenticated using(organization_id=public.current_org_id())',t||'_read_org',t);
end loop; end $$;

create policy classes_write on public.classes for all to authenticated using(organization_id=public.current_org_id() and public.current_role() in('admin','teacher')) with check(organization_id=public.current_org_id() and public.current_role() in('admin','teacher'));
create policy students_write on public.students for all to authenticated using(organization_id=public.current_org_id() and public.current_role() in('admin','teacher')) with check(organization_id=public.current_org_id() and public.current_role() in('admin','teacher'));
create policy attendance_write on public.attendance for all to authenticated using(organization_id=public.current_org_id() and public.current_role() in('admin','teacher')) with check(organization_id=public.current_org_id() and public.current_role() in('admin','teacher'));
create policy fee_plans_write on public.fee_plans for all to authenticated using(organization_id=public.current_org_id() and public.current_role()='admin') with check(organization_id=public.current_org_id() and public.current_role()='admin');
create policy student_fees_write on public.student_fees for all to authenticated using(organization_id=public.current_org_id() and public.current_role()='admin') with check(organization_id=public.current_org_id() and public.current_role()='admin');
create policy payments_insert on public.payments for insert to authenticated with check(organization_id=public.current_org_id() and public.current_role() in('admin','teacher') and status='pending');
create policy reminders_insert on public.reminders for insert to authenticated with check(organization_id=public.current_org_id() and public.current_role() in('admin','teacher'));
create policy parent_replies_insert on public.parent_replies for insert to authenticated with check(organization_id=public.current_org_id());

create policy audit_admin_read on public.audit_logs for select to authenticated using(organization_id=public.current_org_id() and public.current_role()='admin');

grant select on all tables in schema public to authenticated;
grant insert,update on public.classes,public.students,public.attendance,public.fee_plans,public.student_fees to authenticated;
grant insert on public.payments,public.reminders,public.parent_replies to authenticated;
grant execute on function public.create_institute(text),public.verify_manual_payment(uuid) to authenticated;
