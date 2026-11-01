import type { Category, Order, Product, Restaurant } from '../types';

/** Datos de demostración. Todo es ficticio. */
export interface SeedDB {
  restaurants: Restaurant[];
  categories: Category[];
  products: Product[];
  orders: Order[];
  counters: Record<string, number>;
}

const created = '2026-01-15T10:00:00.000Z';

const restaurants: Restaurant[] = [
  {
    id: 'r-piazza', slug: 'la-piazza', name: 'La Piazza', tagline: 'Pizzería y trattoria · horno de leña',
    address: 'Calle Mayor 12, Madrid', phone: '910 000 000', active: true, tables: 12,
    pickupEnabled: true, onlinePaymentEnabled: true, counterPaymentEnabled: true, prepMinutes: 18, createdAt: created, suspended: false,
  },
  {
    id: 'r-sakura', slug: 'sakura-ramen', name: 'Sakura Ramen', tagline: 'Ramen y gyozas caseras',
    address: 'Av. del Puerto 3, Valencia', phone: '960 000 000', active: true, tables: 8,
    pickupEnabled: true, onlinePaymentEnabled: true, counterPaymentEnabled: true, prepMinutes: 12, createdAt: created, suspended: false,
  },
  {
    id: 'r-fogon', slug: 'el-fogon', name: 'El Fogón', tagline: 'Tacos al pastor y antojitos',
    address: 'Plaza Nueva 7, Sevilla', phone: '950 000 000', active: false, tables: 6,
    pickupEnabled: true, onlinePaymentEnabled: false, counterPaymentEnabled: true, prepMinutes: 10, createdAt: created, suspended: false,
  },
];

const cat = (restaurantId: string, id: string, name: string, sort: number): Category => ({ id, restaurantId, name, sort });

const categories: Category[] = [
  cat('r-piazza', 'c-ent', 'Entrantes', 1),
  cat('r-piazza', 'c-piz', 'Pizzas', 2),
  cat('r-piazza', 'c-pas', 'Pastas', 3),
  cat('r-piazza', 'c-pos', 'Postres', 4),
  cat('r-piazza', 'c-beb', 'Bebidas', 5),
  cat('r-sakura', 'c-sk-ram', 'Ramen', 1),
  cat('r-sakura', 'c-sk-ent', 'Para compartir', 2),
  cat('r-sakura', 'c-sk-beb', 'Bebidas', 3),
  cat('r-fogon', 'c-fg-tac', 'Tacos', 1),
  cat('r-fogon', 'c-fg-beb', 'Bebidas', 2),
];

let sort = 0;
const p = (
  restaurantId: string, categoryId: string, id: string, name: string, description: string,
  price: number, art: Product['art'], extra: Partial<Product> = {},
): Product => ({
  id, restaurantId, categoryId, name, description, price, art, imageUrl: null,
  allergens: [], tags: [], available: true, sort: ++sort, ...extra,
});

