package main

import (
	"encoding/json"
	"fmt"
	"log"
	"math/rand"
	"net/http"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

var upgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool {
		return true
	},
}

type Client struct {
	ID        string
	Sovereign string
	Conn      *websocket.Conn
	Send      chan []byte
}

type Message struct {
	Type         string   `json:"type"` // "chat", "square_action", "peers", "create_pair_code", "join_pair_code", "pair_created", "pair_success", "pair_error"
	SenderID     string   `json:"sender_id,omitempty"`
	Sovereign    string   `json:"sovereign,omitempty"`
	TargetID     string   `json:"target_id,omitempty"`
	Content      string   `json:"content,omitempty"`
	Code         string   `json:"code,omitempty"`
	Peers        []string `json:"peers,omitempty"`
	
	// Public Square Interactive Fields
	MessageID    string   `json:"message_id,omitempty"`
	ReplyToID    string   `json:"reply_to_id,omitempty"`
	Action       string   `json:"action,omitempty"`       // "post", "reply", "vote", "reaction"
	VoteType     string   `json:"vote_type,omitempty"`    // "upvote", "downvote"
	ReactionType string   `json:"reaction_type,omitempty"`// "like", "super_like", "resonate"
	Timestamp    string   `json:"timestamp,omitempty"`
}

type PairingSession struct {
	HostClient *Client
	Code       string
	CreatedAt  time.Time
}

type Hub struct {
	clients         map[string]*Client
	pairingSessions map[string]*PairingSession
	broadcast       chan Message
	register        chan *Client
	unregister      chan *Client
	mu              sync.Mutex
}

func newHub() *Hub {
	return &Hub{
		clients:         make(map[string]*Client),
		pairingSessions: make(map[string]*PairingSession),
		broadcast:       make(chan Message),
		register:        make(chan *Client),
		unregister:      make(chan *Client),
	}
}

func generateSixDigitCode() string {
	r := rand.New(rand.NewSource(time.Now().UnixNano()))
	return fmt.Sprintf("%06d", r.Intn(1000000))
}

func (h *Hub) run() {
	for {
		select {
		case client := <-h.register:
			h.mu.Lock()
			h.clients[client.ID] = client
			h.mu.Unlock()
			fmt.Printf(" [+] Node connected: %s (%s) | Total active: %d\n", client.ID, client.Sovereign, len(h.clients))
			h.broadcastPeerList()

		case client := <-h.unregister:
			h.mu.Lock()
			if _, ok := h.clients[client.ID]; ok {
				delete(h.clients, client.ID)
				close(client.Send)
				for code, session := range h.pairingSessions {
					if session.HostClient.ID == client.ID {
						delete(h.pairingSessions, code)
					}
				}
				fmt.Printf(" [-] Node disconnected: %s | Total active: %d\n", client.ID, len(h.clients))
			}
			h.mu.Unlock()
			h.broadcastPeerList()

		case msg := <-h.broadcast:
			h.handleMessage(msg)
		}
	}
}

