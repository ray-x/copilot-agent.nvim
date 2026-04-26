package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	copilot "github.com/github/copilot-sdk/go"
)

const (
	permissionModeApproveAll  = "approve-all"
	permissionModeRejectAll   = "reject-all"
	permissionModeInteractive = "interactive" // routes each request to the Neovim UI
	permissionModeAutopilot   = "autopilot"   // approve-all + auto-answer user inputs
	defaultModel              = ""
	defaultClientName         = "neovim-copilot-service"
	defaultInputTimeout       = 15 * time.Minute
)

type createSessionRequest struct {
	SessionID                      string                       `json:"sessionId,omitempty"`
	Resume                         bool                         `json:"resume,omitempty"`
	ClientName                     string                       `json:"clientName,omitempty"`
	Model                          string                       `json:"model,omitempty"`
	ReasoningEffort                string                       `json:"reasoningEffort,omitempty"`
	WorkingDirectory               string                       `json:"workingDirectory,omitempty"`
	Streaming                      *bool                        `json:"streaming,omitempty"`
	IncludeSubAgentStreamingEvents *bool                        `json:"includeSubAgentStreamingEvents,omitempty"`
	PermissionMode                 string                       `json:"permissionMode,omitempty"`
	AvailableTools                 []string                     `json:"availableTools,omitempty"`
	ExcludedTools                  []string                     `json:"excludedTools,omitempty"`
	SystemMessage                  *copilot.SystemMessageConfig `json:"systemMessage,omitempty"`
	EnableConfigDiscovery          *bool                        `json:"enableConfigDiscovery,omitempty"`
	Agent                          string                       `json:"agent,omitempty"`
	CustomAgents                   []copilot.CustomAgentConfig  `json:"customAgents,omitempty"`
	SkillDirectories               []string                     `json:"skillDirectories,omitempty"`
	DisabledSkills                 []string                     `json:"disabledSkills,omitempty"`
}

type sendMessageRequest struct {
	Prompt         string               `json:"prompt"`
	Mode           string               `json:"mode,omitempty"`
	Attachments    []copilot.Attachment `json:"attachments,omitempty"`
	RequestHeaders map[string]string    `json:"requestHeaders,omitempty"`
}

type setModelRequest struct {
	Model string `json:"model"`
}

type answerUserInputRequest struct {
	Answer      string `json:"answer"`
	WasFreeform bool   `json:"wasFreeform,omitempty"`
}

type sessionSummary struct {
	SessionID         string                      `json:"sessionId"`
	Model             string                      `json:"model,omitempty"`
	WorkingDirectory  string                      `json:"workingDirectory,omitempty"`
	WorkspacePath     string                      `json:"workspacePath,omitempty"`
	PermissionMode    string                      `json:"permissionMode"`
	ExcludedTools     []string                    `json:"excludedTools,omitempty"`
	Capabilities      copilot.SessionCapabilities `json:"capabilities,omitempty"`
	PendingUserInputs []pendingUserInputView      `json:"pendingUserInputs,omitempty"`
	Live              bool                        `json:"live"`
	CreatedAt         time.Time                   `json:"createdAt"`
	Resumed           bool                        `json:"resumed"`
	Streaming         bool                        `json:"streaming"`
	Agent             string                      `json:"agent,omitempty"`
	ConfigDiscovery   bool                        `json:"configDiscovery"`
	ClientName        string                      `json:"clientName,omitempty"`
}

type listSessionsResponse struct {
	Persisted []copilot.SessionMetadata `json:"persisted"`
	Live      []sessionSummary          `json:"live"`
}

type hostEvent struct {
	Timestamp time.Time `json:"timestamp"`
	Data      any       `json:"data"`
}

type pendingUserInputView struct {
	ID            string    `json:"id"`
	Question      string    `json:"question"`
	Choices       []string  `json:"choices,omitempty"`
	AllowFreeform bool      `json:"allowFreeform"`
	CreatedAt     time.Time `json:"createdAt"`
}

type userInputResult struct {
	Response copilot.UserInputResponse
	Err      error
}

type pendingUserInput struct {
	view     pendingUserInputView
	resultCh chan userInputResult
}

type permissionResult struct {
	Approved bool
	Err      error
}

type pendingPermissionView struct {
	ID        string                    `json:"id"`
	Request   copilot.PermissionRequest `json:"request"`
	CreatedAt time.Time                 `json:"createdAt"`
}

type pendingPermission struct {
	view     pendingPermissionView
	resultCh chan permissionResult
}

type sseMessage struct {
	Event string
	Data  []byte
}

type managedSession struct {
	session              *copilot.Session
	model                string
	workingDirectory     string
	permissionMode       string
	excludedTools        []string
	createdAt            time.Time
	resumed              bool
	streaming            bool
	agent                string
	configDiscovery      bool
	clientName           string
	subscribers          map[chan sseMessage]struct{}
	subscribersMu        sync.RWMutex
	pendingInputs        map[string]*pendingUserInput
	pendingInputsMu      sync.Mutex
	pendingPermissions   map[string]*pendingPermission
	pendingPermissionsMu sync.Mutex
	eventUnsubscribe     func()
	inputResponseGrace   time.Duration
}

