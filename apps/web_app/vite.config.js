import { defineConfig } from 'vite'
import { fileURLToPath, URL } from 'node:url'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'

// https://vitejs.dev/config/
export default defineConfig({
  plugins: [
    react(),
    tailwindcss(),
  ],
  resolve: {
    alias: {
      // Pin jspdf to its browser ESM build. When the build runs under Node
      // (e.g. Vercel) the package's `node` export condition pulls a CJS build
      // whose constructor reference breaks after bundling ("Gn is not a
      // constructor"). The browser ESM build constructs correctly.
      jspdf: fileURLToPath(new URL('./node_modules/jspdf/dist/jspdf.es.min.js', import.meta.url)),
    },
  },
  server: {
    host: '0.0.0.0', // Разрешить подключения со всех IP (телефона)
    port: 5173,      // Основной порт
  },
})
