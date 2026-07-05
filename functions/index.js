const { onDocumentCreated } = require("firebase-functions/v2/firestore");
const { initializeApp } = require("firebase-admin/app");
const { getFirestore } = require("firebase-admin/firestore");
const { getMessaging } = require("firebase-admin/messaging");

initializeApp();

const db = getFirestore();
const messaging = getMessaging();

// ─────────────────────────────────────────────
// TRIGGER 1: New message → notify recipient(s)
// ─────────────────────────────────────────────
exports.onNewMessage = onDocumentCreated(
  "chatRooms/{chatRoomId}/messages/{messageId}",
  async (event) => {
    const message = event.data.data();
    const { chatRoomId } = event.params;

    // Ignore system messages
    if (message.type === "system") return;

    // Get the chat room to find all participants
    const chatRoomDoc = await db.collection("chatRooms").doc(chatRoomId).get();
    if (!chatRoomDoc.exists) return;

    const chatRoom = chatRoomDoc.data();
    const participants = chatRoom.participants || [];
    const senderId = message.senderId;

    // Send notification to every participant EXCEPT the sender
    const recipients = participants.filter((uid) => uid !== senderId);

    const notificationPromises = recipients.map(async (uid) => {
      const userDoc = await db.collection("users").doc(uid).get();
      if (!userDoc.exists) return;

      const fcmToken = userDoc.data().fcmToken;
      if (!fcmToken) return; // User has no token (not logged in on any device)

      const senderName = message.senderName || "Someone";
      const text = message.text || "Sent a message";
      const chatName = chatRoom.isGroup
        ? chatRoom.groupName || "Group"
        : senderName;

      return messaging.send({
        token: fcmToken,
        notification: {
          title: chatName,
          body: chatRoom.isGroup ? `${senderName}: ${text}` : text,
        },
        data: {
          type: "chat",
          id: chatRoomId,
        },
        android: {
          priority: "high",
          notification: {
            channelId: "comms_channel",
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
      });
    });

    await Promise.allSettled(notificationPromises);
  }
);

// ─────────────────────────────────────────────
// TRIGGER 2: New call document → notify receiver
// ─────────────────────────────────────────────
exports.onNewCall = onDocumentCreated("calls/{callId}", async (event) => {
  const call = event.data.data();

  // Only notify when the call is first created (status: ringing)
  if (call.status !== "ringing") return;

  const receiverId = call.receiverId;
  if (!receiverId) return;

  const userDoc = await db.collection("users").doc(receiverId).get();
  if (!userDoc.exists) return;

  const fcmToken = userDoc.data().fcmToken;
  if (!fcmToken) return;

  const callerName = call.callerName || "Someone";
  const isVideo = call.type === "video";

  try {
    await messaging.send({
      token: fcmToken,
      notification: {
        title: isVideo ? "📹 Incoming Video Call" : "📞 Incoming Voice Call",
        body: `${callerName} is calling you`,
      },
      data: {
        type: "call",
        id: event.params.callId,
      },
      android: {
        priority: "high",
        notification: {
          channelId: "comms_channel",
          sound: "default",
        },
      },
      apns: {
        payload: {
          aps: {
            sound: "default",
            badge: 1,
            "content-available": 1,
          },
        },
      },
    });
  } catch (err) {
    console.error("Error sending call notification:", err);
  }
});
