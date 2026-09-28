-- ==========================================================
-- Mensajes de la pagina de aniversario
-- ==========================================================
-- Se ejecuta UNA vez en Supabase > SQL Editor (proyecto compartido
-- con Habitos y Mi Semana; solo crea cosas con prefijo aniversario_).
-- Se puede volver a ejecutar sin romper nada.
--
-- Quien puede leer y escribir: solo las cuentas que esten en la
-- tabla aniversario_miembros (abajo, al final). Cualquier otra
-- cuenta que alguien cree desde la pagina no ve ni escribe nada.

create extension if not exists pg_net with schema extensions;

-- ---------- Miembros ----------
-- Nadie la puede leer desde la pagina (RLS sin politicas): asi los
-- topics de ntfy no quedan expuestos.
create table if not exists public.aniversario_miembros (
  email       text primary key,               -- <usuario>@almendrito.github.io
  nombre      text not null,                  -- como aparece en los mensajes
  lado        text not null check (lado in ('walle', 'eva')),
  ntfy_topic  text                            -- null = sin notificaciones
);
alter table public.aniversario_miembros enable row level security;

-- ---------- Mensajes ----------
create table if not exists public.aniversario_mensajes (
  id            bigint generated always as identity primary key,
  created_at    timestamptz not null default now(),
  autor         uuid not null default auth.uid(),
  autor_nombre  text not null,
  autor_lado    text not null,
  texto         text not null check (char_length(texto) between 1 and 2000),
  respuesta_a   bigint references public.aniversario_mensajes (id) on delete cascade
);
create index if not exists aniversario_mensajes_respuesta_idx
  on public.aniversario_mensajes (respuesta_a);
alter table public.aniversario_mensajes enable row level security;

-- ¿La cuenta con la que se entro es de uno de los dos?
create or replace function public.aniversario_es_miembro()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.aniversario_miembros
    where email = lower(auth.jwt() ->> 'email')
  );
$$;
revoke all on function public.aniversario_es_miembro() from public, anon;
grant execute on function public.aniversario_es_miembro() to authenticated;

-- Politicas: leer y escribir solo miembros; borrar solo lo propio
drop policy if exists "leer miembros" on public.aniversario_mensajes;
create policy "leer miembros" on public.aniversario_mensajes
  for select to authenticated
  using (public.aniversario_es_miembro());

drop policy if exists "escribir miembros" on public.aniversario_mensajes;
create policy "escribir miembros" on public.aniversario_mensajes
  for insert to authenticated
  with check (public.aniversario_es_miembro() and autor = auth.uid());

drop policy if exists "borrar lo propio" on public.aniversario_mensajes;
create policy "borrar lo propio" on public.aniversario_mensajes
  for delete to authenticated
  using (autor = auth.uid());

revoke all on public.aniversario_mensajes from anon;
grant select, insert, delete on public.aniversario_mensajes to authenticated;

-- Antes de guardar: el autor y su nombre los pone la base (no se
-- pueden falsificar desde la pagina) y las respuestas tienen un
-- solo nivel (se responde a un mensaje, no a una respuesta).
create or replace function public.aniversario_antes_de_insertar()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  m public.aniversario_miembros;
begin
  select * into m from public.aniversario_miembros
  where email = lower(auth.jwt() ->> 'email');
  if not found then
    raise exception 'cuenta no autorizada';
  end if;

  new.autor := auth.uid();
  new.autor_nombre := m.nombre;
  new.autor_lado := m.lado;
  new.created_at := now();

  if new.respuesta_a is not null and exists (
    select 1 from public.aniversario_mensajes
    where id = new.respuesta_a and respuesta_a is not null
  ) then
    raise exception 'solo se puede responder a un mensaje principal';
  end if;
  return new;
end $$;

drop trigger if exists aniversario_antes_de_insertar on public.aniversario_mensajes;
create trigger aniversario_antes_de_insertar
  before insert on public.aniversario_mensajes
  for each row execute function public.aniversario_antes_de_insertar();

-- Despues de guardar: aviso por ntfy a la otra persona. El texto
-- del mensaje NO se manda, solo quien escribio.
create or replace function public.aniversario_notificar()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  destino record;
begin
  for destino in
    select ntfy_topic from public.aniversario_miembros
    where ntfy_topic is not null and nombre <> new.autor_nombre
  loop
    perform net.http_post(
      url  := 'https://ntfy.sh',
      body := jsonb_build_object(
        'topic',   destino.ntfy_topic,
        'title',   'Directiva: mensaje nuevo',
        'message', case when new.respuesta_a is null
                        then new.autor_nombre || ' te dejo un mensaje.'
                        else new.autor_nombre || ' respondio un mensaje.' end,
        'click',   'https://almendrito.github.io/aniversario-web/#mensajes'
      )
    );
  end loop;
  return new;
end $$;

drop trigger if exists aniversario_notificar on public.aniversario_mensajes;
create trigger aniversario_notificar
  after insert on public.aniversario_mensajes
  for each row execute function public.aniversario_notificar();

-- ---------- Quienes son ----------
-- EDITA AQUI: usuario (antes de @), nombre visible, lado y topic de
-- ntfy. El topic es como una clave: inventa uno largo y al azar, y
-- NO lo subas a GitHub (este archivo es publico; edita solo la copia
-- que pegas en el SQL Editor).
insert into public.aniversario_miembros (email, nombre, lado, ntfy_topic) values
  ('mateo@almendrito.github.io',  'Mateo',  'walle', 'CAMBIA-POR-TU-TOPIC'),
  ('ayleen@almendrito.github.io', 'Ayleen', 'eva',   null)
on conflict (email) do update
  set nombre = excluded.nombre,
      lado = excluded.lado,
      ntfy_topic = excluded.ntfy_topic;
