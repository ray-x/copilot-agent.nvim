// Copyright 2026 ray-x. All rights reserved.
// Use of this source code is governed by an Apache 2.0
// license that can be found in the LICENSE file.

package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	copilot "github.com/github/copilot-sdk/go"
)

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
	svc := &service{}
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
	t.Parallel()

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
