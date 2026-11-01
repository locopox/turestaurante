import QRCode from 'qrcode';
import { useEffect, useMemo, useState } from 'react';
import { ART_OPTIONS, FoodArt } from '../../components/FoodArt';
import { useToast } from '../../components/Toast';
import { Badge, Icon, Modal, Notice, Spinner } from '../../components/ui';
import { config, onlinePaymentsAvailable } from '../../config';
import { useAudit, useMenu, useMySupportRequests, useNow, useOrders, useRestaurants, useStaff, useSupportDenials, useSupportRequests } from '../../hooks/useData';
import { hrefFor } from '../../hooks/useRoute';
import { auditActionLabel, auditActor, auditDetails } from '../../lib/audit';
import { formatPrice, formatTime, orderCode, paymentLabel, prepLabel, slugify } from '../../lib/format';
import { denialReasonLabel, denialSummary, isSupportActive, remainingLabel, supportStatusLabel } from '../../lib/support';
import { data } from '../../services';
import { can, canOpenAdmin, manageableRoles, roleLabel } from '../../lib/permissions';
import type {
  FoodArt as Art, Product, Restaurant, StaffRole, StaffSession, SupportGrant, SupportOrderView, SupportPaymentEventView,
  SupportRestaurantView,
} from '../../types';

type Tab = 'datos' | 'carta' | 'equipo' | 'registro' | 'soporte' | 'qr';

export function AdminView({ selectedId, onSelect, session }: { selectedId: string; onSelect: (id: string) => void; session: StaffSession | null }) {
  const { value: all = [], loading } = useRestaurants();
  // Solo los restaurantes que este usuario puede administrar (la base de datos lo aplica igualmente).
  const restaurants = all.filter((r) => canOpenAdmin(session, r.id));
  const [tab, setTab] = useState<Tab>('datos');
  const [creating, setCreating] = useState(false);
  const current = restaurants.find((r) => r.id === selectedId) ?? restaurants[0];
  const isPlatform = !!session?.isPlatformAdmin;
  // Pestañas según lo que el usuario puede hacer en ese restaurante.
  const tabs = ([
    ['datos', 'Datos y opciones', true],
    ['carta', 'Carta', can(session, current?.id, 'menu.edit')],
    ['equipo', 'Equipo', can(session, current?.id, 'staff.manage')],
    ['registro', 'Registro', can(session, current?.id, 'audit.view')],
    ['soporte', 'Soporte', can(session, current?.id, 'support.request') || can(session, current?.id, 'support.approve')],
    ['qr', 'Mesas y QR', true],
  ] as const).filter(([, , show]) => show);
  const activeTab: Tab = tabs.some(([id]) => id === tab) ? tab : 'datos';

  return (
    <div className="page">
      <header className="page-head">
        <div>
          <span className="eyebrow">{isPlatform ? 'Administración de la plataforma' : 'Administración del restaurante'}</span>
          <h1>Restaurantes</h1>
        </div>
        {can(session, undefined, 'restaurant.create') && (
          <button className="btn btn--primary" onClick={() => setCreating(true)}><Icon name="plus" /> Nuevo restaurante</button>
        )}
      </header>

      {loading && !restaurants.length ? <Spinner /> : (
        <div className="admin">
          <aside className="admin__list" aria-label="Lista de restaurantes">
            <ul>
              {restaurants.map((r) => (
                <li key={r.id}>
                  <button className={`rest-item${current?.id === r.id ? ' is-active' : ''}`} onClick={() => onSelect(r.id)} aria-current={current?.id === r.id ? 'true' : undefined}>
                    <span className="rest-item__mark" aria-hidden="true">{r.name.slice(0, 1)}</span>
                    <span className="rest-item__text">
                      <strong>{r.name}</strong>
                      <span className="muted small">/{r.slug} · {r.tables} mesas</span>
                    </span>
                    {r.suspended
                      ? <Badge tone="danger">Suspendido</Badge>
                      : <Badge tone={r.active ? 'ok' : 'neutral'}>{r.active ? 'Activo' : 'Pausado'}</Badge>}
                  </button>
                </li>
              ))}
            </ul>
          </aside>

          {current && (
            <section className="admin__detail" aria-label={`Configuración de ${current.name}`}>
              {current.suspended && (
                <Notice tone="danger">
                  Restaurante <strong>suspendido por la plataforma</strong>: no acepta pedidos nuevos. Los pedidos ya hechos se pueden terminar.
                </Notice>
              )}
              {can(session, current.id, 'support.approve') && data.kind !== 'mock' && (
                <PendingSupportNotice key={`p-${current.id}`} restaurant={current} onOpen={() => setTab('soporte')} />
              )}
              <RestaurantSummary restaurant={current} showOrders={can(session, current.id, 'orders.view')} />
              <div className="segmented" role="tablist" aria-label="Secciones">
                {tabs.map(([id, label]) => (
                  <button key={id} role="tab" aria-selected={activeTab === id} className={activeTab === id ? 'is-active' : ''} onClick={() => setTab(id)}>{label}</button>
                ))}
              </div>
              {activeTab === 'datos' && (
                <RestaurantForm key={current.id} restaurant={current} canEdit={can(session, current.id, 'restaurant.edit')}
                  isPlatform={can(session, current.id, 'platform.manage')} />
              )}
              {activeTab === 'carta' && <MenuEditor key={current.id} restaurant={current} />}
              {activeTab === 'equipo' && <TeamPanel key={current.id} restaurant={current} session={session} />}
              {activeTab === 'registro' && <AuditPanel key={current.id} restaurant={current} />}
              {activeTab === 'soporte' && (
                data.kind === 'mock'
                  ? <Notice>El modo soporte necesita Supabase: en la demo no hay cuentas de plataforma y de propietario separadas.</Notice>
                  : can(session, current.id, 'support.request')
                    ? <SupportRequestPanel key={current.id} restaurant={current} />
                    : <SupportOwnerPanel key={current.id} restaurant={current} />
              )}
              {activeTab === 'qr' && <QrSheet key={current.id} restaurant={current} />}
            </section>
          )}
        </div>
      )}
      <CreateRestaurant open={creating} onClose={() => setCreating(false)} onCreated={(r) => { setCreating(false); onSelect(r.id); setTab('datos'); }} />
    </div>
  );
}

