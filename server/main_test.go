// Copyright 2026 ray-x. All rights reserved.
// Use of this source code is governed by an Apache 2.0
// license that can be found in the LICENSE file.

package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	copilot "github.com/github/copilot-sdk/go"
)

type decodedSessionEvent struct {
	Type              string          `json:"type"`
	Data              json.RawMessage `json:"data"`
	SequenceID        uint64          `json:"sequenceId"`
	MessageChunkIndex *uint64         `json:"messageChunkIndex,omitempty"`
}

type fakeCopilotClient struct {
	state                   copilot.ConnectionState
	startErr                error
	listModelsResp          []copilot.ModelInfo
	listModelsErr           error
	listSessionsResp        []copilot.SessionMetadata
	listSessionsErr         error
	getSessionMetadataResp  *copilot.SessionMetadata
	getSessionMetadataErr   error
	createSessionResp       *copilot.Session
	createSessionErr        error
	resumeSessionResp       *copilot.Session
	resumeSessionErr        error
	deleteSessionErr        error
	startCalls              int
	stopCalls               int
	forceStopCalls          int
	listModelsCalls         int
	listSessionsCalls       int
	getSessionMetadataCalls int
	createSessionCalls      int
	resumeSessionCalls      int
	deleteSessionCalls      int
}

func (f *fakeCopilotClient) Start(context.Context) error {
	f.startCalls++
	if f.startErr != nil {
		return f.startErr
	}
	if f.state == "" {
		f.state = copilot.StateConnected
	}
	return nil
}

func (f *fakeCopilotClient) Stop() error {
	f.stopCalls++
	f.state = copilot.StateDisconnected
	return nil
}

func (f *fakeCopilotClient) ForceStop() {
	f.forceStopCalls++
	f.state = copilot.StateDisconnected
}

func (f *fakeCopilotClient) State() copilot.ConnectionState {
	return f.state
}

func (f *fakeCopilotClient) ListModels(context.Context) ([]copilot.ModelInfo, error) {
	f.listModelsCalls++
	return f.listModelsResp, f.listModelsErr
}

func (f *fakeCopilotClient) ListSessions(context.Context, *copilot.SessionListFilter) ([]copilot.SessionMetadata, error) {
	f.listSessionsCalls++
	return f.listSessionsResp, f.listSessionsErr
}

func (f *fakeCopilotClient) GetSessionMetadata(context.Context, string) (*copilot.SessionMetadata, error) {
	f.getSessionMetadataCalls++
	return f.getSessionMetadataResp, f.getSessionMetadataErr
}

func (f *fakeCopilotClient) CreateSession(context.Context, *copilot.SessionConfig) (*copilot.Session, error) {
	f.createSessionCalls++
	return f.createSessionResp, f.createSessionErr
}

func (f *fakeCopilotClient) ResumeSession(context.Context, string, *copilot.ResumeSessionConfig) (*copilot.Session, error) {
	f.resumeSessionCalls++
	return f.resumeSessionResp, f.resumeSessionErr
}

func (f *fakeCopilotClient) DeleteSession(context.Context, string) error {
	f.deleteSessionCalls++
	return f.deleteSessionErr
}

func (f *fakeCopilotClient) OnEventType(copilot.SessionLifecycleEventType, copilot.SessionLifecycleHandler) func() {
	return func() {}
}

func decodeSessionEventPayload(t *testing.T, payload []byte) decodedSessionEvent {
	t.Helper()

	var decoded decodedSessionEvent
	if err := json.Unmarshal(payload, &decoded); err != nil {
		t.Fatalf("decode session event payload: %v", err)
	}
	return decoded
}

func TestResolveModelAliasReturnsExactMatch(t *testing.T) {
	t.Parallel()

	models := []copilot.ModelInfo{
		{ID: "auto"},
		{ID: "gpt-5.4"},
	}

	resolved, ok := resolveModelAlias("gpt-5.4", models)
	if !ok {
		t.Fatal("expected exact model match to resolve")
	}
	if resolved != "gpt-5.4" {
		t.Fatalf("expected gpt-5.4, got %q", resolved)
	}
}

func TestResolveModelAliasChoosesLatestPlainFamilyRelease(t *testing.T) {
	t.Parallel()

	models := []copilot.ModelInfo{
		{ID: "gpt-5.3-codex"},
		{ID: "gpt-5.4-mini"},
		{ID: "gpt-5.4"},
		{ID: "gpt-4.1"},
	}

	resolved, ok := resolveModelAlias("gpt-5", models)
	if !ok {
		t.Fatal("expected family alias to resolve")
	}
	if resolved != "gpt-5.4" {
		t.Fatalf("expected gpt-5.4, got %q", resolved)
	}
}

func TestResolveModelAliasChoosesLatestVersionWithinFamily(t *testing.T) {
	t.Parallel()

	models := []copilot.ModelInfo{
		{ID: "claude-sonnet-4.5"},
		{ID: "claude-sonnet-4.6"},
	}

	resolved, ok := resolveModelAlias("claude-sonnet-4", models)
	if !ok {
		t.Fatal("expected family alias to resolve")
	}
	if resolved != "claude-sonnet-4.6" {
		t.Fatalf("expected claude-sonnet-4.6, got %q", resolved)
	}
}

