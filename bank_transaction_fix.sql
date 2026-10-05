-- AGORA CAPITAL
-- Fix: 입금 / 출금 RPC
-- Supabase SQL Editor에서 이 파일 전체를 실행하세요.

drop function if exists public.bank_transaction(text,text,text,bigint);
drop function if exists public.bank_transaction(text,text,text,bigint,text);

create or replace function public.bank_transaction(
  p_no text,
  p_pin text,
  p_type text,
  p_amount bigint,
  p_admin_code text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  a public.bank_accounts;
  new_balance bigint;
begin
  -- 관리자 승인
  if not public.bank_admin_login(trim(coalesce(p_admin_code,''))) then
    raise exception '관리자 승인 코드가 올바르지 않습니다.';
  end if;

  -- 거래 종류 / 금액 검증
  if p_type not in ('deposit','withdraw') then
    raise exception '잘못된 거래 유형입니다.';
  end if;

  if p_amount is null or p_amount < 1 then
    raise exception '1공 이상의 금액을 입력하세요.';
  end if;

  -- 계좌 + 고유번호 확인 후 행 잠금
  select *
    into a
    from public.bank_accounts
   where account_no = trim(p_no)
     and pin_hash = encode(
       extensions.digest(p_pin, 'sha256'),
       'hex'
     )
   for update;

  if not found then
    raise exception '본인확인에 실패했습니다.';
  end if;

  -- 출금: 잔액보다 많이 출금할 수 없음
  if p_type = 'withdraw' and a.balance < p_amount then
    raise exception '잔액이 부족합니다.';
  end if;

  -- 입금: bigint 최대값 초과 방지
  if p_type = 'deposit'
     and a.balance > 9223372036854775807::bigint - p_amount then
    raise exception '입금 후 잔액이 너무 커서 처리할 수 없습니다.';
  end if;

  if p_type = 'deposit' then
    new_balance := a.balance + p_amount;
  else
    new_balance := a.balance - p_amount;
  end if;

  update public.bank_accounts
     set balance = new_balance
   where id = a.id;

  insert into public.bank_transactions(account_id, type, amount)
  values (a.id, p_type, p_amount);

  return jsonb_build_object(
    'success', true,
    'account', jsonb_build_object(
      'id', a.id,
      'no', a.account_no,
      'name', a.name,
      'balance', new_balance
    ),
    'type', p_type,
    'amount', p_amount
  );
end;
$$;

revoke all on function public.bank_transaction(text,text,text,bigint,text)
from public, authenticated;

grant execute on function public.bank_transaction(text,text,text,bigint,text)
to anon;

notify pgrst, 'reload schema';
