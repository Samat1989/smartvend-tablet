import React, { Suspense, lazy } from 'react'
import ReactDOM from 'react-dom/client'
import './index.css'
import './i18n'

import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom'
import Admin from './Admin.jsx'

// Build-time switch: when VITE_ADMIN_ONLY=true the customer-facing
// market is hidden — every path collapses to /admin. Used by the
// dedicated admin deployment so operators don't accidentally expose
// the storefront on the admin URL. The customer App is lazy-loaded
// so the production admin bundle doesn't ship its code at all when
// the switch is on — Vite tree-shakes the dead `lazy(() => …)` away.
const adminOnly = import.meta.env.VITE_ADMIN_ONLY === 'true'
const App = adminOnly ? null : lazy(() => import('./App.jsx'))

ReactDOM.createRoot(document.getElementById('root')).render(
  <React.StrictMode>
    <BrowserRouter>
      <Suspense fallback={null}>
        <Routes>
          {adminOnly ? (
            <>
              <Route path="/admin" element={<Admin />} />
              <Route path="*" element={<Navigate to="/admin" replace />} />
            </>
          ) : (
            <>
              <Route path="/" element={<App />} />
              <Route path="/admin" element={<Admin />} />
            </>
          )}
        </Routes>
      </Suspense>
    </BrowserRouter>
  </React.StrictMode>,
)
