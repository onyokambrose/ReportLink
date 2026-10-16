// ReportLink Web Push Service Worker
self.addEventListener('push', function(event) {
  let data = {
    title: 'ReportLink',
    body: 'You have a new notification.',
    url: '/admin-dashboard/',
  };
  if (event.data) {
    try {
      const parsed = event.data.json();
      data = { ...data, ...parsed };
    } catch (e) {
      data.body = event.data.text();
    }
  }
  const options = {
    body: data.body,
    icon: '/static/dashboard/img/logo.png',
    badge: '/static/dashboard/img/logo.png',
    tag: data.tag || 'reportlink',
    data: { url: data.url },
  };
  event.waitUntil(self.registration.showNotification(data.title, options));
});

self.addEventListener('notificationclick', function(event) {
  event.notification.close();
  const url = event.notification.data && event.notification.data.url
    ? event.notification.data.url
    : '/admin-dashboard/';
  event.waitUntil(clients.openWindow(url));
});