function RestaurantSummary({ restaurant, showOrders }: { restaurant: Restaurant; showOrders: boolean }) {
  const { value: orders } = useOrders(showOrders ? restaurant.id : undefined);
  const { value: menu } = useMenu(restaurant.id);
  if (!showOrders) {
    // Sin acceso a pedidos (por ejemplo, la plataforma): solo datos de la carta, que es pública.
    return (
      <div className="stats stats--compact">
        <div className="stat"><span className="stat__label">Productos</span><strong className="stat__value">{menu?.products.length ?? '–'}</strong><span className="stat__sub">{menu?.products.filter((p) => !p.available).length ?? 0} agotados</span></div>
        <div className="stat"><span className="stat__label">Pedidos</span><strong className="stat__value">—</strong><span className="stat__sub">sin acceso operativo</span></div>
      </div>
    );
  }
  if (!orders || !menu) return <div className="stats stats--compact" aria-busy="true"><div className="stat"><span className="stat__label">Cargando resumen…</span></div></div>;
  const active = orders.filter((o) => ['nuevo', 'en_preparacion', 'listo'].includes(o.prepStatus)).length;
  const total = orders.filter((o) => o.prepStatus !== 'cancelado').reduce((s, o) => s + o.total, 0);
  return (
    <div className="stats stats--compact">
      <div className="stat"><span className="stat__label">Pedidos</span><strong className="stat__value">{orders.length}</strong><span className="stat__sub">{active} en curso</span></div>
      <div className="stat"><span className="stat__label">Importe pedidos</span><strong className="stat__value">{formatPrice(total)}</strong><span className="stat__sub">incluye pagos sin verificar</span></div>
      <div className="stat"><span className="stat__label">Productos</span><strong className="stat__value">{menu?.products.length ?? '–'}</strong><span className="stat__sub">{menu?.products.filter((p) => !p.available).length ?? 0} agotados</span></div>
    </div>
  );
}

function Toggle({ id, label, hint, checked, onChange, disabled }: { id: string; label: string; hint?: string; checked: boolean; onChange: (v: boolean) => void; disabled?: boolean }) {
  return (
    <label className="toggle" htmlFor={id}>
      <span><strong>{label}</strong>{hint && <span className="muted small">{hint}</span>}</span>
      <input id={id} type="checkbox" role="switch" checked={checked} disabled={disabled} onChange={(e) => onChange(e.target.checked)} />
      <span className="toggle__track" aria-hidden="true" />
    </label>
  );
}