type service struct {
	client                  *copilot.Client
	defaultModel            string
	defaultWorkingDirectory string
	sessions                map[string]*managedSession
	sessionsMu              sync.RWMutex
}

func main() {
	addr := flag.String("addr", "", "HTTP listen address (host:port). Leave empty or use port 0 to let the OS assign a free port (default).")
	portRange := flag.String("port-range", "", "Port range to try when -addr is not set, e.g. 18000-19000. The first available port in the range is used.")
	cliPath := flag.String("cli-path", defaultCLIPath(), "path to Copilot CLI binary or JS entrypoint")
	cliURL := flag.String("cli-url", "", "URL for an already-running Copilot CLI server")
	model := flag.String("model", defaultModel, "default model for new sessions; empty uses the Copilot CLI account default")
	logLevel := flag.String("log-level", "error", "Copilot CLI log level")
	cwdFlag := flag.String("cwd", "", "default working directory for new sessions")
	lspMode := flag.Bool("lsp", true, "run LSP server over stdio alongside the HTTP service (default: true)")
	flag.Parse()

	workingDirectory, err := resolveWorkingDirectory(*cwdFlag)
	if err != nil {
		log.Fatal(err)
	}

	client := copilot.NewClient(&copilot.ClientOptions{
		CLIPath:  strings.TrimSpace(*cliPath),
		CLIUrl:   strings.TrimSpace(*cliURL),
		Cwd:      workingDirectory,
		LogLevel: *logLevel,
	})

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if err = client.Start(ctx); err != nil {
		log.Fatalf("start copilot client: %v", err)
	}
	defer client.Stop()

	svc := &service{
		client:                  client,
		defaultModel:            strings.TrimSpace(*model),
		defaultWorkingDirectory: workingDirectory,
		sessions:                make(map[string]*managedSession),
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", svc.handleHealth)
	mux.HandleFunc("GET /models", svc.handleListModels)
	mux.HandleFunc("GET /sessions", svc.handleListSessions)
	mux.HandleFunc("POST /sessions", svc.handleCreateSession)
	mux.HandleFunc("GET /sessions/{id}", svc.handleGetSession)
	mux.HandleFunc("DELETE /sessions/{id}", svc.handleDeleteSession)
	mux.HandleFunc("POST /sessions/{id}/model", svc.handleSetModel)
	mux.HandleFunc("GET /sessions/{id}/messages", svc.handleGetMessages)
	mux.HandleFunc("POST /sessions/{id}/messages", svc.handleSendMessage)
	mux.HandleFunc("GET /sessions/{id}/events", svc.handleEvents)
	mux.HandleFunc("POST /sessions/{id}/user-input/{requestID}", svc.handleAnswerUserInput)
	mux.HandleFunc("POST /sessions/{id}/permission/{requestID}", svc.handleAnswerPermission)
	mux.HandleFunc("POST /sessions/{id}/permission-mode", svc.handleSetPermissionMode)
	mux.HandleFunc("POST /sessions/{id}/tools", svc.handleSetTools)

	// Resolve listen address. When -addr is not set, honour -port-range if
	// provided, otherwise let the OS assign a free port (127.0.0.1:0).
	listenAddr := strings.TrimSpace(*addr)
	var listener net.Listener
	if listenAddr == "" || listenAddr == ":0" {
		if pr := strings.TrimSpace(*portRange); pr != "" {
			listener, err = listenInRange("127.0.0.1", pr)
		} else {
			listener, err = net.Listen("tcp", "127.0.0.1:0")
		}
	} else {
		listener, err = net.Listen("tcp", listenAddr)
	}
	if err != nil {
		log.Fatalf("listen %s: %v", listenAddr, err)
	}
	boundAddr := listener.Addr().String()
	// Ensure LSP proxy always has a full host:port (handles bare ":PORT" case).
	if strings.HasPrefix(boundAddr, ":") {
		boundAddr = "127.0.0.1" + boundAddr
	}

	server := &http.Server{
		Handler:           withCORS(loggingMiddleware(mux)),
		ReadHeaderTimeout: 10 * time.Second,
	}

	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := server.Shutdown(shutdownCtx); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Printf("shutdown HTTP server: %v", err)
		}
		svc.disconnectAll()
	}()

	// Start the LSP server on stdio concurrently with the HTTP service.
	if *lspMode {
		serviceURL := "http://" + boundAddr
		go func() {
			if err := runLSPServer(ctx, serviceURL); err != nil && err != context.Canceled {
				log.Printf("lsp server: %v", err)
			}
		}()
	}

	log.Printf("Neovim Copilot service listening on %s", boundAddr)
	log.Printf("Default workspace: %s", workingDirectory)
	if strings.TrimSpace(*cliURL) != "" {
		log.Printf("Using external Copilot CLI server at %s", strings.TrimSpace(*cliURL))
	} else if strings.TrimSpace(*cliPath) != "" {
		log.Printf("Using Copilot CLI at %s", strings.TrimSpace(*cliPath))
	}

	// Print the machine-readable address to stderr so it doesn't pollute the
	// LSP stdio stream. The Neovim plugin reads it from on_stderr.
	fmt.Fprintf(os.Stderr, "COPILOT_AGENT_ADDR=%s\n", boundAddr)

	if err := server.Serve(listener); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}

