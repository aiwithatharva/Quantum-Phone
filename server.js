// server.js - Place this on your EC2 instance
const WebSocket = require('ws');

const PORT = process.env.PORT || 8080; // Use port 8080 by default

// In-memory storage: Map<userId, WebSocketConnection>
// WARNING: This data is lost if the server restarts! Consider a database for persistence.
const clients = new Map();

// Create the WebSocket server
const wss = new WebSocket.Server({ port: PORT });

console.log(`WebSocket server started on port ${PORT}`);

wss.on('connection', (ws) => {
    console.log('Client connected (IP:', ws._socket.remoteAddress, ')'); // Log IP on connection
    let currentUserId = null; // Track the userId for this specific connection

    ws.on('message', (message) => {
        let parsedMessage;
        try {
            // Ensure message is treated as a string before parsing
            const messageString = message.toString();
            parsedMessage = JSON.parse(messageString);

            const action = parsedMessage.action;
            const userId = parsedMessage.userId; // For register
            const fromId = parsedMessage.fromId; // For calls/signals/qkd etc.
            const toId = parsedMessage.toId;     // Target recipient

            // Log received action details (avoid logging sensitive payload data)
            console.log(`Received: Action='${action}', From='${fromId || userId || 'N/A'}', To='${toId || 'N/A'}', ConnUser='${currentUserId || 'unregistered'}'`);

            // Helper function to send errors back to the sender of the problematic message
            const sendError = (socket, reason, originatingAction = null) => {
                const errorPayload = { action: 'error', reason: reason };
                if (originatingAction) {
                    errorPayload.originalAction = originatingAction;
                }
                try {
                    if (socket && socket.readyState === WebSocket.OPEN) {
                        console.warn(`Sending error to ${currentUserId || 'client'}: ${reason} (Original Action: ${originatingAction || 'N/A'})`);
                        socket.send(JSON.stringify(errorPayload));
                    }
                } catch (e) {
                    console.error("Failed to send error message:", e);
                }
            };

            // Generic relay function: Sends message to targetUserId
            const relayMessage = (targetUserId, messagePayload) => {
                 const targetWs = clients.get(targetUserId);
                 if (targetWs && targetWs.readyState === WebSocket.OPEN) {
                     const senderId = messagePayload.fromId || currentUserId; // Best guess of sender
                     console.log(`Relaying Action='${messagePayload.action}' from '${senderId}' to '${targetUserId}'`);

                     // Ensure the payload identifies the original sender for the recipient
                     // The client usually expects 'fromId'
                     if (!messagePayload.fromId && senderId) {
                        messagePayload.fromId = senderId;
                     }
                     // Add relayedFrom for extra server-side clarity if needed
                     // messagePayload.relayedFrom = senderId;

                     targetWs.send(JSON.stringify(messagePayload));
                     return true; // Relay successful
                 } else {
                     console.warn(`Cannot relay Action='${action}': Target UserID '${targetUserId}' not found or connection not open.`);
                     // Notify the original sender that the relay failed
                     const originalSenderWs = clients.get(fromId || currentUserId);
                     if (originalSenderWs && originalSenderWs.readyState === WebSocket.OPEN) {
                         sendError(originalSenderWs, `User ${targetUserId} is offline or unavailable.`, action);
                     } else if (fromId) {
                         console.error(`Cannot notify original sender ${fromId}, connection not found.`);
                     }
                     return false; // Relay failed
                 }
            };

            // --- Action Handler Switch ---
            switch (action) {
                case 'register':
                    if (userId) {
                        // Check if ID is already in use by a *different* connection
                        if (clients.has(userId) && clients.get(userId) !== ws) {
                            console.warn(`UserID ${userId} is already registered by another connection. Terminating old connection.`);
                            const oldWs = clients.get(userId);
                            sendError(oldWs, 'Connection replaced by new registration for this UserID.', 'register');
                            oldWs.terminate(); // Force close the old connection
                        }
                        // Associate this connection with the userId
                        currentUserId = userId;
                        clients.set(userId, ws);
                        console.log(`User '${userId}' registered/updated. Total clients: ${clients.size}`);
                        ws.send(JSON.stringify({ action: 'registered', userId: userId }));
                    } else {
                        console.error('Register action missing userId');
                        sendError(ws, 'Registration failed: userId missing.', action);
                    }
                    break;

                case 'callRequest':
                    if (toId && fromId) {
                        if(fromId === toId) {
                            sendError(ws, 'Cannot initiate a call with yourself.', action);
                        } else if (clients.has(toId)) {
                             relayMessage(toId, { action: 'incomingCall', fromId: fromId });
                        } else {
                             // Target offline, notify caller immediately
                             sendError(ws, `User ${toId} is offline or unavailable.`, action);
                        }
                    } else {
                         console.error('callRequest missing toId or fromId');
                         sendError(ws, 'Call request invalid: toId or fromId missing.', action);
                    }
                    break;

                case 'callResponse':
                     if (toId && fromId && parsedMessage.accepted !== undefined) {
                        // Relay response (accepted/rejected) back to the original caller (who is 'toId' here)
                        relayMessage(toId, {
                            action: 'callStatus',
                            fromId: fromId, // The user who accepted/rejected
                            accepted: parsedMessage.accepted
                        });
                     } else {
                         console.error('callResponse missing fields (toId, fromId, accepted)');
                         sendError(ws, 'Call response invalid: missing fields.', action);
                     }
                     break;

                 // Relay WebRTC signaling messages (Offer, Answer, ICE Candidate)
                 case 'webrtcSignal':
                    if (toId && fromId && parsedMessage.data) {
                         // Relay the entire original message { action, toId, fromId, data }
                         relayMessage(toId, parsedMessage);
                    } else {
                       console.error(`webrtcSignal message missing fields (toId, fromId, data)`);
                       sendError(ws, 'WebRTC signal invalid: missing fields.', action);
                    }
                    break;

                 // Relay QKD messages
                case 'qkdMessage':
                    if (toId && fromId && parsedMessage.data) {
                         // Relay the entire original message { action, toId, fromId, data }
                         relayMessage(toId, parsedMessage);
                    } else {
                       console.error(`qkdMessage message missing fields (toId, fromId, data)`);
                       sendError(ws, 'QKD message invalid: missing fields.', action);
                    }
                    break;

                // *** ADDED: Relay Push-to-Talk Signals ***
                case 'startTalking':
                case 'stopTalking':
                    if (toId && fromId) {
                        // Relay the start/stop talking signal
                        // The original message already has { action, toId, fromId }
                        relayMessage(toId, parsedMessage);
                    } else {
                        console.error(`${action} message missing fields (toId, fromId)`);
                        sendError(ws, `${action} invalid: missing fields.`, action);
                    }
                    break; // Crucial break!
                // *** END OF ADDED BLOCK ***

                case 'hangUp':
                     if (toId && fromId) {
                         // Notify the other party that the call has ended
                         // The user initiating the hangup is 'fromId'
                         relayMessage(toId, { action: 'callEnded', fromId: fromId });
                         console.log(`Hangup initiated by ${fromId} to ${toId}`);
                     } else {
                         console.error('hangUp message missing fields (toId, fromId)');
                         // Sending an error back isn't strictly necessary, but possible
                         // sendError(ws, 'Hangup invalid: missing fields.', action);
                     }
                    break;

                default:
                    // Handle actions the server doesn't recognize
                    console.warn(`Unknown action received: '${action}' from ${currentUserId || 'unregistered client'}`);
                    sendError(ws, `Unknown action: ${action}`, action);
            }
            // --- End of Action Handler Switch ---

        } catch (e) {
            console.error('Failed to parse message or process action. Raw message:', message.toString(), 'Error:', e);
            // Attempt to send a generic error back if parsing failed
            sendError(ws, 'Invalid message format or server error during processing.');
        }
    });

    ws.on('close', (code, reason) => {
        const reasonString = reason ? reason.toString() : 'No reason provided';
        console.log(`Client disconnected. Code: ${code}, Reason: '${reasonString}', UserID: ${currentUserId || 'Not registered'}`);
        if (currentUserId) {
            const deleted = clients.delete(currentUserId); // Remove user from map
            console.log(`User '${currentUserId}' ${deleted ? 'removed' : 'was not found in map'}. Clients remaining: ${clients.size}`);

            // TODO: Implement robust call state tracking to notify active call partners about disconnects.
            // Example: Iterate through active calls, find partner of 'currentUserId', send 'callEnded' or 'peerDisconnected'.
        }
        currentUserId = null; // Ensure userId is cleared for this connection instance
    });

    ws.on('error', (error) => {
        console.error(`WebSocket error for UserID ${currentUserId || 'Not registered'}:`, error);
        // 'close' event usually follows, but cleanup here ensures removal if 'close' fails
        if (currentUserId && clients.has(currentUserId)) {
            console.log(`Removing user ${currentUserId} due to WebSocket error.`);
            clients.delete(currentUserId);
        }
        currentUserId = null;
        // Don't necessarily terminate here; the 'ws' library often handles this by emitting 'close'
        // If connections linger after errors, consider adding ws.terminate()
    });

    // Send a ping every 30 seconds to keep connection alive and detect broken ones
    const pingInterval = setInterval(() => {
        if (ws.readyState === WebSocket.OPEN) {
            // console.log(`Pinging ${currentUserId || 'client'}...`); // Optional: verbose ping logging
            ws.ping((err) => {
                if (err) {
                    console.error(`Ping error for ${currentUserId || 'client'}:`, err);
                    // Don't necessarily terminate immediately, pong timeout handles it
                }
            });
        } else {
            clearInterval(pingInterval); // Stop pinging if connection is not open
        }
    }, 30000); // 30 seconds

    // Set a timeout for pong response (e.g., 10 seconds after ping)
    let pongTimeout;
    ws.on('pong', () => {
        // console.log(`Pong received from ${currentUserId || 'client'}`); // Optional: verbose pong logging
        clearTimeout(pongTimeout); // Clear the timeout if pong received
        // Optionally schedule the next timeout check or rely on the next ping cycle
    });

    // Check for pong timeout after each ping
    ws.on('ping', () => { // Can also check within the ping sender callback
         clearTimeout(pongTimeout); // Clear previous timeout before setting new one
         pongTimeout = setTimeout(() => {
             console.warn(`Pong timeout for UserID ${currentUserId || 'unregistered'}. Terminating connection.`);
             ws.terminate(); // Terminate connection if no pong received within timeout
             clearInterval(pingInterval); // Stop pinging this connection
         }, 10000); // 10 seconds timeout for pong
    });

    // Clear intervals and timeouts when connection truly closes
    ws.on('close', () => {
        clearInterval(pingInterval);
        clearTimeout(pongTimeout);
    });

});

// Global error handling for the server itself (e.g., port binding)
wss.on('error', (error) => {
    console.error('WebSocket Server Error (wss level):', error);
    if (error.code === 'EADDRINUSE') {
        console.error(`FATAL: Port ${PORT} is already in use. Shutting down.`);
        process.exit(1); // Exit immediately if port is taken
    }
});

console.log('WebSocket server setup complete. Waiting for connections...');