function RestaurantForm({ restaurant, canEdit, isPlatform }: { restaurant: Restaurant; canEdit: boolean; isPlatform: boolean }) {
  const toast = useToast();
  const [r, setR] = useState(restaurant);
  const [saving, setSaving] = useState(false);
  useEffect(() => { setR(restaurant); }, [restaurant]);
  const set = <K extends keyof Restaurant>(k: K, v: Restaurant[K]) => setR((x) => ({ ...x, [k]: v }));
  const dirty = JSON.stringify(r) !== JSON.stringify(restaurant);

  const save = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!r.name.trim() || !r.slug) return toast('El nombre y la dirección web son obligatorios.', 'danger');
    if (!r.onlinePaymentEnabled && !r.counterPaymentEnabled) return toast('Activa al menos un método de pago.', 'danger');
    setSaving(true);
    try { await data.saveRestaurant(r); toast('Cambios guardados'); } catch (err) { toast((err as Error).message, 'danger'); } finally { setSaving(false); }
  };

  return (
    <div className="stack-lg">
    {isPlatform && <SuspensionPanel restaurant={restaurant} />}
    <form className="card stack-lg" onSubmit={save}>
      {!canEdit && <Notice>Solo el propietario puede cambiar estos datos.</Notice>}
      <fieldset className="fieldset" disabled={!canEdit}>
      <div className="form-grid">
        <label className="field"><span>Nombre</span><input id="rf-name" value={r.name} onChange={(e) => set('name', e.target.value)} /></label>
        <label className="field"><span>Dirección web (slug)</span>
          <input id="rf-slug" value={r.slug} disabled={!isPlatform} onChange={(e) => set('slug', slugify(e.target.value))} />
          {!isPlatform && <small className="muted">Solo la plataforma puede cambiarla: cambiarla invalida los QR impresos.</small>}
        </label>
        <label className="field field--wide"><span>Descripción corta</span><input id="rf-tagline" value={r.tagline} onChange={(e) => set('tagline', e.target.value)} /></label>
        <label className="field"><span>Dirección</span><input id="rf-address" value={r.address} onChange={(e) => set('address', e.target.value)} /></label>
        <label className="field"><span>Teléfono</span><input id="rf-phone" value={r.phone} onChange={(e) => set('phone', e.target.value)} /></label>
        <label className="field"><span>Número de mesas</span><input id="rf-tables" type="number" min={0} max={500} value={r.tables} onChange={(e) => set('tables', Math.max(0, Number(e.target.value)))} /></label>
        <label className="field"><span>Tiempo medio de preparación (min)</span><input id="rf-prep" type="number" min={1} max={120} value={r.prepMinutes} onChange={(e) => set('prepMinutes', Math.max(1, Number(e.target.value)))} /></label>
      </div>
      <div className="toggles">
        <Toggle id="rf-active" label="Acepta pedidos" hint="Si está desactivado, los clientes ven la carta cerrada." checked={r.active} onChange={(v) => set('active', v)} />
        <Toggle id="rf-pickup" label="Pedidos para recoger" checked={r.pickupEnabled} onChange={(v) => set('pickupEnabled', v)} />
        {onlinePaymentsAvailable ? (
          <Toggle id="rf-online" label="Pago online" hint="Pasarela simulada de la demo: no cobra nada." checked={r.onlinePaymentEnabled} onChange={(v) => set('onlinePaymentEnabled', v)} />
        ) : (
          <Toggle id="rf-online" label="Pago online" hint="Desactivado hasta integrar un proveedor de pagos real." checked={false} disabled onChange={() => {}} />
        )}
        <Toggle id="rf-counter" label="Pago en caja" checked={r.counterPaymentEnabled} onChange={(v) => set('counterPaymentEnabled', v)} />
      </div>
      </fieldset>
      {canEdit && (
        <div className="row">
          <button type="submit" className="btn btn--primary" disabled={!dirty || saving}>{saving ? 'Guardando…' : 'Guardar cambios'}</button>
          {dirty && <button type="button" className="btn btn--ghost" onClick={() => setR(restaurant)}>Descartar</button>}
        </div>
      )}
    </form>
    </div>
  );
}

/** Solo plataforma: suspender o reactivar. El motivo queda en el registro de auditoría. */
function SuspensionPanel({ restaurant }: { restaurant: Restaurant }) {
  const toast = useToast();
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState(false);
  const apply = async (suspended: boolean) => {
    setBusy(true);
    try {
      await data.setRestaurantSuspension(restaurant.id, suspended, reason);
      toast(suspended ? `${restaurant.name} suspendido` : `${restaurant.name} reactivado`);
      setReason('');
    } catch (e) {
      toast((e as Error).message, 'danger');
    } finally {
      setBusy(false);
    }
  };
  return (
    <section className="card stack">
      <h3 className="card__title">Suspensión (plataforma)</h3>
      <p className="muted small">
        {restaurant.suspended
          ? 'Suspendido: no acepta pedidos nuevos aunque el restaurante se marque como abierto.'
          : 'Activo para la plataforma. Si lo suspendes, el restaurante no podrá reactivarse por sí mismo.'}
      </p>
      <label className="field">
        <span>Motivo {restaurant.suspended ? '(opcional)' : '(obligatorio)'}</span>
        <input id="susp-reason" value={reason} maxLength={200} onChange={(e) => setReason(e.target.value)} placeholder="Queda en el registro de auditoría" />
      </label>
      <div className="row">
        {restaurant.suspended
          ? <button type="button" className="btn btn--primary" disabled={busy} onClick={() => apply(false)}>Reactivar</button>
          : <button type="button" className="btn btn--danger" disabled={busy || reason.trim().length < 3} onClick={() => apply(true)}>Suspender</button>}
      </div>
    </section>
  );
}

