-- 아고라 은행 대출 시스템
create table if not exists public.bank_loans (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.bank_accounts(id) on delete cascade,
  amount bigint not null check (amount > 0),
  remaining bigint not null check (remaining >= 0),
  purpose text not null default '',
  status text not null default 'pending' check (status in ('pending','approved','rejected','paid')),
  requested_at timestamptz not null default now(),
  decided_at timestamptz,
  paid_at timestamptz
);
create index if not exists bank_loans_account_idx on public.bank_loans(account_id);
create index if not exists bank_loans_status_idx on public.bank_loans(status);
alter table public.bank_loans enable row level security;
revoke all on table public.bank_loans from anon, authenticated;

create or replace function public.bank_loan_apply(p_no text,p_pin text,p_amount bigint,p_purpose text)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare a public.bank_accounts; l public.bank_loans;
begin
 select * into a from public.bank_accounts where account_no=p_no and pin_hash=encode(extensions.digest(p_pin,'sha256'),'hex') for update;
 if not found then raise exception '본인확인에 실패했습니다.'; end if;
 if p_amount < 1 then raise exception '대출 금액은 1공 이상이어야 합니다.'; end if;
 if p_amount > 10000 then raise exception '한 번에 최대 10,000공까지 신청할 수 있습니다.'; end if;
 if exists(select 1 from public.bank_loans where account_id=a.id and status in ('pending','approved')) then raise exception '이미 신청 중이거나 상환 중인 대출이 있습니다.'; end if;
 insert into public.bank_loans(account_id,amount,remaining,purpose) values(a.id,p_amount,p_amount,coalesce(trim(p_purpose),'')) returning * into l;
 return jsonb_build_object('id',l.id,'amount',l.amount,'remaining',l.remaining,'purpose',l.purpose,'status',l.status);
end;
$$;

create or replace function public.bank_loan_my(p_no text,p_pin text)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare aid uuid;
begin
 select id into aid from public.bank_accounts where account_no=p_no and pin_hash=encode(extensions.digest(p_pin,'sha256'),'hex');
 if not found then raise exception '본인확인에 실패했습니다.'; end if;
 return jsonb_build_object('loans',coalesce((
  select jsonb_agg(jsonb_build_object(
   'id',l.id,'amount',l.amount,'remaining',l.remaining,'purpose',l.purpose,'status',l.status,
   'requested_at',to_char(l.requested_at at time zone 'Asia/Seoul','YYYY-MM-DD HH24:MI:SS'),
   'decided_at',case when l.decided_at is null then null else to_char(l.decided_at at time zone 'Asia/Seoul','YYYY-MM-DD HH24:MI:SS') end
  ) order by l.requested_at desc) from public.bank_loans l where l.account_id=aid
 ),'[]'::jsonb));
end;
$$;

create or replace function public.bank_loan_repay(p_no text,p_pin text,p_loan_id uuid,p_amount bigint)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare a public.bank_accounts; l public.bank_loans; new_remaining bigint;
begin
 if p_amount < 1 then raise exception '상환 금액은 1공 이상이어야 합니다.'; end if;
 select * into a from public.bank_accounts where account_no=p_no and pin_hash=encode(extensions.digest(p_pin,'sha256'),'hex') for update;
 if not found then raise exception '본인확인에 실패했습니다.'; end if;
 select * into l from public.bank_loans where id=p_loan_id and account_id=a.id and status='approved' for update;
 if not found then raise exception '상환할 수 있는 대출이 없습니다.'; end if;
 if a.balance < p_amount then raise exception '잔액이 부족합니다.'; end if;
 if p_amount > l.remaining then raise exception '상환 금액이 남은 대출금보다 많습니다.'; end if;
 new_remaining:=l.remaining-p_amount;
 update public.bank_accounts set balance=balance-p_amount where id=a.id;
 insert into public.bank_transactions(account_id,type,amount) values(a.id,'withdraw',p_amount);
 update public.bank_loans set remaining=new_remaining,status=case when new_remaining=0 then 'paid' else 'approved' end,paid_at=case when new_remaining=0 then now() else null end where id=l.id;
 return jsonb_build_object('loan_id',l.id,'paid',p_amount,'remaining',new_remaining);
end;
$$;

create or replace function public.bank_admin_loan_list(p_code text)
returns jsonb language plpgsql security definer set search_path=''
as $$
begin
 if not public.bank_admin_login(p_code) then raise exception '관리자 코드가 올바르지 않습니다.'; end if;
 return jsonb_build_object('loans',coalesce((
  select jsonb_agg(jsonb_build_object(
   'id',l.id,'no',a.account_no,'name',a.name,'amount',l.amount,'remaining',l.remaining,'purpose',l.purpose,'status',l.status,
   'requested_at',to_char(l.requested_at at time zone 'Asia/Seoul','YYYY-MM-DD HH24:MI:SS')
  ) order by l.requested_at desc)
  from public.bank_loans l join public.bank_accounts a on a.id=l.account_id
 ),'[]'::jsonb));
end;
$$;

create or replace function public.bank_admin_loan_decide(p_code text,p_loan_id uuid,p_approve boolean)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare l public.bank_loans; a public.bank_accounts;
begin
 if not public.bank_admin_login(p_code) then raise exception '관리자 코드가 올바르지 않습니다.'; end if;
 select * into l from public.bank_loans where id=p_loan_id for update;
 if not found then raise exception '대출 신청을 찾을 수 없습니다.'; end if;
 if l.status <> 'pending' then raise exception '이미 처리된 대출 신청입니다.'; end if;
 select * into a from public.bank_accounts where id=l.account_id for update;
 if not found then raise exception '회원 계좌를 찾을 수 없습니다.'; end if;
 if p_approve then
  update public.bank_accounts set balance=balance+l.amount where id=a.id;
  insert into public.bank_transactions(account_id,type,amount) values(a.id,'deposit',l.amount);
  update public.bank_loans set status='approved',decided_at=now() where id=l.id;
 else
  update public.bank_loans set status='rejected',decided_at=now() where id=l.id;
 end if;
 return jsonb_build_object('id',l.id,'status',case when p_approve then 'approved' else 'rejected' end);
end;
$$;

revoke execute on function public.bank_loan_apply(text,text,bigint,text) from public,authenticated;
revoke execute on function public.bank_loan_my(text,text) from public,authenticated;
revoke execute on function public.bank_loan_repay(text,text,uuid,bigint) from public,authenticated;
revoke execute on function public.bank_admin_loan_list(text) from public,authenticated;
revoke execute on function public.bank_admin_loan_decide(text,uuid,boolean) from public,authenticated;
grant execute on function public.bank_loan_apply(text,text,bigint,text) to anon;
grant execute on function public.bank_loan_my(text,text) to anon;
grant execute on function public.bank_loan_repay(text,text,uuid,bigint) to anon;
grant execute on function public.bank_admin_loan_list(text) to anon;
grant execute on function public.bank_admin_loan_decide(text,uuid,boolean) to anon;
notify pgrst,'reload schema';
