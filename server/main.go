// Copyright 2026 ray-x. All rights reserved.
// Use of this source code is governed by an Apache 2.0
// license that can be found in the LICENSE file.

package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io/fs"
	"log"
	"math"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	copilot "github.com/github/copilot-sdk/go"
	"github.com/github/copilot-sdk/go/rpc"
)

const (
	permissionModeApproveAll   = "approve-all"
	permissionModeRejectAll    = "reject-all"
	permissionModeInteractive  = "interactive"   // routes each request to the Neovim UI
	permissionModeAutopilot    = "autopilot"     // approve-all + auto-answer user inputs
	permissionModeApproveReads = "approve-reads" // auto-approve workspace reads; prompt for writes/shell
	defaultModel               = ""
	defaultClientName          = "neovim-copilot-service"
	defaultInputTimeout        = 15 * time.Minute
	httpReadHeaderTimeout      = 10 * time.Second // Long enough for local clients while still rejecting stalled connections promptly.
	httpShutdownTimeout        = 5 * time.Second  // Allow in-flight HTTP requests a brief grace period during service shutdown.
	sseKeepAliveInterval       = 15 * time.Second // Keep reverse proxies and clients from treating idle event streams as dead.
	clientLeasePollInterval    = 500 * time.Millisecond
	sseSubscriberBufferSize    = 256 // Absorb bursts of session events (tool calls can produce 100+ events rapidly).
	asyncResultChannelSize     = 1   // Each pending prompt/permission only needs to hold a single terminal response.
	permissionRequestIDPrefix  = "perm"
	userInputRequestIDPrefix   = "input"
	sessionIDPrefix            = "nvim"
	sessionIDPrefixMaxLen      = 8
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
	Attachments    []copilot.Attachment `json:"attachments,omitempty"`
	RequestHeaders map[string]string    `json:"requestHeaders,omitempty"`
}

type fleetStartRequest struct {
	Prompt string `json:"prompt,omitempty"`
}

type contextWindowSnapshot struct {
	CurrentTokens         int64 `json:"currentTokens"`
	TokenLimit            int64 `json:"tokenLimit"`
	PromptTokenLimit      int64 `json:"promptTokenLimit"`
	MessagesLength        int64 `json:"messagesLength"`
	SystemTokens          int64 `json:"systemTokens"`
	ToolDefinitionsTokens int64 `json:"toolDefinitionsTokens"`
	SystemToolsTokens     int64 `json:"systemToolsTokens"`
	ConversationTokens    int64 `json:"conversationTokens"`
	FreeTokens            int64 `json:"freeTokens"`
	BufferTokens          int64 `json:"bufferTokens"`
}

type contextWindowResponse struct {
	SessionID     string                 `json:"sessionId"`
	Available     bool                   `json:"available"`
	ContextWindow *contextWindowSnapshot `json:"contextWindow,omitempty"`
}

type compactHistoryRequest struct{}

type setModelRequest struct {
	Model           string `json:"model"`
	ReasoningEffort string `json:"reasoningEffort,omitempty"`
}

type answerUserInputRequest struct {
	Answer      string `json:"answer"`
	WasFreeform bool   `json:"wasFreeform,omitempty"`
}

type sessionSummary struct {
	SessionID         string                      `json:"sessionId"`
	Model             string                      `json:"model,omitempty"`
	AgentMode         string                      `json:"agentMode,omitempty"`
	WorkingDirectory  string                      `json:"workingDirectory,omitempty"`
	WorkspacePath     string                      `json:"workspacePath,omitempty"`
	PermissionMode    string                      `json:"permissionMode"`
	ExcludedTools     []string                    `json:"excludedTools,omitempty"`
	Capabilities      copilot.SessionCapabilities `json:"capabilities,omitempty"`
	PendingUserInputs []pendingUserInputView      `json:"pendingUserInputs,omitempty"`
	Summary           string                      `json:"summary,omitempty"`
	Live              bool                        `json:"live"`
	CreatedAt         time.Time                   `json:"createdAt"`
	Resumed           bool                        `json:"resumed"`
	Streaming         bool                        `json:"streaming"`
	Agent             string                      `json:"agent,omitempty"`
	ConfigDiscovery   bool                        `json:"configDiscovery"`
	ClientName        string                      `json:"clientName,omitempty"`
	InstructionCount  int                         `json:"instructionCount,omitempty"`
	AgentCount        int                         `json:"agentCount,omitempty"`
	SkillCount        int                         `json:"skillCount,omitempty"`
	MCPCount          int                         `json:"mcpCount,omitempty"`
}

type listSessionsResponse struct {
	Persisted []copilot.SessionMetadata `json:"persisted"`
	Live      []sessionSummary          `json:"live"`
}

type backgroundTaskView struct {
	ID             string     `json:"id"`
	Kind           string     `json:"kind"`
	Status         string     `json:"status"`
	Title          string     `json:"title,omitempty"`
	Description    string     `json:"description,omitempty"`
	Summary        string     `json:"summary,omitempty"`
	Prompt         string     `json:"prompt,omitempty"`
	AgentID        string     `json:"agentId,omitempty"`
	AgentType      string     `json:"agentType,omitempty"`
	AgentName      string     `json:"agentName,omitempty"`
	ToolCallID     string     `json:"toolCallId,omitempty"`
	EntryID        string     `json:"entryId,omitempty"`
	Error          string     `json:"error,omitempty"`
	Model          string     `json:"model,omitempty"`
	UpdatedAt      time.Time  `json:"updatedAt"`
	StartedAt      *time.Time `json:"startedAt,omitempty"`
	CompletedAt    *time.Time `json:"completedAt,omitempty"`
	DurationMs     *float64   `json:"durationMs,omitempty"`
	TotalTokens    *float64   `json:"totalTokens,omitempty"`
	TotalToolCalls *float64   `json:"totalToolCalls,omitempty"`
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
	agentMode            string // "interactive", "plan", or "autopilot"
	workingDirectory     string
	permissionMode       string
	excludedTools        []string
	sessionName          string // auto-generated session name provided by the SDK after each turn
	createdAt            time.Time
	resumed              bool
	streaming            bool
	agent                string
	configDiscovery      bool
	clientName           string
	instructionCount     int
	agentCount           int
	skillCount           int
	mcpCount             int
	subscribers          map[chan sseMessage]struct{}
	subscribersMu        sync.RWMutex
	pendingInputs        map[string]*pendingUserInput
	pendingInputsMu      sync.Mutex
	pendingPermissions   map[string]*pendingPermission
	pendingPermissionsMu sync.Mutex
	eventSequenceMu      sync.Mutex
	nextEventSequence    uint64
	messageChunkIndexes  map[string]uint64
	contextUsage         *contextWindowUsage
	contextUsageMu       sync.RWMutex
	eventUnsubscribe     func()
	inputResponseGrace   time.Duration
}

type contextWindowUsage struct {
	CurrentTokens         int64
	TokenLimit            int64
	MessagesLength        int64
	SystemTokens          int64
	ToolDefinitionsTokens int64
	ConversationTokens    int64
}

type copilotClient interface {
	Start(context.Context) error
	Stop() error
	ForceStop()
	State() copilot.ConnectionState
	ListModels(context.Context) ([]copilot.ModelInfo, error)
	ListSessions(context.Context, *copilot.SessionListFilter) ([]copilot.SessionMetadata, error)
	GetSessionMetadata(context.Context, string) (*copilot.SessionMetadata, error)
	CreateSession(context.Context, *copilot.SessionConfig) (*copilot.Session, error)
	ResumeSession(context.Context, string, *copilot.ResumeSessionConfig) (*copilot.Session, error)
	DeleteSession(context.Context, string) error
	OnEventType(copilot.SessionLifecycleEventType, copilot.SessionLifecycleHandler) func()
}

type service struct {
	clientMu                sync.RWMutex
	client                  copilotClient
	clientFactory           func() copilotClient
	clientCtx               context.Context
	defaultModel            string
	defaultWorkingDirectory string
	shutdownHTTP            func(context.Context) error
	sessions                map[string]*managedSession
	sessionsMu              sync.RWMutex
}