/** Equipo del restaurante. Cada acción la valida la base de datos (staff_add_member, etc.). */
function TeamPanel({ restaurant, session }: { restaurant: Restaurant; session: StaffSession | null }) {
  const toast = useToast();
  const { value: members = [], loading, error, reload } = useStaff(restaurant.id);
  const roles = manageableRoles(session, restaurant.id);
  const [email, setEmail] = useState('');
  const [role, setRole] = useState<StaffRole>(roles.includes('waiter') ? 'waiter' : roles[0] ?? 'waiter');
  const [removing, setRemoving] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const run = async (fn: () => Promise<void>, ok: string) => {
    setBusy(true);
    try {
      await fn();
      toast(ok);
      reload();
    } catch (e) {
      toast((e as Error).message, 'danger');
    } finally {
      setBusy(false);
      setRemoving(null);
    }
  };

  return (
    <div className="stack-lg">
      {data.kind === 'mock' && <Notice>En el modo demo no hay cuentas de personal. El equipo se gestiona conectando Supabase.</Notice>}
      <form className="card stack" onSubmit={(e) => { e.preventDefault(); if (email.trim()) void run(async () => { await data.addStaff(restaurant.id, email, role); setEmail(''); }, 'Persona añadida al equipo'); }}>
        <h3 className="card__title">Añadir al equipo</h3>
        <p className="muted small">La cuenta tiene que existir ya (Supabase → Authentication → Users). Las invitaciones por correo llegarán en una fase posterior.</p>
        <div className="form-grid">
          <label className="field"><span>Email</span><input id="team-email" type="email" value={email} onChange={(e) => setEmail(e.target.value)} /></label>
          <label className="field"><span>Función</span>
            <select id="team-role" value={role} onChange={(e) => setRole(e.target.value as StaffRole)}>
              {roles.map((r) => <option key={r} value={r}>{roleLabel[r]}</option>)}
            </select>
          </label>
        </div>
        <button className="btn btn--primary" type="submit" disabled={busy || !email.trim()}>Añadir</button>
      </form>
      <section className="card">
        <h3 className="card__title">Equipo</h3>
        {error && <Notice tone="danger">{error}</Notice>}
        {loading && !members.length ? <Spinner /> : (
          <ul className="team">
            {members.map((m) => {
              const manageable = !m.isMe && roles.includes(m.role);
              return (
                <li key={m.userId} className="team__row">
                  <span className="team__who"><strong>{m.email}</strong>{m.isMe && <span className="muted small"> (tú)</span>}</span>
                  {manageable ? (
                    <label className="team__role">
                      <span className="sr-only">Función de {m.email}</span>
                      <select value={m.role} disabled={busy}
                        onChange={(e) => run(() => data.changeStaffRole(restaurant.id, m.userId, e.target.value as StaffRole), 'Función cambiada')}>
                        {roles.map((r) => <option key={r} value={r}>{roleLabel[r]}</option>)}
                      </select>
                    </label>
                  ) : <Badge tone="neutral">{roleLabel[m.role]}</Badge>}
                  {manageable && (removing === m.userId ? (
                    <span className="row">
                      <button className="btn btn--danger btn--sm" disabled={busy} onClick={() => run(() => data.removeStaff(restaurant.id, m.userId), 'Acceso retirado')}>Retirar acceso</button>
                      <button className="btn btn--ghost btn--sm" onClick={() => setRemoving(null)}>No</button>
                    </span>
                  ) : <button className="btn btn--ghost btn--sm" onClick={() => setRemoving(m.userId)}>Quitar</button>)}
                </li>
              );
            })}
            {!members.length && !loading && <li className="muted small">Sin personas en el equipo.</li>}
          </ul>
        )}
      </section>
    </div>
  );
}

/** Registro de auditoría del restaurante (owner y plataforma). */
function AuditPanel({ restaurant }: { restaurant: Restaurant }) {
  const { value: entries = [], loading, error } = useAudit(restaurant.id);
  return (
    <section className="card">
      <h3 className="card__title">Registro de actividad</h3>
      {data.kind === 'mock' && <Notice>En el modo demo no se guarda registro.</Notice>}
      {error && <Notice tone="danger">{error}</Notice>}
      {loading && !entries.length ? <Spinner /> : (
        <ul className="audit">
          {entries.map((e, i) => (
            <li key={i} className="audit__row">
              <span className="muted small mono">{new Date(e.createdAt).toLocaleString('es-ES')}</span>
              <strong>{auditActionLabel[e.action] ?? e.action}</strong>
              <span className="small">{auditActor(e)}</span>
              {Object.keys(e.details).length > 0 && <span className="muted small">{auditDetails(e.details)}</span>}
            </li>
          ))}
          {!entries.length && !loading && data.kind !== 'mock' && <li className="muted small">Sin actividad registrada.</li>}
        </ul>
      )}
    </section>
  );
}

function MenuEditor({ restaurant }: { restaurant: Restaurant }) {
  const toast = useToast();
  const { value: menu, loading } = useMenu(restaurant.id);
  const [adding, setAdding] = useState(false);
  const [newCat, setNewCat] = useState('');
  if (loading && !menu) return <Spinner />;
  const categories = menu?.categories ?? [];
  const products = menu?.products ?? [];

  const save = async (p: Product, msg: string) => {
    try { await data.saveProduct(p); toast(msg); } catch (e) { toast((e as Error).message, 'danger'); }
  };

  return (
    <div className="stack-lg">
      <div className="row row--wrap">
        <button className="btn btn--primary" onClick={() => setAdding(true)} disabled={!categories.length}><Icon name="plus" /> Añadir producto</button>
        <form className="row" onSubmit={async (e) => {
          e.preventDefault();
          if (!newCat.trim()) return;
          try {
            await data.createCategory(restaurant.id, newCat.trim());
            toast(`Categoría «${newCat.trim()}» creada`);
            setNewCat('');
          } catch (err) {
            toast((err as Error).message, 'danger');
          }
        }}>
          <label className="sr-only" htmlFor="new-cat">Nueva categoría</label>
          <input id="new-cat" className="input" value={newCat} onChange={(e) => setNewCat(e.target.value)} placeholder="Nueva categoría" />
          <button className="btn btn--outline" type="submit">Crear</button>
        </form>
      </div>
      {categories.map((c) => (
        <section key={c.id} className="card">
          <h3 className="card__title">{c.name}</h3>
          <ul className="menu-admin">
            {products.filter((p) => p.categoryId === c.id).map((p) => (
              <li key={p.id} className="menu-admin__row">
                <FoodArt art={p.art} imageUrl={p.imageUrl} label="" className="menu-admin__art" />
                <div className="menu-admin__name">
                  <strong>{p.name}</strong>
                  <span className="muted small clamp-1">{p.description}</span>
                </div>
                <PriceInput product={p} onSave={(price) => save({ ...p, price }, `Precio de ${p.name} actualizado`)} />
                <label className="mini-toggle">
                  <input type="checkbox" checked={p.available} onChange={(e) => save({ ...p, available: e.target.checked }, `${p.name}: ${e.target.checked ? 'disponible' : 'agotado'}`)} />
                  <span>{p.available ? 'Disponible' : 'Agotado'}</span>
                </label>
              </li>
            ))}
            {!products.some((p) => p.categoryId === c.id) && <li className="muted small">Sin productos todavía.</li>}
          </ul>
        </section>
      ))}
      <AddProduct open={adding} restaurant={restaurant} categories={categories} onClose={() => setAdding(false)} />
    </div>
  );
}

