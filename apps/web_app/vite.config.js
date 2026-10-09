import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'

// https://vitejs.dev/config/
export default defineConfig({
  plugins: [
    react(),
    tailwindcss(),
  ],
  // The WebP encoder finds its .wasm next to itself (new URL(..., import.meta.url));
  // pre-bundling moves the JS and leaves the wasm behind, so keep it out.
  optimizeDeps: { exclude: ['@jsquash/webp'] },
  server: {
    host: '0.0.0.0', // Разрешить подключения со всех IP (телефона)
    port: 5173,      // Основной порт
  },
})