func TestResolveModelAliasLeavesUnknownModelUnresolved(t *testing.T) {
	t.Parallel()

	models := []copilot.ModelInfo{
		{ID: "gpt-5.4"},
	}

	resolved, ok := resolveModelAlias("gpt-6", models)
	if ok {
		t.Fatalf("expected unknown alias to stay unresolved, got %q", resolved)
	}
}

func TestBuildContextWindowSnapshotUsesModelPromptLimit(t *testing.T) {
	t.Parallel()

	maxPromptTokens := 258400
	client := &fakeCopilotClient{
		state: copilot.StateConnected,
		listModelsResp: []copilot.ModelInfo{
			{
				ID: "gpt-5.4",
				Capabilities: copilot.ModelCapabilities{
					Limits: copilot.ModelLimits{
						MaxPromptTokens:        &maxPromptTokens,
						MaxContextWindowTokens: 304000,
					},
				},
			},
		},
	}
	svc := &service{client: client}
	managed := &managedSession{model: "gpt-5.4"}
	usage := &contextWindowUsage{
		CurrentTokens:         30000,
		TokenLimit:            304000,
		MessagesLength:        0,
		SystemTokens:          21000,
		ToolDefinitionsTokens: 8700,
		ConversationTokens:    0,
	}

	snapshot := svc.buildContextWindowSnapshot(context.Background(), managed, usage)
	if snapshot == nil {
		t.Fatal("expected context snapshot")
	}
	if snapshot.PromptTokenLimit != 258400 {
		t.Fatalf("expected prompt token limit 258400, got %d", snapshot.PromptTokenLimit)
	}
	if snapshot.SystemToolsTokens != 29700 {
		t.Fatalf("expected system/tools 29700, got %d", snapshot.SystemToolsTokens)
	}
	if snapshot.FreeTokens != 228400 {
		t.Fatalf("expected free tokens 228400, got %d", snapshot.FreeTokens)
	}
	if snapshot.BufferTokens != 45600 {
		t.Fatalf("expected buffer tokens 45600, got %d", snapshot.BufferTokens)
	}
	if client.listModelsCalls != 1 {
		t.Fatalf("expected list models to be called once, got %d", client.listModelsCalls)
	}
}

func TestServiceClientRegistrationAndIdleShutdown(t *testing.T) {
	t.Parallel()

	stopCh := make(chan struct{}, 1)
	svc := &service{
		activeClients:     make(map[string]registeredClient),
		idleShutdownGrace: 20 * time.Millisecond,
		stop: func() {
			select {
			case stopCh <- struct{}{}:
			default:
			}
		},
	}

	if got := svc.registerClient("client-a", "alpha"); got != 1 {
		t.Fatalf("expected 1 active client after register, got %d", got)
	}
	if got := svc.unregisterClient("client-a"); got != 0 {
		t.Fatalf("expected 0 active clients after unregister, got %d", got)
	}

	select {
	case <-stopCh:
	case <-time.After(200 * time.Millisecond):
		t.Fatal("expected detached service shutdown after last client unregisters")
	}
}

func TestServiceClientRegistrationCancelsIdleShutdown(t *testing.T) {
	t.Parallel()

	stopCh := make(chan struct{}, 1)
	svc := &service{
		activeClients:     make(map[string]registeredClient),
		idleShutdownGrace: 25 * time.Millisecond,
		stop: func() {
			select {
			case stopCh <- struct{}{}:
			default:
			}
		},
	}

	if got := svc.registerClient("client-a", "alpha"); got != 1 {
		t.Fatalf("expected 1 active client after register, got %d", got)
	}
	if got := svc.unregisterClient("client-a"); got != 0 {
		t.Fatalf("expected 0 active clients after unregister, got %d", got)
	}
	if got := svc.registerClient("client-b", "beta"); got != 1 {
		t.Fatalf("expected 1 active client after re-register, got %d", got)
	}

	select {
	case <-stopCh:
		t.Fatal("did not expect shutdown while a client is registered again")
	case <-time.After(75 * time.Millisecond):
	}

	if got := svc.unregisterClient("client-b"); got != 0 {
		t.Fatalf("expected 0 active clients after final unregister, got %d", got)
	}

	select {
	case <-stopCh:
	case <-time.After(200 * time.Millisecond):
		t.Fatal("expected shutdown after the final client unregisters")
	}
}

// ── boolOrDefault ─────────────────────────────────────────────────────────────

func TestBoolOrDefaultNilUseFallback(t *testing.T) {
	t.Parallel()
	if !boolOrDefault(nil, true) {
		t.Fatal("expected fallback true when pointer is nil")
	}
	if boolOrDefault(nil, false) {
		t.Fatal("expected fallback false when pointer is nil")
	}
}

func TestBoolOrDefaultNonNilUsesValue(t *testing.T) {
	t.Parallel()
	yes := true
	no := false
	if !boolOrDefault(&yes, false) {
		t.Fatal("expected true from pointer")
	}
	if boolOrDefault(&no, true) {
		t.Fatal("expected false from pointer")
	}
}

// ── firstNonEmpty ─────────────────────────────────────────────────────────────

func TestFirstNonEmptyReturnsFirst(t *testing.T) {
	t.Parallel()
	if got := firstNonEmpty("a", "b", "c"); got != "a" {
		t.Fatalf("want a, got %q", got)
	}
}

