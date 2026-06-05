import React, { Suspense, lazy } from 'react'
import ReactDOM from 'react-dom/client'
import './index.css'
import './i18n'

import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom'

// A single deployment serves both surfaces — no separate storefront project:
//   /admin        — operator admin panel (default landing)
//   /micromarket  — customer storefront, opened from a machine's QR (?id=<machid>)
// Both are lazy-loaded (separate chunks) so each route ships only its own code —
// the storefront no longer downloads the (large) admin bundle and vice versa.
const Admin = lazy(() => import('./Admin.jsx'))
const App = lazy(() => import('./App.jsx'))

ReactDOM.createRoot(document.getElementById('root')).render(
  <React.StrictMode>
    <BrowserRouter>
      <Suspense fallback={null}>
        <Routes>
          <Route path="/admin" element={<Admin />} />
          <Route path="/micromarket" element={<App />} />
          <Route path="*" element={<Navigate to="/admin" replace />} />
        </Routes>
      </Suspense>
    </BrowserRouter>
  </React.StrictMode>,
)
