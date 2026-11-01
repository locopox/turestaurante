import type { AuthRedirect } from '../lib/authRedirect';
import type {
  AuditEntry, Category, Invitation, InvitationSent, KitchenTicket, MyInvitation, NewOrderInput, NewRestaurantInput, Order, PaymentStatus,
  PrepStatus, Product, Restaurant, StaffMember, StaffRole, StaffSession, SupportGrant, SupportOrderView,
  SupportDenial, SupportPaymentEventView, SupportRestaurantView,
} from '../types';

export interface Menu {
  categories: Category[];
  products: Product[];
}

export type Unsubscribe = () => void;

/**
 * Contrato único de acceso a datos. La UI solo habla con esta interfaz, de modo que
 * cambiar de datos ficticios (MockDataService) a Supabase (SupabaseDataService)
 * no requiere tocar las pantallas.
 */
export interface DataService {
  readonly kind: 'mock' | 'supabase';
  /** true si el panel, la cocina y la administración exigen iniciar sesión. */
  readonly requiresLogin: boolean;

  // Sesión del personal
  getSession(): Promise<StaffSession | null>;
  signIn(email: string, password: string): Promise<StaffSession>;
  signOut(): Promise<void>;
  onAuthChange(onChange: () => void): Unsubscribe;

  // Contraseña (Supabase Auth, siempre con la sesión del propio usuario y la clave pública)
  /** Enlace de Supabase Auth con el que se abrió la app (recuperación o enlace caducado). */
  getAuthRedirect(): AuthRedirect;
  dismissAuthRedirect(): void;
  /** true tras abrir un enlace de recuperación o de invitación válido, hasta fijar la contraseña. */
  isPasswordRecoveryPending(): boolean;
  /** Por qué hay que fijar la contraseña: recuperación, invitación (cuenta nueva) o nada. */
  getPasswordSetupKind(): 'recovery' | 'invite' | null;
  /** Fija la contraseña nueva del usuario que abrió el enlace de recuperación. */
  setNewPassword(newPassword: string): Promise<void>;
  /** Cambia la contraseña comprobando antes la actual. No cierra la sesión actual. */
  changePassword(currentPassword: string, newPassword: string, signOutOtherDevices: boolean): Promise<void>;
  /** Envía el correo de recuperación. No revela si el email tiene cuenta. */
  requestPasswordReset(email: string): Promise<void>;
  /** El usuario decide no fijar la contraseña ahora: cierra su sesión (solo si lo pide). */
  cancelPasswordRecovery(): Promise<void>;

  // Restaurantes (multi-tenant)
  listRestaurants(): Promise<Restaurant[]>;
  getRestaurantBySlug(slug: string): Promise<Restaurant | null>;
  /** Solo demo (sin cuentas). Con Supabase se usa createRestaurantWithOwner. */
  createRestaurant(input: NewRestaurantInput): Promise<Restaurant>;
  /** Plataforma: crea el restaurante (cerrado) y la invitación de su primer propietario. */
  createRestaurantWithOwner(input: { name: string; slug: string; ownerEmail: string }): Promise<InvitationSent>;
  saveRestaurant(restaurant: Restaurant): Promise<Restaurant>;

  // Carta
  getMenu(restaurantId: string): Promise<Menu>;
  createCategory(restaurantId: string, name: string): Promise<Category>;
  createProduct(input: Omit<Product, 'id' | 'sort'>): Promise<Product>;
  saveProduct(product: Product): Promise<Product>;

  // Cliente (sin cuenta): solo accede a SU pedido mediante el token secreto
  /** Valida, calcula precios y numera en el servidor. Reenviar el mismo token devuelve el mismo pedido. */
  createOrder(input: NewOrderInput): Promise<Order>;
  getCustomerOrder(orderId: string, accessToken: string): Promise<Order | null>;
  subscribeCustomerOrder(orderId: string, accessToken: string, onChange: () => void): Unsubscribe;
  /** El cliente abandona el pago online pendiente y pagará en caja. */
  switchToCounterPayment(orderId: string, accessToken: string): Promise<Order>;

