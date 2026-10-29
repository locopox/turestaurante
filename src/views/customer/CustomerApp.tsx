import { useEffect, useMemo, useRef, useState } from 'react';
import { FoodArt } from '../../components/FoodArt';
import { useToast } from '../../components/Toast';
import { Badge, Icon, Modal, Notice, Spinner, Stepper } from '../../components/ui';
import { useMenu, useOrder } from '../../hooks/useData';
import { formatPrice, formatTime, orderCode, originLabel, paymentLabel, prepLabel } from '../../lib/format';
import { safeStorage } from '../../lib/storage';
import { data, payments } from '../../services';
import type { Order, OrderMode, PaymentMethod, Product, ProductTag, Restaurant } from '../../types';

type Step = 'menu' | 'cart' | 'checkout' | 'payment' | 'confirm';
type Cart = Record<string, { quantity: number; notes?: string }>;

const tagLabel: Record<ProductTag, string> = {
  vegetariano: 'Vegetariano', vegano: 'Vegano', picante: 'Picante', nuevo: 'Nuevo', sin_gluten: 'Sin gluten',
};

export function CustomerApp({ restaurant, qrTable }: { restaurant: Restaurant; qrTable?: number }) {
  const cartKey = `turestaurante:cart:${restaurant.id}`;
  const { value: menu, loading, error } = useMenu(restaurant.id);
  const [step, setStep] = useState<Step>('menu');
  const [cart, setCart] = useState<Cart>(() => safeStorage.get<Cart>(cartKey, {}));
  const [detail, setDetail] = useState<Product | null>(null);
  const [orderId, setOrderId] = useState<string | null>(null);

  useEffect(() => { safeStorage.set(cartKey, cart); }, [cart, cartKey]);
  useEffect(() => { window.scrollTo(0, 0); }, [step]);

  const products = menu?.products ?? [];
  const lines = useMemo(
    () => Object.entries(cart)
      .map(([id, l]) => ({ product: products.find((p) => p.id === id), ...l }))
      .filter((l): l is { product: Product; quantity: number; notes?: string } => !!l.product && l.quantity > 0),
    [cart, products],
  );
  const count = lines.reduce((s, l) => s + l.quantity, 0);
  const total = lines.reduce((s, l) => s + l.quantity * l.product.price, 0);

  const setQty = (id: string, quantity: number, notes?: string) =>
    setCart((c) => {
      const next = { ...c };
      if (quantity <= 0) delete next[id];
      else next[id] = { quantity, notes: notes ?? c[id]?.notes };
      return next;
    });

  if (!restaurant.active)
    return (
      <div className="cx">
        <CxHeader restaurant={restaurant} qrTable={qrTable} />
        <div className="cx-body"><Notice tone="warn"><strong>{restaurant.name} no acepta pedidos ahora mismo.</strong> Vuelve a intentarlo más tarde o pregunta al personal.</Notice></div>
      </div>
    );

  if (loading && !menu) return <div className="cx"><CxHeader restaurant={restaurant} qrTable={qrTable} /><Spinner label="Cargando la carta…" /></div>;
  if (error) return <div className="cx"><div className="cx-body"><Notice tone="danger">No se pudo cargar la carta: {error}</Notice></div></div>;

  if (step === 'confirm' && orderId)
    return <Confirmation restaurant={restaurant} orderId={orderId} onNew={() => { setOrderId(null); setStep('menu'); }} />;

  if (step === 'payment' && orderId)
    return <SimulatedPayment restaurant={restaurant} orderId={orderId} onDone={() => setStep('confirm')} />;

  if (step === 'checkout')
    return (
      <Checkout restaurant={restaurant} qrTable={qrTable} lines={lines} total={total}
        onBack={() => setStep('cart')}
        onPlaced={(order) => {
          setCart({});
          setOrderId(order.id);
          setStep(order.paymentMethod === 'online' ? 'payment' : 'confirm');
        }} />
    );

  if (step === 'cart')
    return (
      <div className="cx">
        <TopBar title="Tu pedido" onBack={() => setStep('menu')} />
        <div className="cx-body stack">
          {lines.length === 0 ? (
            <div className="empty">
              <Icon name="cart" size={32} />
              <p>Tu carrito está vacío.</p>
              <button className="btn btn--primary" onClick={() => setStep('menu')}>Ver la carta</button>
            </div>
          ) : (
            <>
              <ul className="cart-list">
                {lines.map((l) => (
                  <li key={l.product.id} className="cart-line">
                    <FoodArt art={l.product.art} imageUrl={l.product.imageUrl} label="" className="cart-line__art" />
                    <div className="cart-line__info">
                      <strong>{l.product.name}</strong>
                      {l.notes && <span className="muted small">Nota: {l.notes}</span>}
                      <span className="price">{formatPrice(l.product.price * l.quantity)}</span>
                    </div>
                    <Stepper value={l.quantity} label={l.product.name} onChange={(n) => setQty(l.product.id, n)} />
                  </li>
                ))}
              </ul>
              <div className="totals">
                <span>Total</span>
                <strong className="price">{formatPrice(total)}</strong>
              </div>
              <button className="btn btn--ghost" onClick={() => setStep('menu')}><Icon name="plus" /> Añadir más productos</button>
            </>
          )}
        </div>
        {lines.length > 0 && (
          <BottomBar>
            <button className="btn btn--primary btn--block btn--lg" onClick={() => setStep('checkout')}>
              Continuar <span className="btn__aside">{formatPrice(total)}</span>
            </button>
          </BottomBar>
        )}
      </div>
    );

  // Paso: carta
  const categories = (menu?.categories ?? []).filter((c) => products.some((p) => p.categoryId === c.id));
  return (
    <div className="cx">
      <CxHeader restaurant={restaurant} qrTable={qrTable} />
      <CategoryNav categories={categories} />
      <div className="cx-body">
        {categories.map((c) => (
          <section key={c.id} id={`cat-${c.id}`} className="menu-section" aria-labelledby={`h-${c.id}`}>
            <h2 id={`h-${c.id}`} className="menu-section__title">{c.name}</h2>
            <ul className="product-grid">
              {products.filter((p) => p.categoryId === c.id).map((p) => (
                <li key={p.id}>
                  <ProductCard product={p} quantity={cart[p.id]?.quantity ?? 0}
                    onOpen={() => setDetail(p)} onQty={(n) => setQty(p.id, n)} />
                </li>
              ))}
            </ul>
          </section>
        ))}
        <p className="muted small center">Consulta al personal cualquier duda sobre alérgenos.</p>
      </div>
      {count > 0 && (
        <BottomBar>
          <button className="btn btn--primary btn--block btn--lg" onClick={() => setStep('cart')}>
            <span className="cart-count" aria-hidden="true">{count}</span>
            Ver pedido
            <span className="btn__aside">{formatPrice(total)}</span>
            <span className="sr-only">, {count} productos</span>
          </button>
        </BottomBar>
      )}
      <ProductSheet product={detail} initial={detail ? cart[detail.id] : undefined} onClose={() => setDetail(null)}
        onAdd={(q, notes) => { if (detail) setQty(detail.id, q, notes); setDetail(null); }} />
    </div>
  );
}

