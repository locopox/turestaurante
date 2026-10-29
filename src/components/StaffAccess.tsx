import { useState } from 'react';
import { configIssues } from '../config';
import { data } from '../services';
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
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    setBusy(true);
    setError(null);
    try {
      await data.signIn(email, password);
      onSignedIn();
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="page access">
      <form className="access__card stack-lg" onSubmit={submit} noValidate>
        <div>
          <span className="eyebrow">Personal del restaurante</span>
          <h1>Iniciar sesión</h1>
          <p className="muted">El panel, la cocina y la administración son solo para el personal.</p>
        </div>
        {error && <Notice tone="danger">{error}</Notice>}
        <label className="field">
          <span>Email</span>
          <input id="login-email" type="email" autoComplete="username" value={email} onChange={(e) => setEmail(e.target.value)} required />
        </label>
        <label className="field">
          <span>Contraseña</span>
          <input id="login-password" type="password" autoComplete="current-password" value={password} onChange={(e) => setPassword(e.target.value)} required />
        </label>
        <button className="btn btn--primary btn--block btn--lg" type="submit" disabled={busy || !email || !password}>
          <Icon name="arrow" /> {busy ? 'Entrando…' : 'Entrar'}
        </button>
        <p className="muted small">Las cuentas las crea el administrador de la plataforma. No hay registro público.</p>
      </form>
    </div>
  );
}
