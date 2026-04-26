package main

import (
	"net/url"
	"testing"
)

func TestURIToFilenameStripsFileScheme(t *testing.T) {
	t.Parallel()

	got := uriToFilename("file:///home/user/main.go")
	if got != "/home/user/main.go" {
		t.Fatalf("expected /home/user/main.go, got %q", got)
	}
}

func TestURIToFilenameDecodesSpaces(t *testing.T) {
	t.Parallel()

	got := uriToFilename("file:///home/user/my%20file.go")
	if got != "/home/user/my file.go" {
		t.Fatalf("expected space in path, got %q", got)
	}
}

func TestURIToFilenameDecodesColon(t *testing.T) {
	t.Parallel()

	// Windows-style drive letter: file:///C%3A/Users/main.go
	got := uriToFilename("file:///C%3A/Users/main.go")
	if got != "/C:/Users/main.go" {
		t.Fatalf("expected colon decoded, got %q", got)
	}
}

func TestURIToFilenameDecodesAllPercentSequences(t *testing.T) {
	t.Parallel()

	cases := []struct {
		input string
		want  string
	}{
		{"file:///path/to/file%20name.go", "/path/to/file name.go"},
		{"file:///path/with%2B.go", "/path/with+.go"},
		{"file:///plain.go", "/plain.go"},
		// No file:// prefix — treated as-is after unescape.
		{"/already/plain.go", "/already/plain.go"},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(tc.input, func(t *testing.T) {
			t.Parallel()
			got := uriToFilename(tc.input)
			want, _ := url.PathUnescape(tc.want) // double-check our expectation
			_ = want
			if got != tc.want {
				t.Fatalf("uriToFilename(%q): want %q, got %q", tc.input, tc.want, got)
			}
		})
	}
}