func TestFirstNonEmptySkipsBlanks(t *testing.T) {
	t.Parallel()
	if got := firstNonEmpty("", "  ", "found"); got != "found" {
		t.Fatalf("want found, got %q", got)
	}
}

func TestFirstNonEmptyTrimmedResult(t *testing.T) {
	t.Parallel()
	if got := firstNonEmpty("  trimmed  "); got != "trimmed" {
		t.Fatalf("want trimmed, got %q", got)
	}
}

func TestFirstNonEmptyAllEmptyReturnsEmpty(t *testing.T) {
	t.Parallel()
	if got := firstNonEmpty("", "  ", ""); got != "" {
		t.Fatalf("want empty string, got %q", got)
	}
}

func TestFirstNonEmptyNoArgs(t *testing.T) {
	t.Parallel()
	if got := firstNonEmpty(); got != "" {
		t.Fatalf("want empty string, got %q", got)
	}
}

func TestSessionIDPrefixForWorkingDirectoryUsesRepoFolder(t *testing.T) {
	t.Parallel()

	if got := sessionIDPrefixForWorkingDirectory("/tmp/go.nvim"); got != "go-nvim" {
		t.Fatalf("expected go-nvim, got %q", got)
	}
}

func TestSessionIDPrefixForWorkingDirectoryTruncatesToEightCharacters(t *testing.T) {
	t.Parallel()

	if got := sessionIDPrefixForWorkingDirectory("/tmp/copilot-agent.nvim"); got != "copilot" {
		t.Fatalf("expected copilot, got %q", got)
	}
}

func TestSessionIDPrefixForWorkingDirectorySanitizesAndFallsBack(t *testing.T) {
	t.Parallel()

	if got := sessionIDPrefixForWorkingDirectory("/tmp/My Repo!"); got != "my-repo" {
		t.Fatalf("expected my-repo, got %q", got)
	}
	if got := sessionIDPrefixForWorkingDirectory("/tmp/!!!"); got != sessionIDPrefix {
		t.Fatalf("expected fallback prefix %q, got %q", sessionIDPrefix, got)
	}
}

func TestNewSessionIDUsesSanitizedRepoPrefix(t *testing.T) {
	t.Parallel()

	sessionID := newSessionID("/tmp/copilot-agent.nvim")
	if !strings.HasPrefix(sessionID, "copilot-") {
		t.Fatalf("expected copilot-prefixed session ID, got %q", sessionID)
	}
	suffix := strings.TrimPrefix(sessionID, "copilot-")
	if suffix == "" {
		t.Fatalf("expected timestamp suffix in %q", sessionID)
	}
	for _, r := range suffix {
		if r < '0' || r > '9' {
			t.Fatalf("expected numeric timestamp suffix in %q", sessionID)
		}
	}
}

func TestShouldReplayHistoryEventSkipsPermissionEvents(t *testing.T) {
	t.Parallel()

	if shouldReplayHistoryEvent(copilot.SessionEvent{Type: "permission.requested"}, false) {
		t.Fatal("expected permission.requested to be skipped during history replay")
	}
	if shouldReplayHistoryEvent(copilot.SessionEvent{Type: "permission.completed"}, false) {
		t.Fatal("expected permission.completed to be skipped during history replay")
	}
}

func TestShouldReplayHistoryEventAllowsPermissionEventsWhenEnabled(t *testing.T) {
	t.Parallel()

	if !shouldReplayHistoryEvent(copilot.SessionEvent{Type: "permission.requested"}, true) {
		t.Fatal("expected permission.requested to replay when explicitly enabled")
	}
	if !shouldReplayHistoryEvent(copilot.SessionEvent{Type: "permission.completed"}, true) {
		t.Fatal("expected permission.completed to replay when explicitly enabled")
	}
}

func TestShouldReplayHistoryEventSkipsEmptyAssistantMessages(t *testing.T) {
	t.Parallel()

	if shouldReplayHistoryEvent(copilot.SessionEvent{
		Type: copilot.SessionEventTypeAssistantMessage,
		Data: &copilot.AssistantMessageData{},
	}, false) {
		t.Fatal("expected empty assistant message without tool requests to be skipped")
	}

	if !shouldReplayHistoryEvent(copilot.SessionEvent{
		Type: copilot.SessionEventTypeAssistantMessage,
		Data: &copilot.AssistantMessageData{Content: "hello"},
	}, false) {
		t.Fatal("expected assistant message with content to be replayed")
	}
}

// ── queryBool ─────────────────────────────────────────────────────────────────

func TestQueryBoolRecognisesTrueValues(t *testing.T) {
	t.Parallel()
	for _, v := range []string{"1", "true", "True", "TRUE", "yes", "Yes", "YES"} {
		req := httptest.NewRequest(http.MethodGet, "/?flag="+v, nil)
		if !queryBool(req, "flag") {
			t.Errorf("queryBool should be true for %q", v)
		}
	}
}

func TestQueryBoolRecognisesFalseValues(t *testing.T) {
	t.Parallel()
	for _, v := range []string{"0", "false", "no", "", "random"} {
		req := httptest.NewRequest(http.MethodGet, "/?flag="+v, nil)
		if queryBool(req, "flag") {
			t.Errorf("queryBool should be false for %q", v)
		}
	}
}