func (s *service) handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// listenInRange tries each port in "lo-hi" (inclusive) on the given host and
// returns the first listener that succeeds. Returns an error if no port in the
// range is available.
func listenInRange(host, portRange string) (net.Listener, error) {
	parts := strings.SplitN(portRange, "-", 2)
	if len(parts) != 2 {
		return nil, fmt.Errorf("invalid port range %q: expected \"lo-hi\"", portRange)
	}
	lo, err1 := strconv.Atoi(strings.TrimSpace(parts[0]))
	hi, err2 := strconv.Atoi(strings.TrimSpace(parts[1]))
	if err1 != nil || err2 != nil || lo < 1 || hi > 65535 || lo > hi {
		return nil, fmt.Errorf("invalid port range %q", portRange)
	}
	for port := lo; port <= hi; port++ {
		addr := fmt.Sprintf("%s:%d", host, port)
		ln, err := net.Listen("tcp", addr)
		if err == nil {
			return ln, nil
		}
	}
	return nil, fmt.Errorf("no available port in range %s", portRange)
}

func (s *service) handleListModels(w http.ResponseWriter, r *http.Request) {
	models, err := s.client.ListModels(r.Context())
	if err != nil {
		writeError(w, http.StatusBadGateway, fmt.Sprintf("list models: %v", err))
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{"models": models})
}

func (s *service) handleListSessions(w http.ResponseWriter, r *http.Request) {
	persisted, err := s.client.ListSessions(r.Context(), nil)
	if err != nil {
		writeError(w, http.StatusInternalServerError, fmt.Sprintf("list sessions: %v", err))
		return
	}

	live := s.liveSessionSummaries()
	writeJSON(w, http.StatusOK, listSessionsResponse{Persisted: persisted, Live: live})
}

func (s *service) handleCreateSession(w http.ResponseWriter, r *http.Request) {
	var req createSessionRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	if req.SessionID == "" {
		req.SessionID = newSessionID()
	}

	if req.PermissionMode == "" {
		req.PermissionMode = permissionModeApproveAll
	}
	if !isValidPermissionMode(req.PermissionMode) {
		writeError(w, http.StatusBadRequest, "permissionMode must be one of: interactive, approve-all, autopilot, reject-all")
		return
	}

	if existing, ok := s.getManagedSession(req.SessionID); ok {
		writeJSON(w, http.StatusOK, existing.summary())
		return
	}

	workingDirectory, err := s.resolveSessionWorkingDirectory(req.WorkingDirectory)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	streaming := boolOrDefault(req.Streaming, true)
	configDiscovery := boolOrDefault(req.EnableConfigDiscovery, true)
	clientName := strings.TrimSpace(req.ClientName)
	if clientName == "" {
		clientName = defaultClientName
	}

	model, err := s.resolveRequestedModel(r.Context(), firstNonEmpty(req.Model, s.defaultModel))
	if err != nil {
		writeError(w, http.StatusBadGateway, fmt.Sprintf("resolve model: %v", err))
		return
	}

	managed := &managedSession{
		model:              model,
		workingDirectory:   workingDirectory,
		permissionMode:     req.PermissionMode,
		excludedTools:      req.ExcludedTools,
		createdAt:          time.Now().UTC(),
		resumed:            req.Resume,
		streaming:          streaming,
		agent:              req.Agent,
		configDiscovery:    configDiscovery,
		clientName:         clientName,
		subscribers:        make(map[chan sseMessage]struct{}),
		pendingInputs:      make(map[string]*pendingUserInput),
		pendingPermissions: make(map[string]*pendingPermission),
		inputResponseGrace: defaultInputTimeout,
	}

	var session *copilot.Session
	if req.Resume {
		session, err = s.client.ResumeSession(r.Context(), req.SessionID, &copilot.ResumeSessionConfig{
			ClientName:                     clientName,
			Model:                          managed.model,
			ReasoningEffort:                req.ReasoningEffort,
			SystemMessage:                  req.SystemMessage,
			AvailableTools:                 req.AvailableTools,
			ExcludedTools:                  req.ExcludedTools,
			OnPermissionRequest:            managed.handlePermissionRequest,
			OnUserInputRequest:             managed.handleUserInputRequest,
			WorkingDirectory:               workingDirectory,
			EnableConfigDiscovery:          configDiscovery,
			Streaming:                      streaming,
			IncludeSubAgentStreamingEvents: req.IncludeSubAgentStreamingEvents,
			CustomAgents:                   req.CustomAgents,
			Agent:                          req.Agent,
			SkillDirectories:               req.SkillDirectories,
			DisabledSkills:                 req.DisabledSkills,
		})
		if err != nil {
			writeError(w, http.StatusBadGateway, fmt.Sprintf("resume session: %v", err))
			return
		}
		managed.session = session
		managed.eventUnsubscribe = session.On(managed.handleSessionEvent)
	} else {
		session, err = s.client.CreateSession(r.Context(), &copilot.SessionConfig{
			SessionID:                      req.SessionID,
			ClientName:                     clientName,
			Model:                          managed.model,
			ReasoningEffort:                req.ReasoningEffort,
			SystemMessage:                  req.SystemMessage,
			AvailableTools:                 req.AvailableTools,
			ExcludedTools:                  req.ExcludedTools,
			OnPermissionRequest:            managed.handlePermissionRequest,
			OnUserInputRequest:             managed.handleUserInputRequest,
			WorkingDirectory:               workingDirectory,
			Streaming:                      streaming,
			IncludeSubAgentStreamingEvents: req.IncludeSubAgentStreamingEvents,
			EnableConfigDiscovery:          configDiscovery,
			CustomAgents:                   req.CustomAgents,
			Agent:                          req.Agent,
			SkillDirectories:               req.SkillDirectories,
			DisabledSkills:                 req.DisabledSkills,
			OnEvent:                        managed.handleSessionEvent,
		})
		if err != nil {
			writeError(w, http.StatusBadGateway, fmt.Sprintf("create session: %v", err))
			return
		}
		managed.session = session
	}

	s.storeManagedSession(managed)
	writeJSON(w, http.StatusCreated, managed.summary())
}

