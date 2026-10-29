import { useMemo, useState } from 'react';
import { useToast } from '../../components/Toast';
import { Badge, Icon, Notice, Spinner } from '../../components/ui';
import { useNow, useOrders } from '../../hooks/useData';
import {
  formatPrice, formatTime, itemCount, minutesSince, needsCounterPayment, nextPrep, orderCode, originLabel,
  paymentLabel, prepLabel,
} from '../../lib/format';
import { data } from '../../services';
import { can } from '../../lib/permissions';
import type { Order, PrepStatus, Restaurant, StaffSession } from '../../types';

type Filter = 'activos' | 'cobro' | 'finalizados' | 'todos';
const filters: { id: Filter; label: string; test: (o: Order) => boolean }[] = [
  { id: 'activos', label: 'En curso', test: (o) => ['nuevo', 'en_preparacion', 'listo'].includes(o.prepStatus) },
  { id: 'cobro', label: 'Por cobrar', test: needsCounterPayment },
  { id: 'finalizados', label: 'Finalizados', test: (o) => o.prepStatus === 'entregado' || o.prepStatus === 'cancelado' },
  { id: 'todos', label: 'Todos', test: () => true },
];

export function OrdersPanel({ restaurant, session }: { restaurant: Restaurant; session: StaffSession | null }) {
  const { value: orders = [], loading, error } = useOrders(restaurant.id);
  const [filter, setFilter] = useState<Filter>('activos');
  const [q, setQ] = useState('');
  const now = useNow();

  const stats = useMemo(() => {
    const today = new Date().toDateString();
    const todays = orders.filter((o) => new Date(o.createdAt).toDateString() === today && o.prepStatus !== 'cancelado');
    const toCollect = orders.filter(needsCounterPayment);
    return {
      active: orders.filter(filters[0].test).length,
      collectCount: toCollect.length,
      collectAmount: toCollect.reduce((s, o) => s + o.total, 0),
      todayCount: todays.length,
      todayAmount: todays.reduce((s, o) => s + o.total, 0),
      awaitingOnline: orders.filter((o) => o.paymentStatus === 'pendiente_online').length,
    };
  }, [orders]);

  const visible = orders
    .filter(filters.find((f) => f.id === filter)!.test)
    .filter((o) => {
      const s = q.trim().toLowerCase();
      if (!s) return true;
      return String(o.number).includes(s.replace('#', '')) || originLabel(o).toLowerCase().includes(s) ||
        o.items.some((i) => i.name.toLowerCase().includes(s));
    });

  return (
    <div className="page">
      <header className="page-head">
        <div>
          <span className="eyebrow">Panel del restaurante</span>
          <h1>Pedidos · {restaurant.name}</h1>
        </div>
        <span className="live"><span className="live__dot" aria-hidden="true" />Actualización en directo</span>
      </header>

      <div className="stats">
        <Stat label="En curso" value={String(stats.active)} />
        <Stat label="Por cobrar en caja" value={formatPrice(stats.collectAmount)} sub={`${stats.collectCount} pedidos`} tone={stats.collectCount ? 'warn' : undefined} />
        <Stat label="Pedidos de hoy" value={String(stats.todayCount)} sub={`${formatPrice(stats.todayAmount)} en total`} />
        <Stat label="Esperando pago online" value={String(stats.awaitingOnline)} sub="No visibles en cocina" />
      </div>

      <div className="toolbar">
        <div className="segmented" role="tablist" aria-label="Filtrar pedidos">
          {filters.map((f) => (
            <button key={f.id} role="tab" aria-selected={filter === f.id} className={filter === f.id ? 'is-active' : ''} onClick={() => setFilter(f.id)}>
              {f.label}
              <span className="segmented__count">{orders.filter(f.test).length}</span>
            </button>
          ))}
        </div>
        <label className="search">
          <Icon name="search" size={18} />
          <span className="sr-only">Buscar pedido</span>
          <input id="panel-search" value={q} onChange={(e) => setQ(e.target.value)} placeholder="Nº, mesa, nombre o producto" />
        </label>
      </div>

      {error && <Notice tone="danger">{error}</Notice>}
      {loading && !orders.length ? <Spinner /> : visible.length === 0 ? (
        <div className="empty"><Icon name="list" size={32} /><p>No hay pedidos en esta vista.</p></div>
      ) : (
        <div className="orders">
          <div className="orders__head" aria-hidden="true">
            <span>Pedido</span><span>Origen</span><span>Productos</span><span>Importe</span><span>Pago</span><span>Preparación</span><span />
          </div>
          <ul>
            {visible.map((o) => <OrderRow key={o.id} order={o} now={now}
              canPrep={can(session, restaurant.id, 'orders.prep')} canCancel={can(session, restaurant.id, 'orders.cancel')}
              canCollect={can(session, restaurant.id, 'orders.collect')} />)}
          </ul>
        </div>
      )}
    </div>
  );
}