func TestQueryBoolMissingParamIsFalse(t *testing.T) {
	t.Parallel()
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	if queryBool(req, "flag") {
		t.Fatal("missing param should be false")
	}
}

// ── isValidPermissionMode ─────────────────────────────────────────────────────

func TestIsValidPermissionModeAcceptsKnownModes(t *testing.T) {
	t.Parallel()
	for _, mode := range []string{"approve-all", "reject-all", "interactive", "autopilot"} {
		if !isValidPermissionMode(mode) {
			t.Errorf("expected %q to be valid", mode)
		}
	}
}

func TestIsValidPermissionModeRejectsUnknown(t *testing.T) {
	t.Parallel()
	for _, mode := range []string{"", "all", "APPROVE-ALL", "yes"} {
		if isValidPermissionMode(mode) {
			t.Errorf("expected %q to be invalid", mode)
		}
	}
}

// ── listenInRange ─────────────────────────────────────────────────────────────

func TestListenInRangeBindsSuccessfully(t *testing.T) {
	t.Parallel()
	// Use a wide high-port range; the OS will pick the first available one.
	ln, err := listenInRange("127.0.0.1", "10000-65000")
	if err != nil {
		t.Fatalf("expected a port to be found: %v", err)
	}
	ln.Close()
}

func TestListenInRangeRejectsInvalidFormat(t *testing.T) {
	t.Parallel()
	cases := []string{"norange", "abc-def", "100", "65536-65537", "200-100", "0-100"}
	for _, pr := range cases {
		if _, err := listenInRange("127.0.0.1", pr); err == nil {
			t.Errorf("expected error for port range %q", pr)
		}
	}
}

func TestListenInRangeSinglePort(t *testing.T) {
	t.Parallel()
	// Bind to a wide range to discover a free port, then verify listenInRange
	// can bind to that specific port when expressed as "port-port".
	tmp, err := listenInRange("127.0.0.1", "10000-65000")
	if err != nil {
		t.Fatal(err)
	}
	addr := tmp.Addr().String()
	tmp.Close()
	port := addr[strings.LastIndex(addr, ":")+1:]
	ln, err := listenInRange("127.0.0.1", port+"-"+port)
	if err != nil {
		t.Fatalf("expected single-port range to succeed: %v", err)
	}
	ln.Close()
}

// ── handleHealth ──────────────────────────────────────────────────────────────

func TestHandleHealthReturns200(t *testing.T) {
	t.Parallel()

	svc := &service{
		client: &fakeCopilotClient{state: copilot.StateConnected},
	}
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	w := httptest.NewRecorder()
	svc.handleHealth(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("want 200, got %d", w.Code)
	}
	var body map[string]any
	if err := json.NewDecoder(w.Body).Decode(&body); err != nil {
		t.Fatalf("invalid JSON: %v", err)
	}
	if body["ok"] != true {
		t.Fatalf("expected ok=true, got %v", body["ok"])
	}
}

func TestHandleHealthRestartsDisconnectedClient(t *testing.T) {
	t.Parallel()

	staleClient := &fakeCopilotClient{state: copilot.StateDisconnected}
	freshClient := &fakeCopilotClient{state: copilot.StateConnected}
	svc := &service{
		client:    staleClient,
		clientCtx: context.Background(),
		clientFactory: func() copilotClient {
			return freshClient
		},
		sessions: make(map[string]*managedSession),
	}

	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	w := httptest.NewRecorder()
	svc.handleHealth(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("want 200, got %d: %s", w.Code, w.Body.String())
	}
	if staleClient.forceStopCalls != 1 {
		t.Fatalf("expected stale client to be force-stopped once, got %d", staleClient.forceStopCalls)
	}
	if freshClient.startCalls != 1 {
		t.Fatalf("expected replacement client to start once, got %d", freshClient.startCalls)
	}
}

func TestHandleHealthReturns503WhenRestartFails(t *testing.T) {
	t.Parallel()

	svc := &service{
		client:    &fakeCopilotClient{state: copilot.StateDisconnected},
		clientCtx: context.Background(),
		clientFactory: func() copilotClient {
			return &fakeCopilotClient{startErr: errors.New("boom")}
		},
		sessions: make(map[string]*managedSession),
	}

	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	w := httptest.NewRecorder()
	svc.handleHealth(w, req)

	if w.Code != http.StatusServiceUnavailable {
		t.Fatalf("want 503, got %d", w.Code)
	}
	var body map[string]string
	if err := json.NewDecoder(w.Body).Decode(&body); err != nil {
		t.Fatalf("invalid JSON: %v", err)
	}
	if !strings.Contains(body["error"], "copilot client unavailable") {
		t.Fatalf("unexpected error: %q", body["error"])
	}
}

// ── writeJSON / writeError ────────────────────────────────────────────────────

func TestWriteJSONSetsContentTypeAndStatus(t *testing.T) {
	t.Parallel()
	w := httptest.NewRecorder()
	writeJSON(w, http.StatusCreated, map[string]string{"key": "value"})

	if w.Code != http.StatusCreated {
		t.Fatalf("want 201, got %d", w.Code)
	}
	if ct := w.Header().Get("Content-Type"); ct != "application/json" {
		t.Fatalf("want application/json, got %q", ct)
	}
	var body map[string]string
	if err := json.NewDecoder(w.Body).Decode(&body); err != nil {
		t.Fatalf("invalid JSON: %v", err)
	}
	if body["key"] != "value" {
		t.Fatalf("unexpected body: %v", body)
	}
}