function CxHeader({ restaurant, qrTable }: { restaurant: Restaurant; qrTable?: number }) {
  return (
    <header className="cx-header">
      <div className="cx-header__mark" aria-hidden="true">{restaurant.name.slice(0, 1)}</div>
      <div className="cx-header__text">
        <h1>{restaurant.name}</h1>
        <p>{restaurant.tagline}</p>
      </div>
      <span className="cx-header__chip">
        <Icon name={qrTable ? 'table' : 'bag'} size={16} />
        {qrTable ? `Mesa ${qrTable}` : 'Pedido online'}
      </span>
    </header>
  );
}

function CategoryNav({ categories }: { categories: { id: string; name: string }[] }) {
  const [active, setActive] = useState(categories[0]?.id);
  const navRef = useRef<HTMLElement>(null);
  useEffect(() => {
    const obs = new IntersectionObserver(
      (entries) => {
        const visible = entries.filter((e) => e.isIntersecting).sort((a, b) => a.boundingClientRect.top - b.boundingClientRect.top)[0];
        if (visible) setActive(visible.target.id.replace('cat-', ''));
      },
      { rootMargin: '-120px 0px -60% 0px' },
    );
    categories.forEach((c) => { const el = document.getElementById(`cat-${c.id}`); if (el) obs.observe(el); });
    return () => obs.disconnect();
  }, [categories]);
  useEffect(() => {
    navRef.current?.querySelector(`[data-id="${active}"]`)?.scrollIntoView({ block: 'nearest', inline: 'center' });
  }, [active]);
  return (
    <nav className="cat-nav" aria-label="Categorías" ref={navRef}>
      {categories.map((c) => (
        <button key={c.id} data-id={c.id} className={`cat-nav__item${active === c.id ? ' is-active' : ''}`}
          aria-current={active === c.id ? 'true' : undefined}
          onClick={() => {
            const el = document.getElementById(`cat-${c.id}`);
            if (el) window.scrollTo({ top: el.getBoundingClientRect().top + window.scrollY - 118, behavior: 'smooth' });
            setActive(c.id);
          }}>
          {c.name}
        </button>
      ))}
    </nav>
  );
}

