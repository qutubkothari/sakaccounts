self.addEventListener('push', event => {
  if (!event.data) return
  let message
  try { message = event.data.json() } catch { return }
  event.waitUntil(self.registration.showNotification(message.title || 'SakAccounts', {
    body: message.body || 'Open your daily review.',
    icon: '/icons/icon-192.png',
    badge: '/icons/icon-192.png',
    tag: 'sakaccounts-review',
    data: { url: '/' },
  }))
})

self.addEventListener('notificationclick', event => {
  event.notification.close()
  event.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(clients => {
    const open = clients.find(client => new URL(client.url).origin === self.location.origin)
    if (open) return open.focus()
    return self.clients.openWindow('/')
  }))
})