func main() {
	addr := flag.String("addr", "", "HTTP listen address (host:port). Leave empty or use port 0 to let the OS assign a free port (default).")
	portRange := flag.String("port-range", "", "Port range to try when -addr is not set, e.g. 18000-19000. The first available port in the range is used.")
	controlSocket := flag.String("control-socket", "", "Unix socket path for local control API (GET /service-addr, GET /healthz, POST /shutdown)")
	controlAddr := flag.String("control-addr", "", "TCP listen address for local control API (use on Windows, e.g. 127.0.0.1:0)")
	clientLeaseDir := flag.String("client-lease-dir", "", "Neovim client lease directory used to self-stop detached services when no clients remain")
	cliPath := flag.String("cli-path", defaultCLIPath(), "path to Copilot CLI binary or JS entrypoint")
	cliURL := flag.String("cli-url", "", "URL for an already-running Copilot CLI server")
	model := flag.String("model", defaultModel, "default model for new sessions; empty uses the Copilot CLI account default")
	logLevel := flag.String("log-level", "error", "Copilot CLI log level")
	cwdFlag := flag.String("cwd", "", "default working directory for new sessions")
	lspMode := flag.Bool("lsp", true, "run LSP server over stdio alongside the HTTP service (default: true)")
	lspOnly := flag.Bool("lsp-only", false, "run only the LSP server over stdio and connect to an existing HTTP service")
	serviceURL := flag.String("service-url", "", "HTTP service URL for -lsp-only mode, e.g. http://127.0.0.1:8088")
	flag.Parse()

	if *lspOnly {
		if strings.TrimSpace(*serviceURL) == "" {
			log.Fatal("service-url is required when -lsp-only is set")
		}
		ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
		defer stop()
		if err := runLSPServer(ctx, strings.TrimSpace(*serviceURL)); err != nil && err != context.Canceled {
			log.Fatal(err)
		}
		return
	}

	workingDirectory, err := resolveWorkingDirectory(*cwdFlag)
	if err != nil {
		log.Fatal(err)
	}

	clientOptions := copilot.ClientOptions{
		CLIPath:  strings.TrimSpace(*cliPath),
		CLIUrl:   strings.TrimSpace(*cliURL),
		Cwd:      workingDirectory,
		LogLevel: *logLevel,
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	svc := &service{
		clientCtx: ctx,
		clientFactory: func() copilotClient {
			return copilot.NewClient(&clientOptions)
		},
		defaultModel:            strings.TrimSpace(*model),
		defaultWorkingDirectory: workingDirectory,
		sessions:                make(map[string]*managedSession),
	}

	if err = svc.startCopilotClient(); err != nil {
		log.Fatal(err)
	}
	defer func() {
		if err := svc.stopCopilotClient(); err != nil {
			log.Printf("stop copilot client: %v", err)
		}
	}()

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", svc.handleHealth)
	mux.HandleFunc("GET /models", svc.handleListModels)
	mux.HandleFunc("GET /sessions", svc.handleListSessions)
	mux.HandleFunc("POST /sessions", svc.handleCreateSession)
	mux.HandleFunc("GET /sessions/{id}", svc.handleGetSession)
	mux.HandleFunc("GET /sessions/{id}/context", svc.handleGetContext)
	mux.HandleFunc("DELETE /sessions/{id}", svc.handleDeleteSession)
	mux.HandleFunc("POST /sessions/{id}/model", svc.handleSetModel)
	mux.HandleFunc("POST /sessions/{id}/mode", svc.handleSetAgentMode)
	mux.HandleFunc("GET /sessions/{id}/messages", svc.handleGetMessages)
	mux.HandleFunc("GET /sessions/{id}/tasks", svc.handleGetTasks)
	mux.HandleFunc("POST /sessions/{id}/messages", svc.handleSendMessage)
	mux.HandleFunc("POST /sessions/{id}/compact", svc.handleCompactHistory)
	mux.HandleFunc("POST /sessions/{id}/fleet", svc.handleStartFleet)
	mux.HandleFunc("GET /sessions/{id}/events", svc.handleEvents)
	mux.HandleFunc("POST /sessions/{id}/user-input/{requestID}", svc.handleAnswerUserInput)
	mux.HandleFunc("POST /sessions/{id}/permission/{requestID}", svc.handleAnswerPermission)
	mux.HandleFunc("POST /sessions/{id}/permission-mode", svc.handleSetPermissionMode)
	mux.HandleFunc("POST /sessions/{id}/abort", svc.handleAbortSession)
	mux.HandleFunc("POST /sessions/{id}/tools", svc.handleSetTools)
	mux.HandleFunc("POST /shutdown", svc.handleShutdown)

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
		ReadHeaderTimeout: httpReadHeaderTimeout,
	}
	svc.shutdownHTTP = server.Shutdown
	controlCleanup := func() {}
	socketPath := strings.TrimSpace(*controlSocket)
	controlListenAddr := strings.TrimSpace(*controlAddr)
	switch {
	case socketPath != "":
		cleanup, controlErr := startControlServer(ctx, svc, "unix", socketPath, "", boundAddr)
		if controlErr != nil {
			log.Fatalf("start control socket %s: %v", socketPath, controlErr)
		}
		controlCleanup = cleanup
		defer controlCleanup()
	case controlListenAddr != "":
		cleanup, controlErr := startControlServer(ctx, svc, "tcp", "", controlListenAddr, boundAddr)
		if controlErr != nil {
			log.Fatalf("start control listener %s: %v", controlListenAddr, controlErr)
		}
		controlCleanup = cleanup
		defer controlCleanup()
	case runtime.GOOS == "windows":
		cleanup, controlErr := startControlServer(ctx, svc, "tcp", "", "127.0.0.1:0", boundAddr)
		if controlErr != nil {
			log.Fatalf("start control listener: %v", controlErr)
		}
		controlCleanup = cleanup
		defer controlCleanup()
	}

	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), httpShutdownTimeout)
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

	startClientLeaseWatcher(ctx, strings.TrimSpace(*clientLeaseDir), stop)

	// Print the machine-readable address to stderr so it doesn't pollute the
	// LSP stdio stream. The Neovim plugin reads it from on_stderr.
	fmt.Fprintf(os.Stderr, "COPILOT_AGENT_ADDR=%s\n", boundAddr)

	if err := server.Serve(listener); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}

func startControlServer(ctx context.Context, svc *service, network string, socketPath string, listenAddr string, serviceAddr string) (func(), error) {
	if network == "unix" {
		if err := os.MkdirAll(filepath.Dir(socketPath), 0o700); err != nil {
			return nil, err
		}
		if err := os.Remove(socketPath); err != nil && !errors.Is(err, os.ErrNotExist) {
			return nil, err
		}
	}

	ln, err := net.Listen(network, firstNonEmpty(listenAddr, socketPath))
	if err != nil {
		return nil, err
	}
	if network == "unix" {
		if chmodErr := os.Chmod(socketPath, 0o600); chmodErr != nil {
			ln.Close()
			_ = os.Remove(socketPath)
			return nil, chmodErr
		}
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /service-addr", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{
			"serviceAddr": serviceAddr,
			"serviceURL":  "http://" + serviceAddr,
		})
	})
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{
			"ok":          true,
			"serviceAddr": serviceAddr,
		})
	})
	mux.HandleFunc("POST /shutdown", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
		if svc.shutdownHTTP == nil {
			return
		}
		go func() {
			shutdownCtx, cancel := context.WithTimeout(context.Background(), httpShutdownTimeout)
			defer cancel()
			if err := svc.shutdownHTTP(shutdownCtx); err != nil && !errors.Is(err, http.ErrServerClosed) {
				log.Printf("shutdown via control socket: %v", err)
			}
		}()
	})

	controlServer := &http.Server{
		Handler:           mux,
		ReadHeaderTimeout: httpReadHeaderTimeout,
	}

	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), httpShutdownTimeout)
		defer cancel()
		_ = controlServer.Shutdown(shutdownCtx)
	}()

	go func() {
		if serveErr := controlServer.Serve(ln); serveErr != nil && !errors.Is(serveErr, http.ErrServerClosed) {
			log.Printf("control socket server: %v", serveErr)
		}
	}()

	if network != "unix" {
		fmt.Fprintf(os.Stderr, "COPILOT_AGENT_CONTROL_ADDR=%s\n", ln.Addr().String())
	}

	return func() {
		_ = controlServer.Close()
		_ = ln.Close()
		if network == "unix" {
			_ = os.Remove(socketPath)
		}
	}, nil
}