const products: Product[] = [
  p('r-piazza', 'c-ent', 'p-bru', 'Bruschetta clásica', 'Pan de masa madre tostado, tomate, ajo, albahaca y aceite de oliva virgen extra.', 650, 'bread', { allergens: ['gluten'], tags: ['vegano'] }),
  p('r-piazza', 'c-ent', 'p-cap', 'Ensalada Caprese', 'Tomate de temporada, mozzarella di bufala, albahaca fresca y pesto.', 950, 'salad', { allergens: ['lácteos', 'frutos secos'], tags: ['vegetariano', 'sin_gluten'] }),
  p('r-piazza', 'c-ent', 'p-bur', 'Burrata con rúcula', 'Burrata cremosa, rúcula, tomate cherry asado y reducción de balsámico.', 1250, 'salad', { allergens: ['lácteos'], tags: ['vegetariano', 'nuevo'] }),
  p('r-piazza', 'c-piz', 'p-mar', 'Margherita', 'Tomate San Marzano, mozzarella fior di latte y albahaca.', 1050, 'pizza', { allergens: ['gluten', 'lácteos'], tags: ['vegetariano'] }),
  p('r-piazza', 'c-piz', 'p-dia', 'Diavola', 'Tomate, mozzarella, salami picante y aceite de guindilla.', 1250, 'pizza', { allergens: ['gluten', 'lácteos'], tags: ['picante'] }),
  p('r-piazza', 'c-piz', 'p-4q', 'Quattro formaggi', 'Mozzarella, gorgonzola, parmesano y taleggio.', 1350, 'pizza', { allergens: ['gluten', 'lácteos'], tags: ['vegetariano'] }),
  p('r-piazza', 'c-piz', 'p-pro', 'Prosciutto e funghi', 'Tomate, mozzarella, jamón cocido y champiñones.', 1300, 'pizza', { allergens: ['gluten', 'lácteos'] }),
  p('r-piazza', 'c-piz', 'p-ver', 'Vegetale', 'Calabacín, berenjena, pimiento asado, cebolla roja y mozzarella.', 1200, 'pizza', { allergens: ['gluten', 'lácteos'], tags: ['vegetariano'], available: false }),
  p('r-piazza', 'c-pas', 'p-car', 'Spaghetti carbonara', 'Guanciale, yema de huevo, pecorino romano y pimienta negra.', 1250, 'pasta', { allergens: ['gluten', 'huevo', 'lácteos'] }),
  p('r-piazza', 'c-pas', 'p-pes', 'Trofie al pesto', 'Pesto genovés de albahaca, piñones y parmesano.', 1150, 'pasta', { allergens: ['gluten', 'lácteos', 'frutos secos'], tags: ['vegetariano'] }),
  p('r-piazza', 'c-pas', 'p-arr', 'Penne all’arrabbiata', 'Salsa de tomate con ajo y guindilla.', 1050, 'pasta', { allergens: ['gluten'], tags: ['vegano', 'picante'] }),
  p('r-piazza', 'c-pos', 'p-tir', 'Tiramisú de la casa', 'Bizcocho de soletilla, café, mascarpone y cacao.', 600, 'dessert', { allergens: ['gluten', 'huevo', 'lácteos'] }),
  p('r-piazza', 'c-pos', 'p-pan', 'Panna cotta', 'Con coulis de frutos rojos.', 550, 'dessert', { allergens: ['lácteos'], tags: ['sin_gluten'] }),
  p('r-piazza', 'c-pos', 'p-caf', 'Espresso', 'Café italiano de tueste natural.', 180, 'coffee'),
  p('r-piazza', 'c-beb', 'p-agu', 'Agua mineral 50 cl', 'Natural o con gas.', 220, 'water', { tags: ['vegano'] }),
  p('r-piazza', 'c-beb', 'p-lim', 'Limonada casera', 'Limón, hierbabuena y un toque de jengibre.', 350, 'soda', { tags: ['vegano'] }),
  p('r-piazza', 'c-beb', 'p-chi', 'Copa de Chianti', 'Vino tinto D.O.C.G., Toscana.', 450, 'wine', { allergens: ['sulfitos'] }),

  p('r-sakura', 'c-sk-ram', 'p-sk-sho', 'Shoyu ramen', 'Caldo de pollo y soja, chashu, huevo marinado y cebolleta.', 1300, 'ramen', { allergens: ['gluten', 'soja', 'huevo'] }),
  p('r-sakura', 'c-sk-ram', 'p-sk-mis', 'Miso picante', 'Caldo de miso, carne picada especiada, maíz y brotes.', 1350, 'ramen', { allergens: ['gluten', 'soja', 'sésamo'], tags: ['picante'] }),
  p('r-sakura', 'c-sk-ram', 'p-sk-veg', 'Ramen de verduras', 'Caldo de setas shiitake, tofu y pak choi.', 1200, 'ramen', { allergens: ['gluten', 'soja'], tags: ['vegano'] }),
  p('r-sakura', 'c-sk-ent', 'p-sk-gyo', 'Gyozas de cerdo (6)', 'A la plancha, con salsa ponzu.', 750, 'gyoza', { allergens: ['gluten', 'soja'] }),
  p('r-sakura', 'c-sk-beb', 'p-sk-te', 'Té verde frío', 'Sencha sin azúcar.', 300, 'soda', { tags: ['vegano'] }),

  p('r-fogon', 'c-fg-tac', 'p-fg-pas', 'Tacos al pastor (3)', 'Cerdo adobado, piña, cebolla y cilantro.', 950, 'taco', { tags: ['picante'] }),
  p('r-fogon', 'c-fg-tac', 'p-fg-coc', 'Tacos de cochinita (3)', 'Cochinita pibil con cebolla morada encurtida.', 990, 'taco'),
  p('r-fogon', 'c-fg-tac', 'p-fg-nop', 'Tacos de nopal (3)', 'Nopal asado, queso fresco y salsa verde.', 890, 'taco', { allergens: ['lácteos'], tags: ['vegetariano'] }),
  p('r-fogon', 'c-fg-beb', 'p-fg-hor', 'Horchata', 'Casera, de arroz y canela.', 350, 'soda'),
];

