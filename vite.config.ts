import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { VitePWA } from 'vite-plugin-pwa'

export default defineConfig({
  plugins: [react(), VitePWA({
    registerType: 'autoUpdate',
    manifest: {
      id: '/', name: 'SakAccounts', short_name: 'SakAccounts',
      description: 'Capture expenses, receipts and payments for SakAccounts.',
      start_url: '/?capture=1', scope: '/', display: 'standalone',
      background_color: '#f5f7f4', theme_color: '#15382f',
      icons: [
        { src: '/icons/icon-192.png', sizes: '192x192', type: 'image/png', purpose: 'any maskable' },
        { src: '/icons/icon-512.png', sizes: '512x512', type: 'image/png', purpose: 'any maskable' },
      ],
      shortcuts: [{ name: 'Add expense', short_name: 'Expense', url: '/?capture=1', icons: [{ src: '/icons/icon-192.png', sizes: '192x192' }] }],
      share_target: { action: '/?capture=1', method: 'GET', enctype: 'application/x-www-form-urlencoded', params: { title: 'title', text: 'text', url: 'url' } },
    },
    workbox: {
      importScripts: ['/push-handler.js'],
      globPatterns: ['**/*.{js,css,html,png,svg,wasm,gz,webmanifest}'],
      maximumFileSizeToCacheInBytes: 15 * 1024 * 1024,
      navigateFallback: '/index.html',
      runtimeCaching: [],
    },
  })],
})
