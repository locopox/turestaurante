import { useEffect, useState } from 'react';
import { ToastProvider } from './components/Toast';
import { ChangePasswordForm, ConfigScreen, LoginScreen, SetPasswordScreen } from './components/StaffAccess';
import { Icon, Modal, Notice, Spinner } from './components/ui';
import { configBlocked, isDemo } from './config';
import { useRestaurants, useSession } from './hooks/useData';
import { useRoute, type Route } from './hooks/useRoute';
import { staffGate } from './lib/authRedirect';
import { can, roleIn, roleLabel } from './lib/permissions';
import { safeStorage } from './lib/storage';
import { data } from './services';
import type { StaffRole, StaffSession } from './types';
import { AdminView } from './views/admin/AdminView';
import { CustomerApp } from './views/customer/CustomerApp';
import { Home } from './views/Home';
import { KitchenView } from './views/kitchen/KitchenView';
import { OrdersPanel } from './views/staff/OrdersPanel';

const SEL_KEY = 'turestaurante:restaurante-activo';

export function App() {
  // Con variables de entorno incorrectas no se carga nada: se explica qué falta.
  if (configBlocked) return <ConfigScreen />;
  return <AppContent />;
}

function AppContent() {
  const route = useRoute();
  const { value: restaurants = [], loading, error } = useRestaurants();
  const { value: session = null, loading: sessionLoading, reload: reloadSession } = useSession();
  const [selectedId, setSelectedId] = useState<string>(() => safeStorage.get(SEL_KEY, 'r-piazza'));
  useEffect(() => { safeStorage.set(SEL_KEY, selectedId); }, [selectedId]);

  const staffView = route.view === 'panel' || route.view === 'cocina' || route.view === 'admin';
  const needsLogin = staffView && data.requiresLogin;
  // En las vistas del personal solo aparecen los restaurantes donde el usuario tiene un rol.
  const selectable = needsLogin ? restaurants.filter((r) => roleIn(session, r.id)) : restaurants;
  const selected = selectable.find((r) => r.id === selectedId) ?? selectable[0];
  // El cliente usa el restaurante del enlace/QR si lo hay
  const customerRestaurant = route.view === 'cliente' && route.slug
    ? restaurants.find((r) => r.slug === route.slug) : selected;

  const recoveryPending = data.isPasswordRecoveryPending();
  const authRedirect = data.getAuthRedirect();
  // Qué puede verse según la sesión. Con una recuperación de contraseña pendiente, la única
  // pantalla accesible es la de fijar la contraseña (ver staffGate).
  const gate = staffGate({
    isStaffView: staffView, requiresLogin: data.requiresLogin, sessionLoading, hasSession: !!session, recoveryPending,
  });

  let body;
  if (gate === 'set-password' && session) body = <SetPasswordScreen email={session.email} onDone={reloadSession} />;
  // En las vistas del personal, la sesión va primero: sin ella no se carga nada más.
  else if (gate === 'loading') body = <Spinner />;
  else if (gate === 'login') body = <LoginScreen onSignedIn={reloadSession} />;
  else if (error) body = <div className="page"><Notice tone="danger">No se pudo conectar con los datos: {error}</Notice></div>;
  else if (loading && !restaurants.length) body = <Spinner />;
  else if (route.view === 'cliente')
    body = customerRestaurant
      ? <CustomerApp key={`${customerRestaurant.id}-${route.table ?? ''}`} restaurant={customerRestaurant} qrTable={route.table} />
      : <div className="page"><Notice tone="warn">No encontramos este restaurante. Revisa el enlace o el código QR.</Notice></div>;
  else if (route.view === 'admin' && can(session, undefined, 'restaurant.create'))
    body = <AdminView selectedId={selected?.id ?? ''} onSelect={setSelectedId} session={session} />;
  else if (staffView && !selected)
    body = <div className="page"><Notice>Tu cuenta no tiene ningún restaurante asignado. Pide acceso al administrador de la plataforma.</Notice></div>;
  else if (!selected) body = <div className="page"><Notice>No hay restaurantes todavía. Crea uno en Administración.</Notice></div>;
  else if (route.view === 'panel')
    body = can(session, selected.id, 'orders.view') ? <OrdersPanel restaurant={selected} session={session} /> : <NoAccess />;
  else if (route.view === 'cocina')
    body = can(session, selected.id, 'orders.prep') ? <KitchenView restaurant={selected} /> : <NoAccess />;
  else if (route.view === 'admin')
    body = can(session, selected.id, 'restaurant.edit') ? <AdminView selectedId={selected.id} onSelect={setSelectedId} session={session} /> : <NoAccess />;
  else body = <Home restaurant={selected} />;

  return (
    <ToastProvider>
      <a className="skip" href="#main">Saltar al contenido</a>
      <AppBar route={route} restaurants={staffView ? selectable : restaurants} selectedId={selected?.id ?? ''} onSelect={setSelectedId}
        customerName={route.view === 'cliente' ? customerRestaurant?.name : undefined}
        session={data.requiresLogin ? session : null} selectedRole={roleIn(session, selected?.id)} onSignOut={reloadSession}
        canChangePassword={!!session && data.requiresLogin && !recoveryPending} />
      <main id="main" className={route.view === 'cliente' ? 'main main--customer' : 'main'}>
        {authRedirect.kind === 'error' && (
          <div className="page page--notice">
            <Notice tone="warn">
              {authRedirect.message}{' '}
              <a href="#panel">Ir a iniciar sesión</a>{' · '}
              <button type="button" className="link-btn" onClick={() => { data.dismissAuthRedirect(); reloadSession(); }}>Cerrar aviso</button>
            </Notice>
          </div>
        )}
        {body}
      </main>
    </ToastProvider>
  );
}

