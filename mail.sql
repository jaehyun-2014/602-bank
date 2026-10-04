-- 아고라 메일: 반 친구들 전용 이메일 시스템
create table if not exists public.agora_mail (
  id uuid primary key default gen_random_uuid(),
  sender_account_id uuid not null references public.bank_accounts(id) on delete cascade,
  recipient_account_id uuid not null references public.bank_accounts(id) on delete cascade,
  subject text not null,
  body text not null,
  sent_at timestamptz not null default now(),
  read_at timestamptz
);

create index if not exists agora_mail_recipient_idx on public.agora_mail(recipient_account_id,sent_at desc);
create index if not exists agora_mail_sender_idx on public.agora_mail(sender_account_id,sent_at desc);

alter table public.agora_mail enable row level security;
revoke all on table public.agora_mail from anon, authenticated;

drop function if exists public.mail_send(text,text,text,text);
drop function if exists public.mail_inbox(text,text);
drop function if exists public.mail_sent(text,text);
drop function if exists public.mail_read(text,text,uuid);

create function public.mail_send(
  p_no text,p_pin text,p_to text,p_subject text,p_body text
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  sender public.bank_accounts;
  recipient public.bank_accounts;
  recipient_no text;
  v_id uuid;
begin
  select * into sender from public.bank_accounts
  where account_no=p_no
    and pin_hash=encode(extensions.digest(p_pin,'sha256'),'hex');
  if not found then raise exception '본인확인에 실패했습니다.'; end if;

  if p_to !~* '^[0-9]{3}-[0-9]{3}@agora\.local$' then
    raise exception '아고라 메일 주소 형식이 올바르지 않습니다. 예: 602-739@agora.local';
  end if;

  recipient_no=split_part(lower(trim(p_to)),'@',1);

  select * into recipient from public.bank_accounts
  where lower(account_no)=lower(recipient_no);
  if not found then raise exception '받는 사람을 찾을 수 없습니다.'; end if;

  if recipient.id=sender.id then raise exception '자기 자신에게 메일을 보낼 수 없습니다.'; end if;
  if length(trim(p_subject))<1 or length(trim(p_subject))>100 then raise exception '제목은 1~100자로 입력하세요.'; end if;
  if length(trim(p_body))<1 or length(p_body)>5000 then raise exception '메일 내용은 1~5000자로 입력하세요.'; end if;

  insert into public.agora_mail(sender_account_id,recipient_account_id,subject,body)
  values(sender.id,recipient.id,trim(p_subject),trim(p_body))
  returning id into v_id;

  return jsonb_build_object('id',v_id,'to',recipient.account_no);
end;
$$;

create function public.mail_inbox(
  p_no text,p_pin text
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare me public.bank_accounts;
begin
  select * into me from public.bank_accounts
  where account_no=p_no
    and pin_hash=encode(extensions.digest(p_pin,'sha256'),'hex');
  if not found then raise exception '본인확인에 실패했습니다.'; end if;

  return jsonb_build_object('messages',coalesce((
    select jsonb_agg(jsonb_build_object(
      'id',m.id,
      'subject',m.subject,
      'body',m.body,
      'read_at',m.read_at,
      'other_name',s.name,
      'other_address',lower(s.account_no)||'@agora.local',
      'date',to_char(m.sent_at at time zone 'Asia/Seoul','YYYY-MM-DD HH24:MI')
    ) order by m.sent_at desc)
    from public.agora_mail m
    join public.bank_accounts s on s.id=m.sender_account_id
    where m.recipient_account_id=me.id
  ),'[]'::jsonb));
end;
$$;

create function public.mail_sent(
  p_no text,p_pin text
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare me public.bank_accounts;
begin
  select * into me from public.bank_accounts
  where account_no=p_no
    and pin_hash=encode(extensions.digest(p_pin,'sha256'),'hex');
  if not found then raise exception '본인확인에 실패했습니다.'; end if;

  return jsonb_build_object('messages',coalesce((
    select jsonb_agg(jsonb_build_object(
      'id',m.id,
      'subject',m.subject,
      'body',m.body,
      'read_at',m.read_at,
      'other_name',r.name,
      'other_address',lower(r.account_no)||'@agora.local',
      'date',to_char(m.sent_at at time zone 'Asia/Seoul','YYYY-MM-DD HH24:MI')
    ) order by m.sent_at desc)
    from public.agora_mail m
    join public.bank_accounts r on r.id=m.recipient_account_id
    where m.sender_account_id=me.id
  ),'[]'::jsonb));
end;
$$;

create function public.mail_read(
  p_no text,p_pin text,p_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare me public.bank_accounts;
declare m public.agora_mail;
declare s public.bank_accounts;
begin
  select * into me from public.bank_accounts
  where account_no=p_no
    and pin_hash=encode(extensions.digest(p_pin,'sha256'),'hex');
  if not found then raise exception '본인확인에 실패했습니다.'; end if;

  select * into m from public.agora_mail
  where id=p_id
    and (recipient_account_id=me.id or sender_account_id=me.id);
  if not found then raise exception '메일을 찾을 수 없습니다.'; end if;

  if m.recipient_account_id=me.id then
    update public.agora_mail set read_at=coalesce(read_at,now()) where id=m.id;
  end if;

  select * into s from public.bank_accounts where id=m.sender_account_id;

  return jsonb_build_object(
    'id',m.id,
    'subject',m.subject,
    'body',m.body,
    'sender_name',s.name,
    'sender_address',lower(s.account_no)||'@agora.local',
    'date',to_char(m.sent_at at time zone 'Asia/Seoul','YYYY-MM-DD HH24:MI')
  );
end;
$$;

revoke execute on function public.mail_send(text,text,text,text,text) from public,authenticated;
revoke execute on function public.mail_inbox(text,text) from public,authenticated;
revoke execute on function public.mail_sent(text,text) from public,authenticated;
revoke execute on function public.mail_read(text,text,uuid) from public,authenticated;

grant execute on function public.mail_send(text,text,text,text,text) to anon;
grant execute on function public.mail_inbox(text,text) to anon;
grant execute on function public.mail_sent(text,text) to anon;
grant execute on function public.mail_read(text,text,uuid) to anon;

grant usage on schema public to anon;
notify pgrst,'reload schema';