func (s *service) handleGetSession(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	managed, ok := s.getManagedSession(id)
	if !ok {
		writeError(w, http.StatusNotFound, "session is not attached to this service")
		return
	}
	writeJSON(w, http.StatusOK, managed.summary())
}

func (s *service) handleDeleteSession(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	deleteState := queryBool(r, "delete")

	managed, ok := s.removeManagedSession(id)
	if !ok {
		if deleteState {
			if err := s.client.DeleteSession(r.Context(), id); err != nil {
				writeError(w, http.StatusNotFound, fmt.Sprintf("delete session: %v", err))
				return
			}
			writeJSON(w, http.StatusOK, map[string]any{"sessionId": id, "deleted": true})
			return
		}
		writeError(w, http.StatusNotFound, "session is not attached to this service")
		return
	}

	managed.broadcastHostEvent("host.session_disconnected", map[string]any{"sessionId": id, "deleteState": deleteState})
	managed.close(errors.New("session closed by host"))

	if deleteState {
		if err := s.client.DeleteSession(r.Context(), id); err != nil {
			writeError(w, http.StatusBadGateway, fmt.Sprintf("delete session state: %v", err))
			return
		}
	}

	writeJSON(w, http.StatusOK, map[string]any{"sessionId": id, "deleted": deleteState})
}

func (s *service) handleSetModel(w http.ResponseWriter, r *http.Request) {
	managed, ok := s.getManagedSession(r.PathValue("id"))
	if !ok {
		writeError(w, http.StatusNotFound, "session is not attached to this service")
		return
	}

	var req setModelRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	if strings.TrimSpace(req.Model) == "" {
		writeError(w, http.StatusBadRequest, "model is required")
		return
	}

	model := strings.TrimSpace(req.Model)
	model, err := s.resolveRequestedModel(r.Context(), model)
	if err != nil {
		writeError(w, http.StatusBadGateway, fmt.Sprintf("resolve model: %v", err))
		return
	}
	if err := managed.session.SetModel(r.Context(), model, nil); err != nil {
		writeError(w, http.StatusBadGateway, fmt.Sprintf("set model: %v", err))
		return
	}

	managed.model = model
	managed.broadcastHostEvent("host.model_changed", map[string]any{
		"sessionId": managed.session.SessionID,
		"model":     model,
	})

	writeJSON(w, http.StatusOK, managed.summary())
}

func (s *service) handleGetMessages(w http.ResponseWriter, r *http.Request) {
	managed, ok := s.getManagedSession(r.PathValue("id"))
	if !ok {
		writeError(w, http.StatusNotFound, "session is not attached to this service")
		return
	}

	events, err := managed.session.GetMessages(r.Context())
	if err != nil {
		writeError(w, http.StatusBadGateway, fmt.Sprintf("get messages: %v", err))
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"events": events})
}

func (s *service) handleSendMessage(w http.ResponseWriter, r *http.Request) {
	managed, ok := s.getManagedSession(r.PathValue("id"))
	if !ok {
		writeError(w, http.StatusNotFound, "session is not attached to this service")
		return
	}

	var req sendMessageRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	if strings.TrimSpace(req.Prompt) == "" {
		writeError(w, http.StatusBadRequest, "prompt is required")
		return
	}

	messageID, err := managed.session.Send(r.Context(), copilot.MessageOptions{
		Prompt:         req.Prompt,
		Attachments:    req.Attachments,
		Mode:           req.Mode,
		RequestHeaders: req.RequestHeaders,
	})
	if err != nil {
		writeError(w, http.StatusBadGateway, fmt.Sprintf("send message: %v", err))
		return
	}

	writeJSON(w, http.StatusAccepted, map[string]any{"sessionId": managed.session.SessionID, "messageId": messageID})
}

