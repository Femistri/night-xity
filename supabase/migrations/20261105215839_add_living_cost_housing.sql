-- GASTOS DE VIDA V1: vivienda
-- VIV-003 cuesta 450 CORPOS para tres habitantes: 150 por personaje.
-- El primer cargo es inmediato. Los siguientes siguen el ciclo de seis semanas
-- anclado al miércoles 4 de noviembre de 2026, a las 9:00 de Quintana Roo.

create extension if not exists pg_cron;

alter table public.solicitudes_gastos_vida
    drop constraint if exists solicitudes_gastos_vida_tipo_solicitud_check;

alter table public.solicitudes_gastos_vida
    add constraint solicitudes_gastos_vida_tipo_solicitud_check
    check (tipo_solicitud = any (
        array['desuscripcion', 'variable', 'evento', 'cambio_vivienda']::text[]
    ));

create or replace function public.proximo_cobro_vivienda(p_desde timestamptz)
returns timestamptz
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
    v_local timestamp;
    v_ancla timestamp := timestamp '2026-11-04 09:00:00';
    v_periodos integer;
begin
    v_local := p_desde at time zone 'America/Cancun';

    if v_local < v_ancla then
        v_periodos := 0;
    else
        v_periodos :=
            floor(extract(epoch from (v_local - v_ancla)) / 3628800)::integer + 1;
    end if;

    return (v_ancla + v_periodos * interval '42 days')
        at time zone 'America/Cancun';
end;
$$;

