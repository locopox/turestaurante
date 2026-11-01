import { useState } from 'react';
import { useToast } from '../../components/Toast';
import { Badge, Notice, Spinner } from '../../components/ui';
import { useAudit, useInvitations, useNow } from '../../hooks/useData';
import {
  deliveryResultLabel, INVITE_HINT, invitableRoles, invitationDetail, invitationStateLabel, invitationStateTone, resendStatus,
  visibleInvitations,
} from '../../lib/invitations';
import { roleLabel } from '../../lib/permissions';
import { data } from '../../services';
import type { Invitation, Restaurant, StaffRole, StaffSession } from '../../types';

/**
 * Invitaciones del equipo. Owner y manager ven TODAS las de su restaurante; cada uno solo gestiona
 * las que el servidor marca como suyas (canManage). Nada de esto concede permisos: la persona entra
 * en el equipo cuando acepta y el servidor lo confirma. Los límites (20 por hora, 30 pendientes,
 * 3 reenvíos con 5 minutos de espera) los aplica SQL; aquí solo se explican.
 */
export function TeamInvitations({ restaurant, session, onChanged }: { restaurant: Restaurant; session: StaffSession | null; onChanged?: () => void }) {
  const toast = useToast();
  const now = useNow(30000);
  const live = data.kind !== 'mock';
  const { value: invitations = [], loading, error, reload } = useInvitations(restaurant.id, live);
  const roles = invitableRoles(session, restaurant.id);
  const [email, setEmail] = useState('');
  const [role, setRole] = useState<StaffRole>(roles.includes('waiter') ? 'waiter' : roles[0] ?? 'waiter');
  const [busy, setBusy] = useState<string | null>(null);
  const [revoking, setRevoking] = useState<string | null>(null);
  const [lastMessage, setLastMessage] = useState<string | null>(null);

  const run = async (key: string, fn: () => Promise<string | void>) => {
    setBusy(key);
    try {
      const message = await fn();
      if (message) setLastMessage(message);
      reload();
      onChanged?.();
    } catch (e) {
      toast((e as Error).message, 'danger');
    } finally {
      setBusy(null);
      setRevoking(null);
    }
  };

  const invite = (e: React.FormEvent) => {
    e.preventDefault();
    const clean = email.trim();
    if (!clean) return;
    void run('invitar', async () => {
      const r = await data.inviteStaff(restaurant.id, clean, role);
      setEmail('');
      toast('Invitación creada');
      return r.message;
    });
  };
  const reinvite = (inv: Invitation) => run(`nueva-${inv.id}`, async () => {
    const r = await data.inviteStaff(restaurant.id, inv.email, inv.role);
    toast('Invitación nueva creada');
    return r.message;
  });

  const list = visibleInvitations(invitations);
  return (
    <div className="stack-lg">
      {!live && <Notice>Las invitaciones necesitan Supabase: en el modo demo no hay cuentas ni se envían correos.</Notice>}
      {live && roles.length > 0 && (
        <form className="card stack" onSubmit={invite}>
          <h3 className="card__title">Invitar al equipo</h3>
          <p className="muted small">{INVITE_HINT}</p>
          <div className="form-grid">
            <label className="field"><span>Email</span>
              <input id="invite-email" type="email" autoComplete="off" value={email} onChange={(e) => setEmail(e.target.value)} />
            </label>
            <label className="field"><span>Función</span>
              <select id="invite-role" value={role} onChange={(e) => setRole(e.target.value as StaffRole)}>
                {roles.map((r) => <option key={r} value={r}>{roleLabel[r]}</option>)}
              </select>
            </label>
          </div>
          {!roles.includes('owner') && <p className="muted small">Los propietarios solo los invita la plataforma.</p>}
          <button className="btn btn--primary" type="submit" disabled={busy !== null || !email.trim()}>
            {busy === 'invitar' ? 'Invitando…' : 'Invitar'}
          </button>
          {lastMessage && <Notice tone="ok">{lastMessage}</Notice>}
        </form>
      )}
      {live && (
        <section className="card">
          <h3 className="card__title">Invitaciones</h3>
          {error && <Notice tone="danger">{error}</Notice>}
          {loading && !invitations.length ? <Spinner /> : (
            <ul className="team">
              {list.map((inv) => {
                const resend = resendStatus(inv, now);
                const canReinvite = inv.state === 'caducada' && roles.includes(inv.role);
                return (
                  <li key={inv.id} className="team__row" data-invitation={inv.id}>
                    <span className="team__who">
                      <strong>{inv.email}</strong>
                      <span className="muted small"> · {roleLabel[inv.role]}</span>
                      <span className="muted small invite__detail">{invitationDetail(inv)}</span>
                    </span>
                    <Badge tone={invitationStateTone[inv.state]}>{invitationStateLabel[inv.state]}</Badge>
                    {inv.state === 'pendiente' && inv.canManage && (revoking === inv.id ? (
                      <span className="row">
                        <button className="btn btn--danger btn--sm" disabled={busy !== null}
                          onClick={() => run(`revocar-${inv.id}`, async () => { await data.revokeInvitation(inv.id); toast('Invitación revocada'); })}>
                          Revocar
                        </button>
                        <button className="btn btn--ghost btn--sm" onClick={() => setRevoking(null)}>No</button>
                      </span>
                    ) : (
                      <span className="row">
                        <button className="btn btn--outline btn--sm" disabled={busy !== null || !resend.allowed}
                          title={resend.allowed ? 'Envía un enlace nuevo con 7 días más' : resend.reason}
                          onClick={() => run(`reenviar-${inv.id}`, async () => { const r = await data.resendInvitation(inv.id); toast('Invitación reenviada'); return r.message; })}>
                          {busy === `reenviar-${inv.id}` ? 'Reenviando…' : 'Reenviar'}
                        </button>
                        <button className="btn btn--ghost btn--sm" disabled={busy !== null} onClick={() => setRevoking(inv.id)}>Revocar…</button>
                      </span>
                    ))}
                    {inv.state === 'pendiente' && inv.canManage && !resend.allowed && <span className="muted small">{resend.reason}</span>}
                    {inv.state === 'pendiente' && !inv.canManage && <span className="muted small">Solo puede gestionarla quien tenga permiso para esa función.</span>}
                    {canReinvite && (
                      <button className="btn btn--outline btn--sm" disabled={busy !== null} onClick={() => reinvite(inv)}>
                        {busy === `nueva-${inv.id}` ? 'Invitando…' : 'Invitar de nuevo'}
                      </button>
                    )}
                  </li>
                );
              })}
              {!list.length && !loading && <li className="muted small">Todavía no hay invitaciones.</li>}
            </ul>
          )}
        </section>
      )}
      {live && session?.isPlatformAdmin && <PlatformDeliveries restaurant={restaurant} />}
    </div>
  );
}