func startClientLeaseWatcher(ctx context.Context, leaseDir string, stop func()) {
	leaseDir = strings.TrimSpace(leaseDir)
	if leaseDir == "" || stop == nil {
		return
	}

	go func() {
		ticker := time.NewTicker(clientLeasePollInterval)
		defer ticker.Stop()

		seenLease := false
		shutdown := func(reason string) {
			log.Printf("client lease dir empty (%s); shutting down detached service", reason)
			stop()
		}

		check := func() (bool, string) {
			entries, err := os.ReadDir(leaseDir)
			if err != nil {
				if errors.Is(err, os.ErrNotExist) {
					if seenLease {
						return true, "missing"
					}
					return false, "missing"
				}
				log.Printf("watch client leases %s: %v", leaseDir, err)
				return false, "error"
			}
			if len(entries) > 0 {
				seenLease = true
				return false, "live"
			}
			if seenLease {
				return true, "empty"
			}
			return false, "empty"
		}

		if shouldStop, reason := check(); shouldStop {
			shutdown(reason)
			return
		}

		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				if shouldStop, reason := check(); shouldStop {
					shutdown(reason)
					return
				}
			}
		}
	}()
}

func (s *service) currentClient() copilotClient {
	s.clientMu.RLock()
	defer s.clientMu.RUnlock()
	return s.client
}

func (s *service) attachClientLifecycleHandlers(client copilotClient) {
	// Track session name updates from the SDK. The SDK auto-generates a summary
	// after each turn and delivers it via a SessionLifecycleUpdated event.
	client.OnEventType(copilot.SessionLifecycleUpdated, func(event copilot.SessionLifecycleEvent) {
		if event.Metadata == nil || event.Metadata.Summary == nil {
			return
		}
		s.sessionsMu.RLock()
		managed, ok := s.sessions[event.SessionID]
		s.sessionsMu.RUnlock()
		if !ok {
			return
		}
		name := *event.Metadata.Summary
		managed.sessionName = name
		managed.broadcastHostEvent("host.session_name_updated", map[string]string{
			"sessionId": event.SessionID,
			"name":      name,
		})
	})
}

func (s *service) startCopilotClient() error {
	s.clientMu.Lock()
	defer s.clientMu.Unlock()
	return s.startCopilotClientLocked()
}

func (s *service) startCopilotClientLocked() error {
	if s.clientFactory == nil {
		return errors.New("copilot client factory is not configured")
	}
	if s.clientCtx == nil {
		return errors.New("copilot client context is not configured")
	}
	client := s.clientFactory()
	if client == nil {
		return errors.New("copilot client factory returned nil")
	}
	if err := client.Start(s.clientCtx); err != nil {
		return fmt.Errorf("start copilot client: %w", err)
	}
	s.attachClientLifecycleHandlers(client)
	s.client = client
	return nil
}

func (s *service) stopCopilotClient() error {
	s.clientMu.Lock()
	client := s.client
	s.client = nil
	s.clientMu.Unlock()
	if client == nil {
		return nil
	}
	return client.Stop()
}

func (s *service) ensureClientConnected() error {
	client := s.currentClient()
	if client != nil && client.State() == copilot.StateConnected {
		return nil
	}
	return s.restartCopilotClient(errors.New("copilot client is disconnected"), false)
}

func (s *service) restartCopilotClient(reason error, force bool) error {
	s.clientMu.Lock()
	defer s.clientMu.Unlock()

	if !force && s.client != nil && s.client.State() == copilot.StateConnected {
		return nil
	}

	oldClient := s.client
	s.client = nil
	if oldClient != nil {
		log.Printf("restarting Copilot CLI client after failure: %v", reason)
		oldClient.ForceStop()
		s.closeManagedSessions(fmt.Errorf("copilot client restarted: %w", reason))
	}

	return s.startCopilotClientLocked()
}

func isRecoverableCopilotClientError(err error) bool {
	if err == nil {
		return false
	}
	message := strings.ToLower(err.Error())
	switch {
	case strings.Contains(message, "cli process exited"),
		strings.Contains(message, "process exited unexpectedly"),
		strings.Contains(message, "client not connected"),
		strings.Contains(message, "client stopped"):
		return true
	default:
		return false
	}
}

func withCopilotClientRetry[T any](s *service, operation string, fn func(copilotClient) (T, error)) (T, error) {
	var zero T

	if err := s.ensureClientConnected(); err != nil {
		return zero, err
	}
	client := s.currentClient()
	if client == nil {
		return zero, errors.New("copilot client is unavailable")
	}

	result, err := fn(client)
	if err == nil || !isRecoverableCopilotClientError(err) {
		return result, err
	}

	if restartErr := s.restartCopilotClient(fmt.Errorf("%s: %w", operation, err), true); restartErr != nil {
		return zero, errors.Join(err, fmt.Errorf("restart copilot client: %w", restartErr))
	}
	client = s.currentClient()
	if client == nil {
		return zero, err
	}
	return fn(client)
}

func (s *service) handleHealth(w http.ResponseWriter, r *http.Request) {
	if err := s.ensureClientConnected(); err != nil {
		writeError(w, http.StatusServiceUnavailable, fmt.Sprintf("copilot client unavailable: %v", err))
		return
	}
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
	models, err := withCopilotClientRetry(s, "list models", func(client copilotClient) ([]copilot.ModelInfo, error) {
		return client.ListModels(r.Context())
	})
	if err != nil {
		writeError(w, http.StatusBadGateway, fmt.Sprintf("list models: %v", err))
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{"models": models})
}

func (s *service) handleListSessions(w http.ResponseWriter, r *http.Request) {
	persisted, err := withCopilotClientRetry(s, "list sessions", func(client copilotClient) ([]copilot.SessionMetadata, error) {
		return client.ListSessions(r.Context(), nil)
	})
	if err != nil {
		writeError(w, http.StatusInternalServerError, fmt.Sprintf("list sessions: %v", err))
		return
	}

	persisted = enrichPersistedSessionsFromWorkspace(persisted, defaultSessionStateDir())
	live := s.liveSessionSummaries()
	writeJSON(w, http.StatusOK, listSessionsResponse{Persisted: persisted, Live: live})
}

