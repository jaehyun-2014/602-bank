-- 아고라 케피털 허가 광고 시스템
create table if not exists public.agora_ads (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  description text not null default '',
  sponsor text not null,
  url text not null,
  approved boolean not null default false,
  created_at timestamptz not null default now()
);
alter table public.agora_ads enable row level security;
revoke all on table public.agora_ads from anon, authenticated;

create or replace function public.ad_browse()
returns jsonb language sql security definer set search_path=''
as $$
 select jsonb_build_object('ads',coalesce((
   select jsonb_agg(jsonb_build_object('id',a.id,'title',a.title,'description',a.description,'sponsor',a.sponsor,'url',a.url,'approved',a.approved) order by a.created_at desc)
   from public.agora_ads a where a.approved=true
 ),'[]'::jsonb));
$$;

create or replace function public.ad_admin_list(p_code text)
returns jsonb language plpgsql security definer set search_path=''
as $$
begin
 if not public.bank_admin_login(p_code) then raise exception '관리자 코드가 올바르지 않습니다.'; end if;
 return jsonb_build_object('ads',coalesce((
  select jsonb_agg(jsonb_build_object('id',a.id,'title',a.title,'description',a.description,'sponsor',a.sponsor,'url',a.url,'approved',a.approved,'created_at',a.created_at) order by a.created_at desc)
  from public.agora_ads a
 ),'[]'::jsonb));
end;
$$;

create or replace function public.ad_admin_add(p_code text,p_title text,p_description text,p_sponsor text,p_url text)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare a public.agora_ads;
begin
 if not public.bank_admin_login(p_code) then raise exception '관리자 코드가 올바르지 않습니다.'; end if;
 if length(trim(p_title))<1 or length(trim(p_title))>80 then raise exception '광고 제목은 1~80자로 입력하세요.'; end if;
 if length(trim(p_sponsor))<1 or length(trim(p_sponsor))>80 then raise exception '광고주는 1~80자로 입력하세요.'; end if;
 if length(coalesce(p_description,''))>200 then raise exception '광고 설명은 200자 이하로 입력하세요.'; end if;
 if trim(p_url) !~* '^https?://[^[:space:]]+$' then raise exception '광고 링크는 http:// 또는 https:// 주소여야 합니다.'; end if;
 insert into public.agora_ads(title,description,sponsor,url) values(trim(p_title),trim(coalesce(p_description,'')),trim(p_sponsor),trim(p_url)) returning * into a;
 return jsonb_build_object('id',a.id,'title',a.title,'approved',a.approved);
end;
$$;

create or replace function public.ad_admin_set_approved(p_code text,p_id uuid,p_approved boolean)
returns boolean language plpgsql security definer set search_path=''
as $$
begin
 if not public.bank_admin_login(p_code) then raise exception '관리자 코드가 올바르지 않습니다.'; end if;
 update public.agora_ads set approved=p_approved where id=p_id;
 return found;
end;
$$;

create or replace function public.ad_admin_delete(p_code text,p_id uuid)
returns boolean language plpgsql security definer set search_path=''
as $$
begin
 if not public.bank_admin_login(p_code) then raise exception '관리자 코드가 올바르지 않습니다.'; end if;
 delete from public.agora_ads where id=p_id;
 return found;
end;
$$;

revoke execute on function public.ad_browse() from public,authenticated;
revoke execute on function public.ad_admin_list(text) from public,authenticated;
revoke execute on function public.ad_admin_add(text,text,text,text,text) from public,authenticated;
revoke execute on function public.ad_admin_set_approved(text,uuid,boolean) from public,authenticated;
revoke execute on function public.ad_admin_delete(text,uuid) from public,authenticated;
grant execute on function public.ad_browse() to anon;
grant execute on function public.ad_admin_list(text) to anon;
grant execute on function public.ad_admin_add(text,text,text,text,text) to anon;
grant execute on function public.ad_admin_set_approved(text,uuid,boolean) to anon;
grant execute on function public.ad_admin_delete(text,uuid) to anon;
notify pgrst,'reload schema';