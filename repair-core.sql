-- AGORA CAPITAL 핵심 기능 복구 SQL
-- Supabase SQL Editor에서 이 파일 전체를 한 번만 실행하세요.

create extension if not exists pgcrypto with schema extensions;

-- 1. 회원 로그인
drop function if exists public.bank_member_login(text,text,text);

create or replace function public.bank_member_login(
  p_no text,
  p_name text,
  p_pin text
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare a public.bank_accounts;
begin
  select * into a
  from public.bank_accounts
  where account_no=trim(p_no)
    and name=trim(p_name)
    and pin_hash=encode(extensions.digest(p_pin,'sha256'),'hex');

  if not found then
    raise exception '계좌번호, 이름 또는 고유번호가 올바르지 않습니다.';
  end if;

  return jsonb_build_object(
    'account',jsonb_build_object(
      'id',a.id,
      'no',a.account_no,
      'name',a.name,
      'balance',a.balance
    ),
    'tx',coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'type',t.type,
          'amount',t.amount,
          'date',to_char(
            t.created_at at time zone 'Asia/Seoul',
            'YYYY-MM-DD HH24:MI:SS'
          )
        )
        order by t.created_at desc
      )
      from public.bank_transactions t
      where t.account_id=a.id
    ),'[]'::jsonb),
    'transfers',coalesce(
      (
        select jsonb_agg(to_jsonb(x) order by x.created_at desc)
        from (
          select
            tr.id,
            tr.sender_account_id,
            tr.recipient_account_id,
            tr.amount,
            tr.status,
            tr.created_at
          from public.bank_transfers tr
          where tr.sender_account_id=a.id
             or tr.recipient_account_id=a.id
        ) x
      ),
      '[]'::jsonb
    )
  );
end;
$$;

revoke execute on function public.bank_member_login(text,text,text)
from public,authenticated;

grant execute on function public.bank_member_login(text,text,text)
to anon;


-- 2. 시장 조회
drop function if exists public.market_browse(text,text,text);

create or replace function public.market_browse(
  p_category text default 'all',
  p_no text default '',
  p_pin text default ''
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
begin
  return jsonb_build_object(
    'items',
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id',m.id,
          'title',m.title,
          'description',m.description,
          'category',m.category,
          'price',m.price,
          'preview_url',m.preview_url,
          'download_url',m.download_url,
          'seller_name',a.name,
          'shop_name',coalesce(sh.name,''),
          'shop_description',coalesce(sh.description,''),
          'like_count',(
            select count(*)
            from public.market_likes l
            where l.item_id=m.id
          ),
          'liked',exists(
            select 1
            from public.market_likes l2
            where l2.item_id=m.id
              and l2.account_id=(
                select id
                from public.bank_accounts
                where account_no=trim(p_no)
                  and pin_hash=encode(
                    extensions.digest(p_pin,'sha256'),
                    'hex'
                  )
                limit 1
              )
          )
        )
        order by m.created_at desc
      )
      from public.market_items m
      join public.bank_accounts a
        on a.id=m.seller_account_id
      left join public.market_shops sh
        on sh.id=m.shop_id
        and sh.active=true
      where m.active=true
        and (
          coalesce(p_category,'all')='all'
          or m.category=p_category
        )
    ),'[]'::jsonb)
  );
end;
$$;

revoke execute on function public.market_browse(text,text,text)
from public,authenticated;

grant execute on function public.market_browse(text,text,text)
to anon;


-- 3. 주식 조회
drop function if exists public.stock_browse(text,text);

create or replace function public.stock_browse(
  p_no text default '',
  p_pin text default ''
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  a public.bank_accounts;
  has_member boolean:=false;
begin

  if coalesce(trim(p_no),'')<>'' then
    select * into a
    from public.bank_accounts
    where account_no=trim(p_no)
      and pin_hash=encode(
        extensions.digest(p_pin,'sha256'),
        'hex'
      );

    if not found then
      raise exception '주식 로그인에 실패했습니다.';
    end if;

    has_member:=true;
  end if;

  return jsonb_build_object(
    'stocks',
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id',s.id,
          'symbol',s.symbol,
          'name',sh.name,
          'description',
            '아고라 시장의 "'||sh.name||'" 가게 주식',
          'shop_id',sh.id,
          'price',s.price,
          'previous_price',s.previous_price,
          'change_percent',
            round(
              (
                (s.price-s.previous_price)::numeric
                / nullif(s.previous_price,0)
              )*100,
              2
            ),
          'updated_at',s.updated_at,
          'history',coalesce((
            select jsonb_agg(hx.price order by hx.recorded_at asc)
            from (
              select h.price,h.recorded_at
              from public.agora_stock_history h
              where h.stock_id=s.id
              order by h.recorded_at desc
              limit 20
            ) hx
          ),'[]'::jsonb),
          'shares',
            case when has_member then
              coalesce((
                select h.shares
                from public.agora_stock_holdings h
                where h.account_id=a.id
                  and h.stock_id=s.id
              ),0)
            else 0 end,
          'avg_buy_price',
            case when has_member then
              coalesce((
                select h.avg_buy_price
                from public.agora_stock_holdings h
                where h.account_id=a.id
                  and h.stock_id=s.id
              ),0)
            else 0 end
        )
        order by sh.name
      )
      from public.agora_stocks s
      join public.market_shops sh
        on sh.id=s.shop_id
       and sh.active=true
      where s.active=true
    ),'[]'::jsonb)
  );
end;
$$;

revoke execute on function public.stock_browse(text,text)
from public,authenticated;

grant execute on function public.stock_browse(text,text)
to anon;

grant usage on schema public to anon;

notify pgrst,'reload schema';