func (s *service) handleCreateSession(w http.ResponseWriter, r *http.Request) {
	var req createSessionRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	var workingDirectory string
	if req.SessionID == "" {
		resolvedWorkingDirectory, err := s.resolveSessionWorkingDirectory(req.WorkingDirectory)
		if err != nil {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}
		workingDirectory = resolvedWorkingDirectory
		req.SessionID = newSessionID(workingDirectory)
	}

	if req.PermissionMode == "" {
		req.PermissionMode = permissionModeApproveAll
	}
	if !isValidPermissionMode(req.PermissionMode) {
		writeError(w, http.StatusBadRequest, "permissionMode must be one of: interactive, approve-all, approve-reads, autopilot, reject-all")
		return
	}

	if existing, ok := s.getManagedSession(req.SessionID); ok {
		if req.PermissionMode != "" && req.PermissionMode != existing.permissionMode {
			existing.permissionMode = req.PermissionMode
			existing.broadcastHostEvent("host.permission_mode_changed", map[string]any{
				"sessionId": req.SessionID,
				"mode":      req.PermissionMode,
			})
		}
		writeJSON(w, http.StatusOK, existing.summary())
		return
	}

	if workingDirectory == "" {
		var err error
		workingDirectory, err = s.resolveSessionWorkingDirectory(req.WorkingDirectory)
		if err != nil {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}
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
		model:               model,
		workingDirectory:    workingDirectory,
		permissionMode:      req.PermissionMode,
		excludedTools:       req.ExcludedTools,
		createdAt:           time.Now().UTC(),
		resumed:             req.Resume,
		streaming:           streaming,
		agent:               req.Agent,
		configDiscovery:     configDiscovery,
		clientName:          clientName,
		subscribers:         make(map[chan sseMessage]struct{}),
		pendingInputs:       make(map[string]*pendingUserInput),
		pendingPermissions:  make(map[string]*pendingPermission),
		messageChunkIndexes: make(map[string]uint64),
		inputResponseGrace:  defaultInputTimeout,
	}
	if configDiscovery {
		managed.instructionCount, managed.agentCount, managed.skillCount, managed.mcpCount = countDiscoverableConfig(workingDirectory)
	}

	// Pre-populate the session name from persisted metadata so it's available
	// immediately in the statusline without waiting for the next turn.
	if req.Resume {
		if meta, metaErr := withCopilotClientRetry(s, "get session metadata", func(client copilotClient) (*copilot.SessionMetadata, error) {
			return client.GetSessionMetadata(r.Context(), req.SessionID)
		}); metaErr == nil && meta != nil && meta.Summary != nil {
			managed.sessionName = *meta.Summary
		}
	}

	var session *copilot.Session
	if req.Resume {
		session, err = withCopilotClientRetry(s, "resume session", func(client copilotClient) (*copilot.Session, error) {
			return client.ResumeSession(r.Context(), req.SessionID, &copilot.ResumeSessionConfig{
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
		})
		if err != nil {
			writeError(w, http.StatusBadGateway, fmt.Sprintf("resume session: %v", err))
			return
		}
		managed.session = session
		managed.eventUnsubscribe = session.On(managed.handleSessionEvent)
	} else {
		session, err = withCopilotClientRetry(s, "create session", func(client copilotClient) (*copilot.Session, error) {
			return client.CreateSession(r.Context(), &copilot.SessionConfig{
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
	s.refreshManagedSessionSummary(r.Context(), managed)
	writeJSON(w, http.StatusOK, managed.summary())
}

func (s *service) handleGetContext(w http.ResponseWriter, r *http.Request) {
	managed, ok := s.getManagedSession(r.PathValue("id"))
	if !ok {
		writeError(w, http.StatusNotFound, "session is not attached to this service")
		return
	}

	usage := managed.getContextUsage()
	if usage == nil {
		writeJSON(w, http.StatusOK, contextWindowResponse{
			SessionID: managed.session.SessionID,
			Available: false,
		})
		return
	}

	breakdown := s.buildContextWindowSnapshot(r.Context(), managed, usage)
	writeJSON(w, http.StatusOK, contextWindowResponse{
		SessionID:     managed.session.SessionID,
		Available:     true,
		ContextWindow: breakdown,
	})
}

func (s *service) refreshManagedSessionSummary(ctx context.Context, managed *managedSession) {
	if managed == nil || managed.session == nil {
		return
	}

	meta, err := withCopilotClientRetry(s, "get session metadata", func(client copilotClient) (*copilot.SessionMetadata, error) {
		return client.GetSessionMetadata(ctx, managed.session.SessionID)
	})
	if err != nil || meta == nil || meta.Summary == nil {
		return
	}

	managed.sessionName = strings.TrimSpace(*meta.Summary)
}

func (s *service) handleDeleteSession(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	deleteState := queryBool(r, "delete")

	managed, ok := s.removeManagedSession(id)
	if !ok {
		if deleteState {
			if err := s.ensureClientConnected(); err != nil {
				writeError(w, http.StatusServiceUnavailable, fmt.Sprintf("copilot client unavailable: %v", err))
				return
			}
			if err := s.currentClient().DeleteSession(r.Context(), id); err != nil {
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
		if err := s.ensureClientConnected(); err != nil {
			writeError(w, http.StatusServiceUnavailable, fmt.Sprintf("copilot client unavailable: %v", err))
			return
		}
		if err := s.currentClient().DeleteSession(r.Context(), id); err != nil {
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
	var setOpts *copilot.SetModelOptions
	if re := strings.TrimSpace(req.ReasoningEffort); re != "" {
		setOpts = &copilot.SetModelOptions{ReasoningEffort: &re}
	}
	if err := managed.session.SetModel(r.Context(), model, setOpts); err != nil {
		writeError(w, http.StatusBadGateway, fmt.Sprintf("set model: %v", err))
		return
	}

	managed.model = model
	evt := map[string]any{
		"sessionId": managed.session.SessionID,
		"model":     model,
	}
	if req.ReasoningEffort != "" {
		evt["reasoningEffort"] = req.ReasoningEffort
	}
	managed.broadcastHostEvent("host.model_changed", evt)

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

func (s *service) handleGetTasks(w http.ResponseWriter, r *http.Request) {
	managed, ok := s.getManagedSession(r.PathValue("id"))
	if !ok {
		writeError(w, http.StatusNotFound, "session is not attached to this service")
		return
	}

	events, err := managed.session.GetMessages(r.Context())
	if err != nil {
		writeError(w, http.StatusBadGateway, fmt.Sprintf("get tasks: %v", err))
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{"tasks": extractBackgroundTasks(events)})
}

func (s *service) handleAbortSession(w http.ResponseWriter, r *http.Request) {
	managed, ok := s.getManagedSession(r.PathValue("id"))
	if !ok {
		writeError(w, http.StatusNotFound, "session is not attached to this service")
		return
	}
	if err := managed.session.Abort(r.Context()); err != nil {
		writeError(w, http.StatusInternalServerError, fmt.Sprintf("abort: %v", err))
		return
	}
	managed.broadcastHostEvent("host.turn_aborted", map[string]any{"sessionId": r.PathValue("id")})
	writeJSON(w, http.StatusAccepted, map[string]any{"ok": true})
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
		RequestHeaders: req.RequestHeaders,
	})
	if err != nil {
		writeError(w, http.StatusBadGateway, fmt.Sprintf("send message: %v", err))
		return
	}

	writeJSON(w, http.StatusAccepted, map[string]any{"sessionId": managed.session.SessionID, "messageId": messageID})
}

func (s *service) handleCompactHistory(w http.ResponseWriter, r *http.Request) {
	managed, ok := s.getManagedSession(r.PathValue("id"))
	if !ok {
		writeError(w, http.StatusNotFound, "session is not attached to this service")
		return
	}

	var req compactHistoryRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	result, err := managed.session.RPC.History.Compact(r.Context())
	if err != nil {
		writeError(w, http.StatusBadGateway, fmt.Sprintf("compact history: %v", err))
		return
	}
	if result != nil && result.ContextWindow != nil {
		managed.setContextUsage(contextWindowUsageFromCompact(result.ContextWindow))
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"sessionId": managed.session.SessionID,
		"result":    result,
	})
}

func (s *service) handleStartFleet(w http.ResponseWriter, r *http.Request) {
	managed, ok := s.getManagedSession(r.PathValue("id"))
	if !ok {
		writeError(w, http.StatusNotFound, "session is not attached to this service")
		return
	}

	var req fleetStartRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	var params *rpc.FleetStartRequest
	if prompt := strings.TrimSpace(req.Prompt); prompt != "" {
		params = &rpc.FleetStartRequest{Prompt: &prompt}
	}

	result, err := managed.session.RPC.Fleet.Start(r.Context(), params)
	if err != nil {
		writeError(w, http.StatusBadGateway, fmt.Sprintf("start fleet: %v", err))
		return
	}

	started := result != nil && result.Started
	if started {
		managed.broadcastHostEvent("host.fleet_started", map[string]any{
			"sessionId": managed.session.SessionID,
			"prompt":    strings.TrimSpace(req.Prompt),
			"started":   true,
		})
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"sessionId": managed.session.SessionID,
		"started":   started,
	})
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

	sub := managed.subscribe()
	defer managed.unsubscribe(sub)
	s.refreshManagedSessionSummary(r.Context(), managed)

	if err := writeSSE(w, "host.session_attached", mustJSON(hostEvent{Timestamp: time.Now().UTC(), Data: managed.summary()})); err != nil {
		return
	}
	flusher.Flush()

	if queryBool(r, "history") {
		replayPermissionHistory := queryBool(r, "replay_permission_history")
		replayTurnLimit := historyReplayTurnLimit(r)
		replayActivityLimit := historyReplayActivityTurnLimit(r)
		replayPreviewChars := historyReplayPreviewChars(r)
		events, err := managed.session.GetMessages(r.Context())
		if err != nil {
			writeError(w, http.StatusBadGateway, fmt.Sprintf("get history: %v", err))
			return
		}
		payloads, replayedCount := managed.marshalReplaySessionEvents(events, replayPermissionHistory, replayTurnLimit, replayActivityLimit, replayPreviewChars)
		for _, payload := range payloads {
			if err := writeSSE(w, "session.event", payload); err != nil {
				return
			}
		}
		// Signal that history replay is complete so clients can batch-render once.
		if err := writeSSE(w, "host.history_done", mustJSON(hostEvent{
			Timestamp: time.Now().UTC(),
			Data:      map[string]any{"sessionId": managed.session.SessionID, "count": replayedCount},
		})); err != nil {
			return
		}
		flusher.Flush()
	}

	keepAlive := time.NewTicker(sseKeepAliveInterval)
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
			// Drain any additional buffered messages before flushing to
			// reduce channel back-pressure during event bursts.
		drain:
			for {
				select {
				case msg, ok = <-sub:
					if !ok {
						flusher.Flush()
						return
					}
					if err := writeSSE(w, msg.Event, msg.Data); err != nil {
						return
					}
				default:
					break drain
				}
			}
			flusher.Flush()
		}
	}
}

func shouldReplayHistoryEvent(event copilot.SessionEvent, replayPermissionHistory bool) bool {
	if event.Type == "permission.requested" || event.Type == "permission.completed" {
		if replayPermissionHistory {
			return true
		}
		return false
	}
	if event.Type != copilot.SessionEventTypeAssistantMessage {
		return true
	}
	data, ok := event.Data.(*copilot.AssistantMessageData)
	if !ok {
		return true
	}
	return strings.TrimSpace(data.Content) != "" || len(data.ToolRequests) > 0
}

func historyReplayTurnLimit(r *http.Request) int {
	return queryInt(r, "history_turn_limit")
}

func historyReplayActivityTurnLimit(r *http.Request) int {
	return queryInt(r, "history_activity_turn_limit")
}

func historyReplayPreviewChars(r *http.Request) int {
	value := queryInt(r, "history_preview_chars")
	if value > 0 {
		return value
	}
	return 120
}

func selectReplayWindow(events []copilot.SessionEvent, turnLimit int) []copilot.SessionEvent {
	if turnLimit <= 0 {
		return events
	}

	turnCount := 0
	for _, event := range events {
		if event.Type == "assistant.turn_start" {
			turnCount++
		}
	}
	if turnCount <= turnLimit {
		return events
	}

	keepTurns := turnLimit
	cutoffTurns := turnCount - keepTurns
	seenTurns := 0
	startIndex := 0
	for idx, event := range events {
		if event.Type != "assistant.turn_start" {
			continue
		}
		seenTurns++
		if seenTurns > cutoffTurns {
			startIndex = idx
			break
		}
	}
	if startIndex <= 0 {
		return events
	}
	return events[startIndex:]
}

func truncateRunes(text string, maxChars int) string {
	if maxChars <= 0 {
		return ""
	}
	runes := []rune(text)
	if len(runes) <= maxChars {
		return text
	}
	if maxChars <= 3 {
		return string(runes[:maxChars])
	}
	return string(runes[:maxChars-3]) + "..."
}

func previewString(value any, maxChars int) string {
	switch v := value.(type) {
	case string:
		return truncateRunes(strings.TrimSpace(v), maxChars)
	case []any:
		parts := make([]string, 0, len(v))
		for _, item := range v {
			if preview := previewString(item, maxChars); preview != "" {
				parts = append(parts, preview)
			}
		}
		return truncateRunes(strings.Join(parts, "\n\n"), maxChars)
	case map[string]any:
		for _, key := range []string{"detailedContent", "content", "text", "output", "message", "value"} {
			if s, ok := v[key].(string); ok && strings.TrimSpace(s) != "" {
				return truncateRunes(strings.TrimSpace(s), maxChars)
			}
		}
		if nested, ok := v["contents"]; ok {
			return previewString(nested, maxChars)
		}
	}
	return ""
}

func trimReplayPayload(payload []byte, eventType string, summaryMode bool, previewChars int) ([]byte, bool, error) {
	var envelope map[string]any
	if err := json.Unmarshal(payload, &envelope); err != nil {
		return payload, false, err
	}

	data, _ := envelope["data"].(map[string]any)
	if data == nil {
		return payload, false, nil
	}

	switch eventType {
	case "assistant.message_delta", "assistant.streaming_delta", "assistant.reasoning_delta", "tool.execution_partial_result", "tool.execution_progress":
		if summaryMode {
			return nil, true, nil
		}
	case "tool.execution_complete":
		if result, ok := data["result"].(map[string]any); ok {
			preview := previewString(result, previewChars)
			if preview != "" {
				result = map[string]any{"content": truncateRunes(preview, previewChars)}
				data["result"] = result
			}
		}
	}

	envelope["data"] = data
	trimmed, err := json.Marshal(envelope)
	if err != nil {
		return nil, false, err
	}
	return trimmed, false, nil
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
		writeError(w, http.StatusBadRequest, "mode must be one of: interactive, approve-all, approve-reads, autopilot, reject-all")
		return
	}

	managed.permissionMode = req.Mode
	managed.broadcastHostEvent("host.permission_mode_changed", map[string]any{
		"sessionId": managed.session.SessionID,
		"mode":      req.Mode,
	})

	writeJSON(w, http.StatusOK, map[string]any{"sessionId": managed.session.SessionID, "mode": req.Mode})
}

// handleSetAgentMode changes the agent mode (interactive / plan / autopilot) for a session
// by calling the SDK's session.mode.set RPC.
func (s *service) handleSetAgentMode(w http.ResponseWriter, r *http.Request) {
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

	sdkMode, ok := toSDKAgentMode(req.Mode)
	if !ok {
		writeError(w, http.StatusBadRequest, "mode must be one of: ask, plan, agent (or: interactive, plan, autopilot)")
		return
	}

	if _, err := managed.session.RPC.Mode.Set(r.Context(), &rpc.ModeSetRequest{Mode: sdkMode}); err != nil {
		writeError(w, http.StatusBadGateway, fmt.Sprintf("set agent mode: %v", err))
		return
	}

	managed.agentMode = req.Mode
	managed.broadcastHostEvent("host.agent_mode_changed", map[string]any{
		"sessionId": managed.session.SessionID,
		"mode":      req.Mode,
	})

	writeJSON(w, http.StatusOK, map[string]any{"sessionId": managed.session.SessionID, "mode": req.Mode})
}

// toSDKAgentMode maps user-facing mode names to SDK SessionMode constants.
func toSDKAgentMode(mode string) (rpc.SessionMode, bool) {
	switch strings.ToLower(strings.TrimSpace(mode)) {
	case "ask", "interactive":
		return rpc.SessionModeInteractive, true
	case "plan":
		return rpc.SessionModePlan, true
	case "agent", "autopilot":
		return rpc.SessionModeAutopilot, true
	default:
		return "", false
	}
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

func (s *service) handleShutdown(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
	if s.shutdownHTTP == nil {
		return
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), httpShutdownTimeout)
		defer cancel()
		if err := s.shutdownHTTP(ctx); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Printf("shutdown via endpoint: %v", err)
		}
	}()
}

func (s *service) liveSessionSummaries() []sessionSummary {
	s.sessionsMu.RLock()
	defer s.sessionsMu.RUnlock()

	items := make([]sessionSummary, 0, len(s.sessions))
	for _, managed := range s.sessions {
		if !managed.hasSubscribers() {
			continue
		}
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

	models, err := withCopilotClientRetry(s, "list models", func(client copilotClient) ([]copilot.ModelInfo, error) {
		return client.ListModels(ctx)
	})
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
	s.closeManagedSessions(errors.New("service shutdown"))
}

func (s *service) closeManagedSessions(reason error) {
	s.sessionsMu.Lock()
	sessions := make([]*managedSession, 0, len(s.sessions))
	for id, managed := range s.sessions {
		sessions = append(sessions, managed)
		delete(s.sessions, id)
	}
	s.sessionsMu.Unlock()

	for _, managed := range sessions {
		if managed.session != nil {
			reasonText := ""
			if reason != nil {
				reasonText = reason.Error()
			}
			managed.broadcastHostEvent("host.session_disconnected", map[string]any{
				"sessionId":        managed.session.SessionID,
				"serviceRestarted": reasonText != "" && reasonText != "service shutdown",
				"reason":           reasonText,
			})
		}
		managed.close(reason)
	}
}

func (m *managedSession) handleSessionEvent(event copilot.SessionEvent) {
	if event.Type == copilot.SessionEventTypeSessionUsageInfo {
		if data, ok := event.Data.(*copilot.SessionUsageInfoData); ok {
			m.setContextUsage(contextWindowUsageFromEvent(data))
		}
	}

	// Drop assistant.message events with empty or whitespace-only content
	// so the client never sees bare "Assistant:" entries.
	if event.Type == copilot.SessionEventTypeAssistantMessage {
		if data, ok := event.Data.(*copilot.AssistantMessageData); ok {
			if strings.TrimSpace(data.Content) == "" && len(data.ToolRequests) == 0 {
				return
			}
		}
	}

	payload, err := m.marshalSequencedSessionEvent(event)
	if err != nil {
		return
	}
	m.broadcast(sseMessage{Event: "session.event", Data: payload})
}

func (m *managedSession) setContextUsage(usage *contextWindowUsage) {
	m.contextUsageMu.Lock()
	defer m.contextUsageMu.Unlock()
	if usage == nil {
		m.contextUsage = nil
		return
	}
	copy := *usage
	m.contextUsage = &copy
}

func (m *managedSession) getContextUsage() *contextWindowUsage {
	m.contextUsageMu.RLock()
	defer m.contextUsageMu.RUnlock()
	if m.contextUsage == nil {
		return nil
	}
	copy := *m.contextUsage
	return &copy
}

func int64FromFloat64(value *float64) int64 {
	if value == nil {
		return 0
	}
	return int64(math.Round(*value))
}

func contextWindowUsageFromEvent(data *copilot.SessionUsageInfoData) *contextWindowUsage {
	if data == nil {
		return nil
	}
	return &contextWindowUsage{
		CurrentTokens:         int64(math.Round(data.CurrentTokens)),
		TokenLimit:            int64(math.Round(data.TokenLimit)),
		MessagesLength:        int64(math.Round(data.MessagesLength)),
		SystemTokens:          int64FromFloat64(data.SystemTokens),
		ToolDefinitionsTokens: int64FromFloat64(data.ToolDefinitionsTokens),
		ConversationTokens:    int64FromFloat64(data.ConversationTokens),
	}
}

func contextWindowUsageFromCompact(data *rpc.HistoryCompactContextWindow) *contextWindowUsage {
	if data == nil {
		return nil
	}
	return &contextWindowUsage{
		CurrentTokens:         data.CurrentTokens,
		TokenLimit:            data.TokenLimit,
		MessagesLength:        data.MessagesLength,
		SystemTokens:          int64Value(data.SystemTokens),
		ToolDefinitionsTokens: int64Value(data.ToolDefinitionsTokens),
		ConversationTokens:    int64Value(data.ConversationTokens),
	}
}

func int64Value(value *int64) int64 {
	if value == nil {
		return 0
	}
	return *value
}

func clampInt64(value int64) int64 {
	if value < 0 {
		return 0
	}
	return value
}

func (s *service) buildContextWindowSnapshot(ctx context.Context, managed *managedSession, usage *contextWindowUsage) *contextWindowSnapshot {
	if managed == nil || usage == nil {
		return nil
	}

	promptTokenLimit := usage.TokenLimit
	modelID := strings.TrimSpace(managed.model)
	if modelID != "" {
		models, err := withCopilotClientRetry(s, "list models", func(client copilotClient) ([]copilot.ModelInfo, error) {
			return client.ListModels(ctx)
		})
		if err == nil {
			for _, model := range models {
				if model.ID == modelID || strings.EqualFold(model.Name, modelID) {
					if model.Capabilities.Limits.MaxPromptTokens != nil && *model.Capabilities.Limits.MaxPromptTokens > 0 {
						promptTokenLimit = int64(*model.Capabilities.Limits.MaxPromptTokens)
					}
					break
				}
			}
		}
	}

	if promptTokenLimit <= 0 || promptTokenLimit > usage.TokenLimit {
		promptTokenLimit = usage.TokenLimit
	}

	systemToolsTokens := clampInt64(usage.SystemTokens + usage.ToolDefinitionsTokens)
	freeTokens := clampInt64(promptTokenLimit - usage.CurrentTokens)
	bufferTokens := clampInt64(usage.TokenLimit - maxInt64(usage.CurrentTokens, promptTokenLimit))

	return &contextWindowSnapshot{
		CurrentTokens:         usage.CurrentTokens,
		TokenLimit:            usage.TokenLimit,
		PromptTokenLimit:      promptTokenLimit,
		MessagesLength:        usage.MessagesLength,
		SystemTokens:          usage.SystemTokens,
		ToolDefinitionsTokens: usage.ToolDefinitionsTokens,
		SystemToolsTokens:     systemToolsTokens,
		ConversationTokens:    usage.ConversationTokens,
		FreeTokens:            freeTokens,
		BufferTokens:          bufferTokens,
	}
}

func maxInt64(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
}

func (m *managedSession) marshalReplaySessionEvents(events []copilot.SessionEvent, replayPermissionHistory bool, turnLimit, activityLimit, previewChars int) ([][]byte, int) {
	events = selectReplayWindow(events, turnLimit)
	if activityLimit > 0 && activityLimit > turnLimit && turnLimit > 0 {
		activityLimit = turnLimit
	}

	payloads := make([][]byte, 0, len(events))
	nextSequence := uint64(0)
	messageChunkIndexes := make(map[string]uint64)
	totalTurns := 0
	for _, event := range events {
		if event.Type == "assistant.turn_start" {
			totalTurns++
		}
	}
	summaryCutoff := totalTurns - activityLimit

	currentTurn := 0
	for _, event := range events {
		if !shouldReplayHistoryEvent(event, replayPermissionHistory) {
			continue
		}
		if event.Type == "assistant.turn_start" {
			currentTurn++
		}
		summaryMode := activityLimit > 0 && currentTurn > 0 && currentTurn <= summaryCutoff
		rawPayload, messageID, err := marshalSessionEventPayload(event)
		if err != nil {
			continue
		}
		rawPayload, skip, err := trimReplayPayload(rawPayload, string(event.Type), summaryMode, previewChars)
		if err != nil || skip {
			continue
		}

		nextSequence++
		var messageChunkIndex *uint64
		if messageID != "" {
			messageChunkIndexes[messageID]++
			index := messageChunkIndexes[messageID]
			messageChunkIndex = &index
		}

		payload, err := enrichSessionEventPayload(rawPayload, nextSequence, messageChunkIndex)
		if err != nil {
			continue
		}
		payloads = append(payloads, payload)
	}

	m.hydrateSessionEventSequenceState(nextSequence, messageChunkIndexes)
	return payloads, len(payloads)
}

func (m *managedSession) marshalSequencedSessionEvent(event copilot.SessionEvent) ([]byte, error) {
	rawPayload, messageID, err := marshalSessionEventPayload(event)
	if err != nil {
		return nil, err
	}

	sequenceID, messageChunkIndex := m.nextSessionEventMetadata(messageID)
	return enrichSessionEventPayload(rawPayload, sequenceID, messageChunkIndex)
}

func (m *managedSession) nextSessionEventMetadata(messageID string) (uint64, *uint64) {
	m.eventSequenceMu.Lock()
	defer m.eventSequenceMu.Unlock()

	m.nextEventSequence++
	sequenceID := m.nextEventSequence

	if messageID == "" {
		return sequenceID, nil
	}
	if m.messageChunkIndexes == nil {
		m.messageChunkIndexes = make(map[string]uint64)
	}

	m.messageChunkIndexes[messageID]++
	index := m.messageChunkIndexes[messageID]
	return sequenceID, &index
}

func (m *managedSession) hydrateSessionEventSequenceState(sequenceID uint64, messageChunkIndexes map[string]uint64) {
	m.eventSequenceMu.Lock()
	defer m.eventSequenceMu.Unlock()

	if m.nextEventSequence < sequenceID {
		m.nextEventSequence = sequenceID
	}
	if m.messageChunkIndexes == nil {
		m.messageChunkIndexes = make(map[string]uint64)
	}
	for messageID, chunkIndex := range messageChunkIndexes {
		if existing := m.messageChunkIndexes[messageID]; existing < chunkIndex {
			m.messageChunkIndexes[messageID] = chunkIndex
		}
	}
}

func marshalSessionEventPayload(event copilot.SessionEvent) ([]byte, string, error) {
	payload, err := (&event).Marshal()
	if err != nil {
		return nil, "", err
	}
	return payload, sessionEventMessageID(payload), nil
}

func enrichSessionEventPayload(payload []byte, sequenceID uint64, messageChunkIndex *uint64) ([]byte, error) {
	var envelope map[string]json.RawMessage
	if err := json.Unmarshal(payload, &envelope); err != nil {
		return nil, err
	}

	encodedSequenceID, err := json.Marshal(sequenceID)
	if err != nil {
		return nil, err
	}
	envelope["sequenceId"] = encodedSequenceID

	if messageChunkIndex != nil {
		encodedChunkIndex, err := json.Marshal(*messageChunkIndex)
		if err != nil {
			return nil, err
		}
		envelope["messageChunkIndex"] = encodedChunkIndex
	}

	return json.Marshal(envelope)
}

func sessionEventMessageID(payload []byte) string {
	var envelope struct {
		Data json.RawMessage `json:"data"`
	}
	if err := json.Unmarshal(payload, &envelope); err != nil || len(envelope.Data) == 0 {
		return ""
	}

	var message struct {
		MessageID string `json:"messageId"`
	}
	if err := json.Unmarshal(envelope.Data, &message); err != nil {
		return ""
	}
	return strings.TrimSpace(message.MessageID)
}

func (m *managedSession) handlePermissionRequest(req copilot.PermissionRequest, inv copilot.PermissionInvocation) (copilot.PermissionRequestResult, error) {
	switch m.permissionMode {
	case permissionModeRejectAll:
		m.broadcastHostEvent("host.permission_decision", map[string]any{
			"sessionId": inv.SessionID, "request": req, "decision": "rejected", "mode": m.permissionMode,
		})
		return copilot.PermissionRequestResult{Kind: copilot.PermissionRequestResultKindRejected}, nil

	case permissionModeApproveReads:
		// Auto-approve read requests whose path is within the working directory.
		// Everything else (write, shell, url, mcp, hook, …) falls through to the
		// interactive handler so the user is still prompted.
		if req.Kind == copilot.PermissionRequestKindRead {
			path := firstNonEmpty(stringOrEmpty(req.Path), stringOrEmpty(req.FileName))
			if path != "" && m.workingDirectory != "" {
				wd := m.workingDirectory
				if !strings.HasSuffix(wd, "/") {
					wd += "/"
				}
				absPath := path
				if !strings.HasPrefix(absPath, "/") {
					absPath = wd + absPath
				}
				if strings.HasPrefix(absPath, wd) {
					m.broadcastHostEvent("host.permission_decision", map[string]any{
						"sessionId": inv.SessionID, "request": req, "decision": "approved", "mode": m.permissionMode,
					})
					return copilot.PermissionRequestResult{Kind: copilot.PermissionRequestResultKindApproved}, nil
				}
			}
		}
		// Fall through to interactive for non-read or out-of-workspace paths.
		fallthrough

	case permissionModeInteractive:
		pending := &pendingPermission{
			view: pendingPermissionView{
				ID:        fmt.Sprintf("%s-%d", permissionRequestIDPrefix, time.Now().UnixNano()),
				Request:   req,
				CreatedAt: time.Now().UTC(),
			},
			resultCh: make(chan permissionResult, asyncResultChannelSize),
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
			ID:            fmt.Sprintf("%s-%d", userInputRequestIDPrefix, time.Now().UnixNano()),
			Question:      req.Question,
			Choices:       req.Choices,
			AllowFreeform: boolOrDefault(req.AllowFreeform, true),
			CreatedAt:     time.Now().UTC(),
		},
		resultCh: make(chan userInputResult, asyncResultChannelSize),
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
	sessionID := ""
	workspacePath := ""
	capabilities := copilot.SessionCapabilities{}
	if m.session != nil {
		sessionID = m.session.SessionID
		workspacePath = m.session.WorkspacePath()
		capabilities = m.session.Capabilities()
	}

	return sessionSummary{
		SessionID:         sessionID,
		Model:             m.model,
		AgentMode:         m.agentMode,
		WorkingDirectory:  m.workingDirectory,
		WorkspacePath:     workspacePath,
		PermissionMode:    m.permissionMode,
		ExcludedTools:     m.excludedTools,
		Capabilities:      capabilities,
		PendingUserInputs: m.pendingUserInputsSnapshot(),
		Summary:           m.sessionName,
		Live:              m.hasSubscribers(),
		CreatedAt:         m.createdAt,
		Resumed:           m.resumed,
		Streaming:         m.streaming,
		Agent:             m.agent,
		ConfigDiscovery:   m.configDiscovery,
		ClientName:        m.clientName,
		InstructionCount:  m.instructionCount,
		AgentCount:        m.agentCount,
		SkillCount:        m.skillCount,
		MCPCount:          m.mcpCount,
	}
}

func (m *managedSession) hasSubscribers() bool {
	m.subscribersMu.RLock()
	defer m.subscribersMu.RUnlock()
	return len(m.subscribers) > 0
}

func countDiscoverableConfig(workingDirectory string) (instructionCount, agentCount, skillCount, mcpCount int) {
	if strings.TrimSpace(workingDirectory) == "" {
		return 0, 0, 0, 0
	}

	githubDir := filepath.Join(workingDirectory, ".github")
	if _, err := os.Stat(githubDir); err == nil {
		if fileExists(filepath.Join(githubDir, "copilot-instructions.md")) {
			instructionCount++
		}

		instructionsDir := filepath.Join(githubDir, "instructions")
		_ = filepath.WalkDir(instructionsDir, func(path string, d fs.DirEntry, err error) error {
			if err != nil || d == nil || d.IsDir() {
				return nil
			}
			if strings.HasSuffix(d.Name(), ".instructions.md") {
				instructionCount++
			}
			return nil
		})

		agentsDir := filepath.Join(githubDir, "agents")
		_ = filepath.WalkDir(agentsDir, func(path string, d fs.DirEntry, err error) error {
			if err != nil || d == nil || d.IsDir() {
				return nil
			}
			if strings.HasSuffix(d.Name(), ".agent.md") {
				agentCount++
			}
			return nil
		})

		skillsDir := filepath.Join(githubDir, "skills")
		_ = filepath.WalkDir(skillsDir, func(path string, d fs.DirEntry, err error) error {
			if err != nil || d == nil || d.IsDir() {
				return nil
			}
			if d.Name() == "SKILL.md" || d.Name() == "skill.md" {
				skillCount++
			}
			return nil
		})
	}

	mcpCount += countMCPServersInFile(filepath.Join(workingDirectory, ".mcp.json"))
	mcpCount += countMCPServersInFile(filepath.Join(workingDirectory, ".vscode", "mcp.json"))
	if home, err := os.UserHomeDir(); err == nil {
		mcpCount += countMCPServersInFile(filepath.Join(home, ".copilot", "mcp-config.json"))
	}

	return instructionCount, agentCount, skillCount, mcpCount
}

func countMCPServersInFile(path string) int {
	data, err := os.ReadFile(path)
	if err != nil {
		return 0
	}

	var payload map[string]any
	if err := json.Unmarshal(data, &payload); err != nil {
		return 0
	}

	if count := countMCPServerEntries(payload["mcpServers"]); count > 0 {
		return count
	}
	return countMCPServerEntries(payload["servers"])
}

func countMCPServerEntries(value any) int {
	switch v := value.(type) {
	case map[string]any:
		return len(v)
	case []any:
		return len(v)
	default:
		return 0
	}
}

func extractBackgroundTasks(events []copilot.SessionEvent) []backgroundTaskView {
	tasks := make(map[string]*backgroundTaskView)

	ensureTask := func(id, kind string) *backgroundTaskView {
		task, ok := tasks[id]
		if !ok {
			task = &backgroundTaskView{ID: id, Kind: kind}
			tasks[id] = task
		}
		if task.Kind == "" {
			task.Kind = kind
		}
		return task
	}

	for idx, event := range events {
		switch data := event.Data.(type) {
		case *copilot.SubagentStartedData:
			task := ensureTask("subagent:"+data.ToolCallID, "subagent")
			task.Status = "running"
			task.Title = firstNonEmpty(data.AgentDisplayName, data.AgentName, task.Title, "Subagent")
			task.Description = firstNonEmpty(data.AgentDescription, task.Description)
			task.AgentName = firstNonEmpty(data.AgentName, task.AgentName)
			task.ToolCallID = firstNonEmpty(data.ToolCallID, task.ToolCallID)
			task.UpdatedAt = event.Timestamp
			if task.StartedAt == nil {
				startedAt := event.Timestamp
				task.StartedAt = &startedAt
			}
		case *copilot.SubagentCompletedData:
			task := ensureTask("subagent:"+data.ToolCallID, "subagent")
			task.Status = "completed"
			task.Title = firstNonEmpty(data.AgentDisplayName, data.AgentName, task.Title, "Subagent")
			task.AgentName = firstNonEmpty(data.AgentName, task.AgentName)
			task.ToolCallID = firstNonEmpty(data.ToolCallID, task.ToolCallID)
			task.Model = firstNonEmpty(stringValue(data.Model), task.Model)
			task.DurationMs = data.DurationMs
			task.TotalTokens = data.TotalTokens
			task.TotalToolCalls = data.TotalToolCalls
			task.UpdatedAt = event.Timestamp
			completedAt := event.Timestamp
			task.CompletedAt = &completedAt
			if task.StartedAt == nil {
				startedAt := event.Timestamp
				task.StartedAt = &startedAt
			}
		case *copilot.SubagentFailedData:
			task := ensureTask("subagent:"+data.ToolCallID, "subagent")
			task.Status = "failed"
			task.Title = firstNonEmpty(data.AgentDisplayName, data.AgentName, task.Title, "Subagent")
			task.AgentName = firstNonEmpty(data.AgentName, task.AgentName)
			task.ToolCallID = firstNonEmpty(data.ToolCallID, task.ToolCallID)
			task.Model = firstNonEmpty(stringValue(data.Model), task.Model)
			task.DurationMs = data.DurationMs
			task.TotalTokens = data.TotalTokens
			task.TotalToolCalls = data.TotalToolCalls
			task.Error = firstNonEmpty(data.Error, task.Error)
			task.UpdatedAt = event.Timestamp
			completedAt := event.Timestamp
			task.CompletedAt = &completedAt
			if task.StartedAt == nil {
				startedAt := event.Timestamp
				task.StartedAt = &startedAt
			}
		case *copilot.SystemNotificationData:
			kind := data.Kind
			switch kind.Type {
			case copilot.SystemNotificationTypeAgentCompleted, copilot.SystemNotificationTypeAgentIdle, copilot.SystemNotificationTypeNewInboxMessage:
				key := firstNonEmpty(stringValue(kind.AgentID), stringValue(kind.EntryID), fmt.Sprintf("notification-%d", idx))
				task := ensureTask("background:"+key, "background")
				task.Title = firstNonEmpty(stringValue(kind.Description), task.Title, stringValue(kind.Summary), stringValue(kind.AgentType), "Background agent")
				task.Description = firstNonEmpty(stringValue(kind.Description), task.Description)
				task.Summary = firstNonEmpty(stringValue(kind.Summary), task.Summary)
				task.Prompt = firstNonEmpty(stringValue(kind.Prompt), task.Prompt)
				task.AgentID = firstNonEmpty(stringValue(kind.AgentID), task.AgentID)
				task.AgentType = firstNonEmpty(stringValue(kind.AgentType), task.AgentType)
				task.EntryID = firstNonEmpty(stringValue(kind.EntryID), task.EntryID)
				task.UpdatedAt = event.Timestamp
				if task.StartedAt == nil {
					startedAt := event.Timestamp
					task.StartedAt = &startedAt
				}

				switch kind.Type {
				case copilot.SystemNotificationTypeAgentCompleted:
					if kind.Status != nil && *kind.Status == copilot.SystemNotificationAgentCompletedStatusFailed {
						task.Status = "failed"
					} else {
						task.Status = "completed"
					}
					completedAt := event.Timestamp
					task.CompletedAt = &completedAt
				case copilot.SystemNotificationTypeAgentIdle:
					task.Status = "idle"
				case copilot.SystemNotificationTypeNewInboxMessage:
					task.Status = "inbox"
				}
			}
		}
	}

	out := make([]backgroundTaskView, 0, len(tasks))
	for _, task := range tasks {
		out = append(out, *task)
	}
	sort.Slice(out, func(i, j int) bool {
		leftRank := backgroundTaskStatusRank(out[i].Status)
		rightRank := backgroundTaskStatusRank(out[j].Status)
		if leftRank != rightRank {
			return leftRank < rightRank
		}
		if !out[i].UpdatedAt.Equal(out[j].UpdatedAt) {
			return out[i].UpdatedAt.After(out[j].UpdatedAt)
		}
		return out[i].ID < out[j].ID
	})
	return out
}

func backgroundTaskStatusRank(status string) int {
	switch status {
	case "running":
		return 0
	case "inbox":
		return 1
	case "idle":
		return 2
	case "failed":
		return 3
	case "completed":
		return 4
	default:
		return 5
	}
}

func stringValue(value *string) string {
	if value == nil {
		return ""
	}
	return strings.TrimSpace(*value)
}

func fileExists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && !info.IsDir()
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
	ch := make(chan sseMessage, sseSubscriberBufferSize)
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
			log.Printf("SSE subscriber channel full, dropped event: %s (session %s)", msg.Event, m.session.SessionID)
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

func defaultSessionStateDir() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".copilot", "session-state")
}

func enrichPersistedSessionsFromWorkspace(sessions []copilot.SessionMetadata, stateDir string) []copilot.SessionMetadata {
	if len(sessions) == 0 || strings.TrimSpace(stateDir) == "" {
		return sessions
	}

	enriched := make([]copilot.SessionMetadata, len(sessions))
	copy(enriched, sessions)
	for i := range enriched {
		if enriched[i].Context != nil && strings.TrimSpace(enriched[i].Context.Cwd) != "" {
			continue
		}

		context, ok := readWorkspaceContext(stateDir, enriched[i].SessionID)
		if !ok {
			continue
		}
		enriched[i].Context = context
	}
	return enriched
}

func readWorkspaceContext(stateDir, sessionID string) (*copilot.SessionContext, bool) {
	if strings.TrimSpace(stateDir) == "" || strings.TrimSpace(sessionID) == "" {
		return nil, false
	}

	data, err := os.ReadFile(filepath.Join(stateDir, sessionID, "workspace.yaml"))
	if err != nil {
		return nil, false
	}

	context := &copilot.SessionContext{}
	for _, line := range strings.Split(string(data), "\n") {
		key, value, ok := strings.Cut(line, ":")
		if !ok {
			continue
		}
		value = strings.TrimSpace(strings.Trim(value, `"'`))
		if value == "" {
			continue
		}

		switch strings.TrimSpace(key) {
		case "cwd":
			context.Cwd = value
		case "git_root":
			context.GitRoot = value
		case "repository":
			context.Repository = value
		case "branch":
			context.Branch = value
		}
	}

	if strings.TrimSpace(context.Cwd) == "" {
		return nil, false
	}
	return context, true
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

func queryInt(r *http.Request, name string) int {
	value := strings.TrimSpace(r.URL.Query().Get(name))
	if value == "" {
		return 0
	}
	n, err := strconv.Atoi(value)
	if err != nil || n < 0 {
		return 0
	}
	return n
}

func boolOrDefault(value *bool, fallback bool) bool {
	if value == nil {
		return fallback
	}
	return *value
}

func stringOrEmpty(value *string) string {
	if value == nil {
		return ""
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
	case permissionModeApproveAll, permissionModeRejectAll, permissionModeInteractive, permissionModeAutopilot, permissionModeApproveReads:
		return true
	default:
		return false
	}
}

func sessionIDPrefixForWorkingDirectory(workingDirectory string) string {
	repo := strings.TrimSpace(filepath.Base(filepath.Clean(workingDirectory)))
	if repo == "" || repo == "." || repo == string(filepath.Separator) {
		return sessionIDPrefix
	}

	var builder strings.Builder
	lastSeparator := false
	for _, r := range strings.ToLower(repo) {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9':
			builder.WriteRune(r)
			lastSeparator = false
		case r == '-' || r == '_':
			if builder.Len() > 0 && !lastSeparator {
				builder.WriteRune(r)
				lastSeparator = true
			}
		default:
			if builder.Len() > 0 && !lastSeparator {
				builder.WriteByte('-')
				lastSeparator = true
			}
		}
	}

	prefix := strings.Trim(builder.String(), "-_")
	if len(prefix) > sessionIDPrefixMaxLen {
		prefix = strings.TrimRight(prefix[:sessionIDPrefixMaxLen], "-_")
	}
	if prefix == "" {
		return sessionIDPrefix
	}
	return prefix
}

func newSessionID(workingDirectory string) string {
	return fmt.Sprintf("%s-%d", sessionIDPrefixForWorkingDirectory(workingDirectory), time.Now().UnixNano())
}