function PriceInput({ product, onSave }: { product: Product; onSave: (cents: number) => void }) {
  const [v, setV] = useState((product.price / 100).toFixed(2));
  useEffect(() => { setV((product.price / 100).toFixed(2)); }, [product.price]);
  const commit = () => {
    const cents = Math.round(parseFloat(v.replace(',', '.')) * 100);
    if (!Number.isFinite(cents) || cents < 0) return setV((product.price / 100).toFixed(2));
    if (cents !== product.price) onSave(cents);
  };
  return (
    <label className="price-input">
      <span className="sr-only">Precio de {product.name}</span>
      <input id={`price-${product.id}`} inputMode="decimal" value={v} onChange={(e) => setV(e.target.value)} onBlur={commit}
        onKeyDown={(e) => e.key === 'Enter' && (e.currentTarget as HTMLInputElement).blur()} />
      <span aria-hidden="true">€</span>
    </label>
  );
}

function AddProduct({ open, restaurant, categories, onClose }: {
  open: boolean; restaurant: Restaurant; categories: { id: string; name: string }[]; onClose: () => void;
}) {
  const toast = useToast();
  const [f, setF] = useState({ name: '', description: '', price: '', categoryId: '', art: 'pizza' as Art, allergens: '' });
  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    const price = Math.round(parseFloat(f.price.replace(',', '.')) * 100);
    if (!f.name.trim() || !Number.isFinite(price)) return toast('Indica nombre y precio.', 'danger');
    try {
      await data.createProduct({
        restaurantId: restaurant.id, categoryId: f.categoryId || categories[0].id, name: f.name.trim(), description: f.description.trim(),
        price, art: f.art, imageUrl: null, allergens: f.allergens.split(',').map((s) => s.trim()).filter(Boolean), tags: [], available: true,
      });
      toast(`${f.name.trim()} añadido a la carta`);
      setF({ name: '', description: '', price: '', categoryId: '', art: 'pizza', allergens: '' });
      onClose();
    } catch (err) {
      toast((err as Error).message, 'danger');
    }
  };
  return (
    <Modal open={open} onClose={onClose} title="Añadir producto">
      <form className="sheet__body stack" onSubmit={submit}>
        <h2 className="sheet__title">Añadir producto</h2>
        <label className="field"><span>Nombre</span><input id="ap-name" value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} /></label>
        <label className="field"><span>Descripción</span><textarea id="ap-desc" rows={2} value={f.description} onChange={(e) => setF({ ...f, description: e.target.value })} /></label>
        <div className="form-grid">
          <label className="field"><span>Precio (€)</span><input id="ap-price" inputMode="decimal" value={f.price} onChange={(e) => setF({ ...f, price: e.target.value })} placeholder="9,50" /></label>
          <label className="field"><span>Categoría</span>
            <select id="ap-cat" value={f.categoryId || categories[0]?.id} onChange={(e) => setF({ ...f, categoryId: e.target.value })}>
              {categories.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
            </select>
          </label>
          <label className="field"><span>Ilustración</span>
            <select id="ap-art" value={f.art} onChange={(e) => setF({ ...f, art: e.target.value as Art })}>
              {ART_OPTIONS.map((a) => <option key={a.value} value={a.value}>{a.label}</option>)}
            </select>
          </label>
          <label className="field"><span>Alérgenos (separados por comas)</span><input id="ap-all" value={f.allergens} onChange={(e) => setF({ ...f, allergens: e.target.value })} /></label>
        </div>
        <p className="muted small">La foto real del producto se podrá subir cuando se conecte el almacenamiento (Supabase Storage).</p>
        <button className="btn btn--primary btn--block" type="submit">Añadir a la carta</button>
      </form>
    </Modal>
  );
}

function QrSheet({ restaurant }: { restaurant: Restaurant }) {
  const tables = Array.from({ length: Math.min(restaurant.tables, 60) }, (_, i) => i + 1);
  return (
    <div className="stack-lg">
      <Notice>
        Cada QR abre la carta con la mesa ya seleccionada. Apuntan a <span className="mono">{config.publicBaseUrl}/r/{restaurant.slug}/…</span>,
        la dirección prevista para producción. En esta demo, usa «Probar» para abrir la mesa aquí mismo.
      </Notice>
      <ul className="qr-grid">
        <li><QrCard label="Para recoger" url={`${config.publicBaseUrl}/r/${restaurant.slug}`} href={hrefFor({ view: 'cliente', slug: restaurant.slug })} /></li>
        {tables.map((t) => (
          <li key={t}><QrCard label={`Mesa ${t}`} url={`${config.publicBaseUrl}/r/${restaurant.slug}/mesa/${t}`} href={hrefFor({ view: 'cliente', slug: restaurant.slug, table: t })} /></li>
        ))}
      </ul>
    </div>
  );
}

