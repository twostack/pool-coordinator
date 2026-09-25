import js from '@eslint/js';
import tseslint from 'typescript-eslint';

// API data is text, never markup: Lit escapes what it interpolates, so the
// only ways to put a served string into the page as HTML are the unsafe
// directives and the DOM's HTML setters. Both are banned outright rather
// than reviewed case by case.
const markup = 'API data is rendered as text; building HTML from a string is not allowed on this page.';

export default tseslint.config(
  { ignores: ['dist/', 'node_modules/', 'playwright-report/', 'test-results/', 'pool-elements/dist/', '.host-fixture/'] },
  js.configs.recommended,
  ...tseslint.configs.strict,
  {
    rules: {
      'no-restricted-imports': ['error', {
        patterns: [{ group: ['lit/directives/unsafe-*', 'lit-html/directives/unsafe-*'], message: markup }],
      }],
      'no-restricted-syntax': ['error',
        { selector: "Identifier[name=/^unsafe(HTML|SVG|MathML)$/]", message: markup },
        { selector: "MemberExpression[property.name=/^(innerHTML|outerHTML|insertAdjacentHTML|createContextualFragment)$/]", message: markup },
        { selector: "CallExpression[callee.property.name='write'][callee.object.name='document']", message: markup },
      ],
      'no-restricted-globals': ['error', { name: 'eval', message: markup }],
      'no-implied-eval': 'error',
      'no-new-func': 'error',
    },
  },
  {
    // a test that finds nothing fails on the lookup, which is the point
    files: ['test/**/*.ts', 'e2e/**/*.ts'],
    rules: { '@typescript-eslint/no-non-null-assertion': 'off' },
  },
  {
    files: ['scripts/**/*.mjs'],
    languageOptions: { globals: { process: 'readonly', console: 'readonly', URL: 'readonly' } },
  },
);
