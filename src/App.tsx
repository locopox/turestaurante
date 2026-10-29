import { useEffect, useState } from 'react';
import { ToastProvider } from './components/Toast';
import { Icon, Notice, Spinner } from './components/ui';
import { config } from './config';
import { useRestaurants } from './hooks/useData';
import { useRoute, type Route } from './hooks/useRoute';
import { safeStorage } from './lib/storage';
import { data, payments } from './services';
import { AdminView } from './views/admin/AdminView';
import { CustomerApp } from './views/customer/CustomerApp';
import { Home } from './views/Home';
import { KitchenView } from './views/kitchen/KitchenView';
import { OrdersPanel } from './views/staff/OrdersPanel';

const SEL_KEY = 'turestaurante:restaurante-activo';

export function App() {
  const route = useRoute();
  const { value: restaurants = [], loading, error } = useRestaurants();
  const [selectedId, setSelectedId] = useState<string>(() => safeStorage.get(SEL_KEY, 'r-piazza'));
  useEffect(() => { safeStorage.set(SEL_KEY, selectedId); }, [selectedId]);

  const selected = restaurants.find((r) => r.id === selectedId) ?? restaurants[0];
  // El cliente usa el restaurante del enlace/QR si lo hay
  const customerRestaurant = route.view === 'cliente' && route.slug
    ? restaurants.find((r) => r.slug === route.slug) : selected;

  let body;
  if (error) body = <div className="page"><Notice tone="danger">No se pudo conectar con los datos: {error}</Notice></div>;
  else if (loading && !restaurants.length) body = <Spinner />;
  else if (route.view === 'cliente')
    body = customerRestaurant
      ? <CustomerApp key={`${customerRestaurant.id}-${route.table ?? ''}`} restaurant={customerRestaurant} qrTable={route.table} />
      : <div className="page"><Notice tone="warn">No encontramos este restaurante. Revisa el enlace o el código QR.</Notice></div>;
  else if (!selected) body = <div className="page"><Notice>No hay restaurantes todavía. Crea uno en Administración.</Notice></div>;
  else if (route.view === 'panel') body = <OrdersPanel restaurant={selected} />;
  else if (route.view === 'cocina') body = <KitchenView restaurant={selected} />;
  else if (route.view === 'admin') body = <AdminView selectedId={selected.id} onSelect={setSelectedId} />;
  else body = <Home restaurant={selected} />;

  return (
    <ToastProvider>
      <a className="skip" href="#main">Saltar al contenido</a>
      <AppBar route={route} restaurants={restaurants} selectedId={selected?.id ?? ''} onSelect={setSelectedId}
        customerName={route.view === 'cliente' ? customerRestaurant?.name : undefined} />
      <main id="main" className={route.view === 'cliente' ? 'main main--customer' : 'main'}>{body}</main>
    </ToastProvider>
  );
}

const nav: { view: Route['view']; label: string; href: string; icon: string }[] = [
  { view: 'inicio', label: 'Inicio', href: '#inicio', icon: 'store' },
  { view: 'cliente', label: 'Cliente', href: '#cliente', icon: 'phone' },
  { view: 'panel', label: 'Panel', href: '#panel', icon: 'list' },
  { view: 'cocina', label: 'Cocina', href: '#cocina', icon: 'chef' },
  { view: 'admin', label: 'Admin', href: '#admin', icon: 'settings' },
];

function AppBar({ route, restaurants, selectedId, onSelect, customerName }: {
  route: Route; restaurants: { id: string; name: string }[]; selectedId: string; onSelect: (id: string) => void; customerName?: string;
}) {
  const [resetAsk, setResetAsk] = useState(false);
  return (
    <header className="appbar">
      <div className="appbar__inner">
        <a className="brand" href="#inicio" aria-label="TuRestaurante, inicio">
          <span className="brand__mark" aria-hidden="true">
            <svg viewBox="0 0 24 24" width="18" height="18"><path d="M7 3v8M5 3v4a2 2 0 0 0 4 0V3M7 11v10M16 21V3c-2.5 1-4 4-4 8h4" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" /></svg>
          </span>
          <span className="brand__name">TuRestaurante</span>
        </a>
        <nav className="appnav" aria-label="Interfaces de la demo">
          {nav.map((n) => (
            <a key={n.view} href={n.href} className={route.view === n.view ? 'is-active' : ''} aria-current={route.view === n.view ? 'page' : undefined}>
              <Icon name={n.icon} size={18} /><span>{n.label}</span>
            </a>
          ))}
        </nav>
        <div className="appbar__tools">
          {route.view === 'cliente' && customerName ? (
            <span className="appbar__ctx">{customerName}</span>
          ) : (
            <label className="rest-select">
              <span className="sr-only">Restaurante</span>
              <select id="rest-select" value={selectedId} onChange={(e) => onSelect(e.target.value)}>
                {restaurants.map((r) => <option key={r.id} value={r.id}>{r.name}</option>)}
              </select>
            </label>
          )}
          {data.resetDemo && (resetAsk ? (
            <span className="reset-ask">
              <button className="btn btn--sm btn--danger" onClick={async () => { await data.resetDemo!(); setResetAsk(false); }}>Reiniciar</button>
              <button className="btn btn--sm btn--ghost" onClick={() => setResetAsk(false)}>No</button>
            </span>
          ) : (
            <button className="icon-btn" onClick={() => setResetAsk(true)} aria-label="Reiniciar datos de demostración" title="Reiniciar datos de demostración">
              <Icon name="refresh" size={18} />
            </button>
          ))}
        </div>
      </div>
      {(config.dataBackend === 'mock' || payments.simulated) && (
        <p className="demo-strip">Demo: datos ficticios y pagos simulados, sin cargos reales</p>
      )}
    </header>
  );
}