function QrCard({ label, url, href }: { label: string; url: string; href: string }) {
  const [svg, setSvg] = useState('');
  useEffect(() => {
    QRCode.toString(url, { type: 'svg', margin: 1, color: { dark: '#13201A', light: '#FFFFFF' } }).then(setSvg).catch(() => setSvg(''));
  }, [url]);
  const markup = useMemo(() => ({ __html: svg }), [svg]);
  return (
    <div className="qr-card">
      <div className="qr-card__code" role="img" aria-label={`Código QR de ${label}`} dangerouslySetInnerHTML={markup} />
      <strong>{label}</strong>
      <a className="btn btn--outline btn--sm" href={href}>Probar <Icon name="arrow" size={16} /></a>
    </div>
  );
}

function CreateRestaurant({ open, onClose, onCreated }: { open: boolean; onClose: () => void; onCreated: (r: Restaurant) => void }) {
  const toast = useToast();
  const [name, setName] = useState('');
  const [slug, setSlug] = useState('');
  const [touched, setTouched] = useState(false);
  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!name.trim()) return toast('Escribe el nombre del restaurante.', 'danger');
    try {
      const r = await data.createRestaurant({ name: name.trim(), slug: slug || slugify(name) });
      toast(`${r.name} creado. Añade su carta y actívalo cuando esté listo.`);
      setName(''); setSlug(''); setTouched(false);
      onCreated(r);
    } catch (err) {
      toast((err as Error).message, 'danger');
    }
  };
  return (
    <Modal open={open} onClose={onClose} title="Nuevo restaurante">
      <form className="sheet__body stack" onSubmit={submit}>
        <h2 className="sheet__title">Nuevo restaurante</h2>
        <label className="field"><span>Nombre</span>
          <input id="nr-name" value={name} onChange={(e) => { setName(e.target.value); if (!touched) setSlug(slugify(e.target.value)); }} />
        </label>
        <label className="field"><span>Dirección web (slug)</span>
          <input id="nr-slug" value={slug} onChange={(e) => { setTouched(true); setSlug(slugify(e.target.value)); }} />
          <small className="muted">{config.publicBaseUrl}/r/{slug || 'mi-restaurante'}</small>
        </label>
        <p className="muted small">Se crea en pausa: no recibirá pedidos hasta que lo actives.</p>
        <button className="btn btn--primary btn--block" type="submit">Crear restaurante</button>
      </form>
    </Modal>
  );
}

/** Propietario: aviso si hay solicitudes de soporte pendientes. */
function PendingSupportNotice({ restaurant, onOpen }: { restaurant: Restaurant; onOpen: () => void }) {
  const { value: requests = [] } = useSupportRequests(restaurant.id, true);
  const pending = requests.filter((g) => g.status === 'pendiente').length;
  if (!pending) return null;
  return (
    <Notice tone="warn">
      La plataforma ha pedido acceso de soporte a {restaurant.name}.{' '}
      <button type="button" className="link-btn" onClick={onOpen}>Revisar solicitud</button>
    </Notice>
  );
}

function SupportHistory({ grants }: { grants: SupportGrant[] }) {
  if (!grants.length) return <p className="muted small">Sin solicitudes anteriores.</p>;
  return (
    <ul className="audit">
      {grants.map((g) => (
        <li key={g.id} className="audit__row">
          <span className="muted small mono">{new Date(g.requestedAt).toLocaleString('es-ES')}</span>
          <strong>{supportStatusLabel[g.status]}</strong>
          <span className="small">{g.requestedByEmail ? `${g.requestedByEmail}: ` : ''}{g.reason}</span>
          {g.decidedAt && <span className="muted small">Respondida por {g.decidedByEmail || '—'} el {new Date(g.decidedAt).toLocaleString('es-ES')}</span>}
        </li>
      ))}
    </ul>
  );
}

