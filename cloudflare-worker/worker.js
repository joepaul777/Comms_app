// Comms — Cloudflare Worker (Notification Server)
// Deploy this at: https://workers.cloudflare.com
// Set env variable: FCM_SERVER_KEY = your Firebase Server Key
//
// How to get your FCM Server Key:
// Firebase Console → Project Settings → Cloud Messaging → Server Key

export default {
  async fetch(request, env) {
    // Only allow POST requests
    if (request.method !== "POST") {
      return new Response("Method Not Allowed", { status: 405 });
    }

    // Basic security: check a shared secret header
    const authHeader = request.headers.get("X-Comms-Secret");
    if (!env.COMMS_SECRET || authHeader !== env.COMMS_SECRET) {
      return new Response("Unauthorized", { status: 401 });
    }

    let body;
    try {
      body = await request.json();
    } catch {
      return new Response("Invalid JSON", { status: 400 });
    }

    const { token, title, message, data } = body;

    if (!token || !title || !message) {
      return new Response("Missing required fields: token, title, message", {
        status: 400,
      });
    }

    // Call the FCM Legacy HTTP API
    const fcmResponse = await fetch("https://fcm.googleapis.com/fcm/send", {
      method: "POST",
      headers: {
        Authorization: `key=${env.FCM_SERVER_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        to: token,
        priority: "high",
        notification: {
          title: title,
          body: message,
          sound: "default",
        },
        data: data || {},
        android: {
          priority: "high",
          notification: {
            channel_id: "comms_channel",
            sound: "default",
          },
        },
        apns: {
          payload: {
            aps: {
              sound: "default",
              badge: 1,
            },
          },
        },
      }),
    });

    const result = await fcmResponse.json();

    if (!fcmResponse.ok) {
      return new Response(JSON.stringify({ error: result }), { status: 500 });
    }

    return new Response(JSON.stringify({ success: true, result }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  },
};