func (h *Hub) handleMessage(msg Message) {
	h.mu.Lock()
	defer h.mu.Unlock()

	switch msg.Type {
	case "create_pair_code":
		client, exists := h.clients[msg.SenderID]
		if !exists {
			return
		}
		code := generateSixDigitCode()
		h.pairingSessions[code] = &PairingSession{
			HostClient: client,
			Code:       code,
			CreatedAt:  time.Now(),
		}

		resp := Message{
			Type: "pair_created",
			Code: code,
		}
		data, _ := json.Marshal(resp)
		client.Send <- data
		fmt.Printf(" [🔑] Pairing code generated: %s for %s (%s)\n", code, client.ID, client.Sovereign)

	case "join_pair_code":
		guestClient, exists := h.clients[msg.SenderID]
		if !exists {
			return
		}

		session, found := h.pairingSessions[msg.Code]
		if !found || time.Since(session.CreatedAt) > 10*time.Minute {
			resp := Message{
				Type:    "pair_error",
				Content: "Invalid or expired pairing code.",
			}
			data, _ := json.Marshal(resp)
			guestClient.Send <- data
			return
		}

		hostClient := session.HostClient

		// Send host info to guest
		guestResp := Message{
			Type:      "pair_success",
			SenderID:  hostClient.ID,
			Sovereign: hostClient.Sovereign,
		}
		guestData, _ := json.Marshal(guestResp)
		guestClient.Send <- guestData

		// Send guest info to host
		hostResp := Message{
			Type:      "pair_success",
			SenderID:  guestClient.ID,
			Sovereign: guestClient.Sovereign,
		}
		hostData, _ := json.Marshal(hostResp)
		hostClient.Send <- hostData

		delete(h.pairingSessions, msg.Code)
		fmt.Printf(" [⚡] Pairing successful! %s (%s) <--> %s (%s)\n", hostClient.ID, hostClient.Sovereign, guestClient.ID, guestClient.Sovereign)

	case "square_action":
		// Stamp server timestamp if missing
		if msg.Timestamp == "" {
			msg.Timestamp = time.Now().Format(time.RFC3339)
		}

		data, _ := json.Marshal(msg)
		// Broadcast Public Square actions (posts, comments, votes, reactions) to all clients
		for _, client := range h.clients {
			select {
			case client.Send <- data:
			default:
				close(client.Send)
				delete(h.clients, client.ID)
			}
		}
		fmt.Printf(" [📣] Public Square Action: %s | From: %s | Target Msg: %s\n", msg.Action, msg.Sovereign, msg.MessageID)

	case "chat":
		if msg.TargetID != "" {
			// Direct peer-to-peer message
			if targetClient, ok := h.clients[msg.TargetID]; ok {
				data, _ := json.Marshal(msg)
				targetClient.Send <- data
			}
		} else {
			// Legacy broadcast fallback
			data, _ := json.Marshal(msg)
			for _, client := range h.clients {
				if client.ID == msg.SenderID {
					continue
				}
				select {
				case client.Send <- data:
				default:
					close(client.Send)
					delete(h.clients, client.ID)
				}
			}
		}
	}
}

func (h *Hub) broadcastPeerList() {
	h.mu.Lock()
	defer h.mu.Unlock()

	peers := make([]string, 0, len(h.clients))
	for _, client := range h.clients {
		peers = append(peers, fmt.Sprintf("%s (%s)", client.ID, client.Sovereign))
	}

	msg := Message{
		Type:  "peers",
		Peers: peers,
	}
	data, _ := json.Marshal(msg)

	for _, client := range h.clients {
		select {
		case client.Send <- data:
		default:
		}
	}
}

func handleWebSocket(hub *Hub, w http.ResponseWriter, r *http.Request) {
	deviceID := r.URL.Query().Get("device_id")
	sovereign := r.URL.Query().Get("sovereign")
	if deviceID == "" {
		http.Error(w, "Device ID query parameter required", http.StatusBadRequest)
		return
	}
	if sovereign == "" {
		sovereign = "@anonymous#0000"
	}

	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Println("Upgrade error:", err)
		return
	}

	client := &Client{
		ID:        deviceID,
		Sovereign: sovereign,
		Conn:      conn,
		Send:      make(chan []byte, 256),
	}

	hub.register <- client

	go func() {
		defer func() {
			hub.unregister <- client
			client.Conn.Close()
		}()
		for {
			_, payload, err := client.Conn.ReadMessage()
			if err != nil {
				break
			}
			var msg Message
			if err := json.Unmarshal(payload, &msg); err == nil {
				msg.SenderID = client.ID
				msg.Sovereign = client.Sovereign
				hub.broadcast <- msg
			}
		}
	}()

	go func() {
		defer client.Conn.Close()
		for message := range client.Send {
			err := client.Conn.WriteMessage(websocket.TextMessage, message)
			if err != nil {
				break
			}
		}
	}()
}

func main() {
	hub := newHub()
	go hub.run()

	http.HandleFunc("/ws", func(w http.ResponseWriter, r *http.Request) {
		handleWebSocket(hub, w, r)
	})

	port := ":8080"
	fmt.Printf("🚀 Rootspace Sovereign Server running on http://localhost%s/ws\n", port)
	if err := http.ListenAndServe(port, nil); err != nil {
		log.Fatal("ListenAndServe error:", err)
	}
}