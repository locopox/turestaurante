import { useState } from 'react';
import { configIssues } from '../config';
import { PASSWORD_MIN, validateNewPassword } from '../lib/authRedirect';
import { data } from '../services';
import { useToast } from './Toast';
import { Icon, Notice } from './ui';

/** Se muestra en lugar de la app cuando faltan variables de entorno o son peligrosas. */
export function ConfigScreen() {
  return (
    <main className="page access">
      <div className="access__card stack-lg">
        <div>
          <span className="eyebrow">Configuración</span>
          <h1>La app no está bien configurada</h1>
        </div>
        <ul className="stack">
          {configIssues.map((i) => (
            <li key={i.message}><Notice tone={i.blocking ? 'danger' : 'warn'}>{i.message}</Notice></li>
          ))}
        </ul>
        <p className="muted">
          Revisa el archivo <span className="mono">.env</span> (o las variables del alojamiento) y vuelve a arrancar la app.
          Para usar la demo sin base de datos, pon <span className="mono">VITE_DATA_BACKEND=mock</span>.
        </p>
      </div>
    </main>
  );
}

/** Inicio de sesión del personal (email y contraseña de Supabase Auth). */
export function LoginScreen({ onSignedIn }: { onSignedIn: () => void }) {
  const [mode, setMode] = useState<'login' | 'forgot'>('login');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [sent, setSent] = useState(false);
  const [busy, setBusy] = useState(false);

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    setBusy(true);
    setError(null);
    try {
      if (mode === 'login') {
        await data.signIn(email, password);
        onSignedIn();
      } else {
        await data.requestPasswordReset(email);
        setSent(true);
      }
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setBusy(false);
    }
  };
  const switchMode = (m: 'login' | 'forgot') => {
    setMode(m);
    setError(null);
    setSent(false);
  };

  return (
    <div className="page access">
      <form className="access__card stack-lg" onSubmit={submit} noValidate>
        <div>
          <span className="eyebrow">Personal del restaurante</span>
          <h1>{mode === 'login' ? 'Iniciar sesión' : 'Recuperar contraseña'}</h1>
          <p className="muted">
            {mode === 'login'
              ? 'El panel, la cocina y la administración son solo para el personal.'
              : 'Te enviaremos un enlace para elegir una contraseña nueva.'}
          </p>
        </div>
        {error && <Notice tone="danger">{error}</Notice>}
        {sent && (
          <Notice tone="ok">
            Si ese email corresponde a una cuenta, recibirás un enlace en unos minutos. Ábrelo en este mismo navegador.
          </Notice>
        )}
        <label className="field">
          <span>Email</span>
          <input id="login-email" type="email" autoComplete="username" value={email} onChange={(e) => setEmail(e.target.value)} required />
        </label>
        {mode === 'login' && (
          <label className="field">
            <span>Contraseña</span>
            <input id="login-password" type="password" autoComplete="current-password" value={password} onChange={(e) => setPassword(e.target.value)} required />
          </label>
        )}
        <button className="btn btn--primary btn--block btn--lg" type="submit" disabled={busy || !email || (mode === 'login' && !password)}>
          <Icon name="arrow" />{' '}
          {mode === 'login' ? (busy ? 'Entrando…' : 'Entrar') : busy ? 'Enviando…' : 'Enviar enlace'}
        </button>
        <button type="button" className="btn btn--ghost btn--block" onClick={() => switchMode(mode === 'login' ? 'forgot' : 'login')}>
          {mode === 'login' ? '¿Has olvidado tu contraseña?' : 'Volver a iniciar sesión'}
        </button>
        <p className="muted small">Las cuentas las crea el administrador de la plataforma. No hay registro público.</p>
      </form>
    </div>
  );
}

