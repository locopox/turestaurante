import { Icon } from '../components/ui';
import { hrefFor } from '../hooks/useRoute';
import type { Restaurant } from '../types';

export function Home({ restaurant }: { restaurant: Restaurant | undefined }) {
  const slug = restaurant?.slug ?? 'la-piazza';
  const cards = [
    { href: hrefFor({ view: 'cliente', slug, table: 5 }), icon: 'phone', title: 'Cliente · mesa 5', text: 'Lo que ve un cliente al escanear el QR de su mesa: carta, carrito, pago y seguimiento.' },
    { href: hrefFor({ view: 'cliente', slug }), icon: 'bag', title: 'Cliente · para recoger', text: 'El mismo flujo, pidiendo desde fuera del local para recoger a una hora.' },
    { href: '#panel', icon: 'list', title: 'Panel del restaurante', text: 'Todos los pedidos con número, productos, importe, estado de pago y de preparación.' },
    { href: '#cocina', icon: 'chef', title: 'Pantalla de cocina', text: 'Comandas grandes por columnas, con tiempos y avisos de retraso.' },
    { href: '#admin', icon: 'settings', title: 'Administración', text: 'Alta y configuración de restaurantes, carta, precios, disponibilidad y QR de mesas.' },
  ];
  return (
    <div className="page home">
      <section className="home__intro">
        <span className="eyebrow">Demo · fase 1</span>
        <h1>Pedidos en mesa y para recoger, desde el móvil.</h1>
        <p className="lead">
          TuRestaurante conecta a clientes, sala y cocina. Esta demo usa a <strong>{restaurant?.name ?? 'La Piazza'}</strong> con datos ficticios.
          Para ver el recorrido completo, abre el cliente en una pestaña y el panel o la cocina en otra: los pedidos aparecen al momento.
        </p>
      </section>
      <ul className="home__grid">
        {cards.map((c) => (
          <li key={c.href}>
            <a className="home-card" href={c.href}>
              <span className="home-card__icon"><Icon name={c.icon} size={22} /></span>
              <strong>{c.title}</strong>
              <span className="muted">{c.text}</span>
              <span className="home-card__go">Abrir <Icon name="arrow" size={16} /></span>
            </a>
          </li>
        ))}
      </ul>
      <section className="home__note">
        <h2>Sobre los pagos en esta demo</h2>
        <p>
          El pago online usa una pasarela simulada: no se piden datos de tarjeta, no se cobra nada y ningún pedido aparece como
          «pagado verificado». Ese estado lo reservará el servidor cuando se conecte un proveedor de pagos real.
        </p>
      </section>
    </div>
  );
}
