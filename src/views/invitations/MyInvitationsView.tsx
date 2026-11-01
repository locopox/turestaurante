import { useState } from 'react';
import { useToast } from '../../components/Toast';
import { Badge, Notice, Spinner } from '../../components/ui';
import { useMyInvitations } from '../../hooks/useData';
import { INVITATION_DAYS } from '../../lib/invitations';
import { roleLabel } from '../../lib/permissions';
import { data } from '../../services';
import type { MyInvitation, StaffSession } from '../../types';

/**
 * Invitaciones de quien ha iniciado sesión (las de su correo confirmado). La función con la que se
 * entra es la de la invitación: aquí no se puede elegir otra. La interfaz no da nada por aceptado
 * hasta que el servidor lo confirma (invitation_accept); después se vuelve a leer la sesión.
 */
export function MyInvitationsView({ session, onAccepted }: {
  session: StaffSession | null;
  onAccepted: (restaurantId: string, invitation: MyInvitation) => void;
}) {
  const toast = useToast();
  const live = data.kind !== 'mock';
  const enabled = live && !!session && !session.isPlatformAdmin;
  const { value: invitations = [], loading, error, reload } = useMyInvitations(enabled);
  const [busy, setBusy] = useState<string | null>(null);
  const [declining, setDeclining] = useState<string | null>(null);

  const accept = async (inv: MyInvitation) => {
    setBusy(inv.id);
    try {
      const restaurantId = await data.acceptInvitation(inv.id);
      toast(`Ya formas parte de ${inv.restaurantName} como ${roleLabel[inv.role]}`);
      onAccepted(restaurantId, inv);
    } catch (e) {
      // Puede haber caducado, haberse revocado o el restaurante estar suspendido: se vuelve a leer.
      toast((e as Error).message, 'danger');
      reload();
    } finally {
      setBusy(null);
    }
  };
  const decline = async (inv: MyInvitation) => {
    setBusy(inv.id);
    try {
      await data.declineInvitation(inv.id);
      toast(`Has rechazado la invitación de ${inv.restaurantName}`);
    } catch (e) {
      toast((e as Error).message, 'danger');
    } finally {
      setBusy(null);
      setDeclining(null);
      reload();
    }
  };

  return (
    <div className="page">
      <header className="page-head">
        <div>
          <span className="eyebrow">Tu cuenta</span>
          <h1>Invitaciones</h1>
        </div>
      </header>
      <div className="stack-lg invitations">
        {!live && <Notice>Las invitaciones necesitan Supabase: en el modo demo no hay cuentas ni se envían correos.</Notice>}
        {live && session?.isPlatformAdmin && (
          <Notice>Las cuentas de la plataforma no pueden ser personal de un restaurante. Usa otra cuenta para trabajar en uno.</Notice>
        )}
        {enabled && (
          <>
            <p className="muted">
              Al aceptar entrarás en el equipo con la función indicada; no se puede cambiar desde aquí. Tus otros restaurantes no
              cambian: en cada uno tendrás sus propios permisos.
            </p>
            {error && <Notice tone="danger">{error}</Notice>}
            {loading && !invitations.length ? <Spinner /> : invitations.map((inv) => (
              <section key={inv.id} className="card stack" data-invitation={inv.id}>
                <h3 className="card__title">{inv.restaurantName}</h3>
                <p>Te invita: <strong>{inv.invitedByLabel}</strong></p>
                <p>Función: <Badge tone="brand">{roleLabel[inv.role]}</Badge></p>
                <p className="muted small">Caduca el {new Date(inv.expiresAt).toLocaleString('es-ES', { day: 'numeric', month: 'long', hour: '2-digit', minute: '2-digit' })}.</p>
                {declining === inv.id ? (
                  <div className="row row--wrap">
                    <button className="btn btn--danger" disabled={busy !== null} onClick={() => decline(inv)}>Sí, rechazar</button>
                    <button className="btn btn--ghost" onClick={() => setDeclining(null)}>Volver</button>
                  </div>
                ) : (
                  <div className="row row--wrap">
                    <button className="btn btn--primary" disabled={busy !== null} onClick={() => accept(inv)}>
                      {busy === inv.id ? 'Aceptando…' : 'Aceptar'}
                    </button>
                    <button className="btn btn--ghost" disabled={busy !== null} onClick={() => setDeclining(inv.id)}>Rechazar…</button>
                  </div>
                )}
              </section>
            ))}
            {!loading && !invitations.length && !error && (
              <Notice>
                No tienes invitaciones pendientes. Las invitaciones caducan a los {INVITATION_DAYS} días; si esperabas una, pide que te la
                reenvíen.
              </Notice>
            )}
          </>
        )}
      </div>
    </div>
  );
}
