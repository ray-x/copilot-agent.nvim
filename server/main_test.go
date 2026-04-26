package main

import (
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