func (s *service) handleEvents(w http.ResponseWriter, r *http.Request) {
	managed, ok := s.getManagedSession(r.PathValue("id"))
	if !ok {
		writeError(w, http.StatusNotFound, "session is not attached to this service")
		return
	}

	flusher, ok := w.(http.Flusher)
	if !ok {
		writeError(w, http.StatusInternalServerError, "streaming is not supported by this server")
		return
	}

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")

	if err := writeSSE(w, "host.session_attached", mustJSON(hostEvent{Timestamp: time.Now().UTC(), Data: managed.summary()})); err != nil {
		return
	}
	flusher.Flush()

	if queryBool(r, "history") {
		events, err := managed.session.GetMessages(r.Context())
		if err != nil {
			writeError(w, http.StatusBadGateway, fmt.Sprintf("get history: %v", err))
			return
		}
		for _, event := range events {
			payload, err := (&event).Marshal()
			if err != nil {
				continue
			}
			if err := writeSSE(w, "session.event", payload); err != nil {
				return
			}
		}
		flusher.Flush()
	}

	sub := managed.subscribe()
	defer managed.unsubscribe(sub)

	keepAlive := time.NewTicker(15 * time.Second)
	defer keepAlive.Stop()

	for {
		select {
		case <-r.Context().Done():
			return
		case <-keepAlive.C:
			if _, err := fmt.Fprint(w, ": keepalive\n\n"); err != nil {
				return
			}
			flusher.Flush()
		case msg, ok := <-sub:
			if !ok {
				return
			}
			if err := writeSSE(w, msg.Event, msg.Data); err != nil {
				return
			}
			flusher.Flush()
		}
	}
}

func (s *service) handleAnswerUserInput(w http.ResponseWriter, r *http.Request) {
	managed, ok := s.getManagedSession(r.PathValue("id"))
	if !ok {
		writeError(w, http.StatusNotFound, "session is not attached to this service")
		return
	}

	var req answerUserInputRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	if err := managed.answerUserInput(r.PathValue("requestID"), req); err != nil {
		writeError(w, http.StatusNotFound, err.Error())
		return
	}

	writeJSON(w, http.StatusAccepted, map[string]any{"ok": true})
}

func (s *service) handleAnswerPermission(w http.ResponseWriter, r *http.Request) {
	managed, ok := s.getManagedSession(r.PathValue("id"))
	if !ok {
		writeError(w, http.StatusNotFound, "session is not attached to this service")
		return
	}

	var req struct {
		Approved bool `json:"approved"`
	}
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	if err := managed.answerPermission(r.PathValue("requestID"), req.Approved); err != nil {
		writeError(w, http.StatusNotFound, err.Error())
		return
	}

	writeJSON(w, http.StatusAccepted, map[string]any{"ok": true})
}

func (s *service) handleSetPermissionMode(w http.ResponseWriter, r *http.Request) {
	managed, ok := s.getManagedSession(r.PathValue("id"))
	if !ok {
		writeError(w, http.StatusNotFound, "session is not attached to this service")
		return
	}

	var req struct {
		Mode string `json:"mode"`
	}
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	if !isValidPermissionMode(req.Mode) {
		writeError(w, http.StatusBadRequest, "mode must be one of: interactive, approve-all, autopilot, reject-all")
		return
	}

	managed.permissionMode = req.Mode
	managed.broadcastHostEvent("host.permission_mode_changed", map[string]any{
		"sessionId": managed.session.SessionID,
		"mode":      req.Mode,
	})

	writeJSON(w, http.StatusOK, map[string]any{"sessionId": managed.session.SessionID, "mode": req.Mode})
}

// handleSetTools updates the locally-tracked excluded-tools list for the session.
// Note: this does not affect the active session in the SDK (tools are configured at
// session-creation time); the updated list is reflected in subsequent GET /sessions/{id}
// responses and will be used when the session is next resumed.
func (s *service) handleSetTools(w http.ResponseWriter, r *http.Request) {
	managed, ok := s.getManagedSession(r.PathValue("id"))
	if !ok {
		writeError(w, http.StatusNotFound, "session is not attached to this service")
		return
	}

	var req struct {
		ExcludedTools []string `json:"excludedTools"`
	}
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	managed.excludedTools = req.ExcludedTools
	managed.broadcastHostEvent("host.tools_changed", map[string]any{
		"sessionId":     managed.session.SessionID,
		"excludedTools": req.ExcludedTools,
	})

	writeJSON(w, http.StatusOK, map[string]any{
		"sessionId":     managed.session.SessionID,
		"excludedTools": req.ExcludedTools,
	})
}

func (s *service) liveSessionSummaries() []sessionSummary {
	s.sessionsMu.RLock()
	defer s.sessionsMu.RUnlock()

	items := make([]sessionSummary, 0, len(s.sessions))
	for _, managed := range s.sessions {
		items = append(items, managed.summary())
	}
	return items
}

func (s *service) resolveSessionWorkingDirectory(value string) (string, error) {
	if strings.TrimSpace(value) == "" {
		return s.defaultWorkingDirectory, nil
	}
	return resolveWorkingDirectory(value)
}

func (s *service) resolveRequestedModel(ctx context.Context, requested string) (string, error) {
	requested = strings.TrimSpace(requested)
	if requested == "" {
		return "", nil
	}

	models, err := s.client.ListModels(ctx)
	if err != nil {
		return "", err
	}

	if resolved, ok := resolveModelAlias(requested, models); ok {
		return resolved, nil
	}
	return requested, nil
}

