import react from '@vitejs/plugin-react';
import { defineConfig } from 'vite';

export default defineConfig({
  root: 'client',
  // preact/compat is API-compatible with React and ~130KB smaller. Components
  // import from 'react' as before; the alias swaps the implementation.
  resolve: {
    alias: {
      react: 'preact/compat',
      'react-dom': 'preact/compat',
      'react-dom/client': 'preact/compat/client',
      'react/jsx-runtime': 'preact/jsx-runtime',
    },
  },
  plugins: [react()],
  build: {
    // The server serves this directory directly.
    outDir: '../dist/public',
    emptyOutDir: true,
  },
  server: {
    // In dev the client runs on Vite and proxies the API to the real server.
    proxy: { '/api': 'http://localhost:8080' },
  },
});