/**
 * SOLO plataforma: resultado de cada intento de entrega del correo. Se guarda en el registro sin
 * restaurante (el propietario y el encargado no lo ven: revelaría si la persona ya tenía cuenta).
 */
function PlatformDeliveries({ restaurant }: { restaurant: Restaurant }) {
  const { value: entries = [], loading, error } = useAudit(null);
  const deliveries = entries.filter((e) => e.action === 'invitacion.entrega' && e.details.restaurante === restaurant.id);
  return (
    <section className="card">
      <h3 className="card__title">Entregas de correo (solo plataforma)</h3>
      <p className="muted small">Ni el propietario ni el encargado ven esta información.</p>
      {error && <Notice tone="danger">{error}</Notice>}
      {loading && !entries.length ? <Spinner /> : (
        <ul className="audit">
          {deliveries.map((e, i) => (
            <li key={i} className="audit__row">
              <span className="muted small mono">{new Date(e.createdAt).toLocaleString('es-ES')}</span>
              <strong>{deliveryResultLabel[String(e.details.resultado)] ?? String(e.details.resultado)}</strong>
              <span className="small">{String(e.details.correo ?? '')} · intento {String(e.details.intento ?? '—')}</span>
            </li>
          ))}
          {!deliveries.length && <li className="muted small">Sin entregas registradas para este restaurante.</li>}
        </ul>
      )}
    </section>
  );
}