func (s *service) getManagedSession(id string) (*managedSession, bool) {
	s.sessionsMu.RLock()
	defer s.sessionsMu.RUnlock()
	managed, ok := s.sessions[id]
	return managed, ok
}

func (s *service) storeManagedSession(managed *managedSession) {
	s.sessionsMu.Lock()
	defer s.sessionsMu.Unlock()
	s.sessions[managed.session.SessionID] = managed
}

func (s *service) removeManagedSession(id string) (*managedSession, bool) {
	s.sessionsMu.Lock()
	defer s.sessionsMu.Unlock()
	managed, ok := s.sessions[id]
	if ok {
		delete(s.sessions, id)
	}
	return managed, ok
}

func (s *service) disconnectAll() {
	s.sessionsMu.Lock()
	sessions := make([]*managedSession, 0, len(s.sessions))
	for id, managed := range s.sessions {
		sessions = append(sessions, managed)
		delete(s.sessions, id)
	}
	s.sessionsMu.Unlock()

	for _, managed := range sessions {
		managed.close(errors.New("service shutdown"))
	}
}

func (m *managedSession) handleSessionEvent(event copilot.SessionEvent) {
	payload, err := (&event).Marshal()
	if err != nil {
		return
	}
	m.broadcast(sseMessage{Event: "session.event", Data: payload})
}

func (m *managedSession) handlePermissionRequest(req copilot.PermissionRequest, inv copilot.PermissionInvocation) (copilot.PermissionRequestResult, error) {
	switch m.permissionMode {
	case permissionModeRejectAll:
		m.broadcastHostEvent("host.permission_decision", map[string]any{
			"sessionId": inv.SessionID, "request": req, "decision": "rejected", "mode": m.permissionMode,
		})
		return copilot.PermissionRequestResult{Kind: copilot.PermissionRequestResultKindRejected}, nil

	case permissionModeInteractive:
		pending := &pendingPermission{
			view: pendingPermissionView{
				ID:        fmt.Sprintf("perm-%d", time.Now().UnixNano()),
				Request:   req,
				CreatedAt: time.Now().UTC(),
			},
			resultCh: make(chan permissionResult, 1),
		}
		m.pendingPermissionsMu.Lock()
		m.pendingPermissions[pending.view.ID] = pending
		m.pendingPermissionsMu.Unlock()

		m.broadcastHostEvent("host.permission_requested", map[string]any{
			"sessionId": inv.SessionID, "request": pending.view, "mode": m.permissionMode,
		})

		defer func() {
			m.pendingPermissionsMu.Lock()
			delete(m.pendingPermissions, pending.view.ID)
			m.pendingPermissionsMu.Unlock()
		}()

		select {
		case result := <-pending.resultCh:
			if result.Err != nil {
				return copilot.PermissionRequestResult{Kind: copilot.PermissionRequestResultKindRejected}, result.Err
			}
			kind := copilot.PermissionRequestResultKindApproved
			decision := "approved"
			if !result.Approved {
				kind = copilot.PermissionRequestResultKindRejected
				decision = "rejected"
			}
			m.broadcastHostEvent("host.permission_decision", map[string]any{
				"sessionId": inv.SessionID, "requestId": pending.view.ID, "decision": decision, "mode": m.permissionMode,
			})
			return copilot.PermissionRequestResult{Kind: kind}, nil
		case <-time.After(m.inputResponseGrace):
			return copilot.PermissionRequestResult{Kind: copilot.PermissionRequestResultKindRejected},
				fmt.Errorf("timed out waiting for permission response %s", pending.view.ID)
		}

	default: // approve-all and autopilot
		m.broadcastHostEvent("host.permission_decision", map[string]any{
			"sessionId": inv.SessionID, "request": req, "decision": "approved", "mode": m.permissionMode,
		})
		return copilot.PermissionRequestResult{Kind: copilot.PermissionRequestResultKindApproved}, nil
	}
}

func (m *managedSession) handleUserInputRequest(req copilot.UserInputRequest, inv copilot.UserInputInvocation) (copilot.UserInputResponse, error) {
	// In autopilot mode, auto-answer with the first choice or empty string.
	if m.permissionMode == permissionModeAutopilot {
		answer := ""
		if len(req.Choices) > 0 {
			answer = req.Choices[0]
		}
		m.broadcastHostEvent("host.user_input_resolved", map[string]any{
			"sessionId": inv.SessionID, "auto": true, "answer": answer,
		})
		return copilot.UserInputResponse{Answer: answer, WasFreeform: false}, nil
	}

	pending := &pendingUserInput{
		view: pendingUserInputView{
			ID:            fmt.Sprintf("input-%d", time.Now().UnixNano()),
			Question:      req.Question,
			Choices:       req.Choices,
			AllowFreeform: boolOrDefault(req.AllowFreeform, true),
			CreatedAt:     time.Now().UTC(),
		},
		resultCh: make(chan userInputResult, 1),
	}

	m.pendingInputsMu.Lock()
	m.pendingInputs[pending.view.ID] = pending
	m.pendingInputsMu.Unlock()

	m.broadcastHostEvent("host.user_input_requested", map[string]any{
		"sessionId": inv.SessionID,
		"request":   pending.view,
	})

	defer func() {
		m.pendingInputsMu.Lock()
		delete(m.pendingInputs, pending.view.ID)
		m.pendingInputsMu.Unlock()
	}()

	select {
	case result := <-pending.resultCh:
		if result.Err != nil {
			return copilot.UserInputResponse{}, result.Err
		}
		m.broadcastHostEvent("host.user_input_resolved", map[string]any{
			"sessionId": inv.SessionID,
			"requestId": pending.view.ID,
		})
		return result.Response, nil
	case <-time.After(m.inputResponseGrace):
		return copilot.UserInputResponse{}, fmt.Errorf("timed out waiting for user input %s", pending.view.ID)
	}
}