function ProductCard({ product: p, quantity, onOpen, onQty }: {
  product: Product; quantity: number; onOpen: () => void; onQty: (n: number) => void;
}) {
  return (
    <article className={`product${p.available ? '' : ' is-soldout'}`}>
      <button className="product__main" onClick={onOpen} disabled={!p.available} aria-label={`${p.name}, ${formatPrice(p.price)}. Ver detalle`}>
        <FoodArt art={p.art} imageUrl={p.imageUrl} label="" className="product__art" />
        <div className="product__text">
          <h3>{p.name}</h3>
          <p className="product__desc">{p.description}</p>
          {p.tags.length > 0 && (
            <div className="tags">{p.tags.map((t) => <span key={t} className={`tag tag--${t}`}>{tagLabel[t]}</span>)}</div>
          )}
        </div>
      </button>
      <div className="product__foot">
        <span className="price">{formatPrice(p.price)}</span>
        {!p.available ? (
          <span className="muted small">Agotado</span>
        ) : quantity > 0 ? (
          <Stepper value={quantity} label={p.name} onChange={onQty} />
        ) : (
          <button className="btn btn--primary btn--sm" onClick={() => onQty(1)} aria-label={`Añadir ${p.name}`}>
            <Icon name="plus" size={18} /> Añadir
          </button>
        )}
      </div>
    </article>
  );
}

function ProductSheet({ product, initial, onClose, onAdd }: {
  product: Product | null; initial?: { quantity: number; notes?: string }; onClose: () => void; onAdd: (q: number, notes?: string) => void;
}) {
  const [qty, setQty] = useState(1);
  const [notes, setNotes] = useState('');
  useEffect(() => {
    setQty(initial?.quantity || 1);
    setNotes(initial?.notes ?? '');
  }, [product, initial]);
  if (!product) return null;
  return (
    <Modal open onClose={onClose} title={product.name}>
      <FoodArt art={product.art} imageUrl={product.imageUrl} label={product.name} className="sheet__art" />
      <div className="sheet__body stack">
        <div>
          <h2 className="sheet__title">{product.name}</h2>
          <p className="muted">{product.description}</p>
        </div>
        {product.tags.length > 0 && <div className="tags">{product.tags.map((t) => <span key={t} className={`tag tag--${t}`}>{tagLabel[t]}</span>)}</div>}
        <p className="small"><strong>Alérgenos:</strong> {product.allergens.length ? product.allergens.join(', ') : 'no declarados'}</p>
        <label className="field">
          <span>Nota para cocina (opcional)</span>
          <input id="sheet-notes" value={notes} maxLength={120} onChange={(e) => setNotes(e.target.value)} placeholder="Ej.: sin cebolla" />
        </label>
        <div className="row row--between">
          <Stepper value={qty} min={1} size="lg" label={product.name} onChange={setQty} />
          <button className="btn btn--primary btn--lg" onClick={() => onAdd(qty, notes.trim() || undefined)}>
            {initial?.quantity ? 'Actualizar' : 'Añadir'} · {formatPrice(product.price * qty)}
          </button>
        </div>
      </div>
    </Modal>
  );
}

function pickupSlots(prepMinutes: number): string[] {
  const start = new Date(Date.now() + (prepMinutes + 10) * 60000);
  start.setMinutes(Math.ceil(start.getMinutes() / 15) * 15, 0, 0);
  return Array.from({ length: 8 }, (_, i) => formatTime(new Date(start.getTime() + i * 15 * 60000).toISOString()));
}

