const functions = require('firebase-functions/v1');
const { initializeApp } = require('firebase-admin/app');
const { getDatabase } = require('firebase-admin/database');
const { getMessaging } = require('firebase-admin/messaging');

initializeApp();

/**
 * Karşı cihaza wakeRequests yazıldığında FCM push gönderir.
 * Uygulama kapalı/arka plandayken bile bildirim + uyandırma sağlar.
 */
exports.onWakeRequestPush = functions
  .region('europe-west1')
  .database.ref('/devices/{deviceId}/wakeRequests/{requestId}')
  .onCreate(async (snapshot, context) => {
    const wake = snapshot.val();
    if (!wake || typeof wake !== 'object') return null;

    const deviceId = context.params.deviceId;
    const db = getDatabase();

    const tokenSnap = await db.ref(`devices/${deviceId}/fcmToken`).get();
    const token = tokenSnap.val();
    if (!token || typeof token !== 'string') {
      console.log(`FCM token yok: ${deviceId}`);
      return null;
    }

    const type = wake.type || 'connect';
    const fromName = wake.fromDeviceName || 'Cihaz';
    const fromId = wake.fromDeviceId || '';
    const createdAt = String(wake.createdAt || Date.now());
    const roomCode = wake.roomCode || '';

    let title;
    let body;
    let channelId;

    switch (type) {
      case 'reconnect':
        title = `${fromName} bağlantı kurmak istiyor`;
        body = 'Onaylayın veya reddedin.';
        channelId = 'directdrop_reconnect';
        break;
      case 'file_request':
        title = `${fromName} dosya göndermek istiyor`;
        body = 'Dokunarak bağlanın ve transferi başlatın.';
        channelId = 'directdrop_wake';
        break;
      default:
        title = `${fromName} bağlanmak istiyor`;
        body = 'Dokunarak bağlanın ve transferi başlatın.';
        channelId = 'directdrop_wake';
        break;
    }

    const message = {
      token,
      notification: { title, body },
      data: {
        type,
        fromDeviceId: fromId,
        fromDeviceName: fromName,
        createdAt,
        roomCode,
      },
      android: {
        priority: 'high',
        notification: {
          channelId,
          priority: 'max',
          defaultSound: true,
          defaultVibrateTimings: true,
          visibility: 'public',
        },
      },
      apns: {
        headers: {
          'apns-priority': '10',
        },
        payload: {
          aps: {
            alert: { title, body },
            sound: 'default',
            'interruption-level': 'time-sensitive',
          },
        },
      },
    };

    try {
      await getMessaging().send(message);
      console.log(`FCM gönderildi: ${deviceId} (${type})`);
    } catch (err) {
      console.error(`FCM hatası (${deviceId}):`, err);
    }

    return null;
  });