  // Personal (con sesión y según su rol)
  listOrders(restaurantId: string): Promise<Order[]>;
  updatePrepStatus(orderId: string, status: PrepStatus): Promise<void>;
  markPaidAtCounter(orderId: string): Promise<void>;
  subscribeOrders(restaurantId: string, onChange: () => void): Unsubscribe;
  subscribeCatalog(onChange: () => void): Unsubscribe;
  /** Comandas de cocina: sin teléfono, importes ni pago (kitchen_orders). */
  listKitchenOrders(restaurantId: string): Promise<KitchenTicket[]>;
  subscribeKitchen(restaurantId: string, onChange: () => void): Unsubscribe;

  // Equipo (staff_* en la base de datos, con las reglas de cada rol). Las altas son SOLO por
  // invitación aceptada: no existe ninguna forma de añadir a alguien directamente.
  listStaff(restaurantId: string): Promise<StaffMember[]>;
  changeStaffRole(restaurantId: string, userId: string, role: StaffRole): Promise<void>;
  removeStaff(restaurantId: string, userId: string): Promise<void>;

  // Invitaciones (fase 6). Crear y reenviar pasan por la Edge Function «invitations» (que envía el
  // correo en el servidor); el resto son funciones SQL con la sesión del usuario.
  /** La respuesta es la misma tenga o no cuenta el correo. */
  inviteStaff(restaurantId: string, email: string, role: StaffRole): Promise<InvitationSent>;
  resendInvitation(invitationId: string): Promise<InvitationSent>;
  revokeInvitation(invitationId: string): Promise<void>;
  listInvitations(restaurantId: string): Promise<Invitation[]>;
  /** Invitaciones que puede aceptar quien ha iniciado sesión (las de su correo confirmado). */
  myInvitations(): Promise<MyInvitation[]>;
  /** Devuelve el restaurante al que se ha unido. La función la decide la invitación, no la app. */
  acceptInvitation(invitationId: string): Promise<string>;
  declineInvitation(invitationId: string): Promise<void>;

  // Plataforma y auditoría
  setRestaurantSuspension(restaurantId: string, suspended: boolean, reason: string): Promise<void>;
  /** restaurantId null: registro completo (solo plataforma). */
  listAudit(restaurantId: string | null): Promise<AuditEntry[]>;

  // Modo soporte: la plataforma pide acceso de solo lectura; el propietario lo aprueba (2 horas)
  requestSupport(restaurantId: string, reason: string): Promise<void>;
  /** Solicitudes de un restaurante (propietario). */
  listSupportRequests(restaurantId: string): Promise<SupportGrant[]>;
  /** Solicitudes propias (plataforma). */
  mySupportRequests(): Promise<SupportGrant[]>;
  decideSupport(grantId: string, approve: boolean): Promise<void>;
  revokeSupport(grantId: string): Promise<void>;
  cancelSupport(grantId: string): Promise<void>;
  /** Consultas de solo lectura; cada una la comprueba y la registra la base de datos. */
  supportViewRestaurant(restaurantId: string): Promise<SupportRestaurantView>;
  supportViewOrders(restaurantId: string): Promise<SupportOrderView[]>;
  supportViewPaymentEvents(restaurantId: string): Promise<SupportPaymentEventView[]>;
  /** Intentos de consulta denegados: de un restaurante (su owner) o de toda la plataforma (null). */
  listSupportDenials(restaurantId: string | null): Promise<SupportDenial[]>;

  /**
   * Resultado de la pasarela SIMULADA del modo demo. Con Supabase lanza error: el estado del
   * pago solo lo cambia el servidor tras la confirmación firmada del proveedor.
   */
  recordPaymentResult(orderId: string, status: PaymentStatus, ref: string | null): Promise<Order>;

  /** Solo demo: restaura los datos de ejemplo. */
  resetDemo?(): Promise<void>;
}
