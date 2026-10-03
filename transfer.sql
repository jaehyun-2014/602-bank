-- 아고라 은행 회원 송금 기능
-- Supabase SQL Editor에서 이 파일 전체를 한 번 실행하세요.
-- 구조: 보내기 -> 보낸 사람 즉시 차감 -> 상대방 수신 대기
-- 받기 -> 상대방 입금 / 거절 -> 보낸 사람에게 자동 반환

create table if not exists public.bank_transfers (
  id uuid primary key default gen_random_uuid(),
  sender_account_id uuid not null references public.bank_accounts(id) on delete cascade,
  receiver_account_id uuid not null references public.bank_accounts(id) on delete cascade,
  amount bigint not null check (amount > 0),
  status text not null default 'pending'
    check (status in ('pending','accepted','rejected')),
  created_at timestamptz not null default now(),
  completed_at timestamptz
);

create index if not exists bank_transfers_sender_idx
  on public.bank_transfers(sender_account_id, created_at desc);

create index if not exists bank_transfers_receiver_idx
  on public.bank_transfers(receiver_account_id, created_at desc);

alter table public.bank_transfers enable row level security;
revoke all on table public.bank_transfers from anon, authenticated;

create or replace function public.bank_transfer_send(
  p_sender_no text,
  p_sender_pin text,
  p_recipient_name text,
  p_amount bigint
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  sender public.bank_accounts;
  receiver public.bank_accounts;
  receiver_count integer;
  transfer_id uuid;
begin
  if p_amount is null or p_amount < 1 then
    raise exception '1공 이상의 금액을 입력하세요.';
  end if;

  if p_recipient_name is null or length(trim(p_recipient_name)) = 0 then
    raise exception '받는 사람 이름을 입력하세요.';
  end if;

  select *
  into sender
  from public.bank_accounts
  where account_no = p_sender_no
    and pin_hash = encode(extensions.digest(p_sender_pin,'sha256'),'hex')
  for update;

  if not found then
    raise exception '보내는 사람 본인확인에 실패했습니다.';
  end if;

  select count(*)
  into receiver_count
  from public.bank_accounts
  where name = trim(p_recipient_name);

  if receiver_count = 0 then
    raise exception '해당 이름의 회원을 찾을 수 없습니다.';
  end if;

  if receiver_count > 1 then
    raise exception '같은 이름의 회원이 여러 명입니다. 관리자에게 계좌 이름을 확인해 주세요.';
  end if;

  select *
  into receiver
  from public.bank_accounts
  where name = trim(p_recipient_name)
  limit 1;

  if receiver.id = sender.id then
    raise exception '자기 자신에게는 송금할 수 없습니다.';
  end if;

  if sender.balance < p_amount then
    raise exception '잔액이 부족합니다.';
  end if;

  update public.bank_accounts
  set balance = balance - p_amount
  where id = sender.id;

  insert into public.bank_transfers(
    sender_account_id,
    receiver_account_id,
    amount,
    status
  )
  values(
    sender.id,
    receiver.id,
    p_amount,
    'pending'
  )
  returning id into transfer_id;

  return jsonb_build_object(
    'id', transfer_id,
    'status', 'pending',
    'amount', p_amount,
    'receiver_name', receiver.name,
    'sender_balance', sender.balance - p_amount
  );
end;
$$;

create or replace function public.bank_transfer_accept(
  p_no text,
  p_pin text,
  p_transfer_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  receiver public.bank_accounts;
  transfer public.bank_transfers;
  new_balance bigint;
begin
  select *
  into receiver
  from public.bank_accounts
  where account_no = p_no
    and pin_hash = encode(extensions.digest(p_pin,'sha256'),'hex')
  for update;

  if not found then
    raise exception '본인확인에 실패했습니다.';
  end if;

  select *
  into transfer
  from public.bank_transfers
  where id = p_transfer_id
    and receiver_account_id = receiver.id
    and status = 'pending'
  for update;

  if not found then
    raise exception '이미 처리되었거나 받을 수 없는 송금입니다.';
  end if;

  new_balance := receiver.balance + transfer.amount;

  update public.bank_accounts
  set balance = new_balance
  where id = receiver.id;

  update public.bank_transfers
  set status = 'accepted',
      completed_at = now()
  where id = transfer.id;

  return jsonb_build_object(
    'id', transfer.id,
    'status', 'accepted',
    'amount', transfer.amount,
    'balance', new_balance
  );
end;
$$;

create or replace function public.bank_transfer_reject(
  p_no text,
  p_pin text,
  p_transfer_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  receiver public.bank_accounts;
  transfer public.bank_transfers;
  sender public.bank_accounts;
  new_balance bigint;
begin
  select *
  into receiver
  from public.bank_accounts
  where account_no = p_no
    and pin_hash = encode(extensions.digest(p_pin,'sha256'),'hex')
  for update;

  if not found then
    raise exception '본인확인에 실패했습니다.';
  end if;

  select *
  into transfer
  from public.bank_transfers
  where id = p_transfer_id
    and receiver_account_id = receiver.id
    and status = 'pending'
  for update;

  if not found then
    raise exception '이미 처리되었거나 거절할 수 없는 송금입니다.';
  end if;

  select *
  into sender
  from public.bank_accounts
  where id = transfer.sender_account_id
  for update;

  if not found then
    raise exception '송금한 계좌를 찾을 수 없어 반환할 수 없습니다.';
  end if;

  new_balance := sender.balance + transfer.amount;

  update public.bank_accounts
  set balance = new_balance
  where id = sender.id;

  update public.bank_transfers
  set status = 'rejected',
      completed_at = now()
  where id = transfer.id;

  return jsonb_build_object(
    'id', transfer.id,
    'status', 'rejected',
    'amount', transfer.amount,
    'sender_balance', new_balance
  );
end;
$$;

-- 기존 회원 로그인 함수에 송금내역을 함께 넣습니다.
create or replace function public.bank_member_login(
  p_no text,
  p_name text,
  p_pin text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  a public.bank_accounts;
begin
  select *
  into a
  from public.bank_accounts
  where account_no = p_no
    and name = p_name
    and pin_hash = encode(extensions.digest(p_pin,'sha256'),'hex');

  if not found then
    raise exception '계좌번호, 이름 또는 고유번호가 올바르지 않습니다.';
  end if;

  return jsonb_build_object(
    'account',
    jsonb_build_object(
      'id', a.id,
      'no', a.account_no,
      'name', a.name,
      'balance', a.balance
    ),
    'tx',
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'type', t.type,
          'amount', t.amount,
          'date', to_char(
            t.created_at at time zone 'Asia/Seoul',
            'YYYY-MM-DD HH24:MI:SS'
          )
        )
        order by t.created_at desc
      )
      from public.bank_transactions t
      where t.account_id = a.id
    ), '[]'::jsonb),
    'transfers',
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id', tr.id,
          'sender_id', tr.sender_account_id,
          'receiver_id', tr.receiver_account_id,
          'sender_name', sa.name,
          'receiver_name', ra.name,
          'amount', tr.amount,
          'status', tr.status,
          'date', to_char(
            tr.created_at at time zone 'Asia/Seoul',
            'YYYY-MM-DD HH24:MI:SS'
          )
        )
        order by tr.created_at desc
      )
      from public.bank_transfers tr
      join public.bank_accounts sa
        on sa.id = tr.sender_account_id
      join public.bank_accounts ra
        on ra.id = tr.receiver_account_id
      where tr.sender_account_id = a.id
         or tr.receiver_account_id = a.id
    ), '[]'::jsonb)
  );
end;
$$;

revoke execute on function public.bank_transfer_send(text,text,text,bigint)
from public, authenticated;

revoke execute on function public.bank_transfer_accept(text,text,uuid)
from public, authenticated;

revoke execute on function public.bank_transfer_reject(text,text,uuid)
from public, authenticated;

revoke execute on function public.bank_member_login(text,text,text)
from public, authenticated;

grant execute on function public.bank_transfer_send(text,text,text,bigint)
to anon;

grant execute on function public.bank_transfer_accept(text,text,uuid)
to anon;

grant execute on function public.bank_transfer_reject(text,text,uuid)
to anon;

grant execute on function public.bank_member_login(text,text,text)
to anon;

grant usage on schema public to anon;

notify pgrst, 'reload schema';