function Checkout({ restaurant, qrTable, lines, total, onBack, onPlaced }: {
  restaurant: Restaurant; qrTable?: number; lines: { product: Product; quantity: number; notes?: string }[]; total: number;
  onBack: () => void; onPlaced: (o: Order) => void;
}) {
  const toast = useToast();
  const [mode, setMode] = useState<OrderMode>(qrTable || !restaurant.pickupEnabled ? 'mesa' : 'recoger');
  const [table, setTable] = useState<string>(qrTable ? String(qrTable) : '');
  const [name, setName] = useState('');
  const [phone, setPhone] = useState('');
  const [pickup, setPickup] = useState('asap');
  const [notes, setNotes] = useState('');
  const [method, setMethod] = useState<PaymentMethod>(restaurant.onlinePaymentEnabled ? 'online' : 'caja');
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [sending, setSending] = useState(false);
  const slots = useMemo(() => pickupSlots(restaurant.prepMinutes), [restaurant.prepMinutes]);

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    const errs: Record<string, string> = {};
    if (mode === 'mesa' && !table) errs.table = 'Elige tu número de mesa.';
    if (mode === 'recoger' && name.trim().length < 2) errs.name = 'Escribe un nombre para llamarte cuando esté listo.';
    setErrors(errs);
    if (Object.keys(errs).length) return;
    setSending(true);
    try {
      const order = await data.createOrder({
        restaurantId: restaurant.id, mode, table: mode === 'mesa' ? Number(table) : null,
        customerName: mode === 'recoger' ? name : null, customerPhone: mode === 'recoger' ? phone : null,
        pickupTime: mode === 'recoger' ? pickup : null, notes, paymentMethod: method,
        items: lines.map((l) => ({ productId: l.product.id, quantity: l.quantity, notes: l.notes })),
      });
      onPlaced(order);
    } catch (err) {
      toast((err as Error).message, 'danger');
    } finally {
      setSending(false);
    }
  };

  return (
    <div className="cx">
      <TopBar title="Finalizar pedido" onBack={onBack} />
      <form className="cx-body stack-lg" onSubmit={submit} noValidate>
        <fieldset className="fieldset">
          <legend>¿Dónde lo tomas?</legend>
          <div className="choice-grid">
            <Choice name="mode" checked={mode === 'mesa'} onChange={() => setMode('mesa')} icon="table" title="En mesa" text="Te lo llevamos a la mesa" />
            <Choice name="mode" checked={mode === 'recoger'} onChange={() => setMode('recoger')} icon="bag" title="Para recoger"
              text={restaurant.pickupEnabled ? `Listo en unos ${restaurant.prepMinutes} min` : 'No disponible ahora'} disabled={!restaurant.pickupEnabled} />
          </div>
          {mode === 'mesa' ? (
            <label className="field">
              <span>Número de mesa{qrTable ? ' (detectado por el QR)' : ''}</span>
              <select id="co-table" value={table} onChange={(e) => setTable(e.target.value)} aria-invalid={!!errors.table} aria-describedby="err-table">
                <option value="">Selecciona tu mesa</option>
                {Array.from({ length: restaurant.tables }, (_, i) => <option key={i + 1} value={i + 1}>Mesa {i + 1}</option>)}
              </select>
              {errors.table && <small id="err-table" className="field__error">{errors.table}</small>}
            </label>
          ) : (
            <div className="stack">
              <label className="field">
                <span>Nombre</span>
                <input id="co-name" value={name} onChange={(e) => setName(e.target.value)} autoComplete="given-name" aria-invalid={!!errors.name} aria-describedby="err-name" />
                {errors.name && <small id="err-name" className="field__error">{errors.name}</small>}
              </label>
              <label className="field">
                <span>Teléfono (opcional)</span>
                <input id="co-phone" type="tel" value={phone} onChange={(e) => setPhone(e.target.value)} autoComplete="tel" inputMode="tel" />
              </label>
              <label className="field">
                <span>Hora de recogida</span>
                <select id="co-pickup" value={pickup} onChange={(e) => setPickup(e.target.value)}>
                  <option value="asap">Lo antes posible (unos {restaurant.prepMinutes} min)</option>
                  {slots.map((s) => <option key={s} value={s}>A las {s}</option>)}
                </select>
              </label>
            </div>
          )}
        </fieldset>

        <label className="field">
          <span>Comentarios para el restaurante (opcional)</span>
          <textarea id="co-notes" rows={2} value={notes} maxLength={200} onChange={(e) => setNotes(e.target.value)} placeholder="Alergias, preferencias…" />
        </label>

        <fieldset className="fieldset">
          <legend>¿Cómo quieres pagar?</legend>
          <div className="choice-grid">
            <Choice name="pay" checked={method === 'online'} onChange={() => setMethod('online')} icon="card" title="Pagar ahora"
              text={restaurant.onlinePaymentEnabled ? (payments.simulated ? 'Pago online (simulado en esta demo)' : 'Tarjeta o wallet') : 'No disponible'}
              disabled={!restaurant.onlinePaymentEnabled} />
            <Choice name="pay" checked={method === 'caja'} onChange={() => setMethod('caja')} icon="cash" title="Pagar en caja"
              text={mode === 'mesa' ? 'Al terminar, en caja o con el camarero' : 'Al recoger tu pedido'} disabled={!restaurant.counterPaymentEnabled} />
          </div>
        </fieldset>

        <section className="summary" aria-label="Resumen del pedido">
          <ul>
            {lines.map((l) => (
              <li key={l.product.id}><span>{l.quantity}× {l.product.name}</span><span className="price">{formatPrice(l.product.price * l.quantity)}</span></li>
            ))}
          </ul>
          <div className="totals"><span>Total</span><strong className="price">{formatPrice(total)}</strong></div>
        </section>

        <BottomBar>
          <button type="submit" className="btn btn--primary btn--block btn--lg" disabled={sending}>
            {sending ? 'Enviando…' : method === 'online' ? 'Ir al pago' : 'Confirmar pedido'}
            <span className="btn__aside">{formatPrice(total)}</span>
          </button>
        </BottomBar>
      </form>
    </div>
  );
}