func TestWriteErrorSetsStatusAndMessage(t *testing.T) {
	t.Parallel()
	w := httptest.NewRecorder()
	writeError(w, http.StatusBadRequest, "something went wrong")

	if w.Code != http.StatusBadRequest {
		t.Fatalf("want 400, got %d", w.Code)
	}
	var body map[string]string
	if err := json.NewDecoder(w.Body).Decode(&body); err != nil {
		t.Fatalf("invalid JSON: %v", err)
	}
	if body["error"] != "something went wrong" {
		t.Fatalf("unexpected error message: %q", body["error"])
	}
}

func TestEnrichPersistedSessionsFromWorkspaceBackfillsMissingContext(t *testing.T) {
	t.Parallel()

	stateDir := t.TempDir()
	sessionID := "nvim-1777442217401371000"
	if err := os.MkdirAll(filepath.Join(stateDir, sessionID), 0o755); err != nil {
		t.Fatalf("mkdir state dir: %v", err)
	}
	if err := os.WriteFile(
		filepath.Join(stateDir, sessionID, "workspace.yaml"),
		[]byte("id: nvim-1777442217401371000\ncwd: /tmp/project\ngit_root: /tmp/project\nrepository: owner/repo\nbranch: main\n"),
		0o644,
	); err != nil {
		t.Fatalf("write workspace metadata: %v", err)
	}

	enriched := enrichPersistedSessionsFromWorkspace([]copilot.SessionMetadata{
		{SessionID: sessionID},
	}, stateDir)

	if got := enriched[0].Context; got == nil {
		t.Fatal("expected workspace context to be backfilled")
	} else {
		if got.Cwd != "/tmp/project" {
			t.Fatalf("expected cwd /tmp/project, got %q", got.Cwd)
		}
		if got.GitRoot != "/tmp/project" {
			t.Fatalf("expected gitRoot /tmp/project, got %q", got.GitRoot)
		}
		if got.Repository != "owner/repo" {
			t.Fatalf("expected repository owner/repo, got %q", got.Repository)
		}
		if got.Branch != "main" {
			t.Fatalf("expected branch main, got %q", got.Branch)
		}
	}
}

func TestEnrichPersistedSessionsFromWorkspacePreservesExistingContext(t *testing.T) {
	t.Parallel()

	enriched := enrichPersistedSessionsFromWorkspace([]copilot.SessionMetadata{
		{
			SessionID: "session-123",
			Context: &copilot.SessionContext{
				Cwd:        "/already/set",
				GitRoot:    "/already/set",
				Repository: "owner/existing",
				Branch:     "stable",
			},
		},
	}, t.TempDir())

	if got := enriched[0].Context; got == nil {
		t.Fatal("expected existing context to be preserved")
	} else {
		if got.Cwd != "/already/set" {
			t.Fatalf("expected cwd /already/set, got %q", got.Cwd)
		}
		if got.Repository != "owner/existing" {
			t.Fatalf("expected repository owner/existing, got %q", got.Repository)
		}
		if got.Branch != "stable" {
			t.Fatalf("expected branch stable, got %q", got.Branch)
		}
	}
}

func TestCountDiscoverableConfigCountsMCPServers(t *testing.T) {
	t.Setenv("HOME", t.TempDir())

	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, ".github"), 0o755); err != nil {
		t.Fatalf("mkdir .github: %v", err)
	}
	if err := os.WriteFile(filepath.Join(root, ".github", "copilot-instructions.md"), []byte("# hi"), 0o644); err != nil {
		t.Fatalf("write instructions: %v", err)
	}
	if err := os.MkdirAll(filepath.Join(root, ".github", "agents"), 0o755); err != nil {
		t.Fatalf("mkdir agents: %v", err)
	}
	if err := os.WriteFile(filepath.Join(root, ".github", "agents", "qa.agent.md"), []byte("# agent"), 0o644); err != nil {
		t.Fatalf("write agent: %v", err)
	}
	if err := os.MkdirAll(filepath.Join(root, ".github", "skills", "review"), 0o755); err != nil {
		t.Fatalf("mkdir skills: %v", err)
	}
	if err := os.WriteFile(filepath.Join(root, ".github", "skills", "review", "SKILL.md"), []byte("# skill"), 0o644); err != nil {
		t.Fatalf("write skill: %v", err)
	}
	if err := os.WriteFile(filepath.Join(root, ".mcp.json"), []byte(`{"mcpServers":{"local":{},"docs":{}}}`), 0o644); err != nil {
		t.Fatalf("write root mcp config: %v", err)
	}
	if err := os.MkdirAll(filepath.Join(root, ".vscode"), 0o755); err != nil {
		t.Fatalf("mkdir .vscode: %v", err)
	}
	if err := os.WriteFile(filepath.Join(root, ".vscode", "mcp.json"), []byte(`{"servers":[{"name":"browser"}]}`), 0o644); err != nil {
		t.Fatalf("write vscode mcp config: %v", err)
	}

	instructions, agents, skills, mcp := countDiscoverableConfig(root)
	if instructions != 1 {
		t.Fatalf("expected 1 instruction, got %d", instructions)
	}
	if agents != 1 {
		t.Fatalf("expected 1 agent, got %d", agents)
	}
	if skills != 1 {
		t.Fatalf("expected 1 skill, got %d", skills)
	}
	if mcp != 3 {
		t.Fatalf("expected 3 MCP servers, got %d", mcp)
	}
}

