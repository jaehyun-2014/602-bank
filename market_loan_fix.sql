-- 아고라 케피털 시장/대출 기능 보강
-- 1) 장바구니 RPC
create or replace function public.market_cart_add(p_no text,p_pin text,p_item_id uuid)
returns boolean language plpgsql security definer set search_path=''
as $$
declare a public.bank_accounts; seller uuid;
begin
 select * into a from public.bank_accounts where account_no=p_no and pin_hash=encode(extensions.digest(p_pin,'sha256'),'hex');
 if not found then raise exception '본인확인에 실패했습니다.'; end if;
 select seller_account_id into seller from public.market_items where id=p_item_id and active=true;
 if seller is null then raise exception '상품을 찾을 수 없습니다.'; end if;
 if seller=a.id then raise exception '자신의 상품은 장바구니에 담을 수 없습니다.'; end if;
 insert into public.market_cart(item_id,account_id) values(p_item_id,a.id)
 on conflict(item_id,account_id) do nothing;
 return true;
end;
$$;

create or replace function public.market_cart_list(p_no text,p_pin text)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare a public.bank_accounts;
begin
 select * into a from public.bank_accounts where account_no=p_no and pin_hash=encode(extensions.digest(p_pin,'sha256'),'hex');
 if not found then raise exception '본인확인에 실패했습니다.'; end if;
 return jsonb_build_object('items',coalesce((
  select jsonb_agg(jsonb_build_object('item_id',m.id,'title',m.title,'price',m.price,'seller_name',s.name) order by c.created_at desc)
  from public.market_cart c
  join public.market_items m on m.id=c.item_id
  join public.bank_accounts s on s.id=m.seller_account_id
  where c.account_id=a.id and m.active=true
 ),'[]'::jsonb));
end;
$$;

create or replace function public.market_cart_remove(p_no text,p_pin text,p_item_id uuid)
returns boolean language plpgsql security definer set search_path=''
as $$
declare a public.bank_accounts;
begin
 select * into a from public.bank_accounts where account_no=p_no and pin_hash=encode(extensions.digest(p_pin,'sha256'),'hex');
 if not found then raise exception '본인확인에 실패했습니다.'; end if;
 delete from public.market_cart where item_id=p_item_id and account_id=a.id;
 return true;
end;
$$;

revoke execute on function public.market_cart_add(text,text,uuid) from public,authenticated;
revoke execute on function public.market_cart_list(text,text) from public,authenticated;
revoke execute on function public.market_cart_remove(text,text,uuid) from public,authenticated;
grant execute on function public.market_cart_add(text,text,uuid) to anon;
grant execute on function public.market_cart_list(text,text) to anon;
grant execute on function public.market_cart_remove(text,text,uuid) to anon;

-- 2) 대출 이자 컬럼
alter table public.bank_loans add column if not exists interest_rate numeric(5,2) not null default 0;
alter table public.bank_loans add column if not exists interest_amount bigint not null default 0;
alter table public.bank_loans add column if not exists total_due bigint not null default 0;

update public.bank_loans
set total_due=case when total_due=0 then remaining else total_due end
where total_due=0;

-- 3) 대출 신청: 기본 이자율 5%
create or replace function public.bank_loan_apply(p_no text,p_pin text,p_amount bigint,p_purpose text)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare a public.bank_accounts; l public.bank_loans; interest bigint; total bigint;
begin
 select * into a from public.bank_accounts where account_no=p_no and pin_hash=encode(extensions.digest(p_pin,'sha256'),'hex') for update;
 if not found then raise exception '본인확인에 실패했습니다.'; end if;
 if p_amount < 1 or p_amount > 10000 then raise exception '대출 금액은 1~10,000공까지 가능합니다.'; end if;
 if exists(select 1 from public.bank_loans where account_id=a.id and status in ('pending','approved')) then raise exception '이미 신청 중이거나 상환 중인 대출이 있습니다.'; end if;
 interest:=ceil(p_amount*0.05)::bigint;
 total:=p_amount+interest;
 insert into public.bank_loans(account_id,amount,remaining,purpose,interest_rate,interest_amount,total_due)
 values(a.id,p_amount,total,coalesce(trim(p_purpose),''),5.00,interest,total)
 returning * into l;
 return jsonb_build_object('id',l.id,'amount',l.amount,'remaining',l.remaining,'purpose',l.purpose,'status',l.status,'interest_rate',l.interest_rate,'interest_amount',l.interest_amount,'total_due',l.total_due);
end;
$$;

-- 4) 대출 조회
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
   'interest_rate',l.interest_rate,'interest_amount',l.interest_amount,'total_due',l.total_due,
   'requested_at',to_char(l.requested_at at time zone 'Asia/Seoul','YYYY-MM-DD HH24:MI:SS'),
   'decided_at',case when l.decided_at is null then null else to_char(l.decided_at at time zone 'Asia/Seoul','YYYY-MM-DD HH24:MI:SS') end
  ) order by l.requested_at desc) from public.bank_loans l where l.account_id=aid
 ),'[]'::jsonb));
end;
$$;

-- 5) 상환: 입력한 금액만큼 총 상환액에서 차감
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
 if p_amount > l.remaining then raise exception '상환 금액이 남은 상환액보다 많습니다.'; end if;
 new_remaining:=l.remaining-p_amount;
 update public.bank_accounts set balance=balance-p_amount where id=a.id;
 insert into public.bank_transactions(account_id,type,amount) values(a.id,'withdraw',p_amount);
 update public.bank_loans set remaining=new_remaining,status=case when new_remaining=0 then 'paid' else 'approved' end,paid_at=case when new_remaining=0 then now() else null end where id=l.id;
 return jsonb_build_object('loan_id',l.id,'paid',p_amount,'remaining',new_remaining,'interest_amount',l.interest_amount);
end;
$$;

-- 관리자 목록도 이자 표시 가능
create or replace function public.bank_admin_loan_list(p_code text)
returns jsonb language plpgsql security definer set search_path=''
as $$
begin
 if not public.bank_admin_login(p_code) then raise exception '관리자 코드가 올바르지 않습니다.'; end if;
 return jsonb_build_object('loans',coalesce((
  select jsonb_agg(jsonb_build_object(
   'id',l.id,'no',a.account_no,'name',a.name,'amount',l.amount,'remaining',l.remaining,'purpose',l.purpose,'status',l.status,
   'interest_rate',l.interest_rate,'interest_amount',l.interest_amount,'total_due',l.total_due,
   'requested_at',to_char(l.requested_at at time zone 'Asia/Seoul','YYYY-MM-DD HH24:MI:SS')
  ) order by l.requested_at desc)
  from public.bank_loans l join public.bank_accounts a on a.id=l.account_id
 ),'[]'::jsonb));
end;
$$;

revoke execute on function public.bank_loan_apply(text,text,bigint,text) from public,authenticated;
revoke execute on function public.bank_loan_my(text,text) from public,authenticated;
revoke execute on function public.bank_loan_repay(text,text,uuid,bigint) from public,authenticated;
revoke execute on function public.bank_admin_loan_list(text) from public,authenticated;
grant execute on function public.bank_loan_apply(text,text,bigint,text) to anon;
grant execute on function public.bank_loan_my(text,text) to anon;
grant execute on function public.bank_loan_repay(text,text,uuid,bigint) to anon;
grant execute on function public.bank_admin_loan_list(text) to anon;
notify pgrst,'reload schema';