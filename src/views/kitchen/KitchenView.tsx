import { useToast } from '../../components/Toast';
import { Icon, Spinner } from '../../components/ui';
import { useNow, useOrders } from '../../hooks/useData';
import { formatTime, isKitchenVisible, minutesSince, nextPrep, orderCode, originLabel } from '../../lib/format';
import { data } from '../../services';
import type { Order, PrepStatus, Restaurant } from '../../types';

const columns: { status: PrepStatus; title: string }[] = [
  { status: 'nuevo', title: 'Nuevos' },
  { status: 'en_preparacion', title: 'En preparación' },
  { status: 'listo', title: 'Listos para entregar' },
];
const back: Partial<Record<PrepStatus, PrepStatus>> = { en_preparacion: 'nuevo', listo: 'en_preparacion' };

export function KitchenView({ restaurant }: { restaurant: Restaurant }) {
  const { value: orders = [], loading } = useOrders(restaurant.id);
  const now = useNow(15000);
  const toast = useToast();
  const queue = orders.filter(isKitchenVisible).sort((a, b) => a.createdAt.localeCompare(b.createdAt));

  const move = async (o: Order, to: PrepStatus) => {
    try { await data.updatePrepStatus(o.id, to); } catch (e) { toast((e as Error).message, 'danger'); }
  };

  return (
    <div className="page kitchen">
      <header className="page-head">
        <div>
          <span className="eyebrow">Cocina</span>
          <h1>{restaurant.name}</h1>
        </div>
        <div className="kitchen__meta">
          <span className="mono kitchen__clock">{formatTime(new Date(now).toISOString())}</span>
          <span className="muted">Objetivo: {restaurant.prepMinutes} min por pedido</span>
        </div>
      </header>
      {loading && !orders.length ? <Spinner /> : (
        <div className="kboard">
          {columns.map((c) => {
            const list = queue.filter((o) => o.prepStatus === c.status);
            return (
              <section key={c.status} className={`kcol kcol--${c.status}`} aria-labelledby={`kc-${c.status}`}>
                <h2 id={`kc-${c.status}`}>{c.title} <span className="kcol__count">{list.length}</span></h2>
                {list.length === 0 && <p className="muted kcol__empty">Sin pedidos</p>}
                <ul className="stack">
                  {list.map((o) => {
                    const mins = minutesSince(o.createdAt, now);
                    const late = o.prepStatus !== 'listo' && mins > restaurant.prepMinutes;
                    const next = nextPrep[o.prepStatus];
                    const prev = back[o.prepStatus];
                    return (
                      <li key={o.id} className={`ticket${late ? ' is-late' : ''}`}>
                        <div className="ticket__head">
                          <strong className="ticket__num mono">{orderCode(o.number)}</strong>
                          <span className={`ticket__time mono${late ? ' is-late' : ''}`}>
                            <Icon name="clock" size={16} /> {mins} min{late ? ' · retrasado' : ''}
                          </span>
                        </div>
                        <p className="ticket__origin"><Icon name={o.mode === 'mesa' ? 'table' : 'bag'} size={18} /> {originLabel(o)}</p>
                        <ul className="ticket__items">
                          {o.items.map((i) => (
                            <li key={i.productId}>
                              <span className="ticket__qty mono">{i.quantity}×</span>
                              <span>{i.name}{i.notes && <em className="ticket__note">{i.notes}</em>}</span>
                            </li>
                          ))}
                        </ul>
                        {o.notes && <p className="ticket__ordernote"><Icon name="info" size={16} /> {o.notes}</p>}
                        <div className="ticket__actions">
                          {prev && <button className="btn btn--ghost btn--sm" onClick={() => move(o, prev)} aria-label={`Devolver ${orderCode(o.number)} al paso anterior`}><Icon name="back" size={16} /></button>}
                          {next && <button className="btn btn--primary btn--block" onClick={() => move(o, next.to)}>{next.action}</button>}
                        </div>
                      </li>
                    );
                  })}
                </ul>
              </section>
            );
          })}
        </div>
      )}
      <p className="muted small">Los pedidos con pago online aparecen en cocina cuando el pago se completa (en esta demo, al simularlo).</p>
    </div>
  );
}