create or replace function public.activar_vivienda_predeterminada(
    p_personaje_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_usuario uuid := (select auth.uid());
    v_personaje public.personajes%rowtype;
    v_vivienda public.catalogo_gastos_vida%rowtype;
    v_ficha jsonb;
    v_movimientos jsonb;
    v_saldo_inicial numeric;
    v_saldo_actual numeric;
    v_costo numeric;
    v_suscripcion_id uuid;
    v_nombre text;
begin
    if v_usuario is null then
        raise exception 'Debes iniciar sesión.';
    end if;

    if not exists (
        select 1
        from public.asignaciones
        where perfil_id = v_usuario
          and personaje_id = p_personaje_id
    ) then
        raise exception 'No tienes asignado este personaje.';
    end if;

    select *
    into v_personaje
    from public.personajes
    where id = p_personaje_id
    for update;

    if not found then
        raise exception 'Personaje no encontrado.';
    end if;

    if exists (
        select 1
        from public.suscripciones_gastos_vida
        where personaje_id = p_personaje_id
          and gasto_id like 'VIV-%'
          and estado = 'activa'
    ) then
        raise exception 'Este personaje ya tiene una vivienda activa.';
    end if;

    select *
    into v_vivienda
    from public.catalogo_gastos_vida
    where id = 'VIV-003'
      and grupo = 'vivienda'
      and activo = true;

    if not found then
        raise exception 'No se encontró VIV-003 activo en el catálogo.';
    end if;

    v_costo := coalesce(
        nullif(v_vivienda.datos_originales ->> 'costo_por_persona', '')::numeric,
        v_vivienda.costo
    );

    if v_costo is null or v_costo < 0 then
        raise exception 'El costo por personaje de VIV-003 no es válido.';
    end if;

    v_ficha := coalesce(v_personaje.ficha, '{}'::jsonb);

    if jsonb_typeof(v_ficha -> 'economia') is distinct from 'object' then
        v_ficha := jsonb_set(v_ficha, '{economia}', '{}'::jsonb, true);
    end if;

    v_movimientos := coalesce(
        v_ficha #> '{economia,movimientos}',
        '[]'::jsonb
    );

    if jsonb_typeof(v_movimientos) <> 'array' then
        raise exception 'El historial económico del personaje no es válido.';
    end if;

    v_saldo_inicial :=
        coalesce(nullif(v_ficha #>> '{economia,saldo_inicial}', '')::numeric, 0);

    select v_saldo_inicial + coalesce(sum(
        case movimiento ->> 'tipo'
            when 'ingreso' then coalesce((movimiento ->> 'monto')::numeric, 0)
            when 'egreso' then -coalesce((movimiento ->> 'monto')::numeric, 0)
            else 0
        end
    ), 0)
    into v_saldo_actual
    from jsonb_array_elements(v_movimientos) as movimiento;

    if v_saldo_actual < v_costo then
        raise exception 'Saldo insuficiente. Disponible: % CORPOS.', v_saldo_actual;
    end if;

    insert into public.suscripciones_gastos_vida (
        personaje_id, gasto_id, costo, frecuencia, estado,
        fecha_solicitud, fecha_activacion, proximo_cobro, actualizado_en
    )
    values (
        p_personaje_id, v_vivienda.id, v_costo, 'cada_6_miercoles', 'activa',
        now(), now(), public.proximo_cobro_vivienda(now()), now()
    )
    on conflict (personaje_id, gasto_id)
    do update set
        costo = excluded.costo,
        frecuencia = excluded.frecuencia,
        estado = 'activa',
        fecha_solicitud = now(),
        fecha_activacion = now(),
        proximo_cobro = excluded.proximo_cobro,
        actualizado_en = now()
    returning id into v_suscripcion_id;

    v_nombre := v_personaje.nombre_clave;

    v_movimientos := v_movimientos || jsonb_build_array(
        jsonb_build_object(
            'fecha', now(),
            'tipo', 'egreso',
            'subtipo', 'COSTO_DE_VIDA',
            'monto', v_costo,
            'concepto', v_vivienda.nombre || ' — cuota por personaje',
            'catalogo_id', v_vivienda.id,
            'suscripcion_id', v_suscripcion_id,
            'quien_pago', v_nombre,
            'quien_cobro', 'GASTOS DE VIDA'
        )
    );

    v_ficha := jsonb_set(
        v_ficha,
        '{economia,movimientos}',
        v_movimientos,
        true
    );

    update public.personajes
    set ficha = v_ficha
    where id = p_personaje_id;

    return jsonb_build_object(
        'exito', true,
        'vivienda', v_vivienda.nombre,
        'cargo_inicial', v_costo,
        'saldo_actual', v_saldo_actual - v_costo,
        'proximo_cobro', public.proximo_cobro_vivienda(now())
    );
end;
$$;

create or replace function public.solicitar_cambio_vivienda(
    p_personaje_id uuid,
    p_vivienda_id text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_usuario uuid := (select auth.uid());
    v_vivienda public.catalogo_gastos_vida%rowtype;
    v_costo numeric;
    v_solicitud_id uuid;
begin
    if v_usuario is null then
        raise exception 'Debes iniciar sesión.';
    end if;

    if not exists (
        select 1
        from public.asignaciones
        where perfil_id = v_usuario
          and personaje_id = p_personaje_id
    ) then
        raise exception 'No tienes asignado este personaje.';
    end if;

    perform 1
    from public.personajes
    where id = p_personaje_id
    for update;

    if not found then
        raise exception 'Personaje no encontrado.';
    end if;

    select *
    into v_vivienda
    from public.catalogo_gastos_vida
    where id = p_vivienda_id
      and grupo = 'vivienda'
      and activo = true;

    if not found then
        raise exception 'La vivienda solicitada no está disponible.';
    end if;

    if exists (
        select 1
        from public.suscripciones_gastos_vida
        where personaje_id = p_personaje_id
          and gasto_id = p_vivienda_id
          and estado = 'activa'
    ) then
        raise exception 'Este personaje ya tiene esa vivienda activa.';
    end if;

    if exists (
        select 1
        from public.solicitudes_gastos_vida
        where personaje_id = p_personaje_id
          and tipo_solicitud = 'cambio_vivienda'
          and estado = 'pendiente'
    ) then
        raise exception 'Este personaje ya tiene un cambio de vivienda pendiente.';
    end if;

    v_costo := coalesce(
        nullif(v_vivienda.datos_originales ->> 'costo_por_persona', '')::numeric,
        v_vivienda.costo
    );

    insert into public.solicitudes_gastos_vida (
        personaje_id, gasto_id, tipo_solicitud, importe_solicitado, mensaje
    )
    values (
        p_personaje_id,
        p_vivienda_id,
        'cambio_vivienda',
        v_costo,
        'Solicitud de cambio de vivienda pendiente de revisión del DM.'
    )
    returning id into v_solicitud_id;

    return jsonb_build_object(
        'exito', true,
        'solicitud_id', v_solicitud_id,
        'estado', 'pendiente',
        'vivienda', v_vivienda.nombre,
        'costo_por_personaje', v_costo
    );
end;
$$;

create or replace function public.resolver_solicitud_vivienda(
    p_solicitud_id uuid,
    p_aprobar boolean,
    p_mensaje text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_solicitud public.solicitudes_gastos_vida%rowtype;
    v_personaje public.personajes%rowtype;
    v_vivienda public.catalogo_gastos_vida%rowtype;
    v_ficha jsonb;
    v_movimientos jsonb;
    v_saldo_inicial numeric;
    v_saldo_actual numeric;
    v_costo numeric;
    v_suscripcion_id uuid;
begin
    if (select auth.uid()) is null or not public.es_dm() then
        raise exception 'Solo el DM puede resolver solicitudes de vivienda.';
    end if;

    select *
    into v_solicitud
    from public.solicitudes_gastos_vida
    where id = p_solicitud_id
    for update;

    if not found
       or v_solicitud.tipo_solicitud <> 'cambio_vivienda'
       or v_solicitud.estado <> 'pendiente' then
        raise exception 'La solicitud no existe o ya fue resuelta.';
    end if;

    if not p_aprobar then
        update public.solicitudes_gastos_vida
        set estado = 'rechazada',
            mensaje = coalesce(nullif(p_mensaje, ''), 'Solicitud rechazada por el DM.'),
            fecha_revision = now(),
            revisado_por = (select auth.uid())
        where id = p_solicitud_id;

        return jsonb_build_object('exito', true, 'estado', 'rechazada');
    end if;

    select *
    into v_vivienda
    from public.catalogo_gastos_vida
    where id = v_solicitud.gasto_id
      and grupo = 'vivienda'
      and activo = true;

    if not found then
        raise exception 'La vivienda solicitada ya no está disponible.';
    end if;

    select *
    into v_personaje
    from public.personajes
    where id = v_solicitud.personaje_id
    for update;

    if not found then
        raise exception 'Personaje no encontrado.';
    end if;

    v_costo := coalesce(
        nullif(v_vivienda.datos_originales ->> 'costo_por_persona', '')::numeric,
        v_vivienda.costo
    );

    v_ficha := coalesce(v_personaje.ficha, '{}'::jsonb);

    if jsonb_typeof(v_ficha -> 'economia') is distinct from 'object' then
        v_ficha := jsonb_set(v_ficha, '{economia}', '{}'::jsonb, true);
    end if;

    v_movimientos := coalesce(
        v_ficha #> '{economia,movimientos}',
        '[]'::jsonb
    );

    if jsonb_typeof(v_movimientos) <> 'array' then
        raise exception 'El historial económico del personaje no es válido.';
    end if;

    v_saldo_inicial :=
        coalesce(nullif(v_ficha #>> '{economia,saldo_inicial}', '')::numeric, 0);

    select v_saldo_inicial + coalesce(sum(
        case movimiento ->> 'tipo'
            when 'ingreso' then coalesce((movimiento ->> 'monto')::numeric, 0)
            when 'egreso' then -coalesce((movimiento ->> 'monto')::numeric, 0)
            else 0
        end
    ), 0)
    into v_saldo_actual
    from jsonb_array_elements(v_movimientos) as movimiento;

    if v_saldo_actual < v_costo then
        raise exception 'Saldo insuficiente. Disponible: % CORPOS.', v_saldo_actual;
    end if;

    update public.suscripciones_gastos_vida
    set estado = 'cancelada',
        actualizado_en = now()
    where personaje_id = v_solicitud.personaje_id
      and gasto_id like 'VIV-%'
      and estado = 'activa';

    insert into public.suscripciones_gastos_vida (
        personaje_id, gasto_id, costo, frecuencia, estado,
        fecha_solicitud, fecha_activacion, proximo_cobro, actualizado_en
    )
    values (
        v_solicitud.personaje_id,
        v_vivienda.id,
        v_costo,
        'cada_6_miercoles',
        'activa',
        now(),
        now(),
        public.proximo_cobro_vivienda(now()),
        now()
    )
    on conflict (personaje_id, gasto_id)
    do update set
        costo = excluded.costo,
        frecuencia = excluded.frecuencia,
        estado = 'activa',
        fecha_solicitud = now(),
        fecha_activacion = now(),
        proximo_cobro = excluded.proximo_cobro,
        actualizado_en = now()
    returning id into v_suscripcion_id;

    v_movimientos := v_movimientos || jsonb_build_array(
        jsonb_build_object(
            'fecha', now(),
            'tipo', 'egreso',
            'subtipo', 'COSTO_DE_VIDA',
            'monto', v_costo,
            'concepto', v_vivienda.nombre || ' — cuota por personaje',
            'catalogo_id', v_vivienda.id,
            'suscripcion_id', v_suscripcion_id,
            'quien_pago', v_personaje.nombre_clave,
            'quien_cobro', 'GASTOS DE VIDA'
        )
    );

    v_ficha := jsonb_set(
        v_ficha,
        '{economia,movimientos}',
        v_movimientos,
        true
    );

    update public.personajes
    set ficha = v_ficha
    where id = v_solicitud.personaje_id;

    update public.solicitudes_gastos_vida
    set estado = 'aprobada',
        mensaje = coalesce(nullif(p_mensaje, ''), 'Solicitud aprobada por el DM.'),
        fecha_revision = now(),
        revisado_por = (select auth.uid())
    where id = p_solicitud_id;

    return jsonb_build_object(
        'exito', true,
        'estado', 'aprobada',
        'vivienda', v_vivienda.nombre,
        'cargo_inicial', v_costo,
        'saldo_actual', v_saldo_actual - v_costo,
        'proximo_cobro', public.proximo_cobro_vivienda(now())
    );
end;
$$;

create or replace function public.procesar_cobros_vivienda()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_candidato record;
    v_suscripcion public.suscripciones_gastos_vida%rowtype;
    v_personaje public.personajes%rowtype;
    v_ficha jsonb;
    v_movimientos jsonb;
    v_saldo_inicial numeric;
    v_saldo_actual numeric;
    v_cobrados integer := 0;
    v_suspendidos integer := 0;
    v_ahora timestamptz := now();
begin
    for v_candidato in
        select id, personaje_id
        from public.suscripciones_gastos_vida
        where gasto_id like 'VIV-%'
          and estado = 'activa'
          and proximo_cobro <= v_ahora
        order by proximo_cobro
    loop
        select *
        into v_personaje
        from public.personajes
        where id = v_candidato.personaje_id
        for update skip locked;

        if not found then
            continue;
        end if;

        select *
        into v_suscripcion
        from public.suscripciones_gastos_vida
        where id = v_candidato.id
        for update skip locked;

        if not found
           or v_suscripcion.estado <> 'activa'
           or v_suscripcion.proximo_cobro > v_ahora then
            continue;
        end if;

        v_ficha := coalesce(v_personaje.ficha, '{}'::jsonb);

        if jsonb_typeof(v_ficha -> 'economia') is distinct from 'object' then
            v_ficha := jsonb_set(v_ficha, '{economia}', '{}'::jsonb, true);
        end if;

        v_movimientos := coalesce(
            v_ficha #> '{economia,movimientos}',
            '[]'::jsonb
        );

        if jsonb_typeof(v_movimientos) <> 'array' then
            raise exception 'Historial económico inválido para personaje %.',
                v_personaje.id;
        end if;

        v_saldo_inicial :=
            coalesce(nullif(v_ficha #>> '{economia,saldo_inicial}', '')::numeric, 0);

        select v_saldo_inicial + coalesce(sum(
            case movimiento ->> 'tipo'
                when 'ingreso' then coalesce((movimiento ->> 'monto')::numeric, 0)
                when 'egreso' then -coalesce((movimiento ->> 'monto')::numeric, 0)
                else 0
            end
        ), 0)
        into v_saldo_actual
        from jsonb_array_elements(v_movimientos) as movimiento;

        if v_saldo_actual < v_suscripcion.costo then
            update public.suscripciones_gastos_vida
            set estado = 'suspendida',
                actualizado_en = now()
            where id = v_suscripcion.id;

            v_suspendidos := v_suspendidos + 1;
            continue;
        end if;

        v_movimientos := v_movimientos || jsonb_build_array(
            jsonb_build_object(
                'fecha', now(),
                'tipo', 'egreso',
                'subtipo', 'COSTO_DE_VIDA',
                'monto', v_suscripcion.costo,
                'concepto', 'Cobro periódico de vivienda',
                'catalogo_id', v_suscripcion.gasto_id,
                'suscripcion_id', v_suscripcion.id,
                'quien_pago', v_personaje.nombre_clave,
                'quien_cobro', 'GASTOS DE VIDA'
            )
        );

        v_ficha := jsonb_set(
            v_ficha,
            '{economia,movimientos}',
            v_movimientos,
            true
        );

        update public.personajes
        set ficha = v_ficha
        where id = v_personaje.id;

        update public.suscripciones_gastos_vida
        set proximo_cobro = public.proximo_cobro_vivienda(v_ahora),
            actualizado_en = now()
        where id = v_suscripcion.id;

        v_cobrados := v_cobrados + 1;
    end loop;

    return jsonb_build_object(
        'cobrados', v_cobrados,
        'suspendidos_por_saldo', v_suspendidos
    );
end;
$$;

revoke all on function public.proximo_cobro_vivienda(timestamptz)
    from public, anon, authenticated;
revoke all on function public.activar_vivienda_predeterminada(uuid)
    from public, anon;
revoke all on function public.solicitar_cambio_vivienda(uuid, text)
    from public, anon;
revoke all on function public.resolver_solicitud_vivienda(uuid, boolean, text)
    from public, anon;
revoke all on function public.procesar_cobros_vivienda()
    from public, anon, authenticated;

grant execute on function public.activar_vivienda_predeterminada(uuid)
    to authenticated;
grant execute on function public.solicitar_cambio_vivienda(uuid, text)
    to authenticated;
grant execute on function public.resolver_solicitud_vivienda(uuid, boolean, text)
    to authenticated;

select cron.schedule(
    'night-xity-gastos-vida',
    '0 14 * * 3',
    'select public.procesar_cobros_vivienda();'
);