/** Propietario: ver, aprobar (2 horas, solo lectura), rechazar y revocar. */
function SupportOwnerPanel({ restaurant }: { restaurant: Restaurant }) {
  const toast = useToast();
  const now = useNow(30000);
  const { value: grants = [], loading, error, reload } = useSupportRequests(restaurant.id, true);
  const [confirming, setConfirming] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const run = async (fn: () => Promise<void>, ok: string) => {
    setBusy(true);
    try {
      await fn();
      toast(ok);
    } catch (e) {
      toast((e as Error).message, 'danger');
    } finally {
      setBusy(false);
      setConfirming(null);
      reload();
    }
  };
  const pending = grants.filter((g) => g.status === 'pendiente');
  const active = grants.filter((g) => isSupportActive(g, now));
  const past = grants.filter((g) => g.status !== 'pendiente' && !isSupportActive(g, now));

  return (
    <div className="stack-lg">
      <Notice>
        Solo tú, como propietario, puedes dar acceso de soporte. Es de <strong>solo lectura</strong>, dura <strong>2 horas</strong> y
        puedes revocarlo cuando quieras. Cada consulta queda en el Registro. No incluye nombres, teléfonos ni notas de clientes.
      </Notice>
      {error && <Notice tone="danger">{error}</Notice>}
      {loading && !grants.length ? <Spinner /> : null}
      {active.map((g) => (
        <section key={g.id} className="card stack">
          <h3 className="card__title">Acceso de soporte activo</h3>
          <p>{g.requestedByEmail} · quedan <strong>{remainingLabel(g.expiresAt!, now)}</strong> (hasta las {formatTime(g.expiresAt!)})</p>
          <p className="muted small">Motivo: {g.reason}</p>
          <button className="btn btn--danger" disabled={busy} onClick={() => run(() => data.revokeSupport(g.id), 'Acceso de soporte revocado')}>Revocar ahora</button>
        </section>
      ))}
      {pending.map((g) => (
        <section key={g.id} className="card stack">
          <h3 className="card__title">Solicitud pendiente</h3>
          <p><strong>{g.requestedByEmail}</strong> pide acceso de solo lectura.</p>
          <p className="muted">Motivo: {g.reason}</p>
          {confirming === g.id ? (
            <div className="stack">
              <Notice tone="warn">Darás acceso de <strong>solo lectura</strong> durante <strong>2 horas</strong> a pedidos (sin datos personales), estado del restaurante y avisos de pago.</Notice>
              <div className="row row--wrap">
                <button className="btn btn--primary" disabled={busy} onClick={() => run(() => data.decideSupport(g.id, true), 'Acceso aprobado durante 2 horas')}>Sí, aprobar</button>
                <button className="btn btn--ghost" onClick={() => setConfirming(null)}>Volver</button>
              </div>
            </div>
          ) : (
            <div className="row row--wrap">
              <button className="btn btn--primary" disabled={busy} onClick={() => setConfirming(g.id)}>Aprobar…</button>
              <button className="btn btn--outline" disabled={busy} onClick={() => run(() => data.decideSupport(g.id, false), 'Solicitud rechazada')}>Rechazar</button>
            </div>
          )}
        </section>
      ))}
      {!active.length && !pending.length && !loading && <p className="muted">No hay solicitudes pendientes ni accesos activos.</p>}
      <section className="card">
        <h3 className="card__title">Historial</h3>
        <SupportHistory grants={past} />
      </section>
      <SupportDenials restaurantId={restaurant.id} />
    </div>
  );
}