function NoAccess() {
  return <div className="page"><Notice tone="warn">Tu rol en este restaurante no tiene acceso a esta sección.</Notice></div>;
}

const nav: { view: Route['view']; label: string; href: string; icon: string }[] = [
  { view: 'inicio', label: 'Inicio', href: '#inicio', icon: 'store' },
  { view: 'cliente', label: 'Cliente', href: '#cliente', icon: 'phone' },
  { view: 'panel', label: 'Panel', href: '#panel', icon: 'list' },
  { view: 'cocina', label: 'Cocina', href: '#cocina', icon: 'chef' },
  { view: 'admin', label: 'Admin', href: '#admin', icon: 'settings' },
];

function AppBar({ route, restaurants, selectedId, onSelect, customerName, session, selectedRole, onSignOut, canChangePassword }: {
  route: Route; restaurants: { id: string; name: string }[]; selectedId: string; onSelect: (id: string) => void; customerName?: string;
  session: StaffSession | null; selectedRole: StaffRole | null; onSignOut: () => void; canChangePassword: boolean;
}) {
  const [resetAsk, setResetAsk] = useState(false);
  const [changingPassword, setChangingPassword] = useState(false);
  // Con sesión, se ocultan las secciones a las que el rol no tiene acceso.
  const visibleNav = nav.filter((n) => {
    if (!session) return true;
    if (n.view === 'panel') return can(session, selectedId, 'orders.view');
    if (n.view === 'cocina') return can(session, selectedId, 'orders.prep');
    if (n.view === 'admin') return can(session, selectedId, 'restaurant.edit') || session.isPlatformAdmin;
    return true;
  });
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
          {visibleNav.map((n) => (
            <a key={n.view} href={n.href} className={route.view === n.view ? 'is-active' : ''} aria-current={route.view === n.view ? 'page' : undefined}>
              <Icon name={n.icon} size={18} /><span>{n.label}</span>
            </a>
          ))}
        </nav>
        <div className="appbar__tools">
          {route.view === 'cliente' && customerName ? (
            <span className="appbar__ctx">{customerName}</span>
          ) : restaurants.length > 0 && (
            <label className="rest-select">
              <span className="sr-only">Restaurante</span>
              <select id="rest-select" value={selectedId} onChange={(e) => onSelect(e.target.value)}>
                {restaurants.map((r) => <option key={r.id} value={r.id}>{r.name}</option>)}
              </select>
            </label>
          )}
          {session && (
            <span className="session">
              <span className="session__who" title={session.email}>
                {session.email}{selectedRole ? ` · ${roleLabel[selectedRole]}` : ''}
              </span>
              {canChangePassword && (
                <button className="btn btn--sm btn--ghost" onClick={() => setChangingPassword(true)}>Contraseña</button>
              )}
              <button className="btn btn--sm btn--ghost" onClick={async () => { await data.signOut(); onSignOut(); }}>Salir</button>
            </span>
          )}
          <Modal open={changingPassword} onClose={() => setChangingPassword(false)} title="Cambiar contraseña">
            <ChangePasswordForm onDone={() => setChangingPassword(false)} />
          </Modal>
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
      {isDemo && <p className="demo-strip">Demo: datos ficticios y pagos simulados, sin cargos reales</p>}
    </header>
  );
}
