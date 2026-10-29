import type { ReactNode } from 'react';
import type { FoodArt as Art } from '../types';

/**
 * Ilustraciones vectoriales de reserva para la carta.
 * Cuando un producto tenga `imageUrl`, se muestra la foto en su lugar.
 */
const bg: Record<Art, string> = {
  pizza: '#F7E6CC', pasta: '#F6EBC8', salad: '#DDEFD9', bread: '#F3E3CF', dessert: '#EFE2D8', soda: '#E2F0E6',
  coffee: '#ECE2D9', wine: '#F1DDE0', water: '#DDEBF2', ramen: '#F4E4D2', taco: '#F6E7C3', gyoza: '#F2E9D7',
};

const art: Record<Art, ReactNode> = {
  pizza: (
    <g>
      <circle cx="60" cy="47" r="32" fill="#D99A4E" />
      <circle cx="60" cy="47" r="26" fill="#C8432F" />
      <circle cx="60" cy="47" r="24" fill="#F2CF7E" opacity=".9" />
      {[[48, 38], [70, 36], [56, 58], [74, 54], [44, 52]].map(([x, y], i) => <circle key={i} cx={x} cy={y} r="5" fill="#A8321F" />)}
      <path d="M60 40c4-4 9-3 10 0-4 3-8 3-10 0zM50 60c3-4 8-4 9-1-3 3-7 3-9 1z" fill="#2F7A3E" />
    </g>
  ),
  pasta: (
    <g>
      <ellipse cx="60" cy="52" rx="36" ry="18" fill="#FFFFFF" stroke="#D9D2C3" strokeWidth="2" />
      <path d="M36 50c6-10 16 6 24-4s16 8 24-2M38 56c8-6 14 6 22-2s14 6 22-2M44 44c6-6 12 4 18-2s10 4 16 0" stroke="#E6B84A" strokeWidth="3.2" fill="none" strokeLinecap="round" />
      <circle cx="62" cy="47" r="7" fill="#C8432F" />
      <path d="M66 40c4-3 8-2 9 1-4 2-7 2-9-1z" fill="#2F7A3E" />
    </g>
  ),
  salad: (
    <g>
      <path d="M26 46h68a34 22 0 0 1-68 0z" fill="#FFFFFF" stroke="#CFD8CC" strokeWidth="2" />
      {[[40, 44, '#4E9A4A'], [52, 40, '#6DB35A'], [66, 41, '#3F8A3C'], [78, 45, '#6DB35A'], [58, 47, '#8CC66E']].map(([x, y, c], i) => (
        <ellipse key={i} cx={x as number} cy={y as number} rx="10" ry="6" fill={c as string} transform={`rotate(${i * 25 - 30} ${x} ${y})`} />
      ))}
      <circle cx="48" cy="46" r="5" fill="#D9473A" />
      <circle cx="72" cy="47" r="5" fill="#D9473A" />
      <circle cx="61" cy="42" r="5" fill="#FBF6EA" />
    </g>
  ),
  bread: (
    <g>
      {[[30, 34], [54, 44], [78, 34]].map(([x, y], i) => (
        <g key={i} transform={`rotate(${i * 8 - 8} ${x + 10} ${y + 10})`}>
          <rect x={x - 6} y={y} width="30" height="20" rx="7" fill="#C98B48" />
          <rect x={x - 3} y={y + 3} width="24" height="14" rx="5" fill="#E9B979" />
          <circle cx={x + 3} cy={y + 9} r="3.2" fill="#C8432F" />
          <circle cx={x + 12} cy={y + 8} r="3.2" fill="#C8432F" />
          <circle cx={x + 8} cy={y + 13} r="2" fill="#2F7A3E" />
        </g>
      ))}
    </g>
  ),
  dessert: (
    <g>
      <path d="M34 62l26-34 26 34z" fill="#F4E7D3" />
      <path d="M38 57h44l-4-5H42zM44 49h32l-4-5H48z" fill="#7A4A2B" />
      <path d="M52 37h16l-8-9z" fill="#5A3420" />
      <rect x="30" y="62" width="60" height="5" rx="2.5" fill="#D8CDBF" />
    </g>
  ),
  soda: (
    <g>
      <path d="M44 22h32l-4 48H48z" fill="#FFFFFF" stroke="#BFD4C6" strokeWidth="2" />
      <path d="M46 36h28l-3 32H49z" fill="#F1D65E" />
      <path d="M66 14l-6 40" stroke="#3E8E4F" strokeWidth="3" strokeLinecap="round" />
      <circle cx="74" cy="34" r="8" fill="#F5E27E" stroke="#D8B83A" strokeWidth="2" />
      <circle cx="54" cy="52" r="2" fill="#FFFFFF" /><circle cx="60" cy="60" r="1.6" fill="#FFFFFF" />
    </g>
  ),
  coffee: (
    <g>
      <ellipse cx="60" cy="66" rx="30" ry="7" fill="#FFFFFF" stroke="#D3C6B8" strokeWidth="2" />
      <path d="M40 38h36v14a18 18 0 0 1-36 0z" fill="#FFFFFF" stroke="#D3C6B8" strokeWidth="2" />
      <ellipse cx="58" cy="38" rx="18" ry="4" fill="#6B3F24" />
      <path d="M76 42a7 7 0 0 1 0 12" stroke="#D3C6B8" strokeWidth="3" fill="none" />
      <path d="M52 26c-3 4 3 5 0 9M62 24c-3 4 3 5 0 9" stroke="#B9A796" strokeWidth="2" fill="none" strokeLinecap="round" />
    </g>
  ),
  wine: (
    <g>
      <path d="M46 18h28c0 18-6 28-14 28s-14-10-14-28z" fill="#FFFFFF" stroke="#D9C2C6" strokeWidth="2" />
      <path d="M47 28h26c-1 10-6 16-13 16s-12-6-13-16z" fill="#8E2236" />
      <path d="M60 46v18M48 68h24" stroke="#D9C2C6" strokeWidth="3" strokeLinecap="round" />
    </g>
  ),
  water: (
    <g>
      <path d="M54 14h12v8c8 4 10 10 10 16v32a4 4 0 0 1-4 4H48a4 4 0 0 1-4-4V38c0-6 2-12 10-16z" fill="#FFFFFF" stroke="#A9C7D8" strokeWidth="2" />
      <rect x="44" y="42" width="32" height="16" fill="#3D7FA6" />
      <path d="M50 50h20" stroke="#FFFFFF" strokeWidth="2" />
    </g>
  ),
  ramen: (
    <g>
      <path d="M24 42h72a36 26 0 0 1-72 0z" fill="#1F3D2E" />
      <ellipse cx="60" cy="42" rx="36" ry="8" fill="#E8B46A" />
      <path d="M36 42c6-4 10 3 16 0s10 3 16 0 10 3 16 0" stroke="#F5DE9A" strokeWidth="3" fill="none" />
      <ellipse cx="48" cy="40" rx="7" ry="5" fill="#FFFFFF" /><circle cx="48" cy="40" r="3" fill="#F2A93B" />
      <rect x="62" y="35" width="14" height="8" rx="3" fill="#B8664A" />
      <path d="M78 12l-14 30M86 14l-16 28" stroke="#9C6B3E" strokeWidth="3" strokeLinecap="round" />
    </g>
  ),
  taco: (
    <g>
      <path d="M28 62a32 32 0 0 1 64 0z" fill="#E7B54F" />
      <path d="M36 58c4-14 12-20 24-20s20 6 24 20" fill="#B8532F" />
      <circle cx="46" cy="50" r="4" fill="#4E9A4A" /><circle cx="60" cy="44" r="4" fill="#F2D06B" />
      <circle cx="74" cy="50" r="4" fill="#4E9A4A" /><circle cx="54" cy="54" r="3" fill="#FFFFFF" /><circle cx="68" cy="54" r="3" fill="#C8432F" />
      <path d="M28 62a32 32 0 0 1 64 0" stroke="#C9922F" strokeWidth="3" fill="none" />
    </g>
  ),
  gyoza: (
    <g>
      {[[34, 50], [60, 44], [86, 50]].map(([x, y], i) => (
        <g key={i}>
          <path d={`M${x - 16} ${y + 6}a16 13 0 0 1 32 0z`} fill="#F6EAD0" stroke="#D8C49A" strokeWidth="2" />
          <path d={`M${x - 10} ${y - 2}l3 4M${x - 3} ${y - 6}l2 4M${x + 4} ${y - 6}l-1 4M${x + 10} ${y - 2}l-3 4`} stroke="#D8C49A" strokeWidth="2" strokeLinecap="round" />
          <path d={`M${x - 15} ${y + 6}h30`} stroke="#C58A3E" strokeWidth="3" strokeLinecap="round" />
        </g>
      ))}
    </g>
  ),
};

export function FoodArt({ art: kind, imageUrl, label, className = '' }: { art: Art; imageUrl?: string | null; label: string; className?: string }) {
  if (imageUrl) return <img className={`food-art ${className}`} src={imageUrl} alt={label} loading="lazy" />;
  return (
    <svg className={`food-art ${className}`} viewBox="0 0 120 84" role="img" aria-label={label} style={{ background: bg[kind] }}>
      {art[kind]}
    </svg>
  );
}

export const ART_OPTIONS: { value: Art; label: string }[] = [
  { value: 'pizza', label: 'Pizza' }, { value: 'pasta', label: 'Pasta' }, { value: 'salad', label: 'Ensalada' },
  { value: 'bread', label: 'Pan / tostas' }, { value: 'dessert', label: 'Postre' }, { value: 'coffee', label: 'Café' },
  { value: 'soda', label: 'Refresco' }, { value: 'water', label: 'Agua' }, { value: 'wine', label: 'Vino' },
  { value: 'ramen', label: 'Ramen / bol' }, { value: 'gyoza', label: 'Gyozas' }, { value: 'taco', label: 'Tacos' },
];
