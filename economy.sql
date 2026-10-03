-- 아고라 케피털 : 학급용 경제점수 / 신용정보
-- 실제 금융기관의 신용평가가 아닌 게임용 지표입니다.

create or replace function public.bank_economy_info(p_no text,p_pin text)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
 a public.bank_accounts;
 deposit_count bigint:=0;
 withdraw_count bigint:=0;
 market_purchase_count bigint:=0;
 loan_status text:='없음';
 loan_penalty bigint:=0;
 score bigint;
 level text;
 credit_status text;
begin
 select * into a from public.bank_accounts
 where account_no=p_no
 and pin_hash=encode(extensions.digest(p_pin,'sha256'),'hex');
 if not found then raise exception '본인확인에 실패했습니다.'; end if;

 select count(*) filter(where type='deposit'),count(*) filter(where type='withdraw')
 into deposit_count,withdraw_count
 from public.bank_transactions where account_id=a.id;

 if to_regclass('public.market_purchases') is not null then
   select count(*) into market_purchase_count
   from public.market_purchases where buyer_account_id=a.id;
 end if;

 if to_regclass('public.bank_loans') is not null then
   select case
    when exists(select 1 from public.bank_loans where account_id=a.id and status='approved') then '상환 중'
    when exists(select 1 from public.bank_loans where account_id=a.id and status='pending') then '심사 대기'
    when exists(select 1 from public.bank_loans where account_id=a.id and status='paid') then '상환 완료'
    when exists(select 1 from public.bank_loans where account_id=a.id and status='rejected') then '거절 기록 있음'
    else '없음' end
   into loan_status;

   if exists(select 1 from public.bank_loans where account_id=a.id and status='approved') then loan_penalty:=80;
   elsif exists(select 1 from public.bank_loans where account_id=a.id and status='pending') then loan_penalty:=30;
   end if;
 end if;

 score:=500
   + least(250,greatest(0,a.balance/4))
   + least(100,deposit_count*8)
   + least(50,market_purchase_count*5)
   - least(50,withdraw_count*2)
   - loan_penalty
   + case when loan_status='상환 완료' then 80 else 0 end;

 score:=greatest(0,least(1000,score));

 level:=case
   when score>=850 then '경제관리 우수'
   when score>=700 then '경제관리 양호'
   when score>=500 then '경제관리 보통'
   when score>=300 then '경제관리 주의'
   else '경제관리 점검'
 end;

 credit_status:=case
   when loan_status='상환 중' then '대출 상환 중'
   when loan_status='심사 대기' then '대출 심사 중'
   when loan_status='상환 완료' then '대출 상환 완료'
   when loan_status='거절 기록 있음' then '대출 기록 있음'
   else '대출 이용 기록 없음'
 end;

 return jsonb_build_object(
   'score',score,
   'level',level,
   'credit_status',credit_status,
   'balance',a.balance,
   'deposit_count',deposit_count,
   'withdraw_count',withdraw_count,
   'market_purchase_count',market_purchase_count,
   'loan_status',loan_status
 );
end;
$$;

create or replace function public.bank_admin_economy_list(p_code text)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
begin
 if not public.bank_admin_login(p_code) then
   raise exception '관리자 코드가 올바르지 않습니다.';
 end if;

 return jsonb_build_object('members',coalesce((
  select jsonb_agg(x order by (x->>'score')::int desc)
  from (
   select jsonb_build_object(
    'no',a.account_no,
    'name',a.name,
    'score',(
      500
      + least(250,greatest(0,a.balance/4))
      + least(100,(select count(*) from public.bank_transactions t where t.account_id=a.id and t.type='deposit')*8)
      + least(50,case when to_regclass('public.market_purchases') is not null then (select count(*) from public.market_purchases p where p.buyer_account_id=a.id)*5 else 0 end)
      - least(50,(select count(*) from public.bank_transactions t where t.account_id=a.id and t.type='withdraw')*2)
    )
   ) as x
   from public.bank_accounts a
  ) q
 ),'[]'::jsonb));
end;
$$;

revoke execute on function public.bank_economy_info(text,text) from public,authenticated;
revoke execute on function public.bank_admin_economy_list(text) from public,authenticated;
grant execute on function public.bank_economy_info(text,text) to anon;
grant execute on function public.bank_admin_economy_list(text) to anon;

notify pgrst,'reload schema';