/** Intentos de consulta denegados (sin datos de clientes): quién, cuándo, qué y por qué. */
function SupportDenials({ restaurantId }: { restaurantId: string | null }) {
  const { value: denials = [], loading, error } = useSupportDenials(restaurantId, true);
  return (
    <section className="card">
      <h3 className="card__title">Intentos de acceso denegados</h3>
      <p className="muted small">Los intentos iguales en 10 minutos se agrupan y se cuentan.</p>
      {error && <Notice tone="danger">{error}</Notice>}
      {loading && !denials.length ? <Spinner /> : !denials.length ? <p className="muted small">Ninguno.</p> : (
        <ul className="audit">
          {denials.map((d, i) => (
            <li key={i} className="audit__row">
              <span className="muted small mono">{new Date(d.lastAt).toLocaleString('es-ES')}</span>
              <strong>{denialReasonLabel[d.reason] ?? d.reason}</strong>
              <span className="small">{d.actorEmail ?? d.actorKind} · {denialSummary(d)}</span>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}

type SupportViewKind = 'estado' | 'pedidos' | 'avisos';

/** Plataforma: solicitar acceso y, si el propietario lo aprueba, consultar en solo lectura. */
function SupportRequestPanel({ restaurant }: { restaurant: Restaurant }) {
  const toast = useToast();
  const now = useNow(30000);
  const { value: mine = [], loading, error, reload } = useMySupportRequests(true);
  const grants = mine.filter((g) => g.restaurantId === restaurant.id);
  const active = grants.find((g) => isSupportActive(g, now));
  const pending = grants.find((g) => g.status === 'pendiente');
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState(false);
  const [view, setView] = useState<{ kind: SupportViewKind; data: unknown } | null>(null);

  const run = async (fn: () => Promise<void>, ok?: string) => {
    setBusy(true);
    try {
      await fn();
      if (ok) toast(ok);
    } catch (e) {
      toast((e as Error).message, 'danger');
      setView(null);
    } finally {
      setBusy(false);
      reload();
    }
  };
  const load = (kind: SupportViewKind) =>
    run(async () => {
      const d = kind === 'estado' ? await data.supportViewRestaurant(restaurant.id)
        : kind === 'pedidos' ? await data.supportViewOrders(restaurant.id)
          : await data.supportViewPaymentEvents(restaurant.id);
      setView({ kind, data: d });
    });

  return (
    <div className="stack-lg">
      <Notice>
        Acceso de <strong>solo lectura</strong>, solo a este restaurante, durante <strong>2 horas</strong> desde que su propietario lo
        apruebe. El propietario puede revocarlo y ve cada consulta en su Registro.
      </Notice>
      {error && <Notice tone="danger">{error}</Notice>}
      {loading && !mine.length ? <Spinner /> : active ? (
        <section className="card stack">
          <h3 className="card__title">Acceso activo · quedan {remainingLabel(active.expiresAt!, now)}</h3>
          <p className="muted small">Aprobado por {active.decidedByEmail} · caduca a las {formatTime(active.expiresAt!)}</p>
          <div className="row row--wrap">
            <button className="btn btn--outline btn--sm" disabled={busy} onClick={() => load('estado')}>Estado del restaurante</button>
            <button className="btn btn--outline btn--sm" disabled={busy} onClick={() => load('pedidos')}>Últimos pedidos</button>
            <button className="btn btn--outline btn--sm" disabled={busy} onClick={() => load('avisos')}>Avisos de pago</button>
            <button className="btn btn--ghost btn--sm" disabled={busy} onClick={() => run(async () => { await data.cancelSupport(active.id); setView(null); }, 'Acceso terminado')}>Terminar acceso</button>
          </div>
          {view && <SupportViewResult kind={view.kind} data={view.data} />}
        </section>
      ) : pending ? (
        <section className="card stack">
          <h3 className="card__title">Pendiente de aprobación del propietario</h3>
          <p className="muted">Motivo: {pending.reason}</p>
          <button className="btn btn--ghost" disabled={busy} onClick={() => run(() => data.cancelSupport(pending.id), 'Solicitud retirada')}>Retirar solicitud</button>
        </section>
      ) : (
        <form className="card stack" onSubmit={(e) => { e.preventDefault(); void run(async () => { await data.requestSupport(restaurant.id, reason); setReason(''); }, 'Solicitud enviada al propietario'); }}>
          <h3 className="card__title">Solicitar acceso de soporte</h3>
          <label className="field"><span>Motivo (lo verá el propietario)</span>
            <textarea id="support-reason" rows={3} maxLength={300} value={reason} onChange={(e) => setReason(e.target.value)} placeholder="Ej.: los pedidos no llegan a cocina desde esta mañana" />
          </label>
          <button className="btn btn--primary" type="submit" disabled={busy || reason.trim().length < 10}>Enviar solicitud</button>
        </form>
      )}
      <section className="card">
        <h3 className="card__title">Mis solicitudes para este restaurante</h3>
        <SupportHistory grants={grants.filter((g) => g !== active && g !== pending)} />
      </section>
      <SupportDenials restaurantId={restaurant.id} />
    </div>
  );
}

function SupportViewResult({ kind, data: d }: { kind: SupportViewKind; data: unknown }) {
  if (kind === 'estado') {
    const v = d as SupportRestaurantView;
    return (
      <div className="stack small">
        <p><strong>{v.restaurant.name}</strong> · {v.restaurant.suspended ? 'suspendido' : v.restaurant.active ? 'abierto' : 'cerrado'} ·
          recogida {v.restaurant.pickupEnabled ? 'sí' : 'no'} · caja {v.restaurant.counterPaymentEnabled ? 'sí' : 'no'} · online {v.restaurant.onlinePaymentEnabled ? 'sí' : 'no'}</p>
        <p>Carta: {v.menu.products} productos ({v.menu.unavailable} agotados) en {v.menu.categories} categorías</p>
        <p>Equipo: {Object.entries(v.staff).map(([r, n]) => `${roleLabel[r as StaffRole] ?? r}: ${n}`).join(' · ') || 'sin personal'}</p>
        <p>Pedidos: {v.orders.last24h} en 24 h · {v.orders.inProgress} en curso · {v.orders.pendingOnline} pago online pendiente · {v.orders.pendingCounter} por cobrar
          {v.orders.lastOrderAt ? ` · último a las ${formatTime(v.orders.lastOrderAt)}` : ''}</p>
      </div>
    );
  }
  if (kind === 'pedidos') {
    const rows = d as SupportOrderView[];
    if (!rows.length) return <p className="muted small">Sin pedidos.</p>;
    return (
      <ul className="audit">
        {rows.map((o) => (
          <li key={o.number} className="audit__row">
            <strong className="mono">{orderCode(o.number)} · {formatTime(o.createdAt)} · {o.mode === 'mesa' ? `Mesa ${o.table}` : 'Recoger'}</strong>
            <span className="small">{prepLabel[o.prepStatus].label} · {paymentLabel[o.paymentStatus].label} · {formatPrice(o.total)}
              {o.hasNotes ? ' · con notas (ocultas)' : ''}</span>
            <span className="muted small">{o.items.map((i) => `${i.quantity}× ${i.name}`).join(', ')}</span>
          </li>
        ))}
      </ul>
    );
  }
  const rows = d as SupportPaymentEventView[];
  if (!rows.length) return <p className="muted small">Sin avisos de pago.</p>;
  return (
    <ul className="audit">
      {rows.map((e, i) => (
        <li key={i} className="audit__row">
          <strong>{e.outcome} · {e.resolution}</strong>
          <span className="small">{new Date(e.createdAt).toLocaleString('es-ES')}{e.orderNumber ? ` · pedido ${orderCode(e.orderNumber)}` : ''}{e.amount != null ? ` · ${formatPrice(e.amount)}` : ''}</span>
          {e.detail && <span className="muted small">{e.detail}</span>}
        </li>
      ))}
    </ul>
  );
}
