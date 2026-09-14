import js from '@eslint/js';
import globals from 'globals';
import reactHooks from 'eslint-plugin-react-hooks';

// Deliberately narrow. This is not a style gate — Prettier-style rules on a
// 4000-line file nobody has linted before would bury the one thing worth
// catching automatically.
//
// It exists because `npm run build` does NOT catch an undefined variable:
// rolldown has no way to know whether a bare identifier is a runtime global,
// so a reference left behind by a deletion builds cleanly and then throws in
// the browser, blanking the component. That happened when the shared starter
// catalog was removed — a `counts` helper still read the `mine` array that
// went with it, and the catalog tab rendered nothing at all.
export default [
  { ignores: ['dist/**', 'node_modules/**'] },
  js.configs.recommended,
  {
    files: ['**/*.{js,jsx}'],
    languageOptions: {
      ecmaVersion: 'latest',
      sourceType: 'module',
      globals: { ...globals.browser },
      parserOptions: { ecmaFeatures: { jsx: true } },
    },
    plugins: { 'react-hooks': reactHooks },
    rules: {
      // The ones that catch real breakage.
      'no-undef': 'error',
      'react-hooks/rules-of-hooks': 'error',

      // App.jsx guards every localStorage call with `catch (_) {}` — it
      // throws outright in a private window. Those blanks are the point, so
      // this stays a warning rather than failing the run.
      'no-empty': 'warn',

      // Off on purpose: JSX "uses" a component without the parser seeing it,
      // so every imported component reads as unused here. Unused *variables*
      // are still worth knowing about, hence the args/caught exemptions.
      'no-unused-vars': ['warn', {
        varsIgnorePattern: '^[A-Z]',
        args: 'none',
        caughtErrors: 'none',
      }],
    },
  },
];