func TestCountDiscoverableConfigCountsMCPWithoutGithubDir(t *testing.T) {
	t.Setenv("HOME", t.TempDir())

	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, ".mcp.json"), []byte(`{"mcpServers":{"fff":{}}}`), 0o644); err != nil {
		t.Fatalf("write root mcp config: %v", err)
	}

	instructions, agents, skills, mcp := countDiscoverableConfig(root)
	if instructions != 0 {
		t.Fatalf("expected 0 instructions, got %d", instructions)
	}
	if agents != 0 {
		t.Fatalf("expected 0 agents, got %d", agents)
	}
	if skills != 0 {
		t.Fatalf("expected 0 skills, got %d", skills)
	}
	if mcp != 1 {
		t.Fatalf("expected 1 MCP server, got %d", mcp)
	}
}

func TestManagedSessionSummaryLiveReflectsActiveSubscribers(t *testing.T) {
	t.Parallel()

	managed := &managedSession{
		session:     &copilot.Session{SessionID: "session-123"},
		subscribers: make(map[chan sseMessage]struct{}),
	}

	if managed.summary().Live {
		t.Fatal("expected detached managed session summary to report live=false")
	}

	sub := managed.subscribe()
	defer managed.unsubscribe(sub)

	if !managed.summary().Live {
		t.Fatal("expected attached managed session summary to report live=true")
	}
}

func TestManagedSessionHandleSessionEventAddsSequenceMetadata(t *testing.T) {
	t.Parallel()

	managed := &managedSession{
		session:             &copilot.Session{SessionID: "session-123"},
		subscribers:         make(map[chan sseMessage]struct{}),
		pendingInputs:       make(map[string]*pendingUserInput),
		pendingPermissions:  make(map[string]*pendingPermission),
		messageChunkIndexes: make(map[string]uint64),
	}

	sub := managed.subscribe()
	defer managed.unsubscribe(sub)

	managed.handleSessionEvent(copilot.SessionEvent{
		Type: copilot.SessionEventTypeAssistantMessage,
		Data: &copilot.AssistantMessageData{
			MessageID: "message-1",
			Content:   "first snapshot",
		},
	})

	first := decodeSessionEventPayload(t, (<-sub).Data)
	if first.SequenceID != 1 {
		t.Fatalf("expected first sequenceId to be 1, got %d", first.SequenceID)
	}
	if first.MessageChunkIndex == nil || *first.MessageChunkIndex != 1 {
		t.Fatalf("expected first messageChunkIndex to be 1, got %+v", first.MessageChunkIndex)
	}

	managed.handleSessionEvent(copilot.SessionEvent{
		Type: copilot.SessionEventTypeAssistantMessage,
		Data: &copilot.AssistantMessageData{
			MessageID: "message-1",
			Content:   "second snapshot",
		},
	})

	second := decodeSessionEventPayload(t, (<-sub).Data)
	if second.SequenceID != 2 {
		t.Fatalf("expected second sequenceId to be 2, got %d", second.SequenceID)
	}
	if second.MessageChunkIndex == nil || *second.MessageChunkIndex != 2 {
		t.Fatalf("expected second messageChunkIndex to be 2, got %+v", second.MessageChunkIndex)
	}
}

func TestMarshalReplaySessionEventsHydratesLiveSequenceState(t *testing.T) {
	t.Parallel()

	managed := &managedSession{
		session:             &copilot.Session{SessionID: "session-123"},
		subscribers:         make(map[chan sseMessage]struct{}),
		pendingInputs:       make(map[string]*pendingUserInput),
		pendingPermissions:  make(map[string]*pendingPermission),
		messageChunkIndexes: make(map[string]uint64),
	}

	payloads, count := managed.marshalReplaySessionEvents([]copilot.SessionEvent{
		{
			Type: copilot.SessionEventTypeAssistantMessage,
			Data: &copilot.AssistantMessageData{
				MessageID: "message-1",
				Content:   "first snapshot",
			},
		},
		{
			Type: copilot.SessionEventTypeAssistantMessage,
			Data: &copilot.AssistantMessageData{
				MessageID: "message-1",
				Content:   "second snapshot",
			},
		},
	}, false, 0, 0, 120)

	if count != 2 {
		t.Fatalf("expected 2 replay payloads, got %d", count)
	}
	first := decodeSessionEventPayload(t, payloads[0])
	second := decodeSessionEventPayload(t, payloads[1])
	if first.SequenceID != 1 || second.SequenceID != 2 {
		t.Fatalf("expected replay sequenceIds 1 and 2, got %d and %d", first.SequenceID, second.SequenceID)
	}
	if first.MessageChunkIndex == nil || *first.MessageChunkIndex != 1 {
		t.Fatalf("expected first replay messageChunkIndex to be 1, got %+v", first.MessageChunkIndex)
	}
	if second.MessageChunkIndex == nil || *second.MessageChunkIndex != 2 {
		t.Fatalf("expected second replay messageChunkIndex to be 2, got %+v", second.MessageChunkIndex)
	}

	sub := managed.subscribe()
	defer managed.unsubscribe(sub)

	managed.handleSessionEvent(copilot.SessionEvent{
		Type: copilot.SessionEventTypeAssistantMessage,
		Data: &copilot.AssistantMessageData{
			MessageID: "message-1",
			Content:   "third snapshot",
		},
	})

	live := decodeSessionEventPayload(t, (<-sub).Data)
	if live.SequenceID != 3 {
		t.Fatalf("expected live sequenceId to continue at 3, got %d", live.SequenceID)
	}
	if live.MessageChunkIndex == nil || *live.MessageChunkIndex != 3 {
		t.Fatalf("expected live messageChunkIndex to continue at 3, got %+v", live.MessageChunkIndex)
	}
}