func (m *managedSession) answerUserInput(requestID string, req answerUserInputRequest) error {
	m.pendingInputsMu.Lock()
	pending, ok := m.pendingInputs[requestID]
	if ok {
		delete(m.pendingInputs, requestID)
	}
	m.pendingInputsMu.Unlock()

	if !ok {
		return fmt.Errorf("pending user input %s was not found", requestID)
	}

	pending.resultCh <- userInputResult{Response: copilot.UserInputResponse{Answer: req.Answer, WasFreeform: req.WasFreeform}}
	return nil
}

func (m *managedSession) answerPermission(requestID string, approved bool) error {
	m.pendingPermissionsMu.Lock()
	pending, ok := m.pendingPermissions[requestID]
	if ok {
		delete(m.pendingPermissions, requestID)
	}
	m.pendingPermissionsMu.Unlock()

	if !ok {
		return fmt.Errorf("pending permission %s was not found", requestID)
	}

	pending.resultCh <- permissionResult{Approved: approved}
	return nil
}

func (m *managedSession) summary() sessionSummary {
	return sessionSummary{
		SessionID:         m.session.SessionID,
		Model:             m.model,
		WorkingDirectory:  m.workingDirectory,
		WorkspacePath:     m.session.WorkspacePath(),
		PermissionMode:    m.permissionMode,
		ExcludedTools:     m.excludedTools,
		Capabilities:      m.session.Capabilities(),
		PendingUserInputs: m.pendingUserInputsSnapshot(),
		Live:              true,
		CreatedAt:         m.createdAt,
		Resumed:           m.resumed,
		Streaming:         m.streaming,
		Agent:             m.agent,
		ConfigDiscovery:   m.configDiscovery,
		ClientName:        m.clientName,
	}
}

func (m *managedSession) pendingUserInputsSnapshot() []pendingUserInputView {
	m.pendingInputsMu.Lock()
	defer m.pendingInputsMu.Unlock()

	items := make([]pendingUserInputView, 0, len(m.pendingInputs))
	for _, pending := range m.pendingInputs {
		items = append(items, pending.view)
	}
	return items
}

func (m *managedSession) subscribe() chan sseMessage {
	ch := make(chan sseMessage, 64)
	m.subscribersMu.Lock()
	m.subscribers[ch] = struct{}{}
	m.subscribersMu.Unlock()
	return ch
}

func (m *managedSession) unsubscribe(ch chan sseMessage) {
	m.subscribersMu.Lock()
	if _, ok := m.subscribers[ch]; ok {
		delete(m.subscribers, ch)
		close(ch)
	}
	m.subscribersMu.Unlock()
}

func (m *managedSession) broadcastHostEvent(eventName string, payload any) {
	m.broadcast(sseMessage{Event: eventName, Data: mustJSON(hostEvent{Timestamp: time.Now().UTC(), Data: payload})})
}

func (m *managedSession) broadcast(msg sseMessage) {
	m.subscribersMu.RLock()
	defer m.subscribersMu.RUnlock()
	for ch := range m.subscribers {
		select {
		case ch <- msg:
		default:
		}
	}
}

func (m *managedSession) close(reason error) {
	if m.eventUnsubscribe != nil {
		m.eventUnsubscribe()
		m.eventUnsubscribe = nil
	}

	m.pendingInputsMu.Lock()
	for id, pending := range m.pendingInputs {
		delete(m.pendingInputs, id)
		pending.resultCh <- userInputResult{Err: reason}
	}
	m.pendingInputsMu.Unlock()

	m.pendingPermissionsMu.Lock()
	for id, pending := range m.pendingPermissions {
		delete(m.pendingPermissions, id)
		pending.resultCh <- permissionResult{Err: reason}
	}
	m.pendingPermissionsMu.Unlock()

	if m.session != nil {
		if err := m.session.Disconnect(); err != nil {
			log.Printf("disconnect session %s: %v", m.session.SessionID, err)
		}
	}

	m.subscribersMu.Lock()
	for ch := range m.subscribers {
		close(ch)
		delete(m.subscribers, ch)
	}
	m.subscribersMu.Unlock()
}