function Choice({ name, checked, onChange, icon, title, text, disabled }: {
  name: string; checked: boolean; onChange: () => void; icon: string; title: string; text: string; disabled?: boolean;
}) {
  return (
    <label className={`choice${checked ? ' is-checked' : ''}${disabled ? ' is-disabled' : ''}`}>
      <input type="radio" name={name} checked={checked} onChange={onChange} disabled={disabled} />
      <Icon name={icon} size={24} />
      <span className="choice__title">{title}</span>
      <span className="choice__text">{text}</span>
    </label>
  );
}

function SimulatedPayment({ restaurant, orderId, onDone }: { restaurant: Restaurant; orderId: string; onDone: () => void }) {
  const toast = useToast();
  const { value: order } = useOrder(orderId, restaurant.id);
  const [busy, setBusy] = useState(false);
  if (!order) return <div className="cx"><Spinner /></div>;

  const run = async (fn: () => Promise<unknown>) => {
    setBusy(true);
    try { await fn(); } catch (e) { toast((e as Error).message, 'danger'); } finally { setBusy(false); }
  };
  const failed = order.paymentStatus === 'fallido';

  return (
    <div className="cx">
      <TopBar title="Pago" />
      <div className="cx-body stack-lg">
        <div className="paybox">
          <span className="eyebrow">Pasarela de prueba</span>
          <p className="paybox__amount price">{formatPrice(order.total)}</p>
          <p className="muted">Pedido {orderCode(order.number)} · {restaurant.name}</p>
        </div>
        <Notice tone="warn">
          <strong>Modo demostración.</strong> Esta pantalla sustituye a la pasarela de pago real. No se piden datos de tarjeta,
          no se realiza ningún cargo y el pago no queda verificado.
        </Notice>
        {failed && <Notice tone="danger">El pago simulado ha sido rechazado. Puedes intentarlo de nuevo o pagar en caja.</Notice>}
        <div className="stack">
          <button className="btn btn--primary btn--lg btn--block" disabled={busy}
            onClick={() => run(async () => { await payments.simulateResult!(order, 'aprobado'); onDone(); })}>
            <Icon name="check" /> Simular pago aceptado
          </button>
          <button className="btn btn--outline btn--block" disabled={busy}
            onClick={() => run(() => payments.simulateResult!(order, 'rechazado'))}>
            Simular pago rechazado
          </button>
          {restaurant.counterPaymentEnabled && (
            <button className="btn btn--ghost btn--block" disabled={busy}
              onClick={() => run(async () => { await data.changePaymentMethod(order.id, 'caja'); onDone(); })}>
              Prefiero pagar en caja
            </button>
          )}
        </div>
      </div>
    </div>
  );
}

