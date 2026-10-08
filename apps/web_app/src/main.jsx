import React, { Suspense, lazy } from 'react'
import ReactDOM from 'react-dom/client'
import './index.css'
import './i18n'

import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom'

// A single deployment serves both surfaces — no separate storefront project:
//   /admin        — operator admin panel (default landing)
//   /micromarket  — customer storefront, opened from a machine's QR (?id=<machid>)
//   /help         — user manual (owner / operator / installer), ru-kk-ky, printable
// All three are lazy-loaded (separate chunks) so each route ships only its own code —
// the storefront no longer downloads the (large) admin bundle and vice versa.
const Admin = lazy(() => import('./Admin.jsx'))
const App = lazy(() => import('./App.jsx'))
const Help = lazy(() => import('./help/Help.jsx'))

// Shown while a route's chunk downloads — on a slow phone network the admin
// chunk takes a few seconds, and a blank white page read as "broken".
function RouteLoading() {
  return (
    <div style={{ minHeight: '100dvh', display: 'flex', alignItems: 'center', justifyContent: 'center' }} role="status" aria-label="Loading">
      <div style={{ width: 36, height: 36, borderRadius: '50%', border: '4px solid #dbeafe', borderTopColor: '#2563eb', animation: 'route-spin 0.8s linear infinite' }} />
      <style>{'@keyframes route-spin { to { transform: rotate(360deg) } }'}</style>
    </div>
  )
}

ReactDOM.createRoot(document.getElementById('root')).render(
  <React.StrictMode>
    <BrowserRouter>
      <Suspense fallback={<RouteLoading />}>
        <Routes>
          <Route path="/admin" element={<Admin />} />
          <Route path="/micromarket" element={<App />} />
          <Route path="/help" element={<Help />} />
          <Route path="*" element={<Navigate to="/admin" replace />} />
        </Routes>
      </Suspense>
    </BrowserRouter>
  </React.StrictMode>,
)