function demoOrders(now: number): Order[] {
  const ago = (min: number) => new Date(now - min * 60000).toISOString();
  const item = (id: string, quantity: number, notes?: string) => {
    const prod = products.find((x) => x.id === id)!;
    return { productId: id, name: prod.name, unitPrice: prod.price, quantity, ...(notes ? { notes } : {}) };
  };
  const mk = (o: Omit<Order, 'total' | 'updatedAt' | 'restaurantId' | 'paymentRef'> & { paymentRef?: string }): Order => ({
    restaurantId: 'r-piazza', paymentRef: null, ...o, updatedAt: o.createdAt,
    total: o.items.reduce((s, i) => s + i.unitPrice * i.quantity, 0),
  });
  return [
    mk({ id: 'o-demo-1', number: 101, createdAt: ago(34), mode: 'mesa', table: 3, customerName: null, customerPhone: null, pickupTime: null,
      items: [item('p-mar', 2), item('p-agu', 2)], notes: '', paymentMethod: 'caja', paymentStatus: 'cobrado_caja', prepStatus: 'entregado' }),
    mk({ id: 'o-demo-2', number: 102, createdAt: ago(21), mode: 'recoger', table: null, customerName: 'Lucía', customerPhone: '600 000 001', pickupTime: 'asap',
      items: [item('p-dia', 1), item('p-car', 1), item('p-tir', 2)], notes: '', paymentMethod: 'online', paymentStatus: 'simulado', paymentRef: 'sim_demo_102', prepStatus: 'listo' }),
    mk({ id: 'o-demo-3', number: 103, createdAt: ago(12), mode: 'mesa', table: 7, customerName: null, customerPhone: null, pickupTime: null,
      items: [item('p-cap', 1), item('p-4q', 1, 'Bien hecha'), item('p-chi', 2)], notes: 'Traer los entrantes primero', paymentMethod: 'caja', paymentStatus: 'pendiente_caja', prepStatus: 'en_preparacion' }),
    mk({ id: 'o-demo-4', number: 104, createdAt: ago(4), mode: 'mesa', table: 2, customerName: null, customerPhone: null, pickupTime: null,
      items: [item('p-bru', 1), item('p-pes', 1, 'Sin piñones'), item('p-lim', 1)], notes: '', paymentMethod: 'online', paymentStatus: 'simulado', paymentRef: 'sim_demo_104', prepStatus: 'nuevo' }),
    mk({ id: 'o-demo-5', number: 105, createdAt: ago(2), mode: 'recoger', table: null, customerName: 'Marcos', customerPhone: null, pickupTime: null,
      items: [item('p-pro', 2), item('p-pan', 1)], notes: '', paymentMethod: 'caja', paymentStatus: 'pendiente_caja', prepStatus: 'nuevo' }),
  ];
}

export function createSeed(now = Date.now()): SeedDB {
  return {
    restaurants: structuredClone(restaurants),
    categories: structuredClone(categories),
    products: structuredClone(products),
    orders: demoOrders(now),
    counters: { 'r-piazza': 105, 'r-sakura': 200, 'r-fogon': 300 },
  };
}
