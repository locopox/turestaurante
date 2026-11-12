import { copyFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { defineConfig, type Plugin } from 'vite';
import react from '@vitejs/plugin-react';
import { viteSingleFile } from 'vite-plugin-singlefile';

/**
 * Copia index.html como 404.html al compilar. Algunos alojamientos (por ejemplo GitHub Pages) muestran
 * 404.html en las direcciones que no existen, como /r/<slug>/mesa/<n> de los códigos QR: así se ejecuta
 * el script de index.html que lleva a la carta correcta. No toca index.html ni ningún otro archivo.
 */
function copy404(): Plugin {
  return {
    name: 'turestaurante-copia-404',
    apply: 'build',
    writeBundle(options) {
      const dir = options.dir;
      if (!dir || !existsSync(join(dir, 'index.html'))) return;
      copyFileSync(join(dir, 'index.html'), join(dir, '404.html'));
    },
  };
}

// `npm run build:single` genera un único index.html autocontenido (útil para demos).
export default defineConfig(({ mode }) => ({
  base: './',
  plugins: [react(), ...(mode === 'single' ? [viteSingleFile()] : [copy404()])],
  build: { outDir: mode === 'single' ? 'dist-single' : 'dist' },
}));