/** Campos «contraseña nueva» y «repetir», comunes a la recuperación y al cambio. */
function NewPasswordFields({ password, repeat, onPassword, onRepeat, idPrefix }: {
  password: string; repeat: string; onPassword: (v: string) => void; onRepeat: (v: string) => void; idPrefix: string;
}) {
  return (
    <>
      <label className="field">
        <span>Contraseña nueva</span>
        <input id={`${idPrefix}-new`} type="password" autoComplete="new-password" value={password} onChange={(e) => onPassword(e.target.value)} />
        <small className="muted">Al menos {PASSWORD_MIN} caracteres. Mejor una frase larga que no uses en otros sitios.</small>
      </label>
      <label className="field">
        <span>Repite la contraseña nueva</span>
        <input id={`${idPrefix}-repeat`} type="password" autoComplete="new-password" value={repeat} onChange={(e) => onRepeat(e.target.value)} />
      </label>
    </>
  );
}

/**
 * Tras abrir un enlace de recuperación. Bloquea el panel, la cocina y la administración hasta
 * fijar la contraseña: la sesión que abre el enlace solo sirve para esto.
 */
export function SetPasswordScreen({ email, onDone }: { email: string; onDone: () => void }) {
  const toast = useToast();
  const [password, setPassword] = useState('');
  const [repeat, setRepeat] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    const invalid = validateNewPassword(password, repeat);
    if (invalid) return setError(invalid);
    setBusy(true);
    setError(null);
    try {
      await data.setNewPassword(password);
      toast('Contraseña guardada');
      onDone();
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setBusy(false);
    }
  };
  const cancel = async () => {
    setBusy(true);
    try {
      await data.cancelPasswordRecovery();
      onDone();
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="page access">
      <form className="access__card stack-lg" onSubmit={submit} noValidate>
        <div>
          <span className="eyebrow">Recuperar contraseña</span>
          <h1>Elige una contraseña nueva</h1>
          <p className="muted">Para la cuenta <strong>{email}</strong>. Hasta que la guardes no podrás usar el panel ni la cocina.</p>
        </div>
        {error && <Notice tone="danger">{error}</Notice>}
        <NewPasswordFields idPrefix="recovery" password={password} repeat={repeat} onPassword={setPassword} onRepeat={setRepeat} />
        <button className="btn btn--primary btn--block btn--lg" type="submit" disabled={busy}>
          {busy ? 'Guardando…' : 'Guardar contraseña'}
        </button>
        <button type="button" className="btn btn--ghost btn--block" onClick={cancel} disabled={busy}>
          Ahora no (cerrar sesión)
        </button>
      </form>
    </div>
  );
}

/** Cambio de contraseña con la sesión iniciada. Pide la actual y no cierra esta sesión. */
export function ChangePasswordForm({ onDone }: { onDone: () => void }) {
  const [current, setCurrent] = useState('');
  const [password, setPassword] = useState('');
  const [repeat, setRepeat] = useState('');
  const [others, setOthers] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const toast = useToast();

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!current) return setError('Escribe tu contraseña actual.');
    const invalid = validateNewPassword(password, repeat);
    if (invalid) return setError(invalid);
    setBusy(true);
    setError(null);
    try {
      await data.changePassword(current, password, others);
      toast('Contraseña cambiada');
      onDone();
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setBusy(false);
    }
  };

  return (
    <form className="sheet__body stack" onSubmit={submit} noValidate>
      <h2 className="sheet__title">Cambiar contraseña</h2>
      {error && <Notice tone="danger">{error}</Notice>}
      <label className="field">
        <span>Contraseña actual</span>
        <input id="change-current" type="password" autoComplete="current-password" value={current} onChange={(e) => setCurrent(e.target.value)} />
      </label>
      <NewPasswordFields idPrefix="change" password={password} repeat={repeat} onPassword={setPassword} onRepeat={setRepeat} />
      <label className="mini-toggle">
        <input id="change-others" type="checkbox" checked={others} onChange={(e) => setOthers(e.target.checked)} />
        <span>Cerrar la sesión en otros dispositivos (esta sesión sigue abierta)</span>
      </label>
      <button className="btn btn--primary btn--block" type="submit" disabled={busy}>
        {busy ? 'Guardando…' : 'Cambiar contraseña'}
      </button>
    </form>
  );
}