const progress: { key: Order['prepStatus']; label: string }[] = [
  { key: 'nuevo', label: 'Recibido' },
  { key: 'en_preparacion', label: 'En preparación' },
  { key: 'listo', label: 'Listo' },
  { key: 'entregado', label: 'Entregado' },
];

function Confirmation({ restaurant, orderId, onNew }: { restaurant: Restaurant; orderId: string; onNew: () => void }) {
  const { value: order } = useOrder(orderId, restaurant.id);
  if (!order) return <div className="cx"><Spinner /></div>;
  const idx = progress.findIndex((p) => p.key === order.prepStatus);
  const pay = paymentLabel[order.paymentStatus];
  const cancelled = order.prepStatus === 'cancelado';

  return (
    <div className="cx">
      <div className="cx-body stack-lg confirm">
        <div className="confirm__hero">
          <div className="confirm__check" aria-hidden="true"><Icon name="check" size={34} /></div>
          <h1>{cancelled ? 'Pedido cancelado' : '¡Pedido enviado!'}</h1>
          <p className="muted">{restaurant.name} · {originLabel(order)}</p>
          <div className="confirm__number">
            <span>Número de pedido</span>
            <strong>{orderCode(order.number)}</strong>
          </div>
        </div>

        {!cancelled && (
          <ol className="progress" aria-label="Estado del pedido">
            {progress.map((p, i) => (
              <li key={p.key} className={i < idx ? 'is-done' : i === idx ? 'is-current' : ''} aria-current={i === idx ? 'step' : undefined}>
                <span className="progress__dot" aria-hidden="true">{i < idx ? <Icon name="check" size={14} /> : null}</span>
                {p.label}
              </li>
            ))}
          </ol>
        )}
        <p className="sr-only" aria-live="polite">Estado: {prepLabel[order.prepStatus].label}</p>

        <section className="paystate">
          <div className="row row--between">
            <strong>Pago</strong>
            <Badge tone={pay.tone}>{pay.label}</Badge>
          </div>
          {order.paymentStatus === 'simulado' && (
            <p className="small muted">Pago de demostración: no se ha realizado ningún cargo ni se ha verificado con un banco.</p>
          )}
          {order.paymentStatus === 'pendiente_caja' && (
            <p className="small muted">Pagarás {formatPrice(order.total)} {order.mode === 'mesa' ? 'en caja o al camarero' : 'al recoger'}. Indica el número {orderCode(order.number)}.</p>
          )}
          {order.paymentStatus === 'cobrado_caja' && <p className="small muted">El restaurante ha registrado el cobro.</p>}
        </section>

        <section className="summary" aria-label="Detalle">
          <ul>
            {order.items.map((i) => (
              <li key={i.productId}><span>{i.quantity}× {i.name}{i.notes ? ` (${i.notes})` : ''}</span><span className="price">{formatPrice(i.unitPrice * i.quantity)}</span></li>
            ))}
          </ul>
          <div className="totals"><span>Total</span><strong className="price">{formatPrice(order.total)}</strong></div>
          <p className="small muted">Pedido realizado a las {formatTime(order.createdAt)}. Esta pantalla se actualiza sola.</p>
        </section>

        <button className="btn btn--outline btn--block" onClick={onNew}>Hacer otro pedido</button>
      </div>
    </div>
  );
}

function TopBar({ title, onBack }: { title: string; onBack?: () => void }) {
  return (
    <header className="topbar">
      {onBack ? (
        <button className="icon-btn" onClick={onBack} aria-label="Volver"><Icon name="back" /></button>
      ) : <span className="icon-btn-spacer" />}
      <h1>{title}</h1>
      <span className="icon-btn-spacer" />
    </header>
  );
}

function BottomBar({ children }: { children: React.ReactNode }) {
  return <div className="bottombar"><div className="bottombar__inner">{children}</div></div>;
}