func TestMarshalReplaySessionEventsKeepsFullAssistantMessages(t *testing.T) {
	t.Parallel()

	managed := &managedSession{
		session:             &copilot.Session{SessionID: "session-123"},
		subscribers:         make(map[chan sseMessage]struct{}),
		pendingInputs:       make(map[string]*pendingUserInput),
		pendingPermissions:  make(map[string]*pendingPermission),
		messageChunkIndexes: make(map[string]uint64),
	}

	longContent := "No — **the first `K`** opens the hover **and moves focus into it**.\n\nSo the sequence is:\n\n1. Press **`K`** on an activity line\n2. The hover opens and keeps the full assistant text intact."
	payloads, count := managed.marshalReplaySessionEvents([]copilot.SessionEvent{
		{Type: "assistant.turn_start"},
		{
			Type: copilot.SessionEventTypeAssistantMessage,
			Data: &copilot.AssistantMessageData{
				MessageID: "message-1",
				Content:   longContent,
			},
		},
		{Type: "assistant.turn_end"},
		{Type: "assistant.turn_start"},
		{
			Type: copilot.SessionEventTypeAssistantMessage,
			Data: &copilot.AssistantMessageData{
				MessageID: "message-2",
				Content:   "latest reply",
			},
		},
		{Type: "assistant.turn_end"},
	}, false, 0, 1, 20)

	if count == 0 || len(payloads) == 0 {
		t.Fatal("expected replay payloads")
	}

	found := false
	for _, payload := range payloads {
		decoded := decodeSessionEventPayload(t, payload)
		if decoded.Type != string(copilot.SessionEventTypeAssistantMessage) {
			continue
		}

		var data struct {
			MessageID string `json:"messageId"`
			Content   string `json:"content"`
		}
		if err := json.Unmarshal(decoded.Data, &data); err != nil {
			t.Fatalf("decode assistant message data: %v", err)
		}
		if data.MessageID != "message-1" {
			continue
		}

		found = true
		if data.Content != longContent {
			t.Fatalf("expected full assistant content to be preserved, got %q", data.Content)
		}
	}

	if !found {
		t.Fatal("expected replay payload for the summarized assistant message")
	}
}

func TestReadSelectionTextExtractsExactRange(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	path := filepath.Join(dir, "sample.txt")
	if err := os.WriteFile(path, []byte("alpha beta\ngamma delta\nepsilon zeta\n"), 0o644); err != nil {
		t.Fatalf("write file: %v", err)
	}

	got := readSelectionText(path, lspRange{
		Start: lspPosition{Line: 0, Character: 6},
		End:   lspPosition{Line: 1, Character: 5},
	})
	if got != "beta\ngamma" {
		t.Fatalf("expected exact selection text, got %q", got)
	}
}

func TestLiveSessionSummariesOnlyIncludesAttachedSessions(t *testing.T) {
	t.Parallel()

	detached := &managedSession{
		session:     &copilot.Session{SessionID: "detached-session"},
		subscribers: make(map[chan sseMessage]struct{}),
	}
	attached := &managedSession{
		session:     &copilot.Session{SessionID: "attached-session"},
		subscribers: make(map[chan sseMessage]struct{}),
	}
	sub := attached.subscribe()
	defer attached.unsubscribe(sub)

	svc := &service{
		sessions: map[string]*managedSession{
			"detached-session": detached,
			"attached-session": attached,
		},
	}

	live := svc.liveSessionSummaries()
	if len(live) != 1 {
		t.Fatalf("expected 1 attached session, got %d", len(live))
	}
	if live[0].SessionID != "attached-session" {
		t.Fatalf("expected attached-session, got %+v", live[0])
	}
	if !live[0].Live {
		t.Fatal("expected attached session summary to report live=true")
	}
}

// ── decodeJSON ────────────────────────────────────────────────────────────────

func TestDecodeJSONAcceptsValidBody(t *testing.T) {
	t.Parallel()
	req := httptest.NewRequest(http.MethodPost, "/", strings.NewReader(`{"model":"gpt-5.4"}`))
	req.Header.Set("Content-Type", "application/json")
	var target struct {
		Model string `json:"model"`
	}
	if err := decodeJSON(req, &target); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if target.Model != "gpt-5.4" {
		t.Fatalf("unexpected model: %q", target.Model)
	}
}

