package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

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