const ago = (m: number) => (m < 1 ? 'ahora' : `hace ${m} min`);

function Stat({ label, value, sub, tone }: { label: string; value: string; sub?: string; tone?: 'warn' }) {
  return (
    <div className={`stat${tone ? ` stat--${tone}` : ''}`}>
      <span className="stat__label">{label}</span>
      <strong className="stat__value">{value}</strong>
      {sub && <span className="stat__sub">{sub}</span>}
    </div>
  );
}

function OrderRow({ order: o, now, canPrep, canCancel, canCollect }: {
  order: Order; now: number; canPrep: boolean; canCancel: boolean; canCollect: boolean;
}) {
  const toast = useToast();
  const [confirmCancel, setConfirmCancel] = useState(false);
  const [busy, setBusy] = useState(false);
  const pay = paymentLabel[o.paymentStatus];
  const prep = prepLabel[o.prepStatus];
  const next = nextPrep[o.prepStatus];
  const fresh = o.prepStatus === 'nuevo' && minutesSince(o.createdAt, now) < 3;

  const act = async (fn: () => Promise<unknown>, msg: string) => {
    setBusy(true);
    try { await fn(); toast(msg); } catch (e) { toast((e as Error).message, 'danger'); } finally { setBusy(false); setConfirmCancel(false); }
  };
  const setPrep = (s: PrepStatus, msg: string) => act(() => data.updatePrepStatus(o.id, s), msg);

  return (
    <li className={`order${fresh ? ' is-fresh' : ''}${o.prepStatus === 'cancelado' ? ' is-cancelled' : ''}`}>
      <div className="order__id">
        <strong className="mono">{orderCode(o.number)}</strong>
        <span className="muted small">{formatTime(o.createdAt)}</span>
        <span className="muted small">{ago(minutesSince(o.createdAt, now))}</span>
      </div>
      <div className="order__origin">
        <Icon name={o.mode === 'mesa' ? 'table' : 'bag'} size={18} />
        <span>{originLabel(o)}</span>
      </div>
      <div className="order__items">
        <span className="sr-only">{itemCount(o)} productos: </span>
        {o.items.map((i) => `${i.quantity}× ${i.name}`).join(', ')}
        {o.notes && <span className="order__note">“{o.notes}”</span>}
      </div>
      <strong className="order__total price">{formatPrice(o.total)}</strong>
      <div className="order__pay"><Badge tone={pay.tone} title={pay.hint}>{pay.label}</Badge></div>
      <div className="order__prep"><Badge tone={prep.tone}>{prep.label}</Badge></div>
      <div className="order__actions">
        {confirmCancel ? (
          <>
            <span className="small">¿Cancelar {orderCode(o.number)}?</span>
            <button className="btn btn--danger btn--sm" disabled={busy} onClick={() => setPrep('cancelado', `Pedido ${orderCode(o.number)} cancelado`)}>Sí, cancelar</button>
            <button className="btn btn--ghost btn--sm" onClick={() => setConfirmCancel(false)}>No</button>
          </>
        ) : (
          <>
            {canPrep && next && o.paymentStatus !== 'pendiente_online' && o.paymentStatus !== 'fallido' && (
              <button className="btn btn--primary btn--sm" disabled={busy} onClick={() => setPrep(next.to, `${orderCode(o.number)}: ${prepLabel[next.to].label}`)}>
                {next.action}
              </button>
            )}
            {canCollect && needsCounterPayment(o) && (
              <button className="btn btn--outline btn--sm" disabled={busy} onClick={() => act(() => data.markPaidAtCounter(o.id), `Cobro de ${orderCode(o.number)} registrado`)}>
                <Icon name="cash" size={16} /> Cobrado en caja
              </button>
            )}
            {canCancel && o.prepStatus !== 'cancelado' && o.prepStatus !== 'entregado' && (
              <button className="btn btn--ghost btn--sm" onClick={() => setConfirmCancel(true)}>Cancelar</button>
            )}
          </>
        )}
      </div>
    </li>
  );
}