func TestDecodeJSONRejectsUnknownFields(t *testing.T) {
	t.Parallel()
	req := httptest.NewRequest(http.MethodPost, "/", strings.NewReader(`{"unknown":"field"}`))
	req.Header.Set("Content-Type", "application/json")
	var target struct {
		Model string `json:"model"`
	}
	if err := decodeJSON(req, &target); err == nil {
		t.Fatal("expected error for unknown field")
	}
}

func TestExtractBackgroundTasksSummarizesSubagentsAndNotifications(t *testing.T) {
	t.Parallel()

	startedAt := time.Date(2026, 4, 29, 11, 0, 0, 0, time.UTC)
	completedAt := startedAt.Add(2 * time.Second)
	failedAt := completedAt.Add(2 * time.Second)
	durationMs := 1250.0
	totalTokens := 321.0
	totalToolCalls := 4.0
	model := "gpt-5.4"
	agentID := "agent-123"
	description := "Analyze repository health"
	summary := "Background agent failed while linting"
	status := copilot.SystemNotificationAgentCompletedStatusFailed

	events := []copilot.SessionEvent{
		{
			Type:      copilot.SessionEventTypeSubagentStarted,
			Timestamp: startedAt,
			Data: &copilot.SubagentStartedData{
				AgentDescription: "Review the changed files",
				AgentDisplayName: "Code Review",
				AgentName:        "code-review",
				ToolCallID:       "tool-1",
			},
		},
		{
			Type:      copilot.SessionEventTypeSubagentCompleted,
			Timestamp: completedAt,
			Data: &copilot.SubagentCompletedData{
				AgentDisplayName: "Code Review",
				AgentName:        "code-review",
				DurationMs:       &durationMs,
				Model:            &model,
				ToolCallID:       "tool-1",
				TotalTokens:      &totalTokens,
				TotalToolCalls:   &totalToolCalls,
			},
		},
		{
			Type:      copilot.SessionEventTypeSystemNotification,
			Timestamp: failedAt,
			Data: &copilot.SystemNotificationData{
				Kind: copilot.SystemNotification{
					Type:        copilot.SystemNotificationTypeAgentCompleted,
					AgentID:     &agentID,
					AgentType:   &model,
					Description: &description,
					Summary:     &summary,
					Status:      &status,
				},
			},
		},
	}

	tasks := extractBackgroundTasks(events)
	if len(tasks) != 2 {
		t.Fatalf("expected 2 tasks, got %d", len(tasks))
	}

	if tasks[0].ID != "background:"+agentID {
		t.Fatalf("expected background task first, got %+v", tasks[0])
	}
	if tasks[0].Status != "failed" {
		t.Fatalf("expected failed background task, got %+v", tasks[0])
	}
	if tasks[0].Description != description {
		t.Fatalf("expected description %q, got %+v", description, tasks[0])
	}
	if tasks[0].Summary != summary {
		t.Fatalf("expected summary %q, got %+v", summary, tasks[0])
	}

	if tasks[1].ID != "subagent:tool-1" {
		t.Fatalf("expected subagent task second, got %+v", tasks[1])
	}
	if tasks[1].Status != "completed" {
		t.Fatalf("expected completed subagent task, got %+v", tasks[1])
	}
	if tasks[1].Model != model {
		t.Fatalf("expected model %q, got %+v", model, tasks[1])
	}
	if tasks[1].DurationMs == nil || *tasks[1].DurationMs != durationMs {
		t.Fatalf("expected duration %.0f, got %+v", durationMs, tasks[1])
	}
}

func TestHandleCreateSessionRestartsDeadClientAndRetries(t *testing.T) {
	t.Parallel()

	workingDir := t.TempDir()
	staleClient := &fakeCopilotClient{
		state:            copilot.StateConnected,
		createSessionErr: errors.New("failed to create session: CLI process exited: signal: killed"),
	}
	freshClient := &fakeCopilotClient{
		state:             copilot.StateConnected,
		createSessionResp: &copilot.Session{SessionID: "session-123"},
	}
	svc := &service{
		client:    staleClient,
		clientCtx: context.Background(),
		clientFactory: func() copilotClient {
			return freshClient
		},
		sessions: make(map[string]*managedSession),
	}

	body := fmt.Sprintf(`{"workingDirectory":%q,"enableConfigDiscovery":false}`, workingDir)
	req := httptest.NewRequest(http.MethodPost, "/sessions", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	svc.handleCreateSession(w, req)

	if w.Code != http.StatusCreated {
		t.Fatalf("want 201, got %d: %s", w.Code, w.Body.String())
	}
	if staleClient.createSessionCalls != 1 {
		t.Fatalf("expected stale client create to be attempted once, got %d", staleClient.createSessionCalls)
	}
	if staleClient.forceStopCalls != 1 {
		t.Fatalf("expected stale client to be force-stopped once, got %d", staleClient.forceStopCalls)
	}
	if freshClient.startCalls != 1 {
		t.Fatalf("expected replacement client to start once, got %d", freshClient.startCalls)
	}
	if freshClient.createSessionCalls != 1 {
		t.Fatalf("expected replacement client create to be attempted once, got %d", freshClient.createSessionCalls)
	}
	if _, ok := svc.getManagedSession("session-123"); !ok {
		t.Fatal("expected retried session to be stored after recovery")
	}
}