func resolveWorkingDirectory(value string) (string, error) {
	workingDirectory := strings.TrimSpace(value)
	if workingDirectory == "" {
		cwd, err := os.Getwd()
		if err != nil {
			return "", fmt.Errorf("get working directory: %w", err)
		}
		workingDirectory = cwd
	}

	resolved, err := filepath.Abs(workingDirectory)
	if err != nil {
		return "", fmt.Errorf("resolve working directory: %w", err)
	}
	return resolved, nil
}

func resolveModelAlias(requested string, models []copilot.ModelInfo) (string, bool) {
	requested = strings.TrimSpace(requested)
	if requested == "" {
		return "", false
	}

	var bestID string
	var bestVersion []int
	bestIsPlain := false
	foundFamilyAlias := false

	for _, model := range models {
		id := strings.TrimSpace(model.ID)
		if id == "" {
			continue
		}
		if strings.EqualFold(id, requested) {
			return id, true
		}

		version, isPlain, ok := parseVersionedModelAlias(requested, id)
		if !ok {
			continue
		}
		if !foundFamilyAlias || compareVersionParts(version, bestVersion) > 0 || (compareVersionParts(version, bestVersion) == 0 && isPlain && !bestIsPlain) {
			bestID = id
			bestVersion = version
			bestIsPlain = isPlain
			foundFamilyAlias = true
		}
	}

	if foundFamilyAlias {
		return bestID, true
	}
	return "", false
}

func parseVersionedModelAlias(requested, id string) ([]int, bool, bool) {
	prefix := requested + "."
	if !strings.HasPrefix(id, prefix) {
		return nil, false, false
	}

	remainder := strings.TrimPrefix(id, prefix)
	versionPart := remainder
	isPlain := true
	if idx := strings.Index(versionPart, "-"); idx >= 0 {
		versionPart = versionPart[:idx]
		isPlain = false
	}

	version, ok := parseNumericVersion(versionPart)
	if !ok {
		return nil, false, false
	}
	return version, isPlain, true
}

func parseNumericVersion(value string) ([]int, bool) {
	if value == "" {
		return nil, false
	}

	parts := strings.Split(value, ".")
	version := make([]int, 0, len(parts))
	for _, part := range parts {
		if part == "" {
			return nil, false
		}
		number, err := strconv.Atoi(part)
		if err != nil {
			return nil, false
		}
		version = append(version, number)
	}
	return version, true
}

func compareVersionParts(left, right []int) int {
	limit := max(len(right), len(left))

	for i := range limit {
		leftPart := 0
		if i < len(left) {
			leftPart = left[i]
		}
		rightPart := 0
		if i < len(right) {
			rightPart = right[i]
		}
		switch {
		case leftPart > rightPart:
			return 1
		case leftPart < rightPart:
			return -1
		}
	}
	return 0
}

func defaultCLIPath() string {
	if env := strings.TrimSpace(os.Getenv("COPILOT_CLI_PATH")); env != "" {
		return env
	}

	candidates := []string{
		filepath.Join("..", "..", "nodejs", "node_modules", "@github", "copilot", "index.js"),
		filepath.Join("..", "nodejs", "node_modules", "@github", "copilot", "index.js"),
		filepath.Join("nodejs", "node_modules", "@github", "copilot", "index.js"),
	}

	for _, candidate := range candidates {
		if _, err := os.Stat(candidate); err == nil {
			return candidate
		}
	}
	return ""
}

func loggingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		log.Printf("%s %s %s", r.Method, r.URL.Path, time.Since(start).Round(time.Millisecond))
	})
}

func withCORS(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type")
		w.Header().Set("Access-Control-Allow-Methods", "GET,POST,DELETE,OPTIONS")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(payload)
}

func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, map[string]any{"error": message})
}

func decodeJSON(r *http.Request, target any) error {
	defer r.Body.Close()
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return fmt.Errorf("decode JSON body: %w", err)
	}
	return nil
}

func writeSSE(w http.ResponseWriter, eventName string, payload []byte) error {
	if _, err := fmt.Fprintf(w, "event: %s\n", eventName); err != nil {
		return err
	}
	for line := range strings.SplitSeq(string(payload), "\n") {
		if _, err := fmt.Fprintf(w, "data: %s\n", line); err != nil {
			return err
		}
	}
	_, err := fmt.Fprint(w, "\n")
	return err
}

func mustJSON(payload any) []byte {
	data, err := json.Marshal(payload)
	if err != nil {
		return []byte(`{"error":"failed to marshal host event"}`)
	}
	return data
}

func queryBool(r *http.Request, name string) bool {
	value := strings.TrimSpace(strings.ToLower(r.URL.Query().Get(name)))
	return value == "1" || value == "true" || value == "yes"
}

func boolOrDefault(value *bool, fallback bool) bool {
	if value == nil {
		return fallback
	}
	return *value
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if trimmed := strings.TrimSpace(value); trimmed != "" {
			return trimmed
		}
	}
	return ""
}

func isValidPermissionMode(value string) bool {
	switch value {
	case permissionModeApproveAll, permissionModeRejectAll, permissionModeInteractive, permissionModeAutopilot:
		return true
	default:
		return false
	}
}

func newSessionID() string {
	return fmt.Sprintf("nvim-%d", time.Now().UnixNano())
}
